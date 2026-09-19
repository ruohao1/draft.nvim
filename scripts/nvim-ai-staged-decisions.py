#!/usr/bin/env python3
"""Incremental, one-use decisions over one immutable staged selection."""
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nvim_ai_decision_publish", HERE / "nvim-ai-staged-publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
review = publisher.review
LIMIT = 1024 * 1024
TERMINAL = {"applied", "rejected", "cancelled", "blocked", "conflicted", "partial", "uncertain"}


def _read(task, name):
    try:
        value = publisher._decode(review._private_bytes(str(task / name), LIMIT))
    except FileNotFoundError:
        return None
    if not isinstance(value, dict):
        raise ValueError("Invalid private decision record")
    return value


def _name(number, suffix=""):
    return "decision-" + str(number) + suffix + ".json"


def _reply(files, states, phase=None, reason=None, cleanup=None):
    paths = lambda state: [entry["path"] for entry, value in zip(files, states) if value == state]
    pending, accepted = paths("pending"), paths("accepted")
    return {"phase": phase or ("review_ready" if pending else "applied" if accepted else "rejected"),
            "reason": reason or ("File decision recorded; remaining files still need review." if pending
                                  else "Selected file decisions finished; prior accepted writes are retained."),
            "decisions": [{"path": entry["path"], "state": state} for entry, state in zip(files, states)],
            "applied": accepted, "rejected": paths("rejected"), "pending": pending,
            "uncertain": paths("uncertain"), "unchanged": paths("unchanged"),
            "not_attempted": paths("pending") + paths("blocked") + paths("cancelled"),
            "cleanup_pending": cleanup or []}


def _stop(states):
    return ["blocked" if value == "pending" else value for value in states]


def _interrupted_cleanup(task, proposal, states, number):
    plan = _read(task, _name(number, "-plan"))
    if plan is None:
        return []
    files = proposal["files"]
    if (not review._keys(plan, {"id", "files"}) or plan["id"] != proposal["id"]
            or not isinstance(plan["files"], list) or len(plan["files"]) != len(files)):
        raise ValueError("Invalid interrupted publication plan")
    pending = []
    for entry, item, state in zip(files, plan["files"], states):
        if (not review._keys(item, {"path", "temporary"}) or item["path"] != entry["path"]
                or (item["temporary"] is not None and (not isinstance(item["temporary"], str)
                    or re.fullmatch(r"\.nvim-ai-staged-[0-9a-f]{32}", item["temporary"]) is None))):
            raise ValueError("Invalid interrupted temporary plan")
        # We do not reopen/delete these paths during recovery. A planned file
        # may remain after process death; inspection of the receipt is required.
        if item["temporary"] is not None and state != "accepted":
            pending.append(entry["path"])
    return pending


