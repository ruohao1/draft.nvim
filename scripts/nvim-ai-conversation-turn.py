"""Pinned ACP turn in a fresh selected-file workspace; never publishes files."""
import importlib.util
from pathlib import Path
import secrets
import socket
import time


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


staging = helper('nvim-ai-staged')
protocol = helper('nvim-ai-conversation-protocol')


class Turn:
    def __init__(self, config, store, editor_pipe):
        self.config, self.store, self.pipe = config, store, editor_pipe
        self.task = self.worker = self.session = None
        self.events = []
        self.done = self.submitted = False
        self.stage = None
        self.frozen = None
        self.stopped = self.graceful = self.store_valid = False
        self.cancelling = self.cancel_confirmed = False
        self.on_write_wait = None

    def emit(self, kind, **fields):
        self.events.append(dict(kind=kind, **fields))

    def start(self, command):
        self.command = command
        if command['model'].split('/', 1)[0] != self.config['model'].split('/', 1)[0]:
            raise protocol.Refused('Configured provider cannot change')
        request = dict(self.config, root=command['root'], files=command['sources'], model=command['model'])
        self.selected, _ = staging.selected_files(request)
        self.editable = [staging.PROJECT + '/' + item['path'] for item in self.selected]
        self.task = staging.prepare_workspace(request, self.selected)
        agent = self.task / 'agent'
        for name in ('home', 'config', 'data', 'cache', 'state'):
            (agent / name).mkdir(mode=0o700, parents=True)
        config = staging.configuration(request, agent)
        config['compaction'] = {'auto': False, 'prune': False}
        argv, env = staging.sandbox(request, self.task, config)
        env.update(OPENCODE_DISABLE_AUTOCOMPACT='true', OPENCODE_DISABLE_PRUNE='true',
                   OPENCODE_SERVER_USERNAME='opencode', OPENCODE_SERVER_PASSWORD=secrets.token_hex(16))
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            port = reserved.getsockname()[1]
        argv += ['--hostname', '127.0.0.1', '--port', str(port), '--mdns=false']
        self.startup_deadline = time.monotonic() + 60
        self.worker = self.store.start(argv, env=env, on_notification=self.notification,
                                       on_request=self.request, on_write_wait=self.on_write_wait)
        self.begin('initialize', {'protocolVersion': 1,
            'clientInfo': {'name': 'draft-conversation', 'version': '0.1'},
            'clientCapabilities': {'fs': {'readTextFile': False, 'writeTextFile': False}, 'terminal': False}})

    def begin(self, method, params):
        self.stage = method
        timeout = 180 if method == 'session/prompt' else min(15, self.startup_deadline - time.monotonic())
        if timeout <= 0:
            raise protocol.Refused('ACP startup deadline exceeded')
        self.pending = self.worker.begin(method, params, timeout=timeout)

    def options(self, result, confirmed=None):
        options = result.get('configOptions')
        if not isinstance(options, list) or not 1 <= len(options) <= 32:
            raise protocol.Refused('Missing ACP configuration options')
        indexed = {}
        for option in options:
            if not isinstance(option, dict) or not isinstance(option.get('id'), str) or option['id'] in indexed:
                raise protocol.Refused('Invalid ACP configuration option identity')
            indexed[option['id']] = option
        available = {}
        for key, desired in (('model', self.command['model']), ('mode', 'build')):
            option = indexed.get(key, {})
            choices = option.get('options')
            if option.get('type') != 'select' or not isinstance(choices, list) or not 1 <= len(choices) <= 128:
                raise protocol.Refused('Missing ACP model or mode options')
            values = [item.get('value') if isinstance(item, dict) else None for item in choices]
            if any(not isinstance(value, str) or not value or len(value.encode()) > 256 for value in values):
                raise protocol.Refused('Invalid ACP option value')
            if len(set(values)) != len(values) or desired not in values:
                raise protocol.Refused('Requested ACP option is not advertised')
            if confirmed == key and option.get('currentValue') != desired:
                raise protocol.Refused('ACP did not confirm the requested option')
            available[key] = values
        provider = self.command['model'].split('/', 1)[0]
        self.models = [value for value in available['model']
                       if protocol.model(value) and value.split('/', 1)[0] == provider]

    def notification(self, message):
        if message['method'] != 'session/update':
            return
        params = message.get('params', {})
        if not isinstance(params, dict) or params.get('sessionId') != self.session or self.session is None:
            raise protocol.Refused('Foreign ACP session update')
        update = params.get('update')
        if not isinstance(update, dict):
            raise protocol.Refused('Invalid ACP update')
        kind = update.get('sessionUpdate')
        if kind == 'agent_message_chunk':
            content = update.get('content', {})
            if self.stage != 'session/prompt' or not isinstance(content, dict) or content.get('type') != 'text':
                raise protocol.Refused('Unexpected ACP answer content')
            text = content.get('text')
            if not isinstance(text, str) or len(text.encode()) > 1024 * 1024:
                raise protocol.Refused('ACP answer chunk exceeds display budget')
            if not self.cancelling:
                self.emit('text', text=text)
        elif kind in ('tool_call', 'tool_call_update'):
            tool_id, title, status = update.get('toolCallId'), update.get('title'), update.get('status')
            # ACP updates may omit unchanged presentation fields.
            previous = getattr(self, 'tools', {}).get(tool_id) if isinstance(tool_id, str) else None
            if previous:
                title, status = title or previous[0], status or previous[1]
            if (not isinstance(tool_id, str) or not 0 < len(tool_id.encode()) <= 256
                    or not isinstance(title, str) or not 0 < len(title.encode()) <= 256
                    or status not in ('pending', 'in_progress', 'completed', 'failed', 'cancelled')):
                raise protocol.Refused('Invalid ACP tool progress')
            if not hasattr(self, 'tools'):
                self.tools = {}
            if len(self.tools) >= 20000 and tool_id not in self.tools:
                raise protocol.Refused('ACP tool progress budget exceeded')
            self.tools[tool_id] = (title, status)
            if not self.cancelling:
                self.emit('progress', tool_id=tool_id, title=title, status=status)

    def request(self, message):
        if message['method'] != 'session/request_permission':
            return {'error': {'code': -32601, 'message': 'Client capability disabled'}}
        params = message.get('params', {})
        if not isinstance(params, dict) or params.get('sessionId') != self.session:
            raise protocol.Refused('Foreign ACP permission request')
        call, choices = params.get('toolCall'), params.get('options')
        allowed = isinstance(call, dict) and call.get('kind') == 'edit' and self.stage == 'session/prompt'
        content = call.get('content') if isinstance(call, dict) else None
        diffs = [item for item in content if isinstance(item, dict) and item.get('type') == 'diff'] if isinstance(content, list) else []
        allowed = allowed and bool(diffs) and all(item.get('path') in self.editable for item in diffs)
        options = [item['optionId'] for item in choices if isinstance(item, dict)
                   and item.get('kind') == 'allow_once' and isinstance(item.get('optionId'), str)
                   and 0 < len(item['optionId'].encode()) <= 256] if isinstance(choices, list) else []
        outcome = {'outcome': 'selected', 'optionId': options[0]} if allowed and len(options) == 1 else {'outcome': 'cancelled'}
        return {'result': {'outcome': outcome}}

    def advance(self):
        ready, result = self.worker.poll(self.pending, timeout=.05)
        if ready:
            if self.stage == 'initialize':
                info, capabilities = result.get('agentInfo'), result.get('agentCapabilities')
                sessions = capabilities.get('sessionCapabilities') if isinstance(capabilities, dict) else None
                if (type(result.get('protocolVersion')) is not int or result['protocolVersion'] != 1
                        or not isinstance(info, dict) or info.get('version') != '1.18.30'
                        or not isinstance(sessions, dict) or not isinstance(sessions.get('resume'), dict)):
                    raise protocol.Refused('Pinned ACP version and resume capability required')
                self.begin('session/new', {'cwd': staging.PROJECT, 'mcpServers': []})
            elif self.stage == 'session/new':
                self.session = result.get('sessionId')
                if not protocol.opaque(self.session):
                    raise protocol.Refused('Missing ACP session identity')
                self.options(result)
                self.choice = 'model'
                self.begin('session/set_config_option', {'sessionId': self.session, 'configId': 'model', 'value': self.command['model']})
            elif self.stage == 'session/set_config_option':
                self.options(result, self.choice)
                if self.choice == 'model':
                    self.choice = 'mode'
                    self.begin('session/set_config_option', {'sessionId': self.session, 'configId': 'mode', 'value': 'build'})
                else:
                    self.submitted = True  # Once prompt writing begins, failure cannot authorize replay.
                    self.begin('session/prompt', {'sessionId': self.session, 'prompt': [{'type': 'text', 'text':
                        'Only selected paths in /tmp/project are available. Do not create, delete, rename, or change modes. '
                        'Shell tools are disabled.\n\n' + self.command['message']}]})
                    self.emit('submitted', model=self.command['model'], models=self.models)
            elif self.stage == 'session/prompt':
                if self.cancelling:
                    if result.get('stopReason') != 'cancelled':
                        raise protocol.Refused('ACP cancellation was not confirmed')
                    self.store.stop(outcome='cancelled')
                    self.stopped = self.graceful = self.store_valid = self.cancel_confirmed = True
                    staging.discard_workspace(self.task)
                    self.task = None
                    self.emit('cancelled', stopped=True, graceful=True, store_valid=True,
                              tokens_retired=True, cancel_confirmed=True)
                    self.done = True
                    events, self.events = self.events, []
                    return events
                self.emit('stopping')
                if result.get('stopReason') != 'end_turn':
                    raise protocol.Refused('ACP turn did not finish normally')
                self.store.stop(outcome='completed')
                self.stopped = self.graceful = self.store_valid = True
                self.frozen = staging.freeze_workspace(self.task, self.command['root'], self.selected, multi=True)
                if self.frozen['phase'] != 'unchanged':
                    # Review registration is added by the controller's review boundary.
                    raise protocol.Refused('Frozen review registration is not available')
                staging.discard_workspace(self.task)
                self.task = None
                self.emit('settled', outcome='answer', stopped=True, graceful=True, store_valid=True, tokens_retired=True)
                self.done = True
        events, self.events = self.events, []
        return events

    def cancel(self):
        self.cancelling = True
        if (self.done or self.worker is None or self.worker.fault
                or self.stage != 'session/prompt' or not self.submitted):
            return self.fail()
        # The controller removed the handled command before entering notify.
        # Its write hook still observes fresh close/EOF or malformed input.
        self.worker.deadline = min(self.worker.deadline, time.monotonic() + 5)
        self.worker.notify('session/cancel', {'sessionId': self.session})
        return []

    def fail(self):
        self.events = []
        if not self.cancelling:
            self.emit('stopping')
        if self.worker is not None:
            try:
                self.store.stop(outcome='failed')
            except Exception:
                pass  # Exit evidence, not a cleanup exception, controls deletion below.
            result = self.worker.close()
            self.stopped = result.reaped and result.output_closed
            self.graceful = result.settled
            self.store_valid = False
        else:
            self.stopped = self.graceful = True
            try:
                self.store.check()
                self.store_valid = True
            except Exception:
                self.store_valid = False
        retired = self.task is None
        if self.stopped and self.task is not None:
            try:
                staging.discard_workspace(self.task)
                self.task = None
                retired = True
            except OSError:
                pass
        if self.cancelling:
            self.emit('cancelled', stopped=self.stopped, graceful=self.graceful,
                      store_valid=self.store_valid, tokens_retired=retired, cancel_confirmed=False)
        else:
            self.emit('settled', outcome='failed', stopped=self.stopped, graceful=self.graceful,
                      store_valid=self.store_valid, tokens_retired=retired,
                      submission='submitted' if self.submitted else 'not_submitted')
        self.done = True
        events, self.events = self.events, []
        return events
