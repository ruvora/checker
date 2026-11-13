import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'bridge/checker_bridge.py'
spec = importlib.util.spec_from_file_location('checker_bridge', BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='checker-bridge-test-')
        self.previous = {name: os.environ.get(name) for name in ['CHECKER_DATA_DIR', 'CHECKER_NO_LAUNCH', 'CODEX_THREAD_ID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_HOST_SESSION_ID']}
        os.environ['CHECKER_DATA_DIR'] = self.temporary.name
        os.environ['CHECKER_NO_LAUNCH'] = '1'
        os.environ.pop('CODEX_THREAD_ID', None)
        os.environ.pop('CLAUDE_CODE_SESSION_ID', None)
        os.environ.pop('CLAUDE_CODE_HOST_SESSION_ID', None)

    def tearDown(self):
        for name, value in self.previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        self.temporary.cleanup()

    def test_queue_preserves_quotes_and_original_link(self):
        request_id = str(uuid.uuid4())
        response = bridge.capture({'requestID': request_id, 'title': '검토 "제안" $(literal)', 'sourceURL': 'https://example.com/a?b=1#section', 'sourceApp': 'chrome', 'categoryID': 'review'}, wait=0)
        self.assertEqual(response['status'], 'queued')
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (request_id + '.json')).read_text())
        self.assertEqual(saved['title'], '검토 "제안" $(literal)')
        self.assertEqual(saved['sourceURL'], 'https://example.com/a?b=1#section')
        bridge.capture({'requestID': request_id, 'title': '검토 "제안" $(literal)', 'categoryID': 'review'}, wait=0)
        self.assertEqual(len(list((Path(self.temporary.name) / 'inbox').glob('*.json'))), 1)

    def test_source_links_reject_executable_schemes_and_install_links(self):
        for link in ['javascript:alert(1)', 'file:///etc/passwd', 'codex://plugins/install/something', 'https:///missing-host']:
            with self.subTest(link=link), self.assertRaises(ValueError):
                bridge.capture({'title': 'bad', 'sourceURL': link}, wait=0)
        self.assertFalse((Path(self.temporary.name) / 'inbox').exists())

    def test_codex_uses_only_a_real_provided_thread_id(self):
        thread_id = str(uuid.uuid4())
        os.environ['CODEX_THREAD_ID'] = thread_id
        result = bridge.capture({'title': '현재 대화 검토', 'sourceApp': 'codex'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['sourceURL'], 'codex://threads/' + thread_id)

    def test_claude_code_session_link_is_accepted_and_filled_only_when_known(self):
        link = 'claude://code/continue?session=local_7baffd25-7faf-42e1-bda1-2f90d76a37e6'
        result = bridge.capture({'title': '세션으로 돌아가기', 'sourceApp': 'claude', 'sourceURL': link}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['sourceURL'], link)
        for bad in ['claude://code/new', 'claude://code/continue?session=last', link + '&x=1', 'claude://claude.ai/new']:
            with self.subTest(link=bad), self.assertRaises(ValueError):
                bridge.capture({'title': 'bad', 'sourceApp': 'claude', 'sourceURL': bad}, wait=0)
        os.environ['CLAUDE_CODE_HOST_SESSION_ID'] = 'local_abc-123'
        result = bridge.capture({'title': '자동 링크', 'sourceApp': 'claude'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['sourceURL'], 'claude://code/continue?session=local_abc-123')
        other = 'claude://code/continue?session=local_given-by-caller'
        result = bridge.capture({'title': '명시한 세션 링크 우선', 'sourceApp': 'claude', 'sourceURL': other}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['sourceURL'], other)
        os.environ['CLAUDE_CODE_HOST_SESSION_ID'] = 'local_bad id'
        result = bridge.capture({'title': '잘못된 ID', 'sourceApp': 'claude'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertIsNone(saved['sourceURL'])

    def test_a_web_page_given_as_source_moves_to_related_when_the_conversation_is_known(self):
        thread_id = str(uuid.uuid4())
        os.environ['CODEX_THREAD_ID'] = thread_id
        result = bridge.capture({'title': '승인 확인', 'sourceApp': 'codex', 'sourceURL': 'https://github.com/o/r/pull/1'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual((saved['sourceURL'], saved['relatedURL']), ('codex://threads/' + thread_id, 'https://github.com/o/r/pull/1'))
        os.environ['CLAUDE_CODE_HOST_SESSION_ID'] = 'local_abc-123'
        result = bridge.capture({'title': '문서 확인', 'sourceApp': 'claude', 'sourceURL': 'https://wiki.example.com/a', 'relatedURL': 'https://jira.example.com/BP-1'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual((saved['sourceURL'], saved['relatedURL']), ('claude://code/continue?session=local_abc-123', 'https://jira.example.com/BP-1'))
        # Chrome items are about the page itself; their page link stays the title link.
        result = bridge.capture({'title': '페이지', 'sourceApp': 'chrome', 'sourceURL': 'https://example.com/page'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['sourceURL'], 'https://example.com/page')

    def test_related_link_is_saved_separately_and_must_be_a_web_page(self):
        link = 'claude://code/continue?session=local_abc-123'
        result = bridge.capture({'title': '티켓 확인', 'sourceApp': 'claude', 'sourceURL': link, 'relatedURL': 'https://example.atlassian.net/browse/BP-1'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual((saved['sourceURL'], saved['relatedURL']), (link, 'https://example.atlassian.net/browse/BP-1'))
        for bad in ['codex://threads/abc', link, 'javascript:alert(1)']:
            with self.subTest(link=bad), self.assertRaises(ValueError):
                bridge.capture({'title': 'bad', 'sourceApp': 'claude', 'relatedURL': bad}, wait=0)

    def test_claude_code_session_is_kept_in_the_note_without_a_made_up_link(self):
        session = str(uuid.uuid4())
        os.environ['CLAUDE_CODE_SESSION_ID'] = session
        result = bridge.capture({'title': '배포 확인', 'sourceApp': 'claude', 'note': '스테이징 확인'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertIsNone(saved['sourceURL'])
        self.assertTrue(saved['note'].startswith('스테이징 확인'))
        self.assertIn('claude --resume ' + session, saved['note'])
        os.environ['CLAUDE_CODE_SESSION_ID'] = 'not-a-session'
        result = bridge.capture({'title': '배포 확인', 'sourceApp': 'claude'}, wait=0)
        saved = json.loads((Path(self.temporary.name) / 'inbox' / (result['requestID'] + '.json')).read_text())
        self.assertEqual(saved['note'], '')

    def test_categories_come_from_the_app_including_custom_categories(self):
        custom = bridge.DEFAULT_CATEGORIES + [{'id': 'project-a', 'name': '프로젝트 A', 'description': 'A 프로젝트'}]
        Path(self.temporary.name, 'checklist.json').write_text(json.dumps({'schemaVersion': 1, 'categories': custom, 'items': []}))
        self.assertEqual(bridge.categories()[-1]['id'], 'project-a')
        self.assertEqual(bridge.capture({'title': 'A 확인', 'categoryID': 'project-a'}, wait=0)['status'], 'queued')
        with self.assertRaises(ValueError):
            bridge.capture({'title': '분류 오류', 'categoryID': 'made-up'}, wait=0)

    def test_native_messaging_frames_utf8_and_reports_truncation(self):
        payload = json.dumps({'action': 'categories'}, ensure_ascii=False).encode()
        result = subprocess.run([sys.executable, str(BRIDGE), 'native-host'], input=struct.pack('=I', len(payload)) + payload, capture_output=True, check=True)
        length = struct.unpack('=I', result.stdout[:4])[0]
        decoded = json.loads(result.stdout[4:4 + length])
        self.assertEqual(decoded['categories'][0]['name'], '개발')
        truncated = subprocess.run([sys.executable, str(BRIDGE), 'native-host'], input=struct.pack('=I', 50) + b'{}', capture_output=True, check=True)
        self.assertEqual(json.loads(truncated.stdout[4:])['status'], 'error')

    def test_stdio_mcp_handshake_and_category_tool(self):
        messages = [
            {'jsonrpc': '2.0', 'id': 1, 'method': 'server/discover'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25'}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'},
            {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'list_categories', 'arguments': {}}},
        ]
        result = subprocess.run([sys.executable, str(BRIDGE), 'mcp'], input=''.join(json.dumps(value) + '\n' for value in messages), capture_output=True, text=True, check=True)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 4)
        self.assertEqual(responses[0]['error']['code'], -32601)
        self.assertEqual(responses[1]['result']['protocolVersion'], '2025-11-25')
        self.assertEqual(len(responses[2]['result']['tools']), 2)
        self.assertEqual(len(json.loads(responses[3]['result']['content'][0]['text'])['categories']), 4)

    def test_capture_commits_in_swift_and_receipt_prevents_replay(self):
        binary = Path(os.environ.get('CHECKER_TEST_BINARY', ROOT / '.build/debug/Checker'))
        if not binary.exists():
            self.skipTest('Build the Swift app first')
        payload = {'title': '브리지 통합 확인', 'sourceApp': 'chrome', 'sourceURL': 'https://example.com/check', 'categoryID': 'review'}
        result = bridge.capture(payload, wait=0)
        subprocess.run([str(binary), '--import-only', '--data-dir', self.temporary.name], check=True, capture_output=True)
        stored = bridge.receipt(result['requestID'])
        self.assertEqual(stored['status'], 'added')
        self.assertEqual(stored['categoryID'], 'review')
        payload['requestID'] = result['requestID']
        self.assertEqual(bridge.capture(payload, wait=0)['status'], 'added')
        document = json.loads(Path(self.temporary.name, 'checklist.json').read_text())
        self.assertEqual(len(document['items']), 1)


if __name__ == '__main__':
    unittest.main()
