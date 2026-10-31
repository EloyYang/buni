"""화면 비교용 예시 데이터 — 시간이 흘러도 화면이 같게 고정된 값만 쓴다. (엔진을 쓰지 않고 job.json 을 직접 적는다)"""
import json, os, struct, sys, zlib

home = sys.argv[1]
T0 = 1_700_000_000.0           # 2023-11-14 — 고정
os.makedirs(os.path.join(home, 'jobs', '20231114-000000-demo'), exist_ok=True)
roles = [{'id': 'dev', 'name': '개발자', 'icon': '💻', 'kind': 'code', 'mission': '로그인 화면을 만든다', 'depends_on': []},
         {'id': 'design', 'name': '디자이너', 'icon': '🎨', 'kind': 'docs', 'mission': '색과 글꼴을 정한다', 'depends_on': []},
         {'id': 'qa', 'name': '검수', 'icon': '🔎', 'kind': 'readonly', 'mission': '시험으로 확인한다', 'depends_on': ['dev']}]


def task(i, title, status, prio='normal', **kw):
    t = {'id': f't{i}', 'title': title, 'text': title, 'source': 'chat', 'priority': prio, 'created': T0 + i * 60, 'status': status,
         'parts': {'dev': 0}, 'part_status': {'dev': {'done': 'done', 'review': 'review', 'doing': 'doing'}.get(status, 'todo')}, 'done': {}}
    t.update(kw)
    return t


job = {
    'id': '20231114-000000-demo', 'slug': 'demo', 'title': '예시 프로젝트', 'goal': '화면 비교용 예시', 'project_dir': home,
    'created': T0, 'updated': T0 + 900, 'status': 'review', 'phase': 'done',
    'plan': {'summary': '개발자와 디자이너가 나눠서 해요.', 'roles': roles},
    'roles': {r['id']: {'status': 'accepted', 'attempts': 1, 'finished': T0 + 500, 'summary': r['mission'] + ' — 끝냈어요.'} for r in roles},
    'tasks': [
        task(1, '로그인 버튼 색을 브랜드 색으로', 'todo', 'urgent'),
        task(2, '설정 화면 정리', 'doing', 'high'),
        task(3, '결제 화면 문구 고치기', 'review', 'normal', finished=True, approval='needs', apply_note='중요한 변경: 결제·라이선스 관련 파일'),
        task(4, '목록 화면 간격 맞추기', 'done', 'normal', finished=True, done_at=T0 + 800, applied=T0 + 820, change_id='001', files=['a.swift']),
        task(5, '오래된 안내 문구 삭제', 'done', 'low', finished=True, done_at=T0 + 700, applied=None, rolled_back=T0 + 900, change_id='002'),
    ],
    'events': [{'ts': T0 + 100, 'msg': '업무를 시작했어요'}, {'ts': T0 + 800, 'msg': '결과를 내 폴더에 반영했어요'}],
    'cost_usd': 0.5,
}
job['roles'][roles[1]['id']] = {'status': 'running', 'attempts': 1, 'started': T0 + 600}      # 업무 중인 팀원 한 명 — 왼쪽 목록의 빛나는 테두리가 보이게


def png(path, w, h, rgb, bar):
    """작은 단색 PNG (표준 라이브러리만) — 위쪽 띠는 다른 색으로 그려 변경 전·후가 달라 보이게 한다."""
    rows = b''.join(b'\x00' + bytes(bar if y < h // 5 else rgb) * w for y in range(h))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


croot = os.path.join(home, 'jobs', job['id'], 'changes')
for cid, tasks, rb, shots in (('001', ['t4'], 0, ['목록 화면.png', '설정 화면.png']), ('002', ['t5'], T0 + 900, [])):
    meta = {'id': cid, 'ts': T0 + 820, 'title': '목록 화면 간격 맞추기' if cid == '001' else '오래된 안내 문구 삭제', 'tip': 'x', 'base': 'y',
            'tasks': tasks, 'files': [{'path': 'Sources/ListView.swift', 'kind': 'edit', 'merged': False, 'resolved': False}], 'rolled_back': rb, 'shots': shots}
    os.makedirs(os.path.join(croot, cid), exist_ok=True)
    with open(os.path.join(croot, cid, 'meta.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False)
    for n in shots:
        png(os.path.join(croot, cid, 'shots', 'before', n), 360, 220, (38, 38, 42), (90, 90, 96))
        png(os.path.join(croot, cid, 'shots', 'after', n), 360, 220, (26, 26, 29), (242, 140, 46))

with open(os.path.join(home, 'jobs', job['id'], 'job.json'), 'w', encoding='utf-8') as f:
    json.dump(job, f, ensure_ascii=False, indent=2)
with open(os.path.join(home, 'settings.json'), 'w', encoding='utf-8') as f:
    json.dump({'apply_mode': 'smart', 'window_start': '22:00', 'window_end': '06:00'}, f)
