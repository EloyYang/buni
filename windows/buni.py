#!/usr/bin/env python3
"""
Buni for Windows v1.2.0
Claude Code companion – pixel-art rabbit mascot
https://github.com/EloyYang/buni
"""
import tkinter as tk
from tkinter import simpledialog
import threading
import json, time, os, sys, math, glob, random, re, base64
import ctypes, datetime, queue
from pathlib import Path

# ── Pixel unit (matches macOS p = 6.5)
P = 6.5

# ── Window geometry
WIN_W, WIN_H = 340, 240
CHAR_CX      = WIN_W - 52    # character center-X
CHAR_CY      = WIN_H - 80    # character center-Y
SLOT_STEP    = WIN_H + 8     # vertical spacing between session slots

# ── Transparent key color
TRANSP = '#010101'

# ── Character palettes: (body, ear, nose, extras_dict)
#    extras keys: 'brow' (hex color), 'blush' (bool)
CHARACTERS = {
    'rabbit':       ('#E8E8F0', '#F3B8C7', '#E09090', {}),
    'brownRabbit':  ('#9A6633', '#C47844', '#C47844', {'brow': '#35180A'}),
    'pinkRabbit':   ('#FAC7E0', '#FFEAF5', '#F25999', {}),
    'orangeRabbit': ('#F28520', '#FFD199', '#FFE6CC', {}),
    'yellowRabbit': ('#F5DB38', '#FFF5B8', '#FFF2BF', {'blush': True}),
    'greenRabbit':  ('#73CC61', '#C7F2AD', '#D1F2C7', {}),
}
CHAR_DISPLAY_NAMES = {
    'rabbit':       '부니 (흰토끼)',
    'brownRabbit':  '두니 (갈색토끼)',
    'pinkRabbit':   '푸니 (핑크토끼)',
    'orangeRabbit': '주니 (주황토끼)',
    'yellowRabbit': '누니 (노란토끼)',
    'greenRabbit':  '우니 (연두토끼)',
}

# ── Tool classification: read tools → toolRead state
READ_TOOLS = {'read', 'glob', 'grep', 'ls', 'webfetch', 'websearch', 'todoread'}

# ── Laptop colors (from LaptopView.swift)
LAP_SILVER = '#C2C2CC'  # silverCol rgb(0.76,0.76,0.80)
LAP_HI     = '#E0E0EB'  # silverHi  rgb(0.88,0.88,0.92)
LAP_DARK   = '#808089'  # silverDark rgb(0.50,0.50,0.54)
LAP_MID    = '#A3A3AD'  # silverMid  rgb(0.64,0.64,0.68)
LAP_APPLE  = '#EBEBF2'  # appleCol   rgb(0.92,0.92,0.95)

# ── Document colors (from DocumentView.swift)
DOC_PAPER  = '#EDE3C7'  # paperCol  rgb(0.93,0.89,0.78)
DOC_DARK   = '#CCC1A6'  # paperDark rgb(0.80,0.76,0.65)
DOC_LINE_H = '#8C8069'  # lineHeavy rgb(0.55,0.50,0.42)
DOC_LINE_L = '#9E9078'  # lineLight (lighter)
TAB_PINK   = '#FA6699'
TAB_YELLOW = '#FAD633'
TAB_GREEN  = '#47BF59'

# ── Paths
_TEMP      = Path(os.environ.get('TEMP', os.environ.get('TMP', 'C:/temp')))
STATE_FILE = Path.home() / 'AppData' / 'Roaming' / 'Buni' / 'state.json'
PID_FILE   = _TEMP / 'buni.pid'

# ── Windows API for click-through transparent window
_u32              = ctypes.windll.user32
GWL_EXSTYLE       = -20
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


# ══════════════════════════════════════════════════════════════
class GlobalHotkeyManager:
    """Windows RegisterHotKey 기반 전역 단축키 관리자."""

    WM_HOTKEY    = 0x0312
    MOD_ALT      = 0x0001
    MOD_CTRL     = 0x0002
    MOD_SHIFT    = 0x0004
    MOD_WIN      = 0x0008
    MOD_NOREPEAT = 0x4000

    _VK_NAMES: dict = {
        0x08:'Back', 0x09:'Tab', 0x0D:'Enter', 0x1B:'Esc', 0x20:'Space',
        0x25:'←', 0x26:'↑', 0x27:'→', 0x28:'↓',
        **{0x70+i: f'F{i+1}' for i in range(12)},
        **{0x41+i: chr(65+i)  for i in range(26)},
        **{0x30+i: str(i)      for i in range(10)},
    }

    def __init__(self):
        self._pending : list  = []
        self._lock            = threading.Lock()
        self._q               = queue.SimpleQueue()
        self._reg    : dict   = {}   # action → (mods, vk, hid)
        self._id_map : dict   = {}   # hid → action
        self._next_id         = 300
        self._callbacks: dict = {}

    @classmethod
    def label(cls, mods: int, vk: int) -> str:
        parts = []
        if mods & cls.MOD_CTRL:  parts.append('Ctrl')
        if mods & cls.MOD_ALT:   parts.append('Alt')
        if mods & cls.MOD_SHIFT: parts.append('Shift')
        if mods & cls.MOD_WIN:   parts.append('Win')
        parts.append(cls._VK_NAMES.get(vk, f'[{vk}]'))
        return '+'.join(parts)

    def set_shortcut(self, action: str, mods: int, vk: int):
        with self._lock:
            self._pending.append(('set', action, mods, vk))

    def clear_shortcut(self, action: str):
        with self._lock:
            self._pending.append(('clear', action))

    def start(self, tk_root: tk.Tk, callbacks: dict):
        self._callbacks = callbacks
        threading.Thread(target=self._loop, daemon=True).start()
        self._poll(tk_root)

    def _poll(self, tk_root: tk.Tk):
        try:
            while True:
                action = self._q.get_nowait()
                cb = self._callbacks.get(action)
                if cb:
                    cb()
        except queue.Empty:
            pass
        tk_root.after(50, lambda: self._poll(tk_root))

    def _loop(self):
        class _P(ctypes.Structure):
            _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]
        class _M(ctypes.Structure):
            _fields_ = [
                ('hwnd',    ctypes.c_void_p),
                ('message', ctypes.c_uint),
                ('wParam',  ctypes.c_size_t),
                ('lParam',  ctypes.c_ssize_t),
                ('time',    ctypes.c_ulong),
                ('pt',      _P),
            ]
        u32 = ctypes.windll.user32
        msg = _M()
        while True:
            with self._lock:
                pending, self._pending = self._pending[:], []
            for item in pending:
                op = item[0]
                if op == 'set':
                    _, action, mods, vk = item
                    if action in self._reg and self._reg[action][2] != -1:
                        u32.UnregisterHotKey(None, self._reg[action][2])
                        self._id_map.pop(self._reg[action][2], None)
                    hid = self._next_id; self._next_id += 1
                    ok = u32.RegisterHotKey(None, hid, mods | self.MOD_NOREPEAT, vk)
                    if ok:
                        self._reg[action] = (mods, vk, hid)
                        self._id_map[hid] = action
                    else:
                        self._reg[action] = (mods, vk, -1)  # 저장만
                elif op == 'clear':
                    _, action = item
                    if action in self._reg:
                        hid = self._reg[action][2]
                        if hid != -1:
                            u32.UnregisterHotKey(None, hid)
                            self._id_map.pop(hid, None)
                        del self._reg[action]
            if u32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
                if msg.message == self.WM_HOTKEY:
                    action = self._id_map.get(msg.wParam)
                    if action:
                        self._q.put(action)
            else:
                time.sleep(0.005)


