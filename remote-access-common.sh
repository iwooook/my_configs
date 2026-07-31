#!/bin/bash
# Shared helpers for the always-on remote-access setup (claude rc + code tunnel).
# Sourced by setup-remote-access.sh and by the start-*.sh launchers, so that
# "where is the binary" / "what is this host called" is answered in exactly one
# place. Not executable on its own.

# Per-host overrides live outside the repo, so the same checkout works verbatim
# on every machine. Written by setup-remote-access.sh.
RA_ENV_FILE="$HOME/.config/remote-access.env"

ra_load_env() {
  # shellcheck disable=SC1090
  [ -r "$RA_ENV_FILE" ] && . "$RA_ENV_FILE"
  return 0
}

# Tunnel machine name = the vscode.dev/tunnel/<name> URL you open from outside.
# The service requires <=20 chars of [a-z0-9-], so sanitise the hostname.
ra_tunnel_name() {
  local n="${TUNNEL_NAME:-$(hostname -s 2>/dev/null || hostname)}"
  n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  n=$(printf '%.20s' "$n")
  # Trim leading/trailing hyphens *after* truncating, or a name cut at exactly
  # 20 chars could end in '-', which the service rejects.
  printf '%s' "$n" | sed 's/^-*//; s/-*$//'
}

# A standalone VS Code CLI, or empty. Two traps this has to avoid:
#  1. On a Remote-SSH host, ~/.vscode-server/.../remote-cli/code is a `sh` script
#     that forwards to the running VS Code server. It ACCEPTS `tunnel` and even
#     exits 0 on `tunnel status` -- while printing nothing and doing nothing. So
#     `tunnel --help` is NOT a usable probe; reject shebang files up front.
#  2. The real CLI is an ELF binary and always prints JSON for `tunnel status`
#     (`{"tunnel":null,...}` when no tunnel has ever run), which is the probe.
ra_is_real_code_cli() {
  local c="$1"
  [ -n "$c" ] && [ -x "$c" ] && [ -f "$c" ] || return 1
  [ "$(head -c 2 "$c" 2>/dev/null)" = '#!' ] && return 1
  "$c" tunnel status 2>/dev/null | grep -q '"tunnel"'
}

ra_find_code_cli() {
  local c
  for c in "${CODE_BIN:-}" "$HOME/.local/bin/code" "$HOME/code" "$(command -v code 2>/dev/null)"; do
    if ra_is_real_code_cli "$c"; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

ra_find_claude() {
  local c
  # $HOME/.local/bin first: a systemd user unit's PATH often lacks it, so
  # `command -v` is the fallback rather than the primary lookup.
  for c in "${CLAUDE_BIN:-}" "$HOME/.local/bin/claude" "$(command -v claude 2>/dev/null)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# Is the VS Code CLI logged in to the tunnel service? Prints "not logged in"
# when it is not, which is the whole probe.
ra_tunnel_logged_in() {
  local c="$1"
  [ -n "$c" ] || return 1
  ! "$c" tunnel user show 2>&1 | grep -qi 'not logged in'
}
