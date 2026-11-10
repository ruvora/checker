import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checker_distribution_install', ROOT / 'bridge/install_connections.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class DistributionInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-distribution-unit-')
        self.base = Path(self.temp.name)
        self.home = self.base / 'Test user'
        self.home.mkdir()
        self.app = self.base / "앱's folder/Checker.app"
        resources = self.app / 'Contents/Resources'
        (resources / 'python/bin').mkdir(parents=True)
        python = resources / 'python/bin/python3'
        # The full runtime is exercised by scripts/test_distribution.py. This
        # fixture tests quoting and the installer's routing independently.
        python.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
        python.chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': installer.BUNDLE_ID, 'CFBundleShortVersionString': '0.2.0'}))
        payload = resources / 'capture'
        payload.mkdir()
        shutil.copy2(ROOT / 'bridge/checker_bridge.py', payload / 'checker_bridge.py')
        shutil.copy2(ROOT / 'localization/strings.json', payload / 'strings.json')
        shutil.copytree(ROOT / 'extension', payload / 'extension')
        shutil.copytree(ROOT / '.agents/skills/checker-capture', payload / 'skills/checker-capture')
        self.previous_umask = os.umask(0o077)

    def tearDown(self):
        os.umask(self.previous_umask)
        self.temp.cleanup()

    def test_launchers_handle_spaces_quotes_and_use_embedded_interpreter(self):
        result = installer.install(self.app, self.home, claude=True)
        runtime = self.home / 'Library/Application Support/Checker/runtime'
        config = json.loads((self.home / 'Library/Application Support/Claude/claude_desktop_config.json').read_text())
        self.assertEqual(config['mcpServers']['checker']['command'], str(runtime / 'python3'))
        self.assertEqual(result['extensionID'], 'fmkkbfaiooipnadanpbngibfnndonchn')
        environment = dict(os.environ, HOME=str(self.home), CHECKER_DATA_DIR=str(self.home / 'isolated-data'), CHECKER_NO_LAUNCH='1')
        helper = self.home / '.codex/skills/checker-capture/scripts/checker'
        process = subprocess.run([str(helper), 'categories'], env=environment, capture_output=True, text=True, check=True)
        self.assertEqual(len(json.loads(process.stdout)['categories']), 4)

    def test_relocation_refreshes_connections_preserving_user_data_and_claude_settings(self):
        config = self.home / 'Library/Application Support/Claude/claude_desktop_config.json'
        original = {'mcpServers': {'other': {'command': 'leave-this'}}, 'preferences': {'keep': True}}
        installer.write_json(config, original)
        data = self.home / 'Library/Application Support/Checker/checklist.json'
        installer.write_json(data, {'testSentinel': 'existing checklist'})
        original_data = data.read_bytes()
        installer.install(self.app, self.home, claude=True)
        moved = self.base / 'Applications/Checker.app'
        moved.parent.mkdir()
        shutil.move(self.app, moved)
        installer.install(moved, self.home, claude=True)
        installer.install(moved, self.home, claude=True)
        saved = json.loads(config.read_text())
        self.assertEqual(saved['mcpServers']['other'], original['mcpServers']['other'])
        self.assertTrue(saved['preferences']['keep'])
        self.assertEqual(json.loads(config.with_suffix('.json.checker-backup').read_text()), original)
        self.assertEqual(data.read_bytes(), original_data)
        wrapper = self.home / 'Library/Application Support/Checker/runtime/python3'
        self.assertIn(str(moved), wrapper.read_text())
        self.assertNotIn(str(self.app), wrapper.read_text())

    def test_unknown_claude_connection_is_preserved_before_any_adapters_change(self):
        config = self.home / 'Library/Application Support/Claude/claude_desktop_config.json'
        original = {'mcpServers': {'checker': {'command': 'unrelated', 'args': []}}}
        installer.write_json(config, original)
        with self.assertRaises(ValueError):
            installer.install(self.app, self.home, claude=True)
        self.assertEqual(json.loads(config.read_text()), original)
        self.assertFalse((self.home / 'Library/Application Support/Checker/runtime').exists())

    def test_existing_custom_skill_and_foreign_host_are_not_overwritten(self):
        skill = self.home / '.codex/skills/checker-capture'
        skill.mkdir(parents=True)
        (skill / 'custom.txt').write_text('keep')
        with self.assertRaises(ValueError):
            installer.install(self.app, self.home)
        self.assertEqual((skill / 'custom.txt').read_text(), 'keep')
        host = self.home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json'
        installer.write_json(host, {'path': '/some/other/host'})
        with self.assertRaises(ValueError):
            installer.install(self.app, self.home, codex=False)
        self.assertEqual(json.loads(host.read_text())['path'], '/some/other/host')

    def test_development_install_upgrades_to_bundled_python_without_losing_env(self):
        runtime = self.home / 'Library/Application Support/Checker/runtime'
        config = self.home / 'Library/Application Support/Claude/claude_desktop_config.json'
        installer.write_json(config, {'mcpServers': {'checker': {'command': '/usr/bin/python3',
            'args': [str(runtime / 'checker_bridge.py'), 'mcp'], 'env': {'KEEP_THIS': 'yes'}}}})
        installer.install(self.app, self.home, claude=True)
        entry = json.loads(config.read_text())['mcpServers']['checker']
        self.assertEqual(entry['env'], {'KEEP_THIS': 'yes'})
        self.assertEqual(entry['command'], str(runtime / 'python3'))


    def test_claude_code_gets_a_working_user_scope_server_and_keeps_its_settings(self):
        config = self.home / '.claude.json'
        original = {'numStartups': 7, 'projects': {'/work': {'mcpServers': {'local': {'command': 'keep'}}}},
                    'mcpServers': {'other': {'command': 'leave-this'}}}
        installer.write_json(config, original)
        result = installer.install(self.app, self.home, codex=False, chrome=False, claude_code=True)
        self.assertTrue(result['claudeCode'])
        saved = json.loads(config.read_text())
        self.assertEqual(saved['numStartups'], 7)
        self.assertEqual(saved['projects'], original['projects'])
        self.assertEqual(saved['mcpServers']['other'], original['mcpServers']['other'])
        entry = saved['mcpServers']['checker']
        self.assertEqual(entry['type'], 'stdio')
        self.assertEqual(json.loads((self.home / '.claude.json.checker-backup').read_text()), original)
        # The registered command must answer an MCP handshake and list Checker's tools.
        messages = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
                    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}]
        environment = dict(os.environ, HOME=str(self.home), CHECKER_DATA_DIR=str(self.home / 'isolated-data'), CHECKER_NO_LAUNCH='1')
        process = subprocess.run([entry['command'], *entry['args']], input=''.join(json.dumps(m) + '\n' for m in messages),
                                 env=environment, capture_output=True, text=True, check=True, timeout=30)
        tools = [line for line in process.stdout.splitlines() if '"id": 2' in line or '"id":2' in line]
        self.assertIn('add_checklist_item', tools[0])
        installer.install(self.app, self.home, codex=False, chrome=False, claude_code=True)
        self.assertEqual(json.loads(config.read_text())['mcpServers']['checker'], entry)

    def test_claude_install_time_is_recorded_and_kept_when_other_connections_change(self):
        first = installer.install(self.app, self.home, codex=False, chrome=False, claude=True)
        self.assertIsInstance(first['claudeInstalledAt'], float)
        # No ~/.claude.json yet: Claude Code registration must create it.
        later = installer.install(self.app, self.home, codex=False, chrome=False, claude_code=True)
        self.assertEqual(later['claudeInstalledAt'], first['claudeInstalledAt'])
        self.assertIn('checker', json.loads((self.home / '.claude.json').read_text())['mcpServers'])

    def test_unknown_claude_code_connection_is_preserved(self):
        config = self.home / '.claude.json'
        original = {'mcpServers': {'checker': {'command': 'someone-else', 'args': ['other.py']}}}
        installer.write_json(config, original)
        with self.assertRaises(ValueError):
            installer.install(self.app, self.home, codex=False, chrome=False, claude_code=True)
        self.assertEqual(json.loads(config.read_text()), original)
        self.assertFalse((self.home / 'Library/Application Support/Checker/runtime').exists())

if __name__ == '__main__':
    unittest.main()
