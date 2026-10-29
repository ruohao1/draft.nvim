"""Bounded saved-login ownership and exclusive leases; all tokens are synthetic."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixture = load(ROOT / "tests/fixtures/ai/codex_auth.py")
auth = load(ROOT / "scripts/nvim-ai-codex-auth.py")


class LeaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-owned-auth-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.directory = self.parent / "dedicated login"
        self.directory.mkdir(mode=0o700)
        self.path = self.directory / "auth.json"
        self.write(fixture.bundle())
        self.original = self.path.read_bytes()

    def write(self, value):
        self.path.write_text(json.dumps(value))
        self.path.chmod(0o600)

    def lease(self, **kwargs):
        lease = auth.Lease(str(self.directory), **kwargs)
        self.addCleanup(lease.close)
        return lease

    def refused(self, reason="credentials", **kwargs):
        with self.assertRaises(auth.Refused) as caught:
            self.lease(**kwargs)
        self.assertEqual(str(caught.exception), reason)

    def test_close_preserves_credentials(self):
        lease = self.lease()
        self.assertEqual(lease.owner, ("fixture-user", "fixture-workspace"))
        self.assertFalse(os.get_inheritable(lease.auth_fd))
        self.assertFalse(os.get_inheritable(lease.lock_fd))
        lock = (self.directory / ".draft.lock").stat()
        lease.close()
        lease.close()
        self.assertTrue(self.path.read_bytes() == self.original, "Auth changed on close")
        self.assertEqual((self.directory / ".draft.lock").stat().st_ino, lock.st_ino)

    def test_refresh_preserves_owner_and_next_lease_reads_replacement(self):
        lease = self.lease()
        self.write(fixture.bundle(1))
        lease.check()
        lease.settle()
        lease.close()
        self.assertTrue(json.loads(self.path.read_bytes()) == fixture.bundle(1), "Refresh lost")
        self.lease(expected_owner=("fixture-user", "fixture-workspace")).settle()

    def test_other_process_is_busy_before_auth_read(self):
        self.lease()
        child = '''import importlib.util, sys
spec = importlib.util.spec_from_file_location("auth", sys.argv[1])
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)
def forbidden(*args):
    raise AssertionError("contender read credentials")
auth.review._read_fd = forbidden
try:
    auth.Lease(sys.argv[2])
except auth.Refused as error:
    assert str(error) == "auth_busy"
else:
    raise AssertionError("contender acquired lease")
'''
        result = subprocess.run([sys.executable, "-I", "-B", "-c", child,
            str(ROOT / "scripts/nvim-ai-codex-auth.py"), str(self.directory)],
            capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_close_does_not_unlock_a_borrowed_descriptor(self):
        lease = self.lease()
        duplicate = os.dup(lease.lock_fd)
        try:
            lease.close()
            self.refused("auth_busy")
        finally:
            os.close(duplicate)
        self.lease()

    def test_identity_changes_and_missing_identity_refuse(self):
        for changes in ({"user_id": "other"}, {"workspace_id": "other"}):
            with self.subTest(changes=changes):
                self.write(fixture.bundle(**changes))
                self.refused("auth_identity", expected_owner=("fixture-user", "fixture-workspace"))
        for field in ("user_id", "workspace_id"):
            for value in (None, "", "  ", 3, [], "x\x00y", "x\x7fy", "x\x85y", "é" * 513):
                with self.subTest(field=field, value=value):
                    self.write(fixture.bundle(**{field: value}))
                    with self.assertRaises(auth.Refused):
                        self.lease()
        self.write(fixture.bundle(user_id="é" * 512, workspace_id="x" * 1024))
        self.lease().settle()

    def test_preferred_and_fallback_user_claim(self):
        for preferred in (None, "absent", "preferred", ""):
            value = fixture.bundle()
            claim = {"user_id": "fallback"}
            if preferred != "absent":
                claim["chatgpt_user_id"] = preferred
            value["tokens"]["id_token"] = "e30." + fixture.encoded({fixture.CLAIM: claim}) + ".sig"
            if preferred == "":
                with self.assertRaisesRegex(auth.Refused, "auth_identity"):
                    auth.chatgpt_owner(value)
            else:
                self.assertEqual(auth.chatgpt_owner(value),
                    ("preferred" if preferred == "preferred" else "fallback", "fixture-workspace"))

    def test_invalid_claim_encoding_and_json_budgets(self):
        raw_claims = [b'{"x":1,"x":2}', b"[" * 33 + b"0" + b"]" * 33,
                      b"[" + b"0," * 8192 + b"0]", b'{"x":"\\ud800"}', b'null', b'[]']
        payloads = ["A", "%%%", "a=b", *[base64.urlsafe_b64encode(raw).decode().rstrip("=")
                                            for raw in raw_claims]]
        for payload in payloads:
            value = fixture.bundle()
            value["tokens"]["id_token"] = "e30." + payload + ".sig"
            with self.subTest(payload_length=len(payload)), self.assertRaises(auth.Refused):
                auth.chatgpt_owner(value)
        for raw in (b'{"OPENAI_API_KEY":"a","OPENAI_API_KEY":"b"}', b'{}',
                    b"[" * 33 + b"0" + b"]" * 33):
            with self.assertRaisesRegex(auth.Refused, "credentials"):
                auth.validate(raw)

    def test_exact_file_budget(self):
        self.path.write_bytes(self.original + b" " * (1024 * 1024 - len(self.original)))
        self.lease().close()
        with self.path.open("ab") as output:
            output.write(b" ")
        self.refused()

    def test_api_keys_are_not_owned_chatgpt_credentials(self):
        self.write({"OPENAI_API_KEY": "synthetic-key"})
        self.refused("auth_identity")

    def test_file_and_lock_types_modes_and_links(self):
        self.lease().close()
        for name in ("auth.json", ".draft.lock"):
            target = self.directory / name
            for kind in ("symlink", "hardlink", "fifo", "directory", "0644", "0666"):
                with self.subTest(name=name, kind=kind):
                    saved = self.parent / "saved"
                    target.rename(saved)
                    if kind == "symlink":
                        target.symlink_to(saved)
                    elif kind == "hardlink":
                        os.link(saved, target)
                    elif kind == "fifo":
                        os.mkfifo(target, 0o600)
                    elif kind == "directory":
                        target.mkdir(mode=0o700)
                    else:
                        target.write_bytes(saved.read_bytes())
                        target.chmod(int(kind, 8))
                    try:
                        self.refused()
                    finally:
                        target.rmdir() if kind == "directory" else target.unlink()
                        saved.rename(target)

    def test_directory_path_and_ownership(self):
        for directory in (str(self.directory) + "/", str(self.directory) + "/../dedicated login",
                          str(self.parent / "missing"), "/", "relative", None):
            with self.subTest(directory=directory), self.assertRaises(auth.Refused):
                auth.Lease(directory)
        alias = self.parent / "alias"
        alias.symlink_to(self.directory)
        with self.assertRaises(auth.Refused):
            auth.Lease(str(alias))
        self.directory.chmod(0o755)
        self.refused()
        self.directory.chmod(0o700)
        original = auth.os.getuid()
        with mock.patch.object(auth.os, "getuid", return_value=original + 1):
            self.refused()

    def test_active_replacements_and_mutable_bytes(self):
        lease = self.lease()
        self.path.write_bytes(b"")
        lease.check()  # The upstream writer truncates before writing.
        with self.assertRaisesRegex(auth.Refused, "auth_persistence"):
            lease.settle()
        self.assertEqual(self.path.read_bytes(), b"")
        self.write(fixture.bundle())
        saved = self.parent / "saved"
        for name in ("auth.json", ".draft.lock"):
            target = self.directory / name
            target.rename(saved)
            target.write_bytes(b"")
            target.chmod(0o600)
            try:
                with self.assertRaises(auth.Refused):
                    lease.check()
            finally:
                target.unlink()
                saved.rename(target)
        self.directory.rename(saved)
        self.directory.mkdir(mode=0o700)
        try:
            with self.assertRaises(auth.Refused):
                lease.check()
        finally:
            self.directory.rmdir()
            saved.rename(self.directory)

    def test_settlement_identity_and_sync_failures_keep_latest_file(self):
        lease = self.lease()
        self.write(fixture.bundle(1, user_id="different"))
        with self.assertRaisesRegex(auth.Refused, "auth_identity"):
            lease.settle()
        self.write(fixture.bundle(2))
        with mock.patch.object(auth.os, "fsync", side_effect=OSError("PRIVATE FAILURE")):
            with self.assertRaisesRegex(auth.Refused, "^auth_persistence$"):
                lease.settle()
        self.assertTrue(json.loads(self.path.read_bytes()) == fixture.bundle(2), "Latest auth lost")

    def test_read_race_and_partial_construction_do_not_leak_descriptors(self):
        before = len(os.listdir("/proc/self/fd"))
        reader = auth.review._read_fd
        def replace(*args):
            raw = reader(*args)
            self.path.unlink()
            self.write(fixture.bundle())
            return raw
        for _ in range(10):
            with mock.patch.object(auth.review, "_read_fd", side_effect=replace):
                self.refused()
            self.lease().close()
        self.assertEqual(len(os.listdir("/proc/self/fd")), before)

    def test_supervisor_holds_lease_until_detached_writer_exits(self):
        def descendants(pid):
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
            result = [int(child) for child in children]
            for child in list(result):
                result.extend(descendants(child))
            return result

        for action in ("normal", "TERM", "KILL", "owner-startup", "owner-turn"):
            with self.subTest(action=action), socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                listener.settimeout(8)
                controller = subprocess.Popen([sys.executable, "-I", "-B", __file__,
                    "--lease-controller", str(self.directory), str(listener.getsockname()[1]), action],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                channel, pidfd = None, None
                try:
                    channel, _ = listener.accept()
                    channel.settimeout(5)
                    self.assertEqual(channel.recv(1), b"R")
                    self.assertTrue(select.select([controller.stdout], [], [], 5)[0], "Controller handshake missing")
                    info = json.loads(controller.stdout.readline())
                    writers = [pid for pid in descendants(info["pid"])
                        if Path(f"/proc/{pid}/status").read_text().split("NSpid:")[1]
                            .splitlines()[0].split()[-1] == str(info["writer_pid"])]
                    self.assertEqual(len(writers), 1)
                    pidfd = os.pidfd_open(writers[0])
                    self.refused("auth_busy")
                    controller.stdin.write(b"release\n")
                    controller.stdin.flush()
                    self.assertTrue(select.select([controller.stdout], [], [], 5)[0])
                    self.assertEqual(controller.stdout.readline(), b"released\n")
                    self.refused("auth_busy")  # Only the supervisor retains the lock now.
                    channel.sendall(b"P")
                    self.assertEqual(channel.recv(1), b"W")
                    self.assertFalse(select.select([pidfd], [], [], 0)[0])
                    if action.startswith("owner-"):
                        controller.kill()
                    elif action in ("TERM", "KILL"):
                        os.kill(info["pid"], signal.SIGTERM if action == "TERM" else signal.SIGKILL)
                        controller.stdin.write(b"stop\n")
                        controller.stdin.flush()
                    else:
                        controller.stdin.write(b"stop\n")
                        controller.stdin.flush()
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            lease = auth.Lease(str(self.directory))
                            break
                        except auth.Refused as error:
                            self.assertEqual(str(error), "auth_busy")
                            self.assertLess(time.monotonic(), deadline, "Lease survived writer exit")
                            select.select([pidfd], [], [], .01)
                    try:
                        self.assertTrue(select.select([pidfd], [], [], 0)[0], "Lease released before writer death")
                        self.assertEqual(channel.recv(1), b"", "Descendant still owns write authority")
                        lease.settle()
                    finally:
                        lease.close()
                    self.assertTrue(self.path.read_bytes() == self.original, "Lifetime test changed auth")
                    controller.wait(timeout=5)
                    if not action.startswith("owner-"):
                        self.assertEqual(controller.returncode, 0, controller.stderr.read().decode())
                finally:
                    if controller.poll() is None:
                        controller.kill()
                    controller.communicate(timeout=5)
                    if channel is not None:
                        channel.close()
                    if pidfd is not None:
                        os.close(pidfd)


def lease_controller(directory, port, action):
    storage = load(ROOT / "scripts/nvim-ai-codex-store.py")
    runtime = load(ROOT / "scripts/nvim-ai-codex-runtime.py")
    with tempfile.TemporaryDirectory(prefix="draft-lease-controller-", dir=str(Path(directory).parent)) as name:
        parent = Path(name)
        peer = parent / "codex"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_codex.py", peer)
        peer.chmod(0o700)
        host = peer.with_name("codex-code-mode-host")
        host.write_text("#!/bin/sh\nexit 0\n")
        host.chmod(0o700)
        (parent / "staging").mkdir(mode=0o700)
        store = storage.Store(parent)
        store.initialize(auth_store=directory)
        store.acquire_auth()
        command, env = runtime.sandbox({"codex": str(peer), "bwrap": os.path.realpath(shutil.which("bwrap")),
            "model": "openai/gpt-5.4"}, parent, store)
        worker = store.start(command, env=env, stop_timeout=.2)
        info = worker.request("fixture/hold-writer", {"port": int(port)})
        if action == "owner-turn":
            worker.request("initialize", {})
            worker.request("fixture/blocked", {})
        print(json.dumps(dict(info, pid=worker.child.pid)), flush=True)
        assert input() == "release"
        store._release_auth()  # Deliberately drop every controller-owned credential descriptor.
        print("released", flush=True)
        assert input() == "stop"
        try:
            store.stop(outcome="completed")
        except storage.Refused:
            assert action in ("TERM", "KILL")
        store.close()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--lease-controller"]:
        lease_controller(*sys.argv[2:])
    else:
        unittest.main()
