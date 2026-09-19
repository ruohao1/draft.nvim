#!/usr/bin/env python3
"""One trusted editor/controller lifetime; ACP workers are created by explicit turns."""
import argparse
from collections import deque
import importlib.util
import os
from pathlib import Path
import select
import sys


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


protocol = helper("nvim-ai-conversation-protocol")
review = helper("nvim-ai-review")
storage = helper("nvim-ai-conversation-store")
turns = helper("nvim-ai-conversation-turn")
FAILURES = (OSError, ValueError, RuntimeError, turns.staging.Refused)


def configuration(path):
    value = protocol.decode_json(review._private_bytes(path, protocol.MAX_COMMAND))
    if (not isinstance(value, dict) or not {"opencode", "bwrap", "model"} <= value.keys()
            or set(value) - {"opencode", "bwrap", "model", "auth_file", "provider"}
            or not protocol.model(value["model"])
            or not all(protocol.path(value[key], True) for key in ("opencode", "bwrap"))
            or ("auth_file" in value and not protocol.path(value["auth_file"], True))
            or ("provider" in value and (not isinstance(value["provider"], dict)
                 or set(value["provider"]) != {value["model"].split("/", 1)[0]}))):
        raise protocol.Refused("Invalid trusted controller configuration")
    return value


class Controller:
    def __init__(self, config, pipe):
        self.config, self.pipe = config, pipe
        self.binding = protocol.Binding()
        self.store = self.turn = self.active = None
        self.sequence = 0
        self.closing = False
        self.inbox = deque()

    def collect(self):
        for frame in self.pipe.read_ready():
            if self.binding.accept(frame):
                self.inbox.append(frame)
        if len(self.inbox) > 64:
            raise protocol.Refused("Editor command queue budget exceeded")

    def write_wait(self):
        self.collect()
        return self.pipe.eof or any(frame["command"]["kind"] in ("cancel", "close") for frame in self.inbox)

    def failed(self):
        events = self.turn.fail()
        if not self.pipe.eof and not any(frame["command"]["kind"] in ("cancel", "close") for frame in self.inbox):
            for event in events:
                self.emit(event)

    def emit(self, event):
        self.sequence += 1
        event.update({key: self.active["command"][key] for key in protocol.IDENTITIES})
        event["sequence"] = self.sequence
        self.pipe.enqueue(self.active["serial"], event)

    def cleanup(self):
        if self.turn is not None and not self.turn.done:
            self.turn.fail()
        if self.store is not None:
            self.store.close()

    def dispatch(self, frame):
        if self.closing:
            raise protocol.Refused("Command follows controller close")
        command = frame["command"]
        if command["kind"] == "close":
            self.cleanup()
            self.active = frame
            self.emit(dict(kind="closed", stopped=True, cleaned=True, tokens_retired=True))
            self.closing = True
        elif command["kind"] == "start":
            if self.turn is not None and (not self.turn.done or not self.turn.store_valid):
                raise protocol.Refused("Prior turn does not authorize another worker")
            self.active = frame
            if self.store is None:
                self.store = storage.Store()
            self.turn = turns.Turn(self.config, self.store, self.pipe)
            self.turn.on_write_wait = self.write_wait
            try:
                self.turn.start(command)
            except FAILURES:
                self.failed()
        elif command["kind"] == "cancel":
            if self.turn is None:
                raise protocol.Refused("No turn can be cancelled")
            self.active = frame
            try:
                events = self.turn.cancel()
            except FAILURES:
                events = self.turn.fail()
            for event in events:
                self.emit(event)
        else:
            raise protocol.Refused("Conversation command is not available")

    def run(self):
        try:
            while True:
                self.collect()
                while self.inbox:
                    self.dispatch(self.inbox.popleft())
                if self.pipe.eof and not self.closing:
                    return 0
                if self.turn is not None and not self.turn.done:
                    try:
                        events = self.turn.advance()
                    except FAILURES:
                        self.failed()
                        events = []
                    for event in events:
                        self.emit(event)
                self.pipe.flush_ready()
                if self.closing and not self.pipe.writing:
                    return 0
                # Worker.poll already supplies the bounded wait for active
                # turns. Sleeping again here delays every 64-message batch.
                pause = 0 if self.inbox or (self.turn is not None and not self.turn.done) else .05
                select.select([] if self.pipe.eof else [self.pipe.input],
                              [self.pipe.output] if self.pipe.writing else [], [], pause)
        finally:
            self.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = configuration(args.config)
        return Controller(config, protocol.EditorPipe(sys.stdin.fileno(), sys.stdout.fileno())).run()
    except FAILURES:
        print("Draft conversation failed; explicit recovery required.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
