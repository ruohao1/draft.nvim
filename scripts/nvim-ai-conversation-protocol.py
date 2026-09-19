"""Bounded, closed editor/controller protocol; no ACP or filesystem authority."""
from collections import deque
import json
import math
import os
import re
import time


MAX_COMMAND = 1024 * 1024
MAX_PENDING = 2 * 1024 * 1024
MAX_OUTPUT = 32 * 1024 * 1024
MAX_EVENT = 8 * 1024 * 1024
MAX_EVENTS = 20000
MAX_INTEGER = 2 ** 53 - 1
IDENTITIES = ("conversation_id", "owner_generation", "turn_id", "worker_generation")
REVIEW = {"round_id", "proposal_revision", "proposal_token", "receipt_sequence"}
COMMON = {"kind", *IDENTITIES, "root", "selection", "model"}


class Refused(RuntimeError):
    """Trusted, content-free protocol diagnostic."""


def integer(value, minimum=0):
    return type(value) is int and minimum <= value <= MAX_INTEGER


def path(value, absolute=False):
    return (isinstance(value, str) and 0 < len(value.encode()) <= 4096
            and value.startswith("/") == absolute
            and not any(ord(char) < 32 or ord(char) == 127 for char in value)
            and 1 <= len(value.lstrip("/").split("/")) <= 64
            and all(part not in ("", ".", "..") for part in
                    (value[1:] if absolute else value).split("/")))


def model(value):
    return (isinstance(value, str) and len(value.encode()) <= 256
            and re.fullmatch(r"[a-zA-Z0-9_.-]+/[^\s\x00-\x1f\x7f]+", value) is not None)


def opaque(value):
    return isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9_-]{1,128}", value) is not None


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate key")
        result[key] = value
    return result


def _number(text):
    number = float(text)
    if not math.isfinite(number):
        raise ValueError("Non-finite number")
    return number


def _lex(text):
    cursor, depth, tokens = 0, 0, 0
    while cursor < len(text):
        char = text[cursor]
        if char.isspace():
            cursor += 1
            continue
        tokens += 1
        if tokens > 8192:
            raise Refused("Editor JSON token budget exceeded")
        cursor += 1
        if char == '"':
            while cursor < len(text):
                char = text[cursor]
                cursor += 1
                if char == '"':
                    break
                if char == "\\":
                    cursor += 1
        elif char in "[{":
            depth += 1
            if depth > 32:
                raise Refused("Editor JSON depth budget exceeded")
        elif char in "]}":
            depth -= 1
        elif char not in ",:":
            while cursor < len(text) and not text[cursor].isspace() and text[cursor] not in '{}[],:"':
                cursor += 1


