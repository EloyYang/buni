"""
업무 현황 카드·상세 가독성 시험 — python3 tests/test_board_readability.py
카드의 프로젝트·한 줄 요약(brief)·상태 이유(why)·원래 지시·바뀐 파일 수, 맥 SquadBoard 와 같은 규칙인지.
"""
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402

SWIFT = (HERE.parent / 'Sources/ClaudeCompanion/SquadBoardViews.swift').read_text(encoding='utf-8')


class BoardReadability(unittest.TestCase):
    def _job(self, status='running', rstatus='running', summary='', **extra):
        job = bt.new_job('결제 흐름 점검\n둘째 줄', '결제 목표', TMP.name)
        job['status'] = status
        job['plan'] = {'summary': '', 'roles': [{'id': 'dev', 'name': '개발자', 'icon': '🧑‍💻', 'kind': 'code',
                                                 'mission': '## 결제 코드를 고친다\n자세히', 'deliverable': '패치', 'depends_on': []}]}
        job['roles'] = {'dev': {'status': rstatus, 'summary': summary, 'feedback': '로그 추가'}}
        job.update(extra)
        bt.save_job(job)
        return job

    def card(self, **kw):
        job = self._job(**kw)
        return next(c for c in bt.board_cards([job]) if c['job_id'] == job['id'])

    def test_brief_prefers_report_then_mission(self):
        self.assertEqual(self.card(summary='보고 첫 줄\n둘째')['brief'], '보고 첫 줄')
        self.assertEqual(self.card()['brief'], '결제 코드를 고친다')       # 머리표(##) 제거

    def test_brief_line_rules(self):
        self.assertEqual(bt.brief_line('- **굵게**  글\n다음'), '**굵게** 글')
        self.assertEqual(bt.brief_line('가' * 100), '가' * 59 + '…')
        self.assertEqual(bt.brief_line(''), '')

    def test_why_and_instruction(self):
        c = self.card(status='review', rstatus='done_unreviewed')
        self.assertEqual(c['why'], '결과가 나와 검토를 기다려요')
        self.assertEqual(c['instruction'], '## 결제 코드를 고친다\n자세히\n산출물: 패치')
        self.assertEqual(self.card(status='failed', rstatus='running', error='네트워크 오류')['why'], '네트워크 오류')
        self.assertIn('로그 추가', self.card(rstatus='revise')['why'])
        self.assertEqual(c['project'], '결제 흐름 점검')

    def test_changed_files_and_detail(self):
        c = self.card(changed_files=3, summary='끝')
        d = bt.board_detail(c)
        self.assertEqual((d['changed_files'], d['summary'], d['project']), (3, '끝', '결제 흐름 점검'))
        self.assertTrue(d['instruction'] and d['why'])
        self.assertEqual(self.card()['changed_files'], 0)

    def test_swift_same_rules(self):
        self.assertIn(f'static let briefMax = {bt.BRIEF_MAX}', SWIFT)
        for ko in ('실패로 멈췄어요', '플랜 한도가 풀리길 기다려요', '잠시 멈춰 있어요', '확인이 필요해요', '통과했어요', '프로젝트가 끝났어요',
                   '결과가 나와 검토를 기다려요', '작업하는 중이에요', '고쳐 달라는 요청을 반영하는 중이에요', '시작을 기다려요', '거절해서 닫았어요'):
            self.assertIn(ko, SWIFT)
            self.assertIn(ko, Path(bt.__file__).read_text(encoding='utf-8'))
        for label in ('상태 이유', '원래 지시', '바뀐 파일', '결과 요약', '기록 없음', '아직 보고가 없어요'):
            self.assertIn(label, SWIFT)
            self.assertIn(label, (HERE.parent / 'windows/buni_team_ui.py').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
