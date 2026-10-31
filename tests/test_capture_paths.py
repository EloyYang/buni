"""변경 전·후 캡처 호출 경로 점검 — auto_capture 의 호출 순서(before→작업→after)·실패 시 기존 파일 유지·실패 이유 문구(맥 권한 / Windows Pillow)·안내 문구가 맥·Windows·문서에서 같은지.
실제 화면은 찍지 않는다: PATH 맨 앞에 가짜 `screencapture` 스크립트를 두거나(맥 경로), 가짜 PIL 모듈을 넣는다(Windows 경로)."""
import os
import stat
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
sys.path.insert(0, str(HERE))

import buni_team as bt  # noqa: E402
import test_fake_claude_flow as base  # noqa: E402
from test_screen_diff import write_png, block  # noqa: E402

FAKE_SCREENCAPTURE = '''#!/bin/sh
# 가짜 screencapture — 호출을 FAKE_LOG 에 적고(작업 호출과 한 줄 순서로 비교), FAKE_CAP_RC 가 0 이 아니면 권한 없음처럼 실패한다.
echo '{"name": "GRAB"}' >> "$FAKE_LOG"
if [ "${FAKE_CAP_RC:-0}" != "0" ]; then echo "could not create image from display" >&2; exit 1; fi
for a; do p="$a"; done
cp "$FAKE_PNG" "$p"
'''

ROOT = HERE.parent


class _Env:
    """환경변수를 시험 동안만 바꾼다."""
    def setup_env(self, **kv):
        self._env_saved = {k: os.environ.get(k) for k in kv}
        for k, v in kv.items():
            os.environ[k] = v

    def restore_env(self):
        for k, v in self._env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


@unittest.skipIf(os.name == 'nt', '가짜 screencapture 는 sh 스크립트라 맥·리눅스에서만')
class MacPath(base.FakeClaudeBase, _Env):
    def setUp(self):
        super().setUp()
        root = Path(self.tmp.name)
        bindir = root / 'bin'
        bindir.mkdir()
        tool = bindir / 'screencapture'
        tool.write_text(FAKE_SCREENCAPTURE, encoding='utf-8')
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        self.png = root / 'fake.png'
        write_png(self.png, 32, 32)
        self.setup_env(BUNI_CAPTURE_TEST='1', FAKE_PNG=str(self.png), FAKE_CAP_RC='0',
                       PATH=str(bindir) + os.pathsep + os.environ.get('PATH', ''))
        self.plat = mock.patch.object(bt.sys, 'platform', 'darwin')        # 맥이 아닌 PC 에서도 맥 경로를 탄다
        self.plat.start()
        bt.save_settings({'auto_followup': False, 'auto_capture': True})

    def tearDown(self):
        self.plat.stop()
        self.restore_env()
        super().tearDown()

    def screen_job(self):
        job = self.make_job([('ui', '')])
        job['plan']['roles'][0].update(mission='설정 화면 디자인을 바꾼다', kind='docs')
        bt.save_job(job)
        return job

    def chat_texts(self, jid):
        return [m['text'] for m in bt.load_chat(jid)]

    def test_call_order_is_before_then_work_then_after(self):
        job = self.screen_job()
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))
        names = [c['name'] for c in self.calls()]
        seq = [n for n in names if n == 'GRAB' or '팀장' not in n]            # 팀장 검토·정리 호출은 빼고 캡처와 팀원 작업만
        self.assertEqual(len(seq), 3, seq)
        self.assertEqual((seq[0], seq[2]), ('GRAB', 'GRAB'))
        self.assertIn('팀원ui', seq[1])                                       # before → 작업 → after
        self.assertTrue(bt.job_screens(job['id'])[0]['captured'])

    def test_permission_failure_does_not_block_work_and_says_why(self):
        os.environ['FAKE_CAP_RC'] = '1'
        job = self.screen_job()
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))       # 캡처 실패가 업무를 막지 않는다
        it = bt.job_screens(job['id'])[0]
        self.assertFalse(it['captured'])
        self.assertTrue(it['reason'].startswith(bt.CAPTURE_WHY_PERMISSION), it['reason'])
        self.assertIn(f"{bt.SCREEN_NOT_CAPTURED} — {it['reason']}", self.chat_texts(job['id']))
        self.assertFalse(list(Path(bt.job_path(job['id'], 'screens')).glob('*.tmp')))

    def test_failure_keeps_existing_files(self):
        job = bt.load_job(self.screen_job()['id'])
        role = job['plan']['roles'][0]
        self.assertTrue(bt.auto_capture(job, role, self.proj, 'before')['ok'])
        self.assertTrue(bt.auto_capture(job, role, self.proj, 'after')['ok'])
        before = Path(bt.job_path(job['id'], 'screens/ui.before.png'))
        after = Path(bt.job_path(job['id'], 'screens/ui.after.png'))
        old_b, old_a = before.read_bytes(), after.read_bytes()
        os.environ['FAKE_CAP_RC'] = '1'
        res = bt.auto_capture(job, role, self.proj, 'after')                  # 다시 하기 뒤 after 가 실패
        self.assertFalse(res['ok'])
        self.assertEqual((before.read_bytes(), after.read_bytes()), (old_b, old_a))
        self.assertFalse(after.with_name(after.name + '.tmp').exists())
        line = next(t for t in self.chat_texts(job['id']) if t.startswith(bt.SCREEN_NOT_CAPTURED))   # 파일이 남아도 실패는 채팅으로 알린다
        self.assertIn(bt.CAPTURE_WHY_PERMISSION, line)
        self.assertIn(bt.SCREEN_KEPT_OLD, line)
        log = bt._capture_log(job['id'])
        self.assertFalse(log['ui']['after']['ok'])
        os.environ['FAKE_CAP_RC'] = '0'
        self.assertTrue(bt.auto_capture(job, role, self.proj, 'after')['ok'])  # 다음 성공이면 기록도 성공으로 돌아온다
        self.assertTrue(bt._capture_log(job['id'])['ui']['after']['ok'])


