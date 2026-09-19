"""Bounded ACP pipe/process seam for one isolated conversational worker.

The trusted caller supplies staging.sandbox's Bubblewrap command/environment:
PID isolation and die-with-parent are required, not provided by this module.
No shell, project publication, backend-store validation or session policy lives
here. A settled transport is necessary, never sufficient, for review or resume.
Calls run in the controller process, not on Neovim's main loop. One request may
be outstanding; begin/poll let the controller service editor input and send an
explicit cancellation between reads without shortening the request deadline.
"""
from collections import namedtuple
from contextlib import ExitStack
import json
import math
import os
import select
import subprocess
import time


MAX_FRAME = 16 * 1024 * 1024
MAX_BYTES = 32 * 1024 * 1024
MAX_MESSAGES = 20000


class ProtocolError(RuntimeError):
    """Trusted diagnostic; never include peer text, paths or error data."""


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate JSON key")
        value[key] = item
    return value


def _number(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("Non-finite JSON number")
    return value


def _identifier(value):
    return ((type(value) is int and abs(value) <= 2 ** 53 - 1) or
            (isinstance(value, str) and 0 < len(value) <= 256
             and all(32 <= ord(char) < 127 for char in value)))


class Exit(namedtuple("Exit", "reaped output_closed forced returncode fault pending")):
    __slots__ = ()

    @property
    def graceful(self):
        return self.reaped and self.output_closed and not self.forced and self.returncode == 0

    @property
    def settled(self):
        return self.graceful and self.fault is None and not self.pending


class Worker:
    def __init__(self, command, *, env, rpc_timeout=15, stop_timeout=3,
                 on_notification=None, on_request=None, guard=None, on_write_wait=None):
        self.rpc_timeout, self.stop_timeout = rpc_timeout, stop_timeout
        self.on_notification, self.on_request = on_notification, on_request
        self.on_write_wait = on_write_wait
        self.guard, self.guard_due = guard, 0
        self.pending, self.fault, self.exit = None, None, None
        self.serial, self.count, self.received_bytes = 0, 0, 0
        self.request_ids = set()
        self.buffer = bytearray()
        self.eof, self.closing = False, False
        # Finish parent-side pipe setup before a live child exists. A setup
        # failure must not hide an unreaped worker from the caller's registry.
        with ExitStack() as child_ends, ExitStack() as parent_ends:
            input_read, input_write = os.pipe()
            child_ends.callback(os.close, input_read)
            self.input = parent_ends.enter_context(os.fdopen(input_write, "wb", buffering=0))
            output_read, output_write = os.pipe()
            child_ends.callback(os.close, output_write)
            self.output = parent_ends.enter_context(os.fdopen(output_read, "rb", buffering=0))
            os.set_blocking(self.input.fileno(), False)
            os.set_blocking(self.output.fileno(), False)
            self.child = subprocess.Popen(command, env=env, stdin=input_read, stdout=output_write,
                                          stderr=subprocess.DEVNULL, start_new_session=True, umask=0o077)
            parent_ends.pop_all()  # close() now owns these streams.

    def _fail(self, reason):
        self.fault = self.fault or reason
        raise ProtocolError(self.fault) from None

    def _poll_guard(self):
        # A trusted, bounded metadata guard runs even when the peer is silent or
        # stops reading. Never run it during shutdown: failure must not stop reap.
        now = time.monotonic()
        if self.guard is not None and now >= self.guard_due:
            self.guard_due = now + .1
            try:
                self.guard()
            except Exception:
                self._fail("ACP worker state check failed")

    def _live(self):
        if self.fault or self.closing:
            raise ProtocolError(self.fault or "ACP worker is closing or closed")

    def _read(self):
        try:
            data = os.read(self.output.fileno(), 65536)
        except BlockingIOError:
            return
        if not data:
            self.eof = True
            return
        if self.fault:
            return  # Shutdown still drains the pipe, without retaining peer data.
        self.received_bytes += len(data)
        if self.received_bytes > MAX_BYTES:
            self._fail("ACP byte budget exceeded")
        self.buffer.extend(data)
        if len(self.buffer) - (self.buffer.rfind(b"\n") + 1) > MAX_FRAME:
            self._fail("ACP frame budget exceeded")

    def _message(self):
        end = self.buffer.find(b"\n")
        if end < 0:
            if self.eof and self.buffer:
                self._fail("Malformed ACP truncated frame")
            return None
        raw = bytes(self.buffer[:end + 1])
        del self.buffer[:end + 1]
        self.count += 1
        if len(raw) > MAX_FRAME or self.count > MAX_MESSAGES:
            self._fail("ACP frame or message budget exceeded")
        try:
            value = json.loads(raw.decode("utf-8"), object_pairs_hook=_object,
                               parse_constant=_number, parse_float=_number)
        except (ValueError, UnicodeError, RecursionError):
            self._fail("Malformed ACP JSON")
        if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
            self._fail("Malformed ACP message")
        if "id" in value and not _identifier(value["id"]):
            self._fail("Malformed ACP identity")
        if "method" in value:
            method = value["method"]
            if (not isinstance(method, str) or not 0 < len(method) <= 128
                    or any(ord(char) < 33 or ord(char) > 126 for char in method)
                    or not isinstance(value.get("params", {}), dict)
                    or set(value) - {"jsonrpc", "id", "method", "params"}):
                self._fail("Malformed ACP request or notification")
            if "id" in value:
                if value["id"] in self.request_ids:
                    self._fail("Duplicate ACP request identity")
                self.request_ids.add(value["id"])
        else:
            if ("id" not in value or ("result" in value) == ("error" in value)
                    or set(value) - {"jsonrpc", "id", "result", "error"}):
                self._fail("Malformed ACP response")
            if "result" in value and not isinstance(value["result"], dict):
                self._fail("Malformed ACP result")
            if "error" in value:
                error = value["error"]
                if (not isinstance(error, dict) or type(error.get("code")) is not int
                        or not -(2 ** 31) <= error["code"] < 2 ** 31
                        or not isinstance(error.get("message"), str)):
                    self._fail("Malformed ACP error")
        return value

    def _send(self, value, deadline):
        self._live()
        payload = (json.dumps(dict(jsonrpc="2.0", **value), allow_nan=False) + "\n").encode()
        if len(payload) > MAX_FRAME:
            self._fail("ACP input frame budget exceeded")
        offset = 0
        while offset < len(payload):
            self._poll_guard()
            if self.on_write_wait is not None:
                try:
                    interrupted = self.on_write_wait()
                except Exception:
                    self._fail("ACP write interruption check failed")
                if interrupted:
                    # The pipe may contain a partial frame. A cancel must never
                    # be appended to it; shutdown is the only next operation.
                    self._fail("ACP input write interrupted")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._fail("ACP input deadline exceeded")
            readable, writable, _ = select.select([] if self.eof else [self.output],
                                                 [self.input], [], min(.1, remaining))
            if readable:
                self._read()
            if writable:
                try:
                    offset += os.write(self.input.fileno(), memoryview(payload)[offset:])
                except BlockingIOError:
                    pass
                except OSError:
                    self._fail("ACP input closed")

    def begin(self, method, params, *, timeout=None):
        self._live()
        if self.pending is not None:
            raise ProtocolError("An ACP request is already pending")
        self.serial += 1
        self.pending = "worker-" + str(self.serial)
        self.deadline = time.monotonic() + (self.rpc_timeout if timeout is None else timeout)
        self._send({"id": self.pending, "method": method, "params": params}, self.deadline)
        return self.pending

    def notify(self, method, params):
        self._send({"method": method, "params": params},
                   self.deadline if self.pending else time.monotonic() + self.rpc_timeout)

    def receive(self, identifier, *, timeout=None):
        return self._receive(identifier, timeout=timeout)[1]

    def poll(self, identifier, *, timeout=.1):
        """Return (ready, result); a read slice ending is not an RPC failure.

        The original request deadline and all protocol budgets still apply.
        Yield after at most 64 messages, including notifications, so an active
        peer cannot starve the controller's explicit Cancel/Close handling.
        Trusted callbacks and replies to client requests still run synchronously;
        timeout bounds the read slice, not their execution or output backpressure.
        """
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 1:
            raise ValueError("ACP poll timeout must be finite and within (0, 1]")
        return self._receive(identifier, poll_timeout=timeout)

    def _receive(self, identifier, *, timeout=None, poll_timeout=None):
        self._live()
        if self.pending is None or self.pending != identifier:
            self._fail("Unexpected ACP request identity")
        deadline = self.deadline
        if timeout is not None:
            deadline = min(deadline, time.monotonic() + timeout)
        poll_deadline = None if poll_timeout is None else time.monotonic() + poll_timeout
        processed = 0
        while True:
            self._poll_guard()
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                self._fail("ACP response deadline exceeded")
            if poll_deadline is not None:
                if now >= poll_deadline or processed >= 64:
                    return False, None
                remaining = min(remaining, poll_deadline - now)
            value = self._message()
            if value is None:
                if self.eof:
                    self._fail("ACP output closed before response")
                if select.select([self.output], [], [], min(.1, remaining))[0]:
                    self._read()
                continue
            if "method" not in value:
                if value.get("id") != identifier:
                    self._fail("Unexpected ACP response identity")
                self.pending = None
                if "error" in value:
                    raise ProtocolError(f"ACP request refused: {value['error'].get('code')}")
                return True, value["result"]
            processed += 1
            if "id" not in value:
                if self.on_notification:
                    self.on_notification(value)
            else:
                response = (self.on_request(value) if self.on_request else
                            {"error": {"code": -32601, "message": "Client capability disabled"}})
                self._send(dict(response, id=value["id"]), deadline)

    def request(self, method, params, *, timeout=None):
        return self.receive(self.begin(method, params, timeout=timeout))

    def _settle(self, deadline):
        while time.monotonic() < deadline:
            if self.fault:
                self.buffer.clear()
            else:
                try:
                    value = self._message()
                    if value is not None:
                        if "method" not in value:
                            self._fail("Unexpected ACP response during shutdown")
                        continue  # Never execute client operations during shutdown.
                except ProtocolError:
                    continue
            if self.child.poll() is not None and self.eof:
                return True
            remaining = max(0, min(.05, deadline - time.monotonic()))
            if self.eof:
                try:
                    self.child.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    pass
            elif select.select([self.output], [], [], remaining)[0]:
                try:
                    self._read()
                except ProtocolError:
                    pass
        # At the deadline, even EOF plus a reaped supervisor is insufficient if
        # buffered messages have not yet been checked (for example duplicates).
        return self.child.poll() is not None and self.eof and not self.buffer

    def close(self):
        """Bounded EOF/TERM/KILL and drain; no deletion, freeze, retry or reuse.

        The result is immutable/idempotent. If exit is unproven, the caller must
        retain mounted state and block further workers. Forced or unsettled exit
        cannot authorize a proposal or continuation, even with return code zero.
        """
        if self.exit is not None:
            return self.exit
        self.closing = True
        pending = self.pending is not None
        self.input.close()
        forced = False
        if not self._settle(time.monotonic() + self.stop_timeout):
            forced = True
            self.child.terminate()
            if not self._settle(time.monotonic() + self.stop_timeout):
                self.child.kill()
                self._settle(time.monotonic() + self.stop_timeout)
        self.exit = Exit(self.child.poll() is not None, self.eof, forced,
                         self.child.returncode, self.fault, pending)
        self.output.close()
        self.buffer.clear()
        return self.exit
