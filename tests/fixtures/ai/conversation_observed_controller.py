"""Test-only observer around the production controller; never replace its transport.

The optional restoration fault asks the real backend for a nonexistent session.
All recorded content belongs to the disposable synthetic provider fixture.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("observed_controller", ROOT / "scripts/nvim-ai-conversation.py")
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
config, audit_path, fault = sys.argv[1:]
audit = os.open(audit_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)


def record(**value):
    os.write(audit, json.dumps(value).encode() + b'\n')


start = controller.storage.Store.start
begin = controller.turns.Turn.begin


def observed_start(self, command, *, env, **options):
    worker = start(self, command, env=env, **options)
    task = next(Path(arg).parent for arg in command if arg.endswith('/staging'))
    profile = task / 'agent/data/opencode/auth.json'
    record(worker=worker.child.pid, task=str(task), store=str(self.root),
           port=int(command[command.index('--port') + 1]),
           profile_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(),
           compaction=json.loads((task / 'config.json').read_text())['compaction'],
           disable_compaction=env.get('OPENCODE_DISABLE_AUTOCOMPACT'),
           disable_prune=env.get('OPENCODE_DISABLE_PRUNE'))
    return worker


def observed_begin(self, method, params):
    if fault == 'missing-session' and method == 'session/resume':
        params = dict(params, sessionId='ses_nonexistent_controller_fixture')
    record(method=method, params=params)
    return begin(self, method, params)


controller.storage.Store.start = observed_start
controller.turns.Turn.begin = observed_begin
sys.argv = [str(ROOT / 'scripts/nvim-ai-conversation.py'), '--config', config]
try:
    raise SystemExit(controller.main())
finally:
    os.close(audit)
