# Claude CLI review validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish what one pinned Claude CLI actually does before and after a Neovim diff decision, then make an evidence-based recommendation for Draft.

**Architecture:** Observe the existing claudecode.nvim RPC boundary and the real client's filesystem activity in an independent disposable repository. Keep editor decisions, response transmission, client writes and finalization as separate events. Reuse the earlier editor probes for observer checks; implement no Draft backend or alternate writer.

**Tech Stack:** Linux, Neovim 0.12.4, Lua, Python standard library, tmux, installed strace, pinned Claude CLI and claudecode.nvim.

**Spec:** [ISQ-463](https://linear.app/isqrd/issue/ISQ-463); [original study](https://linear.app/isqrd/document/claudecodenvim-study-architecture-diff-review-and-lessons-for-draft-7658617adef7); [current prerequisite sources](../../research/2026-10-18-claude-cli-validation-prerequisites.md).

## Global Constraints

- Pin and record the Claude CLI, claudecode.nvim and Neovim versions, permission mode and IDE configuration used in the exercise.
- Keep model-visible tools separate from internal CLI/editor RPC.
- A plugin response named FILE_SAVED is not a filesystem acknowledgement.
- This is research; it does not ship an adapter, change the OpenCode roadmap, or reopen ISQ-213's native resize/picker work.
- Keep this plan on `research/isq-463-claude-cli-review` and include it with the eventual validation PR. No standalone plan PR.
- Initial plugin pin: `2390c6e45c4789072c293ac69de051d169668b29`, matching the study. Record incompatibility before considering a separate version comparison.
- Run the primary trial in interactive `--permission-mode default`, with effective rules inspected and IDE Diff tool set to `auto`. Do not substitute `acceptEdits` or bypass permissions.
- Use synthetic fixtures in a separate temporary repository with private HOME/XDG/Claude configuration. The research worktree holds artifacts, not the live fixture. Establish the account/model and auth readiness before requests; do not copy credentials into evidence.
- Proposed live budget: at most ten explicit user prompts, one per matrix case, with no automatic retries or fallback. This is not a monetary or HTTP-request cap. Stop on failed baseline or unusable observations.
- Bound each automated case to five minutes and graceful teardown to twenty seconds. On timeout, stop only the fixture-owned processes and record an incomplete case.
- Preserve raw private evidence and publish a sanitized report. Planning does not install Claude, authenticate, or send any provider prompt.

## Review Focus

- Source bytes or path identity change while review is pending: Task 3 distinguishes rejection, reconfirmation and overwrite from what the trace actually shows.
- The human changes the proposal: Tasks 2–3 compare returned and published bytes, including the final newline.
- Review is skipped or routed elsewhere: Task 2 requires a real baseline; Task 3 includes a terminal-routing control and records alternate tools.
- Disconnect races response transmission and publication: Tasks 1 and 3 keep local enqueue, connection close and observed writes distinct; uncertain ordering stays unknown.
- Finalization succeeds while publication failed: Task 3 checks saved bytes, editor state and errors separately from response names and tab cleanup.

## Artifact map

Create during execution:

- `tests/manual/claude_ide_review.py`: opt-in fixture lifecycle, checkpoint snapshots, process tracing and result assembly. Reuse the tmux/remote-expression pattern in `tests/nvim_ai_chat_ui.py`; do not add a general test framework.
- `tests/manual/claude_ide_observer.lua`: minimal wrappers around pinned `claudecode.server._handle_request(client, request)` and `send_response(client, id, result, error)`. Delegate unchanged to the originals and record selected request/response fields, including deferred results.
- `docs/validation/claude-cli-review.md`: version/mode matrix, observed chronology, exact-byte outcomes, unknowns and recommendation.
- `.test-results/claude-cli-review/<run-id>/`: ignored, private traces, snapshots and captures. No credentials or account identifiers in the public report.

Modify only `tests/README.md` to document the opt-in exercise. Leave runtime, default test discovery and public commands unchanged. The existing fourteen editor-only probe cases remain prior evidence; do not repeat them as live-CLI results.

### Task 1: Prove the observer before spending a provider turn

**Inputs:** The pinned source and prior probe scripts under `.test-results/claudecode-study-2026-10-16/` in the main checkout. If those local files are unavailable, reproduce only the three observer controls below from the pinned handlers.

**Output contract:** A run manifest records versions, model, permission/diff settings, fixture paths, explicit prompt count and provenance (`synthetic` or `real-cli`). Event records contain `origin`, per-origin `sequence`, `monotonic_ns`, `kind`, request ID/tool where present, relative path, byte length/hash, existence and file identity. Preserve synthetic proposal/accepted bytes in private snapshots. Match responses by client/request ID, not arrival order in a separate collector.

- [ ] Check local executables and exact versions. Select a specific Claude release during setup, disable updates for the trial, and verify the version again afterwards. If installation or authentication is missing, report that prerequisite before a live request.
- [x] Add observer controls for accept, reject and edited proposal using the real pinned editor handlers with a synthetic client. Assert one correlated request/response, correct accepted bytes, and unchanged disk at the response boundary.
- [x] Run `python3 -I -B tests/manual/claude_ide_review.py --self-test --plugin /absolute/pinned/claudecode.nvim`. Before implementation, expect the observer assertions to fail; after minimal implementation, require all three controls to pass without launching Claude or accessing account state.
- [x] Verify process-scoped filesystem tracing can distinguish in-place writes and temporary-file rename replacement using a synthetic writer. Exclude payload decoding and filter exported events to the fixture; keep private raw traces private. If tracing is unavailable, mark writer attribution/ordering unknown and do not claim them from polling alone.
- [x] Capture file existence, identity and exact bytes at request, decision/response, finalization and teardown. Also retain the independent syscall trace; checkpoints alone do not prove the absence of intervening writes. Wrappers must not replace, delay or fabricate ordinary responses; enable a delay/drop only in its explicitly labelled fault case.
- [x] Commit observer and controls when the three controls and trace checks pass; retain this plan and prerequisite memo on the same branch.

### Task 2: Establish one real CLI baseline

**Inputs:** Task 1's checked observer and a pinned, authenticated runtime. **Output:** A reproducible real CLI-to-Neovim trace, or a precise compatibility/setup failure.

- [ ] Create a fresh independent fixture repository containing one small saved Lua file. Start a clean Neovim and the plugin's real server/terminal connection. Verify `claude --version`, auth readiness by exit status, `/ide`, effective permissions and Diff tool `auto`; record sanitized fields only.
- [ ] Send one bounded instruction changing one literal. Confirm actual `tools/call` → `openDiff` traffic, pending review and unchanged source bytes before accepting through normal editor keys. If the CLI writes by another route or no diff appears, record the observed route and stop the IDE matrix; do not substitute a synthetic request and call it a live pass.
- [ ] Compare proposal bytes, accepted response bytes and final saved bytes. Record actual `close_tab` arguments and its position relative to filesystem events. An attempted send is not proof that the CLI received it; report that distinction.
- [ ] Confirm process exit, server/lockfile cleanup and fixture cleanup. Record any retained accepted proposal after failure before removing the disposable fixture. Only continue when the baseline produces usable evidence.

### Task 3: Run the bounded case matrix

Each row uses a fresh fixture and at most one explicit prompt. Reset configuration and state between rows. The baseline consumes the first of ten proposed prompts. Record observations rather than making favorable upstream behavior an assumption.

| Case | Intervention and evidence required |
| --- | --- |
| 1. Baseline | Task 2; unchanged source until acceptance, exact published bytes, actual finalizer title/order. |
| 2. Reject | Reject the real proposal; inspect disk, CLI result and retained editor state. |
| 3. Edited split proposal | Change one literal and add a trailing blank line in the proposal; compare returned bytes with what the CLI writes. |
| 4. Content conflict | Change saved source bytes after `openDiff`; identify whether the CLI refuses, asks again or overwrites. |
| 5. Identity conflict | Replace the source with a new inode containing the same original bytes; distinguish identity checks from content checks. |
| 6. New file | Request one absent fixture path; record creation timing, review routing, exact contents and cleanup. |
| 7. Pending disconnect | Close the IDE connection with review pending; observe rejection/retention and any client write. |
| 8. Accepted disconnect | Close the IDE connection after local acceptance response transmission is attempted. Record actual chronology; do not claim the client received the response or that disconnect preceded the write unless evidenced. |
| 9. Write failure | After review opens, make the fixture file and parent unwritable, then accept. Observe write errors, retained accepted text and finalization; restore permissions in teardown. |
| 10. Terminal control | Explicitly select terminal diff rendering and repeat the small edit; distinguish terminal approval and file writes from IDE RPC. |

- [ ] Preserve the exact real `close_tab` title and call it through the normal tool handler in evidence checks. The previous direct-finalizer probe did not test its wire-level title convention.
- [ ] For every case, classify outcome as observed, refused/incompatible or inconclusive. Tool names or `FILE_SAVED` alone cannot establish write success, tool visibility, conflict protection or durable persistence.
- [ ] If a fault misses its timing window, record that limitation; do not spend an unplanned prompt retrying. Keep auth/setup failures separate from protocol findings.
- [ ] Verify cleanup and summarize total explicit prompts. Retain the original failed observer/run evidence if a collector assertion needs correction; verify corrections offline where possible.

### Task 4: Decide what Draft should borrow

- [ ] Write the validation report with pinned environment, matrix, supported observations, raw-evidence references and remaining unknowns. Separate documented behavior, source interpretation, synthetic controls and actual CLI observations.
- [ ] Recommend one outcome: reuse only editor interaction ideas; investigate a narrowly scoped native companion; or defer integration because routing/write boundaries are insufficiently established. No automatic adapter implementation follows this report.
- [ ] Update ISQ-463 and the original Linear study in place. Complete acceptance items only where evidence supports them. Preserve ISQ-461's separate everyday-use feedback item.
- [ ] Verify the manual self-test and `git diff --check`; run the default suite once if shared test/runtime code changed. Document the manual command in `tests/README.md` and create one validation PR containing plan, observer, evidence summary and limits. Do not merge without the applicable session authorization.

## Planning status and handoff

The [Linear execution plan](https://linear.app/isqrd/document/claude-cli-review-validation-execution-plan-0986dea07004) is attached to the existing ISQ-463 issue.

Planned on 2026-10-18 from `bba5c4b`. Claude is not on PATH or at the usual executable locations checked. Neovim 0.12.4, tmux and strace are available. No observer, live matrix or installation has been executed for this plan.

Recommended execution is native/inline: the observer, baseline and fault cases are sequential and share the same evidence contract. Start with Task 1; installation/account readiness is the dependency for Task 2. The plan itself does not require another full Draft suite run because it changes documentation only.

Pinned source interfaces: [RPC/deferred responses](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/server/init.lua#L174-L260), [openDiff](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/tools/open_diff.lua), [close_tab](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/tools/close_tab.lua).

## Execution status — 2026-10-19

The [validation record](../../validation/claude-cli-review.md) contains seven passing
offline controls: accept, reject, edited proposal, two protocol-error paths and
both filesystem write strategies. The observer uses real pinned handlers and a synthetic transport.
No real CLI was installed or invoked; no provider prompt was sent. Task 2 and
the ten-case live matrix await an account route and pinned authenticated runtime.
The live runner, cross-clock correlation and arbitrary temporary-file tracing
still need verification before a baseline. This branch is a partial validation
deliverable and must not close ISQ-463's live acceptance items.
