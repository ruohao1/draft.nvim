#!/usr/bin/env python3
"""Test-only fault injection around the real production controller boundary."""
import importlib.util
import json
from pathlib import Path
import socket
import sys


script = Path(__file__).resolve().parents[3] / 'scripts/nvim-ai-conversation.py'
spec = importlib.util.spec_from_file_location('faulted_conversation', script)
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
fault = sys.argv.pop(1)
config = json.loads(Path(sys.argv[sys.argv.index('--config') + 1]).read_text())

if fault == 'before-retire':
    def refuse(*_args):
        raise OSError('injected pre-retirement failure')
    controller.reviews.decisions.PendingReview.retire = refuse
elif fault == 'freeze-cancel':
    freeze = controller.turns.staging.freeze_workspace

    def paused_freeze(*args, **kwargs):
        result = freeze(*args, **kwargs)
        if kwargs.get('force_review'):
            port = config['provider']['fixture']['options']['auditPort']
            with socket.create_connection(('127.0.0.1', port), timeout=10) as stream:
                stream.sendall(json.dumps({'ready': 'freeze-cancel', 'candidate': result['proposal']}).encode() + b'\n')
                assert stream.recv(32) == b'continue\n'
        return result
    controller.turns.staging.freeze_workspace = paused_freeze
else:
    raise ValueError('Unknown test fault')

sys.exit(controller.main())
