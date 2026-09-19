#!/usr/bin/python3
"""Credential-free ACP peer; tests run this executable inside real Bubblewrap."""
import json
import os
from pathlib import Path
import re
import socket
import sys
import time


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)


def answer(identifier, result):
    send({"id": identifier, "result": result})


for line in sys.stdin:
    message = json.loads(line)
    method, identifier = message.get("method"), message.get("id")
    if method == "initialize":
        assert message["params"]["clientCapabilities"]["fs"]["writeTextFile"] is False
        assert "NVIM_STAGED_SENTINEL" not in os.environ
        answer(identifier, {"protocolVersion": 1, "agentInfo": {"name": "fixture", "version": "1.18.30"}})
    elif method == "session/new":
        assert message["params"]["mcpServers"] == []
        answer(identifier, {"sessionId": "fixture-session"})
    elif method == "session/prompt":
        prompt = message["params"]["prompt"][0]["text"]
        prefix = "Edit only these selected paths (JSON): "
        if prompt.startswith(prefix):
            paths = [Path(value) for value in json.JSONDecoder().raw_decode(prompt[len(prefix):])[0]]
        else:
            paths = [Path(re.search(r"Edit only (.+?)\. This is", prompt)[1])]
        path = paths[0]
        case = re.findall(r"TEST:(\S+)", prompt)[-1]
        before = path.read_text()
        if case == "auth":
            credentials = json.loads(Path("/tmp/agent/data/opencode/auth.json").read_text())
            assert credentials == {"fixture": {"type": "api", "key": "fixture-secret"}}
        if case == "stall":
            port = re.search(r"STALL_PORT:(\d+)", prompt)
            if port:
                with socket.create_connection(("127.0.0.1", int(port[1])), timeout=2) as connection:
                    connection.sendall(b"R")
            time.sleep(30)
        if case == "unchanged":
            answer(identifier, {"stopReason": "end_turn"})
            continue
        if case == "bad-json":
            print("not json", flush=True)
            time.sleep(30)
        edited = paths[:1] if case == "multi-one" else paths
        if case.startswith("refine"):
            assert all(target.read_text().startswith("approved edit\n") for target in paths)
            if case == "refine-one":
                assert len(paths) == 1
                assert [p for p in Path("/tmp/project").rglob("*") if p.is_file()] == paths
        after = {target: target.read_text() + "refined\n" if case.startswith("refine")
                 else "approved edit\n" for target in edited}
        if case == "refine-revert":
            after = {target: {"first.txt": "first original\n", "second.txt": "second original\n"}.get(
                target.name, "original text\n") for target in edited}
        diffs = [{"type": "diff", "path": str(target), "oldText": target.read_text(),
                  "newText": after[target]} for target in edited]
        if case == "multi-permission":
            send({"id": "outside", "method": "session/request_permission", "params": {
                "sessionId": "fixture-session", "toolCall": {"kind": "edit", "content": diffs + [
                    {"type": "diff", "path": "/tmp/project/not-selected.txt", "newText": "unreviewed\n"}]},
                "options": [{"kind": "allow_once", "optionId": "once"}]}})
            assert json.loads(next(sys.stdin))["result"]["outcome"]["outcome"] == "cancelled"
        send({"id": "permission", "method": "session/request_permission", "params": {
            "sessionId": "fixture-session", "toolCall": {"kind": "edit", "content": diffs},
            "options": [{"kind": "allow_once", "optionId": "once"}]}})
        permission = json.loads(next(sys.stdin))
        assert permission["result"]["outcome"]["optionId"] == "once"
        # Even a rogue fs request must not write the real project or be accepted.
        send({"id": "write", "method": "fs/write_text_file", "params": {
            "path": "/tmp/not-the-staging-file", "content": "unreviewed\n"}})
        assert json.loads(next(sys.stdin))["error"]["code"] == -32601
        for target in edited:
            target.write_text(after[target])
        if case in ("extra", "multi-extra"):
            (path.parent / "unreviewed.txt").write_text("extra\n")
        elif case == "symlink":
            path.unlink()
            path.symlink_to("/etc/hosts")
        elif case in ("delete", "multi-delete"):
            paths[-1].unlink()
        elif case in ("mode", "multi-mode"):
            paths[-1].chmod(0o755)
        elif case == "binary":
            path.write_bytes(b"unsafe\x00text\n")
        elif case == "direct":
            outside = re.search(r"OUTSIDE:(\S+)", prompt)[1]
            try:
                Path(outside).write_text("bypass\n")
            except OSError:
                pass
            else:
                raise AssertionError("Real project was reachable from the agent")
        elif case == "permission":
            send({"id": "bash", "method": "session/request_permission", "params": {
                "toolCall": {"kind": "execute", "content": []},
                "options": [{"kind": "allow_once", "optionId": "once"}]}})
            assert json.loads(next(sys.stdin))["result"]["outcome"]["outcome"] == "cancelled"
        elif case == "background" and os.fork() == 0:
            for descriptor in (0, 1, 2):
                os.close(descriptor)
            time.sleep(2)
            port = re.search(r"BACKGROUND_PORT:(\d+)", prompt)
            if port:
                with socket.create_connection(("127.0.0.1", int(port[1])), timeout=2) as connection:
                    connection.sendall(b"background child survived")
            path.write_text("late unreviewed edit\n")
            os._exit(0)
        answer(identifier, {"stopReason": "end_turn"})
