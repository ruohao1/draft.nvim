# Standalone Draft Extraction Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan
> in the separate Draft repository. Steps use checkboxes for tracking.

**Goal:** Publish an installable, documented, and Linux-validated Draft plugin.

**Architecture:** Keep the companion internals behind a small `draft` facade.
Change integration defaults and storage namespaces without rewriting review,
sandbox, or conversation ownership. Use the existing real-process fixtures.

**Tech Stack:** Neovim Lua/LuaJIT, Python standard library, Linux Bubblewrap,
optional tmux, Git.

**Spec:** `docs/superpowers/specs/2026-09-19-standalone-extraction-design.md`

## Global Constraints

- The original source and installed editor configuration remain unchanged.
- Linux is the validation target.
- Require Neovim 0.12+; setup refuses earlier releases before registration.
- Global mappings are off by default.
- Persistent conversations, the production conversation controller, its editor UI,
  and a Rust migration are outside this milestone.
- Ownership, canonical-path, permission, sandbox, and process-lifecycle checks
  remain intact.
- Existing session, credential, baseline, and compatibility state is never
  automatically adopted from another installation.

## Review Focus

- An installation path containing spaces or an unrelated cwd still selects its own helpers.
- Saving staged preferences after setup does not add unwanted global mappings.
- Existing legacy state and tmux panes cannot be silently adopted as Draft state.
- Calling ACP receive/poll before a request fails with a protocol error, not an attribute error.
- Provider-free tests must not inherit live tmux/editor handles or provider credentials.

### Task 1: Selective copy and relocated baseline

**Files:** `lua/ai/**/*.lua`, `lua/nvim-ai/health.lua`, `scripts/nvim-ai*.py`,
`tests/ai*.lua`, `tests/nvim_ai*.py`, `tests/nvim-ai*.sh`,
`tests/fixtures/ai/*.{py,lua}`, new `tests/run.py`.

**Interfaces:** Retain existing Lua module names and helper filenames; expose
`python3 -I -B tests/run.py [suite ...]` as the provider-free test entry point.

- [x] Hash and copy the explicit file allowlist from disk; reject symlinks and
  preserve modes. Record the manifest outside the public tree.
- [x] Run existing tests in the copied tree with a disposable HOME/XDG environment,
  `umask 077`, `NVIM_LOG_FILE=/dev/null`, and no TMUX/NVIM handles or opt-in flags.
  Python suites run as `python3 -I -B tests/nvim_ai_NAME.py -q`; Lua suites as
  `nvim --clean --headless -u NONE -i NONE --cmd 'lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)' -l tests/ai_NAME.lua`.
  Expected: characterize existing failures separately from relocation failures.
- [x] Derive test roots from each test's own file path in conversation-driver,
  conversation-editor, and review tests. Remove personal startup/statusline
  assertions from `tests/ai_status.lua`, retaining portable behavior assertions.
- [x] Add the runner with explicit suite discovery, per-suite timeouts and logs,
  private scratch directories, and isolated child environments. Exclude the
  interactive manual transport script and optional installed-provider probes.
  Run `python3 -I -B tests/run.py`; inspect every failure and skipped suite.

### Task 2: Portable setup, health, state and transport

**Files:** new `lua/draft/init.lua`, `lua/draft/health.lua`, `tests/draft_setup.lua`;
existing init, staged, status, state, staged_settings, opencode_cache, companion,
tmux transport, health alias and affected tests.

**Interfaces:** `require("draft").setup({keymaps = false, tmux_project_pairs = false})`
returns the existing runtime; `require("draft").compact()` returns status text.

- [x] Add setup tests using real Neovim commands/mappings and isolated directories:
  ```lua
  local draft = require("draft")
  local runtime = draft.setup()
  assert(vim.fn.exists(":NvimAIStage") == 2)
  assert(vim.fn.maparg("<leader>ae", "n") == "")
  assert(draft.setup() == runtime)
  ```
  Cover all native/staged mappings, explicit opt-in, preference reconfiguration,
  passive setup, status redraw and state separation. Add a tmux test with stale
  project-pair metadata that still opens in the current window by default.
- [x] Run those tests before implementation; expect missing facade and old-default failures.
- [x] Implement the small facade, propagate one keymap policy to both setup paths,
  replace the personal redraw hook, and use command names in notices.
- [x] Rename state/cache/runtime and tmux ownership namespaces. Make project-pair
  routing conditional on `tmux_project_pairs = true`; keep its isolated opt-in test.
- [x] Run `python3 -I -B tests/run.py draft_setup ai_status ai_health ai_identity ai_transport ai_project_pairs ai_opencode_runtime_paths ai_runtime ai_staged`.
  Expected: all selected suites pass, with no live state touched.

### Task 3: Preserve and validate ACP polling

**Files:** `scripts/nvim-ai-acp-worker.py`, `tests/nvim_ai_acp_worker.py`.

**Interfaces:** Existing `Worker.begin`, `receive`, `poll`, and `close`; no new
production controller or chat entry point.

- [x] Keep the existing poll/cancel fixture and regression unchanged.
- [x] Add real-worker tests that call `receive("missing")` and `poll("missing")`
  before `begin`, expecting `ProtocolError` and proven worker cleanup. Run
  `python3 -I -B tests/run.py nvim_ai_acp_worker`; expect the reported attribute error.
- [x] Validate liveness and a pending request before reading its deadline, keeping
  polling slices distinct from request deadlines.
- [x] Rerun the worker, conversation-store/lifetime, and editor conversation suites.
  Expected: clean cancellation, bounded failure, and no false successful shutdown.

### Task 4: Documentation, review and publication

**Files:** `README.md`, `doc/draft.txt`, `tests/README.md`, validation notes,
and focused fixes supported by test evidence.

**Interfaces:** lazy.nvim/plain runtime installation, setup options, `:checkhealth draft`,
existing commands and review controls, `python3 -I -B tests/run.py`.

- [x] Write portable installation/setup examples and native/staged walkthroughs.
  Document Linux requirements, the OpenCode version gate, retained sensitive
  artifacts, non-atomic batch writes, and unfinished conversation integration.
- [x] Run the full provider-free suite and a relocated-install smoke check from
  an unrelated cwd with spaces in the install path. Generate/verify help tags.
- [x] Inspect every selected file for provenance, personal paths, private issue
  references, credentials, caches and logs. Compare source hashes again.
- [x] Request one independent whole-change review against the spec and review focus;
  reproduce and fix material findings, then rerun affected/full checks as needed.
- [ ] Commit using the existing public Git identity, publish to the approved public
  repository without force, and verify the remote commit and clean local state.
