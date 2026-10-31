"""
보류 중인 '다음에 할 일' 승인·거절·의견 시험 — python3 tests/test_step_decision.py
test_followup.py 의 가짜 팀장/러너와 임시 BUNI_TEAM_HOME 을 그대로 쓴다 (실제 claude 는 부르지 않는다).
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_followup import FollowupBase, FakeRunner, bt, step  # noqa: E402


class StepDecision(FollowupBase):
    def held_job(self):
        job = self.finished_job()
        self.wrap(job, [step('런칭 글 게시', True)])
        st = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertEqual(st['auto'], 'confirm')
        return job, st

    def card(self, job):
        return next(c for c in bt.board_cards([bt.load_job(job['id'])]) if c['kind'] == 'next')

    def test_approve_continues_in_same_job_and_keeps_history(self):
        job, st = self.held_job()
        before = len(bt.list_jobs())
        self.assertTrue(bt.board_detail(self.card(job))['can_decide'])
        bt.step_decision(job['id'], st['id'], 'approve', '진행해 주세요')
        self.assertEqual(len(bt.list_jobs()), before)                    # 새 프로젝트 없음
        cur = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertTrue(cur['role_id'])
        self.assertEqual(cur['history'][-1]['decision'], 'approve')
        self.assertEqual(cur['history'][-1]['text'], '진행해 주세요')
        self.assertIn(cur['role_id'], bt.load_job(job['id'])['roles'])
        self.assertIn('승인', self.read(job, 'chat.jsonl'))
        self.assertEqual(bt.board_detail(next(c for c in bt.board_cards([bt.load_job(job['id'])]) if c.get('step_id') == st['id'] and c['kind'] == 'task'))
                         ['decisions'][-1]['decision'], 'approve')       # 시작된 뒤에도 이력이 보인다

    def test_reject_closes_and_never_auto_runs_again_then_can_reapprove(self):
        job, st = self.held_job()
        bt.step_decision(job['id'], st['id'], 'reject', '지금은 아님')
        c = self.card(job)
        self.assertEqual((c['column'], c['auto'], c['state'][0]), ('done', 'rejected', '거절함'))
        self.assertEqual(bt.board_detail(c)['decisions'][-1]['decision'], 'reject')
        self.assertIn('거절', bt.next_step_status(bt.load_wrapup(job['id'])['next_steps'][0])[1])
        self.assertEqual(bt.auto_followups(job['id']), [])               # 다시 자동 진행되지 않는다
        self.wrap(job, [step('런칭 글 게시', False)])                    # 다시 정리해도 거절·이력이 이어진다
        again = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertTrue(again['rejected'])
        self.assertNotIn('role_id', again)
        self.assertEqual(len(again['history']), 1)
        bt.step_decision(job['id'], st['id'], 'approve')                 # 처리한 뒤에도 다시 승인할 수 있다
        final = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertTrue(final['role_id'])
        self.assertNotIn('rejected', final)
        self.assertEqual([h['decision'] for h in final['history']], ['reject', 'approve'])

    def test_comment_goes_to_lead_and_needs_text(self):
        job, st = self.held_job()
        with self.assertRaises(ValueError):
            bt.step_decision(job['id'], st['id'], 'comment', '  ')
        with self.assertRaises(ValueError):
            bt.step_decision(job['id'], st['id'], 'maybe')
        seen = []

        class Lead(FakeRunner):
            def run(self, prompt, cwd, **kw):
                seen.append(prompt)
                return {'result': json.dumps({'reply': '알겠어요', 'assignments': []}), 'cost': 0.0, 'session_id': 'x', 'denials': []}
        bt._ask_json = self._ask                                         # wrap() 이 바꿔 둔 가짜 팀장 답을 되돌리고 러너를 직접 쓴다
        bt.step_decision(job['id'], st['id'], 'comment', '범위를 줄여 주세요', runner=Lead([]))
        self.assertTrue(any('범위를 줄여 주세요' in p and '런칭 글 게시' in p for p in seen), (seen, self.read(job, 'chat.jsonl')))
        cur = bt.load_wrapup(job['id'])['next_steps'][0]
        self.assertEqual(cur['history'][-1]['decision'], 'comment')
        self.assertNotIn('role_id', cur)                                 # 의견만으로는 시작하지 않는다
        self.assertEqual(cur['auto'], 'confirm')

    def test_comment_reaches_the_team_member_it_names(self):
        job, st = self.held_job()
        before = len(bt.list_jobs())

        class Lead(FakeRunner):
            def run(self, prompt, cwd, **kw):
                return {'result': json.dumps({'reply': '개발자에게 전달할게요', 'assignments': [{'role': 'dev', 'instruction': '게시 문구에서 가격을 빼 주세요'}]}),
                        'cost': 0.0, 'session_id': 'x', 'denials': []}
        bt._ask_json = self._ask
        bt.step_decision(job['id'], st['id'], 'comment', '가격 얘기는 빼 주세요', runner=Lead([]))
        role = bt.load_job(job['id'])['roles']['dev']
        self.assertEqual([n['text'] for n in role['notes']], ['게시 문구에서 가격을 빼 주세요'])   # 해당 팀원에게 실제로 붙음
        self.assertEqual(role['status'], 'revise')                       # 끝난 팀원은 다시 열려 반영한다
        self.assertEqual(len(bt.list_jobs()), before)                    # 같은 프로젝트 안에서
        self.assertNotIn('role_id', bt.load_wrapup(job['id'])['next_steps'][0])   # 그래도 보류 항목은 시작되지 않는다

    def test_unmarked_or_forbidden_steps_wait_for_approval(self):
        job = self.finished_job()
        steps = [step('GitHub 릴리스 push', True), step('가격 인상', True), {'title': '방향 표시 없는 일', 'goal': 'x', 'done_criteria': ['끝']}]
        self.wrap(job, steps)
        for s in bt.load_wrapup(job['id'])['next_steps']:
            self.assertEqual(s['auto'], 'confirm', s['title'])           # 방향 변경(또는 애매함)은 자동 시작 없음
            self.assertNotIn('role_id', s)
        self.assertEqual(bt.auto_followups(job['id']), [])               # 다시 돌려도 사용자가 누르기 전에는 시작 안 함
        self.assertEqual(set(bt.load_job(job['id'])['roles']), {'dev'})

    def test_cli_step_decision(self):
        job, st = self.held_job()
        import subprocess
        import os
        out = subprocess.run([sys.executable, str(Path(bt.__file__)), 'step-decision', job['id'], st['id'], '--decision', 'comment'],
                             capture_output=True, text=True, env={**os.environ, 'BUNI_CLAUDE': '/nonexistent'})
        self.assertIn('"ok": false', out.stdout)                         # 의견 내용이 없으면 거부


if __name__ == '__main__':
    unittest.main()