def _load(task, proposal, states, current, cleanup):
    """Derive current state only from ordered, complete one-use journal entries."""
    files = proposal["files"]
    previous = None
    for number in range(publisher.MAX_FILES + 1):
        begin = _read(task, _name(number))
        if begin is None:
            # Gaps and orphan receipts are never interpreted as a fresh turn.
            prefix = "decision-"
            for name in os.listdir(task):
                if name.startswith(prefix):
                    tail = name[len(prefix):].split("-", 1)[0].split(".", 1)[0]
                    if not tail.isdecimal() or int(tail) >= number:
                        raise ValueError("Orphan incremental receipt")
            return states, current, number, previous, cleanup
        if (previous in TERMINAL or not review._keys(begin, {"schema", "id", "choice", "targets"})
                or type(begin["schema"]) is not int or begin["schema"] != 1
                or begin["id"] != proposal["id"] or begin["choice"] not in ("approve", "reject", "cancel")
                or not isinstance(begin["targets"], list) or not begin["targets"]
                or any(type(index) is not int or not 0 <= index < len(files) for index in begin["targets"])
                or len(set(begin["targets"])) != len(begin["targets"])
                or any(states[index] != "pending" for index in begin["targets"])):
            raise ValueError("Invalid incremental decision journal")
        attempted = []
        for index in begin["targets"]:
            # Preserve uncertainty even when parsing a torn attempt receipt fails.
            if os.path.lexists(task / _name(number, "-attempting-" + str(index))):
                states[index] = "uncertain"
            trying = _read(task, _name(number, "-attempting-" + str(index)))
            receipt = _read(task, _name(number, "-applied-" + str(index)))
            if trying is not None:
                if trying != {"id": proposal["id"], "index": index, "path": files[index]["path"]}:
                    raise ValueError("Invalid attempted-file receipt")
                attempted.append(index)
            if receipt is not None:
                if (begin["choice"] != "approve" or trying is None
                        or not review._keys(receipt, {"id", "index", "path", "entry"})
                        or receipt["id"] != proposal["id"] or receipt["index"] != index
                        or receipt["path"] != files[index]["path"]):
                    raise ValueError("Invalid accepted-file receipt")
                updated = receipt["entry"]
                if (not isinstance(updated, dict) or updated.get("path") != files[index]["path"]
                        or updated.get("expected") != files[index]["desired"]
                        or updated.get("desired") != files[index]["desired"]):
                    raise ValueError("Invalid accepted-file baseline")
                # A partly accepted selection can temporarily be larger than
                # either complete before/after set; validate this one baseline.
                publisher._validate(dict(proposal, files=[updated]))
                if updated["identity"][1] != files[index]["identity"][1]:
                    raise ValueError("Accepted-file parents changed")
                current[index], states[index] = updated, "accepted"
        # Make candidates visible to the caller before reading a possibly torn
        # completion record; confirmed completion can then narrow this list.
        cleanup[:] = _interrupted_cleanup(task, proposal, states, number)
        result = _read(task, _name(number, "-result"))
        if result is None:
            for index in attempted:
                if states[index] != "accepted":
                    states[index] = "uncertain"
            return _stop(states), current, number + 1, "uncertain", cleanup
        if (not review._keys(result, {"id", "phase", "states", "cleanup_pending"})
                or result["id"] != proposal["id"] or result["phase"] not in TERMINAL | {"review_ready"}
                or not isinstance(result["cleanup_pending"], list)
                or any(path not in [entry["path"] for entry in files] for path in result["cleanup_pending"])):
            raise ValueError("Invalid completed decision receipt")
        expected = states[:]
        if result["phase"] in ("review_ready", "applied", "rejected", "cancelled"):
            for index in begin["targets"]:
                if begin["choice"] == "approve":
                    if expected[index] != "accepted":
                        raise ValueError("Missing accepted-file receipt")
                else:
                    expected[index] = "rejected" if begin["choice"] == "reject" else "cancelled"
            inferred = "cancelled" if begin["choice"] == "cancel" else _reply(files, expected)["phase"]
            if result["phase"] != inferred:
                raise ValueError("Contradictory completed decision phase")
        else:
            for index in attempted:
                if expected[index] != "accepted":
                    recorded = result["states"][index] if isinstance(result["states"], list) and len(result["states"]) == len(files) else None
                    if recorded not in ("blocked", "uncertain"):
                        raise ValueError("Invalid interrupted-file outcome")
                    expected[index] = recorded
            expected = _stop(expected)
        if result["states"] != expected:
            raise ValueError("Contradictory completed decision states")
        states[:], previous, cleanup[:] = expected, result["phase"], result["cleanup_pending"]
    raise ValueError("Too many incremental decisions")


