"""Generated profile and fresh outer filesystem for the pinned Codex app-server."""
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nvim-ai-staged", HERE / "nvim-ai-staged.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
Refused = staging.Refused
# The legacy response projects cwd writes but cannot describe restricted reads.
POLICY = {"type": "workspaceWrite", "writableRoots": [],
          "networkAccess": False, "excludeTmpdirEnvVar": True, "excludeSlashTmp": True}
VERSION = "0.163.0"


def require_owned_auth(bwrap: str) -> None:
    """Probe capabilities before opening the dedicated login or its lock."""
    command = [staging.executable(bwrap), "--help"]
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
    try:
        output, deadline = bytearray(), time.monotonic() + 5
        os.set_blocking(child.stdout.fileno(), False)
        while True:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([child.stdout], [], [], left)[0]:
                raise ValueError()
            raw = os.read(child.stdout.fileno(), 65537 - len(output))
            if not raw:
                break
            output.extend(raw)
            if len(output) > 65536:
                raise ValueError()
        if child.wait(timeout=max(0, deadline - time.monotonic())) != 0:
            raise ValueError()
        text = output.decode("utf-8")
        if any(re.search(r"(?<!\S)" + flag + r"(?=\s|$)", text) is None
               for flag in ("--bind-fd", "--sync-fd")):
            raise ValueError()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise Refused("Dedicated Codex credentials require Bubblewrap descriptor support") from None
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        child.stdout.close()


def sandbox(config, task, store):
    model = config.get("model")
    if not isinstance(model, str) or re.fullmatch(r"openai/[a-zA-Z0-9_.-]{1,200}", model) is None:
        raise Refused("Codex requires an explicit openai/model")
    store.check()
    auth_mount = []
    if store.auth_store is not None:
        if len(store.auth_fds) != 2:
            raise Refused("Codex credential lease required")
        auth_fd, lock_fd = store.auth_fds
        auth_mount = ["--bind-fd", str(auth_fd), "/home/agent/.codex/auth.json",
                      "--sync-fd", str(lock_fd)]
    codex = staging.executable(config["codex"])
    host = staging.executable(str(Path(codex).with_name("codex-code-mode-host")))
    agent = task / "agent"
    for name in ("home", "codex-tmp"):
        (agent / name).mkdir(mode=0o700, parents=True)
    private_masks = "".join(json.dumps("/home/agent/.codex/" + name) + ' = "deny"\n'
                            for name in sorted(store.private_roots))
    profile = (
        "model = " + json.dumps(model.split("/", 1)[1]) + "\n"
        'cli_auth_credentials_store = "file"\ncheck_for_update_on_startup = false\n'
        'web_search = "disabled"\napproval_policy = "never"\napprovals_reviewer = "user"\n'
        'default_permissions = "draft"\nproject_doc_max_bytes = 0\n'
        '[projects."/tmp/project"]\ntrust_level = "untrusted"\n'
        '[permissions.draft.filesystem]\n"/" = "read"\n"/tmp/project" = "write"\n'
        + private_masks + '[permissions.draft.network]\nenabled = false\n'
        '[skills.bundled]\nenabled = false\n[analytics]\nenabled = false\n'
        '[agents]\nenabled = false\n[mcp_servers]\n[features]\n'
        'memories = false\nplugins = false\napps = false\nshell_snapshot = false\n'
        'multi_agent = false\nmulti_agent_v2 = false\nweb_search_request = false\n'
        'responses_websockets = false\nresponses_websockets_v2 = false\n'
        'enable_request_compression = false\n')
    staging.private_write(agent / "codex.toml", profile.encode())
    argv = [staging.executable(config["bwrap"]), "--new-session", "--unshare-pid",
            "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--ro-bind", "/usr", "/usr"]
    for name in ("bin", "sbin", "lib", "lib64"):
        path = "/" + name
        if os.path.islink(path):
            argv += ["--symlink", os.readlink(path), path]
        elif os.path.isdir(path):
            argv += ["--ro-bind", path, path]
    for path in staging.SYSTEM_FILES:
        if os.path.exists(path):
            argv += ["--ro-bind", path, path]
    argv += ["--tmpfs", "/tmp", "--dir", "/home", "--dir", "/run", "--dir", "/opt",
             "--dev", "/dev", "--proc", "/proc", "--bind", str(agent / "home"), "/home/agent",
             "--bind", str(store.path), "/home/agent/.codex",
             "--bind", str(agent / "codex-tmp"), "/home/agent/.codex/tmp",
             "--ro-bind", str(agent / "codex.toml"), "/home/agent/.codex/config.toml",
             "--bind", str(task / "staging"), "/tmp/project",
             "--ro-bind", codex, "/opt/codex",
             "--ro-bind", host, "/opt/codex-code-mode-host"] + auth_mount + [
             "--chdir", "/tmp/project", "--", "/opt/codex", "app-server", "--listen", "stdio://"]
    env = {"PATH": "/usr/bin:/bin", "HOME": "/home/agent", "CODEX_HOME": "/home/agent/.codex",
           "LANG": "C.UTF-8", "SHELL": "/bin/sh", "TERM": "dumb"}
    return argv, env
