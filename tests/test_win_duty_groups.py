"""Windows 스쿼드 화면의 직무 그룹 표시 — 사이드바 묶음(부서 → 세부 담당 순), 보관 숨김, 옛 데이터(직무 필드 없음), 카드의 직무 줄."""
import re
import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
import buni_team as bt  # noqa: E402

UI = (ROOT / 'windows/buni_team_ui.py').read_text(encoding='utf-8')


def _shown_members():
    """buni_team_ui.TeamWindow._shown_members 를 Tk 없이 부른다 (소스에서 함수만 꺼내 실행)."""
    m = re.search(r'    def _shown_members\(self, job\):(.*?)\n(?=    def )', UI, re.S)
    ns = {'buni_team': bt}
    exec('def _shown_members(self, job):' + m.group(1), ns)
    return ns['_shown_members']


JOB = {'plan': {'roles': [
    {'id': 'research', 'name': '시장조사원'},                       # 옛 데이터 — 직무 필드 없음
    {'id': 'backend_server', 'name': '백엔드', 'dept': 'backend', 'duty': 'backend_server'},
    {'id': 'frontend_win', 'name': 'Win', 'dept': 'frontend', 'duty': 'frontend_win'},
    {'id': 'frontend_mac', 'name': 'Mac', 'dept': 'frontend', 'duty': 'frontend_mac', 'archived': True},
]}, 'roles': {'frontend_mac': {'status': 'accepted'}}}


class Groups(unittest.TestCase):
    def test_dept_then_duty_order_and_legacy_in_other(self):
        f = _shown_members()
        g = f(types.SimpleNamespace(_show_archived=False), JOB)
        self.assertEqual([(x['dept'], [m['id'] for m in x['members']]) for x in g],
                         [('frontend', ['frontend_win']), ('backend', ['backend_server']), ('', ['research'])])
        g = f(types.SimpleNamespace(_show_archived=True), JOB)
        self.assertEqual([m['id'] for m in g[0]['members']], ['frontend_mac', 'frontend_win'])     # 직무 카탈로그 순서: 맥 → Windows

    def test_card_duty_label_matches_mac_wording(self):
        self.assertEqual(bt.duty_label('backend_server'), '백엔드 · 서버·엔진')
        card = [c for c in bt.board_cards([{**JOB, 'id': 'j1', 'title': 't', 'status': 'running', 'created': 1, 'updated': 1,
                                            'roles': {'backend_server': {'status': 'running'}}}], now=10) if c.get('role_id') == 'backend_server']
        self.assertTrue(card)
        self.assertEqual(card[0]['duty'], '백엔드 · 서버·엔진')

    def test_ui_shows_duty_in_sidebar_dm_and_cards(self):
        for needle in ("buni_team.duty_label(buni_team.role_duty(role))", "c.get('duty')", 'Show archived teammates'):
            self.assertIn(needle, UI)


if __name__ == '__main__':
    unittest.main()
