# Durable Codex Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> (the existing Native execution choice) or superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve refreshed Codex credentials across Close without sharing the
CLI or IDE's login session or weakening the command sandbox.

**Architecture:** Add one credential lease to the existing Codex store owner.
Bind its verified file into each temporary conversation home and keep its lock
in the Bubblewrap supervisor until the writer exits. Reuse Codex refresh, the
current worker, controller, chat state machine and frozen review lifecycle.

**Tech Stack:** Linux, Neovim 0.12+, LuaJIT, Python 3 standard library, Bubblewrap,
Codex 0.163.0 and its matching `codex-code-mode-host`. No new runtime service.

**Spec:** [Approved ownership design](../specs/2026-10-29-codex-credential-ownership-design.md).
The user approved the separate-login approach on 2026-10-29. This plan remains
on `feat/codex-credential-ownership`, based on `e7131e4c5084392238a986a54570133e7a161428`.
Implementation is in progress. Keep the design, plan and implementation in one PR.

## Global Constraints

- Pin Codex **0.163.0** and the matching companion; keep existing refusal checks.
- Exactly one of `chat.auth_file` and `chat.auth_store` is allowed for Codex.
  `auth_file` remains copied API-key input. `auth_store` owns saved ChatGPT credentials.
- Require an owned **0700** credential directory and an owned, single-link,
  regular **0600** `auth.json`. Keep the existing **1 MiB** credential limit.
  Implementation choice: bound each user/workspace identifier to **1024 UTF-8 bytes**.
- Preserve the **64 MiB / 4096 entries / depth 8** temporary-store limits and
  all existing protocol, startup, generation and shutdown limits.
- Read credentials only on explicit Send, after checking owned-mode host support
  and acquiring an exclusive lease. Never launch login, copy another session,
  export secrets in environment variables, or restore an obsolete token seed.
- Owned mode requires `--bind-fd` and `--sync-fd`. Keep both sandbox layers,
  PID isolation, the default Bubblewrap init process and `--die-with-parent`.
- Close removes conversation data and retains credentials. Idle conversations
  and frozen reviews hold no credential lease. No automatic prompt replay.
- Keep OpenCode, API-key source preservation, legacy terminal Codex, public
  command names and the existing review/publication authority unchanged.
- No real credential reads, live refreshes or live model calls in these tasks.
  Live acceptance remains a separately authorized trial after synthetic acceptance.

## Review Focus

1. Contention during a later turn or review revision must preserve the exact
   thread, draft and prior review authority; only explicit retry can proceed — Task 3.
2. Controller death must not release the lease before the last writer exits;
   closing a duplicate descriptor must not unlock the supervisor — Task 2.
3. A different user in the same workspace, malformed identity claims, or a
   legitimate token refresh must not be confused with each other — Tasks 1 and 3.
4. Valid JSON after forced shutdown or a sync failure must not authorize a
   frozen proposal or silently restore an older token — Tasks 2 and 3.
5. Unsupported Bubblewrap, passive UI and backend switches must not read
   credentials, launch a provider or accept another backend's options — Tasks 2 and 3.

## File Responsibilities

| Files | Responsibility |
| --- | --- |
| New `scripts/nvim-ai-codex-auth.py` | Credential validation, account identity, private descriptors and exclusive lease. |
| `scripts/nvim-ai-codex-store.py` | Couple the lease to the existing worker owner; keep persistent auth out of temporary cleanup. |
| `scripts/nvim-ai-codex-runtime.py`, `scripts/nvim-ai-acp-worker.py` | Capability refusal, descriptor-backed mount, supervisor lease and restricted descriptor inheritance. |
| `scripts/nvim-ai-codex-turn.py`, `scripts/nvim-ai-conversation.py` | Explicit acquisition, bounded diagnostics, retry evidence and final cleanup. |
| `lua/ai/conversation_controller.lua`, `lua/ai/conversation.lua` | Configuration forwarding and fixed, secret-free recovery messages. |
| New `tests/nvim_ai_codex_auth.py`, `tests/nvim_ai_codex_auth_runtime.py` | Offline ownership cases and opt-in pinned-runtime refresh acceptance. |
| New `tests/fixtures/ai/codex_auth.py`; existing Codex/chat fixtures | Synthetic identity/token generation, rotating authority and observable lifecycle cases. |
| Existing store/profile/turn/worker/controller/chat tests | Regression coverage at existing seams; preserve OpenCode behavior. |
| `.github/workflows/linux-tests.yml`, `tests/README.md` | Verified Bubblewrap build and explicit runtime-audit selection. |
| `README.md`, `docs/usage.md`, `doc/draft.txt`, `CHANGELOG.md` | Setup, migration, Close behavior, requirements and recovery. |

