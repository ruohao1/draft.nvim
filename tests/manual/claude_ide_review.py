#!/usr/bin/env python3
"""Opt-in, offline observer controls. Never launches Claude or reads account state."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PIN = "2390c6e45c4789072c293ac69de051d169668b29"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ORIGINAL = b'local greeting = "before"\n'
PROPOSED = b'local greeting = "after"\n'
EDITED = b'local greeting = "human"\n\n'
CONTROL = r'''
vim.opt.runtimepath:prepend(vim.env.STUDY_PLUGIN)
vim.o.swapfile = false
vim.o.hidden = true
local path = vim.env.STUDY_FILE
local scenario = vim.env.STUDY_CASE
local title = "✻ [Claude Code] sample.lua (synthetic) ⧉"
local diff = require("claudecode.diff")
diff.setup(require("claudecode.config").apply({
  auto_start = false, track_selection = false,
  terminal = { provider = "none" }, diff_opts = { layout = "vertical" },
}))
local server = require("claudecode.server")
server.register_handlers()
require("claudecode.tools.init").setup(server)
local received = {}
local client = { id = "synthetic-client", state = "connected", tcp_handle = {} }
function client.tcp_handle:write(bytes, callback)
  local parsed = assert(require("claudecode.server.frame").parse_frame(bytes))
  received[#received + 1] = vim.json.decode(parsed.payload)
  if callback then callback(nil) end
end
server.state.server = { clients = { [client.id] = client } }
local observer = dofile(vim.env.STUDY_OBSERVER).install({
  root = vim.env.STUDY_ROOT, file = path, output = vim.env.STUDY_OUTPUT,
})
vim.cmd.edit(vim.fn.fnameescape(path))
local function call(id, name, arguments)
  server._handle_request(client, {
    jsonrpc = "2.0", id = id, method = "tools/call",
    params = { name = name, arguments = arguments },
  })
end
local ok, err = xpcall(function()
  call(11, "openDiff", { old_file_path = path, new_file_path = path,
    new_file_contents = 'local greeting = "after"\n', tab_name = title })
  local state = assert(diff._get_active_diffs()[title], "missing pending diff: " .. vim.inspect(received))
  assert(state.status == "pending" and #received == 0)
  observer.checkpoint("pending")
  vim.api.nvim_set_current_win(state.new_window)
  if scenario == "edited" then
    vim.api.nvim_buf_set_lines(state.new_buffer, 0, -1, false, { 'local greeting = "human"', "" })
  end
  observer.checkpoint("decision", { decision = scenario == "reject" and "reject" or "accept" })
  if scenario == "reject" then diff.deny_current_diff() else vim.cmd.write() end
  assert(#received == 1 and received[1].id == 11, "expected one transport response")
  local result = received[1].result
  local expected = scenario == "reject" and "DIFF_REJECTED" or "FILE_SAVED"
  assert(result.content[1].text == expected, vim.inspect(result))
  if scenario ~= "reject" then
    local text = scenario == "edited" and 'local greeting = "human"\n\n' or 'local greeting = "after"\n'
    assert(result.content[2].text == text, "accepted bytes differ")
    assert(state.status == "saved" and vim.api.nvim_buf_is_valid(state.new_buffer))
  end
  call(12, "close_tab", { tab_name = title })
  assert(#received == 2 and received[2].id == 12)
  assert(received[2].result.content[1].text == "TAB_CLOSED")
  assert(diff._get_active_diffs()[title] == nil, "finalizer did not clean state")
  vim.wait(150, function() return false end, 10)
  if scenario == "invalid_json" then
    assert(server._handle_message(client, "{") == nil)
    assert(#received == 3 and received[3].id == nil and received[3].error.code == -32700)
  elseif scenario == "malformed_params" then
    assert(server._handle_message(client, vim.json.encode({
      jsonrpc = "2.0", id = 13, method = "tools/call", params = 42,
    })) == nil)
    assert(#received == 3 and received[3].id == 13 and received[3].error.code == -32603)
  end
  observer.checkpoint("teardown")
  assert(#observer.errors == 0, table.concat(observer.errors, "\n"))
end, debug.traceback)
server.state.server = nil
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
'''


def run(command, *, cwd, env, log, timeout=300):
    """Only this process group belongs to the fixture; retain timeout evidence."""
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise
    assert code == 0, f"process exit {code}; see {log}"


def private_environment(home):
    env = {"PATH": os.defpath, "LANG": "C.UTF-8", "TERM": "xterm-256color",
           "NVIM_LOG_FILE": "/dev/null", "DISABLE_AUTOUPDATER": "1"}
    for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                      ("XDG_CACHE_HOME", "cache"), ("CLAUDE_CONFIG_DIR", "claude")):
        path = home / name
        path.mkdir(mode=0o700)
        env[key] = str(path)
    return env


def check_control(events, directory, case):
    requests = [e for e in events if e["kind"] == "request"]
    responses = [e for e in events if e["kind"] == "response_attempt"]
    error_case = case in ("invalid_json", "malformed_params")
    expected = [("synthetic-client", 11, "openDiff"), ("synthetic-client", 12, "close_tab")]
    if case == "malformed_params":
        expected.append(("synthetic-client", 13, None))
    assert [(e["client"], e["request_id"], e.get("tool")) for e in requests] == expected
    assert len(responses) == (3 if error_case else 2), "missing correlated RPC events"
    correlated = responses[:-1] if case == "invalid_json" else responses
    assert [(e["client"], e["request_id"], e.get("tool")) for e in correlated] == expected
    if error_case:
        assert responses[-1]["error_code"] == (-32700 if case == "invalid_json" else -32603)
        assert responses[-1].get("request_id") == (None if case == "invalid_json" else 13)
    assert [e["sequence"] for e in events] == list(range(1, len(events) + 1))
    assert all(e["origin"] == "nvim" for e in events)
    assert all(a["monotonic_ns"] <= b["monotonic_ns"] for a, b in zip(events, events[1:]))
    assert {"pending", "decision", "finalization", "teardown"} <= {e["kind"] for e in events}
    assert all(e["file"]["exists"] and e["file"]["path"] == "sample.lua" for e in events)
    assert all(e["file"]["sha256"] == hashlib.sha256(ORIGINAL).hexdigest() for e in events)
    identities = {(e["file"]["device"], e["file"]["inode"]) for e in events}
    assert len(identities) == 1, "source identity changed during editor control"
    for event in events:
        assert event["file"]["length"] == len(ORIGINAL)
        assert (directory / event["file"]["snapshot"]).read_bytes() == ORIGINAL
    proposal = requests[0]["proposal"]
    assert (directory / proposal["snapshot"]).read_bytes() == PROPOSED
    result = responses[0]
    assert result["status"] == ("DIFF_REJECTED" if case == "reject" else "FILE_SAVED")
    if case != "reject":
        accepted = result["accepted"]
        expected = EDITED if case == "edited" else PROPOSED
        assert (directory / accepted["snapshot"]).read_bytes() == expected
        assert accepted["sha256"] == hashlib.sha256(expected).hexdigest()
    returns = [e for e in events if e["kind"] == "response_return"]
    assert len(returns) == len(responses) and all(e["delegated_return"] is True for e in returns)
    assert requests[1]["tab_name"] == "✻ [Claude Code] sample.lua (synthetic) ⧉"


def trace_writer(command, fixture, directory, env):
    strace = shutil.which("strace")
    assert strace, "strace unavailable; writer attribution is unknown"
    # shortcut: known synthetic paths only; extend discovery before tracing a real CLI.
    run([strace, "-ff", "-qq", "--absolute-timestamps=unix,ns", "-y",
         "-e", "trace=openat,close,write,writev,pwrite64,pwritev,pwritev2,ftruncate,rename,renameat,renameat2,unlink,unlinkat,fsync,fdatasync",
         "-e", "raw=write,writev,pwrite64,pwritev,pwritev2",
         "-P", str(fixture / "sample.lua"), "-P", str(fixture / "sample.tmp"),
         "-o", str(directory / "syscalls")] + command,
        cwd=fixture, env=env, log=directory / "writer.log")
    return sorted(directory.glob("syscalls.*"))


def check_trace(case, directory):
    with tempfile.TemporaryDirectory(prefix="draft-claude-writer-") as scratch:
        fixture = Path(scratch)
        env = private_environment(fixture)
        target = fixture / "sample.lua"
        target.write_bytes(ORIGINAL)
        before = target.stat()
        writer = directory / "writer.py"
        writer.write_text("""import os
