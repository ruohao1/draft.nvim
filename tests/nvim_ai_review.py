import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "nvim-ai-review.py"
SPEC = importlib.util.spec_from_file_location("nvim_ai_review", HELPER)
review_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review_helper)


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def fingerprint(value=None, mode="100644", kind="regular"):
    if kind == "absent":
        return {"kind": kind, "mode": None, "size": 0, "sha256": None}
    return {"kind": kind, "mode": mode, "size": len(value), "sha256": sha256(value)}


class ReviewFixture:
    def __init__(self, test):
        self.temp = tempfile.TemporaryDirectory(prefix="nvim-ai-review-", dir="/tmp")
        test.addCleanup(self.temp.cleanup)
        self.base = os.fsencode(self.temp.name)
        self.root = self.base + b"/repo"
        self.private = self.base + b"/private"
        os.mkdir(self.root, 0o700)
        os.mkdir(self.private, 0o700)

    def path(self, path):
        return self.root + b"/" + os.fsencode(path)

    def write(self, path, value, mode=0o644):
        target = self.path(path)
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        with open(target, "wb") as stream:
            stream.write(value)
        os.chmod(target, mode)

    def read(self, path):
        with open(self.path(path), "rb") as stream:
            return stream.read()

    def symlink(self, path, target):
        os.makedirs(os.path.dirname(self.path(path)), mode=0o700, exist_ok=True)
        os.symlink(os.fsencode(target), self.path(path))

    def private_object(self, value):
        path = self.private + b"/" + os.urandom(16).hex().encode()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(value)
        finally:
            os.close(fd)
        return os.fsdecode(path)

    def action(self, path, expected, desired):
        return {"schema": 1, "root": os.fsdecode(self.root), "path_hex": os.fsencode(path).hex(), "expected": expected, "desired": desired}

    def desired(self, value=None, mode="100644", kind="regular"):
        return {**fingerprint(value, mode, kind), "source": None if kind == "absent" else self.private_object(value)}

    def absent_to_regular(self, path, content):
        return self.action(path, fingerprint(kind="absent"), self.desired(content))

    def outside_directory(self):
        outside = self.base + b"/outside"
        os.mkdir(outside, 0o700)
        return outside


