#!/usr/bin/env python3
"""
Buni for Windows v1.0.0
Claude Code companion – pixel-art rabbit mascot
https://github.com/EloyYang/buni
"""
import tkinter as tk
import threading
import json, time, os, sys, math
import ctypes, datetime
from pathlib import Path

# ── Pixel unit (matches macOS p = 6.5)
P = 6.5

# ── Window geometry
WIN_W, WIN_H = 340, 180
CHAR_CX = WIN_W - 52   # character center-X inside window
CHAR_CY = WIN_H - 32   # character center-Y inside window

# ── Transparent-color key (used as WM transparent color on Windows)
TRANSP = '#010101'

# ── Palette
W_BODY = '#E8E8F0'; W_EAR = '#F3B8C7'   # white rabbit
B_BODY = '#9A6633'; B_EAR = '#C47844'   # brown rabbit (Duni)
BROW_C = '#35180A'                        # Duni eyebrow/stubble
NOSE_C = '#E09090'; BLACK = '#000000'
CARROT = '#F58C2E'; LEAF   = '#47B347'
NEEDLE = '#855422'; YARN_D = '#D46614'

# ── Event file: same JSONL format, Windows TEMP dir
_TEMP = Path(os.environ.get('TEMP', os.environ.get('TMP', 'C:/temp')))
EVENTS_FILE = _TEMP / 'claude-companion-events.jsonl'

# ── Windows API (click-through transparent window)
_u32          = ctypes.windll.user32
GWL_EXSTYLE   = -20
WS_EX_LAYERED     = 0x00080000
WS_EX_TRANSPARENT = 0x00000020

def _get_hwnd(widget: tk.Widget) -> int:
    return _u32.GetParent(widget.winfo_id())

def _set_click_through(hwnd: int, enable: bool) -> None:
    style = _u32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    if enable:
        style |= WS_EX_LAYERED | WS_EX_TRANSPARENT
    else:
        style = (style | WS_EX_LAYERED) & ~WS_EX_TRANSPARENT
    _u32.SetWindowLongW(hwnd, GWL_EXSTYLE, style)


