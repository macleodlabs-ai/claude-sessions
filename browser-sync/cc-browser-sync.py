#!/usr/bin/env python3
"""Opt-in browser handoff. No Claude credentials or transcripts are read."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
HOST = 'ai.macleodlabs.claude_sessions'
EVENTS = {'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'Stop', 'SessionEnd'}
TOOL = re.compile(r'^mcp__claude-in-chrome__')


def read_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


class Coordinator:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    @contextlib.contextmanager
    def locked(self):
        with (self.root / 'lock').open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = read_json(self.root / 'state.json', {'owner': None})
            yield state
            write_json(self.root / 'state.json', state)

    def config(self):
        return read_json(self.root / 'config.json', {'mappings': {}})

    def hook(self, event, config_dir):
        kind = event.get('hook_event_name')
        if kind not in EVENTS:
            raise ValueError('Unsupported hook event')
        sid = event.get('session_id')
        if not isinstance(sid, str) or not sid:
            raise ValueError('Hook session_id is missing')
        if not config_dir:
            raise ValueError('CLAUDE_CONFIG_DIR is missing; use a cc-<client> launcher')
        config_dir = str(Path(config_dir).expanduser().resolve())
        key = [config_dir, sid]
        if kind == 'PreToolUse' and not TOOL.match(event.get('tool_name', '')):
            return None
        with self.locked() as state:
            owner = state['owner']
            if kind in ('SessionStart', 'UserPromptSubmit'):
                # Keep metadata only, never prompts or transcript paths.
                state['last_interaction'] = {'key': key, 'time': time.time()}
                return None
            if kind in ('Stop', 'SessionEnd'):
                if owner and owner['key'] == key and owner['phase'] == 'ready':
                    state['owner'] = None
                # Unconfirmed/failed handoffs stay reserved until retry or explicit
                # recovery. A Stop after a denied tool must not discard the request.
                return None
            mapping = self.config()['mappings'].get(config_dir)
            if not mapping:
                return 'No browser account mapped to this config directory. Run browser-sync bind.'
            if owner and owner['key'] != key:
                return 'Chrome is reserved by another session. Finish/release its browser work first.'
            if owner and owner['mapping'] != mapping:
                return 'Account mapping changed during browser ownership. Release and retry.'
            if not owner:
                owner = {'key': key, 'mapping': mapping, 'request_id': str(uuid.uuid4()),
                         'phase': 'pending', 'created_at': time.time()}
                state['owner'] = owner
            if owner['phase'] == 'ready':
                if time.time() - owner.get('verified_at', 0) > 6:
                    return 'Browser helper identity check is stale or disconnected; wait for the companion and retry.'
                return None
            return ('Browser handoff is not verified. Open Claude Sessions Browser Sync in Chrome; '
                    'check/sign into the official Claude extension as ' + mapping['email'] +
                    ', confirm the matching email, then retry. Do not substitute another browser tool.')

    def bridge(self, msg):
        op = msg.get('op')
        with self.locked() as state:
            owner = state['owner']
            if op == 'poll':
                return {'owner': owner}
            if op == 'begin':
                if not owner or owner['request_id'] != msg.get('request_id') or owner['phase'] != 'pending':
                    raise ValueError('Handoff is no longer pending')
                owner['phase'] = 'switching'
                return {'owner': owner}
            if op in ('prepared', 'failed', 'confirm', 'invalidate', 'verify-ready'):
                if not owner or owner['request_id'] != msg.get('request_id'):
                    raise ValueError('Stale handoff')
                if op == 'verify-ready':
                    if owner['phase'] != 'ready' or msg.get('email') != owner['mapping']['email']:
                        raise ValueError('Browser identity changed')
                    owner['verified_at'] = time.time()
                elif op == 'prepared':
                    if owner['phase'] != 'switching' or msg.get('email') != owner['mapping']['email']:
                        raise ValueError('Website identity does not match the requested account')
                    owner['phase'] = 'awaiting-confirmation'
                elif op == 'confirm':
                    if owner['phase'] != 'awaiting-confirmation' or msg.get('email') != owner['mapping']['email']:
                        raise ValueError('Cannot confirm this handoff')
                    owner['phase'] = 'ready'
                    owner['verified_at'] = time.time()
                elif op == 'invalidate':
                    owner['phase'] = 'failed'
                    owner['error'] = 'Browser authentication changed; release and retry.'
                else:
                    owner['phase'] = 'failed'
                    # No raw browser/native errors or cookie values in persistent state.
                    owner['error'] = 'Browser preparation failed. Check saved login, release and retry.'
                return {'owner': owner}
            if op in ('save', 'load', 'snapshot-current'):
                if owner and op == 'save':
                    raise ValueError('Finish/release browser work before saving an account')
                if op == 'snapshot-current':
                    if not owner or owner['request_id'] != msg.get('request_id') or owner['phase'] != 'switching':
                        raise ValueError('Stale snapshot request')
                    op = 'save'
                account = msg.get('account', '')
                if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', account):
                    raise ValueError('Invalid account alias')
                binary = ROOT / 'keychain'
                payload = json.dumps(msg.get('snapshot')) if op == 'save' else ''
                result = subprocess.run([str(binary), op, account], input=payload,
                                        text=True, capture_output=True, timeout=30)
                if result.returncode:
                    raise ValueError('Keychain operation failed; unlock Keychain or register this account')
                return {'snapshot': json.loads(result.stdout)} if op == 'load' else {}
            raise ValueError('Unknown bridge operation')


def native(coord):
    # Chrome native messaging: native-endian uint32 length + UTF-8 JSON.
    while True:
        prefix = sys.stdin.buffer.read(4)
        if not prefix:
            return
        if len(prefix) != 4:
            raise ValueError('Truncated native frame')
        size = struct.unpack('=I', prefix)[0]
        if size > 1024 * 1024:
            raise ValueError('Native frame too large')
        raw = sys.stdin.buffer.read(size)
        if len(raw) != size:
            raise ValueError('Truncated native payload')
        message = {}
        try:
            message = json.loads(raw)
            reply = {'id': message.get('id'), 'ok': True, **coord.bridge(message)}
        except Exception:
            reply = {'id': message.get('id') if isinstance(message, dict) else None, 'ok': False, 'error': 'Browser sync operation failed. Check status and account registration.'}
        data = json.dumps(reply).encode()
        sys.stdout.buffer.write(struct.pack('=I', len(data)) + data)
        sys.stdout.buffer.flush()


def hook_entries(root, state_dir):
    command = (shlex.quote(sys.executable) + ' ' + shlex.quote(str(root / 'cc-browser-sync.py')) +
               ' --state-dir ' + shlex.quote(str(state_dir)) + ' hook')
    return {event: {'hooks': [{'type': 'command', 'command': command, 'timeout': 10}],
                    **({'matcher': '^mcp__claude-in-chrome__.*'} if event == 'PreToolUse' else {})}
            for event in EVENTS}


def wire(settings, entries, remove=False):
    data = read_json(settings, {})
    before = json.dumps(data, sort_keys=True)
    hooks = data.setdefault('hooks', {})
    for event, entry in entries.items():
        # Remove only our exact installed command, not other hooks in the group.
        kept = []
        own_command = entry['hooks'][0]['command']
        for group in hooks.get(event, []):
            others = [h for h in group.get('hooks', []) if h.get('command') != own_command]
            if others:
                kept.append({**group, 'hooks': others})
        if not remove:
            kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if before != json.dumps(data, sort_keys=True):
        if settings.exists():
            backup = settings.with_name('settings.json.browser-sync.bak')
            if not backup.exists():
                shutil.copy2(settings, backup)
                os.chmod(backup, 0o600)
        write_json(settings, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, default=ROOT / 'state')
    sub = parser.add_subparsers(dest='command', required=True)
    install = sub.add_parser('install', help='Install Mac native host after loading the unpacked extension')
    install.add_argument('--extension-id', required=True)
    bind = sub.add_parser('bind', help='Map one existing config directory and install hooks')
    bind.add_argument('config_dir', type=Path)
    bind.add_argument('account', help='Alias saved in the companion extension')
    bind.add_argument('email')
    unbind = sub.add_parser('unbind')
    unbind.add_argument('config_dir', type=Path)
    sub.add_parser('status')
    sub.add_parser('disable', help='Remove this installation’s hooks and native-host registration; keep saved logins')
    release = sub.add_parser('release', help='Explicit recovery after stopping all browser work')
    release.add_argument('--session-id', required=True)
    release.add_argument('--config-dir', required=True, type=Path)
    release.add_argument('--browser-idle', action='store_true', required=True)
    release.add_argument('--extension-disabled', action='store_true', help='Recover a crashed switch only after disabling the companion in Chrome')
    sub.add_parser('hook')
    sub.add_parser('native')
    args = parser.parse_args()
    state_dir = args.state_dir.expanduser().resolve()
    coord = Coordinator(state_dir)
    if args.command == 'install':
        if sys.platform != 'darwin':
            raise ValueError('Native host installation requires macOS')
        if not re.fullmatch('[a-p]{32}', args.extension_id):
            raise ValueError('Invalid Chrome extension ID')
        dest = Path(os.environ.get('SHARED_DIR', str(Path.home() / '.claude-shared'))) / 'browser-sync'
        if dest.resolve() != ROOT:
            shutil.copytree(ROOT, dest, dirs_exist_ok=True, ignore=shutil.ignore_patterns('state', '__pycache__', 'tests', 'keychain'))
        subprocess.run(['swiftc', str(dest / 'keychain.swift'), '-o', str(dest / 'keychain')], check=True)
        installed_state = dest / 'state'
        launcher = dest / 'native-host'
        launcher.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' +
                            shlex.quote(str(dest / 'cc-browser-sync.py')) + ' --state-dir ' +
                            shlex.quote(str(installed_state)) + ' native\n')
        launcher.chmod(0o700)
        manifest = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts' / (HOST + '.json')
        write_json(manifest, {'name': HOST, 'description': 'Claude Sessions browser handoff',
                             'path': str(launcher), 'type': 'stdio',
                             'allowed_origins': ['chrome-extension://' + args.extension_id + '/']})
        print('Installed. Use: python3 ' + str(dest / 'cc-browser-sync.py') + ' bind CONFIG_DIR ALIAS EMAIL')
    elif args.command in ('bind', 'unbind'):
        directory = args.config_dir.expanduser().resolve()
        if not directory.is_dir():
            raise ValueError('Config directory does not exist')
        with coord.locked() as state:
            if state['owner']:
                raise ValueError('Release browser ownership before changing mappings')
            config = coord.config()
            if args.command == 'bind':
                if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', args.account) or not re.fullmatch(r'[^\s@]+@[^\s@]+', args.email):
                    raise ValueError('Invalid alias or email')
                config['mappings'][str(directory)] = {'account': args.account, 'email': args.email.lower()}
            else:
                config['mappings'].pop(str(directory), None)
            wire(directory / 'settings.json', hook_entries(ROOT, state_dir), args.command == 'unbind')
            write_json(state_dir / 'config.json', config)
        print('Updated. Restart the affected Claude Code session to load hook changes.')
    elif args.command == 'disable':
        with coord.locked() as state:
            if state['owner']:
                raise ValueError('Finish/release browser work before disabling')
            config = coord.config()
            for directory in config['mappings']:
                settings = Path(directory) / 'settings.json'
                if settings.exists():
                    wire(settings, hook_entries(ROOT, state_dir), remove=True)
            write_json(state_dir / 'config.json', {'mappings': {}})
            manifest = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts' / (HOST + '.json')
            if read_json(manifest, {}).get('path') == str(ROOT / 'native-host'):
                manifest.unlink()
        print('Hooks disabled. Remove the companion extension in Chrome. Keychain logins are retained.')
    elif args.command == 'status':
        with coord.locked() as state:
            print(json.dumps({'mappings': coord.config()['mappings'], **state}, indent=2))
    elif args.command == 'release':
        with coord.locked() as state:
            owner = state['owner']
            key = [str(args.config_dir.expanduser().resolve()), args.session_id]
            if owner and owner['key'] != key:
                raise ValueError('Owner does not match; inspect status first')
            if owner and owner['phase'] == 'switching' and not args.extension_disabled:
                raise ValueError('Cookie switch still in progress. Wait for completion; do not switch underneath it.')
            state['owner'] = None
    elif args.command == 'native':
        native(coord)
    elif args.command == 'hook':
        event = json.load(sys.stdin)
        reason = coord.hook(event, os.environ.get('CLAUDE_CONFIG_DIR'))
        if reason:
            print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                  'permissionDecision': 'deny', 'permissionDecisionReason': reason}}))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('browser-sync: ' + str(exc), file=sys.stderr)
        # Exit 2 blocks PreToolUse on errors, instead of silently allowing it.
        sys.exit(2)
