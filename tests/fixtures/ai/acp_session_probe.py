"""Disposable interoperability fixture, not an editor controller or publisher.

Observe ACP, the scripted provider, selected files and process/listener lifetime.
Never open the backend database. Reuse production staging confinement as setup.
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import tempfile
import threading
import time


SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
spec = importlib.util.spec_from_file_location("acp_probe_staging", SCRIPTS / "nvim-ai-staged.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
SELECTED = "/tmp/project/src/example.txt"
storage = staging.helper("nvim-ai-conversation-store")
ProtocolError = storage.ProtocolError


class Provider:
    def __init__(self):
        self.requests, self.replies = [], []
        self.streaming = threading.Event()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.connection.settimeout(5)
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/v1/chat/completions" or not 0 < length <= 2 * 1024 * 1024:
                    self.send_error(400)
                    return
                body = json.loads(self.rfile.read(length))
                owner.requests.append({"body": body, "authorization": self.headers.get("Authorization")})
                if not owner.replies:
                    self.send_error(400, "Unexpected fixture request")
                    return
                reply = owner.replies.pop(0)
                if 'error' in reply:
                    payload = json.dumps({'error': reply['error']}).encode()
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def chunk(delta, finish=None):
                    payload = {"id": "local-acp-proof", "object": "chat.completion.chunk", "created": 1,
                               "model": body["model"], "choices": [{"index": 0, "delta": delta,
                                                                    "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())

                try:
                    chunk({"role": "assistant"})
                    if reply.get("edit"):
                        chunk({"tool_calls": [{"index": 0, "id": "first_native_edit", "type": "function",
                              "function": {"name": "edit", "arguments": json.dumps({"filePath": SELECTED,
                                           "oldString": "original text", "newString": "proposed text"})}}]})
                        chunk({}, "tool_calls")
                    else:
                        chunk({"content": reply["text"]})
                        self.wfile.flush()
                        if reply.get("hold") is not None:
                            owner.streaming.set()
                            if not reply["hold"].wait(timeout=10):
                                return
                        chunk({}, "stop")
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def config(self):
        return {"fixture": {"npm": "@ai-sdk/openai-compatible", "name": "Local scripted provider",
                "options": {"baseURL": f"http://127.0.0.1:{self.server.server_port}/v1"},
                "models": {name: {"name": name, "tool_call": True,
                                  "limit": {"context": 32768, "output": 2048}}
                           for name in ("model", "second-model")}}}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


class Fixture:
    def __init__(self, executable, *, parent="/tmp"):
        self.executable = staging.executable(executable)
        self.root = Path(tempfile.mkdtemp(prefix="nvim-ai-acp-proof-", dir=parent))
        self.workers = []
        self.state = storage.Store(self.root)
        self.store = self.state.path
        (self.root / "real-project").mkdir(mode=0o700)
        self.source = self.root / "real-project/example.txt"
        self.source.write_bytes(b"original text\n")
        self.source.chmod(0o644)
        self.provider = Provider()

    @contextmanager
    def worker(self):
        worker = Worker(self, len(self.workers) + 1)
        try:
            yield worker
        finally:
            worker.close()

    def close(self):
        try:
            for worker in self.workers:
                worker.close()
        finally:
            self.provider.close()
        if any(worker.child.poll() is None for worker in self.workers):
            raise RuntimeError("Owned worker exit unproven; scratch evidence retained")
        self.state.close()
        # Only this fixture's mkdtemp root, never a user project or a backend path.
        shutil.rmtree(self.root)


class Worker:
    def __init__(self, owner, generation):
        self.owner = owner
        self.task = Path(tempfile.mkdtemp(prefix=f"worker-{generation}-", dir=owner.root))
        agent = self.task / "agent"
        for name in ("home", "config", "data", "cache", "state"):
            (agent / name).mkdir(mode=0o700, parents=True)
        self.selected = self.task / "staging/src/example.txt"
        self.selected.parent.mkdir(mode=0o700, parents=True)
        self.selected.write_bytes(owner.source.read_bytes())
        self.selected.chmod(0o644)
        auth = self.task / "fixture-auth.json"
        staging.json_write(auth, {"fixture": {"type": "api", "key": f"fixture-profile-{generation}"},
                                  "unrelated": {"type": "api", "key": "never-copy-this-fixture-key"}})
        request = {"model": "fixture/model", "provider": owner.provider.config(), "auth_file": str(auth),
                   "bwrap": os.path.realpath(shutil.which("bwrap")), "opencode": owner.executable}
        config = staging.configuration(request, agent)
        config["compaction"] = {"auto": False, "prune": False}
        command, env = staging.sandbox(request, self.task, config)
        env.update(OPENCODE_DISABLE_AUTOCOMPACT="true", OPENCODE_DISABLE_PRUNE="true",
                   OPENCODE_SERVER_USERNAME="opencode", OPENCODE_SERVER_PASSWORD=secrets.token_hex(16))
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            self.port = reserved.getsockname()[1]
        command += ["--hostname", "127.0.0.1", "--port", str(self.port), "--mdns=false"]
        self.graceful, self.closed = False, False
        self.outcome, self.pending_method = "failed", None
        self.started = time.monotonic()
        self.session, self.options = None, []
        self.updates, self.denied = [], []
        self.transport = owner.state.start(command, env=env, on_notification=self.notification,
                                           on_request=self.client_request)
        self.child = self.transport.child
        # Pipe setup precedes process launch. Register the successfully
        # constructed worker before any handshake can raise.
        owner.workers.append(self)

    def send(self, value):
        self.transport.notify(value["method"], value.get("params", {}))

    def begin(self, method, params):
        self.pending_method = method
        return self.transport.begin(method, params, timeout=180 if method == "session/prompt" else 15)

    def receive(self, identifier, timeout=None):
        result = self.transport.receive(identifier, timeout=timeout)
        if self.pending_method == "session/prompt":
            self.outcome = {"end_turn": "completed", "cancelled": "cancelled"}.get(result.get("stopReason"), "failed")
        self.pending_method = None
        return result

    def notification(self, value):
        if value["method"] == "session/update":
            self.updates.append(value.get("params", {}))

    def client_request(self, value):
        params = value.get("params", {})
        call = params.get("toolCall", {})
        diffs = [part for part in call.get("content", []) if part.get("type") == "diff"]
        allowed = (value["method"] == "session/request_permission" and params.get("sessionId") == self.session
                   and call.get("kind") == "edit" and diffs and all(part.get("path") == SELECTED for part in diffs))
        if value["method"] == "session/request_permission":
            option = next((item.get("optionId") for item in params.get("options", [])
                           if item.get("kind") == "allow_once"), None) if allowed else None
            outcome = {"outcome": "selected", "optionId": option} if option else {"outcome": "cancelled"}
            return {"result": {"outcome": outcome}}
        self.denied.append(value["method"])
        return {"error": {"code": -32601, "message": "Client capability disabled"}}

    def request(self, method, params):
        return self.receive(self.begin(method, params))

    def start(self, session=None, model="fixture/model"):
        info = self.request("initialize", {"protocolVersion": 1,
            "clientInfo": {"name": "nvim-ai-acp-proof", "version": "0.1"},
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
        if info.get("protocolVersion") != 1 or info.get("agentInfo", {}).get("version") != "1.18.30":
            raise ProtocolError("The proof requires pinned OpenCode 1.18.30 / ACP 1")
        if "resume" not in info.get("agentCapabilities", {}).get("sessionCapabilities", {}):
            raise ProtocolError("Resume capability not advertised")
        self.session = session
        params = {"cwd": "/tmp/project", "mcpServers": []}
        if session:
            result = self.request("session/resume", dict(params, sessionId=session))
        else:
            result = self.request("session/new", params)
            self.session = result.get("sessionId")
        if not isinstance(self.session, str) or not self.session:
            raise ProtocolError("Missing session identity")
        self.session_response = result
        self.options = result.get("configOptions", [])
        self.choose("model", model)
        self.choose("mode", "build")
        self.startup = time.monotonic() - self.started
        if not self.listening():
            raise ProtocolError("The owned ACP listener was not observed")
        return self.session

    def choose(self, key, value):
        result = self.request("session/set_config_option", {"sessionId": self.session, "configId": key, "value": value})
        self.options = result.get("configOptions", [])
        if not any(option.get("id") == key and option.get("currentValue") == value for option in self.options):
            raise ProtocolError("ACP did not confirm the selected option")

    def prompt(self, text):
        return self.request("session/prompt", {"sessionId": self.session, "prompt": [{"type": "text", "text": text}]})

    def listening(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=.2):
                return True
        except OSError:
            return False

    def close(self):
        if self.closed:
            return
        try:
            self.shutdown = self.owner.state.stop(outcome=self.outcome)
            self.graceful = self.shutdown.settled
        finally:
            self.shutdown = self.transport.close()
            if self.shutdown.reaped and self.shutdown.output_closed:
                self.closed = True
                shutil.rmtree(self.task)
