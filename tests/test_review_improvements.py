"""
팀장 검토 — 통과여도 개선점을 담당자에게 피드백해 한 번 더 다듬게 하는 흐름 시험.
가짜 claude(BUNI_CLAUDE)와 임시 BUNI_TEAM_HOME 으로 진짜 JobRunner 를 돌린다 (실제 claude·네트워크는 쓰지 않는다).
  - 통과 + improvements → 그 담당자만 한 번 더 일하고(프롬프트에 개선점이 들어간다), 채팅에 피드백이 남는다
  - max_revisions 상한을 넘기지 않고, 이미 다듬은 팀원은 다시 다듬지 않는다
  - 개선점이 있어도 상한이면 '그대로 둔 이유'를 채팅에 남긴다
"""
import json
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'windows'))

import buni_team as bt  # noqa: E402
from test_fake_claude_flow import FakeClaudeBase  # noqa: E402

# 검토 답은 FAKE_REVIEW 파일의 맨 앞 verdicts 목록을 꺼내 쓴다(다 쓰면 전부 통과). 받은 프롬프트(stdin)도 기록한다.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
name = a[a.index('--name') + 1] if '--name' in a else ''
prompt = sys.stdin.read()
with open(os.environ['FAKE_LOG'], 'a', encoding='utf-8') as f:
    f.write(json.dumps({'name': name, 'model': None, 'argv': a, 'prompt': prompt}, ensure_ascii=False) + '\n')
out = '작업을 마쳤어요.'
if '팀장(검토)' in name:
    p = os.environ['FAKE_REVIEW']
    q = json.load(open(p, encoding='utf-8'))
    vs = q.pop(0) if q else []
    json.dump(q, open(p, 'w', encoding='utf-8'))
    out = json.dumps({'verdicts': vs, 'summary': '시험 요약'})
elif '팀장(정리)' in name:
    out = json.dumps({'review_items': [], 'next_steps': []})
print(json.dumps({'type': 'system', 'subtype': 'init'}))
print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': out,
                  'total_cost_usd': 0.0, 'session_id': 'fake'}))
