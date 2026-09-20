"""Production controller exercised through separate processes and private pipes."""
import json
import hashlib
import ctypes
import fcntl
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import select
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import time
import threading
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

    def test_queued_raw_bytes_are_charged_across_separate_input_drains(self):
        spec = importlib.util.spec_from_file_location("queued_controller", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        frames = []
        for number in range(1, 4):
            value = self.close_frame()
            value["serial"] = number
            value["command"].update(kind="start", turn_id=number, worker_generation=number,
                message="explicit message", sources=[{"path": "example.txt", "snapshot_sha256": "b" * 64}])
            frames.append(module.protocol.decode_command(json.dumps(value).encode() + b' ' * 900000))
        pipe = SimpleNamespace(read_ready=lambda: [frames.pop(0)])
        controller = module.Controller({}, pipe)
        controller.collect()
        controller.collect()
        with self.assertRaisesRegex(module.protocol.Refused, "pending input budget"):
            controller.collect()


class EngineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.previous_subreaper = ctypes.c_int()
        if (cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0
                or cls.libc.prctl(36, 1, 0, 0, 0) != 0):
            raise OSError(ctypes.get_errno(), "Cannot own test orphan reaping")

    @classmethod
    def tearDownClass(cls):
        if cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Cannot restore subreaper state")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-engine-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.scratch = Path(self.directory.name)
        self.root = self.scratch / "project"
        self.root.mkdir(mode=0o700)
        self.source = self.root / "example.txt"
        self.source.write_bytes(b"original text\n")
        self.source.chmod(0o644)
        self.selection = ["example.txt"]
        self.peer = self.scratch / "opencode"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_acp.py", self.peer)
        self.peer.chmod(0o700)
        self.audit, self.events, self.buffer = [], [], bytearray()
        audit = self.audit
        self.gate = threading.Event()
        gate = self.gate

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                value = json.loads(self.rfile.readline())
                audit.append(value)
                if value.get("ready") in ("held-answer", "slow-exit", "held-edit", "freeze-cancel"):
                    gate.wait(timeout=15)
                    self.wfile.write(b'continue\n')

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.config = self.scratch / "config.json"
        self.serial = 0
        self.turn = 0

    def stop_server(self):
        self.gate.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def spawn(self, case="answer", fault=None, auth_file=None):
        configuration = {"opencode": str(self.peer),
            "bwrap": os.path.realpath(shutil.which("bwrap")), "model": "fixture/model",
            "provider": {"fixture": {"options": {"testCase": case, "auditPort": self.server.server_address[1]}}}}
        if auth_file:
            configuration["auth_file"] = str(auth_file)
        self.config.write_text(json.dumps(configuration))
        self.config.chmod(0o600)
        controller = [str(ROOT / "tests/fixtures/ai/conversation_fault_controller.py"), fault] if fault else [str(SCRIPT)]
        self.child = subprocess.Popen([sys.executable, "-I", "-B", *controller, "--config", str(self.config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "NVIM_STAGED_SENTINEL": "private"}, umask=0o077)
        self.addCleanup(self.stop)

    def stop(self):
        self.gate.set()
        if self.child.poll() is None:
            self.child.stdin.close()
            try:
                self.child.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        for stream in (self.child.stdin, self.child.stdout, self.child.stderr):
            stream.close()

    def send(self, kind, *, model="fixture/model", **extra):
        self.serial += 1
        if kind in ("start", "revise"):
            self.turn += 1
            extra.setdefault("message", "Answer without editing.")
            extra.setdefault("sources", [{"path": path,
                "snapshot_sha256": hashlib.sha256((self.root / path).read_bytes()).hexdigest()} for path in self.selection])
        command = dict(kind=kind, conversation_id="a" * 32, owner_generation=1,
            turn_id=self.turn, worker_generation=self.turn, root=str(self.root),
            selection=self.selection, model=model, **extra)
        self.child.stdin.write(json.dumps({"version": 1, "serial": self.serial, "command": command}).encode() + b'\n')
        self.child.stdin.flush()

    def receive(self, kind, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                raw, _, remaining = self.buffer.partition(b'\n')
                self.buffer = bytearray(remaining)
                event = json.loads(raw)["event"]
                self.events.append(event)
                if "review_ref" in event:
                    directory = Path(event["review_ref"]["manifest"]).parent
                    self.addCleanup(lambda directory=directory: shutil.rmtree(directory) if directory.exists() else None)
                if event["kind"] == kind:
                    return event
            if select.select([self.child.stdout], [], [], min(.1, max(0, deadline - time.monotonic())))[0]:
                data = os.read(self.child.stdout.fileno(), 65536)
                if not data:
                    self.child.wait(timeout=3)
                    self.fail("Controller closed before " + kind + ": " + self.child.stderr.read().decode())
                self.buffer.extend(data)
        self.fail("Controller timed out before " + kind)

    def test_answer_finishes_without_proposal(self):
        self.spawn()
        self.send("start")
        settled = self.receive("settled")
        self.assertEqual(settled["outcome"], "answer")
        self.assertTrue(settled["stopped"] and settled["graceful"] and settled["store_valid"])
        self.assertNotIn("proposal", settled)
        self.assertNotIn("review_ref", settled)
        self.assertEqual([event["text"] for event in self.events if event["kind"] == "text"], ["A bounded answer."])
        self.assertEqual([event["status"] for event in self.events if event["kind"] == "progress"], ["completed"])
        self.assertEqual([item["method"] for item in self.audit if "method" in item], ["initialize", "session/new",
            "session/set_config_option", "session/set_config_option", "session/prompt"])
        self.assertIn({"exiting": True}, self.audit)
        self.assertEqual(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip(), "")
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.send("close")
        self.assertTrue(self.receive("closed")["cleaned"])
        self.child.wait(timeout=3)
        self.assertEqual(self.child.returncode, 0)

    def test_handshake_and_option_refusals_never_submit_a_prompt(self):
        for case in ("wrong-version", "missing-resume", "missing-model", "missing-mode", "wrong-confirmation"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertFalse(any(item.get("method") == "session/prompt" for item in self.audit))
                self.stop()

    def test_foreign_session_updates_and_unsuccessful_stop_never_freeze(self):
        for case in ("wrong-session", "bad-stop"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertNotIn("proposal", event)
                self.stop()

    def wait_ready(self, case):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if any(item.get("ready") == case for item in self.audit):
                return
            threading.Event().wait(.01)
        self.fail("ACP readiness marker not received: " + case)

    def test_normal_and_flooded_generation_cancel_cleanly(self):
        for case in ("cancel", "flood-cancel"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                self.receive("submitted")
                self.wait_ready(case)
                started = time.monotonic()
                self.send("cancel")
                event = self.receive("cancelled")
                self.assertTrue(event["cancel_confirmed"] and event["store_valid"] and event["tokens_retired"])
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(self.source.read_bytes(), b"original text\n")
                self.stop()

    def test_startup_and_backpressured_prompt_cancel_require_recovery(self):
        for case in ("startup-cancel", "blocked-prompt"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start", message="é" * 16000)
                self.wait_ready(case)
                started = time.monotonic()
                self.send("cancel")
                event = self.receive("cancelled")
                self.assertTrue(event["stopped"] and event["tokens_retired"])
                self.assertFalse(event["store_valid"])
                self.assertFalse(event.get("cancel_confirmed", False))
                self.assertLess(time.monotonic() - started, 4.2)
                self.assertFalse(any(item.get("method") == "session/prompt" for item in self.audit))
                self.stop()

    def test_different_models_resume_one_session_with_fresh_workers(self):
        self.spawn("held-answer")
        workers, tasks = [], []
        for model in ("fixture/model", "fixture/second-model"):
            self.audit[:] = [item for item in self.audit if "ready" not in item]
            self.gate.clear()
            self.send("start", model=model)
            submitted = self.receive("submitted")
            self.assertEqual(submitted["model"], model)
            self.assertEqual(submitted["models"], ["fixture/model", "fixture/second-model"])
            self.wait_ready("held-answer")
            pid = int(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip())
            workers.append(pid)
            args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b'\0')
            tasks.append(next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/staging')))
            self.gate.set()
            self.assertEqual(self.receive("settled")["outcome"], "answer")
            self.assertFalse(Path(f"/proc/{pid}").exists())
            self.assertFalse(tasks[-1].exists())
        self.assertNotEqual(*workers)
        self.assertNotEqual(*tasks)
        methods = [item["method"] for item in self.audit if "method" in item]
        self.assertEqual(methods.count("session/new"), 1)
        self.assertEqual(methods.count("session/resume"), 1)
        self.assertEqual(methods.count("session/prompt"), 2)
        resumes = [item["params"]["sessionId"] for item in self.audit if item.get("method") == "session/resume"]
        self.assertEqual(resumes, ["fixture-session"])
        choices = [item["params"]["value"] for item in self.audit
                   if item.get("method") == "session/set_config_option" and item["params"]["configId"] == "model"]
        self.assertEqual(choices, ["fixture/model", "fixture/second-model"])
        profiles = [item for item in self.audit if "profile_inode" in item]
        self.assertNotEqual(profiles[0]["listener_key_hash"], profiles[1]["listener_key_hash"])

    def test_changed_catalog_and_unconfirmed_switch_never_submit_or_replace_session(self):
        for case in ("switch-model-removed", "switch-unconfirmed"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                self.assertEqual(self.receive("settled")["outcome"], "answer")
                self.send("start", model="fixture/second-model")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertEqual(event["submission"], "not_submitted")
                self.assertFalse(event["store_valid"], "failed negotiation cannot claim resumable context")
                self.assertFalse(any(item["kind"] == "submitted" and item["turn_id"] == 2 for item in self.events))
                methods = [item.get("method") for item in self.audit]
                self.assertEqual(methods.count("session/prompt"), 1)
                self.assertEqual(methods.count("session/new"), 1)
                self.assertEqual(methods.count("session/resume"), 1)
                attempted = [item["params"]["value"] for item in self.audit
                             if item.get("method") == "session/set_config_option" and item["params"]["configId"] == "model"]
                self.assertEqual(attempted, ["fixture/model"] if case == "switch-model-removed"
                                 else ["fixture/model", "fixture/second-model"])
                self.assertEqual(self.source.read_bytes(), b"original text\n")
                self.stop()

    def test_missing_auth_on_next_turn_never_starts_a_worker_or_sends(self):
        auth = self.scratch / "fixture-auth.json"
        auth.write_text(json.dumps({"fixture": {"type": "api", "key": "synthetic-fixture-only"}}))
        auth.chmod(0o600)
        self.spawn(auth_file=auth)
        self.send("start")
        self.assertEqual(self.receive("settled")["outcome"], "answer")
        before = list(self.audit)
        auth.unlink()
        self.send("start", model="fixture/second-model")
        event = self.receive("settled")
        self.assertEqual(event["outcome"], "failed")
        self.assertEqual(event["submission"], "not_submitted")
        self.assertEqual(self.audit, before, "missing copied auth must refuse before worker launch")
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_clean_cancellation_can_resume_but_resume_failure_never_falls_back(self):
        for case in ("cancel", "resume-fails"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                if case == "cancel":
                    self.receive("submitted")
                    self.wait_ready(case)
                    self.send("cancel")
                    self.assertTrue(self.receive("cancelled")["store_valid"])
                else:
                    self.assertEqual(self.receive("settled")["outcome"], "answer")
                self.send("start")
                if case == "cancel":
                    self.receive("submitted")
                    self.send("cancel")
                    self.assertTrue(self.receive("cancelled")["store_valid"])
                else:
                    self.assertEqual(self.receive("settled")["outcome"], "failed")
                methods = [item.get("method") for item in self.audit]
                self.assertEqual(methods.count("session/new"), 1)
                self.assertEqual(methods.count("session/resume"), 1)
                self.assertEqual(methods.count("session/prompt"), 2 if case == "cancel" else 1)
                self.stop()

    def worker_paths(self, controller=None):
        controller = controller or self.child.pid
        pid = int(Path(f"/proc/{controller}/task/{controller}/children").read_text().strip())
        args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b'\0')
        task = next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/staging'))
        store = next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/backend-store'))
        return pid, task, store

    def test_real_neovim_eof_closes_the_production_factory_and_worker(self):
        self.check_editor_eof("conversation_production_editor.lua")

    def test_public_chat_editor_eof_closes_controller_and_worker(self):
        self.check_editor_eof("chat_production_editor.lua")

    def test_public_chat_editor_sigkill_retains_only_private_launch_configuration(self):
        self.check_editor_eof("chat_production_editor.lua", abrupt=True)

    def check_editor_eof(self, fixture, *, abrupt=False):
        nvim = shutil.which("nvim")
        self.assertIsNotNone(nvim)
        gate = self.scratch / "editor-exit"
        self.config.write_text(json.dumps({"root": str(self.root), "selection": self.selection,
            "opencode": str(self.peer), "model": "fixture/model",
            "provider": {"fixture": {"options": {"testCase": "cancel", "auditPort": self.server.server_address[1]}}}}))
        self.config.chmod(0o600)
        env = {"PATH": str(Path(nvim).parent) + os.pathsep + os.defpath, "LANG": "C.UTF-8",
            "DRAFT_EDITOR_CONFIG": str(self.config), "DRAFT_EDITOR_GATE": str(gate),
            "DRAFT_TEST_ROOT": str(ROOT), "NVIM_LOG_FILE": "/dev/null"}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            path = self.scratch / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        editor = subprocess.Popen([nvim, "--clean", "--headless", "-u", "NONE", "-i", "NONE",
            "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)", "-l",
            str(ROOT / "tests/fixtures/ai" / fixture)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, umask=0o077)
        owned = []
        try:
            self.wait_ready("cancel")
            controller = int(Path(f"/proc/{editor.pid}/task/{editor.pid}/children").read_text().strip())
            controller_fd = os.pidfd_open(controller)
            owned.append((controller, controller_fd))
            args = Path(f"/proc/{controller}/cmdline").read_bytes().split(b'\0')
            launch = Path(os.fsdecode(args[args.index(b'--config') + 1]))
            launch_bytes = launch.read_bytes()
            launch_stat = launch.lstat()
            worker, task, store = self.worker_paths(controller)
            worker_fd = os.pidfd_open(worker)
            owned.append((worker, worker_fd))
            if abrupt:
                editor.kill()
            else:
                gate.touch()
            out, error = editor.communicate(timeout=12)
            self.assertEqual(editor.returncode, -signal.SIGKILL if abrupt else 0, out + error)
            self.assertTrue(select.select([controller_fd], [], [], 12)[0], "Controller survived editor EOF")
            self.assertTrue(select.select([worker_fd], [], [], 0)[0], "Worker survived its controller")
            remaining = [str(path) for path in (task, store) if path.exists()]
            self.assertFalse(remaining, remaining)
            self.assertEqual(self.source.read_bytes(), b"original text\n")
            if abrupt:
                # The killed editor cannot run its Lua-owned exit callback.
                # The controller owns the stopped worker/store, not this path.
                self.assertEqual(list(launch.parent.iterdir()), [launch])
                node = launch.lstat()
                self.assertEqual((node.st_dev, node.st_ino),
                                 (launch_stat.st_dev, launch_stat.st_ino))
                self.assertEqual(node.st_mode & 0o7777, 0o600)
                self.assertEqual((node.st_uid, node.st_nlink), (os.getuid(), 1))
                self.assertEqual(launch.parent.stat().st_mode & 0o7777, 0o700)
                self.assertEqual(launch.read_bytes(), launch_bytes)
                # Test-owned artifact, removed only after process/identity proof.
                launch.unlink()
                launch.parent.rmdir()
            else:
                self.assertFalse(launch.parent.exists(), str(launch.parent))
        finally:
            if editor.poll() is None:
                editor.kill()
            editor.communicate(timeout=3)
            for pid, fd in owned:
                if not select.select([fd], [], [], 0)[0]:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
                os.close(fd)

    def test_changed_missing_and_oversized_idle_stores_never_launch_again(self):
        for damage in ("changed", "missing", "oversized"):
            with self.subTest(damage=damage):
                self.serial = self.turn = 0
                self.audit.clear()
                self.gate.clear()
                self.spawn("held-answer")
                self.send("start")
                self.wait_ready("held-answer")
                _, _, store = self.worker_paths()
                self.gate.set()
                self.assertEqual(self.receive("settled")["outcome"], "answer")
                db = store / "backend-store/opencode.db"
                if damage == "missing":
                    db.unlink()
                elif damage == "changed":
                    db.write_bytes(b"changed private artifact")
                else:
                    with db.open("r+b") as stream:
                        stream.truncate(65 * 1024 * 1024)
                self.send("start")
                self.assertEqual(self.receive("settled")["outcome"], "failed")
                self.assertEqual([item.get("method") for item in self.audit].count("session/prompt"), 1)
                self.assertEqual([item.get("method") for item in self.audit].count("initialize"), 1)
                self.stop()
                self.assertFalse(store.exists())

    def test_editor_eof_stops_workers_before_discarding_owned_state(self):
        for case in ("startup-cancel", "cancel", "slow-exit", "held-answer", "held-edit"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.gate.clear()
                self.spawn(case)
                self.send("start")
                self.wait_ready(case)
                pid, task, store = self.worker_paths()
                worker_fd = os.pidfd_open(pid)
                try:
                    self.child.stdin.close()
                    self.gate.set()
                    self.child.wait(timeout=10)
                    self.assertTrue(select.select([worker_fd], [], [], 0)[0])
                    self.assertFalse(task.exists())
                    self.assertFalse(store.exists())
                    self.assertEqual(self.source.read_bytes(), b"original text\n")
                finally:
                    os.close(worker_fd)
                self.stop()

    def test_editor_eof_when_idle_discards_store_without_another_worker(self):
        self.spawn("held-answer")
        self.send("start")
        self.wait_ready("held-answer")
        _, task, store = self.worker_paths()
        self.gate.set()
        self.receive("settled")
        self.child.stdin.close()
        self.child.wait(timeout=3)
        self.assertFalse(task.exists() or store.exists())
        self.assertEqual([item.get("method") for item in self.audit].count("initialize"), 1)

    def test_blocked_editor_output_also_reaps_a_live_worker(self):
        self.spawn("output-blocked")
        self.send("start")
        self.wait_ready("output-blocked")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.child.wait(timeout=9)
            self.assertNotEqual(self.child.returncode, 0)
            self.assertTrue(select.select([worker_fd], [], [], 0)[0])
            self.assertFalse(task.exists() or store.exists())
        finally:
            os.close(worker_fd)

    def test_output_deadline_interrupts_a_blocked_acp_client_reply(self):
        self.spawn("both-blocked")
        # Keep the unread editor pipe smaller than the peer's single text chunk.
        fcntl.fcntl(self.child.stdout, fcntl.F_SETPIPE_SZ, 4096)
        self.send("start")
        self.wait_ready("both-blocked")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.child.wait(timeout=10)
            self.assertNotEqual(self.child.returncode, 0)
            self.assertTrue(select.select([worker_fd], [], [], 0)[0])
            self.assertFalse(task.exists() or store.exists())
        finally:
            os.close(worker_fd)

    def test_text_streams_and_close_interrupts_a_blocked_acp_client_reply(self):
        self.spawn("both-blocked")
        fcntl.fcntl(self.child.stdout, fcntl.F_SETPIPE_SZ, 4096)
        self.send("start")
        self.wait_ready("both-blocked")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.assertEqual(self.receive("text", seconds=3)["text"], "x" * 8192)
            self.send("close")
            self.assertTrue(self.receive("closed", seconds=6)["cleaned"])
            self.child.wait(timeout=3)
            self.assertEqual(self.child.returncode, 0)
            self.assertEqual(sum(event["kind"] == "text" for event in self.events), 1)
            self.assertTrue(select.select([worker_fd], [], [], 0)[0])
            self.assertFalse(task.exists() or store.exists())
        finally:
            os.close(worker_fd)

    def test_controller_death_reaps_descendant_held_pipe_and_retains_unadopted_evidence(self):
        self.spawn("descendant")
        self.send("start")
        self.receive("submitted")
        self.wait_ready("descendant")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.child.kill()
            self.child.wait(timeout=3)
            self.assertTrue(select.select([worker_fd], [], [], 5)[0], "Owned namespace survived controller death")
            self.assertEqual(os.waitpid(pid, 0)[0], pid)
            # Test-only ownership, matching the lifetime suite: this process has
            # no other live subprocesses, only this controller's adopted tree.
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    adopted, _ = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if not adopted:
                    time.sleep(.01)
            else:
                self.fail("Owned descendant was not reaped")
            self.assertTrue(task.exists() and store.exists())
            self.assertEqual(self.source.read_bytes(), b"original text\n")
            shutil.rmtree(task)
            shutil.rmtree(store)
        finally:
            os.close(worker_fd)

    def test_frozen_review_is_exposed_only_after_worker_exit_and_real_receipt(self):
        self.spawn("edit")
        self.send("start")
        event = self.receive("settled")
        self.assertEqual(event["outcome"], "review")
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertEqual(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip(), "")
        ref = event["review_ref"]
        inspected = self.publisher("inspect-review", ref)
        self.assertEqual(inspected["files"][0]["newText"], "proposed edit\n")
        result = self.publisher("approve", ref, "example.txt")
        self.assertEqual(result["phase"], "applied")
        self.send("decide", choice="approve", path="example.txt", round_id=1, proposal_revision=1,
                  proposal_token=ref["token"], receipt_sequence=0)
        receipt = self.receive("decided")["receipt"]
        self.assertEqual(receipt["phase"], "applied")
        self.assertEqual(receipt["sequence"], 1)
        self.assertEqual(self.source.read_bytes(), b"proposed edit\n")

    def publisher(self, operation, ref, path=None):
        argv = [sys.executable, "-I", "-B", str(ROOT / "scripts/nvim-ai-staged.py"), operation,
                "--proposal", ref["manifest"], "--id", ref["token"]]
        if path is not None:
            argv += ["--path", path]
        result = subprocess.run(argv, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_revision_retires_old_authority_and_preserves_accepted_files(self):
        self.selection.append("second.txt")
        (self.root / "second.txt").write_bytes(b"original text\n")
        (self.root / "second.txt").chmod(0o644)
        self.spawn("edit")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        self.assertEqual(self.publisher("approve", ref, "example.txt")["phase"], "review_ready")
        identity = dict(round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
        self.send("decide", choice="approve", path="example.txt", **identity)
        receipt = self.receive("decided")["receipt"]
        identity["receipt_sequence"] = 1
        context = dict(identity, files=receipt["decisions"])
        self.send("revise", message="Revise the pending file.", context=context, **identity)
        revised = self.receive("settled")
        self.assertEqual(revised["outcome"], "review")
        new_ref = revised["review_ref"]
        self.assertNotEqual(ref["token"], new_ref["token"])
        self.assertEqual(revised["prior_review"]["status"], "retired")
        self.assertEqual([item["editable_paths"] for item in self.audit if "editable_paths" in item][-1], ["second.txt"])
        self.assertEqual(self.source.read_bytes(), b"proposed edit\n")
        self.assertNotEqual(self.publisher("approve", ref, "second.txt")["phase"], "applied")
        self.assertEqual((self.root / "second.txt").read_bytes(), b"original text\n")
        self.publisher("reject", new_ref, "second.txt")
        self.send("decide", choice="reject", path="second.txt", round_id=1, proposal_revision=2,
                  proposal_token=new_ref["token"], receipt_sequence=0)
        receipt = self.receive("decided")["receipt"]
        self.assertEqual(receipt["phase"], "applied")
        self.assertEqual([item["state"] for item in receipt["decisions"]], ["accepted", "rejected"])

    def test_discussion_preserves_review_but_reverting_seed_replaces_it(self):
        self.spawn("edit")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        identity = dict(round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
        context = dict(identity, files=first["proposal"]["files"])
        self.send("revise", message="Discuss the current proposal.", context=context, **identity)
        discussed = self.receive("settled")
        self.assertEqual(discussed["outcome"], "answer")
        self.assertEqual(discussed["prior_review"]["status"], "active")
        self.assertTrue(discussed["candidates_retired"])
        self.assertEqual(self.publisher("inspect-review", ref)["phase"], "review_ready")
        self.send("revise", message="Revert the proposed change.", context=context, **identity)
        reverted = self.receive("settled")
        self.assertEqual(reverted["outcome"], "review")
        self.assertEqual(reverted["prior_review"]["status"], "retired")
        self.assertEqual(reverted["proposal"]["files"], [{"path": "example.txt", "state": "unchanged"}])
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_invalid_revision_workspace_restores_only_the_original_review(self):
        self.spawn("edit")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        identity = dict(round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
        self.send("revise", message="Try an extra-file.", context=dict(identity, files=first["proposal"]["files"]), **identity)
        event = self.receive("settled")
        self.assertEqual(event["outcome"], "failed")
        self.assertEqual(event["prior_review"]["status"], "active")
        self.assertTrue(event["candidates_retired"])
        self.assertNotIn("tokens_retired", event)
        self.assertEqual(self.publisher("inspect-review", ref)["phase"], "review_ready")

    def test_worker_free_review_cancel_and_close_retire_real_authority(self):
        for kind in ("cancel", "close"):
            with self.subTest(kind=kind):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn("edit")
                self.send("start")
                first = self.receive("settled")
                ref = first["review_ref"]
                self.send(kind, round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
                event = self.receive("cancelled" if kind == "cancel" else "closed")
                self.assertEqual(event["receipt"]["phase"], "cancelled")
                self.assertTrue(event["tokens_retired"])
                self.assertEqual(self.publisher("approve", ref, "example.txt")["phase"], "cancelled")
                self.assertEqual(self.source.read_bytes(), b"original text\n")
                self.assertEqual([item.get("method") for item in self.audit].count("initialize"), 1)
                self.stop()

    def test_later_explicit_message_carries_confirmed_decisions_separately(self):
        self.spawn("edit")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        self.publisher("reject", ref, "example.txt")
        self.send("decide", choice="reject", path="example.txt", round_id=1, proposal_revision=1,
                  proposal_token=ref["token"], receipt_sequence=0)
        self.assertEqual(self.receive("decided")["receipt"]["phase"], "rejected")
        self.send("start", message="Discuss the saved source.")
        self.assertEqual(self.receive("settled")["outcome"], "answer")
        prompt = [item["params"]["prompt"] for item in self.audit if item.get("method") == "session/prompt"][-1]
        self.assertEqual(prompt[-1], {"type": "text", "text": "Discuss the saved source."})
        self.assertIn('"state": "rejected"', prompt[-2]["text"])
        self.assertNotIn("proposed edit", prompt[-2]["text"])

    def test_failed_review_handoff_emits_one_stopping_event_and_valid_restoration(self):
        self.spawn("edit", fault="before-retire")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        identity = dict(round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
        start = len(self.events)
        self.send("revise", message="Revise the proposal.", context=dict(identity, files=first["proposal"]["files"]), **identity)
        event = self.receive("settled")
        self.assertEqual(event["outcome"], "failed")
        self.assertEqual(event["prior_review"]["status"], "active")
        self.assertEqual([item["kind"] for item in self.events[start:]].count("stopping"), 1)

    def test_cancel_after_candidate_freeze_retires_it_before_exposure(self):
        self.spawn("edit", fault="freeze-cancel")
        self.send("start")
        first = self.receive("settled")
        ref = first["review_ref"]
        identity = dict(round_id=1, proposal_revision=1, proposal_token=ref["token"], receipt_sequence=0)
        start = len(self.events)
        self.send("revise", message="Revise the proposal.", context=dict(identity, files=first["proposal"]["files"]), **identity)
        self.wait_ready("freeze-cancel")
        candidate = Path(next(item["candidate"] for item in self.audit if item.get("ready") == "freeze-cancel"))
        self.assertTrue(candidate.exists())
        self.send("cancel", **identity)
        self.gate.set()
        event = self.receive("cancelled")
        self.assertEqual(event["receipt"]["proposal_token"], ref["token"])
        self.assertTrue(event["tokens_retired"] and event["candidates_retired"])
        self.assertFalse(candidate.parent.exists())
        self.assertFalse(any(item.get("outcome") == "review" for item in self.events[start:]))


if __name__ == "__main__":
    unittest.main()
