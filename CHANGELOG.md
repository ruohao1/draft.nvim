# Changelog

## Unreleased

- Managed Codex accepts private SQLite rollback journals for its known databases,
  avoiding startup refusals when the pinned CLI creates a journal. Journals remain
  subject to the existing state checks and command read restrictions.

- Chat now uses theme-aware message labels and a compact header. Current recovery
  guidance follows the latest reply, and the composer shows Send only when available.
  Frozen review has shorter labels and controls; managed diff panes stay balanced
  when the terminal resizes. The README now has a shorter first-edit walkthrough,
  with detailed setup and recovery guidance in `docs/usage.md`.

- Managed Codex returns to idle after a confirmed cancellation, so a new Send
  can continue the same thread without unnecessary recovery.
- Managed Codex now mounts its code-mode companion so model tools can edit selected
  copies for review. Install the native Codex 0.163.0 CLI and matching
  `codex-code-mode-host` beside it, as provided by the complete release package.
  Missing or unsafe companions stop Send before prompt submission.
