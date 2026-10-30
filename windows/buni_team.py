"""
Buni 부니 스쿼드 — 팀장 Claude가 필요한 역할(디자인·개발·마케팅 …)을 정해 일을 나누고, 검토하고, 합쳐서
결과물을 만드는 "에이전트 모드"와, 사람이 없는 시간대(기본 22:00~06:00)에 맡긴 일을 진행하는 "업무 예약".

흐름 (한 작업 = 한 job)
  1. 사전 요구서  — 사람이 있을 때 Claude가 질문을 모아 묻고, 답을 받아 '사전요구서'를 만든다. 사용자가 승인해야 예약된다.
  2. 팀 구성      — 팀장이 요구서를 보고 필요한 역할과 업무를 JSON 으로 짠다.
  3. 업무 진행    — 역할마다 따로 `claude -p` 세션을 띄운다 (Buni 훅으로 세션마다 부니가 나타난다).
  4. 검토         — 팀장이 결과를 검토하고 모자라면 피드백과 함께 다시 시킨다 (최대 2번).
  5. 통합·보고    — 팀장이 합쳐 FINAL.md 와 REPORT.md 를 만든다. 사용자는 아침에 검토한다.

안전: 사람이 없을 때는 `--permission-mode dontAsk` + 허용 목록만 쓴다 — 목록에 없는 건 묻지 않고 거절한다.
프로젝트 폴더 안의 파일·검색과 안전한 명령(테스트·빌드·git 읽기)만 허용하고, 삭제·설치·외부 전송은 막는다.
코드 변경은 새 git 브랜치(buni/<이름>)에 모으고 원래 브랜치는 건드리지 않는다.

이 파일은 Windows 앱(buni.py)이 직접 불러 쓰고, macOS 앱은 `python3 buni_team.py daemon` 으로 띄워 쓴다
(상태는 모두 job.json 파일로 주고받는다). 파이썬 3.8 이상이면 된다.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

IS_WIN = os.name == 'nt'

# ══════════════════════════════════════════════════════════════
# 저장 위치 · 설정
# ══════════════════════════════════════════════════════════════

DEFAULT_SETTINGS = {
    'enabled': True,            # 예약 실행 켜기
    'window_start': '22:00',    # 사람이 없는 시간대 시작
    'window_end': '06:00',      # 끝 (시작보다 작으면 다음 날 아침까지)
    'concurrency': 2,           # 동시에 돌릴 역할 수 (플랜 사용량을 아끼려고 기본 2)
    'claude_path': '',          # 비워 두면 자동으로 찾는다
    'model': '',                # 팀원 기본 모델 (비워 두면 Claude Code 기본 모델)
    'lead_model': '',           # 팀장(구성·검토·통합·채팅) 모델 (비워 두면 위 기본 모델)
    'apply_mode': 'smart',      # 결과를 내 폴더에 반영하는 방식: smart(중요하지 않으면 바로, 중요하면 확인) · auto(전부 바로) · confirm(전부 확인) · manual(반영하지 않고 브랜치로만)
    # smart 모드에서 '중요한 변경'으로 보고 확인을 받을 것들
    'smart_payments': True,     # 결제·가격·라이선스·구독 관련 파일
    'smart_secrets': True,      # 비밀값·설정·인증 관련 파일 (.env, 키, 토큰, cloud-config …)
    'smart_build': True,        # 빌드·설치·릴리스·훅·버전 파일 (build_app.sh, release.sh, Package.swift, VERSION …)
    'smart_deletes': True,      # 파일을 지우는 변경
    'smart_big': True,          # 큰 변경 (아래 파일 수·줄 수를 넘으면)
    'smart_big_files': 30,
    'smart_big_lines': 1500,
    'smart_custom': '',         # 따로 확인받을 경로 (쉼표로 구분, * 사용 가능 — 예: docs/*, *.plist)
    'schedule_mode': 'window',  # 자동 진행 시간: window(아래 시간대 안에서만) · anytime(언제든 바로) · off(내가 시작할 때만)
    'limit_action': 'stop',     # Claude 사용량 한도에 닿으면: stop(멈추고 내가 이어서 시작할 때까지) · wait(풀리면 알아서 이어서)
    'paused': False,            # 모든 작업 일시정지 (켜 두면 아무것도 시작하지 않고, 돌던 것도 멈춘다)
    'run_mode': 'auto',         # 업무 진행 방식: auto(팀이 알아서 순서대로) · manual(업무마다 내가 ▶ 시작을 눌러야)
    'max_revisions': 2,         # 검토에서 되돌리는 최대 횟수
    'auto_followup': True,      # 끝난 작업의 '다음에 할 일' 중 사업 방향이 안 바뀌는 것은 자동으로 이어서 시작
}
AUTO_FOLLOWUP_MAX = 3           # 자동으로 이어 가는 연속 단계 수 상한 (넘으면 멈추고 알린다)
AUTO_FOLLOWUP_PER_WRAPUP = 2    # 한 번의 정리에서 동시에 자동 시작하는 후속 작업 수

# 고를 수 있는 모델 (id, 한국어, English) — id 가 비면 기본 모델
MODEL_CHOICES = [
    ('', '기본 모델', 'Default'),
    ('claude-fable-5-1', 'Fable 5.1', 'Fable 5.1'),
    ('claude-opus-5-5', 'Opus 5.5', 'Opus 5.5'),
    ('claude-sonnet-5-5', 'Sonnet 5.5', 'Sonnet 5.5'),
    ('claude-haiku-5-5', 'Haiku 5.5 (빠르고 저렴)', 'Haiku 5.5 (fast, cheap)'),
]
APPLY_MODES = ('smart', 'auto', 'confirm', 'manual')
RUN_MODES = ('auto', 'manual')


def _clean_model(m) -> str:
    m = str(m or '').strip()
    return m if re.fullmatch(r'[A-Za-z0-9._\-\[\]]{1,60}', m) else ''


ACTIVE = ('queued', 'running', 'waiting_limit', 'paused')       # 예약 시간대에 이어서 진행할 상태
FINISHED = ('review', 'done', 'failed', 'cancelled')


def team_home() -> str:
    env = os.environ.get('BUNI_TEAM_HOME')
    if env:
        return env
    if IS_WIN:
        base = os.environ.get('APPDATA') or os.path.expanduser('~')
        return os.path.join(base, 'Buni', 'team')
    if sys.platform == 'darwin':
        return os.path.join(os.path.expanduser('~/Library/Application Support'), 'Buni', 'team')
    return os.path.join(os.path.expanduser('~/.local/share'), 'Buni', 'team')


def jobs_dir() -> str:
    return os.path.join(team_home(), 'jobs')


def _atomic_write(path: str, text: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.tmp-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_settings() -> dict:
    s = dict(DEFAULT_SETTINGS)
    raw = {}
    try:
        with open(os.path.join(team_home(), 'settings.json'), encoding='utf-8') as f:
            raw = json.load(f)
            s.update({k: v for k, v in raw.items() if k in DEFAULT_SETTINGS})
    except (OSError, ValueError):
        pass
    if 'schedule_mode' not in raw:                         # 옛 설정 — '예약 실행 켜기' 여부로 정한다
        s['schedule_mode'] = 'window' if s.get('enabled', True) else 'off'
    return s


def save_settings(patch: dict) -> dict:
    s = load_settings()
    for k, v in patch.items():
        if k in DEFAULT_SETTINGS:
            s[k] = v
    s['concurrency'] = max(1, min(4, int(s['concurrency'])))
    s['max_revisions'] = max(0, min(4, int(s['max_revisions'])))
    s['model'], s['lead_model'] = _clean_model(s.get('model')), _clean_model(s.get('lead_model'))
    if s.get('apply_mode') not in APPLY_MODES:
        s['apply_mode'] = DEFAULT_SETTINGS['apply_mode']
    for k in ('smart_payments', 'smart_secrets', 'smart_build', 'smart_deletes', 'smart_big'):
        s[k] = bool(s.get(k))
    s['smart_big_files'] = max(1, min(500, int(s.get('smart_big_files') or 30)))
    s['smart_big_lines'] = max(50, min(100000, int(s.get('smart_big_lines') or 1500)))
    s['smart_custom'] = str(s.get('smart_custom') or '')[:300]
    if s.get('run_mode') not in RUN_MODES:
        s['run_mode'] = DEFAULT_SETTINGS['run_mode']
    if 'schedule_mode' in patch or 'enabled' in patch:
        if 'schedule_mode' not in patch:
            s['schedule_mode'] = 'window' if s.get('enabled') else 'off'
    if s.get('schedule_mode') not in ('window', 'anytime', 'off'):
        s['schedule_mode'] = 'window'
    s['enabled'] = s['schedule_mode'] != 'off'
    if s.get('limit_action') not in ('stop', 'wait'):
        s['limit_action'] = 'stop'
    s['paused'] = bool(s.get('paused'))
    s['auto_followup'] = bool(s.get('auto_followup'))
    _atomic_write(os.path.join(team_home(), 'settings.json'), json.dumps(s, ensure_ascii=False, indent=2))
    return s


# ══════════════════════════════════════════════════════════════
# 시간대
# ══════════════════════════════════════════════════════════════

def _hm(text: str) -> int:
    m = re.fullmatch(r'\s*(\d{1,2}):(\d{2})\s*', text or '')
    if not m:
        raise ValueError(f'시각 형식이 올바르지 않아요: {text!r}')
    h, mi = int(m.group(1)), int(m.group(2))
    if not (0 <= h <= 24 and 0 <= mi < 60):
        raise ValueError(f'시각 범위가 올바르지 않아요: {text!r}')
    return (h % 24) * 60 + mi


def in_window(now: datetime.datetime, start: str, end: str) -> bool:
    """now 가 [start, end) 시간대 안인지. start > end 면 자정을 넘기는 시간대(예: 22:00~06:00)."""
    s, e = _hm(start), _hm(end)
    cur = now.hour * 60 + now.minute
    if s == e:
        return True                      # 같으면 하루 종일
    if s < e:
        return s <= cur < e
    return cur >= s or cur < e


def next_window_start(now: datetime.datetime, start: str) -> datetime.datetime:
    s = _hm(start)
    cand = now.replace(hour=s // 60, minute=s % 60, second=0, microsecond=0)
    if cand <= now:
        cand += datetime.timedelta(days=1)
    return cand


def window_end_time(now: datetime.datetime, start: str, end: str) -> datetime.datetime:
    """now 가 시간대 안일 때, 이 시간대가 끝나는 시각."""
    e = _hm(end)
    cand = now.replace(hour=e // 60, minute=e % 60, second=0, microsecond=0)
    if cand <= now:
        cand += datetime.timedelta(days=1)
    return cand


# ══════════════════════════════════════════════════════════════
# Job 저장
# ══════════════════════════════════════════════════════════════

def _now_ts() -> float:
    return time.time()


def _slugify(text: str) -> str:
    s = re.sub(r'[^0-9A-Za-z가-힣]+', '-', (text or '').strip()).strip('-').lower()
    return (s[:40] or 'job')


def job_path(job_id: str, name: str = 'job.json') -> str:
    return os.path.join(jobs_dir(), job_id, name)


_job_lock = threading.RLock()


def load_job(job_id: str) -> dict | None:
    try:
        with open(job_path(job_id), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_job(job: dict):
    job['updated'] = _now_ts()
    try:
        _sync_tasks(job)
    except Exception:
        pass
    with _job_lock:
        _atomic_write(job_path(job['id']), json.dumps(job, ensure_ascii=False, indent=2))


def list_jobs() -> list:
    out = []
    try:
        names = sorted(os.listdir(jobs_dir()))
    except OSError:
        return out
    for n in names:
        j = load_job(n)
        if j:
            out.append(j)
    out.sort(key=lambda j: j.get('created', 0))
    return out


def log_event(job: dict, msg: str):
    ev = job.setdefault('events', [])
    ev.append({'ts': _now_ts(), 'msg': msg})
    del ev[:-300]


PRIORITIES = ('urgent', 'high', 'normal', 'low')
_PRIO_RANK = {'urgent': 0, 'high': 1, 'normal': 2, 'low': 3}


def _task_title(text: str, limit: int = 60) -> str:
    m = re.match(r'\s*\[이 프로젝트의 다음 업무:\s*(.+?)\]', text or '')
    if m:                                                   # 이어 붙은 다음 업무는 그 제목을 그대로
        return m.group(1)[:limit]
    lines = [l.strip() for l in (text or '').splitlines() if l.strip()]
    t = (lines[0] if lines else '').lstrip('#>*-•` ').replace('**', '').replace('`', '')
    return (t[:limit - 1] + '…') if len(t) > limit else t


def new_task(job: dict, title: str, text: str = '', source: str = 'chat', parts: list | None = None, priority: str = 'normal') -> dict:
    """내가 지시한 업무 하나 — 담당 팀원(parts)이 각자 그 지시를 처리한 만큼 진행률이 오른다. job 만 바꾸고 저장은 부르는 쪽이 한다."""
    now = _now_ts()
    t = {'id': 't' + str(int(now * 1000))[-9:] + uuid.uuid4().hex[:2], 'title': title or _task_title(text) or '업무', 'text': (text or '')[:4000],
         'source': source, 'priority': priority if priority in PRIORITIES else 'normal', 'created': now,
         'parts': {rid: now for rid in (parts or [])}, 'done': {}, 'status': 'todo'}
    job.setdefault('tasks', []).append(t)
    return t


def _sync_tasks(job: dict):
    """역할 상태로 업무 상태를 맞춘다 — job 을 저장할 때마다 부른다. (화면은 이 결과만 읽는다)"""
    if not job.get('plan'):
        return
    roles, plan_roles = job.get('roles') or {}, {r['id']: r for r in job['plan']['roles']}
    tasks = job.setdefault('tasks', [])
    first = not tasks
    covered = {rid for t in tasks for rid in (t.get('parts') or {})}
    for rid, r in plan_roles.items():                       # 담당 업무가 하나도 없는 팀원은 자기 미션이 곧 업무다 (처음 계획·옛 작업·이어 붙은 후속)
        if rid not in covered and not r.get('managed'):
            t = new_task(job, _task_title(r.get('mission') or r.get('name') or rid), r.get('mission') or '', 'plan' if first else 'followup', [rid])
            t['parts'][rid] = 0
            t['created'] = job.get('created') or t['created']
    running = job.get('status') == 'running'
    for t in tasks:
        parts = t.get('parts') or {}
        t.setdefault('done', {})
        ps = {}
        for rid, since in parts.items():
            st = roles.get(rid)
            if st is None:
                ps[rid] = 'done' if rid in t['done'] else 'todo'
                continue
            s_ = st.get('status', 'pending')
            if rid in t['done']:
                ps[rid] = 'done'
            elif s_ == 'accepted' and (st.get('finished') or 0) >= (since or 0) - 2:
                t['done'][rid] = st.get('finished') or _now_ts()
                ps[rid] = 'done'
            elif s_ == 'running' or (s_ == 'revise' and running):
                ps[rid] = 'doing'
            elif s_ == 'done_unreviewed':
                ps[rid] = 'review'
            else:
                ps[rid] = 'todo'
        t['part_status'] = ps
        vals = list(ps.values())
        if not vals:
            t['status'] = 'todo'
        elif all(v == 'done' for v in vals):
            t['status'] = 'done'
            t.setdefault('done_at', max(t['done'].values()) if t['done'] else _now_ts())
        elif any(v in ('doing',) for v in vals) or (any(v == 'done' for v in vals) and not all(v == 'done' for v in vals)):
            t['status'] = 'doing'
        elif any(v == 'review' for v in vals):
            t['status'] = 'review'
        else:
            t['status'] = 'todo'
        if t['status'] != 'done':
            t.pop('done_at', None)


def role_priority(job: dict, rid: str) -> int:
    """이 팀원이 맡은, 아직 안 끝난 업무 중 가장 급한 것의 순위 (0 = 긴급 … 3 = 낮음). 맡은 게 없으면 보통(2)."""
    best = None
    for t in job.get('tasks') or []:
        if rid in (t.get('parts') or {}) and t.get('status') != 'done':
            r = _PRIO_RANK.get(t.get('priority'), 2)
            best = r if best is None else min(best, r)
    return 2 if best is None else best


def set_task_priority(job_id: str, task_id: str, priority: str) -> dict:
    job = load_job(job_id)
    t = next((x for x in (job or {}).get('tasks', []) if x['id'] == task_id), None)
    if not t or priority not in PRIORITIES:
        raise ValueError('업무를 찾지 못했어요')
    t['priority'] = priority
    log_event(job, f"업무 우선순위: {t['title'][:30]} → {dict(urgent='긴급', high='높음', normal='보통', low='낮음')[priority]}")
    save_job(job)
    return job


def heal_interrupted_roles(job_id: str, accept: bool = False) -> list:
    """멈추거나 꺼지는 바람에 '결과 기록 직전'에 끊긴 팀원을 되살린다 — 작업 공간에 시작한 뒤 쓴 NOTES.md 가 있고 활동 기록이 일을 마친 모양이면
    이미 끝난 일이므로 대기·진행 중 목록에서 빼고(검토 대기, accept=True 면 통과) 결과를 이어받는다. 되살린 팀원 id 목록을 돌려준다."""
    job = load_job(job_id)
    if not job or not job.get('plan'):
        return []
    wd = job.get('workdir') or ''
    healed = []
    for rid, st in (job.get('roles') or {}).items():
        if st.get('status') not in ('pending', 'running', 'revise') or not st.get('started'):
            continue
        notes = os.path.join(wd, '.buni-team', job['slug'], rid, 'NOTES.md')
        try:
            mt = os.path.getmtime(notes)
        except OSError:
            continue
        if mt < st['started']:                                  # 이번 실행 전에 쓴 옛 노트
            continue
        act = load_activity(job_id, rid)
        if act.get('state') == 'running':
            continue
        try:
            with open(notes, encoding='utf-8') as f:
                text = f.read()
        except OSError:
            continue
        st['status'] = 'accepted' if accept else 'done_unreviewed'
        st['finished'], st['summary'] = mt, text.strip()[:600]
        st['note_pending'] = False
        healed.append(rid)
        log_event(job, f"끊기기 직전에 끝난 업무를 이어받았어요: {rid}" + (' (통과 처리)' if accept else ' (검토 대기)'))
    if healed:
        save_job(job)
    return healed


def pause_job(job_id: str) -> dict:
    """이 작업을 멈춘다 — 돌고 있으면 엔진이 곧 멈추고, 내가 이어서 시작할 때까지 예약 시간이 와도 시작하지 않는다."""
    job = load_job(job_id)
    if not job or job['status'] in ('cancelled', 'done'):
        raise ValueError('멈출 수 없는 작업이에요')
    job['user_paused'] = True
    job['run_now'] = None
    if job['status'] in ('queued', 'waiting_limit'):
        job['status'] = 'paused'
    log_event(job, '⏸ 내가 멈췄어요')
    save_job(job)
    chat_add(job_id, 'system', 'all', '⏸ 작업을 멈췄어요 — ▶ 이어서 를 누르면 계속해요', 'status')
    return job


def resume_job(job_id: str) -> dict:
    """멈춘 작업을 이어서 한다 (자동 진행 시간대와 상관없이 바로 시작)."""
    job = load_job(job_id)
    if not job or job['status'] in ('cancelled', 'done'):
        raise ValueError('이어갈 수 없는 작업이에요')
    job['user_paused'] = False
    open_work = any(r.get('status') in ('pending', 'revise', 'running') for r in (job.get('roles') or {}).values())
    if job['status'] in ('paused', 'waiting_limit', 'failed') or (job['status'] == 'review' and open_work):
        job['status'], job['phase'], job['error'], job['resume_at'], job['run_now'] = 'queued', '', '', None, True
    log_event(job, '▶ 이어서 진행해요')
    save_job(job)
    chat_add(job_id, 'system', 'all', '▶ 이어서 진행해요', 'status')
    return job


def set_global_pause(on: bool) -> dict:
    """모든 작업 일시정지 / 해제."""
    s = save_settings({'paused': bool(on)})
    return s


def new_job(title: str, goal: str, project_dir: str, permissions: dict | None = None) -> dict:
    title = (title or '').strip() or (goal or '').strip()[:30] or '새 작업'
    job_id = time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:4]
    job = {
        'id': job_id, 'slug': _slugify(title) + '-' + job_id[-4:],
        'title': title, 'goal': (goal or '').strip(), 'project_dir': os.path.abspath(os.path.expanduser(project_dir)),
        'created': _now_ts(), 'updated': _now_ts(),
        'status': 'draft', 'phase': '', 'busy': False, 'busy_msg': '',
        'permissions': {'web': False, **(permissions or {})},
        'extra_requests': [], 'apply_mode': '', 'run_mode': '',          # 빈 값 = 설정을 따른다
        'interview': {'round': 0, 'round_base': 0, 'ready': False, 'understanding': '', 'questions': [], 'answers': {}, 'history': []},
        'requirements': '',
        'plan': None, 'roles': {},
        'branch': '', 'base_ref': '', 'workdir': '', 'created_repo': False,
        'resume_at': None, 'error': '', 'cost_usd': 0.0, 'report': '', 'events': [],
    }
    log_event(job, '작업을 만들었어요')
    save_job(job)
    return job


# ══════════════════════════════════════════════════════════════
# Claude 실행
# ══════════════════════════════════════════════════════════════

class ClaudeNotFound(Exception):
    pass


class RateLimited(Exception):
    def __init__(self, resume_at: float | None, text: str = ''):
        super().__init__(text)
        self.resume_at = resume_at
        self.text = text


class Cancelled(Exception):
    pass


class ClaudeFailed(Exception):
    pass


def find_claude(settings: dict | None = None) -> str:
    s = settings or load_settings()
    if s.get('claude_path') and os.path.exists(s['claude_path']):
        return s['claude_path']
    env = os.environ.get('BUNI_CLAUDE')
    if env and os.path.exists(env):
        return env
    home = os.path.expanduser('~')
    names = ['claude.exe', 'claude.cmd', 'claude'] if IS_WIN else ['claude']
    dirs = [os.path.join(home, '.local', 'bin'), os.path.join(home, '.claude', 'local'),
            os.path.join(home, '.npm-global', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin']
    if IS_WIN:
        dirs += [os.path.join(os.environ.get('APPDATA', ''), 'npm'),
                 os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'claude'),
                 os.path.join(os.environ.get('LOCALAPPDATA', ''), 'AnthropicClaude')]
    for d in dirs:
        for n in names:
            p = os.path.join(d, n)
            if os.path.isfile(p):
                return p
    found = shutil.which('claude')
    if found:
        return found
    raise ClaudeNotFound('Claude Code(claude 명령)를 찾지 못했어요. 먼저 설치해 주세요.')


_LIMIT_RE = re.compile(r'(usage limit|rate limit|limit reached|hit your limit|you.ve hit|too many requests|overloaded_error|429)', re.I)


def parse_reset_time(text: str, now: float | None = None) -> float | None:
    """한도 오류 문구에서 '언제 풀리는지'를 읽는다. 못 읽으면 None."""
    now = now if now is not None else _now_ts()
    m = re.search(r'\|(\d{10})\b', text or '')               # "...limit reached|1760000000"
    if m:
        return float(m.group(1))
    m = re.search(r'resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b', text or '', re.I)
    if m:                                                    # "resets 3am"
        h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3).lower()
        h = h % 12 + (12 if ap == 'pm' else 0)
        dt = datetime.datetime.fromtimestamp(now).replace(hour=h, minute=mi, second=0, microsecond=0)
        if dt.timestamp() <= now:
            dt += datetime.timedelta(days=1)
        return dt.timestamp()
    m = re.search(r'resets?\s+(?:at\s+)?(\d{1,2}):(\d{2})\b', text or '', re.I)
    if m:                                                    # "resets 15:00"
        dt = datetime.datetime.fromtimestamp(now).replace(hour=int(m.group(1)) % 24, minute=int(m.group(2)),
                                                          second=0, microsecond=0)
        if dt.timestamp() <= now:
            dt += datetime.timedelta(days=1)
        return dt.timestamp()
    return None


def extract_json(text: str):
    """모델 답에서 첫 JSON 객체를 꺼낸다 (코드 펜스·앞뒤 설명이 붙어 있어도)."""
    if not text:
        return None
    t = text.strip()
    fence = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', t, re.S)
    if fence:
        t = fence.group(1)
    try:
        return json.loads(t)
    except ValueError:
        pass
    start = t.find('{')
    while start != -1:
        depth, in_str, esc = 0, False, False
        for i in range(start, len(t)):
            c = t[i]
            if in_str:
                if esc:
                    esc = False
                elif c == '\\':
                    esc = True
                elif c == '"':
                    in_str = False
                continue
            if c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(t[start:i + 1])
                    except ValueError:
                        break
        start = t.find('{', start + 1)
    return None


# 사람이 없을 때 허용하는 명령 — 읽기·테스트·빌드 위주. 삭제·설치·외부 전송·git 변경은 넣지 않는다.
# 어떤 역할이든 쓸 수 있는 읽기 전용 명령 — `cd x && grep … | head` 처럼 이어 붙인 명령은 조각마다 허용돼야 해서 흔한 것을 넉넉히 둔다
READ_BASH = [
    'cd *', 'pwd', 'ls*', 'cat *', 'head*', 'tail*', 'wc*', 'grep*', 'egrep*', 'fgrep*', 'sort*', 'uniq*', 'cut *', 'tr *', 'nl *',
    'diff*', 'cmp *', 'echo*', 'printf*', 'test *', '[ *', 'true', 'date*', 'which *', 'file *', 'stat *', 'tree*', 'basename *',
    'dirname *', 'realpath *', 'readlink *', 'jq*', 'sed -n*', 'awk*', 'find *', 'xargs grep*', 'xargs wc*', 'xargs ls*',
    'git status*', 'git diff*', 'git log*', 'git show*', 'git branch', 'git branch -a*', 'git branch -v*', 'git branch --list*',
    'git branch --show-current', 'git remote -v', 'git rev-parse*', 'git ls-files*', 'git ls-tree*', 'git blame*', 'git cat-file*',
    'git describe*', 'git shortlog*', 'git config --get*', 'git stash list*', 'git worktree list*',
]
# 확인용: 시험·빌드·문법 검사 (문서·검수 역할도 돌려 봐야 "확인했다"고 말할 수 있다)
CHECK_BASH = [
    'npm test*', 'npm run test*', 'npm run build*', 'npm run lint*', 'npm run typecheck*', 'npx tsc*',
    'pnpm test*', 'pnpm run test*', 'pnpm run build*', 'yarn test*', 'yarn build*',
    'pytest*', 'python -m pytest*', 'python3 -m pytest*', 'python -m unittest*', 'python3 -m unittest*',
    'python -m py_compile*', 'python3 -m py_compile*', 'python3 tests/*', 'python3 -m compileall*', 'ruff check*', 'mypy*',
    'swift build*', 'swift test*', 'swiftc *', 'xcodebuild -list*', 'cargo test*', 'cargo build*', 'cargo check*',
    'go test*', 'go build*', 'go vet*', 'make test*', 'make build*', 'make check*', 'mvn test*', 'gradle test*', './gradlew test*',
    './build_app.sh', 'bash build_app.sh', 'bash ./build_app.sh', './build_app.sh 2>&1*', './build_app.sh --no-install*',
]
# 코드를 고치는 역할만: 파일 만들기·복사·옮기기, 스크립트 실행
CODE_BASH = [
    'mkdir *', 'touch *', 'cp *', 'mv *', 'chmod +x *',
    'python3 *', 'python *', 'node *', 'cat > *', 'cat >> *', 'tee *',        # 스크립트는 python·node 만 — bash·sh 로 아무 명령이나 돌리는 건 막아 둔다
]
SAFE_BASH = READ_BASH + CHECK_BASH            # (이전 이름 호환)
DENY_BASH = [
    'rm *', 'rm', 'rmdir *', 'del *', 'sudo *', 'su *', 'chown *', 'mkfs*', 'dd *', 'kill *', 'pkill *', 'killall *',
    'curl *', 'wget *', 'ssh *', 'scp *', 'rsync *', 'nc *', 'ncat *', 'ftp *', 'telnet *',
    'find * -delete*', 'find * -exec*', 'find * -ok*',
    'git push*', 'git reset*', 'git clean*', 'git checkout*', 'git switch*', 'git rebase*', 'git merge*', 'git stash drop*', 'git stash pop*',
    'git stash push*', 'git stash save*', 'git remote add*', 'git remote set*', 'git remote remove*', 'git config --global*', 'git config --unset*',
    'git commit*', 'git add*', 'git tag*', 'git branch -D*', 'git branch -d*', 'git branch -m*', 'git branch -M*', 'git worktree add*', 'git worktree remove*',
    'npm install*', 'npm i *', 'npm i', 'npm publish*', 'npm exec*', 'pnpm install*', 'pnpm add*', 'yarn add*', 'yarn install*',
    'pip install*', 'pip3 install*', 'pip uninstall*', 'brew *', 'apt *', 'apt-get *', 'gem install*', 'cargo install*', 'go install*',
    'launchctl *', 'systemctl *', 'defaults *', 'osascript *', 'open *', 'shutdown*', 'reboot*', 'format *', 'reg *', 'powershell*',
    './build_app.sh --install*', 'bash build_app.sh --install*', 'bash ./build_app.sh --install*', './release.sh*', 'bash release.sh*', 'bash ./release.sh*',
]


def permission_args(role_kind: str, slug: str, web: bool) -> tuple:
    """역할 종류별 (허용 도구 목록, 금지 도구 목록).
    role_kind: 'readonly'(조사·검토) / 'docs'(문서 산출) / 'code'(프로젝트 수정)
    모든 역할이 읽기·시험·빌드 명령은 돌려 볼 수 있어야 "확인했다"고 보고할 수 있다. 파일을 고치는 건 종류별로 다르다."""
    allowed = ['Read', 'Glob', 'Grep'] + [f'Bash({c})' for c in READ_BASH + CHECK_BASH]
    if role_kind == 'docs':
        allowed += [f'Write(.buni-team/{slug}/**)', f'Edit(.buni-team/{slug}/**)']
    elif role_kind == 'code':
        allowed += ['Write', 'Edit', 'MultiEdit'] + [f'Bash({c})' for c in CODE_BASH]
    if web:
        allowed += ['WebSearch', 'WebFetch']
    denied = [f'Bash({c})' for c in DENY_BASH]
    if not web:
        denied += ['WebFetch', 'WebSearch']
    return allowed, denied


# ══════════════════════════════════════════════════════════════
# 세션 기록 · 실시간 활동 (화면과 Claude 에서 진행을 볼 수 있게)
# ══════════════════════════════════════════════════════════════

def _key_file(key: str) -> str:
    return re.sub(r'[^A-Za-z0-9_-]', '_', str(key or 'lead'))[:40] or 'lead'


def _sessions_path(job_id: str) -> str:
    return job_path(job_id, 'sessions.jsonl')


def record_session(job_id: str, **entry):
    """세션 기록을 한 줄 덧붙인다 (덧붙이기만 해서 job.json 을 쓰는 쪽과 부딪히지 않는다)."""
    try:
        with open(_sessions_path(job_id), 'a', encoding='utf-8') as f:
            f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    except OSError:
        pass


def find_job_for_session(session_id: str) -> str | None:
    """이 세션(claude 한 번 실행)이 어느 스쿼드 작업의 것인지 — 부니 완료 말풍선에서 결과로 바로 가는 데 쓴다."""
    if not session_id:
        return None
    try:
        names = sorted(os.listdir(jobs_dir()), reverse=True)
    except OSError:
        return None
    for name in names:
        try:
            with open(os.path.join(jobs_dir(), name, 'sessions.jsonl'), encoding='utf-8') as f:
                if session_id in f.read():
                    return name
        except OSError:
            continue
    return None


def load_sessions(job_id: str) -> list:
    """세션 목록 — 시작/끝 기록을 id 별로 합쳐 시작 순서대로."""
    out, order = {}, []
    try:
        with open(_sessions_path(job_id), encoding='utf-8') as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                sid = e.get('id')
                if not sid:
                    continue
                if sid not in out:
                    out[sid] = {}
                    order.append(sid)
                out[sid].update(e)
    except OSError:
        return []
    return [out[i] for i in order]


class ActivityLog:
    """한 세션이 지금 뭘 하는지(도구 사용·말)를 최근 몇 줄만 파일에 적어 둔다 — 화면이 읽어 보여 준다."""
    MAX = 60

    def __init__(self, job_id: str, key: str):
        self.path = job_path(job_id, f'activity-{_key_file(key)}.json')
        self.lines: list = []
        self._last_write = 0.0
        self._state = 'running'
        try:
            with open(self.path, encoding='utf-8') as f:
                self.lines = json.load(f).get('lines', [])[-self.MAX:]
        except (OSError, ValueError):
            pass

    def add(self, text: str, force: bool = False):
        self.lines.append({'ts': _now_ts(), 'text': text})
        del self.lines[:-self.MAX]
        if force or time.time() - self._last_write >= 0.6:
            self.flush()

    def finish(self, ok: bool = True):
        self._state = 'done' if ok else 'stopped'
        self.flush()

    def flush(self):
        self._last_write = time.time()
        try:
            _atomic_write(self.path, json.dumps({'lines': self.lines, 'state': self._state,
                                                 'updated': _now_ts()}, ensure_ascii=False))
        except OSError:
            pass


def load_activity(job_id: str, key: str) -> dict:
    try:
        with open(job_path(job_id, f'activity-{_key_file(key)}.json'), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {'lines': [], 'state': '', 'updated': 0}


def _short(text, n=70) -> str:
    text = ' '.join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + '…'


def _tool_summary(name: str, inp: dict) -> str:
    arg = ''
    for k in ('file_path', 'path', 'pattern', 'command', 'query', 'url', 'description'):
        if inp.get(k):
            arg = str(inp[k])
            if k in ('file_path', 'path'):
                arg = os.path.basename(arg.rstrip('/')) or arg
            break
    return f'{name} {_short(arg)}'.strip()


def _activity_lines(ev: dict) -> list:
    """stream-json 이벤트 하나에서 사람이 읽을 활동 줄을 뽑는다."""
    out = []
    if ev.get('type') == 'assistant':
        for b in (ev.get('message') or {}).get('content') or []:
            if b.get('type') == 'tool_use':
                out.append('🔧 ' + _tool_summary(str(b.get('name') or ''), b.get('input') or {}))
            elif b.get('type') == 'text' and str(b.get('text') or '').strip():
                txt = str(b['text']).strip()
                if txt[0] in '{[`':                           # 팀장이 내는 JSON 원문은 보여 줄 필요가 없다
                    out.append('✍️ 정리한 내용을 내는 중')
                else:
                    out.append('💬 ' + _short(txt, 140))
    return out


def open_session_in_terminal(job_id: str, session_id: str) -> bool:
    """그 세션을 터미널에서 `claude --resume` 으로 열어 Claude 에서 이어 보게 한다."""
    job = load_job(job_id)
    if not job:
        return False
    entry = next((e for e in load_sessions(job_id) if e.get('id') == session_id), {})
    cwd = entry.get('cwd') or job.get('workdir') or job['project_dir']
    if not os.path.isdir(cwd):
        cwd = job['project_dir'] if os.path.isdir(job['project_dir']) else os.path.expanduser('~')
    exe = find_claude(load_settings())
    if IS_WIN:
        subprocess.Popen(['cmd', '/k', f'cd /d "{cwd}" && "{exe}" --resume {session_id}'], creationflags=0x00000010)
        return True
    path = os.path.join(tempfile.gettempdir(), f'buni-resume-{session_id[:8]}.command')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(f'#!/bin/bash\ncd "{cwd}" || exit 1\n"{exe}" --resume {session_id}\n')
    os.chmod(path, 0o755)
    subprocess.Popen(['/usr/bin/open', path])
    return True



# ══════════════════════════════════════════════════════════════
# 스쿼드 부니 — 팀원 세션마다 부니가 생기지 않게 하고(훅이 BUNI_TEAM_RUN 세션은 건너뜀),
# 스쿼드 전체를 '팀장 부니' 하나가 대신 보여 준다: 진행 중이면 일하는 모습, 다 끝나면 완료 말풍선(→ 스쿼드 결과 보기).
# 부니 앱이 읽는 이벤트 파일(훅이 쓰는 것과 같은 형식)을 엔진이 직접 적는다.
# ══════════════════════════════════════════════════════════════

_sq_lock = threading.Lock()
_sq_active: dict = {}


def squad_session_id(job_id: str) -> str:
    return 'squad-' + job_id


def squad_events_path(job_id: str) -> str:
    if os.environ.get('BUNI_TEAM_HOME'):                     # 시험·개발용 별도 홈 — 실제 부니가 읽는 /tmp 에는 절대 쓰지 않는다 (안 그러면 시험마다 부니가 새로 생긴다)
        d = os.path.join(os.environ['BUNI_TEAM_HOME'], 'buni-events')
        os.makedirs(d, exist_ok=True)
        return os.path.join(d, f'claude-companion-events-{squad_session_id(job_id)}.jsonl')
    base = (os.environ.get('TEMP') or os.environ.get('TMP') or 'C:/temp') if IS_WIN else '/tmp'
    return os.path.join(base, f'claude-companion-events-{squad_session_id(job_id)}.jsonl')


def squad_buni_event(job_id: str, typ: str, **kw):
    if typ in ('done', 'notification', 'tool_done') and not os.path.exists(squad_events_path(job_id)):
        return                                              # 일한 적 없는 작업의 '끝났다' 알림이 새 부니를 만들지 않게
    try:
        with open(squad_events_path(job_id), 'a', encoding='utf-8') as f:
            f.write(json.dumps({'type': typ, 'ts': time.time(), **kw}, ensure_ascii=False) + '\n')
    except OSError:
        pass


def squad_run_begin(job_id: str, label: str):
    """팀장·팀원 Claude 세션이 하나 시작될 때 — 팀장 부니가 일하는 중으로 보이게."""
    sid = squad_session_id(job_id)
    with _sq_lock:
        _sq_active[job_id] = _sq_active.get(job_id, 0) + 1
    if not any(s.get('id') == sid for s in load_sessions(job_id)):     # '스쿼드 결과 보기' 버튼이 이 부니 → 작업을 찾을 수 있게
        record_session(job_id, id=sid, key='squad', label='🐰 스쿼드 (팀장 부니)', cwd='', started=_now_ts())
    tail = (label or '').split(' · ')[-1].strip() or '팀원'
    squad_buni_event(job_id, 'tool_use', tool=f'squad:🐰 {tail} 진행 중')


def squad_run_end(job_id: str):
    with _sq_lock:
        _sq_active[job_id] = max(0, _sq_active.get(job_id, 0) - 1)
    squad_buni_event(job_id, 'tool_done')
    squad_maybe_done(job_id)


def squad_maybe_done(job_id: str, notice: str = ''):
    """모든 세션이 끝났고 작업도 더는 돌고 있지 않을 때만 — 팀장 부니가 끝났다고 알린다."""
    with _sq_lock:
        if _sq_active.get(job_id, 0) > 0:
            return
    job = load_job(job_id)
    if job and job.get('status') == 'running':
        return
    if notice:
        squad_buni_event(job_id, 'notification', message=notice[:120])
    squad_buni_event(job_id, 'done')



# 모든 스쿼드 세션에 덧붙이는 도구 사용 요령 — 실제 시험에서 `cd … && 쓰기` 나 `> 파일` 리다이렉트는 사람이 없을 때 거절됐다
TOOL_TIPS = (
    "[도구 사용 요령 — 사람이 없어서 허용 목록에 없는 명령은 거절됩니다]\n"
    "- 이미 프로젝트 작업 폴더 안에서 실행 중입니다. `cd` 로 이동하지 마세요(특히 `cd … && mkdir/cp/mv …` 는 거절됩니다). 경로는 상대 경로로 쓰세요.\n"
    "- 파일을 만들거나 고칠 때는 셸의 `>`·`>>`·heredoc(`cat > f <<EOF`) 대신 Write/Edit 도구를 쓰세요.\n"
    "- 확인은 직접 돌려서 하세요: `swift build`, `python3 -m unittest discover -s tests -p 'test_*.py'`, `python3 -m py_compile …`, `./build_app.sh`(설치 옵션 없이). "
    "`git status`·`git diff`·`git log` 도 됩니다. 커밋·브랜치 이름 바꾸기·설치(--install)·삭제·네트워크 명령은 엔진이 따로 처리하니 시도하지 마세요.\n"
    "- 어떤 명령이 거절되면 같은 명령을 반복하지 말고, 다른 도구(Read/Grep/Glob/Write/Edit)로 같은 목적을 이루거나, 못 한 사실과 이유를 보고서에 그대로 적으세요.\n"
)


class ClaudeRunner:
    """`claude -p` 를 한 번 실행해서 결과를 돌려준다. 취소하면 프로세스를 끝낸다."""

    def __init__(self, settings: dict | None = None):
        self.settings = settings or load_settings()
        self._procs: set = set()
        self._lock = threading.Lock()
        self.cancelled = threading.Event()

    def cancel(self):
        self.cancelled.set()
        with self._lock:
            procs = list(self._procs)
        for p in procs:
            _terminate(p)

    def run(self, prompt: str, cwd: str, *, role_kind: str = 'readonly', slug: str = '', web: bool = False,
            name: str = '', system_append: str = '', timeout: int = 3600, log_path: str | None = None,
            readonly_tools: bool = True, track: dict | None = None, model: str = '') -> dict:
        """결과 dict(result, cost, session_id, denials). 한도면 RateLimited, 취소면 Cancelled.
        track={'job_id','key','label'} 를 주면 세션을 기록하고 진행 상황(활동)을 파일에 적는다."""
        if self.cancelled.is_set():
            raise Cancelled()
        exe = find_claude(self.settings)
        session_id = str(uuid.uuid4())
        cmd = [exe, '-p', '--output-format', 'stream-json', '--verbose', '--session-id', session_id,
               '--strict-mcp-config', '--permission-mode', 'dontAsk', '--permission-prompts', 'none']
        allowed, denied = permission_args(role_kind, slug, web)
        cmd += ['--allowedTools', ','.join(allowed), '--disallowedTools', ','.join(denied)]
        if name:
            cmd += ['--name', name]
        use_model = _clean_model(model)
        if not use_model:                                          # 팀장 세션은 팀장 모델, 나머지는 기본 모델
            lead_side = bool(track) and track.get('key') in ('lead', 'interview')
            use_model = _clean_model(self.settings.get('lead_model') if lead_side else '') or _clean_model(self.settings.get('model'))
        if use_model:
            cmd += ['--model', use_model]
        cmd += ['--append-system-prompt', ((system_append + '\n\n') if system_append else '') + TOOL_TIPS]
        env = dict(os.environ)
        env['BUNI_TEAM_RUN'] = '1'
        creation = 0x08000000 if IS_WIN else 0            # CREATE_NO_WINDOW
        activity = None
        if track:
            activity = ActivityLog(track['job_id'], track.get('key', 'lead'))
            activity.add('— ' + (track.get('label') or name or '세션') + ' 시작 —', force=True)
            record_session(track['job_id'], id=session_id, key=track.get('key', 'lead'),
                           label=track.get('label') or name, cwd=cwd, started=_now_ts())
            squad_run_begin(track['job_id'], track.get('label') or name)
        proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env, creationflags=creation,
                                **({} if IS_WIN else {'start_new_session': True}))
        with self._lock:
            self._procs.add(proc)
        timer = threading.Timer(timeout, lambda: _terminate(proc))
        timer.daemon = True
        timer.start()

        def feed():                                                # 큰 프롬프트도 막히지 않게 따로 쓴다
            try:
                proc.stdin.write(prompt.encode('utf-8'))
                proc.stdin.close()
            except OSError:
                pass
        threading.Thread(target=feed, daemon=True).start()
        err_box: list = []
        threading.Thread(target=lambda: err_box.append(proc.stderr.read()), daemon=True).start()
        result_ev, last_json, raw_tail = None, None, []
        try:
            for raw in proc.stdout:
                line = raw.decode('utf-8', 'replace').strip()
                if not line:
                    continue
                raw_tail.append(line)
                del raw_tail[:-5]
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(ev, dict):
                    continue
                last_json = ev
                if ev.get('type') == 'result':
                    result_ev = ev
                elif activity:
                    for text in _activity_lines(ev):
                        activity.add(text)
            proc.wait()
        finally:
            timer.cancel()
            with self._lock:
                self._procs.discard(proc)
            if track:
                squad_run_end(track['job_id'])
        cancelled = self.cancelled.is_set()
        if activity:
            activity.finish(ok=not cancelled)
            record_session(track['job_id'], id=session_id, finished=_now_ts(), ok=not cancelled)
        if cancelled:
            raise Cancelled()
        time.sleep(0.05)                                           # stderr 읽기 스레드가 마무리되게
        out = '\n'.join(raw_tail)
        err = (err_box[0] if err_box else b'').decode('utf-8', 'replace')
        if log_path:
            try:
                with open(log_path, 'a', encoding='utf-8') as f:
                    f.write(f'\n===== {time.strftime("%Y-%m-%d %H:%M:%S")} {name} (exit {proc.returncode}) =====\n'
                            f'{json.dumps(result_ev, ensure_ascii=False) if result_ev else out}\n{err}\n')
            except OSError:
                pass
        data = result_ev or (last_json if isinstance(last_json, dict) and 'result' in last_json else None)
        if not isinstance(data, dict):
            blob = (out + '\n' + err)
            if _LIMIT_RE.search(blob):
                raise RateLimited(parse_reset_time(blob), blob[-300:])
            raise ClaudeFailed((err or out or f'exit {proc.returncode}').strip()[-400:])
        text = str(data.get('result') or '')
        if data.get('is_error'):
            if _LIMIT_RE.search(text) or data.get('api_error_status') in (429, 529):
                raise RateLimited(parse_reset_time(text), text)
            raise ClaudeFailed(text[-400:] or 'Claude 오류')
        return {'result': text, 'cost': float(data.get('total_cost_usd') or 0.0),
                'session_id': data.get('session_id') or session_id,
                'denials': data.get('permission_denials') or []}


def _terminate(proc):
    try:
        if IS_WIN:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(proc.pid)], capture_output=True,
                           creationflags=0x08000000)
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


# ══════════════════════════════════════════════════════════════
# 프롬프트
# ══════════════════════════════════════════════════════════════

INTERVIEW_PROMPT = """당신은 '사전요구서 담당자'입니다.
사용자가 아래 작업을 맡겼고, 이 작업은 사람이 없는 새벽에 팀이 끝까지 해냅니다. 새벽에는 아무에게도 질문할 수 없으므로,
시작하기 전에 불확실한 것을 모두 없애야 합니다.

