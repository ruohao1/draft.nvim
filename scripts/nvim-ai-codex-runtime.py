"""Generated profile and fresh outer filesystem for the pinned Codex app-server."""
import importlib.util
import json
import os
from pathlib import Path
import re


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nvim-ai-staged", HERE / "nvim-ai-staged.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
Refused = staging.Refused
# The legacy response projects cwd writes but cannot describe restricted reads.
POLICY = {"type": "workspaceWrite", "writableRoots": [],
          "networkAccess": False, "excludeTmpdirEnvVar": True, "excludeSlashTmp": True}
VERSION = "0.163.0"


def sandbox(config, task, store):
    model = config.get("model")
    if not isinstance(model, str) or re.fullmatch(r"openai/[a-zA-Z0-9_.-]{1,200}", model) is None:
        raise Refused("Codex requires an explicit openai/model")
    store.check()
    agent = task / "agent"
    for name in ("home", "codex-tmp"):
        (agent / name).mkdir(mode=0o700, parents=True)
    profile = (
        "model = " + json.dumps(model.split("/", 1)[1]) + "\n"
        'cli_auth_credentials_store = "file"\ncheck_for_update_on_startup = false\n'
        'web_search = "disabled"\napproval_policy = "never"\napprovals_reviewer = "user"\n'
        'default_permissions = "draft"\nproject_doc_max_bytes = 0\n'
        '[projects."/tmp/project"]\ntrust_level = "untrusted"\n'
        '[permissions.draft.filesystem]\n":minimal" = "read"\n'
        '"/opt/codex" = "read"\n"/tmp/project" = "write"\n'
        '[permissions.draft.network]\nenabled = false\n'
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
             "--ro-bind", staging.executable(config["codex"]), "/opt/codex",
             "--chdir", "/tmp/project", "--", "/opt/codex", "app-server", "--listen", "stdio://"]
    env = {"PATH": "/usr/bin:/bin", "HOME": "/home/agent", "CODEX_HOME": "/home/agent/.codex",
           "LANG": "C.UTF-8", "SHELL": "/bin/sh", "TERM": "dumb"}
    return argv, env