Run tasks in order. Task 2 proves the mount and lease before Task 3 exposes the
new configuration. If supervisor lifetime or nested command isolation cannot
be proved, stop that dependent work and report the failed contract. Do not
substitute pathname binding, source copy-back or relaxed sandbox rules.

### Task 1: Add the bounded credential owner

**Files:** Create `scripts/nvim-ai-codex-auth.py`, `tests/nvim_ai_codex_auth.py`
and `tests/fixtures/ai/codex_auth.py`. Modify `scripts/nvim-ai-codex-store.py`
only to reuse the moved validator. Keep current import behavior until Task 3.

**Interfaces:**

- Move `_auth(raw)` into `validate(raw: bytes) -> dict` in the new auth helper.
  Preserve its accepted forms, rejected fields and errors; return the validated
  object for the trusted Python caller. No compatibility wrapper is needed.
- `chatgpt_owner(value: dict) -> tuple[str, str]` returns `(user_id, workspace_id)`.
  Use `tokens.account_id` and the ID token's `https://api.openai.com/auth` claim:
  prefer `chatgpt_user_id`, then `user_id` when the former is absent or null.
  Reject a missing, blank, malformed, oversized or control-bearing identity.
  Decode with strict standard-library base64 and `protocol.decode_json` bounds.
- `Lease(directory: str, expected_owner: tuple[str, str] | None = None)` acquires
  a nonblocking exclusive lock on `.draft.lock`, then opens and validates auth.
  It exposes `auth_fd`, `lock_fd` and `owner`. Both descriptors are close-on-exec.
- `Lease.check() -> None` verifies current path/descriptor identity and metadata,
  allowing bounded content changes while a worker writes. `Lease.settle() -> None`
  validates stable credentials and owner, then synchronizes the file after exit.
  `Lease.close() -> None` is idempotent descriptor closure, without `LOCK_UN`,
  unlink, truncation, source repair or token restoration.
- Auth failures carry only a fixed reason: `credentials`, `auth_busy`,
  `auth_identity` or `auth_persistence`. Never include OS errors or parsed values.
- Fixture `bundle(generation=0, *, user_id="fixture-user",
  workspace_id="fixture-workspace") -> dict` creates synthetic saved credentials.
  It is deterministic within a test run; capture one fixture clock and place
  token expiry beyond the proactive refresh window. Tests write bundles beneath
  their private temporary directory with mode 0600.

- [x] **1. Add failing ownership tests.** Set up `self.directory`, `self.path`
  and `self.original` using `bundle(0)`. Include these assertions:

  ```python
  def test_close_preserves_credentials(self):
      lease = auth.Lease(str(self.directory))
      self.assertEqual(lease.owner, ("fixture-user", "fixture-workspace"))
      lease.close()
      lease.close()
      self.assertTrue(self.path.read_bytes() == self.original, "Auth changed on close")

  def test_refresh_preserves_owner(self):
      lease = auth.Lease(str(self.directory))
      self.path.write_text(json.dumps(bundle(1)))
      lease.check()
      lease.settle()
      lease.close()
      self.assertTrue(json.loads(self.path.read_bytes()) == bundle(1), "Refresh lost")
  ```

  Add `test_other_process_is_busy_before_auth_read`, using a second process and
  a read sentinel, not a second lock object in the same process. Add table cases
  for user-only/workspace-only changes, missing identity, the fallback claim,
  duplicate JSON keys, invalid base64, depth/token budgets and the exact size
  limits. Reuse secure-path test patterns for symlinks, hard links, FIFO,
  directory replacement, foreign ownership and modes 0644/0666.

