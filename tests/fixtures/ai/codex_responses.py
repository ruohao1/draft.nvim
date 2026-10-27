"""Local, scripted Responses SSE peer for pinned Codex acceptance tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import queue
import threading


def response(item):
    return [
        {"type": "response.created", "response": {"id": "fixture-response"}},
        {"type": "response.output_item.done", "item": item},
        {"type": "response.completed", "response": {"id": "fixture-response",
         "usage": {"input_tokens": 0, "input_tokens_details": None, "output_tokens": 0,
                   "output_tokens_details": None, "total_tokens": 0}}},
    ]


def answer(text):
    return response({"type": "message", "role": "assistant", "id": "fixture-message",
                     "content": [{"type": "output_text", "text": text}]})


def command(script, call_id="fixture-command"):
    arguments = json.dumps({"cmd": script, "workdir": "/tmp/project", "yield_time_ms": 1000})
    return response({"type": "custom_tool_call", "call_id": call_id, "name": "exec",
                     "input": "text(await tools.exec_command(" + arguments + "));"})


class Provider:
    def __init__(self):
        self.requests = []
        self.errors = []
        self.websocket_probes = 0
        self.replies = queue.Queue()
        self.streaming = threading.Event()
        self.gate = threading.Event()
        self.gate.set()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if (self.path == "/v1/responses"
                        and self.headers.get("Upgrade", "").lower() == "websocket"
                        and owner.websocket_probes < 16):
                    owner.websocket_probes += 1
                    self.send_error(426, "This fixture supports Responses over HTTP")
                    return
                owner.errors.append("Unexpected GET " + self.path)
                self.send_error(404)

            def do_POST(self):
                self.connection.settimeout(5)
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if (self.path != "/v1/responses" or not 0 < length <= 2 * 1024 * 1024
                            or self.headers.get("Content-Encoding", "identity") != "identity"
                            or self.headers.get("Authorization") != "Bearer synthetic-codex-key"
                            or len(owner.requests) >= 16):
                        raise ValueError("Unexpected fixture request")
                    body = json.loads(self.rfile.read(length))
                    owner.requests.append(body)
                    events = owner.replies.get_nowait()
                except (ValueError, queue.Empty) as error:
                    owner.errors.append(str(error))
                    self.send_error(400)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    for event in events:
                        if event["type"] == "response.completed":
                            owner.streaming.set()
                            if not owner.gate.wait(timeout=15):
                                return
                        self.wfile.write(("event: " + event["type"] + "\ndata: "
                                          + json.dumps(event) + "\n\n").encode())
                        self.wfile.flush()
                except (OSError, TimeoutError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def enqueue(self, events):
        self.replies.put(events)

    def hold(self):
        self.streaming.clear()
        self.gate.clear()

    def release(self):
        self.gate.set()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.release()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
