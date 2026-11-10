#!/usr/bin/env python3
"""Prepare or install the local capture adapters; never replace existing connectors."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.checker-config-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def install_payload(home):
    source = ROOT / 'build/Checker.app'
    destination = home / 'Applications/Checker.app'
    if not source.is_dir():
        raise RuntimeError('먼저 scripts/build.sh로 Checker 앱을 빌드해 주세요.')
    if destination.exists():
        info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'local.checker.prototype':
            raise RuntimeError('같은 이름의 다른 앱은 덮어쓰지 않습니다.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, dirs_exist_ok=True)
    runtime = home / 'Library/Application Support/Checker/runtime'
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copy2(ROOT / 'bridge/checker_bridge.py', runtime / 'checker_bridge.py')
    shutil.copy2(ROOT / 'localization/strings.json', runtime / 'strings.json')
    launcher = runtime / 'native-host'
    launcher.write_text('#!/bin/sh\nset -eu\nCHECKER_RUNTIME_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec /usr/bin/python3 "$CHECKER_RUNTIME_DIR/checker_bridge.py" native-host "$@"\n', encoding='utf-8')
    launcher.chmod(0o755)
    write_json(runtime / 'runtime-config.json', {'appPath': str(destination)})
    shutil.copytree(ROOT / '.agents/skills/checker-capture', runtime / 'skills/checker-capture', dirs_exist_ok=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    return runtime, destination

def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', action='store_true', help='Install the Codex skill link and Chrome Native Messaging host for this user')
    parser.add_argument('--claude', action='store_true', help='Merge the Checker local MCP entry into Claude Desktop config')
    parser.add_argument('--claude-code', action='store_true', help='Register the Checker MCP server for Claude Code (user scope, ~/.claude.json)')
    args = parser.parse_args()
    manifest_file = ROOT / 'extension/manifest.json'
    manifest = json.loads(manifest_file.read_text())
    if 'key' not in manifest:
        with tempfile.TemporaryDirectory(prefix='checker-extension-key-') as temporary:
            private = Path(temporary) / 'private.pem'
            subprocess.run(['/usr/bin/openssl', 'genrsa', '-out', str(private), '2048'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            public = subprocess.run(['/usr/bin/openssl', 'rsa', '-in', str(private), '-pubout', '-outform', 'DER'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
            manifest['key'] = base64.b64encode(public).decode('ascii')
        write_json(manifest_file, manifest)
    digest = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
    extension_id = ''.join(chr(ord('a') + int(value, 16)) for value in digest)
    home = Path.home()
    runtime = home / 'Library/Application Support/Checker/runtime'
    installed_app = home / 'Applications/Checker.app'
    if args.install or args.claude or args.claude_code:
        runtime, installed_app = install_payload(home)
    native = {'name': 'local.checker.capture', 'description': 'Checker local checklist capture', 'path': str(runtime / 'native-host'), 'type': 'stdio', 'allowed_origins': ['chrome-extension://' + extension_id + '/']}
    mcp = {'command': '/usr/bin/python3', 'args': [str(runtime / 'checker_bridge.py'), 'mcp']}
    write_json(ROOT / 'build/native-host.json', native)
    write_json(ROOT / 'build/claude-desktop-config.json', {'mcpServers': {'checker': mcp}})
    (ROOT / 'build/extension-id.txt').write_text(extension_id + '\n')
    if args.install:
        host_file = home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.checker.capture.json'
        if host_file.exists() and json.loads(host_file.read_text()).get('path') not in [native['path'], str(ROOT / 'scripts/native-host')]:
            raise RuntimeError('An existing Checker Native Messaging host belongs to a different installation.')
        write_json(host_file, native)
        skill = home / '.codex/skills/checker-capture'
        target = runtime / 'skills/checker-capture'
        skill.parent.mkdir(parents=True, exist_ok=True)
        if skill.is_symlink() and skill.resolve() == (ROOT / '.agents/skills/checker-capture').resolve():
            skill.unlink()
        if not skill.exists() and not skill.is_symlink():
            skill.symlink_to(target, target_is_directory=True)
        elif skill.resolve() != target.resolve():
            raise RuntimeError('An existing checker-capture skill was preserved; choose its location manually.')
    if args.claude:
        config = home / 'Library/Application Support/Claude/claude_desktop_config.json'
        existing = json.loads(config.read_text()) if config.exists() else {}
        servers = existing.setdefault('mcpServers', {})
        old_args = [str(ROOT / 'bridge/checker_bridge.py'), 'mcp']
        if 'checker' in servers and servers['checker'].get('args') not in [mcp['args'], old_args]:
            raise RuntimeError('An existing Claude Checker connector was preserved.')
        if config.exists():
            backup = config.with_suffix('.json.checker-backup')
            if not backup.exists():
                backup.write_bytes(config.read_bytes())
        servers['checker'] = {**servers.get('checker', {}), **mcp}
        write_json(config, existing)
    if args.claude_code:
        config = home / '.claude.json'
        existing = json.loads(config.read_text()) if config.exists() else {}
        servers = existing.setdefault('mcpServers', {})
        if 'checker' in servers and servers['checker'].get('args') != mcp['args']:
            raise RuntimeError('An existing Claude Code Checker connector was preserved.')
        if config.exists():
            backup = home / '.claude.json.checker-backup'
            if not backup.exists():
                backup.write_bytes(config.read_bytes())
        servers['checker'] = {**servers.get('checker', {}), 'type': 'stdio', **mcp}
        write_json(config, existing)
    print(json.dumps({'extensionID': extension_id, 'extensionFolder': str(ROOT / 'extension'), 'app': str(installed_app), 'runtime': str(runtime), 'installed': args.install, 'claudeConfigured': args.claude, 'claudeCodeConfigured': args.claude_code}, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
