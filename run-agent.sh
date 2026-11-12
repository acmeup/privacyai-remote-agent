#!/bin/sh
# run-agent.sh - Privacy AI Remote Agent detach wrapper, version 1.4.
# POSIX sh only (macOS + Linux). Starts one ACP agent detached, with stdin from a
# named pipe and stdout appended to a log, so an SSH client can disconnect and
# reattach. It opens no network connection, installs no service, login item or
# cron entry, and writes only under $BASE and the project folder the agent uses.
#
#   version                               print the script version
#   start  <id> <cwd> <agent command...>  start the agent detached, exit at once
#                                         (a stopped id appends to its out.log: resume)
#   exec   <id> <agent command...>        run the agent in the foreground on this
#                                         channel, with the same environment as start
#   write  <id>                           copy this channel's stdin into the agent
#   read   <id> <byte-offset>             stream out.log from offset (0-based), follow
#   status <id>                           running|stopped agent=<pid> holder=<pid> pgid=<g> out=<bytes>
#   errtail <id> <lines>                  the last <lines> lines of the agent's stderr
#   stop   <id>                           end agent, holder, readers and every descendant;
#                                         keep logs; prints "stopped <id> survivors=<n>"
#                                         (exit 3 when n > 0, one line per survivor on stderr)
#
# Environment (start, exec): the key file <session>/agent.env the app may write
# (0600), then with PRIVACYAI_SHELL_ENV=1 the variables your interactive shell sets
# (~/.zshrc, ~/.bashrc), so the host's own settings win. Never PATH. Both files are
# removed before the agent starts; no value is ever printed.
set -u
VERSION='1.4'
BASE="${PRIVACYAI_HOME:-$HOME/.privacyai}"
SESS="${BASE}/sessions"
# The holder checks the agent every _ra_poll seconds and exits with it.
# Every variable the script reads after load_env is named _ra_*: the capture
# never takes such a name, so an rc that exports d, id or cf cannot redirect it.
_ra_poll="${PRIVACYAI_HOLDER_POLL:-30}"
# stop waits up to STOP_GRACE seconds after TERM, then again after KILL.
STOP_GRACE="${PRIVACYAI_STOP_GRACE:-5}"
case "$STOP_GRACE" in ''|*[!0-9]*) STOP_GRACE=5 ;; esac
# The shell-settings capture may take up to SHELL_ENV_TIMEOUT seconds.
SHELL_ENV_TIMEOUT="${PRIVACYAI_SHELL_ENV_TIMEOUT:-10}"
case "$SHELL_ENV_TIMEOUT" in ''|*[!0-9]*) SHELL_ENV_TIMEOUT=10 ;; esac

die() { printf 'run-agent: %s\n' "$*" >&2; exit 2; }

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) die "bad session id" ;;
  esac
}

# A zombie is not alive: kill -0 succeeds on an exited process nobody reaped yet.
alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in
    Z*) return 1 ;;
    '') kill -0 "$1" 2>/dev/null || return 1 ;;
  esac
  return 0
}

# lstart <pid>: the process's start time as ps prints it ("" when gone or unsupported).
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }

# owned <pid> <start file>: alive and still the process the session recorded. A pid
# file outlives its process and the pid can be reused, so a recorded start time must
# match; an empty or missing one (no lstart in this ps, a 1.2 session) is not checked.
owned() {
  alive "$1" || return 1
  rec="$(cat "$2" 2>/dev/null)"
  [ -z "$rec" ] || [ "$(lstart "$1")" = "$rec" ]
}

# tree "<pids>": those pids, their descendants (by parent pid, to a fixed point)
# and the members of a process group one of them leads. Never this shell. A pid
# passed in is kept even when it is gone, so the caller's set only grows.
tree() {
  ps -A -o pid= -o ppid= -o pgid= 2>/dev/null | awk -v seed="$1" -v self="$$" '
    BEGIN { n = split(seed, s, " ")
            for (i = 1; i <= n; i++) if (s[i] ~ /^[0-9]+$/ && s[i] + 0 > 1 && s[i] + 0 != self + 0) t[s[i] + 0] = 1 }
    { pp[$1 + 0] = $2 + 0; pg[$1 + 0] = $3 + 0 }
    END {
      do {
        more = 0
        for (p in pp) if (!(p in t) && p + 0 > 1 && p + 0 != self + 0 && ((pp[p] in t) || (pg[p] in t))) { t[p] = 1; more = 1 }
      } while (more)
      for (p in t) printf "%s ", p
    }'
}

