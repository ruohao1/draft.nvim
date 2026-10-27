# Codex code-mode companion validation — 2026-10-27

The launcher now validates the companion beside the configured native Codex CLI
and mounts it read-only at `/opt/codex-code-mode-host`. It mounts no containing
package directory. Existing private-state masks and both sandbox layers remain.

## Regression evidence

The new profile assertions failed against the old launcher: the companion bind
was absent, and missing/writable/non-executable/symlink/directory/FIFO companions
were accepted. After the change, all nine profile tests passed.
The turn test proves that a missing companion starts no worker and submits no
prompt. The editor test checks the actionable hint, retained draft, and matching
status/health diagnostics.

The focused profile, turn, controller and editor suites passed. The first full
run found an incomplete store-test installation fixture; adding its companion
stub made all 11 store tests pass. The final full run is recorded below.

## Pinned installed runtime

The complete 0.163.0 x86_64 Linux package was downloaded from the official release.
Its SHA-256 is
`582646c6bf0561eb0de540f7fc85b9121b0091a826bc6e96830b7f1722122182`.
Only `bin/codex` and `bin/codex-code-mode-host` were extracted, using the same
command as the updated CI job.

A supported Ubuntu 26.04 host ran the production sandbox, Store and controller
against a loopback scripted Responses provider and synthetic credentials.
No account credential or live model request was used.

The control replaced only the launcher with its old version. The new custom
`exec` fixture then returned the exact missing-host spawn error and no frozen
review. The review test failed as expected. Restoring the new launcher made
**all seven installed tests pass**, with **zero skips**, in **60.438 seconds**.

This covers selected-copy writes, private credential/model-cache read denial,
network denial, hostile configuration isolation, positive code-mode command
completion, frozen pending review after worker exit, exact-thread resume,
matching cancellation and normal Close. The saved source remains unchanged
while the proposal is pending. Credential isolation is checked in new and resumed
threads; a failed tool cannot satisfy the expected successful nested output.

The temporary named AppArmor profile applied only to the test process tree.
It was removed afterward. A root observer found no matching process, open handle
or retained installed-test directory. The stock profile checksum and both global
namespace restrictions stayed unchanged. Temporary remote tools were removed
after evidence collection.

## Local checks

- Focused suites: 9 profile tests, 16 turn tests, 41 controller tests, the Codex
  editor suite, and the corrected 11 store tests passed.
- Final full suite: **76/76 suites passed**, zero failures (`run-jetwbu96`).
  The default run kept its 20 optional installed-provider unittest skips and one
  installed-OpenCode artifact-audit skip. The seven Codex installed cases ran
  separately above with no skips.
- `stylua --check lua tests` and `git diff --check` passed.
- Independent read-only review found no Critical, Important or Minor defects.

## Limits

This proves the synthetic code-mode edit → frozen review → resume path.
It does not establish live-account review/approval or actual token refresh.
The companion has no independent version-reporting option; install the native
CLI and companion from the same pinned release. Other installation layouts are
not searched. This change is not yet part of a tagged release.