[작업 제목] {title}
[맡긴 내용] {goal}
{extra}[프로젝트 폴더] {project} (이 폴더 안은 Read/Glob/Grep 으로 읽어 파악할 수 있습니다)
{previous}{history}
할 일:
1. 프로젝트 폴더가 있으면 먼저 훑어서 이미 알 수 있는 것(언어, 구조, 스타일, 기존 문서)은 질문하지 마세요.
2. 결과의 방향이 달라지는 불확실한 점만 질문하세요. 한 번에 최대 {max_q}개, 각 질문에는 객관식 보기(options)와 추천 기본값(default)을 함께 주세요.
3. 이미 충분하면 ready 를 true 로 하고 questions 는 빈 배열로 두세요.
4. [사용자가 나중에 추가한 요청]이 있으면 그 요청 때문에 새로 생기는 불확실한 점을 질문하세요. 이미 답을 받은 질문은 다시 묻지 마세요.
{final_note}
반드시 아래 JSON 한 덩어리만 출력하세요 (다른 설명 금지):
{{"ready": false, "understanding": "작업을 이해한 내용 2~3문장", "questions": [{{"id": "q1", "question": "...", "why": "이게 왜 필요한지 한 줄", "options": ["보기1", "보기2"], "default": "추천 기본값"}}]}}
"""

REQUIREMENTS_PROMPT = """당신은 '사전요구서 담당자'입니다. 아래 정보로 팀이 새벽에 질문 없이 일할 수 있는 '사전요구서'를 마크다운으로 작성하세요.
머리말 없이 문서 본문만 출력하세요.

[작업 제목] {title}
[맡긴 내용] {goal}
{extra}[프로젝트 폴더] {project}
{previous}[작업을 이해한 내용] {understanding}
[사용자와 주고받은 질문·답변]
{qa}

문서는 반드시 아래 순서와 제목을 따르세요.
# 사전요구서: {title}
## 1. 목표
## 2. 결과물 (무엇을·어떤 형식으로·어디에 둘지)
## 3. 완료 기준 (체크리스트로, 검토자가 O/X 로 확인할 수 있게)
## 4. 범위 (포함 / 제외)
## 5. 제약과 선호 (기술·스타일·말투 등)
## 6. 결정 사항 (사용자가 직접 답한 것)
## 7. 가정 (답이 없어 기본값으로 정한 것 — 틀렸을 때 고치기 쉽게 표시)
## 8. 막혔을 때 규칙 (질문하지 말고 가장 안전한 쪽으로 진행하고 가정에 기록한다. 끝내 못 하는 건 건너뛰고 보고서에 적는다)
## 9. 허용 범위 (프로젝트 폴더 안에서만 작업한다. 파일 삭제·프로그램 설치·외부 전송 금지. 웹 검색: {web})
"""

PLAN_PROMPT = """당신은 이 작업의 '팀장'입니다. 아래 사전요구서를 보고, 필요한 역할만으로 팀을 짜서 업무를 나누세요.

