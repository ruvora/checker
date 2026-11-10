import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checker_setup', ROOT / 'scripts/setup_integrations.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-install-test-')
        self.base = Path(self.temp.name)
        self.project = self.base / 'Desktop/project'
        self.home = self.base / 'user'
        self.home.mkdir()
        for folder in ['bridge', 'extension', 'localization', 'build/Checker.app/Contents/MacOS', '.agents/skills']:
            (self.project / folder).mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'bridge/checker_bridge.py', self.project / 'bridge/checker_bridge.py')
        shutil.copy2(ROOT / 'localization/strings.json', self.project / 'localization/strings.json')
        shutil.copy2(ROOT / 'extension/manifest.json', self.project / 'extension/manifest.json')
        shutil.copytree(ROOT / '.agents/skills/checker-capture', self.project / '.agents/skills/checker-capture')
        (self.project / 'build/Checker.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.checker.prototype'}))
        (self.project / 'build/Checker.app/Contents/MacOS/Checker').write_text('test fixture')
        self.previous_root = setup.ROOT
        setup.ROOT = self.project
        self.previous_umask = os.umask(0o077)

    def tearDown(self):
        setup.ROOT = self.previous_root
        os.umask(self.previous_umask)
        self.temp.cleanup()

    def install(self):
        with patch.object(Path, 'home', return_value=self.home), patch.object(sys, 'argv', ['setup', '--install', '--claude']), contextlib.redirect_stdout(io.StringIO()):
            setup.main()

    def test_installed_adapters_do_not_depend_on_the_desktop_project(self):
        self.install()
        runtime = self.home / 'Library/Application Support/Checker/runtime'
        config = json.loads((self.home / 'Library/Application Support/Claude/claude_desktop_config.json').read_text())
        self.assertEqual(config['mcpServers']['checker']['args'][0], str(runtime / 'checker_bridge.py'))
        host = json.loads((self.home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json').read_text())
        self.assertEqual(host['path'], str(runtime / 'native-host'))
        installed_skill = self.home / '.codex/skills/checker-capture'
        self.assertEqual(installed_skill.resolve(), (runtime / 'skills/checker-capture').resolve())
        # Remove the development tree: installed scripts must remain functional.
        shutil.rmtree(self.project)
        env = dict(os.environ, CHECKER_DATA_DIR=str(self.home / 'test-data'), CHECKER_NO_LAUNCH='1')
        result = subprocess.run([sys.executable, str(installed_skill / 'scripts/checker.py'), 'categories'], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(len(json.loads(result.stdout)['categories']), 4)
        runtime_info = json.loads((runtime / 'runtime-config.json').read_text())
        self.assertEqual(runtime_info['appPath'], str(self.home / 'Applications/Checker.app'))

    def test_upgrade_preserves_other_claude_connections_and_existing_settings(self):
        config = self.home / 'Library/Application Support/Claude/claude_desktop_config.json'
        original = {'mcpServers': {'other': {'command': 'keep-me'}, 'checker': {'command': '/usr/bin/python3', 'args': [str(self.project / 'bridge/checker_bridge.py'), 'mcp'], 'env': {'KEEP_SETTING': 'yes'}}}, 'preferences': {'keep': True}}
        setup.write_json(config, original)
        host = self.home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json'
        setup.write_json(host, {'path': str(self.project / 'scripts/native-host')})
        skill = self.home / '.codex/skills/checker-capture'
        skill.parent.mkdir(parents=True)
        skill.symlink_to(self.project / '.agents/skills/checker-capture')
        self.install()
        self.install()
        saved = json.loads(config.read_text())
        self.assertEqual(saved['mcpServers']['other'], original['mcpServers']['other'])
        self.assertEqual(saved['mcpServers']['checker']['env'], {'KEEP_SETTING': 'yes'})
        self.assertTrue(saved['preferences']['keep'])
        self.assertEqual(json.loads(config.with_suffix('.json.checker-backup').read_text()), original)


if __name__ == '__main__':
    unittest.main()
