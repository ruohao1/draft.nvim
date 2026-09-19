# Standalone Draft extraction

Draft packages the existing Neovim AI companion as an independently installable
MIT plugin. This milestone covers portable code, user documentation, isolated
Linux validation, and the first reviewed code publication.

## Interface and layout

Expose `require("draft").setup(options)` and `require("draft").compact()` through
a small facade. Keep the internal `ai` modules and `NvimAI*` commands to avoid a
wide mechanical rewrite of the existing review and lifecycle machinery. Provide
`:checkhealth draft`, with the old health name retained as an alias. Installing
the plugin alone has no side effects; setup registers commands and exit handlers
but does not launch agents, read credentials, or create a session.

The existing sibling `lua/`, `scripts/`, and `tests/` layout becomes the repository
root. Helpers resolve relative to the loaded module, independently of cwd,
runtimepath ordering, and the user's Neovim config directory.

Global mappings are off by default. `setup({ keymaps = true })` enables the
existing native and staged mappings. Buffer-local review controls remain active.
Setup is idempotent; configure global options before the first setup call.
Staged preference reconfiguration must not silently enable global mappings.

Status updates redraw Neovim's statusline with its public API and retain the
existing custom redraw callback; no personal statusline module is required.
Notifications name commands so they remain useful without default mappings.

## Isolation and defaults

Native runtime state uses `$XDG_RUNTIME_DIR/draft.nvim/`, falling back to
`/tmp/draft.nvim-<uid>/`. Native durable state uses
`$XDG_STATE_HOME/draft.nvim/`, falling back to `~/.local/state/draft.nvim/`.
Staging preferences and compatibility caches use `draft.nvim` below Neovim's
state/cache directories. Tmux pane metadata and paste buffers use Draft-specific
names. Existing session, credential, baseline, and compatibility state is never
automatically adopted from another installation.

Native tmux transport uses the current window by default, with no required
personal tmux configuration. The optional legacy project-pair integration is
available only with `tmux_project_pairs = true`. Ownership, canonical-path,
permission, sandbox, and process-lifecycle checks remain intact.

## Behavior and support boundary

Native companions support after-write review. OpenCode staging offers explicit
selected-file approval before writing, including pending-proposal follow-ups.
Persistent conversations, the production conversation controller, its editor UI,
and a Rust migration are outside this milestone. Preserve their existing internal
modules and fixtures, without exposing a chat command or claiming integration.

Linux is the validation target. Require Neovim 0.12+ and refuse earlier releases
before registering commands: native binary hashing fails on Neovim 0.11.6.
Record the exact tested Neovim, Python, tmux,
and Bubblewrap versions; do not claim a broader support matrix. OpenCode paths
keep their existing version gate. Documentation must distinguish deterministic
fixtures from real-provider acceptance and explain publication/recovery limits.

## Extraction and verification

Copy only companion Lua modules, Python helpers, relevant tests, and their
Python/Lua fixtures from current files on disk, including uncommitted work.
Do not include unrelated editor configuration, history, private operational
documents, scratch artifacts, caches, logs, or authentication material. Preserve
executable modes and record private source hashes outside the public repository.
The original source and installed editor configuration remain unchanged.

Establish a baseline on the extracted copy, fix checkout-relative tests, and run
the full provider-free suite with isolated home/state directories and private
tmux servers. Keep real-provider and installed-OpenCode probes explicitly opt-in.
Test new portable defaults and the reported ACP receive-before-begin edge case
before changing behavior. Perform a fresh code review and focused publication
scan before committing/pushing the first code, using the existing public author
identity.
