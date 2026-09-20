"""Controller-owned proposal identities and writer facts; never project writes."""
import copy
import importlib.util
from pathlib import Path


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


decisions = helper('nvim-ai-staged-decisions')
staging = helper('nvim-ai-staged')


class ReviewRegistry:
    def __init__(self, root, selection):
        self.root, self.selection = root, list(selection)
        self.entries = {}
        self.current = self.pending = None
        self.rounds = 0
        self.context = []
        self.revision = None

    def install(self, frozen, turn_id, *, previous=None):
        if self.current is not None and self.current is not previous:
            raise ValueError('An existing review must be retired before replacement')
        token, manifest = frozen['id'], frozen['proposal']
        value = decisions.read_receipt(manifest, token)
        if (token in self.entries or value['root'] != self.root or value['sequence'] != 0
                or [item['path'] for item in value['decisions']] != self.selection
                or (previous is None and not any(item['state'] == 'pending' for item in value['decisions']))):
            raise ValueError('Invalid fresh frozen proposal')
        if previous is None:
            self.rounds += 1
        merged = copy.deepcopy(value['decisions'])
        inherited = copy.deepcopy(previous['files']) if previous is not None else None
        if inherited is not None:
            for item, prior in zip(merged, inherited):
                if prior['state'] != 'pending':
                    if item['state'] != 'unchanged':
                        raise ValueError('Replacement changed an already decided file')
                    item['state'] = prior['state']
        entry = dict(manifest=manifest, token=token,
                     round_id=previous['round_id'] if previous else self.rounds,
                     proposal_revision=previous['proposal_revision'] + 1 if previous else 1,
                     receipt_sequence=0, files=merged, inherited=inherited,
                     journal_files=copy.deepcopy(value['decisions']))
        self.entries[token] = entry
        self.current = entry if any(item['state'] == 'pending' for item in merged) else None
        self.context = copy.deepcopy(merged)
        return {'proposal': {'token': token, 'source_generation': turn_id, 'files': value['decisions']},
                'review_ref': {'manifest': manifest, 'token': token}}

    def match(self, command):
        entry = self.current
        if (entry is None or command.get('proposal_token') != entry['token']
                or any(command.get(key) != entry[key] for key in
                       ('round_id', 'proposal_revision', 'receipt_sequence'))):
            raise ValueError('Stale conversation review identity')
        return entry

    def normalize(self, entry, value, choice, paths):
        if (value['id'] != entry['token'] or value['root'] != self.root
                or value['sequence'] != entry['receipt_sequence'] + 1
                or value['intent'] != {'choice': choice, 'paths': paths}
                or [item['path'] for item in value['decisions']] != self.selection):
            raise ValueError('Writer receipt does not confirm this intent')
        states = copy.deepcopy(value['decisions'])
        if entry['inherited']:
            for item, inherited in zip(states, entry['inherited']):
                if inherited['state'] != 'pending':
                    if item['state'] != 'unchanged':
                        raise ValueError('A decided file was reopened')
                    item['state'] = inherited['state']
        phase = value['phase']
        failed = phase not in ('review_ready', 'applied', 'rejected', 'cancelled')
        for before, after in zip(entry['files'], states):
            expected = before['state']
            selected = before['path'] in paths and expected == 'pending'
            if selected:
                expected = {'approve': 'accepted', 'reject': 'rejected', 'cancel': 'cancelled'}[choice]
            allowed = {expected} if not failed or before['state'] != 'pending' else {'blocked', 'uncertain'} | ({expected} if selected else set())
            if after['state'] not in allowed:
                raise ValueError('Writer receipt changed unrelated decisions')
        if not failed:
            phase = ('cancelled' if choice == 'cancel' else 'review_ready' if any(item['state'] == 'pending' for item in states)
                     else 'applied' if any(item['state'] == 'accepted' for item in states) else 'rejected')
        result = dict(round_id=entry['round_id'], proposal_revision=entry['proposal_revision'],
                      proposal_token=entry['token'], sequence=value['sequence'], phase=phase,
                      decisions=states, cleanup_pending=value['cleanup_pending'])
        entry['files'], entry['receipt_sequence'] = states, value['sequence']
        entry['journal_files'] = copy.deepcopy(value['decisions'])
        self.context = copy.deepcopy(states)
        # Terminal failures consume pending authority too. Preserve their
        # context, but do not invent another cancel decision during close.
        if not any(item['state'] == 'pending' for item in states):
            self.current = None
        return result

    def receipt(self, command):
        entry = self.match(command)
        if 'remaining' in command and (command['remaining'] is not True or 'path' in command):
            raise ValueError('Invalid remaining-file decision')
        paths = [item['path'] for item in entry['files'] if item['state'] == 'pending'
                 and (command.get('remaining') is True or item['path'] == command.get('path'))]
        if not paths:
            raise ValueError('Only pending selected files can receive a decision')
        value = decisions.read_receipt(entry['manifest'], entry['token'])
        return self.normalize(entry, value, command['choice'], paths)

    def begin_revision(self, command):
        entry = self.match(command)
        expected = {key: command[key] for key in ('round_id', 'proposal_revision', 'proposal_token', 'receipt_sequence')}
        expected['files'] = entry['files']
        if self.pending is not None or command['context'] != expected:
            raise ValueError('Review context changed before revision')
        pending = decisions.PendingReview(entry['manifest'], entry['token'], self.root,
                                          [item['state'] for item in entry['journal_files']])
        self.pending = pending
        context = pending.snapshot()
        selected, _ = staging.selected_files({'root': self.root, 'files': command['sources']})
        for item, source in zip(selected, context['files']):
            if item['identity'] != source['identity'] or item['expected'] != source['expected']:
                raise ValueError('Review source changed before revision')
            item['context_only'] = source['context_only']
            item['seed'] = item['before'] if source['context_only'] else source['seed']
        self.revision = {'context': copy.deepcopy(expected), 'selected': selected, 'entry': entry}
        return selected

    def validate_revision(self):
        if self.pending is None or self.revision is None:
            raise ValueError('No pending revision ownership')
        self.pending.snapshot()
        for item in self.revision['selected']:
            data, mode, identity = staging.snapshot(self.root, item['path'])
            if identity != item['identity'] or staging.fingerprint(data, mode) != item['expected']:
                raise ValueError('Review source changed during revision')

    def evidence(self, status):
        # Only the editor adapter may upgrade context_valid after checking
        # captured buffers/aliases and frozen panels in the owning Neovim.
        return dict(copy.deepcopy(self.revision['context']), status=status, context_valid=False)

    def finish_revision(self, frozen, turn_id):
        self.validate_revision()
        unchanged_seed = all(item['newText'].encode() == selected.get('seed', selected['before'])
                             for item, selected in zip(frozen['files'], self.revision['selected']))
        if unchanged_seed:
            staging.discard_workspace(Path(frozen['proposal']).parent)
            self.validate_revision()
            result = dict(outcome='answer', prior_review=self.evidence('active'), candidates_retired=True)
        else:
            self.pending.retire(frozen['proposal'], frozen['id'])
            prior, previous = self.evidence('retired'), self.revision['entry']
            result = dict(outcome='review', prior_review=prior, **self.install(frozen, turn_id, previous=previous))
        self.pending.close()
        self.pending = self.revision = None
        return result

    def restore_revision(self):
        self.validate_revision()
        evidence = self.evidence('active')
        self.pending.close()
        self.pending = self.revision = None
        return dict(prior_review=evidence, candidates_retired=True)

    def retire_all(self):
        if self.current is None:
            return {}
        entry = self.current
        paths = [item['path'] for item in entry['files'] if item['state'] == 'pending']
        try:
            value = self.pending.cancel() if self.pending is not None else decisions.retire_review(entry['manifest'], entry['token'])
        finally:
            if self.pending is not None:
                self.pending.close()
                self.pending = None
                self.revision = None
        return {'receipt': self.normalize(entry, value, 'cancel', paths)}
