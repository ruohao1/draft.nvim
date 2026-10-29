# Codex rollback journal validation

Date: 2026-10-29. Baseline: `8cc5ecf`.

## Failure and change

A prior synthetic refresh preflight with Codex 0.163.0 observed an owned,
single-link `0600` file named `memories_1.sqlite-journal` during initialization.
The private store admitted the database and its WAL/SHM files but refused its
rollback journal. The refusal occurred before a refresh request.

The deterministic backend now creates that journal during initialization and
state persistence. Against the old policy, store and turn checks refuse it, and
the independent generated-profile assertion finds no journal read-deny entry.
The failing run is `.test-results/run-e8w2ph6s`.

The production change adds `-journal` to the existing suffix list for the six
pinned database names. The same inventory generates private command masks.
No wildcard admission or separate mask list was added. File ownership, `0600`
mode, regular type, single-link, byte/count budgets, race checks and stopped-state
seals remain unchanged. Inspection remains metadata-only.

## Checks

- Baseline store/profile checks passed: 20 tests in two suites
  (`run-ntcnt8ld`). The restricted tool environment first refused its remapped
  system executable owner; the normal Linux host run passed without policy changes.
- The focused store/profile/turn suites passed: 39 tests in three suites
  (`run-7d7uf2xs`). They exercise journal
  creation and disappearance while active, stopped-worker reuse, source retention,
  tamper refusal and complete Close.
- Unsafe journal modes, symlinks, hardlinks, FIFOs and directories refuse cleanup
  before deletion. Unknown database names, non-database names and nested journal
  paths remain refused. A large journal still triggers the byte budget.
- Literal profile assertions cover each known database journal independently of
  the production inventory. Existing installed-runtime probes cover direct,
  symlink and proc-root private-state read denial.

- The full provider-free run passed **76/76 suites**, zero failures
  (`run-613nz3y8`). Optional installed-provider cases remain opt-in.
- Lua formatting and whitespace checks passed. Independent review found no
  material issues. Hosted CI and installed-runtime results are recorded on the PR.

## Limits

These regressions use synthetic state and deterministic providers. They do not
overwrite a real CLI's active SQLite journal to create a read-denial sentinel.
The change does not establish actual token refresh, durable credential ownership
or live-service acceptance. No account credential or live provider request is
needed for these checks. This fix is not part of a tagged release.
