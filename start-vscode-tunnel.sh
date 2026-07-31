#!/bin/bash
# Ensure a `code tunnel` session exists on the DEFAULT tmux socket, so it shows
# up in a plain `tmux ls` and can be attached with `tmux attach -t vscode-tunnel`.
# The tunnel makes this machine reachable at https://vscode.dev/tunnel/<name>
# from anywhere, with no inbound port or VPN.
#
# Crash/network recovery is handled INSIDE tmux by a while-loop that re-runs the
# tunnel, so systemd only has to make sure the session exists (at boot). That
# loop is also what makes a boot-time race harmless: if the network is not up
# yet the tunnel exits and is simply retried.
#
# Auth lives in ~/.vscode/cli/token.json — HOME-relative, no env var — so this
# works unchanged under systemd, which does not inherit the login shell's env.
set -u

SESSION=vscode-tunnel
. "$(dirname "$(readlink -f "$0")")/remote-access-common.sh"
ra_load_env

if ! CODE=$(ra_find_code_cli); then
  echo "start-vscode-tunnel: no standalone VS Code CLI found; set CODE_BIN in $RA_ENV_FILE" >&2
  echo "  (run setup-remote-access.sh to download one)" >&2
  exit 1
fi
NAME=$(ra_tunnel_name)

# Idempotent: if the session is already there, do nothing. This matters more
# than for claude rc — only ONE tunnel may run per machine, so a second one
# would just exit on the lock and spin in the retry loop.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exit 0
fi

tmux new-session -d -s "$SESSION" -c "$HOME" \
  "while true; do '$CODE' tunnel --accept-server-license-terms --name '$NAME'; echo '[code tunnel exited, restarting in 10s]'; sleep 10; done"
