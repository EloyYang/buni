"""
배터리 절약 회귀 가드 — python3 tests/test_battery_guards.py
맥(Swift)·Windows(Python) 앱의 반복 작업이 예전의 잦은 깨움으로 되돌아가지 않았는지 소스로 확인한다.
(앱을 띄워 재는 시험이 아니라, 줄인 값·멈추는 조건이 코드에 남아 있는지 보는 시험)
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'Sources/ClaudeCompanion'
WIN = (ROOT / 'windows/buni.py').read_text(encoding='utf-8')


def swift(name):
    return (SRC / name).read_text(encoding='utf-8')


class WindowsBattery(unittest.TestCase):
    def test_hotkey_loop_sleeps_until_message(self):
        # 5ms sleep 폴링이 아니라 GetMessageW 로 잠든다
        body = WIN[WIN.index('class GlobalHotkeyManager'):WIN.index('class GlobalHotkeyManager') + 6000]
        self.assertIn('GetMessageW', body)
        self.assertNotIn('time.sleep(0.005)', body)
        self.assertIn('PostThreadMessageW', body)          # 등록·해제 요청 때 깨운다

    def test_tasklist_not_every_second(self):
        self.assertRegex(WIN, r'CLAUDE_CHECK_SEC\s*=\s*([4-9]|\d{2,})\.0')
        self.assertRegex(WIN, r'MONITOR_SLEEP_SEC\s*=\s*([2-9]|\d{2,})\.0')

    def test_click_through_adaptive(self):
        self.assertRegex(WIN, r'CLICK_POLL_HIDDEN_MS\s*=\s*500')
        self.assertRegex(WIN, r'CLICK_POLL_FAR_MS\s*=\s*100')
        self.assertIn('if over != self._click_over', WIN)  # 바뀔 때만 SetWindowLong

    def test_hidden_windows_do_not_draw(self):
        self.assertIn('if not self.is_visible:               # 숨겨진 창은 깜빡이지 않고', WIN)
        self.assertIn('self.state != \'idle\' and self.is_visible', WIN)

    def test_token_scan_skips_old_files(self):
        self.assertIn('st.st_mtime < month_start', WIN)
        self.assertIn('_token_cache', WIN)

    def test_session_poll_backs_off(self):
        m = re.search(r'SESSION_POLL_ACTIVE_MS\s*=\s*(\d+).*?SESSION_POLL_QUIET_MS\s*=\s*(\d+).*?SESSION_POLL_NONE_MS\s*=\s*(\d+)',
                      WIN, re.S)
        self.assertIsNotNone(m)
        a, q, n = map(int, m.groups())
        self.assertLess(a, q)
        self.assertLess(q, n)


class MacBattery(unittest.TestCase):
    def test_scanner_adapts_interval(self):
        s = swift('AppDelegate.swift')
        self.assertIn('repeating: scanInterval', s)
        self.assertNotIn('repeating: .milliseconds(500))\n        t.setEventHandler { [weak self] in self?.scanForSessions()', s)
        self.assertIn('AppActivity.shared.screenAsleep ? .seconds(4)', s)
        self.assertIn('timeIntervalSince(claudeLastSeen) >= 3', s)       # 종료 디바운스는 시간 기준 3초

    def test_event_monitor_single_timer_and_watcher(self):
        s = swift('EventMonitor.swift')
        self.assertIn('guard timer == nil else { return }', s)           # 타이머 중복 방지
        self.assertIn('makeFileSystemObjectSource', s)
        self.assertIn('watcher?.cancel()', s)                            # stop() 에서 정리

    def test_animations_pause_when_hidden(self):
        self.assertIn('ctrl.isPaused ? nil : .easeInOut', swift('EquipmentView.swift'))
        self.assertIn('paused', swift('WorkToolViews.swift'))
        self.assertIn('didChangeOcclusionStateNotification', swift('SessionWindow.swift'))
        self.assertIn('screensDidSleepNotification', swift('AppActivity.swift'))


class Parity(unittest.TestCase):
    def test_same_quiet_policy_names(self):
        # 양쪽 모두 "창이 가려지면 멈춘다"와 "화면이 꺼지면 스캔을 늦춘다/숨기면 확인만 한다" 정책을 가진다
        self.assertIn('is_visible', WIN)
        self.assertIn('occlusionState', swift('SessionWindow.swift'))


if __name__ == '__main__':
    unittest.main()