# ═══════════════════════════════════════════════════════════════
class BuniApp:
    """Main application – window, character, event monitor."""

    def __init__(self):
        self.root = tk.Tk()
        self._setup_window()
        self.cv = tk.Canvas(self.root, width=WIN_W, height=WIN_H,
                            bg=TRANSP, highlightthickness=0)
        self.cv.pack()

        # ── App state
        self.state        = 'idle'
        self.msg: str | None = None   # bubble text
        self.perm_id: str | None = None
        self.perm_cmd: str | None = None
        self.always_approve = False
        self.brown        = False     # False=부니, True=두니

        # ── Animation values
        self.body_dy  = 0.0
        self.body_dx  = 0.0
        self.larm_dx  = 0.0; self.larm_dy = 0.0
        self.rarm_dx  = 0.0; self.rarm_dy = 0.0
        self.show_kn  = False
        self.kn_phase = False
        self.blinking = False
        self.wide_eyes = False
        self.dot_count = 1
        self._usage           = 0.0   # 0.0 – 1.0 (컨텍스트 사용률)
        self._session_start: datetime.datetime | None = None  # sessionStartTs
        self._monthly_tokens: int = 0    # 이번 달 누적 토큰

        # ── After-job handles (to cancel)
        self._kn_job = self._dot_job = self._idle_job = None
        self._perm_win: tk.Toplevel | None = None

        # ── File monitoring state
        self._file_offset = 0

        # ── Build UI
        self._draw()
        self._position_window()

        # ── hwnd (available after window is mapped)
        self._hwnd: int | None = None
        self.root.after(300, self._init_hwnd)

        # ── Bindings
        self._build_menu()
        self.cv.bind('<Button-3>',        self._show_menu)
        self.cv.bind('<Double-Button-1>', lambda _e: self._open_claude())
        self.cv.bind('<ButtonPress-1>',   self._drag_press)
        self.cv.bind('<B1-Motion>',       self._drag_motion)
        self.cv.bind('<ButtonRelease-1>', self._drag_release)
        self._drag_start: tuple | None = None

        # ── Background monitoring thread
        threading.Thread(target=self._monitor_loop, daemon=True).start()

        # ── Schedule idle blink
        self._schedule_blink()

        # ── Optional system tray
        self._tray_thread: threading.Thread | None = None
        self._start_tray()

        self.root.mainloop()

    # ── Window ────────────────────────────────────────────────

    def _setup_window(self):
        r = self.root
        r.overrideredirect(True)
        r.wm_attributes('-topmost', True)
        r.wm_attributes('-transparentcolor', TRANSP)
        r.config(bg=TRANSP)
        r.resizable(False, False)
        r.title('Buni')

    def _position_window(self):
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        x = sw - WIN_W - 10
        y = sh - WIN_H - 50
        self.root.geometry(f'{WIN_W}x{WIN_H}+{x}+{y}')

    def _init_hwnd(self):
        try:
            self._hwnd = _get_hwnd(self.root)
            _set_click_through(self._hwnd, True)   # default: pass clicks through
            self.cv.bind('<Enter>', lambda _e: self._on_hover(True))
            self.cv.bind('<Leave>', lambda _e: self._on_hover(False))
        except Exception:
            pass

    def _on_hover(self, entering: bool):
        if self._hwnd:
            _set_click_through(self._hwnd, not entering)

    # ── Drag to reposition ────────────────────────────────────

    def _drag_press(self, e: tk.Event):
        self._drag_start = (e.x_root, e.y_root,
                            self.root.winfo_x(), self.root.winfo_y())
        if self._hwnd:
            _set_click_through(self._hwnd, False)

    def _drag_motion(self, e: tk.Event):
        if not self._drag_start:
            return
        sx, sy, wx, wy = self._drag_start
        nx = wx + (e.x_root - sx)
        ny = wy + (e.y_root - sy)
        self.root.geometry(f'+{nx}+{ny}')

    def _drag_release(self, _e: tk.Event):
        self._drag_start = None
        if self._hwnd:
            _set_click_through(self._hwnd, True)

    # ── Drawing helpers ───────────────────────────────────────

    def _px(self, ox: float, oy: float, w: float, h: float, color: str, tag='char'):
        """Pixel block at character-center offset (body_dy applied automatically)."""
        x = CHAR_CX + ox + self.body_dx
        y = CHAR_CY + oy + self.body_dy
        self.cv.create_rectangle(
            x - w*P/2, y - h*P/2,
            x + w*P/2, y + h*P/2,
            fill=color, outline='', tags=tag
        )

    def _line(self, ox1, oy1, ox2, oy2, color, width=1, tag='char'):
        x1 = CHAR_CX + ox1 + self.body_dx; y1 = CHAR_CY + oy1 + self.body_dy
        x2 = CHAR_CX + ox2 + self.body_dx; y2 = CHAR_CY + oy2 + self.body_dy
        self.cv.create_line(x1, y1, x2, y2, fill=color, width=width, tags=tag)

    def _oval(self, ox, oy, rx, ry, fill, outline='', tag='char'):
        x = CHAR_CX + ox + self.body_dx
        y = CHAR_CY + oy + self.body_dy
        self.cv.create_oval(x-rx, y-ry, x+rx, y+ry,
                            fill=fill, outline=outline, tags=tag)

    # ── Full redraw ───────────────────────────────────────────

    def _draw(self):
        self.cv.delete('all')
        self._draw_bubble()
        self._draw_char()
        self._draw_bar()

    def _draw_char(self):
        BDY = B_BODY if self.brown else W_BODY
        EAR = B_EAR  if self.brown else W_EAR

        # Ears (behind head)
        self._px(-P*1.6, -P*3.5,          1.6, 3.4, BDY)
        self._px(-P*1.6, -P*3.5 - P*0.1,  0.8, 2.7, EAR)
        self._px( P*1.6, -P*3.5,           1.6, 3.4, BDY)
        self._px( P*1.6, -P*3.5 - P*0.1,  0.8, 2.7, EAR)

        # Body
        self._px(0, P*1.5, 4.5, 2.5, BDY)

        # Arms (with knitting DX/DY)
        lx = -P*2.65 + self.larm_dx;  ly = P*1.1 + self.larm_dy
        rx =  P*2.65 + self.rarm_dx;  ry = P*1.1 + self.rarm_dy
        if self.show_kn:
            self._px(lx, ly, 1.9, 1.2, '#888888')   # border for visibility
            self._px(rx, ry, 1.9, 1.2, '#888888')
        self._px(lx, ly, 1.5, 0.9, BDY)
        self._px(rx, ry, 1.5, 0.9, BDY)

        # Feet
        self._px(-P*1.2, P*2.9, 1.5, 0.9, BDY)
        self._px( P*1.2, P*2.9, 1.5, 0.9, BDY)

        # Knitting elements (behind head)
        if self.show_kn:
            self._draw_knitting(lx, ly, rx, ry)

        # Head (over knitting)
        self._px(0, -P*0.8, 5.5, 2.5, BDY)

        # Eyebrows + stubble (두니 only)
        if self.brown:
            self._px(-P*1.45, -P*1.35, 0.95, 0.24, BROW_C)
            self._px( P*1.45, -P*1.35, 0.95, 0.24, BROW_C)
            self._px(-P*0.85, -P*0.10, 0.20, 0.20, BROW_C)
            self._px( P*0.85, -P*0.10, 0.20, 0.20, BROW_C)

        # Eyes
        ey = -P*0.9
        eh = 0.12 if self.blinking else (1.1 if self.wide_eyes else 0.75)
        self._px(-P*1.4, ey, 0.65, eh, BLACK)
        self._px( P*1.4, ey, 0.65, eh, BLACK)

        # Nose
        nc = B_EAR if self.brown else NOSE_C
        self._px(0, -P*0.25, 0.55, 0.40, nc)

    def _draw_knitting(self, lx, ly, rx, ry):
        # Yarn ball (bottom-left of character)
        bx, by = -P*1.6, P*3.15
        r = P*0.85
        self._oval(bx, by, r, r, CARROT, YARN_D)
        # Yarn strand lines on ball
        for angle in [0, 40, 80, 130, -40]:
            a = math.radians(angle)
            self._line(bx + r*math.cos(a+1.6), by + r*math.sin(a+1.6),
                       bx + r*math.cos(a-1.6), by + r*math.sin(a-1.6),
                       YARN_D, width=2)
        # Thread from ball to carrot
        self._line(bx, by - r, 0, P*2.65, CARROT, width=1)
        # Carrot leaves
        self._px(-P*0.35, P*1.15, 0.65, 0.55, LEAF)
        self._px( P*0.35, P*1.15, 0.65, 0.55, LEAF)
        self._px(0, P*1.5, 1.1, 0.5,  LEAF)
        self._px(0, P*2.1, 1.3, 1.1,  CARROT)
        # Needles (follow arm positions)
        for ax, ay, angle in [(lx, ly, 24), (rx, ry, -24)]:
            rad = math.radians(angle)
            hw = P*1.2
            x1 = CHAR_CX + ax - hw*math.cos(rad) + self.body_dx
            y1 = CHAR_CY + ay - hw*math.sin(rad) + self.body_dy
            x2 = CHAR_CX + ax + hw*math.cos(rad) + self.body_dx
            y2 = CHAR_CY + ay + hw*math.sin(rad) + self.body_dy
            self.cv.create_line(x1, y1, x2, y2, fill=NEEDLE, width=3, tags='char')

    def _rounded_rect(self, x0, y0, x1, y1, r, fill, outline, tag):
        """tkinter에는 rounded rectangle이 없어서 폴리곤으로 그림."""
        pts = [
            x0+r, y0,   x1-r, y0,
            x1,   y0,   x1,   y0+r,
            x1,   y1-r, x1,   y1,
            x1-r, y1,   x0+r, y1,
            x0,   y1,   x0,   y1-r,
            x0,   y0+r, x0,   y0,
        ]
        self.cv.create_polygon(pts, smooth=True,
                               fill=fill, outline=outline, width=1, tags=tag)

    def _draw_bubble(self):
        if not self.msg:
            return
        bx = CHAR_CX - P*5
        by = CHAR_CY - P*3.5
        text = self.msg
        pad = 10
        font = ('Malgun Gothic', 10)
        temp = self.cv.create_text(0, 0, text=text, font=font)
        bb = self.cv.bbox(temp)
        self.cv.delete(temp)
        tw = (bb[2] - bb[0]) if bb else 60
        th = (bb[3] - bb[1]) if bb else 14
        bw = tw + pad * 2
        bh = th + pad * 1.4
        r  = 8   # corner radius
        x0 = bx - bw; y0 = by - bh/2
        x1 = bx;      y1 = by + bh/2
        # Rounded bubble background
        self._rounded_rect(x0, y0, x1, y1, r, 'white', '#cccccc', 'bubble')
        # Tail (small triangle pointing right toward character)
        self.cv.create_polygon(x1-2, by - 5, x1 + 9, by, x1-2, by + 5,
                                fill='white', outline='', tags='bubble')
        self.cv.create_line(x1-2, by-5, x1+9, by, fill='#cccccc', width=1, tags='bubble')
        self.cv.create_line(x1+9, by, x1-2, by+5, fill='#cccccc', width=1, tags='bubble')
        # Text
        self.cv.create_text(x0 + pad, (y0+y1)/2, text=text, anchor='w',
                             font=font, fill='#222222', tags='bubble')

    def _draw_bar(self):
        if self.state == 'idle':
            return

        # ── 좌표 기준 (맥용과 동일한 비율)
        SEG   = 10; GAP = 2; BW = 1.5
        SH    = 9          # segment height
        bx    = CHAR_CX - P*3.3
        bar_y = CHAR_CY + P*4.0   # 게이지 바 top-y
        w     = P*6.6
        sw    = (w - GAP*(SEG-1)) / SEG

        filled = int(self._usage * SEG + 0.5)
        filled = max(0, min(SEG, filled))

        # ── 1. 레벨 (바 위 왼쪽, 맥용 size=7 bold)
        level = self._monthly_tokens // 500_000 + 1
        lv_y  = bar_y - 12
        self.cv.create_text(bx, lv_y, text=f'★ Lv.{level}',
                             anchor='w', font=('Consolas', 7, 'bold'),
                             fill='#F2CC25', tags='bar')

        # ── 2. 게이지 바 (라운드 테두리 + 세그먼트)
        r = 3   # corner radius (맥용 cornerRadius: 3)
        self._rounded_rect(bx - BW, bar_y - BW,
                           bx + w + BW, bar_y + SH + BW,
                           r, '', '#999999', 'bar')

        for i in range(SEG):
            ratio = (i+1)/SEG
            if ratio <= 0.50:   fc = '#4DDA59'
            elif ratio <= 0.75: fc = '#F2CC25'
            else:               fc = '#F24D33'
            color = fc if i < filled else '#151515'
            sx = bx + i*(sw+GAP)
            # 세그먼트 칸
            self.cv.create_rectangle(sx, bar_y, sx+sw, bar_y+SH,
                                      fill=color, outline='', tags='bar')
            # 채워진 세그먼트에 흰 하이라이트 (맥용과 동일)
            if i < filled:
                self.cv.create_rectangle(sx, bar_y, sx+sw, bar_y+2,
                                          fill='#ffffff47', outline='', tags='bar')

        # ── 3. 바 아래: 왼쪽 사용량%, 오른쪽 초기화시간 (맥용 size=7)
        label_y = bar_y + SH + 10
        pct_str = f'{round(self._usage * 100)}%'
        self.cv.create_text(bx, label_y, text=pct_str,
                             anchor='w', font=('Consolas', 7),
                             fill='#888888', tags='bar')

        reset_str = self._reset_time_str()
        if reset_str:
            self.cv.create_text(bx + w, label_y, text=f'↺ {reset_str}',
                                 anchor='e', font=('Consolas', 7),
                                 fill='#888888', tags='bar')

    def _reset_time_str(self) -> str:
        """sessionStart+5h 기준 남은 시간 (맥용과 동일한 로직)."""
        if self._session_start is None:
            return ''
        reset_at = self._session_start + datetime.timedelta(hours=5)
        now  = datetime.datetime.now(datetime.timezone.utc)
        diff = int((reset_at - now).total_seconds())
        if diff <= 0:
            return ''
        h = diff // 3600
        m = (diff % 3600) // 60
        return f'{h}:{m:02d}' if h > 0 else f'{m}m'

    # ── Bubble text ───────────────────────────────────────────

    def _set_msg(self, msg: str | None):
        self.msg = msg
        self.root.after(0, self._draw)

    # ── Dot animation for thinking ────────────────────────────

    def _start_dots(self):
        if self._dot_job:
            return
        self.dot_count = 1
        self._tick_dots()

    def _tick_dots(self):
        if self.state not in ('thinking',):
            self._dot_job = None
            return
        self.dot_count = self.dot_count % 3 + 1
        self.msg = '코드짜는중' + '.' * self.dot_count
        self._draw()
        self._dot_job = self.root.after(500, self._tick_dots)

    def _stop_dots(self):
        if self._dot_job:
            self.root.after_cancel(self._dot_job)
            self._dot_job = None

    # ── Knitting animation ────────────────────────────────────

    def _start_knitting(self):
        if self.show_kn:
            return
        self.larm_dx =  P*1.4; self.rarm_dx = -P*1.4
        self.larm_dy = -P*0.45; self.rarm_dy = -P*0.45
        self.show_kn = True
        self.kn_phase = False
        self._draw()
        self._tick_knitting()

    def _tick_knitting(self):
        if self.state not in ('thinking', 'toolUse'):
            self._kn_job = None
            return
        self.kn_phase = not self.kn_phase
        base  = -P*0.55; swing = P*0.38
        self.larm_dy = base - swing if self.kn_phase else base + swing
        self.rarm_dy = base + swing if self.kn_phase else base - swing
        self._draw()
        self._kn_job = self.root.after(360, self._tick_knitting)

    def _stop_knitting(self):
        if self._kn_job:
            self.root.after_cancel(self._kn_job); self._kn_job = None
        self.show_kn  = False
        self.larm_dx  = self.larm_dy = 0.0
        self.rarm_dx  = self.rarm_dy = 0.0

    # ── Notification bounce ───────────────────────────────────

    def _bounce(self):
        steps_up   = [(0, -i*P*0.4) for i in range(1, 6)]
        steps_down = [(0,  i*P*0.4) for i in range(4, -1, -1)]
        frames = steps_up + steps_down

        def step(i=0):
            if i >= len(frames):
                self.body_dy = 0; self._draw(); return
            self.body_dy = frames[i][1]
            self._draw()
            self.root.after(30, lambda: step(i+1))
        step()

    # ── Blink ─────────────────────────────────────────────────

    def _schedule_blink(self):
        import random
        delay = random.randint(2500, 6000)
        self.root.after(delay, self._do_blink)

    def _do_blink(self):
        self.blinking = True; self._draw()
        self.root.after(130, self._end_blink)

    def _end_blink(self):
        self.blinking = False; self._draw()
        self._schedule_blink()

    # ── State machine ─────────────────────────────────────────

    def _apply_state(self, new_state: str, tool: str | None = None,
                     notif: str | None = None,
                     perm_cmd: str | None = None, perm_id: str | None = None):
        self.root.after(0, lambda: self._do_apply(new_state, tool, notif, perm_cmd, perm_id))

    def _do_apply(self, new_state, tool, notif, perm_cmd, perm_id):
        prev = self.state
        self.state = new_state

        # Cancel knitting / dots when leaving those states
        if new_state not in ('thinking', 'toolUse'):
            self._stop_dots()
            self._stop_knitting()

        self.wide_eyes = False

        if new_state == 'idle':
            self.msg = None

        elif new_state == 'thinking':
            self._start_knitting()
            self._start_dots()

        elif new_state == 'toolUse':
            self._start_knitting()
            self._stop_dots()
            self.msg = tool or '작업 중...'

        elif new_state == 'notification':
            self.msg = notif
            self._bounce()
            self.root.after(5000, lambda: self._clear_msg_if(notif))

        elif new_state == 'permission':
            self.wide_eyes = True
            self.msg = None
            self.perm_cmd = perm_cmd
            self.perm_id  = perm_id
            self._show_perm_popup()

        elif new_state == 'ready':
            self.msg = None

        self._draw()

    def _clear_msg_if(self, old_msg):
        if self.msg == old_msg:
            self.msg = None
            self._draw()

    # ── Permission popup ──────────────────────────────────────

    def _show_perm_popup(self):
        if self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()

        win = tk.Toplevel(self.root)
        self._perm_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.config(bg='white')

        # Position left of character
        rx = self.root.winfo_x(); ry = self.root.winfo_y()
        win.geometry(f'230x160+{rx-235}+{ry+20}')

        tk.Label(win, text='🔐 실행 허용?', font=('Consolas', 11, 'bold'),
                 bg='white').pack(anchor='w', padx=12, pady=(10,2))

        cmd_box = tk.Text(win, height=4, font=('Consolas', 9),
                          bg='#F0F0F0', relief='flat', wrap='word')
        cmd_box.insert('1.0', self.perm_cmd or '')
        cmd_box.config(state='disabled')
        cmd_box.pack(fill='x', padx=12, pady=4)

        btn_f = tk.Frame(win, bg='white')
        btn_f.pack(padx=12, pady=(4,10))

        def _btn(text, fg, cmd):
            b = tk.Button(btn_f, text=text, font=('Consolas', 9, 'bold'),
                          fg='white', bg=fg, relief='flat',
                          padx=8, pady=4, command=cmd)
            b.pack(side='left', padx=3)

        _btn('거부',     '#D93A2F', lambda: self._decide('deny'))
        _btn('허용',     '#2DB357', lambda: self._decide('approve'))
        _btn('전체 허용', '#3D7FE0', lambda: self._decide('approve_all'))

    def _decide(self, action: str):
        if self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()
        pid = self.perm_id
        if not pid:
            return
        if action == 'approve_all':
            self.always_approve = True
            action = 'approve'
        decision = 'approve' if action == 'approve' else 'deny'
        fpath = _TEMP / f'claude-companion-decision-{pid}'
        try:
            fpath.write_text(decision)
        except Exception:
            pass
        self.perm_id = None
        self._apply_state('thinking')

    # ── Usage bar ─────────────────────────────────────────────

    def _set_usage(self, pct: float, session_start_ts: str | None = None):
        self._usage = max(0.0, min(1.0, pct / 100.0))
        if session_start_ts:
            try:
                ts = session_start_ts.replace('Z', '+00:00')
                parsed = datetime.datetime.fromisoformat(ts)
                # 더 이른 시각이면 교체 (맥용 동일 로직)
                if self._session_start is None or parsed < self._session_start:
                    self._session_start = parsed
            except Exception:
                pass
        self._draw()

    def _read_monthly_tokens(self):
        """~/.claude/projects 폴더의 JSONL에서 이번 달 토큰 합산."""
        try:
            projects_dir = Path.home() / '.claude' / 'projects'
            if not projects_dir.exists():
                return
            now = datetime.datetime.now()
            total = 0
            for jf in projects_dir.rglob('*.jsonl'):
                try:
                    for line in jf.read_text(encoding='utf-8', errors='replace').splitlines():
                        if not line.strip():
                            continue
                        obj = json.loads(line)
                        # timestamp 필드로 이번 달 필터
                        ts_str = obj.get('timestamp', '')
                        if ts_str:
                            try:
                                ts = datetime.datetime.fromisoformat(
                                    ts_str.replace('Z', '+00:00'))
                                if ts.year != now.year or ts.month != now.month:
                                    continue
                            except Exception:
                                continue
                        msg = obj.get('message', {})
                        usage = msg.get('usage', {}) if isinstance(msg, dict) else {}
                        total += usage.get('input_tokens', 0)
                        total += usage.get('output_tokens', 0)
                except Exception:
                    continue
            self._monthly_tokens = total
        except Exception:
            pass

    # ── Context menu ──────────────────────────────────────────

    def _build_menu(self):
        self._menu = tk.Menu(self.root, tearoff=0)
        self._menu.add_command(label='Claude 열기',
                               command=self._open_claude)
        self._menu.add_separator()
        self._menu.add_command(label='부니 (흰토끼)',
                               command=lambda: self._set_char(False))
        self._menu.add_command(label='두니 (갈색토끼)',
                               command=lambda: self._set_char(True))
        self._menu.add_separator()
        self._menu.add_command(label='위치 초기화',
                               command=self._reset_position)
        self._menu.add_separator()
        self._menu.add_command(label='종료',
                               command=self._quit)

    def _show_menu(self, e: tk.Event):
        try:
            self._menu.tk_popup(e.x_root, e.y_root)
        finally:
            self._menu.grab_release()

    def _open_claude(self):
        os.startfile('claude')  # opens Claude desktop if associated

    def _set_char(self, brown: bool):
        self.brown = brown
        self._draw()

    def _reset_position(self):
        self._position_window()

    def _quit(self):
        self.root.destroy()
        sys.exit(0)

    # ── System tray ───────────────────────────────────────────

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except ImportError:
            return   # pystray/Pillow not installed – skip tray

        def make_icon():
            img = Image.new('RGB', (32, 32), '#9A6633')
            d = ImageDraw.Draw(img)
            d.ellipse([8, 4, 24, 20], fill='#E8E8F0')   # head
            return img

        def on_quit(icon, _item):
            icon.stop()
            self.root.after(0, self._quit)

        def on_toggle(icon, _item):
            self.root.after(0, lambda: (
                self.root.withdraw() if self.root.state() == 'normal'
                else self.root.deiconify()
            ))

        icon = pystray.Icon('Buni', make_icon(), 'Buni',
                            pystray.Menu(
                                pystray.MenuItem('보이기/숨기기', on_toggle),
                                pystray.MenuItem('종료', on_quit),
                            ))
        self._tray_thread = threading.Thread(target=icon.run, daemon=True)
        self._tray_thread.start()

    # ── Claude process detection ──────────────────────────────

    @staticmethod
    def _is_claude_running() -> bool:
        try:
            import subprocess
            CREATE_NO_WINDOW = 0x08000000
            out = subprocess.check_output(
                ['tasklist', '/FI', 'IMAGENAME eq claude.exe', '/NH'],
                stderr=subprocess.DEVNULL,
                text=True,
                creationflags=CREATE_NO_WINDOW,
            )
            return 'claude.exe' in out.lower()
        except Exception:
            return False

    # ── Event file monitor ────────────────────────────────────

    def _monitor_loop(self):
        claude_running = False
        EVENTS_FILE.parent.mkdir(parents=True, exist_ok=True)
        if not EVENTS_FILE.exists():
            EVENTS_FILE.touch()
        self._file_offset = EVENTS_FILE.stat().st_size

        # 앱 시작 시 월별 토큰 즉시 읽기
        self._read_monthly_tokens()
        self.root.after(0, self._draw)

        tick = 0
        while True:
            # Process detection
            running = self._is_claude_running()
            if running != claude_running:
                claude_running = running
                if running:
                    # 새 세션 시작 시 session_start 초기화
                    if self._session_start is None:
                        self._session_start = datetime.datetime.now(datetime.timezone.utc)
                    self._apply_state('ready')
                else:
                    self._session_start = None
                    self._apply_state('idle')
            # Poll event file
            self._poll_file()
            # 5분마다 월별 토큰 갱신
            tick += 1
            if tick % 600 == 0:
                self._read_monthly_tokens()
                self.root.after(0, self._draw)
            time.sleep(0.5)

    def _poll_file(self):
        try:
            size = EVENTS_FILE.stat().st_size
        except FileNotFoundError:
            return
        if size <= self._file_offset:
            return
        with EVENTS_FILE.open('r', encoding='utf-8', errors='replace') as f:
            f.seek(self._file_offset)
            new_data = f.read()
        self._file_offset = EVENTS_FILE.stat().st_size
        for line in new_data.splitlines():
            if line.strip():
                self._handle_event(line)

    def _handle_event(self, raw: str):
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            return
        t = ev.get('type', '')

        if t == 'tool_use':
            tool = self._fmt_tool(ev.get('tool', 'tool'))
            self._apply_state('toolUse', tool=tool)

        elif t == 'tool_done':
            self._apply_state('thinking')

        elif t == 'done':
            self._apply_state('ready')

        elif t == 'notification':
            self._apply_state('notification', notif=ev.get('message', '알림'))

        elif t == 'permission_request':
            pid = ev.get('id')
            cmd = ev.get('message', '명령')
            if pid and self.always_approve:
                fpath = _TEMP / f'claude-companion-decision-{pid}'
                try:
                    fpath.write_text('approve')
                except Exception:
                    pass
            elif pid:
                self._apply_state('permission', perm_cmd=cmd, perm_id=pid)

        elif t == 'usage':
            pct = ev.get('percent', 0)
            sts = ev.get('sessionStartTs', None)
            self.root.after(0, lambda p=pct, s=sts: self._set_usage(p, s))

    @staticmethod
    def _fmt_tool(raw: str) -> str:
        return {
            'bash':      '터미널 명령 실행 중',
            'read':      '파일 읽는 중',
            'write':     '파일 쓰는 중',
            'edit':      '파일 수정 중',
            'glob':      '파일 검색 중',
            'grep':      '코드 검색 중',
            'websearch': '웹 검색 중',
            'webfetch':  '페이지 읽는 중',
            'todowrite': '할 일 정리 중',
        }.get(raw.lower(), f'{raw} 실행 중')


# ── Entry point ───────────────────────────────────────────────

if __name__ == '__main__':
    BuniApp()
