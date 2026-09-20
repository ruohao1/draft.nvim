# Conversation Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete ISQ-235 with guarded current-file/batch decisions and conversational revisions through the public chat UI.

**Architecture:** Extend the existing decision intent to address all pending files, retaining the current synchronous publisher and journal reader. Shared review handles own editor eligibility; the trusted adapter fences per-handle callbacks; chat dispatches owner actions and renders confirmed outcomes.

**Tech Stack:** Linux, Neovim 0.12+ / LuaJIT, Python standard library, existing Bubblewrap/controller and private TUI fixtures.

**Spec:** [Conversational approval and revision](../specs/2026-09-20-conversation-approval-design.md). Continue the established native implementation, isolated worktree, one final review and PR/CI/merge workflow. Do not represent working artifacts as separately approved by the user.

## Global Constraints

- Only the existing guarded staged publisher writes project files; five-second synchronous publication bound.
- One conversation/runtime lease; fixed selection of 1–16 saved files, 1 MiB aggregate selected/proposed bytes.
- `decide` has exactly one target: selected `path` or literal `remaining=true`; identities and exact writer receipt remain required.
- Preserve confirmed accepted/rejected outcomes across revisions; lost batch publication evidence marks every possibly written target uncertain.
- Twelve chat commands after four approval commands are added; explicit Send in review means a bound follow-up, never approval.
- Keep 64 turns / 32 MiB owner history, 2 MiB / 20,000 rendered lines and 32 KiB composer limit; no transcript undo retention.
- No implicit diff opening/visits, paid requests, runtime dependencies, live editor/tmux/account/configuration changes or native-write fallback.
- Preserve root untracked AGENTS.md, unrelated worktrees and staged/native compatibility.

## Review Focus

- Navigation away and back during a batch dialog: an old confirmation must not become eligible again; Task 2/3 tests pin view revision and source/frozen buffer metadata.
- Receipt arrives after the user leaves the review: outcomes update without tab/focus theft; Task 2 adapter test.
- Late mappings from superseded frozen buffers: cannot operate on a newer proposal or owner, even when a user repurposed the old tab; Tasks 2/4.
- Lost/partial batch receipt after publication: retain confirmed successes and mark other possible writes uncertain, never pending/safely rejected; Task 1.
- Hidden chat or closed original tab when returning from diff: preserve frozen windows and unsent draft, with no implicit submission; Tasks 3/4.

---

## Task 1: Represent and verify one explicit batch decision

**Files:** modify `lua/ai/conversation.lua`, `scripts/nvim-ai-conversation-protocol.py`, `scripts/nvim-ai-conversation-review.py`; extend `tests/ai_conversation_review.lua`, `tests/nvim_ai_conversation_protocol.py`, `tests/nvim_ai_conversation_review.py`.
**Interfaces:** consume existing `decide` identities/receipts; produce exclusive `path` or `remaining=true` targeting on owner actions and controller commands. ReviewRegistry derives ordered pending targets internally.

- [x] Add failing real-owner cases for approved/rejected batches, preservation of prior decisions, malformed target forms, partial receipts and driver loss. Existing path-plus-remaining rejection must stay valid.

```lua
assert(owner:dispatch({ kind = "decide", choice = "approve", remaining = true,
  round_id = 1, proposal_revision = 1, proposal_token = "proposal-1" },
  owner:snapshot().view_revision))
assert(owner:snapshot().phase == "publishing")
-- A literal receipt with two accepted files settles the round;
-- disconnect before that receipt makes both pending targets uncertain.
```

- [x] Add protocol cases accepting only `remaining=true` without path and rejecting false/numeric/string targets or both fields. Add registry cases using the real `staging.decide(..., remaining=True)` journal, rejecting a single-file receipt presented as a batch and preserving inherited decisions.

```python
command = self.command(choice='approve', remaining=True)
staging.decide(self.first['proposal'], self.first['id'], 'approve', remaining=True)
receipt = self.registry.receipt(command)
self.assertEqual([item['state'] for item in receipt['decisions']], ['accepted', 'accepted'])
```

- [x] Run `python3 -I -B tests/run.py ai_conversation_review nvim_ai_conversation_protocol nvim_ai_conversation_review`; expect batch admission/receipt failures before implementation.
- [x] Extend the closed schemas and target selection. Record `pending_decision.remaining`, derive each expected outcome from pending membership, and apply the same targeting to uncertain-state recovery. Emit a path only for a single-file intent. In Python derive pending paths before reading and normalizing the real journal.
- [x] Run the three changed suites plus `ai_conversation`, `ai_conversation_followup`, `nvim_ai_conversation_controller`; expect all pass. Commit `feat: verify explicit conversation batch decisions`.

## Task 2: Expose guarded review controls through the trusted adapter

**Files:** modify `lua/ai/staged_review.lua`, `lua/ai/staged.lua`, `lua/ai/conversation_controller.lua`; extend `tests/ai_staged_shared.lua`, `tests/ai_conversation_controller.lua`.
**Interfaces:** produce `handle:current()`, `handle:move(delta)`, `handle:prepare(choice, remaining) -> intent|nil,reason`; intent carries path/remaining, count and `valid()`. Extend `handle:decide(choice,path,remaining)` with a third return: a presentation guard. Factory accepts `on_review_action(name,argument)` and exposes guarded presentation/eligibility methods through `on_review`.

- [x] Add failing real-panel cases: no preparation before display, all pending files must be visited before batch approval, navigation away/back invalidates confirmation, source/panel/alias edits invalidate it, rejection remains possible after an already dirty source, and retired handles refuse.

