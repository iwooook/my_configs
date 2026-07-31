#!/bin/bash
# Ensure a `claude rc` (remote-control) tmux session exists on the DEFAULT tmux
# socket, so it shows up in a plain `tmux ls` and can be attached with a plain
# `tmux attach -t claude-rc` — no special socket needed.
#
# Crash recovery is handled INSIDE tmux by a while-loop that re-runs claude rc,
# so systemd only has to make sure the session exists (at boot). This keeps the
# session on the shared default socket without systemd needing to own/kill it.
set -u

SESSION=claude-rc
. "$(dirname "$(readlink -f "$0")")/remote-access-common.sh"
ra_load_env

# Where remote-control sessions start. Fall back to $HOME rather than trusting
# the configured path, so a missing directory cannot break the unit.
WORKDIR=${CLAUDE_RC_WORKDIR:-$HOME}
[ -d "$WORKDIR" ] || WORKDIR="$HOME"

if ! CLAUDE=$(ra_find_claude); then
  echo "start-claude-rc: no claude binary found; set CLAUDE_BIN in $RA_ENV_FILE" >&2
  exit 1
fi

# Idempotent: if the session is already there, do nothing.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exit 0
fi

tmux new-session -d -s "$SESSION" -c "$WORKDIR" \
  "while true; do '$CLAUDE' rc; echo '[claude rc exited, restarting in 5s]'; sleep 5; done"
