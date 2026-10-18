# Manual proposal corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct one pending conversational proposal locally, explicitly freeze a fresh revision, and publish only through normal guarded approval.

**Architecture:** Reuse ReviewRegistry, PendingReview, the existing freezer and publisher. Add a non-model correction operation, semantic editing/freezing states, and a separate scratch buffer. Keep candidate ownership explicit through cancellation and failure.

**Tech Stack:** Existing Lua/Neovim 0.12+, Python standard library, existing isolated test runner; no new dependencies.

**Spec:** [Approved recommendation](../specs/2026-10-17-manual-corrections-design.md), also [recorded in Linear](https://linear.app/isqrd/document/manual-proposal-corrections-design-recommendation-and-implementation-e6cec96ba5ee).

## Global Constraints

- Keep original frozen panes immutable; edit one pending selected file at a time.
- Freeze never publishes or starts a model/worker. Keep turn and worker generations unchanged.
- Fresh changed proposal token, same round, revision +1, receipt sequence 0; old authority retired before adoption.
- Preserve accepted/rejected outcomes and real receipts. Reset all pending visits after replacement.
- Require exact predecessor context, source identities/content, clean aliases, immutable panels and current callback identity.
- Supported text: UTF-8, no BOM/NUL/CR, final LF on nonempty content, 20,000 LF characters per file, 1 MiB aggregate proposal, 16 selected existing files.
- Keep 1 MiB encoded command and existing output budgets. Preflight without consuming a serial or faulting the driver.
- Cap changed manual revisions at 64 per conversation; no-op/discard and cleanup remain possible at the cap.
- Preserve modified correction text on cancellation, close, refusal and recovery; no crash recovery promise.
- Update README.md and doc/draft.txt and capture the new UI. Keep this plan with implementation, no plan-only PR.
- User selected implementation on 2026-10-17; actual daily-use benefit remains unvalidated.

## Review Focus

- Cancel/close can overtake UI adoption after the backend already retired the parent: Task 1 cleanup and Task 2 stale-operation tests.
- A callback can alter the draft or EOF metadata while freeze is outstanding: Task 3 verifies preservation and refuses newer edits as candidate content.
- A hidden correction must still fence public commands and stale dialogs: Task 2 owner gates and Task 3 public-command tests.
- Zero bytes and one newline look identical: Task 3 checks actual byte publication, not rendered lines alone.
- A valid decoded replacement can exceed the encoded command budget: Task 2 tests escaping/overhead and no serial consumption.

### Task 1: Non-model correction transaction

**Files:** Modify scripts/nvim-ai-conversation-protocol.py, scripts/nvim-ai-conversation-review.py, scripts/nvim-ai-conversation.py, scripts/nvim-ai-conversation-turn.py; tests/nvim_ai_conversation_protocol.py, tests/nvim_ai_conversation_review.py, tests/nvim_ai_conversation_controller.py.

**Interfaces:**
- Consumes ReviewRegistry.begin_revision(command), validate_revision(), restore_revision(), finish_revision(frozen, turn_id), PendingReview.retire, prepare_workspace and freeze_workspace.
- Produces ReviewRegistry.correct(command) -> result with outcome review/unchanged/refused, predecessor evidence and optional proposal/review_ref. Failed safe-restoration proof raises and requires cleanup/recovery.
- Wire command kind correct carries common binding, complete review context/sources, path and replacement. Result kind corrected is terminal; no model lifecycle fields. Controller owns unfinished candidates until retirement/transfer.

- [x] Add real-registry tests: a correction leaves project bytes unchanged, consumes old authority and publishes exact new bytes only on approve; preserve earlier accepted/rejected context; no-op keeps identity; baseline reversion settles; invalid text/target and capacity are safe refusals; source drift/fence/install/cleanup failures cannot restore uncertain authority.
- [x] Add closed-protocol tests for correct, invalid fields and duplicate serials without turn/worker increments; add real controller coverage showing no provider turn for correction and cleanup on cancel/close.
- [x] Run `python3 -I -B tests/run.py nvim_ai_conversation_protocol nvim_ai_conversation_review nvim_ai_conversation_controller`. Expected: new correction assertions fail because the operation is absent.
- [x] Implement correct using existing revision/freezer paths and explicit candidate ownership. Return unchanged after seed comparison before budget allocation; validate all paths/text before replacement. Bound manual provenance for the next model prompt.
- [x] Run the same command. Expected: all three suites pass.
- [x] Commit backend, tests, spec and this plan: `feat: freeze manual corrections through the review registry`.

### Task 2: Semantic owner and trusted editor admission

**Files:** Modify lua/ai/conversation.lua, lua/ai/conversation_controller.lua, lua/ai/conversation_driver.lua, lua/ai/staged_review.lua, lua/ai/staged_sources.lua; tests/ai_conversation_followup.lua, tests/ai_conversation_driver.lua, tests/ai_conversation_controller.lua, tests/ai_staged_shared.lua.

**Interfaces:**
- Consumes correct/corrected from Task 1; proposal fields and writer receipts remain unchanged.
- Produces owner actions edit-proposal(path + seed_sha256 + review identity), discard-correction, correct(replacement + review identity/path); owner phases editing/freezing with bound correction context. No raw draft bytes retained in semantic history; seed_sha256 permits the owner to distinguish no-op from changed correction at its cap. Reuse ai.review.reducer.is_text in staged_sources.valid_text(text) for strict UTF-8 checks.
- Produces driver:preflight(command) -> true or nil, reason; trusted wrapper adds captured sources before exact size preflight.
- Produces narrow review handle:proposal() -> {path, text} for the current eligible pending file; immutable panels retain their existing API.

- [x] Add owner tests for all action gates, no extra model turn, active/retired evidence, mixed decisions, no-op, fresh revision/history, budget, cancellation and stale callbacks.
- [x] Add driver tests proving oversize/escaped commands are refused before serial/send/fault; valid command following refusal retains serial continuity.
- [x] Add trusted admission tests for source/frozen drift and unavailable correction targets.
- [x] Run `python3 -I -B tests/run.py ai_conversation_followup ai_conversation_driver ai_conversation_controller ai_staged_shared`. Expected: new actions/interface assertions fail.
- [x] Implement owner states and shared predecessor checks without forging model events. Prepare correction command and preflight before mutating state. Extend trusted result admission and timer recognition; preserve disconnect handling during local editing.
- [x] Run the same command plus `ai_conversation ai_conversation_review`. Expected: all pass.
- [x] Commit: `feat: guard manual correction state and revision adoption`.

### Task 3: Editable draft and public workflow

**Files:** Create lua/ai/proposal_correction.lua, tests/ai_proposal_correction.lua and tests/ai_chat_correction.lua. Modify lua/ai/chat.lua, lua/ai/chat_view.lua, lua/ai/init.lua, tests/ai_chat_approval.lua, tests/ai_runtime.lua and tests/fixtures/ai/chat_approval.lua as needed.

**Interfaces:**
- Consumes Task 2 owner actions and narrow read-only proposal material.
- Produces proposal_correction.open(path, text, on_actions?) -> draft handle with show(), hide(), stamp(), snapshot() -> text/stamp or nil/reason, lock(), unchanged(stamp), modified(), release(), discard(stamp?) and detach(). No project writes, no owned publisher.
- Produces chat:edit_proposal(), freeze_proposal(), discard_correction() and public NvimAIChatEditProposal/NvimAIChatFreezeProposal/NvimAIChatDiscardCorrection. Existing actions menu exposes the same operations.
- Draft ownership must survive chat hide; source of truth is the current correction and its owner, not transient window callbacks.

- [x] Add draft tests for exact bytes including empty/newline/trailing blanks, undo, metadata/NUL/CR refusal, no approval mappings, hide/reopen, unchanged-stamp checks, locking and detached text preservation.
- [x] Add public-action tests: edit visible pending file; decisions/follow-up blocked; freeze creates new review; unchanged freeze returns original; modified text survives refusal/cancel/close/controller loss; stale dialogs and callbacks cannot erase edits.
- [x] Run `python3 -I -B tests/run.py ai_proposal_correction ai_chat_correction ai_chat_approval ai_runtime`. Expected: new draft/workflow assertions fail.
- [x] Implement separate scratch buffers and explicit EOF metadata; preserve ordinary editing. Wire commands/runtime/menu and update chat rendering with truthful manual provenance and editing/freezing status.
- [x] Run the same command plus `ai_chat ai_chat_view ai_chat_controller ai_chat_auto_review ai_chat_recovery`. Expected: all pass.
- [x] Commit: `feat: edit and freeze proposal corrections in chat`.

### Task 4: End-to-end evidence and delivery

**Files:** Modify tests/nvim_ai_chat_ui.py and its real controller/editor fixtures, README.md, doc/draft.txt, tests/README.md. Add docs/validation/2026-10-17-manual-corrections.md and review/draft screenshots.

**Interfaces:** Exercise the real public commands, controller registry and guarded writer from Tasks 1–3; no provider credentials.

- [x] Add an actual-key/UI or production-editor path that corrects frozen bytes, proves disk unchanged before approval, then verifies exact publication, replacement visits and prior accepted files. Run it red if it exposes an integration gap; fix the shared cause.
- [x] Document commands, explicit final-newline behavior, in-memory draft recovery and encoded-size limitation in both usage documents.
- [x] Run `python3 -I -B tests/run.py`, `stylua --check lua tests`, and `git diff --check`. Expected: all suites and checks pass. Capture and visually inspect the draft and resulting frozen review.
- [x] Record evidence and commit: `test: validate manual correction workflow and document limits`.
- [x] Request one fresh whole-branch review against the spec and this plan. Address substantive findings with regressions, rerun affected checks and the full suite after fixes.
- [x] Push the feature branch and open an implementation PR including this plan, issue/spec links, validation and screenshots. Update Linear with verified delivery state; do not mark untested daily-use benefit complete or merge without authorization.

Delivered for review in [PR #11](https://github.com/ruohao1/draft.nvim/pull/11);
[ISQ-461](https://linear.app/isqrd/issue/ISQ-461) and the Linear design/study records
contain the verified results. The PR is unmerged; daily-use benefit remains open.
