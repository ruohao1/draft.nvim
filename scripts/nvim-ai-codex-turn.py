"""One Codex turn: terminal identity and stopped state precede any frozen review."""
import importlib.util
import json
from pathlib import Path
import re
import time


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = helper("nvim-ai-codex-runtime")
staging = runtime.staging
protocol = helper("nvim-ai-conversation-protocol")
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


class Turn:
    def __init__(self, config, store, editor_pipe, *, session=None):
        self.config, self.store, self.pipe = config, store, editor_pipe
        self.session = self.initial_session = session
        self.task = self.worker = self.frozen = self.pending = None
        self.stage = self.turn_id = self.terminal = None
        self.events, self.early, self.items = [], [], {}
        self.early_bytes = 0
        self.done = self.submitted = self.stopped = self.graceful = self.store_valid = False
        self.cancelling = self.cancel_confirmed = self.retired_store = False
        self.on_write_wait = None
        self.diagnostic = "sources"
        self.models, self.cursors = [], set()

    def emit(self, kind, **fields):
        self.events.append(dict(kind=kind, **fields))

    def drain_events(self):
        events, self.events = self.events, []
        return events

    def startup(self, stage):
        self.diagnostic = stage
        self.emit("startup", stage=stage)

    def start(self, command, *, selected=None, context=None, manual_corrections=False):
        self.command, self.context, self.manual_corrections = command, context, manual_corrections
        self.startup("sources")
        if re.fullmatch(r"openai/[a-zA-Z0-9_.-]{1,200}", command["model"]) is None:
            raise protocol.Refused("Codex requires an explicit OpenAI model")
        request = dict(self.config, root=command["root"], files=command["sources"], model=command["model"])
        self.selected = selected if selected is not None else staging.selected_files(request)[0]
        self.task = staging.prepare_workspace(request, self.selected)
        self.startup("credentials")
        if not self.store.initialized:
            self.store.initialize(self.config["auth_file"])
        self.startup("launch")
        argv, env = runtime.sandbox(request, self.task, self.store)
        self.startup_deadline = time.monotonic() + 60
        self.worker = self.store.start(argv, env=env, on_notification=self.notification,
                                      on_request=self.request, on_write_wait=self.on_write_wait)
        self.begin("initialize", {"clientInfo": {"name": "draft_conversation", "version": "0.1"}})

    def begin(self, method, params):
        self.stage = method
        if method == "turn/start":
            self.diagnostic = "generation"
            self.deadline = time.monotonic() + 180
            self.submitted = True  # A partial pipe write is already unsafe to replay.
            deadline = self.deadline
        elif method == "turn/interrupt":
            deadline = self.deadline
        else:
            self.startup({"initialize": "initialize", "model/list": "model", "command/exec": "compatibility",
                          "thread/start": "session", "thread/resume": "resume"}[method])
            deadline = self.startup_deadline
        timeout = min(15, deadline - time.monotonic())
        if timeout <= 0:
            self.diagnostic = "timeout"
            raise protocol.Refused("Codex startup or turn deadline exceeded")
        self.pending = self.worker.begin(method, params, timeout=timeout)

    def request(self, message):
        return {"error": {"code": -32601, "message": "Client capability disabled"}}

    def notification(self, message):
        method, params = message["method"], message.get("params", {})
        correlated = method in ("turn/started", "turn/completed", "item/started", "item/completed") or method.startswith("item/")
        if self.stage == "turn/start" and self.turn_id is None and correlated:
            self.early_bytes += len(json.dumps(message).encode())
            if len(self.early) >= 64 or self.early_bytes > 1024 * 1024:
                raise protocol.Refused("Codex early-event budget exceeded")
            self.early.append(message)
            return
        if "threadId" in params and params["threadId"] != self.session:
            raise protocol.Refused("Foreign Codex thread event")
        if not correlated:
            return  # Global status/additive notifications carry no editor authority.
        if self.turn_id is None or params.get("threadId") != self.session:
            raise protocol.Refused("Codex turn event without a bound thread")
        if self.terminal is not None:
            raise protocol.Refused("Codex event follows terminal completion")
        if method in ("turn/started", "turn/completed"):
            turn = params.get("turn")
            if not isinstance(turn, dict) or turn.get("id") != self.turn_id:
                raise protocol.Refused("Foreign Codex terminal identity")
            if method == "turn/started":
                if getattr(self, "started_event", False) or turn.get("status") != "inProgress":
                    raise protocol.Refused("Invalid Codex start notification")
                self.started_event = True
            else:
                if turn.get("status") not in ("completed", "interrupted", "failed"):
                    raise protocol.Refused("Invalid Codex terminal status")
                if turn.get("status") == "completed" and turn.get("error") is not None:
                    raise protocol.Refused("Codex completion carries an error")
                self.terminal = turn["status"]
            return
        if params.get("turnId") != self.turn_id:
            raise protocol.Refused("Foreign Codex turn event")
        if method in ("item/started", "item/completed"):
            item = params.get("item")
            if not isinstance(item, dict) or not protocol.opaque(item.get("id")):
                raise protocol.Refused("Invalid Codex item identity")
            identifier, kind = item["id"], item.get("type")
            previous = self.items.get(identifier)
            if method == "item/started":
                if previous is not None or len(self.items) >= 20000:
                    raise protocol.Refused("Duplicate or excess Codex item")
                if kind not in ("agentMessage", "userMessage", "commandExecution", "fileChange",
                                "reasoning", "plan", "contextCompaction", "functionCallOutput"):
                    raise protocol.Refused("Codex item capability unavailable")
                previous = self.items[identifier] = {"type": kind, "closed": False, "text": ""}
            elif previous is None or previous["closed"] or previous["type"] != kind:
                raise protocol.Refused("Unmatched Codex completed item")
            if kind == "agentMessage" and method == "item/completed":
                text = item.get("text")
                if (not isinstance(text, str) or len(text.encode()) > 1024 * 1024
                        or not text.startswith(previous["text"])):
                    raise protocol.Refused("Invalid Codex completed text")
                if not self.cancelling and text != previous["text"]:
                    self.emit("text", text=text[len(previous["text"]):])
            if kind in ("commandExecution", "fileChange", "contextCompaction"):
                status = "in_progress" if method == "item/started" else "completed"
                if kind != "contextCompaction":
                    status = {"inProgress": "in_progress", "completed": "completed",
                              "failed": "failed", "declined": "cancelled"}.get(item.get("status"))
                    if status is None:
                        raise protocol.Refused("Invalid Codex item status")
                if not self.cancelling:
                    self.emit("progress", tool_id=identifier, status=status, title={
                        "commandExecution": "Running an isolated command",
                        "fileChange": "Editing selected copies",
                        "contextCompaction": "Compacting conversation context"}[kind])
            previous["closed"] = method == "item/completed"
        elif "itemId" in params:
            previous = self.items.get(params["itemId"]) if isinstance(params["itemId"], str) else None
            if previous is None or previous["closed"]:
                raise protocol.Refused("Foreign Codex delta item")
            if method == "item/agentMessage/delta":
                delta = params.get("delta")
                if (previous["type"] != "agentMessage" or not isinstance(delta, str)
                        or len(previous["text"].encode()) + len(delta.encode()) > 1024 * 1024):
                    raise protocol.Refused("Invalid Codex text delta")
                previous["text"] += delta
                if not self.cancelling:
                    self.emit("text", text=delta)

    def catalog(self, result):
        data, cursor = result.get("data"), result.get("nextCursor")
        if not isinstance(data, list) or len(data) > 128 or len(self.models) + len(data) > 128:
            raise protocol.Refused("Codex model catalog exceeds budget")
        for item in data:
            model = item.get("model") if isinstance(item, dict) else None
            if (not isinstance(model, str) or re.fullmatch(r"[a-zA-Z0-9_.-]{1,200}", model) is None
                    or "openai/" + model in self.models):
                raise protocol.Refused("Invalid Codex model catalog identity")
            self.models.append("openai/" + model)
        if cursor is not None:
            if (not isinstance(cursor, str) or not 0 < len(cursor.encode()) <= 1024
                    or cursor in self.cursors or len(self.cursors) >= 7):
                raise protocol.Refused("Invalid Codex model pagination")
            self.cursors.add(cursor)
            self.begin("model/list", {"limit": 128, "cursor": cursor})
        else:
            if self.command["model"] not in self.models:
                raise protocol.Refused("Requested Codex model is not advertised")
            self.begin("command/exec", {"command": ["/usr/bin/test", "!", "-r", "/home/agent/.codex/auth.json"],
                                       "cwd": staging.PROJECT, "timeoutMs": 5000})

    def bind_thread(self, result):
        thread = result.get("thread")
        if (not isinstance(thread, dict) or not isinstance(thread.get("id"), str)
                or re.fullmatch(UUID, thread["id"]) is None
                or (self.session is not None and thread["id"] != self.session)
                or thread.get("cwd") != staging.PROJECT or thread.get("cliVersion") != runtime.VERSION
                or thread.get("ephemeral") is not False or thread.get("modelProvider") != "openai"
                or result.get("model") != self.command["model"].split("/", 1)[1]
                or result.get("modelProvider") != "openai" or result.get("cwd") != staging.PROJECT
                or result.get("approvalPolicy") != "never" or result.get("approvalsReviewer") != "user"
                or result.get("sandbox") != runtime.POLICY):
            raise protocol.Refused("Codex thread identity, model or permissions mismatch")
        self.session = thread["id"]
        text = ("Only the selected editable paths in /tmp/project are available. "
                "Do not create, delete, rename, or change modes. Changes require editor review. "
                "Context snapshots and their paths grant no additional file access or editing authority.")
        if self.context:
            text += "\nEditor-confirmed file decisions (rejected proposals are not saved):\n" + json.dumps(self.context)
        if self.manual_corrections:
            text += ("\nThis conversation includes editor-made corrections. "
                     "Use selected workspace contents and confirmed decisions as current state.")
        text += "\n" + self.command["message"]
        self.begin("turn/start", {"threadId": self.session,
            "input": [{"type": "text", "text": text, "text_elements": []}],
            "approvalPolicy": "never", "approvalsReviewer": "user"})
        self.emit("submitted", model=self.command["model"], models=self.models)

    def advance(self):
        if self.pending is not None:
            if self.cancelling:
                self.worker.deadline = min(self.worker.deadline, self.deadline)
            ready, result = self.worker.poll(self.pending, timeout=.05)
            if not ready:
                return self.drain_events()
            self.pending = None
            if self.stage == "initialize":
                if (not isinstance(result.get("userAgent"), str)
                        or not result["userAgent"].startswith("draft_conversation/" + runtime.VERSION + " ")
                        or result.get("codexHome") != "/home/agent/.codex"
                        or result.get("platformOs") != "linux"):
                    self.diagnostic = "compatibility"
                    raise protocol.Refused("Pinned Codex runtime required")
                self.worker.notify("initialized", {})
                self.begin("model/list", {"limit": 128})
            elif self.stage == "model/list":
                self.catalog(result)
            elif self.stage == "command/exec":
                if type(result.get("exitCode")) is not int or result["exitCode"] != 0:
                    raise protocol.Refused("Codex command isolation is unavailable")
                params = {"cwd": staging.PROJECT, "model": self.command["model"].split("/", 1)[1],
                          "modelProvider": "openai", "approvalPolicy": "never",
                          "approvalsReviewer": "user"}
                if self.session is not None:
                    params.update(threadId=self.session, excludeTurns=True)
                self.begin("thread/resume" if self.session is not None else "thread/start", params)
            elif self.stage in ("thread/start", "thread/resume"):
                self.bind_thread(result)
            elif self.stage == "turn/start":
                turn = result.get("turn")
                if (not isinstance(turn, dict) or not protocol.opaque(turn.get("id"))
                        or turn.get("status") not in ("inProgress", "completed")):
                    raise protocol.Refused("Missing Codex turn identity")
                self.turn_id, self.stage = turn["id"], "running"
                early, self.early = self.early, []
                for message in early:
                    self.notification(message)
            elif self.stage == "turn/interrupt":
                self.stage = "interrupting"
        elif self.terminal is None:
            self.worker.poll_events(deadline=self.deadline)
        if self.pending is None and self.terminal is not None:
            self.finish()
        return self.drain_events()

    def finish(self):
        expected = "interrupted" if self.cancelling else "completed"
        if self.terminal != expected:
            raise protocol.Refused("Codex turn did not reach the required terminal status")
        if not self.cancelling:
            self.emit("stopping")
        self.diagnostic = "cleanup"
        self.store.stop(outcome="cancelled" if self.cancelling else "completed", session=self.session)
        self.stopped = self.graceful = self.store_valid = True
        if self.cancelling:
            staging.discard_workspace(self.task)
            self.task = None
            self.cancel_confirmed = self.done = True
            self.emit("cancelled", stopped=True, graceful=True, store_valid=True,
                      tokens_retired=True, cancel_confirmed=True)
            return
        if self.on_write_wait is not None and self.on_write_wait():
            raise protocol.Refused("Editor ownership changed before workspace freeze")
        self.diagnostic = "sources"
        for item in self.selected:
            data, mode, identity = staging.snapshot(self.command["root"], item["path"])
            if identity != item["identity"] or staging.fingerprint(data, mode) != item["expected"]:
                raise protocol.Refused("Saved source changed during Codex generation")
        self.diagnostic = "review"
        self.frozen = staging.freeze_workspace(self.task, self.command["root"], self.selected,
                                                multi=True, force_review=self.command["kind"] == "revise")
        if self.on_write_wait is not None and self.on_write_wait():
            raise protocol.Refused("Editor ownership changed before proposal exposure")
        if self.frozen["phase"] != "unchanged":
            self.emit("settled", outcome="review", stopped=True, graceful=True, store_valid=True)
        else:
            staging.discard_workspace(self.task)
            self.task = None
            self.emit("settled", outcome="answer", stopped=True, graceful=True, store_valid=True, tokens_retired=True)
        self.done = True

    def cancel(self):
        self.cancelling = True
        if (self.done or self.worker is None or self.worker.fault or self.turn_id is None
                or self.pending is not None or self.terminal is not None):
            return self.fail()
        self.deadline = min(self.deadline, time.monotonic() + 5)
        self.begin("turn/interrupt", {"threadId": self.session, "turnId": self.turn_id})
        return []

    def fail(self):
        self.events = []
        if self.worker is not None and self.worker.fault and "deadline" in self.worker.fault:
            self.diagnostic = "timeout"
        if not self.cancelling:
            self.emit("stopping")
        if self.worker is not None and not self.stopped:
            try:
                self.store.stop(outcome="failed")
            except Exception:
                pass
            result = self.worker.close()
            self.stopped = result.reaped and result.output_closed
            self.graceful, self.store_valid = result.settled, False
        elif self.worker is None:
            self.stopped = self.graceful = True
        elif self.store_valid and not self.retired_store:
            try:
                self.store.check()
            except Exception:
                self.store_valid = False
        retired = self.task is None
        if self.stopped and self.task is not None:
            try:
                if self.task.exists():
                    staging.discard_workspace(self.task)
                self.task, retired = None, True
            except OSError:
                pass
        if (not self.submitted and self.initial_session is None and self.stopped and self.graceful
                and retired and not self.cancelling):
            try:
                self.store.close()
                self.retired_store = self.store_valid = True
                self.session = None
            except Exception:
                self.store_valid = False
        if self.cancelling:
            self.emit("cancelled", stopped=self.stopped, graceful=self.graceful,
                      store_valid=self.store_valid, tokens_retired=retired, cancel_confirmed=False)
        else:
            self.emit("settled", outcome="failed", stopped=self.stopped, graceful=self.graceful,
                      store_valid=self.store_valid, tokens_retired=retired, diagnostic=self.diagnostic,
                      submission="submitted" if self.submitted else "not_submitted")
        self.done = True
        return self.drain_events()
