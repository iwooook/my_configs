#!/bin/bash
# Set up always-on remote access on this machine, in two attachable tmux
# sessions on the default socket, both auto-started at boot by systemd --user:
#
#   claude-rc      `claude rc`    -> control local sessions from claude.ai/code
#   vscode-tunnel  `code tunnel`  -> reach this box at vscode.dev/tunnel/<host>
#
# Usage:  ./setup-remote-access.sh [--check] [--no-tunnel] [--no-claude-rc]
#                                 [--no-download] [--name NAME] [--workdir DIR]
#
#   --check         report what would happen and what is missing; change nothing
#   --no-download   do not fetch the VS Code CLI when it is absent
#   --name NAME     tunnel machine name (default: this host's short name)
#   --workdir DIR   directory new claude rc sessions start in (default: ~/TAPER
#                   if it exists, else $HOME)
#
# Settings can equivalently come from the environment, which is usually the
# terser way to say it:
#
#   CLAUDE_RC_WORKDIR=~/TAPER TUNNEL_NAME=box1 ./setup-remote-access.sh
#
# Anything given that way is STORED in the env file, because a systemd user unit
# does not inherit your shell environment -- at boot the launcher would never see
# it otherwise. Precedence: command line > environment > stored file > default.
#
# Safe to re-run: every step is idempotent, and it never restarts anything that
# would drop a live tmux session.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$REPO_DIR/remote-access-common.sh"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SCRIPTS=(tmux-server-up.sh start-claude-rc.sh start-vscode-tunnel.sh)
UNITS=(tmux-server.service claude-rc.service vscode-tunnel.service)

# Grab anything the environment supplied BEFORE ra_load_env sources the stored
# file, which would otherwise clobber it. Empty means "not specified".
ENV_TUNNEL_NAME="${TUNNEL_NAME:-}"
ENV_RC_WORKDIR="${CLAUDE_RC_WORKDIR:-}"
ENV_CLAUDE_BIN="${CLAUDE_BIN:-}"
ENV_CODE_BIN="${CODE_BIN:-}"

CHECK_ONLY=0 WANT_TUNNEL=1 WANT_RC=1 ALLOW_DOWNLOAD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--dry-run) CHECK_ONLY=1 ;;
    --no-tunnel)       WANT_TUNNEL=0 ;;
    --no-claude-rc)    WANT_RC=0 ;;
    --no-download)     ALLOW_DOWNLOAD=0 ;;
    --name)            ENV_TUNNEL_NAME="${2:-}"; shift ;;
    --workdir)         ENV_RC_WORKDIR="${2:-}"; shift ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# `VAR=~/x cmd` expands the tilde, but `VAR="~/x"` does not; fix the quoted case
