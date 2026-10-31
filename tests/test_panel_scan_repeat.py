"""스캔을 여러 번 돌려도 스쿼드 팀장 부니 패널이 작업당(앱 전체에서) 하나로 유지된다.
Windows 감시 주기(_poll_sessions)가 쓰는 규칙(buni_sessions)을 같은 순서(예약 → 생성 → 정리)로 반복 돌려 재현하고,
맥 AppDelegate 가 같은 문 앞에서 같은 규칙을 쓰는지 소스로 확인한다. 앱을 직접 띄우지는 않는다."""
import random
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
import buni_sessions as bs  # noqa: E402

APP = (ROOT / 'Sources/ClaudeCompanion/AppDelegate.swift').read_text(encoding='utf-8')
WIN = (ROOT / 'windows/buni.py').read_text(encoding='utf-8')


class Sim:
    """창(panels)·예약(pending)·치운 시각을 가진 작은 앱 — 한 번의 scan() 이 감시 주기 한 번이다."""

    def __init__(self):
        self.panels = {}          # 세션 id → 이벤트 파일 수정 시각
        self.pending = set()
        self.removed_at = 0.0

    def scan(self, found, now, finish_pending=True):
        # 1) 닫을 중복 정리 (collapse_squad_panels)
        for sid in bs.squad_panels_to_close({s: found.get(s, 0) for s in self.panels}):
            self.panels.pop(sid)
            self.removed_at = now
        # 2) 새 패널 예약 (_pending_add 에 올린 뒤 창 만들기)
        for sid in bs.pick_new_sessions(found, set(self.panels) | self.pending, self.removed_at):
            self.pending.add(sid)
        if finish_pending:
            for sid in sorted(self.pending):
                if sid.startswith(bs.SQUAD_PREFIX) and any(s.startswith(bs.SQUAD_PREFIX) for s in self.panels):
                    continue   # add_session 안의 마지막 문(이미 스쿼드 창이 있으면 만들지 않음)
                self.panels[sid] = found.get(sid, 0)
            self.pending.clear()

    def squads(self):
        return [s for s in self.panels if s.startswith(bs.SQUAD_PREFIX)]


class RepeatedScan(unittest.TestCase):
    def test_same_files_scanned_many_times_make_one_panel(self):
        sim = Sim()
        found = {'squad-j1': 10, 'squad-j2': 30, 'squad-j3': 20, 'u1': 5}
        for i in range(50):
            sim.scan(found, 100 + i)
        self.assertEqual(sim.squads(), ['squad-j2'])
        self.assertEqual(sorted(sim.panels), ['squad-j2', 'u1'])

    def test_slow_window_creation_does_not_double_reserve(self):
        # 창 만들기가 다음 주기까지 밀려도(예약만 있고 창은 아직 없음) 다른 스쿼드 파일이 또 예약되지 않는다
        sim = Sim()
        found = {'squad-j1': 10, 'squad-j2': 30}
        for i in range(5):
            sim.scan(found, 100 + i, finish_pending=False)
        self.assertEqual(len(sim.pending), 1)
        sim.scan(found, 200)
        self.assertEqual(len(sim.squads()), 1)

    def test_new_job_events_keep_single_panel(self):
        # 작업이 바뀌어 새 squad 파일이 더 최근이 돼도(패널이 이미 있는 동안) 패널은 늘지 않는다
        sim = Sim()
        sim.scan({'squad-j1': 10}, 100)
        for i, mt in enumerate((120, 130, 140)):
            sim.scan({'squad-j1': 10, 'squad-j%d' % (i + 2): mt}, 150 + i)
            self.assertEqual(len(sim.squads()), 1)

    def test_preexisting_duplicates_collapse_and_do_not_come_back(self):
        sim = Sim()
        sim.panels = {'squad-a': 10, 'squad-b': 30, 'squad-c': 20}   # 이미 3개 떠 있던 상태
        found = {'squad-a': 10, 'squad-b': 30, 'squad-c': 20}
        for i in range(20):
            sim.scan(found, 100 + i)
            self.assertEqual(sim.squads(), ['squad-b'])

    def test_closed_panel_is_not_revived_by_stale_files(self):
        sim = Sim()
        sim.scan({'squad-j1': 10, 'squad-j2': 20}, 100)
        sim.panels.clear()
        sim.removed_at = 150.0                                       # 사용자가 패널을 닫음
        for i in range(10):
            sim.scan({'squad-j1': 10, 'squad-j2': 20}, 160 + i)       # 그 뒤로 안 바뀐 파일
        self.assertEqual(sim.squads(), [])
        sim.scan({'squad-j1': 10, 'squad-j2': 200}, 210)              # 새 활동이 생기면 하나만 다시 뜬다
        self.assertEqual(sim.squads(), ['squad-j2'])

    def test_random_scans_never_exceed_one(self):
        rnd = random.Random(6001)
        sim = Sim()
        for step in range(300):
            found = {'squad-j%d' % k: rnd.randint(1, 1000) for k in range(rnd.randint(0, 5))}
            if rnd.random() < 0.1:
                sim.panels.update({'squad-x%d' % step: rnd.randint(1, 1000), 'squad-y%d' % step: rnd.randint(1, 1000)})
            sim.scan(found, 1000 + step, finish_pending=rnd.random() < 0.7)
            self.assertLessEqual(len(sim.squads()), 1, 'step %d' % step)


class CreationPathsGuard(unittest.TestCase):
    def test_mac_every_add_path_is_gated(self):
        # 소켓(149)·스캐너·레거시 모두 addSession 하나로 모이고, 거기서 스쿼드 중복을 막는다
        m = re.search(r'private func addSession\(id: String, fileURL: URL\) \{(.*?)\n        // 실제 Claude', APP, re.S)
        self.assertTrue(m)
        self.assertIn('guard sessions[id] == nil', m.group(1))
        self.assertIn('hasSquadPanel()', m.group(1))
        self.assertEqual(len(re.findall(r'SessionWindow\(sessionId:', APP)), 1)   # 패널을 만드는 곳은 한 곳뿐
        self.assertIn('self.collapseSquadPanels()', APP)

    def test_windows_every_add_path_is_gated(self):
        self.assertIn('set(self.sessions) | set(self._pending_add)', WIN)
        self.assertIn('self._pending_add.discard(session_id)', WIN)
        self.assertIn('self._squad_removed_at', WIN)
        self.assertIn('self.collapse_squad_panels()', WIN)


if __name__ == '__main__':
    unittest.main()
