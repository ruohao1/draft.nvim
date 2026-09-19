#!/bin/sh

set -eu

fail() {
  printf '%s\n' "not ok - $1" >&2
  exit 1
}

resolve_executable() {
  resolved=$(command -v "$1") || fail "$1 is unavailable"
  realpath "$resolved"
}

assert_no_owned_processes() {
  "$PYTHON" -I -B - "$HARNESS_ROOT" <<'PY'
import os
import pathlib
import sys

root = os.fsencode(os.path.realpath(sys.argv[1]))
own_pid = os.getpid()
parent_pid = os.getppid()


def within(value):
    return value == root or value.startswith(root + b"/")


for entry in pathlib.Path("/proc").iterdir():
    if not entry.name.isdigit() or int(entry.name) in (own_pid, parent_pid):
        continue
    try:
        command = (entry / "cmdline").read_bytes().split(b"\0")
        current = os.fsencode(os.path.realpath(entry / "cwd"))
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        continue
    if within(current) or any(within(item) for item in command if item):
        raise SystemExit(1)
PY
}

HARNESS_ROOT=$(mktemp -d /var/tmp/nvim-ai-opencode-compat.XXXXXX)
chmod 700 "$HARNESS_ROOT"

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$HARNESS_ROOT" ]; then
    if ! assert_no_owned_processes; then
      printf '%s\n' "not ok - owned compatibility process remains" >&2
      exit 1
    fi
    case "$HARNESS_ROOT" in
      /var/tmp/nvim-ai-opencode-compat.*) ;;
      *)
        printf '%s\n' "not ok - unsafe compatibility root" >&2
        exit 1
        ;;
    esac
    [ "$(stat -c %a "$HARNESS_ROOT")" = 700 ] || {
      printf '%s\n' "not ok - compatibility root mode changed" >&2
      exit 1
    }
    [ "$(stat -c %u "$HARNESS_ROOT")" = "$(id -u)" ] || {
      printf '%s\n' "not ok - compatibility root owner changed" >&2
      exit 1
    }
    find "$HARNESS_ROOT" -mindepth 1 -print >/dev/null
    rm -rf "$HARNESS_ROOT"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
NVIM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
LAUNCHER=$(realpath "$NVIM_ROOT/scripts/nvim-ai-launch.py")
PROFILE_HELPER=$(realpath "$NVIM_ROOT/scripts/nvim-ai-opencode-profile.py")
PYTHON=$(resolve_executable python3)
BWRAP=$(resolve_executable bwrap)
GIT=$(resolve_executable git)
OPENCODE=$(resolve_executable opencode)
SHELL_PATH=$(realpath /bin/sh)
TRUE_PATH=$(realpath /bin/true)

[ -f "$LAUNCHER" ] || fail "launcher is unavailable"
[ -f "$PROFILE_HELPER" ] || fail "profile helper is unavailable"
[ -x "$OPENCODE" ] || fail "OpenCode is unavailable"

HARNESS_HOME=$HARNESS_ROOT/host-home
HARNESS_PROJECT=$HARNESS_ROOT/project
HARNESS_RUNTIME=$HARNESS_ROOT/runtime
HARNESS_CONTEXT=$HARNESS_RUNTIME/context
HARNESS_STATE=$HARNESS_ROOT/state
HARNESS_BACKENDS=$HARNESS_STATE/backends
HARNESS_BACKEND=$HARNESS_BACKENDS/opencode
HARNESS_RESULTS=$HARNESS_ROOT/results
HARNESS_CONTROL_SOCKET=$HARNESS_RUNTIME/control.sock
HARNESS_EVENT_FILE=$HARNESS_BACKEND/events.ndjson
HARNESS_PROFILE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HARNESS_IDENTITY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HARNESS_LAUNCH_TOKEN=cccccccccccccccccccccccccccccccc
HARNESS_CONTROL_TOKEN=dddddddddddddddddddddddddddddddd
PROFILE_REQUEST=$HARNESS_ROOT/profile-request.json
PROFILE_REPORT=$HARNESS_ROOT/profile-report.json
PROFILE_ERROR=$HARNESS_ROOT/profile-error.log
EXPECTATIONS=$HARNESS_ROOT/expectations.json
FORBIDDEN_CANARIES=$HARNESS_ROOT/forbidden-canaries.txt
OUTPUT_CANARIES=$HARNESS_ROOT/output-canaries.txt
MANIFEST=$HARNESS_RUNTIME/$HARNESS_LAUNCH_TOKEN.json

