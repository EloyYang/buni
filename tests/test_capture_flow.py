"""화면 업무 완료 시 변경 전·후 캡처가 자동으로 시도되는 흐름 — 가짜 claude(BUNI_CLAUDE)·임시 BUNI_TEAM_HOME·가짜 PNG.
실제 화면은 찍지 않는다: grab_screen 을 가짜 PNG 를 쓰는 함수로 바꿔치기한다.
  · 화면·디자인 업무(is_screen_task)면 시작 전 before, 끝난 뒤 after 를 엔진이 시도한다
  · 못 찍으면 채팅에 '캡처 아님 — 이유' 가 오르고 job_screens 가 captured=False + reason (맥·Windows 보드가 같은 문구)
  · 화면과 상관없는 업무·설정 꺼짐·가짜 claude 시험 중(BUNI_CAPTURE_TEST 없음)에는 찍지 않는다"""
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
sys.path.insert(0, str(HERE))

import buni_team as bt  # noqa: E402
import test_fake_claude_flow as base  # noqa: E402
from test_screen_diff import write_png, block  # noqa: E402


class CaptureFlow(base.FakeClaudeBase):
    def setUp(self):
        super().setUp()
        self._saved_env = os.environ.get('BUNI_CAPTURE_TEST')
        os.environ['BUNI_CAPTURE_TEST'] = '1'
        bt.save_settings({'auto_followup': False})
        self._grab = bt.grab_screen
        self.grabs = []

        def fake_grab(path, window='', region=''):
            self.grabs.append(path)
            # 첫 번째(before)는 빈 화면, 그 뒤(after)는 사각형이 그려진 화면
            write_png(path, 32, 32, paint=block(4, 4, 12, 12) if len(self.grabs) > 1 else None)
            return ''
        bt.grab_screen = fake_grab

    def tearDown(self):
        bt.grab_screen = self._grab
        if self._saved_env is None:
            os.environ.pop('BUNI_CAPTURE_TEST', None)
        else:
            os.environ['BUNI_CAPTURE_TEST'] = self._saved_env
        super().tearDown()

    def job_with(self, mission, kind='docs', rid='ui'):
        job = self.make_job([(rid, '')])
        job['plan']['roles'][0].update(mission=mission, kind=kind)
        bt.save_job(job)
        return job

    def texts(self, jid):
        return [m['text'] for m in bt.load_chat(jid)]

    def test_screen_task_captures_before_and_after(self):
        job = self.job_with('설정 화면 디자인을 바꾼다')
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))
        self.assertEqual(len(self.grabs), 2)
        items = bt.job_screens(job['id'])
        self.assertEqual([i['name'] for i in items], ['ui'])
        self.assertTrue(items[0]['captured'])
        self.assertEqual(len(items[0]['boxes']), 1)                 # 바뀐 부분 테두리가 계산된다
        self.assertFalse(any(bt.SCREEN_NOT_CAPTURED in t for t in self.texts(job['id'])))

    def test_failed_grab_says_not_a_capture_with_reason(self):
        bt.grab_screen = lambda path, window='', region='': '화면 기록 권한이 없어요'
        job = self.job_with('색상 토큰 적용', kind='code')
        self.run_job(job['id'])
        it = bt.job_screens(job['id'])[0]
        self.assertFalse(it['captured'])
        self.assertEqual(it['missing'], ['before', 'after'])
        self.assertIn('화면 기록 권한이 없어요', it['reason'])
        self.assertIn('캡처 아님 — ' + it['reason'], self.texts(job['id']))

    def test_non_screen_task_is_not_captured(self):
        job = self.job_with('요금 계산 엔진 로직을 고친다', rid='eng')
        self.run_job(job['id'])
        self.assertEqual(self.grabs, [])
        self.assertEqual(bt.job_screens(job['id']), [])

    def test_readonly_research_is_not_captured(self):
        job = self.job_with('경쟁 앱 화면 조사', kind='readonly', rid='res')
        self.run_job(job['id'])
        self.assertEqual(self.grabs, [])

    def test_off_by_setting_or_without_test_flag(self):
        bt.save_settings({'auto_capture': False})
        job = self.job_with('화면 디자인')
        self.run_job(job['id'])
        self.assertEqual(self.grabs, [])
        bt.save_settings({'auto_capture': True})
        del os.environ['BUNI_CAPTURE_TEST']                         # 가짜 claude 시험 중이면 실제 화면을 건드리지 않는다
        job2 = self.job_with('화면 디자인')
        self.run_job(job2['id'])
        self.assertEqual(self.grabs, [])

    def test_worker_made_pngs_are_imported_instead_of_grabbing(self):
        job = bt.load_job(self.job_with('레이아웃 디자인')['id'])
        wd = Path(self.tmp.name) / 'wd'
        d = wd / '.buni-team' / job['slug'] / 'ui' / 'screens'
        d.mkdir(parents=True)
        write_png(d / 'ui.before.png', 16, 16)
        write_png(d / 'ui.after.png', 16, 16, paint=block(2, 2, 6, 6))
        role = job['plan']['roles'][0]
        self.assertTrue(bt.auto_capture(job, role, str(wd), 'before')['ok'])
        self.assertTrue(bt.auto_capture(job, role, str(wd), 'after')['ok'])
        self.assertEqual(self.grabs, [])
        self.assertTrue(bt.job_screens(job['id'])[0]['captured'])

    def test_revise_keeps_first_before_and_replaces_after(self):
        job = bt.load_job(self.job_with('화면 디자인')['id'])
        role = job['plan']['roles'][0]
        bt.auto_capture(job, role, self.proj, 'before')
        first = Path(bt.job_path(job['id'], 'screens/ui.before.png')).read_bytes()
        self.assertIsNone(bt.auto_capture(job, role, self.proj, 'before'))      # 두 번째 시도는 건너뛴다
        n = len(self.grabs)
        bt.auto_capture(job, role, self.proj, 'after')
        self.assertEqual(len(self.grabs), n + 1)
        self.assertEqual(Path(bt.job_path(job['id'], 'screens/ui.before.png')).read_bytes(), first)

    def test_is_screen_task_rules(self):
        self.assertTrue(bt.is_screen_task({'name': '프론트엔드 담당', 'mission': '', 'kind': 'code'}))
        self.assertTrue(bt.is_screen_task({'name': 'x', 'mission': 'Fix the layout', 'kind': 'docs'}))
        self.assertFalse(bt.is_screen_task({'name': '백엔드', 'mission': '라이선스 검증', 'kind': 'code'}))
        self.assertFalse(bt.is_screen_task({'name': '디자인 조사', 'mission': '', 'kind': 'readonly'}))


if __name__ == '__main__':
    unittest.main()