{requirements}

규칙:
- 역할은 2~5개. 꼭 필요한 역할만 두세요 (예: 기획, 디자인, 개발, 마케팅, 문서, QA …). 작업에 필요 없는 역할은 만들지 마세요.
- 역할마다 kind 를 정하세요: "docs"(문서·카피·기획·디자인 명세 등 문서로 산출), "code"(프로젝트의 파일을 직접 수정), "readonly"(조사·검토만).
  code 역할은 프로젝트를 직접 고치므로 서로 동시에 돌리지 않고 순서대로 진행됩니다.
- depends_on 에는 먼저 끝나야 하는 역할의 id 를 적으세요 (없으면 빈 배열).
- 각 역할의 산출물은 .buni-team/{slug}/<역할id>/ 폴더에 둡니다 (code 역할은 프로젝트 파일 수정 + 그 폴더에 작업 요약 NOTES.md).
- id 는 영문 소문자·숫자·밑줄만 쓰세요.

아래 JSON 한 덩어리만 출력하세요:
{{"summary": "팀 구성과 진행 방식을 2~3문장으로", "roles": [{{"id": "design", "name": "디자이너", "icon": "🎨", "kind": "docs", "mission": "이 역할이 해야 할 일 (구체적으로)", "deliverable": "산출물 설명", "depends_on": []}}]}}
"""

WORKER_PROMPT = """당신은 이 팀의 '{name}'입니다. 팀장이 맡긴 일을 사람의 도움 없이 끝까지 해내세요.

[전체 사전요구서]
{requirements}

[팀 구성] {team}

[당신의 업무]
{mission}
산출물: {deliverable}

{deps}{feedback}
규칙:
- 질문하지 마세요. 불확실하면 사전요구서의 '막혔을 때 규칙'을 따라 가장 안전한 쪽으로 정하고, 정한 내용을 .buni-team/{slug}/{rid}/ASSUMPTIONS.md 에 적으세요.
- 산출물은 .buni-team/{slug}/{rid}/ 폴더에 만드세요.{code_note}
- 허용되지 않는 명령은 자동으로 거절됩니다. 거절되면 우회하지 말고 그 사실을 NOTES.md 에 적고 다른 방법으로 진행하세요.
- 끝나면 마지막 답변에 한 문단으로 '무엇을 만들었고 어디에 있는지'만 적으세요.
"""

REVIEW_PROMPT = """당신은 이 작업의 '팀장'입니다. 팀원들의 결과물을 사전요구서의 완료 기준에 비춰 검토하세요.

[사전요구서]
{requirements}

[검토할 역할] {names}
각 역할의 산출물은 .buni-team/{slug}/<역할id>/ 에 있습니다. 파일을 직접 읽어서 확인하세요 (Read/Glob/Grep).

역할마다 판정하세요: "accept"(통과) 또는 "revise"(다시 — 무엇을 어떻게 고쳐야 하는지 구체적인 feedback 필수).
사소한 아쉬움은 통과시키고, 완료 기준을 못 채웠거나 틀린 것만 되돌리세요.

아래 JSON 한 덩어리만 출력하세요:
{{"verdicts": [{{"id": "design", "verdict": "accept", "feedback": ""}}], "summary": "검토 요약 한두 문장"}}
"""

MERGE_PROMPT = """당신은 이 작업의 '팀장'입니다. 팀원들의 결과물을 합쳐 최종 결과물을 만드세요.

[사전요구서]
{requirements}

[팀원 산출물] .buni-team/{slug}/<역할id>/ 폴더들: {names}
파일을 읽고, 사전요구서의 '결과물' 항목에 맞는 최종 결과물을 .buni-team/{slug}/FINAL.md 로 작성하세요
(필요하면 팀원 산출물을 요약·인용·연결해서 하나의 문서로). 코드 변경은 이미 프로젝트에 반영되어 있으니 FINAL.md 에 무엇이 바뀌었는지 설명하세요.

그리고 .buni-team/{slug}/REPORT.md 를 작성하세요 — 사용자가 아침에 5분 안에 검토할 보고서입니다:
1. 한 줄 결과  2. 완료 기준 체크리스트(O/X 와 근거)  3. 만든 것과 위치  4. 가정한 것(틀렸다면 고칠 곳)  5. 못 한 것·주의할 것  6. 검토하는 방법

끝나면 답변에 한 문단으로 결과를 요약하세요.
"""


# ══════════════════════════════════════════════════════════════
# 사전요구서 (인터뷰)
# ══════════════════════════════════════════════════════════════

MAX_INTERVIEW_ROUNDS = 3
ROLE_NOTE_FEEDBACK = '사용자가 새 요구사항을 전달했어요 — 아래 [사용자가 이 팀원에게 직접 전달한 요구사항]을 반영해 산출물을 고치세요.'


def _qa_text(job: dict) -> str:
    out = []
    for r in job['interview']['history']:
        for q in r.get('questions', []):
            ans = (r.get('answers') or {}).get(q['id'])
            out.append(f"Q. {q['question']}\nA. {ans if ans not in (None, '') else '(답 없음 — 기본값: ' + str(q.get('default', '')) + ')'}")
    return '\n'.join(out) or '(질문 없이 진행)'


def _extra_text(job: dict) -> str:
    items = [str(e.get('text', '')).strip() for e in job.get('extra_requests') or [] if str(e.get('text', '')).strip()]
    if not items:
        return ''
    return '[사용자가 나중에 추가한 요청]\n' + '\n'.join(f'- {t}' for t in items) + '\n'


def _previous_text(job: dict) -> str:
    prev = (job.get('requirements') or '').strip()
    if not prev:
        return ''
    return ('[기존 사전요구서 — 사용자가 직접 고친 내용이 섞여 있을 수 있어요. 유지할 것은 유지하고, 추가한 요청과 새 답변을 반영해 갱신하세요]\n'
            + prev + '\n')


def _save_keep_cancel(job: dict):
    """저장하되, 그 사이 사용자가 취소했다면 취소 상태를 덮어쓰지 않는다."""
    cur = load_job(job['id'])
    if cur and cur.get('status') == 'cancelled':
        job['status'] = 'cancelled'
    save_job(job)


def start_interview(job_id: str, runner: ClaudeRunner | None = None) -> dict:
    """첫 질문을 만든다 (또는 이미 충분하면 바로 요구서 작성 단계로)."""
    job = load_job(job_id)
    job['status'], job['busy'], job['busy_msg'] = 'interviewing', True, '질문을 정리하는 중…'
    job['error'] = ''
    save_job(job)
    return _interview_step(job_id, runner)


def answer_interview(job_id: str, answers: dict, runner: ClaudeRunner | None = None) -> dict:
    """사용자 답을 받아 다음 질문 또는 요구서를 만든다."""
    job = load_job(job_id)
    iv = job['interview']
    cur = {'questions': iv['questions'], 'answers': {str(k): str(v) for k, v in (answers or {}).items()}}
    iv['history'].append(cur)
    iv['questions'], iv['answers'] = [], {}
    job['busy'], job['busy_msg'] = True, '답변을 반영하는 중…'
    save_job(job)
    return _interview_step(job_id, runner)


def resume_interview(job_id: str, runner: ClaudeRunner | None = None) -> dict:
    """질문 정리·요구서 작성이 중간에 실패했을 때 — 처음부터인지 이어서인지 알아서 다시 시도한다."""
    job = load_job(job_id)
    if not job['interview']['history']:
        return start_interview(job_id, runner)
    job['busy'], job['busy_msg'], job['error'] = True, '다시 시도하는 중…', ''
    save_job(job)
    return _interview_step(job_id, runner)


def add_request(job_id: str, text: str, answers: dict | None = None, edited_requirements: str | None = None,
                runner: ClaudeRunner | None = None) -> dict:
    """질문 답변 중이거나 사전요구서가 나온 뒤에도 요청을 새로 추가한다 — 팀장이 그에 맞는 질문을 다시 정리한다.
    답하던 질문이 있으면 지금까지 적은 답(비운 건 추천값)과 함께 기록한다. 고치던 요구서가 있으면 그 내용을 보존한다."""
    text = (text or '').strip()
    if not text:
        raise ValueError('추가할 요청을 입력해 주세요')
    job = load_job(job_id)
    if job['status'] not in ('draft', 'interviewing', 'review_requirements'):
        raise ValueError('지금은 요청을 추가할 수 없어요')
    if job.get('busy'):
        raise ValueError('Claude가 작업 중이에요. 끝난 뒤에 추가해 주세요')
    iv = job['interview']
    if job['status'] == 'review_requirements' and edited_requirements and edited_requirements.strip():
        job['requirements'] = edited_requirements.strip()
        _atomic_write(job_path(job['id'], 'requirements.md'), job['requirements'] + '\n')
    if iv['questions']:
        iv['history'].append({'questions': iv['questions'],
                              'answers': {str(k): str(v) for k, v in (answers or {}).items()}})
        iv['questions'], iv['answers'] = [], {}
    job.setdefault('extra_requests', []).append({'text': text, 'ts': _now_ts()})
    iv['round_base'] = len(iv['history'])                  # 추가 요청마다 질문 라운드를 새로 센다
    iv['ready'] = False
    job['status'], job['error'] = 'interviewing', ''
    job['busy'], job['busy_msg'] = True, '추가한 요청을 반영해 질문을 다시 정리하는 중…'
    log_event(job, '요청을 추가했어요: ' + (text if len(text) <= 40 else text[:38] + '…'))
    save_job(job)
    return _interview_step(job_id, runner)


def restart_interview(job_id: str, runner: ClaudeRunner | None = None) -> dict:
    """사전요구서를 버리고 질문부터 다시 받는다."""
    job = load_job(job_id)
    job['interview'].update(round=0, round_base=0, ready=False, questions=[], answers={}, history=[], understanding='')
    job['extra_requests'] = []
    job['requirements'], job['status'], job['error'] = '', 'draft', ''
    save_job(job)
    return start_interview(job_id, runner)


def _interview_step(job_id: str, runner: ClaudeRunner | None) -> dict:
    job = load_job(job_id)
    runner = runner or ClaudeRunner()
    iv = job['interview']
    stop_watch = threading.Event()

    def _watch_cancel():                                         # 사용자가 취소하면 진행 중인 Claude 도 바로 끝낸다
        while not stop_watch.wait(2.0):
            cur = load_job(job_id)
            if cur and cur.get('status') == 'cancelled':
                runner.cancel()
                return
    threading.Thread(target=_watch_cancel, daemon=True).start()
    try:
        iv['round'] = len(iv['history']) + 1
        last = (len(iv['history']) - iv.get('round_base', 0) + 1) >= MAX_INTERVIEW_ROUNDS
        history = ''
        if iv['history']:
            history = '\n[지금까지 주고받은 질문·답변]\n' + _qa_text(job) + '\n'
        final_note = ('이번이 마지막 라운드입니다. 남은 불확실한 점은 질문하지 말고 합리적인 기본값으로 정하세요. ready 는 true 로 하세요.\n'
                      if last else '')
        prompt = INTERVIEW_PROMPT.format(title=job['title'], goal=job['goal'], project=job['project_dir'],
                                         extra=_extra_text(job), previous=_previous_text(job),
                                         history=history, max_q=6, final_note=final_note)
        data = _ask_json(runner, prompt, job, name=f"🐰 {job['title']} · 질문 정리", key='interview')
        iv['understanding'] = str(data.get('understanding') or iv.get('understanding') or '')
        questions = []
        for i, q in enumerate(data.get('questions') or []):
            if not isinstance(q, dict) or not q.get('question'):
                continue
            questions.append({'id': str(q.get('id') or f'q{i + 1}'), 'question': str(q['question']),
                              'why': str(q.get('why') or ''), 'options': [str(o) for o in (q.get('options') or [])][:6],
                              'default': str(q.get('default') or '')})
        if bool(data.get('ready')) or not questions or last:
            iv['ready'], iv['questions'] = True, []
            job['busy_msg'] = '사전요구서를 쓰는 중…'
            _save_keep_cancel(job)
            _write_requirements(job, runner)
            job['status'] = 'review_requirements'
            log_event(job, '사전요구서가 준비됐어요 — 검토하고 승인해 주세요')
        else:
            iv['ready'], iv['questions'] = False, questions[:6]
            job['status'] = 'interviewing'
            log_event(job, f'질문 {len(iv["questions"])}개가 있어요')
    except Cancelled:
        job['status'] = 'cancelled'
    except RateLimited as e:
        job['error'] = '플랜 사용량 한도에 걸렸어요. 한도가 풀린 뒤 다시 시도해 주세요.'
        job['status'] = 'draft' if not job['interview']['history'] else 'interviewing'
    except (ClaudeFailed, ClaudeNotFound) as e:
        job['error'] = str(e)
        job['status'] = 'draft' if not job['interview']['history'] else 'interviewing'
    finally:
        stop_watch.set()
        job['busy'], job['busy_msg'] = False, ''
        _save_keep_cancel(job)
    return job


def _write_requirements(job: dict, runner: ClaudeRunner):
    prompt = REQUIREMENTS_PROMPT.format(
        title=job['title'], goal=job['goal'], project=job['project_dir'],
        extra=_extra_text(job), previous=_previous_text(job),
        understanding=job['interview'].get('understanding', ''), qa=_qa_text(job),
        web='허용' if job['permissions'].get('web') else '사용하지 않음')
    nm = f"🐰 {job['title']} · 사전요구서"
    res = runner.run(prompt, _safe_cwd(job), role_kind='readonly', slug=job['slug'],
                     name=nm, timeout=900, track={'job_id': job['id'], 'key': 'interview', 'label': nm})
    job['cost_usd'] += res['cost']
    text = res['result'].strip()
    text = re.sub(r'^```(?:markdown|md)?\s*\n|\n```\s*$', '', text)
    job['requirements'] = text
    _atomic_write(job_path(job['id'], 'requirements.md'), text + '\n')


def _safe_cwd(job: dict) -> str:
    d = job['project_dir']
    return d if os.path.isdir(d) else tempfile.gettempdir()


def _ask_json(runner: ClaudeRunner, prompt: str, job: dict, name: str, role_kind: str = 'readonly',
              cwd: str | None = None, retries: int = 1, key: str = 'lead') -> dict:
    """JSON 만 내라고 시키고, 깨졌으면 한 번 고쳐 달라고 다시 부탁한다."""
    cwd = cwd or _safe_cwd(job)
    track = {'job_id': job['id'], 'key': key, 'label': name}
    res = runner.run(prompt, cwd, role_kind=role_kind, slug=job['slug'], name=name, timeout=900,
                     log_path=job_path(job['id'], 'claude.log'), track=track)
    job['cost_usd'] += res['cost']
    data = extract_json(res['result'])
    attempt = 0
    while not isinstance(data, dict) and attempt < retries:
        attempt += 1
        res = runner.run('방금 답을 지정한 JSON 형식 한 덩어리로만 다시 출력하세요. 설명이나 코드 펜스 없이 JSON 만.\n\n'
                         + res['result'][-6000:], cwd, role_kind='readonly', slug=job['slug'], name=name,
                         timeout=600, log_path=job_path(job['id'], 'claude.log'), track=track)
        job['cost_usd'] += res['cost']
        data = extract_json(res['result'])
    if not isinstance(data, dict):
        raise ClaudeFailed('답변을 읽지 못했어요 (JSON 형식이 아니에요)')
    return data


def approve_job(job_id: str, edited_requirements: str | None = None, start_now: bool = False) -> dict:
    """사용자가 사전요구서를 승인 → 예약 대기열에 올린다. start_now 면 시간대와 상관없이 바로 시작한다."""
    job = load_job(job_id)
    if edited_requirements is not None and edited_requirements.strip():
        job['requirements'] = edited_requirements.strip()
        _atomic_write(job_path(job['id'], 'requirements.md'), job['requirements'] + '\n')
    if not job['requirements']:
        raise ValueError('사전요구서가 아직 없어요')
    job['status'], job['error'] = 'queued', ''
    if start_now:
        job['run_now'] = True
        log_event(job, '승인했어요 — 지금 바로 시작해요')
    else:
        log_event(job, '승인했어요 — 예약 시간대에 시작해요')
    save_job(job)
    return job


def add_role(job_id: str, spec: dict, managed: bool = False) -> str:
    """팀장이 채팅에서 새 팀원이 필요하다고 하면 그 자리에서 만든다 (끝난 작업이어도 된다). 만든 역할 id 를 돌려준다."""
    job = load_job(job_id)
    if not job or not job.get('plan'):
        raise ValueError('아직 팀이 꾸려지지 않았어요')
    base = re.sub(r'[^a-z0-9_]', '', str(spec.get('id') or '').lower()) or f"role{len(job['plan']['roles']) + 1}"
    rid = base
    while rid in job['roles']:
        rid += '_'
    kind = spec.get('kind') if spec.get('kind') in ('docs', 'code', 'readonly') else 'code'
    deps = [d for d in (spec.get('depends_on') or []) if d in job['roles']]
    role = {'id': rid, 'name': str(spec.get('name') or rid)[:30], 'icon': str(spec.get('icon') or '🧑‍💻')[:4], 'kind': kind,
            'mission': str(spec.get('mission') or '')[:1500], 'deliverable': str(spec.get('deliverable') or '')[:300], 'depends_on': deps,
            'model': _clean_model(spec.get('model'))}
    if managed:
        role['managed'] = True                              # 업무(task)는 부르는 쪽이 따로 만든다 — 자동으로 만들지 않는다
    job['plan']['roles'].append(role)
    job['roles'][rid] = {'status': 'pending', 'attempts': 0, 'feedback': '', 'summary': '', 'session_id': None,
                         **({'hold': True} if run_mode_of(job) == 'manual' else {})}
    log_event(job, f"새 팀원을 만들었어요: {role['icon']} {role['name']}")
    save_job(job)
    chat_add(job_id, 'lead', 'all', f"새 팀원 {role['icon']} {role['name']} 이(가) 합류했어요.", 'say')
    return rid


def resolve_role(job: dict, ref) -> str:
    """팀장이 말한 역할 이름·id 를 이 작업의 팀원 id 로 맞춘다 (대소문자·공백·'name' 으로 말한 것도). 없으면 ''."""
    ref = str(ref or '').strip()
    if not ref:
        return ''
    roles = job['plan']['roles']
    norm = lambda x: re.sub(r'[\s_\-()（）]+', '', str(x).lower())
    for r in roles:
        if ref == r['id']:
            return r['id']
    for r in roles:
        if norm(ref) in (norm(r['id']), norm(r['name'])):
            return r['id']
    return ''


def set_role_model(job_id: str, role_id: str, model: str) -> dict:
    """팀원 한 명이 쓸 모델을 바꾼다 (다음 번 실행부터 적용, 일하는 중이면 끝난 뒤). 빈 값이면 기본 모델."""
    job = load_job(job_id)
    if not job or not job.get('plan'):
        raise ValueError('아직 팀이 꾸려지지 않았어요')
    role = next((r for r in job['plan']['roles'] if r['id'] == role_id), None)
    if not role:
        raise ValueError('그 팀원을 찾지 못했어요')
    role['model'] = _clean_model(model)
    label = next((ko for mid, ko, _en in MODEL_CHOICES if mid == role['model']), role['model'] or '기본 모델')
    log_event(job, f"{role['icon']} {role['name']} 의 모델을 {label} 로 바꿨어요")
    save_job(job)
    chat_add(job_id, 'system', role_id, f'모델: {label} (다음 실행부터 적용)', 'status')
    return job


def send_role_note(job_id: str, role_id: str, text: str, by: str = 'user', task_id: str | None = None, priority: str | None = None) -> dict:
    """특정 팀원(세션)에게 요구사항을 전한다. 아직 시작 전이면 시작할 때 반영하고, 일하는 중이면 끝나는 대로,
    이미 끝났으면 다시 열어서 반영해 진행한다. 그 팀원의 산출물에 기대던 팀원도 다시 확인하게 한다."""
    text = (text or '').strip()
    if not text:
        raise ValueError('전달할 요구사항을 입력해 주세요')
    job = load_job(job_id)
    if not job or not job.get('plan') or role_id not in job.get('roles', {}):
        raise ValueError('아직 팀이 꾸려지지 않았어요')
    if job['status'] == 'cancelled':
        raise ValueError('취소된 작업이에요')
    role = next(r for r in job['plan']['roles'] if r['id'] == role_id)
    r = job['roles'][role_id]
    r.setdefault('notes', []).append({'text': text, 'ts': _now_ts()})
    st = r.get('status')
    if st == 'running':
        r['note_pending'] = True                              # 일하는 중 → 끝나는 대로 반영해서 다시
        how = '지금 하는 일이 끝나면 반영해서 다시 진행해요'
    elif st in ('done_unreviewed', 'accepted'):
        r['status'], r['feedback'] = 'revise', ROLE_NOTE_FEEDBACK
        how = '반영해서 다시 진행해요'
        todo, seen = [role_id], {role_id}
        while todo:                                           # 이 팀원 산출물에 기대던 팀원도 다시 확인
            cur = todo.pop()
            for d in job['plan']['roles']:
                if cur in d['depends_on'] and d['id'] not in seen:
                    seen.add(d['id'])
                    todo.append(d['id'])
                    dr = job['roles'][d['id']]
                    if dr.get('status') in ('done_unreviewed', 'accepted'):
                        dr['status'] = 'revise'
                        dr['feedback'] = f"앞 단계 '{role['name']}'의 산출물이 사용자 요청으로 바뀌었어요 — 새 산출물을 읽고 필요한 부분을 고치세요."
    else:
        how = '시작할 때 반영해요'
    if job['status'] in ('review', 'done'):                   # 끝난 작업을 다시 연다
        job['status'], job['phase'], job['run_now'] = 'queued', '', True
        how += ' (끝난 작업을 다시 열었어요)'
    log_event(job, f"{role['icon']} {role['name']}에게 요구사항을 보냈어요 — {how}")
    task = next((x for x in job.get('tasks', []) if x['id'] == task_id), None) if task_id else None
    if task:
        task['parts'][role_id] = _now_ts()
        task['done'].pop(role_id, None)
    elif by in ('user', 'lead'):                           # 내가 한 지시 하나 = 업무 하나
        new_task(job, _task_title(text), text, 'note', [role_id], priority or 'normal')
    save_job(job)
    chat_add(job_id, by, role_id, text, 'user' if by == 'user' else 'instruction')
    chat_add(job_id, 'system', role_id, how, 'status')
    return job


def retry_job(job_id: str) -> dict:
    """실패했거나 멈춘 작업을 다시 대기열에 올린다 (끝난 역할은 건너뛰고 이어서 한다)."""
    job = load_job(job_id)
    if job['status'] in ('failed', 'paused', 'waiting_limit', 'cancelled') and job.get('requirements'):
        job['status'], job['error'], job['resume_at'] = 'queued', '', None
        for r in job.get('roles', {}).values():
            if r.get('status') == 'running':
                r['status'] = 'pending'
        log_event(job, '다시 시도하도록 대기열에 올렸어요')
        save_job(job)
    return job


def mark_done(job_id: str) -> dict:
    """사용자가 결과를 검토했다 — 목록에서 '검토 완료'로 정리한다."""
    job = load_job(job_id)
    job['status'] = 'done'
    save_job(job)
    return job


def delete_job(job_id: str):
    """작업 기록을 지운다 (별도 작업 공간이 있었다면 함께 정리 — 만들어 둔 git 브랜치는 남긴다)."""
    job = load_job(job_id)
    if job and job.get('workdir') and os.path.abspath(job['workdir']) != os.path.abspath(job['project_dir']):
        _git(['worktree', 'remove', '--force', job['workdir']], job['project_dir'], check=False)
    if job and job.get('result_dir') and os.path.isdir(job['result_dir']):
        _git(['worktree', 'remove', '--force', job['result_dir']], job['project_dir'], check=False)
    shutil.rmtree(os.path.join(jobs_dir(), job_id), ignore_errors=True)
    try:
        os.remove(squad_events_path(job_id))
    except OSError:
        pass


def cancel_job(job_id: str, runner: ClaudeRunner | None = None):
    job = load_job(job_id)
    if runner:
        runner.cancel()
    job['status'], job['busy'], job['busy_msg'] = 'cancelled', False, ''
    log_event(job, '취소했어요')
    save_job(job)


# ══════════════════════════════════════════════════════════════
# git 작업 공간
# ══════════════════════════════════════════════════════════════

def _git(args: list, cwd: str, check: bool = True) -> str:
    p = subprocess.run(['git'] + args, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace',
                       creationflags=0x08000000 if IS_WIN else 0)
    if check and p.returncode != 0:
        raise ClaudeFailed(f'git {" ".join(args)} 실패: {(p.stderr or p.stdout).strip()[-300:]}')
    return (p.stdout or '').strip()


def _is_repo(path: str) -> bool:
    return subprocess.run(['git', 'rev-parse', '--is-inside-work-tree'], cwd=path, capture_output=True,
                          creationflags=0x08000000 if IS_WIN else 0).returncode == 0


def _start_ref(job: dict, proj: str) -> str:
    """새 브랜치를 어디서 딸지 — 이어서 하는 후속 작업이면 앞 작업의 결과 브랜치에서."""
    ref = job.get('start_ref') or ''
    if ref and _git(['branch', '--list', ref], proj, check=False):
        return ref
    return 'HEAD'


def _snapshot_commit(proj: str) -> str:
    """내 폴더의 지금 모습(커밋 안 한 변경·새 파일 포함)을 임시 인덱스로 커밋 객체 하나로 찍는다 — 내 브랜치·작업본은 건드리지 않는다.
    스쿼드가 이 위에서 일하면 결과가 내 폴더에 그대로 겹쳐진다."""
    fd, idx = tempfile.mkstemp(prefix='buni-idx-')
    os.close(fd)
    os.unlink(idx)
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    flags = 0x08000000 if IS_WIN else 0

    def g(args):
        p = subprocess.run(['git'] + args, cwd=proj, env=env, capture_output=True, text=True, encoding='utf-8',
                           errors='replace', creationflags=flags)
        if p.returncode != 0:
            raise ClaudeFailed(f'git {" ".join(args)} 실패: {(p.stderr or p.stdout).strip()[-200:]}')
        return p.stdout.strip()
    try:
        g(['read-tree', 'HEAD'])
        g(['add', '-A'])
        tree = g(['write-tree'])
        return g(['-c', 'user.name=Buni', '-c', 'user.email=buni@localhost', 'commit-tree', tree, '-p', 'HEAD',
                  '-m', 'buni: 작업 시작 시점의 내 폴더'])
    finally:
        try:
            os.unlink(idx)
        except OSError:
            pass


def _carry_parent_result(job: dict, wt: str):
    """후속 작업이 앞 작업의 아직 반영 안 된 결과를 이어받게 — 앞 작업이 내 폴더에 이미 들어갔다면(지금 모습에 있다) 건너뛴다."""
    pid = job.get('parent_id')
    parent = load_job(pid) if pid else None
    if not parent:
        return
    try:
        info = unmerged_info(parent)
    except Exception:
        info = {}
    if not info:
        return
    patch = subprocess.run(['git', 'diff', '--binary', f"{info['base']}..{info['branch']}", '--', '.', ':(exclude).buni-team'],
                           cwd=parent['project_dir'], capture_output=True, creationflags=0x08000000 if IS_WIN else 0).stdout
    if not patch.strip():
        return
    flags = 0x08000000 if IS_WIN else 0
    ok = subprocess.run(['git', 'apply', '-'], cwd=wt, input=patch, capture_output=True, creationflags=flags).returncode == 0
    if ok:
        _git(['add', '-A'], wt, check=False)
        _git(['-c', 'user.name=Buni', '-c', 'user.email=buni@localhost', 'commit', '-q', '-m', 'buni: 앞 작업의 결과 이어받기'], wt, check=False)
        log_event(job, f"앞 작업 '{parent['title']}' 의 아직 반영 안 된 결과 {len(info['files'])}개 파일을 이어받았어요")
    else:
        log_event(job, f"앞 작업 '{parent['title']}' 의 결과가 지금 폴더와 겹쳐서 이어받지 못했어요 — 지금 폴더 기준으로 시작해요")


def prepare_workspace(job: dict) -> str:
    """결과를 모을 브랜치를 준비하고 작업 폴더 경로를 돌려준다 (처음 시작할 때도, 멈췄다 이어갈 때도 부른다).
    - 폴더가 git 저장소가 아니면 git init + 빈 커밋
    - 깨끗하면 그 자리에서 브랜치로, 커밋 안 된 변경이 있으면 별도 worktree 에서 (사용자 작업을 건드리지 않으려고)"""
    proj = job['project_dir']
    wd = job.get('workdir')
    if wd and os.path.abspath(wd) != os.path.abspath(proj) and os.path.isdir(wd):
        return wd                                          # 이미 별도 worktree 가 있다
    os.makedirs(proj, exist_ok=True)
    rd = job.get('result_dir')
    if rd:                                                   # 끝난 작업을 다시 열 때 — 결과 폴더가 브랜치를 쥐고 있으면 놓아 준다
        if os.path.isdir(rd):
            _git(['worktree', 'remove', '--force', rd], proj, check=False)
        _git(['worktree', 'prune'], proj, check=False)
        job['result_dir'] = ''
    if not _is_repo(proj):
        _git(['init', '-q'], proj)
        _git(['-c', 'user.name=Buni', '-c', 'user.email=buni@localhost', 'commit', '-q', '--allow-empty',
              '-m', 'buni: 작업 시작 전 상태'], proj)
        job['created_repo'] = True
    branch = job.get('branch') or ('buni/' + job['slug'])
    job['branch'] = branch
    exists = bool(_git(['branch', '--list', branch], proj, check=False))
    current = _git(['rev-parse', '--abbrev-ref', 'HEAD'], proj)
    if current == branch:                                  # 이미 그 브랜치에 있다
        job['workdir'] = proj
        save_job(job)
        return proj
    if not job.get('base_ref'):
        job['base_ref'] = current
    dirty = bool(_git(['status', '--porcelain'], proj))
    if dirty:
        wt = os.path.join(team_home(), 'worktrees', job['slug'])
        os.makedirs(os.path.dirname(wt), exist_ok=True)
        if exists:
            _git(['worktree', 'add', '-q', wt, branch], proj)
        else:
            start = 'HEAD'
            try:                                                       # 후속 작업도 내 폴더의 '지금 모습' 위에서 시작한다 (옛 브랜치 위가 아니라)
                start = _snapshot_commit(proj)
                job['snapshot'] = start
            except ClaudeFailed:
                start = _start_ref(job, proj)
            _git(['worktree', 'add', '-q', '-b', branch, wt, start], proj)
            _carry_parent_result(job, wt)
        job['workdir'] = wt
        log_event(job, f'커밋 안 된 변경이 있어서 별도 작업 공간(worktree)에서 진행해요 (내 폴더의 지금 모습에서 시작): {wt}')
    else:
        if exists:
            _git(['switch', '-q', branch], proj)
        else:
            _git(['switch', '-q', '-c', branch, _start_ref(job, proj)], proj)
        job['workdir'] = proj
        log_event(job, f'브랜치 {branch} 에서 진행해요')
    save_job(job)
    return job['workdir']


def commit_work(job: dict, message: str):
    wd = job.get('workdir')
    if not wd or not os.path.isdir(wd):
        return
    _git(['add', '-A'], wd, check=False)
    if _git(['status', '--porcelain'], wd, check=False):
        _git(['-c', 'user.name=Buni', '-c', 'user.email=buni@localhost', 'commit', '-q', '-m', message], wd, check=False)


def release_workspace(job: dict, message: str = ''):
    """멈추거나 끝날 때 — 지금까지 한 일을 커밋하고, 제자리에서 작업했다면 원래 브랜치로 돌아간다."""
    wd, proj = job.get('workdir'), job['project_dir']
    if not wd or not os.path.isdir(wd):
        return
    if message:
        commit_work(job, message)
    if os.path.abspath(wd) == os.path.abspath(proj) and job.get('base_ref') and job['base_ref'] != 'HEAD':
        _git(['switch', '-q', job['base_ref']], proj, check=False)
        job['workdir'] = ''                                 # 다음에 이어갈 때 다시 브랜치로 들어간다
        save_job(job)


# ══════════════════════════════════════════════════════════════
# 스쿼드 채팅방 — 팀장의 지시 · 팀원의 보고 · 나의 지시를 시간순으로
# ══════════════════════════════════════════════════════════════

def _chat_path(job_id: str) -> str:
    return job_path(job_id, 'chat.jsonl')


def chat_add(job_id: str, frm: str, to: str, text: str, kind: str = 'say'):
    """채팅방에 한 줄 덧붙인다. frm/to: 'lead' · 'user' · 'all' · 'system' · 팀원 id.
    kind: instruction(지시) · report(보고) · review(검토) · status(상태) · user(내 말) · say(대화).
    덧붙이기만 해서 job.json 을 쓰는 쪽과 부딪히지 않는다."""
    text = (text or '').strip()
    if not text:
        return
    try:
        with open(_chat_path(job_id), 'a', encoding='utf-8') as f:
            f.write(json.dumps({'ts': _now_ts(), 'from': frm, 'to': to, 'kind': kind, 'text': text[:4000]},
                               ensure_ascii=False) + '\n')
    except OSError:
        pass


def load_chat(job_id: str, limit: int = 500) -> list:
    out = []
    try:
        with open(_chat_path(job_id), encoding='utf-8') as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return out[-limit:]


def _typing_path(job_id: str) -> str:
    return job_path(job_id, 'chat_typing.json')


def chat_typing(job_id: str) -> str:
    """지금 답을 쓰는 중인 쪽('lead' 등) — 없으면 ''. 오래된 표시는 무시한다."""
    try:
        with open(_typing_path(job_id), encoding='utf-8') as f:
            d = json.load(f)
        return d.get('who', '') if _now_ts() - float(d.get('ts', 0)) < 600 else ''
    except (OSError, ValueError):
        return ''


_ROLE_STATUS_KO = {'pending': '대기', 'running': '작업 중', 'done_unreviewed': '검토 대기', 'revise': '다시 작업 예정', 'accepted': '통과'}

TRIAGE_PROMPT = """당신은 이 작업의 '팀장'입니다. 사용자가 팀 채팅방에서 말을 걸었습니다. 사용자의 말을 이해해서 (1) 사용자에게 짧게 답하고, (2) 필요하면 팀원에게 지시를 나눠 주세요.