- [x] **2. Run `python3 -I -B tests/run.py nvim_ai_codex_auth`.** Confirm failure
  names the missing helper or new behavior, rather than a fixture/import error.

- [x] **3. Implement the interfaces.** Reuse `review.open_parent`, its pinned
  descriptor verification and `_read_fd`; reuse `protocol.decode_json`.
  Open untrusted entries without following links or blocking on special files.
  Validate before and after lock/read. Never create a credential directory or
  auth file. Create only the private lease file if missing; never replace it.
  On any partial-construction error, close every acquired descriptor.

- [x] **4. Run `python3 -I -B tests/run.py nvim_ai_codex_auth nvim_ai_codex_profile
  nvim_ai_codex_store`.** All selected suites pass. Existing copied ChatGPT/API-key
  tests still pass at this step. Check partial-construction and repeated-close
  paths for descriptor leaks.

- [x] **5. Commit this tested unit:** `feat: add private Codex credential leases`.

### Task 2: Bind credentials and preserve the lease through sandbox exit

**Files:** Modify `scripts/nvim-ai-acp-worker.py`, `scripts/nvim-ai-codex-store.py`,
`scripts/nvim-ai-codex-runtime.py`, `tests/nvim_ai_acp_worker.py`,
`tests/nvim_ai_codex_store.py`, `tests/nvim_ai_codex_profile.py`,
`tests/fixtures/ai/conversation_codex.py`, `.github/workflows/linux-tests.yml`
and `tests/README.md`. Extend `tests/nvim_ai_codex_auth.py` for process lifetime.

**Interfaces:**

- Add keyword-only `pass_fds: tuple[int, ...] = ()` to `Worker.__init__`.
  It borrows valid, unique descriptors above 2 for `Popen`; it does not close
  caller-owned descriptors. Preserve default inheritance and all current limits.
- Extend `Store.initialize(auth_file=None, *, auth_store=None) -> None` with
  exactly-one validation. Owned mode records its directory and creates only an
  empty 0600 auth mount placeholder beside the current temporary files.
- `Store.acquire_auth() -> None` acquires a fresh Task 1 lease in owned mode;
  API-key mode is a no-op. The first lease records the owner tuple. Later leases
  must match it. `Store.auth_fds` is `()` or `(auth_fd, lock_fd)`.
- `Store.check/start/stop/close` remain the worker authority. `check` also guards
  the lease. `start` passes only `auth_fds` and forbids caller overrides.
  `stop` settles auth after proven exit and closes the lease on every path.
  Unknown exit closes only this process's descriptors and keeps continuation
  and temporary cleanup refused. `close` never deletes persistent auth or locks.
  Retain a bounded `Store.auth_diagnostic` for the turn adapter on auth failures;
  clear it when starting a new acquisition attempt.
- Add `runtime.require_owned_auth(bwrap: str) -> None`: a bounded, sanitized
  `--help` probe requiring both flags, with no credential access. Cap output at
  64 KiB and time at 5 seconds. Missing flags, timeout or nonzero exit refuse.
- Keep `runtime.sandbox(config, task, store) -> (argv, env)`. In owned mode,
  require an acquired lease and add `--bind-fd` for auth and `--sync-fd` for the
  lock. Preserve the existing auth deny mask and generated environment.

- [x] **1. Add failing bind and supervisor tests.** Assert the generated argv
  mounts only the auth descriptor, never its host directory, and carries only
  the two required descriptors. A fake engine reports booleans for whether
  either inherited descriptor matches the original file identity; it must see
  neither. Descriptor-number reuse alone must not count as a leak.

  ```python
  def test_owned_mount_is_not_a_token_copy(self):
      self.store.initialize(auth_store=str(self.directory))
      self.store.acquire_auth()
      argv, env = self.sandbox()
      self.assertIn("--bind-fd", argv)
      self.assertIn("--sync-fd", argv)
      self.assertEqual((self.store.path / "auth.json").read_bytes(), b"")
      self.assertNotIn(str(self.directory), argv)
      self.assertNotIn("OPENAI_API_KEY", env)
  ```

  Add synchronized subprocess tests for normal exit, TERM/KILL, owner death
  during startup and during a held turn, and failed spawn. A competing writer
  must not acquire the lock while the sandbox writer is still alive. Use pipe
  handshakes and bounded deadlines, not sleeps as proof. Probe a synthetic
  sentinel after exit to prove no descendant remains able to write.

