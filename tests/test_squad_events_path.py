"""시험 중에는 스쿼드 이벤트 파일을 진짜 /tmp 에 만들지 않는다 (켜져 있는 부니 앱이 보고 패널을 만들 수 있다)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'windows'))
import buni_team  # noqa: E402


class SquadEventsPath(unittest.TestCase):
    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in ('BUNI_TEAM_HOME', 'BUNI_EVENTS_DIR')}

    def tearDown(self):
        for k, v in self._saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

    def test_team_home_keeps_events_out_of_tmp(self):
        with tempfile.TemporaryDirectory() as home:
            os.environ['BUNI_TEAM_HOME'] = home
            p = buni_team.squad_events_path('job-x')
            self.assertTrue(p.startswith(home))
            self.assertFalse(p.startswith('/tmp/'))

    def test_events_dir_wins(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ['BUNI_EVENTS_DIR'] = d
            self.assertEqual(os.path.dirname(buni_team.squad_events_path('job-x')), d)

    def test_default_unchanged(self):
        if os.name != 'nt':
            self.assertEqual(buni_team.squad_events_path('job-x'),
                             '/tmp/claude-companion-events-squad-job-x.jsonl')


if __name__ == '__main__':
    unittest.main()
