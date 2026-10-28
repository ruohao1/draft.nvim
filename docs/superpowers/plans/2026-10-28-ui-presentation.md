# UI and Documentation Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use the established native implementation workflow and one independent whole-branch review.

**Goal:** Make chat and frozen review easier to read, and reduce the README to a clear installation and first-edit path.

**Architecture:** Keep presentation in `ai.chat_view` and the existing shared frozen-review renderer. Consume the current owner snapshot and action callbacks without changing runtime or publication ownership. Reorganize documentation around onboarding, task guidance and reference.

**Tech Stack:** Linux, Neovim 0.12+ / LuaJIT, existing Lua and Python test fixtures, private tmux captures, standard theme highlights. No new runtime dependency.

**Spec:** [Presentation design](../specs/2026-10-28-ui-presentation-design.md).

## Global constraints

- Start from `f35a0c3` on `feat/ui-presentation`. Keep these documents with the implementation PR; do not open a planning-only PR.
- Preserve public `NvimAI*` commands, mappings, setup options, split thresholds and default dimensions.
- Preserve literal provider text, passive navigation, drafts, focus, bounded rendering and every approval/source/recovery check.
- Keep the current 2 MiB / 20,000-line transcript and 32 KiB draft limits.
- Use standard Neovim highlight groups. Add no runtime dependencies, Markdown parser, icon font or global editor settings.
- The published `v0.1.0-beta.1` supports OpenCode 1.18.34 / ACP 1. Managed Codex requires development code and Codex 0.163.0 with the matching code-mode host. Recheck these facts if the release changes before execution.
- Keep private issue identifiers out of public docs, commits and PR text. Preserve unrelated untracked files and other worktrees.

## Review focus

1. Long Unicode paths/models and literal `%`: headers remain literal; role, phase and essential controls stay legible. Test in Tasks 1 and 2.
2. Provider text resembling a role, receipt or error: styling never promotes it to trusted metadata. Test in Task 1.
3. ColorScheme changes, narrow panes and `laststatus=3`: core cues survive without changing user settings. Test in Tasks 1 and 2.
4. Cancellation, retained decisions and uncertain publication: shorter copy never implies that work completed or can safely retry. Test in Tasks 1 and 2.
5. A reader installing the tag while viewing main: screenshots and Codex instructions do not imply those features ship in that tag. Check in Task 3.

## File responsibilities

| Files | Responsibility |
| --- | --- |
| `lua/ai/chat_view.lua` | Transcript projection, semantic highlights and compact window chrome. Keep its public view API. |
| `lua/ai/staged_review.lua` | Shared saved/proposed titles and decision/file-position presentation. |
| `lua/ai/conversation_controller.lua` | Only the trusted managed-review controls string supplied to the renderer. |
| `tests/ai_chat_view.lua`, `tests/nvim_ai_chat_ui.py` | Actual buffer/window and keyboard assertions; light/dark captures. |
| `tests/ai_staged_multi.lua`, `tests/ai_staged_refine.lua` | Shared-review compatibility, retained decisions and standalone controls. |
| Existing `tests/fixtures/ai/chat_*ui.lua` | Deterministic visual scenarios; reuse the capture renderer. |
| `README.md`, new `docs/usage.md`, `doc/draft.txt`, `docs/releases/install-upgrade-rollback.md` | Short landing page, task guidance, complete reference and installation links. |
| `docs/images/`, new `docs/validation/2026-10-28-ui-presentation.md`, `tests/README.md`, `CHANGELOG.md` | Actual screenshots, reproducible evidence and user-visible change record. |

## Task 1: Give chat a clear visual hierarchy

**Interfaces:** Keep `require("ai.chat_view").new(options)` and all view methods unchanged. The private `projection(snapshot, notice)` returns `lines, highlights`; each highlight is `{ line = <zero-based row>, group = <standard highlight name> }`. `render()` applies them in the `draft-chat` namespace. Consumers outside this module do not change.

