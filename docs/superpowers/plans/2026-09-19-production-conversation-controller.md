# Production Conversation Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete ISQ-233 with two explicit context-preserving turns through the production controller, safe immutable review, cancellation and bounded owner-loss cleanup.

**Architecture:** Keep the existing Lua conversation owner and editor pipe. A Python controller composes Store, Worker and PendingReview; a trusted Lua adapter supplies source/review guards and the existing synchronous publisher. Workers stop before proposals become reviewable, while the backend store survives eligible turns.

**Tech Stack:** Linux, Neovim 0.12+ / LuaJIT, Python 3 standard library, Bubblewrap, OpenCode 1.18.30 / ACP 1, unittest and clean headless Neovim fixtures.

**Spec:** [Production controller contract](../specs/2026-09-19-production-conversation-controller-design.md). Read both artifacts. Status: approved for native execution; completed steps are checked as their evidence is recorded.

## Global Constraints

- Linux, Neovim 0.12+, Python 3 standard library, OpenCode 1.18.30 / ACP 1.
- One owning editor/controller lifetime, one canonical project root, one configured provider, and 1–16 explicitly selected saved existing files.
- Selected source bytes and resulting proposal bytes each have a 1 MiB aggregate limit; retain existing UTF-8, mode, ACL, link and identity checks.
- Only the existing guarded staged publisher writes project files. Generation has no writable project mount.
- No automatic prompt replay, new-session fallback, native fallback, implicit login, cross-editor adoption or crash resume.
- No paid requests, real account credentials, installations or live editor/tmux/configuration changes are needed for automated validation.
- Keep native and standalone staged behavior compatible. Internal module names remain `ai` and helper names remain `nvim-ai-*.py`.
- Store ownership, private permissions and artifact validation remain mandatory; restricted test environments are not a reason to weaken them.

## Review Focus

- Peer stops reading during prompt/client-reply transmission: cancel/EOF still ends the owned worker; partial transmission never becomes a safe-retry claim. Task 4.
- Editor stops reading stdout or a descendant retains a pipe: queues and shutdown remain bounded; no false clean-close event. Tasks 2 and 5.
- A hidden alias becomes dirty, or a native picker completes during conversation ownership: no unsafe publish or overlapping launch. Task 7.
- Publication partly succeeds, or replacement retirement fails after its fence: retain actual outcomes and block old/new authority without rollback. Task 6.
- Provider rejects context, or retained state is corrupt/oversized: no implicit compaction, extra prompt or replacement session. Tasks 3, 5 and 8.

---

## Delivery order and tracking

| Change | Deliverable | Tracking / prerequisite |
| --- | --- | --- |
| 1 | Reviewable contract and current baseline | ISQ-232; CI prerequisite ISQ-256 is Done |
| 2 | Bounded production controller framing | ISQ-233; contract decisions settled |
| 3 | Shared workspace preparation/freeze and first real answer | ISQ-233; framing |
| 4 | Responsive cancellation, including blocked writes | ISQ-233; first answer |
| 5 | Resume, truthful failure and editor-loss lifetime | ISQ-233; cancellation |
| 6 | Frozen proposals, receipt normalization and revision retirement | ISQ-233; lifetime |
| 7 | Trusted editor assembly, guards and runtime exclusion | ISQ-233; controller/review seams |
| 8 | Pinned-runtime proof and full CI acceptance | ISQ-233; production editor path |

Use one focused commit per independently tested deliverable and small PRs following
this order. Do not combine the entire milestone into a single integration PR.
Steps 3–7 may need multiple test-first commits; preserve their dependency order.
The first useful checkpoint is two answer-only turns with no worker left alive
between them (Task 5). Full milestone completion includes Tasks 6–8.

Retain the existing issue hierarchy. Record this plan in the existing Linear
milestone and attach it to ISQ-232/233; do not create a replacement milestone.
ISQ-234–237 and ISQ-252 retain their separate scopes. No calendar estimate or due
date is implied by this technical sequence.

## File and interface map

