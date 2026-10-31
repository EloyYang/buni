"""Windows 스쿼드 목록 '업무 중' 아바타 테두리 규칙 — 업무 중일 때만, 간격 ≥300ms, 행이 없으면 타이머 정지, BUNI_PREVIEW 고정.
Tk 없이 buni_ring 의 가짜 after 로 시험한다 (화면 실기 아님)."""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
import buni_ring as br  # noqa: E402
from buni_theme import C, mix  # noqa: E402


class FakeTk:
    def __init__(self):
        self.jobs, self.n, self.delays = {}, 0, []

    def after(self, ms, fn):
        self.n += 1
        self.jobs[self.n] = fn
        self.delays.append(ms)
        return self.n

    def cancel(self, i):
        self.jobs.pop(i, None)

    def fire(self):
        i = min(self.jobs)
        self.jobs.pop(i)()


def make(still=False, active=lambda: True, period=br.PERIOD_MS):
    tk, drawn = FakeTk(), []
    clock = br.RingClock(tk.after, tk.cancel, lambda c, b: drawn.append((c, b)), still=still, period_ms=period, active=active)
    return tk, clock, drawn


class Rules(unittest.TestCase):
    def test_only_working_statuses(self):
        self.assertTrue(br.is_working('running'))
        self.assertTrue(br.is_working('doing'))
        for s in ('pending', 'accepted', 'done_unreviewed', 'revise', '', None):
            self.assertFalse(br.is_working(s))

    def test_period_at_least_300ms(self):
        self.assertGreaterEqual(br.PERIOD_MS, 300)
        tk, clock, _ = make(period=50)               # 더 짧게 넣어도 300 아래로는 안 내려간다
        clock.register('a')
        self.assertTrue(all(d >= 300 for d in tk.delays))

    def test_timer_runs_only_with_working_rows(self):
        tk, clock, drawn = make()
        self.assertFalse(clock.running)
        clock.register('a')
        self.assertTrue(clock.running)
        tk.fire()
        self.assertEqual([b for _, b in drawn][-1], False)       # 켜짐 ↔ 꺼짐 번갈아
        tk.fire()
        self.assertEqual([b for _, b in drawn][-1], True)
        clock.clear()                                            # 목록을 다시 그림/창 닫음 → 멈춤
        self.assertFalse(clock.running)
        self.assertEqual(tk.jobs, {})

    def test_dead_canvas_stops_clock(self):
        tk, clock, _ = make()
        calls = []

        def redraw(c, b):
            if c == 'gone':
                raise RuntimeError('destroyed')
        clock._redraw = redraw
        clock.items = ['gone']
        clock.resume()
        tk.fire()
        self.assertEqual(clock.items, [])
        self.assertFalse(clock.running)                          # 업무 중인 행이 없으면 다음 예약도 없다
        self.assertEqual(tk.jobs, {})

    def test_hidden_stops_and_resumes(self):
        state = {'on': True}
        tk, clock, _ = make(active=lambda: state['on'])
        clock.register('a')
        state['on'] = False
        tk.fire()
        self.assertFalse(clock.running)
        clock.resume()
        self.assertFalse(clock.running)                          # 가려진 동안은 안 켠다
        state['on'] = True
        clock.resume()
        self.assertTrue(clock.running)

    def test_still_never_schedules(self):
        tk, clock, drawn = make(still=True)
        clock.register('a')
        self.assertEqual(tk.jobs, {})
        self.assertEqual(drawn, [('a', True)])                   # 한 번 밝게 그려 두기만

    def test_preview_and_reduce_motion_env(self):
        self.assertTrue(br.is_still({'BUNI_PREVIEW': '1'}))
        self.assertTrue(br.is_still({'BUNI_REDUCE_MOTION': '1'}))
        self.assertFalse(br.reduce_motion({'BUNI_REDUCE_MOTION': '0'}))
        if not sys.platform.startswith('win'):
            self.assertFalse(br.is_still({}))

    def test_colors_come_from_tokens(self):
        on, off = br.ring_colors(True), br.ring_colors(False)
        self.assertEqual(on['ring'], mix(C['ok'], C['rail'], 0.95))
        self.assertEqual(off['ring'], mix(C['ok'], C['rail'], 0.5))
        self.assertEqual((on['glow_w'], off['glow_w'], on['width']), (4, 0, 2))
        src = (ROOT / 'windows' / 'buni_ring.py').read_text(encoding='utf-8')
        self.assertIsNone(re.search(r"['\"]#[0-9A-Fa-f]{3,6}['\"]", src))

    def test_ui_wiring(self):
        src = (ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        self.assertIn("buni_ring.is_working(rs.get('status'))", src)
        self.assertIn('self._ring_clock.clear()', src)           # 다시 그리기·닫기에서 정리
        self.assertIn("'통과', 'Accepted'", src)                  # 글씨 상태 표시는 그대로
        self.assertIn("'● ' + t(rko, ren)", src)


if __name__ == '__main__':
    unittest.main()
