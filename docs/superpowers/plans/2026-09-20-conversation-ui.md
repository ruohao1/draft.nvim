# Neovim Conversation UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver ISQ-234's explicit multi-turn Neovim conversation surface on the production controller.

**Architecture:** A runtime-owned coordinator maps commands and view actions to the existing semantic owner. One bounded split view owns presentation only. Frozen review windows are deferred until explicit navigation, while source and writer guards remain in the trusted adapter.

**Tech Stack:** Linux, Neovim 0.12+ / LuaJIT, Python standard-library fixtures, existing Bubblewrap controller confinement.

**Spec:** [Conversation UI](../specs/2026-09-20-conversation-ui-design.md). The user instructed continuation after the first UI checkpoint was described; use the established native execution/worktree/review workflow. Record working design assumptions without calling them a separate written-spec approval.

## Global Constraints

- One current or retained closed chat per runtime; one reusable transcript/composer pair.
- Setup and opening never submit, authenticate, discover models or launch an ACP worker.
- Preserve source buffers, global mappings, focus and cursor during background output.
- Selection is 1–16 saved existing files, at most 1 MiB combined, fixed for the owner's lifetime.
- Existing 64-turn/32 MiB engine budget; render at most the newest 2 MiB / 20,000 lines; submit at most 32 KiB.
- Hidden views unsubscribe and cancel rendering; at most one latest snapshot and one 30 ms render timer.
- Existing writer/source/frozen guards remain authoritative; no chat approval actions in this issue.
- ISQ-235/236/237 retain approval/revision UX, model picker and integrated/live-account acceptance.
- No paid requests, installations or live editor/configuration changes. Preserve untracked root AGENTS.md.

## Review Focus

- Background completion while another tab/window is active: no focus steal, hidden diff creation or synthetic visit. Tasks 2 and 4.
- Late menu/confirmation after scope or owner replacement: no dispatch into a new owner or loss of an edited draft. Task 3.
- User repurposes or wipes UI windows during resize/streaming: no source-buffer replacement or runaway reopen. Task 2.
- Large Unicode output and repeated close/new cycles: bounded display/retention without malformed UTF-8 or timer accumulation. Tasks 2 and 3.
- Dirty aliases or missing frozen panels before explicit review: refusal preserves publication guards, with cancel/close still reachable. Task 4.

---

## Task 1: Read effective conversation configuration without side effects

**Files:** modify `lua/ai/staged.lua`; extend `tests/ai_staged_shared.lua` and `tests/draft_setup.lua` as applicable.
**Interfaces:** produce `staged.conversation_options() -> options|nil,reason`, containing only root/model/auth_file/provider/python/opencode/bwrap; consumes existing `configured()` preference merging. It does not call `ready()` or acquire a lease.

- [x] Add a failing consumer test that explicit staging configuration reaches conversation creation unchanged, and disabled/invalid configuration refuses with no controller/provider launch. Mutating the returned provider table must not mutate saved runtime options.

```lua
staged.setup({ enabled = true, model = "fixture/model", provider = { fixture = {} } })
local config = assert(staged.conversation_options())
config.provider.fixture.changed = true
assert(not staged.conversation_options().provider.fixture.changed)
staged.setup({ enabled = false })
assert(not staged.conversation_options())
```

- [x] Run `python3 -I -B tests/run.py ai_staged_shared`; expect missing-reader failure.
- [x] Implement the narrow copied read boundary with existing `configured()` behavior and setup guidance. Never return enable/review-mode/settings-directory fields to the closed factory schema.
- [x] Run `ai_staged_shared ai_staged draft_setup`; expect all pass. Commit `feat: share effective configuration with conversation UI`.

## Task 2: Render and manage a bounded passive split view

**Files:** create `lua/ai/chat_view.lua`, `tests/ai_chat_view.lua`.
**Interfaces:** `new({on_action,on_hide,width?}) -> view`; `show(snapshot)`, `update(snapshot)`, `hide()`, `dispose()`, `draft()`, `set_draft(text)`, `notice(reason)`. No engine calls or test-only introspection APIs; tests observe actual buffers/windows and real input.