| File | Responsibility |
| --- | --- |
| Existing `lua/ai/conversation.lua` | Actions, phases, identities, transcript and receipt-facing state; add bounded progress only |
| Existing `lua/ai/conversation_driver.lua` | Framing, process lifetime and command serials; use explicit production watchdogs |
| New `lua/ai/conversation_controller.lua` | Trusted passive factory and adapter around owner/pipe/source/review guards |
| New `lua/ai/staged_sources.lua` | Shared saved-buffer capture, aliases and changed-tick guards extracted from staged.lua |
| New `lua/ai/staged_review.lua` | Existing frozen-review handle and guarded local decision operation extracted from staged.lua |
| Existing `lua/ai/init.lua`, `lua/ai/staged.lua` | Runtime exclusion and compatibility with existing commands |
| New `scripts/nvim-ai-conversation.py` | Executable controller, one owner, command dispatch and lifetime orchestration |
| New `scripts/nvim-ai-conversation-protocol.py` | Closed editor command schemas, bounded incremental framing and output queue |
| New `scripts/nvim-ai-conversation-turn.py` | Method-specific ACP validation, create/resume/configuration/prompt and normalized display data |
| New `scripts/nvim-ai-conversation-review.py` | Proposal registry, validated receipts, context and PendingReview handoff; no project writer |
| Existing `scripts/nvim-ai-staged.py` | Extract shared workspace prepare/freeze; keep standalone prepare interface |
| Existing Worker / Store / decisions helpers | Own transport/shutdown, store eligibility and journal validation respectively |
| New `tests/nvim_ai_conversation_protocol.py`, `tests/nvim_ai_conversation_controller.py` | Pure protocol and real-process controller cases |
| New `tests/ai_conversation_controller.lua` | Real Neovim adapter, source/review guards and process integration |
| New `tests/nvim_ai_conversation_interop.py` | Opt-in pinned executable plus local scripted provider through the production controller |
| New `tests/fixtures/ai/conversation_harness.py`, `tests/fixtures/ai/conversation_peer.py` | Owned disposable process harness and adversarial ACP peer |

Use module-relative helper resolution. Do not add a package manager dependency or
general multi-provider framework. Keep the fake controller used by existing pipe
tests: it still tests a useful transport boundary independently of the real one.

### Common planned records

`Binding` contains conversation ID, owner generation, root, ordered selection and
provider. `Start` adds turn/worker IDs, model, message and ordered
`sources=[{path,snapshot_sha256}]`. `revise` also includes the existing bound review
context. No wire command contains executable argv, database path or credentials.

Trusted launch configuration is a private, bounded file passed with `--config`
in factory-generated argv. It contains only validated `opencode`, `bwrap`, model,
optional auth-file path and explicit provider configuration. The controller pins
and validates this file before reading it; it is never writable or visible to the
agent. The adapter removes it after confirmed controller exit; unknown exit keeps
exact-path cleanup evidence. Avoid credentials in argv/environment or diagnostics.

`Frame` has exactly `{version=1, serial, command}`; a response has exactly
`{version=1, serial, event}`. `Event` uses the existing owner's closed event schema
plus Task 3's bounded progress event. The trusted adapter alone consumes an
optional controller-issued `review_ref={manifest,token}` attachment, validates it
through the shared reader and strips it before the owner sees the event. Actions
and ACP cannot supply that attachment.

`Frozen` is the existing prepare result (`phase`, `proposal`, `id`, `files`) kept
host-side. Semantic proposal events contain token/source generation/ordered file
states, without exposing a manifest path as an action capability.

`DecisionSnapshot` contains phase, complete ordered decisions, cleanup_pending
and a validated per-proposal operation count. Only the decisions module reads its
private journal. The controller maps this to the owner's proposal-local receipt
ordinal, preserving previously accepted/rejected context across revisions.
`Receipt` is the existing owner's round/revision/token/sequence/phase/decisions/
cleanup_pending record. `Retirement` contains validated final receipts and facts
about token/candidate retirement, writer exit and cleanup; these fields are
derived from real operations, never accepted as command input.

The fixture helper provides `exercise(case_name: str) -> dict`: launch the actual
controller with private config/project, run the case's explicit pipe commands and
return observed editor frames, exact owned process-exit evidence, source bytes
and the fixture peer/local-provider request record. Its scenarios use real I/O,
never patched subprocess/Store/Worker/publisher objects. Examples below state the
scenario and required result fields; add each named case with its owning task.

## Task 1: Close the contract review and establish the execution baseline

