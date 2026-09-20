# Testing Draft

The default suite uses disposable files, fake agent processes, local pipes,
Bubblewrap and private tmux servers. It does not use a live editor, the default
tmux server, real account credentials, or paid model requests.

Run from any directory, passing the path to the runner:

```sh
python3 -I -B tests/run.py
```

Dependencies are Linux, Neovim, Python 3, Git, tmux 3.6, Bubblewrap and a POSIX shell.
`setfacl` enables an extra inherited-ACL publication test. The runner builds an
allowlisted child environment, supplies a disposable HOME and XDG directories,
sets a private umask, and applies a per-suite deadline. It does not inherit
editor handles, credentials or real-agent opt-in environment variables.
Logs go under ignored `.test-results/`; failed-suite scratch is retained under
the exact `/tmp/draft-tests-*` path printed by the runner.

Create development checkouts with `umask 022`. Draft refuses group- or
world-writable helpers and executable fixtures. If a checkout was created with
a shared-write umask, correct those file permissions before running the suite:

```sh
chmod go-w scripts/nvim-ai*.py tests/nvim-ai*.sh
```

Choose individual suites by filename stem:

```sh
python3 -I -B tests/run.py draft_setup draft_state ai_runtime
python3 -I -B tests/run.py nvim_ai_acp_worker ai_conversation_driver
python3 -I -B tests/run.py ai_chat ai_chat_view ai_chat_controller ai_chat_approval nvim_ai_chat_ui
```

The review suite needs private root/platform variables; the runner supplies
them. Run each Lua suite in a separate clean Neovim process. A restricted
container that masks `/tmp` or Bubblewrap ownership, blocks sockets, or disables
user namespaces cannot run the confinement fixtures. Use a suitable Linux test
environment; do not relax production ownership or sandbox checks.

## Conversation UI evidence

`ai_chat_controller` exercises the public commands through the production
runtime, controller, confinement and copied fake ACP peer: two explicit turns,
streamed text/progress, eligible context resume, hidden cancellation, deferred
frozen previews, source refusal and cleanup. `nvim_ai_install` repeats that flow
from a plugin path with spaces and an unrelated cwd. `ai_chat_approval` extends
that production path with partial acceptance/rejection, pending revision,
discussion, exact subsequent decision context, confirmed batches and real
source/alias/frozen-buffer drift. It checks stale dialogs and retired mappings,
runtime exclusion, accepted-file preservation, and return to hidden chat even
after the original tab closes. Relocated-install coverage repeats this flow.
The controller suite also
observes public-chat Neovim EOF through process handles and checks private-state
removal. These tests send no live-account requests.

`nvim_ai_chat_ui` uses actual keys in a private tmux server and Neovim TUI. Its
basic input/layout case uses deterministic in-process provider events. Its
model case uses `gm`, cancellation, hide/reopen and explicit Send to verify
passive choice and fixed historical labels. `ai_chat_model` covers stale dialogs,
catalog replacement and the boundary between local choice and saved defaults.
The production controller cases prove two models resume one session; removed
options, rejected confirmation and missing synthetic credentials never send a
second prompt or replace the session. The approval case uses the production
controller, confined fake ACP peer and real
writer to exercise a/r/A/R/f/q, file navigation, revisions and partial receipts.
It can capture the real terminal grids for review:

```sh
DRAFT_CHAT_CAPTURE_DIR=/tmp/draft-chat-captures \
  python3 -I -B tests/nvim_ai_chat_ui.py -q
python3 -I -B tests/fixtures/ai/render_chat_capture.py \
  /tmp/draft-chat-captures/conversation-wide.ansi \
  /tmp/draft-chat-captures/conversation-wide.png --columns 140
python3 -I -B tests/fixtures/ai/render_chat_capture.py \
  /tmp/draft-chat-captures/conversation-narrow.ansi \
  /tmp/draft-chat-captures/conversation-narrow.png --columns 70
python3 -I -B tests/fixtures/ai/render_chat_capture.py \
  /tmp/draft-chat-captures/conversation-review.ansi \
  /tmp/draft-chat-captures/conversation-review.png --columns 140
python3 -I -B tests/fixtures/ai/render_chat_capture.py \
  /tmp/draft-chat-captures/conversation-decisions.ansi \
  /tmp/draft-chat-captures/conversation-decisions.png --columns 140
python3 -I -B tests/fixtures/ai/render_chat_capture.py \
  /tmp/draft-chat-captures/conversation-model.ansi \
  /tmp/draft-chat-captures/conversation-model.png --columns 140
```

Only this optional PNG renderer needs Pillow and DejaVu Sans Mono. It translates
captured cells/SGR colors; the plugin and default tests keep standard-library
Python dependencies. The committed captures and acceptance record are in
[`docs/validation/2026-09-20-conversation-approval.md`](../docs/validation/2026-09-20-conversation-approval.md)
and the earlier UI record. Model selection has its own
[validation record](../docs/validation/2026-09-20-conversation-model.md).

## Linux CI

[Linux tests](../.github/workflows/linux-tests.yml) runs the complete default
suite on pull requests and pushes, and supports manual dispatch. It uses the
GitHub-hosted Ubuntu 24.04 image, its system Python 3, Neovim 0.12.4, and tmux 3.6.
Both release archives have pinned SHA-256 checksums, and both GitHub actions are
pinned to commits. Git, Bubblewrap, ripgrep, ACL tools and tmux build dependencies
come from Ubuntu's configured package repositories; runtime versions are printed
in each run. Ubuntu's tmux 3.4 has a percentage-split regression, so CI builds the
same tmux 3.6 version used in the local transport validation.