- [x] Add failing headless cases with literal semantic snapshots. Opening creates distinct transcript/composer buffers, focuses composer, shows model/phase/messages, and leaves the original source bytes/options unchanged. Updates while a source window is focused cannot change focus/cursor or draft contents.

```lua
local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
view:show(snapshot)
view:set_draft("next explicit question")
vim.api.nvim_set_current_win(win)
view:update(next_snapshot)
assert(vim.wait(500, function() return visible_text():find("reply marker", 1, true) end))
assert(vim.api.nvim_get_current_win() == win)
assert(view:draft() == "next explicit question")
assert(vim.api.nvim_get_current_buf() == source)
```

`visible_text` is a test helper joining lines of the real `draft-chat` transcript buffer; snapshots are literal fixtures, not generated by the renderer.

- [x] Run `ai_chat_view`; expect missing module/behavior failure. Implement owned nofile buffers, right/bottom layout, literal projection, escaped window titles, local mappings and one coalesced timer.
- [x] Add tests before implementing tail-follow behavior, history omission, UTF-8 boundaries, hide/reopen draft preservation, tiny dimensions and repurposed windows. Refuse oversize submission without changing its text. Assert that hiding cancels scheduled render work and ordinary source buffers remain untouched.
- [x] Exercise repeated show/hide and explicit disposal by observing buffer/window counts and mappings. No source options or global message settings may change.
- [x] Run `ai_chat_view draft_setup ai_staged_shared`; expect all pass. Commit `feat: add the bounded Neovim conversation view`.

## Task 3: Connect explicit commands and lifecycle actions

**Files:** create `lua/ai/chat.lua`, `tests/ai_chat.lua`; modify `lua/ai/init.lua`, `tests/draft_setup.lua`, `tests/ai_runtime.lua`.
**Interfaces:** `chat.new({create,configuration,width?})`; coordinator methods from the spec. Runtime supplies `create = function(config) return runtime:conversation(config) end` and `configuration = staged.conversation_options`. All production construction uses the runtime lease and real factory.

- [ ] Add a failing real-owner/driver fixture test for two explicit submissions, preserved draft on preflight refusal, passive reopen, hidden output and explicit close. Test double only the ACP/controller transport below owner semantics; Task 5 proves the real production path.

```lua
assert(chat:open({ source_path }))
set_composer("first question")
assert(chat:send())
finish_fixture_turn("first reply")
assert(chat:hide())
assert(chat:open())
assert(submitted_count() == 1)
set_composer("second question")
assert(chat:send())
```

`set_composer` edits the real composer buffer; the fixture records actual owner commands and emits complete matching semantic events.

- [ ] Run `ai_chat`; expect missing coordinator. Implement copied fixed scope, one owner/view, show-only subscriptions, action dispatch using current view revisions, and closed-state retention with explicit New.
- [ ] Add failing callback-race cases: delayed Close/Cancel review confirmation after an edited draft or owner/view change; repeated submission during generation; unavailable retry; new-owner failure must retain closed transcript/draft. Implement identity/revision/tick fences and state-derived action menus.
- [ ] Register the nine explicit `NvimAIChat*` commands and optional `<leader>at`. Extend public setup tests: commands register passively, default mappings unchanged, no helper process or preference file at setup.
- [ ] Verify runtime exclusions while chat is hidden/idle and release only after confirmed close. Shutdown refuses an unclosed conversation and disposes closed view state on success.
- [ ] Run `ai_chat ai_chat_view ai_runtime draft_setup ai_conversation ai_conversation_review`; expect all pass. Commit `feat: wire explicit conversation commands and lifecycle controls`.

## Task 4: Defer frozen review display until explicit navigation

