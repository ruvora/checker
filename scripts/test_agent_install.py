#!/usr/bin/env python3
"""Exercise agent installation and its post-approval handoff in an isolated home.

For an unsigned local build, the installer must stop before execution. This test
harness then starts our locally built app to exercise the handoff; it does not
grant or claim macOS approval, or change Gatekeeper/quarantine settings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run([str(value) for value in command], capture_output=True, **kwargs)


def stop_owned_test_app(app):
    expected = str(app / 'Contents/MacOS/Checker')
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == expected:
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', nargs='?', type=Path)
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    image = (args.dmg or ROOT / ('dist/Checker-' + version + '-macOS-arm64.dmg')).resolve()
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='checker-agent-e2e-') as temporary:
        home = Path(temporary).resolve() / "테스트 user's home"
        home.mkdir()
        app = home / 'Applications/Checker.app'
        data = home / 'Library/Application Support/Checker'
        claude = home / 'Library/Application Support/Claude/claude_desktop_config.json'
        claude.parent.mkdir(parents=True)
        original_config = {'preferences': {'keep': True}, 'mcpServers': {'other': {'command': 'preserve-me'}}}
        claude.write_text(json.dumps(original_config))
        environment = dict(os.environ, CHECKER_DATA_DIR=str(data), CHECKER_NO_LAUNCH='1')
        captured = run([sys.executable, ROOT / 'bridge/checker_bridge.py', 'add', '--title', '기존 항목 보존 검사', '--category', 'review', '--wait', '0'], env=environment)
        assert captured.returncode == 0, captured.stderr
        imported = run([ROOT / '.build/release/Checker', '--import-only', '--data-dir', data])
        assert imported.returncode == 0, imported.stderr
        original_data = (data / 'checklist.json').read_bytes()
        all_children = []
        approval_handoffs = 0
        try:
            for language in ['en', 'ko']:
                installed = run(['/bin/bash', ROOT / 'install.sh', '--yes', '--local-dmg', image, '--sha256', digest,
                                 '--version', version, '--connections', 'all', '--language', language, '--install-home', home, '--timeout', '8'])
                result = json.loads(installed.stdout)
                assert installed.returncode in (0, 2), (result, installed.stderr.decode())
                request_id = result['requestID']
                if installed.returncode == 2:
                    assert result['status'] == 'needs_user_action'
                    assert result['stage'] == 'macos_approval'
                    pending = json.loads((data / 'installations/pending.json').read_text())
                    assert pending['requestID'] == request_id
                    assert not (data / ('installations/' + request_id + '.json')).exists()
                    approval_handoffs += 1
                    child = subprocess.Popen([str(app / 'Contents/MacOS/Checker'), '--data-dir', str(data)],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    all_children.append(child)
                    threading.Thread(target=child.wait, daemon=True).start()
                receipt = data / ('installations/' + request_id + '.json')
                for _ in range(100):
                    if receipt.exists():
                        value = json.loads(receipt.read_text())
                        if value['status'] in ('configured', 'error'):
                            break
                    time.sleep(0.1)
                else:
                    raise AssertionError('The locally built app did not write a setup receipt')
                assert value['status'] == 'configured', value
                assert value['language'] == language
                assert set(value['connectionsRegistered']) == {'codex', 'chrome', 'claude'}
                assert 'chrome_extension_add_or_reload' in value['remainingActions']
                assert not (data / 'installations/pending.json').exists()
                status = run(['/bin/bash', ROOT / 'install.sh', '--status', request_id, '--install-home', home])
                assert status.returncode == 0, (status.stdout.decode(), status.stderr.decode())
                assert json.loads(status.stdout)['status'] == 'configured'
                assert (data / 'checklist.json').read_bytes() == original_data
                saved = json.loads(claude.read_text())
                assert saved['mcpServers']['other'] == original_config['mcpServers']['other']
                assert saved['preferences'] == original_config['preferences']
                helper = home / '.codex/skills/checker-capture/scripts/checker'
                categories = run([helper, 'categories'], env=environment)
                assert categories.returncode == 0, categories.stderr
                assert json.loads(categories.stdout)['language'] == language
                checked = run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
                assert checked.returncode == 0, checked.stderr
            assert any((data / 'app-backups').iterdir()), 'Update did not preserve the previous app'
            assert json.loads(claude.with_suffix('.json.checker-backup').read_text()) == original_config
            print(json.dumps({'status': 'passed', 'freshInstallAndUpdate': True,
                'macOSApprovalHandoffsPreserved': approval_handoffs, 'automaticSetupAfterLaunch': True,
                'englishAndKorean': True, 'existingChecklistAndOtherConnectorsPreserved': True,
                'receiptStatusVerified': True, 'bundledSignatureStillValid': True}, indent=2))
        finally:
            stop_owned_test_app(app)
            for child in all_children:
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == '__main__':
    main()
