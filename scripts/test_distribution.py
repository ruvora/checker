#!/usr/bin/env python3
"""Mount the built DMG and exercise its adapters in an isolated user's home."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run([str(value) for value in command], check=True, capture_output=True, **kwargs)


def native(host, payload, environment):
    encoded = json.dumps(payload).encode()
    output = run([host], input=struct.pack('=I', len(encoded)) + encoded, env=environment).stdout
    length = struct.unpack('=I', output[:4])[0]
    result = json.loads(output[4:4 + length])
    if result.get('status') == 'error':
        raise AssertionError(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', nargs='?', type=Path)
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    dmg = args.dmg or ROOT / ('dist/Checker-' + version + '-macOS-arm64.dmg')
    with tempfile.TemporaryDirectory(prefix='checker-dmg-verify-') as temporary:
        folder = Path(temporary)
        mount = folder / 'mounted'
        mount.mkdir()
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg])
        try:
            home = folder / "테스트 user's home"
            app = home / 'Applications/Checker.app'
            app.parent.mkdir(parents=True)
            shutil.copytree(mount / 'Checker.app', app, symlinks=True)
            assert (mount / 'Applications').is_symlink()
            assert (mount / '설치 안내.html').is_file()
            assert (mount / 'Installation Guide.html').is_file()
        finally:
            run(['/usr/bin/hdiutil', 'detach', mount])
        # The disk image is detached before setup or launch: no development or
        # mounted-image paths may be needed by any installed adapter.
        environment = dict(os.environ, HOME=str(home), PATH='/usr/bin:/bin',
                           CHECKER_DATA_DIR=str(home / 'Library/Application Support/Checker'), CHECKER_NO_LAUNCH='1')
        for name in ['PYTHONPATH', 'PYTHONHOME', 'CODEX_HOME', 'CODEX_THREAD_ID', 'OPENAI_API_KEY']:
            environment.pop(name, None)
        resources = app / 'Contents/Resources'
        python = resources / 'python/bin/python3'
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        installed = json.loads(run([python, '-I', '-B', resources / 'capture/install_connections.py',
                                   '--app-bundle', app, '--codex', '--chrome', '--claude'], env=environment).stdout)
        assert installed['status'] == 'ok', installed
        runtime = home / 'Library/Application Support/Checker/runtime'
        interpreter = run([runtime / 'python3', '-c', 'import sys; print(sys.executable)'], env=environment).stdout.decode().strip()
        assert str(app) in interpreter, interpreter
        host = runtime / 'native-host'
        assert native(host, {'action': 'set_language', 'language': 'en'}, environment)['language'] == 'en'
        assert len(native(host, {'action': 'categories'}, environment)['categories']) == 4
        assert native(host, {'action': 'categories'}, environment)['categories'][1]['name'] == 'Review'
        request_id = str(uuid.uuid4())
        queued = native(host, {'action': 'capture', 'requestID': request_id,
            'title': '설치 파일의 Chrome 연결 확인', 'sourceApp': 'chrome', 'categoryID': 'review',
            'sourceURL': 'https://example.com/pull/128#review', 'note': '합성 설치 검증 데이터'}, environment)
        assert queued['status'] == 'queued', queued
        data = Path(environment['CHECKER_DATA_DIR'])
        run([app / 'Contents/MacOS/Checker', '--import-only', '--data-dir', data], env=environment)
        assert native(host, {'action': 'status', 'requestID': request_id}, environment)['status'] == 'added'
        doc = json.loads((data / 'checklist.json').read_text())
        assert doc['items'][0]['sourceURL'] == 'https://example.com/pull/128#review'
        skill = home / '.codex/skills/checker-capture/scripts/checker'
        skill_result = json.loads(run([skill, 'categories'], env=environment).stdout)
        assert len(skill_result['categories']) == 4
        assert skill_result['language'] == 'en'
        config = json.loads((home / 'Library/Application Support/Claude/claude_desktop_config.json').read_text())
        checker = config['mcpServers']['checker']
        messages = [
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'checker-dmg-test', 'version': '1'}}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
            {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'list_categories'}}]
        output = run([checker['command'], *checker['args']], input=''.join(json.dumps(value) + '\n' for value in messages).encode(), env=environment).stdout
        replies = [json.loads(line) for line in output.splitlines()]
        tools = next(value['result']['tools'] for value in replies if value.get('id') == 2)
        assert {value['name'] for value in tools} == {'list_categories', 'add_checklist_item'}
        content = next(value['result']['content'][0]['text'] for value in replies if value.get('id') == 3)
        assert json.loads(content)['language'] == 'en'
        saved_data = (data / 'checklist.json').read_bytes()
        assert native(host, {'action': 'set_language', 'language': 'ko'}, environment)['language'] == 'ko'
        assert native(host, {'action': 'categories'}, environment)['categories'][1]['name'] == '리뷰'
        assert (data / 'checklist.json').read_bytes() == saved_data
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        print(json.dumps({'status': 'passed', 'appSignatureVerified': True, 'diskImageEjectedBeforeSetup': True,
                          'bundledInterpreterUsed': True, 'nativeMessagingSavedAndAcknowledged': True,
                          'codexSkillRuns': True, 'claudeMCPHandshakeAndTools': True,
                          'englishAndKoreanSharedAcrossAdapters': True,
                          'appSignatureStillValidAfterUse': True, 'realUserDataUntouched': True}, indent=2))


if __name__ == '__main__':
    main()
