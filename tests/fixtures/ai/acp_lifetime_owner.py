"""Disposable host owner of the real shared modules; NOT the chat controller."""
import array
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import threading


HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[2] / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pin_worker(root, worker):
    # Transfer only a duplicate read end to the test. It never consumes ACP
    # while this owner is alive; after death it can independently observe EOF.
    with socket.socket(fileno=int(sys.argv[3])) as observer:
        observer.sendmsg([b"output"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                       array.array("i", [worker.output.fileno()]))])
    print(json.dumps({"root": str(root), "worker": worker.child.pid}), flush=True)
    assert sys.stdin.readline() == "start\n"


storage, staging = load("nvim-ai-conversation-store"), load("nvim-ai-staged")
parent = Path(sys.argv[1])
phase = sys.argv[2]
if phase == "real-active":
    spec = importlib.util.spec_from_file_location("acp_session_probe", HERE / "acp_session_probe.py")
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    fixture = probe.Fixture(os.path.realpath(os.environ["NVIM_AI_ACP_REAL_OPENCODE"]), parent=parent)
    real_worker = probe.Worker(fixture, 1)
    pin_worker(fixture.state.root, real_worker.transport)
    session = real_worker.start()
    fixture.provider.replies.append({"text": "Partial local-fixture answer.", "hold": threading.Event()})
    identifier = real_worker.begin("session/prompt", {"sessionId": session, "prompt": [
        {"type": "text", "text": "Answer briefly without editing any file."}]})
    assert fixture.provider.streaming.wait(timeout=5)
    print(json.dumps({"ports": [real_worker.port, fixture.provider.server.server_port],
                      "requests": len(fixture.provider.requests), "source": str(fixture.source),
                      "selected": str(real_worker.selected)}), flush=True)
    real_worker.receive(identifier)
    raise AssertionError("Test owner survived its held provider response")

state = storage.Store(parent)
if phase == "fresh":
    print(json.dumps({"root": str(state.root), "artifacts": state.check()}), flush=True)
    state.close()
    sys.exit(0)
task = parent / "worker"
for name in ("home", "config", "data", "cache", "state"):
    (task / "agent" / name).mkdir(mode=0o700, parents=True)
(task / "staging").mkdir(mode=0o700)
(task / "staging/example.txt").write_bytes(b"original text\n")
peer = parent / "peer"
shutil.copyfile(HERE / "acp_lifetime_peer.py", peer)
peer.chmod(0o700)
command, env = staging.sandbox({"bwrap": os.path.realpath(shutil.which("bwrap")),
                               "opencode": str(peer)}, task, {})


def ready(message):
    assert message["method"] == "fixture/ready"
    print(json.dumps({"ports": message["params"]["ports"]}), flush=True)


worker = state.start(command, env=env, on_notification=ready)
pin_worker(state.root, worker)
# Intentionally no finally: tests kill this exact process to bypass Python cleanup.
reply = worker.request("fixture/" + phase, {}, timeout=180)
assert phase in ("stopping", "idle")
assert reply == {"stopReason": "end_turn"}
state.stop(outcome="completed")  # The test kills us after the peer observes EOF.
if phase == "idle":
    print(json.dumps({"ports": [], "settled": True}), flush=True)
    sys.stdin.read()  # No live worker while the owner is idle.
raise AssertionError("Crash-test shutdown unexpectedly completed")
