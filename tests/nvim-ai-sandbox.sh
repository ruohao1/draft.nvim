#!/bin/sh

set -eu

if [ "${1:-}" = "--pure" ]; then
  shift
  fake_mode=${1:-}
  shift
  case "$fake_mode" in
    serve)
      [ "$#" -eq 4 ] || exit 47
      [ "${1:-}" = "--hostname" ] || exit 41
      [ "${2:-}" = "127.0.0.1" ] || exit 42
      [ "${3:-}" = "--port" ] || exit 43
      fake_port=${4:-}
      shift 4
      ;;
    attach)
      [ "$#" -eq 5 ] || exit 47
      fake_url=${1:-}
      case "$fake_url" in
        http://127.0.0.1:*) ;;
        *) exit 44 ;;
      esac
      fake_port=${fake_url##*:}
      shift
      [ "${1:-}" = "--dir" ] || exit 45
      fake_project_root=${2:-}
      shift 2
      [ "${1:-}" = "--session" ] || exit 46
      [ "${2:-}" = "ses_fixture" ] || exit 46
      shift 2
      ;;
    *) exit 48 ;;
  esac
  [ "$#" -eq 0 ] || exit 47

  project_root=$(pwd -P)
  harness_root=${project_root%/*}
  [ "$project_root" = "$harness_root/project" ] || exit 70
  if [ "$fake_mode" = attach ]; then
    [ "$fake_project_root" = "$project_root" ] || exit 71
  fi
  sibling_root=$harness_root/sibling
  git_root=$harness_root/git
  backend_state=$harness_root/state/backends/opencode
  tmux_socket=$harness_root/runtime/tmux.sock
  grant_root=$harness_root/grant
  profiles_root=$backend_state/profiles
  profile_root=$profiles_root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  profile_manifest=$profile_root/manifest.json
  backends_parent=$harness_root/state/backends
  expected_home_mask=$harness_root/home/.opencode
  profiles_preserved=$profiles_root/harness-preserved
  profiles_empty=$profiles_root/harness-preserved-empty
  staging_preserved=$backends_parent/.opencode-profile-preserved.tmp
  staging_empty=$backends_parent/.opencode-profile-preserved-empty.tmp

  trusted_python=$(realpath "$(command -v python3)")
  trusted_bwrap=$(realpath "$(command -v bwrap)")
  trusted_git=$(realpath "$(command -v git)")
  trusted_tmux=$(realpath "$(command -v tmux)")
  trusted_shell=$(realpath /bin/sh)
  trusted_true=$(realpath /bin/true)
  trusted_fake=$(realpath "$0")
  trusted_tests=${trusted_fake%/*}
  trusted_nvim=${trusted_tests%/*}
  trusted_launcher=$trusted_nvim/scripts/nvim-ai-launch.py
  trusted_profile_helper=$trusted_nvim/scripts/nvim-ai-opencode-profile.py
  set -- "$trusted_python" "$trusted_bwrap" "$trusted_launcher" \
    "$trusted_true" "$trusted_true" "$trusted_true" \
    "$trusted_profile_helper" "$trusted_shell" "$trusted_git" \
    "$trusted_tmux" "$trusted_fake"

  expected_fingerprint=$("$trusted_python" -I -B -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["fingerprint"])' "$profile_manifest") || exit 49
  [ "${#expected_fingerprint}" -eq 64 ] || exit 49
  grep -F "\"fingerprint\":\"$expected_fingerprint\"" "$profile_manifest" >/dev/null || exit 49
  [ "$HOME/.opencode" = "$expected_home_mask" ] || exit 50
  [ ! -e "$HOME/.opencode/host-preserved" ] || exit 51
  "$trusted_python" -I -B -c 'import os,pathlib,stat,sys; path=pathlib.Path(sys.argv[1]); expected=b"node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"; metadata=(path/".gitignore").lstat(); valid=sorted(item.name for item in path.iterdir())==[".gitignore"] and stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode) and metadata.st_uid==os.getuid() and stat.S_IMODE(metadata.st_mode)==0o600 and (path/".gitignore").read_bytes()==expected; raise SystemExit(0 if valid else 1)' "$HOME/.opencode" || exit 72

  if printf '%s' inside >"$project_root/inside.txt" 2>/dev/null; then :; fi
  if printf '%s' sibling >"$sibling_root/outside.txt" 2>/dev/null; then exit 21; fi
  if printf '%s' git >"$git_root/config" 2>/dev/null; then exit 22; fi
  if printf '%s' escape >"$project_root/escape/outside.txt" 2>/dev/null; then exit 23; fi
  printf '%s' cache >"$backend_state/cache-$fake_mode.txt"
  [ ! -S "$tmux_socket" ] || exit 24
  if printf '%s' grant >"$grant_root/granted.txt" 2>/dev/null; then :; fi

  if printf '%s' hostile >"$profile_root/xdg-config/opencode/opencode.json" 2>/dev/null; then exit 52; fi
  if printf '%s' hostile >"$profile_root/xdg-config/opencode/.gitignore" 2>/dev/null; then exit 53; fi
  if printf '%s' hostile >"$profile_root/xdg-config/opencode/AGENTS.md" 2>/dev/null; then exit 54; fi
  if printf '%s' hostile >"$profile_root/credentials/auth.json" 2>/dev/null; then exit 55; fi
  if printf '%s' hostile >"$profile_manifest" 2>/dev/null; then exit 56; fi
  if printf '%s' hostile >"$HOME/.opencode/hostile" 2>/dev/null; then exit 57; fi
  if printf '%s' hostile >"$HOME/.opencode/.gitignore" 2>/dev/null; then exit 73; fi
  if rm "$HOME/.opencode/.gitignore" 2>/dev/null; then exit 74; fi
  printf '%s' hostile >"$backend_state/home-bootstrap-replacement"
  if mv "$backend_state/home-bootstrap-replacement" "$HOME/.opencode/.gitignore" 2>/dev/null; then exit 75; fi
  rm "$backend_state/home-bootstrap-replacement"
  if mkdir "$profiles_root/hostile" 2>/dev/null; then exit 58; fi
  if mv "$profile_root" "$profiles_root/moved" 2>/dev/null; then exit 59; fi
  if rm "$profile_manifest" 2>/dev/null; then exit 60; fi
  if mkdir "$backends_parent/.opencode-profile-hostile.tmp" 2>/dev/null; then exit 61; fi
  if mv "$profiles_preserved" "$profiles_root/harness-preserved-moved" 2>/dev/null; then exit 64; fi
  if rm "$profiles_preserved/marker" 2>/dev/null; then exit 65; fi
  if rmdir "$profiles_empty" 2>/dev/null; then exit 66; fi
  if mv "$staging_preserved" "$backends_parent/.opencode-profile-preserved-moved.tmp" 2>/dev/null; then exit 67; fi
  if rm "$staging_preserved/marker" 2>/dev/null; then exit 68; fi
  if rmdir "$staging_empty" 2>/dev/null; then exit 69; fi
  for trusted_path in "$@"; do
    if printf '%s' hostile >"$trusted_path" 2>/dev/null; then exit 62; fi
  done

  umask 077
  printf '%s' "$expected_fingerprint" >"$backend_state/fingerprint-$fake_mode"
  printf '%s' complete >"$backend_state/complete-$fake_mode"
  chmod 600 "$backend_state/fingerprint-$fake_mode" "$backend_state/complete-$fake_mode"
  if [ "$fake_mode" = serve ]; then
    exec python3 -I -B -c 'import signal,socket,sys; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); server=socket.socket(); server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); server.bind(("127.0.0.1",int(sys.argv[1]))); server.listen(); signal.pause()' "$fake_port"
  fi
  exit 0
fi

fail() {
  printf '%s\n' "not ok - $1" >&2
  exit 1
}

umask 077
HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nvim-ai-sandbox.XXXXXX")
chmod 700 "$HARNESS_ROOT"
HARNESS_LAUNCH_PID=
HARNESS_SOCKET_PID=
stop_owned_process() {
  owned_pid=$1
  [ -n "$owned_pid" ] || return 0
  kill -TERM "$owned_pid" 2>/dev/null || true
  stop_attempt=0
  while kill -0 "$owned_pid" 2>/dev/null && [ "$stop_attempt" -lt 40 ]; do
    sleep 0.05
    stop_attempt=$((stop_attempt + 1))
  done
  if kill -0 "$owned_pid" 2>/dev/null; then
    kill -KILL "$owned_pid" 2>/dev/null || true
  fi
  wait "$owned_pid" 2>/dev/null || true
}
cleanup() {
  if [ -n "$HARNESS_LAUNCH_PID" ]; then
    stop_owned_process "$HARNESS_LAUNCH_PID"
  fi
  if [ -n "$HARNESS_SOCKET_PID" ]; then
    stop_owned_process "$HARNESS_SOCKET_PID"
  fi
  rm -rf "$HARNESS_ROOT"
}
trap cleanup EXIT HUP INT TERM

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
NVIM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
LAUNCHER=$NVIM_ROOT/scripts/nvim-ai-launch.py
PROFILE_HELPER=$NVIM_ROOT/scripts/nvim-ai-opencode-profile.py
PYTHON=$(command -v python3) || fail "python3 is unavailable"
PYTHON=$(realpath "$PYTHON")
BWRAP=$(command -v bwrap) || fail "Bubblewrap is unavailable"
BWRAP=$(realpath "$BWRAP")
GIT=$(command -v git) || fail "Git is unavailable"
GIT=$(realpath "$GIT")
TMUX=$(command -v tmux) || fail "tmux is unavailable"
TMUX=$(realpath "$TMUX")
SHELL_PATH=$(realpath /bin/sh)
TRUE_PATH=$(realpath /bin/true)
FAKE_BACKEND=$(realpath "$0")

HARNESS_HOME=$HARNESS_ROOT/home
HARNESS_PROJECT=$HARNESS_ROOT/project
HARNESS_SIBLING=$HARNESS_ROOT/sibling
HARNESS_GRANT=$HARNESS_ROOT/grant
HARNESS_ESCAPE=$HARNESS_ROOT/escape-target
HARNESS_GIT=$HARNESS_ROOT/git
HARNESS_GIT_DIR=$HARNESS_GIT/worktrees/repo
HARNESS_RUNTIME=$HARNESS_ROOT/runtime
HARNESS_CONTEXT=$HARNESS_RUNTIME/context
HARNESS_STATE=$HARNESS_ROOT/state
HARNESS_BACKENDS=$HARNESS_STATE/backends
HARNESS_BACKEND=$HARNESS_BACKENDS/opencode
HARNESS_GLOBAL_DATA=$HARNESS_ROOT/global-opencode
HARNESS_PROFILE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HARNESS_PROFILE=$HARNESS_BACKEND/profiles/$HARNESS_PROFILE_TOKEN
HARNESS_PROFILE_MANIFEST=$HARNESS_PROFILE/manifest.json
HARNESS_PROFILES_PRESERVED=$HARNESS_BACKEND/profiles/harness-preserved
HARNESS_PROFILES_EMPTY=$HARNESS_BACKEND/profiles/harness-preserved-empty
HARNESS_STAGING_PRESERVED=$HARNESS_BACKENDS/.opencode-profile-preserved.tmp
HARNESS_STAGING_EMPTY=$HARNESS_BACKENDS/.opencode-profile-preserved-empty.tmp
HARNESS_CONTROL_SOCKET=$HARNESS_RUNTIME/control.sock
HARNESS_TMUX_SOCKET=$HARNESS_RUNTIME/tmux.sock
HARNESS_EVENT_FILE=$HARNESS_BACKEND/events.ndjson
HARNESS_IDENTITY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HARNESS_CONTROL_TOKEN=dddddddddddddddddddddddddddddddd

mkdir -m 700 "$HARNESS_HOME" "$HARNESS_PROJECT" "$HARNESS_SIBLING" \
  "$HARNESS_GRANT" "$HARNESS_ESCAPE" "$HARNESS_GIT" "$HARNESS_RUNTIME" \
  "$HARNESS_STATE" "$HARNESS_GLOBAL_DATA"
mkdir -m 700 "$HARNESS_GIT/worktrees" "$HARNESS_GIT_DIR" "$HARNESS_CONTEXT" \
  "$HARNESS_BACKENDS" "$HARNESS_BACKEND" "$HARNESS_HOME/.opencode"
ln -s "$HARNESS_ESCAPE" "$HARNESS_PROJECT/escape"
printf '%s\n' original >"$HARNESS_GIT/config"
printf '%s\n' host-preserved >"$HARNESS_HOME/.opencode/host-preserved"
printf '%s\n' 'repository instruction' >"$HARNESS_PROJECT/AGENTS.md"
printf '%s\n' '{"provider":{"type":"api","key":"credential-canary"}}' >"$HARNESS_GLOBAL_DATA/auth.json"
printf 'gitdir: %s\n' "$HARNESS_GIT_DIR" >"$HARNESS_PROJECT/.git"
printf '' >"$HARNESS_EVENT_FILE"
chmod 600 "$HARNESS_GIT/config" "$HARNESS_HOME/.opencode/host-preserved" \
  "$HARNESS_PROJECT/AGENTS.md" "$HARNESS_GLOBAL_DATA/auth.json" \
  "$HARNESS_PROJECT/.git" "$HARNESS_EVENT_FILE"

"$PYTHON" -I -B -c 'import signal,socket,sys,time; sockets=[]; [sockets.append(socket.socket(socket.AF_UNIX)) or sockets[-1].bind(path) or sockets[-1].listen() for path in sys.argv[1:]]; signal.signal(signal.SIGTERM,lambda *_:sys.exit(0)); time.sleep(60)' "$HARNESS_CONTROL_SOCKET" "$HARNESS_TMUX_SOCKET" &
HARNESS_SOCKET_PID=$!
socket_ready=0
for _attempt in $(seq 1 100); do
  if [ -S "$HARNESS_CONTROL_SOCKET" ] && [ -S "$HARNESS_TMUX_SOCKET" ]; then
    socket_ready=1
    break
  fi
  sleep 0.05
done
[ "$socket_ready" -eq 1 ] || fail "private control and tmux sockets did not start"
chmod 770 "$HARNESS_TMUX_SOCKET"
HARNESS_HOME_METADATA=$(stat -c '%d:%i:%a:%u' "$HARNESS_HOME")
HARNESS_HOME_OPENCODE_METADATA=$(stat -c '%d:%i:%a:%u' "$HARNESS_HOME/.opencode")

export HARNESS_BACKEND HARNESS_GLOBAL_DATA HARNESS_HOME HARNESS_IDENTITY
export HARNESS_PROFILE_TOKEN HARNESS_PROJECT
PROFILE_REQUEST=$HARNESS_ROOT/profile-request.json
PROFILE_REPORT=$HARNESS_ROOT/profile-report.json
# shellcheck disable=SC2016
"$PYTHON" -I -B -c 'import json,os; print(json.dumps({"schema":1,"token":os.environ["HARNESS_PROFILE_TOKEN"],"identity_key":os.environ["HARNESS_IDENTITY"],"root":os.environ["HARNESS_PROJECT"],"backend_state":os.environ["HARNESS_BACKEND"],"global_auth":os.environ["HARNESS_GLOBAL_DATA"]+"/auth.json","user_agents":os.environ["HARNESS_HOME"]+"/missing-AGENTS.md","repo_agents":os.environ["HARNESS_PROJECT"]+"/AGENTS.md","version":"1.18.30","config_json":"{\"$schema\":\"https://opencode.ai/config.json\",\"autoupdate\":false,\"permission\":{\"bash\":\"ask\",\"doom_loop\":\"ask\",\"external_directory\":\"ask\",\"skill\":\"deny\",\"task\":\"deny\",\"webfetch\":\"ask\",\"websearch\":\"ask\"},\"agent\":{\"general\":{\"disable\":true},\"explore\":{\"disable\":true},\"compaction\":{\"permission\":{\"*\":\"deny\"}},\"summary\":{\"permission\":{\"*\":\"deny\"}},\"title\":{\"permission\":{\"*\":\"deny\"}}}}","policy_json":"{\"bash\":\"ask\",\"doom_loop\":\"ask\",\"external_directory\":\"ask\",\"skill\":\"deny\",\"task\":\"deny\",\"webfetch\":\"ask\",\"websearch\":\"ask\"}"},separators=(",",":")))' >"$PROFILE_REQUEST"
chmod 600 "$PROFILE_REQUEST"
"$PYTHON" -I -B "$PROFILE_HELPER" --operation prepare <"$PROFILE_REQUEST" >"$PROFILE_REPORT"
chmod 600 "$PROFILE_REPORT"
HARNESS_FINGERPRINT=$("$PYTHON" -I -B -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["fingerprint"])' "$PROFILE_REPORT")
[ "${#HARNESS_FINGERPRINT}" -eq 64 ] || fail "managed profile fingerprint is invalid"
mkdir -m 700 "$HARNESS_PROFILES_PRESERVED" "$HARNESS_PROFILES_EMPTY" \
  "$HARNESS_STAGING_PRESERVED" "$HARNESS_STAGING_EMPTY"
printf '%s\n' profiles-preserved >"$HARNESS_PROFILES_PRESERVED/marker"
printf '%s\n' staging-preserved >"$HARNESS_STAGING_PRESERVED/marker"
chmod 600 "$HARNESS_PROFILES_PRESERVED/marker" \
  "$HARNESS_STAGING_PRESERVED/marker"

export BWRAP FAKE_BACKEND GIT HARNESS_BACKENDS HARNESS_CONTEXT HARNESS_CONTROL_TOKEN
export HARNESS_EVENT_FILE HARNESS_FINGERPRINT HARNESS_GIT HARNESS_GIT_DIR
export HARNESS_GRANT HARNESS_PROFILE HARNESS_PROFILE_MANIFEST HARNESS_RUNTIME
export HARNESS_CONTROL_SOCKET
export HARNESS_SIBLING HARNESS_STATE HARNESS_TMUX_SOCKET LAUNCHER PROFILE_HELPER
export PYTHON SHELL_PATH TMUX TRUE_PATH

write_manifest() {
  manifest_path=$1
  launch_token=$2
  root_policy=$3
  grant_policy=$4
  port=$5
  export manifest_path launch_token root_policy grant_policy port
  "$PYTHON" -I -B -c 'import json,os; e=os.environ; p=e["HARNESS_PROFILE"]; b=e["HARNESS_BACKEND"]; profile={"schema":1,"version":"1.18.30","profile_root":p,"fingerprint":e["HARNESS_FINGERPRINT"],"config_source":p+"/xdg-config","auth_source":p+"/credentials/auth.json","home_mask_source":p+"/empty-home-opencode"}; env={"OPENCODE_DISABLE_AUTOUPDATE":"true","OPENCODE_DISABLE_CLAUDE_CODE":"true","OPENCODE_DISABLE_EXTERNAL_SKILLS":"true","OPENCODE_DISABLE_LSP_DOWNLOAD":"true","OPENCODE_DISABLE_PROJECT_CONFIG":"true","OPENCODE_PERMISSION":"{\"bash\":\"ask\",\"doom_loop\":\"ask\",\"external_directory\":\"ask\",\"skill\":\"deny\",\"task\":\"deny\",\"webfetch\":\"ask\",\"websearch\":\"ask\"}","OPENCODE_PURE":"true","OPENCODE_SERVER_PASSWORD":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","OPENCODE_SERVER_USERNAME":"opencode","XDG_CACHE_HOME":b+"/xdg-cache","XDG_CONFIG_HOME":b+"/xdg-config","XDG_DATA_HOME":b+"/xdg-data","XDG_STATE_HOME":b+"/xdg-state"}; prefix=[e["FAKE_BACKEND"],"--pure"]; launch={"kind":"server_attach","backend":"opencode","argv":None,"server_argv":[*prefix,"serve","--hostname","127.0.0.1","--port",e["port"]],"attach_argv":[*prefix,"attach","http://127.0.0.1:"+e["port"],"--dir",e["HARNESS_PROJECT"],"--session","ses_fixture"],"env":env,"session":"ses_fixture","capabilities":{"approval":True,"busy":True,"completion":True,"exact_session":True},"read_only_inputs":[],"protected_paths":sorted([e["FAKE_BACKEND"],p]),"event_url":"http://127.0.0.1:"+e["port"]+"/event","event_file":e["HARNESS_EVENT_FILE"],"managed_profile":profile}; writable=e["root_policy"]=="allow"; grants=[e["HARNESS_GRANT"]] if e["grant_policy"]=="allow" else []; manifest={"schema":1,"token":e["launch_token"],"identity_key":e["HARNESS_IDENTITY"],"root":e["HARNESS_PROJECT"],"git_dir":e["HARNESS_GIT_DIR"],"git_common_dir":e["HARNESS_GIT"],"git_entry":e["HARNESS_PROJECT"]+"/.git","writable":writable,"grants":grants,"review_id":"review_0123456789abcdef" if writable else None,"runtime_root":e["HARNESS_RUNTIME"],"state_root":e["HARNESS_STATE"],"context_dir":e["HARNESS_CONTEXT"],"backend_state_dir":b,"control_socket":e["HARNESS_CONTROL_SOCKET"],"control_token":e["HARNESS_CONTROL_TOKEN"],"control_helper":e["TRUE_PATH"],"event_helper":e["TRUE_PATH"],"profile_helper":e["PROFILE_HELPER"],"launcher":e["LAUNCHER"],"review_helper":e["TRUE_PATH"],"event_file":e["HARNESS_EVENT_FILE"],"tmux_socket":e["HARNESS_TMUX_SOCKET"],"python":e["PYTHON"],"bwrap":e["BWRAP"],"host_tools":sorted([e["GIT"],e["TMUX"]]),"shell":e["SHELL_PATH"],"launch":launch}; open(e["manifest_path"],"w",encoding="utf-8").write(json.dumps(manifest,separators=(",",":"))+"\n")'
  chmod 600 "$manifest_path"
}

run_case() {
  case_name=$1
  launch_token=$2
  root_policy=$3
  grant_policy=$4
  port=$("$PYTHON" -I -B -c 'import socket; value=socket.socket(); value.bind(("127.0.0.1",0)); print(value.getsockname()[1]); value.close()')
  manifest=$HARNESS_RUNTIME/$launch_token.json
  run_log=$HARNESS_ROOT/$case_name.log
  rm -f "$HARNESS_BACKEND/complete-serve" "$HARNESS_BACKEND/complete-attach" \
    "$HARNESS_BACKEND/fingerprint-serve" "$HARNESS_BACKEND/fingerprint-attach"
  write_manifest "$manifest" "$launch_token" "$root_policy" "$grant_policy" "$port"
  # The production OpenCode relay requires real dimensions. Own and drain a
  # sized PTY even when the checker itself has no terminal; never bypass the
  # guard or substitute COLUMNS/LINES. This wrapper signals only its own child.
  HOME=$HARNESS_HOME PATH=/usr/bin:/bin USER=nvim-ai LOGNAME=nvim-ai TERM=xterm \
    "$PYTHON" -I -B -c '
import os, pty, select, signal, subprocess, sys, termios
stopped = False
def stop(_number, _frame):
    global stopped
    stopped = True
for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(number, stop)
master, slave = pty.openpty()
child = None
try:
    termios.tcsetwinsize(slave, (24, 80))
    # File-mutation probes must not prompt (for example rm on a read-only
    # file). The actual output PTY still supplies dimensions to the guard.
    child = subprocess.Popen([sys.executable, "-I", "-B", *sys.argv[1:]],
                             stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                             close_fds=True, start_new_session=True)
    os.close(slave)
    slave = None
    size = 0
    while not stopped and child.poll() is None:
        if not select.select([master], [], [], .05)[0]:
            continue
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        size += len(data)
        if size > 128 * 1024:
            raise ValueError("bounded confinement PTY output exceeded")
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=.75)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=.75)
    os.close(master)
    if slave is not None:
        os.close(slave)
' "$LAUNCHER" --manifest "$manifest" >"$run_log" 2>&1 &
  HARNESS_LAUNCH_PID=$!
  completed=0
  for _attempt in $(seq 1 100); do
    if [ -f "$HARNESS_BACKEND/complete-attach" ]; then
      completed=1
      break
    fi
    if ! kill -0 "$HARNESS_LAUNCH_PID" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if [ "$completed" -ne 1 ]; then
    sed -n '1,20p' "$run_log" >&2
    fail "$case_name did not complete"
  fi
  [ ! -e "$manifest" ] || fail "$case_name launch manifest was not consumed"
  [ "$(cat "$HARNESS_BACKEND/fingerprint-serve")" = "$HARNESS_FINGERPRINT" ] || fail "$case_name server fingerprint changed"
  [ "$(cat "$HARNESS_BACKEND/fingerprint-attach")" = "$HARNESS_FINGERPRINT" ] || fail "$case_name attach fingerprint changed"
  [ "$(stat -c %a "$HARNESS_BACKEND/complete-attach")" = 600 ] || fail "$case_name sentinel mode changed"
  stop_owned_process "$HARNESS_LAUNCH_PID"
  HARNESS_LAUNCH_PID=
}

run_case read-only cccccccccccccccccccccccccccccccc deny deny
[ ! -e "$HARNESS_PROJECT/inside.txt" ] || fail "read-only root became writable"

run_case writable eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee allow deny
[ "$(cat "$HARNESS_PROJECT/inside.txt")" = inside ] || fail "writable root write failed"
[ ! -e "$HARNESS_GRANT/granted.txt" ] || fail "unapproved grant became writable"
rm -f "$HARNESS_PROJECT/inside.txt"

run_case approved-grant ffffffffffffffffffffffffffffffff allow allow
[ "$(cat "$HARNESS_PROJECT/inside.txt")" = inside ] || fail "approved root write failed"
[ "$(cat "$HARNESS_GRANT/granted.txt")" = grant ] || fail "approved grant write failed"

[ ! -e "$HARNESS_SIBLING/outside.txt" ] || fail "sibling directory became writable"
[ "$(cat "$HARNESS_GIT/config")" = original ] || fail "Git administration became writable"
[ ! -e "$HARNESS_ESCAPE/outside.txt" ] || fail "symlink escape became writable"
[ -f "$HARNESS_BACKEND/cache-serve.txt" ] || fail "server cache was not writable"
[ -f "$HARNESS_BACKEND/cache-attach.txt" ] || fail "attach cache was not writable"
[ -f "$HARNESS_PROFILE_MANIFEST" ] || fail "managed profile manifest was removed"
[ "$(find "$HARNESS_PROFILE/empty-home-opencode" -mindepth 1 -maxdepth 1 -printf '%f\n')" = .gitignore ] || fail "managed home mask tree changed"
"$PYTHON" -I -B -c 'import pathlib,sys; expected=b"node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"; raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes()==expected else 1)' "$HARNESS_PROFILE/empty-home-opencode/.gitignore" || fail "managed home bootstrap changed"
[ ! -e "$HARNESS_BACKEND/profiles/hostile" ] || fail "profiles directory became writable"
[ ! -e "$HARNESS_BACKEND/profiles/moved" ] || fail "managed profile was renamed"
[ -d "$HARNESS_PROFILES_PRESERVED" ] || fail "profiles preserved fixture was removed"
[ -d "$HARNESS_PROFILES_EMPTY" ] || fail "profiles empty fixture was removed"
[ ! -e "$HARNESS_BACKEND/profiles/harness-preserved-moved" ] || fail "profiles preserved fixture was renamed"
[ "$(cat "$HARNESS_PROFILES_PRESERVED/marker")" = profiles-preserved ] || fail "profiles preserved content changed"
[ ! -e "$HARNESS_BACKENDS/.opencode-profile-hostile.tmp" ] || fail "unpublished generation namespace became writable"
[ -d "$HARNESS_STAGING_PRESERVED" ] || fail "staging preserved fixture was removed"
[ -d "$HARNESS_STAGING_EMPTY" ] || fail "staging empty fixture was removed"
[ ! -e "$HARNESS_BACKENDS/.opencode-profile-preserved-moved.tmp" ] || fail "staging preserved fixture was renamed"
[ "$(cat "$HARNESS_STAGING_PRESERVED/marker")" = staging-preserved ] || fail "staging preserved content changed"
[ ! -e "$HARNESS_HOME/.opencode/hostile" ] || fail "host home mask destination was modified"
[ "$(cat "$HARNESS_HOME/.opencode/host-preserved")" = host-preserved ] || fail "host home configuration changed"
[ "$(stat -c '%d:%i:%a:%u' "$HARNESS_HOME")" = "$HARNESS_HOME_METADATA" ] || fail "inherited home metadata changed"
[ "$(stat -c '%d:%i:%a:%u' "$HARNESS_HOME/.opencode")" = "$HARNESS_HOME_OPENCODE_METADATA" ] || fail "host OpenCode destination metadata changed"
[ "$(find "$HARNESS_HOME" -mindepth 1 -maxdepth 1 -printf '%f\n')" = .opencode ] || fail "inherited home gained an unexpected mountpoint"
[ "$(find "$HARNESS_HOME/.opencode" -mindepth 1 -maxdepth 1 -printf '%f\n')" = host-preserved ] || fail "host OpenCode destination contents changed"
for private_directory in \
  "$HARNESS_BACKEND/xdg-cache" \
  "$HARNESS_BACKEND/xdg-config" \
  "$HARNESS_BACKEND/xdg-data" \
  "$HARNESS_BACKEND/xdg-data/opencode" \
  "$HARNESS_BACKEND/xdg-state"; do
  [ -d "$private_directory" ] || fail "first-launch private destination is missing"
  [ "$(stat -c %a "$private_directory")" = 700 ] || fail "first-launch private destination mode changed"
done
[ -f "$HARNESS_BACKEND/xdg-data/opencode/auth.json" ] || fail "authentication placeholder is missing"
[ "$(stat -c %a "$HARNESS_BACKEND/xdg-data/opencode/auth.json")" = 600 ] || fail "authentication placeholder mode changed"
[ ! -s "$HARNESS_BACKEND/xdg-data/opencode/auth.json" ] || fail "authentication placeholder retained credentials"
[ -z "$(find "$HARNESS_BACKEND/xdg-cache" -mindepth 1 -print -quit)" ] || fail "cache destination gained an unexpected host entry"
[ -z "$(find "$HARNESS_BACKEND/xdg-config" -mindepth 1 -print -quit)" ] || fail "configuration overlay mutated its host destination"
[ -z "$(find "$HARNESS_BACKEND/xdg-state" -mindepth 1 -print -quit)" ] || fail "state destination gained an unexpected host entry"
[ "$(find "$HARNESS_BACKEND/xdg-data/opencode" -mindepth 1 -maxdepth 1 -printf '%f\n')" = auth.json ] || fail "data destination gained an unexpected host entry"
backend_directories=$(find "$HARNESS_BACKEND" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
expected_backend_directories=$(printf '%s\n' profiles xdg-cache xdg-config xdg-data xdg-state | sort)
[ "$backend_directories" = "$expected_backend_directories" ] || fail "backend state gained an unexpected host mountpoint"
grep -F '"state":"open"' "$HARNESS_EVENT_FILE" >/dev/null || fail "open event was not recorded"
if grep -F 'credential-canary' "$HARNESS_EVENT_FILE" "$HARNESS_ROOT"/*.log >/dev/null 2>&1; then
  fail "credential contents escaped into diagnostics"
fi

printf '%s\n' 'ok - nvim AI Bubblewrap boundary'
