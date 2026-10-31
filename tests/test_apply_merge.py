"""내 폴더에 반영 — 파일별 세 갈래 병합 · 겹친 파일 정리 · 일부만 반영 · 되돌리기/다시 적용 · 거절 · 변경 전후 화면.
임시 git 저장소와 BUNI_TEAM_HOME 임시 폴더만 쓴다. 실제 claude 는 부르지 않는다(겹친 파일 정리는 대체한다)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))
TMP = tempfile.TemporaryDirectory()
import buni_team as t  # noqa: E402


class ApplyMerge(unittest.TestCase):
    def test_merge_conflict_rollback_reject_shots(self):
        orig = t._resolve_conflicts
        self.addCleanup(lambda: setattr(t, '_resolve_conflicts', orig))
        old = {k: os.environ.get(k) for k in ('BUNI_TEAM_HOME', 'BUNI_TEAM_NO_SHOTS')}     # 다른 시험의 작업 목록과 섞이지 않게 이 시험 동안만 쓴다
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v) for k, v in old.items()])
        os.environ['BUNI_TEAM_HOME'] = tempfile.mkdtemp(dir=TMP.name)
        os.environ['BUNI_TEAM_NO_SHOTS'] = '1'
        proj = tempfile.mkdtemp(dir=TMP.name)


        def g(*a, cwd=None):
            r = subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x'] + list(a), cwd=cwd or proj, capture_output=True, text=True)
            return r.stdout.strip()


        def w(path, text, root=None):
            p = os.path.join(root or proj, path)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, 'w').write(text)


        def r(path, root=None):
            try:
                return open(os.path.join(root or proj, path)).read()
            except OSError:
                return None


        LINES = ''.join(f'line{i}\n' for i in range(1, 11))
        g('init', '-q')
        w('a.txt', LINES); w('b.txt', LINES); w('c.txt', 'gone\n'); w('Sub/MainView.swift', 'struct V {}\n')
        g('add', '.'); g('commit', '-qm', 'init')
        base = g('rev-parse', 'HEAD')
        g('branch', 'buni/x')
        wt = tempfile.mkdtemp() + '/wt'
        g('worktree', 'add', '-q', wt, 'buni/x')
        # 팀: a 의 9번째 줄, b 의 2번째 줄, c 삭제, new 추가, 화면 파일 수정
        w('a.txt', LINES.replace('line9', 'TEAM9'), wt)
        w('b.txt', LINES.replace('line2', 'TEAM2'), wt)
        os.remove(os.path.join(wt, 'c.txt'))
        w('new.txt', 'n\n', wt)
        w('Sub/MainView.swift', 'struct V { let x = 1 }\n', wt)
        g('add', '-A', cwd=wt); g('commit', '-qm', 'work', cwd=wt)
        # 나: a 의 1번째 줄(겹치지 않음), b 의 2번째 줄(겹침), 따로 만든 파일 — 모두 커밋 안 한 변경
        w('a.txt', LINES.replace('line1\n', 'MINE1\n', 1))
        w('b.txt', LINES.replace('line2', 'MINE2'))
        w('mine.txt', 'dirty\n')

        j = t.new_job('t', 'goal', proj, {})
        j.update(branch='buni/x', status='review', snapshot=base, workdir=wt, plan={'summary': '', 'roles': [{'id': 'dev', 'name': 'd', 'icon': 'x', 'kind': 'code', 'mission': 'm', 'depends_on': []}]},
                 roles={'dev': {'status': 'accepted', 'finished': 1, 'attempts': 1}})
        t.save_job(j)
        j = t.load_job(j['id'])
        tk = [x for x in j['tasks']]
        assert tk and tk[0]['status'] == 'done' and tk[0].get('finished') is True, tk

        info = t.unmerged_info(j)
        assert sorted(info['files']) == ['Sub/MainView.swift', 'a.txt', 'b.txt', 'c.txt', 'new.txt'], info
        plan = {e['path']: e for e in t._plan_merge(proj, info)}
        assert plan['a.txt']['action'] == 'write' and plan['a.txt']['merged'], plan['a.txt']          # 서로 다른 곳 → 그대로 합침
        assert plan['b.txt']['action'] == 'conflict' and b'<<<<<<<' in plan['b.txt']['markers'], plan['b.txt']
        assert plan['c.txt']['action'] == 'delete' and plan['new.txt']['action'] == 'write'

        # 1) 정리를 못 하면(Claude 없음) — 겹친 파일만 남기고 나머지는 모두 반영한다
        t._resolve_conflicts = lambda job, conflicts: {}
        res = t.apply_result(j['id'])
        assert res['ok'] is False and res['partial'] and res['left'] == ['b.txt'] and res['files'] == 4, res
        assert r('a.txt') == LINES.replace('line1\n', 'MINE1\n', 1).replace('line9', 'TEAM9'), r('a.txt')   # 내 변경 + 팀 변경
        assert r('b.txt') == LINES.replace('line2', 'MINE2'), '겹친 파일은 건드리지 않는다'
        assert r('c.txt') is None and r('new.txt') == 'n\n' and r('mine.txt') == 'dirty\n'
        j = t.load_job(j['id'])
        assert j['conflicts'] == {'b.txt': base} and j['tasks'][0]['approval'] == 'conflict' and j['tasks'][0]['status'] == 'review', (j['conflicts'], j['tasks'][0])
        cid = res['change_id']
        meta = t.load_change(j['id'], cid)
        assert {f['path'] for f in meta['files']} == {'a.txt', 'c.txt', 'new.txt', 'Sub/MainView.swift'}, meta
        st = t.apply_state(j['id'])
        assert st['pending'] and st['files'] == ['b.txt'] and st['conflicts'] == ['b.txt'] and st['changes'][0]['id'] == cid, st

        # 2) 되돌리기 — 내 변경은 남기고 팀이 바꾼 것만 되돌린다
        rb = t.rollback_change(j['id'], cid)
        assert rb['ok'] and not rb['skipped'], rb
        assert r('a.txt') == LINES.replace('line1\n', 'MINE1\n', 1), r('a.txt')
        assert r('c.txt') == 'gone\n' and r('new.txt') is None and r('mine.txt') == 'dirty\n'
        j = t.load_job(j['id'])
        assert j['tasks'][0]['rolled_back'] and not j['tasks'][0]['applied']
        ra = t.reapply_change(j['id'], cid)
        assert ra['ok'] and r('new.txt') == 'n\n' and 'TEAM9' in r('a.txt') and 'MINE1' in r('a.txt')
        # 되돌린 뒤 내가 같은 파일을 또 고쳤으면 겹치는 곳만 건너뛴다
        w('new.txt', 'my own edit\n')
        rb = t.rollback_change(j['id'], cid)
        assert rb['skipped'] == ['new.txt'] and r('new.txt') == 'my own edit\n' and r('c.txt') == 'gone\n', rb
        t.reapply_change(j['id'], cid)

        # 3) 겹친 파일을 Claude 가 정리하면 남은 것도 들어간다 (정리가 이상하면 — 마커가 남으면 — 거부한다)
        bad = lambda job, conflicts: {'b.txt': conflicts[0]['markers']}
        assert t._valid_resolution('b.txt', plan['b.txt']['markers']) == '충돌 표시가 남아 있어요'
        good = LINES.replace('line2', 'MINE2+TEAM2')
        t._resolve_conflicts = lambda job, conflicts: {'b.txt': good.encode()}
        res = t.apply_result(j['id'])
        assert res['ok'] and res['files'] == 1 and r('b.txt') == good, res
        j = t.load_job(j['id'])
        assert not j['conflicts'] and j['tasks'][0].get('approval') in ('', None) and t.apply_state(j['id'])['pending'] is False

        # 4) 거절 — 승인 대기 변경을 내 폴더에 넣지 않고 팀 작업에서도 걷어 낸다
        w('d.txt', 'd1\n', wt); g('add', '-A', cwd=wt); g('commit', '-qm', 'more', cwd=wt)
        j = t.load_job(j['id'])
        tk2 = t.new_task(j, '두 번째 업무', '', 'chat', ['dev']); tk2['parts']['dev'] = 0
        j['roles']['dev']['finished'] = tk2['created'] + 5
        t.save_job(j)
        j = t.load_job(j['id'])
        t2 = [x for x in j['tasks'] if x['id'] == tk2['id']][0]
        assert t2['finished'], t2
        t2['approval'] = 'needs'; t.save_job(j)
        j = t.load_job(j['id'])
        assert [x for x in j['tasks'] if x['id'] == tk2['id']][0]['status'] == 'review'
        rj = t.reject_changes(j['id'])
        assert rj['ok'] and r('d.txt') is None
        assert not os.path.exists(os.path.join(wt, 'd.txt')), '팀 작업 공간에서도 걷어 냄'
        j = t.load_job(j['id'])
        t2 = [x for x in j['tasks'] if x['id'] == tk2['id']][0]
        assert t2['rejected'] and t2['approval'] == '' and t2['status'] == 'done', t2
        assert not t.apply_state(j['id'])['pending']

        # 5) 변경 전·후 화면 — 화면 파일이 바뀐 변경이면 같은 이름으로 찍고, 같은 그림은 버린다
        shot = tempfile.mkdtemp() + '/shot.sh'
        open(shot, 'w').write('#!/bin/bash\nmkdir -p "$BUNI_SHOT_DIR"\nprintf "PNG-$BUNI_SHOT_SIDE" > "$BUNI_SHOT_DIR/화면.png"\nprintf "SAME" > "$BUNI_SHOT_DIR/같음.png"\n')
        os.chmod(shot, 0o755)
        t.save_settings({'preview_cmd': shot})
        assert t.capture_shots(j['id'], cid) == ['화면.png'], '화면 파일(MainView)이 바뀐 변경이라 찍는다'
        meta = t.load_change(j['id'], cid)
        sp = t._shot_paths(j['id'], meta)
        assert sp and open(sp[0]['before']).read() == 'PNG-before' and open(sp[0]['after']).read() == 'PNG-after'
        st = t.apply_state(j['id'])
        assert st['changes'][0]['shots'][0]['name'] == '화면.png' and os.path.exists(st['changes'][0]['shots'][0]['after']), st['changes'][0]
        t.save_settings({'preview_cmd': ''})


if __name__ == '__main__':
    unittest.main()