'''


def v(rid, verdict='accept', feedback='', improvements=None, left=''):
    return {'id': rid, 'verdict': verdict, 'feedback': feedback, 'improvements': improvements or [], 'left_as_is': left}


class ReviewImprovements(FakeClaudeBase):
    def setUp(self):
        super().setUp()
        exe = Path(os.environ['BUNI_CLAUDE'])
        exe.write_text(FAKE, encoding='utf-8')
        self.review_q = exe.parent / 'review.json'
        self.review_q.write_text('[]', encoding='utf-8')
        self._old = os.environ.get('FAKE_REVIEW')
        os.environ['FAKE_REVIEW'] = str(self.review_q)
        bt.save_settings({'auto_followup': False})

    def tearDown(self):
        if self._old is None:
            os.environ.pop('FAKE_REVIEW', None)
        else:
            os.environ['FAKE_REVIEW'] = self._old
        super().tearDown()

    def queue(self, *rounds):
        self.review_q.write_text(json.dumps(list(rounds), ensure_ascii=False), encoding='utf-8')

    def chat(self, job_id):
        return Path(bt.job_path(job_id, 'chat.jsonl')).read_text(encoding='utf-8')

    def worker_prompts(self, rid):
        return [c['prompt'] for c in self.calls() if c['name'].endswith(f'팀원{rid}')]

    def test_prompt_asks_for_improvements(self):
        self.assertIn('improvements', bt.REVIEW_PROMPT)
        self.assertIn('left_as_is', bt.REVIEW_PROMPT)
        self.assertIn('그대로 둔 이유', bt.REVIEW_PROMPT)

    def test_accept_with_improvements_sends_member_back_once(self):
        job = self.make_job([('a', ''), ('b', '')])
        self.queue([v('a', improvements=['README 예시를 실제 명령으로']), v('b')], [v('a'), v('b')])
        after = self.run_job(job['id'])
        self.assertEqual(after['status'], 'review', after.get('error'))
        self.assertEqual(after['roles']['a']['attempts'], 2)                     # 개선점을 받은 a 만 한 번 더 일했다
        self.assertEqual(after['roles']['b']['attempts'], 1)
        self.assertTrue(after['roles']['a']['polished'])
        self.assertTrue(all(r['status'] == 'accepted' for r in after['roles'].values()))
        second = self.worker_prompts('a')[1]
        self.assertIn('README 예시를 실제 명령으로', second)                      # 개선 피드백이 담당자 프롬프트에 들어갔다
        self.assertNotIn('README 예시', self.worker_prompts('a')[0])
        chat = self.chat(job['id'])
        self.assertIn('한 번 더 다듬어 주세요', chat)
        self.assertIn('README 예시를 실제 명령으로', chat)
        self.assertEqual(after['review_notes']['a']['action'], 'accept')         # 마지막 라운드 기록(개선점 없음)

    def test_polish_only_once_even_if_reviewer_keeps_finding_more(self):
        job = self.make_job([('a', '')])
        self.queue([v('a', improvements=['첫 개선'])], [v('a', improvements=['둘째 개선'], left='범위 밖')])
        after = self.run_job(job['id'])
        self.assertEqual(after['roles']['a']['attempts'], 2)                     # 두 번째 라운드의 개선점은 시키지 않는다
        self.assertEqual(after['roles']['a']['status'], 'accepted')
        chat = self.chat(job['id'])
        self.assertIn('둘째 개선', chat)
        self.assertIn('그대로 둔 이유: 범위 밖', chat)
        self.assertEqual(after['review_notes']['a']['improvements'], ['둘째 개선'])

    def test_max_revisions_zero_never_polishes(self):
        bt.save_settings({'auto_followup': False, 'max_revisions': 0})
        job = self.make_job([('a', '')])
        self.queue([v('a', improvements=['개선 하나'])])
        after = self.run_job(job['id'])
        self.assertEqual(after['roles']['a']['attempts'], 1)
        self.assertFalse(after['roles']['a'].get('polished'))
        chat = self.chat(job['id'])
        self.assertIn('개선 하나', chat)
        self.assertIn('max_revisions', chat)                                     # 상한 때문에 그대로 뒀다고 알린다

    def test_revise_verdict_still_capped(self):
        job = self.make_job([('a', '')])
        bad = [v('a', 'revise', '고쳐 주세요', ['곁들인 개선'])] * 5
        self.queue(*[[b] for b in bad])
        after = self.run_job(job['id'])
        self.assertEqual(after['roles']['a']['attempts'], 3)                     # 기본 max_revisions=2 → 처음 + 2번
        self.assertEqual(after['roles']['a']['status'], 'accepted')
        self.assertIn('곁들인 개선', self.worker_prompts('a')[1])

    def test_no_improvements_keeps_old_flow(self):
        job = self.make_job([('a', '')])
        self.queue([v('a')])
        after = self.run_job(job['id'])
        self.assertEqual(after['roles']['a']['attempts'], 1)
        self.assertIn('통과예요', self.chat(job['id']))

    def test_note_helper_normalizes_input(self):
        n = bt._review_note({'verdict': 'accept', 'improvements': ' 한 줄 '}, {'attempts': 1}, 2)
        self.assertEqual((n['action'], n['improvements']), ('polish', ['한 줄']))
        n = bt._review_note(None, {'attempts': 1}, 2)
        self.assertEqual(n['action'], 'accept')
        n = bt._review_note({'verdict': 'revise', 'feedback': ''}, {'attempts': 1}, 2)
        self.assertEqual(n['action'], 'accept')                                  # 피드백 없는 되돌리기는 통과로 본다(기존 규칙)


if __name__ == '__main__':
    unittest.main()