- [x] **2. Run the affected tests and confirm the new contract fails.** Use
  `python3 -I -B tests/run.py nvim_ai_codex_auth nvim_ai_codex_profile
  nvim_ai_codex_store nvim_ai_acp_worker`. Keep existing host refusal checks.

- [x] **3. Implement descriptor handoff, store coupling and CI support.** On
  `Popen` failure, release acquired credentials without changing them. On proven
  exit, attempt stable validation and sync even if the turn failed; a valid file
  does not turn a forced exit into successful review evidence. Always release
  the local lease after settlement, including validation or sync errors.

  CI must build Bubblewrap **0.11.1** from the [official release][bwrap-release].
  Verify `bubblewrap-0.11.1.tar.xz` against:

  ```text
  c1b7455a1283b1295879a46d5f001dfd088c0bb0f238abb5e128b3583a246f71
  ```

  Add `meson`, `ninja-build`, `libcap-dev` and `libselinux1-dev` to build tools.
  Use `meson setup build --prefix=/usr -Dman=disabled -Dtests=false
  -Dbash_completion=disabled -Dzsh_completion=disabled`, then
  `meson compile -C build`. Install only the built `bwrap` as root-owned mode
  0755 at `/usr/bin/bwrap`, preserving the existing executable-specific AppArmor
  profile and namespace verification. Do not disable host restrictions globally.

- [x] **4. Run the same four suites.** Require successful lease lifetime and
  descriptor-isolation tests. Test an older-help fixture that lacks `--bind-fd`:
  owned mode refuses before credential reads, while API-key mode still works.
  Inject a sync error and auth corruption after worker exit: both preserve auth
  and refuse reuse. No test should read token bytes during an active rewrite.

- [x] **5. Commit:** `feat: retain Codex credentials through sandbox exit`.

### Task 3: Integrate Send, Close and actionable recovery

**Files:** Modify `scripts/nvim-ai-conversation.py`, `scripts/nvim-ai-codex-turn.py`,
`scripts/nvim-ai-codex-store.py`, `lua/ai/conversation_controller.lua`,
`lua/ai/conversation.lua`, `tests/nvim_ai_conversation_controller.py`,
`tests/nvim_ai_codex_turn.py`, `tests/nvim_ai_codex_profile.py`,
`tests/ai_conversation.lua`, `tests/ai_chat_codex.lua`,
`tests/fixtures/ai/chat_approval.lua`, `tests/fixtures/ai/conversation_codex.py`,
`README.md`, `docs/usage.md`, `doc/draft.txt`, `CHANGELOG.md`, and the affected
credential paragraphs in `docs/superpowers/specs/2026-10-19-managed-codex-design.md`.

**Interfaces:**

- Lua and Python configuration accept one absolute `auth_file` or `auth_store`
  for Codex. Reject both, neither, invalid paths and `auth_store` for OpenCode.
  Forward only the path; preserve complete explicit-chat configuration semantics.
- Before reading owned credentials, `Turn.start` sets `diagnostic="auth_support"`, calls
  `runtime.require_owned_auth`, initializes temporary state if needed, then calls
  `Store.acquire_auth`. Keep the existing startup-stage keys. The returned mount
  uses the same lease until shutdown.
- Copied import now requires an API key. Saved ChatGPT input yields `auth_migrate`
  before starting a worker, with the source unchanged.
- Keep the existing event envelope. Add Codex-only diagnostic keys `auth_support`,
  `auth_busy`, `auth_identity`, `auth_persistence` and `auth_migrate`. Validate
  against the selected backend's `diagnostics` map, not the current global map.
  Messages explain retry, migration or dedicated-login recovery without printing
  file paths, identity claims, raw exceptions or tokens.
- A pre-launch `auth_busy` failure on a resumed conversation may set
  `store_valid=true` only after the unchanged store is checked and the new staging
  workspace is retired. Preserve the existing session. The first-turn path can
  retire its empty store as today. Revisions use the existing positive prior-review
  restoration path. Other failures keep their current recovery requirements.

