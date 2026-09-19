#!/usr/bin/python3
"""Crash-test peer; only run inside the disposable staging PID namespace."""
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time


def listener():
    stream = socket.socket()
    stream.bind(("127.0.0.1", 0))
    stream.listen()
    return stream


request = json.loads(next(sys.stdin))
store = Path("/tmp/backend-state")
for name, content in (("opencode.db", b"opaque\n"), ("opencode.db-wal", b"wal\n"),
                      ("opencode.db-shm", b"shm\n")):
    (store / name).write_bytes(content)  # Synthetic files, never SQLite databases.

if request["method"] == "fixture/idle":
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                      "result": {"stopReason": "end_turn"}}), flush=True)
    sys.stdin.read()
    sys.exit(0)

signal.signal(signal.SIGTERM, signal.SIG_IGN)
direct, detached = listener(), listener()
ready_read, ready_write = os.pipe()
if os.fork() == 0:
    os.close(ready_read)
    direct.close()
    os.setsid()
    Path("example.txt").write_bytes(b"unapproved descendant edit\n")
    os.write(ready_write, b"1")
    os.close(ready_write)
    with Path("example.txt").open("r+b", buffering=0) as selected:
        while True:
            selected.seek(0)
            selected.write(b"unapproved descendant edit\n")
            time.sleep(.02)

os.close(ready_write)
assert os.read(ready_read, 1) == b"1"
os.close(ready_read)
ports = [direct.getsockname()[1], detached.getsockname()[1]]
detached.close()
print(json.dumps({"jsonrpc": "2.0", "method": "fixture/ready", "params": {"ports": ports}}), flush=True)
if request["method"] == "fixture/stopping":
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                      "result": {"stopReason": "end_turn"}}), flush=True)
# Both processes ignore TERM, and the descendant holds stdout.
for line in sys.stdin:
    pass  # Ignore cancellation as well.
Path("eof-seen").write_bytes(b"1")
while True:
    time.sleep(1)
