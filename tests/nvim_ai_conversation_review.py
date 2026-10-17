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

    def correct(self, text, path='first.txt'):
        self.assertTrue(callable(getattr(self.registry, 'correct', None)),
                        'Manual corrections must use the real review registry')
        context = self.command(files=copy.deepcopy(self.registry.current['files']))
        command = self.command(context=context, sources=self.sources(), path=path,
                               replacement=text, turn_id=1)
        prepare = staging.prepare_workspace

        def observed_prepare(*args, **kwargs):
            task = prepare(*args, **kwargs)
            self.tasks.append(task)
            return task

        with patch.object(staging, 'prepare_workspace', side_effect=observed_prepare):
            return self.registry.correct(command)

    def test_manual_correction_freezes_without_publishing_and_retires_parent(self):
        result = self.correct('corrected text\n\n')
        self.assertEqual(result['outcome'], 'review')
        self.assertEqual(result['prior_review']['status'], 'retired')
        self.assertFalse(result['prior_review']['context_valid'])
        self.assertNotEqual(result['proposal']['token'], self.first['id'])
        self.assertEqual(result['proposal']['source_generation'], 1)
        self.assertEqual(self.registry.current['proposal_revision'], 2)
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'original text\n')
        self.assertNotEqual(staging.decide(self.first['proposal'], self.first['id'],
                                          'approve', 'first.txt')['phase'], 'applied')
        ref = result['review_ref']
        staging.decide(ref['manifest'], ref['token'], 'approve', remaining=True)
        self.assertEqual(self.registry.receipt(self.command(choice='approve', remaining=True))['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'corrected text\n\n')
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'proposed edit\n')

    def test_manual_correction_preserves_accepted_context(self):
        intent = self.command(choice='approve', path='first.txt')
        staging.decide(self.first['proposal'], self.first['id'], 'approve', 'first.txt')
        self.registry.receipt(intent)
        result = self.correct('corrected second\n', 'second.txt')
        self.assertEqual([f['state'] for f in self.registry.current['files']], ['accepted', 'pending'])
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'proposed edit\n')
        self.assertEqual(self.correct('cannot reopen\n')['outcome'], 'refused')
        self.assertEqual(self.registry.current['token'], result['proposal']['token'])

    def test_manual_noop_keeps_identity_and_baseline_reversion_is_unchanged(self):
        result = self.correct('proposed edit\n')
        self.assertEqual(result['outcome'], 'unchanged')
        self.assertTrue(result['candidates_retired'])
        self.assertEqual(result['prior_review']['status'], 'active')
        self.assertEqual(self.registry.current['token'], self.first['id'])
        result = self.correct('original text\n')
        self.assertEqual(result['proposal']['files'][0]['state'], 'unchanged')
        result = self.correct('original text\n', 'second.txt')
        self.assertEqual([f['state'] for f in result['proposal']['files']], ['unchanged', 'unchanged'])
        self.assertIsNone(self.registry.current)

    def test_manual_invalid_bytes_refuse_without_losing_parent(self):
        for text in ('no final newline', '\ufeffbom\n', 'cr\r\n', 'nul\0\n', '\n' * 20001):
            with self.subTest(text=text[:20]):
                result = self.correct(text)
                self.assertEqual(result['outcome'], 'refused')
                self.assertEqual(result['prior_review']['status'], 'active')
                self.assertTrue(result['candidates_retired'])
                self.assertEqual(self.registry.current['token'], self.first['id'])
        self.assertEqual(self.correct('valid\n', 'outside.txt')['outcome'], 'refused')

    def test_manual_limit_leaves_noop_and_cleanup_available(self):
        for index in range(64):
            self.assertEqual(self.correct('revision %d\n' % index)['outcome'], 'review')
        token = self.registry.current['token']
        self.assertEqual(self.correct('one too many\n')['outcome'], 'refused')
        self.assertEqual(self.registry.current['token'], token)
        self.assertEqual(self.correct('revision 63\n')['outcome'], 'unchanged')
        self.assertEqual(self.registry.retire_all()['receipt']['phase'], 'cancelled')

    def test_manual_failure_before_fence_restores_only_after_candidate_cleanup(self):
        with patch.object(module.decisions.PendingReview, 'retire', side_effect=OSError('before fence')):
            result = self.correct('corrected\n')
        self.assertEqual(result['outcome'], 'refused')
        self.assertEqual(result['prior_review']['status'], 'active')
        self.assertTrue(result['candidates_retired'])
        self.assertFalse(self.tasks[-1].exists())

    def test_manual_failure_after_fence_never_restores_parent(self):
        retire = module.decisions.PendingReview.retire

        def lost_reply(pending, *args):
            retire(pending, *args)
            raise OSError('lost retirement reply')

        with patch.object(module.decisions.PendingReview, 'retire', new=lost_reply):
            with self.assertRaises((OSError, ValueError)):
                self.correct('corrected\n')
        self.registry.retire_all()
        self.assertNotEqual(staging.decide(self.first['proposal'], self.first['id'],
                                          'approve', 'first.txt')['phase'], 'applied')
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'original text\n')

    def test_manual_cleanup_failure_retains_ownership_until_close(self):
        with patch.object(staging, 'freeze_workspace', side_effect=OSError('freeze failed')):
            with patch.object(staging, 'discard_workspace', side_effect=OSError('cleanup failed')):
                with self.assertRaises(OSError):
                    self.correct('corrected\n')
        task = self.tasks[-1]
        self.assertTrue(task.exists())
        self.registry.retire_all()
        self.assertFalse(task.exists())
        self.assertEqual((self.root / 'first.txt').read_bytes(), b'original text\n')

    def test_manual_source_drift_cannot_restore_parent_eligibility(self):
        freeze = staging.freeze_workspace

        def drift(*args, **kwargs):
            frozen = freeze(*args, **kwargs)
            (self.root / 'second.txt').write_bytes(b'user edit\n')
            return frozen

        with patch.object(staging, 'freeze_workspace', side_effect=drift):
            with self.assertRaises(ValueError):
                self.correct('corrected\n')
        self.registry.retire_all()
        self.assertEqual((self.root / 'second.txt').read_bytes(), b'user edit\n')
        self.assertNotEqual(staging.decide(self.first['proposal'], self.first['id'],
                                          'approve', 'first.txt')['phase'], 'applied')

    def test_manual_install_lost_reply_still_owns_replacement_for_close(self):
        install = self.registry.install
        ref = {}

        def lost_reply(*args, **kwargs):
            result = install(*args, **kwargs)
            ref.update(result['review_ref'])
            raise OSError('install reply lost')

        intent = self.command()
        with patch.object(self.registry, 'install', side_effect=lost_reply):
            with self.assertRaises((OSError, ValueError)):
                self.correct('corrected\n')
        self.assertTrue(Path(ref['manifest']).is_file())
        result = self.registry.retire_all(intent)
        self.assertEqual(result['receipt']['proposal_token'], self.first['id'])
        self.assertEqual(result['receipt']['phase'], 'cancelled')
        self.assertNotEqual(staging.decide(ref['manifest'], ref['token'],
                                          'approve', 'first.txt')['phase'], 'applied')

    def test_manual_install_lost_reply_after_reverting_every_file_can_close(self):
        self.correct('original text\n')
        intent = self.command()
        install = self.registry.install

        def lost_reply(*args, **kwargs):
            install(*args, **kwargs)
            raise OSError('install reply lost')

        with patch.object(self.registry, 'install', side_effect=lost_reply):
            with self.assertRaises((OSError, ValueError)):
                self.correct('original text\n', 'second.txt')
        self.assertEqual(self.registry.retire_all(intent)['receipt']['phase'], 'cancelled')

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