class ReviewMutationTests(unittest.TestCase):
    def test_regular_opens_are_nonblocking_against_fifo_substitution(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"baseline"))
        real_open = os.open
        def checked_open(path, flags, *args, **kwargs):
            if not flags & os.O_DIRECTORY and not flags & os.O_WRONLY:
                self.assertTrue(flags & os.O_NONBLOCK, "a swapped FIFO must not block a fingerprint read")
                self.assertIsNotNone(kwargs.get("dir_fd"), "file reads stay descriptor-relative")
            return real_open(path, flags, *args, **kwargs)
        with mock.patch.object(review_helper.os, "open", side_effect=checked_open):
            review_helper.apply_action(action)

    def test_temporary_descriptor_is_closed_when_initial_fstat_fails(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"baseline"))
        opened, closed = [], []
        real_open, real_fstat, real_close = os.open, os.fstat, os.close
        def capture_open(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            if flags & os.O_WRONLY:
                opened.append(fd)
                closed.clear()  # Earlier source reads may have reused this fd number.
            return fd
        def fail_fstat(fd):
            if fd in opened:
                raise OSError("temporary fstat failure")
            return real_fstat(fd)
        def capture_close(fd):
            closed.append(fd)
            return real_close(fd)
        with mock.patch.object(review_helper.os, "open", side_effect=capture_open), mock.patch.object(review_helper.os, "fstat", side_effect=fail_fstat), mock.patch.object(review_helper.os, "close", side_effect=capture_close):
            with self.assertRaises(OSError):
                review_helper.apply_action(action)
        self.assertEqual(len(opened), 1)
        self.assertIn(opened[0], closed, "even an unidentified temporary descriptor must be closed")
        self.assertEqual(fixture.read("item"), b"original")

    def test_post_publication_failures_do_not_roll_back_over_a_later_writer(self):
        for failure in ("directory-fsync", "post-write-hash"):
            with self.subTest(failure=failure):
                fixture = ReviewFixture(self)
                fixture.write("item", b"original")
                action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"baseline"))
                real_fsync = os.fsync
                def fail_after_publication(fd):
                    if stat.S_ISDIR(os.fstat(fd).st_mode):
                        if failure == "directory-fsync":
                            raise OSError("directory fsync failed after publication")
                        fixture.write("item", b"later writer")
                    return real_fsync(fd)
                with mock.patch.object(review_helper.os, "fsync", side_effect=fail_after_publication):
                    with self.assertRaises((OSError, ValueError)):
                        review_helper.apply_action(action)
                self.assertEqual(fixture.read("item"), b"baseline" if failure == "directory-fsync" else b"later writer")
                self.assertEqual(os.listdir(fixture.root), [b"item"])

    def test_unlink_rechecks_a_changed_destination(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(kind="absent"))
        real_fingerprint = review_helper.fingerprint_at
        calls = []
        def change_after_initial_read(fd, name):
            result = real_fingerprint(fd, name)
            calls.append(name)
            if len(calls) == 1:
                fixture.write("item", b"later writer")
            return result
        with mock.patch.object(review_helper, "fingerprint_at", side_effect=change_after_initial_read):
            with self.assertRaisesRegex(ValueError, "before unlink"):
                review_helper.apply_action(action)
        self.assertEqual(fixture.read("item"), b"later writer")

    def test_regular_replacement_is_exact_and_descriptor_relative(self):
        fixture = ReviewFixture(self)
        fixture.write("src/item.txt", b"agent\n")
        action = fixture.action(b"src/item.txt", fingerprint(b"agent\n"), fixture.desired(b"baseline dirty\n"))
        real_rename = os.rename
        def checked_rename(source, destination, **kwargs):
            self.assertEqual(len(source), 32)
            self.assertEqual(destination, b"item.txt")
            self.assertIsInstance(kwargs.get("src_dir_fd"), int)
            self.assertEqual(kwargs["src_dir_fd"], kwargs.get("dst_dir_fd"))
            return real_rename(source, destination, **kwargs)
        with mock.patch.object(review_helper.os, "rename", side_effect=checked_rename):
            result = review_helper.apply_action(action)
        self.assertEqual(result, {"kind": "regular", "mode": "100644", "size": 15, "sha256": sha256(b"baseline dirty\n")})
        self.assertEqual(fixture.read("src/item.txt"), b"baseline dirty\n")
        self.assertEqual(os.listdir(fixture.path("src")), [b"item.txt"])

    def test_expected_hash_mismatch_writes_nothing(self):
        fixture = ReviewFixture(self)
        fixture.write("race.txt", b"newer\n")
        action = fixture.action(b"race.txt", fingerprint(b"older\n"), fixture.desired(kind="absent"))
        with self.assertRaisesRegex(ValueError, "expected fingerprint"):
            review_helper.apply_action(action)
        self.assertEqual(fixture.read("race.txt"), b"newer\n")

    def test_symlink_parent_is_refused(self):
        fixture = ReviewFixture(self)
        outside = fixture.outside_directory()
        fixture.symlink("linked", outside)
        with self.assertRaisesRegex(ValueError, "parent.*symlink"):
            review_helper.apply_action(fixture.absent_to_regular(b"linked/escape.txt", b"no\n"))
        self.assertFalse(os.path.exists(outside + b"/escape.txt"))

    def test_created_file_is_unlinked_only_after_exact_comparison(self):
        fixture = ReviewFixture(self)
        fixture.write("created.txt", b"agent")
        result = review_helper.apply_action(fixture.action(b"created.txt", fingerprint(b"agent"), fixture.desired(kind="absent")))
        self.assertEqual(result, fingerprint(kind="absent"))
        self.assertFalse(os.path.lexists(fixture.path("created.txt")))

    def test_deleted_executable_is_restored_with_exact_bytes_and_mode(self):
        fixture = ReviewFixture(self)
        value = b"#!/bin/sh\r\nprintf '\\0'\n\xff\0"
        action = fixture.action(b"deleted.sh", fingerprint(kind="absent"), fixture.desired(value, "100755"))
        self.assertEqual(review_helper.apply_action(action), fingerprint(value, "100755"))
        self.assertEqual(fixture.read("deleted.sh"), value)
        self.assertEqual(stat.S_IMODE(os.lstat(fixture.path("deleted.sh")).st_mode), 0o755)

    def test_whole_object_type_matrix_preserves_symlink_target_bytes(self):
        for current_kind in ("absent", "regular", "symlink"):
            for desired_kind in ("regular", "symlink", "absent"):
                with self.subTest(current=current_kind, desired=desired_kind):
                    fixture = ReviewFixture(self)
                    value, target = b"regular\n", b"../literal-$PATH\n\xff"
                    if current_kind == "regular":
                        fixture.write("item", value)
                        expected = fingerprint(value)
                    elif current_kind == "symlink":
                        fixture.symlink("item", b"does-not-exist")
                        expected = fingerprint(b"does-not-exist", "120000", "symlink")
                    else:
                        expected = fingerprint(kind="absent")
                    desired = fixture.desired(target if desired_kind == "symlink" else value, "120000" if desired_kind == "symlink" else "100644", desired_kind)
                    result = review_helper.apply_action(fixture.action(b"item", expected, desired))
                    self.assertEqual(result, {key: desired[key] for key in ("kind", "mode", "size", "sha256")})
                    if desired_kind == "symlink":
                        self.assertEqual(os.readlink(fixture.path("item")), target)
                    elif desired_kind == "regular":
                        self.assertEqual(fixture.read("item"), value)
                    else:
                        self.assertFalse(os.path.lexists(fixture.path("item")))

    def test_nul_symlink_target_is_rejected_without_mutation(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        with self.assertRaisesRegex(ValueError, "symlink.*NUL"):
            review_helper.apply_action(fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"a\0b", "120000", "symlink")))
        self.assertEqual(fixture.read("item"), b"original")

    def test_source_hash_mismatch_is_rejected(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        desired = fixture.desired(b"baseline")
        with open(desired["source"], "wb") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "source fingerprint"):
            review_helper.apply_action(fixture.action(b"item", fingerprint(b"original"), desired))
        self.assertEqual(fixture.read("item"), b"original")

    def test_partial_writes_complete_exactly(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"replacement\0without newline"))
        real_write = os.write
        with mock.patch.object(review_helper.os, "write", side_effect=lambda fd, value: real_write(fd, value[:2])):
            review_helper.apply_action(action)
        self.assertEqual(fixture.read("item"), b"replacement\0without newline")

    def test_write_fsync_and_rename_failures_leave_destination_unchanged(self):
        for operation in ("write", "fsync", "rename"):
            with self.subTest(operation=operation):
                fixture = ReviewFixture(self)
                fixture.write("item", b"original")
                action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"replacement"))
                with mock.patch.object(review_helper.os, operation, side_effect=OSError("injected failure")):
                    with self.assertRaises(OSError):
                        review_helper.apply_action(action)
                self.assertEqual(fixture.read("item"), b"original")
                self.assertEqual(os.listdir(fixture.root), [b"item"])

    def test_destination_swap_is_rechecked_before_publication(self):
        for replacement in ("regular", "symlink", "directory"):
            with self.subTest(replacement=replacement):
                fixture = ReviewFixture(self)
                fixture.write("item", b"original")
                action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"baseline"))
                real_fsync = os.fsync
                def swap(fd):
                    if stat.S_ISREG(os.fstat(fd).st_mode):
                        os.unlink(fixture.path("item"))
                        if replacement == "regular":
                            fixture.write("item", b"new writer")
                        elif replacement == "symlink":
                            fixture.symlink("item", b"outside-target")
                        else:
                            os.mkdir(fixture.path("item"))
                    return real_fsync(fd)
                with mock.patch.object(review_helper.os, "fsync", side_effect=swap):
                    with self.assertRaises(ValueError):
                        review_helper.apply_action(action)
                if replacement == "regular":
                    self.assertEqual(fixture.read("item"), b"new writer")
                elif replacement == "symlink":
                    self.assertEqual(os.readlink(fixture.path("item")), b"outside-target")
                else:
                    self.assertTrue(os.path.isdir(fixture.path("item")))
                self.assertEqual(os.listdir(fixture.root), [b"item"])

    def test_parent_rename_is_refused_and_cleanup_uses_retained_descriptor(self):
        fixture = ReviewFixture(self)
        fixture.write("src/item", b"original")
        outside = fixture.outside_directory()
        action = fixture.action(b"src/item", fingerprint(b"original"), fixture.desired(b"baseline"))
        real_fsync = os.fsync
        def move_parent(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode):
                os.rename(fixture.path("src"), outside + b"/moved")
                os.mkdir(fixture.path("src"))
                fixture.write("src/unrelated", b"do not touch")
            return real_fsync(fd)
        with mock.patch.object(review_helper.os, "fsync", side_effect=move_parent):
            with self.assertRaisesRegex(ValueError, "parent changed"):
                review_helper.apply_action(action)
        self.assertEqual(os.listdir(outside + b"/moved"), [b"item"])
        self.assertEqual(fixture.read("src/unrelated"), b"do not touch")

    def test_parent_move_after_final_fingerprint_cannot_mutate_outside_root(self):
        for desired_kind in ("regular", "absent"):
            with self.subTest(desired=desired_kind):
                fixture = ReviewFixture(self)
                fixture.write("src/item", b"original")
                outside = fixture.outside_directory()
                action = fixture.action(b"src/item", fingerprint(b"original"), fixture.desired(b"baseline", kind=desired_kind))
                real_fingerprint = review_helper.fingerprint_at
                reads = []
                def move_after_destination_read(fd, name):
                    result = real_fingerprint(fd, name)
                    if name == b"item":
                        reads.append(name)
                        if len(reads) == 2:
                            os.rename(fixture.path("src"), outside + b"/moved")
                            os.mkdir(fixture.path("src"))
                    return result
                with mock.patch.object(review_helper, "fingerprint_at", side_effect=move_after_destination_read):
                    with self.assertRaisesRegex(ValueError, "parent changed"):
                        review_helper.apply_action(action)
                self.assertEqual((Path(os.fsdecode(outside)) / "moved" / "item").read_bytes(), b"original")
                self.assertEqual(os.listdir(outside + b"/moved"), [b"item"])

    def test_swapped_temporary_is_neither_published_nor_removed_as_owned(self):
        fixture = ReviewFixture(self)
        fixture.write("item", b"original")
        action = fixture.action(b"item", fingerprint(b"original"), fixture.desired(b"baseline"))
        swapped = []
        real_fsync = os.fsync
        def swap_temporary(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode):
                leaf = next(name for name in os.listdir(fixture.root) if name != b"item")
                os.unlink(fixture.path(leaf))
                fixture.symlink(leaf, b"unrelated-target")
                swapped.append(leaf)
            return real_fsync(fd)
        with mock.patch.object(review_helper.os, "fsync", side_effect=swap_temporary):
            with self.assertRaisesRegex(ValueError, "temporary"):
                review_helper.apply_action(action)
        self.assertEqual(fixture.read("item"), b"original")
        self.assertEqual(os.readlink(fixture.path(swapped[0])), b"unrelated-target")

    def test_control_and_non_utf8_path_bytes_are_literal(self):
        fixture = ReviewFixture(self)
        path = b"literal-$PATH-\n\r\t\x1b\xff"
        result = review_helper.apply_action(fixture.absent_to_regular(path, b"exact"))
        self.assertEqual(result, fingerprint(b"exact"))
        self.assertEqual(fixture.read(path), b"exact")

    def test_invalid_action_shapes_and_paths_are_rejected_before_writing(self):
        fixture = ReviewFixture(self)
        original = fixture.absent_to_regular(b"safe", b"exact")
        cases = []
        for path in (b"", b"/absolute", b"../escape", b"a/../b", b"a/./b", b"a//b", b"a/", b"a\0b", b"a" * 4097):
            cases.append({**original, "path_hex": path.hex()})
        cases.extend(({**original, "path_hex": "AA"}, {**original, "path_hex": "abc"}, {**original, "path_hex": "zz"}, {**original, "root": "/"}, {**original, "schema": True}, {**original, "unknown": True}, {**original, "expected": {**original["expected"], "extra": None}}))
        for action in cases:
            with self.subTest(action=action["path_hex"][:40]):
                with self.assertRaises(ValueError):
                    review_helper.apply_action(action)
        self.assertEqual(os.listdir(fixture.root), [])

    def test_manifest_is_private_bounded_nonsymlink_and_strict_json(self):
        fixture = ReviewFixture(self)
        action = fixture.absent_to_regular(b"safe", b"exact")
        manifest = fixture.private_object(json.dumps(action).encode())
        self.assertEqual(review_helper.read_manifest(manifest), action)
        linked = os.fsdecode(fixture.private + b"/manifest-link")
        os.symlink(manifest, linked)
        with self.assertRaises(ValueError):
            review_helper.read_manifest(linked)
        os.chmod(manifest, 0o644)
        with self.assertRaises(ValueError):
            review_helper.read_manifest(manifest)
        os.chmod(manifest, 0o600)
        uid = os.getuid()
        with mock.patch.object(review_helper.os, "getuid", return_value=uid + 1):
            with self.assertRaises(ValueError):
                review_helper.read_manifest(manifest)
        for value in (b" " * (1024 * 1024 + 1), b"{", b"\xff", b'{"schema":1,"schema":1}', json.dumps({**action, "unknown": 1}).encode()):
            invalid = fixture.private_object(value)
            with self.assertRaises((ValueError, UnicodeError)):
                review_helper.read_manifest(invalid)
        self.assertEqual(os.listdir(fixture.root), [])

    def test_private_source_rejects_symlink_and_unsafe_mode(self):
        fixture = ReviewFixture(self)
        action = fixture.absent_to_regular(b"safe", b"exact")
        source = action["desired"]["source"]
        for mode in (0o644, 0o660):
            os.chmod(source, mode)
            with self.assertRaises(ValueError):
                review_helper.apply_action(action)
        os.chmod(source, 0o600)
        linked = os.fsdecode(fixture.private + b"/source-link")
        os.symlink(source, linked)
        action["desired"]["source"] = linked
        with self.assertRaises(ValueError):
            review_helper.apply_action(action)
        self.assertEqual(os.listdir(fixture.root), [])

    def test_cli_accepts_only_a_private_manifest_and_returns_content_free_json(self):
        fixture = ReviewFixture(self)
        action = fixture.absent_to_regular(b"safe", b"selected-secret")
        manifest = fixture.private_object(json.dumps(action).encode())
        result = subprocess.run([sys.executable, "-I", "-B", str(HELPER), "--manifest", manifest], capture_output=True, close_fds=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), fingerprint(b"selected-secret"))
        self.assertNotIn(b"selected-secret", result.stdout + result.stderr)
        invalid = fixture.private_object(b"selected-secret malformed manifest")
        result = subprocess.run([sys.executable, "-I", "-B", str(HELPER), "--manifest", invalid], capture_output=True, close_fds=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"selected-secret", result.stderr)


if __name__ == "__main__":
    unittest.main()
