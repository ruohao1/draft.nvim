"""Run the provider-free Linux suites with disposable editor state.

Usage: python3 -I -B tests/run.py [suite ...]
Installed OpenCode probes are deliberately excluded; see tests/README.md.
"""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencode", type=Path, help="opt in to the installed OpenCode artifact audit")
    parser.add_argument("suites", nargs="*")
    args = parser.parse_args()
    if args.opencode and not args.opencode.is_absolute():
        parser.error("--opencode must be an absolute executable path")
    os.umask(0o077)
    nvim = shutil.which("nvim")
    if not nvim:
        raise SystemExit("Neovim is required (nvim was not found on PATH)")
    suites = {p.stem: [sys.executable, "-I", "-B", str(p), "-q"]
              for p in sorted((ROOT / "tests").glob("nvim_ai*.py"))}
    for pattern in ("ai*.lua", "draft*.lua"):
        for p in sorted((ROOT / "tests").glob(pattern)):
            if p.stem != "ai_transport_manual":
                suites[p.stem] = [nvim, "--clean", "--headless", "-u", "NONE", "-i", "NONE",
                                  "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)",
                                  "-l", str(p)]
    suites["nvim-ai-native"] = ["sh", str(ROOT / "tests/nvim-ai-native.sh")]
    suites["nvim-ai-sandbox"] = ["sh", str(ROOT / "tests/nvim-ai-sandbox.sh")]
    selected = args.suites or sorted(suites)
    unknown = set(selected) - suites.keys()
    if unknown:
        raise SystemExit("Unknown suites: " + ", ".join(sorted(unknown)))
    log_root = ROOT / ".test-results"
    log_root.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="run-", dir=log_root))
    print(f"Logs: {logs}", flush=True)
    failed = []
    # Start from an allowlist, never the caller's credentials, editor handles,
    # agent options, or opt-in real-provider test flags.
    scratch = Path(tempfile.mkdtemp(prefix="draft-tests-", dir="/tmp"))
    try:
        for name in selected:
            private = scratch / name
            private.mkdir()
            env = {"PATH": str(Path(nvim).parent) + os.pathsep + os.defpath,
                   "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TERM": "xterm-256color",
                   "SHELL": "/bin/sh", "NVIM_LOG_FILE": "/dev/null",
                   "DRAFT_TEST_ROOT": str(ROOT), "PYTHONDONTWRITEBYTECODE": "1"}
            for key, directory in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                                   ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                                   ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "run")):
                path = private / directory
                path.mkdir(mode=0o700)
                env[key] = str(path)
            if args.opencode:
                env["NVIM_AI_MANAGED_REAL_OPENCODE"] = str(args.opencode.resolve())
            if name == "ai_review":
                review_root = private / "review"
                review_root.mkdir(mode=0o700)
                env["AI_REVIEW_TEST_ROOT"] = str(review_root)
                env["AI_REVIEW_NATIVE_PLATFORM"] = "Linux"
            started = time.monotonic()
            timed_out = False
            with (logs / (name + ".log")).open("wb") as output:
                child = subprocess.Popen(suites[name], cwd=ROOT, env=env, stdout=output,
                                         stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = child.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    code = 124
            if code:
                failed.append(name)
            else:
                shutil.rmtree(private)
            label = "TIMEOUT" if timed_out else "FAIL" if code else "PASS"
            print(f"{label} {name} ({time.monotonic() - started:.1f}s)", flush=True)
            content = (logs / (name + ".log")).read_text(errors="replace")
            if code:
                print("\n".join(content.splitlines()[-18:]), flush=True)
            else:
                for line in content.splitlines():
                    if line.startswith(("Ran ", "OK (skipped=", "SKIP ")):
                        print("  " + line, flush=True)
    finally:
        if not any(scratch.iterdir()):
            scratch.rmdir()
        else:
            print(f"Retained failed-suite scratch: {scratch}", flush=True)
    print(f"{len(selected) - len(failed)}/{len(selected)} suites passed; {len(failed)} failed.", flush=True)
    return bool(failed)


if __name__ == "__main__":
    sys.exit(main())
