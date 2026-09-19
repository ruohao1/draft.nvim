"""Trusted-pipe fixture only: no ACP worker, store, proposal or project writer."""
import json
import os
import signal
import sys
import time

mode = sys.argv[1]
if mode == "epipe":
    os.close(0)
    os.close(1)
    time.sleep(.5)
    sys.exit(0)

previous = None

for line in sys.stdin.buffer:
    frame = json.loads(line)
    command = frame["command"]
    sequence = 0
    mode = sys.argv[1]
    if mode in ("bad-json", "duplicate", "escaped-duplicate", "wrong-version", "future", "extra", "deep", "oversize", "truncated", "nan", "utf8"):
        envelope = {"version": 1, "serial": frame["serial"], "event": dict(
            {key: command[key] for key in (
                "conversation_id", "owner_generation", "turn_id", "worker_generation")},
            kind="submitted", sequence=1, model=command["model"])}
        if mode == "wrong-version":
            envelope["version"] = 2
        if mode == "future":
            envelope["serial"] += 1
        if mode == "extra":
            envelope["unexpected"] = True
        raw = json.dumps(envelope)
        if mode == "bad-json":
            raw = "{bad"
        elif mode == "duplicate":
            raw = raw.replace('"version": 1', '"version": 99, "version": 1')
        elif mode == "escaped-duplicate":
            raw = raw.replace('"version": 1', '"versi\\u006fn": 99, "version": 1')
        elif mode == "nan":
            raw = raw.replace('"sequence": 1', '"sequence": NaN')
        elif mode == "utf8":
            sys.stdout.buffer.write(raw.replace('"fixture/model"', '"fixture/INVALID"').encode().replace(b"INVALID", b"\xff") + b"\n")
            sys.stdout.flush()
            sys.stdin.buffer.read()
            break
        elif mode == "deep":
            raw = "[" * 200 + "0" + "]" * 200
        elif mode == "oversize":
            raw = '"' + "x" * (8 * 1024 * 1024)
        elif mode == "truncated":
            sys.stdout.write(raw[:20])
            sys.stdout.flush()
            break
        print(raw, flush=True)
        sys.stdin.buffer.read()  # Adapter must close its input on a pipe fault.
        break

    def emit(kind, **fields):
        global sequence
        sequence += 1
        event = {key: command[key] for key in (
            "conversation_id", "owner_generation", "turn_id", "worker_generation")}
        event.update(kind=kind, sequence=sequence, **fields)
        print(json.dumps({"version": 1, "serial": frame["serial"], "event": event}), flush=True)

    if command["kind"] == "start":
        if mode in ("byte-flood", "event-flood"):
            emit("submitted", model=command["model"])
            stale = dict({key: command[key] for key in (
                "conversation_id", "owner_generation", "turn_id", "worker_generation")},
                kind="text", sequence=1, text="x" * (4096 if mode == "byte-flood" else 1))
            data = (json.dumps({"version": 1, "serial": frame["serial"], "event": stale}) + "\n").encode()
            try:
                for _ in range(21000):
                    sys.stdout.buffer.write(data)
                sys.stdout.flush()
                sys.stdin.buffer.read()
            except BrokenPipeError:
                pass
            break
        if mode == "fragmented":
            def emit(kind, **fields):
                global sequence
                sequence += 1
                event = {key: command[key] for key in (
                    "conversation_id", "owner_generation", "turn_id", "worker_generation")}
                event.update(kind=kind, sequence=sequence, **fields)
                data = (json.dumps({"version": 1, "serial": frame["serial"], "event": event},
                                   ensure_ascii=False) + "\n").encode()
                for index in range(0, len(data), 7):
                    sys.stdout.buffer.write(data[index:index + 7])
                    sys.stdout.flush()
        if mode == "cancel-stale":
            emit("submitted", model=command["model"])
            previous = frame
            continue
        if mode == "exit-on-eof":
            emit("submitted", model=command["model"])
            if sys.stdin.buffer.read() == b"":
                with open(sys.argv[2], "x", encoding="utf-8") as observed:
                    observed.write("editor EOF observed\n")
            break
        if mode == "silent":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(1)
            break
        if mode == "eof-alive":
            os.close(1)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(1)
            break
        if sys.argv[1] == "crash":
            sys.exit(7)
        emit("submitted", model=command["model"])
        if mode == "nested":
            time.sleep(.02)
        emit("text", text="Fixture answer: " + command["message"])
        emit("stopping")
        if mode == "review-crash":
            emit("settled", outcome="review", stopped=True, graceful=True, store_valid=True,
                 proposal={"token": "fixture-token", "source_generation": command["turn_id"],
                           "files": [{"path": "example.txt", "state": "pending"}]})
            time.sleep(.05)
            sys.exit(7)
        emit("settled", outcome="answer", stopped=True, graceful=True, store_valid=True)
        if mode == "held-output":
            if os.fork() == 0:
                # Bounded fixture child; never signal unrelated processes.
                time.sleep(.8)
                os._exit(0)
            break
        if sys.argv[1] == "idle-crash":
            time.sleep(.05)
            sys.exit(7)
    elif command["kind"] == "close":
        if mode == "close-burst":
            stale = json.dumps({"version": 1, "serial": frame["serial"] - 1, "event": {}}) + "\n"
            sys.stdout.write(stale * 100)
        emit("closed", stopped=True, cleaned=True, tokens_retired=True)
        if sys.argv[1] == "false-close":
            sys.exit(7)
        if mode == "close-trailing":
            print("untrusted trailing bytes", flush=True)
        if mode == "close-alive":
            os.close(1)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(1)
        break
    elif command["kind"] == "cancel":
        # Same semantic turn/worker, wrong command serial: must not restore review.
        stale = {key: previous["command"][key] for key in (
            "conversation_id", "owner_generation", "turn_id", "worker_generation")}
        stale.update(kind="settled", sequence=999, outcome="review", stopped=True,
                     graceful=True, store_valid=True, proposal={"token": "old-token",
                     "source_generation": command["turn_id"], "files": [{
                         "path": "example.txt", "state": "pending"}]})
        print(json.dumps({"version": 1, "serial": previous["serial"], "event": stale}), flush=True)
        emit("cancelled", stopped=True, graceful=True, store_valid=True,
             tokens_retired=True, cancel_confirmed=True)
