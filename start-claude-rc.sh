#!/bin/bash
# Ensure a `claude rc` (remote-control) tmux session exists on the DEFAULT
# tmux socket, so it shows up in a plain `tmux ls` and can be attached with
# `tmux attach -t claude-rc` — no special socket needed.
#
# Crash recovery is handled INSIDE tmux by a while-loop that re-runs claude rc,
# so systemd only has to make sure the session exists (at boot). This keeps the
# session on the shared default socket without systemd needing to own/kill it.
set -u

SESSION=claude-rc
WORKDIR=/home/jungwook/TAPER
CLAUDE=/home/jungwook/.local/bin/claude

# Idempotent: if the session is already there, do nothing.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exit 0
fi

tmux new-session -d -s "$SESSION" -c "$WORKDIR" \
  "while true; do '$CLAUDE' rc; echo '[claude rc exited, restarting in 5s]'; sleep 5; done"
