"""Production controller exercised through separate processes and private pipes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/nvim-ai-conversation.py"


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-controller-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"opencode": "/missing/unused-agent", "bwrap": "/usr/bin/bwrap",
                                           "model": "fixture/model"}))
        self.config.chmod(0o600)

    def close_frame(self):
        return {"version": 1, "serial": 1, "command": {
            "kind": "close", "conversation_id": "a" * 32, "owner_generation": 1,
            "turn_id": 0, "worker_generation": 0, "root": str(self.root),
            "selection": ["example.txt"], "model": "fixture/model"}}

    def invoke(self, raw):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                              input=raw, capture_output=True, timeout=3,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)

    def test_close_before_a_turn_needs_no_agent_or_store(self):
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["version"], value["serial"]), (1, 1))
        self.assertEqual(value["event"], {"kind": "closed", "conversation_id": "a" * 32,
            "owner_generation": 1, "turn_id": 0, "worker_generation": 0, "sequence": 1,
            "stopped": True, "cleaned": True, "tokens_retired": True})
        self.assertEqual(list(self.root.iterdir()), [self.config])
        self.assertEqual(result.stderr, b'')

    def test_malformed_or_partial_editor_input_never_asserts_cleanup(self):
        for raw in (b'{bad}\n', b'{"version":1', b'[]\n'):
            with self.subTest(raw=raw):
                result = self.invoke(raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertNotIn(b'{bad}', result.stderr)

    def test_untrusted_launch_file_is_refused_even_for_passive_close(self):
        self.config.chmod(0o644)
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')

    def test_blocked_editor_output_exits_within_its_absolute_deadline(self):
        reader, writer = os.pipe()
        try:
            os.set_blocking(writer, False)
            try:
                while True:
                    os.write(writer, b'x' * 4096)
            except BlockingIOError:
                pass
            started = time.monotonic()
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)
            try:
                _, error = process.communicate(json.dumps(self.close_frame()).encode() + b'\n', timeout=7)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            self.assertNotEqual(process.returncode, 0)
            self.assertGreaterEqual(time.monotonic() - started, 5)
            self.assertLess(time.monotonic() - started, 7)
            self.assertIn(b'explicit recovery required', error)
        finally:
            os.close(reader)
            os.close(writer)


if __name__ == "__main__":
    unittest.main()