```lua
assert(handle:show("first.txt"))
assert(not handle:prepare("approve", true))
assert(handle:move(1))
local intent = assert(handle:prepare("approve", true))
assert(intent.remaining and intent.count == 2 and intent.valid())
assert(handle:move(-1))
assert(not intent.valid())
```

- [x] Run `ai_staged_shared`; expect the missing eligibility/navigation API to fail. Move the existing staged confirmation snapshot into the shared review module and keep staged consumers using it. Implement silent visibility/current lookup, bounded navigation and confirmation/navigation guards without exposing the writer.
- [x] Add failing production adapter tests for two-file batch publication, real diff key callback routing, stale old-handle actions after revision and a decision receipt after leaving the review tab. Observe project bytes, owner receipts and current tab/window.
- [x] Run `ai_conversation_controller`; expect the missing trusted callback/batch integration to fail. Validate the callback option, build per-handle action closures, forward the batch target to the existing writer and return its real receipt through the controller. Advance after confirmed single approval only while the returned presentation guard still holds.
- [x] Run `ai_staged_shared ai_conversation_controller ai_staged ai_staged_multi ai_staged_refine`; expect all pass. Commit `feat: bind conversation controls to frozen review guards`.

## Task 3: Wire chat decisions, follow-ups and confirmed outcomes

**Files:** modify `lua/ai/chat.lua`, `lua/ai/chat_view.lua`, `lua/ai/init.lua`; extend `tests/ai_chat.lua`, `tests/ai_chat_view.lua`, `tests/ai_runtime.lua`, `tests/draft_setup.lua`.
**Interfaces:** add coordinator `approve()`, `reject()`, `approve_all()`, `reject_all()`, `followup()` and optional step to `review(delta)`. Runtime registers four matching approval commands. Send in pending review includes the current round/revision/token in `revise`.

- [ ] Add failing real-owner/coordinator tests that Send in review dispatches a follow-up, preserves refused drafts, and delayed batch/menu callbacks cannot act after draft edits, view changes, newer dialogs or owner/review replacement. Use real review eligibility in production integration rather than inventing writer success.

```lua
compose("Revise the pending proposal")
assert(chat:send())
local request = last().driver.requests[#last().driver.requests].command
assert(request.kind == "revise" and request.proposal_token == "proposal-1")
assert(last().owner:snapshot().review.status == "revising")
```

- [ ] Add view cases with literal receipt-derived rounds showing pending versus accepted/rejected/uncertain outcomes. Assert repeated updates remain within existing display/undo bounds.
- [ ] Run `ai_chat ai_chat_view draft_setup`; expect missing follow-up/commands/outcome rendering. Implement current-binding lookup, owner dispatch from prepared intents, explicit batch dialogs and most-recent-dialog fencing. Preserve the original chat tab for return from review; if it was closed, create an explicit safe chat tab rather than reuse frozen windows.
- [ ] Map shared review callbacks to these methods, retain confirmed cancel/close behavior, and expose state-appropriate action-menu entries. Render each round's confirmed file states with its corresponding current proposal turn, separately from assistant text.
- [ ] Run `ai_chat ai_chat_view ai_runtime draft_setup ai_conversation_review ai_conversation_followup`; expect all pass. Commit `feat: connect chat approvals and proposal follow-ups`.

## Task 4: Prove and document the public approval workflow

**Files:** create `tests/ai_chat_approval.lua`; extend production fixtures, `tests/nvim_ai_install.py` and private TUI coverage as needed; update `README.md`, `doc/draft.txt`, `tests/README.md`; add `docs/validation/2026-09-20-conversation-approval.md` and actual review UI captures.
**Interfaces:** public commands and buffer-local keys through the real runtime, owner, controller, confined fake ACP and guarded publisher. No production test switches.

- [ ] Build a disposable two/three-file public flow: request edits, prove disk unchanged, open real diffs, approve one and verify auto-advance, reject one, send a revision for pending files, inspect fresh token/visit requirements, and prove old callbacks cannot publish. Verify discussion-only follow-up and subsequent independent-turn context reflect confirmed decisions.

```lua
vim.cmd.NvimAIChatApprove()
wait_phase("review")
assert(vim.fn.readfile(first)[1] == "proposed edit")
assert(vim.fn.readfile(second)[1] == "original text")
-- Later cancellation retires pending files and preserves first on disk.
```

- [ ] Exercise public confirmed batches, source/alias/frozen-buffer drift, cancellation/close after partial acceptance, hidden runtime exclusion and preserved drafts. Extend relocated-install coverage to run the approval flow from a path with spaces.
- [ ] Run the new integration suite before completing any uncovered behavior; each observed missing behavior gets a RED→GREEN fix. Run public flow/relocation/controller suites; expect all pass.
- [ ] Capture actual review keys and partial-decision chat state in a private Neovim TUI. Visually inspect screenshots. Document twelve commands, a/r/A/R/f/q/navigation, all-diff visit requirement, Send-as-follow-up, truthful partial outcomes and recovery guidance.
- [ ] Run `python3 -I -B tests/run.py`, `stylua --check lua tests` and `git diff --check`; expect every default suite passes with expected provider opt-in skips. Record exact counts and limitations; commit `docs: validate conversational approval and revision`.

After Task 4: obtain one fresh-context whole-branch review, fix material findings
with regressions and a green complete suite, then push and verify exact-head CI.
Merge and verify main CI, update ISQ-235/milestone with PR/screenshots/evidence,
archive the execution ledger and remove only the owned worktree. Keep ISQ-236/237
open and do not run live-account acceptance without its separate authorization.