- [x] Add regression cases to `tests/ai_chat_view.lua` before changing rendering:
  - `compact headings`: one model/phase winbar, no duplicate buffer heading; editable paths and first-message hint remain visible.
  - `semantic roles`: inspect extmarks on generated role/progress/review/notice rows. An assistant body containing `You · turn 99` and `accepted.txt · accepted` remains plain body text.
  - `state-specific hints`: cover every row in the design's state table. `gr retry` appears only for a safe failed turn; recovery-required and uncertain states keep their reason and close guidance. After a long reply, the current notice appears at the transcript tail; a reader scrolled upward keeps their viewport.
  - `literal metadata`: use `dir/é%name.lua` and a long model. Evaluate the actual winbar with `nvim_eval_statusline(..., { winid = win, use_winbar = true, maxwidth = width })`; no statusline expression executes.
  - `theme and retention`: switch between bundled dark/light themes after opening; retain readable group links, draft bytes and focus. Repeated bounded renders must clear obsolete marks, preserve UTF-8 and keep marks within existing rows.
- [x] Run `python3 -I -B tests/run.py ai_chat_view`; record failures caused by the missing presentation behavior.
- [x] Update private `projection(snapshot, notice)` and `render()` in `lua/ai/chat_view.lua`. Carry trusted row metadata through existing clipping; never infer it by matching final transcript text. Link roles to standard groups such as `Title` and `Identifier`, secondary metadata to `Comment`, pending notices to `DiagnosticWarn`, and errors to `DiagnosticError`. Keep failure detail within the existing bounded notice path.
- [x] Simplify `open_windows()` and rendered chrome to the design. Keep `next:` explicit, escape all interpolated winbar text and retain normal mappings. Align hint eligibility with `chat:actions()` in `lua/ai/chat.lua`; do not move action ownership into the view.
- [x] Extend existing real-key cases and captures in `tests/nvim_ai_chat_ui.py`, using `chat_ui.lua` and `chat_startup_ui.lua`. Cover idle, populated, startup and failure views at 140×42 and 70×28; switch a populated view to a bundled light theme. Keep existing prompt-count, draft, focus and tiny-editor assertions. Update wording assertions without weakening those invariants.
- [x] Run `python3 -I -B tests/run.py ai_chat_view ai_chat ai_chat_model ai_chat_readonly_context ai_chat_startup ai_chat_recovery nvim_ai_chat_ui`; confirm every selected suite exists before execution and passes. Check touched Lua with `stylua --check`.
- [x] Inspect the actual captures before continuing. Commit the design/plan and tested task as `feat: simplify chat presentation` when implementation is authorized for commit.

## Task 2: Simplify frozen-review titles and controls

**Interfaces:** Preserve `staged_review.open(frozen, captured, options)`, its handle, `options.actions` and the trusted `options.controls` string. `show_file(state, index)` still updates the same two read-only panels and visit state. No new mode flag or presentation module is needed.

- [ ] Add/update cases in `tests/ai_staged_multi.lua` and `tests/ai_staged_refine.lua`: evaluated titles identify Saved/Proposed, file index/total and decision; a literal `%`/Unicode path is not interpreted; retained accepted/rejected context is explicitly retained. Keep assertions for immutable snapshots, counts, file visits and explicit decisions.
- [ ] Extend the managed review cases in `tests/nvim_ai_chat_ui.py`: at 70 columns, both focused panes expose `a accept`, `r reject` and `f chat`; `g?` still opens the existing menu. Repeat with `laststatus=3`, then restore it. Navigation and resize must leave source bytes and submission counts unchanged. Include retained decisions and return-to-chat without reopening the diff.
- [ ] Run `python3 -I -B tests/run.py ai_staged_multi ai_staged_refine nvim_ai_chat_ui`; confirm the new presentation assertions fail before implementation.
- [ ] Shorten `show_file(state, index)` titles in `lua/ai/staged_review.lua`. Put panel role and decision before truncatable path detail, escape interpolated values, and retain full literal metadata in the format string. Keep retained-context wording explicit. Preserve standalone staging counts and its different follow-up controls.
- [ ] Replace only the managed controls copy in `lua/ai/conversation_controller.lua` with the compact primary hint. Keep the same hint in both panes for global-statusline compatibility. Preserve standalone and no-action preview fallbacks; do not edit action routing or writer logic.
- [ ] Run `python3 -I -B tests/run.py ai_staged_shared ai_staged_multi ai_staged_refine ai_conversation_controller ai_chat_auto_review ai_chat_approval ai_chat_correction nvim_ai_chat_ui`. Inspect dark/light diff captures and verify all source/frozen-buffer checks still pass.
- [ ] Commit as `feat: clarify frozen review presentation` when commit is authorized.