def decode_json(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_COMMAND:
        raise Refused("Editor frame budget exceeded")
    try:
        text = raw.decode("utf-8")
        _lex(text)
        value = json.loads(text, object_pairs_hook=_object, parse_float=_number,
                           parse_constant=_number)
        remaining = [value]
        while remaining:
            item = remaining.pop()
            if isinstance(item, str):
                item.encode("utf-8")  # JSON escapes must not introduce lone surrogates.
            elif isinstance(item, dict):
                remaining.extend(item.keys())
                remaining.extend(item.values())
            elif isinstance(item, list):
                remaining.extend(item)
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise Refused("Malformed editor JSON") from None


def _review(value):
    return (integer(value.get("round_id"), 1) and integer(value.get("proposal_revision"), 1)
            and opaque(value.get("proposal_token")) and integer(value.get("receipt_sequence")))


def validate_command(command):
    if not isinstance(command, dict) or not COMMON <= command.keys():
        raise Refused("Incomplete editor command")
    kind, selected = command["kind"], command["selection"]
    if (kind not in ("start", "revise", "decide", "cancel", "close")
            or not isinstance(command["conversation_id"], str)
            or re.fullmatch(r"[a-f0-9]{32}", command["conversation_id"]) is None
            or not integer(command["owner_generation"], 1)
            or not integer(command["turn_id"]) or not integer(command["worker_generation"])
            or not path(command["root"], True) or not model(command["model"])
            or not isinstance(selected, list) or not 1 <= len(selected) <= 16
            or not all(path(item) for item in selected) or len(set(selected)) != len(selected)):
        raise Refused("Invalid editor command binding")
    allowed = set(COMMON)
    has_review = bool(REVIEW & command.keys())
    if kind in ("decide", "revise") or has_review:
        if not _review(command):
            raise Refused("Invalid editor review identity")
        allowed |= REVIEW
    if kind in ("start", "revise"):
        allowed |= {"message", "sources"}
        message, sources = command.get("message"), command.get("sources")
        if (not isinstance(message, str) or not 0 < len(message.encode()) <= 32768
                or not message.strip() or any(ord(char) < 32 and char not in "\n\t"
                                              or ord(char) == 127 for char in message)
                or not isinstance(sources, list) or len(sources) != len(selected)):
            raise Refused("Invalid editor submission")
        for name, item in zip(selected, sources):
            if (not isinstance(item, dict) or set(item) != {"path", "snapshot_sha256"}
                    or item["path"] != name or not isinstance(item["snapshot_sha256"], str)
                    or re.fullmatch(r"[a-f0-9]{64}", item["snapshot_sha256"]) is None):
                raise Refused("Invalid captured source binding")
    if kind == "start" and has_review:
        raise Refused("Independent start cannot carry review authority")
    if kind == "revise":
        allowed.add("context")
        context = command.get("context")
        if (not isinstance(context, dict) or set(context) != REVIEW | {"files"}
                or any(context[key] != command[key] for key in REVIEW)
                or not isinstance(context["files"], list) or len(context["files"]) != len(selected)):
            raise Refused("Invalid review context")
        for name, item in zip(selected, context["files"]):
            if (not isinstance(item, dict) or set(item) != {"path", "state"}
                    or item["path"] != name or item["state"] not in
                    ("pending", "accepted", "rejected", "unchanged", "cancelled")):
                raise Refused("Invalid review file context")
    if kind == "decide":
        allowed |= {"choice", "path"}
        if command.get("choice") not in ("approve", "reject") or command.get("path") not in selected:
            raise Refused("Invalid file decision")
    if set(command) - allowed:
        raise Refused("Unknown editor command fields")
    return command


def decode_command(raw):
    value = decode_json(raw)
    if (not isinstance(value, dict) or set(value) != {"version", "serial", "command"}
            or type(value["version"]) is not int or value["version"] != 1
            or not integer(value["serial"], 1)):
        raise Refused("Invalid editor envelope")
    validate_command(value["command"])
    return value


class Binding:
    """One immutable scope; stale serials never replay a side effect."""
    def __init__(self):
        self.scope = None
        self.serial = self.turn = self.worker = 0

    def accept(self, frame):
        command = validate_command(frame["command"])
        scope = (command["conversation_id"], command["owner_generation"], command["root"],
                 tuple(command["selection"]), command["model"].split("/", 1)[0])
        if self.scope is not None and scope != self.scope:
            raise Refused("Controller ownership cannot change")
        serial = frame["serial"]
        if not integer(serial, 1):
            raise Refused("Invalid command serial")
        if serial <= self.serial:
            return False
        if serial != self.serial + 1:
            raise Refused("Future command serial")
        starts = command["kind"] in ("start", "revise")
        if self.scope is None and command["kind"] not in ("start", "close"):
            raise Refused("Controller needs an initial start or close")
        if ((command["turn_id"], command["worker_generation"]) !=
                (self.turn + starts, self.worker + starts)):
            raise Refused("Invalid turn or worker generation")
        self.scope, self.serial = scope, serial
        self.turn, self.worker = command["turn_id"], command["worker_generation"]
        return True


class EditorPipe:
    def __init__(self, input_fd, output_fd):
        self.input, self.output = input_fd, output_fd
        os.set_blocking(input_fd, False)
        os.set_blocking(output_fd, False)
        self.buffer, self.queue = bytearray(), deque()
        self.eof, self.queued = False, 0
        self.serial, self.events, self.bytes = None, 0, 0

    @property
    def writing(self):
        return bool(self.queue)

    def read_ready(self):
        frames, charged = [], len(self.buffer)
        for _ in range(64):
            if self.eof:
                break
            try:
                raw = os.read(self.input, 65536)
            except BlockingIOError:
                break
            if not raw:
                self.eof = True
                break
            charged += len(raw)
            if charged > MAX_PENDING:
                raise Refused("Editor pending input budget exceeded")
            self.buffer.extend(raw)
            while True:
                end = self.buffer.find(b"\n")
                if end < 0:
                    break
                if len(frames) >= 64:
                    raise Refused("Editor command queue budget exceeded")
                frames.append(decode_command(bytes(self.buffer[:end])))
                del self.buffer[:end + 1]
            if len(self.buffer) > MAX_COMMAND:
                raise Refused("Editor frame budget exceeded")
        if self.eof and self.buffer:
            raise Refused("Truncated editor frame")
        return frames

    def enqueue(self, serial, event):
        data = (json.dumps({"version": 1, "serial": serial, "event": event},
                           ensure_ascii=False, allow_nan=False) + "\n").encode()
        if serial != self.serial:
            self.serial, self.events, self.bytes = serial, 0, 0
        self.events += 1
        self.bytes += len(data)
        if (len(data) > MAX_EVENT or self.bytes > MAX_OUTPUT or self.events > MAX_EVENTS
                or self.queued + len(data) > MAX_OUTPUT):
            raise Refused("Editor output budget exceeded")
        self.queue.append([data, 0, time.monotonic() + 5])
        self.queued += len(data)

    def flush_ready(self):
        for _ in range(64):
            if not self.queue:
                return
            data, offset, deadline = self.queue[0]
            if time.monotonic() >= deadline:
                raise Refused("Editor output delivery deadline exceeded")
            try:
                size = os.write(self.output, memoryview(data)[offset:offset + 65536])
            except BlockingIOError:
                return
            if size <= 0:
                raise Refused("Editor output closed")
            self.queued -= size
            self.queue[0][1] += size
            if self.queue[0][1] == len(data):
                self.queue.popleft()