**Files:** this plan, its spec, `tests/README.md`, existing conversation tests.
**Produces:** reviewed contract; baseline/version evidence in `docs/validation/2026-09-19-conversation-controller.md` (create during execution).

- [x] Read the spec alongside `lua/ai/conversation.lua`, Worker, Store, PendingReview and the existing pipe tests. The user's approval accepts resume-only behavior, startup-cancel failure policy, synchronous guarded publication, write interruption and watchdog budgets.
- [x] Create an isolated implementation worktree from current main with a private/trusted file-mode policy. The default runner passed all 46 suites with expected installed-agent skips.
- [x] Re-run the existing pinned `nvim_ai_acp_resume.py` and `nvim_ai_conversation_lifetime.py` cases: all 4 resume and 5 lifetime tests passed with synthetic auth and a loopback provider. Version/hash are in the validation record.
- [x] Record the approved contract and fresh baseline for `docs: define production conversation controller contract`.

## Task 2: Implement bounded controller framing and passive ownership

**Files:** create controller/protocol helpers, protocol/controller tests and fixture harness from the file map.
**Interfaces:** `EditorPipe(input_fd, output_fd)`, `read_ready() -> list[Frame]`, `enqueue(serial,event)`, `flush_ready()`, `eof`; `Controller(config, pipe).run() -> int`. Construction launches no ACP worker.

- [x] Add protocol tests for fragmented UTF-8, duplicate/escaped keys, NaN/infinity, bool-as-integer, depth/token/byte/count limits, partial EOF, extra keys and duplicate/future/stale serials. A repeated or stale command never replays work; unknown/future identity fails the binding.

```python
def test_duplicate_decoded_key_is_rejected(self):
    frame = {"version": 1, "serial": 1, "command": {
        "kind": "close", "conversation_id": "a" * 32, "owner_generation": 1,
        "turn_id": 0, "worker_generation": 0, "root": "/tmp/project",
        "selection": ["example.txt"], "model": "fixture/model"}}
    raw = json.dumps(frame).encode()
    self.assertEqual(protocol.decode_command(raw), frame)
    raw = raw.replace(b'"version": 1', b'"version": 1, "versi\\u006fn": 2')
    with self.assertRaises(protocol.Refused):
        protocol.decode_command(raw)

def test_close_before_first_turn_starts_no_worker(self):
    observed = exercise("close-before-start")
    self.assertEqual(observed["worker_starts"], 0)
    self.assertEqual(observed["events"][-1]["kind"], "closed")
    self.assertEqual(observed["controller_returncode"], 0)
```

- [x] Run `python3 -I -B tests/run.py nvim_ai_conversation_protocol nvim_ai_conversation_controller`; first failure must be the missing production boundary/validation, not missing fixture dependencies.
- [x] Implement strict decoding and closed command validation mirroring the owner fields. Add `decode_command(raw: bytes) -> Frame`. Bind once on the first accepted command; permit an initial close at turn/worker zero. Serial must be the next positive safe integer. Stale frames consume limits and cannot invoke a second operation.
- [x] Use nonblocking stdin/stdout and bounded queues. Allow at most 64 pending commands and 2 MiB raw command bytes; reject malformed input instead of silently dropping a cancel. Limit queued output to 32 MiB and each oldest frame's delivery to 5 seconds, without renewing that deadline on partial writes. Add `exercise("editor-output-blocked")` with a pipe that is deliberately not drained: assert bounded exit and no worker left running. Repeat with a live worker in Task 5.
- [x] Run both new suites plus `ai_conversation_driver`; commit `feat: add bounded conversation controller protocol`.

## Task 3: Share workspace preparation and complete a real answer-only turn

**Files:** modify `scripts/nvim-ai-staged.py`; create turn helper; extend controller, fixture peer and tests; retain staged/refine regressions.
**Interfaces:** `prepare_workspace(request, selected) -> Path`, `freeze_workspace(task, root, selected, *, multi, force_review=False) -> Frozen`, `discard_workspace(task)`; turn adapter `Turn(config, store, editor_pipe).start(command)` and `advance() -> list[Event]`.