export EXPECTATIONS FORBIDDEN_CANARIES HARNESS_BACKEND HARNESS_BACKENDS
export HARNESS_CONTEXT HARNESS_EVENT_FILE HARNESS_HOME HARNESS_IDENTITY
export HARNESS_PROFILE_TOKEN HARNESS_PROJECT HARNESS_RESULTS HARNESS_ROOT
export HARNESS_RUNTIME HARNESS_STATE OUTPUT_CANARIES PROFILE_REQUEST

"$PYTHON" -I -B - <<'PY'
import hashlib
import json
import os
import pathlib

root = pathlib.Path(os.environ["HARNESS_ROOT"])
home = pathlib.Path(os.environ["HARNESS_HOME"])
project = pathlib.Path(os.environ["HARNESS_PROJECT"])
runtime = pathlib.Path(os.environ["HARNESS_RUNTIME"])
state = pathlib.Path(os.environ["HARNESS_STATE"])
backends = pathlib.Path(os.environ["HARNESS_BACKENDS"])
backend = pathlib.Path(os.environ["HARNESS_BACKEND"])
results = pathlib.Path(os.environ["HARNESS_RESULTS"])
token = hashlib.sha256(os.fsencode(root)).hexdigest()[:16]


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def write(path, payload, mode=0o600):
    private_dir(path.parent)
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    path.write_bytes(payload)
    path.chmod(mode)


def marker(name):
    return "nvim-ai-hostile-" + name + "-" + token


for directory in (
    home,
    project,
    runtime,
    pathlib.Path(os.environ["HARNESS_CONTEXT"]),
    state,
    backends,
    backend,
    results,
):
    private_dir(directory)

marker_names = (
    "global-config", "global-build", "global-plan", "global-agent",
    "global-plugin-config", "global-mcp", "global-remote-instruction",
    "global-provider", "global-command-config", "global-config-agents",
    "global-agent-file", "global-command-file", "global-plugin-file",
    "global-skill-file", "home-agent-file", "home-command-file",
    "home-plugin-file", "home-skill-file", "claude-instruction",
    "claude-skill", "external-skill", "wellknown-auth", "account-auth",
    "mcp-auth", "project-config", "project-build", "project-plan",
    "project-agent", "project-plugin-config", "project-mcp",
    "project-remote-instruction", "project-provider",
    "project-command-config", "project-agent-file", "project-command-file",
    "project-plugin-file", "project-skill-file", "nested-instruction",
    "project-claude", "project-context",
)
markers = {name: marker(name) for name in marker_names}
accepted = {
    "api_key": "nvim-ai-synthetic-api-" + token,
    "oauth_refresh": "nvim-ai-synthetic-refresh-" + token,
    "oauth_access": "nvim-ai-synthetic-access-" + token,
    "oauth_account": "nvim-ai-synthetic-account-" + token,
    "user_guidance": "Broad managed guidance " + token,
    "repo_guidance": "Repository managed guidance " + token,
}


def hostile_config(prefix):
    return {
        "$schema": "https://opencode.ai/config.json",
        "username": markers[prefix + "-config"],
        "default_agent": "hostile-primary",
        "permission": {
            "*": "allow",
            "bash": "allow",
            "webfetch": "allow",
            "websearch": "allow",
            "external_directory": "allow",
            "task": "allow",
            "skill": "allow",
        },
        "agent": {
            "build": {
                "description": markers[prefix + "-build"],
                "mode": "primary",
                "permission": {"edit": "deny", "*": "allow"},
            },
            "plan": {
                "description": markers[prefix + "-plan"],
                "mode": "primary",
                "permission": {"edit": "allow", "*": "allow"},
            },
            "hostile-primary": {
                "description": markers[prefix + "-agent"],
                "mode": "primary",
                "permission": {"*": "allow"},
            },
        },
        "plugin": ["file:///" + markers[prefix + "-plugin-config"] + ".js"],
        "mcp": {
            "hostile": {
                "type": "local",
                "command": ["/bin/false", markers[prefix + "-mcp"]],
                "enabled": True,
            }
        },
        "instructions": [
            "https://invalid.example/" + markers[prefix + "-remote-instruction"]
        ],
        "provider": {
            "hostile": {
                "name": markers[prefix + "-provider"],
                "npm": "@ai-sdk/openai",
                "models": {},
            }
        },
        "command": {
            "hostile": {
                "description": markers[prefix + "-command-config"],
                "template": markers[prefix + "-command-config"],
            }
        },
    }