from pathlib import Path
import sys
path = Path(sys.argv[1])
if sys.argv[2] == 'trace_rename':
    temporary = path.with_suffix('.tmp')
    temporary.write_bytes(b'SYNTHETIC_PAYLOAD_NOT_FOR_TRACE\\n')
    os.replace(temporary, path)
else:
    path.write_bytes(b'SYNTHETIC_PAYLOAD_NOT_FOR_TRACE\\n')
""")
        traces = trace_writer([sys.executable, "-I", "-B", str(writer), str(target), case],
                              fixture, directory, env)
        assert traces, "missing process-scoped syscall trace"
        raw = "".join(path.read_text() for path in traces)
        assert "SYNTHETIC_PAYLOAD" not in raw, "trace decoded write payload"
        assert "write(0x" in raw, "missing undecoded write syscall"
        assert str(target) in raw, "missing fixture attribution"
        assert target.read_bytes() == b'SYNTHETIC_PAYLOAD_NOT_FOR_TRACE\n'
        after = target.stat()
        renamed = "rename(" in raw
        assert renamed == (case == "trace_rename")
        assert ((before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)) == renamed
        (directory / "result.json").write_text(json.dumps({
            "provenance": "synthetic", "writer": "isolated Python child", "case": case,
            "before": {"device": before.st_dev, "inode": before.st_ino},
            "after": {"device": after.st_dev, "inode": after.st_ino},
            "fixture": scratch, "raw_traces": [path.name for path in traces],
            "cross_clock_ordering": "not established",
        }, indent=2) + "\n")
    assert not fixture.exists()


def self_test(plugin):
    nvim = shutil.which("nvim")
    assert nvim, "Neovim is required"
    pin = subprocess.check_output(["git", "-C", str(plugin), "rev-parse", "HEAD"], text=True).strip()
    assert pin == PIN, f"expected plugin pin {PIN}, got {pin}"
    assert not subprocess.check_output(["git", "-C", str(plugin), "status", "--porcelain"], text=True), "plugin checkout is dirty"
    evidence_root = ROOT / ".test-results" / "claude-cli-review"
    evidence_root.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%dT%H%M%S-"), dir=evidence_root))
    manifest = {"provenance": "synthetic", "plugin_commit": pin,
                "nvim": subprocess.check_output([nvim, "--version"], text=True).splitlines()[0],
                "strace": subprocess.check_output(["strace", "--version"], text=True).splitlines()[0] if shutil.which("strace") else None,
                "python": sys.version.split()[0], "claude": "not invoked", "model": None,
                "permission_mode": None, "diff_tool": None, "layout": "vertical",
                "explicit_prompts": 0, "results": [], "fixtures": []}
    for case in ("accept", "reject", "edited", "invalid_json", "malformed_params"):
        directory = evidence / case
        directory.mkdir(mode=0o700)
        try:
            with tempfile.TemporaryDirectory(prefix="draft-claude-control-") as scratch:
                fixture = Path(scratch)
                manifest["fixtures"].append(scratch)
                env = private_environment(fixture)
                path = fixture / "sample.lua"
                path.write_bytes(ORIGINAL)
                control = directory / "control.lua"
                control.write_text(CONTROL)
                env.update(STUDY_PLUGIN=str(plugin), STUDY_FILE=str(path), STUDY_CASE=case,
                           STUDY_OBSERVER=str(HERE / "claude_ide_observer.lua"),
                           STUDY_ROOT=str(fixture), STUDY_OUTPUT=str(directory))
                run([nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", str(control)],
                    cwd=fixture, env=env, log=directory / "nvim.log")
                event_path = directory / "events.jsonl"
                events = [json.loads(line) for line in event_path.read_text().splitlines()] if event_path.exists() else []
                check_control(events, directory, case)
                assert path.read_bytes() == ORIGINAL
            manifest["results"].append({"case": case, "outcome": "passed"})
            print(f"PASS {case}", flush=True)
        except Exception as error:
            manifest["results"].append({"case": case, "outcome": "failed", "error": str(error)})
            print(f"FAIL {case}: {error}", flush=True)
    for case in ("trace_in_place", "trace_rename"):
        directory = evidence / case
        directory.mkdir(mode=0o700)
        try:
            check_trace(case, directory)
            manifest["results"].append({"case": case, "outcome": "passed"})
            print(f"PASS {case}", flush=True)
        except Exception as error:
            manifest["results"].append({"case": case, "outcome": "failed", "error": str(error)})
            print(f"FAIL {case}: {error}", flush=True)
    manifest["fixtures_removed"] = all(not Path(path).exists() for path in manifest["fixtures"])
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Private evidence: {evidence}", flush=True)
    return int(any(result["outcome"] != "passed" for result in manifest["results"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    sys.exit(self_test(args.plugin.resolve()))
