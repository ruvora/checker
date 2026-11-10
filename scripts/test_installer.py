#!/usr/bin/env python3
"""Verify fresh install, same-version no-op and update without launching the app."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    version = (ROOT / 'VERSION').read_text().strip()
    image = ROOT / ('dist/Checker-' + version + '-macOS-arm64.dmg')
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='checker-install-check-') as temporary:
        home = Path(temporary).resolve() / "테스트 user's home"
        home.mkdir()
        data = home / 'Library/Application Support/Checker'
        data.mkdir(parents=True)
        store = data / 'checklist.json'
        original = b'{"schemaVersion":1,"categories":[],"items":[]}\n'
        store.write_bytes(original)
        app = home / 'Applications/Checker.app'
        info_file = app / 'Contents/Info.plist'
        backups = data / 'app-backups'
        command = ['/bin/bash', str(ROOT / 'install.sh'), '--yes', '--local-dmg', str(image),
                   '--sha256', digest, '--version', version, '--install-home', str(home)]
        def install():
            result = subprocess.run(command, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            assert store.read_bytes() == original
            assert not (data / 'installations').exists()
            assert not (data / 'runtime').exists(), 'Installer configured connections instead of leaving the app button in control'
            return result.stdout
        assert 'Installed Checker' in install()
        assert 'CheckerAgentInstallVersion' not in plistlib.loads(info_file.read_bytes())
        stamp = info_file.stat().st_mtime_ns
        inode = app.stat().st_ino
        assert 'Already installed' in install()
        assert info_file.stat().st_mtime_ns == stamp and app.stat().st_ino == inode
        assert not backups.exists()
        # Simulate an older owned app; the installer must preserve it on update.
        info = plistlib.loads(info_file.read_bytes())
        info['CFBundleShortVersionString'] = '0.0.0'
        info_file.write_bytes(plistlib.dumps(info))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        assert 'Installed Checker' in install()
        saved = list(backups.glob('*/Checker.app'))
        assert len(saved) == 1
        assert plistlib.loads((saved[0] / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '0.0.0'
        assert 'Already installed' in install()
        assert len(list(backups.glob('*/Checker.app'))) == 1
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
        print(json.dumps({'status': 'passed', 'freshInstall': True, 'sameVersionLeftUnchanged': True,
                          'updatePreservesPreviousAppAndData': True, 'noSetupStateOrConnectionChanges': True}, indent=2))


if __name__ == '__main__':
    main()