# rather than storing a path that silently falls back to $HOME at boot.
case "$ENV_RC_WORKDIR" in "~/"*) ENV_RC_WORKDIR="$HOME/${ENV_RC_WORKDIR#\~/}" ;; esac

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mmiss\033[0m  %s\n' "$*"; }
act()  { printf '  \033[36m->\033[0m    %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

ra_load_env
# Re-apply on top of the stored file so the caller's wishes win for this run.
[ -n "$ENV_TUNNEL_NAME" ] && TUNNEL_NAME="$ENV_TUNNEL_NAME"
[ -n "$ENV_RC_WORKDIR" ]  && CLAUDE_RC_WORKDIR="$ENV_RC_WORKDIR"
[ -n "$ENV_CLAUDE_BIN" ]  && CLAUDE_BIN="$ENV_CLAUDE_BIN"
[ -n "$ENV_CODE_BIN" ]    && CODE_BIN="$ENV_CODE_BIN"

# Upsert one KEY=value into the stored env file. Paths never contain '|', which
# is why it is safe as the sed delimiter here.
ra_env_set() {
  local key="$1" val="$2"
  [ -n "$val" ] || return 0
  mkdir -p "$RA_ENV_DIR"; touch "$RA_ENV_FILE"
  if grep -q "^${key}=" "$RA_ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$RA_ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$RA_ENV_FILE"
  fi
}

# ---------------------------------------------------------------- preflight ---
head_ "preflight  (host $(hostname -s), user $USER)"
FATAL=0

if command -v tmux >/dev/null 2>&1; then ok "tmux            $(command -v tmux)"
else bad "tmux is not installed  (apt install tmux)"; FATAL=1; fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  ok "systemd --user  available"
else
  bad "no usable systemd --user session"; FATAL=1
fi

# Linger is what makes the units start at boot with nobody logged in, and keeps
# them alive after you log out. No sudo required for your own user.
LINGER=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)
[ "$LINGER" = yes ] && ok "linger          enabled" || warn "linger          disabled -> will enable"

if CLAUDE=$(ra_find_claude); then
  ok "claude          $CLAUDE"
  [ -d "$HOME/.claude" ] || warn "  ~/.claude missing: run \`claude\` once to log in, or rc will idle"
else
  [ "$WANT_RC" = 1 ] && { bad "claude not found (https://claude.com/claude-code) -> skipping claude-rc"; WANT_RC=0; }
fi

CODE=$(ra_find_code_cli || true)
if [ -n "$CODE" ]; then
  ok "code CLI        $CODE"
elif [ "$WANT_TUNNEL" = 1 ]; then
  if [ "$ALLOW_DOWNLOAD" = 1 ]; then
    warn "code CLI        absent -> will download the standalone CLI"
  else
    bad "code CLI absent and --no-download given -> skipping vscode-tunnel"; WANT_TUNNEL=0
  fi
fi

[ "$FATAL" = 1 ] && { printf '\nblocked by the missing prerequisites above.\n'; exit 1; }

# ------------------------------------------------------- VS Code CLI fetch ---
fetch_code_cli() {
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=cli-linux-x64 ;;
    aarch64|arm64) arch=cli-linux-arm64 ;;
    *) warn "unknown arch $(uname -m); cannot pick a CLI build"; return 1 ;;
  esac
  url="https://update.code.visualstudio.com/latest/$arch/stable"
  tmp=$(mktemp -d) || return 1
  act "downloading $arch"
  if ! curl -fsSL "$url" -o "$tmp/cli.tar.gz"; then
    warn "download failed: $url"; rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/cli.tar.gz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$BIN_DIR"
  install -m 0755 "$tmp/code" "$BIN_DIR/code" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  CODE="$BIN_DIR/code"
  ok "installed       $CODE ($("$CODE" --version 2>/dev/null | head -1))"
}

if [ "$WANT_TUNNEL" = 1 ] && [ -z "$CODE" ] && [ "$CHECK_ONLY" = 0 ]; then
  head_ "vs code cli"
  fetch_code_cli || WANT_TUNNEL=0
fi

# --------------------------------------------------------------- what to do ---
head_ "plan"
act "tunnel name    $(ra_tunnel_name)"
rc_wd="${CLAUDE_RC_WORKDIR:-}"
if [ -z "$rc_wd" ]; then rc_wd="$HOME"; [ -d "$HOME/TAPER" ] && rc_wd="$HOME/TAPER"; fi
act "rc workdir     $rc_wd"
[ -d "$rc_wd" ] || warn "               ^ does not exist; the launcher will fall back to \$HOME"
act "symlink ${#SCRIPTS[@]} launchers into $BIN_DIR"
act "install ${#UNITS[@]} units into $UNIT_DIR"
[ "$WANT_RC" = 1 ]     && act "enable+start claude-rc      (session: claude-rc)"     || warn "claude-rc      skipped"
[ "$WANT_TUNNEL" = 1 ] && act "enable+start vscode-tunnel  (session: vscode-tunnel)" || warn "vscode-tunnel  skipped"

if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n--check: nothing was changed.\n'
  exit 0
fi

# ------------------------------------------------------------------ install ---
head_ "install"

# Per-host settings stay out of the repo. Only created if absent, so a host's
# local choices survive a re-run.
mkdir -p "$RA_ENV_DIR"
# Move a pre-namespacing file into place rather than leaving two sources of truth.
if [ ! -e "$RA_ENV_FILE" ] && [ -e "$RA_ENV_FILE_LEGACY" ]; then
  mv "$RA_ENV_FILE_LEGACY" "$RA_ENV_FILE"
  ok "migrated       $RA_ENV_FILE_LEGACY -> $RA_ENV_FILE"
fi
if [ ! -e "$RA_ENV_FILE" ]; then
  {
    echo "# Per-host overrides for the remote-access units (not in git)."
    echo "# Set these on the setup-remote-access.sh command line instead of"
    echo "# editing here if you prefer, e.g. CLAUDE_RC_WORKDIR=~/foo ./setup-..."
    echo "# TUNNEL_NAME       vscode.dev/tunnel/<name>; <=20 chars of [a-z0-9-]"
    echo "# CLAUDE_RC_WORKDIR directory new claude rc sessions start in"
    echo "# CLAUDE_BIN / CODE_BIN  override binary autodetection"
    echo "TUNNEL_NAME=$(ra_tunnel_name)"
    echo "CLAUDE_RC_WORKDIR=$rc_wd"
  } > "$RA_ENV_FILE"
  ok "wrote          $RA_ENV_FILE"
