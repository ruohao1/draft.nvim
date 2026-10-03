# Linux Beta Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. This session uses inline execution and one final independent review.

**Goal:** Make the integrated Linux/OpenCode workflow repeatable and attach classified acceptance evidence to a known candidate.

**Architecture:** Reuse the production-controller approval, recovery, terminal and installation fixtures. Add one missing installation boundary: the complete core chat journey with no tmux executable available to Neovim. Keep a reusable checklist separate from its dated results; do not add another runner or change production behavior.

**Tech Stack:** Linux, Neovim/LuaJIT, standard-library Python, Git, Bubblewrap, the existing optional tmux TUI harness and OpenCode 1.18.34 / ACP 1.

**Spec:** [ISQ-352](https://linear.app/isqrd/issue/ISQ-352/prepare-repeatable-linux-beta-acceptance), retrieved 2026-10-04. Its acceptance requires discussion, proposal, per-file decisions, partial decisions, revision, model choice, continuation, unsaved-buffer conflicts, startup failure, cancellation, Close, editor exit, restart, fresh installation and core chat without tmux. Record candidate/runtime versions, classify evidence, route failures to owners and scope provider validation before execution.

## Global Constraints

- Start from integrated runtime commit `b9cbc36`; preserve root untracked files and unrelated worktrees.
- Core chat uses review before project writes. Optional native transport has separate after-write checks.
- Keep production confinement, source guards and approval authority unchanged.
- Use disposable HOME/XDG directories, synthetic credentials and test-owned processes.
- Installed-provider scope: OpenCode 1.18.34 artifact audit, four production-controller interop cases and one owner-death case, all using local scripted providers where requests are needed.
- Live-account prompts, publication, remote CI and Linear writes are not part of this execution. Define the live-provider scope for the release handoff without executing it.
- Separate automated fixtures, actual terminal input, installed-binary checks, agent-operated checks and user-operated/live-account acceptance.

## Review Focus

1. Removing `TMUX` alone is not proof that core chat works without tmux. Assert `executable("tmux") == 0` inside the relocated editor.
2. A no-tmux test must still traverse the real controller, confinement and guarded writer; reuse the approval and recovery suites, not a mocked owner.
3. Automatic review and insert-mode deferral changed the old walkthrough. Match the current actual-key TUI cases and exact saved bytes.
4. A passing default suite skips installed providers. Record installed and live-provider evidence separately, including what did not run.
5. Results need an exact tested commit and reproducible commands. Do not label local fixtures as remote CI, real-user acceptance or a published beta.

## Task 1: Deliver the repeatable acceptance package

**Files:**
- Modify: `tests/nvim_ai_install.py`, `tests/README.md`, `README.md`.
- Create: `docs/validation/linux-beta-checklist.md` and `docs/validation/2026-10-04-linux-beta.md`.
- Reuse: `tests/ai_chat_approval.lua`, `tests/ai_chat_recovery.lua`, `tests/nvim_ai_chat_ui.py`, controller/interop/lifetime suites and their fixtures.

**Interfaces:** `InstallTest.run_editor(script)` runs clean headless Neovim against a copied plugin in a path with spaces from an unrelated cwd. `test_relocated_core_chat_without_tmux(self)` supplies a private executable directory without tmux and runs the existing approval/recovery scripts. The checklist consumes existing public commands and fixture prompts; no production API is introduced.

- [x] Add the no-tmux assertion and reuse the two existing journeys. Run the new test before filtering PATH; expect failure because tmux is visible in the normal test environment.
- [x] Build the private PATH from symlinks to required installed commands, excluding tmux. Run `python3 -I -B tests/run.py nvim_ai_install`; expect all three installation tests to pass with real writes, conflicts, recovery and cleanup intact.
- [x] Write the reusable checklist, exact fresh-editor fixture launcher, coverage matrix, current automatic-review actions, failure/restart checks and separately scoped provider gates. Link it from both testing and usage documentation.
- [ ] Commit the test and checklist checkpoint so acceptance runs identify an exact candidate.
- [ ] Run `python3 -I -B tests/run.py`, `stylua --check lua tests`, and `git diff --check`. Expect all suites and checks to pass. Run the scoped installed audit and five lifecycle cases in the documented private environment.
- [ ] Capture the existing real-key TUI suite and inspect its wide/narrow review output. Record exact versions, commit, results, evidence locations, ownership for any failures and remaining release gates in the dated record.
- [ ] Obtain one independent review. Resolve material findings with focused verification, commit the completed evidence, then fast-forward local main and archive logs before removing this worktree.

## Execution notes

The relocated-install baseline passed both existing tests in `run-nrku8sd8`.
The current default suite already passed 63/63 at the runtime handoff; the final
acceptance run will identify the new test/checklist checkpoint explicitly.
