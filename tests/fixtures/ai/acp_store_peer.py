#!/usr/bin/python3
"""Store metadata fixture in Bubblewrap. These opaque files are NOT SQLite DBs."""
import json
import signal
from pathlib import Path
import sys
import time


store = Path("/tmp/backend-state")
stubborn = False
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "fixture/create-state":
        (store / "opencode.db").write_bytes(b"opaque\n")
        (store / "opencode.db-wal").write_bytes(b"wal\n")
        (store / "opencode.db-shm").write_bytes(b"shm\n")
        result = {"stopReason": "end_turn"}
    elif request["method"] == "fixture/grow-and-stall":
        with (store / "opencode.db").open("wb") as opaque:
            opaque.truncate(64 * 1024 * 1024 + 1)
        sys.stdin.read()  # No ACP output: monitoring must not depend on messages.
        break
    elif request["method"] == "fixture/combined-budget":
        (store / "opencode.db").write_bytes(b"opaque\n")
        for name in ("opencode.db-wal", "opencode.db-shm"):
            with (store / name).open("wb") as opaque:
                opaque.truncate(32 * 1024 * 1024)
        result = {"stopReason": "end_turn"}
    elif request["method"] == "fixture/ignore-eof":
        (store / "opencode.db").write_bytes(b"opaque\n")
        stubborn = True
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        result = {"stopReason": "end_turn"}
    elif request["method"] == "fixture/check-isolation":
        result = {"host_visible": any(Path(value).exists() for value in request["params"]["paths"])}
    else:
        result = {"names": sorted(entry.name for entry in store.iterdir())}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)

while stubborn:
    time.sleep(1)