# ══════════════════════════════════════════════════════════════
class ShortcutSettingsWindow:
    """전역 단축키 설정 다이얼로그."""

    ACTIONS = [
        ('approve',        '권한 허락'),
        ('always_approve', '전체 허용'),
        ('deny',           '권한 거부'),
        ('hide',           '숨기기/보이기'),
    ]

    def __init__(self, parent: tk.Tk, persist: 'PersistenceManager',
                 hotkey_mgr: GlobalHotkeyManager):
        self._parent    = parent
        self._persist   = persist
        self._hotkey    = hotkey_mgr
        self._shortcuts : dict = {}  # action → (mods, vk) | None
        self._recording : str | None = None
        self._btns      : dict = {}
        self._win       : tk.Toplevel | None = None
        self._load()
        self._build()

    # ── 저장/불러오기 ─────────────────────────────────────
    def _load(self):
        saved = self._persist.get('shortcuts', {})
        defaults = {'approve': (GlobalHotkeyManager.MOD_CTRL, 0x0D)}  # Ctrl+Enter
        for action, _ in self.ACTIONS:
            v = saved.get(action)
            if v:
                self._shortcuts[action] = (v['mods'], v['vk'])
            elif action in defaults:
                self._shortcuts[action] = defaults[action]
            else:
                self._shortcuts[action] = None
        # 초기 단축키 등록
        for action, v in self._shortcuts.items():
            if v:
                self._hotkey.set_shortcut(action, v[0], v[1])

    def _save(self):
        data = {}
        for action, _ in self.ACTIONS:
            v = self._shortcuts.get(action)
            data[action] = {'mods': v[0], 'vk': v[1]} if v else None
        self._persist.set('shortcuts', data)
        for action, _ in self.ACTIONS:
            v = self._shortcuts.get(action)
            if v:
                self._hotkey.set_shortcut(action, v[0], v[1])
            else:
                self._hotkey.clear_shortcut(action)

    # ── UI 구성 ───────────────────────────────────────────
    def _build(self):
        if self._win and self._win.winfo_exists():
            self._win.lift(); self._win.focus_force(); return

        win = tk.Toplevel(self._parent)
        self._win = win
        win.title('단축키 설정')
        win.resizable(False, False)
        win.configure(bg='#1E1E24')
        win.protocol('WM_DELETE_WINDOW', self._close)
        win.attributes('-topmost', True)

        tk.Label(win, text='단축키 설정', bg='#1E1E24', fg='white',
                 font=('Malgun Gothic', 13, 'bold')).grid(
            row=0, column=0, columnspan=3, pady=(16,4), padx=20, sticky='w')
        tk.Frame(win, bg='#3A3A44', height=1).grid(
            row=1, column=0, columnspan=3, sticky='ew', padx=16, pady=(0,10))

        for i, (action, label) in enumerate(self.ACTIONS):
            tk.Label(win, text=label, bg='#1E1E24', fg='#CCCCCC',
                     font=('Malgun Gothic', 10), width=11, anchor='w').grid(
                row=2+i, column=0, padx=(20,8), pady=6, sticky='w')

            btn = tk.Button(win, text=self._btn_text(action),
                            bg='#2A2A34', fg='white', relief='flat',
                            font=('Consolas', 9), width=16,
                            activebackground='#3A3A50', activeforeground='white',
                            cursor='hand2',
                            command=lambda a=action: self._toggle_record(a))
            btn.grid(row=2+i, column=1, padx=4, pady=6)
            self._btns[action] = btn

            tk.Button(win, text='✕', bg='#1E1E24', fg='#FF6666', relief='flat',
                      font=('Consolas', 10), activebackground='#1E1E24',
                      activeforeground='#FF4444', cursor='hand2',
                      command=lambda a=action: self._clear(a)).grid(
                row=2+i, column=2, padx=(2,16), pady=6)

        r = 2 + len(self.ACTIONS)
        tk.Frame(win, bg='#3A3A44', height=1).grid(
            row=r, column=0, columnspan=3, sticky='ew', padx=16, pady=(8,4))
        tk.Label(win, text='단축키는 전역으로 동작합니다.',
                 bg='#1E1E24', fg='#555566',
                 font=('Malgun Gothic', 8)).grid(
            row=r+1, column=0, columnspan=2, padx=20, sticky='w', pady=(4,0))
        tk.Button(win, text='닫기', bg='#3377E0', fg='white', relief='flat',
                  font=('Malgun Gothic', 10), activebackground='#2255BB',
                  activeforeground='white', cursor='hand2', padx=12, pady=3,
                  command=self._close).grid(
            row=r+1, column=2, padx=16, pady=(4,16), sticky='e')

        win.bind('<Escape>', lambda _: self._close())
        win.update_idletasks()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        w, h   = win.winfo_reqwidth(),    win.winfo_reqheight()
        win.geometry(f'+{(sw-w)//2}+{(sh-h)//2}')

    def _btn_text(self, action: str) -> str:
        v = self._shortcuts.get(action)
        return GlobalHotkeyManager.label(v[0], v[1]) if v else '(없음)'

    def _toggle_record(self, action: str):
        if self._recording == action:
            self._stop_record(action); return
        if self._recording:
            self._stop_record(self._recording)
        self._recording = action
        self._btns[action].config(text='키 입력 대기...', bg='#4A3A00', fg='#FFDD00')
        self._win.bind('<KeyPress>', self._on_key)
        self._win.focus_force()

    def _stop_record(self, action: str):
        self._recording = None
        self._btns[action].config(text=self._btn_text(action),
                                   bg='#2A2A34', fg='white')
        try: self._win.unbind('<KeyPress>')
        except Exception: pass

    def _on_key(self, e: tk.Event):
        # 수정자 단독 입력 무시
        if e.keysym in ('Control_L','Control_R','Alt_L','Alt_R',
                        'Shift_L','Shift_R','Super_L','Super_R'):
            return
        action = self._recording
        if not action: return
        if e.keysym == 'Escape':           # ESC = 취소
            self._stop_record(action); return
        mods = 0
        if e.state & 0x0001:   mods |= GlobalHotkeyManager.MOD_SHIFT
        if e.state & 0x0004:   mods |= GlobalHotkeyManager.MOD_CTRL
        if e.state & 0x20000:  mods |= GlobalHotkeyManager.MOD_ALT
        vk = e.keycode
        self._shortcuts[action] = (mods, vk)
        self._stop_record(action)
        self._save()

    def _clear(self, action: str):
        if self._recording == action:
            self._stop_record(action)
        self._shortcuts[action] = None
        self._btns[action].config(text='(없음)')
        self._save()

    def _close(self):
        if self._recording:
            self._stop_record(self._recording)
        if self._win:
            try: self._win.destroy()
            except Exception: pass
            self._win = None

    def show(self):
        if self._win and self._win.winfo_exists():
            self._win.lift(); self._win.focus_force()
        else:
            self._build()

    def is_open(self) -> bool:
        return bool(self._win and self._win.winfo_exists())


# ══════════════════════════════════════════════════════════════
class PersistenceManager:
    """JSON-backed key-value store (character, memo, window position)."""

    def __init__(self):
        self._data: dict = {}
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        try:
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            if STATE_FILE.exists():
                self._data = json.loads(
                    STATE_FILE.read_text(encoding='utf-8'))
        except Exception:
            self._data = {}

    def save(self):
        try:
            with self._lock:
                STATE_FILE.write_text(
                    json.dumps(self._data, indent=2, ensure_ascii=False),
                    encoding='utf-8')
        except Exception:
            pass

    def get(self, key, default=None):
        with self._lock:
            return self._data.get(key, default)

    def set(self, key, value):
        with self._lock:
            self._data[key] = value
        self.save()

    def remove(self, key):
        with self._lock:
            self._data.pop(key, None)
        self.save()


