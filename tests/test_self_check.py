"""
스쿼드의 스스로 점검 시험 — python3 tests/test_self_check.py
"끝났다"고 한 것과 내 컴퓨터의 실제 모습이 어긋났을 때 사람이 말하지 않아도 알아채고 고치게 하는지:
 - 반영 뒤 확인(tools/verify) 실패 → 팀장에게 고치게 한다 (횟수 제한), 통과하면 설치를 예약한다
 - live-state 의 '!' 이상 신호 → 알려진 종류는 엔진이 고치고, 나머지는 팀장에게 한 번씩만 시킨다
 - 없는 작업의 스쿼드 이벤트 파일 정리, 팀원 프롬프트에 실제 상태 붙이기
임시 폴더만 쓴다 (진짜 claude·/tmp·내 폴더는 건드리지 않는다).
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
os.environ['BUNI_TEAM_NO_VERIFY'] = '1'                       # 시험이 떼어 낸 프로세스를 띄우지 않게 한다
import buni_team as bt  # noqa: E402


def sh(cwd, *args):
    return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


class SelfCheck(unittest.TestCase):
    def setUp(self):
        self._home = os.environ['BUNI_TEAM_HOME']
        os.environ['BUNI_TEAM_HOME'] = tempfile.mkdtemp(dir=TMP.name)
        self.addCleanup(lambda: os.environ.__setitem__('BUNI_TEAM_HOME', self._home))
        bt._live_cache.clear()
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        sh(self.proj, 'init', '-q', '-b', 'main')
        Path(self.proj, 'a.py').write_text('x = 1\n')
        sh(self.proj, 'add', '.')
        sh(self.proj, 'commit', '-q', '-m', 'init')
        self.job = bt.new_job('작업', '목표', self.proj)
        self.job.update(status='done')
        bt.save_job(self.job)
        self.sent = []
        self._send = bt.chat_send
        bt.chat_send = lambda jid, to, text, *a, **k: self.sent.append(text) or {}
        self.addCleanup(lambda: setattr(bt, 'chat_send', self._send))

    def script(self, name, body):
        d = Path(self.proj, 'tools')
        d.mkdir(exist_ok=True)
        p = d / f'{name}.sh'
        p.write_text('#!/bin/bash\n' + body)
        p.chmod(0o755)

    def chat(self):
        return Path(bt.job_path(self.job['id'], 'chat.jsonl')).read_text(encoding='utf-8') if Path(bt.job_path(self.job['id'], 'chat.jsonl')).exists() else ''

    def test_verify_failure_asks_lead_to_fix_with_a_limit(self):
        self.script('verify', 'echo "빌드 오류: 없는 이름 Foo"; exit 1\n')
        for _ in range(4):
            bt.verify_applied(self.job['id'])
        self.assertEqual(len(self.sent), bt.VERIFY_FIX_MAX)                        # 무한히 되풀이하지 않는다
        self.assertIn('빌드 오류: 없는 이름 Foo', self.sent[0])
        self.assertIn('내 폴더에서 확인에 실패했어요', self.chat())
        self.assertIn('직접 확인해 주세요', self.chat())

    def test_verify_pass_resets_and_schedules_deploy(self):
        self.script('verify', 'exit 0\n')
        self.script('deploy', 'exit 0\n')
        bt.verify_applied(self.job['id'])
        j = bt.load_job(self.job['id'])
        self.assertTrue(j['verify']['ok'])
        self.assertTrue(j.get('deploy_pending'))                                   # 팀이 쉬면 설치한다
        bt.save_settings({'deploy_mode': 'off'})
        self.addCleanup(lambda: bt.save_settings({'deploy_mode': 'auto'}))
        j.pop('deploy_pending')
        bt.save_job(j)
        bt.verify_applied(self.job['id'])
        self.assertFalse(bt.load_job(self.job['id']).get('deploy_pending'))

    def test_no_scripts_means_nothing_to_verify_for_text_files(self):
        Path(self.proj, 'n.md').write_text('hi')
        self.assertEqual(bt.verify_plan(self.proj, ['n.md']), [])
        self.assertTrue(bt.verify_plan(self.proj, ['a.py']))                         # 파이썬은 문법 검사

    def test_python_syntax_error_is_caught_without_any_project_script(self):
        Path(self.proj, 'a.py').write_text('def (:\n')
        res = bt.run_verify(self.proj, ['a.py'])
        self.assertFalse(res['ok'])
        self.assertIn('문법', res['label'])

    def test_anomaly_kinds(self):
        live = '부니 앱: 실행 중\n!panels 스쿼드 패널이 3개예요\n!stray-events 이벤트 파일 2개\n!stale-build 설치본이 오래됐어요'
        self.assertEqual([a['kind'] for a in bt._anomalies(live)], ['panels', 'stray-events', 'stale-build'])
        self.script('deploy', 'exit 0\n')
        bt.handle_anomalies(self.job['id'], live)
        j = bt.load_job(self.job['id'])
        self.assertTrue(j.get('deploy_pending'))                                   # 설치본이 오래됐으면 엔진이 설치한다
        self.assertEqual(len(self.sent), 1)                                        # 모르는 이상(panels)만 팀장에게
        self.assertIn('스쿼드 패널이 3개', self.sent[0])
        for _ in range(4):                                                         # 같은 이상으로 계속 시키지 않는다
            bt.handle_anomalies(self.job['id'], live)
        self.assertEqual(len(self.sent), bt.HEALTH_FIX_MAX)
        bt.handle_anomalies(self.job['id'], '부니 앱: 정상')                       # 사라지면 잊는다 → 다시 생기면 새로 알린다
        bt.handle_anomalies(self.job['id'], '!panels 스쿼드 패널이 3개예요')
        self.assertEqual(len(self.sent), bt.HEALTH_FIX_MAX + 1)

    def test_health_check_finds_broken_folder_and_live_anomaly(self):
        self.script('verify', 'grep -q BROKEN a.py && { echo "a.py 가 깨졌어요"; exit 1; }; exit 0\n')
        self.script('live-state', 'echo "상태 정상"; echo "!panels 패널이 너무 많아요"\n')
        sh(self.proj, 'add', '.')
        sh(self.proj, 'commit', '-q', '-m', 'scripts')
        r = bt.health_check(self.job['id'])                                        # 처음 보는 폴더에서 통과한 것은 조용히
        self.assertTrue(r['verified'])
        self.assertEqual(len(r['anomalies']), 1)
        self.assertEqual(bt.health_check(self.job['id'])['verified'], None)        # 바뀐 게 없으면 다시 안 돌린다
        Path(self.proj, 'a.py').write_text('BROKEN = 1\n')                          # 내 폴더가 팀 모르게 깨졌다
        r = bt.health_check(self.job['id'])
        self.assertFalse(r['verified'])
        self.assertTrue(any('a.py 가 깨졌어요' in t for t in self.sent))
        self.assertIn('내 폴더에서 확인에 실패했어요', self.chat())

    def test_fingerprint_ignores_files_tests_rewrite(self):
        a, _ = bt.tree_fingerprint(self.proj)
        Path(self.proj, 'tests').mkdir()
        Path(self.proj, 'tests/license_vectors.json').write_text('{}')
        Path(self.proj, '.DS_Store').write_text('x')
        self.assertEqual(bt.tree_fingerprint(self.proj)[0], a)
        Path(self.proj, 'a.py').write_text('x = 2\n')
        self.assertNotEqual(bt.tree_fingerprint(self.proj)[0], a)

    def test_live_block_is_added_to_prompts_only_when_project_reads_it(self):
        self.assertEqual(bt.live_block(bt.load_job(self.job['id'])), '')
        self.script('live-state', 'echo "떠 있는 창 6개"\n')
        blk = bt.live_block(bt.load_job(self.job['id']))
        self.assertIn('떠 있는 창 6개', blk)
        self.assertIn('확인 못 함', blk)

    def test_purge_removes_only_events_of_missing_jobs(self):
        keep = bt.squad_events_path(self.job['id'])
        Path(keep).write_text('{}')
        base = Path(keep).parent
        stray = base / 'claude-companion-events-squad-20260101-000000-dead.jsonl'
        other = base / 'claude-companion-events-0234c62e-f202-4890-930e-7dd6f84ceac3.jsonl'
        stray.write_text('{}')
        other.write_text('{}')
        gone = bt.purge_stray_squad_events()
        self.assertEqual(gone, [stray.name])
        self.assertTrue(Path(keep).exists() and other.exists())

    def test_after_note_follows_project_scripts(self):
        os.environ.pop('BUNI_TEAM_NO_VERIFY')
        self.addCleanup(lambda: os.environ.__setitem__('BUNI_TEAM_NO_VERIFY', '1'))
        self.assertIn('다시 빌드해야', bt._after_note(self.job['id']))
        self.script('verify', 'exit 0\n')
        self.assertIn('다시 확인하고', bt._after_note(self.job['id']))

    def test_project_ships_the_three_scripts(self):
        for n in ('live-state', 'verify', 'deploy'):
            self.assertTrue((HERE.parent / 'tools' / f'{n}.sh').is_file(), n)
        out = subprocess.run(['bash', str(HERE.parent / 'tools/live-state.sh')], capture_output=True, text=True, timeout=30).stdout
        self.assertIn('부니 앱:', out)


if __name__ == '__main__':
    unittest.main()
