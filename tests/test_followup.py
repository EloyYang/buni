"""
'다음에 할 일' 자동 진행 · 같은 프로젝트 안에서 이어서 진행 시험 — python3 tests/test_followup.py
팀장 답(_ask_json)과 Claude 실행(ClaudeRunner)을 가짜로 바꾸고 BUNI_TEAM_HOME 을 임시 폴더로 돌려 쓴다 (실제 claude 는 부르지 않는다).
"""
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


def step(title, direction_change, **kw):
    return {'title': title, 'why': '시험', 'goal': f'{title} 을 한다', 'done_criteria': ['끝남'], 'direction_change': direction_change, **kw}


class FakeRunner:
    """가짜 claude — 이름으로 어느 단계인지 보고 알맞은 답을 돌려준다."""
    def __init__(self, wrap_steps):
        self.wrap_steps = wrap_steps               # 정리 호출마다 하나씩 꺼내 쓴다 (다 쓰면 빈 목록)
        self.worker_names = []

    def cancel(self):
        pass

    def run(self, prompt, cwd, **kw):
        name = kw.get('name', '')
        out = '작업을 마쳤어요.'
        if '팀장(구성)' in name:
            out = json.dumps({'summary': '한 명', 'roles': [{'id': 'dev', 'name': '개발자', 'icon': '🧑‍💻', 'kind': 'docs',
                                                              'mission': '일', 'deliverable': 'NOTES.md', 'depends_on': []}]})
        elif '팀장(검토)' in name:
            out = json.dumps({'verdicts': [], 'summary': ''})
        elif '팀장(정리)' in name:
            out = json.dumps({'review_items': [], 'next_steps': self.wrap_steps.pop(0) if self.wrap_steps else []})
        elif '팀장(통합)' not in name:
            self.worker_names.append(name)
        return {'result': out, 'cost': 0.0, 'session_id': 'fake', 'denials': []}


