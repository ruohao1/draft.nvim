#!/usr/bin/env python3
"""One-use, preflighted staged publication; not a multi-file transaction."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat


HERE = Path(__file__).resolve().parent
MAX_BYTES = 1024 * 1024
MAX_FILES = 16
spec = importlib.util.spec_from_file_location("nvim_ai_publish_review", HERE / "nvim-ai-review.py")
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class Conflict(ValueError):
    """A selected original or its parent no longer matches the approved input."""


def _decode(data):
    return json.loads(data, object_pairs_hook=review._unique_object,
                      parse_constant=review._invalid_constant)


def _identity(value, directory=False):
    if (not isinstance(value, list) or len(value) != 4
            or any(type(item) is not int or item < 0 for item in value)
            or not (stat.S_ISDIR(value[2]) if directory else stat.S_ISREG(value[2]))):
        raise ValueError("Invalid recorded inode identity")


def _validate(proposal):
    if (not review._keys(proposal, {"schema", "id", "root", "files"})
            or type(proposal["schema"]) is not int or proposal["schema"] != 2
            or not isinstance(proposal["id"], str)
            or not re.fullmatch(r"[0-9a-f]{32}", proposal["id"])):
        raise ValueError("Invalid staged publication manifest")
    root = proposal["root"]
    review._absolute(root)
    if root == "/" or os.path.realpath(root) != root:
        raise ValueError("Invalid staged publication root")
    files = proposal["files"]
    if not isinstance(files, list) or not 1 <= len(files) <= MAX_FILES:
        raise ValueError("Invalid staged file selection")
    seen, totals = set(), [0, 0]
    for entry in files:
        if not review._keys(entry, {"path", "identity", "expected", "desired"}):
            raise ValueError("Invalid staged file entry")
        path = entry["path"]
        if (not isinstance(path, str) or path in seen or path.startswith("/")
                or any(ord(c) < 32 or ord(c) == 127 for c in path)):
            raise ValueError("Invalid or duplicate staged path")
        parts = review._relative(path.encode("utf-8"))
        if len(parts) > 64:
            raise ValueError("Staged path depth exceeded")
        seen.add(path)
        for index, key in enumerate(("expected", "desired")):
            value = entry[key]
            review._object(value)
            if value["kind"] != "regular" or value["size"] > MAX_BYTES:
                raise ValueError("Only bounded regular staged files are supported")
            totals[index] += value["size"]
        if entry["expected"]["mode"] != entry["desired"]["mode"]:
            raise ValueError("Staged mode changes are unsupported")
        identity = entry["identity"]
        if not isinstance(identity, list) or len(identity) != 2:
            raise ValueError("Invalid staged snapshot identity")
        node, parents = identity
        if (not isinstance(node, list) or len(node) != 5
                or any(type(value) is not int for value in node[1:])
                or node[1] != entry["expected"]["size"] or node[4] != 1):
            raise ValueError("Invalid staged snapshot metadata")
        _identity(node[0])
        mode = 0o755 if entry["expected"]["mode"] == "100755" else 0o644
        if stat.S_IMODE(node[0][2]) != mode or node[0][3] != os.getuid():
            raise ValueError("Invalid staged snapshot ownership or mode")
        if not isinstance(parents, list) or len(parents) != len(parts):
            raise ValueError("Invalid staged parent identities")
        for parent in parents:
            _identity(parent, directory=True)
        if parents[0] != files[0]["identity"][1][0]:
            raise ValueError("Selected files have different recorded roots")
    if any(total > MAX_BYTES for total in totals):
        raise ValueError("Staged aggregate size exceeded")
    # A selected regular file cannot also be another selected file's parent.
    if any(path.startswith(other + "/") for path in seen for other in seen if path != other):
        raise ValueError("Overlapping staged selections")
    return files


def _frozen(task, index, entry):
    result = []
    for prefix, kind in (("before", "expected"), ("after", "desired")):
        data = review._private_bytes(str(task / (prefix + "-" + str(index))), MAX_BYTES)
        text = data.decode("utf-8")
        if ("\0" in text or "\r" in text or text.startswith("\ufeff")
                or (text and not text.endswith("\n")) or text.count("\n") > 20000):
            raise ValueError("Unsupported frozen staged text")
        expected = entry[kind]
        if len(data) != expected["size"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
            raise ValueError("Frozen staged source fingerprint mismatch")
        result.append(data)
    return result


def _write_all(fd, data):
    cursor = 0
    while cursor < len(data):
        size = os.write(fd, data[cursor:])
        if type(size) is not int or not 0 < size <= len(data) - cursor:
            raise OSError("Staged publication write failed")
        cursor += size


def check_approval_active(task_parent):
    """A handoff record retires old publication authority, even if it is torn.

    Call under the shared proposal lock before consuming an approval. Never
    parse or follow the replacement path: mere presence is a fail-closed fence.
    Rejection/cancellation may still finish retiring the old pending decisions.
    """
    task_parent.verify()
    try:
        os.stat(b"followup.json", dir_fd=task_parent.fd, follow_symlinks=False)
    except FileNotFoundError:
        task_parent.verify()
        return
    raise ValueError("Follow-up handoff recorded; the previous approval is inactive")


def _receipt(task_parent, name, value):
    task_parent.verify()
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=task_parent.fd)
    try:
        _write_all(fd, json.dumps(value, ensure_ascii=True, sort_keys=True).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(task_parent.fd)
    task_parent.verify()


def _original(root, record, snapshot):
    try:
        record["parent"].verify()
        data, mode, identity = snapshot(root, record["entry"]["path"])
        expected = record["entry"]["expected"]
        if (identity != record["entry"]["identity"] or len(data) != expected["size"]
                or hashlib.sha256(data).hexdigest() != expected["sha256"]
                or mode != (0o755 if expected["mode"] == "100755" else 0o644)):
            raise Conflict("Selected file changed")
        parents = json.loads(json.dumps(record["parent"].identities))
        if parents != identity[1]:
            raise Conflict("Selected parent changed")
        record["parent"].verify()
    except Exception as error:
        # snapshot belongs to the controller and has its own refusal type.
        # All failures here happen before this record's rename attempt.
        raise Conflict("Selected file or parent changed") from error


def _temporary(record):
    parent, name = record["parent"], record["temporary"]
    parent.verify()
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=parent.fd)
    try:
        record["owned"] = os.fstat(fd)
        _write_all(fd, record["after"])
        os.fchmod(fd, 0o755 if record["entry"]["desired"]["mode"] == "100755" else 0o644)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(parent.fd)
    _check_temporary(record)


def _check_temporary(record):
    parent, name = record["parent"], record["temporary"]
    parent.verify()
    node = os.stat(name, dir_fd=parent.fd, follow_symlinks=False)
    if (not review._same_inode(record["owned"], node) or node.st_uid != os.getuid()
            or node.st_nlink != 1
            or stat.S_IMODE(node.st_mode) != (0o755 if record["entry"]["desired"]["mode"] == "100755" else 0o644)
            or review.fingerprint_at(parent.fd, name) != record["entry"]["desired"]):
        raise ValueError("Prepared staged replacement changed")
    fd = os.open(name, review.READ_FLAGS, dir_fd=parent.fd)
    try:
        if review._snapshot(node) != review._snapshot(os.fstat(fd)) or os.listxattr(fd):
            raise ValueError("Prepared staged replacement metadata changed")
    finally:
        os.close(fd)
    parent.verify()


def _cleanup(records):
    pending = []
    for record in records:
        if record.get("owned") is None:
            continue
        parent, name = record["parent"], record["temporary"]
        try:
            parent.verify()
            try:
                node = os.stat(name, dir_fd=parent.fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not review._same_inode(record["owned"], node):
                # It is no longer our file. Do not unlink it.
                pending.append(record["entry"]["path"])
                continue
            os.unlink(name, dir_fd=parent.fd)
            os.fsync(parent.fd)
        except (OSError, ValueError):
            pending.append(record["entry"]["path"])
    return pending


def publish(task, proposal, snapshot):
    """Publish schema-2 selected files, retaining one-use write-ahead evidence.

    The caller must consume the proposal before calling. Every replacement is
    prepared and all selected originals are checked before the first rename.
    Renames are individually atomic, not collectively atomic or external CAS.
    No failure path retries publication or restores older project bytes.
    """
    records, attempted, applied = [], [], []
    task_parent, root_fd, result = None, None, None
    journal = False
    changed, unchanged = [], []
    try:
        files = _validate(proposal)
        changed = [entry["path"] for entry in files if entry["expected"] != entry["desired"]]
        unchanged = [entry["path"] for entry in files if entry["expected"] == entry["desired"]]
        if not changed:
            raise ValueError("A publication needs at least one changed file")
        task = Path(task)
        if (str(task) != os.path.realpath(task) or task.parent != Path("/tmp")
                or not task.name.startswith("nvim-ai-staged-")):
            raise ValueError("Invalid private staged task")
        task_parent = review.open_parent(str(task), b"publication.json")
        node = os.fstat(task_parent.fd)
        if node.st_uid != os.getuid() or stat.S_IMODE(node.st_mode) != 0o700:
            raise ValueError("Invalid private staged task mode")
        consumed = _decode(review._private_bytes(str(task / "consumed.json"), 1024))
        if consumed != {"choice": "approve", "id": proposal["id"]}:
            raise ValueError("Staged proposal was not consumed for approval")
        check_approval_active(task_parent)
        # Persist the caller's one-use marker before any project replacement.
        os.fsync(task_parent.fd)
        try:
            os.stat(b"publication.json", dir_fd=task_parent.fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            return {"phase": "already_decided", "reason": "Publication already started; inspect retained receipts. No replay.",
                    "applied": [], "uncertain": changed, "not_attempted": [], "unchanged": unchanged}
        root_fd = os.open(proposal["root"], review.DIRECTORY_FLAGS)
        try:
            fcntl.flock(root_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Conflict("Another staged writer holds this project") from error
        if list(review._identity(os.fstat(root_fd))) != files[0]["identity"][1][0]:
            raise Conflict("Project root changed before the publication lock")
        plan = [{"path": entry["path"], "index": index,
                 "expected": entry["expected"], "desired": entry["desired"],
                 "state": "planned" if entry["path"] in changed else "unchanged",
                 "temporary": ".nvim-ai-staged-" + os.urandom(16).hex() if entry["path"] in changed else None}
                for index, entry in enumerate(files)]
        _receipt(task_parent, b"publication.json", {
            "schema": 1, "id": proposal["id"], "root": proposal["root"], "files": plan})
        journal = True
        for index, entry in enumerate(files):
            _, after = _frozen(task, index, entry)
            record = {"index": index, "entry": entry, "after": after, "owned": None,
                      "temporary": plan[index]["temporary"].encode("ascii") if plan[index]["temporary"] else None,
                      "parent": review.open_parent(proposal["root"], entry["path"].encode("utf-8"))}
            records.append(record)
            _original(proposal["root"], record, snapshot)
        for record in records:
            if record["entry"]["path"] in changed:
                _temporary(record)
        for record in records:
            _original(proposal["root"], record, snapshot)
        for record in records:
            path = record["entry"]["path"]
            if path not in changed:
                continue
            # Recheck unmodified context and all remaining targets each time;
            # already-published files necessarily have different identities.
            for pending in records:
                if pending["entry"]["path"] not in attempted:
                    _original(proposal["root"], pending, snapshot)
            _check_temporary(record)
            receipt = {"id": proposal["id"], "path": path, "index": record["index"]}
            _receipt(task_parent, ("attempting-" + str(record["index"]) + ".json").encode("ascii"),
                     dict(receipt, state="attempting"))
            # Receipt IO can take time: one last exact check before renaming.
            _original(proposal["root"], record, snapshot)
            _check_temporary(record)
            parent = record["parent"]
            attempted.append(path)
            os.rename(record["temporary"], parent.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            record["owned"] = None
            os.fsync(parent.fd)
            parent.verify()
            if review.fingerprint_at(parent.fd, parent.name) != record["entry"]["desired"]:
                raise ValueError("Staged post-write fingerprint mismatch")
            parent.verify()
            _receipt(task_parent, ("applied-" + str(record["index"]) + ".json").encode("ascii"),
                     dict(receipt, state="applied"))
            applied.append(path)
        result = {"phase": "applied", "reason": "All approved files individually published and confirmed; not a multi-file atomic transaction."}
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        if attempted:
            phase = "uncertain" if any(path not in applied for path in attempted) else "partial"
            reason = "Publication stopped. Inspect disk and retained receipts; some files may have changed. No retry or rollback."
        else:
            phase = "conflicted" if isinstance(error, Conflict) else "blocked"
            reason = "Publication refused before any target replacement. Proposal consumed; review current files before a new turn."
        result = {"phase": phase, "reason": reason}
    finally:
        cleanup_pending = _cleanup(records)
        if result is not None:
            result.update(applied=applied[:], uncertain=[path for path in attempted if path not in applied],
                          not_attempted=[path for path in changed if path not in attempted], unchanged=unchanged,
                          cleanup_pending=cleanup_pending)
            if task_parent is not None and journal:
                try:
                    _receipt(task_parent, b"result.json", dict(result, id=proposal["id"]))
                except (OSError, ValueError):
                    result["phase"] = "uncertain" if attempted else "blocked"
                    result["reason"] = "Final receipt could not be confirmed. Inspect disk and retained evidence. No retry or rollback."
        for record in records:
            try:
                record["parent"].close()
            except OSError:
                pass
        if root_fd is not None:
            try:
                os.close(root_fd)
            except OSError:
                pass
        if task_parent is not None:
            try:
                task_parent.close()
            except OSError:
                pass
    return result