[사전요구서]
{requirements}

[팀원 현황]
{roster}

[최근 대화]
{recent}

[사용자의 말]
{text}

반드시 아래 JSON 한 덩어리만 출력하세요 (다른 설명 금지):
{{"reply": "사용자에게 할 말 1~3문장 — 누구에게 무엇을 시켰는지 포함", "priority": "urgent|high|normal|low", "requirements": {{"add": ["사전요구서에 없던 새 방향·요구"], "change": [{{"was": "사전요구서의 기존 문장(원문 그대로 인용)", "now": "바뀐 요구", "why": "어떻게 다른지 한 줄"}}]}}, "new_roles": [{{"id": "영문소문자id", "name": "이름", "icon": "이모지", "kind": "code", "mission": "맡을 일", "deliverable": "산출물"}}], "assignments": [{{"role": "역할id", "instruction": "그 팀원에게 줄 구체적인 지시"}}]}}

규칙:
- 질문·상황 문의면 assignments 는 비우고 reply 로만 답하세요.
- 지시는 일을 맡은 팀원에게만, 여러 팀원에 걸치면 각각 나눠서 주세요. 역할 id 는 위 [팀원 현황]에 있는 것만 쓰세요.
- 사전요구서 관리: 사용자의 말에 앞으로 계속 지켜야 할 **새 방향·요구·제약**(사전요구서에 없던 것)이 있으면 requirements.add 에 한 문장씩 독립된 문장으로 적으세요. 사전요구서의 **기존 내용과 어긋나는** 요청이면 requirements.change 에 기존 문장(was)을 원문 그대로 인용하고 바뀐 요구(now)를 적으세요 — 이 경우 사용자 확인을 받은 뒤에 반영하므로, 그 일의 assignments 는 평소처럼 적되 reply 에서 "확인해 주시면 진행할게요"라고 말하세요. 일회성 작업 지시·질문·잡담은 둘 다 빈 배열로 두세요.
- priority: 사용자가 '급해/당장/먼저/긴급'이라고 하면 urgent 또는 high, '나중에/천천히'면 low, 그 밖에는 normal.
- 사용자가 무언가를 고치거나 바꾸거나 만들라고 하면 reply 만 하지 말고 반드시 assignments 로 실제 일을 시키세요. 시켰다고 말하려면 assignments 에 그 지시가 있어야 합니다.
- assignments 의 role 은 위 [팀원 현황]의 id 만 쓰세요. 프로젝트 폴더의 CLAUDE.md·에이전트 파일에 나오는 이름(ios, windows, 관리자 등)은 이 스쿼드의 팀원이 아닙니다.
- 맞는 팀원이 없을 때만 new_roles 로 새 팀원을 만드세요(예: 앱 코드를 고쳐야 하면 kind 를 code 로). 만든 팀원의 id 로 assignments 를 주세요. 필요 없으면 new_roles 는 빈 배열.
- 팀원을 없애지 마세요. 사전요구서와 충돌하면 사용자의 말을 우선하되 reply 에 그 사실을 알리세요.
- 고친 결과는 팀원이 실제 파일을 수정한 뒤 확인까지 해서 보고하게 하세요(빌드·실행으로 확인한 것만 보고).
- 확인하지 않은 것을 '됐다/작동한다'고 말하지 마세요. 코드를 쓴 것과 사용자의 앱에서 실제로 보이고 동작하는 것은 다릅니다.
{where}
"""


REQ_ADD_HEAD = '## 추가 방향 (채팅으로 추가됨)'


def _set_requirements(job: dict, text: str):
    job['requirements'] = text.strip()
    _atomic_write(job_path(job['id'], 'requirements.md'), job['requirements'] + '\n')


def requirements_add(job_id: str, items: list, source: str = '채팅') -> list:
    """채팅에서 나온 새 방향을 사전요구서의 '추가 방향' 에 덧붙인다 (기존 내용은 그대로)."""
    items = [str(i).strip() for i in items if str(i or '').strip()]
    job = load_job(job_id)
    if not job or not items:
        return []
    req = job.get('requirements') or ''
    items = [i for i in items if i not in req]                     # 이미 있는 말은 건너뛴다
    if not items:
        return []
    if REQ_ADD_HEAD not in req:
        req = req.rstrip() + '\n\n' + REQ_ADD_HEAD + '\n'
    day = time.strftime('%m/%d')
    req = req.rstrip('\n') + '\n' + '\n'.join(f'- {i} ({day} {source})' for i in items) + '\n'
    _set_requirements(job, req)
    log_event(job, '사전요구서에 새 방향 ' + str(len(items)) + '개를 추가했어요')
    save_job(job)
    chat_add(job_id, 'system', 'all', '📋 사전요구서에 추가했어요: ' + ' / '.join(items), 'status')
    return items


def add_req_proposal(job_id: str, change: dict, extra: dict | None = None) -> dict:
    """기존 사전요구서와 다른 요청 — 바로 고치지 않고 확인을 기다리는 제안으로 남긴다. 연결된 지시(extra)는 승인하면 그때 전달한다."""
    job = load_job(job_id)
    prop = {'id': 'p' + str(int(_now_ts() * 1000))[-8:], 'was': str(change.get('was') or '').strip()[:400],
            'now': str(change.get('now') or '').strip()[:600], 'why': str(change.get('why') or '').strip()[:240],
            'status': 'pending', 'ts': _now_ts(), 'extra': extra or {}}
    job.setdefault('req_proposals', []).append(prop)
    save_job(job)
    return prop


def resolve_req_proposal(job_id: str, pid: str, accept: bool) -> dict:
    """제안을 승인하면 사전요구서를 고치고 보류했던 지시를 전달한다. 거절하면 기존 요구서를 그대로 둔다."""
    job = load_job(job_id)
    prop = next((p for p in (job or {}).get('req_proposals', []) if p['id'] == pid), None)
    if not prop or prop.get('status') != 'pending':
        raise ValueError('이미 처리됐거나 찾을 수 없는 제안이에요')
    prop['status'] = 'accepted' if accept else 'rejected'
    extra = prop.pop('extra', {}) or {}
    if accept:
        req, was, now = job.get('requirements') or '', prop['was'], prop['now']
        day = time.strftime('%m/%d')
        if was and was in req:
            req = req.replace(was, now, 1)
            tail = f'- (변경됨 {day}) "{was}" → "{now}"'
        else:
            tail = f'- (변경 {day}) {now}' + (f' — 기존: "{was}"' if was else '')
        if REQ_ADD_HEAD not in req:
            req = req.rstrip() + '\n\n' + REQ_ADD_HEAD + '\n'
        req = req.rstrip('\n') + '\n' + tail + '\n'
        _set_requirements(job, req)
        log_event(job, '사전요구서를 고쳤어요: ' + now[:60])
    else:
        log_event(job, '사전요구서 변경을 거절했어요 (기존 내용 유지)')
    save_job(job)
    if not accept:
        chat_add(job_id, 'lead', 'user', '알겠어요, 기존 사전요구서를 그대로 유지할게요. 이 요청과 연결된 지시는 보내지 않았어요.', 'say')
        return {'ok': True, 'accepted': False}
    sent_to, bad = _dispatch_assignments(job_id, extra, (extra or {}).get('task_id')) if extra else ([], [])
    msg = '✅ 사전요구서를 수정했어요: ' + prop['now']
    if sent_to:
        msg += '\n📨 이어서 전달했어요: ' + ', '.join(sent_to)
    chat_add(job_id, 'lead', 'user', msg, 'say')
    return {'ok': True, 'accepted': True, 'sent': sent_to}


def _dispatch_assignments(job_id: str, data: dict, task_id: str | None = None) -> tuple:
    """팀장의 답에서 새 팀원을 만들고 지시를 실제로 전달한다. (전달한 팀원 이름들, 맞지 않은 역할 이름들)을 돌려준다."""
    sent_to, bad = [], []
    for spec in (data.get('new_roles') or [])[:3]:
        if isinstance(spec, dict) and (spec.get('mission') or spec.get('name')):
            try:
                add_role(job_id, spec, managed=True)
            except ValueError:
                pass
    job = load_job(job_id)
    for a in data.get('assignments') or []:
        if not isinstance(a, dict) or not str(a.get('instruction') or '').strip():
            continue
        rid = resolve_role(job, a.get('role'))
        if not rid:
            bad.append(str(a.get('role') or '?'))
            continue
        try:
            send_role_note(job_id, rid, str(a['instruction']), by='lead', task_id=task_id)
            r = next(r for r in load_job(job_id)['plan']['roles'] if r['id'] == rid)
            label = f"{r['icon']} {r['name']}"
            if label not in sent_to:
                sent_to.append(label)
        except ValueError:
            bad.append(str(a.get('role')))
    return sent_to, bad


def chat_send(job_id: str, to: str, text: str, runner: ClaudeRunner | None = None) -> dict:
    """채팅방에서 내가 말을 건다. 팀원을 지목하면 그 팀원에게 바로 지시하고, 팀장(또는 전체)에게 하면 팀장이 이해해서
    답하고 필요한 팀원에게 지시를 나눈다."""
    text = (text or '').strip()
    if not text:
        raise ValueError('보낼 내용을 입력해 주세요')
    job = load_job(job_id)
    if not job or not job.get('plan'):
        raise ValueError('아직 팀이 꾸려지지 않았어요')
    if job['status'] == 'cancelled':
        raise ValueError('취소된 작업이에요')
    role_ids = {r['id'] for r in job['plan']['roles']}
    if to in role_ids:
        send_role_note(job_id, to, text, by='user')           # 기록과 반영은 거기서 한다
        return {'ok': True}
    chat_add(job_id, 'user', 'lead', text, 'user')
    _atomic_write(_typing_path(job_id), json.dumps({'who': 'lead', 'ts': _now_ts()}))
    try:
        roster = '\n'.join(
            f"- {r['id']} ({r['name']}, {r['mission'][:60]}): {_ROLE_STATUS_KO.get(job['roles'][r['id']]['status'], '대기')}"
            + (f" — 마지막 보고: {job['roles'][r['id']]['summary'][:120]}" if job['roles'][r['id']].get('summary') else '')
            for r in job['plan']['roles'])
        names = {r['id']: r['name'] for r in job['plan']['roles']}
        names.update({'lead': '팀장', 'user': '나', 'all': '전체', 'system': '시스템'})
        recent = '\n'.join(f"{names.get(m['from'], m['from'])} → {names.get(m['to'], m['to'])}: {m['text'][:200]}"
                           for m in load_chat(job_id, 14)[:-1]) or '(없음)'
        try:
            um = unmerged_info(job)
        except Exception:
            um = {}
        where = (f"- 지금 팀원들의 결과는 별도 작업 공간의 브랜치 `{um['branch']}` 에만 있고 사용자의 폴더에는 합쳐지지 않았습니다. "
                 "그래서 사용자의 설치된 앱·실행 중인 프로그램에는 아직 반영되지 않았습니다. 사용자가 '안 보인다/작동 안 한다'고 하면 먼저 이 사실을 알리고, "
                 "결과 화면 맨 위의 '승인하고 내 폴더에 반영' 버튼을 안내하세요. 팀원에게는 새로 만들기 전에 기존 파일을 확인하게 하세요.") if um else ''
        prompt = TRIAGE_PROMPT.format(requirements=job['requirements'][:6000], roster=roster, recent=recent, text=text, where=where)
        cwd = result_dir(job) or _safe_cwd(job)
        run = runner or ClaudeRunner()
        data = _ask_json(run, prompt, job, name=f"🐰 {job['title']} · 팀장(채팅)", cwd=cwd, key='lead')
        reply = str(data.get('reply') or '').strip() or '알겠어요.'
        reqs = data.get('requirements') if isinstance(data.get('requirements'), dict) else {}
        changes = [c for c in (reqs.get('change') or []) if isinstance(c, dict) and str(c.get('now') or '').strip()][:3]
        added = requirements_add(job_id, [str(x) for x in (reqs.get('add') or [])][:5])
        sent_to, bad = [], []
        task_id = None
        if data.get('assignments') or changes:                               # 내가 한 지시 하나 = 업무 하나 (담당 팀원이 각자 끝내면 완료)
            tj = load_job(job_id)
            prio = data.get('priority') if data.get('priority') in PRIORITIES else 'normal'
            task_id = new_task(tj, _task_title(text), text, 'chat', [], prio)['id']
            save_job(tj)
        if changes:                                                          # 기존 요구서와 다르다 — 확인을 받기 전에는 관련 지시를 보내지 않는다
            extra = {'new_roles': data.get('new_roles') or [], 'assignments': data.get('assignments') or [], 'task_id': task_id}
            for i, c in enumerate(changes):
                add_req_proposal(job_id, c, extra if i == 0 else None)
        else:
            sent_to, bad = _dispatch_assignments(job_id, data, task_id)
            if bad and not sent_to:                                          # 존재하지 않는 팀원에게만 시켰다 — 한 번 바로잡아 다시 묻는다
                fix = (prompt + '\n\n[바로잡기] 방금 답의 assignments 가 실제 팀원이 아닙니다(' + ', '.join(bad) + '). '
                       '위 [팀원 현황]의 id 만 쓰거나, 맞는 팀원이 없으면 new_roles 로 만든 뒤 그 id 로 지시하세요. 같은 형식의 JSON 으로 다시 답하세요.')
                data = _ask_json(run, fix, job, name=f"🐰 {job['title']} · 팀장(채팅)", cwd=cwd, key='lead')
                reply = str(data.get('reply') or '').strip() or reply
                sent_to, bad = _dispatch_assignments(job_id, data, task_id)
        if task_id and not sent_to and not changes:                          # 아무에게도 전달 못 했다 — 빈 업무는 남기지 않는다
            tj = load_job(job_id)
            tj['tasks'] = [t for t in tj.get('tasks', []) if t['id'] != task_id]
            save_job(tj)
        sent = len(sent_to)
        if added:
            reply += '\n\n📋 사전요구서에 추가했어요: ' + ' / '.join(added)
        if changes:
            reply += '\n\n✋ 사전요구서의 기존 내용과 달라서 확인이 필요해요 (위쪽 카드에서 수정할지 정해 주세요) — 정하기 전에는 관련 지시를 보내지 않아요.'
        elif sent_to:
            reply += '\n\n📨 실제로 전달했어요: ' + ', '.join(sent_to)
        elif data.get('assignments') or bad:
            reply += '\n\n⚠️ 팀원에게 지시가 전달되지 않았어요' + (f" (알 수 없는 팀원: {', '.join(bad)})" if bad else '') + ' — 팀원 대화(DM)에서 직접 지시해 주세요.'
        chat_add(job_id, 'lead', 'user', reply, 'say')
        return {'ok': True, 'assignments': sent}
    except RateLimited:
        chat_add(job_id, 'system', 'user', '플랜 사용량 한도에 걸려 팀장이 답하지 못했어요. 한도가 풀린 뒤 다시 보내 주세요.', 'status')
    except (ClaudeFailed, ClaudeNotFound, Cancelled) as e:
        chat_add(job_id, 'system', 'user', '팀장이 답하지 못했어요: ' + (str(e) or '오류'), 'status')
    finally:
        try:
            os.unlink(_typing_path(job_id))
        except OSError:
            pass
    return {'ok': False}


# ══════════════════════════════════════════════════════════════
# 결과 폴더 · 검토할 것 · 다음 작업
# ══════════════════════════════════════════════════════════════

def result_dir(job: dict) -> str:
    """결과 파일을 볼 수 있는 폴더. 작업 공간이 남아 있으면 그곳, 아니면 결과 브랜치를 별도 폴더로 꺼내 둔다
    (같은 자리에서 브랜치로 작업하고 원래 브랜치로 돌아오면 결과 파일이 폴더에서 사라지기 때문)."""
    wd = job.get('workdir')
    if wd and os.path.isdir(wd):
        return wd
    proj, branch = job['project_dir'], job.get('branch')
    rd = job.get('result_dir')
    if rd and os.path.isdir(rd):
        return rd
    if branch and os.path.isdir(proj) and _is_repo(proj) and _git(['branch', '--list', branch], proj, check=False):
        if _git(['rev-parse', '--abbrev-ref', 'HEAD'], proj, check=False) == branch:
            return proj                                   # 지금 그 브랜치에 있다
        rd = os.path.join(jobs_dir(), job['id'], 'result')
        shutil.rmtree(rd, ignore_errors=True)
        _git(['worktree', 'prune'], proj, check=False)
        _git(['worktree', 'add', '-q', rd, branch], proj, check=False)
        if os.path.isdir(rd):
            cur = load_job(job['id'])
            if cur:
                cur['result_dir'] = rd
                save_job(cur)
            return rd
    return proj if os.path.isdir(proj) else ''


WRAPUP_PROMPT = """당신은 이 작업의 '팀장'입니다. 작업이 끝났습니다. 사용자가 (1) 지금 무엇을 직접 확인해야 하는지, (2) 이어서 무엇을 하면 좋은지를 한눈에 보고 버튼 한 번으로 실행할 수 있게 정리하세요.