- [x] Extract the existing pre-ACP setup and post-ACP validation/freeze sections of `prepare()` without changing its public result. `freeze_workspace` never starts a worker or writes the project. The controller calls it only after verified stop; standalone `prepare` retains its existing execution path. Cleanup is permitted only for the task created by that invocation and after its worker has stopped.
- [x] Add a real peer scenario that advertises 1.18.30/ACP 1, creates a session, confirms model/mode, streams text and `end_turn`, creates allowed synthetic store artifacts, and exits gracefully on EOF. No edit is made.

```python
def test_answer_finishes_without_proposal(self):
    observed = exercise("first-answer")
    self.assertEqual(observed["methods"], ["initialize", "session/new",
        "session/set_config_option", "session/set_config_option", "session/prompt"])
    self.assertEqual(observed["outcome"], "answer")
    self.assertEqual(observed["tokens"], [])
    self.assertTrue(observed["reaped_before_settled"])
    self.assertEqual(observed["project_after"], observed["project_before"])
```

- [x] Run the new case and observe failure before adding session behavior. Implement only pinned initialize/new/config/prompt schemas, exact session binding, authorized options, denied filesystem/terminal RPCs and selected-path edit permission handling. Unknown/non-success stop reasons are failures; they cannot freeze output.
- [x] Reuse `staging.configuration()`/`sandbox()` with fresh filtered profile. Add the conversation-specific compaction/prune-disable config/env from the existing `acp_session_probe.py`; preserve its loopback authenticated ACP listener configuration. Store mounts only its backend child.
- [x] Use Worker `begin`/`poll`, with at most 50 ms polls and 64-message batches, total startup/generation deadlines and bounded normalized text/progress. Add closed `progress` schema to the owner: `{kind="progress", tool_id, title, status}` plus identities/sequence; allowed statuses are pending/in_progress/completed/failed/cancelled, strings at most 256 bytes, all data charged to existing budgets. Progress is display-only.
- [x] Add cases for wrong version, missing resume capability, unadvertised model/mode, wrong config confirmation, mismatched session updates and denied host operations. Assert zero prompt requests after handshake/config refusal. Run `nvim_ai_conversation_controller nvim_ai_staged nvim_ai_staged_multi nvim_ai_staged_refine ai_conversation`; commit the extraction separately from `feat: execute a validated conversation turn`.

## Task 4: Make cancellation responsive through blocked ACP I/O

**Files:** Worker, turn/controller helpers, `tests/nvim_ai_acp_worker.py`, fault peer and controller tests.
**Interfaces:** optional Worker `on_write_wait: () -> bool`, forwarded through `Store.start`; true interrupts the write with a trusted protocol fault. Callback only drains/validates editor input and records intent; it never recursively calls ACP or a publisher.

- [x] Add real peer cases for cancel during initialize, normal generating cancel, a peer that never reads a large prompt, blocked client-capability reply and a notification flood. Synchronize with pipe/readiness markers, not repeated sleep-based races.

```python
def test_cancel_interrupts_backpressured_prompt(self):
    observed = exercise("cancel-blocked-prompt")
    self.assertLess(observed["cancel_to_stop_started_seconds"], 1.0)
    self.assertTrue(observed["worker_reaped"])
    self.assertFalse(observed["resume_eligible"])
    self.assertFalse(observed["retry_safe"])
    self.assertEqual(observed["tokens"], [])
```

- [x] Run worker/controller suites to show blocked input currently delays interruption. Add the hook before bounded write waits in `_send`; keep existing callers unchanged when omitted. Preserve Store's independent metadata guard.
- [x] Between normal polls, process cancel before new work. If the prompt frame was fully sent, issue one `session/cancel` and await the matching prompt's `cancelled` result for at most 5 seconds. If a write was interrupted, never splice another JSON message into that frame or claim graceful resumability. Clear the handled cancel intent before its own notify call; fresh close/EOF must still interrupt a blocked cancellation write.
- [x] Add a startup-cancel regression: no `session/prompt`, no invented cancellation acknowledgement, no false idle-success event. Safe retry is permitted only when all existing owner proof fields can be established; otherwise explicit recovery remains required. Close can still clean a proven-stopped tainted store.
- [x] Run `nvim_ai_acp_worker nvim_ai_conversation_store nvim_ai_conversation_controller ai_conversation`; commit `fix: service conversation cancellation during ACP backpressure`.

## Task 5: Resume eligible sessions and supervise editor loss

