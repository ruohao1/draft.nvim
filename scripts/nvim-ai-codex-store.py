"""Own one private Codex home; inspect retained state through metadata only."""
from contextlib import ExitStack
from datetime import datetime
import importlib.util
import os
from pathlib import Path
import re
import secrets
import stat


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


review = helper("nvim-ai-review")
protocol = helper("nvim-ai-conversation-protocol")
acp = helper("nvim-ai-acp-worker")
ProtocolError = acp.ProtocolError
MAX_BYTES, MAX_ENTRIES, MAX_DEPTH = 64 * 1024 * 1024, 4096, 8
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
DATABASES = {"goals_1.sqlite", "logs_2.sqlite", "memories_1.sqlite", "queue_1.sqlite",
             "state_5.sqlite", "thread_history_1.sqlite"}
FILES = {"auth.json", "config.toml", "installation_id", ".sandbox_migration", "models_cache.json"} | {
    name + suffix for name in DATABASES for suffix in ("", "-wal", "-shm")}


class Refused(RuntimeError):
    """Diagnostics never contain backend filenames, payloads or OS errors."""


def _identity(node):
    return node.st_dev, node.st_ino, node.st_mode, node.st_uid, node.st_gid


def _snapshot(node):
    return _identity(node), node.st_size, node.st_mtime_ns, node.st_ctime_ns, node.st_nlink


def _allowed(path, directory):
    parts = path.split("/")
    if directory:
        return (path in ("sessions", "thread-writer-locks", "tmp")
                or re.fullmatch(r"sessions/[0-9]{4}(?:/(?:0[1-9]|1[0-2])(?:/(?:0[1-9]|[12][0-9]|3[01]))?)?", path) is not None)
    if len(parts) == 1:
        return path in FILES
    if len(parts) == 2 and parts[0] == "thread-writer-locks":
        return parts[1] == ".coordination.lock" or re.fullmatch(UUID + r"\.lock", parts[1]) is not None
    match = re.fullmatch(r"sessions/([0-9]{4})/([0-9]{2})/([0-9]{2})/"
                         r"rollout-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2})-"
                         + UUID + r"\.jsonl", path)
    if match is None or "-".join(match.groups()[:3]) != match[4][:10]:
        return False
    try:
        datetime.strptime(match[4], "%Y-%m-%dT%H-%M-%S")
    except ValueError:
        return False
    return True


def _auth(raw):
    value = protocol.decode_json(raw)
    if not isinstance(value, dict) or value.keys() - {
            "auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"}:
        raise ValueError()
    mode, key, tokens = value.get("auth_mode"), value.get("OPENAI_API_KEY"), value.get("tokens")
    if mode not in (None, "apikey", "chatgpt"):
        raise ValueError()
    if key is not None:
        if not isinstance(key, str) or not key.strip() or tokens is not None or mode == "chatgpt":
            raise ValueError()
    else:
        if (mode == "apikey" or not isinstance(tokens, dict)
                or tokens.keys() - {"id_token", "access_token", "refresh_token", "account_id"}
                or any(not isinstance(tokens.get(k), str) or not tokens[k].strip()
                       for k in ("id_token", "access_token", "refresh_token"))
                or (tokens.get("account_id") is not None
                    and (not isinstance(tokens["account_id"], str) or not tokens["account_id"]))):
            raise ValueError()
        if re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", tokens["id_token"]) is None:
            raise ValueError()
    if value.get("last_refresh") is not None:
        stamp = value["last_refresh"]
        if (not isinstance(stamp, str) or not stamp.endswith("Z")
                or datetime.fromisoformat(stamp).tzinfo is None):
            raise ValueError()