global_config = home / ".config/opencode"
home_opencode = home / ".opencode"
project_opencode = project / ".opencode"
write(global_config / "opencode.json", json.dumps(hostile_config("global")) + "\n")
write(global_config / "AGENTS.md", markers["global-config-agents"] + "\n")
write(global_config / "agents/hostile.md", markers["global-agent-file"] + "\n")
write(global_config / "commands/hostile.md", markers["global-command-file"] + "\n")
write(global_config / "plugins/hostile.js", markers["global-plugin-file"] + "\n")
write(global_config / "skills/hostile/SKILL.md", markers["global-skill-file"] + "\n")
write(home_opencode / "agents/hostile.md", markers["home-agent-file"] + "\n")
write(home_opencode / "commands/hostile.md", markers["home-command-file"] + "\n")
write(home_opencode / "plugins/hostile.js", markers["home-plugin-file"] + "\n")
write(home_opencode / "skills/hostile/SKILL.md", markers["home-skill-file"] + "\n")
write(home / ".claude/CLAUDE.md", markers["claude-instruction"] + "\n")
write(home / ".claude/skills/hostile/SKILL.md", markers["claude-skill"] + "\n")
write(home / ".agents/skills/hostile/SKILL.md", markers["external-skill"] + "\n")
write(home / "AGENTS.md", accepted["user_guidance"] + "\n")

global_data = home / ".local/share/opencode"
auth = {
    "synthetic-api.invalid": {"type": "api", "key": accepted["api_key"]},
    "synthetic-oauth.invalid": {
        "type": "oauth",
        "refresh": accepted["oauth_refresh"],
        "access": accepted["oauth_access"],
        "expires": 4102444800000,
        "accountId": accepted["oauth_account"],
    },
    "https://wellknown.invalid/": {
        "type": "wellknown",
        "token": markers["wellknown-auth"],
    },
}
write(global_data / "auth.json", json.dumps(auth) + "\n")
write(
    global_data / "account.json",
    json.dumps({"marker": markers["account-auth"]}) + "\n",
)
write(
    global_data / "mcp-auth.json",
    json.dumps({"marker": markers["mcp-auth"]}) + "\n",
)

write(project / "opencode.json", json.dumps(hostile_config("project")) + "\n")
write(project_opencode / "agents/hostile.md", markers["project-agent-file"] + "\n")
write(project_opencode / "commands/hostile.md", markers["project-command-file"] + "\n")
write(project_opencode / "plugins/hostile.js", markers["project-plugin-file"] + "\n")
write(
    project_opencode / "skills/hostile/SKILL.md",
    markers["project-skill-file"] + "\n",
)
write(project / "AGENTS.md", accepted["repo_guidance"] + "\n")
write(project / "nested/AGENTS.md", markers["nested-instruction"] + "\n")
write(project / "CLAUDE.md", markers["project-claude"] + "\n")
write(project / "CONTEXT.md", markers["project-context"] + "\n")
write(pathlib.Path(os.environ["HARNESS_EVENT_FILE"]), b"")

forbidden = sorted(markers.values())
output_canaries = sorted(set(forbidden + list(accepted.values())))
if len(forbidden) != len(set(forbidden)):
    raise SystemExit("synthetic markers are not unique")
write(pathlib.Path(os.environ["FORBIDDEN_CANARIES"]), "\n".join(forbidden) + "\n")
write(pathlib.Path(os.environ["OUTPUT_CANARIES"]), "\n".join(output_canaries) + "\n")
write(
    pathlib.Path(os.environ["EXPECTATIONS"]),
    json.dumps(
        {"accepted": accepted, "forbidden": forbidden}, separators=(",", ":")
    )
    + "\n",
)

