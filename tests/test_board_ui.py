"""
Windows 전체 현황 화면 훑어보기 시험 — Tk 를 띄울 수 없는 환경(화면 없음)이면 건너뛴다.
보드 ↔ 목록 전환 · 검색/상태/범위 필터 · 카드 상세 · 프로젝트 화면으로 이동이 오류 없이 그려지는지만 본다 (눈으로 보는 확인은 아님).
"""
import faulthandler
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
sys.path.insert(0, str(HERE))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
os.environ['BUNI_CLAUDE'] = os.path.join(TMP.name, 'no-such-claude')      # 실수로라도 진짜 claude 를 부르지 않는다
import test_board  # noqa: E402,F401  (BUNI_TEAM_HOME 을 같은 임시 폴더로 쓴다)

_root = None
if os.environ.get('BUNI_UI_TEST') == '1':           # 화면이 있는 PC 에서만: BUNI_UI_TEST=1 python3 -m unittest tests.test_board_ui
    try:
        import tkinter as tk
        _root = tk.Tk()
        _root.withdraw()
    except Exception:                               # 화면이 없거나 tkinter 가 없다
        _root = None


@unittest.skipIf(_root is None, 'BUNI_UI_TEST=1 이고 Tk 를 띄울 수 있을 때만')
class BoardUi(unittest.TestCase):
    def test_draw_and_navigate(self):
        faulthandler.dump_traceback_later(25, exit=True)          # 멈추면 어디서 멈췄는지 찍고 끝낸다
        import buni_team
        import buni_team_ui as ui
        test_board.BoardCards.setUpClass()
        buni_team.ensure_wrapup = lambda *a, **k: None              # 결과 화면이 열릴 때 부르는 팀장 정리 — 진짜 claude 를 부르지 않게
        win = ui.TeamWindow(type('M', (), {'root': _root})(), lambda ko, en: ko)
        try:
            win._open_board(); _root.update()
            self.assertTrue(win._board)
            for view in ('board', 'list'):
                win._bset('view', view); _root.update()
                win._bsel = win._cards[0]['id']; win._draw_board_results(); _root.update()
            # 카드 상세는 오른쪽 벽이 아니라 창 가운데 팝업이다 — 한 번 열면 하나, 닫으면 사라지고, 다른 화면으로 가면 같이 닫힌다
            win._bsel = win._cards[0]['id']; win._draw_board_results(); _root.update()
            pop = win._dpop
            self.assertIsNotNone(pop)
            self.assertTrue(pop.winfo_exists())
            win._draw_board_results(); _root.update()
            self.assertIs(win._dpop, pop)                                 # 다시 그려도 팝업을 또 만들지 않는다
            win.win.update_idletasks()
            cx = pop.winfo_rootx() + pop.winfo_width() / 2
            self.assertAlmostEqual(cx, win.win.winfo_rootx() + win.win.winfo_width() / 2, delta=80)   # 가운데
            win._close_detail_popup(clear=True); win._draw_board_results(); _root.update()
            self.assertIsNone(win._bsel)
            self.assertIsNone(win._dpop)
            win._bsel = win._cards[0]['id']; win._draw_board_results(); _root.update()
            win._select(None); _root.update()
            self.assertIsNone(win._dpop)                                   # 다른 화면으로 가면 같이 닫힌다
            win._open_board(); _root.update()
            win._bset('q', '결제'); win._bset('scope', 'finished'); win._bset('status', ''); _root.update()
            win._bset('scope', 'all'); win._bset('q', '')
            card = next(c for c in win._cards if c['role_id'])
            win._board_goto(card['job_id'], 'dm:' + card['role_id']); _root.update()
            self.assertFalse(win._board)
            self.assertEqual(win.sel, card['job_id'])
            self.assertEqual(len(buni_team.list_jobs()), len({c['job_id'] for c in win._cards}))   # 이동해도 프로젝트가 늘지 않는다
        finally:
            win.close()


if __name__ == '__main__':
    unittest.main()
