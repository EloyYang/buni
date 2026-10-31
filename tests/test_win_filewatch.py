"""Windows 스쿼드 화면의 파일 변경 확인 — mtime 판정, 입력 중 보류, 숨김, 안전망 주기. Tk 없이 buni_watch 만 시험한다."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
import buni_watch as bw  # noqa: E402


def _write(p, text, ns):
    Path(p).parent.mkdir(parents=True, exist_ok=True)
    Path(p).write_text(text, encoding='utf-8')
    os.utime(p, ns=(ns, ns))


class Scan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jobs = os.path.join(self.tmp.name, 'jobs')
        self.job = os.path.join(self.jobs, 'a', 'job.json')
        _write(self.job, '{}', 1_000_000_000)

    def tearDown(self):
        self.tmp.cleanup()

    def test_mtime_change_detected(self):
        a = bw.scan_jobs(self.jobs)
        self.assertEqual(a, bw.scan_jobs(self.jobs))
        _write(self.job, '{}', 2_000_000_000)                 # 같은 크기, 수정 시각만 다름
        self.assertNotEqual(a, bw.scan_jobs(self.jobs))

    def test_size_change_with_same_mtime(self):
        a = bw.scan_jobs(self.jobs)
        _write(self.job, '{"x":1}', 1_000_000_000)            # 제자리 덮어쓰기로 시각이 같아도 크기가 다름
        self.assertNotEqual(a, bw.scan_jobs(self.jobs))

    def test_new_and_removed_job(self):
        a = bw.scan_jobs(self.jobs)
        _write(os.path.join(self.jobs, 'b', 'chat.jsonl'), 'x', 1)
        self.assertNotEqual(a, bw.scan_jobs(self.jobs))
        self.assertEqual(bw.scan_jobs(os.path.join(self.tmp.name, 'none')), bw.scan_jobs(os.path.join(self.tmp.name, 'none')))

    def test_unwatched_files_ignored(self):
        a = bw.scan_jobs(self.jobs)
        _write(os.path.join(self.jobs, 'a', 'activity-dev.json'), 'x', 5)   # 실시간 활동은 별도 갱신
        self.assertEqual(a, bw.scan_jobs(self.jobs))


class Watch(unittest.TestCase):
    def make(self, safety=30.0):
        self.state = ['v1']
        self.calls = 0

        def scan():
            self.calls += 1
            return self.state[0]
        return bw.ChangeWatch(scan, safety)

    def test_first_then_quiet_then_change(self):
        w = self.make()
        self.assertTrue(w.poll(0))                  # 처음 한 번
        self.assertFalse(w.poll(1.5))               # 변화 없으면 다시 읽지 않는다
        self.assertFalse(w.poll(3.0))
        self.state[0] = 'v2'
        self.assertTrue(w.poll(4.5))
        self.assertFalse(w.poll(6.0))

    def test_typing_defers_then_applies_once(self):
        w = self.make()
        w.poll(0)
        self.state[0] = 'v2'
        for t in (1, 2, 3):
            self.assertFalse(w.poll(t, typing=True))   # 입력 중에는 디스크도 안 읽고 갱신도 안 한다
        self.assertEqual(self.calls, 1)
        self.assertTrue(w.poll(4))                     # 입력이 끝나면 쌓인 변화를 한 번 반영
        self.assertFalse(w.poll(5))

    def test_hidden_skips_and_catches_up(self):
        w = self.make()
        w.poll(0)
        self.state[0] = 'v2'
        self.assertFalse(w.poll(5, hidden=True))
        self.assertEqual(self.calls, 1)
        self.assertTrue(w.poll(10))                    # 다시 보이면 바로 반영

    def test_safety_interval_rereads(self):
        w = self.make(safety=30)
        w.poll(0)
        self.assertFalse(w.poll(29))
        self.assertTrue(w.poll(30))                    # 감지 못 한 변화를 위해 한 번은 읽는다
        self.assertFalse(w.poll(31))

    def test_reset(self):
        w = self.make()
        w.poll(0)
        w.reset()
        self.assertTrue(w.poll(1))


class UiWiring(unittest.TestCase):
    def test_no_unconditional_refresh_in_tick(self):
        src = (ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        tick = src[src.index('    def _tick(self):'):src.index('    HIDDEN_TICK_MS')]
        self.assertIn('self._watch.poll(', tick)
        self.assertIn('poll(time.time(), typing=False, hidden=False):', tick.split('self.refresh()')[0].splitlines()[-2])
        self.assertIn('rw.poll(', src)


if __name__ == '__main__':
    unittest.main()
