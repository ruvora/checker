import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin' and os.getuid() != 0, 'macOS user installer')
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-installer-')
        self.home = Path(self.temp.name) / "테스트 user's home"
        self.home.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_installer(self, *arguments):
        return subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--install-home', str(self.home), *arguments], capture_output=True, text=True)

    def test_checksum_mismatch_cannot_install_the_app(self):
        image = self.home / 'fake.dmg'
        image.write_bytes(b'a synthetic disk image')
        result = self.run_installer('--yes', '--local-dmg', str(image), '--sha256', '0' * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse((self.home / 'Applications').exists())

    def test_different_application_is_preserved(self):
        app = self.home / 'Applications/Checker.app/Contents'
        app.mkdir(parents=True)
        original = plistlib.dumps({'CFBundleIdentifier': 'someone.elses.app'})
        (app / 'Info.plist').write_bytes(original)
        result = self.run_installer('--yes')
        self.assertEqual(result.returncode, 1)
        self.assertIn('different app', result.stderr)
        self.assertEqual((app / 'Info.plist').read_bytes(), original)

    def test_invalid_arguments_cannot_write_settings(self):
        for arguments in [('--version', 'v0.5.0/../other'), ('--status', 'obsolete-request')]:
            result = self.run_installer(*arguments)
            self.assertEqual(result.returncode, 1)
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
