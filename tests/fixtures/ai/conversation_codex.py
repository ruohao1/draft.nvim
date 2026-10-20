#!/usr/bin/python3
"""Deterministic Codex wire faults; only run in a disposable test namespace."""
import errno
import json
import os
from pathlib import Path
import sys
import socket
import threading
import time


CASE = "answer"
AUDIT_PORT = 0
THREAD = "00000000-0000-4000-8000-000000000001"
TURN = "00000000-0000-4000-8000-000000000002"
POLICY = {"type": "workspaceWrite", "writableRoots": ["/tmp/project"],
          "networkAccess": False, "excludeTmpdirEnvVar": True, "excludeSlashTmp": True}


def audit(value):
    if AUDIT_PORT:
        with socket.create_connection(("127.0.0.1", AUDIT_PORT), timeout=6) as stream:
            stream.sendall(json.dumps(value).encode() + b"\n")
            stream.recv(64)


def note(method, **params):
    send({"method": method, "params": params, "emittedAtMs": 1700000000000})


def persist():
    home = Path(os.environ["CODEX_HOME"])
    (home / "state_5.sqlite").write_bytes(b"opaque fixture database")
    sessions = home / "sessions/2026/10/20"
    sessions.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (sessions / ("rollout-2026-10-20T00-00-00-" + THREAD + ".jsonl")).open("ab") as out:
        out.write(b"opaque fixture rollout\n")


def completed(status="completed"):
    note("turn/completed", threadId=THREAD,
         turn={"id": TURN, "status": status, "items": [], "error": None})


def answer_events():
    item = {"type": "agentMessage", "id": "message-1", "text": ""}
    fields = {"threadId": THREAD, "turnId": TURN}
    note("turn/started", threadId=THREAD, turn={"id": TURN, "status": "inProgress", "items": []})
    note("item/started", **fields, item=item, startedAtMs=1700000000000)
    if CASE in ("wrong-thread", "early-wrong"):
        fields["threadId"] = "foreign-thread"
    if CASE == "wrong-turn":
        fields["turnId"] = "foreign-turn"
    note("item/agentMessage/delta", **fields,
         itemId="foreign-item" if CASE == "foreign-item" else "message-1", delta="Bounded answer.")
    note("item/completed", threadId=THREAD, turnId=TURN,
         item=dict(item, text="Bounded answer."), completedAtMs=1700000000001)
    completed("failed" if CASE == "failed-terminal" else "completed")
    if CASE == "duplicate-terminal":
        completed()


def held_answer():
    audit({"waiting": True})
    answer_events()


