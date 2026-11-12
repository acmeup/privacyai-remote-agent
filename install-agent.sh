#!/bin/sh
# install-agent.sh - Privacy AI Remote Agent installer, version 1.0.
# POSIX sh only (macOS + Linux). Installs or upgrades one npm-published ACP agent
# for the user who runs it, always at its latest version:
#   - an agent this script installed before ($BASE/tools/bin/<bin>) is upgraded there;
#   - an npm-managed copy whose npm prefix you can write and whose Node is new enough
#     is upgraded in place (your own prefix and npm cache, which is what an in-place
#     upgrade means);
#   - otherwise the agent goes into $BASE/tools (npm prefix; programs in tools/bin),
#     with its own Node in tools/node when the host has none, has no npm or has one
#     older than the agent needs (the newest LTS from nodejs.org, SHA-256 checked
#     against SHASUMS256.txt; there is no GPG check);
#   - a copy that is not npm-managed (a git checkout, an official installer, Homebrew
#     formula) is left alone and the reason is printed.
# It opens network connections to nodejs.org and the npm registry, never uses sudo,
# never edits a shell rc or profile, and installs no service, login item or cron
# entry. Removing $BASE/tools undoes everything it installed there.
#
#   version                                          print the script version
#   plan <bin> <npm-package> <min-node> [<path>]     decide and print, change nothing
#   run  <bin> <npm-package> <min-node> [<path>]     the same decision, then do it
#
# <path> is where the host's copy of <bin> is, when known. Output (stdout, one per line):
#   @@decision <install|upgrade|skip> <tools|inplace|none> <reason>
#   @@node <have|install> <version>
#   @@step <n> <total> <name>
#   @@cmd <shell-quoted argv>          plan prints every command run would run, in order
#   @@result <ok|failed|skipped> <reason> [where=<tools|inplace> bin=<path> version=<first line>]
# version= is last and runs to the end of the line. Every other line is tool output.
# Exit 0 ok or skipped, 1 failed, 2 usage.
set -u
VERSION='1.0'
BASE="${PRIVACYAI_HOME:-$HOME/.privacyai}"
T="${BASE}/tools"
NODE_DIST='https://nodejs.org/dist'
NL='
'

usage() { printf 'install-agent: %s\n' "$*"; exit 2; }
mark() { printf '%s\n' "$*"; }
fail() { mark "@@result failed $*"; exit 1; }

# q <word>: the word as a shell word (single-quoted unless it is plain).
q() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:=@,+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

showcmd() {
  _l='@@cmd'
  for _a in "$@"; do _l="$_l $(q "$_a")"; done
  printf '%s\n' "$_l"
}

# step <argv...>: print it; in run mode run it (no eval, stdin /dev/null).
step() {
  showcmd "$@"
  [ "$MODE" = run ] || return 0
  "$@" </dev/null
}

# step_cap <argv...>: as step, the output into _out instead of stdout.
step_cap() {
  showcmd "$@"
  _out=''
  [ "$MODE" = run ] || return 0
  _out="$("$@" </dev/null 2>&1)"
}

_sn=0
phase() { _sn=$((_sn + 1)); mark "@@step $_sn $_st $1"; }

# ver_ge <a> <b>: a >= b, numeric on up to three dot parts (a leading v ignored).
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/^v/, "", a); sub(/^v/, "", b)
    na = split(a, x, "."); nb = split(b, y, ".")
    for (i = 1; i <= 3; i++) {
      p = (i <= na) ? x[i] + 0 : 0; r = (i <= nb) ? y[i] + 0 : 0
      if (p > r) exit 0
      if (p < r) exit 1
    }
    exit 0 }'
}

# node_ver <node>: X.Y.Z of that node ("" when it does not run).
node_ver() {
  [ -x "$1" ] || return 0
  "$1" --version 2>/dev/null </dev/null | head -n 1 | sed -n 's/^v\{0,1\}\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p'
}

# npm_for <node>: the npm next to that node, else the one on PATH.
npm_for() {
  _d="$(dirname "$1")"
  if [ -x "$_d/npm" ]; then printf '%s\n' "$_d/npm"; else command -v npm 2>/dev/null || true; fi
}

