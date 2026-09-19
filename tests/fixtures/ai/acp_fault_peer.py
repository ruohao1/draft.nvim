#!/usr/bin/python3
"""Scripted ACP faults. Run only in the test's disposable PID/mount namespace."""
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def listener():
    stream = socket.socket()
    stream.bind(("127.0.0.1", 0))
    stream.listen()
    return stream


stubborn = False


for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "fixture/malformed":
        print("not JSON: fixture-secret-must-not-escape", flush=True)
    elif request.get("method") == "fixture/wrong-version":
        print(json.dumps({"jsonrpc": "1.0", "id": request["id"], "result": {}}), flush=True)
    elif request.get("method") == "fixture/envelope":
        identifier = json.dumps(request["id"])
        tail = {
            "duplicate-key": '"result":{},"result":{"injected":true}',
            "nan": '"result":{"usage":NaN}',
            "overflow": '"result":{"usage":1e9999}',
            "both": '"result":{},"error":{"code":-1,"message":"fixture-secret"}',
            "result-array": '"result":[]',
            "error-string": '"error":"fixture-secret"',
            "error-bool-code": '"error":{"code":true,"message":"fixture-secret"}',
            "method-array": '"method":[],"params":{}',
            "params-array": '"method":"fs/write_text_file","params":[]',
            "mixed": '"method":"fs/write_text_file","params":{},"result":{}',
        }[request["params"]["case"]]
        print('{"jsonrpc":"2.0","id":' + identifier + ',' + tail + '}', flush=True)
    elif request.get("method") in ("fixture/stall", "session/close"):
        stubborn = True
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        held = listener()
        Path("example.txt").write_bytes(b"unapproved mutable edit\n")
        send({"method": "fixture/ready", "params": {"port": held.getsockname()[1]}})
        if request["method"] == "session/close":
            send({"id": request["id"], "result": {}})
    elif request.get("method") == "session/cancel":
        pass  # Deliberately ignored; EOF and TERM will be ignored too.
    elif request.get("method") == "fixture/await-cancel":
        pending = request["id"]
        cancel = json.loads(next(sys.stdin))
        assert cancel == {"jsonrpc": "2.0", "method": "session/cancel",
                          "params": {"sessionId": "fixture-session"}}
        send({"id": pending, "result": {"stopReason": "cancelled"}})
    elif request.get("method") == "fixture/descendant":
        held = listener()
        port = held.getsockname()[1]
        if os.fork() == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            # Keep stdout and the listener open, independently of the ACP peer.
            while True:
                Path("example.txt").write_bytes(b"detached descendant edit\n")
                time.sleep(.02)
        held.close()
        send({"id": request["id"], "result": {"port": port}})
    elif request.get("method") == "fixture/duplicate":
        for _ in range(2):
            send({"id": request["id"], "result": {"stopReason": "end_turn"}})
    elif request.get("method") == "fixture/late":
        send({"id": request["id"], "result": {"stopReason": "end_turn"}})
        assert not sys.stdin.read()
        send({"id": request["id"], "result": {"stopReason": "end_turn"}})
    elif request.get("method") == "fixture/duplicate-request":
        for _ in range(2):
            send({"id": "reused", "method": "fs/write_text_file", "params": {}})
            assert json.loads(next(sys.stdin))["error"]["code"] == -32601
        send({"id": request["id"], "result": {}})
    elif request.get("method") == "fixture/wrong-id":
        send({"id": "another-worker", "result": {"stopReason": "end_turn"}})
    elif request.get("method") == "fixture/exit":
        os._exit(23)
    elif request.get("method") == "fixture/budget":
        case = request["params"]["case"]
        if case == "frame":
            sys.stdout.write("x" * (16 * 1024 * 1024 + 1))
            sys.stdout.flush()
        elif case == "messages":
            for _ in range(20001):
                send({"method": "fixture/update", "params": {}})
        else:
            for _ in range(4):
                send({"method": "fixture/update", "params": {"text": "x" * (9 * 1024 * 1024)}})
    elif request.get("method") == "fixture/blocked-input":
        send({"id": request["id"], "result": {}})
        while True:
            time.sleep(1)
    elif request.get("method") == "fixture/blocked-reply":
        send({"id": "client", "method": "fixture/client", "params": {}})
        while True:
            time.sleep(1)
    elif request.get("method") == "fixture/client-operations":
        for index, method in enumerate(("fs/write_text_file", "terminal/create")):
            send({"id": index, "method": method, "params": {"path": request["params"]["outside"],
                  "content": "unreviewed", "command": "must-not-run"}})
            assert json.loads(next(sys.stdin))["error"]["code"] == -32601
        send({"id": request["id"], "result": {"denied": 2}})
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}), flush=True)

while stubborn:
    time.sleep(1)