def model(name):
    return {"id": name, "model": name, "displayName": name, "description": "fixture",
            "hidden": False, "isDefault": True, "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [{"reasoningEffort": "medium", "description": "fixture"}]}


def send(value):
    print(json.dumps(value), flush=True)


def terminal():
    send({"method": "turn/completed", "emittedAtMs": 1700000000000,
          "params": {"threadId": "thread-1", "turn": {
              "id": "turn-1", "status": "completed", "items": [], "error": None}}})


if "--version" in sys.argv:
    print("codex-cli 0.163.0")
    raise SystemExit(0)

for line in sys.stdin:
    frame = json.loads(line)
    method, params = frame.get("method"), frame.get("params", {})
    if method == "fixture/codex-state":
        home = Path(os.environ["CODEX_HOME"])
        for name in (".sandbox_migration", "state_5.sqlite", "state_5.sqlite-wal", "logs_2.sqlite",
                     "goals_1.sqlite", "memories_1.sqlite", "queue_1.sqlite", "thread_history_1.sqlite"):
            (home / name).write_bytes(b"opaque")
        (home / "installation_id").write_text("00000000-0000-4000-8000-000000000002")
        (home / "installation_id").chmod(0o644)
        locks = home / "thread-writer-locks"
        locks.mkdir(mode=0o700, exist_ok=True)
        (locks / ".coordination.lock").touch(mode=0o600)
        if params.get("rollout", True):
            sessions = home / "sessions/2026/10/20"
            sessions.mkdir(mode=0o700, parents=True, exist_ok=True)
            (sessions / ("rollout-2026-10-20T00-00-00-" + params["thread"] + ".jsonl")).write_bytes(b"opaque")
        send({"id": frame["id"], "result": {}})
    elif method == "fixture/rotate-auth":
        (Path(os.environ["CODEX_HOME"]) / "auth.json").write_text('{"OPENAI_API_KEY":"synthetic-refreshed"}')
        send({"id": frame["id"], "result": {}})
    elif method == "fixture/auth-generation":
        auth = json.loads((Path(os.environ["CODEX_HOME"]) / "auth.json").read_bytes())
        send({"id": frame["id"], "result": {"refreshed": auth.get("OPENAI_API_KEY") == "synthetic-refreshed"}})
    elif method == "fixture/grow-codex-state":
        with (Path(os.environ["CODEX_HOME"]) / "state_5.sqlite").open("wb") as output:
            output.truncate(64 * 1024 * 1024 + 1)
        send({"id": frame["id"], "result": {}})
    elif method == "fixture/codex-many-entries":
        locks = Path(os.environ["CODEX_HOME"]) / "thread-writer-locks"
        locks.mkdir(mode=0o700, exist_ok=True)
        for i in range(4097):
            (locks / ("00000000-0000-4000-8000-" + str(i).zfill(12) + ".lock")).touch(mode=0o600)
        send({"id": frame["id"], "result": {}})
    elif method == "fixture/profile-isolation":
        home = Path(os.environ["CODEX_HOME"])
        readonly = False
        try:
            (home / "config.toml").write_text("bad")
        except OSError as error:
            readonly = error.errno == errno.EROFS
        (home / "tmp/alias").symlink_to("/opt/codex")
        send({"id": frame["id"], "result": {"readonly": readonly,
              "ambient_absent": "OPENAI_API_KEY" not in os.environ and "CODEX_CONFIG_FILE" not in os.environ,
              "scratch_separate": (home / "tmp/alias").is_symlink()}})
    elif method == "fixture/stream":
        send({"method": "item/agentMessage/delta", "emittedAtMs": 1700000000000,
              "params": {"threadId": "thread-1", "turnId": "turn-1",
                         "itemId": "item-1", "delta": "Early text"}})
        send({"id": 99, "method": "item/commandExecution/requestApproval", "params": {}})
        reply = json.loads(next(sys.stdin))
        send({"id": frame["id"], "result": {"saw_jsonrpc": "jsonrpc" in frame or "jsonrpc" in reply,
              "denied": reply.get("error", {}).get("code") == -32601, "additive": {"future": True}}})
        time.sleep(.02)
        terminal()
    elif method == "fixture/late-terminal":
        send({"id": frame["id"], "result": {}})
        terminal()
        assert not sys.stdin.read()
        terminal()
    elif method == "fixture/shutdown-request":
        send({"id": frame["id"], "result": {}})
        assert not sys.stdin.read()
        send({"id": 80, "method": "item/commandExecution/requestApproval", "params": {}})
    elif method == "fixture/envelope":
        raw = {
            "timestamp-bool": '{"method":"x","params":{},"emittedAtMs":true}',
            "timestamp-float": '{"method":"x","params":{},"emittedAtMs":1.5}',
            "timestamp-overflow": '{"method":"x","params":{},"emittedAtMs":9007199254740992}',
            "request-timestamp": '{"id":55,"method":"x","params":{},"emittedAtMs":1}',
            "jsonrpc": '{"jsonrpc":"2.0","method":"x","params":{}}',
            "duplicate-key": '{"method":"x","params":{},"params":{"secret":true}}',
            "unknown-envelope": '{"method":"x","params":{},"injected":true}',
            "mixed": '{"method":"x","params":{},"result":{}}',
            "depth": '{"method":"x","params":{"deep":' + '[' * 2000 + '0' + ']' * 2000 + '}}',
            "nan": '{"method":"x","params":{"usage":NaN}}',
        }[params["case"]]
        print(raw, flush=True)
    elif method == "fixture/bad-utf8":
        sys.stdout.buffer.write(b'{"method":"\xff","params":{}}\n')
        sys.stdout.buffer.flush()
    elif method == "fixture/unsolicited":
        send({"id": frame["id"], "result": {}})
        send({"id": "unasked", "result": {}})
    elif method == "fixture/flood":
        send({"id": frame["id"], "result": {}})
        for _ in range(params.get("count", 20001)):
            send({"method": "fixture/update", "params": {"text": "x" * params.get("size", 0)}})
    elif method == "fixture/ticker":
        send({"id": frame["id"], "result": {}})
        while True:
            send({"method": "fixture/update", "params": {}})
            time.sleep(.005)
    elif method == "fixture/nesting":
        print('{"id":' + json.dumps(frame["id"]) + ',"result":{"value":'
              + '[' * params["depth"] + '"{} \\" []"' + ']' * params["depth"] + '}}', flush=True)
    elif method == "fixture/oversized":
        send({"id": frame["id"], "result": {}})
        sys.stdout.write("x" * (16 * 1024 * 1024 + 1))
        sys.stdout.flush()
    elif method == "fixture/duplicate-request":
        send({"id": frame["id"], "result": {}})
        for _ in range(2):
            send({"id": "reused", "method": "fixture/denied", "params": {}})
            assert json.loads(next(sys.stdin))["error"]["code"] == -32601
    elif method == "fixture/exit":
        send({"id": frame["id"], "result": {}})
        os._exit(23)
    elif method == "fixture/terminal-exit":
        send({"id": frame["id"], "result": {}})
        terminal()
        raise SystemExit(0)
    elif method == "fixture/blocked":
        send({"id": frame["id"], "result": {}})
        time.sleep(20)
    elif method in ("initialize", "initialized", "model/list", "command/exec", "thread/start",
                    "thread/resume", "turn/start", "turn/interrupt"):
        audit({"method": method, "params": params})
        if method == "initialized":
            continue
        if method == "initialize":
            result = {"userAgent": "draft_conversation/" + ("0.999.0" if CASE == "wrong-version" else "0.163.0") + " (fixture)",
                      "codexHome": "/home/agent/.codex", "platformFamily": "unix", "platformOs": "linux"}
        elif method == "model/list":
            result = {"data": [model("gpt-5.4")], "nextCursor": None}
            if CASE == "missing-model":
                result["data"] = [model("another-model")]
            if CASE in ("model-pages", "model-loop"):
                result = {"data": [model("gpt-5.4" if not params.get("cursor") else "gpt-second")],
                          "nextCursor": "page-2" if CASE == "model-loop" or not params.get("cursor") else None}
        elif method == "command/exec":
            assert params["command"] == ["/usr/bin/true"] and params["sandboxPolicy"] == POLICY
            result = {"exitCode": 1 if CASE == "unsupported" else 0, "stdout": "", "stderr": ""}
        elif method in ("thread/start", "thread/resume"):
            assert params["cwd"] == "/tmp/project" and params["sandbox"] == "workspace-write"
            assert params["approvalPolicy"] == "never" and params["approvalsReviewer"] == "user"
            assert params["modelProvider"] == "openai"
            if method == "thread/resume":
                assert params["threadId"] == THREAD
                if CASE == "resume-refused":
                    send({"id": frame["id"], "error": {"code": -32600, "message": "resume refused"}})
                    continue
            result = {"thread": {"id": THREAD, "sessionId": THREAD, "cwd": "/tmp/project", "cliVersion": "0.163.0",
                      "createdAt": 1700000000, "updatedAt": 1700000000, "ephemeral": False, "turns": [],
                      "status": {"type": "idle"}, "source": "vscode", "preview": "", "projectId": None,
                      "modelProvider": "openai", "model": params["model"]},
                      "model": "different" if CASE == "wrong-model" else params["model"],
                      "modelProvider": "openai", "cwd": "/tmp/project", "approvalPolicy": "never",
                      "approvalsReviewer": "user", "sandbox": dict(POLICY)}
            if CASE == "wrong-policy":
                result["sandbox"]["networkAccess"] = True
        elif method == "turn/start":
            assert params["threadId"] == THREAD and params["sandboxPolicy"] == POLICY
            assert params["approvalPolicy"] == "never" and params["approvalsReviewer"] == "user"
            assert all(item["type"] == "text" and item["text_elements"] == [] for item in params["input"])
            persist()
            if CASE in ("edit", "edit-held", "forced-exit"):
                selected = Path("/tmp/project/example.txt")
                selected.write_bytes(b"revised text\n" if selected.read_bytes() == b"proposed text\n" else b"proposed text\n")
            if CASE == "lost-start":
                continue
            if CASE in ("early", "early-wrong"):
                answer_events()
            send({"id": frame["id"], "result": {"turn": {"id": TURN, "status": "inProgress", "items": []}}})
            if CASE == "callbacks":
                for index, method in enumerate(("item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                    "item/tool/requestUserInput", "item/permissions/requestApproval", "item/tool/call")):
                    send({"id": "callback-" + str(index), "method": method,
                          "params": {"threadId": THREAD, "turnId": TURN}})
                    reply = json.loads(next(sys.stdin))
                    assert reply.get("error", {}).get("code") == -32601
                audit({"client_denied": True})
            if CASE in ("early", "early-wrong", "cancel", "cancel-ack"):
                continue
            if CASE == "edit-held":
                threading.Thread(target=held_answer, daemon=True).start()
                continue
            answer_events()
            if CASE == "forced-exit":
                time.sleep(20)
            continue
        else:
            assert params == {"threadId": THREAD, "turnId": TURN}
            send({"id": frame["id"], "result": {}})
            if CASE != "cancel-ack":
                completed("interrupted")
            continue
        send({"id": frame["id"], "result": result})
    else:
        send({"id": frame["id"], "result": {}})

if CASE == "late-terminal":
    completed()
audit({"exiting": True})
