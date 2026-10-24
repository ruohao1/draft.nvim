# Read-only Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> (recommended here) or superpowers:subagent-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach explicit buffer snapshots and cached diagnostics to managed
Codex/OpenCode messages without expanding editable files or submitting a turn.

**Architecture:** Add one chat-specific capture/render helper and reuse the
existing visual extractor, composer and message field. The chat coordinator keeps
owner/draft race checks; selected-source capture, sandboxes, frozen review and
publication retain their current authority. No attachment ledger or new protocol.

**Tech Stack:** Linux, Neovim 0.12+, LuaJIT, existing Python 3 standard-library
controllers, Bubblewrap and the isolated Lua/Python/tmux test runner. No new dependencies.

**Spec:** [Approved contract](../specs/2026-10-21-readonly-context-design.md).
User approved revision `39d4218b4fc4f99355f08f115d28698ce1c901c5` for planning on
2026-10-23 after the independent review cleared both capture-resource findings.
Work on `feat/isq-462-readonly-context`, based on main `48ea226505309ea04160bcc30fe6ea42259b34a9`.
Track [ISQ-462](https://linear.app/isqrd/issue/ISQ-462/define-read-only-context-attachments-independently-of-editable-scope).
User approved this plan and Native execution on 2026-10-24; implementation is in progress. Keep it with the
implementation PR. Recommend Native execution with a final independent review:
the four tasks share the capture/coordinator interfaces and are best done in order.

## Global Constraints

- Keep the existing **32,768-byte complete message limit**, including draft,
  metadata, fences and all attachments. Count UTF-8 bytes; refuse atomically.
- Bound source-line spans to **1 MiB before materializing their text**; independently
  prove the **expanded selection fits 32,768 bytes** before visual extraction.
- Diagnostics: **1,000 cached-record acquisition cap**, **100 matching records**
  in output. Count and get are synchronous; a narrower range cannot bypass the
  cache cap. Neither cap promises bounded total allocation or latency.
- Retain the existing **1 MiB encoded command, 64-turn and 32 MiB conversation limits**.
- Capture loaded, named, normal, UTF-8, nonbinary buffers under the pinned physical
  root, including unsaved/new buffers. Reject symlink components and outside-root
  paths; do not save, reload or read source-file contents from disk.
- Keep literal filenames literal. Reject CR, NUL, invalid UTF-8, DEL and other
  controls except tab/LF in captured content. JSON-quote relative source names.
- Preserve exact accepted character/line/block/exclusive selections, buffer LF
  representation, whole-buffer final-newline state, and dynamic Markdown fences.
- `message` alone carries context. `selection`/`sources`, workspace preparation,
  manifests, source fingerprints, review registries and publisher inputs stay fixed.
- Managed Codex and OpenCode only; no new mounts, callbacks, sockets, native
  fallback, setup options or default keymaps. Native delivery stays unchanged.
- Attach is local and explicit. No provider/auth/LSP work, automatic refresh or
  replay. Existing Send/Retry/Hide/Close/New semantics and saved-source guards stay.
- Use the isolated runner and synthetic providers; preserve sandbox checks.
  Existing runtime-version restrictions remain unchanged. No real-account calls.

## Review Focus

1. Tiny source text with huge virtual padding must refuse before extraction;
   tab, wide/combining and exclusive selections that fit retain their text — Task 1.
2. Literal `$`/percent/non-ASCII filenames, unsaved ancestors and same-root
   symlink aliases must not change the source identity or expand paths — Task 1.
3. Focus autocommands can edit a source, window options or composer, or replace
   the owner: refusal must preserve the newer draft and source edits — Task 2.
4. One matching diagnostic in a large cache still hits the whole-cache policy;
   nested producer data stays out of the prompt without a false memory claim — Task 3.
5. A snapshot edited at its source after attachment must survive an explicit safe
   Retry unchanged and never become an editable file on resume — Task 4.

## File Ownership and Sequence

| Boundary | Files and responsibility |
| --- | --- |
| Source capture | New `lua/ai/chat_context.lua`; export the existing resolver from `lua/ai/context.lua`. New `tests/ai_chat_context.lua` covers paths, text, limits and source guards. |
| Composer actions | Existing `lua/ai/chat.lua`, `lua/ai/chat_view.lua`, `lua/ai/init.lua`; extend `tests/ai_chat_selection.lua`, `tests/ai_chat_view.lua`, `tests/draft_setup.lua` and `tests/fixtures/ai/chat_ui.lua`. |
| Diagnostics | Same capture helper/coordinator/registration; new `tests/ai_chat_diagnostics.lua` with synthetic namespaces and the existing chat fixture. |
| Backend boundary and lifecycle | Existing concrete turn preambles; new `tests/ai_chat_readonly_context.lua`; extend controller, recovery and TUI suites plus their existing fake peers. |
| Usage and evidence | Update `README.md` and `doc/draft.txt` with their owning actions; update `tests/README.md`; new `docs/validation/2026-10-23-readonly-context.md` and two real UI captures. |

Tasks run sequentially. The new test names follow runner discovery; no runner
registration or new fixture framework is needed. Use each named test group as a
small red/green cycle; restore patched APIs in cleanup even when an assertion fails.

### Task 1: Capture and render bounded buffer snapshots

**Files:** Create `lua/ai/chat_context.lua`, `tests/ai_chat_context.lua`.
Modify `lua/ai/context.lua` only to export its existing physical-source resolver.

**Interfaces:**
- Consumes `ai.context.selection(bufnr, marks) -> {bytes, first, last}|nil, reason`.
  `marks` retains `{mode, first, last, inclusive}`; positions are four-number lists.
- Export `ai.context.physical_source(name) -> absolute_path|nil` with its existing
  nearest-existing-ancestor behavior; native callers keep their current semantics.
- Produce `ai.chat_context.capture_text(root, bufnr, marks_or_nil) -> Capture|nil, reason`.
  Nil marks mean whole buffer; explicit `V` marks mean whole selected lines.
- `Capture = {block = string, guard = table}`. `block` is the complete rendered
  attachment. `guard` is opaque, ephemeral source identity/options/tick data.
- Produce `ai.chat_context.unchanged(guard) -> boolean` for the coordinator's
  post-focus check. This verifies source identity/options, not disk contents or
  conversation ownership. No capture survives in a hidden store after append.

- [x] Write `test_buffer_snapshot_fidelity` in the new Lua suite using real named
  buffers. Use `capture_text` directly and assert the following cases:

  ```lua
  -- Each row is (buffer lines, endofline, expected text body, final-newline label).
  local cases = {
    { { "café" }, true, "café\n", "yes" },
    { { "café" }, false, "café", "no" },
  }
  -- For each case: capture exists, contains the exact body and newline label,
  -- source bytes/modified flag are unchanged, and the block uses LF boundaries.
  -- Also accept an empty whole buffer; refuse an empty visual selection.
  ```

  Test character/line/block/exclusive selections against the existing extractor
  on small input; embedded backticks require a longer fence. CRLF fileformat uses
  editor LF text. Assert labels contain relative path, kind, line span, UTC capture
  time and modified state. Whole-buffer metadata also exposes final newline yes/no
  so the closing-fence separator cannot disguise missing final newline.
- [x] Run `python3 -I -B tests/run.py ai_chat_context`; expect failure because the
  capture module is absent, not because the fixture or environment is broken.
- [x] Export the resolver and implement `capture_text`/`unchanged`. Compare the
  normalized absolute name to its physical resolution and require the root prefix
  before reading buffer lines. Reuse `ai.review.reducer.is_text(bytes)` for UTF-8
  validation plus the contract's control-character check; do not use or weaken
  `staged_sources.valid_text`/`text_buffer`, which enforce editable-file rules.
  Keep rendering private to the helper and source revalidation separate from it.
- [x] Add `test_source_identity_and_guards`: existing/unsaved/new named buffers;
  literal `$`, spaces, `%` and Unicode names; symlinks pointing both inside and
  outside root; unnamed/special/unloaded/binary/non-UTF-8 buffers; invalid UTF-8,
  NUL, CR, DEL and controls. Assert canonical refusal or exact literal attribution.
  Change buffer text/name/encoding/EOL and capture-relevant window options after
  capture: `assert(not context.unchanged(capture.guard))`. No disk-content reads.
- [x] Add `test_preflight_before_materialization` with counted/wrapped extraction
  APIs. Include exactly 1 MiB versus 1 MiB+1 source spans, a small selected range
  in a larger buffer, and a tiny rectangle whose enclosing span exceeds 1 MiB.

  ```lua
  -- Set virtualedit=all and use 100 lines containing "x".
  local marks = { mode = "\22", first = {buf, 1, 1, 0}, last = {buf, 100, 2, 999} }
  -- After wrapping getregion to count calls:
  assert(context.capture_text(root, buf, marks) == nil)
  assert(getregion_calls == 0) -- 200 source bytes would expand to 100,199 bytes.
  ```

  Also test excessive row counts before `getregionpos`, a very long single line,
  partial tabs, wide/combining characters and exclusive endpoints. Test 32,768
  and 32,769 expanded bytes independently from final block overhead: extraction
  may be bounded yet the completed block still correctly refuses.
- [x] Implement preflight before calling the existing extractor. Use buffer byte
  offsets to cap the source span before fetching lines. Bound row count using
  required separators before enumerating positions. Use `getregionpos` with
  `eol=true` and the same window/options to account for selected byte spans,
  partial-character replacement spaces and virtual padding arithmetically; never
  allocate padding to measure it. Include combining bytes and linewise final LF.
  Stop on overflow or an unprovable size. Only then call `ai.context.selection`;
  retain its own post-extraction checks and the final rendered-block byte check.
- [x] Run `python3 -I -B tests/run.py ai_chat_context ai_context`; expect both suites
  to pass, including unchanged native context behavior. Run `stylua --check lua tests`.
- [x] Commit `feat: capture bounded read-only buffer context` with these files only.

### Task 2: Attach snapshots through the existing composer

**Files:** Modify `lua/ai/chat.lua`, `lua/ai/chat_view.lua`, `lua/ai/init.lua`,
`tests/ai_chat_selection.lua`, `tests/ai_chat_view.lua`, `tests/draft_setup.lua`,
`tests/fixtures/ai/chat_ui.lua`, `README.md`, `doc/draft.txt`.

**Interfaces:**
- Consume Task 1's `Capture`, `capture_text` and `unchanged`.
- Preserve `chat:attach(selection) -> true|nil, reason` and
  `runtime:chat_attach(selection)`, where selection is nil, `"x"`, or `{line1,line2}`.
- Reuse `view:draft() -> text|nil, reason, stamp` and
  `view:append_draft(block) -> true|nil, reason`; combined-message authority remains
  in the view. A private coordinator `append_context(capture, state, visual)` may
  share show/revalidation/append with Task 3; it introduces no public API or state.

- [ ] Update `ai_chat_selection` expectations for named unselected/dirty buffers
  and no-range whole-buffer attachment. Add `test_attach_is_local_and_undoable`:

  ```lua
  local before = draft()
  assert(runtime:chat_attach()) -- current unselected, unsaved named buffer
  assert(draft():find("Read-only context snapshot", 1, true))
  assert(vim.g.chat_fixture_prompts == 0)
  -- Undo one attachment: assert(draft() == before); redo restores the same bytes.
  -- Assert original buffer text/modified state and editable selection are unchanged.
  ```

  Extend the existing in-process fixture to retain sent command copies in
  `vim.g.chat_fixture_commands`; use them only as observations, not a replacement
  for Task 4's production-controller authority checks. Preserve exact visual
  cases and snapshot immutability after later source changes.
- [ ] Run `python3 -I -B tests/run.py ai_chat_selection ai_chat_view draft_setup`;
  expect old no-range/selected-only behavior and header assertions to fail.
- [ ] Replace attach-only saved-source/disk comparison with `capture_text`.
  Keep saved-source capture for opening and sending intact. Capture visual marks
  before leaving Visual mode; retain whole-line command ranges. Record the owner
  reference, view revision and composer stamp before capture. After showing
  the composer, check owner identity, view revision, composer stamp and
  `unchanged(capture.guard)` before the one atomic append. Refuse closed, closing
  and recovery-required owners; allow draft preparation during an active turn.
  Change the header to `Editable files:` and the command description to buffer
  snapshots. Notice: `Context attached. Edit or remove it in the composer. No
  editable files were added; Ctrl-S sends.`
- [ ] Add `test_focus_races_preserve_newer_state`: BufEnter/WinEnter handlers edit
  or rename the source, change its options, alter the composer or replace/close
  the owner. Assert attach returns nil, the handler's draft/source bytes remain,
  and no command is dispatched. Add `test_complete_message_byte_budget`:

  ```lua
  view:set_draft(string.rep("x", 32760))
  assert(view:append_draft("123456") == true) -- includes two separator bytes
  assert(#assert(view:draft()) == 32768)
  local prior = assert(view:draft())
  assert(view:append_draft("é") == nil)
  assert(view:draft() == prior)
  ```

  Include metadata/fence overhead, long backtick runs, multibyte overflow and
  multiple attachments through the public action. No truncation or partial append.
- [ ] Update both usage documents and command tables: no-range whole-buffer,
  exact Visual/ranged behavior, unsaved/new named in-root buffers, explicit
  snapshot labeling, source/message bounds, manual refresh and fixed editable
  scope. Remove the old claim that dirty context or every stale disk buffer is
  refused; retain the requirement to save dirty **editable** files before Send.
- [ ] Run `python3 -I -B tests/run.py ai_chat_context ai_chat_selection ai_chat_view draft_setup ai_chat ai_runtime`;
  expect all selected suites to pass. Commit `feat: attach buffer snapshots to managed chat`.

### Task 3: Attach cached diagnostic snapshots

**Files:** Modify `lua/ai/chat_context.lua`, `lua/ai/chat.lua`, `lua/ai/init.lua`,
`tests/draft_setup.lua`, `README.md`, `doc/draft.txt`; create `tests/ai_chat_diagnostics.lua`.

**Interfaces:**
- Add `capture_diagnostics(root, bufnr, range_or_nil) -> Capture|nil, reason` to
  `ai.chat_context`; same opaque guard and `unchanged` as Task 1.
- Add `chat:diagnostics(range_or_nil)` and `runtime:chat_diagnostics(range_or_nil)`;
  range is `{line1,line2}`. Register `:[range]NvimAIChatDiagnostics`, no path
  argument and no default keymap. Nil range means all current-buffer records.
- Share Task 2's guarded append. A no-match result returns a local notice through
  the current refusal/notice path and leaves draft, scope and owner usable.

- [ ] Write `test_diagnostic_acquisition_and_output_caps` with synthetic
  namespaces and counters around `vim.diagnostic.count/get`:

  ```lua
  -- Seed 1,001 total records, exactly one starting on line 1.
  assert(context.capture_diagnostics(root, buf, {line1=1, line2=1}) == nil)
  assert(get_calls == 0)
  -- Seed 1,000 records with that one match: capture succeeds, get_calls == 1.
  -- Within an eligible cache: 100 matching records fit; 101 refuse, never truncate.
  -- A zero cache needs no get; API errors/bad counts/count mismatch leave the draft.
  ```
- [ ] Run `python3 -I -B tests/run.py ai_chat_diagnostics draft_setup`; expect
  failure because diagnostic capture/command are absent.
- [ ] Implement synchronous count preflight, one get, returned-count validation,
  start-line filtering and deterministic sorting. Serialize only one-based line,
  byte column, severity, optional source/code and message. Validate integer
  nonnegative positions, known severity and allowed field types/text; missing
  source/code is omitted. Ignore unrelated nested fields rather than traversing
  or serializing them. Bound each selected field before escaping/fence generation
  and charge aggregate rendered bytes. Reject an oversized matching set atomically.
  Keep an in-code note: `shortcut: diagnostic count scans the cache and get copies
  nested data; replace acquisition if a hard memory/latency bound is required`.
- [ ] Add `test_cached_diagnostics_are_attributed_text`: two namespaces, duplicates,
  missing/Unicode source and numeric/string code, multiline messages, stale
  positions beyond EOF, malformed/negative positions and invalid text. Preserve
  duplicates, sort by position/severity/source/code/message with a deterministic
  type order for numeric versus string codes. Assert starting-line rather than
  end-position overlap filtering and exact `Cached diagnostics; freshness unverified`.
  A small nested sentinel must be copied by the API but absent from `block`.
- [ ] Add `test_diagnostic_action_is_passive`: execute the public command on an
  unsaved unselected named buffer; assert zero provider/auth/LSP requests, no
  source text implicitly included, unchanged editable selection, normal edit/
  remove/undo, and no mutation after a later diagnostic/source update. Zero matches,
  malformed input and overflow retain the existing draft. Exercise the same
  post-focus source/composer races through the shared coordinator.
- [ ] Wire registration, range decoding and runtime dispatch. Update both usage
  documents with capture time/modified/freshness labels, allowlisted fields,
  whole-cache versus matching-record caps, start-line filtering, and the remaining
  allocation/latency limitation. A smaller range must not be suggested as a fix
  for a cache exceeding 1,000 records.
- [ ] Run `python3 -I -B tests/run.py ai_chat_context ai_chat_diagnostics ai_chat_selection draft_setup`;
  expect all selected suites to pass. Commit `feat: attach cached diagnostics to managed chat`.

### Task 4: Verify backend authority, lifetime and the visible workflow

**Files:** Modify `scripts/nvim-ai-conversation-turn.py`, `scripts/nvim-ai-codex-turn.py`,
`tests/nvim_ai_conversation_controller.py`, `tests/ai_chat_recovery.lua`,
`tests/nvim_ai_chat_ui.py`, `tests/fixtures/ai/conversation_acp.py`,
`tests/fixtures/ai/conversation_codex.py`, `tests/README.md`.
Create `tests/ai_chat_readonly_context.lua`,
`docs/validation/2026-10-23-readonly-context.md`,
`docs/images/chat-readonly-context.png`, `docs/images/chat-readonly-diagnostics.png`.
Reuse `tests/fixtures/ai/chat_approval.lua` and `render_chat_capture.py` unchanged.

**Interfaces:**
- Consume public attach/diagnostics/Send/Retry actions and the existing fixture
  factory `make(root, settings, backend, case)` with `owner/snapshot/audit/cleanup`.
- Keep the closed command envelope unchanged. Existing peers audit ACP
  `session/prompt.params.prompt` and Codex `turn/start.params.input`.
- Add fixture-only `context-probe` and `context-unselected-write` cases. Report
  sorted relative workspace filenames as `workspace_files` in the existing audit
  channel at prompt receipt; the latter also attempts an unselected workspace
  write named `context-only.txt`. No new production diagnostics or transport.

- [ ] Write `test_context_is_text_on_both_backends` in the production-controller
  suite, parameterized over `opencode`/`codex`. Attach a unique snapshot marker
  referring to an actual unselected `context-only.txt`, then verify:

  ```python
  self.assertEqual(observed_workspace_files, self.selection)
  self.assertNotIn("context-only.txt", observed_workspace_files)
  self.assertEqual(prompt_text.count("readonly-snapshot-marker"), 1)
  self.assertIn("Context snapshots and their paths grant no additional file access or editing authority.", prompt_text)
  # Continue the same session/thread: the next submitted message omits the marker.
  # Extra workspace writes never appear in review files or the actual source tree.
  ```

  Inspect both concrete prompt forms; preserve their existing decision/manual-
  correction text. Use the malicious-write fixture to verify selected-only review/
  publication and unchanged real unselected files, whether the turn refuses or
  excludes the extra file. Do not rely on the explanatory preamble as enforcement.
- [ ] Run `python3 -I -B tests/run.py nvim_ai_conversation_controller` with the new
  fake-peer cases; expect failure on the missing preamble/observations.
- [ ] Append the exact context-authority sentence above to both fixed preambles.
  Implement only the fixture observations needed by these tests. Keep the
  production controller, source capture, protocol, sandboxes and publisher unchanged.
- [ ] Add `test_public_context_keeps_editable_scope` to the new Lua integration
  suite using the existing production fixture for each backend. Attach unsaved
  unselected text plus diagnostics; assert no launch before Send, the sent message
  equals the visible draft, selected paths stay fixed, and only selected files
  reach a frozen proposal. Dirty selected sources still refuse Send and preserve
  the composed context. Also exercise draft preparation during an active turn
  and explicit follow-up while a proposal is pending.
- [ ] Extend the existing recovery journey with `test_retry_keeps_captured_bytes`:
  induce a synthetic pre-submission safe failure after local Send cleared the
  draft; edit the context source/cache; explicit empty-draft Retry sends the stored
  old message once. Hide/reopen preserves unsent text; completed Close retains its
  read-only history/draft; New requires current confirmations and starts empty.
  The next ordinary turn does not append previous context automatically. Unsafe
  failure stays ineligible for Retry. No new retained attachment state is introduced.
- [ ] Update the actual-key TUI attachment test for the new labels and add a
  diagnostic preview case using synthetic cached records. Verify `Editable files:`
  at wide/narrow widths, unsaved attribution, edit/undo/redo, Hide/reopen and one
  explicit send. Export the two named PNGs from real ANSI captures using the
  existing capture helper; inspect the images before committing. The runner
  intentionally strips ambient capture variables: follow the isolated manual
  capture setup in `tests/README.md`, rather than weakening its environment policy.
- [ ] Run `python3 -I -B tests/run.py ai_chat_readonly_context ai_chat_recovery nvim_ai_conversation_controller nvim_ai_codex_turn nvim_ai_conversation_protocol nvim_ai_chat_ui`;
  expect all selected suites to pass. Document exact commands/results and screenshot
  paths in the validation record, including the diagnostic allocation limitation.
  Link it from `tests/README.md`. Commit `feat: preserve context authority across managed backends`.

## Branch Verification and Delivery

- [ ] Run `python3 -I -B tests/run.py`, `stylua --check lua tests` and
  `git diff --check`; require zero failed suites and no formatting/whitespace errors.
  Record actual skips separately from passes. Use a supported host for sandbox
  fixtures; do not relax ownership, socket or namespace checks to get a green run.
- [ ] Review the full branch against all eight spec acceptance classes, including
  both usage documents and screenshots. Obtain the requested independent final
  review; fix confirmed findings and rerun the affected checks.
- [ ] Push the implementation and open one PR containing the approved spec, this
  plan, code, regression coverage and evidence. Link ISQ-462; report CI at the
  reviewed head. Existing installed-runtime evidence applies only while runtime/
  sandbox code is unchanged. No live-account validation is part of this slice.
- [ ] Update ISQ-462 with the PR and verified result; distinguish design approval,
  implementation progress and shipped behavior. Follow the existing integration
  decision at delivery; this plan does not itself merge or publish a release.

## Plan Self-Review

All spec sections map to tasks: capture/attribution/bounds to Task 1; user actions,
atomic composer append and focus races to Task 2; diagnostic semantics/acquisition
limits to Task 3; backend authority, retention, retry and both supported backends
to Task 4. Each of the five Review Focus cases has an owning regression group.
`Capture`, guard checks and range/mark signatures match across task boundaries.
The only new production module is `ai.chat_context`; no hidden attachment state,
new dependencies or protocol changes are required. Test commands name discovered
or explicitly planned suites. Plan review does not establish implementation success.
