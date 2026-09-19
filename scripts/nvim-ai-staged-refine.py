#!/usr/bin/env python3
"""Replace pending frozen proposals, never publish them or reopen decided files."""
from pathlib import Path
import select
import shutil


def refine(controller, request, editor, manifest, token):
    decisions = controller.helper("nvim-ai-staged-decisions")
    pending, child, parent_active = None, None, False
    try:
        pending = decisions.PendingReview(manifest, token, request.get("root"), request.get("decisions"))
        context = pending.snapshot()
        selected, _ = controller.selected_files({"root": context["root"], "files": [
            {"path": item["path"], "snapshot_sha256": item["expected"]["sha256"]}
            for item in context["files"]]})
        for item, entry in zip(selected, context["files"]):
            if item["identity"] != entry["identity"] or item["expected"] != entry["expected"]:
                raise controller.Refused("Selected file or parent changed since the previous review")
            item["context_only"] = entry["context_only"]
            item["seed"] = item["before"] if entry["context_only"] else entry["seed"]
        parent_active = True
        child = controller.prepare(request, editor, selected=selected, force_review=True)
        # No project lock is held during model execution. Recheck every selected
        # original (including accepted/rejected context) before retiring approval.
        pending.snapshot()
        for item, entry in zip(selected, context["files"]):
            data, mode, identity = controller.snapshot(context["root"], item["path"])
            if identity != entry["identity"] or controller.fingerprint(data, mode) != entry["expected"]:
                raise controller.Refused("Selected file or parent changed during the follow-up")
        if select.select([editor], [], [], 0)[0]:
            raise controller.Refused("Follow-up cancelled before replacing the old proposal")
        pending.retire(child["proposal"], child["id"])
        parent_active = False
        child.update(parent_active=False, prior_decisions=context["states"], previous_proposal=manifest,
                     reason="Follow-up frozen. Prior approval retired; review pending files again. Earlier accepted writes remain published.")
        result, child = child, None
        return result
    except (OSError, ValueError, KeyError, TypeError, AttributeError, controller.Refused) as error:
        if child is not None:
            # Only a directory returned by this invocation's trusted prepare().
            # Failure to clean it up is reported; no proposal is auto-approved.
            try:
                shutil.rmtree(Path(child["proposal"]).parent)
            except OSError:
                return {"phase": "blocked", "parent_active": False,
                        "reason": "Follow-up cleanup could not be confirmed; inspect " + child["proposal"]}
        if parent_active and pending is not None:
            try:
                pending.snapshot()
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                parent_active = False
        reason = str(error) if isinstance(error, controller.Refused) else "Follow-up refused; inspect the previous proposal before retrying"
        return {"phase": "blocked", "parent_active": parent_active, "reason": reason}
    finally:
        if pending is not None:
            pending.close()
