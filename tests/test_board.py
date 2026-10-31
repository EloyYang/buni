"""
스쿼드 업무 현황 보드 시험 — python3 tests/test_board.py
칼럼 판정 · 카드(이어서 진행한 업무·지난 업무·다음에 할 일) · 요약 · 검색/상태/담당자/범위 필터 · 정렬 · 상세.
BUNI_TEAM_HOME 을 임시 폴더로 돌려 쓰고 실제 claude 는 부르지 않는다.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402


def make_job(title, status, roles, states, **extra):
    job = bt.new_job(title, f'{title} 목표', TMP.name)
    job['status'] = status
    job['plan'] = {'summary': '', 'roles': [{'id': i, 'name': n, 'icon': '🧑‍💻', 'kind': 'code', 'mission': m, 'deliverable': '', 'depends_on': []}
                                            for i, n, m in roles]} if roles else None
    job['roles'] = {i: {'status': s, 'summary': f'{i} 요약\n둘째 줄'} for i, s in states.items()}
    job.update(extra)
    bt.save_job(job)
    return job


class BoardColumn(unittest.TestCase):
    def test_column_rules(self):
        c = bt.board_column
        self.assertEqual(c('cancelled', 'running'), 'done')
        self.assertEqual(c('done', None), 'done')
        self.assertEqual(c('review', 'pending'), 'review')
        self.assertEqual(c('running', 'accepted'), 'done')
        self.assertEqual(c('failed', 'accepted'), 'done')
        for s in ('failed', 'waiting_limit', 'paused'):
            self.assertEqual(c(s, 'running'), 'blocked')
        self.assertEqual(c('running', None), 'running')
        self.assertEqual(c('queued', None), 'ready')
        self.assertEqual(c('running', 'revise'), 'running')
        self.assertEqual(c('running', 'done_unreviewed'), 'review')
        self.assertEqual(c('running', 'pending'), 'ready')

    def test_names_and_elapsed(self):
        self.assertEqual(bt.BOARD_COLUMN_NAMES['ready'], ('대기', 'Waiting'))
        self.assertEqual(bt.BOARD_COLUMN_NAMES['blocked'][0], '확인 필요')
        self.assertEqual(bt.board_elapsed(100, 130), '방금')
        self.assertEqual(bt.board_elapsed(0, 3 * 60), '3분')
        self.assertEqual(bt.board_elapsed(0, 3600 + 120, en=True), '1h 2m')
        self.assertEqual(bt.board_elapsed(0, 86400 * 2 + 3600 * 5), '2일 5시간')


class BoardCards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.a = make_job('가격 페이지', 'running', [('dev', '결제 개발자', '결제 흐름'), ('qa', '검증 담당', '시험'), ('next_x', '후속 정리', '이어서')],
                         {'dev': 'accepted', 'qa': 'running', 'next_x': 'pending'})
        bt.chat_add(cls.a['id'], 'lead', 'qa', '시험을 돌려 주세요', 'instruction')
        bt.chat_add(cls.a['id'], 'lead', 'dev', '다른 사람 지시', 'instruction')
        bt.ActivityLog(cls.a['id'], 'qa').add('pytest 실행 중', force=True)
        cls.b = make_job('마케팅 글', 'review', [('mk', '마케팅 작가', '글')], {'mk': 'done_unreviewed'})
        cls.c = make_job('막힌 일', 'failed', [('x', '엑스', 'x')], {'x': 'running'}, error='한도 문제')
        cls.d = make_job('계획 전', 'queued', None, {})
        wu = {'review_items': [], 'next_steps': [
            {'id': 's1', 'title': '자동으로 이어 간 일', 'why': '이유', 'goal': '목표', 'role_id': 'next_x', 'auto': 'started', 'direction_change': False},
            {'id': 's2', 'title': '가격 바꾸기', 'why': '정책', 'goal': '가격 조정', 'auto': 'confirm', 'direction_change': True},
            {'id': 's3', 'title': '상한 걸린 일', 'why': '단계', 'goal': 'g', 'auto': 'limit', 'direction_change': False},
            {'id': 's4', 'title': '그냥 대기', 'why': 'w', 'goal': 'g', 'auto': 'cap', 'direction_change': False}]}
        Path(bt.wrapup_path(cls.a['id'])).write_text(json.dumps(wu, ensure_ascii=False), encoding='utf-8')
        cls.cards = bt.board_cards()
        # 업무(task) 카드는 담당 팀원 id 로도 찾을 수 있게 — 시험 사례는 팀원 하나가 업무 하나를 맡는다
        cls.by = {(f"{c['job_id']}|{c['role_id']}" if c['kind'] == 'task' else c['id']): c for c in cls.cards}

    def test_role_cards_include_followup_and_finished(self):
        a = self.a['id']
        self.assertEqual(self.by[f'{a}|dev']['column'], 'done')
        self.assertEqual(self.by[f'{a}|qa']['column'], 'running')
        self.assertEqual(self.by[f'{a}|qa']['recent'], 'pytest 실행 중')
        self.assertEqual(self.by[f'{a}|qa']['progress'], (0, 1))                    # 업무 카드의 진행률 = 그 업무를 맡은 팀원 중 끝낸 수
        nx = self.by[f'{a}|next_x']
        self.assertEqual((nx['column'], nx['auto']), ('ready', 'started'))      # 이어서 진행하는 업무 = 대기열, 자동 진행됨
        self.assertEqual(self.by[f'{self.b["id"]}|mk']['column'], 'review')

    def test_blocked_and_job_card(self):
        x = self.by[f'{self.c["id"]}|x']
        self.assertEqual((x['column'], x['state'][0], x['recent']), ('blocked', '실패', '한도 문제'))
        d = self.by[self.d['id']]
        self.assertEqual((d['kind'], d['column'], d['assignee']), ('job', 'ready', '팀장'))

    def test_next_step_cards(self):
        a = self.a['id']
        self.assertEqual((self.by[f'{a}|step:s2']['column'], self.by[f'{a}|step:s2']['auto']), ('blocked', 'confirm'))
        self.assertEqual((self.by[f'{a}|step:s3']['column'], self.by[f'{a}|step:s3']['auto']), ('blocked', 'limit'))
        self.assertEqual((self.by[f'{a}|step:s4']['column'], self.by[f'{a}|step:s4']['auto']), ('ready', ''))
        self.assertNotIn(f'{a}|step:s1', self.by)                                # 이미 이어서 진행 중인 것은 팀원 카드로만 보인다
        self.assertEqual(sum(1 for c in self.cards if c['job_id'] == a), 3 + 3)

    def test_summary(self):
        s = bt.board_summary(self.cards)
        self.assertEqual(s['total'], len(self.cards))
        self.assertEqual(s['running'], 1)
        self.assertEqual(s['done'], 1)
        self.assertEqual(s['blocked'], 3)
        self.assertEqual(s['review'], 1)

    def test_search_status_assignee_scope(self):
        f = lambda **kw: {(f"{c['job_id']}|{c['role_id']}" if c['kind'] == 'task' else c['id']) for c in bt.board_filter(self.cards, **kw)}
        a = self.a['id']
        self.assertEqual(f(query='pytest'), {f'{a}|qa'})                         # 최근 활동 내용
        self.assertEqual(f(query='결제 개발자'), {f'{a}|dev'})                    # 담당자
        self.assertIn(f'{a}|dev', f(query='가격 페이지'))                         # 제목
        self.assertIn(f'{a}|step:s2', f(query='가격 조정'))                       # 내용(목표)
        self.assertEqual(f(query='가격 페이지 pytest'), {f'{a}|qa'})              # 여러 낱말은 모두 맞아야
        self.assertEqual(f(query='없는말'), set())
        self.assertEqual(f(status='review'), {f'{self.b["id"]}|mk'})
        self.assertEqual(f(assignee='mk'), {f'{self.b["id"]}|mk'})
        done, active = f(scope='finished'), f(scope='active')
        self.assertEqual(done, {f'{a}|dev'})                                     # 끝난 지난 업무도 찾아볼 수 있다
        self.assertFalse(done & active)
        self.assertEqual(done | active, f())
        self.assertEqual(f(scope='active', status='done'), set())

    def test_sort(self):
        cols = [c['column'] for c in bt.board_filter(self.cards, sort='state')]
        self.assertEqual(cols, sorted(cols, key=bt.BOARD_COLUMNS.index))
        names = [c['assignee'] for c in bt.board_filter(self.cards, sort='assignee')]
        self.assertEqual(names, sorted(names))

    def test_detail(self):
        d = bt.board_detail(self.by[f'{self.a["id"]}|qa'])
        self.assertEqual(d['activity'], ['pytest 실행 중'])
        self.assertEqual([m['text'] for m in d['chat']], ['시험을 돌려 주세요'])    # 그 담당자와 오간 채팅만
        self.assertIn('요약', d['summary'])

    def test_job_count_unchanged_by_board(self):
        n = len(bt.list_jobs())
        bt.board_cards(); bt.board_filter(self.cards, query='x')
        self.assertEqual(len(bt.list_jobs()), n)


if __name__ == '__main__':
    unittest.main()
