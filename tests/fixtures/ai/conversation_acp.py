#!/usr/bin/python3
"""Scripted ACP process running inside the production Bubblewrap boundary."""
import json
import hashlib
import os
from pathlib import Path
import socket
import sys
import time


config = json.loads(Path('/opt/config.json').read_text())
options = config['provider']['fixture']['options']
case = options['testCase']
session = 'fixture-session'
model, mode = 'fixture/model', 'build'


def audit(value, wait=False):
    with socket.create_connection(('127.0.0.1', options['auditPort']), timeout=2) as stream:
        stream.sendall(json.dumps(value).encode() + b'\n')
        if wait:
            stream.settimeout(15)
            assert stream.recv(32) == b'continue\n'


def send(value):
    print(json.dumps(dict(jsonrpc='2.0', **value)), flush=True)


def answer(identifier, result):
    send({'id': identifier, 'result': result})


def choices(model='fixture/model', mode='build'):
    return [dict(id=key, name=key, type='select', category=key, currentValue=current,
                 options=[{'value': value, 'name': value} for value in values])
            for key, current, values in (
                ('model', model, ['fixture/second-model'] if case == 'missing-model'
                 else ['fixture/model', 'fixture/second-model']),
                ('mode', mode, ['plan'] if case == 'missing-mode' else ['build', 'plan']))]


assert config['compaction'] == {'auto': False, 'prune': False}
assert os.environ['OPENCODE_DISABLE_AUTOCOMPACT'] == 'true'
assert os.environ['OPENCODE_DISABLE_PRUNE'] == 'true'
assert os.environ['OPENCODE_SERVER_USERNAME'] == 'opencode'
assert os.environ['OPENCODE_SERVER_PASSWORD']
assert 'NVIM_STAGED_SENTINEL' not in os.environ
assert Path('/tmp/backend-state').is_dir()
assert not Path('/tmp/backend-state/../proposal.json').exists()
audit({'profile_inode': os.stat('/tmp/agent').st_ino,
       'listener_key_hash': hashlib.sha256(os.environ['OPENCODE_SERVER_PASSWORD'].encode()).hexdigest()})
