# Codex companion design

Managed Codex must execute code-mode edits inside its existing sandbox, then
freeze proposals only after the worker stops. The confirmed failure is a missing
`codex-code-mode-host`: Draft currently mounts only `/opt/codex`.

Use the companion beside the canonical configured native Codex executable.
The supported installation is the Codex 0.163.0 native CLI and companion from
the same release. Reuse the existing executable ownership, mode, canonical-path
and executable-bit checks. Reject a missing or unsafe companion before starting
app-server or submitting a prompt. Mount only that file read-only at
`/opt/codex-code-mode-host`.

The user authorized companion discovery, the narrow mount and code-mode review
regressions after a controlled missing/present experiment. Implementation choices:
support the pinned release's sibling layout; do not search PATH, import a package
directory, add an override, disable code mode or weaken either sandbox.
The companion has no `--version` option. The CLI's existing 0.163.0 handshake
check remains; users must install the matching pair. CI will extract both
executables from one checksum-pinned release package.

Update the fixed launch diagnostic to name the companion. Opening chat and
health remain passive. Native backend launchers and OpenCode remain unchanged.

The provider fixture must emit custom `exec` that calls `tools.exec_command`.
Installed checks must prove actual command completion, credential isolation on
new/resumed threads, a real staging edit, frozen pending review after worker exit,
exact-thread resume, and Close. Frozen bytes must stay separate from saved source
bytes until approval.

Keep the design, plan, documentation and changelog with the implementation branch.
Use synthetic credentials only. The supplied SSH host may run the existing scoped
test profile; remove it and temporary files afterward. A live account trial is
a separate follow-up.

Alternatives: mounting the full package grants unnecessary read access; forcing
direct tools conflicts with models that require code mode. The narrow companion
mount is the demonstrated fix.
