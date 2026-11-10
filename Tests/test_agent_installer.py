import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin' and os.getuid() != 0, 'macOS user installer')
class AgentInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-agent-installer-')
        self.home = Path(self.temp.name) / "테스트 user's home"
        self.home.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_installer(self, *arguments):
        result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--install-home', str(self.home), *arguments], capture_output=True, text=True)
        return result, json.loads(result.stdout)

    def test_plan_has_no_installation_side_effects(self):
        result, report = self.run_installer('--plan', '--connections', 'all', '--language', 'en')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['status'], 'planned')
        self.assertEqual(list(self.home.iterdir()), [])

    def test_checksum_mismatch_never_mounts_or_installs_the_app(self):
        image = self.home / 'fake.dmg'
        image.write_bytes(b'a synthetic disk image')
        result, report = self.run_installer('--yes', '--local-dmg', str(image), '--sha256', '0' * 64)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['status'], 'error')
        self.assertIn('checksum', report['message'])
        self.assertFalse((self.home / 'Applications').exists())

    def test_different_application_is_preserved_before_download(self):
        app = self.home / 'Applications/Checker.app/Contents'
        app.mkdir(parents=True)
        original = plistlib.dumps({'CFBundleIdentifier': 'someone.elses.app'})
        (app / 'Info.plist').write_bytes(original)
        result, report = self.run_installer('--yes')
        self.assertEqual(result.returncode, 1)
        self.assertIn('different app', report['message'])
        self.assertEqual((app / 'Info.plist').read_bytes(), original)

    def test_invalid_profile_and_status_id_cannot_write_settings(self):
        for arguments in [('--yes', '--connections', 'chrome,unknown'), ('--status', '../../other-file'), ('--plan', '--version', 'v0.4.0/../other')]:
            result, report = self.run_installer(*arguments)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(report['status'], 'error')
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