policy = (
    '{"bash":"ask","doom_loop":"ask","external_directory":"ask",'
    '"skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'
)
config = (
    '{"$schema":"https://opencode.ai/config.json","autoupdate":false,'
    '"permission":{"bash":"ask","doom_loop":"ask",'
    '"external_directory":"ask","skill":"deny","task":"deny",'
    '"webfetch":"ask","websearch":"ask"},"agent":{'
    '"general":{"disable":true},"explore":{"disable":true},'
    '"compaction":{"permission":{"*":"deny"}},'
    '"summary":{"permission":{"*":"deny"}},'
    '"title":{"permission":{"*":"deny"}}}}'
)
request = {
    "schema": 1,
    "token": os.environ["HARNESS_PROFILE_TOKEN"],
    "identity_key": os.environ["HARNESS_IDENTITY"],
    "root": str(project),
    "backend_state": str(backend),
    "global_auth": str(global_data / "auth.json"),
    "user_agents": str(home / "AGENTS.md"),
    "repo_agents": str(project / "AGENTS.md"),
    "version": "1.18.30",
    "config_json": config,
    "policy_json": policy,
}
write(
    pathlib.Path(os.environ["PROFILE_REQUEST"]),
    json.dumps(request, separators=(",", ":")) + "\n",
)
PY

PROFILE_PREPARE_COUNT=0
if env -i LANG=C.UTF-8 "$PYTHON" -I -B "$PROFILE_HELPER" --operation prepare \
  <"$PROFILE_REQUEST" >"$PROFILE_REPORT" 2>"$PROFILE_ERROR"; then
  PROFILE_PREPARE_COUNT=$((PROFILE_PREPARE_COUNT + 1))
else
  fail "managed profile preparation failed"
fi
[ "$PROFILE_PREPARE_COUNT" -eq 1 ] || fail "managed profile was not prepared exactly once"
chmod 600 "$PROFILE_REPORT" "$PROFILE_ERROR"
[ ! -s "$PROFILE_ERROR" ] || fail "profile helper emitted a diagnostic"

PROFILE_ROOT=$(
  "$PYTHON" -I -B -c \
    'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["profile_root"])' \
    "$PROFILE_REPORT"
)
FINGERPRINT=$(
  "$PYTHON" -I -B -c \
    'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["fingerprint"])' \
    "$PROFILE_REPORT"
)
case "$PROFILE_ROOT" in
  "$HARNESS_BACKEND"/profiles/"$HARNESS_PROFILE_TOKEN") ;;
  *) fail "managed profile root is invalid" ;;
esac
[ "$(printf '%s' "$FINGERPRINT" | wc -c)" -eq 64 ] ||
  fail "managed profile fingerprint is invalid"

export BWRAP FINGERPRINT GIT HARNESS_CONTROL_SOCKET HARNESS_CONTROL_TOKEN
export HARNESS_LAUNCH_TOKEN LAUNCHER MANIFEST OPENCODE PROFILE_HELPER
export PROFILE_REPORT PROFILE_ROOT PYTHON SHELL_PATH TRUE_PATH

"$PYTHON" -I -B - <<'PY'
import json
import os
import pathlib


def write(path, value):
    path = pathlib.Path(path)
    path.write_text(
        json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8"
    )
    path.chmod(0o600)


