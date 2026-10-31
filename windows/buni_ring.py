"""스쿼드 왼쪽 목록의 '업무 중' 팀원 아바타 테두리 — 규칙만 모았다 (Tk 없이 시험할 수 있다).
맥 SquadWorkingRing/SquadGlowClock 과 같은 규칙: 굵기 2 · 색 ok 토큰 · 글로우 4 ↔ 0 이 PERIOD_MS 마다 번갈아 바뀐다.
업무 중인 행이 있을 때만 시계가 돌고, 없으면 멈춘다. BUNI_PREVIEW·움직임 줄이기에서는 고정 테두리."""
import os
import sys

from buni_theme import C, mix

WORKING = ('running', 'doing')      # 팀원 상태 중 업무 중인 것 (이 밖에는 테두리 없음)
PERIOD_MS = 600                     # 300ms 이상 (배터리) — 맥은 0.6초
MIN_PERIOD_MS = 300
WIDTH = 2
GLOW = 4


def is_working(status) -> bool:
    return status in WORKING


def reduce_motion(env=None) -> bool:
    """움직임 줄이기. BUNI_REDUCE_MOTION=1 이면 켠 것으로 보고, Windows 는 '설정 > 접근성 > 시각 효과 > 애니메이션 효과'를 끄면(SPI_GETCLIENTAREAANIMATION) 켠 것으로 본다."""
    env = os.environ if env is None else env
    v = env.get('BUNI_REDUCE_MOTION')
    if v is not None:
        return v not in ('', '0', 'false')
    if sys.platform.startswith('win'):
        try:
            import ctypes
            on = ctypes.c_int(1)
            if ctypes.windll.user32.SystemParametersInfoW(0x1042, 0, ctypes.byref(on), 0):
                return not on.value
        except Exception:
            pass
    return False


def is_still(env=None) -> bool:
    """고정 테두리로 그려야 하는가 — BUNI_PREVIEW(캡처가 프레임마다 달라지지 않게) 또는 움직임 줄이기."""
    env = os.environ if env is None else env
    return env.get('BUNI_PREVIEW') is not None or reduce_motion(env)


def ring_colors(bright: bool, bg: str = C['rail']) -> dict:
    """테두리 그리기 값. 모두 ok 토큰을 바탕색(bg)에 섞은 것 (맥: buniOk.opacity)."""
    ok = C['ok']
    return {'ring': mix(ok, bg, 0.95 if bright else 0.5),
            'glow': mix(ok, bg, 0.3) if bright else bg,
            'glow_w': GLOW if bright else 0, 'width': WIDTH}


class RingClock:
    """깜빡임 시계 하나. register 한 캔버스가 하나라도 있을 때만 after() 가 돌고, 없으면 멈춘다. (무한 애니메이션 없음)
    after/cancel 은 Tk 의 widget.after / after_cancel, redraw(canvas, bright) 는 캔버스를 다시 칠하는 함수."""

    def __init__(self, after, cancel, redraw, still=False, period_ms=PERIOD_MS, active=lambda: True):
        self._after, self._cancel, self._redraw = after, cancel, redraw
        self.still, self.period_ms = still, max(MIN_PERIOD_MS, int(period_ms))
        self._active = active           # False(창이 가려짐)면 멈춘다 — resume() 이 다시 켠다
        self.items = []
        self.bright = True
        self._job = None

    @property
    def running(self) -> bool:
        return self._job is not None

    def register(self, canvas):
        self.items.append(canvas)
        self._redraw(canvas, self.bright)
        if not self.still and self._job is None:
            self._job = self._after(self.period_ms, self._step)

    def clear(self):
        """목록을 다시 그리기 전에 부른다 — 옛 캔버스는 사라지므로 비우고 멈춘다."""
        self.items = []
        self.stop()

    def stop(self):
        if self._job is not None:
            try:
                self._cancel(self._job)
            except Exception:
                pass
            self._job = None

    def resume(self):
        if self.items and not self.still and self._job is None and self._active():
            self._job = self._after(self.period_ms, self._step)

    def _step(self):
        self._job = None
        if not self.items or self.still or not self._active():
            return                       # 업무 중인 행이 없거나 가려졌으면 다음 예약을 안 한다
        self.bright = not self.bright
        alive = []
        for c in self.items:
            try:
                self._redraw(c, self.bright)
                alive.append(c)
            except Exception:
                pass                     # 이미 사라진 캔버스
        self.items = alive
        if self.items:
            self._job = self._after(self.period_ms, self._step)
