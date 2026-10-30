"""Synthetic saved ChatGPT logins. Never reads an installed login."""
import base64
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import queue
import sys
import threading
import time


CLOCK = int(time.time())
CLAIM = "https://api.openai.com/auth"


def encoded(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def bundle(generation=0, *, user_id="fixture-user", workspace_id="fixture-workspace"):
    claims = {"exp": CLOCK + 86400, "iat": CLOCK + generation,
              "email": "fixture@example.test", CLAIM: {"chatgpt_user_id": user_id,
                  "chatgpt_account_id": workspace_id, "chatgpt_plan_type": "plus"}}
    access = {"exp": CLOCK + 86400, "generation": generation}
    return {"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
            "tokens": {"id_token": encoded({"alg": "none"}) + "." + encoded(claims) + ".synthetic",
                       "access_token": encoded({"alg": "none"}) + "." + encoded(access) + ".synthetic",
                       "refresh_token": "synthetic-refresh-" + str(generation),
                       "account_id": workspace_id},
            "last_refresh": datetime.fromtimestamp(CLOCK + generation, timezone.utc)
                .isoformat().replace("+00:00", "Z")}


class Authority:
    """Rotate one synthetic token family and serve scripted model responses."""

    def __init__(self):
        self.generation = self.rejected_count = self.websocket_probes = 0
        self.accepted_generations, self.authorized_generations = [], []
        self.requests, self.errors = [], []
        self.replies = queue.Queue()
        self.lock = threading.Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, value):
                data = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                # Exact auxiliary routes observed in the pinned runtime.
                if self.path in ("/v1/models?client_version=0.163.0", "/api/codex/accounts/check",
                                 "/api/codex/settings/user"):
                    self.reply(404, {"error": "fixture_auxiliary_unavailable"})
                elif (self.path == "/v1/responses" and self.headers.get("Upgrade", "").lower() == "websocket"
                      and owner.websocket_probes < 16):
                    owner.websocket_probes += 1
                    self.reply(426, {"error": "fixture_requires_http"})
                else:
                    owner.errors.append("Unexpected GET route")
                    self.reply(404, {"error": "unexpected_request"})

            def do_POST(self):
                self.connection.settimeout(5)
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    limit = 4096 if self.path == "/oauth/token" else 2 * 1024 * 1024
                    if (self.path not in ("/oauth/token", "/v1/responses") or not 0 < length <= limit
                            or self.headers.get("Content-Encoding", "identity") != "identity"):
                        raise ValueError()
                    body = json.loads(self.rfile.read(length))
                    if not isinstance(body, dict):
                        raise ValueError()
                    with owner.lock:
                        if self.path == "/oauth/token":
                            if (body.get("grant_type") != "refresh_token" or not isinstance(body.get("client_id"), str)
                                    or len(owner.accepted_generations) + owner.rejected_count >= 16):
                                raise ValueError()
                            if body.get("refresh_token") != bundle(owner.generation)["tokens"]["refresh_token"]:
                                owner.rejected_count += 1
                                self.reply(401, {"error": {"code": "refresh_token_reused"}})
                                return
                            owner.accepted_generations.append(owner.generation)
                            owner.generation += 1
                            self.reply(200, {key: value for key, value in bundle(owner.generation)["tokens"].items()
                                             if key != "account_id"})
                            return
                        if (self.headers.get("Authorization") != "Bearer " + bundle(owner.generation)["tokens"]["access_token"]
                                or len(owner.requests) >= 16):
                            raise ValueError()
                        owner.authorized_generations.append(owner.generation)
                        owner.requests.append(body)
                        events = owner.replies.get_nowait()
                except (ValueError, queue.Empty):
                    owner.errors.append("Unexpected fixture request or authorization")
                    self.reply(400, {"error": "unexpected_request"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    for event in events:
                        self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
                        self.wfile.flush()
                except (OSError, TimeoutError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def enqueue(self, events):
        self.replies.put(events)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


if __name__ == "__main__":
    path = Path(sys.argv[1]) / "auth.json"
    path.write_text(json.dumps(bundle()))
    path.chmod(0o600)
