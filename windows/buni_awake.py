"""
노트북 덮개를 닫아도 Claude가 계속 돌도록 절전을 막는다 (macOS AwakeManager.swift 포팅).

Windows에서는 두 가지를 함께 한다.
  · SetThreadExecutionState(ES_SYSTEM_REQUIRED)로 유휴 절전을 막는다.
  · 현재 전원 관리 옵션의 "덮개를 닫을 때" 동작을 "아무 것도 안 함"으로 바꾼다.
    (powercfg — 관리자 권한이 필요 없다. 원래 값은 파일에 적어 두었다가 되돌린다)

안전장치
  · 켤 때 지정한 시간이 지나면 자동으로 되돌린다(무제한 선택 시 제외).
  · 앱이 종료될 때 반드시 되돌린다 — 켜둔 채 꺼지면 덮개를 닫아도 영영 안 자게 된다.
  · 앱이 뜰 때도 한 번 정리한다(지난번에 비정상 종료된 경우 대비).
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

_IS_WIN = sys.platform == 'win32'
_NO_WINDOW = 0x08000000      # CREATE_NO_WINDOW

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001

DURATIONS = [   # (분, 라벨 ko, 라벨 en) — 0은 무제한
    (30, '30분', '30 min'),
    (60, '1시간', '1 hour'),
    (120, '2시간', '2 hours'),
    (240, '4시간', '4 hours'),
    (480, '8시간', '8 hours'),
    (0, '직접 끌 때까지', 'Until I turn it off'),
]


def _state_file() -> Path:
    base = os.environ.get('APPDATA') or str(Path.home() / 'AppData' / 'Roaming')
    return Path(base) / 'Buni' / 'awake.json'


def hhmm(minute: int) -> str:
    return f'{minute // 60:02d}:{minute % 60:02d}'


def _powercfg(*args):
    """(성공 여부, 출력). Windows가 아니면 항상 실패."""
    if not _IS_WIN:
        return False, ''
    try:
        r = subprocess.run(['powercfg', *args], capture_output=True, text=True,
                           creationflags=_NO_WINDOW, timeout=15)
        return r.returncode == 0, r.stdout
    except Exception:
        return False, ''


class AwakeManager:
    def __init__(self, persist, root, t):
        self.persist = persist
        self.root = root                  # Tk — after()로 타이머를 돌린다
        self.t = t
        self.is_active = False
        self.active_until = None          # epoch 초 — None이면 무제한
        self.activated_by_schedule = False
        self.last_error = None
        self._listeners = []
        self._expiry_job = None
        self._keeper = None               # ES_SYSTEM_REQUIRED를 쥐고 있는 스레드
        self._keeper_stop = threading.Event()

        self.schedule_enabled = bool(persist.get('awake.schedule.enabled', False))
        self.schedule_start = int(persist.get('awake.schedule.start', 9 * 60))
        self.schedule_end = int(persist.get('awake.schedule.end', 18 * 60))

        self._restore_leftover()          # 지난번에 켜둔 채 끝났다면 되돌린다
        self._schedule_tick()

    # ── 지원 여부 / 알림 ────────────────────────────────────

    @property
    def supported(self) -> bool:
        return _IS_WIN

    def add_listener(self, cb):
        self._listeners.append(cb)

    def _notify(self):
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass

    # ── 켜기 / 끄기 ─────────────────────────────────────────

    def enable(self, minutes, by_schedule=False) -> bool:
        """minutes: 유지할 시간(분). 0/None이면 직접 끌 때까지 무제한."""
        t = self.t
        if not self.supported:
            self.last_error = t('Windows에서만 쓸 수 있어요', 'Only available on Windows')
            self._notify()
            return False
        if not self.is_active:
            if not self._set_lid_do_nothing():
                self.last_error = t('덮개 동작을 바꾸지 못했어요 (전원 관리 정책이 막고 있을 수 있어요)',
                                    "Couldn't change the lid action (a power policy may block it)")
                self._notify()
                return False
            self._start_keeper()
        self.last_error = None
        self.activated_by_schedule = by_schedule
        self.is_active = True

        if self._expiry_job:
            self.root.after_cancel(self._expiry_job)
            self._expiry_job = None
        if minutes:
            self.active_until = time.time() + minutes * 60
            self._expiry_job = self.root.after(int(minutes * 60 * 1000), self.disable)
        else:
            self.active_until = None
        self._notify()
        return True

    def disable(self):
        if self._expiry_job:
            try:
                self.root.after_cancel(self._expiry_job)
            except Exception:
                pass
            self._expiry_job = None
        self.active_until = None
        self.activated_by_schedule = False
        if self.is_active:
            self._stop_keeper()
            self._restore_lid_action()
        self.is_active = False
        self._notify()

    def restore_on_quit(self):
        """앱 종료 시 반드시 호출 — 켜둔 채 꺼지면 덮개를 닫아도 계속 안 자게 된다."""
        if self.is_active or _state_file().exists():
            self._stop_keeper()
            self._restore_lid_action()
            self.is_active = False

    # ── 상태 문구 ───────────────────────────────────────────

    def status_text(self) -> str:
        """언제 끝나는지가 항상 드러나게 한다.
        · 시간을 골라 켠 경우: "1시간 23분 남음"
        · 시간대 예약으로 켜진 경우: "18:00까지 (3시간 12분 남음)"
        · 직접 무제한으로 켠 경우만 "무제한" """
        t = self.t
        if self.active_until is not None:
            return self._left(int(max(0, self.active_until - time.time())) // 60)
        if self.activated_by_schedule:
            end = hhmm(self.schedule_end)
            left = self._left(self._minutes_until_schedule_end())
            return t(f'{end}까지 ({left})', f'until {end} ({left})')
        return t('무제한', 'no limit')

    def _left(self, minutes: int) -> str:
        h, m = divmod(minutes, 60)
        if h > 0:
            return self.t(f'{h}시간 {m}분 남음', f'{h}h {m}m left')
        return self.t(f'{m}분 남음', f'{m}m left')

    def _minutes_until_schedule_end(self) -> int:
        lt = time.localtime()
        now = lt.tm_hour * 60 + lt.tm_min
        diff = self.schedule_end - now
        if diff <= 0:
            diff += 24 * 60
        return diff

    # ── 시간대 예약 ─────────────────────────────────────────

    def set_schedule(self, enabled=None, start=None, end=None):
        if enabled is not None:
            self.schedule_enabled = enabled
            self.persist.set('awake.schedule.enabled', enabled)
        if start is not None:
            self.schedule_start = start
            self.persist.set('awake.schedule.start', start)
        if end is not None:
            self.schedule_end = end
            self.persist.set('awake.schedule.end', end)
        self._apply_schedule()
        self._notify()

    def _schedule_tick(self):
        self._apply_schedule()
        self.root.after(30_000, self._schedule_tick)

    def _apply_schedule(self):
        if not self.schedule_enabled:
            if self.activated_by_schedule:        # 예약을 끌 때 예약으로 켜진 것도 같이 끈다
                self.disable()
            return
        lt = time.localtime()
        in_window = self._in_window(lt.tm_hour * 60 + lt.tm_min)
        if in_window and not self.is_active:
            self.enable(None, by_schedule=True)
        elif not in_window and self.is_active and self.activated_by_schedule:
            self.disable()

    def _in_window(self, minute: int) -> bool:
        """종료 시각이 시작보다 빠르면 자정을 넘는 구간으로 본다 (예: 22:00~06:00)."""
        s, e = self.schedule_start, self.schedule_end
        if s == e:
            return False
        if s < e:
            return s <= minute < e
        return minute >= s or minute < e

    # ── 절전 방지 스레드 ────────────────────────────────────
    # ES_CONTINUOUS 설정은 그것을 호출한 스레드가 살아 있는 동안만 유지되므로
    # 전용 스레드가 쥐고 있다가, 끄면 스레드를 끝내 설정을 풀어 준다.

    def _start_keeper(self):
        if not _IS_WIN or (self._keeper and self._keeper.is_alive()):
            return
        self._keeper_stop.clear()

        def run():
            import ctypes
            k32 = ctypes.windll.kernel32
            k32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
            self._keeper_stop.wait()
            k32.SetThreadExecutionState(ES_CONTINUOUS)
        self._keeper = threading.Thread(target=run, daemon=True)
        self._keeper.start()

    def _stop_keeper(self):
        self._keeper_stop.set()
        self._keeper = None

    # ── 덮개 동작 (powercfg) ────────────────────────────────

    @staticmethod
    def _read_lid_values():
        """현재 전원 옵션의 (전원 연결 시, 배터리 시) 덮개 닫기 동작 값. 읽지 못하면 None."""
        ok, out = _powercfg('/query', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION')
        if not ok:
            return None
        ac = re.search(r'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)', out)
        dc = re.search(r'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)', out)
        if not ac:
            # 한국어 Windows 등 — 영어 라벨이 아니면 줄 끝의 16진수를 순서대로 읽는다
            vals = re.findall(r'0x([0-9a-fA-F]{8})\s*$', out, re.M)
            if len(vals) >= 2:
                return int(vals[-2], 16), int(vals[-1], 16)
            return None
        return int(ac.group(1), 16), int(dc.group(1), 16) if dc else int(ac.group(1), 16)

    def _set_lid_do_nothing(self) -> bool:
        values = self._read_lid_values()
        if values is None:
            return False
        # 원래 값을 먼저 적어 둔다 — 앱이 비정상 종료돼도 다음에 되돌릴 수 있게
        try:
            sf = _state_file()
            sf.parent.mkdir(parents=True, exist_ok=True)
            if not sf.exists():                           # 이미 켜져 있던 값을 덮어쓰지 않는다
                sf.write_text(json.dumps({'ac': values[0], 'dc': values[1]}), encoding='utf-8')
        except Exception:
            return False
        ok1, _ = _powercfg('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')
        ok2, _ = _powercfg('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')
        ok3, _ = _powercfg('/setactive', 'SCHEME_CURRENT')
        if not (ok1 and ok2 and ok3):
            self._restore_lid_action()
            return False
        return True

    def _restore_lid_action(self):
        sf = _state_file()
        try:
            saved = json.loads(sf.read_text(encoding='utf-8'))
        except Exception:
            return
        ok1, _ = _powercfg('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', str(saved['ac']))
        ok2, _ = _powercfg('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', str(saved['dc']))
        ok3, _ = _powercfg('/setactive', 'SCHEME_CURRENT')
        if ok1 and ok2 and ok3:
            try:
                sf.unlink()
            except Exception:
                pass

    def _restore_leftover(self):
        """지난번에 켜둔 채 비정상 종료됐다면 원래 값으로 되돌린다."""
        if _IS_WIN and _state_file().exists():
            self._restore_lid_action()
