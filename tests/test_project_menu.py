"""사이드바 우클릭 — 프로젝트 이름 수정·삭제·프로젝트 모델 설정(우선순위: 팀원별 → 프로젝트 → 전역).
임시 BUNI_TEAM_HOME 만 쓴다. 진짜 claude 는 부르지 않는다."""
import json
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


class ProjectMenu(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        bt.save_settings({'model': '', 'lead_model': ''})

    def job(self, **kw):
        j = bt.new_job('원래 이름', '목표', self.proj)
        j.update(kw)
        bt.save_job(j)
        return j

    def test_rename(self):
        j = self.job()
        n = len(bt.list_jobs())
        self.assertEqual(bt.rename_job(j['id'], '  새   이름 ')['title'], '새 이름')
        self.assertEqual(bt.load_job(j['id'])['title'], '새 이름')
        self.assertEqual(len(bt.list_jobs()), n)

    def test_rename_rejects_empty(self):
        j = self.job()
        for bad in ('', '   ', None):
            with self.assertRaises(ValueError):
                bt.rename_job(j['id'], bad)
        self.assertEqual(bt.load_job(j['id'])['title'], '원래 이름')

    def test_delete_finished_project(self):
        j = self.job(status='done')
        bt.delete_project(j['id'])
        self.assertIsNone(bt.load_job(j['id']))

    def test_delete_refuses_running(self):
        for kw in ({'status': 'running'}, {'busy': True}):
            j = self.job(**kw)
            with self.assertRaises(ValueError):
                bt.delete_project(j['id'])
            self.assertIsNotNone(bt.load_job(j['id']))

    def test_delete_after_cancel(self):
        j = self.job(status='running')
        bt.cancel_job(j['id'])
        bt.delete_project(j['id'])
        self.assertIsNone(bt.load_job(j['id']))

    def test_model_priority(self):
        s = {'model': 'claude-haiku-5-5', 'lead_model': 'claude-opus-5-5'}
        job = {'model': 'claude-sonnet-5-5', 'lead_model': 'claude-fable-5-1'}
        r = bt.resolve_model
        self.assertEqual(r('claude-opus-5-5', job, False, s), 'claude-opus-5-5')       # 팀원별
        self.assertEqual(r('', job, False, s), 'claude-sonnet-5-5')                    # 프로젝트 팀원 기본
        self.assertEqual(r('', job, True, s), 'claude-fable-5-1')                      # 프로젝트 팀장
        self.assertEqual(r('', {}, False, s), 'claude-haiku-5-5')                      # 전역 팀원 기본
        self.assertEqual(r('', {}, True, s), 'claude-opus-5-5')                        # 전역 팀장
        self.assertEqual(r('', {'model': 'claude-sonnet-5-5'}, True, {'model': '', 'lead_model': ''}), 'claude-sonnet-5-5')  # 팀장 비면 프로젝트 팀원 기본
        self.assertEqual(r('', None, True, {}), '')

    def test_set_project_settings(self):
        j = self.job()
        out = bt.set_project_settings(j['id'], 'claude-sonnet-5-5', 'bad model!')
        self.assertEqual((out['model'], out['lead_model']), ('claude-sonnet-5-5', ''))
        bt.set_project_settings(j['id'], lead_model='claude-opus-5-5')                  # model 은 건드리지 않는다
        self.assertEqual(bt.load_job(j['id'])['model'], 'claude-sonnet-5-5')
        self.assertEqual(bt.load_job(j['id'])['lead_model'], 'claude-opus-5-5')
        bt.set_project_settings(j['id'], '', '')                                        # 비우면 전역을 따른다
        self.assertEqual(bt.load_job(j['id'])['model'], '')

    def test_cli(self):
        j = self.job(status='done')
        exe = [sys.executable, str(HERE.parent / 'windows' / 'buni_team.py')]
        env = dict(os.environ)

        def cli(*a):
            p = subprocess.run(exe + list(a), capture_output=True, text=True, env=env, timeout=60)
            return json.loads(p.stdout.strip().splitlines()[-1])
        self.assertTrue(cli('rename', j['id'], '--title', '이름2')['ok'])
        self.assertFalse(cli('rename', j['id'], '--title', ' ')['ok'])
        self.assertEqual(cli('project-settings', j['id'], '--model', 'claude-haiku-5-5')['model'], 'claude-haiku-5-5')
        self.assertTrue(cli('delete', j['id'])['ok'])
        self.assertIsNone(bt.load_job(j['id']))


if __name__ == '__main__':
    unittest.main()