[사전요구서]
{requirements}

먼저 읽으세요: .buni-team/{slug}/REPORT.md (보고서), .buni-team/{slug}/FINAL.md (최종 결과물). 필요하면 결과 파일도 읽어 확인하세요 (Read/Glob/Grep).

반드시 아래 JSON 한 덩어리만 출력하세요 (다른 설명 금지):
{{"review_items": [{{"id": "r1", "title": "짧은 제목", "why": "무엇을 확인하는지 한 줄", "kind": "file", "target": "docs/intro.md", "expect": "이렇게 보이면 정상"}}],
  "next_steps": [{{"id": "n1", "title": "짧은 제목", "why": "왜 필요한지 한 줄", "goal": "새 작업으로 그대로 맡길 수 있는 자기완결적 지시 (무엇을·어떻게·어디에, 3~8문장)", "done_criteria": ["완료 기준 1", "완료 기준 2"], "direction_change": false}}]}}

규칙:
- review_items: 사용자가 직접 눈으로 보거나 돌려 볼 것만, 중요한 순서로 최대 6개.
  · kind 는 file(프로젝트 폴더 기준 상대경로 — 실제 있는 파일만, Glob 으로 확인) / folder / url(http·https 만) / command(터미널에서 돌려 확인하는 안전한 명령).
  · command 는 읽기·테스트·로컬 실행만 (예: 테스트 실행, 로컬 서버 띄우기, 파일 열기). 설치·삭제·이동·전송·sudo·리다이렉트(>) 금지.
