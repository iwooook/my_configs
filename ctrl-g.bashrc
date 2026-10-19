# Claude Code Ctrl+G → 지금 보고 있는 VS Code 창 (tmux 안에서도). VS Code 터미널이 아니면 vim.
# 설치: cat ~/my_configs/ctrl-g.bashrc >> ~/.bashrc  (자세한 건 ~/my_configs/README.md)
# EDITOR는 셸 밖에서 실행되므로 실행 파일이 필요하다 → 아래 내용으로 ~/.local/bin/code-wait를 만든다.
# 이 블록을 고치면 다음 셸 시작 때 파일도 갱신된다.
_cw=~/.local/bin/code-wait
_cw_src=$(cat <<'EOF'
#!/bin/bash
# (~/.bashrc가 생성하는 파일. 고치려면 ~/.bashrc의 Ctrl+G 블록을 고칠 것)
hook=$VSCODE_IPC_HOOK_CLI
d=$(tr ':' '\n' <<<"$PATH" | grep remote-cli | head -1)
if [ -n "$TMUX" ]; then
  # 이 셸(과 tmux 서버)의 env는 낡았을 수 있으니 가장 최근 활동한 클라이언트의 env만 따른다
  hook= d=
  c=$(tmux list-clients -F '#{client_activity} #{client_pid}' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
  if [ -n "$c" ] && [ -r "/proc/$c/environ" ]; then
    env=$(tr '\0' '\n' <"/proc/$c/environ")
    hook=$(grep '^VSCODE_IPC_HOOK_CLI=' <<<"$env" | cut -d= -f2-)
    d=$(grep '^PATH=' <<<"$env" | cut -d= -f2- | tr ':' '\n' | grep remote-cli | head -1)
  fi
fi
if [ -S "$hook" ] && [ -x "$d/code" ]; then
  export VSCODE_IPC_HOOK_CLI=$hook
  start=$SECONDS
  "$d/code" --wait "$@" && exit 0
  # 소켓이 죽어서 바로 실패한 경우만 터미널 에디터로 넘어간다
  (( SECONDS - start >= 3 )) && exit 1
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