**Files:** controller/turn helpers, controller/lifetime tests and real-process fixture peer.
**Interfaces:** controller retains exactly one backend session ID and one Store; `Store.stop(outcome="completed"|"cancelled")` receives only validated semantic outcomes. All other stops taint continuation.

- [x] Add two explicit answer turns with different worker PIDs, the same resumed session ID, a fresh per-worker profile and no transcript replay. Add clean-cancel-then-resume and failed-resume-without-fallback cases.

```python
def test_resume_is_explicit_and_worker_free_between_turns(self):
    observed = exercise("two-answers")
    self.assertEqual(observed["new_session_count"], 1)
    self.assertEqual(observed["resume_ids"], [observed["first_session_id"]])
    self.assertEqual(observed["prompt_count"], 2)
    self.assertNotEqual(*observed["worker_pids"])
    self.assertTrue(observed["idle_has_no_worker"])
```

- [x] Run the new cases red, then preserve Store/session binding across fully stopped turns. Revalidate options after every resume, with no automatic request on model choice. Keep prior trusted file outcomes in a bounded structured context block; the new user message remains separate. Reject before startup at the existing turn/transcript limits.
- [x] Test corrupt/missing/oversized store, RPC error, non-normal stop reason, forced exit and unknown reap outcome. Validate metadata through Store only. No host SQL, checkpoints, repair or blessing by file hash. Add a case proving `session/new`/prompt counts do not increase after resume refusal.
- [x] Close controller stdin during startup, generation, stopping, idle and pending review preparation. Also kill the exact owned controller and exercise a descendant-held ACP pipe. Observe actual pidfd/reap/EOF/listener evidence using the lifetime suite's existing ownership pattern; keep unsafe mounted state instead of deleting it early.
- [x] Implement idempotent bounded owner-loss cleanup. Once EOF/close is admitted, no queued turn starts. Full worker stop precedes token retirement and Store.close. Clean close requires stdout drain and zero controller exit; failed cleanup must not emit `closed` success.
- [x] Run `nvim_ai_conversation_controller nvim_ai_conversation_store nvim_ai_conversation_lifetime nvim_ai_acp_worker ai_conversation_driver`; commit `feat: retain conversation sessions across supervised workers`.

## Task 6: Integrate frozen proposals, receipts and follow-up retirement

**Files:** new conversation-review helper; controller/shared freeze; decisions helper; controller, decisions and follow-up tests.
**Interfaces:** `ReviewRegistry` stores controller-created token→manifest bindings. Its `install(Frozen, turn_id)`, `receipt(command) -> Receipt`, `begin_revision(command) -> PendingReview`, `finish_revision(candidate, context) -> Event`, `retire_all() -> Retirement` never write project files. Add `decisions.read_receipt(manifest, token) -> DecisionSnapshot` and `read_review(manifest, token) -> Frozen` under the existing proposal lock and journal/frozen-byte validation. Expose read_review through a bounded, read-only `inspect-review` operation in the staged helper for the editor adapter.

- [x] Add actual staged-copy edits and wait-for-worker-exit assertions before proposal exposure. Confirm generation leaves host sources unchanged. Receipt/revision fixture cases explicitly invoke the existing publisher on disposable files to establish real prior decisions; the guarded production editor bridge arrives in Task 7. All selected outputs must pass current mode/link/UTF-8/size/path/source checks.
- [x] Add read-receipt tests against real existing writer output, including accept-A/reject-B cumulative `applied` status, partial/uncertain outcomes and cleanup_pending. Caller data cannot substitute a receipt or manifest. The journal module verifies a complete result before normalization.

```python
def test_revision_retires_old_authority_and_preserves_decisions(self):
    observed = exercise("revision-after-partial-decision")
    self.assertNotEqual(observed["old_token"], observed["new_token"])
    self.assertFalse(observed["old_token_approvable"])
    self.assertEqual(observed["new_receipt_sequence"], 0)
    self.assertEqual(observed["confirmed_A"], "accepted")
    self.assertEqual(observed["editable_paths"], ["B.txt"])
```

