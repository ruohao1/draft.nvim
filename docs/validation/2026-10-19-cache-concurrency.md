# Compatibility-cache concurrency test correction

The [push run for PR #12](https://github.com/ruohao1/draft.nvim/actions/runs/39299514344)
failed `test_concurrent_publication_leaves_one_complete_private_receipt`:
one publisher returned `{"stored": false}`. The [parallel PR run](https://github.com/ruohao1/draft.nvim/actions/runs/39299524397)
passed all 67 suites at the same revision. The cache helper and its test were
unchanged from `bba5c4b`.

## Diagnosis and scope

A private host-filesystem probe of the original CLI completed 100 batches of
four stores. Eight concurrent calls to the real `store()` function reproduced
the refusal after 17 batches. A second run instrumenting only the failed file
check reproduced it after 112 batches. The rejected metadata described a regular
0600 file owned by the current user, but with **zero links**. The current path
already named a different inode with the same safe mode/owner and one link.

Another publisher's atomic rename can unlink the inode while `stat()` collects
its metadata. The safety check correctly refuses that stale observation. The
helper reports this as a best-effort miss. `opencode_validation.lua` explicitly
ignores publication failure after a successful compatibility audit; another
publisher's valid receipt can still be reused. Unlike saved user settings, this
cache does not promise successful publication from every concurrent caller.

The initial sandbox-only probe hit the separate `unsafe cache directory` guard.
That was not the CI failure; subsequent probes ran on the normal host filesystem.
No ownership or confinement check was relaxed.

Only `tests/nvim_ai_opencode_cache.py` changes. Production helpers, cache locks,
lookup behavior, commands, options and default test discovery are unchanged.
The existing test now requires at least one successful publisher, successful or
refused outcomes, a single complete private receipt and a fresh-editor cache hit.
It permits safe refusals from other publishers.

## Deterministic regression

The same test also controls the observed filesystem interleaving in a disposable
Python process. Its `stat()` hook holds a real receipt descriptor, invokes a
second real `store()` to replace that receipt, then returns `fstat()` metadata
from the now-unlinked inode. The original CLI `main()` must return
`{"stored": false}`; the hook does not fabricate that response. The peer's store
must succeed, and the remaining receipt must still provide a warm editor hit.

The uncontrolled four-process result is checked **before** this control writes
anything, so the extra store cannot repair a broken concurrent result and hide a
regression. Both paths require no leftover temporary receipts. Removing the
zero-link safety check would fail the explicit refusal assertion.

With the deterministic refusal added, the old all-publishers-succeed assertion
failed on every execution in the recorded RED run. Changing that assertion to
the existing best-effort contract made the cache suite pass. The production
safety check was preserved.

## Validation

From the isolated `fix/cache-concurrent-publication` worktree:

- Baseline cache suite: 20 tests, two installed-provider skips; passed.
- RED: `.test-results/run-lljj9w0n`, expected `stored: true`, observed `stored: false`.
- GREEN: `.test-results/run-ypp5aeug`, 20 tests, two skips; passed.
- Full suite: `python3 -I -B tests/run.py`, `.test-results/run-82qm8trh`;
  **67/67 suites passed**, including the final cache test with both pre-injection
  and post-injection receipt checks. Installed-provider audits remained skipped.
- Independent review: no critical, important or minor findings; ready for PR.
- `git diff --check`: passed.

No credentials or provider requests were used. The separate Claude live baseline
remains dependent on installation and authentication.
