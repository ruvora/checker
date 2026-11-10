#!/usr/bin/env python3
"""Build an Apple Silicon DMG with a bundled, checksum-pinned Python runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MACHO_MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def run(command, **kwargs):
    process = subprocess.run([str(value) for value in command], capture_output=True, text=True, **kwargs)
    if process.returncode:
        raise RuntimeError(process.stdout + process.stderr)
    return process.stdout


def checksum(file):
    digest = hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def download_runtime(config):
    folder = ROOT / 'build/downloads'
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / Path(urllib.parse.unquote(urllib.parse.urlsplit(config['url']).path)).name
    if not archive.exists() or checksum(archive) != config['sha256']:
        partial = archive.with_suffix('.partial')
        try:
            with urllib.request.urlopen(config['url'], timeout=60) as source, partial.open('wb') as destination:
                shutil.copyfileobj(source, destination)
            if checksum(partial) != config['sha256']:
                raise ValueError('Python runtime SHA-256 mismatch; refusing to package it.')
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    return archive


def extract_runtime(archive, resources):
    with tarfile.open(archive, 'r:gz') as source:
        # Reject traversal, special devices and external symlink targets before
        # extracting. All upstream install-only files belong below python/.
        for member in source.getmembers():
            destination = (resources / member.name).resolve()
            if not destination.is_relative_to(resources.resolve()) or not member.name.startswith('python/'):
                raise ValueError('Unexpected runtime archive path: ' + member.name)
            if member.isdev() or member.isfifo():
                raise ValueError('Unexpected device in runtime archive')
            if member.issym() or member.islnk():
                link = (destination.parent / member.linkname).resolve() if member.issym() else (resources / member.linkname).resolve()
                if not link.is_relative_to((resources / 'python').resolve()):
                    raise ValueError('External link in runtime archive')
        source.extractall(resources, filter='data')


def sign_app(app, identity):
    def sign(path):
        command = ['/usr/bin/codesign', '--force', '--sign', identity]
        if identity != '-':
            command += ['--options', 'runtime', '--timestamp']
        run(command + [path])
    signed = 0
    for file in sorted((app / 'Contents/Resources/python').rglob('*')):
        if file.is_symlink() or not file.is_file():
            continue
        with file.open('rb') as stream:
            magic = stream.read(4)
        if magic in MACHO_MAGIC:
            sign(file); signed += 1
    sign(app)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    return signed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Use the existing build/Checker.app')
    parser.add_argument('--sign-identity', default='-', help='Developer ID Application identity, or - for a test build')
    parser.add_argument('--notary-profile', help='Explicitly submit the DMG with a saved notarytool keychain profile')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This packaging target must be built on an Apple Silicon Mac.')
    if args.sign_identity != '-' and not args.sign_identity.startswith('Developer ID Application:'):
        parser.error('Distribution signing requires a Developer ID Application identity.')
    if args.notary_profile and args.sign_identity == '-':
        parser.error('Notarization requires Developer ID signing.')
    version = (ROOT / 'VERSION').read_text().strip()
    run([shutil.which('python3') or '/usr/bin/python3', ROOT / 'scripts/sync_localization.py'], cwd=ROOT)
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('VERSION must contain a semantic version.')
    runtime_config = json.loads((ROOT / 'packaging/python-runtime.json').read_text())
    print('Preparing Python runtime (SHA-256 verified)…', flush=True)
    archive = download_runtime(runtime_config)
    if not args.skip_build:
        print('Building release app…', flush=True)
        run(['/bin/sh', ROOT / 'scripts/build.sh'], cwd=ROOT, env={**os.environ, 'CHECKER_BUILD_CONFIGURATION': 'release'})
    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    distribution = ROOT / 'build/distribution'
    if distribution.exists():
        shutil.rmtree(distribution)
    distribution.mkdir()
    app = distribution / 'Checker.app'
    shutil.copytree(ROOT / 'build/Checker.app', app, symlinks=True)
    resources = app / 'Contents/Resources'
    shutil.copy2(ROOT / 'bridge/checker_bridge.py', resources / 'checker_bridge.py')
    extract_runtime(archive, resources)
    payload = resources / 'capture'
    payload.mkdir()
    for name in ['checker_bridge.py', 'install_connections.py']:
        shutil.copy2(ROOT / 'bridge' / name, payload / name)
    shutil.copy2(ROOT / 'localization/strings.json', payload / 'strings.json')
    shutil.copy2(ROOT / 'localization/strings.json', resources / 'strings.json')
    shutil.copytree(ROOT / '.agents/skills/checker-capture', payload / 'skills/checker-capture',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
    shutil.copytree(ROOT / 'extension', payload / 'extension', ignore=shutil.ignore_patterns('.DS_Store'))
    licenses = ROOT / 'packaging/python-licenses'
    license_manifest = json.loads((licenses / 'manifest.json').read_text())
    for notice in license_manifest['files']:
        if checksum(licenses / notice['file']) != notice['sha256']:
            raise ValueError('A bundled license file has changed: ' + notice['file'])
    shutil.copytree(licenses, resources / 'python-licenses')
    shutil.copy2(ROOT / 'packaging/python-runtime.json', resources / 'python-runtime.json')
    (resources / 'THIRD-PARTY-NOTICES.txt').write_text(
        'Checker includes CPython from Astral Python Standalone Builds.\n'
        + runtime_config['source'] + '\nSee python-licenses/ and python/lib/python3.13/LICENSE.txt for upstream licenses, including notices for optional components.\n', encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='checker-icon-', dir=ROOT / 'build') as folder:
        iconset = Path(folder) / 'Checker.iconset'
        run(['/usr/bin/swift', ROOT / 'scripts/make_icon.swift', iconset])
        run(['/usr/bin/iconutil', '-c', 'icns', iconset, '-o', resources / 'Checker.icns'])
    info_file = app / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    info.update(CFBundleShortVersionString=version, CFBundleIconFile='Checker.icns', CFBundleLocalizations=['en', 'ko'], CFBundleDevelopmentRegion='en')
    info_file.write_bytes(plistlib.dumps(info))
    print('Signing bundled executables…', flush=True)
    signed = sign_app(app, args.sign_identity)
    print('Verified app and %d bundled Mach-O files.' % signed, flush=True)
    # Verify relocation and stdlib dependencies using the actual bundled binary.
    run([resources / 'python/bin/python3', '-I', '-B', '-c',
         'import ssl, sqlite3, ctypes, json, multiprocessing; print(ssl.OPENSSL_VERSION)'])
    notice = ('이 파일은 Developer ID 서명 및 Apple 공증을 마친 배포판입니다.' if args.notary_profile else
              '이 파일은 Apple 공증을 받지 않은 테스트 배포판입니다. Mac에서 최초 실행 시 개발자 확인 경고가 나타날 수 있습니다.')
    guide = (ROOT / 'packaging/INSTALL.html').read_text().replace('{{VERSION}}', version).replace('{{SIGNING_NOTICE}}', notice)
    english_notice = ('This distribution is Developer ID signed and notarized by Apple.' if args.notary_profile else
                      'This is a test distribution without Apple notarization. macOS may show a developer verification warning on first launch.')
    english_guide = (ROOT / 'packaging/INSTALL.en.html').read_text().replace('{{VERSION}}', version).replace('{{SIGNING_NOTICE}}', english_notice)
    (distribution / '설치 안내.html').write_text(guide, encoding='utf-8')
    (distribution / 'Installation Guide.html').write_text(english_guide, encoding='utf-8')
    (distribution / 'Applications').symlink_to('/Applications', target_is_directory=True)
    extension_zip = output / ('Checker-' + version + '-Chrome-extension.zip')
    with zipfile.ZipFile(extension_zip, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        for file in sorted((payload / 'extension').rglob('*')):
            if file.is_file():
                zipped.write(file, Path('Checker-extension') / file.relative_to(payload / 'extension'))
    dmg = output / ('Checker-' + version + '-macOS-arm64.dmg')
    print('Creating disk image…', flush=True)
    run(['/usr/bin/hdiutil', 'create', '-volname', 'Checker ' + version, '-srcfolder', distribution,
         '-ov', '-format', 'UDZO', '-imagekey', 'zlib-level=9', dmg])
    if args.sign_identity != '-':
        run(['/usr/bin/codesign', '--force', '--sign', args.sign_identity, '--timestamp', dmg])
    if args.notary_profile:
        print('Submitting disk image for notarization…', flush=True)
        run(['/usr/bin/xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile, '--wait'])
        run(['/usr/bin/xcrun', 'stapler', 'staple', dmg])
        run(['/usr/bin/xcrun', 'stapler', 'validate', dmg])
    run(['/usr/bin/hdiutil', 'verify', dmg])
    sums = ''.join(checksum(file) + '  ' + file.name + '\n' for file in [dmg, extension_zip])
    (output / 'SHA256SUMS.txt').write_text(sums)
    (output / '설치 안내.html').write_text(guide, encoding='utf-8')
    (output / 'Installation Guide.html').write_text(english_guide, encoding='utf-8')
    metadata = {'version': version, 'architecture': 'arm64', 'minimumMacOS': '13.0', 'languages': ['en', 'ko'],
                'signature': 'ad-hoc' if args.sign_identity == '-' else 'Developer ID',
                'notarized': bool(args.notary_profile), 'python': runtime_config,
                'artifacts': [{'file': file.name, 'bytes': file.stat().st_size, 'sha256': checksum(file)} for file in [dmg, extension_zip]]}
    (output / 'release.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(metadata, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
