#!/usr/bin/python3
"""Deterministic Codex wire faults; only run in a disposable test namespace."""
import errno
import json
import os
from pathlib import Path
import sys
import time


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
    else:
        send({"id": frame["id"], "result": {}})
