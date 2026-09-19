#!/bin/sh
# Provider-free lifecycle test. Every tmux call is fenced to one owned socket.
set -eu
umask 077

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
nvim_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
real_tmux=$(command -v tmux)
real_nvim=$(command -v nvim)
real_python=$(command -v python3)
fixture=native_lifecycle.py
[ "$#" -le 1 ] || { printf '%s\n' 'expected at most one native UI case' >&2; exit 2; }
case "${1-}" in
  '') set -- ;;
  prompt|prompt-chunked|prompt-drop|prompt-redirect|prompt-timeout|prompt-oversized|prompt-boundary|prompt-review-opencode|notice-layouts|review|review-reentry|review-conflict|close|crash|crash-opencode|resize-codex|resize-opencode|graphics-opencode|termcap-opencode|size-guard-opencode|version-upgrade-opencode) fixture=native_ui.py ;;
  *) printf '%s\n' 'usage: nvim-ai-native.sh [prompt[-chunked|-drop|-redirect|-timeout|-oversized|-boundary|-review-opencode]|notice-layouts|review[-reentry|-conflict]|close|crash[-opencode]|resize-codex|resize-opencode|graphics-opencode|termcap-opencode|size-guard-opencode|version-upgrade-opencode]' >&2; exit 2 ;;
esac
test_parent=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_root=$(mktemp -d "$test_parent/draft-native.XXXXXX")
chmod 700 "$test_root"
socket=$test_root/tmux.sock
tmux_started=false

stop_server() {
  if [ "$tmux_started" = true ] && [ -S "$socket" ]; then
    "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || true
  fi
  tmux_started=false
}

processes_absent() {
  LC_ALL=C ps -A -o args= > "$test_root/processes.txt" 2>&1 || return 1
  awk -v root="$test_root" 'index($0, root) { found=1 } END { exit found ? 1 : 0 }' \
    "$test_root/processes.txt"
}

cleanup() {
  stop_server
  cleanup_attempt=0
  while ! processes_absent; do
    cleanup_attempt=$((cleanup_attempt + 1))
    if [ "$cleanup_attempt" -ge 50 ]; then
      printf 'AI test processes remain; preserved private root: %s\n' "$test_root" >&2
      return 1
    fi
    sleep 0.1
  done
  case "$test_root" in
    "$test_parent"/draft-native.??????) rm -rf -- "$test_root" ;;
    *) printf 'refusing unsafe AI test cleanup: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -m 700 "$test_root/bin" "$test_root/home" "$test_root/state" \
  "$test_root/runtime" "$test_root/root" "$test_root/outside"
# No inherited configuration, default socket, or live-server reload.
env -i HOME="$test_root/home" PATH="$test_root/bin:$PATH" SHELL=/bin/sh \
  TERM="${TERM:-xterm-256color}" \
  "$real_tmux" -S "$socket" -f /dev/null new-session -d -s nvim-ai \
  -x 200 -y 60 -c "$test_root/root" 'exec sleep 300'
tmux_started=true
env -i HOME="$test_root/home" PATH="$PATH" SHELL=/bin/sh \
  TERM="${TERM:-xterm-256color}" NVIM_LOG_FILE=/dev/null PYTHONDONTWRITEBYTECODE=1 \
  "$real_python" -I -B "$nvim_root/tests/fixtures/ai/$fixture" \
  "$test_root" "$socket" "$real_tmux" "$real_nvim" "$real_python" "$nvim_root" ${1+"$1"}
cleanup
trap - EXIT HUP INT TERM
printf '%s\n' 'ok - nvim AI private tmux lifecycle'
