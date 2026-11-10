#!/usr/bin/env python3
"""Install per-user adapters from the distribution app, without developer tools."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import sys
import tempfile

BUNDLE_ID = 'local.checker.prototype'


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.checker-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path, default=None):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else default


def install(app, home, *, codex=True, chrome=True, claude=False, language=None):
    app = app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError('Checker 앱을 확인해 주세요.')
    if str(app).startswith('/Volumes/') or '/AppTranslocation/' in str(app):
        raise ValueError('먼저 Checker를 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요.')
    resources = app / 'Contents/Resources'
    python = resources / 'python/bin/python3'
    payload = resources / 'capture'
    settings_file = home / 'Library/Application Support/Checker/settings.json'
    settings = read_json(settings_file, {})
    if not isinstance(settings, dict):
        raise ValueError('언어 설정을 읽지 못했어요. 설정 파일을 확인해 주세요.')
    if language is not None and language not in ('en', 'ko'):
        raise ValueError('한국어 또는 영어를 선택해 주세요.')
    if not python.is_file() or not os.access(python, os.X_OK) or not (payload / 'checker_bridge.py').is_file():
        raise ValueError('실행 환경이 없는 앱입니다. 배포용 Checker 앱으로 다시 설치해 주세요.')
    runtime = home / 'Library/Application Support/Checker/runtime'
    host_file = home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json'
    skill = home / '.codex/skills/checker-capture'
    target = runtime / 'skills/checker-capture'
    claude_file = home / 'Library/Application Support/Claude/claude_desktop_config.json'
    # Check every selected destination before making changes. Unknown connectors
    # or custom skills are not silently replaced by an installer.
    if chrome and host_file.exists():
        old_host = read_json(host_file)
        if old_host.get('path') != str(runtime / 'native-host'):
            raise ValueError('다른 Checker Chrome 연결이 있어 보존했습니다. 기존 연결을 확인해 주세요.')
    if codex and os.path.lexists(skill):
        if not skill.is_symlink() or skill.resolve() != target.resolve():
            raise ValueError('기존 checker-capture 스킬이 있어 보존했습니다. 해당 스킬을 먼저 확인해 주세요.')
    existing = read_json(claude_file, {}) if claude else {}
    if not isinstance(existing, dict) or (claude and not isinstance(existing.get('mcpServers', {}), dict)):
        raise ValueError('Claude 설정 파일 형식을 확인해 주세요. 기존 설정은 변경하지 않았습니다.')
    servers = existing.get('mcpServers', {})
    old_checker = servers.get('checker', {})
    if claude and 'checker' in servers and (not isinstance(old_checker, dict) or old_checker.get('args') != [str(runtime / 'checker_bridge.py'), 'mcp']):
        raise ValueError('다른 Claude checker 연결이 있어 보존했습니다. 기존 연결을 확인해 주세요.')
    manifest = read_json(payload / 'extension/manifest.json')
    digest = hashlib.sha256(base64.b64decode(manifest['key'], validate=True)).hexdigest()[:32]
    extension_id = ''.join(chr(ord('a') + int(value, 16)) for value in digest)
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ['checker_bridge.py', 'strings.json']:
        shutil.copy2(payload / name, runtime / name)
    shutil.copytree(payload / 'skills', runtime / 'skills', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copytree(payload / 'extension', runtime / 'extension', dirs_exist_ok=True)
    # A shell launcher removes the recipient's system-Python dependency. Never
    # interpolate a path into unquoted shell text.
    interpreter = runtime / 'python3'
    interpreter.write_text('#!/bin/sh\nexec ' + shlex.quote(str(python)) + ' -I -B "$@"\n', encoding='utf-8')
    interpreter.chmod(0o755)
    host = runtime / 'native-host'
    host.write_text('#!/bin/sh\nset -eu\nCHECKER_RUNTIME_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)\nexec "$CHECKER_RUNTIME_DIR/python3" "$CHECKER_RUNTIME_DIR/checker_bridge.py" native-host "$@"\n', encoding='utf-8')
    host.chmod(0o755)
    write_json(runtime / 'runtime-config.json', {'appPath': str(app)})
    if language is not None:
        settings['language'] = language
        write_json(settings_file, settings)
    if chrome:
        write_json(host_file, {'name': 'local.checker.capture', 'description': 'Checker local checklist capture',
                              'path': str(host), 'type': 'stdio', 'allowed_origins': ['chrome-extension://' + extension_id + '/']})
    if codex:
        skill.parent.mkdir(parents=True, exist_ok=True)
        if not os.path.lexists(skill):
            skill.symlink_to(target, target_is_directory=True)
    if claude:
        if claude_file.exists():
            backup = claude_file.with_suffix('.json.checker-backup')
            if not backup.exists():
                backup.write_bytes(claude_file.read_bytes())
                backup.chmod(0o600)
        existing.setdefault('mcpServers', {})['checker'] = {
            **old_checker, 'command': str(interpreter), 'args': [str(runtime / 'checker_bridge.py'), 'mcp']}
        write_json(claude_file, existing)
    previous = read_json(runtime / 'connections.json', {})
    connected = {name: selected or previous.get(name, False) for name, selected in [('codex', codex), ('chrome', chrome), ('claude', claude)]}
    result = {'status': 'ok', 'appPath': str(app), 'version': info['CFBundleShortVersionString'],
              'extensionID': extension_id, 'extensionFolder': str(runtime / 'extension'), **connected}
    write_json(runtime / 'connections.json', result)
    return result


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-bundle', type=Path, required=True)
    parser.add_argument('--codex', action='store_true')
    parser.add_argument('--chrome', action='store_true')
    parser.add_argument('--claude', action='store_true')
    parser.add_argument('--language', choices=['en', 'ko'])
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.app_bundle, Path.home(), codex=args.codex, chrome=args.chrome, claude=args.claude, language=args.language), ensure_ascii=False))
    except (ValueError, KeyError, OSError) as error:
        message = str(error)
        catalog = args.app_bundle / 'Contents/Resources/capture/strings.json'
        if args.language == 'en' and catalog.is_file():
            message = read_json(catalog).get(message, message)
        print(json.dumps({'status': 'error', 'message': message}, ensure_ascii=False))
        sys.exit(1)


if __name__ == '__main__':
    main()
