"""
가짜 claude 스크립트로 엔진 전체 흐름 시험 — python3 tests/test_fake_claude_flow.py
BUNI_CLAUDE(가짜 스크립트)와 BUNI_TEAM_HOME(임시 폴더)로 진짜 ClaudeRunner·JobRunner 를 돌린다 (실제 claude·네트워크는 쓰지 않는다).
  1) --model 우선순위: 팀원별 role.model → 프로젝트 job.model(팀장은 job.lead_model 먼저) → 전역 설정
  2) wrap_up 뒤 auto_followups 가 같은 프로젝트 안에서 AUTO_FOLLOWUP_PER_WRAPUP·AUTO_FOLLOWUP_MAX 상한까지만 잇고 방향 변경은 대기
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

import buni_team as bt  # noqa: E402

# 가짜 claude — 받은 인자를 FAKE_LOG 에 한 줄씩 적고, --name 으로 어느 단계인지 보고 알맞은 stream-json 결과를 낸다.
# 정리(팀장(정리)) 답은 FAKE_WRAP 파일의 맨 앞 목록을 꺼내 쓴다 (다 쓰면 빈 목록).
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
name = a[a.index('--name') + 1] if '--name' in a else ''
model = a[a.index('--model') + 1] if '--model' in a else None
sys.stdin.read()
with open(os.environ['FAKE_LOG'], 'a', encoding='utf-8') as f:
    f.write(json.dumps({'name': name, 'model': model, 'argv': a}, ensure_ascii=False) + '\n')
out = '작업을 마쳤어요.'
if '팀장(검토)' in name:
    out = json.dumps({'verdicts': [], 'summary': ''})
elif '팀장(정리)' in name:
    p = os.environ['FAKE_WRAP']
    q = json.load(open(p, encoding='utf-8'))
    steps = q.pop(0) if q else []
    json.dump(q, open(p, 'w', encoding='utf-8'))
    out = json.dumps({'review_items': [], 'next_steps': steps})
print(json.dumps({'type': 'system', 'subtype': 'init'}))
print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': out,
                  'total_cost_usd': 0.0, 'session_id': 'fake'}))
'''


def step(title, direction_change):
    return {'title': title, 'why': '시험', 'goal': f'{title} 을 한다', 'done_criteria': ['끝남'], 'direction_change': direction_change}


class FakeClaudeBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = {k: os.environ.get(k) for k in ('BUNI_TEAM_HOME', 'BUNI_CLAUDE', 'FAKE_LOG', 'FAKE_WRAP')}
        root = Path(self.tmp.name)
        self.log, self.wrap_q = root / 'calls.jsonl', root / 'wrap.json'
        exe = root / 'claude'
        exe.write_text(FAKE, encoding='utf-8')
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
        os.environ.update(BUNI_TEAM_HOME=str(root / 'home'), BUNI_CLAUDE=str(exe),
                          FAKE_LOG=str(self.log), FAKE_WRAP=str(self.wrap_q))
        self.wrap_q.write_text('[]', encoding='utf-8')
        self.proj = str(root / 'proj')
        os.makedirs(self.proj)
        subprocess.run(['git', 'init', '-q'], cwd=self.proj, check=True)
        subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@localhost', 'commit', '-q', '--allow-empty', '-m', 'init'],
                       cwd=self.proj, check=True)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(l) for l in self.log.read_text(encoding='utf-8').splitlines() if l.strip()]

    def make_job(self, roles, **job_kw):
        """팀이 이미 꾸려진 프로젝트 (팀 구성 단계는 건너뛴다). roles = [(id, role.model)]"""
        job = bt.new_job('프로젝트', '목표', self.proj)
        job['requirements'] = '# 사전요구서\n'
        job['plan'] = {'summary': '', 'roles': [
            dict({'id': rid, 'name': f'팀원{rid}', 'icon': '🧑‍💻', 'kind': 'docs', 'mission': '일', 'deliverable': 'NOTES.md',
                  'depends_on': []}, **({'model': m} if m else {})) for rid, m in roles]}
        job['roles'] = {rid: {'status': 'pending', 'attempts': 0, 'feedback': '', 'summary': '', 'session_id': None} for rid, _ in roles}
        job.update(job_kw)
        bt.save_job(job)
        return job

    def run_job(self, job_id):
        bt.JobRunner(job_id, bt.load_settings()).run()
        return bt.load_job(job_id)

    def worker_models(self):
        return {c['name'].split('·')[-1].strip(): c['model'] for c in self.calls() if '팀장' not in c['name']}

    def lead_models(self):
        return {c['name'].split('·')[-1].strip(): c['model'] for c in self.calls() if '팀장' in c['name']}


class ModelArgPriority(FakeClaudeBase):
    def test_three_levels_reach_fake_claude(self):
        bt.save_settings({'model': 'claude-sonnet-5-5', 'lead_model': 'claude-opus-5-5', 'auto_followup': False})
        job = self.make_job([('a', 'claude-haiku-5-5'), ('b', ''), ('c', '')])
        bt.set_project_settings(job['id'], model='claude-fable-5-1')          # 프로젝트 팀원 기본
        bt.set_role_model(job['id'], 'c', '')                                  # 비우면 프로젝트 → 전역 순서를 따른다
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))
        w = self.worker_models()
        self.assertEqual(w['팀원a'], 'claude-haiku-5-5')                        # 1단계: 팀원별 role.model
        self.assertEqual(w['팀원b'], 'claude-fable-5-1')                        # 2단계: 프로젝트 job.model
        self.assertEqual(w['팀원c'], 'claude-fable-5-1')
        # 팀장(검토·정리)은 프로젝트 lead_model 이 없으니 → 프로젝트 model 이 전역 lead_model 보다 먼저다
        self.assertTrue(all(m == 'claude-fable-5-1' for m in self.lead_models().values()), self.lead_models())

    def test_global_settings_when_project_empty(self):
        bt.save_settings({'model': 'claude-sonnet-5-5', 'lead_model': 'claude-opus-5-5', 'auto_followup': False})
        job = self.make_job([('a', 'claude-haiku-5-5'), ('b', '')])
        self.run_job(job['id'])
        w = self.worker_models()
        self.assertEqual(w['팀원a'], 'claude-haiku-5-5')
        self.assertEqual(w['팀원b'], 'claude-sonnet-5-5')                       # 3단계: 전역 model
        self.assertTrue(self.lead_models() and all(m == 'claude-opus-5-5' for m in self.lead_models().values()))   # 팀장은 전역 lead_model

    def test_project_lead_model_beats_everything_for_lead(self):
        bt.save_settings({'model': 'claude-sonnet-5-5', 'lead_model': 'claude-opus-5-5', 'auto_followup': False})
        job = self.make_job([('a', '')], model='claude-fable-5-1', lead_model='claude-haiku-5-5')
        self.run_job(job['id'])
        self.assertEqual(self.worker_models()['팀원a'], 'claude-fable-5-1')
        self.assertTrue(all(m == 'claude-haiku-5-5' for m in self.lead_models().values()), self.lead_models())

    def test_no_model_anywhere_omits_flag(self):
        bt.save_settings({'auto_followup': False})
        job = self.make_job([('a', '')])
        self.run_job(job['id'])
        self.assertTrue(self.calls())
        for c in self.calls():
            self.assertNotIn('--model', c['argv'], c['name'])


class AutoFollowupFlow(FakeClaudeBase):
    def queue(self, *wraps):
        self.wrap_q.write_text(json.dumps(list(wraps), ensure_ascii=False), encoding='utf-8')

    def test_per_wrapup_cap_and_direction_change_wait(self):
        bt.save_settings({'auto_followup': True, 'model': 'claude-sonnet-5-5'})
        job = self.make_job([('dev', '')])
        # 첫 정리: 방향 유지 3개 + 방향 변경 1개. 이어 붙은 업무가 끝난 뒤의 정리는 빈 목록.
        self.queue([step('보완 1', False), step('보완 2', False), step('보완 3', False), step('가격 인상', True)])
        before = len(bt.list_jobs())
        after = self.run_job(job['id'])
        self.assertEqual(len(bt.list_jobs()), before)                           # 새 프로젝트가 생기지 않는다
        self.assertEqual(after['status'], 'review', after.get('error'))
        # 이어 붙은 업무가 끝난 뒤의 두 번째 정리(빈 목록)가 wrapup.json 을 덮으니, 상한·대기는 팀원·가짜 claude 호출·채팅으로 확인한다.
        nxt = sorted(set(after['roles']) - {'dev'})
        self.assertEqual(len(nxt), bt.AUTO_FOLLOWUP_PER_WRAPUP)                  # 한 번의 정리에서 상한까지만 시작
        titles = {r['id']: r['name'] for r in after['plan']['roles']}
        self.assertEqual(sorted(titles[r] for r in nxt), ['보완 1', '보완 2'])    # 방향 유지 앞의 2개만 같은 프로젝트의 팀원으로 이어 붙음
        self.assertEqual(after['auto_depth'], 1)
        chat = Path(bt.job_path(job['id'], 'chat.jsonl')).read_text(encoding='utf-8')
        self.assertIn('사업 방향이 바뀔 수 있는 후속 작업 1개는 자동으로 시작하지 않았어요', chat)
        self.assertTrue(all(r['status'] == 'accepted' for r in after['roles'].values()))
        names = [c['name'] for c in self.calls()]
        self.assertEqual(sum(1 for n in names if '보완 3' in n or '가격 인상' in n), 0)   # 대기·상한 항목은 가짜 claude 가 받지 않았다
        for t in ('보완 1', '보완 2'):
            self.assertTrue(any(t in n for n in names), t)
        w = self.worker_models()
        self.assertTrue(all(m == 'claude-sonnet-5-5' for m in w.values()), w)  # 이어 붙은 팀원도 같은 모델 규칙을 쓴다

    def test_chain_stops_at_auto_followup_max(self):
        bt.save_settings({'auto_followup': True})
        job = self.make_job([('dev', '')])
        # 매 정리마다 방향 유지 후속 1개를 낸다 — 그래도 연속 AUTO_FOLLOWUP_MAX 단계까지만 이어진다.
        self.queue(*[[step(f'단계 {n}', False)] for n in range(1, bt.AUTO_FOLLOWUP_MAX + 3)])
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))
        self.assertEqual(after['auto_depth'], bt.AUTO_FOLLOWUP_MAX)
        self.assertEqual(len(after['plan']['roles']), 1 + bt.AUTO_FOLLOWUP_MAX)  # 원래 팀원 + 자동 단계 3개
        wu = bt.load_wrapup(job['id'])
        last = wu['next_steps'][0]
        self.assertEqual(last['auto'], 'limit')                                  # 상한에 닿아 멈춤
        self.assertNotIn('role_id', last)
        self.assertEqual(len(bt.list_jobs()), 1)
        self.assertIn('멈췄어요', (Path(bt.job_path(job['id'], 'chat.jsonl'))).read_text(encoding='utf-8'))
        for n in range(1, bt.AUTO_FOLLOWUP_MAX + 1):
            self.assertTrue(any(f'단계 {n}' in c['name'] for c in self.calls()), n)
        self.assertFalse(any(f'단계 {bt.AUTO_FOLLOWUP_MAX + 1}' in c['name'] for c in self.calls()))

    def test_setting_off_keeps_waiting(self):
        bt.save_settings({'auto_followup': False})
        job = self.make_job([('dev', '')])
        self.queue([step('보완 1', False)])
        after = self.run_job(job['id'])
        self.assertEqual(sorted(after['roles']), ['dev'])
        self.assertEqual(bt.load_wrapup(job['id'])['next_steps'][0]['auto'], 'off')


if __name__ == '__main__':
    unittest.main()