# sweep <TERM|KILL>: collect the session's processes again, signal the live ones
# (TERM once per pid, KILL every time) and leave them in $left.
tset=""; termed=" "; left=""
sweep() {
  tset="$(tree "$tset")"; left=""
  for p in $tset; do
    alive "$p" || continue
    left="$left $p"
    if [ "$1" = TERM ]; then
      case "$termed" in *" $p "*) continue ;; esac
      termed="$termed$p "
    fi
    kill -"$1" "$p" 2>/dev/null
  done
}

# The capture's awk program (no single quote in it: it runs inside the shell's -c).
# Prints export NAME='value' for every variable except bad names, PATH and the
# shell's own or read-only ones, and empty values; then "#@@end <count>".
CAPTURE_AWK='BEGIN {
  sq = sprintf("%c", 39); bs = sprintf("%c", 92); n = 0
  for (k in ENVIRON) {
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
    if (k ~ /^(PATH|PWD|OLDPWD|SHLVL|_|PRIVACYAI_.*|_ra_.*|UID|EUID|PPID|SHELLOPTS|BASHOPTS|BASH_.*|IFS|CDPATH|ENV|OPTIND|PS[1-4])$/) continue
    v = ENVIRON[k]
    if (v == "") continue
    o = ""
    while ((i = index(v, sq)) > 0) { o = o substr(v, 1, i - 1) sq bs sq sq; v = substr(v, i + 1) }
    printf "export %s=%s%s%s\n", k, sq, o v, sq
    n++
  }
  printf "#@@end %d\n", n
}'

note() { printf 'run-agent: shell settings not loaded (%s); using the login environment\n' "$1" >&2; }

# load_env <session dir>: the app's key file (the fallback), then the interactive
# shell's environment (the host's own settings win). Never PATH; values never printed.
load_env() {
  ef="$1/agent.env"
  if [ -f "$ef" ]; then
    if ( . "$ef" ) >/dev/null 2>&1; then . "$ef"; else printf 'run-agent: key file not loaded\n' >&2; fi
    rm -f "$ef"
  fi
  [ "${PRIVACYAI_SHELL_ENV:-}" = 1 ] || return 0
  # zsh/ksh: a login + interactive shell, as a terminal opens it (.zprofile, then
  # .zshrc); bash: interactive (~/.bashrc); sh/dash: interactive ($ENV).
  _ra_sh="${SHELL:-}"
  case "${_ra_sh##*/}" in
    zsh|ksh) sf="-l -i" ;;
    bash|sh|dash) sf="-i" ;;
    *) note "unsupported shell"; return 0 ;;
  esac
  _ra_cf="$1/shell.env"
  ( umask 077; : > "$_ra_cf" ) || { note "failed"; return 0; }
  PRIVACYAI_CAPTURE_AWK="$CAPTURE_AWK" "$_ra_sh" $sf -c 'exec awk "$PRIVACYAI_CAPTURE_AWK" >&3' 3>"$_ra_cf" </dev/null >/dev/null 2>&1 &
  sp=$!
  n=$((SHELL_ENV_TIMEOUT * 5)); tick=0.2
  while alive "$sp" && [ "$n" -gt 0 ]; do
    # Fractional sleep is not POSIX: fall back to whole seconds.
    sleep "$tick" 2>/dev/null || { tick=1; sleep 1; n=$((n - 4)); }
    n=$((n - 1))
  done
  if alive "$sp"; then
    # The capture and every child its rc started; never a group signal.
    tset="$sp"; sweep KILL; sweep KILL; tset=""; termed=" "; left=""
    wait "$sp" 2>/dev/null
    rm -f "$_ra_cf"; note "timeout"; return 0
  fi
  wait "$sp" 2>/dev/null; rc=$?
  _ra_last="$(tail -n 1 "$_ra_cf" 2>/dev/null)"
  case "$_ra_last" in '#@@end'*) ;; *) rc=1 ;; esac
  if [ "$rc" -ne 0 ] || ! ( . "$_ra_cf" ) >/dev/null 2>&1; then rm -f "$_ra_cf"; note "failed"; return 0; fi
  . "$_ra_cf"; rm -f "$_ra_cf"
  _ra_c="${_ra_last#?@@end}"; _ra_c="${_ra_c# }"
  case "$_ra_c" in ''|*[!0-9]*) _ra_c="?" ;; esac
  printf 'run-agent: shell settings loaded (%s variables)\n' "$_ra_c" >&2
}