class FollowupBase(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        bt.save_settings({'auto_followup': True})
        self._ask = bt._ask_json

    def tearDown(self):
        bt._ask_json = self._ask

    @staticmethod
    def read(job, name):
        with open(bt.job_path(job['id'], name), encoding='utf-8') as f:
            return f.read()

    def finished_job(self, depth=0):
        job = bt.new_job('앞 작업', '목표', self.proj)
        job['status'], job['auto_depth'] = 'done', depth
        job['plan'] = {'summary': '', 'roles': [{'id': 'dev', 'name': '개발자', 'icon': '🧑‍💻', 'kind': 'docs', 'mission': '일',
                                                  'deliverable': 'NOTES.md', 'depends_on': []}]}
        job['roles'] = {'dev': {'status': 'accepted', 'attempts': 1, 'feedback': '', 'summary': '', 'session_id': None}}
        bt.save_job(job)
        return job

    def wrap(self, job, steps):
        bt._ask_json = lambda *a, **k: {'review_items': [], 'next_steps': steps}
        return bt.wrap_up(job['id'])


class AutoFollowup(FollowupBase):
    def test_direction_unchanged_continues_in_same_job_and_changed_waits(self):
        job = self.finished_job()
        before = len(bt.list_jobs())
        clean = self.wrap(job, [step('테스트 보완', False), step('가격 인상', False), step('런칭 글 게시', True), step('방향 미표시', None)])
        self.assertEqual(len(bt.list_jobs()), before)             # 새 프로젝트가 생기지 않는다
        by = {s['title']: s for s in bt.load_wrapup(job['id'])['next_steps']}
        self.assertEqual(by['테스트 보완']['auto'], 'started')
        self.assertNotIn('job_id', by['테스트 보완'])
        cur = bt.load_job(job['id'])
        rid = by['테스트 보완']['role_id']
        self.assertEqual((cur['status'], cur['auto_depth'], cur['roles'][rid]['status']), ('queued', 1, 'pending'))
        self.assertIn(rid, [r['id'] for r in cur['plan']['roles']])
        for t in ('가격 인상', '런칭 글 게시', '방향 미표시'):          # 위험한 말이 있거나 애매하면 대기
            self.assertEqual(by[t]['auto'], 'confirm', t)
            self.assertNotIn('role_id', by[t])
        self.assertTrue(clean['next_steps'][0]['direction_change'] is False)
        view = self.read(job, 'report_view.md')
        self.assertIn('진행 중', view)
        self.assertIn('확인 필요 (방향 변경)', view)
        self.assertIn('이 프로젝트에서 이어서 진행', view)
        chat = self.read(job, 'chat.jsonl')
        self.assertIn('이 프로젝트에서 자동으로 이어서 진행해요', chat)
        cur['roles'][rid]['status'] = 'accepted'                  # 끝나면 '자동 진행됨' 으로 바뀐다
        bt.save_job(cur)
        self.assertEqual(bt.next_step_status(bt.load_wrapup(job['id'])['next_steps'][0], cur)[1], '✅ 자동 진행됨')

    def test_depth_limit_stops(self):
        job = self.finished_job(depth=bt.AUTO_FOLLOWUP_MAX)
        self.wrap(job, [step('테스트 보완', False)])
        st = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertEqual(st['auto'], 'limit')
        self.assertNotIn('role_id', st)
        self.assertIn('상한', bt.next_step_status(st)[1])
        self.assertIn('멈췄어요', self.read(job, 'chat.jsonl'))

    def test_chain_reaches_limit_after_three(self):
        job = self.finished_job()
        for n in range(1, bt.AUTO_FOLLOWUP_MAX + 1):
            self.wrap(job, [step(f'단계 {n}', False)])
            st = bt.load_wrapup(job['id'])['next_steps'][0]
            self.assertEqual(st['auto'], 'started')
            job = bt.load_job(job['id'])
            self.assertEqual(job['auto_depth'], n)
            job['status'] = 'done'
            bt.save_job(job)
        self.wrap(job, [step('단계 4', False)])
        self.assertEqual(bt.load_wrapup(job['id'])['next_steps'][0]['auto'], 'limit')
        self.assertEqual(len(bt.load_job(job['id'])['plan']['roles']), 1 + bt.AUTO_FOLLOWUP_MAX)

    def test_manual_start_resets_depth(self):
        job = self.finished_job(depth=bt.AUTO_FOLLOWUP_MAX)
        self.wrap(job, [step('테스트 보완', False)])
        new = bt.start_followup(job['id'], 'n1')
        self.assertEqual((new['id'], new['auto_depth']), (job['id'], 0))

    def test_setting_off_keeps_everything_waiting(self):
        bt.save_settings({'auto_followup': False})
        job = self.finished_job()
        self.wrap(job, [step('테스트 보완', False)])
        st = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertEqual(st['auto'], 'off')
        self.assertNotIn('role_id', st)

    def test_per_wrapup_cap(self):
        job = self.finished_job()
        self.wrap(job, [step(f'보완 {i}', False) for i in range(4)])
        steps = bt.load_wrapup(job['id'])['next_steps']
        autos = [s['auto'] for s in steps]
        self.assertEqual(autos.count('started'), bt.AUTO_FOLLOWUP_PER_WRAPUP)
        self.assertEqual(autos.count('cap'), 2)
        self.assertEqual(bt.load_job(job['id'])['auto_depth'], 1)  # 같은 정리에서 둘을 시작해도 한 단계로 센다

    def test_rewrap_does_not_duplicate(self):
        job = self.finished_job()
        self.wrap(job, [step('테스트 보완', False)])
        first = bt.load_wrapup(job['id'])['next_steps'][0]['role_id']
        self.wrap(job, [step('테스트 보완', False)])
        st = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertEqual((st['role_id'], st['auto']), (first, 'started'))
        self.assertEqual(len(bt.load_job(job['id'])['plan']['roles']), 2)

    def test_legacy_job_id_step_is_kept(self):
        job = self.finished_job()
        old = bt.new_job('옛 후속', '목표', self.proj)
        old['parent_id'] = job['id']
        bt.save_job(old)
        wu = {'review_items': [], 'next_steps': [dict(step('옛 후속', False), id='n1', job_id=old['id'], auto='started')]}
        bt._atomic_write(bt.wrapup_path(job['id']), json.dumps(wu))
        self.assertEqual(bt.start_followup(job['id'], 'n1')['id'], old['id'])    # 옛 방식으로 만든 작업은 그대로 돌려준다
        self.assertIn(f"buni://view/{old['id']}", bt.report_view(job['id']))

    def test_settings_default_on(self):
        self.assertTrue(bt.DEFAULT_SETTINGS['auto_followup'])


class SameJobRun(FollowupBase):
    """가짜 claude 로 JobRunner 를 끝까지 돌린다 — 다음 할 일을 실행해도 작업 수가 늘지 않고 같은 작업에서 진행된다."""

    def run_job(self, job_id, fake):
        runner = bt.JobRunner(job_id, bt.load_settings())
        runner.runner = fake
        runner.run()

    def test_next_step_runs_inside_same_job(self):
        subprocess.run(['git', 'init', '-q'], cwd=self.proj, check=True)
        subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@localhost', 'commit', '-q', '--allow-empty', '-m', 'init'],
                       cwd=self.proj, check=True)
        job = bt.new_job('프로젝트', '목표', self.proj)
        job['requirements'] = '# 사전요구서\n'
        bt.save_job(job)
        before = len(bt.list_jobs())
        both = [step('테스트 보완', False), step('릴리스 하기', True)]
        fake = FakeRunner([both, both])                                # 팀장이 두 번째 정리에서도 같은 제안을 다시 낸다
        self.run_job(job['id'], fake)
        after = bt.load_job(job['id'])
        self.assertEqual(len(bt.list_jobs()), before)                  # 작업(프로젝트)이 늘지 않았다
        self.assertEqual(after['status'], 'review', after.get('error'))
        self.assertEqual(sorted(after['roles']), ['dev', 'next_n1'])    # 같은 작업에 팀원으로 이어 붙어 끝까지 진행됐다
        self.assertTrue(all(r['status'] == 'accepted' for r in after['roles'].values()))
        self.assertEqual(len(fake.worker_names), 2)
        wu = bt.load_wrapup(job['id'])
        by = {s['title']: s for s in wu['next_steps']}
        self.assertEqual(by['테스트 보완']['auto'], 'started')
        self.assertEqual(by['릴리스 하기']['auto'], 'confirm')           # 방향 변경은 대기
        self.assertIn('자동 진행됨', bt.report_view(job['id']))
        chat = self.read(job, 'chat.jsonl')
        self.assertIn('이 프로젝트에서 자동으로 이어서 진행해요', chat)
        # 사용자가 대기 중인 항목을 누르면 — 역시 같은 작업, 끝난 작업을 다시 연다
        again = bt.start_followup(job['id'], by['릴리스 하기']['id'])
        self.assertEqual((again['id'], again['status'], again['auto_depth']), (job['id'], 'queued', 0))
        self.run_job(job['id'], FakeRunner([both]))
        final = bt.load_job(job['id'])
        self.assertEqual(len(bt.list_jobs()), before)
        self.assertEqual((final['status'], len(final['plan']['roles'])), ('review', 3))


if __name__ == '__main__':
    unittest.main()
