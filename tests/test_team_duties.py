"""
상시 직무 + 추가 배정 시험 — python3 tests/test_team_duties.py
직무 카탈로그·업무 분류·기존 담당자 재사용·직무 변경·새 팀원 생성·예전 job.json 읽기를 확인한다.
팀장 답(_ask_json)은 가짜로 바꾸고 BUNI_TEAM_HOME 을 임시 폴더로 돌려 쓴다 (실제 claude 는 부르지 않는다).
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


def role(rid, name, mission='일', kind='code', **kw):
    return {'id': rid, 'name': name, 'icon': '🧑‍💻', 'kind': kind, 'mission': mission, 'deliverable': 'NOTES.md', 'depends_on': [], **kw}


class DutyBase(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        bt.save_settings({'auto_followup': True})
        self._ask = bt._ask_json

    def tearDown(self):
        bt._ask_json = self._ask

    def make(self, roles, statuses=None, status='done'):
        job = bt.new_job('직무 시험', '목표', self.proj)
        job['status'] = status
        job['plan'] = {'summary': '', 'roles': roles}
        job['roles'] = {r['id']: {'status': (statuses or {}).get(r['id'], 'accepted'), 'attempts': 1, 'feedback': '', 'summary': '', 'session_id': None}
                        for r in roles}
        bt.save_job(job)
        return job['id']

    def chat_text(self, jid):
        return '\n'.join(m['text'] for m in bt.load_chat(jid))

    def lead_says(self, data):
        bt._ask_json = lambda *a, **k: {'reply': '알겠어요', **data}

    def duties(self, jid):
        return {r['id']: (r.get('dept'), r.get('duty')) for r in bt.load_job(jid)['plan']['roles']}


class Catalog(unittest.TestCase):
    def test_catalog_has_two_departments_with_duties(self):
        cat = bt.duty_catalog()
        self.assertEqual([d['id'] for d in cat], ['frontend', 'backend'])
        ids = {d['id']: [x['id'] for x in d['duties']] for d in cat}
        self.assertEqual(ids['frontend'], ['frontend_mac', 'frontend_win'])
        self.assertEqual(ids['backend'], ['backend_server', 'backend_license', 'backend_chat_cloud'])
        self.assertEqual(bt.duty_label('backend_server'), '백엔드 · 서버·엔진')
        self.assertEqual(bt.duty_label('nope'), '')
        self.assertIn('backend_license', bt.duties_prompt())

    def test_classify(self):
        c = bt.classify_task
        self.assertEqual(c('windows/buni_team.py 의 resolve_role 오류를 고쳐 주세요')['duties'], ['backend_server'])   # windows/ 경로는 엔진 쪽
        self.assertEqual(c('Sources/ClaudeCompanion/ 의 SwiftUI 화면 버튼을 고쳐')['duties'], ['frontend_mac'])
        self.assertEqual(c('Tkinter 창에서 buni_team_ui 입력창이 느려요')['duties'], ['frontend_win'])
        self.assertEqual(c('라이선스 키 검증과 Stripe 링크 점검')['duties'], ['backend_license'])
        self.assertEqual(c('채팅방 Realtime Database 방 코드 오류')['duties'], ['backend_chat_cloud'])
        self.assertEqual(c('맥과 Windows 화면 문구를 같게')['duties'], ['frontend_mac', 'frontend_win'])    # 프론트엔드 동점 → 양쪽
        self.assertEqual(c('화면 디자인을 손봐 주세요'), {'dept': 'frontend', 'duties': [], 'scores': c('화면 디자인')['scores']})
        self.assertEqual(c('가격 인상 검토')['dept'], '')
        self.assertEqual(c('맥락을 정리')['duties'], [])                                                    # '맥락' 은 맥 앱이 아니다


class LegacyRead(DutyBase):
    def test_old_job_without_dept_duty_still_reads(self):
        jid = self.make([role('dev', '개발자', '일'), role('backend_server', '백엔드 담당', '엔진'),
                         role('research', '시장조사원', '경쟁 앱 가격 조사', kind='readonly')])
        job = bt.load_job(jid)
        self.assertNotIn('duty', job['plan']['roles'][0])                    # 데이터는 그대로
        self.assertEqual([bt.role_duty(r) for r in job['plan']['roles']], ['', 'backend_server', ''])
        team = {t['dept']: t for t in bt.team_structure(job)}
        self.assertEqual([m['id'] for m in team['backend']['members']], ['backend_server'])
        self.assertEqual(team['backend']['members'][0]['duty_label'], '백엔드 · 서버·엔진')
        self.assertEqual(sorted(m['id'] for m in team['']['members']), ['dev', 'research'])

    def test_legacy_role_guessed_from_mission_only_when_clear(self):
        r = role('x', '결제 개발자', 'Stripe 결제 링크와 라이선스 키 Ed25519 검증을 맡는다')
        self.assertEqual(bt.role_duty(r), 'backend_license')
        self.assertEqual(bt.role_duty(role('y', '개발자', '여러 가지 일')), '')

    def test_valid_plan_keeps_duty_and_old_plans_pass(self):
        plan = bt._valid_plan({'summary': 's', 'roles': [
            {'id': 'backend_server', 'name': 'B', 'kind': 'code', 'mission': 'm'},
            {'id': 'a', 'name': 'A', 'kind': 'code', 'mission': 'm', 'duty': 'frontend_mac'},
            {'id': 'r', 'name': 'R', 'kind': 'docs', 'mission': 'm', 'duty': 'bogus'}]})
        got = {r['id']: (r.get('dept'), r.get('duty')) for r in plan['roles']}
        self.assertEqual(got, {'backend_server': ('backend', 'backend_server'), 'a': ('frontend', 'frontend_mac'), 'r': (None, None)})


class Reuse(DutyBase):
    def test_unknown_role_name_goes_to_existing_holder_not_new_member(self):
        jid = self.make([role('backend_server', '백엔드 담당 (서버·엔진)'), role('frontend_mac', '프론트엔드 담당 (맥)')])
        self.lead_says({'assignments': [{'role': 'ghost', 'instruction': 'windows/buni_team.py 의 chat_send 오류를 고쳐'}]})
        res = bt.chat_send(jid, 'lead', '엔진 오류 고쳐 줘')
        self.assertTrue(res['ok'])
        self.assertEqual(len(bt.load_job(jid)['plan']['roles']), 2)           # 팀원 수 그대로
        job = bt.load_job(jid)
        self.assertEqual(job['roles']['backend_server']['status'], 'revise')   # 끝난 담당자를 다시 열어 반영
        self.assertEqual(job['status'], 'queued')
        text = self.chat_text(jid)
        self.assertIn('📌 업무 배정', text)
        self.assertIn('새 팀원은 만들지 않았어요', text)
        self.assertIn('📨 실제로 전달했어요', text)

    def test_new_roles_request_reuses_holder_and_assignment_follows_alias(self):
        jid = self.make([role('backend_server', '백엔드 담당 (서버·엔진)')])
        self.lead_says({'new_roles': [{'id': 'bugfixer', 'name': '엔진 버그 수정', 'mission': 'buni_team.py 엔진 오류 수정', 'kind': 'code'}],
                        'assignments': [{'role': 'bugfixer', 'instruction': '엔진 오류를 고쳐'}]})
        bt.chat_send(jid, 'lead', '엔진 버그 있어')
        self.assertEqual([r['id'] for r in bt.load_job(jid)['plan']['roles']], ['backend_server'])
        self.assertEqual(bt.load_job(jid)['roles']['backend_server']['status'], 'revise')
        self.assertEqual(len(bt.load_job(jid)['roles']['backend_server']['notes']), 1)

    def test_picks_least_busy_holder_and_queues_when_running(self):
        jid = self.make([role('a', '엔진 1', duty='backend_server', dept='backend'), role('b', '엔진 2', duty='backend_server', dept='backend')],
                        statuses={'a': 'running', 'b': 'accepted'}, status='running')
        self.assertEqual(bt.find_assignee(bt.load_job(jid), 'buni_team.py 수정'), 'b')
        jid = self.make([role('a', '엔진 1', duty='backend_server', dept='backend')], statuses={'a': 'running'}, status='running')
        self.lead_says({'assignments': [{'role': 'zzz', 'instruction': '엔진 daemon 오류'}]})
        bt.chat_send(jid, 'lead', '엔진')
        job = bt.load_job(jid)
        self.assertTrue(job['roles']['a']['note_pending'])                       # 일하는 중이면 끝나는 대로 반영
        self.assertEqual(len(job['plan']['roles']), 1)

    def test_explicit_valid_role_is_kept(self):
        jid = self.make([role('backend_server', '백엔드'), role('frontend_mac', '맥')])
        self.lead_says({'assignments': [{'role': 'frontend_mac', 'instruction': '엔진 쪽도 한 번 봐 줘'}]})
        bt.chat_send(jid, 'lead', 'x')
        self.assertEqual(bt.load_job(jid)['roles']['frontend_mac']['status'], 'revise')
        self.assertEqual(bt.load_job(jid)['roles']['backend_server']['status'], 'accepted')

    def test_resolve_role_by_duty_name_and_by_old_name(self):
        jid = self.make([role('x1', '백엔드 담당 (서버·엔진)', duty='backend_server', dept='backend')])
        job = bt.load_job(jid)
        self.assertEqual(bt.resolve_role(job, 'backend_server'), 'x1')
        self.assertEqual(bt.resolve_role(job, '백엔드 담당 (서버·엔진)'), 'x1')
        self.assertEqual(bt.resolve_role(job, '', 'job.json 저장 오류'), 'x1')
        self.assertEqual(bt.resolve_role(job, 'nobody'), '')

    def test_both_frontends_get_the_task_on_tie(self):
        jid = self.make([role('frontend_mac', '맥'), role('frontend_win', 'Windows')])
        self.lead_says({'assignments': [{'role': 'nobody', 'instruction': '맥과 Windows 화면 문구를 같게'}]})
        bt.chat_send(jid, 'lead', 'x')
        job = bt.load_job(jid)
        self.assertEqual((job['roles']['frontend_mac']['status'], job['roles']['frontend_win']['status']), ('revise', 'revise'))


class Reassign(DutyBase):
    def test_idle_member_takes_over_duty_when_no_holder(self):
        jid = self.make([role('research', '시장조사원', '경쟁 앱 가격 조사', kind='readonly'),
                         role('frontend_mac', '프론트엔드 담당 (맥)')])
        self.lead_says({'assignments': [{'role': 'nobody', 'instruction': '라이선스 키 검증 버그와 Stripe 링크 점검'}]})
        bt.chat_send(jid, 'lead', 'x')
        job = bt.load_job(jid)
        self.assertEqual(len(job['plan']['roles']), 2)                          # 팀원은 없애지도 늘리지도 않는다
        r = next(r for r in job['plan']['roles'] if r['id'] == 'research')
        self.assertEqual((r['dept'], r['duty'], r['kind']), ('backend', 'backend_license', 'code'))
        self.assertEqual(r['name'], '백엔드 담당 (라이선스·결제)')
        self.assertEqual(r['duty_history'][0]['name'], '시장조사원')
        self.assertEqual(job['roles']['research']['status'], 'revise')
        self.assertIn('🔄 직무 변경', self.chat_text(jid))
        self.assertEqual(bt.resolve_role(job, '시장조사원'), 'research')           # 옛 이름으로 불러도 같은 사람
        self.assertEqual(bt.resolve_role(job, 'backend_license'), 'research')

    def test_sole_holder_and_busy_members_are_not_taken(self):
        jid = self.make([role('backend_server', '엔진'), role('frontend_mac', '맥', status_note='x')],
                        statuses={'backend_server': 'accepted', 'frontend_mac': 'running'}, status='running')
        self.assertIsNone(bt._idle_candidate(bt.load_job(jid)))                  # 유일한 담당자·일하는 사람은 건드리지 않는다
        out = bt.assign_task(jid, 'Tkinter 창 수정')                              # 프론트엔드는 맥 담당자가 Windows 를 대신하지 않는다
        self.assertEqual(out[0][1], 'create')
        out = bt.assign_task(jid, '라이선스 결제 점검')                             # 백엔드는 같은 부서 담당자가 겸한다
        self.assertEqual(out, [('backend_server', 'reuse')])

    def test_creates_member_with_duty_only_when_nobody_fits(self):
        jid = self.make([role('backend_server', '엔진'), role('frontend_mac', '맥')])
        before = len(bt.load_job(jid)['plan']['roles'])
        self.lead_says({'new_roles': [{'id': 'winfix', 'name': 'Windows 화면', 'mission': 'Tkinter buni_team_ui 입력창 수정', 'kind': 'code'}],
                        'assignments': [{'role': 'winfix', 'instruction': '입력창 지연을 고쳐'}]})
        bt.chat_send(jid, 'lead', 'x')
        job = bt.load_job(jid)
        self.assertEqual(len(job['plan']['roles']), before + 1)
        new = job['plan']['roles'][-1]
        self.assertEqual((new['id'], new['dept'], new['duty']), ('frontend_win', 'frontend', 'frontend_win'))
        self.assertIn('프론트엔드 · Windows', self.chat_text(jid))
        self.assertEqual(len(job['roles']['frontend_win']['notes']), 1)

    def test_unclassifiable_new_role_keeps_old_behaviour(self):
        jid = self.make([role('backend_server', '엔진')])
        self.lead_says({'new_roles': [{'id': 'pr', 'name': '홍보', 'mission': '런칭 글 다듬기', 'kind': 'docs'}],
                        'assignments': [{'role': 'pr', 'instruction': '글을 다듬어'}]})
        bt.chat_send(jid, 'lead', 'x')
        job = bt.load_job(jid)
        self.assertEqual([r['id'] for r in job['plan']['roles']], ['backend_server', 'pr'])
        self.assertNotIn('duty', job['plan']['roles'][1])


class Followup(DutyBase):
    def step_for(self, jid, title, goal):
        st = {'id': 's1', 'title': title, 'why': '시험', 'goal': goal, 'done_criteria': ['끝남'], 'direction_change': False}
        bt._atomic_write(bt.wrapup_path(jid), json.dumps({'review_items': [], 'next_steps': [st]}, ensure_ascii=False))
        return 's1'

    def test_followup_goes_to_field_owner_without_new_member(self):
        jid = self.make([role('backend_server', '엔진'), role('frontend_mac', '맥')])
        sid = self.step_for(jid, '엔진 보강', 'buni_team.py 의 wrap_up 를 손본다')
        bt.start_followup(jid, sid, auto=True, depth=0)
        job = bt.load_job(jid)
        self.assertEqual([r['id'] for r in job['plan']['roles']], ['backend_server', 'frontend_mac'])
        self.assertEqual(bt.load_wrapup(jid)['next_steps'][0]['role_id'], 'backend_server')
        self.assertEqual((job['status'], job['auto_depth'], job['roles']['backend_server']['status']), ('queued', 1, 'revise'))
        self.assertEqual(job['plan']['roles'][0]['step_id'], 's1')
        self.assertIn('📌 업무 배정', self.chat_text(jid))

    def test_followup_without_field_keeps_next_role(self):
        jid = self.make([role('backend_server', '엔진')])
        sid = self.step_for(jid, '테스트 보완', '테스트를 늘린다')
        bt.start_followup(jid, sid)
        ids = [r['id'] for r in bt.load_job(jid)['plan']['roles']]
        self.assertEqual(ids, ['backend_server', 'next_s1'])


class Archive(DutyBase):
    """안 쓰는 팀원 보관 — 삭제하지 않고 archived 표시만, 상시·진행 중 팀원은 건드리지 않는다."""
    def team(self):
        return [role('research', '조사', kind='readonly'),
                role('next_n1', '디자인 정리'), role('boardux', '보드', origin='added'), role('late', '나중 팀원'),
                role('backend_server', '엔진'), role('frontend_mac', '맥'), role('next_n2', '진행 중 업무'), role('next_n3', '다시 작업', depends_on=[])]

    def make_team(self):
        st = {'next_n2': 'running', 'next_n3': 'revise', 'frontend_mac': 'pending'}
        jid = self.make(self.team(), st)
        bt.chat_add(jid, 'lead', 'all', '새 팀원 🧑‍💻 나중 팀원 이(가) 합류했어요.', 'say')       # origin 없는 예전 데이터: 채팅 기록으로 알아낸다
        return jid

    def test_dry_run_changes_nothing_and_picks_one_offs(self):
        jid = self.make_team()
        got = bt.archive_roles(jid, dry_run=True)
        self.assertEqual({x['id'] for x in got}, {'next_n1', 'boardux', 'late'})
        self.assertFalse(any(bt.is_archived(r) for r in bt.load_job(jid)['plan']['roles']))

    def test_archive_marks_but_never_deletes_or_touches_standing_and_busy(self):
        jid = self.make_team()
        before = len(bt.load_chat(jid))
        got = bt.archive_roles(jid)
        job = bt.load_job(jid)
        self.assertEqual(len(job['plan']['roles']), 8)                         # 삭제 없음
        self.assertEqual({r['id'] for r in job['plan']['roles'] if r.get('archived')}, {'next_n1', 'boardux', 'late'})
        r = next(r for r in job['plan']['roles'] if r['id'] == 'next_n1')
        self.assertIs(r['archived'], True)
        self.assertGreater(r['archived_at'], 0)
        self.assertTrue(r['archived_reason'])
        for keep in ('research', 'backend_server', 'frontend_mac', 'next_n2', 'next_n3'):     # 처음 팀원·상시·진행 중·다시 작업 중
            self.assertFalse(next(x for x in job['plan']['roles'] if x['id'] == keep).get('archived'), keep)
        self.assertEqual(len(got), 3)
        self.assertEqual(len(bt.load_chat(jid)), before + 1)                   # 채팅에 한 줄만 더 붙고 기록은 그대로
        self.assertEqual(bt.archive_roles(jid), [])                            # 두 번 해도 같다

    def test_dependents_block_archive(self):
        roles = [role('next_a', '앞'), role('next_b', '뒤', depends_on=['next_a'])]
        jid = self.make(roles, {'next_b': 'pending'})
        self.assertEqual(bt.archive_roles(jid), [])

    def test_structure_hides_archived_by_default(self):
        jid = self.make_team()
        bt.archive_roles(jid)
        job = bt.load_job(jid)
        ids = lambda t: {m['id'] for g in t for m in g['members']}
        self.assertNotIn('next_n1', ids(bt.team_structure(job)))
        shown = bt.team_structure(job, include_archived=True)
        self.assertIn('next_n1', ids(shown))
        self.assertTrue(next(m for g in shown for m in g['members'] if m['id'] == 'next_n1')['archived'])

    def test_board_assignee_filter_hides_archived(self):
        jid = self.make_team()
        bt.archive_roles(jid)
        legacy = dict(bt.load_job(jid)); legacy['tasks'] = []                   # 업무(tasks)가 없는 옛 작업은 팀원 카드
        cards = [c for c in bt.board_cards([legacy]) if c['kind'] == 'role']
        self.assertEqual(len(cards), 8)                                        # 카드(기록)는 모두 그대로
        self.assertTrue(next(c for c in cards if c['role_id'] == 'boardux')['assignee_archived'])
        self.assertNotIn('boardux', [a['id'] for a in bt.board_assignees(cards)])
        self.assertIn('boardux', [a['id'] for a in bt.board_assignees(cards, show_archived=True)])

    def test_note_to_archived_member_unarchives_and_roster_skips_it(self):
        jid = self.make_team()
        bt.archive_roles(jid)
        seen = []
        bt._ask_json = lambda runner, prompt, *a, **k: (seen.append(prompt), {'reply': 'ok'})[1]
        bt.chat_send(jid, 'lead', '안녕')
        self.assertNotIn('boardux (', seen[0])
        self.assertIn('backend_server (', seen[0])
        bt.send_role_note(jid, 'boardux', '다시 부탁해요')
        job = bt.load_job(jid)
        self.assertFalse(next(r for r in job['plan']['roles'] if r['id'] == 'boardux').get('archived'))
        self.assertEqual(job['roles']['boardux']['status'], 'revise')

    def test_archived_not_reused_by_assignment_and_unarchive(self):
        roles = [role('next_x', '옛 라이선스', mission='라이선스 키 검증', duty='backend_license')]
        jid = self.make(roles)
        job = bt.load_job(jid)
        job['plan']['roles'][0]['archived'] = True                              # 직접 보관 표시된 경우에도 재사용 후보가 아니다
        bt.save_job(job)
        self.assertEqual(bt.find_assignee(bt.load_job(jid), duty_id='backend_license'), '')
        bt.unarchive_role(jid, 'next_x')
        self.assertEqual(bt.find_assignee(bt.load_job(jid), duty_id='backend_license'), 'next_x')

    def test_cli_duties_reports_archived(self):
        jid = self.make_team()
        bt.archive_roles(jid)
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bt.main(['duties', jid])
        out = json.loads(buf.getvalue())
        self.assertEqual(out['archived_count'], 3)


if __name__ == '__main__':
    unittest.main()
