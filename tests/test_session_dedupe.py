"""같은 세션에 부니 패널이 둘 이상 생기지 않는다 — 세션 고르기 규칙(맥 SessionDedupe.swift · Windows buni_sessions.py)과
치운 세션이 파일 변화 없이 되살아나지 않는 장치(맥 ignoredSessionIds · Windows _removed_at)를 확인한다."""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
import buni_sessions as bs  # noqa: E402

SWIFT = (ROOT / 'Sources/ClaudeCompanion/SessionDedupe.swift').read_text(encoding='utf-8')
APP = (ROOT / 'Sources/ClaudeCompanion/AppDelegate.swift').read_text(encoding='utf-8')
WIN = (ROOT / 'windows/buni.py').read_text(encoding='utf-8')


class PickNewSessions(unittest.TestCase):
    def test_existing_session_is_not_created_again(self):
        self.assertEqual(bs.pick_new_sessions({'a': 1, 'b': 2}, {'a'}), ['b'])
        self.assertEqual(bs.pick_new_sessions({'a': 1}, {'a'}), [])

    def test_many_squad_files_make_one_panel(self):
        found = {'squad-j1': 10, 'squad-j2': 30, 'squad-j3': 20, 'abc': 5}
        self.assertEqual(bs.pick_new_sessions(found, set()), ['abc', 'squad-j2'])

    def test_no_second_squad_panel_while_one_exists(self):
        found = {'squad-j1': 10, 'squad-j2': 30}
        self.assertEqual(bs.pick_new_sessions(found, {'squad-j1'}), [])
        self.assertEqual(bs.pick_new_sessions(found, {'squad-j2'}), [])

    def test_squad_does_not_block_normal_sessions(self):
        found = {'squad-j1': 10, 'u1': 1, 'u2': 2}
        self.assertEqual(bs.pick_new_sessions(found, {'squad-j1', 'u1'}), ['u2'])

    def test_id_prefix_is_case_sensitive_like_the_engine(self):
        # 엔진은 항상 소문자 'squad-' 로 적는다 — 다른 철자는 일반 세션으로 본다
        self.assertEqual(bs.pick_new_sessions({'Squad-j1': 1}, set()), ['Squad-j1'])


class SquadRevive(unittest.TestCase):
    def test_stale_squad_file_is_not_revived_after_panel_removed(self):
        # 패널을 치운 뒤(t=100) 안 바뀐 다른 작업의 스쿼드 파일로 새 패널이 생기면 안 된다
        found = {'squad-j1': 50, 'squad-j2': 90}
        self.assertEqual(bs.pick_new_sessions(found, set(), squad_removed_at=100), [])
        self.assertEqual(bs.pick_new_sessions({**found, 'squad-j2': 120}, set(), squad_removed_at=100), ['squad-j2'])

    def test_pending_squad_counts_as_existing(self):
        self.assertEqual(bs.pick_new_sessions({'squad-j1': 10, 'squad-j2': 30}, {'squad-j2'}), [])

    def test_collapse_keeps_only_newest_squad_panel(self):
        panels = {'squad-a': 10, 'squad-b': 30, 'squad-c': 20, 'u1': 1}
        self.assertEqual(bs.squad_panels_to_close(panels), ['squad-a', 'squad-c'])
        self.assertEqual(bs.squad_panels_to_close({'squad-a': 10, 'u1': 1}), [])
        self.assertEqual(bs.squad_panels_to_close({}), [])


class BothPlatformsGuard(unittest.TestCase):
    def test_windows_collapse_and_add_gate(self):
        self.assertIn('def collapse_squad_panels', WIN)
        self.assertIn('self.collapse_squad_panels()', WIN)             # 주기적 확인(_poll_sessions)
        self.assertIn('self._squad_removed_at', WIN)
        self.assertIn('set(self.sessions) | set(self._pending_add)', WIN)
        m = re.search(r'def collapse_squad_panels\(self\):(.*?)\n    def ', WIN, re.S)
        self.assertTrue(m)
        self.assertNotIn('unlink', m.group(1))                          # 패널만 닫고 데이터 파일은 지우지 않는다

    def test_swift_rule_matches_python(self):
        self.assertIn('"squad-"', SWIFT)
        self.assertEqual(bs.SQUAD_PREFIX, 'squad-')
        self.assertIn('SessionDedupe.newSessions', APP)

    def test_mac_stale_removal_remembers_session(self):
        m = re.search(r'func removeStaledSession\(id: String\) \{(.*?)\n    \}', APP, re.S)
        self.assertTrue(m)
        self.assertIn('ignoredSessionIds[id] = Date()', m.group(1))

    def test_windows_remove_and_monitor_guards(self):
        self.assertIn('self._removed_at[session_id] = time.time()', WIN)
        self.assertIn('buni_sessions.pick_new_sessions', WIN)
        self.assertIn('self._pending_add', WIN)


if __name__ == '__main__':
    unittest.main()
