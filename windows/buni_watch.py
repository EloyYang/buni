"""스쿼드 화면의 파일 변경 확인 — 표준 라이브러리만 쓴다 (Tk 없이 시험할 수 있다).
수정 시각(mtime)·크기 비교로 job.json·chat.jsonl 같은 파일이 바뀌었을 때만 화면을 다시 읽게 한다.
맥 TeamStore 파일 감시와 같은 규칙: 입력 중에는 미뤘다가 끝나면 한 번 반영, 가려지면 확인을 멈추고, 안전망 주기마다 한 번은 다시 읽는다."""
import os

JOB_FILES = ('job.json', 'chat.jsonl', 'wrapup.json', 'report_view.md', 'chat_typing.json')
SAFETY_S = 30.0               # 제자리 덮어쓰기·놓친 변화를 위해 이만큼 지나면 한 번은 다시 읽는다


def _stamp(path):
    try:
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


def scan_jobs(jobs_dir, settings_path='', names=JOB_FILES, extra=()):
    """작업 폴더들의 주요 파일 (mtime, 크기) 묶음. 폴더가 늘거나 줄어도 값이 달라진다."""
    out = [('settings', _stamp(settings_path) if settings_path else None)]
    out += [(p, _stamp(p)) for p in extra]
    try:
        ids = sorted(os.listdir(jobs_dir))
    except OSError:
        return tuple(out)
    for jid in ids:
        base = os.path.join(jobs_dir, jid)
        for n in names:
            s = _stamp(os.path.join(base, n))
            if s is not None:
                out.append((jid + '/' + n, s))
    return tuple(out)


class ChangeWatch:
    """poll() 이 True 를 돌려줄 때만 화면을 다시 읽는다.
    - typing/hidden 이면 False (기록을 갱신하지 않으므로 끝난 뒤 변화는 한 번에 반영된다)
    - 처음 한 번, 변화가 있을 때, 마지막으로 읽은 지 safety_s 가 지났을 때 True"""

    def __init__(self, scan, safety_s=SAFETY_S):
        self.scan, self.safety_s = scan, safety_s
        self._stamp = None
        self._last = None

    def poll(self, now, typing=False, hidden=False):
        if typing or hidden:
            return False
        cur = self.scan()
        if self._last is None or cur != self._stamp or now - self._last >= self.safety_s:
            self._stamp, self._last = cur, now
            return True
        return False

    def reset(self):
        """다음 poll 에서 무조건 한 번 읽게 한다 (직접 고친 직후 등)."""
        self._last = None