# sweep_keys: a key file whose start never ran (the connection dropped after the
# upload, a discarded id) is removed by the next start, exec or version.
sweep_keys() {
  [ -d "$SESS" ] || return 0
  find "$SESS" -mindepth 2 -maxdepth 2 \( -name agent.env -o -name shell.env \) -mmin +5 -exec rm -f {} + 2>/dev/null
  return 0
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  version)
    sweep_keys
    echo "$VERSION"
    ;;
  start)
    [ $# -ge 3 ] || die "usage: start <id> <cwd> <agent command...>"
    _ra_id="$1"; cwd="$2"; shift 2; valid_id "$_ra_id"
    _ra_d="${SESS}/${_ra_id}"
    # A die before the key file is sourced never leaves a key behind.
    trap 'rm -f "$_ra_d/agent.env" "$_ra_d/shell.env"' EXIT
    sweep_keys
    [ -e "$_ra_d/agent.pid" ] && owned "$(cat "$_ra_d/agent.pid")" "$_ra_d/agent.start" && die "session already running"
    # No umask change: the agent inherits the user's own umask for the files it
    # writes in the project. Only the session folder and its files are private.
    mkdir -p "$_ra_d" || die "cannot create $_ra_d"
    chmod 700 "$BASE" "$SESS" "$_ra_d"
    cd "$cwd" || die "cannot cd to $cwd"
    rm -f "$_ra_d/in"
    mkfifo -m 600 "$_ra_d/in" || die "mkfifo failed"
    : >> "$_ra_d/out.log"; : >> "$_ra_d/err.log"
    chmod 600 "$_ra_d/out.log" "$_ra_d/err.log"
    load_env "$_ra_d" 2>> "$_ra_d/err.log"
    # The agent: stdin from the fifo (open blocks until the holder opens the
    # write end), stdout appended to out.log. nohup ignores SIGHUP.
    nohup "$@" < "$_ra_d/in" >> "$_ra_d/out.log" 2>> "$_ra_d/err.log" &
    _ra_agent=$!
    echo "$_ra_agent" > "$_ra_d/agent.pid"
    lstart "$_ra_agent" > "$_ra_d/agent.start"
    # The holder keeps a write end of the fifo open for the agent's whole life,
    # so a client writer that disconnects never delivers EOF to the agent, and
    # ends with the agent: an agent that exits by itself leaves no process behind.
    # It then removes the pid files (unless a new start replaced them meanwhile).
    nohup sh -c 'exec 3>"$1/in"; while kill -0 "$2" 2>/dev/null; do sleep "$3"; done; [ "$(cat "$1/agent.pid" 2>/dev/null)" = "$2" ] && rm -f "$1/agent.pid" "$1/holder.pid"' holder "$_ra_d" "$_ra_agent" "$_ra_poll" < /dev/null > /dev/null 2>&1 &
    _ra_holder=$!
    echo "$_ra_holder" > "$_ra_d/holder.pid"
    lstart "$_ra_holder" > "$_ra_d/holder.start"
    # This exec's process group, for the record only (status prints it). stop
    # never signals it: other sessions of the same SSH connection can share it.
    ps -o pgid= -p $$ | tr -d ' ' > "$_ra_d/pgid"
    # An agent that exits at once can take the pid files with its holder already.
    chmod 600 "$_ra_d/agent.pid" "$_ra_d/holder.pid" "$_ra_d/agent.start" "$_ra_d/holder.start" "$_ra_d/pgid" 2>/dev/null
    printf 'started %s agent=%s holder=%s pgid=%s\n' "$_ra_id" "$_ra_agent" "$_ra_holder" "$(cat "$_ra_d/pgid")"
    exit 0
    ;;
  exec)
    [ $# -ge 2 ] || die "usage: exec <id> <agent command...>"
    _ra_id="$1"; shift; valid_id "$_ra_id"
    sweep_keys
    _ra_d="${SESS}/${_ra_id}"
    trap 'rm -f "$_ra_d/agent.env" "$_ra_d/shell.env"' EXIT
    mkdir -p "$_ra_d" || die "cannot create $_ra_d"
    chmod 700 "$BASE" "$SESS" "$_ra_d"
    load_env "$_ra_d"
    rmdir "$_ra_d" 2>/dev/null
    trap - EXIT
    exec "$@"
    ;;
  write)
    [ $# -eq 1 ] || die "usage: write <id>"
    id="$1"; valid_id "$id"; d="${SESS}/${id}"
    [ -p "$d/in" ] || die "no such session"
    owned "$(cat "$d/agent.pid" 2>/dev/null)" "$d/agent.start" || die "agent not running"
    exec cat > "$d/in"
    ;;
  read)
    [ $# -eq 2 ] || die "usage: read <id> <byte-offset>"
    id="$1"; off="$2"; valid_id "$id"; d="${SESS}/${id}"
    case "$off" in ''|*[!0-9]*) die "bad offset" ;; esac
    [ -f "$d/out.log" ] || die "no such session"
    # One reader per session: a reader left by a dropped connection only notices
    # on its next write (SIGPIPE), so end it here. Each line: "<pid> <start time>".
    if [ -f "$d/readers" ]; then
      while read -r p ps_start; do
        [ -z "$ps_start" ] || [ "$(lstart "$p")" = "$ps_start" ] || continue
        alive "$p" && kill -TERM "$p" 2>/dev/null
      done < "$d/readers"
    fi
    : > "$d/readers"
    tail -c +"$((off + 1))" -f "$d/out.log" &
    tp=$!
    echo "$tp $(lstart "$tp")" > "$d/readers"
    wait "$tp"
    ;;
  status)
    [ $# -eq 1 ] || die "usage: status <id>"
    id="$1"; valid_id "$id"; d="${SESS}/${id}"
    [ -d "$d" ] || die "no such session"
    a="$(cat "$d/agent.pid" 2>/dev/null)"; h="$(cat "$d/holder.pid" 2>/dev/null)"
    st=stopped; owned "$a" "$d/agent.start" && st=running
    sz=$(wc -c < "$d/out.log" | tr -d ' ')
    printf '%s agent=%s holder=%s pgid=%s out=%s\n' "$st" "$a" "$h" "$(cat "$d/pgid" 2>/dev/null)" "$sz"
    ;;
  errtail)
    [ $# -eq 2 ] || die "usage: errtail <id> <lines>"
    id="$1"; n="$2"; valid_id "$id"; d="${SESS}/${id}"
    case "$n" in ''|*[!0-9]*) die "bad line count" ;; esac
    [ -f "$d/err.log" ] || die "no such session"
    tail -n "$n" "$d/err.log"
    ;;
  stop)
    [ $# -eq 1 ] || die "usage: stop <id>"
    id="$1"; valid_id "$id"; d="${SESS}/${id}"
    [ -d "$d" ] || die "no such session"
    # Only recorded pids that are still the session's own (owned: start time
    # matches) seed the set; a reused pid belongs to someone else.
    a=""; h=""; r=""
    p="$(cat "$d/agent.pid" 2>/dev/null)"; owned "$p" "$d/agent.start" && a="$p"
    p="$(cat "$d/holder.pid" 2>/dev/null)"; owned "$p" "$d/holder.start" && h="$p"
    if [ -f "$d/readers" ]; then
      while read -r p ps_start; do
        alive "$p" || continue
        [ -z "$ps_start" ] || [ "$(lstart "$p")" = "$ps_start" ] || continue
        r="$r $p"
      done < "$d/readers"
    fi
    # Never a process group signal: on a host the execs of one SSH connection can
    # share a group, so the recorded pgid may hold other sessions too. The tree is
    # ended pid by pid: TERM, up to STOP_GRACE seconds, then KILL and the same wait.
    # It is collected again on every round, so a child that lost its parent
    # mid-stop, or was started meanwhile, is still found.
    tset="$(echo $a $h $r)"
    tick=0.2
    for sig in TERM KILL; do
      n=$((STOP_GRACE * 5))
      while sweep "$sig"; [ -n "$left" ] && [ "$n" -gt 0 ]; do
        # Fractional sleep is not POSIX: fall back to whole seconds.
        sleep "$tick" 2>/dev/null || { tick=1; sleep 1; n=$((n - 4)); }
        n=$((n - 1))
      done
      [ -z "$left" ] && break
    done
    rm -f "$d/readers" "$d/in"
    n=0
    for p in $left; do
      alive "$p" || continue
      n=$((n + 1))
      printf 'run-agent: survivor %s\n' "$(ps -o pid= -o ppid= -o pgid= -o stat= -o args= -p "$p" 2>/dev/null | tr -s ' ' | sed 's/^ //')" >&2
    done
    echo "stopped $id survivors=$n"
    [ "$n" -eq 0 ] || exit 3
    ;;
  *)
    die "usage: version|start|exec|write|read|status|errtail|stop"
    ;;
esac