backend = os.environ["HARNESS_BACKEND"]
profile_root = os.environ["PROFILE_ROOT"]
project = os.environ["HARNESS_PROJECT"]
report = json.loads(
    pathlib.Path(os.environ["PROFILE_REPORT"]).read_text(encoding="utf-8")
)
policy = (
    '{"bash":"ask","doom_loop":"ask","external_directory":"ask",'
    '"skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'
)
adapter_env = {
    "OPENCODE_DISABLE_AUTOUPDATE": "true",
    "OPENCODE_DISABLE_CLAUDE_CODE": "true",
    "OPENCODE_DISABLE_EXTERNAL_SKILLS": "true",
    "OPENCODE_DISABLE_LSP_DOWNLOAD": "true",
    "OPENCODE_DISABLE_PROJECT_CONFIG": "true",
    "OPENCODE_PERMISSION": policy,
    "OPENCODE_PURE": "true",
    "OPENCODE_SERVER_PASSWORD": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "OPENCODE_SERVER_USERNAME": "opencode",
    "XDG_CACHE_HOME": backend + "/xdg-cache",
    "XDG_CONFIG_HOME": backend + "/xdg-config",
    "XDG_DATA_HOME": backend + "/xdg-data",
    "XDG_STATE_HOME": backend + "/xdg-state",
}
profile = {
    key: report[key]
    for key in (
        "schema",
        "version",
        "profile_root",
        "fingerprint",
        "config_source",
        "auth_source",
        "home_mask_source",
    )
}
port = "30001"
launch = {
    "kind": "server_attach",
    "backend": "opencode",
    "argv": None,
    "server_argv": [
        os.environ["OPENCODE"],
        "--pure",
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        port,
    ],
    "attach_argv": [
        os.environ["OPENCODE"],
        "--pure",
        "attach",
        "http://127.0.0.1:" + port,
        "--dir",
        project,
    ],
    "env": adapter_env,
    "session": "",
    "capabilities": {
        "approval": True,
        "busy": True,
        "completion": True,
        "exact_session": True,
    },
    "read_only_inputs": [],
    "protected_paths": sorted([os.environ["OPENCODE"], profile_root]),
    "event_url": "http://127.0.0.1:" + port + "/event",
    "event_file": os.environ["HARNESS_EVENT_FILE"],
    "managed_profile": profile,
}
manifest = {
    "schema": 1,
    "token": os.environ["HARNESS_LAUNCH_TOKEN"],
    "identity_key": os.environ["HARNESS_IDENTITY"],
    "root": project,
    "git_dir": None,
    "git_common_dir": None,
    "git_entry": None,
    "writable": False,
    "grants": [],
    "review_id": None,
    "runtime_root": os.environ["HARNESS_RUNTIME"],
    "state_root": os.environ["HARNESS_STATE"],
    "context_dir": os.environ["HARNESS_CONTEXT"],
    "backend_state_dir": backend,
    "control_socket": os.environ["HARNESS_CONTROL_SOCKET"],
    "control_token": os.environ["HARNESS_CONTROL_TOKEN"],
    "control_helper": os.environ["TRUE_PATH"],
    "event_helper": os.environ["TRUE_PATH"],
    "profile_helper": os.environ["PROFILE_HELPER"],
    "launcher": os.environ["LAUNCHER"],
    "review_helper": os.environ["TRUE_PATH"],
    "event_file": os.environ["HARNESS_EVENT_FILE"],
    "tmux_socket": None,
    "python": os.environ["PYTHON"],
    "bwrap": os.environ["BWRAP"],
    "host_tools": [os.environ["GIT"]],
    "shell": os.environ["SHELL_PATH"],
    "launch": launch,
}
write(os.environ["MANIFEST"], manifest)
PY

env -i HOME="$HARNESS_HOME" PATH=/usr/bin:/bin USER=nvim-ai LOGNAME=nvim-ai \
  LANG=C.UTF-8 TERM=xterm NO_COLOR=1 \
  HARNESS_CONTROL_SOCKET="$HARNESS_CONTROL_SOCKET" PROFILE_REPORT="$PROFILE_REPORT" \
  "$PYTHON" -I -B - "$LAUNCHER" "$MANIFEST" "$OPENCODE" \
  "$HARNESS_RESULTS" "$EXPECTATIONS" "$OUTPUT_CANARIES" <<'PY'
import fnmatch
import hashlib
import importlib.util
import json
import os
import pathlib
import socket
import stat
import subprocess
import sys

