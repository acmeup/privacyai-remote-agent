# privacyai-remote-agent

`run-agent.sh` is the small shell script that the Privacy AI app's **Remote Agent** copies to your own
computer or server, so a coding agent you start from your phone keeps running when the phone sleeps or
loses its connection. This repository publishes the script so you can read exactly what runs on your host.

## What it does

- Starts the coding agent you chose (through its Agent Client Protocol command) in the folder you chose, detached from the SSH connection, so it keeps running after the connection drops.
- Keeps the agent's output in `~/.privacyai/sessions/<session id>/out.log` (and its errors in
  `err.log`) until the app reconnects and reads it, and lets the app reattach to a run that is still going.
- Ends a session's agent and every process it started when you end the session in the app, and keeps
  the logs.
- Starts the agent with your own settings when the app asks for them: the variables your interactive shell
  sets (`~/.zshrc`, `~/.bashrc`), read by a separate shell run with no input and its output discarded, with a
  time limit (10 seconds by default; a shell setup that takes longer is skipped and its processes ended).
  Your `PATH`, your shell's own internal variables and empty values are never taken from it.
- When you turn on "Use Privacy AI API keys" for a host in the app, and an agent has no sign-in of its own
  on the host, the app writes that agent's API key to a file in the session folder that only your user can
  read (`agent.env`). The script loads it and deletes it before the agent starts; a key your shell sets
  wins over it. A key file left by a dropped connection is deleted within minutes by the next run. No key
  is ever printed or put on a command line.

## What it never does

- It opens no network connection of its own: no server, no open port. The app reaches it over your own
  SSH connection. (Your shell setup, when the app asks the script to load it, runs as it does in a terminal.)
- It installs no background service, login item or scheduled job, and runs only while a run is going.
- It writes nothing outside `~/.privacyai` and the project folder the agent itself works in. The session
  folders and their files are readable by your user only.
- It is POSIX `sh` only (macOS and Linux) and passes `sh -n` and `dash -n`.

## Commands

The app runs these over SSH; you never need to run them yourself.

| Command | What it does |
|---|---|
| `version` | Prints the script version. |
| `start <id> <cwd> <agent command...>` | Starts the agent detached and returns at once. Starting a stopped id again continues its `out.log` (resume). |
| `exec <id> <agent command...>` | Runs the agent in the foreground on the SSH channel, with the same settings as `start` (the app's connection test). |
| `write <id>` | Copies the SSH channel's input into the agent. |
| `read <id> <byte offset>` | Streams `out.log` from the offset and follows it. |
| `status <id>` | Prints `running` or `stopped` with the recorded process ids and the size of `out.log`. |
| `errtail <id> <lines>` | Prints the last lines of the agent's `err.log`. |
| `stop <id>` | Ends the agent and every process it started; keeps the logs. |

## Where the logs are

Each session has a folder in `~/.privacyai/sessions/` with the agent's output (`out.log`) and errors
(`err.log`). Files you attach in the app are uploaded to the session's `uploads` folder there.

## How it is installed and checked

Privacy AI installs the script at `~/.privacyai/run-agent.sh` the first time it connects to a host, and
on every connection compares `run-agent.sh version` with the version it carries. It replaces the copy
only when the version differs, through a temporary name and a rename.

To read the copy installed on your host:

```sh
cat ~/.privacyai/run-agent.sh
~/.privacyai/run-agent.sh version
```

The file in this repository at the tag `v<version>` is the script of that version.

## How to remove it

Delete the folder on the host:

```sh
rm -rf ~/.privacyai
```

The next connection from the app copies the script again. Without it, a run stops when the connection drops.

## Versions

- 1.4: agents can start with the variables your interactive shell sets, and with an API key the app delivers
  in a private file that is deleted before the agent starts; new `exec` command for the connection test.
- 1.3: recorded process ids are checked against their start time, so a reused process id is never treated
  as the session's agent.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
