"""Opt-in real OpenCode through the production conversation controller and pipes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_provider", ROOT / 'tests/fixtures/ai/acp_session_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


@unittest.skipUnless(os.environ.get('NVIM_AI_ACP_REAL_OPENCODE'), 'opt-in real production-controller proof')
class InteropTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='draft-controller-interop-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.scratch = Path(self.temporary.name)
        self.root = self.scratch / 'project'
        (self.root / 'src').mkdir(mode=0o700, parents=True)
        self.source = self.root / 'src/example.txt'
        self.source.write_bytes(b'original text\n')
        self.source.chmod(0o644)
        self.provider = probe.Provider()
        self.addCleanup(self.provider.close)
        self.auth = self.scratch / 'auth.json'
        self.profile(1)
        self.config = self.scratch / 'config.json'
        self.config.write_text(json.dumps({'opencode': os.path.realpath(os.environ['NVIM_AI_ACP_REAL_OPENCODE']),
            'bwrap': os.path.realpath(shutil.which('bwrap')), 'model': 'fixture/model',
            'auth_file': str(self.auth), 'provider': self.provider.config()}))
        self.config.chmod(0o600)
        self.audit = self.scratch / 'audit.jsonl'
        self.buffer, self.events, self.proposals = bytearray(), [], set()
        self.serial = self.turn = 0
        self.model = 'fixture/model'
        self.child = None
        self.addCleanup(self.cleanup)

    def profile(self, generation):
        self.auth.write_text(json.dumps({'fixture': {'type': 'api', 'key': f'synthetic-profile-{generation}'},
                                        'unrelated': {'type': 'api', 'key': 'never-forward-this-key'}}))
        self.auth.chmod(0o600)

    def launch(self, fault='none'):
        env = {'PATH': os.defpath, 'LANG': 'C.UTF-8'}
        for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR'):
            path = self.scratch / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        self.child = subprocess.Popen([sys.executable, '-I', '-B',
            str(ROOT / 'tests/fixtures/ai/conversation_observed_controller.py'),
            str(self.config), str(self.audit), fault], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, umask=0o077)

    def cleanup(self):
        if self.child is not None:
            if self.child.poll() is None:
                self.child.stdin.close()
                try:
                    self.child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(timeout=3)
            for stream in (self.child.stdin, self.child.stdout, self.child.stderr):
                stream.close()
        for directory in self.proposals:
            if directory.exists():
                shutil.rmtree(directory)

    def observations(self):
        return [json.loads(line) for line in self.audit.read_text().splitlines()]

    def send(self, kind, **extra):
        self.serial += 1
        if kind == 'start':
            self.turn += 1
            extra.setdefault('message', 'Answer this explicit message without editing.')
            extra['sources'] = [{'path': 'src/example.txt',
                                 'snapshot_sha256': hashlib.sha256(self.source.read_bytes()).hexdigest()}]
        command = dict(kind=kind, conversation_id='a' * 32, owner_generation=1,
            turn_id=self.turn, worker_generation=self.turn, root=str(self.root),
            selection=['src/example.txt'], model=self.model, **extra)
        self.child.stdin.write(json.dumps({'version': 1, 'serial': self.serial, 'command': command}).encode() + b'\n')
        self.child.stdin.flush()

    def receive(self, kind, timeout=35):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                raw, _, self.buffer = self.buffer.partition(b'\n')
                event = json.loads(raw)['event']
                self.events.append(event)
                if 'review_ref' in event:
                    self.proposals.add(Path(event['review_ref']['manifest']).parent)
                if event['kind'] == kind:
                    return event
            if select.select([self.child.stdout], [], [], .1)[0]:
                chunk = os.read(self.child.stdout.fileno(), 65536)
                if not chunk:
                    self.child.wait(timeout=5)
                    self.fail('Controller exited before ' + kind + ': ' + self.child.stderr.read().decode())
                self.buffer.extend(chunk)
        self.fail('Timed out before ' + kind + ': ' + repr(self.events[-3:]))

    def assert_stopped(self):
        workers = [value for value in self.observations() if 'worker' in value]
        for item in workers:
            self.assertFalse(Path('/proc').joinpath(str(item['worker'])).exists())
            with socket.socket() as connection:
                self.assertNotEqual(connection.connect_ex(('127.0.0.1', item['port'])), 0)
            self.assertEqual(item['compaction'], {'auto': False, 'prune': False})
            self.assertEqual((item['disable_compaction'], item['disable_prune']), ('true', 'true'))
            self.assertFalse((Path(item['task']) / 'agent').exists())
        self.assertEqual(len({item['worker'] for item in workers}), len(workers))
        self.assertEqual(self.source.read_bytes(), b'original text\n')
        return workers

    def finish(self):
        self.send('close')
        self.assertTrue(self.receive('closed')['cleaned'])
        self.child.wait(timeout=5)
        self.assertEqual(self.child.returncode, 0, self.child.stderr.read())
        for worker in self.assert_stopped():
            self.assertFalse(Path(worker['store']).exists())

    def test_real_backend_preserves_context_without_prompt_replay(self):
        self.provider.replies.extend([{'edit': True}, {'text': 'Distinctive assistant reply: copper-orbit-731.'},
                                      {'text': 'Second explicit turn received.'}])
        self.launch()
        self.send('start', message='Edit /tmp/project/src/example.txt from original text to proposed text.')
        first = self.receive('settled')
        self.assertEqual(first['outcome'], 'review', first)
        self.assert_stopped()
        manifest, token = first['review_ref']['manifest'], first['proposal']['token']
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'scripts/nvim-ai-staged.py'),
            'reject', '--proposal', manifest, '--id', token, '--path', 'src/example.txt'], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.send('decide', choice='reject', path='src/example.txt', round_id=1,
                  proposal_revision=1, proposal_token=token, receipt_sequence=0)
        self.assertEqual(self.receive('decided')['receipt']['decisions'][0]['state'], 'rejected')
        self.profile(2)
        self.model = 'fixture/second-model'
        self.send('start', message='Continue without editing. This is a new explicit user message.')
        self.assertEqual(self.receive('settled')['outcome'], 'answer')
        records = self.observations()
        prompts = [item['params'] for item in records if item.get('method') == 'session/prompt']
        self.assertNotIn('copper-orbit-731', json.dumps(prompts[1]))
        self.assertNotIn('first_native_edit', json.dumps(prompts[1]))
        self.assertEqual(prompts[0]['sessionId'], prompts[1]['sessionId'])
        self.assertEqual([item.get('method') for item in records].count('session/new'), 1)
        self.assertEqual([item.get('method') for item in records].count('session/resume'), 1)
        messages = self.provider.requests[-1]['body']['messages']
        self.assertTrue(any(item.get('role') == 'assistant' and 'copper-orbit-731' in str(item.get('content'))
                            for item in messages))
        self.assertTrue(any(item.get('role') == 'tool' and item.get('tool_call_id') == 'first_native_edit'
                            for item in messages))
        self.assertEqual([item['authorization'] for item in self.provider.requests],
                         ['Bearer synthetic-profile-1', 'Bearer synthetic-profile-1', 'Bearer synthetic-profile-2'])
        self.assertEqual([item['body']['model'] for item in self.provider.requests], ['model', 'model', 'second-model'])
        workers = self.assert_stopped()
        self.assertEqual(len({item['profile_sha256'] for item in workers}), 2)
        artifacts = {}
        for entry in (Path(workers[-1]['store']) / 'backend-store').iterdir():
            node = entry.lstat()
            self.assertTrue(stat.S_ISREG(node.st_mode))
            self.assertEqual((stat.S_IMODE(node.st_mode), node.st_nlink, node.st_uid), (0o600, 1, os.getuid()))
            artifacts[entry.name] = node.st_size
        self.assertIn('opencode.db', artifacts)
        self.assertLessEqual(set(artifacts), {'opencode.db', 'opencode.db-wal', 'opencode.db-shm'})
        self.assertLessEqual(sum(artifacts.values()), 64 * 1024 * 1024)
        print(f'\nReal controller workers: {[item["worker"] for item in workers]}; retained artifact bytes: {artifacts}', flush=True)
        self.finish()

    def test_clean_cancel_resumes_only_on_an_explicit_new_turn(self):
        release = threading.Event()
        self.addCleanup(release.set)
        self.provider.replies.extend([{'text': 'Partial answer before cancellation.', 'hold': release},
                                      {'text': 'Fresh explicit request after cancellation.'}])
        self.launch()
        self.send('start', message='cancelled-user-marker: answer without editing')
        self.receive('submitted')
        self.assertTrue(self.provider.streaming.wait(timeout=8))
        self.send('cancel')
        cancelled = self.receive('cancelled')
        self.assertTrue(cancelled['cancel_confirmed'] and cancelled['graceful'] and cancelled['store_valid'])
        release.set()
        self.assertEqual(len(self.provider.requests), 1)
        self.assert_stopped()
        self.profile(2)
        self.send('start', message='This is the new explicit user request.')
        self.assertEqual(self.receive('settled')['outcome'], 'answer')
        self.assertIn('cancelled-user-marker', json.dumps(self.provider.requests[-1]['body']['messages']))
        self.assertEqual(len(self.provider.requests), 2)
        prompts = [item['params'] for item in self.observations() if item.get('method') == 'session/prompt']
        self.assertEqual(prompts[0]['sessionId'], prompts[1]['sessionId'])
        self.finish()

    def test_real_session_restoration_error_never_creates_a_replacement_session(self):
        self.provider.replies.append({'text': 'One valid first turn.'})
        self.launch('missing-session')
        self.send('start')
        self.assertEqual(self.receive('settled')['outcome'], 'answer')
        self.send('start')
        self.assertEqual(self.receive('settled')['outcome'], 'failed')
        methods = [item.get('method') for item in self.observations()]
        self.assertEqual(methods.count('session/new'), 1)
        self.assertEqual(methods.count('session/resume'), 1)
        self.assertEqual(methods.count('session/prompt'), 1)
        self.assertEqual(len(self.provider.requests), 1)
        self.finish()

    def test_context_overflow_does_not_trigger_compaction_or_replay(self):
        self.provider.replies.append({'error': {'message': 'maximum context length exceeded',
            'type': 'context_length_exceeded', 'code': 'context_length_exceeded'}})
        self.launch()
        self.send('start')
        self.assertEqual(self.receive('settled')['outcome'], 'failed')
        self.assertEqual(len(self.provider.requests), 1)
        self.assertEqual([item.get('method') for item in self.observations()].count('session/prompt'), 1)
        self.finish()


if __name__ == '__main__':
    unittest.main()