CI uses `/usr/bin/python3` consistently with the nested confinement fixtures.
The job loads an AppArmor user-namespace profile attached to `/usr/bin/bwrap`
on the disposable runner; Ubuntu's global namespace restriction remains enabled.
It checks user, PID and network namespace creation before running the suite.
All confinement tests remain enabled, and installed-OpenCode probes remain
explicit opt-ins. Test logs are uploaded as `linux-test-logs` for seven days,
including after a test failure. The job has a 25-minute deadline, with the
runner's existing per-suite deadlines inside it.

Hosted validation on 2026-09-19: [46/46 suites passed](https://github.com/ruohao1/draft.nvim/actions/runs/35463990214)
with the expected installed-agent opt-in skips. The Ubuntu 24.04 runner image
`20260907.300.1` provided Python 3.12.3, Git 2.55.0, Bubblewrap 0.9.0,
ripgrep 14.1.0 and ACL tools 2.3.2, alongside the pinned Neovim 0.12.4 and tmux 3.6.

## Installed OpenCode audit (optional)

The deterministic managed-OpenCode suite explicitly skips its installed-binary
artifact audit by default. To include that audit, pass the canonical path to
OpenCode **1.18.30**:

```sh
python3 -I -B tests/run.py --opencode /absolute/path/to/opencode ai_opencode_managed
```

This tests local compatibility commands and disposable artifact trees, without a
model request. It is distinct from the default fixtures.

Additional Python interoperability cases are opt-in when running those test
files directly in an isolated environment:

- `NVIM_AI_STAGED_REAL_OPENCODE=/absolute/path`: staged native edit tools against
  a loopback scripted provider (`nvim_ai_staged.py`, `nvim_ai_staged_multi.py`).
- `NVIM_AI_ACP_REAL_OPENCODE=/absolute/path`: retained-session/owner-death proofs
  with a scripted provider (`nvim_ai_acp_resume.py`, `nvim_ai_conversation_lifetime.py`)
  and the production controller (`nvim_ai_conversation_interop.py`).
- `NVIM_AI_CACHE_REAL=1`: installed OpenCode cache audit
  (`nvim_ai_opencode_cache.py`; the binary must also be on PATH).

These flags are deliberately not forwarded by the standard runner. The shell
scripts `nvim-ai-opencode-probe.sh` and `nvim-ai-opencode-compat.sh` are optional
installed-binary probes. `ai_transport_manual.lua` is an interactive transport
demo and is never part of automated testing.

Run the production-controller proof from the checkout with a canonical path to
the installed **1.18.30** executable. This exact invocation constructs an
allowlisted environment and removes only its own disposable profile directories:

```sh
python3 - <<'PY'
import os, pathlib, subprocess, sys, tempfile
os.umask(0o077)
with tempfile.TemporaryDirectory(prefix="draft-pinned-controller-", dir="/tmp") as scratch:
    env = {"PATH": os.defpath, "LANG": "C.UTF-8",
           "NVIM_AI_ACP_REAL_OPENCODE": "/absolute/path/to/opencode"}
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
        path = pathlib.Path(scratch) / key.lower()
        path.mkdir(mode=0o700)
        env[key] = str(path)
    result = subprocess.run([sys.executable, "-I", "-B",
                             "tests/nvim_ai_conversation_interop.py", "-v"], env=env)
    sys.exit(result.returncode)
PY
```

The four cases check real assistant/native-tool continuity without prompt replay,
model/profile reapplication, cooperative cancellation/resume, actual restoration
errors, and provider context overflow without compaction or replay. They observe
the production controller's real ACP calls and worker metadata. The restoration
fault substitutes a nonexistent session ID only in the test observer; the real
backend returns the error. No database bytes are inspected, changed or repaired.
Synthetic request contents stay in test fixtures; production diagnostics remain
content-free. Every owned listener must stop, and close must remove retained state.

## What the tests establish

Native suites cover identity, private state, transport, context, sandbox
manifests, session lifecycle, review/rejection, scope grants and event handling.
Staging suites cover selection, settings, dirty-source guards, frozen proposals,
incremental/batch publication, receipts, partial failures and follow-ups.
The sandbox shell fixture exercises actual confinement with a fake agent.
The native lifecycle harness exercises the public Draft facade through private
tmux panes with fake Codex, Claude and OpenCode processes. Optional terminal UI
cases can be selected explicitly, for example
`sh tests/nvim-ai-native.sh prompt` or `sh tests/nvim-ai-native.sh review`.
Use Neovim 0.12+ on PATH for these direct invocations.

The install suite copies the plugin to a directory containing spaces, launches
Neovim from an unrelated cwd, exercises real sibling helpers/controller fixtures,
and generates and resolves the public help tags.

Conversation tests exercise internal owners, the production controller, ACP
workers, retained storage, review receipts, cancellation/backpressure and process
lifetime. A separate scripted controller remains in the isolated pipe unit suite.
Real headless tests exercise the production factory, guarded publication, dirty
hidden aliases, frozen-panel changes, source-refresh failures and editor EOF.
Passing these internal engine tests does not make the unfinished chat UI available.

The first extraction is validated on Linux with Neovim 0.12.4, Python 3.14.4,
Bubblewrap 0.11.1, Git 2.53.0 and tmux 3.6. This is not a claim that older Neovim,
macOS, Windows or every real backend/account workflow is supported.