# ══════════════════════════════════════════════════════════════
class SessionWindow:
    """One Toplevel window per active Claude session."""

    def __init__(self, manager: 'BuniManager', session_id: str, slot: int,
                 event_file: Path, persist: PersistenceManager):
        self.manager    = manager
        self.session_id = session_id
        self.slot       = slot
        self.event_file = event_file
        self.persist    = persist

        # ── Toplevel
        self.win = tk.Toplevel(manager.root)
        self._setup_window()
        self.cv = tk.Canvas(self.win, width=WIN_W, height=WIN_H,
                            bg=TRANSP, highlightthickness=0)
        self.cv.pack()

        # ── Character & memo
        self.character: str = self._load_character()
        self.memo:      str = self._load_memo()

        # ── Body/arm animation floats
        self.body_dy  = 0.0;  self.body_dx  = 0.0
        self.larm_dx  = 0.0;  self.larm_dy  = 0.0
        self.rarm_dx  = 0.0;  self.rarm_dy  = 0.0

        # ── Laptop typing state
        self.show_laptop  = False
        self.laptop_phase = False

        # ── Document reading state
        self.show_reading = False
        self._reading_step = 0
        self.throw_dx  = 0.0;  self.throw_dy = 0.0
        self.doc_visible  = True

        # ── Eyes
        self.blinking   = False
        self.wide_eyes  = False

        # ── App state
        self.state          = 'idle'
        self.msg: str | None = None
        self.perm_id: str | None   = None
        self.perm_cmd: str | None  = None
        self.always_approve = False

        # ── Usage
        self._usage                = 0.0
        self._session_start: datetime.datetime | None = None
        self._monthly_tokens: int  = 0
        self._server_utilization: float | None        = None
        self._server_resets_at: datetime.datetime | None = None

        # ── After handles
        self._laptop_job   = None
        self._reading_job  = None
        self._blink_job    = None
        self._idle_job     = None
        self._perm_win: tk.Toplevel | None = None
        self._destroyed    = False

        # ── File monitoring
        self._file_offset = 0
        self._last_event_time = time.time()
        self._init_file_offset()

        # ── HWND (after window is mapped)
        self._hwnd: int | None = None
        self.win.after(300, self._init_hwnd)

        # ── Position & initial draw
        self._position_window()
        self._draw()

        # ── Bindings
        self._build_menu()
        self.cv.bind('<Button-3>',        self._show_menu)
        self.cv.bind('<Double-Button-1>', lambda _: self._open_claude())
        self.cv.bind('<ButtonPress-1>',   self._drag_press)
        self.cv.bind('<B1-Motion>',       self._drag_motion)
        self.cv.bind('<ButtonRelease-1>', self._drag_release)
        self._drag_start: tuple | None = None

        # ── Start
        self._apply_state('ready')
        self._schedule_blink()
        self._schedule_idle_hop()
        self._tick_bar_refresh()

    # ── Persistence ───────────────────────────────────────────

    def _load_character(self) -> str:
        char = (self.persist.get(f'character.session.{self.session_id}') or
                self.persist.get(f'character.slot.{self.slot}') or 'rabbit')
        return char if char in CHARACTERS else 'rabbit'

    def _load_memo(self) -> str:
        return (self.persist.get(f'memo.session.{self.session_id}') or
                self.persist.get(f'memo.slot.{self.slot}') or '')

    def _save_character(self):
        self.persist.set(f'character.session.{self.session_id}', self.character)
        self.persist.set(f'character.slot.{self.slot}', self.character)

    def _save_memo(self):
        ks = f'memo.session.{self.session_id}'
        kl = f'memo.slot.{self.slot}'
        if self.memo:
            self.persist.set(ks, self.memo)
            self.persist.set(kl, self.memo)
        else:
            self.persist.remove(ks)
            self.persist.remove(kl)

    # ── Window setup ──────────────────────────────────────────

    def _setup_window(self):
        w = self.win
        w.overrideredirect(True)
        w.wm_attributes('-topmost', True)
        w.wm_attributes('-transparentcolor', TRANSP)
        w.config(bg=TRANSP)
        w.resizable(False, False)
        w.title(f'Buni-{self.slot}')

    def _position_window(self):
        sw = self.win.winfo_screenwidth()
        if self.slot == 0:
            saved = self.persist.get('window_pos')
            if saved and isinstance(saved, (list, tuple)) and len(saved) == 2:
                try:
                    x, y = int(saved[0]), int(saved[1])
                    self.win.geometry(f'{WIN_W}x{WIN_H}+{x}+{y}')
                    return
                except Exception:
                    pass
        # Top-right corner, slots stack downward
        x = sw - WIN_W - 10
        y = 50 + self.slot * SLOT_STEP
        self.win.geometry(f'{WIN_W}x{WIN_H}+{x}+{y}')

    def _init_hwnd(self):
        try:
            self._hwnd = _get_hwnd(self.win)
            _set_click_through(self._hwnd, True)
        except Exception:
            pass
        # <Enter>/<Leave>는 WS_EX_TRANSPARENT 상태에서 OS 이벤트가 도달하지 않아
        # 절대 발생하지 않음 → 30ms 폴링으로 마우스 위치를 직접 확인
        self._poll_click_through()

    def _poll_click_through(self):
        """30ms마다 마우스가 창 위에 있는지 확인해 클릭 투과를 토글."""
        if self._destroyed or not self._hwnd:
            return
        try:
            mx = self.win.winfo_pointerx()
            my = self.win.winfo_pointery()
            wx = self.win.winfo_rootx()
            wy = self.win.winfo_rooty()
            over = wx <= mx < wx + WIN_W and wy <= my < wy + WIN_H
            _set_click_through(self._hwnd, not over)
        except Exception:
            pass
        self.win.after(30, self._poll_click_through)

    # ── Drag ─────────────────────────────────────────────────

    def _drag_press(self, e: tk.Event):
        self._drag_start = (e.x_root, e.y_root,
                            self.win.winfo_x(), self.win.winfo_y())
        if self._hwnd:
            _set_click_through(self._hwnd, False)

    def _drag_motion(self, e: tk.Event):
        if not self._drag_start:
            return
        sx, sy, wx, wy = self._drag_start
        new_x = wx + e.x_root - sx
        new_y = wy + e.y_root - sy
        self.win.geometry(f'+{new_x}+{new_y}')
        # 권한 팝업도 같이 이동
        if self._perm_win and self._perm_win.winfo_exists():
            self._reposition_perm_popup(new_x, new_y)

    def _reposition_perm_popup(self, win_x: int, win_y: int):
        """캐릭터 창 좌표(win_x, win_y) 기준으로 권한 팝업 재배치."""
        if not (self._perm_win and self._perm_win.winfo_exists()):
            return
        try:
            BW, TAIL_W = 230, 15
            ph = self._perm_win.winfo_height()
            if ph < 10:
                ph = 156  # 초기 렌더 전 폴백 높이
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            px = win_x + tail_tip_x - (BW + TAIL_W)
            py = win_y + int(CHAR_CY - P * 3.5) - ph // 2
            self._perm_win.geometry(f'+{px}+{py}')
        except Exception:
            pass

    def _drag_release(self, _e: tk.Event):
        self._drag_start = None
        if self._hwnd:
            _set_click_through(self._hwnd, True)
        if self.slot == 0:
            self.persist.set('window_pos',
                             [self.win.winfo_x(), self.win.winfo_y()])

    # ── Drawing helpers ───────────────────────────────────────

    def _rect(self, ox: float, oy: float, w: float, h: float,
              color: str, tag: str = 'char') -> None:
        """Pixel block at character-center offset (body_dx/dy applied)."""
        x = CHAR_CX + ox + self.body_dx
        y = CHAR_CY + oy + self.body_dy
        self.cv.create_rectangle(x - w*P/2, y - h*P/2,
                                  x + w*P/2, y + h*P/2,
                                  fill=color, outline='', tags=tag)

    def _oval(self, ox: float, oy: float, w: float, h: float,
              color: str, tag: str = 'char') -> None:
        """Ellipse at character-center offset (body_dx/dy applied)."""
        x = CHAR_CX + ox + self.body_dx
        y = CHAR_CY + oy + self.body_dy
        self.cv.create_oval(x - w*P/2, y - h*P/2,
                             x + w*P/2, y + h*P/2,
                             fill=color, outline='', tags=tag)

    def _rounded_rect(self, x0, y0, x1, y1, r, fill, outline, tag='misc'):
        pts = [x0+r, y0,  x1-r, y0,  x1,  y0,   x1,  y0+r,
               x1,  y1-r, x1,  y1,   x1-r, y1,  x0+r, y1,
               x0,  y1,   x0,  y1-r, x0,  y0+r, x0,  y0]
        self.cv.create_polygon(pts, smooth=True,
                                fill=fill, outline=outline, width=1, tags=tag)

    # ── Full redraw (draw order matches macOS z-order) ────────

    def _draw(self):
        if self._destroyed:
            return
        self.cv.delete('all')
        # 1. Speech bubble (behind everything)
        self._draw_bubble()
        # 2. Paper pile (far left, background)
        if self.show_reading:
            self._draw_doc_pile()
        # 3. Ears (behind head)
        self._draw_ears()
        # 4. Body + arms
        self._draw_body_arms()
        # 5. Laptop (on top of arms, below head)
        if self.show_laptop:
            self._draw_laptop()
        # 6. Feet
        self._draw_feet()
        # 7. Held document (in front of body, behind head)
        if self.show_reading and self.doc_visible:
            self._draw_held_doc()
        # 8. Head (topmost character layer)
        self._draw_head()
        # 9. Usage bar
        self._draw_bar()
        # 10. Memo tag (above ears)
        self._draw_memo()

    # ── Character parts ───────────────────────────────────────

    def _draw_ears(self):
        body, ear, *_ = CHARACTERS[self.character]
        ch = self.character
        # Ear dimensions per character (matching Swift views)
        if ch == 'pinkRabbit':
            ow, oh, iw, ih, xo, yo = 1.65, 3.4, 0.85, 2.7, P*1.55, P*3.5
        elif ch == 'orangeRabbit':
            ow, oh, iw, ih, xo, yo = 1.6,  3.3, 0.8,  2.6, P*1.7,  P*3.4
        elif ch == 'yellowRabbit':
            ow, oh, iw, ih, xo, yo = 1.6,  3.8, 0.8,  3.1, P*1.5,  P*3.8
        elif ch == 'greenRabbit':
            ow, oh, iw, ih, xo, yo = 1.8,  3.2, 1.0,  2.5, P*1.5,  P*3.3
        else:  # rabbit, brownRabbit
            ow, oh, iw, ih, xo, yo = 1.6,  3.4, 0.8,  2.7, P*1.6,  P*3.5
        self._rect(-xo, -yo,        ow, oh, body)
        self._rect(-xo, -yo-P*0.1,  iw, ih, ear)
        self._rect( xo, -yo,        ow, oh, body)
        self._rect( xo, -yo-P*0.1,  iw, ih, ear)

    def _draw_body_arms(self):
        body, ear, nose, extras = CHARACTERS[self.character]
        ch = self.character
        # Body size per character
        if ch == 'orangeRabbit':
            self._rect(0, P*1.5, 4.7, 2.6, body)
        elif ch in ('pinkRabbit', 'greenRabbit'):
            self._rect(0, P*1.5, 4.6, 2.5, body)
        else:
            self._rect(0, P*1.5, 4.5, 2.5, body)
        # Arms (with dark outline when holding laptop/doc)
        arm_x = P*2.70 if ch == 'orangeRabbit' else P*2.68 if ch == 'greenRabbit' else P*2.65
        lx = -arm_x + self.larm_dx;  ly = P*1.1 + self.larm_dy
        rx =  arm_x + self.rarm_dx;  ry = P*1.1 + self.rarm_dy
        if self.show_laptop or self.show_reading:
            self._rect(lx, ly, 1.9, 1.2, '#3A3A3A')   # outline
            self._rect(rx, ry, 1.9, 1.2, '#3A3A3A')
        self._rect(lx, ly, 1.5, 0.9, body)
        self._rect(rx, ry, 1.5, 0.9, body)

    def _draw_feet(self):
        body = CHARACTERS[self.character][0]
        ch = self.character
        # Foot size per character
        if ch in ('orangeRabbit', 'greenRabbit'):
            self._rect(-P*1.2, P*2.9, 1.6, 1.0, body)
            self._rect( P*1.2, P*2.9, 1.6, 1.0, body)
        else:
            self._rect(-P*1.2, P*2.9, 1.5, 0.9, body)
            self._rect( P*1.2, P*2.9, 1.5, 0.9, body)

    def _draw_head(self):
        body, ear, nose, extras = CHARACTERS[self.character]
        ch = self.character

        # ── Head size (per-character, matching each Swift view)
        if ch in ('pinkRabbit', 'orangeRabbit', 'greenRabbit'):
            self._rect(0, -P*0.8, 5.6, 2.6, body)
        else:
            self._rect(0, -P*0.8, 5.5, 2.5, body)

        # ── Eyebrows + stubble (두니 only)
        if 'brow' in extras:
            brow = extras['brow']
            self._rect(-P*1.45, -P*1.35, 0.95, 0.24, brow)
            self._rect( P*1.45, -P*1.35, 0.95, 0.24, brow)
            self._rect(-P*0.85, -P*0.10, 0.20, 0.20, brow)
            self._rect( P*0.85, -P*0.10, 0.20, 0.20, brow)

        # ── Blush / cheeks (character-specific, drawn before eyes)
        if ch == 'pinkRabbit':
            # 푸니: 크고 부드러운 타원형 볼 홍조
            # pre-blended: Color(0.98,0.62,0.75).opacity(0.55) over #FAC7E0
            self._oval(-P*1.9, -P*0.30, 1.6, 1.0, '#FAB0CE')
            self._oval( P*1.9, -P*0.30, 1.6, 1.0, '#FAB0CE')
        elif ch == 'orangeRabbit':
            # 주니: 발랄한 둥근 볼터치
            # pre-blended: Color(1.0,0.70,0.50).opacity(0.55) over #F28520
            self._oval(-P*1.8, -P*0.35, 1.4, 1.0, '#F9A055')
            self._oval( P*1.8, -P*0.35, 1.4, 1.0, '#F9A055')
        elif ch == 'yellowRabbit':
            # 누니: 작고 따뜻한 타원형 볼 홍조 (위치 맥버전 기준으로 수정)
            self._oval(-P*1.55, -P*0.42, 0.68, 0.28, '#F5B06E')
            self._oval( P*1.55, -P*0.42, 0.68, 0.28, '#F5B06E')

        # ── Eye parameters (per-character, matching each Swift eyeBlock)
        if ch == 'pinkRabbit':
            ew, ex, ey_off = 0.75, P*1.45, P*0.92
            eh_n, eh_w, eh_b = 0.90, 1.20, 0.10
        elif ch == 'orangeRabbit':
            ew, ex, ey_off = 0.68, P*1.42, P*0.88
            eh_n, eh_w, eh_b = 0.78, 1.10, 0.10
        elif ch == 'yellowRabbit':
            ew, ex, ey_off = 0.68, P*1.4,  P*0.90
            eh_n, eh_w, eh_b = 0.82, 1.15, 0.11
        elif ch == 'greenRabbit':
            ew, ex, ey_off = 0.72, P*1.42, P*0.90
            eh_n, eh_w, eh_b = 0.60, 1.05, 0.10
        else:  # rabbit, brownRabbit
            ew, ex, ey_off = 0.65, P*1.4,  P*0.90
            eh_n, eh_w, eh_b = 0.75, 1.10, 0.12

        ey = -ey_off
        if self.blinking:    eh = eh_b
        elif self.wide_eyes: eh = eh_w
        else:                eh = eh_n

        self._rect(-ex, ey, ew, eh, '#000000')
        self._rect( ex, ey, ew, eh, '#000000')

        # ── Eye sparkle highlights (푸니, 누니)
        if not self.blinking:
            if ch == 'pinkRabbit':
                self._rect(-P*1.60, ey - P*0.28, 0.22, 0.22, '#FFEAF5')
                self._rect( P*1.30, ey - P*0.28, 0.22, 0.22, '#FFEAF5')
            elif ch == 'yellowRabbit':
                self._rect(-P*1.54, ey - P*0.22, 0.22, 0.22, '#FFFFFF')
                self._rect( P*1.26, ey - P*0.22, 0.22, 0.22, '#FFFFFF')

        # ── Nose (per-character shape and size)
        if ch == 'pinkRabbit':
            # 픽셀아트 하트 코 (PinkRabbitCharacterView.heartNoseView)
            ny = -P*0.22
            self._rect(-P*0.17, ny - P*0.17, 0.30, 0.30, nose)
            self._rect( P*0.17, ny - P*0.17, 0.30, 0.30, nose)
            self._rect(0,       ny,           0.52, 0.28, nose)
            self._rect(0,       ny + P*0.22,  0.30, 0.24, nose)
            self._rect(0,       ny + P*0.40,  0.16, 0.18, nose)
        elif ch in ('orangeRabbit', 'yellowRabbit'):
            self._rect(0, -P*0.24, 0.58, 0.40, nose)
        elif ch == 'greenRabbit':
            self._rect(0, -P*0.24, 0.60, 0.40, nose)
        else:
            self._rect(0, -P*0.25, 0.55, 0.40, nose)

    # ── Laptop ────────────────────────────────────────────────

    def _draw_laptop(self):
        """MacBook on character's lap — positions from LaptopView.swift."""
        cx = CHAR_CX + self.body_dx
        cy = CHAR_CY + self.body_dy

        def r(oy, w, h, color):
            y = cy + P * oy
            self.cv.create_rectangle(cx - P*w/2, y - P*h/2,
                                      cx + P*w/2, y + P*h/2,
                                      fill=color, outline='', tags='char')

        r(1.48, 3.15, 2.15, LAP_SILVER)   # Lid back
        r(0.41, 3.15, 0.17, LAP_HI)       # Lid top highlight
        r(2.64, 3.50, 0.20, LAP_DARK)     # Hinge
        r(2.90, 3.80, 0.44, LAP_MID)      # Keyboard base
        r(3.13, 3.80, 0.16, LAP_DARK)     # Keyboard front thickness
        r(2.82, 3.10, 0.13, '#909099')    # Key hint
        r(3.02, 1.00, 0.22, '#9090A0')    # Trackpad
        # Apple logo (simplified)
        lx = cx; ly = cy + P*1.42
        self.cv.create_rectangle(lx - P*0.35, ly - P*0.55,
                                  lx + P*0.35, ly + P*0.40,
                                  fill=LAP_APPLE, outline='', tags='char')

    # ── Document ──────────────────────────────────────────────

    def _draw_doc_pile(self):
        """Paper pile on the left — static, behind character."""
        pile_cx = CHAR_CX + self.body_dx - P*5.4
        pile_cy = CHAR_CY + self.body_dy + P*2.55

        def r(ox, oy, w, h, color):
            x = pile_cx + ox*P;  y = pile_cy + oy*P
            self.cv.create_rectangle(x - w*P/2, y - h*P/2,
                                      x + w*P/2, y + h*P/2,
                                      fill=color, outline='', tags='char')

        r(0.12,  0.84, 2.85, 0.26, DOC_DARK)    # shadow
        r(0,    -0.74, 2.55, 1.45, DOC_PAPER)   # pile body
        r(0,    -1.22, 1.90, 0.13, DOC_LINE_H)
        r(0,    -1.04, 1.60, 0.10, DOC_LINE_L)
        r(0,    -0.88, 1.90, 0.10, DOC_LINE_L)
        r(0,    -0.56, 1.90, 0.10, DOC_LINE_L)
        r(0,    -0.03, 2.55, 0.12, DOC_DARK)    # thickness lines
        r(0,     0.11, 2.55, 0.12, DOC_DARK)
        r(1.28, -0.90, 0.26, 0.52, TAB_PINK)    # post-it tabs
        r(1.28, -0.36, 0.26, 0.46, TAB_YELLOW)
        r(1.28,  0.14, 0.26, 0.44, TAB_GREEN)

    def _draw_held_doc(self):
        """Document the character is holding — affected by throw offset."""
        doc_cx = CHAR_CX + self.body_dx + self.throw_dx
        doc_cy = CHAR_CY + self.body_dy + self.throw_dy

        def r(oy, w, h, color):
            y = doc_cy + P * oy
            self.cv.create_rectangle(doc_cx - P*w/2, y - P*h/2,
                                      doc_cx + P*w/2, y + P*h/2,
                                      fill=color, outline='', tags='char')

        r(1.90, 3.2, 2.80, DOC_DARK)    # shadow
        r(1.80, 3.0, 2.80, DOC_PAPER)   # paper main
        r(0.55, 3.0, 0.13, DOC_LINE_H)  # top separator
        r(0.78, 1.85, 0.25, DOC_LINE_H) # title
        r(1.06, 1.30, 0.16, DOC_LINE_L)
        r(1.35, 2.55, 0.13, DOC_LINE_L) # body lines
        r(1.55, 2.55, 0.13, DOC_LINE_L)
        r(1.75, 2.55, 0.13, DOC_LINE_L)
        r(1.95, 2.10, 0.13, DOC_LINE_L)
        r(2.36, 2.55, 0.13, DOC_LINE_L)
        r(2.55, 1.80, 0.13, DOC_LINE_L)
        # Corner fold
        corner_x = doc_cx + P*1.29
        corner_y = doc_cy + P*0.47
        self.cv.create_rectangle(corner_x - P*0.21, corner_y - P*0.21,
                                  corner_x + P*0.21, corner_y + P*0.21,
                                  fill=DOC_DARK, outline='', tags='char')

    # ── Speech bubble ─────────────────────────────────────────

    def _draw_bubble(self):
        if not self.msg:
            return
        bx  = CHAR_CX - P*5 + self.body_dx
        by  = CHAR_CY - P*3.5 + self.body_dy
        pad = 10
        font = ('Malgun Gothic', 10)
        tmp = self.cv.create_text(0, 0, text=self.msg, font=font)
        bb  = self.cv.bbox(tmp); self.cv.delete(tmp)
        tw  = (bb[2] - bb[0]) if bb else 60
        bw  = tw + pad*2;  bh = 28;  r = 8
        x0  = bx - bw;    x1 = bx
        y0  = by - bh/2;  y1 = by + bh/2
        # ① 테두리용 외곽 레이어 (body+꼬리 모두 border 색으로, outline='')
        self._rounded_rect(x0-1, y0-1, x1+1, y1+1, r+1, '#cccccc', '', 'bubble')
        self.cv.create_polygon(x1-3, by-6, x1+10, by, x1-3, by+6,
                                fill='#cccccc', outline='', tags='bubble')
        # ② 흰색 채움 레이어 (접합부 포함) — 바깥 border만 보임
        self._rounded_rect(x0, y0, x1, y1, r, 'white', '', 'bubble')
        self.cv.create_polygon(x1-2, by-5, x1+9, by, x1-2, by+5,
                                fill='white', outline='', tags='bubble')
        # ③ 텍스트
        self.cv.create_text(x0+pad, (y0+y1)/2, text=self.msg,
                             anchor='w', font=font, fill='#222222', tags='bubble')

    # ── Memo tag ──────────────────────────────────────────────

    def _draw_memo(self):
        if not self.memo:
            return
        cx  = CHAR_CX + self.body_dx
        cy  = CHAR_CY + self.body_dy - P*7.0   # 귀 끝보다 넉넉히 위에 배치
        font = ('Malgun Gothic', 9, 'bold')
        self.cv.create_text(cx+1, cy+1, text=self.memo, anchor='center',
                             font=font, fill='#999999', tags='memo')
        self.cv.create_text(cx, cy, text=self.memo, anchor='center',
                             font=font, fill='#FFFFFF', tags='memo')

    # ── Usage bar ─────────────────────────────────────────────

    def _draw_bar(self):
        if self.state == 'idle':
            return

        SH = 6          # 바 높이 (pill 형태)
        R  = 3          # 모서리 반지름
        # 이전보다 조금 작게: P*9 ≈ 58px
        bx = CHAR_CX - P * 4.5
        w  = P * 9

        display_pct = (self._server_utilization
                       if self._server_utilization is not None
                       else self._usage * 100)

        feet_y  = CHAR_CY + P * 3.35
        lv_y    = feet_y + 8
        bar_y   = lv_y + 8      # 레벨 텍스트와 바 간격 축소
        label_y = bar_y + SH + 6

        # ── 텍스트 그리기 헬퍼: 1px 쉐도우 + 본문 ──────────────
        def _txt(x, y, text, anchor, font, color, shadow='#555555'):
            self.cv.create_text(x+1, y+1, text=text, anchor=anchor,
                                font=font, fill=shadow, tags='bar')
            self.cv.create_text(x,   y,   text=text, anchor=anchor,
                                font=font, fill=color,  tags='bar')

        # 레벨 텍스트
        _txt(bx, lv_y,
             text=f'Lv.{self._monthly_tokens // 500_000 + 1}',
             anchor='w', font=('Consolas', 6, 'bold'), color='#F2CC25')

        # 트랙 (어두운 pill)
        self._rounded_rect(bx, bar_y, bx + w, bar_y + SH, R, '#2A2A2A', '', 'bar')

        # 채움 (컬러 pill)
        if display_pct > 0:
            fill_ratio = min(1.0, display_pct / 100)
            fill_w = max(w * fill_ratio, R * 2 + 2)   # 최소 너비 확보
            fc = ('#4DDA59' if display_pct <= 50
                  else '#F2CC25' if display_pct <= 75
                  else '#F24D33')
            self._rounded_rect(bx, bar_y, bx + fill_w, bar_y + SH, R, fc, '', 'bar')
            # 상단 하이라이트 (맥 버전 광택)
            if fill_w > R * 2 + 4:
                self.cv.create_rectangle(
                    bx + R + 1, bar_y + 1,
                    bx + fill_w - R - 1, bar_y + 2,
                    fill='#FFFFFF', outline='', tags='bar')

        # 라벨: % (왼쪽), ↺ (오른쪽)
        _lf = ('Consolas', 6, 'bold')
        label_pct = (f'{round(display_pct)}%'
                     if self._server_utilization is not None else '동기화중')
        _txt(bx, label_y, text=label_pct,
             anchor='w', font=_lf, color='#AAAAAA')
        rst = self._reset_time_str()
        if rst:
            _txt(bx + w, label_y, text=f'↺ {rst}',
                 anchor='e', font=_lf, color='#AAAAAA')

    def _reset_time_str(self) -> str:
        # 맥과 동일하게: 서버 resets_at 우선, 없으면 session_start + 5시간으로 추정
        if self._server_resets_at is not None:
            reset_at = self._server_resets_at
        elif self._session_start is not None:
            reset_at = self._session_start + datetime.timedelta(hours=5)
        else:
            return ''
        now  = datetime.datetime.now(datetime.timezone.utc)
        diff = int((reset_at - now).total_seconds())
        if diff <= 0:
            return ''
        h = diff // 3600; m = (diff % 3600) // 60
        return f'{h}:{m:02d}' if h > 0 else f'{m}m'

    def _tick_bar_refresh(self):
        if self._destroyed:
            return
        if self.state != 'idle':
            self._draw()
        self.win.after(30_000, self._tick_bar_refresh)

    # ── Blink ─────────────────────────────────────────────────

    def _schedule_blink(self):
        if self._destroyed:
            return
        self._blink_job = self.win.after(random.randint(2500, 6000), self._do_blink)

    def _do_blink(self):
        if self._destroyed:
            return
        self.blinking = True;  self._draw()
        self.win.after(130, self._end_blink)

    def _end_blink(self):
        if self._destroyed:
            return
        self.blinking = False; self._draw()
        self._schedule_blink()

    # ── Idle hop ──────────────────────────────────────────────

    def _schedule_idle_hop(self):
        if self._destroyed:
            return
        self._idle_job = self.win.after(random.randint(5000, 14000), self._do_idle_hop)

    def _do_idle_hop(self):
        if self._destroyed:
            return
        if self.state != 'ready':
            self._schedule_idle_hop(); return
        if random.random() < 0.5:
            self._hop_anim(on_done=self._schedule_idle_hop)
        else:
            self._ear_anim(on_done=self._schedule_idle_hop)

    def _hop_anim(self, on_done=None):
        frames = [0, -P*0.8, -P*1.5, -P*1.8, -P*1.5, -P*0.8, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dy = 0; self._draw()
                if on_done: on_done(); return
            self.body_dy = frames[i]; self._draw()
            self.win.after(40, lambda: step(i+1))
        step()

    def _ear_anim(self, on_done=None):
        frames = [0, P*0.5, P*1.0, P*0.5, 0, -P*0.5, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dx = 0; self._draw()
                if on_done: on_done(); return
            self.body_dx = frames[i]; self._draw()
            self.win.after(60, lambda: step(i+1))
        step()

    def _bounce(self, high: bool = False):
        amp = -P*2.5 if high else -P*2.0
        frames = [0, P*0.5*amp/(-P*2), amp*0.8, amp, amp*0.8, P*0.5*amp/(-P*2), 0]
        frames = [0, amp*0.35, amp*0.80, amp, amp*0.80, amp*0.35, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dy = 0; self._draw(); return
            self.body_dy = frames[i]; self._draw()
            self.win.after(30, lambda: step(i+1))
        step()

    # ── Laptop typing ─────────────────────────────────────────

    def _start_laptop(self):
        if self.show_laptop:
            return
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self.larm_dy =  P*1.00; self.rarm_dy =  P*1.00
        self.show_laptop  = True
        self.laptop_phase = False
        self._draw()
        self._tick_laptop()

    def _tick_laptop(self):
        if self._destroyed:
            return
        if self.state not in ('thinking', 'toolUse'):
            self._laptop_job = None; return
        self.laptop_phase = not self.laptop_phase
        base = P*1.00; swing = P*0.60
        if self.laptop_phase:
            self.larm_dy = base - swing; self.rarm_dy = base + swing
        else:
            self.larm_dy = base + swing; self.rarm_dy = base - swing
        self._draw()
        self._laptop_job = self.win.after(360, self._tick_laptop)

    def _stop_laptop(self):
        if self._laptop_job:
            self.win.after_cancel(self._laptop_job); self._laptop_job = None
        self.show_laptop = False
        if not self.show_reading:
            self.larm_dx = self.larm_dy = 0.0
            self.rarm_dx = self.rarm_dy = 0.0

    # ── Document reading ──────────────────────────────────────

    def _start_reading(self):
        if self.show_reading:
            return
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self.larm_dy =  P*0.25; self.rarm_dy =  P*0.25
        self.show_reading = True
        self.throw_dx = 0.0; self.throw_dy = 0.0
        self.doc_visible  = True
        self._reading_step = 0
        self._draw()
        self._step_reading()

    def _step_reading(self):
        if self._destroyed or self.state != 'toolRead':
            return
        self._reading_step += 1
        if self._reading_step % 3 == 0:
            self._throw_and_replace()
        else:
            phase = (self._reading_step % 2) == 0
            self.larm_dy = P*0.18 if phase else P*0.30
            self.rarm_dy = P*0.30 if phase else P*0.18
            self._draw()
            self._reading_job = self.win.after(1300, self._step_reading)

    def _throw_and_replace(self):
        if self._destroyed or self.state != 'toolRead':
            return
        # Arms up for the throw
        self.larm_dy = -P*0.30; self.rarm_dy = -P*0.30
        self.larm_dx =  P*1.80; self.rarm_dx = -P*1.80

        # Step through throw offset
        throw_frames = [(P*1.5, -P*1.0), (P*3.0, -P*2.0), (P*4.0, -P*3.0)]

        def step_throw(i=0):
            if self._destroyed: return
            if i < len(throw_frames):
                self.throw_dx, self.throw_dy = throw_frames[i]
                self._draw()
                self.win.after(65, lambda: step_throw(i+1))
            else:
                # Doc thrown away — hide and snap back
                self.doc_visible = False
                self.throw_dx = 0.0; self.throw_dy = 0.0
                self._draw()
                self.win.after(300, self._replace_doc)

        step_throw()

    def _replace_doc(self):
        if self._destroyed or self.state != 'toolRead':
            return
        self.doc_visible = True
        self.larm_dy =  P*0.25; self.rarm_dy =  P*0.25
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self._draw()
        self._reading_job = self.win.after(400, self._step_reading)

    def _stop_reading(self):
        if self._reading_job:
            self.win.after_cancel(self._reading_job); self._reading_job = None
        self.show_reading = False
        self.throw_dx = 0.0; self.throw_dy = 0.0
        self.doc_visible  = True
        if not self.show_laptop:
            self.larm_dx = self.larm_dy = 0.0
            self.rarm_dx = self.rarm_dy = 0.0

    # ── State machine ─────────────────────────────────────────

    def _apply_state(self, new_state: str, *, tool=None, notif=None,
                     perm_cmd=None, perm_id=None):
        if not self._destroyed:
            self.win.after(0, lambda: self._do_apply(
                new_state, tool, notif, perm_cmd, perm_id))

    def _do_apply(self, new_state, tool, notif, perm_cmd, perm_id):
        if self._destroyed:
            return
        self.state = new_state
        self.wide_eyes = False

        # Stop animations that are no longer relevant
        if new_state not in ('thinking', 'toolUse'):
            self._stop_laptop()
        if new_state != 'toolRead':
            self._stop_reading()

        if new_state == 'idle':
            self.msg = None
            self._draw()
            # 자동 숨기기 제거 — 사용자가 직접 숨기기 전까지 표시 유지

        elif new_state == 'thinking':
            self.msg = '코딩중'
            self._start_laptop()
            self._draw()

        elif new_state == 'toolUse':
            self.msg = tool or '작업 중...'
            self._start_laptop()
            self._draw()

        elif new_state == 'toolRead':
            self.msg = tool or '읽는 중...'
            self._start_reading()
            self._draw()

        elif new_state == 'notification':
            self.msg = notif
            self._draw()
            self._bounce()
            self.win.after(5000, lambda: self._clear_msg_if(notif))

        elif new_state == 'permission':
            self.wide_eyes = True
            self.msg = None
            self.perm_cmd = perm_cmd
            self.perm_id  = perm_id
            self.show()   # 숨겨진 경우에도 팝업이 보이도록
            self._draw()
            self._show_perm_popup()

        elif new_state == 'completed':
            self.msg = None
            self.wide_eyes = True
            self._bounce(high=True)
            self._draw()
            self.win.after(3000, lambda: (
                self._apply_state('ready') if self.state == 'completed' else None))

        elif new_state == 'ready':
            self.msg = None
            self._draw()
            self.show()

    def _clear_msg_if(self, old_msg):
        if not self._destroyed and self.msg == old_msg:
            self.msg = None; self._draw()

    # ── Permission popup ──────────────────────────────────────

    def _show_perm_popup(self):
        if self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()

        # ── 상수 ──────────────────────────────────────────────
        TRANSP   = '#010101'
        WHITE    = '#FFFFFF'
        SHADOW   = '#BBBBBB'
        CMD_BG   = '#F0F0F0'
        BW       = 230          # 말풍선 너비 (꼬리 제외)
        TAIL_W   = 15           # 꼬리 너비
        R        = 14           # 모서리 반지름
        PAD      = 12           # 내부 여백
        TITLE_H  = 20
        BTN_H    = 28
        GAP      = 6
        CMD_H    = 72           # 명령 영역 고정 높이 (스크롤)

        cmd = (self.perm_cmd or '').strip()

        # ── 위치 계산 ─────────────────────────────────────────
        _bubble_by = int(CHAR_CY - P * 3.5)

        def _get_geometry(h: int):
            self.win.update_idletasks()
            rx = self.win.winfo_rootx(); ry = self.win.winfo_rooty()
            pw = BW + TAIL_W
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            wx = rx + tail_tip_x - pw
            wy = ry + _bubble_by - h // 2
            return pw, wx, wy

        # ── 헬퍼: 말풍선 + 꼬리 ───────────────────────────────
        def _bubble(cv, ox, oy, h, color):
            x0, y0, x1, y1 = ox, oy, ox + BW, oy + h
            cv.create_arc(x0, y0, x0+2*R, y0+2*R, start=90, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y0, x1, y0+2*R, start=0, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x0, y1-2*R, x0+2*R, y1, start=180, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y1-2*R, x1, y1, start=270, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0+R, y0, x1-R, y1,   fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0, y0+R, x1, y1-R,   fill=color, outline=color, tags='bubble')
            mid = oy + h // 2
            cv.create_polygon(x1, mid-7, x1+TAIL_W+ox, mid, x1, mid+7,
                              fill=color, outline=color, tags='bubble')

        def _darken(hex_color: str) -> str:
            r = max(0, int(hex_color[1:3], 16) - 30)
            g = max(0, int(hex_color[3:5], 16) - 30)
            b = max(0, int(hex_color[5:7], 16) - 30)
            return f'#{r:02X}{g:02X}{b:02X}'

        # ── 윈도우 생성 ───────────────────────────────────────
        WIN_H         = PAD + TITLE_H + GAP + CMD_H + GAP + BTN_H + PAD
        WIN_W, wx, wy = _get_geometry(WIN_H)

        win = tk.Toplevel(self.win)
        self._perm_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.wm_attributes('-transparentcolor', TRANSP)
        win.config(bg=TRANSP)
        win.geometry(f'{WIN_W}x{WIN_H}+{wx}+{wy}')

        cv = tk.Canvas(win, width=WIN_W, height=WIN_H,
                       bg=TRANSP, highlightthickness=0)
        cv.pack()

        # 말풍선 배경
        _bubble(cv, 2, 3, WIN_H, SHADOW)
        _bubble(cv, 0, 0, WIN_H, WHITE)

        # 제목
        cv.create_text(PAD + 4, PAD + 2, text='🔐 실행 허용?',
                       anchor='nw', font=('Consolas', 10, 'bold'),
                       fill='#000000', tags='bubble')

        # 명령 박스 배경 (둥근 사각형)
        cmd_y = PAD + TITLE_H + GAP
        cx0, cy0 = PAD, cmd_y
        cx1, cy1 = BW - PAD, cmd_y + CMD_H
        cr = 6
        for dx0, dy0, dx1, dy1, start in [
            (cx0,cy0,cx0+2*cr,cy0+2*cr,90),(cx1-2*cr,cy0,cx1,cy0+2*cr,0),
            (cx0,cy1-2*cr,cx0+2*cr,cy1,180),(cx1-2*cr,cy1-2*cr,cx1,cy1,270)]:
            cv.create_arc(dx0,dy0,dx1,dy1, start=start, extent=90,
                          fill=CMD_BG, outline=CMD_BG, tags='bubble')
        cv.create_rectangle(cx0+cr, cy0, cx1-cr, cy1, fill=CMD_BG, outline=CMD_BG, tags='bubble')
        cv.create_rectangle(cx0, cy0+cr, cx1, cy1-cr, fill=CMD_BG, outline=CMD_BG, tags='bubble')

        # 스크롤 가능한 텍스트 위젯
        txt = tk.Text(win, bg=CMD_BG, fg='#333333',
                      font=('Consolas', 8), bd=0, highlightthickness=0,
                      wrap='word', relief='flat', cursor='arrow',
                      padx=5, pady=4)
        txt.insert('1.0', cmd)
        txt.config(state='disabled')
        cv.create_window(cx0 + cr, cy0 + 3, anchor='nw', window=txt,
                         width=cx1 - cx0 - cr * 2, height=CMD_H - 6)

        def _on_wheel(e):
            txt.yview_scroll(int(-1 * (e.delta / 120)), 'units')
        txt.bind('<MouseWheel>', _on_wheel)
        cv.bind('<MouseWheel>', _on_wheel)

        # 버튼
        btn_y = cmd_y + CMD_H + GAP
        btns  = [('거부', '#DA3733', 'deny'),
                 ('허용', '#2DB357', 'approve'),
                 ('전체 허용', '#3377E0', 'approve_all')]
        bx = PAD
        for label, bg, action in btns:
            bw = len(label) * 9 + 16
            by0, by1 = btn_y, btn_y + BTN_H
            br = 7
            tag    = f'btn_{action}'
            tag_bg = f'btnbg_{action}'
            for dx0,dy0,dx1,dy1,st in [
                (bx,by0,bx+2*br,by0+2*br,90),(bx+bw-2*br,by0,bx+bw,by0+2*br,0),
                (bx,by1-2*br,bx+2*br,by1,180),(bx+bw-2*br,by1-2*br,bx+bw,by1,270)]:
                cv.create_arc(dx0,dy0,dx1,dy1, start=st, extent=90,
                              fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_rectangle(bx+br, by0, bx+bw-br, by1, fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_rectangle(bx, by0+br, bx+bw, by1-br, fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_text(bx + bw//2, btn_y + BTN_H//2, text=label,
                           font=('Consolas', 9, 'bold'), fill='white', tags=(tag, 'bubble'))
            cv.tag_bind(tag, '<Button-1>', lambda _, a=action: self._decide(a))
            cv.tag_bind(tag, '<Enter>',
                        lambda _, tb=tag_bg, b=bg: cv.itemconfig(tb, fill=_darken(b), outline=_darken(b)))
            cv.tag_bind(tag, '<Leave>',
                        lambda _, tb=tag_bg, b=bg: cv.itemconfig(tb, fill=b, outline=b))
            bx += bw + 6

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
        try:
            (_TEMP / f'claude-companion-decision-{pid}').write_text(decision)
        except Exception:
            pass
        self.perm_id = None
        self._apply_state('thinking')

    # ── Context menu ──────────────────────────────────────────

    def _build_menu(self):
        self._menu = tk.Menu(self.win, tearoff=0)
        self._menu.add_command(label='숨기기',  command=self.hide)
        self._menu.add_command(label='Claude 열기', command=self._open_claude)
        self._menu.add_separator()

        char_menu = tk.Menu(self._menu, tearoff=0)
        for cid, name in CHAR_DISPLAY_NAMES.items():
            char_menu.add_command(label=name,
                                   command=lambda c=cid: self._set_character(c))
        self._menu.add_cascade(label='캐릭터 변경', menu=char_menu)

        self._menu.add_separator()
        label = '메모 추가...' if not self.memo else '메모 편집...'
        self._menu.add_command(label=label, command=self._edit_memo)
        if self.memo:
            self._menu.add_command(label='메모 지우기', command=self._clear_memo)

        self._menu.add_separator()
        self._menu.add_command(label='위치 초기화',  command=self._reset_position)
        self._menu.add_command(label='단축키 설정...', command=self.manager._open_shortcut_settings)
        self._menu.add_separator()
        self._menu.add_command(label='세션 끊기',    command=self._disconnect)
        self._menu.add_separator()
        self._menu.add_command(label='종료', command=self.manager.quit)

    def _show_menu(self, e: tk.Event):
        self._build_menu()
        try:
            self._menu.tk_popup(e.x_root, e.y_root)
        finally:
            self._menu.grab_release()

    def _open_claude(self):
        try:
            os.startfile('claude')
        except Exception:
            pass

    def _set_character(self, char_id: str):
        self.character = char_id
        self._save_character()
        self._draw()

    def _edit_memo(self):
        result = simpledialog.askstring(
            '메모 설정',
            '이 캐릭터의 메모를 입력하세요:\n(빈칸으로 두면 메모가 삭제됩니다)',
            initialvalue=self.memo, parent=self.win)
        if result is not None:
            self.memo = result.strip()
            self._save_memo()
            self._draw()

    def _clear_memo(self):
        self.memo = ''
        self._save_memo()
        self._draw()

    def _reset_position(self):
        if self.slot == 0:
            self.persist.remove('window_pos')
        self._position_window()

    # ── Usage ─────────────────────────────────────────────────

    def set_usage(self, pct: float, session_start_ts=None):
        self._usage = max(0.0, min(1.0, pct / 100.0))
        if session_start_ts:
            try:
                parsed = datetime.datetime.fromisoformat(
                    session_start_ts.replace('Z', '+00:00'))
                if self._session_start is None or parsed < self._session_start:
                    self._session_start = parsed
            except Exception:
                pass
        self._draw()

    def set_monthly_tokens(self, tokens: int):
        self._monthly_tokens = tokens
        self._draw()

    def set_server_usage(self, utilization: float | None, resets_at: datetime.datetime | None):
        self._server_utilization = utilization
        self._server_resets_at   = resets_at
        self._draw()

    # ── Event file polling ────────────────────────────────────

    def _init_file_offset(self):
        try:
            if self.event_file.exists():
                self._file_offset = self.event_file.stat().st_size
        except Exception:
            pass

    def poll_events(self) -> bool:
        """Read new lines from event file. Returns False if file gone."""
        if self._destroyed:
            return False
        try:
            size = self.event_file.stat().st_size
        except FileNotFoundError:
            # 파일이 삭제됐어도 창은 유지 — 사용자가 숨길 때까지
            return True
        if size <= self._file_offset:
            return True
        try:
            with self.event_file.open('r', encoding='utf-8', errors='replace') as f:
                f.seek(self._file_offset)
                data = f.read()
            self._file_offset = self.event_file.stat().st_size
        except Exception:
            return True
        for line in data.splitlines():
            if line.strip():
                self._last_event_time = time.time()
                self._handle_event(line)

        # macOS처럼 5분 비활동 시 세션 종료 (크래시/강제종료 감지)
        if time.time() - self._last_event_time > 300 and self.state != 'idle':
            self._apply_state('idle')

        return True

    def _handle_event(self, raw: str):
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            return
        t = ev.get('type', '')

        if t == 'tool_use':
            # 권한 요청 중에는 도구 이벤트 무시 — 말풍선 겹침 방지
            if self.state == 'permission':
                return
            tool_raw   = ev.get('tool', 'tool')
            label      = self._fmt_tool(tool_raw)
            next_state = 'toolRead' if tool_raw.lower() in READ_TOOLS else 'toolUse'
            # macOS처럼 ready 상태에서는 thinking 0.6초 후 도구 상태로 전환
            if self.state == 'ready':
                self._apply_state('thinking')
                self.win.after(600, lambda ns=next_state, lb=label: (
                    self._apply_state(ns, tool=lb) if self.state == 'thinking' else None
                ))
            else:
                self._apply_state(next_state, tool=label)

        elif t == 'tool_done':
            if self.state == 'permission':
                return
            self._apply_state('thinking')

        elif t == 'done':
            self._apply_state('completed')
            # 자동 파일 삭제·세션 제거 없음 — 사용자가 숨기기 전까지 유지

        elif t == 'notification':
            self._apply_state('notification', notif=ev.get('message', '알림'))

        elif t == 'permission_request':
            pid = ev.get('id');  cmd = ev.get('message', '명령')
            if pid and self.always_approve:
                try:
                    (_TEMP / f'claude-companion-decision-{pid}').write_text('approve')
                except Exception:
                    pass
            elif pid:
                self._apply_state('permission', perm_cmd=cmd, perm_id=pid)

        elif t == 'usage':
            pct = ev.get('percent', 0)
            sts = ev.get('sessionStartTs', None)
            self.win.after(0, lambda p=pct, s=sts: self.set_usage(p, s))

    def _cleanup_event_file(self):
        """세션 이벤트 파일 삭제 → poll_events가 False를 반환해 세션 자동 제거."""
        if self._destroyed:
            return
        try:
            self.event_file.unlink(missing_ok=True)
        except Exception:
            pass

    @staticmethod
    def _fmt_tool(raw: str) -> str:
        return {
            'bash':      '터미널 명령 실행 중',
            'read':      '파일 읽는 중',
            'write':     '파일 쓰는 중',
            'edit':      '파일 수정 중',
            'multiedit': '파일 수정 중',
            'glob':      '파일 검색 중',
            'grep':      '코드 검색 중',
            'ls':        '폴더 탐색 중',
            'websearch': '웹 검색 중',
            'webfetch':  '페이지 읽는 중',
            'todowrite': '할 일 정리 중',
            'todoread':  '할 일 확인 중',
        }.get(raw.lower(), f'{raw} 실행 중')

    # ── Visibility ────────────────────────────────────────────

    def hide(self):
        self.win.withdraw()

    def show(self):
        self.win.deiconify()

    @property
    def is_visible(self) -> bool:
        try:
            return self.win.state() == 'normal'
        except Exception:
            return False

    # ── Disconnect ────────────────────────────────────────────

    def _disconnect(self):
        """사용자가 이 세션을 수동으로 끊습니다.
        이벤트 파일을 삭제하고 매니저의 차단 목록에 세션 ID를 추가해
        같은 세션 파일이 다시 감지돼도 재생성되지 않도록 합니다.
        Claude를 새로 시작하면 새 session_id로 새 부니가 생성됩니다."""
        import tkinter.messagebox as mb
        if not mb.askyesno(
                '세션 끊기',
                '이 세션을 끊으시겠습니까?\n\n'
                '창이 닫히며, 이 세션에 대한 알림은 더 이상 표시되지 않습니다.\n'
                'Claude를 새로 시작하면 새 부니가 생성됩니다.',
                parent=self.win):
            return
        self.manager.disconnect_session(self.session_id, self.event_file)

    # ── Cleanup ───────────────────────────────────────────────

    def destroy(self):
        if self._destroyed:
            return
        self._destroyed = True
        for job_attr in ('_laptop_job', '_reading_job', '_blink_job', '_idle_job'):
            job = getattr(self, job_attr, None)
            if job:
                try: self.win.after_cancel(job)
                except Exception: pass
        if self._perm_win:
            try: self._perm_win.destroy()
            except Exception: pass
        try: self.win.destroy()
        except Exception: pass


# ══════════════════════════════════════════════════════════════
class BuniManager:
    """Root application — manages multiple SessionWindows."""

    def __init__(self):
        self.root = tk.Tk()
        self.root.withdraw()   # hidden background window

        # PID 파일 기록 — 훅이 부니 실행 여부 확인에 사용
        try:
            PID_FILE.write_text(str(os.getpid()), encoding='utf-8')
        except Exception:
            pass

        self.persist  = PersistenceManager()
        self.sessions: dict[str, SessionWindow] = {}
        self._slot_map: dict[int, str] = {}
        self._disconnected: set[str] = set()   # 수동으로 끊긴 세션 ID 차단 목록
        self._is_manually_hidden = False
        self._monthly_tokens = 0
        self._claude_was_running = False
        self._server_utilization: float | None = None
        self._server_resets_at:   datetime.datetime | None = None

        # ── 단축키 ─────────────────────────────────────────
        self._hotkey_mgr = GlobalHotkeyManager()
        self._shortcut_settings: 'ShortcutSettingsWindow | None' = None
        self._init_hotkeys()

        # Start threads
        threading.Thread(target=self._monitor_loop,      daemon=True).start()
        threading.Thread(target=self._token_loop,        daemon=True).start()
        threading.Thread(target=self._server_usage_loop, daemon=True).start()

        # Poll sessions on main thread
        self._poll_sessions()

        # System tray
        self._start_tray()

        self.root.mainloop()

    # ── Session management ────────────────────────────────────

    def _next_slot(self) -> int:
        for i in range(20):
            if i not in self._slot_map:
                return i
        return len(self._slot_map)

    def _add_session(self, session_id: str, event_file: Path):
        if session_id in self.sessions:
            return
        if session_id in self._disconnected:
            return

        # 30분 이상 수정되지 않은 오래된 파일은 유령 세션이므로 건너뜀
        try:
            if time.time() - event_file.stat().st_mtime > 1800:
                return
        except Exception:
            return

        slot = self._next_slot()
        self._slot_map[slot] = session_id

        # ── 캐릭터 배정 ─────────────────────────────────────
        # 우선순위: ① 슬롯 저장값(재시작 유지) ② 미사용 캐릭터 자동 배정
        # character.session.{id} 는 세션마다 새 UUID라 재시작 시 항상 없음 →
        # character.slot.{slot} 을 실질적인 영구 저장소로 사용
        in_use    = {sw.character for sw in self.sessions.values()}
        slot_char = self.persist.get(f'character.slot.{slot}')
        if slot_char and slot_char in CHARACTERS and slot_char not in in_use:
            assigned = slot_char
        else:
            # 슬롯 저장값이 없거나 이미 사용 중 → 미사용 캐릭터 자동 선택
            assigned = next(
                (cid for cid in CHARACTERS if cid not in in_use),
                list(CHARACTERS.keys())[slot % len(CHARACTERS)]   # 최후 폴백
            )
        # 두 키 모두 저장 (slot 기준 영구 유지)
        self.persist.set(f'character.session.{session_id}', assigned)
        self.persist.set(f'character.slot.{slot}',          assigned)

        win = SessionWindow(self, session_id, slot, event_file, self.persist)
        win.set_monthly_tokens(self._monthly_tokens)
        win.set_server_usage(self._server_utilization, self._server_resets_at)
        self.sessions[session_id] = win

        if self._is_manually_hidden:
            win.hide()

    def remove_session(self, session_id: str):
        win = self.sessions.pop(session_id, None)
        if win:
            self._slot_map.pop(win.slot, None)
            win.destroy()

    def disconnect_session(self, session_id: str, event_file: Path):
        """세션을 수동으로 끊고 차단 목록에 추가합니다.
        이벤트 파일을 삭제해 훅 이벤트가 재감지되지 않도록 하고,
        session_id를 차단 목록에 등록해 파일이 다시 생겨도 무시합니다."""
        self._disconnected.add(session_id)
        try:
            event_file.unlink(missing_ok=True)
        except Exception:
            pass
        self.remove_session(session_id)

    def hide_all(self):
        self._is_manually_hidden = True
        for win in self.sessions.values():
            win.hide()

    def show_all(self):
        self._is_manually_hidden = False
        for win in self.sessions.values():
            win.show()

    def quit(self):
        try:
            PID_FILE.unlink(missing_ok=True)
        except Exception:
            pass
        self.root.quit()
        sys.exit(0)

    # ── Session polling (main thread) ─────────────────────────

    def _poll_sessions(self):
        for sid in list(self.sessions.keys()):
            win = self.sessions.get(sid)
            if win and not win.poll_events():
                # event file gone — remove session
                self.root.after(0, lambda s=sid: self.remove_session(s))
        self.root.after(500, self._poll_sessions)

    # ── File monitor (background thread) ─────────────────────

    def _monitor_loop(self):
        """Detect new/removed event files and Claude process state."""
        while True:
            try:
                found: dict[str, Path] = {}
                for p in glob.glob(str(_TEMP / 'claude-companion-events-*.jsonl')):
                    fp  = Path(p)
                    sid = self._sid_from_file(fp)
                    if sid in self._disconnected:
                        continue
                    found[sid] = fp
                # 세션 ID 없이 쓴 고정 파일 — 세션별 파일이 하나도 없을 때만 폴백으로 사용
                fixed = _TEMP / 'claude-companion-events.jsonl'
                if fixed.exists() and not found:
                    found['windows-default'] = fixed

                # 세션별 파일이 있으면 windows-default 유령 세션 제거
                real_sids = [s for s in found if s != 'windows-default']
                if real_sids and 'windows-default' in self.sessions:
                    self.root.after(0, lambda: self.remove_session('windows-default'))

                # New sessions
                for sid, fp in found.items():
                    if sid not in self.sessions:
                        self.root.after(0, lambda s=sid, f=fp: self._add_session(s, f))

                # Claude process state (for idle detection)
                running = self._is_claude_running()
                if not running and self._claude_was_running:
                    # All sessions go idle
                    self.root.after(0, self._all_sessions_idle)
                elif running and not self._claude_was_running:
                    # Claude started — sessions already created via file detection
                    pass
                self._claude_was_running = running

            except Exception:
                pass
            time.sleep(1.0)

    def _all_sessions_idle(self):
        for win in list(self.sessions.values()):
            win._apply_state('idle')

    @staticmethod
    def _sid_from_file(f: Path) -> str:
        m = re.search(r'claude-companion-events-(.+)\.jsonl$', f.name)
        if m:
            return m.group(1)
        if f.name == 'claude-companion-events.jsonl':
            return 'windows-default'
        return f.stem

    @staticmethod
    def _is_claude_running() -> bool:
        try:
            import subprocess
            CREATE_NO_WINDOW = 0x08000000
            out = subprocess.check_output(
                ['tasklist', '/FI', 'IMAGENAME eq node.exe', '/NH'],
                stderr=subprocess.DEVNULL, text=True,
                creationflags=CREATE_NO_WINDOW)
            return 'node.exe' in out.lower()
        except Exception:
            return False

    # ── Monthly token refresh (background thread) ─────────────

    def _token_loop(self):
        while True:
            try:
                total = 0
                projects_dir = Path.home() / '.claude' / 'projects'
                if projects_dir.exists():
                    now = datetime.datetime.now()
                    for jf in projects_dir.rglob('*.jsonl'):
                        try:
                            for line in jf.read_text(
                                    encoding='utf-8', errors='replace').splitlines():
                                if not line.strip():
                                    continue
                                obj = json.loads(line)
                                ts_str = obj.get('timestamp', '')
                                if ts_str:
                                    try:
                                        ts = datetime.datetime.fromisoformat(
                                            ts_str.replace('Z', '+00:00'))
                                        if ts.year != now.year or ts.month != now.month:
                                            continue
                                    except Exception:
                                        continue
                                usage = (obj.get('message', {}) or {}).get('usage', {})
                                total += usage.get('input_tokens', 0)
                                total += usage.get('output_tokens', 0)
                        except Exception:
                            continue
                self._monthly_tokens = total
                self.root.after(0, self._broadcast_tokens)
            except Exception:
                pass
            time.sleep(300)

    def _broadcast_tokens(self):
        for win in self.sessions.values():
            win.set_monthly_tokens(self._monthly_tokens)

    # ── Server plan usage (5분마다 fetch) ─────────────────────

    # ── Chromium AES key 복호화 (1회 캐시) ───────────────────
    _aes_key_cache: bytes | None = None

    @staticmethod
    def _find_claude_dir() -> 'Path | None':
        """%APPDATA%\Claude 또는 MSIX 패키지 경로 중 config.json이 있는 곳을 반환."""
        candidates = [Path(os.environ.get('APPDATA', '')) / 'Claude']
        local_app = Path(os.environ.get('LOCALAPPDATA', ''))
        packages_dir = local_app / 'Packages'
        if packages_dir.exists():
            for pkg in packages_dir.iterdir():
                if pkg.name.startswith('Claude_'):
                    msix_claude = pkg / 'LocalCache' / 'Roaming' / 'Claude'
                    if msix_claude.exists():
                        candidates.insert(0, msix_claude)
        for d in candidates:
            if (d / 'config.json').exists():
                return d
        return candidates[0]

    @staticmethod
    def _get_aes_key() -> 'bytes | None':
        if BuniManager._aes_key_cache is not None:
            return BuniManager._aes_key_cache
        try:
            import ctypes, ctypes.wintypes as wt
            claude_dir = BuniManager._find_claude_dir()
            local_state = claude_dir / 'Local State'
            data = json.loads(local_state.read_text(encoding='utf-8'))
            enc_b64 = data['os_crypt']['encrypted_key']
            dpapi_blob = base64.b64decode(enc_b64)[5:]  # strip 'DPAPI' prefix

            class _BLOB(ctypes.Structure):
                _fields_ = [('cbData', wt.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]

            blob_in  = _BLOB(len(dpapi_blob), ctypes.cast(ctypes.c_char_p(dpapi_blob), ctypes.POINTER(ctypes.c_char)))
            blob_out = _BLOB()
            ok = ctypes.windll.crypt32.CryptUnprotectData(
                ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
            if not ok:
                return None
            key = ctypes.string_at(blob_out.pbData, blob_out.cbData)
            ctypes.windll.kernel32.LocalFree(blob_out.pbData)
            BuniManager._aes_key_cache = key
            return key
        except Exception:
            return None

    @staticmethod
    def _get_oauth_token() -> 'str | None':
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
            aes_key = BuniManager._get_aes_key()
            if not aes_key:
                return None
            config = BuniManager._find_claude_dir() / 'config.json'
            cfg = json.loads(config.read_text(encoding='utf-8'))
            enc_b64 = cfg.get('oauth:tokenCache', '')
            if not enc_b64:
                return None
            enc = base64.b64decode(enc_b64 + '==')
            plaintext = AESGCM(aes_key).decrypt(enc[3:15], enc[15:], None).decode('utf-8')
            token_data = json.loads(plaintext)
            best_key = max(token_data.keys(), key=lambda k: len(k))
            return token_data[best_key]['token']
        except Exception:
            return None

    def _server_usage_loop(self):
        import urllib.request, urllib.error
        plan_file = _TEMP / 'claude-companion-plan-usage.json'
        while True:
            try:
                token = BuniManager._get_oauth_token()
                if token:
                    req = urllib.request.Request(
                        'https://api.anthropic.com/api/oauth/usage',
                        headers={'Authorization': f'Bearer {token}',
                                 'anthropic-beta': 'oauth-2025-04-20'}
                    )
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        api_data = json.loads(resp.read().decode())
                    fh = api_data.get('five_hour', {})
                    result = {'utilization': fh.get('utilization', 0),
                              'resets_at':   fh.get('resets_at', '')}
                    plan_file.write_text(json.dumps(result), encoding='utf-8')

                if plan_file.exists():
                    data     = json.loads(plan_file.read_text(encoding='utf-8'))
                    util     = float(data.get('utilization', 0))
                    ra       = data.get('resets_at', '')
                    resets_at: datetime.datetime | None = None
                    if ra:
                        try:
                            resets_at = datetime.datetime.fromisoformat(
                                ra.replace('Z', '+00:00'))
                        except Exception:
                            pass
                    # resets_at이 이미 지났으면 캐시 데이터 만료 → 둘 다 None으로
                    now_utc = datetime.datetime.now(datetime.timezone.utc)
                    if resets_at is not None and resets_at <= now_utc:
                        util      = None
                        resets_at = None
                    self._server_utilization = util
                    self._server_resets_at   = resets_at
                    self.root.after(0, self._broadcast_server_usage)
            except Exception:
                pass
            time.sleep(300)

    def _broadcast_server_usage(self):
        for win in self.sessions.values():
            win.set_server_usage(self._server_utilization, self._server_resets_at)

    # ── 단축키 ────────────────────────────────────────────────

    def _init_hotkeys(self):
        callbacks = {
            'approve':        self._hk_approve,
            'always_approve': self._hk_always_approve,
            'deny':           self._hk_deny,
            'hide':           self._hk_hide,
        }
        self._hotkey_mgr.start(self.root, callbacks)
        # 저장된 단축키 로드 (ShortcutSettingsWindow 생성 전 직접 적용)
        saved = self.persist.get('shortcuts', {})
        defaults = {'approve': {'mods': GlobalHotkeyManager.MOD_CTRL, 'vk': 0x0D}}
        for action in ('approve', 'always_approve', 'deny', 'hide'):
            v = saved.get(action) or defaults.get(action)
            if v:
                self._hotkey_mgr.set_shortcut(action, v['mods'], v['vk'])

    def _hk_approve(self):
        for win in self.sessions.values():
            if win.state == 'permission':
                win._decide('approve')

    def _hk_deny(self):
        for win in self.sessions.values():
            if win.state == 'permission':
                win._decide('deny')

    def _hk_always_approve(self):
        for win in self.sessions.values():
            if win.state == 'permission':
                win._decide('approve_all')

    def _hk_hide(self):
        if any(w.is_visible for w in self.sessions.values()):
            self.hide_all()
        else:
            self.show_all()

    def _open_shortcut_settings(self):
        if self._shortcut_settings and self._shortcut_settings.is_open():
            self._shortcut_settings.show()
            return
        self._shortcut_settings = ShortcutSettingsWindow(
            self.root, self.persist, self._hotkey_mgr)

    def _open_claude(self):
        try:
            os.startfile('claude')
        except Exception:
            pass

    # ── System tray ───────────────────────────────────────────

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except ImportError:
            return   # pystray/Pillow not installed

        def make_icon():
            # 9×10 픽셀아트 토끼 (맥 버전 MenuBarIcon 포팅)
            grid = [
                ".XX...XX.",
                ".XX...XX.",
                ".XX...XX.",
                ".XX...XX.",
                ".XXXXXXX.",
                ".X.XXX.X.",
                ".XXX.XXX.",
                ".XXXXXXX.",
                "..XXXXX..",
            ]
            size = 32
            rows, cols = len(grid), len(grid[0])
            cw = size / cols;  ch = size / rows
            img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
            d   = ImageDraw.Draw(img)
            for r, row in enumerate(grid):
                for c, px in enumerate(row):
                    if px == 'X':
                        x0, y0 = int(c*cw), int(r*ch)
                        x1, y1 = int((c+1)*cw)-1, int((r+1)*ch)-1
                        d.rectangle([x0, y0, x1, y1], fill=(232, 232, 240, 255))
            return img

        # ── 동적 메뉴 타이틀 ─────────────────────────────
        def _toggle_title(item):
            return '부니 숨기기' if any(
                w.is_visible for w in self.sessions.values()) else '부니 보이기'

        def on_toggle(icon, item):
            self.root.after(0, self._hk_hide)

        def on_claude(icon, item):
            self.root.after(0, self._open_claude)

        def on_settings(icon, item):
            self.root.after(0, self._open_shortcut_settings)

        def on_reset(icon, item):
            self.root.after(0, lambda: [
                w._reset_position() for w in self.sessions.values()])

        def on_quit(icon, item):
            icon.stop()
            self.root.after(0, self.quit)

        icon = pystray.Icon('Buni', make_icon(), 'Buni', pystray.Menu(
            pystray.MenuItem(_toggle_title, on_toggle, default=True),
            pystray.MenuItem('Claude 열기',   on_claude),
            pystray.MenuItem('단축키 설정...', on_settings),
            pystray.MenuItem('위치 초기화',    on_reset),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('종료',           on_quit),
        ))
        threading.Thread(target=icon.run, daemon=True).start()


# ── Entry point ───────────────────────────────────────────────

if __name__ == '__main__':
    BuniManager()
