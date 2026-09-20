# Linux Conversational Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Demonstrate the integrated Linux conversational editing workflow and its failure boundaries, with reproducible fixture evidence and an exact worktree-Neovim checklist.

**Architecture:** Reuse the production runtime, confined scripted ACP peer, guarded publisher, private tmux harness, and existing regression suites. Extend three specific coverage gaps; collect the results in one acceptance record. No new public API, recovery engine, or cache scavenger is planned.

**Tech Stack:** Neovim Lua/LuaJIT, Python standard library, Linux process handles, Bubblewrap, private tmux.

**Spec:** [ISQ-237](https://linear.app/isqrd/issue/ISQ-237/validate-conversational-pre-write-workflow-end-to-end-on-linux), together with the existing [UI](../specs/2026-09-20-conversation-ui-design.md), [approval](../specs/2026-09-20-conversation-approval-design.md), and [model](../specs/2026-09-20-conversation-model-design.md) contracts. This is an acceptance plan for those interfaces, not a new architectural design.

**Execution state:** Tasks 1–3 are verified; Task 4 remains. Coverage audited at `f4ec449d2c11532c7ad2a185d26d70b17e4a6cd7`; checked steps below have execution evidence in the task ledger. The existing [main CI](https://github.com/ruohao1/draft.nvim/actions/runs/35513883573) passed 58/58. That is baseline evidence, not a result for these proposed additions. Worktree: `.worktrees/conversation-acceptance`; branch: `test/conversation-linux-acceptance`.

## Global Constraints

- Linux and OpenCode only. macOS and Codex/Claude conversational acceptance are deferred.
- Any provider request, account action, package change, installation, or release operation requires its own authorization.
- Linux; Neovim 0.12+ and LuaJIT; Python standard library; pinned OpenCode 1.18.30.
- Keep two-space Lua indentation, double quotes and 100-column formatting.
- No real provider request, user credential, live editor, personal config or user tmux server is used.
- Run confined fixtures outside the tool sandbox; do not weaken Bubblewrap, helper trust checks or cleanup proof.
- Keep fixture, installed-binary/scripted-provider, and live-account evidence separate. Existing historical interop evidence does not constitute a new live-account run.
- Preserve the root untracked `AGENTS.md` and unrelated `.worktrees/linux-ci`. Do not change ISQ-237's status or acceptance boxes merely because planning is complete.

## Coverage audit

These are source-level mappings, cross-referenced to the passing baseline. New checks are deliberately narrower than a second copy of the entire regression suite.

| ISQ-237 requirement | Existing evidence | Work in this plan |
| --- | --- | --- |
| Discussion, proposals, revisions, partial accept/reject, continued conversation | `ai_chat_approval`: production controller, frozen buffers, real receipts, accepted/rejected/pending context; `nvim_ai_chat_ui.ChatApprovalUITest`; relocated `nvim_ai_install` | Task 1 joins the initial discussion and next-turn model changes into this same production approval journey |
| Eligible model switch and failed/unsupported switches | `ai_chat_model`; `ai_chat_controller`; `nvim_ai_conversation_controller` tests for changed catalog, unconfirmed switch and missing synthetic auth | Task 1 adds real approval-history/model integration; retain existing refusal cases |
| Cancellation, safe retry, late events | `ai_conversation` cancellation/retry/sequence scenarios; `ai_conversation_driver` stale completion and broken-pipe scenarios; controller cooperative/forced cancellation | Task 4 reruns and records the existing cases; no duplicate failure driver |
| Stale approvals, disk changes, unsaved buffers and aliases | `ai_chat_approval`; `ai_conversation_review`; `nvim_ai_staged`, `_decisions`, `_publish`, `_multi`, `_refine` | Task 1 retains retired-key assertions; Task 4 includes these suites and manual refusal observations |
| Process shutdown and immutable review inputs | Controller editor-EOF and controller-death tests; `nvim_ai_conversation_lifetime`; `_store`; publication/frozen-panel tests | Task 2 adds abrupt public-chat editor death; reuse existing owner-death, no-adoption and interrupted-publication proofs |
| Private state cleanup/retention and restart behavior | Store identity/permission/cleanup tests; lifetime fresh-owner refusal; controller retained evidence on death | Tasks 2–4 distinguish orderly EOF cleanup, abrupt controller evidence retention, fresh context, and no token replay |
| Native/pre-write exclusion | `ai_chat_controller`, `ai_chat_approval`, `ai_runtime`, `ai_scope`, `nvim-ai-native` | Task 4 reruns them and adds a manual hidden-chat exclusion step |
| Readiness cache interruption | Existing timeout, untrusted receipt, completed concurrent write and fresh-editor reuse tests | Task 3 adds a deterministic killed-writer orphan test and records the retention decision |
| Versions, environment limits, exact manual checklist | Individual validation records; `tests/README.md`; production `chat_approval_ui.lua` fixture | Task 4 produces one acceptance record with commands, expected bytes, version output and classified evidence |
| Separate real-provider evidence and release/install blockers | Prior controller interop record, explicit opt-in instructions, documented recovery limitations | Task 4 lists live-account testing as unperformed unless separately authorized and gives an explicit release/install decision |

## Approach and decisions

Use the existing suites as the acceptance backbone and add the three gaps above. A new monolithic harness would duplicate process ownership and writer behavior; a documentation-only pass would leave the public editor-kill and interrupted-cache boundaries untested.

For interrupted cache writes, retain a private orphan rather than automatically adopting or deleting it. Readers recognize only the complete `compatibility.json` name. The cache helper bounds each receipt at 65,536 bytes, but repeated interrupted writes have no aggregate retention bound. Document exact-path cleanup after all possible users have stopped; automatic scavenging remains a release/maintenance consideration. This decision avoids deleting a concurrent writer's in-progress file and does not claim leak-free cache cleanup.

Keep restart semantics explicit: normal editor EOF can let the surviving controller stop its worker and remove owned state; killing the controller can retain private evidence. An editor killed by SIGKILL can leave its Lua-owned private launch configuration even when the controller cleans worker/store state. A new editor/owner does not restore history, adopt an old backend store, replay a prompt, or revive an approval token. Existing accepted writes remain on disk; uncertain publication requires inspection, not an assumed rollback.

## Review Focus

1. Switching models after partial decisions must preserve accepted bytes, rejected bytes, receipt context and earlier model labels — Task 1.
2. An old idle frame must not satisfy a later turn's completion assertion — Task 1 uses turn identity plus phase and explicit prompt counts.
3. Killing Neovim while hidden must still let the controller reap the confined worker and remove worker/store state — Task 2; Lua-owned launch configuration survives SIGKILL, and controller death has different retention expectations.
4. A fully written but unrenamed cache receipt from a killed helper must never count as a hit or cause deletion of unrelated state — Task 3.
5. The manual recipe must use the exact worktree and disposable state, report real file contents, and distinguish fixtures from live-provider proof — Task 4.

---

### Task 1: Join model selection to the production approval journey

**Files:**
- Modify: `tests/ai_chat_approval.lua`
- Modify: `tests/nvim_ai_chat_ui.py`
- Reuse: `tests/fixtures/ai/chat_approval.lua`, `tests/fixtures/ai/chat_approval_ui.lua`, `tests/fixtures/ai/conversation_acp.py`
- Existing relocation check: `tests/nvim_ai_install.py`

**Interfaces:** `make(root)` returns the existing fixture with `compose(text)`, `snapshot()`, `phase(name)`, `rendered(text)`, `disk(index)`, `audit`, and `cleanup()`. Snapshots expose `turn_id`, `turns`, `rounds`, `desired_model`, and `phase`. Public commands remain the only UI action entry points; `f.key()` exercises installed mappings. No production interface is produced.

- [x] **Step 1: Add an initial discussion and passive choice to the first existing headless journey.** Add these helpers next to `context()` and `states()`:

  ```lua
  local function method_count(method)
    local total = 0
    for _, event in ipairs(f.audit) do
      if event.method == method then
        total = total + 1
      end
    end
    return total
  end
  local function completed(turn_id, phase)
    assert(vim.wait(12000, function()
      local state = f.snapshot()
      return state.turn_id == turn_id and state.phase == phase
    end, 10), vim.inspect(f.snapshot()))
  end
  ```

  Immediately after the first `assert(#f.audit == 0)`, before `request()`, insert:

  ```lua
  f.compose("Discuss the selected files without editing.")
  vim.cmd("NvimAIChatSend")
  completed(1, "idle")
  assert(method_count("session/prompt") == 1)
  for index = 1, 3 do
    assert(f.disk(index) == "original text")
  end
  f.compose("Propose edits to all selected files.")
  vim.cmd("NvimAIChatModel")
  choose(nil, 2)
  assert(f.snapshot().desired_model == "fixture/second-model")
  assert(f.snapshot().turn_id == 1 and method_count("session/prompt") == 1)
  assert(f.text("draft-chat-input") == "Propose edits to all selected files.")
  ```

  The existing `request()` now produces turn 2. Keep all existing real writer assertions: first accepted, second rejected, third pending; retired mapping inert after revision; accepted content survives revision; pending discussion preserves the active proposal.

- [x] **Step 2: Switch back only after the reviewed revision is resolved.** Before the existing final `f.compose("Discuss the saved results.")`, insert the selection below; replace its loose `f.phase("idle")` with `completed(5, "idle")`:

  ```lua
  local reviewed = vim.deepcopy(f.snapshot().rounds[1])
  vim.cmd("NvimAIChatModel")
  choose(nil, 1)
  assert(f.snapshot().desired_model == "fixture/model")
  assert(method_count("session/prompt") == 4)
  assert(vim.deep_equal(f.snapshot().rounds[1], reviewed))
  ```

  After the final discussion's existing receipt-context assertions, add:

  ```lua
  assert(method_count("session/new") == 1)
  assert(method_count("session/resume") == 4)
  assert(method_count("session/prompt") == 5)
  local expected = {
    "fixture/model", "fixture/second-model", "fixture/second-model",
    "fixture/second-model", "fixture/model",
  }
  for index, model in ipairs(expected) do
    assert(f.snapshot().turns[index].model == model)
  end
  assert(f.snapshot().rounds[1].model == "fixture/second-model")
  assert(f.disk(1) == "proposed edit")
  assert(f.disk(2) == "original text")
  assert(f.disk(3) == "revised edit")
  ```

- [x] **Step 3: Add a real-key integration case inside `ChatApprovalUITest`.** It must use its production fixture, not `ChatUITest`'s in-process event source:

  ```python
  def test_model_switch_after_review_keeps_saved_files_and_session(self):
      self.send("Propose edits to the selected files.")
      self.review()
      self.keys("R")
      self.confirm("Reject remaining 3 file(s)?")
      self.phase("idle")
      self.command("NvimAIChat")
      self.keys("i")
      self.literal("Discuss the rejected edits.")
      self.keys("Escape", "g", "m")
      self.wait(lambda: "Model for next turn (conversation only)" in
                self.tm("capture-pane", "-p", "-t", "draft"), "model picker")
      self.keys("2", "Enter")
      self.wait(lambda: self.evaluate(
          "chat_approval_fixture.snapshot().desired_model") ==
          "fixture/second-model", "local model selection")
      self.assertEqual(self.evaluate("chat_approval_fixture.snapshot().turn_id"), "1")
      self.assertEqual(self.evaluate("vim.api.nvim_get_current_line()"),
                       "Discuss the rejected edits.")
      self.keys("C-s")
      self.wait(lambda: self.evaluate(
          "chat_approval_fixture.snapshot().turn_id == 2 and "
          "chat_approval_fixture.snapshot().phase == 'idle'") == "true",
          "second completed turn")
      for index in (1, 2, 3):
          self.assertEqual(self.evaluate(f"chat_approval_fixture.disk({index})"),
                           "original text")
      audit = json.loads(self.evaluate("vim.json.encode(chat_approval_fixture.audit)"))
      methods = [event.get("method") for event in audit]
      self.assertEqual(methods.count("session/new"), 1)
      self.assertEqual(methods.count("session/resume"), 1)
      self.assertEqual(methods.count("session/prompt"), 2)
      self.wait(lambda: "Assistant · fixture/second-model" in
                self.capture("conversation-acceptance"), "second model label")
      self.assertIn("Assistant · fixture/model", self.capture("conversation-acceptance"))
      self.command("NvimAIChatClose")
      self.phase("closed")
  ```

- [x] **Step 4: Run the affected suites.** These are additional acceptance checks for existing behavior and may pass immediately; do not manufacture a production failure. If a real failure appears, isolate it and use RED/GREEN for the smallest repair.

  ```sh
  python3 -I -B tests/run.py ai_chat_approval nvim_ai_chat_ui nvim_ai_install
  ```

  Expected: 3/3 suites, including the new production TUI case and relocated headless journey. Preserve failure logs and exact turn observations. Commit the reviewed task as `test: cover model changes across conversational approval` during implementation.

### Task 2: Prove abrupt public-editor shutdown

**Files:** Modify `tests/nvim_ai_conversation_controller.py`; reuse `tests/fixtures/ai/chat_production_editor.lua`.

**Interfaces:** Extend test-only `EngineTest.check_editor_eof(self, fixture, *, abrupt=False)`. Its existing process handles identify the controller and confined worker; `worker_paths(controller)` returns `(pid, task, store)`. The fixture waits at `DRAFT_EDITOR_GATE` while hidden and generating.

- [x] **Step 1: Add the new test before extending the helper.** The initial run should fail on the missing `abrupt` parameter, establishing that the new path is actually selected:

  ```python
  def test_public_chat_editor_sigkill_retains_only_private_launch_configuration(self):
      self.check_editor_eof("chat_production_editor.lua", abrupt=True)
  ```

  Run `python3 -I -B tests/run.py nvim_ai_conversation_controller`; retain the named failure.

- [x] **Step 2: Add the keyword parameter, then replace only the gate/return-code section in the existing helper:**

  ```python
  if abrupt:
      editor.kill()
  else:
      gate.touch()
  out, error = editor.communicate(timeout=12)
  self.assertEqual(editor.returncode, -signal.SIGKILL if abrupt else 0, out + error)
  ```

  Keep controller pidfd readable, worker pidfd readable, task/store paths absent, and source bytes exactly `b"original text\n"`. For orderly EOF require the launch path absent. For SIGKILL require only the original unchanged launch.json in its 0700 directory, with mode 0600, same device/inode, current UID and one link; remove that test-owned artifact only after process and identity proof. Keep the existing `finally` cleanup through owned pidfds. Do not replace this with PID-existence polling, global process killing, or deletion before exit proof.

- [x] **Step 3: Verify the distinct restart/retention cases together.**

  ```sh
  python3 -I -B tests/run.py nvim_ai_conversation_controller nvim_ai_conversation_lifetime nvim_ai_conversation_store ai_conversation_driver
  ```

  Expected: all four suites pass. Record the existing `test_controller_death_reaps_descendant_held_pipe_and_retains_unadopted_evidence`, `test_idle_owner_death_does_not_let_a_new_owner_adopt_its_stopped_store`, forced-worker taint, and failed-close proof alongside the new SIGKILL case. These support different outcomes; retained evidence is not a resumable conversation. Commit as `test: verify abrupt conversational editor shutdown`.

### Task 3: Pin the interrupted-cache retention boundary

**Files:** Modify `tests/nvim_ai_opencode_cache.py`. No production cache change is planned.

**Interfaces:** Existing `CompatibilityCacheTest.seed()`, `record()`, `run_editor()` and per-test relocated helper copies. Helper CLI accepts `store` or `lookup` and JSON on stdin; returns `stored` or `hit`. Add the standard-library `signal` import.

- [x] **Step 1: Add a deterministic killed-writer test.** Block only the disposable copied helper after bytes are written but before rename. The marker, not elapsed startup time, proves the kill point:

  ```python
  def test_killed_cache_writer_leaves_private_untrusted_receipt(self):
      self.seed()
      receipt = json.loads(self.record().read_bytes())
      self.record().unlink()
      helper = self.runtime / "scripts/nvim-ai-opencode-cache.py"
      original = helper.read_text()
      marker = self.root / "writer-ready"
      needle = "                os.fsync(fd)\n"
      self.assertEqual(original.count(needle), 1)
      hook = (f"                Path({str(marker)!r}).write_text('ready')\n"
              "                time.sleep(30)\n" + needle)
      helper.write_text(original.replace(needle, hook, 1))
      request = {"directory": str(self.cache), "key": receipt["key"],
                 "report": receipt["report"]}
      child = subprocess.Popen([sys.executable, "-I", "-B", str(helper), "store"],
          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
          env={"LANG": "C.UTF-8"}, umask=0o077)
      try:
          child.stdin.write(json.dumps(request).encode())
          child.stdin.close()
          child.stdin = None
          deadline = time.monotonic() + 5
          while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
              time.sleep(.01)
          self.assertTrue(marker.exists(), "copied helper did not reach the write boundary")
          child.kill()
          out, error = child.communicate(timeout=5)
          self.assertEqual(child.returncode, -signal.SIGKILL, out + error)
      finally:
          if child.poll() is None:
              child.kill()
          child.communicate(timeout=5)
          helper.write_text(original)
      leftovers = list(self.cache.glob(".receipt-*"))
      self.assertEqual(len(leftovers), 1)
      orphan = leftovers[0]
      before = orphan.read_bytes()
      node = orphan.lstat()
      self.assertTrue(stat.S_ISREG(node.st_mode))
      self.assertEqual((stat.S_IMODE(node.st_mode), node.st_uid, node.st_nlink),
                       (0o600, os.getuid(), 1))
      self.assertLessEqual(len(before), 65536)
      orphan_record = json.loads(before)
      for field in ("schema", "key", "report"):
          self.assertEqual(orphan_record[field], receipt[field])
      self.assertEqual(orphan_record["expires_at"] - orphan_record["created_at"], 86400)
      lookup = subprocess.run([sys.executable, "-I", "-B", str(helper), "lookup"],
          input=json.dumps({"directory": str(self.cache), "key": receipt["key"]}).encode(),
          capture_output=True, check=True, timeout=5, env={"LANG": "C.UTF-8"})
      self.assertEqual(json.loads(lookup.stdout), {"hit": False})
      self.seed()
      self.assertEqual(self.run_editor()["starts"], 0)
      self.assertEqual(orphan.read_bytes(), before)
      self.assertEqual(orphan.lstat().st_ino, node.st_ino)
  ```

  The stable-field comparison permits the second store to cross a clock second. The complete orphan must be valid for the explicit lookup key: failure must establish that the filename is untrusted, not merely that its cache fingerprint is stale.

- [x] **Step 2: Run existing cache regression coverage with the new test.**

  ```sh
  python3 -I -B tests/run.py nvim_ai_opencode_cache
  ```

  Expected: default cases pass with installed-binary opt-ins skipped. The existing 250 ms helper deadline test and four completed concurrent publications remain separate. This deterministic kill test can pass on current production code; it verifies a documented limitation, not a promised cleanup fix. Commit as `test: document interrupted cache receipt retention`.

### Task 4: Publish reproducible Linux acceptance evidence

**Files:**
- Create: `docs/validation/2026-09-20-conversation-linux.md`
- Modify: `tests/README.md`, `README.md`, `doc/draft.txt`
- Reuse: `tests/fixtures/ai/chat_approval_ui.lua` and actual terminal capture support
- Discovered repair: `scripts/nvim-ai-conversation-review.py`, `tests/nvim_ai_conversation_review.py`, `tests/ai_chat_approval.lua`

**Interfaces:** The existing registry releases current authority after a validated terminal receipt while preserving context; no new interface is added. The manual launcher uses the existing environment variables `DRAFT_TEST_ROOT`, `DRAFT_CHAT_UI_ROOT`, and `DRAFT_CHAT_UI_SCRIPT`. It loads the same production fixture used by Task 1; no new runtime command or fixture-only product setting is added.

- [x] **Step 0: Repair the terminal-receipt Close failure exposed by the walkthrough.** Two real-journal tests and the public partial-approval/drift journey fail before the fix. The writer has already consumed a terminal failure's authority, but the registry keeps it current and requests a second cancel receipt on Close. Clear `current` after every validated receipt with no pending files, preserving its context and the owner's recovery/cleanup evidence. The existing receipt reader must still prove the consumption marker and terminal journal; a missing marker must retain the current review and refuse ingestion. Run `python3 -I -B tests/run.py nvim_ai_conversation_review ai_chat_approval ai_conversation_review`. Expected: blocked and uncertain receipts close without replay or journal changes; partial accepted bytes and external edits survive; unproven receipt evidence remains refused. No writer, protocol or recovery-reset change is needed.

- [ ] **Step 1: Write the evidence record with four explicitly labeled evidence classes.** Record baseline SHA, final tested SHA, environment/version output, actual command/log paths, per-criterion test names, expected opt-in skips, and unresolved limitations. Use: automated fixtures; automated real terminal keys; hands-on fixture checklist; installed/live-provider evidence. An unperformed class says `not run`; it never inherits a passing status from another class.

  Record versions without invoking an installed agent:

  ```sh
  git rev-parse HEAD
  nvim --version
  python3 --version
  bwrap --version
  tmux -V
  git --version
  rg --version
  uname -srmo
  ```

- [ ] **Step 2: Include this exact disposable manual launcher.** Run it from the intended worktree in a terminal with sufficient size (140 columns × 42 rows is the reference capture). The separate directories are created with a private umask; the plugin's trusted helpers must already have safe permissions.

  ```sh
  DRAFT_ACCEPTANCE_PLUGIN="$(pwd -P)"
  DRAFT_ACCEPTANCE_NVIM="$(command -v nvim)"
  DRAFT_ACCEPTANCE_ROOT="$(mktemp -d /tmp/draft-chat-acceptance.XXXXXX)"
  chmod 700 "$DRAFT_ACCEPTANCE_ROOT"
  for part in home config data state cache run; do
    mkdir -m 700 "$DRAFT_ACCEPTANCE_ROOT/$part"
  done
  printf 'Fixture root: %s\nPlugin checkout: %s\n' "$DRAFT_ACCEPTANCE_ROOT" "$DRAFT_ACCEPTANCE_PLUGIN"
  env -i \
    PATH="$(dirname "$DRAFT_ACCEPTANCE_NVIM"):/usr/bin:/bin" \
    LANG=C.UTF-8 TERM=xterm-256color NVIM_LOG_FILE=/dev/null \
    HOME="$DRAFT_ACCEPTANCE_ROOT/home" \
    XDG_CONFIG_HOME="$DRAFT_ACCEPTANCE_ROOT/config" \
    XDG_DATA_HOME="$DRAFT_ACCEPTANCE_ROOT/data" \
    XDG_STATE_HOME="$DRAFT_ACCEPTANCE_ROOT/state" \
    XDG_CACHE_HOME="$DRAFT_ACCEPTANCE_ROOT/cache" \
    XDG_RUNTIME_DIR="$DRAFT_ACCEPTANCE_ROOT/run" \
    DRAFT_TEST_ROOT="$DRAFT_ACCEPTANCE_PLUGIN" \
    DRAFT_CHAT_UI_ROOT="$DRAFT_ACCEPTANCE_ROOT" \
    DRAFT_CHAT_UI_SCRIPT="$DRAFT_ACCEPTANCE_PLUGIN/tests/fixtures/ai/chat_approval_ui.lua" \
    "$DRAFT_ACCEPTANCE_NVIM" --clean -u NONE -i NONE \
    --cmd 'lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)' \
    -c 'lua dofile(vim.env.DRAFT_CHAT_UI_SCRIPT)'
  ```

  Verify the loaded code with `:lua print(vim.api.nvim_get_runtime_file("lua/draft/init.lua", false)[1])`. It must point into this worktree. `:lua print(chat_approval_fixture.root)` identifies the disposable root. In this fixture, `Discuss` is a deliberate case-sensitive control word; use the messages below exactly.

- [ ] **Step 3: Include and execute the complete fixture checklist.** `i` enters the composer; Ctrl-S explicitly sends; Escape returns to normal mode. Allow each expected state to settle before the next step. Inspect all three actual files under the printed root's `project with spaces` directory. Every content value below is one line with a trailing newline.

  | Action | Expected visible state | Disk: first / second / third |
  | --- | --- | --- |
  | Open fixture; try `:NvimAIChatModel` | `Model choices are available after an explicitly sent, successfully negotiated turn`; no prompt or worker | original text / original text / original text |
  | Send `Discuss the selected files without editing.` | idle, `Assistant · fixture/model`; no proposal | original text / original text / original text |
  | Type `Propose edits to all selected files.`; press Escape then `gm`, select second model | `next: fixture/second-model`; draft retained, no new send | original text / original text / original text |
  | Hide with `q`, reopen with `:NvimAIChat`; Ctrl-S | draft retained before Send; then review, old model label unchanged | original text / original text / original text |
  | Try `:NvimAIChatModel` during review | `Model selection requires an idle conversation; current state: review` | original text / original text / original text |
  | `gd`, choose first file | SAVED SNAPSHOT / FROZEN STAGED PROPOSAL, proposed edit on right | original text / original text / original text |
  | `a`, then `r` on second file | first accepted; second rejected and still visible | proposed edit / original text / original text |
  | `f`, send `Revise the pending edit.` | replacement review; prior accepted/rejected decisions retained | proposed edit / original text / original text |
  | `gd`, choose third, inspect, then `a` | third accepted; idle | proposed edit / original text / revised edit |
  | Return with `:NvimAIChat`, `gm` select first model; send `Discuss the saved results.` | new reply uses fixture/model, earlier replies and receipt labels remain fixed | proposed edit / original text / revised edit |
  | Hide chat; run `:NvimAIStage` | native/staged ownership refusal while chat remains open | proposed edit / original text / revised edit |
  | `:NvimAIChatClose`, then `:NvimAIChatNew` | new empty conversation with default fixture/model; opening is passive | proposed edit / original text / revised edit |

  Add three fresh fixture runs for these exact refusal/rejection checks. Each starts by sending `Propose edits to all selected files.`, then opening the first diff with `gd`:

  - Disk change: run `:lua vim.fn.writefile({"external change"}, chat_approval_fixture.files[1])`, then `:NvimAIChatApprove`. Approval must refuse; first-file bytes stay `external change\n`, and the other two stay `original text\n`.
  - Unsaved buffer: run `:lua local b = vim.fn.bufadd(chat_approval_fixture.files[1]); vim.fn.bufload(b); vim.api.nvim_buf_set_lines(b, 0, -1, false, {"unsaved change"})`, then `:NvimAIChatApprove`. Approval must refuse; all disk files stay original, and `:lua local b = vim.fn.bufadd(chat_approval_fixture.files[1]); print(vim.bo[b].modified, vim.api.nvim_buf_get_lines(b, 0, -1, false)[1])` must print `true` and `unsaved change`.
  - Complete rejection: press `R` and confirm `Reject remaining 3 file(s)?`. Chat becomes idle and all originals remain.

  Record the actual refusal messages. Use the existing automated suites for forced process death, uncertain publication, synthetic-auth failure and late events; do not improvise a kill or credential change in a user's live editor.

  End each fixture run with `:NvimAIChatClose`, wait for `closed`, then `:lua assert(chat_approval_fixture.snapshot().phase == "closed"); chat_approval_fixture.cleanup()` and `:qa!`. Retain the exact printed directory until evidence is recorded and all owned processes are confirmed stopped. Cleanup is limited to that run's identified paths; no directory-family sweep. If a step is not performed, leave it unchecked and state why.

- [ ] **Step 4: Correct stale documentation and explain recovery/retention.** Remove `tests/README.md`'s obsolete claim that the chat UI is unfinished. Link the new acceptance record from the testing guide, README and help. State explicitly that a new editor starts fresh context; controller-death artifacts and accepted writes are not automatically recovered or rolled back. Document cache orphan mode/size, lack of aggregate retention bound, no adoption, and exact-path cleanup only after users of the artifact have stopped. No new end-user recovery command is implied.

- [ ] **Step 5: Run the complete provider-free gate once after the changes.** It includes the required staged, native lifecycle, cache, review and confinement regressions. Capture the command output and installed-provider skip reasons. Do not rerun unchanged green focused suites separately afterward.

  ```sh
  stylua --check lua tests
  git diff --check
  python3 -I -B tests/run.py
  ```

  Expect the existing 58 suite files to pass with additional cases (no new suite file is planned). Report the actual count, never a predetermined success. If confinement is blocked, use an authorized suitable Linux execution context; never change checks to force a pass. No package installation is part of this plan.

- [ ] **Step 6: Record the release/install decision and deliver the reviewed work.** Commit the acceptance record as `docs: record Linux conversational acceptance`. Use the established inline workflow: one fresh whole-branch review, address actionable findings with focused regression evidence, PR, exact-head CI, merge, main CI, then Linear evidence and archive. Announce mutations when performing them; do not silently mark acceptance complete.

  A passing fixture record supports the Linux fixture milestone only. List live-account/provider testing as outstanding, cross-platform/backend acceptance as deferred, and interrupted-cache retention plus crash-recovery limitations explicitly. The next decision is whether to authorize a separate live-provider pilot and then release/install work; neither action is performed by this plan. If any required acceptance remains unmet, retain its unchecked status and a concrete blocker instead of claiming the milestone complete.

## Plan self-review

- All seven ISQ-237 acceptance bullets map to the audit and Tasks 1–4.
- Every new check uses existing production boundaries; test-only hooks operate on owned fixture copies.
- Completion barriers name turn identity, audit messages or owned process handles; the cache kill uses a reached marker.
- The five review-focus conditions each have an owning task.
- Planning does not claim a new test result, human checklist completion, live-provider acceptance or release readiness.
