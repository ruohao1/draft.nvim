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
reviews = helper("nvim-ai-conversation-review")
FAILURES = (OSError, ValueError, RuntimeError, turns.staging.Refused, reviews.staging.Refused)


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
        self.inbox_bytes = 0
        self.session = None
        self.transcript_bytes = 0
        self.reviews = None
        self.stopping_sent = False

    def collect(self):
        for frame in self.pipe.read_ready():
            if self.binding.accept(frame):
                self.inbox.append(frame)
                self.inbox_bytes += frame.wire_bytes
        if len(self.inbox) > 64:
            raise protocol.Refused("Editor command queue budget exceeded")
        if self.inbox_bytes + len(getattr(self.pipe, "buffer", b"")) > protocol.MAX_PENDING:
            raise protocol.Refused("Editor pending input budget exceeded")

    def write_wait(self):
        self.collect()
        self.pipe.check_deadline()
        return self.pipe.eof or any(frame["command"]["kind"] in ("cancel", "close") for frame in self.inbox)

    def failed(self):
        events = self.turn.fail()
        if (self.active["command"]["kind"] == "revise" and self.turn.stopped
                and self.turn.graceful and self.turn.store_valid and events[-1].get("tokens_retired")):
            try:
                events[-1].update(self.reviews.restore_revision())
                events[-1].pop("tokens_retired", None)
            except FAILURES:
                pass  # Missing positive evidence must remain recovery-required.
        if not self.pipe.eof and not any(frame["command"]["kind"] in ("cancel", "close") for frame in self.inbox):
            for event in events:
                self.emit(event)

    def emit(self, event):
        if event["kind"] == "stopping":
            if self.stopping_sent:
                return
            self.stopping_sent = True
        if event["kind"] == "settled" and event["outcome"] == "review":
            if self.active["command"]["kind"] == "revise":
                event.update(self.reviews.finish_revision(self.turn.frozen, self.active["command"]["turn_id"]))
            else:
                event.update(self.reviews.install(self.turn.frozen, self.active["command"]["turn_id"]))
            self.turn.task = None  # The registry now owns this stopped, frozen task.
        if event["kind"] == "cancelled" and self.reviews is not None and self.reviews.current is not None:
            event.update(self.reviews.retire_all(), candidates_retired=True)
        if event["kind"] == "text":
            self.transcript_bytes += len(event["text"].encode())
            if self.transcript_bytes > protocol.MAX_OUTPUT:
                raise protocol.Refused("Conversation transcript budget exceeded")
        self.sequence += 1
        event.update({key: self.active["command"][key] for key in protocol.IDENTITIES})
        event["sequence"] = self.sequence
        self.pipe.enqueue(self.active["serial"], event)

    def cleanup(self):
        if self.turn is not None and (not self.turn.done or self.turn.task is not None):
            self.turn.fail()
        try:
            retirement = self.reviews.retire_all() if self.reviews is not None else {}
        finally:
            if self.store is not None:
                self.store.close()
        return retirement

    def dispatch(self, frame):
        if self.closing:
            raise protocol.Refused("Command follows controller close")
        command = frame["command"]
        if command["kind"] == "close":
            retirement = self.cleanup()
            self.active = frame
            self.emit(dict(kind="closed", stopped=True, cleaned=True, tokens_retired=True,
                           **({'writer_stopped': True, 'candidates_retired': True, **retirement} if self.turn else {})))
            self.closing = True
        elif command["kind"] in ("start", "revise"):
            if command["kind"] == "start" and self.reviews is not None and self.reviews.current is not None:
                raise protocol.Refused("An independent turn cannot bypass pending review")
            if self.turn is not None and (not self.turn.done or not self.turn.store_valid):
                raise protocol.Refused("Prior turn does not authorize another worker")
            self.active = frame
            self.stopping_sent = False
            self.transcript_bytes += len(command["message"].encode())
            if command["turn_id"] > 64 or self.transcript_bytes > protocol.MAX_OUTPUT:
                raise protocol.Refused("Conversation turn or transcript budget exceeded")
            if self.store is None:
                self.store = storage.Store()
                self.reviews = reviews.ReviewRegistry(command["root"], command["selection"])
            if self.turn is not None and self.turn.store_valid:
                self.session = self.turn.session
            self.turn = turns.Turn(self.config, self.store, self.pipe, session=self.session)
            self.turn.on_write_wait = self.write_wait
            try:
                selected = self.reviews.begin_revision(command) if command["kind"] == "revise" else None
                self.turn.start(command, selected=selected, context=self.reviews.context)
            except FAILURES:
                self.failed()
        elif command["kind"] == "cancel":
            if self.turn is None:
                raise protocol.Refused("No turn can be cancelled")
            self.active = frame
            if self.turn.done and self.reviews.current is not None:
                retirement = self.reviews.retire_all()
                self.emit(dict(kind="cancelled", stopped=True, graceful=True, store_valid=self.turn.store_valid,
                               tokens_retired=True, candidates_retired=True, **retirement))
                return
            try:
                events = self.turn.cancel()
            except FAILURES:
                events = self.turn.fail()
            for event in events:
                self.emit(event)
        elif command["kind"] == "decide":
            if self.turn is None or not self.turn.done:
                raise protocol.Refused("A live turn cannot receive publication evidence")
            self.active = frame
            self.emit(dict(kind="decided", receipt=self.reviews.receipt(command)))
        else:
            raise protocol.Refused("Conversation command is not available")

    def run(self):
        try:
            while True:
                self.collect()
                if self.pipe.eof or any(frame["command"]["kind"] == "close" for frame in self.inbox):
                    # Admission of owner loss fences all queued generation.
                    self.inbox = deque(frame for frame in self.inbox if frame["command"]["kind"] == "close")
                    self.inbox_bytes = sum(frame.wire_bytes for frame in self.inbox)
                while self.inbox:
                    frame = self.inbox.popleft()
                    self.inbox_bytes -= frame.wire_bytes
                    self.dispatch(frame)
                if self.pipe.eof and not self.closing:
                    return 0
                if self.turn is not None and not self.turn.done:
                    try:
                        events = self.turn.advance()
                    except FAILURES:
                        self.failed()
                        events = []
                    for event in events:
                        try:
                            self.emit(event)
                        except FAILURES:
                            if event["kind"] != "settled" or event.get("outcome") != "review":
                                raise
                            self.failed()
                            break
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
