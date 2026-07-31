#!/bin/bash
# Bring up the shared tmux server on the DEFAULT socket, with an anchor session
# named "main".
#
# Owning the server from its own systemd unit is what keeps the per-app units
# (claude-rc, vscode-tunnel) stateless: tmux forks every window's processes from
# the *server*, so all of that lands in THIS unit's cgroup. The app units only
# run a short-lived tmux client, so restarting one can never disturb the other,
# and a workload OOM inside any session cannot flip an app unit to "failed".
# (That is not hypothetical -- it is what happened to claude-rc.service on
# ttdev31 on 2026-07-29, back when claude-rc owned the server: a 52 GB job in an
# unrelated session got OOM-killed and took the unit's state down with it.)
#
# The "main" session is also the anchor that keeps the server alive if every
# other session is killed, and gives you a plain shell to attach to.
set -u

# Idempotent, and deliberately adopts an already-running server rather than
# restarting it: this unit may be (re)started while live sessions -- including
# the one you are attached to -- are in flight.
if tmux ls >/dev/null 2>&1; then
  exit 0
fi

exec tmux new-session -d -s main -c "$HOME"