class WindowsPillowPath(unittest.TestCase, _Env):
    def setUp(self):
        self.tmp = __import__('tempfile').TemporaryDirectory()
        self.setup_env(BUNI_TEAM_HOME=self.tmp.name, BUNI_CAPTURE_TEST='1')
        self.out = Path(self.tmp.name) / 'o.png'
        self.patches = [mock.patch.object(bt.sys, 'platform', 'win32'), mock.patch.object(bt, 'IS_WIN', True)]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.restore_env()
        self.tmp.cleanup()

    def test_missing_pillow_reason(self):
        with mock.patch.dict(sys.modules, {'PIL': None, 'PIL.ImageGrab': None}):
            self.assertEqual(bt.grab_screen(str(self.out)), bt.CAPTURE_WHY_NO_PILLOW)
        self.assertFalse(self.out.exists())

    def test_pillow_present_saves_and_errors_are_reasons(self):
        png = Path(self.tmp.name) / 'p.png'
        write_png(png, 8, 8)

        class Img:
            def save(self_, path, fmt):                                     # noqa: N805
                Path(path).write_bytes(png.read_bytes())
        grab = mock.Mock(return_value=Img())
        fake_pil = mock.Mock(ImageGrab=mock.Mock(grab=grab))
        with mock.patch.dict(sys.modules, {'PIL': fake_pil, 'PIL.ImageGrab': fake_pil.ImageGrab}):
            self.assertEqual(bt.grab_screen(str(self.out)), '')
            self.assertEqual(bt.grab_screen(str(self.out), region='1,2,30,40'), '')
            self.assertEqual(grab.call_args.kwargs['bbox'], (1, 2, 31, 42))
            grab.side_effect = OSError('no display')
            self.assertEqual(bt.grab_screen(str(self.out)), '화면을 찍지 못했어요: OSError')

    def test_not_a_capture_line_has_same_shape_as_mac(self):
        """Windows(Pillow 없음)도 채팅에 `캡처 아님 — 이유` — 맥 권한 실패와 같은 형식·같은 상수 접두어."""
        job = bt.new_job('프로젝트', '목표', self.tmp.name)
        job['plan'] = {'summary': '', 'roles': [{'id': 'ui', 'name': '화면', 'kind': 'docs', 'mission': '화면 디자인', 'deliverable': 'x'}]}
        job['roles'] = {'ui': {'status': 'pending'}}
        bt.save_job(job)
        role = job['plan']['roles'][0]
        bt.save_settings({'auto_capture': True})
        with mock.patch.dict(sys.modules, {'PIL': None, 'PIL.ImageGrab': None}):
            bt.auto_capture(job, role, self.tmp.name, 'before')
            bt.auto_capture(job, role, self.tmp.name, 'after')
        it = bt.job_screens(job['id'])[0]
        self.assertFalse(it['captured'])
        self.assertEqual(it['reason'], bt.CAPTURE_WHY_NO_PILLOW)
        self.assertIn(f"{bt.SCREEN_NOT_CAPTURED} — {bt.CAPTURE_WHY_NO_PILLOW}", [m['text'] for m in bt.load_chat(job['id'])])


class SameWordingEverywhere(unittest.TestCase):
    swift = ''.join((ROOT / 'Sources/ClaudeCompanion' / f).read_text(encoding='utf-8') for f in ('TeamViews.swift', 'SquadBoardViews.swift'))
    ui = (ROOT / 'windows/buni_team_ui.py').read_text(encoding='utf-8')
    doc = (ROOT / 'docs/team-structure.md').read_text(encoding='utf-8')

    def test_help_text_matches_in_settings_and_docs(self):
        self.assertIn(bt.CAPTURE_HELP_KO, self.swift)                        # 맥 설정 화면
        self.assertIn(bt.CAPTURE_HELP_EN, self.swift)
        self.assertIn('buni_team.CAPTURE_HELP_KO', self.ui)                  # Windows 설정 화면은 엔진 상수를 그대로 쓴다
        self.assertIn('buni_team.CAPTURE_HELP_EN', self.ui)
        self.assertIn(bt.CAPTURE_HELP_KO, self.doc)                          # 문서
        for needle in ('화면 기록', 'Pillow'):
            self.assertIn(needle, bt.CAPTURE_HELP_KO)

    def test_reasons_come_only_from_engine(self):
        for why in (bt.CAPTURE_WHY_PERMISSION, bt.CAPTURE_WHY_NO_PILLOW):
            self.assertIn(why, self.doc)
            self.assertNotIn(why, self.swift)                                # 맥 화면은 엔진이 준 reason 을 그대로 그린다
            self.assertNotIn(why, self.ui)                                   # Windows 화면도 마찬가지


if __name__ == '__main__':
    unittest.main()
