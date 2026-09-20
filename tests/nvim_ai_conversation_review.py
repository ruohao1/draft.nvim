"""Review handoff faults over real immutable files and writer journals."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/nvim-ai-conversation-review.py'
spec = importlib.util.spec_from_file_location('conversation_review', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
staging = module.staging


class RegistryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='draft-review-test-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.paths = ['first.txt', 'second.txt']
        for path in self.paths:
            (self.root / path).write_bytes(b'original text\n')
            (self.root / path).chmod(0o644)
        self.tasks = []
        self.registry = module.ReviewRegistry(str(self.root), self.paths)
        self.first = self.freeze([b'proposed edit\n'] * 2)
        self.registry.install(self.first, 1)

    def tearDown(self):
        if self.registry.pending is not None:
            self.registry.pending.close()
        for task in self.tasks:
            if task.exists():
                shutil.rmtree(task)
        self.temp.cleanup()

    def sources(self):
        return [{'path': path, 'snapshot_sha256': hashlib.sha256((self.root / path).read_bytes()).hexdigest()}
                for path in self.paths]

    def freeze(self, after, selected=None):
        request = {'root': str(self.root), 'files': self.sources()}
        selected = selected if selected is not None else staging.selected_files(request)[0]
        task = staging.prepare_workspace(request, selected)
        self.tasks.append(task)
        for item, data in zip(selected, after):
            if not item.get('context_only'):
                (task / 'staging' / item['path']).write_bytes(data)
        return staging.freeze_workspace(task, str(self.root), selected, multi=True, force_review=True)

    def command(self, **fields):
        entry = self.registry.current
        value = {key: entry[key] for key in ('round_id', 'proposal_revision', 'receipt_sequence')}
        value['proposal_token'] = entry['token']
        return dict(value, **fields)

    def revision(self):
        context = self.command(files=copy.deepcopy(self.registry.current['files']))
        return self.registry.begin_revision(self.command(context=context, sources=self.sources()))

    def test_unpublished_intent_and_stale_token_cannot_manufacture_a_receipt(self):
        command = self.command(choice='approve', path='first.txt')
        with self.assertRaises(ValueError):
            self.registry.receipt(command)
        command['proposal_token'] = 'unknown-token'
        with self.assertRaises(ValueError):
            self.registry.receipt(command)
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'original text\n')

    def test_batch_receipt_requires_the_actual_full_writer_intent(self):
        command = self.command(choice='approve', remaining=True)
        with self.assertRaises(ValueError):
            self.registry.receipt(command)
        staging.decide(self.first['proposal'], self.first['id'], 'approve', remaining=True)
        receipt = self.registry.receipt(command)
        self.assertEqual(receipt['phase'], 'applied')
        self.assertEqual([item['state'] for item in receipt['decisions']], ['accepted', 'accepted'])
        self.assertEqual(receipt['sequence'], 1)
        self.assertIsNone(self.registry.current)
        self.assertEqual([path.read_bytes() for path in (self.root / name for name in self.paths)],
                         [b'proposed edit\n', b'proposed edit\n'])

    def test_single_file_journal_cannot_be_presented_as_batch_authority(self):
        command = self.command(choice='approve', remaining=True)
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        with self.assertRaisesRegex(ValueError, 'intent'):
            self.registry.receipt(command)
        self.assertEqual(self.registry.current['receipt_sequence'], 0)
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'original text\n')

    def test_terminal_writer_failure_closes_without_a_second_decision(self):
        command = self.command(choice='approve', path='first.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        self.registry.receipt(command)
        (self.root / 'second.txt').write_bytes(b'external change\n')
        command = self.command(choice='approve', path='second.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'second.txt')
        receipt = self.registry.receipt(command)
        self.assertEqual([item['state'] for item in receipt['decisions']], ['accepted', 'blocked'])
        before = module.decisions.read_receipt(self.first['proposal'], self.first['id'])
        self.assertEqual(self.registry.retire_all(), {})
        self.assertEqual(module.decisions.read_receipt(self.first['proposal'], self.first['id']), before)
        self.assertEqual([item['state'] for item in self.registry.context], ['accepted', 'blocked'])
        replay = staging.decide(self.first['proposal'], self.first['id'], 'approve', 'second.txt')
        self.assertNotEqual(replay['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'proposed edit\n')
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'external change\n')

    def test_uncertain_writer_receipt_survives_close_without_replay_or_cleanup(self):
        command = self.command(choice='approve', path='first.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        self.registry.receipt(command)
        command = self.command(choice='approve', path='second.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'second.txt')
        task = Path(self.first['proposal']).parent
        # A completed real write whose confirmation was lost stays uncertain.
        (task / 'decision-1-applied-1.json').unlink()
        (task / 'decision-1-result.json').unlink()
        receipt = self.registry.receipt(command)
        self.assertEqual(receipt['phase'], 'uncertain')
        self.assertEqual([item['state'] for item in receipt['decisions']], ['accepted', 'uncertain'])
        self.assertEqual(receipt['cleanup_pending'], ['second.txt'])
        before = module.decisions.read_receipt(self.first['proposal'], self.first['id'])
        self.assertEqual(self.registry.retire_all(), {})
        self.assertEqual(module.decisions.read_receipt(self.first['proposal'], self.first['id']), before)
        self.assertEqual([item['state'] for item in self.registry.context], ['accepted', 'uncertain'])
        replay = staging.decide(self.first['proposal'], self.first['id'], 'approve', 'second.txt')
        self.assertNotEqual(replay['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'proposed edit\n')
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'proposed edit\n')

    def test_unproven_terminal_receipt_cannot_release_current_review(self):
        command = self.command(choice='approve', path='first.txt')
        (self.root / 'first.txt').write_bytes(b'external change\n')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        (Path(self.first['proposal']).parent / 'consumed.json').unlink()
        current = copy.deepcopy(self.registry.current)
        with self.assertRaises(ValueError):
            self.registry.receipt(command)
        self.assertEqual(self.registry.current, current)
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'external change\n')

    def test_reject_remaining_after_revision_preserves_inherited_acceptance(self):
        command = self.command(choice='approve', path='first.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        self.registry.receipt(command)
        candidate = self.freeze([b'proposed edit\n', b'revised edit\n'], self.revision())
        self.registry.finish_revision(candidate, 2)
        command = self.command(choice='reject', remaining=True)
        staging.decide(candidate['proposal'], candidate['id'], 'reject', remaining=True)
        receipt = self.registry.receipt(command)
        self.assertEqual([item['state'] for item in receipt['decisions']], ['accepted', 'rejected'])
        self.assertEqual(receipt['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'proposed edit\n')
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'original text\n')

    def test_failure_before_fence_can_restore_only_after_candidate_retirement(self):
        candidate = self.freeze([b'revised edit\n'] * 2, self.revision())
        with patch.object(self.registry.pending, 'retire', side_effect=OSError('before fence')):
            with self.assertRaises(OSError):
                self.registry.finish_revision(candidate, 2)
        staging.discard_workspace(Path(candidate['proposal']).parent)
        restored = self.registry.restore_revision()
        self.assertEqual(restored['prior_review']['status'], 'active')
        self.assertTrue(restored['candidates_retired'])
        self.assertFalse(restored['prior_review']['context_valid'], 'Only Neovim proves captured-buffer validity')

    def test_failure_after_fence_never_restores_old_approval(self):
        candidate = self.freeze([b'revised edit\n'] * 2, self.revision())
        retire = self.registry.pending.retire

        def failed_reply(*args):
            retire(*args)
            raise OSError('after durable fence')

        with patch.object(self.registry.pending, 'retire', side_effect=failed_reply):
            with self.assertRaises(OSError):
                self.registry.finish_revision(candidate, 2)
        with self.assertRaises(ValueError):
            self.registry.restore_revision()
        retirement = self.registry.retire_all()
        self.assertEqual(retirement['receipt']['phase'], 'cancelled')
        result = staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        self.assertNotEqual(result['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'original text\n')

    def test_discussion_cleanup_failure_cannot_claim_retired_candidate(self):
        candidate = self.freeze([b'proposed edit\n'] * 2, self.revision())
        with patch.object(staging, 'discard_workspace', side_effect=OSError('candidate retained')):
            with self.assertRaises(OSError):
                self.registry.finish_revision(candidate, 2)
        self.assertTrue(Path(candidate['proposal']).exists())
        self.assertEqual(self.registry.pending.snapshot()['states'], ['pending', 'pending'])

    def test_source_drift_prevents_both_replacement_and_active_predecessor_proof(self):
        candidate = self.freeze([b'revised edit\n'] * 2, self.revision())
        (self.root / 'first.txt').write_bytes(b'user edit\n')
        with self.assertRaises(ValueError):
            self.registry.finish_revision(candidate, 2)
        with self.assertRaises(ValueError):
            self.registry.restore_revision()
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'user edit\n')


if __name__ == '__main__':
    unittest.main()