else
  ok "kept           $RA_ENV_FILE (existing per-host settings)"
fi

# Persist whatever was given on the command line or in the environment. This is
# the whole reason the file exists: a systemd user unit does not inherit the
# invoking shell's environment, so at boot the launcher can only read a file.
for kv in "TUNNEL_NAME:$ENV_TUNNEL_NAME" "CLAUDE_RC_WORKDIR:$ENV_RC_WORKDIR" \
          "CLAUDE_BIN:$ENV_CLAUDE_BIN" "CODE_BIN:$ENV_CODE_BIN"; do
  k=${kv%%:*}; v=${kv#*:}
  [ -n "$v" ] || continue
  [ "$k" = TUNNEL_NAME ] && v=$(ra_tunnel_name)
  old=$(sed -n "s|^${k}=||p" "$RA_ENV_FILE" | head -1)
  ra_env_set "$k" "$v"
  ok "set            $k=$v"
  # The launcher reads the file at ExecStart, so an already-running session keeps
  # the old value. Say so instead of silently restarting it -- a restart would
  # drop whatever is connected to that session.
  if [ "$old" != "$v" ]; then
    case "$k" in
      CLAUDE_RC_WORKDIR|CLAUDE_BIN) RESTART_HINT="claude-rc" ;;
      TUNNEL_NAME|CODE_BIN)         RESTART_HINT="vscode-tunnel" ;;
    esac
  fi
done

# Symlinks, not copies: `git pull` then updates the launchers with no re-run.
mkdir -p "$BIN_DIR"
for s in "${SCRIPTS[@]}"; do
  chmod +x "$REPO_DIR/$s"
  ln -sfn "$REPO_DIR/$s" "$BIN_DIR/$s"
done
ok "linked         $BIN_DIR/{$(IFS=,; echo "${SCRIPTS[*]}")}"

mkdir -p "$UNIT_DIR"
for u in "${UNITS[@]}"; do install -m 0644 "$REPO_DIR/$u" "$UNIT_DIR/$u"; done
ok "installed      units"

[ "$LINGER" = yes ] || { loginctl enable-linger "$USER" && ok "enabled        linger"; }

systemctl --user daemon-reload
# Clear a stale `failed` before enabling; `restart` would run ExecStop and drop
# a live session, `reset-failed` only forgets the recorded failure.
systemctl --user reset-failed tmux-server.service claude-rc.service vscode-tunnel.service 2>/dev/null || true

want=(tmux-server.service)
[ "$WANT_RC" = 1 ]     && want+=(claude-rc.service)
[ "$WANT_TUNNEL" = 1 ] && want+=(vscode-tunnel.service)
systemctl --user enable "${want[@]}" >/dev/null 2>&1 && ok "enabled        ${want[*]}"

# `start`, never `restart`: start on an already-active unit is a no-op, so this
# cannot disturb sessions that are already running (possibly with your work in
# them). Skip the tunnel when it is not logged in, so it does not sit in a loop
# reprinting device codes that expire.
for u in "${want[@]}"; do
  if [ "$u" = vscode-tunnel.service ] && ! ra_tunnel_logged_in "$CODE"; then
    warn "vscode-tunnel  not started: the CLI is not logged in yet"
    printf '\n         %s tunnel user login --provider github\n' "$CODE"
    printf '         systemctl --user start vscode-tunnel\n'
    continue
  fi
  systemctl --user start "$u" && ok "started        $u"
done

# ------------------------------------------------------------------- report ---
head_ "state"
for u in tmux-server claude-rc vscode-tunnel; do
  printf '  %-16s %-9s %s\n' "$u" \
    "$(systemctl --user is-enabled "$u" 2>/dev/null || echo -)" \
    "$(systemctl --user is-active "$u" 2>/dev/null || echo -)"
done
printf '\n  tmux sessions: %s\n' "$(tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || echo none)"
if [ "$WANT_TUNNEL" = 1 ] && [ -n "$CODE" ] && ra_tunnel_logged_in "$CODE"; then
  printf '  tunnel:        https://vscode.dev/tunnel/%s\n' "$(ra_tunnel_name)"
fi
if [ -n "${RESTART_HINT:-}" ]; then
  printf '\n  a setting changed; the running session still uses the old one:\n'
  printf '                 systemctl --user restart %s\n' "$RESTART_HINT"
fi
printf '\n  attach with:   tmux attach -t claude-rc   |   tmux attach -t vscode-tunnel\n\n'
