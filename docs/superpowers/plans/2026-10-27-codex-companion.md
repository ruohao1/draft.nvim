# Codex companion implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox syntax.

**Goal:** Let managed Codex execute code-mode tools and reach frozen review.
**Architecture:** Validate the sibling companion with the existing executable checks.
Mount that single file read-only. Exercise the model-visible code-mode path in
the existing installed-runtime audit.
**Tech Stack:** Python standard library, Lua, Bubblewrap, Codex 0.163.0.
**Spec:** `docs/superpowers/specs/2026-10-27-codex-companion-design.md`

## Global constraints

- Preserve both sandbox layers and all private-state deny masks.
- Keep Codex pinned to 0.163.0; require its matching native companion.
- No PATH fallback, new configuration field, package-directory mount or live prompt.
- Keep the plan with the implementation; preserve unrelated workspace files.

## Review focus

- A missing, writable, non-executable or symlinked companion fails before submission.
- Discovery uses the configured native binary's directory, including spaces/Unicode.
- The mount is read-only and cannot expose adjacent package/private files.
- An answer-only fixture response cannot make a failed tool look successful.
- Code-mode lifecycle events must preserve stopped-worker review and resume fences.

## Task 1: Mount the validated companion and cover refusals

**Files:** `scripts/nvim-ai-codex-runtime.py`, `lua/ai/conversation.lua`,
`tests/nvim_ai_codex_profile.py`, `tests/nvim_ai_codex_turn.py`,
`tests/nvim_ai_codex_store.py`, `tests/nvim_ai_conversation_controller.py`,
`tests/fixtures/ai/chat_approval.lua`,
`tests/ai_chat_codex.lua`.
**Interfaces:** Keep `sandbox(config, task, store) -> (argv, env)` unchanged.
No new public option.

- [x] Add mount/refusal regression tests and a missing-companion editor startup case.
- [x] Run the new profile assertions against old production code and observe failure.
- [x] Validate both native executables before creating the runtime filesystem; add one bind.
- [x] Add the companion to fake installation fixtures and the fixed launch diagnostic.
- [x] Run focused profile, turn, controller and editor suites.

## Task 2: Exercise code mode and deliver the supported installation

**Files:** `tests/fixtures/ai/codex_responses.py`, `tests/nvim_ai_codex_runtime.py`,
`.github/workflows/linux-tests.yml`, `tests/README.md`, `README.md`,
`doc/draft.txt`, `CHANGELOG.md`, a validation record.
**Interfaces:** Keep `command(script, call_id)`; emit custom `exec` instead of a
direct function call. Existing controller fixture stays on the production launcher.

- [x] Route scripted commands through custom exec and require positive nested output.
- [x] Run the installed audit against the old launcher to prove the new path fails.
- [x] Use the new launcher to verify confinement, frozen review and exact-thread resume.
- [x] Extract the matching CLI/host pair from the checksum-pinned 0.163.0 package in CI.
- [x] Document the sibling installation, pre-submission refusal and verified limits.
- [x] Run the full default suite, formatting/diff checks and independent branch review.
- [x] Prepare the implementation, tests, plan and documentation for one PR.
