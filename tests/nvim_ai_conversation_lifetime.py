"""Owner-death proof at process/file seams; optional pinned local-provider run."""
import array
import ctypes
from itertools import chain
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent


class LifetimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Adopt the scratch worker boundary, instead of leaving its zombies to
        # init. This setting affects this standalone test process only.
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.previous_subreaper = ctypes.c_int()
        if (cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0 or
                cls.libc.prctl(36, 1, 0, 0, 0) != 0):
            raise OSError(ctypes.get_errno(), "Cannot own scratch orphan reaping")

    @classmethod
    def tearDownClass(cls):
        if cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Cannot restore test subreaper setting")

    def setUp(self):
        self.parent = Path(tempfile.mkdtemp(prefix="nvim-ai-lifetime-test-", dir="/tmp"))
        self.source = self.parent / "real-source.txt"
        self.source.write_bytes(b"original text\n")
        self.owner, self.worker_pid, self.worker_fd = None, None, None
        self.worker_output = None
        self.output_closed = False
        self.ports = []
        self.reaped = False
        self.addCleanup(self.cleanup)

    def cleanup(self):
        try:
            if self.owner is not None:
                if self.owner.poll() is None:
                    self.owner.kill()
                self.owner.wait(timeout=5)
            if self.worker_fd is not None and not self.reaped:
                try:
                    # Only the pidfd opened for this exact owned supervisor.
                    signal.pidfd_send_signal(self.worker_fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.reap_worker()
            self.drain_output()
            self.reap_adopted()
            if self.owner is not None and not (self.reaped and self.output_closed):
                raise AssertionError("Worker exit unproven; scratch evidence retained: " + str(self.parent))
            for port in self.ports:
                self.assertFalse(self.listening(port), "Listener survived; retain: " + str(self.parent))
            shutil.rmtree(self.parent)
        finally:
            for descriptor in (self.worker_fd, self.worker_output):
                if descriptor is not None:
                    os.close(descriptor)
            if self.owner is not None:
                for stream in (self.owner.stdin, self.owner.stdout, self.owner.stderr):
                    stream.close()

    def start_owner(self, phase="active", *, advance=True):
        observer, owner_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        with observer, owner_end:
            observer.settimeout(5)
            self.owner = subprocess.Popen(
                [sys.executable, "-I", "-B", str(HERE / "fixtures/ai/acp_lifetime_owner.py"),
                 str(self.parent), phase, str(owner_end.fileno())],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(owner_end.fileno(),), start_new_session=True, umask=0o077)
            result = self.owner_message()
            self.worker_pid = result["worker"]
            self.worker_fd = os.pidfd_open(self.worker_pid)
            descriptors = array.array("i")
            _, control, _flags, _ = observer.recvmsg(16, socket.CMSG_SPACE(descriptors.itemsize),
                                                    socket.MSG_CMSG_CLOEXEC)
            self.assertEqual(len(control), 1)
            kind, method, data = control[0]
            self.assertEqual((kind, method), (socket.SOL_SOCKET, socket.SCM_RIGHTS))
            descriptors.frombytes(data)
            self.assertEqual(len(descriptors), 1)
            self.worker_output = descriptors[0]
        if not advance:
            return result
        self.owner.stdin.write(b"start\n")
        self.owner.stdin.flush()
        result.update(self.owner_message())
        self.ports = result["ports"]
        if result.get("settled"):
            self.assertTrue(select.select([self.worker_fd], [], [], 0)[0])
            self.reaped = True  # Store.stop already reaped it in the still-live owner.
        return result

    def owner_message(self):
        self.assertTrue(select.select([self.owner.stdout], [], [], 10)[0], "Owner readiness timed out")
        ready = self.owner.stdout.readline()
        if not ready:
            self.owner.wait(timeout=5)
            self.fail("Owner exited before readiness: " + self.owner.stderr.read().decode())
        return json.loads(ready)

    def assert_not_adopted(self, old_root):
        # Stat-only evidence. Never open even the synthetic backend file bytes.
        def metadata():
            fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_uid", "st_gid",
                      "st_size", "st_mtime_ns", "st_ctime_ns")
            # Directory enumeration can update atime itself. It is not mutation
            # evidence; compare identity and change metadata at full precision.
            return {str(path.relative_to(old_root)): tuple(getattr(node, field) for field in fields)
                    for path in chain((old_root,), old_root.rglob("*")) for node in (path.lstat(),)}

        before = metadata()
        fresh = subprocess.run(
            [sys.executable, "-I", "-B", str(HERE / "fixtures/ai/acp_lifetime_owner.py"),
             str(old_root.parent), "fresh"], capture_output=True, timeout=5, check=True, umask=0o077)
        result = json.loads(fresh.stdout)
        self.assertNotEqual(Path(result["root"]), old_root)
        self.assertEqual(result["artifacts"], {}, "A new owner must never adopt interrupted backend history")
        self.assertFalse(Path(result["root"]).exists(), "Explicit close must remove only the new owner's state")
        self.assertEqual(metadata(), before)

    def reap_worker(self):
        self.assertTrue(select.select([self.worker_fd], [], [], 5)[0], "Worker survived its owner")
        pid, _ = os.waitpid(self.worker_pid, 0)
        self.assertEqual(pid, self.worker_pid)
        self.reaped = True
        self.drain_output()
        self.reap_adopted()

    def drain_output(self):
        if self.worker_output is None or self.output_closed:
            return
        deadline, total = time.monotonic() + 3, 0
        while time.monotonic() < deadline:
            if select.select([self.worker_output], [], [], .05)[0]:
                data = os.read(self.worker_output, 65536)
                if not data:
                    self.output_closed = True
                    return
                total += len(data)
                self.assertLessEqual(total, 32 * 1024 * 1024)
        self.fail("ACP output survived owner death; retain scratch evidence: " + str(self.parent))

    def reap_adopted(self):
        # This standalone test process spawns only the disposable owner and the
        # already-awaited fresh-owner check. After owner exit, any remaining
        # direct children are its adopted test namespace, never user sessions.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                time.sleep(.01)
        self.fail("Adopted test process survived; retain scratch evidence: " + str(self.parent))

    def listening(self, port):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.2):
                return True
        except OSError:
            return False

    def test_killed_owner_stops_active_worker_and_detached_writer_without_publishing(self):
        ready = self.start_owner()
        self.assertEqual(len(ready["ports"]), 2)
        for port in ready["ports"]:
            self.assertTrue(self.listening(port))
        copy = self.parent / "worker/staging/example.txt"
        self.assertEqual(copy.read_bytes(), b"unapproved descendant edit\n")
        self.owner.kill()
        self.assertEqual(self.owner.wait(timeout=5), -signal.SIGKILL)
        self.reap_worker()
        for port in ready["ports"]:
            self.assertFalse(self.listening(port), "Owned listener survived owner death")
        stopped = copy.stat().st_mtime_ns
        time.sleep(.1)  # Only a short observation window, not a synchronization mechanism.
        self.assertEqual(copy.stat().st_mtime_ns, stopped)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        root = Path(ready["root"])
        self.assertEqual(root.parent, self.parent)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        self.assertEqual({p.name: (p.stat().st_size, stat.S_IMODE(p.stat().st_mode))
                          for p in (root / "backend-store").iterdir()},
                         {"opencode.db": (7, 0o600), "opencode.db-wal": (4, 0o600),
                          "opencode.db-shm": (4, 0o600)})
        self.assert_not_adopted(root)

    def test_owner_death_during_shutdown_still_stops_the_entire_worker_boundary(self):
        ready = self.start_owner("stopping")
        deadline = time.monotonic() + 1.5
        eof_marker = self.parent / "worker/staging/eof-seen"
        while not eof_marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(eof_marker.exists(), "Peer must observe real input EOF before owner death")
        for port in ready["ports"]:
            self.assertTrue(self.listening(port), "Test must interrupt a still-live shutdown")
        self.owner.kill()
        self.assertEqual(self.owner.wait(timeout=5), -signal.SIGKILL)
        self.reap_worker()
        for port in ready["ports"]:
            self.assertFalse(self.listening(port))
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertTrue((Path(ready["root"]) / "backend-store/opencode.db").is_file(),
                        "Interrupted shutdown must retain its private evidence")
        self.assert_not_adopted(Path(ready["root"]))

    def test_idle_owner_death_does_not_let_a_new_owner_adopt_its_stopped_store(self):
        ready = self.start_owner("idle")
        self.assertTrue(ready["settled"])
        self.owner.terminate()
        self.assertEqual(self.owner.wait(timeout=5), -signal.SIGTERM)
        backend = Path(ready["root"]) / "backend-store"
        # Synthetic fixture only: force a directory access-time update on the
        # next walk, without modifying any backend artifact or its contents.
        os.utime(backend, ns=(0, backend.stat().st_mtime_ns))
        self.assert_not_adopted(Path(ready["root"]))
        self.assertGreater(backend.stat().st_atime_ns, 0, "This case must exercise observer-induced atime drift")
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_owner_death_before_first_acp_request_leaves_no_running_worker(self):
        ready = self.start_owner(advance=False)
        self.owner.kill()
        self.assertEqual(self.owner.wait(timeout=5), -signal.SIGKILL)
        self.reap_worker()
        root = Path(ready["root"])
        self.assertEqual(list((root / "backend-store").iterdir()), [])
        self.assert_not_adopted(root)
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    @unittest.skipUnless(os.environ.get("NVIM_AI_ACP_REAL_OPENCODE"),
                         "opt-in pinned OpenCode/local-provider owner-death proof")
    def test_real_opencode_owner_death_stops_active_listener_without_resuming(self):
        ready = self.start_owner("real-active")
        self.assertEqual(ready["requests"], 1, "The held stream must come from one explicit local request")
        for port in ready["ports"]:
            self.assertTrue(self.listening(port))
        self.owner.kill()
        self.assertEqual(self.owner.wait(timeout=5), -signal.SIGKILL)
        self.reap_worker()
        for index, port in enumerate(ready["ports"]):
            self.assertFalse(self.listening(port), f"Listener index {index} survived process/pipe shutdown")
        self.assertEqual(Path(ready["source"]).read_bytes(), b"original text\n")
        self.assertEqual(Path(ready["selected"]).read_bytes(), b"original text\n")
        self.assert_not_adopted(Path(ready["root"]))


if __name__ == "__main__":
    unittest.main()