- [x] Implement fresh freeze using Task 3's shared function, token registry and complete canonical file states. Attach only a controller-registered review_ref for editor material loading. The read-only inspect-review helper must verify token, source/proposal identity, private frozen bytes and size bounds; reject extra fields and supplied success flags. For revision, hold PendingReview, seed only pending files, revalidate sources after stop and call `retire(candidate_manifest,candidate_id)` before exposing the new token. Never hold the project publication lock during generation or reacquire a proposal lock through another descriptor while already holding it.
- [x] Distinguish discussion-only unchanged seeds from removal of pending edits back to saved baselines. The first restores the active predecessor after validation; the second is a frozen replacement that can settle the round. Retain prior accepted/rejected outcomes even when candidate manifests mark those files unchanged.
- [x] Add failures before/after retirement fence, candidate cleanup failure, stale tokens, decided-file edits, source drift and cancellation after candidate freeze. Report active predecessor only after positive snapshot validation plus independent candidate retirement. Cancel/close retires pending authority without rolling back accepted files.
- [x] Run `nvim_ai_conversation_controller nvim_ai_staged_decisions nvim_ai_staged_publish nvim_ai_staged_refine ai_conversation_review ai_conversation_followup`; commit `feat: bind conversation reviews to validated staged receipts`.

## Task 7: Wire the real editor with shared source and publication guards

**Files:** create Lua factory/source/review modules; modify staged.lua, init.lua, driver and add `tests/ai_conversation_controller.lua`; extend runtime/staged/install tests.
**Interfaces:** `staged_sources.capture(files,root) -> capture|nil,reason`, `unchanged(capture) -> bool`; `staged_review.open(frozen,capture) -> handle`, `handle:decide(choice,path) -> verdict`, `handle:retire()`. `conversation_controller.new(options) -> owner|nil,reason` composes the existing owner and driver. Internal `runtime:conversation(options)` acquires the runtime lease and calls this factory. Options are trusted root/selection/model/executable/profile configuration, not dispatch actions; they introduce no public chat command.

- [ ] Extract source capture/alias checks and frozen-review guards from staged.lua without altering standalone semantics. Keep existing `visible_review`, visited-diff, frozen-buffer and saved-source checks in the shared review handle. Give each replacement a fresh handle and visit set. Retain the synchronous existing `vim.system(...):wait(5000)` publication boundary.
- [ ] Add an internal factory that resolves the controller relative to the plugin, creates validated private launch config and wraps `driver:send`. Capture sources before start/revise; bind review handles to current token/revision. Consume review_ref only from the trusted controller, inspect its material through Task 6's read-only helper, then strip it from the semantic event. Bound that helper's output/deadline independently and recheck captures before forwarding review/restoration; failure fences actions and requires retirement/close. Never treat a raw owner dispatch as a replacement for this production adapter.
- [ ] For `decide`, validate the bound visible/visited review and invoke its existing guarded writer once. Only after it returns send the expected intent/identity to the controller, which reads authoritative receipts through Task 6. Never send a caller-authored success receipt. A timeout/unknown result leaves publication recovery required. Update the driver contract comment to document this narrowly bounded local publication exception to prompt-returning send.

```lua
local owner = assert(factory.new(options))
assert(owner:dispatch({ kind = "submit", text = "first question" }, owner:snapshot().view_revision))
wait_phase(owner, "idle")
assert(owner:dispatch({ kind = "submit", text = "use the earlier context" }, owner:snapshot().view_revision))
wait_phase(owner, "idle")
assert(#owner:snapshot().turns == 2)
assert(owner:dispatch({ kind = "close" }, owner:snapshot().view_revision))
wait_phase(owner, "closed")
```

The Lua suite defines `options` from its disposable fixture configuration and
`wait_phase(owner,phase)` using `vim.wait` only in the test driver. Production
publication must not use `vim.wait` to process input between its final guard and write.

- [ ] Set the production pipe's explicit 270000 ms command and 10000 ms stop watchdogs; retain shorter test deadlines via trusted construction. Tests must prove a long allowed turn is not killed by the old 120-second default without waiting 120 seconds: inject coherent scaled deadlines through trusted test configuration and observe the ordering.
- [ ] Integrate the conversation lease into init.lua's existing before_staging/native_transaction/generation fences. The internal creation method refuses an active pane, queued native open, unresolved native review, staged operation/dialog or another conversation. Release only after confirmed close; a hidden/idle conversation remains busy. No public command/keymap changes.
- [ ] Add real headless cases for dirty hidden aliases during generation/review, changed frozen panels, unvisited approval, a stale native picker, a second owner, plugin relocation, editor EOF and accepted-source refresh failure. Assert source bytes and actual writer receipts. Keep chat navigation assertions for ISQ-234/235.
- [ ] Run `python3 -I -B tests/run.py ai_conversation_controller ai_conversation_driver ai_conversation ai_conversation_review ai_conversation_followup ai_runtime ai_staged ai_staged_multi ai_staged_refine nvim_ai_install`; commit source/review extraction independently, then `feat: connect the production conversation controller to Neovim`.

