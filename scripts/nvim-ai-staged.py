#!/usr/bin/env python3
"""Opt-in, explicitly selected-file ACP staging. Only editor approval publishes."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import resource
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
MAX_BYTES = 1024 * 1024
MAX_MESSAGE = 16 * MAX_BYTES
MAX_FILES = 16
VERSION = "1.18.30"
PROJECT = "/tmp/project"
AGENT = "/tmp/agent"
SYSTEM_FILES = ("/etc/ssl", "/etc/ca-certificates", "/etc/resolv.conf", "/etc/hosts",
                "/etc/nsswitch.conf", "/etc/localtime")


class Refused(Exception):
    """A diagnostic containing no provider output, credentials, or file content."""


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


review = helper("nvim-ai-review")


def decode(raw):
    return json.loads(raw, object_pairs_hook=review._unique_object,
                      parse_constant=review._invalid_constant)


def private_write(path, payload):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                           0o600), "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def json_write(path, value):
    private_write(path, json.dumps(value, ensure_ascii=True).encode())


def fingerprint(data, mode):
    return {"kind": "regular", "mode": "100755" if mode == 0o755 else "100644",
            "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def text_bytes(data):
    text = data.decode("utf-8")
    if len(data) > MAX_BYTES or "\0" in text or "\r" in text or text.startswith("\ufeff"):
        raise Refused("Only UTF-8 text without BOM, NUL, or CR is supported")
    if text and not text.endswith("\n"):
        raise Refused("The selected file must end with a newline")
    if text.count("\n") > 20000:
        raise Refused("The single-file diff is limited to 20000 lines")
    return text


def canonical(path):
    if (not isinstance(path, str) or not path.startswith("/") or path == "/"
            or os.path.normpath(path) != path or os.path.realpath(path) != path
            or any(ord(c) < 32 or ord(c) == 127 for c in path)):
        raise Refused("Paths must be canonical, bounded, and free of symlinks")
    return path


def selected_path(root, path):
    canonical(root)
    if (not isinstance(path, str) or len(path.encode()) > 4096
            or path.startswith("/") or any(p in ("", ".", "..") for p in path.split("/"))
            or any(ord(c) < 32 or ord(c) == 127 for c in path)):
        raise Refused("Invalid selected relative path")
    parts = path.split("/")
    if len(parts) > 64:
        raise Refused("Selected paths are limited to 64 components")
    if any(p.lower() in (".git", ".ssh", ".gnupg", "auth.json")
           or p.lower().startswith(".env") or p.lower().endswith((".pem", ".key")) for p in parts):
        raise Refused("Metadata and credential paths are not supported")
    canonical(os.path.join(root, path))
    return path.encode("utf-8")


def snapshot(root, path):
    raw_path = selected_path(root, path)
    with review.open_parent(root, raw_path) as parent:
        before = os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) not in (0o644, 0o755)
                or before.st_size > MAX_BYTES):
            raise Refused("Select an owned regular file, mode 0644/0755, one link, at most 1 MiB")
        fd = os.open(parent.name, review.READ_FLAGS, dir_fd=parent.fd)
        try:
            if review._snapshot(before) != review._snapshot(os.fstat(fd)):
                raise Refused("File changed during snapshot")
            if os.listxattr(fd):
                raise Refused("Files with extended attributes or ACLs are not supported")
            data = review._read_fd(fd, before, MAX_BYTES)
        finally:
            os.close(fd)
        parent.verify()
        if review._snapshot(before) != review._snapshot(os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False)):
            raise Refused("File changed during snapshot")
        text_bytes(data)
        # JSON-stable metadata also catches replacements with identical bytes.
        identity = json.loads(json.dumps([review._snapshot(before), parent.identities]))
        return data, stat.S_IMODE(before.st_mode), identity


def executable(path):
    canonical(path)
    node = os.lstat(path)
    if (not stat.S_ISREG(node.st_mode) or node.st_uid not in (0, os.getuid())
            or node.st_mode & 0o022 or not os.access(path, os.X_OK)):
        raise Refused("Untrusted executable")
    return path


def configuration(request, agent):
    model = request.get("model")
    if not isinstance(model, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]+/[^\s\x00-\x1f]+", model):
        raise Refused("Configure an explicit provider/model")
    provider = model.split("/", 1)[0]
    config = {
        "autoupdate": False, "model": model, "small_model": model,
        "enabled_providers": [provider], "snapshot": False, "share": "disabled",
        "formatter": False, "lsp": False,
        "permission": {"*": "deny", "read": "allow", "edit": "ask"},
        "agent": {name: {"disable": True} for name in
                  ("title", "summary", "compaction", "general", "explore")},
    }
    # Optional explicit self-hosted provider configuration, never project config.
    if request.get("provider"):
        value = request["provider"]
        if not isinstance(value, dict) or set(value) != {provider}:
            raise Refused("Provider configuration must match the selected model")
        config["provider"] = value
    if request.get("auth_file"):
        profile = helper("nvim-ai-opencode-profile")
        payload, _ = profile._secure_read_path(request["auth_file"], MAX_BYTES, "credential", False)
        filtered, _ = profile._decode_auth_bytes(payload)
        if provider not in filtered:
            raise Refused("No credential for the selected provider")
        (agent / "data/opencode").mkdir(mode=0o700)
        json_write(agent / "data/opencode/auth.json", {provider: filtered[provider]})
    return config


def sandbox(request, task, config):
    # Construct a fresh filesystem, not a writable host-root clone. The actual
    # project and the trusted proposal directory are not mounted into the agent.
    command = [executable(request["bwrap"]), "--new-session", "--unshare-pid",
               "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--ro-bind", "/usr", "/usr"]
    for name in ("bin", "sbin", "lib", "lib64"):
        source = "/" + name
        if os.path.islink(source):
            command += ["--symlink", os.readlink(source), source]
        elif os.path.isdir(source):
            command += ["--ro-bind", source, source]
    for source in SYSTEM_FILES:
        if os.path.exists(source):
            command += ["--ro-bind", source, source]
    command += ["--tmpfs", "/tmp", "--dir", "/home", "--dir", "/root", "--dir", "/run",
                "--dir", "/opt", "--dev", "/dev", "--proc", "/proc",
                "--bind", str(task / "agent"), AGENT,
                "--bind", str(task / "staging"), PROJECT,
                "--ro-bind", executable(request["opencode"]), "/opt/opencode",
                "--ro-bind", str(task / "config.json"), "/opt/config.json",
                "--chdir", PROJECT, "--", "/opt/opencode", "acp", "--cwd", PROJECT]
    env = {"PATH": "/usr/bin:/bin", "HOME": AGENT + "/home", "LANG": "C.UTF-8",
           "SHELL": "/bin/sh", "TERM": "dumb", "OPENCODE_CONFIG": "/opt/config.json"}
    for name in ("CONFIG", "DATA", "CACHE", "STATE"):
        env["XDG_" + name + "_HOME"] = AGENT + "/" + name.lower()
    for flag in ("PURE", "DISABLE_AUTOUPDATE", "DISABLE_CLAUDE_CODE", "DISABLE_EXTERNAL_SKILLS",
                 "DISABLE_PROJECT_CONFIG", "DISABLE_LSP_DOWNLOAD", "DISABLE_MODELS_FETCH"):
        env["OPENCODE_" + flag] = "true"
    json_write(task / "config.json", config)
    return command, env


def read_messages(stream, destination, origin):
    try:
        while True:
            line = stream.readline(MAX_MESSAGE + 1)
            if not line:
                break
            if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
                break
            value = decode(line)
            if not isinstance(value, dict):
                break
            destination.put((origin, value))
    except (OSError, ValueError, UnicodeError):
        pass
    destination.put((origin, None))


def acp_turn(request, task, editor):
    paths = [PROJECT + "/" + item["path"] for item in request["files"]]
    agent = task / "agent"
    for name in ("home", "config", "data", "cache", "state"):
        (agent / name).mkdir(mode=0o700, parents=True)
    command, env = sandbox(request, task, configuration(request, agent))
    messages = queue.Queue(maxsize=64)
    child = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
    os.set_blocking(child.stdin.fileno(), False)
    threading.Thread(target=read_messages, args=(child.stdout, messages, "agent"), daemon=True).start()
    deadline, count = time.monotonic() + 180, 0

    def send(value):
        payload = (json.dumps(dict(jsonrpc="2.0", **value)) + "\n").encode()
        while payload:
            if time.monotonic() >= deadline:
                raise Refused("Agent input timed out")
            readable, writable, _ = select.select([editor], [child.stdin], [], .2)
            if readable:
                raise Refused("Cancelled or editor disconnected; no project publication")
            if writable:
                try:
                    payload = payload[os.write(child.stdin.fileno(), payload):]
                except BlockingIOError:
                    pass

    def response(identifier, method, params):
        nonlocal count
        send({"id": identifier, "method": method, "params": params})
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Refused("Agent turn timed out")
            if select.select([editor], [], [], 0)[0]:
                raise Refused("Cancelled or editor disconnected; no project publication")
            try:
                origin, value = messages.get(timeout=min(remaining, 1))
            except queue.Empty:
                continue
            if value is None:
                raise Refused("ACP stopped or returned invalid data; no project publication")
            count += 1
            if count > 20000:
                raise Refused("ACP message limit exceeded")
            if "method" not in value and value.get("id") == identifier:
                if "error" in value or not isinstance(value.get("result"), dict):
                    raise Refused("ACP request failed; no project publication")
                return value["result"]
            if "id" not in value:
                continue
            if value.get("method") == "session/request_permission":
                params = value.get("params", {})
                call = params.get("toolCall", {})
                diffs = [x for x in call.get("content", []) if x.get("type") == "diff"]
                allowed = (call.get("kind") == "edit" and diffs
                           and all(x.get("path") in paths for x in diffs))
                option = next((x.get("optionId") for x in params.get("options", [])
                               if x.get("kind") == "allow_once"), None) if allowed else None
                outcome = {"outcome": "selected", "optionId": option} if option else {"outcome": "cancelled"}
                send({"id": value["id"], "result": {"outcome": outcome}})
            else:
                # Including fs/write_text_file: agent JSON never reaches the writer.
                send({"id": value["id"], "error": {"code": -32601, "message": "Client capability disabled"}})

    try:
        info = response(1, "initialize", {"protocolVersion": 1,
            "clientInfo": {"name": "nvim-ai-staged", "version": "0.1"},
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
        if info.get("protocolVersion") != 1 or info.get("agentInfo", {}).get("version") != VERSION:
            raise Refused("This opt-in path requires OpenCode 1.18.30 / ACP 1")
        session = response(2, "session/new", {"cwd": PROJECT, "mcpServers": []})
        if not isinstance(session.get("sessionId"), str):
            raise Refused("ACP session identity is missing")
        scope = ("Edit only " + paths[0]) if len(paths) == 1 else (
            "Edit only these selected paths (JSON): " + json.dumps(paths, ensure_ascii=True))
        result = response(3, "session/prompt", {"sessionId": session["sessionId"], "prompt": [{
            "type": "text", "text": scope
            + ". This is an isolated selected-file copy, not the real project. "
            + "All other files are unavailable. Do not create, delete, rename, or change file modes. "
            + "Shell tools are disabled.\n\n" + request["prompt"]}]})
        if result.get("stopReason") != "end_turn":
            raise Refused("Agent turn did not finish normally")
    finally:
        # Bubblewrap is the owned PID-namespace supervisor; exiting it kills
        # namespace descendants, even background tools that changed process group.
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=3)
        child.stdin.close()
        child.stdout.close()


def staged_snapshot(task, selected):
    paths = {item["path"] for item in selected}
    expected = set(paths)
    for path in paths:
        parts = path.split("/")
        expected.update("/".join(parts[:i]) for i in range(1, len(parts)))
    observed = set()
    for root, dirs, files in os.walk(task / "staging", followlinks=False):
        for name in dirs + files:
            relative = str((Path(root) / name).relative_to(task / "staging"))
            observed.add(relative)
            if relative not in expected or (relative not in paths and not stat.S_ISDIR(os.lstat(Path(root) / name).st_mode)):
                raise Refused("Extra paths or unsupported entries in staging; nothing published")
    if observed != expected:
        raise Refused("Staged deletion is unsupported; nothing published")
    values, total = [], 0
    for item in selected:
        data, actual_mode, _ = snapshot(str(task / "staging"), item["path"])
        if actual_mode != item["mode"]:
            raise Refused("Staged mode changes are unsupported; nothing published")
        total += len(data)
        if total > MAX_BYTES:
            raise Refused("The selected-file proposal is limited to 1 MiB in total")
        values.append(data)
    return values


def selected_files(request):
    root = canonical(request["root"])
    # System runtime mounts are intentionally visible to the agent. A project
    # must not overlap them, or unselected project files could become readable.
    for source in ("/usr", "/bin", "/sbin", "/lib", "/lib64") + SYSTEM_FILES:
        if not os.path.exists(source):
            continue
        for visible in (source, os.path.realpath(source)):
            if root == visible or root.startswith(visible + "/") or visible.startswith(root + "/"):
                raise Refused("Project root overlaps a system runtime mount; select a separate project")
    multi = "files" in request
    if multi and ("path" in request or "snapshot_sha256" in request):
        raise Refused("Choose either a single-file request or an explicit file list")
    files = request["files"] if multi else [{"path": request.get("path"),
        "snapshot_sha256": request.get("snapshot_sha256")}]
    if not isinstance(files, list) or not 1 <= len(files) <= MAX_FILES:
        raise Refused("Select between 1 and 16 existing files")
    selected, paths, total = [], set(), 0
    for item in files:
        if not review._keys(item, {"path", "snapshot_sha256"}) or not review._hex(item["snapshot_sha256"], 64):
            raise Refused("Invalid selected-file snapshot request")
        path = item["path"]
        selected_path(request["root"], path)
        if path in paths:
            raise Refused("Selected paths must be unique")
        paths.add(path)
        before, mode, identity = snapshot(request["root"], path)
        expected = fingerprint(before, mode)
        if item["snapshot_sha256"] != expected["sha256"]:
            raise Refused("Saved file and editor snapshot differ")
        total += len(before)
        if total > MAX_BYTES:
            raise Refused("Selected files are limited to 1 MiB in total")
        selected.append({"path": path, "before": before, "mode": mode,
                         "identity": identity, "expected": expected})
    return selected, multi


def sync_directory(path):
    fd = os.open(path, review.DIRECTORY_FLAGS)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def discard_workspace(task):
    """Discard a task created by this invocation, only after its worker stops."""
    shutil.rmtree(task)


def prepare_workspace(request, selected):
    """Copy trusted source snapshots; this boundary never launches an agent."""
    editable = [item for item in selected if not item.get("context_only")]
    if not editable or sum(len(item.get("seed", item["before"])) for item in selected) > MAX_BYTES:
        raise Refused("Follow-up requires pending files within the 1 MiB total limit")
    task = Path(tempfile.mkdtemp(prefix="nvim-ai-staged-", dir="/tmp"))
    try:
        staging = task / "staging"
        for item in editable:
            destination = staging / item["path"]
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            private_write(destination, item.get("seed", item["before"]))
            os.chmod(destination, item["mode"])
        return task
    except BaseException:
        discard_workspace(task)
        raise


def freeze_workspace(task, root, selected, *, multi, force_review=False):
    """Validate and freeze a stopped workspace; never publish to the project."""
    editable = [item for item in selected if not item.get("context_only")]
    changed = dict(zip([item["path"] for item in editable], staged_snapshot(task, editable)))
    values = [changed.get(item["path"], item["before"]) for item in selected]
    if sum(map(len, values)) > MAX_BYTES:
        raise Refused("The selected-file proposal is limited to 1 MiB in total")
    if not force_review and all(after == item["before"] for item, after in zip(selected, values)):
        return {"phase": "unchanged", "reason": "Agent stopped; no staged change to review"}
    records, files = [], []
    for index, (item, after) in enumerate(zip(selected, values)):
        records.append({"path": item["path"], "identity": item["identity"],
                        "expected": item["expected"], "desired": fingerprint(after, item["mode"])})
        private_write(task / ("before-" + str(index) if multi else "before"), item["before"])
        private_write(task / ("after-" + str(index) if multi else "after"), after)
        files.append({"path": item["path"], "oldText": text_bytes(item["before"]), "newText": text_bytes(after)})
    proposal = {"schema": 2 if multi else 1, "id": os.urandom(16).hex(), "root": root}
    proposal.update({"files": records} if multi else records[0])
    json_write(task / "proposal.json", proposal)
    # Credentials, mutable staging and agent state do not outlive the turn.
    if (task / "agent").exists():
        shutil.rmtree(task / "agent")
    shutil.rmtree(task / "staging")
    (task / "config.json").unlink(missing_ok=True)
    sync_directory(task)
    result = {"phase": "review_ready", "proposal": str(task / "proposal.json"), "id": proposal["id"],
              "files": files, "reason": "Agent stopped. Real project unchanged. Review the frozen proposal."}
    if len(files) == 1:
        result.update(files[0])
    return result


def prepare(request, editor, selected=None, force_review=False):
    if not isinstance(request.get("prompt"), str) or not 0 < len(request["prompt"]) <= 32768:
        raise Refused("Provide a nonempty prompt of at most 32768 characters")
    if selected is None:
        selected, multi = selected_files(request)
    else:
        # Internal refinement inputs only; callers cannot add seeds through JSON.
        multi = True
    task = prepare_workspace(request, selected)
    keep = False
    try:
        editable = [item for item in selected if not item.get("context_only")]
        acp_turn(dict(request, files=[{"path": item["path"]} for item in editable]), task, editor)
        result = freeze_workspace(task, request["root"], selected, multi=multi, force_review=force_review)
        keep = result["phase"] == "review_ready"
        return result
    finally:
        if not keep:
            discard_workspace(task)


def decide(manifest, token, choice, path=None, remaining=False):
    canonical(manifest)
    task = Path(manifest).parent
    node = task.lstat()
    if (task.parent != Path("/tmp") or not task.name.startswith("nvim-ai-staged-")
            or not stat.S_ISDIR(node.st_mode) or node.st_uid != os.getuid()
            or stat.S_IMODE(node.st_mode) != 0o700 or Path(manifest).name != "proposal.json"):
        raise Refused("Invalid private proposal directory")
    proposal = decode(review._private_bytes(manifest, MAX_MESSAGE))
    if type(proposal.get("schema")) is not int or proposal["schema"] not in (1, 2) or proposal.get("id") != token:
        raise Refused("Proposal identity mismatch")
    if choice == "cancel" and (path is not None or remaining):
        raise Refused("Cancel only applies to all pending decisions")
    if proposal["schema"] == 1 and (path is not None or remaining):
        raise Refused("File selectors require a multi-file approve/reject proposal")
    # Both schema generations serialize with refinement. In particular, a
    # single-file approval must not race its newly durable handoff receipt.
    lock = review.open_parent(str(task), b"consumed.json")
    try:
        fcntl.flock(lock.fd, fcntl.LOCK_EX)
        lock.verify()
        if review._identity(os.fstat(lock.fd)) != review._identity(node):
            raise Refused("Private proposal directory changed before locking")
        if proposal["schema"] == 2:
            # All schema-2 protocols share this lock. Journal evidence wins over
            # a missing/torn marker, so legacy commands cannot replay a rejection.
            names = os.listdir(lock.fd)
            incremental = path is not None or remaining or "halted.json" in names or any(
                name.startswith("decision-") for name in names)
            if not incremental:
                try:
                    marker = decode(review._private_bytes(str(task / "consumed.json"), 1024))
                    incremental = marker == {"choice": "incremental", "id": token}
                except FileNotFoundError:
                    pass
            if incremental:
                return helper("nvim-ai-staged-decisions").decide(
                    task, proposal, choice, path, remaining, snapshot, locked_parent=lock)
        return legacy_decide(task, proposal, token, choice, lock)
    finally:
        try:
            lock.close()
        except OSError:
            # Read-only lock teardown must not replace a confirmed verdict.
            pass


def legacy_decide(task, proposal, token, choice, locked_parent):
    if choice == "approve":
        try:
            os.stat(b"consumed.json", dir_fd=locked_parent.fd, follow_symlinks=False)
        except FileNotFoundError:
            helper("nvim-ai-staged-publish").check_approval_active(locked_parent)
    # A consumed proposal is never replayed, including after an uncertain write.
    try:
        json_write(task / "consumed.json", {"choice": choice, "id": token})
        sync_directory(task)
    except FileExistsError:
        return {"phase": "already_decided", "reason": "Proposal already consumed; no replay"}
    if choice != "approve":
        shutil.rmtree(task)
        return {"phase": "rejected" if choice == "reject" else "cancelled",
                "reason": "Proposal discarded; project unchanged by this decision"}
    if proposal["schema"] == 2:
        return helper("nvim-ai-staged-publish").publish(task, proposal, snapshot)
    root, path = proposal["root"], proposal["path"]
    # Serializes our own staged writers for this root. Not a filesystem CAS
    # against arbitrary external editors; the helper also checks immediately
    # before its atomic rename. No project lock file is created.
    fd = os.open(canonical(root), review.DIRECTORY_FLAGS)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"phase": "conflicted", "reason": "Another staged writer holds this project"}
        current, mode, identity = snapshot(root, path)
        if identity != proposal["identity"] or fingerprint(current, mode) != proposal["expected"]:
            return {"phase": "conflicted", "reason": "Project file or parent changed after the snapshot"}
        action = {"schema": 1, "root": root, "path_hex": path.encode().hex(),
                  "expected": proposal["expected"], "desired": dict(proposal["desired"], source=str(task / "after"))}
        try:
            review.apply_action(action)
        except (OSError, ValueError):
            # An fsync/post-rename check can fail after publication. Never say
            # unchanged or automatically retry/roll back in that case.
            return {"phase": "uncertain", "reason": "Writer did not confirm publication; inspect disk. Proposal consumed."}
        return {"phase": "applied", "reason": "Approved frozen bytes published by Neovim's writer"}
    finally:
        try:
            os.close(fd)
        except OSError:
            # This read-only root descriptor only holds the serialization lock.
            # Process exit releases it; teardown must not overwrite the already
            # determined publication verdict with a misleading 'blocked'.
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "refine", "approve", "reject", "cancel", "inspect-review"))
    parser.add_argument("--proposal")
    parser.add_argument("--id")
    selector = parser.add_mutually_exclusive_group()
    selector.add_argument("--path")
    selector.add_argument("--remaining", action="store_true")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    try:
        if args.operation in ("prepare", "refine"):
            if args.path is not None or args.remaining:
                raise Refused("File selectors are only valid for approve/reject")
            # Unbuffered: cancellation/EOF must remain visible to select(), and
            # no blocked stdin reader thread may outlive Python finalization.
            with os.fdopen(os.dup(0), "rb", buffering=0) as editor:
                line = editor.readline(MAX_MESSAGE + 1)
                if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
                    raise Refused("Invalid editor request")
                request = decode(line)
                result = (prepare(request, editor) if args.operation == "prepare" else
                          helper("nvim-ai-staged-refine").refine(
                              sys.modules[__name__], request, editor, args.proposal, args.id))
        elif args.operation == "inspect-review":
            if args.path is not None or args.remaining:
                raise Refused("Review inspection takes no decision selectors")
            result = helper("nvim-ai-staged-decisions").read_review(args.proposal, args.id)
        else:
            result = decide(args.proposal, args.id, args.operation, args.path, args.remaining)
    except Refused as error:
        result = {"phase": "blocked", "reason": str(error)}
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        result = {"phase": "blocked", "reason": "Staged operation refused; no success assumed"}
    print(json.dumps(result, ensure_ascii=True), flush=True)


if __name__ == "__main__":
    main()