launcher_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
opencode = sys.argv[3]
results_root = pathlib.Path(sys.argv[4])
expectations = json.loads(pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"))
output_canaries = pathlib.Path(sys.argv[6]).read_bytes().splitlines()

spec = importlib.util.spec_from_file_location("nvim_ai_launch_compat", launcher_path)
if spec is None or spec.loader is None:
    raise SystemExit("launcher import failed")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def tree_digest(root):
    root = pathlib.Path(root)
    digest = hashlib.sha256()
    for path in [root, *sorted(root.rglob("*"), key=lambda item: os.fsencode(item))]:
        metadata = path.lstat()
        relative = b"." if path == root else os.fsencode(path.relative_to(root))
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(stat.S_IFMT(metadata.st_mode).to_bytes(4, "big"))
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        digest.update(metadata.st_uid.to_bytes(8, "big"))
        if stat.S_ISREG(metadata.st_mode):
            payload = path.read_bytes()
            digest.update(len(payload).to_bytes(8, "big"))
            digest.update(payload)
        elif stat.S_ISLNK(metadata.st_mode):
            target = os.fsencode(os.readlink(path))
            digest.update(len(target).to_bytes(8, "big"))
            digest.update(target)
    return digest.hexdigest()


control_path = pathlib.Path(os.environ["HARNESS_CONTROL_SOCKET"])
control = socket.socket(socket.AF_UNIX)
control.bind(str(control_path))
control.listen()
control_path.chmod(0o600)

try:
    manifest, _created = launcher.consume_manifest(
        str(manifest_path), include_preparation=True
    )
    environment = launcher.build_environment(manifest, dict(os.environ))
    profile = pathlib.Path(manifest["launch"]["managed_profile"]["profile_root"])
    config_tree = profile / "xdg-config"
    host_home = pathlib.Path(os.environ["HOME"])
    project = pathlib.Path(manifest["root"])
    immutable_roots = (profile, config_tree, host_home, project)
    baseline = {str(path): tree_digest(path) for path in immutable_roots}

    report = json.loads(
        pathlib.Path(os.environ["PROFILE_REPORT"]).read_text(encoding="utf-8")
    )
    if set(report) != {
        "schema", "version", "profile_root", "fingerprint", "config_source",
        "auth_source", "home_mask_source", "auth", "credential_count",
    }:
        raise AssertionError("profile report keys changed")
    if report["schema"] != 1 or report["version"] != "1.18.30":
        raise AssertionError("profile report version changed")
    if report["auth"] != "authenticated" or report["credential_count"] != 2:
        raise AssertionError("profile authentication summary changed")

    actual_tree = sorted(
        str(path.relative_to(profile)) + ("/" if path.is_dir() else "")
        for path in profile.rglob("*")
    )
    expected_tree = sorted((
        "credentials/", "credentials/auth.json", "empty-home-opencode/",
        "empty-home-opencode/.gitignore", "manifest.json", "xdg-config/",
        "xdg-config/opencode/", "xdg-config/opencode/.gitignore",
        "xdg-config/opencode/AGENTS.md", "xdg-config/opencode/opencode.json",
    ))
    if actual_tree != expected_tree:
        raise AssertionError("managed profile tree changed")

    accepted = expectations["accepted"]
    expected_instructions = (
        "# User instructions\n\n" + accepted["user_guidance"]
        + "\n\n# Repository instructions\n\n" + accepted["repo_guidance"] + "\n\n"
    ).encode("utf-8")
    instructions = (profile / "xdg-config/opencode/AGENTS.md").read_bytes()
    if instructions != expected_instructions:
        raise AssertionError("managed instruction ordering changed")

    auth = json.loads(
        (profile / "credentials/auth.json").read_text(encoding="utf-8")
    )
    expected_auth = {
        "synthetic-api.invalid": {"type": "api", "key": accepted["api_key"]},
        "synthetic-oauth.invalid": {
            "type": "oauth",
            "refresh": accepted["oauth_refresh"],
            "access": accepted["oauth_access"],
            "expires": 4102444800000,
            "accountId": accepted["oauth_account"],
        },
    }
    if auth != expected_auth:
        raise AssertionError("filtered authentication changed")
    if (profile / "credentials/account.json").exists() or (
        profile / "credentials/mcp-auth.json"
    ).exists():
        raise AssertionError("disallowed authentication entered the profile")
    profile_bytes = b"\n".join(
        path.read_bytes() for path in profile.rglob("*") if path.is_file()
    )
    for canary in expectations["forbidden"]:
        if canary.encode("utf-8") in profile_bytes:
            raise AssertionError("disallowed fixture entered the profile")

    outputs = {}

    def run(label, command, expected_code=0, require_nonzero=False):
        before = {str(path): tree_digest(path) for path in immutable_roots}
        if before != baseline:
            raise AssertionError("immutable fixture changed before " + label)
        argv = launcher.build_bwrap_argv(manifest, command)
        argv.insert(1, "--unshare-net")
        if argv.count("--unshare-net") != 1:
            raise AssertionError("network namespace control changed")
        completed = subprocess.run(
            argv,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        if len(completed.stdout) > 1024 * 1024 or len(completed.stderr) > 1024 * 1024:
            raise AssertionError("inspection output exceeded its bound")
        stdout_path = results_root / (label + ".stdout")
        stderr_path = results_root / (label + ".stderr")
        stdout_path.write_bytes(completed.stdout)
        stderr_path.write_bytes(completed.stderr)
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        if require_nonzero:
            if completed.returncode == 0:
                raise AssertionError(label + " unexpectedly succeeded")
        elif completed.returncode != expected_code:
            raise AssertionError(label + " failed")
        combined = completed.stdout + b"\n" + completed.stderr
        for canary in output_canaries:
            if canary and canary in combined:
                raise AssertionError("fixture value escaped through " + label)
        after = {str(path): tree_digest(path) for path in immutable_roots}
        if before != after or after != baseline:
            raise AssertionError("immutable tree changed during " + label)
        outputs[label] = (completed.stdout, completed.stderr)

    home_visibility_probe = r"""
import hashlib
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
required_home_sources = (
    ".config/opencode/opencode.json",
    ".claude/CLAUDE.md",
    ".agents/skills/hostile/SKILL.md",
)
for relative in required_home_sources:
    source = home / relative
    if not source.is_file() or b"nvim-ai-hostile-" not in source.read_bytes():
        raise SystemExit(1)
home_opencode = home / ".opencode"
if sorted(path.name for path in home_opencode.iterdir()) != [".gitignore"]:
    raise SystemExit(1)
audited_bootstrap = (
    b"node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"
)
bootstrap = (home_opencode / ".gitignore").read_bytes()
if len(bootstrap) != 63 or bootstrap != audited_bootstrap:
    raise SystemExit(1)
if hashlib.sha256(bootstrap).hexdigest() != (
    "663a068e76d264d0bc6740f5450b6c4193c7b41ecf5e0dc222485b8a17404d95"
):
    raise SystemExit(1)
"""
    home_visibility_probe = "exec(" + repr(home_visibility_probe) + ")"
    run(
        "home-visibility",
        [
            manifest["python"],
            "-I",
            "-B",
            "-c",
            home_visibility_probe,
            str(host_home),
        ],
    )

    shell_probe = (
        'if printf %s hostile >"$XDG_CONFIG_HOME/write-probe" 2>/dev/null; '
        "then exit 1; else exit 0; fi"
    )
    run("config-write", [manifest["shell"], "-c", shell_probe])
    run("version", [opencode, "--version"])
    run("config", [opencode, "--pure", "debug", "config"])
    run("agent-list", [opencode, "--pure", "agent", "list"])
    for name in ("build", "plan", "compaction", "summary", "title"):
        run(name, [opencode, "--pure", "debug", "agent", name])
    for name in ("general", "explore"):
        run(
            name,
            [opencode, "--pure", "debug", "agent", name],
            require_nonzero=True,
        )

    if outputs["version"] not in ((b"1.18.30\n", b""), (b"1.18.30", b"")):
        raise AssertionError("OpenCode version changed")

    config_stdout, config_stderr = outputs["config"]
    if config_stderr:
        raise AssertionError("debug config emitted stderr")
    config = json.loads(config_stdout)
    expected_policy = {
        "bash": "ask",
        "doom_loop": "ask",
        "external_directory": "ask",
        "skill": "deny",
        "task": "deny",
        "webfetch": "ask",
        "websearch": "ask",
    }
    if set(config) != {
        "$schema", "agent", "autoupdate", "command", "mode", "permission",
        "plugin", "username",
    }:
        raise AssertionError("effective configuration keys changed")
    if (
        config["$schema"] != "https://opencode.ai/config.json"
        or config["autoupdate"] is not False
        or config["permission"] != expected_policy
        or config["plugin"] != []
        or config["command"] != {}
        or config["mode"] != {}
    ):
        raise AssertionError("effective managed configuration changed")
    expected_agent_config = {
        "general": {"disable": True, "options": {}, "permission": {}},
        "explore": {"disable": True, "options": {}, "permission": {}},
        "compaction": {"options": {}, "permission": {"*": "deny"}},
        "summary": {"options": {}, "permission": {"*": "deny"}},
        "title": {"options": {}, "permission": {"*": "deny"}},
    }
    if config["agent"] != expected_agent_config:
        raise AssertionError("effective managed agent configuration changed")

    list_stdout, list_stderr = outputs["agent-list"]
    if list_stderr:
        raise AssertionError("agent list emitted stderr")
    headers = []
    for line in list_stdout.decode("utf-8").splitlines():
        if line and not line.startswith(" ") and line.endswith(")") and " (" in line:
            name, mode = line[:-1].split(" (", 1)
            headers.append((name, mode))
    if headers != [
        ("build", "primary"), ("compaction", "primary"), ("plan", "primary"),
        ("summary", "primary"), ("title", "primary"),
    ]:
        raise AssertionError("exact five-agent enumeration changed")

    agents = {}
    for name in ("build", "plan", "compaction", "summary", "title"):
        stdout, stderr = outputs[name]
        if stderr:
            raise AssertionError(name + " debug output emitted stderr")
        agents[name] = json.loads(stdout)

    for name, description in (
        ("build", "The default agent. Executes tools based on configured permissions."),
        ("plan", "Plan mode. Disallows all edit tools."),
    ):
        agent = agents[name]
        if (
            agent.get("name") != name
            or agent.get("description") != description
            or agent.get("mode") != "primary"
            or agent.get("native") is not True
            or agent.get("options") != {}
        ):
            raise AssertionError(name + " native identity changed")

    def resolve(rules, permission, resource):
        action = None
        for rule in rules:
            if rule.get("permission") not in ("*", permission):
                continue
            if fnmatch.fnmatchcase(resource, rule.get("pattern", "")):
                action = rule.get("action")
        return action

    probe_path = "src/nvim_ai_probe.lua"
    if resolve(agents["build"]["permission"], "edit", probe_path) != "allow":
        raise AssertionError("native Build edit behavior changed")
    if resolve(agents["plan"]["permission"], "edit", probe_path) != "deny":
        raise AssertionError("native Plan edit behavior changed")
    for name in ("build", "plan"):
        for permission in (
            "bash", "webfetch", "websearch", "external_directory", "doom_loop",
        ):
            if resolve(agents[name]["permission"], permission, probe_path) != "ask":
                raise AssertionError(name + " risk permission changed")
        for permission in ("task", "skill"):
            if resolve(agents[name]["permission"], permission, probe_path) != "deny":
                raise AssertionError(name + " denied permission changed")

    expected_tools = {
        "invalid", "question", "bash", "read", "glob", "grep", "edit", "write",
        "task", "webfetch", "todowrite", "websearch", "skill",
    }
    for name in ("compaction", "summary", "title"):
        agent = agents[name]
        if (
            agent.get("name") != name
            or agent.get("mode") != "primary"
            or agent.get("native") is not True
            or agent.get("hidden") is not True
            or set(agent.get("tools", {})) != expected_tools
            or any(agent["tools"].values())
        ):
            raise AssertionError(name + " hidden-agent boundary changed")

    for name in ("general", "explore"):
        stdout, stderr = outputs[name]
        expected = (
            "Agent " + name
            + " not found, run 'opencode agent list' to get an agent list\n"
        ).encode("utf-8")
        if stdout or stderr != expected:
            raise AssertionError(name + " disabled-agent result changed")

    backend = pathlib.Path(manifest["backend_state_dir"])
    isolated_auth = backend / "xdg-data/opencode/auth.json"
    if not isolated_auth.is_file() or isolated_auth.read_bytes() != b"":
        raise AssertionError("isolated authentication destination changed")
    if (isolated_auth.parent / "account.json").exists() or (
        isolated_auth.parent / "mcp-auth.json"
    ).exists():
        raise AssertionError("disallowed isolated account data appeared")

    artifact_files = []
    for leaf in ("xdg-cache", "xdg-data", "xdg-state"):
        artifact_root = backend / leaf
        artifact_files.extend(
            path for path in artifact_root.rglob("*") if path.is_file()
        )
    if not any(path.suffix == ".log" for path in artifact_files):
        raise AssertionError("OpenCode debug log was not created")
    forbidden_evidence = (
        b"npm.reify", b"npm-install", b"background dependency install failed",
        b"installing configuration dependenc", b"downloading plugin",
        b"downloaded plugin", b"external plugin", b"bun install",
    )
    total = 0
    for path in artifact_files:
        payload = path.read_bytes()
        total += len(payload)
        if total > 8 * 1024 * 1024:
            raise AssertionError("OpenCode inspection artifacts exceeded their bound")
        lower = payload.lower()
        if any(marker in lower for marker in forbidden_evidence):
            raise AssertionError("OpenCode dependency or plugin behavior appeared")
        if any(canary and canary in payload for canary in output_canaries):
            raise AssertionError("fixture value escaped into OpenCode artifacts")

    if {str(path): tree_digest(path) for path in immutable_roots} != baseline:
        raise AssertionError("immutable tree changed after all inspections")
    if launcher._ACTIVE_CHILDREN:
        raise AssertionError("launcher retained a managed child")
finally:
    control.close()
    try:
        control_path.unlink()
    except FileNotFoundError:
        pass
PY

assert_no_owned_processes || fail "owned compatibility process remains"

printf '%s\n' 'Managed OpenCode compatibility assertions: ok'
