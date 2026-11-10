import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import types
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checker_ai', ROOT / 'bridge/checker_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class AICaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-ai-check-')
        self.environment = patch.dict(os.environ, {'CHECKER_DATA_DIR': self.temp.name, 'CHECKER_NO_LAUNCH': '1'})
        self.environment.start()
        self.page = {'sourceURL': 'https://example.com/pull/128#diff', 'title': 'Review requested',
                     'visibleText': 'A login retry fix needs review. Verify the regression tests before approving the change.'}
        self.generated = {'title': '로그인 재시도 변경과 회귀 테스트 검토', 'note': '오류 처리와 테스트 범위를 확인하기.', 'categoryID': 'review'}

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def start_without_worker(self, **extra):
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'Popen') as spawn:
            job = bridge.start_page_analysis({'page': self.page, **extra})
        return job, spawn

    def test_ai_receives_page_data_on_stdin_without_tools_or_parent_api_keys(self):
        seen = {}
        def provider(command, **kwargs):
            seen.update(command=command, **kwargs)
            output = Path(command[command.index('--output-last-message') + 1])
            output.write_text(json.dumps(self.generated))
            return types.SimpleNamespace(returncode=0, stdout='{"type":"turn.completed"}\n', stderr='')
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'run', side_effect=provider), patch.dict(os.environ, {'OPENAI_API_KEY': 'synthetic-parent-key', 'UNRELATED_SECRET': 'synthetic-secret'}):
            value = bridge.run_page_analysis(self.page, bridge.DEFAULT_CATEGORIES)
        self.assertEqual(value['title'], self.generated['title'])
        self.assertIn(self.page['visibleText'], seen['input'])
        self.assertNotIn(self.page['visibleText'], seen['command'])
        self.assertNotIn('OPENAI_API_KEY', seen['env'])
        self.assertNotIn('UNRELATED_SECRET', seen['env'])
        for feature in ['shell_tool', 'apps', 'plugins', 'multi_agent', 'hooks']:
            position = seen['command'].index(feature)
            self.assertEqual(seen['command'][position - 1], '--disable')
        self.assertIn('--ignore-user-config', seen['command'])
        self.assertEqual(seen['command'][-2:], ['--', '-'])

    def test_model_cannot_replace_the_original_url_or_create_a_category(self):
        def invalid_provider(command, **kwargs):
            output = Path(command[command.index('--output-last-message') + 1])
            output.write_text(json.dumps({**self.generated, 'sourceURL': 'https://unrelated.example'}))
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'run', side_effect=invalid_provider):
            with self.assertRaises(ValueError):
                bridge.run_page_analysis(self.page, bridge.DEFAULT_CATEGORIES)
        self.assertFalse((Path(self.temp.name) / 'inbox').exists())

    def test_successful_analysis_preserves_link_and_is_added_only_after_ai_finishes(self):
        job, _ = self.start_without_worker()
        self.assertFalse((Path(self.temp.name) / 'inbox').exists())
        original_capture = bridge.capture
        with patch.object(bridge, 'run_page_analysis', return_value=self.generated), patch.object(bridge, 'capture', side_effect=lambda data: original_capture(data, wait=0)):
            bridge.run_analysis_job(job['jobID'])
        queued = bridge.analysis_status(job['jobID'])
        self.assertEqual(queued['status'], 'queued')
        request = json.loads(next((Path(self.temp.name) / 'inbox').glob('*.json')).read_text())
        self.assertEqual(request['sourceURL'], self.page['sourceURL'])
        self.assertEqual(request['title'], self.generated['title'])
        self.assertEqual(request['categoryID'], 'review')
        self.assertFalse(bridge.analysis_paths(job['jobID'])[1].exists())
        binary = ROOT / '.build/debug/Checker'
        if binary.exists():
            subprocess.run([str(binary), '--import-only', '--data-dir', self.temp.name], capture_output=True, check=True)
            self.assertEqual(bridge.analysis_status(job['jobID'])['status'], 'added')

    def test_failure_never_saves_a_raw_title_fallback_and_cleans_inputs(self):
        job, _ = self.start_without_worker()
        with patch.object(bridge, 'run_page_analysis', side_effect=ValueError('AI 분석 실패')), patch.object(bridge, 'capture') as save:
            bridge.run_analysis_job(job['jobID'])
        self.assertEqual(bridge.analysis_status(job['jobID'])['status'], 'error')
        save.assert_not_called()
        self.assertFalse((Path(self.temp.name) / 'inbox').exists())
        self.assertFalse(bridge.analysis_paths(job['jobID'])[1].exists())

    def test_retrying_an_accepted_job_does_not_spawn_a_second_ai_run(self):
        request_id = str(uuid.uuid4())
        with patch.object(bridge, 'codex_executable', return_value='/test/codex'), patch.object(bridge.subprocess, 'Popen') as spawn:
            first = bridge.start_page_analysis({'page': self.page, 'requestID': request_id})
            second = bridge.start_page_analysis({'page': self.page, 'requestID': request_id})
        self.assertEqual(first['jobID'], second['jobID'])
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(spawn.call_args.args[0][1:3], ['-I', '-B'])

    def test_empty_or_non_page_capture_cannot_start_analysis(self):
        for payload in [{'page': {'sourceURL': 'https://example.com', 'title': 'Only title'}},
                        {'page': {**self.page, 'sourceURL': 'file:///private/example'}},
                        {'page': self.page, 'screenshot': 'data:text/html;base64,SGVsbG8='}]:
            with self.subTest(payload=payload), patch.object(bridge.subprocess, 'Popen') as spawn, self.assertRaises(ValueError):
                bridge.start_page_analysis(payload)
            spawn.assert_not_called()

    def test_abandoned_job_reports_failure_and_removes_page_text(self):
        job, _ = self.start_without_worker()
        status, request, _ = bridge.analysis_paths(job['jobID'])
        data = json.loads(status.read_text()); data['startedAt'] = time.time() - 1000
        bridge.write_private_json(status, data)
        self.assertEqual(bridge.analysis_status(job['jobID'])['status'], 'error')
        self.assertFalse(request.exists())


if __name__ == '__main__':
    unittest.main()
