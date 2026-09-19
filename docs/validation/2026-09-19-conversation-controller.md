# Production conversation controller validation

## Baseline — 2026-09-19

Baseline commit: `c6d4d198fe019c9372ab0a2bae24dc3afca462c1`.
The approved controller plan starts from the completed standalone extraction and
Linux CI. Tests ran from a new isolated worktree before implementation changes.

- `python3 -I -B tests/run.py`: **46/46 suites passed**, zero failures; installed-agent opt-in skips were expected.
- `tests/nvim_ai_acp_resume.py -v`, with its explicit pinned-runtime opt-in: **4/4 passed** in 14.097 seconds.
- `tests/nvim_ai_conversation_lifetime.py -v`, with the same opt-in: **5/5 passed** in 2.273 seconds, including the real runtime owner-death case.

The opt-in runs used an allowlisted environment, disposable HOME/XDG directories,
synthetic credentials and a loopback scripted provider. They reused the existing
OpenCode executable without installation or upgrade. No live account, editor,
tmux session or configuration was changed.

Tested versions: Neovim 0.12.4, Python 3.14.4, Bubblewrap 0.11.1, Git 2.53.0,
tmux 3.6 and OpenCode 1.18.30 / ACP 1. The OpenCode executable SHA-256 was
`87bd160e053af86b5b409daabf71f8dc05bbc3a2a3a5f563f36011cdf706a999`.

These fresh results establish the existing component baseline, including retained
history across worker restart and owner-death supervision. Production-controller
integration and its separate pinned-runtime proof remain implementation work.
