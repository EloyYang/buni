"""변경 전·후 화면 캡처 생성기 — 엔진 capture_screen · CLI capture · '캡처 아님' 표시 (맥·Windows 화면이 같은 문구·필드를 쓰는지 포함).
실제 화면은 찍지 않는다: 가짜 PNG 파일 가져오기(source)와 grab_screen 바꿔치기로 시험한다."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
sys.path.insert(0, str(HERE))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402
from test_screen_diff import write_png, block  # noqa: E402


class CaptureEngine(unittest.TestCase):
    def setUp(self):
        self.src = Path(TMP.name) / 'src'
        self.src.mkdir(exist_ok=True)
        self.a = self.src / 'a.png'
        self.b = self.src / 'b.png'
        write_png(self.a, 32, 32)
        write_png(self.b, 32, 32, paint=block(8, 8, 16, 16))
        self._grab = bt.grab_screen

    def tearDown(self):
        bt.grab_screen = self._grab

    def test_import_pair_makes_captured_screen_with_box(self):
        jid = 'cap-import'
        r1 = bt.capture_screen(jid, 'home', 'before', source=str(self.a))
        r2 = bt.capture_screen(jid, 'home', 'after', source=str(self.b))
        self.assertTrue(r1['ok'] and r2['ok'])
        self.assertTrue(Path(bt.job_path(jid, 'screens/home.before.png')).is_file())
        items = bt.job_screens(jid)
        self.assertEqual(len(items), 1)
        self.assertTrue(items[0]['captured'])
        self.assertEqual(len(items[0]['boxes']), 1)

    def test_one_side_only_is_not_a_capture(self):
        jid = 'cap-half'
        bt.capture_screen(jid, 'home', 'before', source=str(self.a))
        it = bt.job_screens(jid)[0]
        self.assertFalse(it['captured'])
        self.assertEqual(it['missing'], ['after'])
        self.assertEqual(it['after'], '')
        self.assertTrue(it['before'].endswith('home.before.png'))
        self.assertIn('변경 후', it['reason'])
        bt.capture_screen(jid, 'home', 'after', source=str(self.b))     # 나중에 찍으면 다시 계산돼 캡처로 바뀐다
        self.assertTrue(bt.job_screens(jid)[0]['captured'])

    def test_failed_grab_records_reason_and_keeps_old_file(self):
        jid = 'cap-fail'
        bt.capture_screen(jid, 'home', 'after', source=str(self.a))
        old = Path(bt.job_path(jid, 'screens/home.after.png')).read_bytes()
        bt.grab_screen = lambda path, window='', region='': '화면 기록 권한이 없어요'
        r = bt.capture_screen(jid, 'home', 'after')
        self.assertFalse(r['ok'])
        self.assertEqual(Path(bt.job_path(jid, 'screens/home.after.png')).read_bytes(), old)
        self.assertFalse(Path(bt.job_path(jid, 'screens/home.after.png.tmp')).exists())
        log = json.loads(Path(bt.job_path(jid, 'captures.json')).read_text(encoding='utf-8'))
        self.assertFalse(log['home']['after']['ok'])

    def test_failed_only_screen_shows_not_a_capture(self):
        jid = 'cap-none'
        bt.grab_screen = lambda path, window='', region='': '화면을 찍지 못했어요'
        bt.capture_screen(jid, 'settings', 'before')
        bt.capture_screen(jid, 'settings', 'after')
        it = bt.job_screens(jid)[0]
        self.assertFalse(it['captured'])
        self.assertEqual(it['missing'], ['before', 'after'])
        self.assertIn('화면을 찍지 못했어요', it['reason'])

    def test_grab_writing_non_png_is_failure(self):
        def fake(path, window='', region=''):
            Path(path).write_bytes(b'not an image')
            return ''
        bt.grab_screen = fake
        r = bt.capture_screen('cap-bad', 'x', 'before')
        self.assertFalse(r['ok'])
        self.assertFalse(Path(bt.job_path('cap-bad', 'screens/x.before.png')).exists())

    def test_grab_success_saves_png(self):
        def fake(path, window='', region=''):
            Path(path).write_bytes(self.a.read_bytes())
            return ''
        bt.grab_screen = fake
        self.assertTrue(bt.capture_screen('cap-ok', 'x', 'before')['ok'])

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            bt.capture_screen('cap-arg', '../evil', 'before', source=str(self.a))
        with self.assertRaises(ValueError):
            bt.capture_screen('cap-arg', 'ok', 'middle', source=str(self.a))
        self.assertFalse(bt.capture_screen('cap-arg', 'ok', 'before', source=str(self.src / 'none.png'))['ok'])
        self.assertTrue(bt.grab_screen(str(self.src / 'z.png'), region='1,2,3'))      # 영역 형식 오류 → 이유 문자열

    def test_cli_capture_and_screens(self):
        env = dict(os.environ, BUNI_TEAM_HOME=TMP.name)
        cli = [sys.executable, str(HERE.parent / 'windows/buni_team.py')]
        r = subprocess.run(cli + ['capture', 'cap-cli', 'home', 'before', '--from-file', str(self.a)], capture_output=True, text=True, env=env)
        self.assertTrue(json.loads(r.stdout)['ok'], r.stdout + r.stderr)
        r = subprocess.run(cli + ['capture', 'cap-cli', 'bad/name', 'after', '--from-file', str(self.a)], capture_output=True, text=True, env=env)
        self.assertFalse(json.loads(r.stdout)['ok'])
        r = subprocess.run(cli + ['screens', 'cap-cli'], capture_output=True, text=True, env=env)
        s = json.loads(r.stdout)['screens']
        self.assertFalse(s[0]['captured'])


class NotCaptureInViews(unittest.TestCase):
    swift = (HERE.parent / 'Sources/ClaudeCompanion/SquadBoardViews.swift').read_text(encoding='utf-8')
    py = (HERE.parent / 'windows/buni_team_ui.py').read_text(encoding='utf-8')

    def test_same_label_and_fields(self):
        for ko, en in (('캡처 아님', 'Not a capture'),):
            for src in (self.swift, self.py):
                self.assertIn(ko, src)
                self.assertIn(en, src)
        for key in ('captured', 'reason'):
            self.assertIn(f'"{key}"', self.swift)
            self.assertIn(f"'{key}'", self.py)


if __name__ == '__main__':
    unittest.main()