def _lock_proposal(manifest):
    review._absolute(manifest)
    task = Path(manifest).parent
    if (os.path.realpath(manifest) != manifest or len(os.fsencode(manifest)) > 4096
            or any(ord(char) < 32 or ord(char) == 127 for char in manifest)
            or task.parent != Path("/tmp") or not task.name.startswith("nvim-ai-staged-")
            or Path(manifest).name != "proposal.json"):
        raise ValueError("Invalid private proposal path")
    node = task.lstat()
    if (not stat.S_ISDIR(node.st_mode) or node.st_uid != os.getuid()
            or stat.S_IMODE(node.st_mode) != 0o700):
        raise ValueError("Invalid private proposal directory")
    lock = review.open_parent(str(task), b"consumed.json")
    try:
        fcntl.flock(lock.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock.verify()
        if review._identity(os.fstat(lock.fd)) != review._identity(node):
            raise ValueError("Private proposal directory changed")
        return task, lock
    except BaseException:
        try:
            lock.close()
        except OSError:
            pass
        raise


class PendingReview:
    """Locked, read-only eligibility/data until explicit candidate retirement.

    snapshot() validates proposal/frozen bytes and decision receipts and returns
    detached current baselines, pending seeds and context-only flags. It does not
    validate live project files or editor buffers: callers retain those guards.
    retire() accepts only a caller-owned, freshly frozen candidate, records its
    origin, fences old approval and cancels old pending decisions under the lock.
    No method publishes project files. close() only releases this ownership.
    """
    def __init__(self, manifest, token, root, states):
        self._lock, self._retiring = None, False
        self._manifest, self._view = manifest, copy.deepcopy(states)
        try:
            self._task, self._lock = _lock_proposal(manifest)
            original = _read(self._task, "proposal.json")
            if (not isinstance(original, dict) or type(original.get("schema")) is not int
                    or original["schema"] not in (1, 2) or original.get("id") != token
                    or original.get("root") != root):
                raise ValueError("Follow-up proposal identity/root mismatch")
            self._original, self._legacy = original, original["schema"] == 1
            self._proposal = ({"schema": 2, "id": token, "root": root, "files": [
                {key: original[key] for key in ("path", "identity", "expected", "desired")}]}
                if self._legacy else original)
            publisher._validate(self._proposal)
            self.snapshot()
        except BaseException:
            self.close()
            raise

    def _frozen(self, index, entry):
        if not self._legacy:
            return publisher._frozen(self._task, index, entry)
        result = []
        for name, kind in (("before", "expected"), ("after", "desired")):
            data = review._private_bytes(str(self._task / name), publisher.MAX_BYTES)
            text, expected = data.decode("utf-8"), entry[kind]
            if ("\0" in text or "\r" in text or text.startswith("\ufeff")
                    or (text and not text.endswith("\n")) or text.count("\n") > 20000
                    or len(data) != expected["size"] or hashlib.sha256(data).hexdigest() != expected["sha256"]):
                raise ValueError("Invalid frozen staged text or fingerprint")
            result.append(data)
        return result

    def snapshot(self):
        """Revalidate token eligibility under the held lock; never consume it."""
        if self._lock is None or self._retiring:
            raise ValueError("Pending review is closed or its handoff has started")
        publisher.check_approval_active(self._lock)
        if _read(self._task, "proposal.json") != self._original:
            raise ValueError("Proposal changed since review ownership was acquired")
        files = self._proposal["files"]
        states = ["unchanged" if item["expected"] == item["desired"] else "pending" for item in files]
        current = copy.deepcopy(files)
        marker = _read(self._task, "consumed.json")
        if self._legacy:
            if marker is not None or any(name.startswith("decision-") for name in os.listdir(self._lock.fd)):
                raise ValueError("The previous proposal has already been consumed")
        else:
            states, current, number, previous, cleanup = _load(self._task, self._proposal, states, current, [])
            if (previous in TERMINAL or cleanup or os.path.lexists(self._task / "halted.json")
                    or (marker is None and number != 0)
                    or (marker is not None and (marker != {"choice": "incremental", "id": self._proposal["id"]}
                                               or number == 0))
                    or os.path.lexists(self._task / "publication.json")):
                raise ValueError("Previous decision evidence does not permit a follow-up")
        if "pending" not in states or self._view != states:
            raise ValueError("Pending decisions changed; no follow-up permitted")
        for index, (entry, state) in enumerate(zip(current, states)):
            _, seed = self._frozen(index, files[index])
            entry.update(seed=seed if state == "pending" else None, context_only=state != "pending")
        self._lock.verify()
        return {"root": self._proposal["root"], "states": states, "files": current}

    def retire(self, candidate_manifest, candidate_id):
        """Fence this token before making a fresh candidate reviewable.

        Call only after generation has stopped and all selected sources/editor
        guards were revalidated. Failure after fence creation begins is never
        evidence that the old token can be used again, even if the receipt tore.
        """
        context = self.snapshot()
        candidate, candidate_lock = _lock_proposal(candidate_manifest)
        try:
            proposal = _read(candidate, "proposal.json")
            files = publisher._validate(proposal)
            if (proposal["id"] != candidate_id or candidate_id == self._proposal["id"]
                    or proposal["root"] != context["root"] or len(files) != len(context["files"])):
                raise ValueError("Replacement proposal identity or selection changed")
            names = os.listdir(candidate_lock.fd)
            if (any(name in names for name in ("consumed.json", "publication.json", "halted.json", "followup.json"))
                    or any(name.startswith("decision-") for name in names)):
                raise ValueError("Replacement proposal has already been consumed")
            for index, (entry, expected) in enumerate(zip(files, context["files"])):
                if (any(entry[key] != expected[key] for key in ("path", "identity", "expected"))
                        or (expected["context_only"] and entry["desired"] != entry["expected"])):
                    raise ValueError("Replacement must preserve selection, saved baselines and decided context")
                publisher._frozen(candidate, index, entry)
            publisher._receipt(candidate_lock, b"origin.json", {
                "schema": 1, "proposal": self._manifest, "id": self._proposal["id"], "decisions": context["states"]})
            # An attempted handoff may be durable even when its reply or fsync
            # fails. No caller may infer active approval from that missing reply.
            self._retiring = True
            publisher._receipt(self._lock, b"followup.json", {
                "schema": 1, "id": self._proposal["id"], "candidate": candidate_manifest, "candidate_id": candidate_id})
            if self._legacy:
                publisher._receipt(self._lock, b"consumed.json", {"choice": "cancel", "id": self._proposal["id"]})
            else:
                # Cancellation cannot invoke the project snapshot/writer path.
                verdict = decide(self._task, self._proposal, "cancel", None, False, None, locked_parent=self._lock)
                if verdict["phase"] != "cancelled":
                    raise ValueError("Could not confirm retirement; inspect the previous proposal receipts")
        finally:
            try:
                candidate_lock.close()
            except OSError:
                pass

    def close(self):
        if self._lock is not None:
            lock, self._lock = self._lock, None
            try:
                lock.close()
            except OSError:
                pass  # Read-only lock teardown cannot replace a recorded verdict.


def _approve(task, task_parent, proposal, current, states, targets, number, snapshot):
    records, attempted, accepted, cleanup = [], [], [], []
    root_fd, phase = None, None
    try:
        root_fd = os.open(proposal["root"], review.DIRECTORY_FLAGS)
        try:
            fcntl.flock(root_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise publisher.Conflict("Another staged writer holds this project") from error
        if list(review._identity(os.fstat(root_fd))) != current[0]["identity"][1][0]:
            raise publisher.Conflict("Project root changed")
        plan = []
        for index, entry in enumerate(current):
            _, after = publisher._frozen(task, index, proposal["files"][index])
            temporary = ".nvim-ai-staged-" + os.urandom(16).hex() if index in targets else None
            record = {"index": index, "entry": entry, "after": after, "owned": None,
                      "temporary": temporary.encode() if temporary else None,
                      "parent": review.open_parent(proposal["root"], entry["path"].encode())}
            records.append(record)
            plan.append({"path": entry["path"], "temporary": temporary})
            publisher._original(proposal["root"], record, snapshot)
        publisher._receipt(task_parent, _name(number, "-plan").encode(), {"id": proposal["id"], "files": plan})
        for index in targets:
            publisher._temporary(records[index])
        for index in targets:
            for record in records:
                publisher._original(proposal["root"], record, snapshot)
            record, entry = records[index], current[index]
            publisher._check_temporary(record)
            receipt = {"id": proposal["id"], "index": index, "path": entry["path"]}
            publisher._receipt(task_parent, _name(number, "-attempting-" + str(index)).encode(), receipt)
            # Receipt IO may allow concurrent external changes: recheck all context.
            for selected in records:
                publisher._original(proposal["root"], selected, snapshot)
            publisher._check_temporary(record)
            parent = record["parent"]
            prepared = os.stat(record["temporary"], dir_fd=parent.fd, follow_symlinks=False)
            attempted.append(index)
            os.rename(record["temporary"], parent.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            record["owned"] = None
            os.fsync(parent.fd)
            data, mode, identity = snapshot(proposal["root"], entry["path"])
            desired = entry["desired"]
            if (len(data) != desired["size"] or hashlib.sha256(data).hexdigest() != desired["sha256"]
                    or mode != (0o755 if desired["mode"] == "100755" else 0o644)
                    or identity[0][0] != list(review._identity(prepared))
                    or identity[0][2] != prepared.st_mtime_ns
                    or identity[1] != json.loads(json.dumps(parent.identities))):
                raise ValueError("Published replacement identity or bytes changed")
            parent.verify()
            updated = dict(entry, expected=desired, identity=identity)
            publisher._receipt(task_parent, _name(number, "-applied-" + str(index)).encode(), dict(receipt, entry=updated))
            accepted.append(index)
            states[index], current[index], record["entry"] = "accepted", updated, updated
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        phase = ("uncertain" if any(index not in accepted for index in attempted) else "partial" if accepted
                 else "conflicted" if isinstance(error, publisher.Conflict) else "blocked")
        for index in attempted:
            if index not in accepted:
                states[index] = "uncertain"
        states[:] = _stop(states)
    finally:
        cleanup = publisher._cleanup(records)
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
    return phase, cleanup


def decide(task, proposal, choice, path, remaining, snapshot, locked_parent=None):
    """Consume only selected pending files; preserve all earlier accepted writes."""
    files = publisher._validate(proposal)
    task = Path(task)
    states = ["unchanged" if entry["expected"] == entry["desired"] else "pending" for entry in files]
    current = copy.deepcopy(files)
    parent, began, number, phase, cleanup = None, False, 0, None, []
    loading, history = False, False
    try:
        parent = locked_parent or review.open_parent(str(task), b"consumed.json")
        node = os.fstat(parent.fd)
        if (str(task) != os.path.realpath(task) or task.parent != Path("/tmp")
                or not task.name.startswith("nvim-ai-staged-")
                or node.st_uid != os.getuid() or stat.S_IMODE(node.st_mode) != 0o700):
            raise ValueError("Invalid private staged directory")
        # Serializes separate Neovim/helper processes, including opposing choices.
        if locked_parent is None:
            fcntl.flock(parent.fd, fcntl.LOCK_EX)
        parent.verify()
        names = os.listdir(parent.fd)
        history = any(name.startswith("decision-") or name == "publication.json" for name in names)
        loading = True
        states, current, number, previous, cleanup = _load(task, proposal, states, current, cleanup)
        loading = False
        marker = _read(task, "consumed.json")
        if marker is not None and marker != {"choice": "incremental", "id": proposal["id"]}:
            # Legacy approval may already have written; do not call its paths
            # definitely unattempted merely because it used older receipts.
            if marker.get("choice") == "approve" and number == 0:
                states = ["uncertain" if state == "pending" else state for state in states]
            return _reply(files, _stop(states), "uncertain" if number else "already_decided", "Proposal already consumed by another decision protocol.")
        if marker is None and number:
            return _reply(files, _stop(states), "uncertain", "Incremental consumption marker is missing; no remaining publication.", cleanup)
        if os.path.lexists(task / "halted.json") or (marker is not None and number == 0):
            return _reply(files, _stop(states), "uncertain", "Interrupted decision; retained evidence must be inspected. No remaining publication.", cleanup)
        if previous in TERMINAL:
            return _reply(files, states, previous, "Decisions already finished; retained evidence is authoritative. No replay.", cleanup)
        if choice not in ("approve", "reject", "cancel") or (path is not None and remaining):
            return _reply(files, states, reason="Invalid decision selector; nothing changed.")
        if choice == "cancel":
            targets = [index for index, state in enumerate(states) if state == "pending"]
        elif path is not None:
            targets = [index for index, entry in enumerate(files) if entry["path"] == path and states[index] == "pending"]
        elif remaining:
            targets = [index for index, state in enumerate(states) if state == "pending"]
        else:
            targets = []
        if not targets:
            return _reply(files, states, reason="No matching pending file; no decision replay or project write.")
        if choice == "approve":
            publisher.check_approval_active(parent)
        # Validate every immutable proposal, not only the one currently visible.
        for index, entry in enumerate(files):
            publisher._frozen(task, index, entry)
        if marker is None:
            publisher._receipt(parent, b"consumed.json", {"choice": "incremental", "id": proposal["id"]})
        begin = {"schema": 1, "id": proposal["id"], "choice": choice, "targets": targets}
        began = True
        publisher._receipt(parent, _name(number).encode(), begin)
        if choice == "approve":
            phase, cleanup = _approve(task, parent, proposal, current, states, targets, number, snapshot)
        else:
            for index in targets:
                states[index] = "rejected" if choice == "reject" else "cancelled"
            if choice == "cancel":
                phase = "cancelled"
        result = _reply(files, states, phase, cleanup=cleanup)
        publisher._receipt(parent, _name(number, "-result").encode(), {
            "id": proposal["id"], "phase": result["phase"], "states": states, "cleanup_pending": cleanup})
        if result["phase"] in ("conflicted", "blocked", "partial", "uncertain"):
            result["reason"] = "Decision stopped; inspect disk and retained receipts. Prior accepted files remain published. No retry or rollback."
        return result
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        if loading and history:
            # If even an early begin record is torn/missing, later receipts may
            # belong to a write we cannot reconstruct. Never call those paths
            # definitely unattempted. Retain any already-proven prefix outcomes.
            states = ["uncertain" if state == "pending" else state for state in states]
        states = _stop(states)
        phase = "uncertain" if began or "accepted" in states or "uncertain" in states else "blocked"
        if parent is not None:
            try:
                # Presence alone blocks subsequent publication, even if torn.
                publisher._receipt(parent, b"halted.json", {"id": proposal["id"]})
            except (OSError, ValueError):
                pass
        return _reply(files, states, phase, "Decision evidence could not be confirmed. Inspect retained files and receipts; no retry or rollback.", cleanup)
    finally:
        if parent is not None and locked_parent is None:
            try:
                parent.close()
            except OSError:
                pass