## Task 3: Shorten the README and deliver the presentation evidence

**Interfaces:** Keep existing commands/options and use accurate links to `:help draft-*` reference sections. The README links to `docs/usage.md`, existing release guidance, help and tests. It does not reproduce their full contents.

| Current README content | Destination / treatment |
| --- | --- |
| Purpose, requirements, installation | Keep concise in README; retain platform and exact backend/release distinctions. Link upgrade/migration details to `docs/releases/install-upgrade-rollback.md`. |
| OpenCode onboarding | Keep one short first-edit walkthrough, including setup, explicit Send, frozen review and Close. Preserve the Ctrl-S fallback. |
| Managed Codex | Move complete configuration and CLI/auth setup to `docs/usage.md#codex`; retain a clearly marked development link near installation. |
| Full commands, mappings, model selection, context, corrections and layout limits | Link to verified `doc/draft.txt` tags. Move any unique instructions before removing duplicate README text. |
| Standalone staging and native companions | Concise recipes in `docs/usage.md#other-workflows`; keep the native after-write warning beside its commands. |
| State, safety and recovery | `docs/usage.md#safety-and-recovery`; retain a brief README caveat and link. Preserve data-retention, non-atomic publication and uncertain-outcome guidance. |
| Detailed validation history | Existing `tests/README.md` and validation records; repair cross-links rather than duplicate the history. |

- [ ] Write `docs/usage.md` and update the existing installation guide only where content has no current home. Reconcile all removed README sections against the table. Use the help file for command/option reference; do not paste a second full reference into the new guide.
- [ ] Rewrite `README.md` to the design's 120–160-line target. Lead with purpose and a populated chat capture. Include essential chat/review keys, an accessible image description and a linked diff screenshot. Clearly label development visuals and fixture data. Keep MIT licensing and material limitations discoverable. Preserve the existing `requirements`, `install` and `start-with-opencode-chat` heading anchors, which the release guide and beta checklist use; repair any moved links.
- [ ] Update affected wording in `doc/draft.txt`, the capture instructions in `tests/README.md`, and `CHANGELOG.md` using the repository's current changelog format. Add no new command or option.
- [ ] Capture real terminal grids using the existing private tmux harness:

  ```sh
  DRAFT_CHAT_CAPTURE_DIR=/tmp/draft-presentation-captures python3 -I -B tests/nvim_ai_chat_ui.py -q
  python3 -I -B tests/fixtures/ai/render_chat_capture.py /tmp/draft-presentation-captures/conversation-wide.ansi docs/images/presentation-chat-wide.png --columns 140
  python3 -I -B tests/fixtures/ai/render_chat_capture.py /tmp/draft-presentation-captures/conversation-narrow.ansi docs/images/presentation-chat-narrow.png --columns 70
  ```

  Render the pending-review and failure captures produced in Tasks 1–2 with their
  actual column widths and new `presentation-` filenames. Preserve older images
  referenced by historical validation records. Reuse the renderer; do not add Pillow as a plugin runtime
  dependency. Inspect every published image. Record themes, dimensions and fixture
  limits in `docs/validation/2026-10-28-ui-presentation.md`.
- [ ] Check relative Markdown links/anchors and help tags, then read the README in rendered form. Walk through its install/first-edit instructions against the public commands in a clean fixture. Confirm the release pin cannot be mistaken for Codex support. Check `wc -l README.md` and `git diff --check`; length is a target, not permission to delete needed guidance.
- [ ] Run `python3 -I -B tests/run.py` once for the integrated result and `stylua --check lua tests`. Record exact results and skips. Do not make live-provider or production-account claims from fixtures.
- [ ] Obtain one independent whole-branch review of behavior, screenshots and documentation. Resolve material findings with focused checks. Commit the final docs/evidence as `docs: simplify the README and refresh UI examples` when authorized.
- [ ] Prepare one implementation PR containing all three tasks and these planning documents. Report actual validation and limits. Publishing and merging remain separate from this planning request.

## Planning handoff

Implementation is authorized. Checked steps record completed work; the validation
record will report the integrated result.
The existing native execution workflow is suitable because the three tasks share
presentation strings and screenshots. Start with Task 1 and review its wide/narrow
captures before extending the same presentation to frozen review.
