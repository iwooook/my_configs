# Claude Code Ctrl+G → 지금 보고 있는 VS Code 창에서 프롬프트 편집 (tmux 안에서도). VS Code 터미널이 아니면 vim.
# 탭을 닫을 때까지 tmux에는 그 세션을 보기 전용으로 띄워 둔다 (PgUp/PgDn으로 위 내용 보기).
# 설치: cat ~/my_configs/ctrl-g.bashrc >> ~/.bashrc  (자세한 건 ~/my_configs/README.md)
# EDITOR는 셸 밖에서 실행되므로 실행 파일이 필요하다 → 아래 내용으로 ~/.local/bin/code-wait를 만든다.
# 이 블록을 고치면 다음 셸 시작 때 파일도 갱신된다.
_cw=~/.local/bin/code-wait
_cw_src=$(cat <<'EOF'
#!/bin/bash
# (~/.bashrc가 생성하는 파일. 고치려면 ~/.bashrc의 Ctrl+G 블록을 고칠 것)

# ── VS Code 찾기: hook(소켓)과 d(remote-cli 경로)를 정한다 ──
# 소켓 파일은 VS Code 창이 닫혀도 남으므로 지금 listen 중인지까지 본다
live() { [ -S "$1" ] && { ! command -v ss >/dev/null || ss -xl | grep -qF " $1 "; }; }
# 가장 최근 활동한 tmux client(= 지금 타이핑 중인 터미널)의 env를 따른다. client가 없으면 1
from_tmux() {
  local c env
  hook= d=
  c=$(tmux list-clients -F '#{client_activity} #{client_pid}' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
  [ -n "$c" ] && [ -r "/proc/$c/environ" ] || return 1
  env=$(tr '\0' '\n' <"/proc/$c/environ")
  hook=$(grep '^VSCODE_IPC_HOOK_CLI=' <<<"$env" | cut -d= -f2-)
  d=$(grep '^PATH=' <<<"$env" | cut -d= -f2- | tr ':' '\n' | grep remote-cli | head -1)
  return 0
}
find_vscode() {
  local s pid
  hook=$VSCODE_IPC_HOOK_CLI
  d=$(tr ':' '\n' <<<"$PATH" | grep remote-cli | head -1)
  if [ -n "$TMUX" ]; then
    # 이 셸(과 tmux 서버)의 env는 낡았을 수 있으니 tmux client의 env만 따른다
    from_tmux
  elif ! live "$hook"; then
    # 백그라운드 세션(claude daemon이 띄움)은 daemon이 뜰 때의 env를 물려받아 소켓이 죽어 있기 쉽다
    # → tmux client를 따르고, tmux client가 아예 없으면 살아 있는 VS Code 창 중 가장 최근 것
    from_tmux && return
    for s in $(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/vscode-ipc-*.sock 2>/dev/null); do
      pid=$(ss -xlp 2>/dev/null | grep -F " $s " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
      [ -n "$pid" ] || continue
      hook=$s d=$(dirname "$(readlink "/proc/$pid/exe")")/bin/remote-cli
      return
    done
  fi
}

# ── 탭을 닫을 때까지 tmux 쪽 ──
# Claude는 탭이 닫힐 때까지 멈춰 있어 화면을 다시 그리지도, 키(PgUp/PgDn)를 받지도 못한다.
# 탭이 열리며 VS Code 터미널이 줄면 세션 창(claude agents에서 연 백그라운드 세션)은 attach 쪽이 화면을
# 지운 채로 남아 검게 된다 → 지금 보는 tmux 창 크기를 고정한다 (줄어든 만큼은 잘려 보임)
freeze() {
  local w h
  cl=$(tmux list-clients -F '#{client_activity} #{client_name}' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
  [ -n "$cl" ] || return 0
  read -r win w h < <(tmux display -p -c "$cl" '#{window_id} #{window_width} #{window_height}' 2>/dev/null)
  [ -n "$h" ] || { win=; return 0; }
  prev=$(tmux show -wqv -t "$win" window-size 2>/dev/null)
  tmux resize-window -t "$win" -x "$w" -y "$h" 2>/dev/null || win=
}
# 이 세션을 보기 전용 fork로 popup에 띄운다. Claude Code가 직접 그리므로 화면이 똑같고 PgUp/PgDn도 된다.
# - 부모($PPID)가 Claude 프로세스라 ~/.claude/sessions/<pid>.json에서 sessionId와 cwd를 읽는다
# - --fork-session --session-id: 원래 세션은 건드리지 않고, 정해 둔 id라 끝나고 지울 수 있다
# - ANTHROPIC_BASE_URL을 닫힌 포트로: popup에서 실수로 Enter를 쳐도 메시지가 나가지 않는다
show_view() {
  local j sid scwd cc
  [ -n "$cl" ] || return 0
  j=$(cat ~/.claude/sessions/"$PPID".json 2>/dev/null) || return 0
  sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' <<<"$j")
  scwd=$(sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' <<<"$j")
  [ -n "$sid" ] && [ -d "$scwd" ] || return 0
  cc=$(command -v claude || echo ~/.local/bin/claude)
  fork=$(cat /proc/sys/kernel/random/uuid)
  tmux display-popup -c "$cl" -B -w 100% -h 100% -d "$scwd" -E \
    "ANTHROPIC_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 '$cc' --resume '$sid' --fork-session --session-id '$fork' --strict-mcp-config" \
    </dev/null >/dev/null 2>&1 &
  viewpid=$!
}
# popup을 닫고, 창 크기를 풀고, fork가 끝나며 남기는 파일은 3초 뒤에 지운다
# (code-wait는 바로 끝나야 Claude가 이어서 돌므로 따로 떼어 둔다)
restore() {
  [ -n "$viewpid" ] && { tmux display-popup -C -c "$cl" 2>/dev/null; kill "$viewpid" 2>/dev/null; }
  if [ -n "$win" ]; then
    if [ -n "$prev" ]; then tmux set -wq -t "$win" window-size "$prev"; else tmux set -wqu -t "$win" window-size; fi
  fi
  [ -n "$fork" ] && setsid -f bash -c "sleep 3; find ~/.claude -maxdepth 3 -name '*$fork*' -prune -exec rm -rf {} +" </dev/null >/dev/null 2>&1
  win= viewpid= fork=
}

# ── 실행 ──
find_vscode
if live "$hook" && [ -x "$d/code" ]; then
  export VSCODE_IPC_HOOK_CLI=$hook
  freeze; show_view; trap restore EXIT
  start=$SECONDS
  "$d/code" --wait "$@" && exit 0
  # 소켓이 죽어서 바로 실패한 경우만 터미널 에디터로 넘어간다
  (( SECONDS - start >= 3 )) && exit 1
  restore; trap - EXIT
fi
ed=${CODE_WAIT_FALLBACK:-vim}
# Claude는 이름에 code가 들어간 에디터를 VS Code로 보고 `-g 파일:줄[:열]`로 부르므로 `+줄 파일`로 바꾼다
if [ "$1" = -g ] && { [[ $2 =~ ^(.+):([0-9]+):[0-9]+$ ]] || [[ $2 =~ ^(.+):([0-9]+)$ ]]; }; then
  exec "$ed" "+${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${@:3}"
fi
[ "$1" = -g ] && shift
exec "$ed" "$@"
EOF
)
if [ "$(cat "$_cw" 2>/dev/null)" != "$_cw_src" ]; then
  # 임시 파일 + mv: symlink를 따라가 덮어쓰지 않고, 반쯤 쓰인 파일이 실행되지 않게
  mkdir -p ~/.local/bin
  printf '%s\n' "$_cw_src" >"$_cw.$$" && chmod +x "$_cw.$$" && mv -f "$_cw.$$" "$_cw"
fi
export EDITOR=$_cw
unset _cw _cw_src