- [ ] **1. Add failing configuration and user-flow cases.** Exercise both the
  Python controller and the real Neovim/controller/fixture pipeline:

  ```lua
  -- owned_chat_is_passive_until_send
  assert(auth_reads == 0 and launches == 0)
  -- busy_resume_keeps_draft_and_thread (after another process takes the lease)
  assert(f.snapshot().retry_safe and not f.snapshot().recovery_required)
  assert(f.text("draft-chat-input") == "PRIVATE_UNSENT")
  assert(requests("turn/start") == previous_requests)
  ```

  After releasing the other process, explicit Retry must resume the same thread
  once. Repeat with a pending review revision: the previous round remains
  actionable only after existing restoration checks. Cover Close before first
  Send, hidden chat, passive health, invalid/mixed configuration, the other CLI
  missing, stale backend callbacks and unknown/private diagnostic values.
  Replace the saved-ChatGPT-copy acceptance test with migration refusal.

- [ ] **2. Run `python3 -I -B tests/run.py nvim_ai_conversation_controller
  nvim_ai_codex_turn nvim_ai_codex_profile ai_conversation ai_chat_codex` and
  confirm the new cases fail for the intended behavior.

- [ ] **3. Implement the config and lifecycle changes.** Preserve first-turn
  cleanup, acknowledged Cancel, failed startup and forced-exit proof requirements.
  Auth settlement must precede exposing a frozen proposal. Close and early
  cleanup remove the empty placeholder, databases and transcripts only.
  A changed user/workspace never reaches `thread/resume` or `turn/start`.

  Document creation of a fresh private dedicated `CODEX_HOME`, file credential
  storage, login and logout through Codex while all Draft workers are stopped.
  Verify command syntax with isolated `--help` calls; do not execute login.
  State that copying another client's tokens is not a separate login, Close
  retains credentials, and a crash can require reauthentication. Keep the README
  brief and put migration/recovery detail in `docs/usage.md` and `doc/draft.txt`.
  Add one Unreleased changelog entry covering the compatibility change.

- [ ] **4. Run the five affected suites plus `draft_setup`, `draft_state`,
  `ai_runtime` and `ai_chat_startup`.** Require unchanged project bytes, no
  automatic replay, fixed recovery messages, retained API-key sources and
  working OpenCode. Check forced exit and sync failure cannot publish review.

- [ ] **5. Commit:** `feat: use dedicated Codex logins in managed chat`.

### Task 4: Prove persistence and confinement with the pinned runtime

**Files:** Create `tests/nvim_ai_codex_auth_runtime.py`. Extend
`tests/fixtures/ai/codex_auth.py` and, only for shared test routing,
`tests/fixtures/ai/codex_runtime_controller.py`. Modify the runtime-audit command
in `.github/workflows/linux-tests.yml` and its instructions in `tests/README.md`.
Reuse `tests/fixtures/ai/codex_responses.py` response builders unchanged.

**Interfaces:** Extend the fixture with `Authority()` as a context manager. It
exposes `url`, `accepted_generations`, `rejected_count`, `errors` and
`enqueue(events) -> None`. It accepts only the current synthetic refresh token,
rotates it once per successful request, validates model-request authorization,
and never puts credential values in assertion messages or recorded receipts.

Use the existing `tests/run.py --codex ABSOLUTE_PATH` opt-in and
`NVIM_AI_REAL_CODEX` handoff. The new suite skips only when no explicit Codex
path was supplied. An explicit audit must fail on wrong version, missing host
capability, absent companion or failed confinement; it must not skip these cases.

- [ ] **1. Add the rotating-authority and pinned-runtime acceptance test.** In
  test code only, redirect `chatgpt_base_url`, `openai_base_url` and
  `CODEX_REFRESH_TOKEN_URL_OVERRIDE` to loopback. Reuse the recorded probe's
  controlled refresh technique; production gains no endpoint override.

  ```python
  def test_refreshed_login_survives_close_and_new_conversation(self):
      # Start through production Store/runtime; refresh with includeToken=False.
      self.assertEqual(authority.accepted_generations, [0])
      self.assertTrue(current_auth["tokens"] == bundle(1)["tokens"], "Refresh mismatch")
      # Close, then construct a new conversation using the same auth directory.
      self.assertFalse(old_store.root.exists())
      self.assertTrue(auth_path.exists())
      # The second real worker must load and refresh generation 1.
      self.assertEqual(authority.accepted_generations, [0, 1])
      self.assertEqual(authority.rejected_count, 0)
  ```

  Compare timestamps and replacement values inside the trusted test only.
  Do not infer refresh from RPC success or by backdating `last_refresh` alone.
  Test Close/new conversation and stopped-worker resume as distinct cases.

