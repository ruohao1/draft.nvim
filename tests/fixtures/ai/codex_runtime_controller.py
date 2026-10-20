"""Test-only local provider routing; all controller, turn and store behavior is production."""
import importlib.util
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("runtime_controller", ROOT / "scripts/nvim-ai-conversation.py")
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
sandbox = controller.codex_turns.runtime.sandbox
begin = controller.codex_storage.acp.Worker.begin
notification = controller.codex_turns.Turn.notification


def audit(value):
    with Path(os.environ["DRAFT_CODEX_AUDIT"]).open("a") as output:
        output.write(json.dumps(value) + "\n")


def local_provider(config, task, store):
    argv, env = sandbox(config, task, store)
    profile = task / "agent/codex.toml"
    profile.write_text("openai_base_url = " + json.dumps(os.environ["DRAFT_CODEX_PROVIDER"])
                       + "\n" + profile.read_text())
    return argv, env


def request(worker, method, params, **options):
    audit(dict(method=method, **{key: params[key] for key in ("threadId", "turnId") if key in params}))
    return begin(worker, method, params, **options)


def observed(turn, message):
    notification(turn, message)
    if message["method"] == "turn/completed" and turn.terminal is not None:
        params = message["params"]
        audit({"terminal": params["turn"]["status"], "threadId": params["threadId"],
               "turnId": params["turn"]["id"]})


controller.codex_turns.runtime.sandbox = local_provider
controller.codex_storage.acp.Worker.begin = request
controller.codex_turns.Turn.notification = observed
sys.exit(controller.main())