# qualifies <node>: sets NODE_BIN NODE_V NPM_BIN when that node is >= MIN and has an npm.
qualifies() {
  [ -n "$1" ] && [ -x "$1" ] || return 1
  _v="$(node_ver "$1")"
  [ -n "$_v" ] && ver_ge "$_v" "$MIN" || return 1
  _m="$(npm_for "$1")"
  [ -n "$_m" ] || return 1
  NODE_BIN="$1"; NODE_V="$_v"; NPM_BIN="$_m"
  return 0
}

# resolve <path>: the path with every symlink followed (POSIX readlink loop).
resolve() {
  _p="$1"; _i=0
  while [ -L "$_p" ] && [ "$_i" -lt 40 ]; do
    _k="$(readlink "$_p")" || break
    case "$_k" in
      /*) _p="$_k" ;;
      *) _p="$(dirname "$_p")/$_k" ;;
    esac
    _i=$((_i + 1))
  done
  _d="$(cd -P "$(dirname "$_p")" 2>/dev/null && pwd -P)" && _p="$_d/$(basename "$_p")"
  printf '%s\n' "$_p"
}

# Timeouts: an unreachable or stalled server fails instead of hanging. fetch (the small
# index.tab, read during plan) ends within about 60 s, inside the app's plan deadline;
# a download fails after 15 s without a connection or 60 s without data.
fetch() {
  case "$DL" in
    curl) curl -fsSL --connect-timeout 10 --max-time 20 --retry 3 --retry-max-time 40 "$1" ;;
    wget) wget -q -T 15 -t 2 -O - "$1" ;;
  esac
}

download() {
  case "$DL" in
    curl) step curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 1 --speed-time 60 -o "$1" "$2" ;;
    wget) step wget -q -T 60 -t 3 -O "$1" "$2" ;;
  esac
}

# Node for tools: os/arch, downloader, checksum tool, the version from index.tab.
plan_node() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) _os=darwin; _ft=osx ;;
    Linux) _os=linux; _ft=linux ;;
    *) fail "unsupported-os" ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    x86_64 | amd64) _ar=x64 ;;
    arm64 | aarch64) _ar=arm64 ;;
    *) fail "unsupported-arch" ;;
  esac
  if [ "$_os" = linux ]; then
    [ -f /etc/alpine-release ] && fail "musl"
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then fail "musl"; fi
  fi
  if command -v curl >/dev/null 2>&1; then DL=curl
  elif command -v wget >/dev/null 2>&1; then DL=wget
  else fail "no-downloader"; fi
  if command -v sha256sum >/dev/null 2>&1; then SHA=sha256sum
  elif command -v shasum >/dev/null 2>&1; then SHA=shasum
  else fail "no-sha256"; fi
  if [ "$_os" = darwin ]; then _tok="osx-$_ar-tar"; else _tok="linux-$_ar"; fi
  _idx="$(fetch "$NODE_DIST/index.tab")" || fail "node-index"
  # Newest first: the newest LTS row with this platform's build that meets MIN,
  # else the newest release (never a prerelease) that does.
  NV="$(printf '%s\n' "$_idx" | awk -F '\t' -v tok="$_tok" -v min="$MIN" '
    function ge(a, b,   x, y, na, nb, i, p, r) {
      sub(/^v/, "", a); na = split(a, x, "."); nb = split(b, y, ".")
      for (i = 1; i <= 3; i++) {
        p = (i <= na) ? x[i] + 0 : 0; r = (i <= nb) ? y[i] + 0 : 0
        if (p > r) return 1
        if (p < r) return 0
      }
      return 1 }
    $1 !~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { next }
    index("," $3 ",", "," tok ",") == 0 { next }
    !ge($1, min) { next }
    lts == "" && $10 != "" && $10 != "-" { lts = $1 }
    any == "" { any = $1 }
    END { if (lts != "") print lts; else if (any != "") print any }')"
  [ -n "$NV" ] || fail "no-node-version"
  NODE_DIR="node-$NV-$_os-$_ar"
}

# decide: sets ACTION LOC REASON and, for an install or upgrade, PREFIX and the node.
decide() {
  NEED_NODE=0; NODE_BIN=''; NODE_V=''; NPM_BIN=''; HOSTPATH=''
  if [ -e "$T/bin/$BIN" ] || [ -L "$T/bin/$BIN" ]; then
    ACTION=upgrade; LOC=tools; REASON=tools
  else
    _cp="$CUR"
    if [ -z "$_cp" ] || ! [ -e "$_cp" ]; then
      _cp="$(command -v "$BIN" 2>/dev/null || true)"
      case "$_cp" in /*) ;; *) _cp='' ;; esac
    fi
    if [ -z "$_cp" ]; then
      ACTION=install; LOC=tools; REASON=fresh
    else
      HOSTPATH="$_cp"
      _rp="$(resolve "$_cp")"
      case "$_rp" in
        */Cellar/* | */Caskroom/*)
          # A Homebrew formula or cask (even one built with npm) belongs to Homebrew.
          ACTION=skip; LOC=none; REASON=not-npm
          ;;
        */lib/node_modules/"$PKG"/*)
          _pf="${_rp%%/lib/node_modules/"$PKG"/*}"
          # npm replaces the package folder: it, its parent (the scope folder) and the
          # prefix's bin must all be writable, else the install goes into tools.
          _pd="$_pf/lib/node_modules/$PKG"
          if ! [ -w "$_pf/lib/node_modules" ] || ! [ -w "$_pf/bin" ] || ! [ -w "$_pd" ] \
            || ! [ -w "$(dirname "$_pd")" ]; then
            ACTION=install; LOC=tools; REASON=npm-unwritable
          else
            _nd="$_pf/bin/node"
            [ -x "$_nd" ] || _nd="$(command -v node 2>/dev/null || true)"
            if qualifies "$_nd"; then
              ACTION=upgrade; LOC=inplace; REASON=npm-writable; PREFIX="$_pf"
            else
              ACTION=install; LOC=tools; REASON=node-too-old
            fi
          fi
          ;;
        *)
          ACTION=skip; LOC=none; REASON=not-npm
          ;;
      esac
    fi
  fi
  mark "@@decision $ACTION $LOC $REASON"
  [ "$ACTION" = skip ] && return 0
  if [ "$LOC" = tools ]; then
    PREFIX="$T"
    NODE_BIN=''
    if ! qualifies "$T/node/bin/node" && ! qualifies "$(command -v node 2>/dev/null || true)"; then
      NEED_NODE=1
      plan_node
      NODE_BIN="$T/node/bin/node"; NPM_BIN="$T/node/bin/npm"
    fi
  fi
  if [ "$NEED_NODE" = 1 ]; then mark "@@node install $NV"; else mark "@@node have v$NODE_V"; fi
}

# The Node swap: never a half-written tools/node (the old one is moved aside first and
# moved back when the new one cannot take its place).
install_node() {
  _tar="$T/.dl/$NODE_DIR.tar.gz"
  phase download-node
  step rm -rf "$T/.dl" || fail "download"
  step mkdir -p "$T/.dl/x" || fail "download"
  download "$T/.dl/SHASUMS256.txt" "$NODE_DIST/$NV/SHASUMS256.txt" || { cleanup_dl; fail "download"; }
  download "$_tar" "$NODE_DIST/$NV/$NODE_DIR.tar.gz" || { cleanup_dl; fail "download"; }
  phase check-node
  if [ "$SHA" = sha256sum ]; then step_cap sha256sum "$_tar"; else step_cap shasum -a 256 "$_tar"; fi
  _rc=$?
  if [ "$MODE" = run ]; then
    _want="$(awk -v f="$NODE_DIR.tar.gz" '$2 == f { print $1; exit }' "$T/.dl/SHASUMS256.txt" 2>/dev/null)"
    _got="$(printf '%s\n' "$_out" | awk 'NR == 1 { print $1 }')"
    if [ "$_rc" -ne 0 ] || [ -z "$_want" ] || [ "$_want" != "$_got" ]; then
      cleanup_dl
      fail "checksum"
    fi
  fi
  phase unpack-node
  step tar -xzf "$_tar" -C "$T/.dl/x" || { cleanup_dl; fail "unpack"; }
  if [ "$MODE" = run ] && ! [ -x "$T/.dl/x/$NODE_DIR/bin/node" ]; then cleanup_dl; fail "unpack"; fi
  # The new Node must start on this host before it replaces anything (a missing
  # shared library such as libatomic.so.1 shows here, with the loader's message).
  step_cap "$T/.dl/x/$NODE_DIR/bin/node" --version
  _rc=$?
  if [ "$MODE" = run ]; then
    [ -n "$_out" ] && printf '%s\n' "$_out"
    case "$_out" in
      v[0-9]*) [ "$_rc" -eq 0 ] || { cleanup_dl; fail "node-start"; } ;;
      *) cleanup_dl; fail "node-start" ;;
    esac
  fi
  if [ -e "$T/node" ] || [ -L "$T/node" ]; then
    step mv "$T/node" "$T/.dl/node.old" || { cleanup_dl; fail "unpack"; }
    step mv "$T/.dl/x/$NODE_DIR" "$T/node" || {
      mv "$T/.dl/node.old" "$T/node" 2>/dev/null
      cleanup_dl
      fail "unpack"
    }
  else
    step mv "$T/.dl/x/$NODE_DIR" "$T/node" || { cleanup_dl; fail "unpack"; }
  fi
  step rm -rf "$T/.dl"
}

cleanup_dl() {
  [ "$MODE" = run ] || return 0
  showcmd rm -rf "$T/.dl"
  rm -rf "$T/.dl"
}

act() {
  if [ "$ACTION" = skip ]; then
    mark "@@result skipped $REASON bin=$HOSTPATH"
    exit 0
  fi
  if [ "$NEED_NODE" = 1 ]; then _st=5; else _st=2; fi
  [ "$NEED_NODE" = 1 ] && install_node
  _nb="$(dirname "$NODE_BIN")"
  phase install-agent
  if [ "$LOC" = tools ]; then
    step mkdir -p "$T" || fail "npm-install"
    step env "PATH=$_nb:$PATH" "npm_config_cache=$T/.npm-cache" "$NPM_BIN" install -g --prefix "$T" \
      --no-fund --no-audit "$PKG@latest" || fail "npm-install"
  else
    step env "PATH=$PREFIX/bin:$PATH" "$NPM_BIN" install -g --prefix "$PREFIX" \
      --no-fund --no-audit "$PKG@latest" || fail "npm-install"
  fi
  phase verify-agent
  _vp="$_nb:$PREFIX/bin"
  [ "$_nb" = "$PREFIX/bin" ] && _vp="$_nb"
  step_cap env "PATH=$_vp:$PATH" "$PREFIX/bin/$BIN" --version
  _rc=$?
  [ "$MODE" = run ] || exit 0
  [ -n "$_out" ] && printf '%s\n' "$_out"
  _ver="$(printf '%s\n' "$_out" | head -n 1)"
  if [ "$_rc" -ne 0 ] || [ -z "$_ver" ]; then fail "verify where=$LOC bin=$PREFIX/bin/$BIN"; fi
  mark "@@result ok $REASON where=$LOC bin=$PREFIX/bin/$BIN version=$_ver"
  exit 0
}

MODE="${1:-}"; [ $# -gt 0 ] && shift
case "$MODE" in
  version)
    echo "$VERSION"
    exit 0
    ;;
  plan | run) ;;
  *) usage "usage: version|plan|run <bin> <npm-package> <min-node> [<path>]" ;;
esac
[ $# -ge 3 ] && [ $# -le 4 ] || usage "usage: $MODE <bin> <npm-package> <min-node> [<path>]"
BIN="$1"; PKG="$2"; MIN="$3"; CUR="${4:-}"
case "$BIN" in
  '' | . | .. | *[!A-Za-z0-9._-]*) usage "bad bin" ;;
esac
case "$PKG" in
  @*/*)
    _s="${PKG%%/*}"; _s="${_s#@}"; _n="${PKG#*/}"
    case "$_s" in '' | *[!a-z0-9._-]*) usage "bad package" ;; esac
    case "$_n" in '' | *[!a-z0-9._-]*) usage "bad package" ;; esac
    ;;
  '' | *[!a-z0-9._-]*) usage "bad package" ;;
esac
printf '%s\n' "$MIN" | grep -Eqx '[0-9]+(\.[0-9]+){0,2}' || usage "bad min-node"
case "$CUR" in *"$NL"*) usage "bad path" ;; esac

[ "$MODE" = run ] && exec 2>&1
decide
# plan walks the same steps as run: step prints each command and runs none of them.
act
