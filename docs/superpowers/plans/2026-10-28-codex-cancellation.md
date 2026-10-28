# Codex cancellation event fix

A confirmed Codex interrupt currently emits `stopping` before `cancelled`.
The editor is already `cancelling` and rejects that extra event. Return to
`idle` only after the existing interrupt, worker-exit, store-validation and
workspace-retirement checks pass. A new explicit Send must resume the same thread.

- [x] Reproduce through the existing managed-Codex editor suite, using the
  production controller, adapter and owner with the scripted wire peer.
- [x] Emit `stopping` only for normal completion. Preserve cancellation proof
  and all failure/recovery paths.
- [x] Verify explicit same-thread continuation, unchanged sources and Close.
  Run the affected suites and the default suite. Add the changelog entry and
  validation record, then obtain independent review.

Keep this plan, implementation and regression in one PR. A new live-account
trial follows review and integration; this fix uses no real account or prompt.
