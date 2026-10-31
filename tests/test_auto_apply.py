"""
결과 자동 반영(apply_mode 기본 smart — 중요하지 않으면 바로) 시험 — python3 tests/test_auto_apply.py
임시 git 저장소와 BUNI_TEAM_HOME 임시 폴더만 쓴다 (실제 claude·내 폴더는 건드리지 않는다).
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
import buni_team as bt  # noqa: E402


def git(cwd, *args):
    return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


def write(root, name, text):
    p = Path(root, name)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding='utf-8')


class AutoApply(unittest.TestCase):
    def setUp(self):
        self._home = os.environ.get('BUNI_TEAM_HOME')                           # 다른 시험의 작업 목록과 섞이지 않게 시험마다 따로 쓴다
        self.addCleanup(lambda: os.environ.__setitem__('BUNI_TEAM_HOME', self._home) if self._home else os.environ.pop('BUNI_TEAM_HOME', None))
        os.environ['BUNI_TEAM_HOME'] = tempfile.mkdtemp(dir=TMP.name)
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        git(self.proj, 'init', '-q', '-b', 'main')
        write(self.proj, 'a.txt', '\n'.join(f'line{i}' for i in range(30)) + '\n')
        write(self.proj, 'b.txt', 'b\n')
        git(self.proj, 'add', '.')
        git(self.proj, 'commit', '-q', '-m', 'init')
        git(self.proj, 'checkout', '-q', '-b', 'buni/x')                       # 팀의 결과 브랜치: a.txt 위쪽 · b.txt 를 고친다
        write(self.proj, 'a.txt', 'TOP\n' + Path(self.proj, 'a.txt').read_text(encoding='utf-8'))
        write(self.proj, 'b.txt', 'b2\n')
        git(self.proj, 'commit', '-q', '-am', 'team')
        git(self.proj, 'checkout', '-q', 'main')
        self.job = bt.new_job('작업', '목표', self.proj)
        self.job.update(status='done', branch='buni/x')
        bt.save_job(self.job)

    def set_mode(self, mode):
        bt.save_settings({'apply_mode': mode})

    def test_default_is_smart(self):
        self.assertEqual(bt.DEFAULT_SETTINGS['apply_mode'], 'smart')
        self.assertEqual(bt.load_settings()['apply_mode'], 'smart')              # 설정 파일이 없으면 smart (중요하지 않으면 바로 반영)
        self.assertEqual(bt._apply_mode(), 'smart')

    def test_saved_confirm_is_kept(self):
        self.set_mode('confirm')
        self.assertEqual(bt.load_settings()['apply_mode'], 'confirm')
        self.assertEqual(bt._apply_mode(), 'confirm')

    def test_auto_applies_without_approval_and_banner_shows_state(self):
        self.set_mode('auto')
        self.assertIn('자동 반영 대기 중', '\n'.join(bt._unmerged_md(bt.load_job(self.job['id']))))
        self.assertNotIn('승인하고 내 폴더에 반영', '\n'.join(bt._unmerged_md(bt.load_job(self.job['id']))))
        r = bt.auto_apply(self.job['id'])
        self.assertTrue(r['ok'])
        self.assertEqual(Path(self.proj, 'b.txt').read_text(encoding='utf-8'), 'b2\n')
        self.assertTrue(Path(self.proj, 'a.txt').read_text(encoding='utf-8').startswith('TOP\n'))
        self.assertEqual(git(self.proj, 'log', '--oneline').count('\n'), 1)      # 커밋은 안 했다
        md = '\n'.join(bt._unmerged_md(bt.load_job(self.job['id'])))
        self.assertIn('자동 반영됨', md)
        self.assertNotIn('buni://apply', md)
        self.assertEqual(bt.auto_apply(self.job['id']).get('files'), 0)          # 다시 불러도 그대로

    def test_overlap_applies_the_rest_and_explains_only_the_blocked_file(self):
        """같은 자리를 서로 다르게 고쳐서 정리하지 못한 파일만 남기고, 나머지는 모두 반영한다 (하나가 막혀 전부 못 넣는 일은 없다)."""
        self.set_mode('auto')
        bt._resolve_conflicts = lambda job, conflicts: {}                          # 실제 Claude 는 부르지 않는다
        mine = 'MINE\n' + Path(self.proj, 'a.txt').read_text(encoding='utf-8')   # 내 폴더의 커밋 안 한 변경이 같은 자리를 고친다
        write(self.proj, 'a.txt', mine)
        r = bt.auto_apply(self.job['id'])
        self.assertFalse(r['ok'])
        self.assertTrue(r['partial'])
        self.assertEqual(r['left'], ['a.txt'])
        self.assertEqual(Path(self.proj, 'a.txt').read_text(encoding='utf-8'), mine)         # 겹친 파일은 내 변경 그대로
        self.assertEqual(Path(self.proj, 'b.txt').read_text(encoding='utf-8'), 'b2\n')        # 나머지는 들어갔다
        md = '\n'.join(bt._unmerged_md(bt.load_job(self.job['id'])))
        self.assertIn('a.txt', md)
        chat = Path(bt.job_path(self.job['id'], 'chat.jsonl')).read_text(encoding='utf-8')
        self.assertIn('일부만 반영했어요', chat)
        bt.auto_apply(self.job['id'])                                                         # 같은 결과로 Claude 를 또 부르거나 또 알리지 않는다
        lines = Path(bt.job_path(self.job['id'], 'chat.jsonl')).read_text(encoding='utf-8').splitlines()
        self.assertEqual(len([l for l in lines if '일부만 반영했어요' in l]), 1)
        write(self.proj, 'a.txt', Path(self.proj, 'a.txt').read_text(encoding='utf-8').replace('MINE\n', '', 1))   # 겹침을 치우면 다시 반영된다
        self.assertTrue(bt.apply_result(self.job['id'])['ok'])
        self.assertTrue(Path(self.proj, 'a.txt').read_text(encoding='utf-8').startswith('TOP\n'))

    def test_confirm_and_manual_do_not_auto_apply(self):
        for mode in ('confirm', 'manual'):
            self.set_mode(mode)
            self.assertTrue(bt.auto_apply(self.job['id']).get('skipped'))
            self.assertEqual(Path(self.proj, 'b.txt').read_text(encoding='utf-8'), 'b\n')
        self.set_mode('confirm')
        md = '\n'.join(bt._unmerged_md(bt.load_job(self.job['id'])))
        self.assertIn('승인', md)

    def test_finished_job_is_applied_when_opened(self):
        self.set_mode('auto')
        bt.ensure_wrapup(self.job['id'], full=False)
        self.assertEqual(Path(self.proj, 'b.txt').read_text(encoding='utf-8'), 'b2\n')


if __name__ == '__main__':
    unittest.main()
