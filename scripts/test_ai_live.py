#!/usr/bin/env python3
"""Optional live AI check, using only a synthetic screenshot and isolated storage."""
import argparse
import base64
import importlib.util
import json
import os
import re
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('checker_live', ROOT / 'bridge/checker_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

parser = argparse.ArgumentParser(description=__doc__)
target = parser.add_mutually_exclusive_group()
target.add_argument('--installed', action='store_true', help='Exercise the installed Native Messaging launcher')
target.add_argument('--app-bundle', type=Path, help='Exercise the distribution app and its bundled Python')
parser.add_argument('--language', choices=['en', 'ko'], help='Verify AI output in the selected language')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='checker-live-ai-') as temporary:
    folder = Path(temporary)
    os.environ['CHECKER_DATA_DIR'] = temporary
    os.environ['CHECKER_NO_LAUNCH'] = '1'
    if args.language:
        bridge.set_language(args.language)
    image = folder / 'synthetic-page.png'
    subprocess.run(['/usr/bin/swift', str(ROOT / 'Tests/fixtures/PageFixture.swift'), str(image)], check=True, capture_output=True)
    # The browser name and detailed behavior intentionally occur ONLY in the image.
    payload = {'action': 'start_analysis', 'page': {
        'sourceURL': 'https://example.com/pull/128#review', 'title': 'PR #128: Login flow',
        'visibleText': 'Review the change and test coverage described in the visible screenshot.'},
        'screenshot': 'data:image/png;base64,' + base64.b64encode(image.read_bytes()).decode('ascii')}
    encoded = json.dumps(payload).encode('utf-8')
    if args.app_bundle:
        resources = args.app_bundle.resolve() / 'Contents/Resources'
        command = [str(resources / 'python/bin/python3'), '-I', '-B', str(resources / 'capture/checker_bridge.py'), 'native-host']
    elif args.installed:
        command = [str(Path.home() / 'Library/Application Support/Checker/runtime/native-host')]
    else:
        command = [sys.executable, str(ROOT / 'bridge/checker_bridge.py'), 'native-host']
    started = time.monotonic()
    process = subprocess.run(command, input=struct.pack('=I', len(encoded)) + encoded, capture_output=True, check=True, timeout=15)
    length = struct.unpack('=I', process.stdout[:4])[0]
    response = json.loads(process.stdout[4:4 + length])
    if response.get('status') != 'analyzing':
        raise RuntimeError(response)
    print(json.dumps({'started': response['jobID'], 'imageBytes': image.stat().st_size}), flush=True)
    while time.monotonic() - started < bridge.AI_TIMEOUT_SECONDS + 50:
        response = bridge.analysis_status(response['jobID'])
        if response['status'] != 'analyzing':
            break
        time.sleep(1)
    if response['status'] == 'queued':
        subprocess.run([str(ROOT / '.build/debug/Checker'), '--import-only', '--data-dir', temporary], check=True, capture_output=True)
        response = bridge.analysis_status(response['jobID'])
    if response['status'] != 'added':
        raise RuntimeError(response)
    assert response['mode'] == 'image_and_text'
    assert response['sourceURL'] == payload['page']['sourceURL']
    assert response['title'] != payload['page']['title']
    combined = response['title'] + response['note']
    if args.language:
        assert response['contentLanguage'] == args.language
        assert bool(re.search('[가-힣]', combined)) == (args.language == 'ko'), 'AI did not follow the selected output language'
    assert 'safari' in combined.lower() or '사파리' in combined, 'AI did not use the screenshot-only evidence'
    assert not list((folder / 'analysis/requests').glob('*'))
    assert not list((folder / 'analysis/images').glob('*'))
    if args.app_bundle:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(args.app_bundle.resolve())], check=True, capture_output=True)
    print(json.dumps({'status': 'passed', 'elapsedSeconds': round(time.monotonic() - started, 1),
                      'title': response['title'], 'category': response['categoryName'],
                      'screenshotEvidenceUsed': True, 'temporaryInputsRemoved': True}, ensure_ascii=False), flush=True)