for raw in sys.stdin:
    message = json.loads(raw)
    method, identifier = message.get('method'), message.get('id')
    audit({'method': method, 'params': message.get('params')})
    if method == 'initialize':
        if case == 'startup-cancel':
            audit({'ready': 'startup-cancel'})
            while True:
                time.sleep(1)
        assert message['params']['clientCapabilities'] == {
            'fs': {'readTextFile': False, 'writeTextFile': False}, 'terminal': False}
        answer(identifier, {'protocolVersion': 1, 'agentInfo': {
            'name': 'fixture', 'version': 'wrong' if case == 'wrong-version' else '1.18.30'},
            'agentCapabilities': {'sessionCapabilities': {} if case == 'missing-resume' else {'resume': {}}}})
    elif method == 'session/new':
        assert message['params'] == {'cwd': '/tmp/project', 'mcpServers': []}
        Path(os.environ['OPENCODE_DB']).write_bytes(b'synthetic private store')
        answer(identifier, {'sessionId': session, 'configOptions': choices()})
    elif method == 'session/resume':
        assert message['params'] == {'cwd': '/tmp/project', 'mcpServers': [], 'sessionId': session}
        assert Path(os.environ['OPENCODE_DB']).stat().st_size > 0
        if case == 'resume-fails':
            send({'id': identifier, 'error': {'code': -32000, 'message': 'fixture resume refusal'}})
        else:
            answer(identifier, {'configOptions': choices()})
    elif method == 'session/set_config_option':
        params = message['params']
        assert params['sessionId'] == session
        value = 'wrong' if case == 'wrong-confirmation' else params['value']
        if params['configId'] == 'model':
            model = value
        else:
            mode = value
        answer(identifier, {'configOptions': choices(model, mode)})
        if params['configId'] == 'mode' and case == 'blocked-prompt':
            audit({'ready': 'blocked-prompt'})
            while True:
                time.sleep(1)
    elif method == 'session/prompt':
        assert message['params']['sessionId'] == session
        if case in ('edit', 'held-edit'):
            text = message['params']['prompt'][-1]['text']
            paths = sorted(path for path in Path('/tmp/project').rglob('*') if path.is_file())
            audit({'editable_paths': [str(path.relative_to('/tmp/project')) for path in paths]})
            if 'Discuss' not in text:
                for path in paths:
                    after = ('original text\n' if 'Revert' in text else
                             'revised edit\n' if 'proposed edit' in path.read_text() else 'proposed edit\n')
                    send({'id': 'edit-' + path.name, 'method': 'session/request_permission', 'params': {
                        'sessionId': session, 'toolCall': {'kind': 'edit', 'content': [
                            {'type': 'diff', 'path': str(path), 'oldText': path.read_text(), 'newText': after}]},
                        'options': [{'kind': 'allow_once', 'optionId': 'once'}]}})
                    assert json.loads(next(sys.stdin))['result']['outcome']['optionId'] == 'once'
                    path.write_text(after)
            if 'extra-file' in text:
                Path('/tmp/project/not-selected.txt').write_text('unreviewed\n')
        if case == 'held-answer':
            audit({'ready': case}, wait=True)
        if case == 'output-blocked':
            audit({'ready': case})
            for _ in range(8):
                send({'method': 'session/update', 'params': {'sessionId': session, 'update': {
                    'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'x' * (1024 * 1024)}}}})
            assert not sys.stdin.read()
            break
        if case == 'both-blocked':
            audit({'ready': case})
            send({'method': 'session/update', 'params': {'sessionId': session, 'update': {
                'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'x' * (1024 * 1024)}}}})
            for index in range(10000):
                send({'id': 'no-read-' + str(index), 'method': 'fs/read_text_file', 'params': {'sessionId': session}})
            while True:
                time.sleep(1)
        if case == 'descendant':
            if os.fork() == 0:
                os.setsid()
                while True:
                    time.sleep(1)
            audit({'ready': case})
            assert not sys.stdin.read()
            break
        if case in ('cancel', 'flood-cancel'):
            audit({'ready': case})
            if case == 'flood-cancel':
                for _ in range(4000):
                    send({'method': 'session/update', 'params': {'sessionId': session, 'update': {
                        'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'text'}}}})
            cancel = json.loads(next(sys.stdin))
            assert cancel == {'jsonrpc': '2.0', 'method': 'session/cancel', 'params': {'sessionId': session}}
            audit({'cancel_received': True})
            answer(identifier, {'stopReason': 'cancelled'})
            continue
        for index, denied in enumerate(('fs/read_text_file', 'fs/write_text_file', 'terminal/create')):
            send({'id': 'denied-' + str(index), 'method': denied, 'params': {'sessionId': session}})
            assert json.loads(next(sys.stdin))['error']['code'] == -32601
        send({'id': 'outside', 'method': 'session/request_permission', 'params': {
            'sessionId': session, 'toolCall': {'kind': 'edit', 'content': [
                {'type': 'diff', 'path': '/tmp/project/unselected.txt', 'newText': 'escape'}]},
            'options': [{'kind': 'allow_once', 'optionId': 'once'}]}})
        assert json.loads(next(sys.stdin))['result']['outcome']['outcome'] == 'cancelled'
        for update in ({'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'A bounded answer.'}},
                       {'sessionUpdate': 'tool_call', 'toolCallId': 'read-1', 'title': 'Read selected file', 'status': 'completed'}):
            send({'method': 'session/update', 'params': {
                'sessionId': 'wrong-session' if case == 'wrong-session' else session, 'update': update}})
        if case == 'stream':
            audit({'ready': case}, wait=True)
        answer(identifier, {'stopReason': 'refusal' if case == 'bad-stop' else 'end_turn'})
if case in ('slow-exit', 'held-edit'):
    audit({'ready': case}, wait=True)
audit({'exiting': True})