## Task 8: Prove interoperability and close the milestone with current evidence

**Files:** create opt-in interop suite; reuse `acp_session_probe.py` Provider only; update `tests/README.md`, `README.md`, `doc/draft.txt` and validation record from Task 1.
**Produces:** evidence for the actual controller path, reviewed changes, passing post-merge CI; no broader chat-release claim.

- [ ] Run the production controller with actual OpenCode 1.18.30 and the scripted loopback provider. Use synthetic credentials and fresh disposable HOME/XDG. Capture the second provider request and assert it includes the prior distinctive assistant/native-tool context even though the submitted second prompt contains no replay. Record fresh worker PIDs, exact session ID reuse, profile replacement and absence of project writes.
- [ ] Add pinned-runtime cases for clean cancellation/resume, configuration reapplication, session restoration error, context-overflow response, disabled implicit compaction/pruning, listener exit and retained-artifact boundaries. Default execution skips these explicitly. Keep fake-peer safety tests in ordinary CI; a fake session ID alone never counts as interoperability proof.

```python
def test_real_backend_preserves_context_without_prompt_replay(self):
    observed = exercise("installed-opencode-two-turns")
    self.assertIn("distinctive prior assistant reply", observed["second_provider_request"])
    self.assertNotIn("distinctive prior assistant reply", observed["second_submitted_prompt"])
    self.assertEqual(observed["new_session_count"], 1)
    self.assertTrue(observed["all_owned_listeners_stopped"])
```

- [ ] Document an exact isolated opt-in invocation for `tests/nvim_ai_conversation_interop.py` using `NVIM_AI_ACP_REAL_OPENCODE`. Preserve tests/run.py's default environment allowlist; do not forward user credentials or installed-runtime opt-ins by default. Test fixtures only record synthetic request bodies; application diagnostics remain content-free.
- [ ] Run `python3 -I -B tests/run.py`; expect all discovered old and new suites to pass. Run `stylua --check` on touched Lua files and `git diff --check`. Record actual counts, expected skips, executable hash/versions and the limitation that user-facing chat is still a sibling issue.
- [ ] Obtain whole-branch review of process lifetime, identity/schema checks, selection/approval authority and compatibility. Fix material findings, then push and check CI on the exact reviewed head. Merge only that head and wait for the new main run to pass before completing ISQ-233 or the milestone.
- [ ] Update Linear with PRs, main run and pinned-runtime evidence. ISQ-232 closes only its reviewed contract; ISQ-233 closes the integrated engine. Leave ISQ-234–237/252 open for their own acceptance. Commit validation/docs as `docs: record production controller validation`.

## Completion checklist

- [ ] Real two-turn continuity and question-only completion.
- [ ] Cancel/close/EOF are bounded through startup, backpressure, generation, stopping and review.
- [ ] No frozen proposal before graceful confirmed exit; no reuse after forced/unknown stop.
- [ ] Real guarded publication, complete receipts and writer-enforced revision retirement.
- [ ] No authority from malformed/stale data, source drift, hidden buffers or agent text.
- [ ] Default suite and pinned-runtime evidence distinguished, with fresh passing main CI.
- [ ] Documentation and Linear report exactly the internal engine delivered; follow-on UX remains separately tracked.

## Execution handoff

Recommended execution: native implementation task by task in an isolated worktree,
with focused review for each PR and an independent whole-branch review. These tasks
share lifecycle and receipt interfaces, so a single implementing context avoids
parallel ownership conflicts. Subagent-driven implementation is an alternative if
the user prefers independent implementation/review gates for every task.

The user's subsequent “proceed” authorizes native implementation of this plan and
accepts its contract decisions. Unchecked tasks remain incomplete until verified.
