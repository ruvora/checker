import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checker_language_tests', ROOT / 'bridge/checker_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-language-test-')
        self.folder = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {'CHECKER_DATA_DIR': self.temp.name, 'CHECKER_NO_LAUNCH': '1'})
        self.environment.start()
        self.old_override = os.environ.pop('CHECKER_LANGUAGE', None)

    def tearDown(self):
        if self.old_override is not None:
            os.environ['CHECKER_LANGUAGE'] = self.old_override
        self.environment.stop()
        self.temp.cleanup()

    def test_language_setting_is_shared_with_new_processes_and_preserves_other_settings(self):
        bridge.write_private_json(self.folder / 'settings.json', {'otherSetting': 'keep me'})
        bridge.set_language('en')
        result = subprocess.run([sys.executable, str(ROOT / 'bridge/checker_bridge.py'), 'categories'],
                                check=True, capture_output=True, text=True, env=os.environ)
        response = json.loads(result.stdout)
        self.assertEqual(response['language'], 'en')
        self.assertEqual(response['categories'][1]['name'], 'Review')
        bridge.set_language('ko')
        self.assertEqual(bridge.categories()[1]['name'], '리뷰')
        self.assertEqual(json.loads((self.folder / 'settings.json').read_text())['otherSetting'], 'keep me')
        with self.assertRaises(ValueError):
            bridge.set_language('fr')
        self.assertEqual(bridge.current_language(), 'ko')

    def test_switching_language_localizes_default_categories_without_changing_saved_content(self):
        stored = {'schemaVersion': 1, 'categories': [*bridge.DEFAULT_CATEGORIES,
                  {'id': 'custom-project', 'name': '리뷰', 'description': '직접 쓴 설명'}],
                  'items': [{'title': '기존 제목', 'note': 'Existing note'}]}
        file = self.folder / 'checklist.json'
        bridge.write_private_json(file, stored)
        original = file.read_bytes()
        bridge.set_language('en')
        categories = bridge.categories()
        self.assertEqual(categories[0]['name'], 'Development')
        self.assertEqual(categories[-1]['name'], '리뷰')
        self.assertEqual(file.read_bytes(), original)

    def test_error_responses_follow_current_language_without_translating_user_titles(self):
        original = {'status': 'error', 'message': '분석이 중단됐어요. 다시 시도해 주세요.', 'title': '분석이 중단됐어요. 다시 시도해 주세요.'}
        bridge.set_language('en')
        english = bridge.localized_response(original)
        self.assertEqual(english['message'], 'Analysis was interrupted. Please try again.')
        self.assertEqual(english['title'], original['title'])
        bridge.set_language('ko')
        self.assertEqual(bridge.localized_response(english)['message'], original['message'])

    def test_provider_receives_requested_output_language_independently_of_page_language(self):
        seen = []
        def provider(command, **kwargs):
            seen.append(kwargs['input'])
            output = Path(command[command.index('--output-last-message') + 1])
            output.write_text(json.dumps({'title': 'Review login retry changes', 'note': 'Check regression coverage.', 'categoryID': 'review'}))
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        bridge.set_language('en')
        page = {'sourceURL': 'https://example.com/pull/1', 'title': '로그인 변경', 'text': '로그인 오류 처리와 회귀 테스트 검토'}
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'run', side_effect=provider):
            bridge.run_page_analysis(page, bridge.categories())
        self.assertIn('follow-up task in English:', seen[0])
        self.assertIn('"outputLanguage": "en"', seen[0])
        self.assertIn(page['text'], seen[0])

    def test_in_flight_analysis_keeps_the_language_selected_when_it_started(self):
        bridge.set_language('en')
        page = {'sourceURL': 'https://example.com/pr/2', 'text': 'Review the login retry fix and regression tests.'}
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'Popen'):
            job = bridge.start_page_analysis({'page': page})
        bridge.set_language('ko')
        generated = {'title': 'Review login retry fix', 'note': 'Check regression tests.', 'categoryID': 'review'}
        with patch.object(bridge, 'run_page_analysis', return_value=generated) as analyze, patch.object(bridge, 'capture', return_value={'status': 'queued'}):
            bridge.run_analysis_job(job['jobID'])
        self.assertEqual(analyze.call_args.kwargs['language'], 'en')
        self.assertEqual(analyze.call_args.args[1][1]['name'], 'Review')
        result = bridge.localized_response(bridge.analysis_status(job['jobID']))
        self.assertEqual(result['contentLanguage'], 'en')
        self.assertEqual(result['language'], 'ko')
        self.assertEqual(result['title'], generated['title'])
        self.assertEqual(result['categoryName'], '리뷰')


if __name__ == '__main__':
    unittest.main()
