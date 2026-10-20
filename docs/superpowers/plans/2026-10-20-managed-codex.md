# Managed Codex Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> (recommended here) or superpowers:subagent-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Codex through Draft's existing composer, isolated selected-file
workspace and frozen diff, publishing project bytes only after explicit approval.

**Architecture:** Add a concrete Codex turn adapter and private state owner to the
existing controller. Extend its bounded pipe worker with an explicit Codex wire
mode; reuse staging, review revisions, manual corrections, receipts and publishing.
Prove the pinned runtime's command confinement before exposing managed support.

**Tech Stack:** Linux, Neovim 0.12+, LuaJIT, Python 3 standard library, Bubblewrap,
tmux and Codex CLI 0.163.0 app-server over stdio. No new package dependencies.

**Spec:** [Approved design](../specs/2026-10-19-managed-codex-design.md).
User approved the design and implementation plan on 2026-10-20; Native execution selected.
Work on `feat/isq-491-managed-codex`, based on `bba5c4bfda8f1f779348bd5b776235924a07c90d`.
Track [ISQ-491](https://linear.app/isqrd/issue/ISQ-491/bring-codex-into-drafts-managed-conversation-and-pre-write-review).

## Global Constraints

- Pin CLI **0.163.0** and its generated stable schemas; refuse version mismatch.
- Retain **1–16 files / 1 MiB** aggregate selection and existing byte/mode checks.
- Retain worker limits: **16 MiB/frame, 32 MiB/stream, 20000 messages**.
  Codex additionally enforces **depth 32** before decoding (execution ruling).
- Retain **60 s startup, 15 s RPC, 180 s generation, 5 s cancellation** deadlines;
  shutdown has **3 s each** for EOF, TERM and KILL. Output never renews deadlines.
- Retained state: **64 MiB, 4096 entries, depth 8**; owned 0700 directories and
  single-link 0600 regular payload files. Only exact root `installation_id` may
  be 0644. Count all retained entries below root (root depth 0) and all regular
  file sizes, including auth. No links, special files, adoption or broad globs.
- Mount selected copies at `/tmp/project`; the actual project, editor socket
  and trusted proposal directory remain absent. System runtime stays read-only.
- Inner `workspaceWrite`: only `/tmp/project` writable, `networkAccess=false`,
  `excludeTmpdirEnvVar=true`, `excludeSlashTmp=true`; `approvalPolicy="never"`,
  `approvalsReviewer="user"`. Retain both sandbox layers and process supervision.
- Provider connectivity belongs to the engine. Test command network denial
  while the outer sandbox can reach a local provider; `--unshare-net` is no proof.
- Keep private `CODEX_HOME=/home/agent/.codex`, generated profile and file auth.
  No ambient credentials/configuration, login, native fallback or automatic replay.
- An explicit `chat` table is complete; absence preserves current OpenCode
  staged preferences. Backend identity is fixed for the owning conversation.
- Preserve public `NvimAI*` commands, internal `ai` names, native capabilities
  and OpenCode behavior. No second UI/publisher or generic backend registry.
- Keep this plan with implementation on this branch/PR. Claude comparison and
  broader read-only context remain separate ISQ-463 and ISQ-462 work.

## Review Focus

1. Terminal notifications buffered after the apparent completion must still
   invalidate review before shutdown finishes — Tasks 2 and 4.
2. A new thread without a persisted user message cannot resume; retry is explicit
   and needs positive pre-submission cleanup evidence — Tasks 1 and 4.
3. Credential paths with spaces/non-ASCII, private token rotation and replaced
   directory entries must preserve source credentials and refuse tampering — Task 3.
4. Revision after partial decisions and a supported LF correction must retain
   receipts, require a fresh review visit and avoid an extra model turn — Task 6.
5. Passive UI/health with the other backend missing must not launch app-server
   or import auth; stale callbacks cannot change the conversation's backend — Task 5.

## File Ownership and Sequence

| Deliverable | Owned files and responsibility |
| --- | --- |
| Runtime proof | New `tests/nvim_ai_codex_runtime.py` and `tests/fixtures/ai/codex_responses.py`; opt-in runner/CI wiring and validation evidence. |
| Pipe transport | Existing `scripts/nvim-ai-acp-worker.py`; new `tests/nvim_ai_codex_worker.py` and `tests/fixtures/ai/conversation_codex.py`. |
| Profile and retained state | New `scripts/nvim-ai-codex-runtime.py`, `scripts/nvim-ai-codex-store.py` and matching Python suites. |
| Turn lifecycle | New `scripts/nvim-ai-codex-turn.py`, `tests/nvim_ai_codex_turn.py`; existing conversation controller routing. |
| Editor integration | Existing `lua/ai/init.lua`, `conversation_controller.lua`, `conversation.lua`, `chat.lua`, `chat_view.lua`, `lua/draft/health.lua`; setup/usage tests and docs. |
| Acceptance | Existing chat/review tests and UI capture helper; new Codex chat integration suite and final validation record. |

Task 2 can proceed offline if Task 1 is host-blocked. Task 3's artifact policy
depends on a successful real turn/resume inventory. Tasks 4–6 consume prior
interfaces in order. Do not call fake-peer success a passed runtime gate.
Within each task, use the named regression tests as small red/green cycles.

### Task 1: Establish the Pinned Runtime and Confinement Gate

**Files:** Create `tests/nvim_ai_codex_runtime.py`,
`tests/fixtures/ai/codex_responses.py`,
`docs/validation/2026-10-20-managed-codex-runtime.md`.
Modify `tests/run.py`, `tests/README.md`, `.github/workflows/linux-tests.yml`.

**Interfaces:**
- Consumes: the pinned schemas/source and
  [preflight evidence](../../validation/2026-10-19-codex-app-server-preflight.md).
- Produces: runner option `--codex /absolute/executable`, forwarded only as
  `NVIM_AI_REAL_CODEX`; no inherited real-provider environment.
- Produces: fixture `Provider()` context manager with `url: str`,
  `requests: list[dict]`, `enqueue(events: list[dict]) -> None`,
  `hold() -> None`, `release() -> None`. It serves bounded Responses SSE on
  loopback with synthetic credentials; OpenCode's Chat Completions fixture
  cannot be used unchanged.
- Produces: exact stopped-state path/type/mode inventory after initialize,
  completed turn, interrupted turn and stopped-worker resume; no payload bytes.

- [x] Write `test_opt_in_is_explicit` and `test_pinned_cli_confinement`: absent
  flag skips installed execution; an explicit wrong version or denied namespace
  fails. Assert workspace write succeeds, private-state and `/tmp` escape writes
  fail, actual project/editor socket are absent, and a command cannot reach the
  fixture while the app-server engine demonstrably can.
  Key assertions: `assert command_exit == 0`, `assert all(checks.values())`,
  `assert len(provider.requests) > 0`; a namespace error cannot produce `checks`.
- [x] Run `python3 -I -B tests/run.py --codex /absolute/path/to/codex nvim_ai_codex_runtime`.
  Initially expect the missing runner option/test harness to fail, then retain
  a real unsupported-host result separately from implementation failures.
- [x] Implement the opt-in harness using the pinned stable schema and the
  disposable launch shape in the preflight. Add
  `test_empty_thread_resume_fails`, `test_completed_thread_resumes_after_exit`
  and `test_interrupt_requires_terminal`: assert the empty-thread -32600
  negative control, matching thread ID after a completed edit and process exit,
  and matching interrupted terminal event before continuation. Record artifact
  metadata only after reaping; do not count an ID-only fake as resume evidence.
- [x] Add `workflow_dispatch.inputs.codex_runtime` as a boolean, default false,
  to the existing Linux workflow. Its opt-in steps download the official
  `rust-v0.163.0/codex-x86_64-unknown-linux-musl.tar.gz` release asset and verify
  SHA-256 `beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4`
  before extraction/execution. Inspect archive paths and resolve its executable
  unambiguously. Reuse the workflow's existing narrow Bubblewrap AppArmor profile;
  do not change host sysctls, weaken either sandbox or use legacy Landlock.
- [x] Run the optional workflow on this feature ref and the explicit local
  command above where supported. Require actual executed confinement, completion,
  cancellation and resume assertions, not skipped tests. If nested confinement
  still fails, record the failure and pause dependent runtime/store work; Task 2
  remains independently possible. Update the validation file with commit, CLI
  identity, commands, CI URL, exact inventory and any unproved behaviors.
  The checksum above is published metadata from the [official release](https://github.com/openai/codex/releases/tag/rust-v0.163.0);
  this planning turn did not download/execute that archive.
- [x] Commit `test: establish pinned Codex runtime gate`.

### Task 2: Support Codex Frames Without Relaxing ACP

**Files:** Modify `scripts/nvim-ai-acp-worker.py`,
`tests/nvim_ai_acp_worker.py`. Create `tests/nvim_ai_codex_worker.py`,
`tests/fixtures/ai/conversation_codex.py`.

**Interfaces:**
- Consumes: existing `Worker.begin`, `poll`, `notify`, callback and `Exit` contracts.
- Produces: `Worker(..., wire: str = "acp")`; accept only `"acp"` or `"codex"`.
  Preserve all other constructor defaults and existing ACP envelope rules.
- Produces: `poll_events(*, deadline: float, timeout: float = .05) -> int` for
  Codex with no pending RPC; return processed message count using the same
  guards/budgets and at most 64 messages per poll. The deadline is absolute.
- Produces: fake executable fixture selected through test-owned configuration;
  it supports `--version`, `app-server` and deterministic protocol fault cases.

- [x] Write `test_codex_envelopes_and_idle_pump`: use frames without `jsonrpc`,
  timestamped notifications, interleaved callbacks and completion after the
  `turn/start` response. Assert callbacks still run with no pending RPC.
  Add `test_acp_stays_strict`: the same Codex envelope is rejected in default mode.
  After the RPC settles, `assert worker.poll_events(deadline=deadline) > 0`
  and `assert notifications[-1]["method"] == "turn/completed"`.
- [x] Run `python3 -I -B tests/run.py nvim_ai_codex_worker nvim_ai_acp_worker`;
  expect new constructor/pump tests to fail before the implementation.
- [x] Implement the explicit codec branch and idle event pump. Validate the
  observed optional `emittedAtMs` integer on Codex notifications; reject invalid
  envelope structure, duplicate JSON keys/IDs and unsolicited responses.
  Allow additive response payload data only outside authority validation.
  Keep denied client-request replies bounded and preserve cancel responsiveness
  during blocked/partial writes; a partial frame cannot be followed by another.
- [x] Add `test_terminal_validation_during_close`: a late duplicate/contradictory
  terminal callback marks `Exit.settled` false even when exit code is zero.
  Codex shutdown must continue semantic notification validation while reaping,
  without answering new client requests or initiating work. Callback failure
  must not prevent cleanup. Preserve the existing ACP shutdown behavior.
  Assert `result.reaped is True` and `result.settled is False`.
- [x] Run the two suites with malformed UTF-8/JSON, oversized/deep frames,
  cumulative budget, EOF, blocked writes, delayed notifications and sustained
  output cases. Assert bounded failure, no deadline renewal and reaped workers.
- [x] Commit `feat: support bounded Codex app-server transport`.

### Task 3: Own the Private Codex Profile and Retained State

**Files:** Create `scripts/nvim-ai-codex-runtime.py`,
`scripts/nvim-ai-codex-store.py`, `tests/nvim_ai_codex_profile.py`,
`tests/nvim_ai_codex_store.py`. Update Task 1's runtime test and validation record.

**Interfaces:**
- Consumes: `review._private_bytes(path, maximum) -> bytes`, Task 1's real
  artifact inventory, and Task 2's `Worker`/`Exit`.
- Produces: `Store(parent: str = "/tmp")` with `root: Path`, `path: Path`,
  `initialize(auth_file: str) -> None` (once, before launch),
  `check() -> dict[str, int]`, `start(command, *, env, **worker_options) -> Worker`,
  `stop(*, outcome: str, session: str | None = None) -> Exit`, `close() -> None`.
  Only `"completed"`/`"cancelled"` plus a settled exit can authorize reuse;
  any other outcome taints it. Continuation with `session` also requires a
  matching persisted rollout identified by validated path metadata.
- Produces: `sandbox(config: dict, task: Path, store: Store) -> tuple[list[str], dict[str, str]]`
  in the runtime helper. It builds the generated profile and outer launch argv/env.
  Store owns credentials, metadata guards, worker lifetime and stopped seal;
  runtime owns mounts/profile. `Store.start` always selects `wire="codex"`.

- [ ] Write `test_private_auth_import_and_rotation`: import synthetic supported
  API-key and ChatGPT-token files from paths containing spaces/non-ASCII; reject
  unrelated/keyring-only/malformed forms. Assert original bytes unchanged,
  copied auth mode 0600, retained private refresh across two workers, and no
  credential values in events/logs. Bound import at 1 MiB using `_private_bytes`.
  This tests ownership of refresh writes, not actual OAuth refresh.
  Assert `source.read_bytes() == original` and
  `stat.S_IMODE(copied_auth.stat().st_mode) == 0o600`.
- [ ] Write `test_closed_store_policy_and_seal`: allow only the exact artifact
  families/path structures established by Task 1, including valid rollout
  identity; refuse missing rollouts, extra entries, depth 9, entry 4097,
  >64 MiB, links, replacement races, wrong owner/modes and forced exit.
  Assert only exact root `installation_id` permits 0644; auth/rollouts never do.
- [ ] Run `python3 -I -B tests/run.py nvim_ai_codex_profile nvim_ai_codex_store`;
  expect missing helper/import failures.
- [ ] Implement the two concrete helpers. Validate auth at import only; retained
  state inspection stays metadata-only. Preserve private refreshes without
  exporting them. Put helper aliases/caches in disposable scratch, mount the
  generated profile read-only, and exclude scratch from retained seals.
  Require reaping before seal/reuse/removal; unsafe cleanup remains a refusal.
  Do not subclass or broaden OpenCode's three-file whitelist.
- [ ] Add `test_generated_profile_ignores_external_config`: inject hostile ambient
  environment and selected `.codex/config.toml`; assert no external MCP/plugin
  process or unauthorized request starts. Use the pinned untrusted-project
  setting for `/tmp/project`, explicit permissions, disabled bundled skills,
  plugins/MCP, subagents, memories, web search, shell snapshots, updates and
  analytics. Verify effective behavior, not just serialized flags.
- [ ] Run both offline suites and Task 1's explicit installed-runtime command,
  now using this production sandbox/store. Remove the duplicated probe launcher.
  Require the same confinement/turn/resume assertions and closed inventory;
  document any newly observed artifact before admitting it.
- [ ] Commit `feat: own isolated Codex credentials and conversation state`.

### Task 4: Implement Codex Turn Semantics and Controller Routing

**Files:** Create `scripts/nvim-ai-codex-turn.py`,
`tests/nvim_ai_codex_turn.py`. Modify `scripts/nvim-ai-conversation.py`,
`tests/nvim_ai_conversation_controller.py` and the fake Codex fixture.

**Interfaces:**
- Consumes: Tasks 2–3; existing `staging.selected_files`, `prepare_workspace`,
  `freeze_workspace`, `discard_workspace`, `ReviewRegistry` and editor protocol.
- Produces: `Turn(config, store, editor_pipe, *, session=None)` matching the
  existing adapter's `start(command, *, selected=None, context=None,
  manual_corrections=False)`, `advance`, `cancel`, `fail`, `drain_events`
  methods and return contracts. Preserve controller-consumed `task`, `session`,
  `done`, `submitted`, `store_valid`, `on_write_wait` and settled-event fields.
- Produces: closed trusted configuration `backend="opencode"|"codex"`; omission
  remains OpenCode for existing callers. Codex requires `codex`, `bwrap`,
  `model="openai/<id>"`, `auth_file`; reject OpenCode-only `provider` options.
  Backend never becomes an editor/agent command field.

- [ ] Write `test_controller_chooses_trusted_backend` and
  `test_completion_is_not_start_ack`: assert static backend selection, one
  worker, unchanged source bytes and no review before matching terminal
  completion plus settled exit, valid store and current source snapshots.
  At the start acknowledgement, `assert turn.done is False`,
  `assert turn.frozen is None`, `assert source.read_bytes() == original`.
- [ ] Run `python3 -I -B tests/run.py nvim_ai_codex_turn nvim_ai_conversation_controller`;
  expect missing adapter/unsupported trusted configuration failures.
- [ ] Implement the Codex adapter and two explicit controller branches. On Send,
  initialize/validate 0.163.0, send `initialized`, discover models and verify
  sandbox execution with `command/exec` of `/usr/bin/true` before `turn/start`.
  Fail unsupported hosts before a prompt; this readiness check supplements
  Task 1's full confinement proof. Start or resume the exact thread; validate
  returned cwd, model/provider and permissions. Strip `openai/` only at this
  boundary, paginate model discovery within existing budgets, and never
  substitute an unadvertised model.
  Initialize a newly owned Codex store once from trusted `auth_file`, inside
  the controller's failure handling; preserve bounded, secret-free diagnostics.
- [ ] Implement `turn/start` submission fencing, bounded early-event buffering,
  thread/turn/item correlation, permitted text/progress mapping and the idle
  pump. Mark submission uncertain before its first pipe write. Reuse controller
  generation fences, receipt-derived context and local correction seeds.
  A terminal `completed` event is necessary but insufficient to freeze; call
  the existing freezer only after store/exit/source validation. Answer-only
  turns have no proposal. Reject escalation/client-tool/grant requests.
- [ ] Add `test_early_and_shutdown_terminal_identity`, `test_cancel_ack_is_not_terminal`,
  `test_empty_thread_failure_allows_only_explicit_safe_retry`,
  `test_resume_failure_never_replays` and `test_unsupported_host_never_submits`.
  Assert wrong/duplicate/late terminal identity cannot expose review; interrupt
  ack alone cannot preserve continuation; cleanup and no submission are required
  for retry; failed resume never calls thread/start or replays text.
  An explicit safe pre-submission retry retires unused thread/store state before
  creating a fresh attempt; it must not become a fallback from failed resume.
- [ ] Run the selected suites plus `nvim_ai_conversation_lifetime`,
  `nvim_ai_conversation_protocol`, `nvim_ai_conversation_review`. Exercise lost
  responses, generation/cancel timeout, forced exit, state/source tampering,
  model mismatch and stale generation callbacks. Assert no publication.
- [ ] Commit `feat: manage Codex turns through the existing conversation controller`.

### Task 5: Select the Managed Backend in the Existing Editor Flow

**Files:** Modify `lua/ai/init.lua`, `lua/ai/conversation_controller.lua`,
`lua/ai/conversation.lua`, `lua/ai/chat.lua`, `lua/ai/chat_view.lua`,
`lua/draft/health.lua`, `README.md`, `doc/draft.txt`.
Create `tests/ai_chat_codex.lua`; extend `tests/draft_setup.lua`,
`tests/ai_conversation_controller.lua`, `tests/ai_chat_startup.lua`.

**Interfaces:**
- Consumes: Task 4's closed launch configuration and unchanged editor events.
- Produces: `require("draft").setup({chat={backend="codex", model="openai/<id>",
  auth_file="/absolute/path/auth.json", codex="/optional/executable"}})`.
  An explicit OpenCode table uses its existing credential/provider options.
  Reuse current root/selection and python/bwrap launch options.
- Produces: immutable `snapshot.backend` and truthful chat/status/health labels.
  Keep the existing `configuration()` callback and controller factory contracts.

- [ ] Write `test_explicit_chat_configuration_does_not_inherit` and
  `test_passive_chat_and_health_do_not_start_managed_worker` in the new suite:
  assert no OpenCode auth/provider inheritance, no app-server launch, credential
  content read or provider request during setup/open/hide/status/health.
  CLI version diagnostics alone are not a managed launch.
  Assert `app_server_launches == 0`, `auth_reads == 0` and
  `snapshot.backend == "codex"` using the suite's spies.
- [ ] Run `python3 -I -B tests/run.py ai_chat_codex draft_setup ai_conversation_controller ai_chat_startup`;
  expect backend/configuration/label assertions to fail initially.
- [ ] Implement trusted optional chat configuration in existing setup/factory;
  absent config still calls `staged.conversation_options()`. Resolve only the
  selected backend executable; pin/recheck runtime on Send. Carry backend
  through the owner and render labels/startup diagnostics from it. Preserve
  `NvimAIChatModel`, native/staged selection, runtime lease and command names.
  Remove remaining managed-chat OpenCode assumptions, including compact status.
- [ ] Add `test_other_backend_missing_and_stale_owner`: Codex works with no
  OpenCode executable and OpenCode with no Codex; conflicting live ownership
  and callbacks from an old owner cannot switch backend or affect a new chat.
- [ ] Update both usage documents with the complete optional configuration,
  supported version, explicit Send/Cancel/Retry semantics, supported-host gate,
  private auth handling and unchanged native workflow. Say unsupported where
  runtime proof fails; do not advertise unverified account/token refresh.
- [ ] Run the four suites plus `draft_state ai_runtime ai_conversation ai_chat ai_chat_view ai_chat_model ai_chat_recovery`.
  Run `stylua --check lua tests`; expect all selected suites and formatting to pass.
- [ ] Commit `feat: expose managed Codex in the existing chat workflow`.

### Task 6: Prove Review, Publication and Continuity End to End

**Files:** Update `tests/ai_chat_codex.lua`, `tests/nvim_ai_codex_runtime.py`,
`tests/nvim_ai_chat_ui.py`, `tests/README.md` and the runtime validation record.
Reuse `tests/fixtures/ai/render_chat_capture.py`; retain a sanitized UI capture
under `docs/validation/` alongside the evidence.

**Interfaces:**
- Consumes: the production composer/controller/adapter/store and existing
  review, correction and publisher APIs. No test-only publication path.
- Produces: reproducible fake-peer Neovim coverage, pinned real-runtime evidence
  with the synthetic provider, UI capture and implementation PR including this plan.

- [ ] Add `test_codex_review_accept_reject_and_source_drift`: drive real headless
  Neovim commands through compose → Send → frozen diff → Accept/Reject.
  Assert exact project bytes unchanged before approval and after Reject;
  Accept writes only the visited frozen version, while drift blocks publication.
- [ ] Add `test_partial_decisions_manual_correction_and_resume`: accept one
  file, reject another, correct the remaining supported LF bytes locally,
  Freeze, then explicitly revise. Separately verify CRLF/no-final-newline
  corrections are refused without losing the draft or changing disk bytes,
  preserving the existing documented format policy. Assert receipts remain unchanged, old review
  visits cannot approve the new revision, Edit/Freeze sends zero model requests,
  the next request includes correction/decision context, and prior decided
  files do not regain edit authority. Assert byte fidelity after final approval.
  Key assertions: `requests_after_freeze == requests_before_edit`,
  `published_bytes == corrected_bytes` and `old_visit_accepted == false`.
- [ ] Run `python3 -I -B tests/run.py ai_chat_codex`; verify the new assertions
  detect deliberately withheld terminal completion/stale visits. Fix only the
  responsible existing integration boundary if a real regression is found.
- [ ] Move installed-runtime acceptance onto the production controller/turn path
  and run `python3 -I -B tests/run.py --codex /absolute/path/to/codex nvim_ai_codex_runtime`.
  Assert actual isolated edit, matching completion, unchanged source before
  approval, stopped-worker exact-thread resume, cancellation and confinement
  with engine connectivity. The fixture provider override belongs only to the
  test harness; do not add a public unconfined/custom-provider configuration.
- [ ] Capture the Codex chat label and pending diff with the existing TUI helper.
  Inspect the render and record its producing commit/command; exclude secrets.
- [ ] Run `python3 -I -B tests/run.py`, `stylua --check lua tests` and
  `git diff --check`. Require the default OpenCode/native/review regressions to
  pass; record optional-runtime skips separately.
- [ ] Review the whole branch against the spec, fix confirmed findings, rerun
  affected checks and commit `test: verify managed Codex review and continuity`.
- [ ] Push and run the default and optional Codex workflows against that exact
  feature head. Open one implementation PR including the spec/plan, link ISQ-491
  and record check URLs/commit there. Any later change needs checks on the new
  PR head. Do not mark runtime support complete on skipped/failed confinement
  tests; do not merge automatically.

Real-account editing/token refresh remains a separately scoped opt-in acceptance
step using an identified credential source and disposable file. This plan's
runtime tests use synthetic credentials and a local provider, not paid requests.

## Plan Self-Review

Spec coverage: configuration/UI → Task 5; confinement/profile/auth/store → Tasks
1 and 3; wire/identity/deadlines → Tasks 2 and 4; revisions/publication/bytes →
Task 6; compatibility/delivery → Tasks 1 and 6. Each Review Focus item names a
regression above. The same store/worker/turn signatures connect the tasks.
No new publisher, context subsystem, Claude login or dependency framework is needed.