- next_steps: 팀장이 보기에 이어서 하면 좋을 일, 우선순위 순으로 최대 5개. 이번에 못 한 것·보고서에 '주의'로 적은 것·후속 개선 위주. goal 은 질문 없이 바로 시작할 수 있을 만큼 구체적으로.
- next_steps 의 direction_change: 그 일이 '사업 방향을 바꾸는지' 를 true/false 로 적으세요. 가격·Pro 정책 변경, 외부 게시·발송(글 올리기·메일·광고), push·릴리스·배포·태그, 사전요구서가 제외한 범위에 해당하면 true. 사전요구서 범위 안의 보완·수정·시험·문서 정리면 false. 조금이라도 애매하면 true.
- 할 게 없으면 해당 배열을 비워 두세요. 억지로 채우지 마세요.
"""

_UNSAFE_CMD = re.compile(
    r'(^|[;&|`(\s])(rm|rmdir|sudo|su|dd|mkfs|chmod|chown|mv|cp|curl|wget|scp|ssh|rsync|kill|killall|pkill|shutdown|reboot|brew|'
    r'git\s+(push|reset|clean|checkout|rebase)|npm\s+(i|install|publish|uninstall)|pnpm\s+(add|install)|yarn\s+(add|install)|'
    r'pip3?\s+(install|uninstall)|del|rd|format|powershell|iex)\b|>|\$\(|`', re.I)


def unsafe_command(cmd: str) -> bool:
    return bool(_UNSAFE_CMD.search(cmd or ''))


def wrapup_path(job_id: str) -> str:
    return job_path(job_id, 'wrapup.json')


def load_wrapup(job_id: str) -> dict:
    try:
        with open(wrapup_path(job_id), encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


_DIRECTION_RE = re.compile(r'push|릴리스|release|배포|deploy|publish|게시|발송|메일|광고|가격|요금|정책|태그|병합|merge', re.I)


def _direction_change(st: dict) -> bool:
    """사업 방향이 바뀌는 후속 작업인가 — 팀장이 false 로 분명히 적었고 제목·이유에 위험한 말이 없을 때만 False. 애매하면 True(대기)."""
    if st.get('direction_change') is not False:
        return True
    return bool(_DIRECTION_RE.search(f"{st.get('title') or ''} {st.get('why') or ''}"))


def _clean_wrapup(data: dict) -> dict:
    items, steps = [], []
    for i, it in enumerate((data.get('review_items') or [])[:6]):
        if not isinstance(it, dict) or not str(it.get('target') or '').strip():
            continue
        kind = it.get('kind') if it.get('kind') in ('file', 'folder', 'url', 'command') else 'file'
        target = str(it['target']).strip()
        item = {'id': f'r{i + 1}', 'title': _short(it.get('title') or target, 60), 'why': _short(it.get('why') or '', 160),
                'kind': kind, 'target': target[:300], 'expect': _short(it.get('expect') or '', 160)}
        if kind == 'command' and unsafe_command(target):
            item['blocked'] = True                          # 위험해 보이면 보여 주기만 하고 실행은 막는다
        if kind == 'url' and not re.match(r'^https?://', target):
            item['blocked'] = True
        items.append(item)
    for i, st in enumerate((data.get('next_steps') or [])[:5]):
        if not isinstance(st, dict) or not str(st.get('goal') or '').strip():
            continue
        steps.append({'id': f'n{i + 1}', 'title': _short(st.get('title') or st['goal'], 60), 'why': _short(st.get('why') or '', 200),
                      'goal': str(st['goal']).strip()[:1500],
                      'done_criteria': [_short(c, 160) for c in (st.get('done_criteria') or []) if str(c).strip()][:6],
                      'direction_change': _direction_change(st)})
    return {'review_items': items, 'next_steps': steps}


def wrap_up(job_id: str, runner: ClaudeRunner | None = None) -> dict:
    """팀장이 '지금 검토할 것'과 '이어서 할 일'을 정리한다 (wrapup.json). 끝난 작업이면 언제든 다시 만들 수 있다."""
    job = load_job(job_id)
    runner = runner or ClaudeRunner()
    cwd = result_dir(job) or _safe_cwd(job)
    prompt = WRAPUP_PROMPT.format(requirements=job['requirements'], slug=job['slug'])
    cost0 = job.get('cost_usd', 0.0)
    data = _ask_json(runner, prompt, job, name=f"🐰 {job['title']} · 팀장(정리)", cwd=cwd)
    spent = job.get('cost_usd', 0.0) - cost0
    cur = load_job(job_id)
    cur['cost_usd'] = round(cur.get('cost_usd', 0.0) + spent, 4)
    save_job(cur)
    prev = {s.get('title'): s for s in load_wrapup(job_id).get('next_steps', []) if s.get('job_id') or s.get('role_id')}
    clean = _clean_wrapup(data)
    for st in clean['next_steps']:
        if st['title'] in prev:                              # 이미 실행한 후속 작업은 표시를 이어 간다
            for k in ('job_id', 'role_id'):
                if prev[st['title']].get(k):
                    st[k] = prev[st['title']][k]
            if prev[st['title']].get('auto'):
                st['auto'] = prev[st['title']]['auto']
    clean['ts'] = _now_ts()
    _atomic_write(wrapup_path(job_id), json.dumps(clean, ensure_ascii=False, indent=1))
    auto_followups(job_id, clean)
    write_report_view(job_id)
    return clean


def auto_followups(job_id: str, wu: dict | None = None) -> list:
    """정리 직후 — 방향이 안 바뀌는 '다음에 할 일'은 앞 작업 브랜치 위의 새 작업으로 자동 시작하고, 방향이 바뀌는 것은 사용자가 누를 때까지 대기시킨다.
    자동으로 시작된 작업이 만든 후속은 연속 AUTO_FOLLOWUP_MAX 단계까지만 이어 간다. 시작한 작업 id 목록을 돌려준다."""
    job = load_job(job_id)
    wu = wu if wu is not None else load_wrapup(job_id)
    steps = [st for st in wu.get('next_steps', []) if not st.get('job_id') and not st.get('role_id')]
    if not job or not steps:
        return []
    on = bool(load_settings().get('auto_followup'))
    depth = int(job.get('auto_depth') or 0)
    started, limit_hit = [], False
    for st in steps:
        if not on:
            st['auto'] = 'off'
        elif st.get('direction_change', True):
            st['auto'] = 'confirm'
        elif depth >= AUTO_FOLLOWUP_MAX:
            st['auto'] = 'limit'
            limit_hit = True
        elif len(started) >= AUTO_FOLLOWUP_PER_WRAPUP:
            st['auto'] = 'cap'
        else:
            _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
            try:
                start_followup(job_id, st['id'], auto=True, depth=depth)
            except Exception:
                st['auto'] = 'cap'
                continue
            st.update(next(s for s in load_wrapup(job_id)['next_steps'] if s['id'] == st['id']))   # start_followup 이 role_id·auto 를 적어 두었다
            started.append(st['role_id'])
            chat_add(job_id, 'lead', 'user', f"➡️ 방향이 바뀌지 않는 다음 업무 '{st['title']}' 을 이 프로젝트에서 자동으로 이어서 진행해요 "
                     f"(자동 진행 {depth + 1}/{AUTO_FOLLOWUP_MAX}단계).", 'say')
    waiting = [st for st in steps if st.get('auto') == 'confirm']
    if waiting:
        chat_add(job_id, 'lead', 'user', f"✋ 사업 방향이 바뀔 수 있는 후속 작업 {len(waiting)}개는 자동으로 시작하지 않았어요. "
                 '결과 화면의 "다음에 할 일"에서 확인하고 직접 눌러 주세요.', 'say')
    if limit_hit:
        chat_add(job_id, 'lead', 'user', f"⏸ 자동 진행이 연속 {AUTO_FOLLOWUP_MAX}단계에 닿아 여기서 멈췄어요. "
                 '이어서 하려면 결과 화면의 "다음에 할 일"에서 직접 눌러 주세요.', 'say')
    _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
    return started


def next_step_status(st: dict, job: dict | None = None) -> tuple:
    """'다음에 할 일' 항목의 상태 — (키, 글). 자동 진행됨 / 진행 중 / 확인 필요(방향 변경) / 자동 진행 멈춤.
    job 은 이 항목이 속한 프로젝트 (이어서 진행하는 팀원의 상태를 읽는다)."""
    jid = st.get('job_id')
    cur = load_job(jid) if jid else None
    if st.get('role_id') and job:                             # 같은 프로젝트의 팀원으로 이어 가는 중 — 그 팀원의 상태로 본다
        if (job.get('roles') or {}).get(st['role_id'], {}).get('status') == 'accepted':
            return ('done', '✅ 자동 진행됨') if st.get('auto') == 'started' else ('done', '✅ 진행 끝남')
        if job.get('status') in ('failed', 'cancelled'):
            return ('stopped', '⏹ 멈췄어요')
        return ('running', '🔄 진행 중')
    if cur:
        if cur.get('status') in ('review', 'done'):
            return ('done', '✅ 자동 진행됨') if st.get('auto') == 'started' else ('done', '✅ 진행 끝남')
        if cur.get('status') in ('failed', 'cancelled'):
            return ('stopped', '⏹ 멈췄어요')
        return ('running', '🔄 진행 중')
    return {'confirm': ('confirm', '⚠️ 확인 필요 (방향 변경)'),
            'limit': ('limit', f'⏸ 자동 진행 {AUTO_FOLLOWUP_MAX}단계 상한에 닿아 멈춤 — 직접 시작해 주세요'),
            'cap': ('wait', '⏸ 대기 — 직접 시작해 주세요'),
            'off': ('wait', '⏸ 자동 진행이 꺼져 있어요 — 직접 시작해 주세요')}.get(st.get('auto'), ('wait', ''))


# ── 업무 현황 보드 (맥·Windows 공용 판정 — 화면은 이 결과만 그린다) ──

BOARD_COLUMNS = ('ready', 'running', 'review', 'done', 'blocked')
BOARD_COLUMN_NAMES = {'ready': ('대기', 'Waiting'), 'running': ('진행 중', 'In progress'), 'review': ('검토', 'Review'),
                      'done': ('완료', 'Done'), 'blocked': ('확인 필요', 'Needs attention')}
BOARD_AUTO_NAMES = {'started': ('자동 진행됨', 'Auto-started'), 'confirm': ('확인 필요', 'Needs your OK'),
                    'limit': ('상한으로 멈춤', 'Stopped at limit')}
BOARD_SCOPES = ('all', 'active', 'finished')            # 전체 / 진행 중만 / 끝난 것만
BOARD_SORTS = ('recent', 'oldest', 'state', 'assignee')
_BOARD_JOB_NAMES = {'draft': ('작성 중', 'Draft'), 'interviewing': ('질문 답변 중', 'Answering'),
                    'review_requirements': ('요구서 승인 대기', 'Awaiting approval'), 'queued': ('예약됨', 'Scheduled'),
                    'running': ('진행 중', 'Running'), 'waiting_limit': ('한도 대기', 'Waiting (limit)'),
                    'paused': ('잠시 멈춤', 'Paused'), 'review': ('검토 대기', 'Ready to review'), 'done': ('검토 완료', 'Done'),
                    'failed': ('실패', 'Failed'), 'cancelled': ('취소됨', 'Cancelled')}
_BOARD_ROLE_NAMES = {'running': ('작업 중', 'Working'), 'done_unreviewed': ('검토 대기', 'In review'),
                     'revise': ('다시 작업', 'Revising'), 'accepted': ('통과', 'Accepted'), 'pending': ('대기', 'Waiting')}


def board_column(job_status: str, role_status: str | None = None) -> str:
    """작업 상태 + (있다면) 팀원 상태 → 칼럼 키. 위에서부터 먼저 맞는 것 (맥 SquadBoard.column 과 같다)."""
    if job_status in ('cancelled', 'done'):
        return 'done'
    if job_status == 'review':
        return 'review'
    if role_status == 'accepted':
        return 'done'
    if job_status in ('failed', 'waiting_limit', 'paused'):
        return 'blocked'
    if role_status is None:
        return 'running' if job_status == 'running' else 'ready'
    if role_status in ('running', 'revise'):
        return 'running'
    return 'review' if role_status == 'done_unreviewed' else 'ready'


def board_elapsed(since: float, now: float | None = None, en: bool = False) -> str:
    s = max(0, int((now if now is not None else _now_ts()) - (since or 0)))
    m = s // 60; h = m // 60; d = h // 24
    if d:
        return f'{d}d {h % 24}h' if en else f'{d}일 {h % 24}시간'
    if h:
        return f'{h}h {m % 60}m' if en else f'{h}시간 {m % 60}분'
    if m:
        return f'{m}m' if en else f'{m}분'
    return 'just now' if en else '방금'


def board_cards(jobs: list | None = None, now: float | None = None) -> list:
    """업무 카드 목록 — 팀원이 맡은 일(이어서 진행하는 다음 업무 포함, 끝난 지난 업무도 모두) 한 장씩,
    아직 팀이 없는 작업은 작업이 한 장, 시작되지 않은 '다음에 할 일'은 대기/확인 필요 카드 한 장.
    카드는 dict: id · job_id · job_title · role_id · kind(role/job/next) · assignee_id/assignee/icon · column ·
    state(ko,en) · recent · since · updated · progress(done,total) · auto(started/confirm/limit/'') · text(검색용)."""
    now = now if now is not None else _now_ts()
    out = []
    for job in (jobs if jobs is not None else list_jobs()):
        jid, status = job['id'], job.get('status', '')
        title = job.get('title') or job.get('goal') or jid
        job_since = job.get('updated') or job.get('created') or now
        err = job.get('error') or ''
        roles = (job.get('plan') or {}).get('roles') or []
        steps = load_wrapup(jid).get('next_steps') or []
        by_role = {s['role_id']: s for s in steps if s.get('role_id')}

        def card(**kw):
            c = {'job_id': jid, 'job_title': title, 'role_id': None, 'updated': job_since, 'recent': '', 'summary': '',
                 'progress': (0, 0), 'auto': '', 'since': job_since, 'mission': '', 'step_title': '', **kw}
            c['text'] = ' '.join(str(x) for x in (c['job_title'], job.get('goal', ''), c['assignee'], c['recent'], c['summary'],
                                                  c['mission'], c['step_title'], c['state'][0], c['state'][1])).lower()
            return c

        if not roles:
            out.append(card(id=jid, kind='job', assignee_id='lead', assignee='팀장', icon='🐰', column=board_column(status),
                            state=_BOARD_JOB_NAMES.get(status, (status, status)), recent=err or job.get('busy_msg') or ''))
        else:
            accepted = sum(1 for r in roles if (job.get('roles') or {}).get(r['id'], {}).get('status') == 'accepted')
            sess = load_sessions(jid)
            for r in roles:
                st = (job.get('roles') or {}).get(r['id'], {})
                rs = st.get('status') or 'pending'
                col = board_column(status, rs)
                state = _BOARD_JOB_NAMES.get(status, (status, status)) if (
                    col == 'blocked' or (col == 'review' and rs in ('pending', 'accepted'))) else _BOARD_ROLE_NAMES.get(rs, _BOARD_ROLE_NAMES['pending'])
                since, recent = job_since, ''
                if rs == 'running':
                    lines = load_activity(jid, r['id']).get('lines') or []
                    recent = (lines[-1].get('text') if lines and isinstance(lines[-1], dict) else '') or ''
                    opened = [x.get('started') or 0 for x in sess if x.get('key') == r['id'] and not x.get('finished')]
                    if opened:
                        since = max(opened)
                summary = st.get('summary') or ''
                recent = recent or (err if col == 'blocked' else '') or (summary.split('\n')[0] if summary else '')
                step = by_role.get(r['id'])
                out.append(card(id=f'{jid}|{r["id"]}', kind='role', role_id=r['id'], assignee_id=r['id'],
                                assignee=r.get('name') or r['id'], icon=r.get('icon') or '🧑‍💻', column=col, state=state,
                                recent=recent, since=since, summary=summary, mission=r.get('mission', ''),
                                progress=(accepted, len(roles)), step_title=step.get('title', '') if step else '',
                                auto='started' if step and step.get('auto') == 'started' else ''))
        for s in steps:                                       # 아직 시작하지 않은 '다음에 할 일' — 자동 진행되지 않은 이유를 보여 준다
            if s.get('role_id') or s.get('job_id'):
                continue
            a = s.get('auto') or ''
            held = a in ('confirm', 'limit')
            out.append(card(id=f'{jid}|step:{s.get("id")}', kind='next', step_id=s.get('id'), assignee_id='lead', assignee='팀장', icon='🐰',
                            column='blocked' if held else 'ready', state=('확인 필요', 'Needs attention') if held else ('대기', 'Waiting'),
                            recent=s.get('why') or '', summary=s.get('goal') or '', step_title=s.get('title', ''),
                            auto=a if held else '', job_title=f"{title} › {s.get('title', '')}"))
    return out


def board_summary(cards: list) -> dict:
    """상단 요약 숫자 — 전체 · 진행 중 · 완료 · 확인 필요 (+ 대기 · 검토)."""
    n = {c: sum(1 for x in cards if x['column'] == c) for c in BOARD_COLUMNS}
    return {'total': len(cards), 'running': n['running'], 'done': n['done'], 'blocked': n['blocked'],
            'ready': n['ready'], 'review': n['review']}


def board_filter(cards: list, query: str = '', status: str = '', assignee: str = '', scope: str = 'all', sort: str = 'recent') -> list:
    """검색(제목·담당자·내용) · 상태 · 담당자 · 진행 중만/끝난 것만/전체 · 정렬. 비어 있는 조건은 거른 게 없다."""
    q = ' '.join((query or '').lower().split())
    out = []
    for c in cards:
        if status and c['column'] != status:
            continue
        if assignee and c['assignee_id'] != assignee:
            continue
        if scope == 'active' and c['column'] == 'done':
            continue
        if scope == 'finished' and c['column'] != 'done':
            continue
        if q and not all(w in c['text'] for w in q.split()):
            continue
        out.append(c)
    if sort == 'oldest':
        out.sort(key=lambda c: c['since'])
    elif sort == 'state':
        out.sort(key=lambda c: BOARD_COLUMNS.index(c['column']))
    elif sort == 'assignee':
        out.sort(key=lambda c: c['assignee'])
    else:
        out.sort(key=lambda c: -c['updated'])
    return out


def board_detail(card: dict) -> dict:
    """카드를 눌렀을 때 보여 줄 상세 — 담당자 · 진행률 · 최근 활동 · 결과 · 관련 채팅 · 세션(Claude 에서 열기)."""
    jid, rid = card['job_id'], card.get('role_id')
    chat = [m for m in load_chat(jid) if rid is None or rid in (m.get('from'), m.get('to'))][-8:]
    sess = [s for s in load_sessions(jid) if rid is None or s.get('key') == rid]
    lines = (load_activity(jid, rid).get('lines') or [])[-5:] if rid else []
    return {'assignee': card['assignee'], 'progress': card['progress'], 'summary': card.get('summary', ''),
            'activity': [x.get('text', '') for x in lines if isinstance(x, dict)], 'chat': chat, 'sessions': sess,
            'has_report': os.path.exists(job_path(jid, 'report_view.md')) or os.path.exists(job_path(jid, 'REPORT.md'))}


def wrap_up_job(job_id: str) -> dict:
    """화면의 '정리하기' 버튼 — 진행 표시를 켜고 정리한 뒤 끈다."""
    job = load_job(job_id)
    job['busy'], job['busy_msg'], job['error'] = True, '검토할 것과 다음 작업을 정리하는 중…', ''
    save_job(job)
    err = ''
    try:
        wrap_up(job_id)
    except RateLimited:
        err = '플랜 사용량 한도에 걸렸어요. 한도가 풀린 뒤 다시 시도해 주세요.'
    except (ClaudeFailed, ClaudeNotFound, Cancelled) as e:
        err = str(e) or '정리하지 못했어요'
    job = load_job(job_id)
    job['busy'], job['busy_msg'] = False, ''
    if err:
        job['error'] = err
    save_job(job)
    return job


def _report_text(job_id: str) -> str:
    try:
        with open(job_path(job_id, 'REPORT.md'), encoding='utf-8') as f:
            return f.read()
    except OSError:
        job = load_job(job_id)
        return (job or {}).get('summary', '') or ''


_REVIEW_HEAD = re.compile(r'^(#{1,6})\s+.*(검토하는 방법|검토 방법|확인하는 방법|검토할 것|확인할 것)')


def _review_md(wu: dict, level: int) -> list:
    """'지금 확인할 것' 을 보고서 안에 끼워 넣을 마크다운으로 — 항목마다 제목·설명·대상·버튼 줄."""
    h = '#' * min(max(level + 1, 3), 6)
    out = []
    icons = {'file': '📄', 'folder': '📂', 'url': '🌐', 'command': '▶'}
    verbs = {'file': '보기', 'folder': '열기', 'url': '열기', 'command': '실행'}
    for it in wu.get('review_items', []):
        out += ['', f"{h} {icons.get(it['kind'], '📄')} {it['title']}", '']
        line = it.get('why', '')
        if it.get('expect'):
            line += (' — ' if line else '') + '정상이면: ' + it['expect']
        if line:
            out += [line, '']
        if it['kind'] == 'command':
            out += ['```', '$ ' + it['target'], '```', '']
        else:
            out += ['`' + it['target'] + '`', '']
        row = []
        if it.get('blocked'):
            out += ['*안전하지 않아 보여 실행하지 않아요 — 직접 확인해 주세요.*', '']
        else:
            host = 'run' if it['kind'] == 'command' else 'open'
            row.append(f"[{icons.get(it['kind'], '📄')} {verbs.get(it['kind'], '열기')}](buni://{host}/{it['id']})")
        row.append(f"[👍 문제 없어요](buni://ok/{it['id']})")
        out += [' '.join(row), '']
        rv = it.get('review') or {}
        if rv.get('status') == 'ok':
            out += ['✅ **확인했어요 — 문제 없음**', '']
        elif rv.get('status') == 'sending':
            out += ['⏳ 피드백을 팀장에게 전달하는 중이에요…', '']
        elif rv.get('status') in ('fix', 'noted'):
            tail = '팀장이 팀원에게 수정을 지시했고 반영해서 다시 진행해요.' if rv['status'] == 'fix' else '팀장이 확인했어요. (따로 지시가 필요하진 않다고 판단했어요)'
            out += [f"📨 **내 피드백:** {rv.get('text', '')}", '', f"*{tail}*", '']
        # 채팅 입력창 — 항목 바로 아래에 늘 떠 있어서 보고 나서 바로 글을 남긴다
        out += [f"[💬 피드백 보내기](buni://feedbackbox/{it['id']})"]
    return out


def _next_md(wu: dict, job: dict | None = None) -> list:
    out = []
    steps = wu.get('next_steps', [])
    if not steps:
        return out
    out += ['', '---', '', '## ➡️ 다음에 할 일 (팀장 제안)', '', '*방향이 바뀌지 않는 일은 이 프로젝트에서 자동으로 이어서 진행하고, 방향이 바뀌는 일은 버튼을 눌러야 진행해요.*']
    for st in steps:
        out += ['', f"### {st['title']}", '']
        if st.get('why'):
            out += [st['why'], '']
        out += [st['goal'], '']
        label = next_step_status(st, job)[1]
        if label:
            out += [f'**{label}**', '']
        out += [f'- [ ] {c}' for c in st.get('done_criteria') or []]
        if st.get('done_criteria'):
            out.append('')
        if st.get('job_id') and load_job(st['job_id']):       # 예전 방식으로 따로 시작해 둔 작업
            out += [f"[진행 보기 →](buni://view/{st['job_id']})"]
        elif not (st.get('role_id') and job and st['role_id'] in (job.get('roles') or {})):
            out += [f"[▶ 이 프로젝트에서 이어서 진행](buni://followup/{st['id']})"]
    return out


def report_view(job_id: str) -> str:
    """보고서 하나로 읽으면서 바로 누를 수 있게 — 보고서 본문 안에 '지금 확인할 것' 버튼 줄을 넣고, 끝에 '다음에 할 일' 을 붙인다.
    (버튼은 `[라벨](buni://동작/대상)` 한 줄로 적고, 화면이 그 줄을 버튼으로 그린다)"""
    rep = _report_text(job_id).rstrip('\n')
    job = load_job(job_id)
    head = '\n'.join(_unmerged_md(job)) + '\n' if job and job.get('status') in ('review', 'done') else ''
    wu = load_wrapup(job_id)
    if not wu:
        return head + rep
    lines = rep.split('\n')
    review = None
    if wu.get('review_items'):
        idx = None
        for i, ln in enumerate(lines):
            if _REVIEW_HEAD.match(ln):
                idx = i
        if idx is not None:                                   # 보고서의 '검토하는 방법' 자리를 버튼 목록으로 바꾼다
            lvl = len(_REVIEW_HEAD.match(lines[idx]).group(1))
            end = len(lines)
            for j in range(idx + 1, len(lines)):
                m = re.match(r'^(#{1,6})\s', lines[j])
                if m and len(m.group(1)) <= lvl:
                    end = j
                    break
            lines = lines[:idx + 1] + _review_md(wu, lvl) + [''] + lines[end:]
        else:
            lines += ['', '## 👀 지금 확인할 것'] + _review_md(wu, 2)
    return head + '\n'.join(lines + _next_md(wu, job)) + '\n'


_QUICK_CMD = re.compile(r'^(cat|wc|ls|head|tail|grep|git (show|status|log|diff)|npm (test|start|run)|pnpm (test|start)|yarn (test|start)|'
                        r'python3? |node |open |pytest|swift (build|test)|make (test|run))\b')


def quick_wrapup(job_id: str) -> dict:
    """Claude 를 부르지 않고 보고서의 '검토하는 방법' 에서 바로 누를 수 있는 항목을 뽑는다 — 작업을 열자마자 보이게.
    (팀장 정리가 끝나면 그 결과로 덮어쓴다)"""
    job = load_job(job_id)
    rep = _report_text(job_id)
    base = result_dir(job) if job else ''
    lines = rep.split('\n')
    idx = None
    for i, ln in enumerate(lines):
        if _REVIEW_HEAD.match(ln):
            idx = i
    items, seen = [], set()
    if idx is not None:
        lvl = len(_REVIEW_HEAD.match(lines[idx]).group(1))
        for ln in lines[idx + 1:]:
            m = re.match(r'^(#{1,6})\s', ln)
            if m and len(m.group(1)) <= lvl:
                break
            for sp in re.finditer(r'`([^`]+)`', ln):
                tok = sp.group(1).strip()
                kind = None
                if re.match(r'^https?://', tok):
                    kind = 'url'
                elif base and not tok.startswith(('/', '~')) and '..' not in tok and os.path.exists(os.path.join(base, tok)):
                    kind = 'folder' if os.path.isdir(os.path.join(base, tok)) else 'file'
                elif _QUICK_CMD.match(tok) and not unsafe_command(tok):
                    kind = 'command'
                if not kind or (kind, tok) in seen or len(items) >= 6:
                    continue
                seen.add((kind, tok))
                title = re.sub(r'^\s*(\d+[.)]|[-*+])\s*', '', ln).replace('`', '').strip()
                items.append({'id': f'r{len(items) + 1}', 'title': _short(title or tok, 60), 'why': '', 'kind': kind,
                              'target': tok[:300], 'expect': ''})
    data = {'review_items': items, 'next_steps': [], 'quick': True, 'ts': _now_ts()}
    _atomic_write(wrapup_path(job_id), json.dumps(data, ensure_ascii=False, indent=1))
    write_report_view(job_id)
    return data


def ensure_wrapup(job_id: str, full: bool = True):
    """끝난 작업을 열었을 때 — 먼저 보고서에서 바로 쓸 수 있는 항목을 만들고, 이어서 팀장 정리를 한 번만 돌린다."""
    job = load_job(job_id)
    if not job or job.get('status') not in ('review', 'done') or job.get('busy'):
        return
    wu = load_wrapup(job_id)
    if not wu:
        wu = quick_wrapup(job_id)
    if full and wu.get('quick') and not job.get('wrapup_tried'):
        cur = load_job(job_id)
        cur['wrapup_tried'] = True
        save_job(cur)
        wrap_up_job(job_id)



def write_report_view(job_id: str):
    try:
        _atomic_write(job_path(job_id, 'report_view.md'), report_view(job_id))
    except OSError:
        pass



def review_feedback(job_id: str, item_id: str, verdict: str, text: str = '', runner: ClaudeRunner | None = None) -> dict:
    """'지금 확인할 것' 하나를 보고 난 뒤의 반응 — 'ok'(문제 없어요) 또는 'fix'(피드백).
    피드백이면 팀장에게 전달해 해당 팀원에게 수정 지시를 내리게 하고, 끝난 작업이면 다시 열어 반영해서 진행한다."""
    wu = load_wrapup(job_id)
    item = next((i for i in wu.get('review_items', []) if i.get('id') == item_id), None)
    job = load_job(job_id)
    if not job or not item:
        raise ValueError('검토 항목을 찾지 못했어요')
    text = (text or '').strip()
    if verdict == 'ok':
        item['review'] = {'status': 'ok', 'ts': _now_ts()}
        _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
        write_report_view(job_id)
        chat_add(job_id, 'user', 'lead', f"'{item['title']}' 확인했어요 — 문제 없어요 👍", 'user')
        return {'ok': True}
    if not text:
        raise ValueError('피드백 내용을 입력해 주세요')
    item['review'] = {'status': 'sending', 'text': text, 'ts': _now_ts()}
    _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
    write_report_view(job_id)
    what = f"{item['kind']}: {item['target']}" + (f" (기대: {item['expect']})" if item.get('expect') else '')
    msg = (f"📋 검토 피드백 — '{item['title']}' ({what}) 을 확인해 봤어요.\n내 의견: {text}\n"
           f"이 의견을 반영하려면 어느 팀원이 무엇을 고쳐야 할지 정해서 수정 지시를 내려 주세요.")
    try:
        res = chat_send(job_id, 'lead', msg, runner)
    except ValueError:
        res = {'ok': False}
    wu = load_wrapup(job_id) or wu                              # 팀장 처리 중에 정리가 바뀌었을 수 있다
    cur = next((i for i in wu.get('review_items', []) if i.get('id') == item_id), None)
    if cur is not None:
        if res.get('ok'):
            cur['review'] = {'status': 'fix' if res.get('assignments') else 'noted', 'text': text, 'ts': _now_ts()}
        else:
            cur.pop('review', None)                             # 전달 실패 — 다시 보낼 수 있게 되돌린다
        _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
        write_report_view(job_id)
    return res



def _open_path(path: str):
    if IS_WIN:
        os.startfile(path)                                    # type: ignore[attr-defined]
    elif sys.platform == 'darwin':
        subprocess.Popen(['/usr/bin/open', path])
    else:
        subprocess.Popen(['xdg-open', path])


def _run_in_terminal(cwd: str, cmd: str):
    """눈에 보이는 터미널 창에서 명령을 돌린다 (무엇이 도는지 사용자가 볼 수 있게)."""
    if IS_WIN:
        subprocess.Popen(['cmd', '/k', f'cd /d "{cwd}" && echo $ {cmd} && {cmd}'], creationflags=0x00000010)
        return
    path = os.path.join(tempfile.gettempdir(), f'buni-run-{uuid.uuid4().hex[:8]}.command')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(f'#!/bin/bash\ncd "{cwd}" || exit 1\necho "$ "{shlex.quote(cmd)}\n{cmd}\n'
                'echo\necho "— 끝났어요. 창을 닫아도 돼요 —"\nexec "$SHELL" -l\n')
    os.chmod(path, 0o755)
    subprocess.Popen(['/usr/bin/open', path])


def open_review_item(job_id: str, item_id: str) -> dict:
    """'검토할 것' 하나를 연다 — 파일·폴더는 바로 열고, 주소는 브라우저로, 명령은 터미널 창에서 돌린다.
    화면은 id 만 넘기고 실제 대상은 저장된 wrapup.json 에서 읽는다."""
    job = load_job(job_id)
    item = next((i for i in load_wrapup(job_id).get('review_items', []) if i.get('id') == item_id), None)
    if not job or not item:
        return {'ok': False, 'error': '항목을 찾지 못했어요'}
    if item.get('blocked'):
        return {'ok': False, 'error': '안전하지 않아 보이는 항목이라 열지 않아요. 직접 확인해 주세요'}
    base = result_dir(job)
    kind, target = item['kind'], item['target']
    try:
        if kind in ('file', 'folder'):
            root = os.path.realpath(base)
            p = os.path.realpath(os.path.join(root, target))
            if p != root and not p.startswith(root + os.sep):
                return {'ok': False, 'error': '결과 폴더 밖의 경로예요'}
            if not os.path.exists(p):
                return {'ok': False, 'error': f'파일이 없어요: {target}'}
            _open_path(p)
        elif kind == 'url':
            import webbrowser
            webbrowser.open(target)
        elif kind == 'command':
            if unsafe_command(target):
                return {'ok': False, 'error': '안전하지 않아 보이는 명령이라 실행하지 않아요'}
            _run_in_terminal(base, target)
    except OSError as e:
        return {'ok': False, 'error': str(e)}
    return {'ok': True}


def unmerged_info(job: dict) -> dict:
    """결과 브랜치가 내 폴더(project_dir)에 아직 합쳐지지 않았는지 — 별도 작업 공간에서 만든 결과는 설치된 앱·실행 중인 프로그램에 반영되지 않는다."""
    proj, br = job.get('project_dir'), job.get('branch')
    if not proj or not br or not os.path.isdir(proj) or not _is_repo(proj):
        return {}
    if not _git(['branch', '--list', br], proj, check=False):
        return {}
    tip = _git(['rev-parse', br], proj, check=False)
    flags = 0x08000000 if IS_WIN else 0
    if subprocess.run(['git', 'merge-base', '--is-ancestor', br, 'HEAD'], cwd=proj, capture_output=True,
                      creationflags=flags).returncode == 0:
        return {}                                           # 이미 내 폴더에 들어와 있다
    base = job.get('applied_tip') or job.get('snapshot') or _git(['merge-base', br, 'HEAD'], proj, check=False)
    if not base or base == tip:
        return {}                                           # 반영한 뒤로 달라진 게 없다
    files = _git(['diff', '--name-only', f'{base}..{br}', '--', '.', ':(exclude).buni-team'], proj, check=False).split('\n')
    files = [f for f in files if f]
    if not files:
        return {}
    dirty = len([l for l in _git(['status', '--porcelain'], proj, check=False).split('\n') if l.strip()])
    return {'branch': br, 'files': files, 'dirty': dirty, 'base': base, 'tip': tip}


def apply_result(job_id: str) -> dict:
    """결과 브랜치에서 바뀐 내용을 내 폴더 작업본에 반영한다 (커밋은 하지 않는다).
    내 폴더의 커밋 안 된 변경과 겹치면 아무것도 건드리지 않고 이유를 돌려준다."""
    job = load_job(job_id)
    if not job:
        raise ValueError('작업을 찾지 못했어요')
    info = unmerged_info(job)
    if not info:
        return {'ok': True, 'files': 0, 'note': '이미 반영돼 있어요'}
    proj, br = job['project_dir'], info['branch']
    patch = subprocess.run(['git', 'diff', '--binary', f"{info['base']}..{br}", '--', '.', ':(exclude).buni-team'],
                           cwd=proj, capture_output=True, creationflags=0x08000000 if IS_WIN else 0).stdout
    if not patch.strip():
        return {'ok': True, 'files': 0, 'note': '반영할 변경이 없어요'}
    chk = subprocess.run(['git', 'apply', '--check', '-'], cwd=proj, input=patch, capture_output=True,
                         creationflags=0x08000000 if IS_WIN else 0)
    if chk.returncode != 0:
        why = (chk.stderr or b'').decode('utf-8', 'replace').strip().split('\n')[:3]
        return {'ok': False, 'error': '내 폴더의 파일과 겹쳐서 자동으로 반영하지 못했어요 (아무것도 바꾸지 않았어요).\n' + '\n'.join(why)
                + f"\n\n직접 합치려면 터미널에서: git merge {br}"}
    done = subprocess.run(['git', 'apply', '-'], cwd=proj, input=patch, capture_output=True,
                          creationflags=0x08000000 if IS_WIN else 0)
    if done.returncode != 0:
        return {'ok': False, 'error': (done.stderr or b'').decode('utf-8', 'replace').strip()[-300:]}
    job['applied'] = int(time.time())
    job['applied_tip'] = info['tip']                          # 다음에 반영할 때는 이 뒤로 바뀐 것만
    log_event(job, f"결과를 내 폴더에 반영했어요 ({len(info['files'])}개 파일, 커밋은 안 했어요)")
    save_job(job)
    chat_add(job_id, 'system', 'all', '결과를 내 폴더에 반영했어요 — 앱을 다시 빌드해야 보여요', kind='status')
    write_report_view(job_id)
    return {'ok': True, 'files': len(info['files'])}


def changes_diff(job_id: str) -> str:
    """반영하기 전에 볼 수 있게, 팀이 바꾼 내용(내 폴더 기준)을 파일로 적어 두고 경로를 돌려준다. 없으면 ''."""
    job = load_job(job_id)
    info = unmerged_info(job) if job else {}
    if not info:
        return ''
    out = subprocess.run(['git', 'diff', '--stat', '--patch', f"{info['base']}..{info['branch']}", '--', '.', ':(exclude).buni-team'],
                         cwd=job['project_dir'], capture_output=True, text=True, encoding='utf-8', errors='replace',
                         creationflags=0x08000000 if IS_WIN else 0).stdout
    path = job_path(job_id, 'changes.diff')
    _atomic_write(path, out)
    return path


def open_changes_diff(job_id: str) -> dict:
    path = changes_diff(job_id)
    if not path:
        return {'ok': False, 'error': '반영할 변경이 없어요'}
    _open_path(path)
    return {'ok': True}


_PAY_RE = re.compile(r'(?i)(licen[sc]e|payment|pricing|\bprice|billing|stripe|subscription|checkout|promanager|prolicense|buni_pro|issue_license|pro-config)')
_SECRET_RE = re.compile(r'(?i)((^|/)\.env|secrets?[._-]|(^|/)secrets?\b|credentials?|cloud-config|\.(key|pem|p12)$|(auth|access|refresh|api|id)[-_]?(token|key)|firebase|google-services|\.entitlements$|keychain)')
_BUILD_RE = re.compile(r'(?i)((^|/)(build_app\.sh|release\.sh|install\.sh|install\.bat|install_hooks\.py|hookinstaller\.swift|package\.swift|version|info\.plist)$|^\.github/|\.claude/settings|(^|/)\.gitignore$)')


def classify_changes(job: dict, info: dict | None = None) -> list:
    """smart 모드에서 '확인이 필요한 중요한 변경' 이유 목록 — 비어 있으면 중요하지 않다고 보고 바로 반영한다."""
    info = info if info is not None else unmerged_info(job)
    if not info:
        return []
    s = load_settings()
    files, reasons = info.get('files') or [], []

    def hit(rx):
        return [f for f in files if rx.search(f)]
    if s.get('smart_payments'):
        h = hit(_PAY_RE)
        if h:
            reasons.append('결제·라이선스 관련 파일: ' + ', '.join(h[:3]) + (' 외' if len(h) > 3 else ''))
    if s.get('smart_secrets'):
        h = hit(_SECRET_RE)
        if h:
            reasons.append('비밀값·설정 관련 파일: ' + ', '.join(h[:3]) + (' 외' if len(h) > 3 else ''))
    if s.get('smart_build'):
        h = hit(_BUILD_RE)
        if h:
            reasons.append('빌드·설치·릴리스 파일: ' + ', '.join(h[:3]) + (' 외' if len(h) > 3 else ''))
    custom = [c.strip() for c in str(s.get('smart_custom') or '').split(',') if c.strip()]
    if custom:
        import fnmatch
        h = [f for f in files if any(fnmatch.fnmatch(f, c) or fnmatch.fnmatch(os.path.basename(f), c) for c in custom)]
        if h:
            reasons.append('내가 정한 확인 경로: ' + ', '.join(h[:3]) + (' 외' if len(h) > 3 else ''))
    proj, base, br = job['project_dir'], info.get('base'), info.get('branch')
    if s.get('smart_deletes') and base and br:
        names = _git(['diff', '--name-status', f'{base}..{br}', '--', '.', ':(exclude).buni-team'], proj, check=False)
        gone = [l.split('\t', 1)[1] for l in names.split('\n') if l.startswith('D\t')]
        if gone:
            reasons.append(f'파일 {len(gone)}개 삭제: ' + ', '.join(gone[:3]) + (' 외' if len(gone) > 3 else ''))
    if s.get('smart_big'):
        n_files = len(files)
        lines = 0
        if base and br:
            for l in _git(['diff', '--numstat', f'{base}..{br}', '--', '.', ':(exclude).buni-team'], proj, check=False).split('\n'):
                a = l.split('\t')
                if len(a) >= 2 and a[0].isdigit() and a[1].isdigit():
                    lines += int(a[0]) + int(a[1])
        if n_files >= int(s['smart_big_files']) or lines >= int(s['smart_big_lines']):
            reasons.append(f'큰 변경: 파일 {n_files}개 · 약 {lines}줄')
    return reasons


def apply_state(job_id: str) -> dict:
    """화면용 — 아직 내 폴더에 안 들어온 변경이 있는지, 왜 안 들어왔는지(중요한 변경이라 확인 대기 · 겹쳐서 못 함 · 방식이 확인/수동) 알려 준다."""
    job = load_job(job_id)
    if not job:
        return {'pending': False}
    try:
        info = unmerged_info(job)
    except Exception:
        info = {}
    dismissed = bool(info) and job.get('dismissed_tip') == info.get('tip')
    mode = _apply_mode(job)
    try:
        reasons = classify_changes(job, info) if (info and mode == 'smart') else []
    except Exception:
        reasons = []
    return {'pending': bool(info) and not dismissed, 'files': (info.get('files') or [])[:40], 'count': len(info.get('files') or []),
            'branch': info.get('branch') or job.get('branch') or '', 'dirty': info.get('dirty', 0),
            'mode': mode, 'run_mode': run_mode_of(job), 'applied': bool(job.get('applied')),
            'note': job.get('apply_note') or '', 'reasons': reasons,
            'job_apply_mode': job.get('apply_mode') or '', 'job_run_mode': job.get('run_mode') or ''}


def dismiss_apply(job_id: str) -> dict:
    """반영하지 않고 닫는다 — 이 결과는 브랜치에 그대로 남고, 이후 새로 바뀐 것만 다시 묻는다."""
    job = load_job(job_id)
    info = unmerged_info(job) if job else {}
    if job and info:
        job['dismissed_tip'] = info['tip']
        job['apply_note'] = ''
        log_event(job, '이 결과는 반영하지 않고 닫았어요 (브랜치에는 남아 있어요)')
        save_job(job)
    return {'ok': True}


def _apply_mode(job: dict | None = None) -> str:
    """이 작업의 반영 방식 — 작업에서 따로 정했으면 그것, 아니면 설정."""
    m = (job or {}).get('apply_mode') or load_settings().get('apply_mode')
    return m if m in APPLY_MODES else 'smart'


def run_mode_of(job: dict) -> str:
    m = job.get('run_mode') or load_settings().get('run_mode')
    return m if m in RUN_MODES else 'auto'


def set_job_modes(job_id: str, apply_mode: str | None = None, run_mode: str | None = None) -> dict:
    """이 작업만 반영·진행 방식을 바꾼다 (빈 값 = 설정을 따름)."""
    job = load_job(job_id)
    if not job:
        raise ValueError('작업을 찾지 못했어요')
    if apply_mode is not None:
        job['apply_mode'] = apply_mode if apply_mode in APPLY_MODES else ''
    if run_mode is not None:
        job['run_mode'] = run_mode if run_mode in RUN_MODES else ''
        if job['run_mode'] == 'auto' or (not job['run_mode'] and load_settings().get('run_mode') == 'auto'):
            for r in (job.get('roles') or {}).values():     # 자동으로 돌리면 기다리던 업무도 이어서 한다
                r.pop('hold', None)
            if job.get('status') == 'paused' and job.get('phase') == 'waiting_start':
                job['status'], job['phase'], job['run_now'] = 'queued', '', True
    save_job(job)
    return job


def start_role(job_id: str, role_id: str) -> dict:
    """수동 진행 모드 — 이 업무(팀원)를 지금 시작한다."""
    job = load_job(job_id)
    if not job or role_id not in (job.get('roles') or {}):
        raise ValueError('그 업무를 찾지 못했어요')
    if job['status'] == 'cancelled':
        raise ValueError('취소된 작업이에요')
    job['roles'][role_id].pop('hold', None)
    if job['status'] in ('paused', 'review', 'done', 'failed', 'waiting_limit') or (job['status'] == 'paused'):
        job['status'], job['phase'], job['error'], job['run_now'] = 'queued', '', '', True
    log_event(job, '▶ 업무를 직접 시작했어요: ' + next((r['name'] for r in job['plan']['roles'] if r['id'] == role_id), role_id))
    save_job(job)
    return job


def _unmerged_md(job: dict) -> list:
    """보고서 맨 위 안내 — 결과가 내 폴더에 합쳐졌는지, 반영 방식(자동·확인 후·수동)에 맞춰 승인 버튼을 단다."""
    try:
        info = unmerged_info(job)
    except Exception:
        return []
    if not info:
        if job.get('applied'):
            return ['> ✅ 이 결과는 내 폴더에 반영돼 있어요 (커밋은 안 했어요). 앱·프로그램은 다시 빌드해야 새 기능이 보여요.', '']
        return []
    mode = _apply_mode(job)
    n = len(info['files'])
    shown = info['files'][:12]
    out = [f"> ✋ **내 폴더에 반영할지 확인해 주세요.** 팀이 바꾼 파일 {n}개는 아직 별도 작업 공간의 브랜치 `{info['branch']}` 에만 있어서, "
           f"반영하기 전에는 설치된 앱·실행 중인 프로그램에 보이지 않아요." if mode != 'manual' else
           f"> 📦 **수동 모드** — 팀이 바꾼 파일 {n}개는 브랜치 `{info['branch']}` 에만 있어요. 내 폴더에는 반영하지 않았어요."]
    out += ['', '바뀐 파일:'] + [f'- `{f}`' for f in shown] + ([f'- … 외 {n - 12}개'] if n > 12 else [])
    if info['dirty']:
        out += ['', f"> 내 폴더의 커밋 안 한 변경 {info['dirty']}건은 그대로 두고, 그 위에 겹치지 않게 얹어요. 내용이 겹치면 아무것도 바꾸지 않고 알려 줘요."]
    row = []
    if mode != 'manual':
        row.append(f"[✅ 승인하고 내 폴더에 반영](buni://apply/{job['id']})")
    row.append(f"[📄 변경 내용 보기](buni://diff/{job['id']})")
    out += ['', ' '.join(row), '']
    if mode == 'manual':
        out += [f"직접 합치려면 터미널에서: `git merge {info['branch']}`", '']
    return out


def start_followup(job_id: str, step_id: str, auto: bool = False, depth: int | None = None) -> dict:
    """팀장이 제안한 '다음 작업'을 이 프로젝트 안에서 이어서 진행한다 — 새 작업(job)을 만들지 않고 같은 job 에 새 팀원(업무)으로 붙여
    같은 브랜치·작업 공간·채팅방·세션 목록 위에서 한다. 끝난 작업이면 다시 열고, 진행 중이면 대기열에 넣어 하던 일 뒤에 한다."""
    job = load_job(job_id)
    wu = load_wrapup(job_id)
    step = next((s for s in wu.get('next_steps', []) if s.get('id') == step_id), None)
    if not job or not step:
        raise ValueError('다음 작업을 찾지 못했어요')
    if step.get('role_id') and step['role_id'] in job.get('roles', {}):
        return job                                            # 이미 이어서 진행 중이다
    if step.get('job_id') and load_job(step['job_id']):
        return load_job(step['job_id'])                       # 예전 방식(새 작업)으로 시작해 둔 것 — 그대로 둔다
    if not job.get('plan'):
        raise ValueError('아직 팀이 꾸려지지 않았어요')
    if job['status'] == 'cancelled':
        raise ValueError('취소된 작업이에요')
    crit = '\n'.join(f'- [ ] {c}' for c in step.get('done_criteria') or []) or '- [ ] 지시한 내용이 빠짐없이 반영됨'
    mission = (f"[이 프로젝트의 다음 업무: {step['title']}]\n{step['goal']}\n\n이유: {step.get('why') or '-'}\n\n완료 기준:\n{crit}\n\n"
               f"앞 단계의 결과 위에 이어서 만든다. 같은 브랜치에서 기존 파일을 먼저 확인하고 보고서(.buni-team/{job['slug']}/REPORT.md)와 "
               "스타일·구조를 따른다. 질문 없이 진행하고, 불확실한 것은 가장 안전한 쪽으로 정해 기록한다.")
    rid = add_role(job_id, {'id': f'next_{step_id}', 'name': step['title'], 'icon': '➡️', 'kind': 'code', 'mission': mission,
                            'deliverable': '한 일과 확인 결과를 담은 NOTES.md'}, managed=True)
    job = load_job(job_id)
    ft = new_task(job, step['title'], step['goal'], 'followup', [rid])          # 다음 업무도 업무 보드에 한 장으로 올라간다
    ft['auto'] = bool(auto)
    job['auto_depth'] = (int(job.get('auto_depth') or 0) if depth is None else depth) + 1 if auto else 0   # 사용자가 누르면 단계를 처음부터 센다
    role = next(r for r in job['plan']['roles'] if r['id'] == rid)
    role['step_id'], role['auto'] = step_id, bool(auto)
    queued = job['status'] in ('review', 'done')
    if queued:                                                # 끝난 작업을 다시 연다 (진행 중·대기 중이면 그대로 두어 뒤에 이어서 한다)
        job['status'], job['phase'], job['run_now'] = 'queued', '', True
    log_event(job, f"다음 업무 '{step['title']}' 를 {'자동으로 ' if auto else ''}이 프로젝트에서 이어서 진행해요" + ('' if queued else ' (대기열에 넣었어요)'))
    save_job(job)
    step['role_id'], step['auto'] = rid, 'started' if auto else 'manual'
    _atomic_write(wrapup_path(job_id), json.dumps(wu, ensure_ascii=False, indent=1))
    chat_add(job_id, 'lead', rid, f"{step['goal']}\n(이 프로젝트에서 이어서 진행하는 다음 업무예요)", 'instruction')
    write_report_view(job_id)
    return job



# ══════════════════════════════════════════════════════════════
# 팀 실행
# ══════════════════════════════════════════════════════════════

def _valid_plan(plan) -> dict:
    if not isinstance(plan, dict) or not isinstance(plan.get('roles'), list) or not plan['roles']:
        raise ClaudeFailed('팀 구성을 읽지 못했어요')
    roles, seen = [], set()
    for i, r in enumerate(plan['roles'][:6]):
        if not isinstance(r, dict):
            continue
        rid = re.sub(r'[^a-z0-9_]', '', str(r.get('id') or f'role{i + 1}').lower()) or f'role{i + 1}'
        while rid in seen:
            rid += '_'
        seen.add(rid)
        kind = r.get('kind') if r.get('kind') in ('docs', 'code', 'readonly') else 'docs'
        roles.append({'id': rid, 'name': str(r.get('name') or rid), 'icon': str(r.get('icon') or '🧑‍💻'),
                      'kind': kind, 'mission': str(r.get('mission') or ''), 'deliverable': str(r.get('deliverable') or ''),
                      'depends_on': [str(d) for d in (r.get('depends_on') or [])]})
    ids = {r['id'] for r in roles}
    for r in roles:
        r['depends_on'] = [d for d in r['depends_on'] if d in ids and d != r['id']]
    if not roles:
        raise ClaudeFailed('팀 구성에 역할이 없어요')
    return {'summary': str(plan.get('summary') or ''), 'roles': roles}


def _deps_text(job: dict, role: dict) -> str:
    if not role['depends_on']:
        return ''
    lines = ['[먼저 끝난 팀원의 산출물 — 읽고 이어서 작업하세요]']
    for d in role['depends_on']:
        lines.append(f"- {d}: .buni-team/{job['slug']}/{d}/")
    return '\n'.join(lines) + '\n\n'


class HoldForUser(Exception):
    """수동 진행 모드 — 남은 업무가 모두 내가 ▶ 시작을 누르기를 기다린다."""


class JobRunner:
    """한 job 을 끝까지(또는 멈출 때까지) 진행한다. 상태는 매 단계 job.json 에 저장한다."""

    def __init__(self, job_id: str, settings: dict | None = None, notify=None):
        self.job_id = job_id
        self.settings = settings or load_settings()
        self.runner = ClaudeRunner(self.settings)
        self.notify = notify or (lambda kind, job: None)
        self._lock = threading.RLock()
        self.stop_reason = ''

    # ── 바깥에서 부르는 것 ──
    def stop(self, reason: str = 'paused'):
        self.stop_reason = reason
        self.runner.cancel()

    # ── 상태 저장 도우미 ──
    def _job(self) -> dict:
        return load_job(self.job_id)

    def _update(self, fn):
        with self._lock:
            job = self._job()
            prev = job.get('status')
            fn(job)
            if prev == 'cancelled':                    # 다른 곳에서 취소했다면 되살리지 않는다
                job['status'] = 'cancelled'
            save_job(job)
            return job

    def _cost(self, c: float):
        self._update(lambda j: j.__setitem__('cost_usd', round(j.get('cost_usd', 0.0) + c, 4)))

    # ── 본체 ──
    def run(self):
        try:
            self._update(lambda j: (j.update(status='running', error='', resume_at=None, busy=False),
                                    log_event(j, '업무를 시작했어요')))
            chat_add(self.job_id, 'system', 'all', '업무를 시작했어요', 'status')
            job = self._job()
            wd = prepare_workspace(job)
            for _ in range(1 + AUTO_FOLLOWUP_MAX):                   # 정리 중에 '다음 업무'가 이어 붙으면 같은 작업 안에서 한 번 더 돈다
                for _ in range(6):                                   # 합친 뒤에 팀원에게 새 요구사항이 오면 다시 돈다
                    self._plan()
                    self._work_loop(wd)
                    self._merge(wd)
                    if not any(r.get('status') in ('pending', 'revise') for r in self._job()['roles'].values()):
                        break
                    self._update(lambda j: j.update(phase=''))
                self._finish_message()
                if not any(r.get('status') in ('pending', 'revise') for r in self._job()['roles'].values()):
                    break
                self._update(lambda j: j.update(phase=''))
            job = self._job()
            release_workspace(job, f"buni: {job['title']} 완료")
            try:
                result_dir(self._job())                          # 결과 파일을 열어 볼 수 있게 폴더를 마련해 둔다
            except Exception:
                pass
            self._update(lambda j: (j.update(status='review', phase='', busy=False, busy_msg=''),
                                    j.pop('run_now', None), log_event(j, '모두 끝났어요 — 아침에 검토해 주세요')))
            self._auto_apply()
            self.notify('job_done', self._job())
            squad_maybe_done(self.job_id)
        except HoldForUser:
            self._release('buni: 시작 대기 중 진행분')
            msg = '▶ 수동 진행 모드 — 시작하려면 업무 카드의 [▶ 시작] 을 눌러 주세요'
            self._update(lambda j: (j.update(status='paused', phase='waiting_start', busy=False, busy_msg='', run_now=None),
                                    self._reset_running_roles(j), log_event(j, msg)))
            chat_add(self.job_id, 'system', 'all', msg, 'status')
            squad_maybe_done(self.job_id, '업무를 시작해 주세요 (수동 진행 모드)')
        except RateLimited as e:
            resume = e.resume_at or (_now_ts() + 30 * 60)
            self._release('buni: 한도 대기 중 진행분')
            if load_settings().get('limit_action') == 'stop':          # 한도에 닿으면 멈춘다 — 풀려도 내가 ▶ 이어서 를 누를 때까지 시작하지 않는다
                msg = 'Claude 사용량 한도에 닿아 멈췄어요 — 한도가 풀리면 ▶ 이어서 를 눌러 주세요'
                self._update(lambda j: (j.update(status='paused', user_paused=True, resume_at=resume, busy=False, busy_msg='', run_now=None),
                                        self._reset_running_roles(j), log_event(j, msg)))
                chat_add(self.job_id, 'system', 'all', msg, 'status')
                self.notify('limit_stop', self._job())
                squad_maybe_done(self.job_id, 'Claude 사용량 한도에 닿아 멈췄어요')
            else:
                self._update(lambda j: (j.update(status='waiting_limit', resume_at=resume, busy=False, busy_msg=''),
                                        self._reset_running_roles(j),
                                        log_event(j, '플랜 사용량 한도에 걸렸어요 — 풀리면 이어서 해요')))
                chat_add(self.job_id, 'system', 'all', '플랜 사용량 한도에 걸렸어요 — 풀리면 이어서 해요', 'status')
                self.notify('limit_wait', self._job())
                squad_maybe_done(self.job_id, '플랜 사용량 한도에 걸려 잠시 멈췄어요')
        except Cancelled:
            status = 'cancelled' if self.stop_reason == 'cancel' else 'paused'
            self._release('buni: 멈추기 전까지 진행분')
            msg = '취소했어요' if status == 'cancelled' else '예약 시간이 끝나 잠시 멈췄어요 — 다음 시간대에 이어서 해요'
            chat_add(self.job_id, 'system', 'all', msg, 'status')
            self._update(lambda j: (j.update(status=status, busy=False, busy_msg=''), self._reset_running_roles(j),
                                    log_event(j, msg)))
            if status == 'paused':
                self.notify('paused', self._job())
            squad_maybe_done(self.job_id, '' if status == 'cancelled' else '예약 시간이 끝나 잠시 멈췄어요')
        except (ClaudeFailed, ClaudeNotFound, ValueError) as e:
            err = str(e)
            self._release('buni: 오류 직전까지 진행분')
            self._update(lambda j: (j.update(status='failed', error=err, busy=False, busy_msg=''),
                                    self._reset_running_roles(j), log_event(j, '오류: ' + err)))
            chat_add(self.job_id, 'system', 'all', '오류로 멈췄어요: ' + err, 'status')
            self.notify('job_failed', self._job())
            squad_maybe_done(self.job_id, '스쿼드가 오류로 멈췄어요: ' + err[:60])

    def _apply_ready_tasks(self):
        """자동·스마트 모드 — 업무 하나가 끝날 때마다 그 변경을 바로 내 폴더에 반영해서, 다음 업무가 도는 동안 내가 확인할 수 있게 한다.
        (중요한 변경이거나 겹치면 건드리지 않고 알린다. 작업 전체가 끝났을 때의 반영은 `_auto_apply` 가 마저 한다.)"""
        job = self._job()
        mode = _apply_mode(job)
        if mode not in ('auto', 'smart') or not job.get('workdir') or os.path.abspath(job['workdir']) == os.path.abspath(job['project_dir']):
            return
        newly = [t for t in job.get('tasks', []) if t.get('status') == 'done' and not t.get('applied') and not t.get('apply_tried')]
        if not newly:
            return
        title = ', '.join(t['title'] for t in newly)[:80]
        commit_work(job, f"buni: 업무 완료 — {title}")
        try:
            info = unmerged_info(job)
        except Exception:
            info = {}

        def mark(**kw):
            self._update(lambda j: [t.update(kw) for t in j.get('tasks', []) if t['id'] in {n['id'] for n in newly}])
        if not info:
            mark(apply_tried=True)
            return
        reasons = classify_changes(job, info) if mode == 'smart' else []
        if reasons:
            mark(apply_tried=True, apply_note='중요한 변경: ' + ' / '.join(reasons)[:200])
            chat_add(self.job_id, 'lead', 'user', f"✋ 업무 '{title}' 가 끝났어요. 중요한 변경이라 반영은 승인을 기다려요 — " + ' / '.join(reasons)
                     + '\n(다음 업무는 계속 진행해요. 업무 보드에서 "승인하고 내 폴더에 반영"을 눌러 주세요.)', 'say')
            return
        r = apply_result(self.job_id)
        if r.get('ok'):
            mark(applied=_now_ts(), files=info['files'][:30], apply_tried=True)
            chat_add(self.job_id, 'lead', 'user', f"✅ 업무 '{title}' 끝 — 바뀐 파일 {r.get('files', len(info['files']))}개를 내 폴더에 바로 반영했어요 "
                     f"({', '.join(info['files'][:4])}{' 외' if len(info['files']) > 4 else ''}). 다음 업무를 이어서 진행해요. (앱은 다시 빌드해야 보여요)", 'say')
        else:
            note = str(r.get('error', ''))[:240]
            mark(apply_tried=True, apply_note=note)
            self._update(lambda j: j.__setitem__('apply_note', note))
            chat_add(self.job_id, 'lead', 'user', f"⚠️ 업무 '{title}' 는 끝났지만 내 폴더에 반영하지 못했어요: {note}\n다음 업무는 계속 진행해요.", 'say')

    def _auto_apply(self):
        """끝난 결과를 내 폴더에 어떻게 넘길지 — smart: 중요하지 않으면 바로, 중요하면 확인 · auto: 전부 바로 · confirm: 전부 확인 · manual: 브랜치로만."""
        job = self._job()
        mode = _apply_mode(job)
        try:
            info = unmerged_info(job)
        except Exception:
            info = {}
        if not info:
            return
        reasons = []
        if mode == 'smart':
            try:
                reasons = classify_changes(job, info)
            except Exception:
                reasons = []
        if mode == 'auto' or (mode == 'smart' and not reasons):
            try:
                r = apply_result(self.job_id)
            except Exception as e:
                r = {'ok': False, 'error': str(e)}
            note = '' if r.get('ok') else str(r.get('error', ''))[:300]
            self._update(lambda j: j.__setitem__('apply_note', note))
            if r.get('ok'):
                if r.get('files'):
                    why = '중요한 변경이 아니라 ' if mode == 'smart' else ''
                    chat_add(self.job_id, 'system', 'user', f"결과 {r['files']}개 파일을 {why}내 폴더에 바로 반영했어요 (커밋은 안 했어요) — 앱은 다시 빌드해야 보여요", 'status')
            else:
                chat_add(self.job_id, 'system', 'user', '내 폴더에 자동으로 반영하지 못했어요: ' + note
                         + '\n업무 보드의 "승인하고 내 폴더에 반영"으로 다시 시도하거나, "반영하지 않고 닫기"로 정리할 수 있어요.', 'status')
            return
        names = ', '.join(info['files'][:6]) + (f" 외 {len(info['files']) - 6}개" if len(info['files']) > 6 else '')
        if mode == 'manual':
            chat_add(self.job_id, 'lead', 'user', f"📦 결과는 브랜치 {info['branch']} 에 두었어요 (바뀐 파일 {len(info['files'])}개). 수동 모드라 내 폴더에는 반영하지 않았어요.", 'say')
        else:
            why = ('\n중요한 변경이라 확인을 받아요 — ' + ' / '.join(reasons)) if reasons else ''
            chat_add(self.job_id, 'lead', 'user', f"✋ 내 폴더에 반영할까요? 바뀐 파일 {len(info['files'])}개: {names}{why}\n"
                     '업무 보드의 "변경 내용 보기"로 확인하고, "승인하고 내 폴더에 반영"을 누르면 바로 들어가요.', 'say')

    def _unmerged_hint(self) -> str:
        job = load_job(self.job_id)
        try:
            info = unmerged_info(job) if job else {}
        except Exception:
            info = {}
        if not info:
            return ''
        return (f"\n⚠️ 아직 내 폴더에는 합쳐지지 않았어요(브랜치 {info['branch']}). 결과 화면 맨 위의 '승인하고 내 폴더에 반영'을 눌러야 "
                "설치된 앱에서 보여요.")

    def _finish_message(self):
        """한 바퀴가 끝났을 때 — 팀장이 '다음에 할 일'을 정리하고(방향이 안 바뀌는 것은 같은 프로젝트의 새 업무 카드로 자동 이어 붙는다),
        더 이어갈 업무가 없으면 완료 요약을 채팅에 남긴다. (보고서 화면은 없다 — 업무 보드가 대신한다.)"""
        self._update(lambda j: j.update(phase='wrapup', busy=True, busy_msg='팀장이 다음 업무를 정리하는 중…'))
        try:
            wrap_up(self.job_id, self.runner)
        except (RateLimited, ClaudeFailed, ClaudeNotFound, ValueError):
            self._update(lambda j: log_event(j, '다음 업무 정리는 건너뛰었어요'))
        finally:
            self._update(lambda j: j.update(busy=False, busy_msg=''))
        job = self._job()
        if any(r.get('status') in ('pending', 'revise') for r in job['roles'].values()):
            return                                              # 이어 붙은 업무가 있다 — 끝난 게 아니다
        done = [r for r in job['plan']['roles'] if job['roles'].get(r['id'], {}).get('status') == 'accepted']
        names = ', '.join(f"{r['icon']} {r['name']}" for r in done)
        chat_add(self.job_id, 'lead', 'user', f"✅ 모든 업무가 끝났어요 — 완료 {len(done)}개: {names}\n"
                 '업무 보드에서 누가 무엇을 했는지 볼 수 있어요. 더 시킬 게 있으면 여기에 말해 주세요.' + self._unmerged_hint(), 'say')

    def _release(self, message: str):
        try:
            release_workspace(self._job(), message)
        except Exception:
            pass

    @staticmethod
    def _reset_running_roles(j: dict):
        for rid, r in j.get('roles', {}).items():
            if r.get('status') == 'running':
                notes = os.path.join(j.get('workdir') or '', '.buni-team', j.get('slug', ''), rid, 'NOTES.md')
                try:                                           # 결과 기록 직전에 끊겼어도 일이 끝났다면 대기로 돌리지 않는다
                    if r.get('started') and os.path.getmtime(notes) >= r['started']:
                        with open(notes, encoding='utf-8') as f:
                            r['status'], r['finished'], r['summary'] = 'done_unreviewed', os.path.getmtime(notes), f.read().strip()[:600]
                        continue
                except OSError:
                    pass
                r['status'] = 'pending'

    # ── 1) 팀 구성 ──
    def _plan(self):
        job = self._job()
        if job.get('plan') and job['roles']:
            return
        self._update(lambda j: j.update(phase='planning', busy=True, busy_msg='팀을 구성하는 중…'))
        job = self._job()
        prompt = PLAN_PROMPT.format(requirements=job['requirements'], slug=job['slug'])
        data = _ask_json(self.runner, prompt, job, name=f"🐰 {job['title']} · 팀장(구성)", cwd=job['workdir'])
        plan = _valid_plan(data)

        def apply(j):
            j['cost_usd'] = job['cost_usd']
            j['plan'] = plan
            manual = run_mode_of(j) == 'manual'
            j['roles'] = {r['id']: {'status': 'pending', 'attempts': 0, 'feedback': '', 'summary': '', 'session_id': None,
                                    **({'hold': True} if manual else {})} for r in plan['roles']}
            j['busy'], j['busy_msg'] = False, ''
            log_event(j, '팀 구성: ' + ', '.join(f"{r['icon']} {r['name']}" for r in plan['roles']))
        self._update(apply)
        chat_add(job['id'], 'lead', 'all', ('팀을 이렇게 꾸렸어요. ' + plan['summary']).strip() + '\n' +
                 '\n'.join(f"{r['icon']} {r['name']}" for r in plan['roles']), 'say')
        for r in plan['roles']:
            dep = (' (먼저 끝나야 하는 팀원: ' + ', '.join(r['depends_on']) + ')') if r['depends_on'] else ''
            chat_add(job['id'], 'lead', r['id'], f"{r['mission']}\n산출물: {r['deliverable']}{dep}", 'instruction')
        os.makedirs(os.path.join(job['workdir'], '.buni-team', job['slug']), exist_ok=True)

    # ── 2) 업무 진행 + 3) 검토 ──
    def _work_loop(self, wd: str):
        max_rev = int(self.settings.get('max_revisions', 2))
        concurrency = max(1, int(self.settings.get('concurrency', 2)))
        while True:
            self._apply_ready_tasks()                               # 끝난 업무는 바로 내 폴더에 반영하고 다음 업무로 넘어간다
            job = self._job()
            roles = {r['id']: r for r in job['plan']['roles']}
            state = job['roles']
            pending_all = [rid for rid in roles if state[rid]['status'] in ('pending', 'revise')]
            held = [rid for rid in pending_all if state[rid].get('hold')]
            pending = [rid for rid in pending_all if not state[rid].get('hold')]
            if not pending:
                # 모두 done(승인 대기 포함) → 검토
                to_review = [rid for rid in roles if state[rid]['status'] == 'done_unreviewed']
                if not to_review:
                    if held:
                        raise HoldForUser()
                    break
                self._review(to_review, max_rev)
                continue
            self._update(lambda j: j.update(phase='working'))
            ready = [rid for rid in pending if all(state[d]['status'] == 'accepted' for d in roles[rid]['depends_on'])]
            ready.sort(key=lambda rid: role_priority(job, rid))        # 급한 업무를 맡은 팀원부터 (같으면 원래 순서)
            if not ready:
                # 의존하는 역할이 검토를 기다리는 중 → 먼저 검토
                to_review = [rid for rid in roles if state[rid]['status'] == 'done_unreviewed']
                if to_review:
                    self._review(to_review, max_rev)
                    continue
                if held:
                    raise HoldForUser()
                raise ClaudeFailed('역할 사이의 순서가 꼬였어요 (서로를 기다리고 있어요)')
            # code 역할은 한 번에 하나만, 나머지는 concurrency 만큼 병렬
            batch = []
            for rid in ready:
                if roles[rid]['kind'] == 'code':
                    if not batch:
                        batch = [rid]
                    break
                batch.append(rid)
                if len(batch) >= concurrency:
                    break
            if not batch:
                batch = ready[:1]
            self._run_batch(batch, roles, wd)
            # 이 묶음이 끝나면 바로 검토해서 다음 역할이 검토된 결과를 쓰게 한다
            to_review = [rid for rid in roles if self._job()['roles'][rid]['status'] == 'done_unreviewed']
            if to_review:
                self._review(to_review, max_rev)

    def _run_batch(self, batch: list, roles: dict, wd: str):
        errors, rate = [], []
        threads = []

        def work(rid):
            try:
                self._run_role(roles[rid], wd)
            except RateLimited as e:
                rate.append(e)
            except Cancelled:
                errors.append(Cancelled())
            except (ClaudeFailed, ClaudeNotFound) as e:
                errors.append(e)

        for rid in batch:
            t = threading.Thread(target=work, args=(rid,), daemon=True)
            threads.append(t)
            t.start()
        for t in threads:
            t.join()
        for e in errors:
            if isinstance(e, Cancelled):
                raise e
        if rate:
            raise rate[0]
        for e in errors:
            raise e

    def _run_role(self, role: dict, wd: str):
        rid = role['id']
        job = self._job()
        st = job['roles'][rid]

        def start(j):
            r = j['roles'][rid]
            r['status'], r['attempts'], r['started'] = 'running', r.get('attempts', 0) + 1, _now_ts()
            r.pop('note_pending', None)
            j['busy'], j['busy_msg'] = True, f"{role['icon']} {role['name']} 진행 중…"
            log_event(j, f"{role['icon']} {role['name']} 시작 ({r['attempts']}번째)")
        self._update(start)
        att = self._job()['roles'][rid].get('attempts', 1)
        chat_add(job['id'], rid, 'lead', '작업을 시작할게요.' if att <= 1 else f'다시 작업할게요 ({att}번째).', 'status')
        feedback = ''
        if st.get('feedback'):
            feedback = f"[팀장의 피드백 — 이번에는 이 내용을 반영해서 고치세요]\n{st['feedback']}\n\n"
        if st.get('notes'):
            feedback += ('[사용자가 이 팀원에게 직접 전달한 요구사항 — 사전요구서보다 우선해서 반드시 반영하세요]\n'
                         + '\n'.join(f"- {n.get('text', '')}" for n in st['notes']) + '\n\n')
        code_note = ''
        if role['kind'] == 'code':
            code_note = '\n- 이 업무는 프로젝트 파일을 직접 수정합니다. 수정은 프로젝트 폴더 안에서만 하고, 테스트·빌드 명령으로 확인하세요. 커밋은 팀 시스템이 합니다.'
        team = ', '.join(f"{r['name']}({r['id']})" for r in job['plan']['roles'])
        prompt = WORKER_PROMPT.format(name=role['name'], requirements=job['requirements'], team=team,
                                      mission=role['mission'], deliverable=role['deliverable'],
                                      deps=_deps_text(job, role), feedback=feedback, slug=job['slug'], rid=rid,
                                      code_note=code_note)
        os.makedirs(os.path.join(wd, '.buni-team', job['slug'], rid), exist_ok=True)
        nm = f"🐰 {job['title']} · {role['name']}"
        res = self.runner.run(prompt, wd, role_kind=role['kind'], slug=job['slug'], web=bool(job['permissions'].get('web')),
                              name=nm, timeout=2 * 3600, log_path=job_path(job['id'], 'claude.log'),
                              track={'job_id': job['id'], 'key': rid, 'label': nm}, model=role.get('model', ''))
        denials = [f"{d.get('tool_name')}" for d in res['denials']]

        def done(j):
            r = j['roles'][rid]
            r['status'], r['finished'], r['summary'] = 'done_unreviewed', _now_ts(), res['result'].strip()[-600:]
            r['session_id'] = res.get('session_id')
            if r.pop('note_pending', False):                       # 일하는 중에 사용자가 요구사항을 보냈다 → 검토 전에 바로 반영해 다시
                r['status'], r['feedback'] = 'revise', ROLE_NOTE_FEEDBACK
            if denials:
                r['denied'] = sorted(set(denials))
            j['cost_usd'] = round(j.get('cost_usd', 0.0) + res['cost'], 4)
            j['busy'], j['busy_msg'] = False, ''
            log_event(j, f"{role['icon']} {role['name']} 완료")
        self._update(done)
        report = res['result'].strip()[-700:] or '작업을 마쳤어요.'
        if denials:
            report += '\n(막힌 도구: ' + ', '.join(sorted(set(denials))) + ')'
        chat_add(job['id'], rid, 'lead', report, 'report')
        if role['kind'] == 'code':
            with self._lock:
                commit_work(self._job(), f"buni: {role['name']} — {job['title']}")

    def _review(self, ids: list, max_rev: int):
        job = self._job()
        roles = {r['id']: r for r in job['plan']['roles']}
        self._update(lambda j: j.update(phase='reviewing', busy=True, busy_msg='팀장이 검토하는 중…'))
        names = ', '.join(f"{roles[i]['name']}({i})" for i in ids)
        prompt = REVIEW_PROMPT.format(requirements=job['requirements'], names=names, slug=job['slug'])
        data = _ask_json(self.runner, prompt, job, name=f"🐰 {job['title']} · 팀장(검토)", cwd=job['workdir'])
        verdicts = {}
        for v in data.get('verdicts') or []:
            if isinstance(v, dict) and v.get('id') in ids:
                verdicts[v['id']] = v

        def apply(j):
            j['cost_usd'] = job['cost_usd']
            for rid in ids:
                r = j['roles'][rid]
                v = verdicts.get(rid, {'verdict': 'accept'})
                if v.get('verdict') == 'revise' and r['attempts'] <= max_rev and (v.get('feedback') or '').strip():
                    r['status'], r['feedback'] = 'revise', str(v['feedback']).strip()
                    log_event(j, f"{roles[rid]['icon']} {roles[rid]['name']} — 다시 하도록 했어요")
                else:
                    r['status'], r['feedback'] = 'accepted', ''
                    log_event(j, f"{roles[rid]['icon']} {roles[rid]['name']} — 통과")
            j['review_summary'] = str(data.get('summary') or '')
            j['busy'], j['busy_msg'] = False, ''
        self._update(apply)
        for rid in ids:
            v = verdicts.get(rid, {'verdict': 'accept'})
            if v.get('verdict') == 'revise' and (v.get('feedback') or '').strip():
                if self._job()['roles'][rid]['status'] == 'revise':
                    chat_add(job['id'], 'lead', rid, '다시 해 주세요.\n' + str(v['feedback']).strip(), 'review')
                    continue
            chat_add(job['id'], 'lead', rid, '통과예요 👍', 'review')
        if str(data.get('summary') or '').strip():
            chat_add(job['id'], 'lead', 'all', '검토 요약: ' + str(data['summary']).strip(), 'say')

    # ── 4) 통합·보고 ──
    def _merge(self, wd: str):
        job = self._job()
        if job.get('phase') == 'done_merge':
            return
        self._update(lambda j: j.update(phase='merging', busy=True, busy_msg='팀장이 결과를 합치는 중…'))
        names = ', '.join(f"{r['name']}({r['id']})" for r in job['plan']['roles'])
        prompt = MERGE_PROMPT.format(requirements=job['requirements'], slug=job['slug'], names=names)
        nm = f"🐰 {job['title']} · 팀장(통합)"
        res = self.runner.run(prompt, wd, role_kind='docs', slug=job['slug'], name=nm, timeout=3600,
                              log_path=job_path(job['id'], 'claude.log'),
                              track={'job_id': job['id'], 'key': 'lead', 'label': nm})
        report_src = os.path.join(wd, '.buni-team', job['slug'], 'REPORT.md')
        final_src = os.path.join(wd, '.buni-team', job['slug'], 'FINAL.md')
        report_dst = job_path(job['id'], 'REPORT.md')
        for src, dst in ((report_src, report_dst), (final_src, job_path(job['id'], 'FINAL.md'))):
            if os.path.exists(src):
                shutil.copyfile(src, dst)
        if not os.path.exists(report_dst):                  # 팀장이 보고서를 못 썼으면 최소한의 보고서를 만든다
            _atomic_write(report_dst, '# 보고서\n\n' + res['result'].strip() + '\n')

        def done(j):
            j['cost_usd'] = round(j.get('cost_usd', 0.0) + res['cost'], 4)
            j['report'] = report_dst
            j['summary'] = res['result'].strip()[-800:]
            j['phase'], j['busy'], j['busy_msg'] = 'done_merge', False, ''
        self._update(done)
        write_report_view(job['id'])
        chat_add(job['id'], 'lead', 'all', '팀원들의 결과를 합쳐서 최종 결과물과 보고서를 만들었어요.', 'say')


# ══════════════════════════════════════════════════════════════
# 예약 실행기 (시간대를 지키며 대기열을 처리)
# ══════════════════════════════════════════════════════════════

class Scheduler:
    """tick() 을 주기적으로 부르면, 시간대 안에서만 대기열의 작업을 하나씩 진행한다."""

    def __init__(self, notify=None, now_fn=None):
        self.notify = notify or (lambda kind, job: None)
        self.now_fn = now_fn or datetime.datetime.now
        self._current: JobRunner | None = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self.awake_cb = None            # 진행 중일 때 절전을 막는 콜백(True/False)

    # ── 상태 ──
    @property
    def running_job_id(self) -> str | None:
        t = self._thread
        return self._current.job_id if (self._current and t and t.is_alive()) else None

    def recover(self):
        """앱이 갑자기 꺼졌다 켜진 경우 — 'running' 으로 남은 작업을 멈춘 상태로 돌려 놓는다."""
        for j in list_jobs():
            if j['status'] == 'running' and j['id'] != self.running_job_id:
                j['status'], j['busy'], j['busy_msg'] = 'paused', False, ''
                JobRunner._reset_running_roles(j)
                log_event(j, '앱이 다시 켜져서 이어서 하려고 멈춘 상태로 돌려놨어요')
                save_job(j)
            elif j.get('busy') and j['id'] != self.running_job_id:          # 질문 정리 중에 앱이 꺼진 경우
                j['busy'], j['busy_msg'] = False, ''
                j['error'] = j.get('error') or '앱이 꺼져서 중간에 멈췄어요. 다시 시도해 주세요.'
                save_job(j)

    def tick(self):
        s = load_settings()
        now = self.now_fn()
        with self._lock:
            running = self.running_job_id
            mode = s.get('schedule_mode', 'window')
            allowed = mode == 'anytime' or (mode == 'window' and in_window(now, s['window_start'], s['window_end']))
            if running:
                j = load_job(running)
                if s.get('paused') or (j and j.get('user_paused')):
                    self._current.stop('paused')            # 내가 멈췄다 (전체 일시정지 또는 이 작업만)
                elif j and j['status'] == 'cancelled':
                    self._current.stop('cancel')            # 다른 곳(앱 화면)에서 취소했다
                elif not allowed and not self._manual(running):
                    self._current.stop('paused')            # 시간대가 끝났다 → 멈춘다
                return
            if self._thread and not self._thread.is_alive():
                self._thread, self._current = None, None
                if self.awake_cb:
                    self.awake_cb(False)
            if s.get('paused'):
                return                                      # 전체 일시정지 — 아무것도 시작하지 않는다
            candidates = []
            for j in list_jobs():
                if j.get('user_paused'):
                    continue
                if j['status'] in ('queued', 'paused') and (allowed or j.get('run_now')):
                    candidates.append(j)
                elif j['status'] == 'waiting_limit' and (allowed or j.get('run_now')) and _now_ts() >= (j.get('resume_at') or 0):
                    candidates.append(j)
            if not candidates:
                self._retro_apply()
                return
            job = candidates[0]
            self._start(job['id'], s)

    def _retro_apply(self):
        """이미 끝났는데 아직 내 폴더에 안 들어온 결과 — 반영 방식이 바뀌었거나 앱이 꺼져 있던 사이에 끝난 것 — 중 '중요하지 않은' 것을 이어서 반영한다.
        (5분에 한 번만 보고, 한 번 시도한 결과는 다시 시도하지 않는다.)"""
        now = _now_ts()
        if now - getattr(self, '_last_retro', 0) < 300:
            return
        self._last_retro = now
        for j in list_jobs():
            if j['status'] not in ('review', 'done'):
                continue
            try:
                mode = _apply_mode(j)
                if mode not in ('auto', 'smart'):
                    continue
                info = unmerged_info(j)
                if not info or j.get('dismissed_tip') == info['tip'] or j.get('auto_tried_tip') == info['tip']:
                    continue
                if mode == 'smart' and classify_changes(j, info):
                    continue                                   # 중요한 변경은 내가 승인할 때까지 기다린다
                cur = load_job(j['id'])
                cur['auto_tried_tip'] = info['tip']
                save_job(cur)
                r = apply_result(j['id'])
                cur = load_job(j['id'])
                cur['apply_note'] = '' if r.get('ok') else str(r.get('error', ''))[:300]
                save_job(cur)
                chat_add(j['id'], 'system', 'user',
                         (f"끝나 있던 결과 {r.get('files', 0)}개 파일을 중요한 변경이 아니라 내 폴더에 반영했어요" if r.get('ok')
                          else '이어서 자동 반영을 시도했지만 하지 못했어요: ' + cur['apply_note']), 'status')
            except Exception:
                continue

    def _manual(self, job_id: str) -> bool:
        j = load_job(job_id)
        return bool(j and j.get('run_now'))

    def _start(self, job_id: str, settings: dict):
        runner = JobRunner(job_id, settings, notify=self.notify)
        self._current = runner
        if self.awake_cb:
            self.awake_cb(True)

        def go():
            try:
                runner.run()
            finally:
                if self.awake_cb:
                    self.awake_cb(False)
        self._thread = threading.Thread(target=go, daemon=True)
        self._thread.start()

    # ── 사용자가 부르는 것 ──
    def run_now(self, job_id: str):
        """시간대와 상관없이 지금 바로 시작 (낮에 직접 돌려 보고 싶을 때)."""
        j = load_job(job_id)
        if j and j['status'] in ('queued', 'paused', 'waiting_limit', 'failed'):
            j['run_now'] = True
            if j['status'] in ('failed', 'waiting_limit'):
                j['status'] = 'paused'
            j['error'], j['resume_at'] = '', None
            save_job(j)

    def cancel(self, job_id: str):
        if self.running_job_id == job_id and self._current:
            self._current.stop('cancel')
        j = load_job(job_id)
        if j and j['status'] not in FINISHED:
            j['status'], j['busy'], j['busy_msg'] = 'cancelled', False, ''
            log_event(j, '취소했어요')
            save_job(j)

    def stop_all(self):
        if self._current:
            self._current.stop('paused')


# ══════════════════════════════════════════════════════════════
# 명령줄 (macOS 앱이 부른다)
# ══════════════════════════════════════════════════════════════

def _out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
    sys.stdout.flush()


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if IS_WIN:
        r = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'], capture_output=True, text=True,
                           creationflags=0x08000000)
        return str(pid) in r.stdout
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def daemon_loop(parent_pid: int = 0, interval: float = 20.0):
    """macOS 앱이 띄우는 상주 프로세스 — 부모(앱)가 끝나면 같이 끝난다."""
    sched = Scheduler()
    sched.recover()
    pidfile = os.path.join(team_home(), 'daemon.pid')
    _atomic_write(pidfile, str(os.getpid()))
    caff = None
    last_active = False
    while True:
        if parent_pid and not _pid_alive(parent_pid):
            sched.stop_all()
            break
        try:
            sched.tick()
        except Exception as e:                                       # 한 번 틱이 실패해도 계속 돈다
            sys.stderr.write(f'tick 오류: {e}\n')
        active = sched.running_job_id is not None
        if sys.platform == 'darwin' and active != last_active:       # 진행 중엔 맥이 잠들지 않게
            if active:
                try:
                    caff = subprocess.Popen(['/usr/bin/caffeinate', '-ims'])
                except OSError:
                    caff = None
            elif caff:
                caff.terminate()
                caff = None
        last_active = active
        time.sleep(interval)
    if caff:
        caff.terminate()
    try:
        os.unlink(pidfile)
    except OSError:
        pass


def main(argv=None):
    ap = argparse.ArgumentParser(prog='buni_team')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('new');  p.add_argument('--title', default=''); p.add_argument('--goal', required=True)
    p.add_argument('--project', required=True); p.add_argument('--web', action='store_true')
    p = sub.add_parser('interview-start');  p.add_argument('job')
    p = sub.add_parser('interview-resume'); p.add_argument('job')
    p = sub.add_parser('interview-add'); p.add_argument('job'); p.add_argument('--text-file', required=True)
    p.add_argument('--answers', default=''); p.add_argument('--requirements-file', default='')
    p = sub.add_parser('role-note'); p.add_argument('job'); p.add_argument('role'); p.add_argument('--text-file', required=True)
    p = sub.add_parser('open-session'); p.add_argument('job'); p.add_argument('session')
    p = sub.add_parser('chat-send'); p.add_argument('job'); p.add_argument('--to', default='lead'); p.add_argument('--text-file', required=True)
    p = sub.add_parser('review-feedback'); p.add_argument('job'); p.add_argument('item'); p.add_argument('--verdict', default='fix'); p.add_argument('--text-file', default='')
    p = sub.add_parser('ensure-wrapup'); p.add_argument('job')
    p = sub.add_parser('wrap-up'); p.add_argument('job')
    p = sub.add_parser('open-item'); p.add_argument('job'); p.add_argument('item')
    p = sub.add_parser('followup'); p.add_argument('job'); p.add_argument('step')
    p = sub.add_parser('apply-result'); p.add_argument('job')
    p = sub.add_parser('open-diff'); p.add_argument('job')
    p = sub.add_parser('apply-state'); p.add_argument('job')
    p = sub.add_parser('pause-job'); p.add_argument('job')
    p = sub.add_parser('heal-job'); p.add_argument('job'); p.add_argument('--accept', action='store_true')
    p = sub.add_parser('resume-job'); p.add_argument('job')
    p = sub.add_parser('global-pause'); p.add_argument('state', choices=['on', 'off'])
    p = sub.add_parser('task-priority'); p.add_argument('job'); p.add_argument('task'); p.add_argument('priority')
    p = sub.add_parser('apply-dismiss'); p.add_argument('job')
    p = sub.add_parser('job-modes'); p.add_argument('job'); p.add_argument('--apply'); p.add_argument('--run')
    p = sub.add_parser('start-role'); p.add_argument('job'); p.add_argument('role')
    p = sub.add_parser('req-resolve'); p.add_argument('job'); p.add_argument('proposal'); p.add_argument('--accept', action='store_true')
    p = sub.add_parser('role-model'); p.add_argument('job'); p.add_argument('role'); p.add_argument('--model', default='')
    p = sub.add_parser('interview-restart'); p.add_argument('job')
    p = sub.add_parser('interview-answer'); p.add_argument('job'); p.add_argument('--answers', required=True, help='JSON 파일 경로')
    p = sub.add_parser('approve'); p.add_argument('job'); p.add_argument('--requirements-file', default=''); p.add_argument('--now', action='store_true')
    p = sub.add_parser('cancel'); p.add_argument('job')
    p = sub.add_parser('run-now'); p.add_argument('job')
    p = sub.add_parser('delete'); p.add_argument('job')
    p = sub.add_parser('retry'); p.add_argument('job')
    p = sub.add_parser('mark-done'); p.add_argument('job')
    p = sub.add_parser('settings'); p.add_argument('--set', default='', help='JSON')
    p = sub.add_parser('daemon'); p.add_argument('--parent-pid', type=int, default=0); p.add_argument('--interval', type=float, default=20.0)
    sub.add_parser('check')
    a = ap.parse_args(argv)

    if a.cmd == 'new':
        _out(new_job(a.title, a.goal, a.project, {'web': a.web}))
    elif a.cmd == 'interview-start':
        _out(start_interview(a.job))
    elif a.cmd == 'interview-resume':
        _out(resume_interview(a.job))
    elif a.cmd == 'interview-add':
        def _read(path):
            if not path:
                return None
            with open(path, encoding='utf-8') as f:
                return f.read()
        ans = _read(a.answers)
        _out(add_request(a.job, _read(a.text_file), json.loads(ans) if ans else None, _read(a.requirements_file)))
    elif a.cmd == 'role-note':
        with open(a.text_file, encoding='utf-8') as fh:
            _out(send_role_note(a.job, a.role, fh.read()))
    elif a.cmd == 'open-session':
        _out({'ok': open_session_in_terminal(a.job, a.session)})
    elif a.cmd == 'chat-send':
        with open(a.text_file, encoding='utf-8') as fh:
            _out(chat_send(a.job, a.to, fh.read()))
    elif a.cmd == 'review-feedback':
        txt = ''
        if a.text_file:
            with open(a.text_file, encoding='utf-8') as fh:
                txt = fh.read()
        _out(review_feedback(a.job, a.item, a.verdict, txt))
    elif a.cmd == 'ensure-wrapup':
        ensure_wrapup(a.job)
        _out({'ok': True})
    elif a.cmd == 'wrap-up':
        _out(wrap_up_job(a.job))
    elif a.cmd == 'open-item':
        _out(open_review_item(a.job, a.item))
    elif a.cmd == 'followup':
        _out(start_followup(a.job, a.step))
    elif a.cmd == 'apply-result':
        _out(apply_result(a.job))
    elif a.cmd == 'req-resolve':
        _out(resolve_req_proposal(a.job, a.proposal, a.accept))
    elif a.cmd == 'job-modes':
        _out(set_job_modes(a.job, a.apply, a.run))
    elif a.cmd == 'start-role':
        _out(start_role(a.job, a.role))
    elif a.cmd == 'apply-dismiss':
        _out(dismiss_apply(a.job))
    elif a.cmd == 'heal-job':
        _out({'healed': heal_interrupted_roles(a.job, a.accept)})
    elif a.cmd == 'pause-job':
        _out(pause_job(a.job))
    elif a.cmd == 'resume-job':
        _out(resume_job(a.job))
    elif a.cmd == 'global-pause':
        _out(set_global_pause(a.state == 'on'))
    elif a.cmd == 'task-priority':
        _out(set_task_priority(a.job, a.task, a.priority))
    elif a.cmd == 'apply-state':
        _out(apply_state(a.job))
    elif a.cmd == 'open-diff':
        _out(open_changes_diff(a.job))
    elif a.cmd == 'role-model':
        _out(set_role_model(a.job, a.role, a.model))
    elif a.cmd == 'interview-restart':
        _out(restart_interview(a.job))
    elif a.cmd == 'interview-answer':
        with open(a.answers, encoding='utf-8') as f:
            _out(answer_interview(a.job, json.load(f)))
    elif a.cmd == 'approve':
        edited = None
        if a.requirements_file:
            with open(a.requirements_file, encoding='utf-8') as f:
                edited = f.read()
        _out(approve_job(a.job, edited, start_now=a.now))
    elif a.cmd == 'cancel':
        cancel_job(a.job)
        _out({'ok': True})
    elif a.cmd == 'run-now':
        j = load_job(a.job)
        if j and j['status'] in ('queued', 'paused', 'waiting_limit', 'failed'):
            j['run_now'] = True
            if j['status'] in ('failed', 'waiting_limit'):
                j['status'] = 'paused'
            j['error'], j['resume_at'] = '', None
            save_job(j)
        _out({'ok': True})
    elif a.cmd == 'delete':
        delete_job(a.job)
        _out({'ok': True})
    elif a.cmd == 'retry':
        _out(retry_job(a.job))
    elif a.cmd == 'mark-done':
        _out(mark_done(a.job))
    elif a.cmd == 'settings':
        _out(save_settings(json.loads(a.set)) if a.set else load_settings())
    elif a.cmd == 'daemon':
        daemon_loop(a.parent_pid, a.interval)
    elif a.cmd == 'check':
        try:
            _out({'claude': find_claude(), 'git': bool(shutil.which('git')), 'home': team_home()})
        except ClaudeNotFound as e:
            _out({'claude': '', 'git': bool(shutil.which('git')), 'error': str(e), 'home': team_home()})


if __name__ == '__main__':
    main()
