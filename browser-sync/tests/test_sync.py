import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'cc-browser-sync.py'
spec = importlib.util.spec_from_file_location('sync', MODULE)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.coord = sync.Coordinator(self.root / 'state')
        self.a = self.root / 'a'
        self.b = self.root / 'b'
        self.a.mkdir()
        self.b.mkdir()
        sync.write_json(self.coord.root / 'config.json', {'mappings': {
            str(self.a): {'account': 'a', 'email': 'a@example.com'},
            str(self.b): {'account': 'b', 'email': 'b@example.com'}}})

    def event(self, kind='PreToolUse', sid='session-a', tool='mcp__claude-in-chrome__navigate'):
        return {'hook_event_name': kind, 'session_id': sid, 'tool_name': tool,
                'prompt': 'PRIVATE PROMPT', 'transcript_path': '/private/transcript'}

    def owner(self):
        return self.coord.bridge({'op': 'poll'})['owner']

    def ready(self):
        self.coord.hook(self.event(), str(self.a))
        request = self.owner()['request_id']
        for op in ('begin', 'prepared', 'confirm'):
            self.coord.bridge({'op': op, 'request_id': request, 'email': 'a@example.com'})
        return request

    def test_unmapped_and_missing_context_denied(self):
        self.assertIn('No browser account', self.coord.hook(self.event(), str(self.root)))
        with self.assertRaises(ValueError):
            self.coord.hook(self.event(), None)
        with self.assertRaises(ValueError):
            self.coord.hook({'hook_event_name': 'PreToolUse'}, str(self.a))

    def test_unrelated_tools_do_not_claim_browser(self):
        self.assertIsNone(self.coord.hook(self.event(tool='Bash'), str(self.a)))
        self.assertIsNone(self.owner())

    def test_account_handoff_and_turn_release(self):
        self.assertIn('not verified', self.coord.hook(self.event(), str(self.a)))
        self.ready()
        self.assertIsNone(self.coord.hook(self.event(), str(self.a)))
        self.assertIn('another session', self.coord.hook(self.event(sid='b'), str(self.b)))
        self.coord.hook(self.event('Stop'), str(self.a))
        self.assertIsNone(self.owner())
        self.coord.hook(self.event(sid='b'), str(self.b))
        self.assertEqual(self.owner()['mapping']['email'], 'b@example.com')
        self.assertEqual(self.owner()['phase'], 'pending')

    def test_shared_session_id_does_not_share_ownership(self):
        self.ready()
        self.assertIn('another session', self.coord.hook(self.event(), str(self.b)))
        self.coord.hook(self.event('SessionEnd'), str(self.b))
        self.assertIsNotNone(self.owner())

    def test_wrong_or_stale_confirmation_never_allows(self):
        self.coord.hook(self.event(), str(self.a))
        request = self.owner()['request_id']
        for msg in [
            {'op': 'confirm', 'request_id': request, 'email': 'a@example.com'},
            {'op': 'begin', 'request_id': 'old'},
        ]:
            with self.assertRaises(ValueError): self.coord.bridge(msg)
        self.coord.bridge({'op': 'begin', 'request_id': request})
        with self.assertRaises(ValueError):
            self.coord.bridge({'op': 'prepared', 'request_id': request, 'email': 'b@example.com'})
        self.assertEqual(self.owner()['phase'], 'switching')

    def test_stop_preserves_pending_for_human_verification(self):
        self.coord.hook(self.event(), str(self.a))
        request = self.owner()['request_id']
        self.coord.hook(self.event('Stop'), str(self.a))
        self.assertEqual(self.owner()['request_id'], request)

    def test_expired_heartbeat_and_identity_changes_block(self):
        request = self.ready()
        with self.coord.locked() as state:
            state['owner']['verified_at'] = 0
        self.assertIn('stale', self.coord.hook(self.event(), str(self.a)))
        with self.assertRaises(ValueError):
            self.coord.bridge({'op': 'verify-ready', 'request_id': request, 'email': 'b@example.com'})
        self.coord.bridge({'op': 'invalidate', 'request_id': request})
        self.assertIn('not verified', self.coord.hook(self.event(), str(self.a)))

    def test_mapping_change_cannot_reuse_ready_owner(self):
        self.ready()
        config = self.coord.config()
        config['mappings'][str(self.a)]['email'] = 'changed@example.com'
        sync.write_json(self.coord.root / 'config.json', config)
        self.assertIn('mapping changed', self.coord.hook(self.event(), str(self.a)))

    def test_prompt_and_transcript_never_persist(self):
        self.coord.hook(self.event('UserPromptSubmit'), str(self.a))
        text = (self.coord.root / 'state.json').read_text()
        self.assertNotIn('PRIVATE', text)
        self.assertNotIn('transcript', text)
        self.assertEqual((self.coord.root / 'state.json').stat().st_mode & 0o777, 0o600)

    def test_lock_contention_fails_instead_of_waiting_for_hook_timeout(self):
        with self.coord.locked():
            with self.assertRaises(BlockingIOError): self.coord.hook(self.event(), str(self.a))

    def test_settings_merge_idempotence_and_precise_removal(self):
        settings = self.a / 'settings.json'
        original = {'model': 'test', 'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [
            {'type': 'command', 'command': 'user-script'}]}]}}
        sync.write_json(settings, original)
        entries = sync.hook_entries(Path('/path with spaces'), self.coord.root)
        sync.wire(settings, entries)
        first = settings.read_text()
        sync.wire(settings, entries)
        self.assertEqual(settings.read_text(), first)
        sync.wire(settings, entries, remove=True)
        self.assertEqual(json.loads(settings.read_text()), original)
        self.assertEqual(json.loads(settings.with_name('settings.json.browser-sync.bak').read_text()), original)

    def test_corrupt_settings_not_overwritten(self):
        settings = self.a / 'settings.json'
        settings.write_text('{bad')
        with self.assertRaises(json.JSONDecodeError):
            sync.wire(settings, sync.hook_entries(sync.ROOT, self.coord.root))
        self.assertEqual(settings.read_text(), '{bad')

    def cli(self, *args, input=None, env=None):
        return subprocess.run([sys.executable, str(MODULE), '--state-dir', str(self.coord.root), *args],
                              input=input, capture_output=True, env=env)

    def test_real_hook_cli_denies_and_errors_block(self):
        env = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.a))
        result = self.cli('hook', input=json.dumps(self.event()).encode(), env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'], 'deny')
        result = self.cli('hook', input=b'{invalid', env=env)
        self.assertEqual(result.returncode, 2)

    def test_native_framing_roundtrip(self):
        payload = json.dumps({'id': 'test', 'op': 'poll'}).encode()
        result = self.cli('native', input=struct.pack('=I', len(payload)) + payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(struct.unpack('=I', result.stdout[:4])[0], len(result.stdout[4:]))
        self.assertEqual(json.loads(result.stdout[4:]), {'id': 'test', 'ok': True, 'owner': None})
        self.assertEqual(self.cli('native', input=struct.pack('=I', 2_000_000)).returncode, 2)

    def test_release_requires_matching_owner_and_explicit_recovery(self):
        self.coord.hook(self.event(), str(self.a))
        self.coord.bridge({'op': 'begin', 'request_id': self.owner()['request_id']})
        args = ('release', '--session-id', 'session-a', '--config-dir', str(self.a), '--browser-idle')
        self.assertEqual(self.cli(*args).returncode, 2)
        self.assertEqual(self.cli(*args, '--extension-disabled').returncode, 0)
        self.assertIsNone(self.owner())

    def test_cli_bind_unbind_preserves_user_settings(self):
        settings = self.a / 'settings.json'
        sync.write_json(settings, {'model': 'keep'})
        self.assertEqual(self.cli('bind', str(self.a), 'alias', 'A@EXAMPLE.COM').returncode, 0)
        self.assertEqual(self.coord.config()['mappings'][str(self.a)]['email'], 'a@example.com')
        self.assertEqual(self.cli('unbind', str(self.a)).returncode, 0)
        self.assertEqual(json.loads(settings.read_text()), {'model': 'keep', 'hooks': {}})


if __name__ == '__main__':
    unittest.main()