- [ ] **2. Run the new explicit suite before accepting its assertions.** Use
  `python3 -I -B tests/run.py --codex /absolute/path/to/codex
  nvim_ai_codex_auth_runtime`. Record failures accurately and correct fixture
  routing against the pinned source; do not broaden allowed network requests.

- [ ] **3. Add real nested-command denial checks before and after refresh.**
  Exercise direct auth access, a workspace symlink, proc-root aliases and
  descriptor aliases with both reads and non-destructive write-open attempts.
  Require permission denial or confirmed absence of an alias; never accept an
  empty successful read as proof. A model-issued command must execute through
  code mode, fail to access credentials, and return only the expected sentinel.
  Verify the provider history contains no synthetic token. Recheck outer-parent
  directory/lease absence and unchanged real project files.

- [ ] **4. Run `python3 -I -B tests/run.py --codex /absolute/path/to/codex
  nvim_ai_codex_runtime nvim_ai_codex_auth_runtime`.** Both suites pass with zero
  skips on the supported host. Wire both names into the existing optional CI
  audit. Keep default provider-free tests independent of installed Codex.

- [ ] **5. Commit:** `test: verify durable Codex refresh and credential isolation`.

### Task 5: Verify the complete change and prepare one implementation PR

**Files:** Add `docs/validation/2026-10-29-codex-credential-ownership.md` with the
actual execution date and tested revision. Update this plan's checkboxes only
from completed evidence. Keep historical refresh artifacts unchanged.

**Interfaces:** No new runtime interfaces. The handoff names the tested commit,
the commands/results, host capabilities, independent findings and live limits.

- [ ] **1. Run the full provider-free suite:** `python3 -I -B tests/run.py`.
  Run `stylua --check lua tests` and `git diff --check`. Every required check
  passes; report optional runtime skips separately from tested behavior.
  If the agent sandbox remaps trusted executable ownership or denies namespaces,
  use the supported host execution path. Never weaken the executable checks.

- [ ] **2. Run the two explicit runtime suites once against the final changes.**
  Repeat only when a later fix affects the checked behavior. Record the pinned
  CLI/companion, Bubblewrap version and zero-skip results. Document limits:
  cooperative local locking, dedicated login required, no crash-atomic refresh,
  and no live-service validation.

- [ ] **3. Obtain one independent whole-branch review of a fixed revision.**
  Ask it to check the five Review Focus cases, descriptor lifetime, authentication
  boundaries, compatibility and the actual affected callers. Resolve material
  findings and run checks affected by each fix. No per-task agent fan-out is needed
  for the preserved Native execution method.

- [ ] **4. Commit the validation record:** `docs: record Codex credential acceptance`.
  Prepare one implementation PR containing the approved design, this plan, code,
  regression tests and migration docs. Do not create a planning-only PR or claim
  merge/release completion. Keep live-account acceptance as the separate next gate.

## Plan Self-Review

The task map covers configuration, migration, source ownership, Close, Cancel,
interrupted work, account continuity, concurrent editors, host support and command
isolation. The five Review Focus cases each have an owning regression step.
Task 2 supplies every store/runtime/worker interface Task 3 consumes. Task 4
reuses those production paths and the runner's existing explicit opt-in.

One lifecycle detail was resolved during planning: `Turn.fail()` currently treats
a worker-free failure after a prior session as unproven reuse. Task 3 adds only
the positively checked pre-launch contention case. It does not relax failed
workers, unknown exits or revision restoration evidence.

This plan was checked against current code and the design. No implementation,
runtime experiments, product tests or live-account checks were run while writing it.

[bwrap-release]: https://github.com/containers/bubblewrap/releases/tag/v0.11.1