**Files:** modify `lua/ai/conversation_controller.lua`, `lua/ai/staged_review.lua`, `lua/ai/chat.lua`; extend `tests/ai_staged_shared.lua`, `tests/ai_conversation_controller.lua`, `tests/ai_chat.lua`.
**Interfaces:** factory accepts trusted boolean `defer_review`; passes `defer=true` to the shared review handle. Existing callers remain eager by default. `handle:show(path)` creates/focuses windows explicitly; `intact()` covers immutable material before first display and all created panels afterward.

- [ ] Add a failing production editor case: submit an editing turn while source focus remains active; wait for review; assert no diff tab or focus change. Explicit `show` must then display the correct old/new bytes without modifying disk.

```lua
local tabs, focus = #vim.api.nvim_list_tabpages(), vim.api.nvim_get_current_win()
local owner = make({ defer_review = true, on_review = function(value) frozen_view = value end })
assert(act(owner, { kind = "submit", text = "Propose an edit." }))
wait_phase(owner, "review")
assert(#vim.api.nvim_list_tabpages() == tabs)
assert(vim.api.nvim_get_current_win() == focus)
assert(frozen_view:show("example.txt"))
```

- [ ] Run focused case; expect eager-focus behavior to fail. Split material validation/buffer creation from window presentation. Before first show recheck captured sources. Reopen valid existing panels without resetting visits or blessing missing/changed buffers.
- [ ] Add tests for source/hidden-alias drift before first open, changed/removed panels before reopen, cancelled unopened review, and stale file-selection callbacks. Wire explicit ChatReview with fixed current review identities. Preserve cancel/close cleanup paths after local guard refusal.
- [ ] Run `ai_conversation_controller ai_staged_shared ai_staged ai_staged_multi ai_staged_refine ai_chat`; expect all pass. Commit `feat: open conversation diffs only on explicit navigation`.

## Task 5: Prove the public flow, document and integrate

**Files:** create `tests/ai_chat_controller.lua`; extend `tests/nvim_ai_install.py`; update `README.md`, `doc/draft.txt`, `tests/README.md`; create `docs/validation/2026-09-20-conversation-ui.md` and actual UI captures under `docs/images/`.
**Interfaces:** public commands and real coordinator/runtime/factory/controller, existing copied fake ACP peer and loopback audit fixture. No production fault flags.

- [ ] Build a disposable fixture that configures the actual public runtime and uses real `NvimAIChat`/Send/Hide/Cancel/Close commands. Assert two provider prompts only after two explicit submissions, same eligible session, unchanged source bytes, passive hide/reopen, and controller cleanup after close. Observe actual buffers and private process audit, not command-text presence.
- [ ] Exercise streamed text/progress and question-only settlement, cancelled generation, deferred edit preview and return, failed source capture with draft retained, hidden lease exclusion and editor exit. Extend relocation to run this flow from a plugin path with spaces and an unrelated cwd.
- [ ] Capture actual wide and narrow Neovim TUI screens using a private tmux server and synthetic owner/fixture data; no live editor or default tmux server. Inspect rendered artifacts and include them in the PR.
- [ ] Document setup, the nine commands, buffer-local controls, hide versus close, fixed selection, deferred preview scope, narrow fallback, display omission and a concise keyboard walkthrough. Resolve the previously deferred obsolete owner integration comment while documenting this real consumer.
- [ ] Run `python3 -I -B tests/run.py`; expect every discovered default suite to pass with installed-provider skips. Run touched-Lua `stylua --check` and `git diff --check`. Record counts and limitations. Existing same-tree baseline is main CI `35472738528` (52/52), not a need to replay unchanged tests before work.
- [ ] Commit `docs: record conversation UI validation`. Obtain one fresh-context whole-branch review under the established native execution workflow. Fix material findings with regression tests, push, verify exact-head CI, merge and wait for main CI.
- [ ] Update ISQ-234 with concrete PR/screenshots/validation and mark Done only after integration. Keep the Usable conversational editing milestone open for ISQ-235/236/237.