class Store:
    private_roots = frozenset(FILES | {"sessions", "thread-writer-locks"})

    def __init__(self, parent="/tmp"):
        parent = os.fspath(parent)
        if (not hasattr(os, "O_PATH") or not isinstance(parent, str) or not parent.startswith("/")
                or parent == "/" or os.path.normpath(parent) != parent
                or os.path.realpath(parent) != parent or len(os.fsencode(parent)) > 4000
                or any(ord(char) < 32 or ord(char) == 127 for char in parent)):
            raise Refused("Store requires a canonical private parent on Linux")
        self.root = Path(parent) / ("nvim-ai-codex-" + secrets.token_hex(16))
        self.path = self.root / "backend-store"
        self._worker, self._failed = None, None
        self._closed = self.initialized = False
        self._sealed = {}
        self._fds = ExitStack()
        try:
            self._parent = self._fds.enter_context(review.open_parent("/", os.fsencode(str(self.root)[1:])))
            self._parent.verify()
            os.mkdir(self._parent.name, 0o700, dir_fd=self._parent.fd)
            self._root = os.open(self._parent.name, review.DIRECTORY_FLAGS, dir_fd=self._parent.fd)
            self._fds.callback(os.close, self._root)
            os.mkdir("backend-store", 0o700, dir_fd=self._root)
            self._backend = os.open("backend-store", review.DIRECTORY_FLAGS, dir_fd=self._root)
            self._fds.callback(os.close, self._backend)
            self._root_identity = _identity(os.fstat(self._root))
            self._backend_identity = _identity(os.fstat(self._backend))
            self.check()
        except BaseException:
            self._fds.close()
            raise

    def _verify(self):
        self._parent.verify()
        for fd, name, parent, expected in (
                (self._root, self._parent.name, self._parent.fd, self._root_identity),
                (self._backend, "backend-store", self._root, self._backend_identity)):
            node = os.fstat(fd)
            if (not stat.S_ISDIR(node.st_mode) or node.st_uid != os.getuid()
                    or stat.S_IMODE(node.st_mode) != 0o700 or _identity(node) != expected
                    or _identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != expected):
                raise Refused("Codex store directory identity or permissions changed")
        if os.listdir(self._root) != ["backend-store"]:
            raise Refused("Unexpected Codex store root entry")

    def _inventory(self, *, stable=True, budget=True):
        self._verify()
        values, total = {}, 0

        def visit(fd, prefix="", depth=0):
            nonlocal total
            if depth > MAX_DEPTH:
                raise Refused("Codex store depth budget exceeded")
            names = set()
            with os.scandir(fd) as entries:
                for entry in entries:
                    path = prefix + entry.name
                    if path in values or len(values) >= MAX_ENTRIES:
                        raise Refused("Codex store entry budget exceeded")
                    names.add(entry.name)
                    try:
                        before = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                        descriptor = os.open(entry.name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                    except FileNotFoundError:
                        if not stable:
                            continue
                        raise
                    try:
                        node = os.fstat(descriptor)
                        directory = stat.S_ISDIR(node.st_mode)
                        mode = stat.S_IMODE(node.st_mode)
                        if (not _allowed(path, directory) or node.st_uid != os.getuid()
                                or _identity(node) != _identity(before)
                                or (stable and _snapshot(node) != _snapshot(before))
                                or (directory and mode != 0o700)
                                or (not directory and (not stat.S_ISREG(node.st_mode)
                                    or node.st_nlink != 1
                                    or mode not in ((0o600, 0o644) if path == "installation_id" else (0o600,))))):
                            raise Refused("Unsafe or unexpected Codex store artifact")
                        values[path] = _snapshot(node)
                        if directory:
                            child = os.open(entry.name, review.DIRECTORY_FLAGS, dir_fd=fd)
                            try:
                                if _identity(os.fstat(child)) != _identity(node):
                                    raise Refused("Codex store directory replaced")
                                visit(child, path + "/", depth + 1)
                            finally:
                                os.close(child)
                        else:
                            total += node.st_size
                            if budget and total > MAX_BYTES:
                                raise Refused("Codex store byte budget exceeded")
                        after = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                        if _identity(after) != _identity(node) or (stable and _snapshot(after) != _snapshot(node)):
                            raise Refused("Codex store artifact changed during inspection")
                    except FileNotFoundError:
                        if stable:
                            raise
                    finally:
                        os.close(descriptor)
            if stable and set(os.listdir(fd)) != names:
                raise Refused("Codex store entries changed during inspection")

        visit(self._backend)
        self._verify()
        return values

    def initialize(self, auth_file):
        if self.initialized or self._worker is not None or self._closed or self._failed:
            raise Refused("Codex credentials can only be imported once")
        self.check()
        try:
            raw = review._private_bytes(auth_file, 1024 * 1024)
            _auth(raw)
        except (OSError, ValueError, TypeError, protocol.Refused):
            raise Refused("Configure a private supported Codex credential file") from None
        try:
            self._verify()
            for name, data in (("auth.json", raw), ("config.toml", b"")):
                with os.fdopen(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                       | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self._backend), "wb") as output:
                    output.write(data)
                    output.flush()
                    os.fsync(output.fileno())
            os.mkdir("tmp", 0o700, dir_fd=self._backend)
            self._sealed = self._inventory()
            self.initialized = True
        except (OSError, ValueError, Refused):
            self._failed = "Codex credential import incomplete"
            raise Refused(self._failed) from None

    def check(self):
        if self._closed or self._failed:
            raise Refused(self._failed or "Codex store is closed")
        try:
            values = self._inventory(stable=self._worker is None)
            if self._worker is None and values != self._sealed:
                raise Refused("Codex store changed while no worker was active")
            return {path: node[1] for path, node in values.items()}
        except (OSError, ValueError, Refused) as error:
            self._failed = str(error) if isinstance(error, Refused) else "Codex store validation failed"
            raise Refused(self._failed) from None

    def start(self, command, *, env, **worker_options):
        if not self.initialized or self._worker is not None:
            raise Refused("Codex store is uninitialized or already in use")
        if "guard" in worker_options or "wire" in worker_options:
            raise Refused("Codex store owns its guard and wire codec")
        self.check()
        self._worker = acp.Worker(command, env=env, guard=self.check, wire="codex", **worker_options)
        return self._worker

    def stop(self, *, outcome, session=None):
        if self._worker is None:
            raise Refused("No Codex worker is active")
        result = self._worker.close()
        if not result.reaped or not result.output_closed:
            self._failed = "Codex worker exit unproven; explicit recovery required"
            raise Refused(self._failed)
        self._worker = None
        try:
            if self._failed or not result.settled or outcome not in ("completed", "cancelled"):
                raise Refused(self._failed or "Codex worker outcome cannot authorize reuse")
            values = self._inventory()
            if session is not None and (not isinstance(session, str)
                    or re.fullmatch(UUID, session) is None
                    or not any(path.startswith("sessions/") and path.endswith("-" + session + ".jsonl")
                               and node[1] > 0 for path, node in values.items())):
                raise Refused("Persisted Codex thread rollout missing")
            self._sealed = values
            return result
        except (OSError, ValueError, Refused) as error:
            self._failed = str(error) if isinstance(error, Refused) else "Codex store validation failed"
            raise Refused(self._failed) from None

    def close(self):
        if self._closed:
            return
        if self._worker is not None:
            raise Refused("Cannot remove Codex state before worker exit is proven")
        try:
            values = self._inventory(budget=False)
            # Validate the entire tree before deletion; never follow or adopt replacements.
            for path in sorted(values, key=lambda p: p.count("/"), reverse=True):
                expected = values[path]
                self._verify()
                with review.open_parent(str(self.path), os.fsencode(path)) as parent:
                    parent.verify()
                    for index, fd in enumerate(parent.fds):
                        ancestor = "/".join(path.split("/")[:index])
                        identity = values[ancestor][0] if index else self._backend_identity
                        if _identity(os.fstat(fd)) != identity:
                            raise Refused("Codex store ancestor changed during cleanup")
                    node = os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False)
                    directory = stat.S_ISDIR(node.st_mode)
                    if (_identity(node) != expected[0]
                            or (not directory and _snapshot(node) != expected)):
                        raise Refused("Codex store artifact changed during cleanup")
                    (os.rmdir if directory else os.unlink)(parent.name, dir_fd=parent.fd)
            self._verify()
            os.rmdir("backend-store", dir_fd=self._root)
            self._parent.verify()
            if _identity(os.stat(self._parent.name, dir_fd=self._parent.fd,
                                 follow_symlinks=False)) != self._root_identity:
                raise Refused("Codex store root changed during cleanup")
            os.rmdir(self._parent.name, dir_fd=self._parent.fd)
            os.fsync(self._parent.fd)
            self._fds.close()
            self._closed = True
        except (OSError, ValueError, Refused):
            self._failed = "Codex state cleanup incomplete; explicit recovery required"
            raise Refused(self._failed) from None
