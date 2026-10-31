"""맥 사이드바 '업무 중' 팀원 아바타의 빛나는 테두리 규칙을 소스로 확인한다 (화면 실기 아님)."""
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read(*parts):
    with open(os.path.join(ROOT, *parts), encoding='utf-8') as f:
        return f.read()


def _block(src, start_marker, end_marker):
    a = src.index(start_marker)
    return src[a:src.index(end_marker, a)]


class WorkingRingRules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = _read('Sources', 'ClaudeCompanion', 'SquadSlackViews.swift')
        cls.ring = _block(cls.src, 'struct SquadWorkingRing', '// MARK: - 모델 고르기')

    def test_only_when_working(self):
        presence = _block(self.src, 'struct SquadPresence', 'struct SquadWorkingRing')
        self.assertIn('if working { SquadWorkingRing() }', presence)

    def test_no_infinite_animation(self):
        for banned in ('TimelineView', 'repeatForever', 'withAnimation', '.animation('):
            self.assertNotIn(banned, self.ring)

    def test_timer_period_and_stops(self):
        m = re.search(r'static let period: TimeInterval = ([0-9.]+)', self.ring)
        self.assertGreaterEqual(float(m.group(1)), 0.5)
        self.assertIn('timer?.invalidate()', self.ring)       # 업무 중인 행이 없으면 멈춘다
        self.assertIn('users == 0', self.ring)

    def test_preview_and_reduce_motion_are_still(self):
        self.assertIn('BUNI_PREVIEW', self.ring)
        self.assertIn('accessibilityReduceMotion', self.ring)
        self.assertIn('if !still { clock.retain() }', self.ring)

    def test_tokens_only(self):
        self.assertIn('Color.buniOk', self.ring)
        for banned in ('.gray', '.accentColor', 'Color.white', 'Color.green', '.green'):
            self.assertNotIn(banned, self.ring)

    def test_sidebar_passes_working_state(self):
        views = _read('Sources', 'ClaudeCompanion', 'TeamViews.swift')
        self.assertIn('working: st?.status == "running"', views)


if __name__ == '__main__':
    unittest.main()
