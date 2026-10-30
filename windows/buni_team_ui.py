"""
Buni 부니 스쿼드 창 (Windows / Tkinter) — buni_team.py 엔진의 화면.
  새 작업 → 사전요구서(질문·답) → 승인·예약 → 진행 상황 → 아침 검토
"""
import datetime
import os
import re
import unicodedata
import webbrowser
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox

import buni_team

BG, PANEL, FIELD, LINE = '#1E1E24', '#26262E', '#2A2A34', '#3A3A44'
RAIL = '#17171D'
FG, DIM, ACCENT, GREEN, GOLD, RED = 'white', '#8A8A98', '#3377E0', '#4DC780', '#D9B25A', '#E06060'
FONT = 'Malgun Gothic'


def _short_text(text, n=70):
    text = ' '.join(str(text or '').split())
    return text if len(text) <= n else text[:n - 1] + '…'

STATUS = {   # (한국어, English, 색)
    'draft':               ('작성 중',       'Draft',          DIM),
    'interviewing':        ('질문 답변 중',  'Answering',      GOLD),
    'review_requirements': ('요구서 승인 대기', 'Awaiting approval', GOLD),
    'queued':              ('예약됨',        'Scheduled',      ACCENT),
    'running':             ('진행 중',       'Running',        GREEN),
    'waiting_limit':       ('한도 대기',     'Waiting (limit)', GOLD),
    'paused':              ('잠시 멈춤',     'Paused',         GOLD),
    'review':              ('검토 대기',     'Ready to review', GREEN),
    'done':                ('검토 완료',     'Done',           DIM),
    'failed':              ('실패',          'Failed',         RED),
    'cancelled':           ('취소됨',        'Cancelled',      DIM),
}
ROLE_STATUS = {
    'pending': ('대기', 'Waiting', DIM), 'running': ('작업 중', 'Working', GREEN),
    'done_unreviewed': ('검토 대기', 'In review', GOLD), 'revise': ('다시 작업', 'Revising', GOLD),
    'accepted': ('통과', 'Accepted', GREEN),
}


def open_path(path: str):
    try:
        if sys.platform.startswith('win'):
            os.startfile(path)                                   # type: ignore[attr-defined]
        elif sys.platform == 'darwin':
            subprocess.Popen(['open', path])
        else:
            subprocess.Popen(['xdg-open', path])
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════
# 마크다운 보기 (tk.Text 에 서식을 입혀 그린다)
# ══════════════════════════════════════════════════════════════

_CHECK = {'o': '✅', 'O': '✅', 'x': '✅', '✓': '✅', '✔': '✅', 'X': '❌', '△': '⚠️', '~': '⚠️', ' ': '☐'}
_INLINE = re.compile(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)|(?<![*\w])\*([^*\n]+?)\*(?!\w)')


def _disp_width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s)


def render_markdown(txt, md: str, colors: dict, on_action=None, on_feedback=None):
    """마크다운 문서를 tk.Text 에 서식대로 넣는다 — 제목·목록·체크리스트·표·코드·인용·굵게/기울임/링크."""
    fg, dim, accent, panel = colors['fg'], colors['dim'], colors['accent'], colors['code_bg']
    base = colors['font']
    txt.tag_configure('h1', font=(base, 15, 'bold'), spacing1=10, spacing3=4)
    txt.tag_configure('h2', font=(base, 12, 'bold'), spacing1=10, spacing3=3)
    txt.tag_configure('h3', font=(base, 10, 'bold'), spacing1=6, spacing3=2)
    txt.tag_configure('bold', font=(base, 9, 'bold'))
    txt.tag_configure('italic', font=(base, 9, 'italic'))
    txt.tag_configure('code', font=('Consolas', 9), background=panel)
    txt.tag_configure('codeblock', font=('Consolas', 9), background=panel, lmargin1=10, lmargin2=10, spacing1=1)
    txt.tag_configure('quote', foreground=dim, lmargin1=16, lmargin2=16)
    txt.tag_configure('table', font=('Consolas', 9), background=panel, lmargin1=6, lmargin2=6)
    txt.tag_configure('tablehead', font=('Consolas', 9, 'bold'), background=panel, lmargin1=6, lmargin2=6)
    txt.tag_configure('link', foreground=accent, underline=True)
    txt.tag_configure('rule', foreground=dim)

    def inline(text, *tags):
        pos = 0
        for m in _INLINE.finditer(text):
            if m.start() > pos:
                txt.insert('end', text[pos:m.start()], tags)
            if m.group(1) is not None:
                txt.insert('end', m.group(1), tags + ('bold',))
            elif m.group(2) is not None:
                txt.insert('end', m.group(2), tags + ('code',))
            elif m.group(3) is not None:
                tag = f'link{txt.index("end")}'
                url = m.group(4)
                txt.tag_configure(tag, foreground=accent, underline=True)
                txt.tag_bind(tag, '<Button-1>', lambda e, u=url: webbrowser.open(u))
                txt.tag_bind(tag, '<Enter>', lambda e: txt.config(cursor='hand2'))
                txt.tag_bind(tag, '<Leave>', lambda e: txt.config(cursor=''))
                txt.insert('end', m.group(3), tags + (tag,))
            else:
                txt.insert('end', m.group(5), tags + ('italic',))
            pos = m.end()
        if pos < len(text):
            txt.insert('end', text[pos:], tags)

    lines = md.replace('\r\n', '\n').split('\n')
    i, para = 0, []

    _ACTION = re.compile(r'\[([^\]]+)\]\(buni://([a-z]+)/([^)\s]+)\)')
    _ACOLOR = {'run': '#D98A2B', 'followup': '#7350D9', 'apply': '#D98A2B', 'diff': '#6A6A78', 'view': '#6A6A78', 'ok': '#2F9E55', 'feedback': '#4B73CC'}

    def flush():
        if not para:
            return
        joined = ' '.join(para); para.clear()
        links = list(_ACTION.finditer(joined))
        if len(links) == 1 and links[0].group(2) == 'feedbackbox' and not _ACTION.sub('', joined).strip():   # 채팅 입력창
            import tkinter as _tk
            item_id = links[0].group(3)
            box = _tk.Frame(txt, bg=panel, highlightthickness=1, highlightbackground='#3A3A4A')
            tk_var = _tk.StringVar()
            ent = _tk.Entry(box, textvariable=tk_var, bg=panel, fg=fg, insertbackground=fg, relief='flat', font=(base, 10), width=52)
            ent.pack(side='left', padx=(8, 4), pady=6, ipady=2)

            def send(_e=None, v=tk_var, iid=item_id):
                text = v.get().strip()
                if text and on_feedback:
                    v.set('')
                    on_feedback(iid, text)
            ent.bind('<Return>', send)
            _tk.Button(box, text='보내기', command=send, bg=accent, fg='white', relief='flat', bd=0, cursor='hand2',
                       font=(base, 9, 'bold'), padx=10, pady=3).pack(side='left', padx=(0, 6))
            txt.window_create('end', window=box, padx=2, pady=4)
            txt.insert('end', '\n')
            return
        if links and not _ACTION.sub('', joined).strip():                  # 버튼 줄
            import tkinter as _tk
            for m in links:
                label, host, target = m.group(1), m.group(2), m.group(3)
                color = _ACOLOR.get(host, accent)
                b = _tk.Button(txt, text=label, bg=color, fg='white', relief='flat', bd=0, cursor='hand2',
                               font=(base, 9, 'bold'), padx=10, pady=4, activebackground=color, activeforeground='white',
                               command=(lambda h=host, t_=target: on_action(h, t_)) if on_action else None)
                txt.window_create('end', window=b, padx=2, pady=2)
                txt.insert('end', ' ')
            txt.insert('end', '\n')
            return
        inline(joined); txt.insert('end', '\n')

    def cells(line):
        line = line.strip()
        line = line[1:] if line.startswith('|') else line
        line = line[:-1] if line.endswith('|') else line
        return [re.sub(r'[`*]', '', c.strip()) for c in line.split('|')]     # 표 안은 서식 기호만 걷어 낸다

    def sep_row(line):
        c = cells(line)
        return bool(c) and all(x and set(x) <= set('-: ') for x in c)

    while i < len(lines):
        raw = lines[i]; line = raw.strip()
        if line.startswith('```'):
            flush(); i += 1; code = []
            while i < len(lines) and not lines[i].strip().startswith('```'):
                code.append(lines[i]); i += 1
            txt.insert('end', '\n'.join(code) + '\n', 'codeblock'); i += 1; continue
        if not line:
            flush(); i += 1; continue
        m = re.match(r'^(#{1,6})\s+(.*)$', line)
        if m:
            flush(); lvl = min(len(m.group(1)), 3)
            inline(m.group(2), f'h{lvl}'); txt.insert('end', '\n'); i += 1; continue
        if re.match(r'^(-{3,}|\*{3,}|_{3,})$', line):
            flush(); txt.insert('end', '─' * 60 + '\n', 'rule'); i += 1; continue
        if line.startswith('|') and i + 1 < len(lines) and sep_row(lines[i + 1]):
            flush(); head = cells(line); rows = []; i += 2
            while i < len(lines) and lines[i].strip().startswith('|'):
                r = cells(lines[i]); r += [''] * (len(head) - len(r)); rows.append(r[:len(head)]); i += 1
            widths = [max(_disp_width(x) for x in col) for col in zip(head, *rows)]
            def fmt(r):
                return '  '.join(c + ' ' * (w - _disp_width(c)) for c, w in zip(r, widths)).rstrip()
            txt.insert('end', fmt(head) + '\n', 'tablehead')
            txt.insert('end', '  '.join('─' * w for w in widths) + '\n', 'table')
            for r in rows:
                txt.insert('end', fmt(r) + '\n', 'table')
            continue
        if line.startswith('>'):
            flush(); q = []
            while i < len(lines) and lines[i].strip().startswith('>'):
                q.append(lines[i].strip()[1:].strip()); i += 1
            inline(' '.join(q), 'quote'); txt.insert('end', '\n'); continue
        m = re.match(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$', raw)
        if m:
            flush(); level = len(m.group(1).replace('\t', '  ')) // 2
            marker = '•' if m.group(2) in '-*+' else m.group(2)
            body = m.group(3)
            c = re.match(r'^\[(.)\]\s*(.*)$', body)
            if c:
                marker, body = _CHECK.get(c.group(1), '☐'), c.group(2)
            tag = f'li{level}'
            txt.tag_configure(tag, lmargin1=10 + level * 18, lmargin2=34 + level * 18, spacing1=1)
            txt.insert('end', marker + ' ', tag); inline(body, tag); txt.insert('end', '\n'); i += 1; continue
        para.append(line); i += 1
    flush()


class TeamWindow:
    def __init__(self, manager, t):
        self.manager, self.t = manager, t
        self.sel = None              # 선택한 job id (None = 새 작업 화면)
        self._sig = None
        self._pane = {}               # 작업별로 보고 있는 화면: overview / channel / lead / dm:<팀원>
        self._seen = {}               # (작업, 화면) → 마지막으로 본 시각 (안 읽음 표시용)
        self._opened = {}             # 작업을 처음 연 시각 (그 전 대화는 안 읽음으로 치지 않는다)
        self._drafts = {}             # 쓰던 글 (다시 그려도 남긴다)
        self._want_focus = False
        self._room = None
        self._room_token = 0
        self._wrapup_checked = set()  # 검토할 것 정리를 확인한 작업
        self._attn = {}               # 작업 id → '확인 필요' 이유 (없으면 키 없음) — 사이드바 하이라이트용
        self._attn_next = 0
        self._attn_busy = False
        self._open_role = None        # 펼쳐 둔 팀원(세션)
        self._act_widget = None
        self._vars = {}
        self._board = False           # 업무 현황 화면을 보는 중
        self._board_built = False
        self._bsel = None             # 현황에서 연 카드
        self._cards = []
        self._bf = {'view': 'board', 'q': '', 'status': '', 'assignee': '', 'scope': 'all', 'sort': 'recent'}
        win = self.win = tk.Toplevel(manager.root)
        win.title(t('부니 스쿼드', 'Buni Squad'))
        win.configure(bg=BG)
        win.geometry('1080x700')
        win.minsize(860, 560)
        win.protocol('WM_DELETE_WINDOW', self.close)
        self._build_frame()
        jobs = buni_team.list_jobs()
        pending = [j for j in jobs if j['status'] == 'review']
        self.sel = (pending or jobs or [{'id': None}])[-1]['id']
        self.refresh(force=True)
        self._tick()

    # ── 기본 틀 ──────────────────────────────────────────────
    def _build_frame(self):
        t = self.t
        body = tk.Frame(self.win, bg=BG); body.pack(fill='both', expand=True)
        left = tk.Frame(body, bg=RAIL, width=272); left.pack(side='left', fill='y'); left.pack_propagate(False)
        head = tk.Frame(left, bg=RAIL); head.pack(fill='x', padx=14, pady=(12, 10))
        tk.Label(head, text=t('🐰 부니 스쿼드', '🐰 Buni Squad'), bg=RAIL, fg=FG, font=(FONT, 13, 'bold')).pack(side='left')
        new = tk.Label(head, text='✎', bg='#34343F', fg=FG, font=(FONT, 11), width=3, cursor='hand2')
        new.pack(side='right'); new.bind('<Button-1>', lambda e: self._new())
        sch = tk.Label(head, text='⚙', bg=RAIL, fg=DIM, font=(FONT, 11), cursor='hand2')
        sch.pack(side='right', padx=(6, 2)); sch.bind('<Button-1>', lambda e: self._open_settings())
        self._gp_lbl = tk.Label(head, text='⏸', bg=RAIL, fg=DIM, font=(FONT, 12), cursor='hand2')
        self._gp_lbl.pack(side='right', padx=4); self._gp_lbl.bind('<Button-1>', lambda e: self._toggle_global_pause())
        tk.Frame(left, bg='#2A2A34', height=1).pack(fill='x')
        self.sched_lbl = tk.Label(left, bg=RAIL, fg='#6A6A78', font=(FONT, 8), anchor='w', justify='left', wraplength=240)
        self.sched_lbl.pack(side='bottom', fill='x', padx=14, pady=8)
        tk.Frame(left, bg='#2A2A34', height=1).pack(side='bottom', fill='x')
        self.list_frame = tk.Frame(left, bg=RAIL); self.list_frame.pack(fill='both', expand=True, pady=(4, 0))
        tk.Frame(body, bg='#2A2A34', width=1).pack(side='left', fill='y')
        self.right = tk.Frame(body, bg=PANEL); self.right.pack(side='left', fill='both', expand=True)

    def _btn(self, parent, text, cmd, color=PANEL, **kw):
        return tk.Button(parent, text=text, command=cmd, bg=color, fg=FG, relief='flat', bd=0, cursor='hand2',
                         font=(FONT, 9, 'bold'), padx=12, pady=5, activebackground=color, activeforeground=FG, **kw)

    def _label(self, parent, text, fg=FG, size=9, bold=False, **kw):
        return tk.Label(parent, text=text, bg=parent['bg'], fg=fg, font=(FONT, size, 'bold' if bold else 'normal'),
                        justify='left', anchor='w', **kw)

    def is_open(self):
        try:
            return bool(self.win.winfo_exists())
        except Exception:
            return False

    def show(self, job_id=None):
        if job_id:
            self._board = False
            self.sel = job_id
            self._open_role = None
            self.refresh(force=True)
        self.win.deiconify(); self.win.lift(); self.win.focus_force()

    def close(self):
        try:
            self.win.destroy()
        except Exception:
            pass

    # ── 주기적으로 상태를 읽는다 ─────────────────────────────
    @staticmethod
    def _attention_text(t, job, ast, settings):
        """확인이 필요한 상황인지 — 반영 승인 대기 · 사전요구서 변경 확인 · 수동 진행에서 시작 대기 · 한도로 멈춤."""
        if any(x.get('status') == 'pending' for x in job.get('req_proposals', [])):
            return t('요구서 변경 확인', 'Confirm requirement change')
        if ast.get('pending') and (ast['mode'] in ('confirm',) or ast.get('reasons') or ast.get('note')):
            return (t('중요한 변경 — 승인 필요', 'Important change — approve') if ast.get('reasons')
                    else t('자동 반영 실패', 'Apply failed') if ast.get('note') else t('반영 승인 필요', 'Approve to apply'))
        if job['status'] == 'paused' and job.get('phase') == 'waiting_start':
            return t('▶ 시작 대기', 'Waiting to start')
        if job['status'] == 'paused' and job.get('user_paused') and '한도' in ((job.get('events') or [{}])[-1].get('msg', '')):
            return t('한도로 멈춤', 'Stopped at limit')
        return None

    def _refresh_attention(self):
        """확인이 필요한 작업을 뒤에서 계산해 두고(git 을 부르므로), 달라졌을 때만 사이드바를 다시 그린다."""
        if self._attn_busy:
            return
        self._attn_busy = True

        def run():
            try:
                settings = buni_team.load_settings()
                new = {}
                for j in buni_team.list_jobs():
                    if j['status'] in ('review', 'done', 'failed', 'paused', 'running', 'queued'):
                        txt = self._attention_text(self.t, j, buni_team.apply_state(j['id']), settings)
                        if txt:
                            new[j['id']] = txt
                if new != self._attn:
                    self._attn = new
                    self._sig = None                       # 다음 틱에 사이드바를 다시 그린다
            except Exception:
                pass
            finally:
                self._attn_busy = False
        threading.Thread(target=run, daemon=True).start()

    def _tick(self):
        if not self.is_open():
            return
        if time.time() >= self._attn_next:
            self._attn_next = time.time() + 10
            self._refresh_attention()
        try:
            err, self._note_error = getattr(self, '_note_error', None), None
            if err:
                messagebox.showinfo(self.t('부니 스쿼드', 'Buni Squad'), err, parent=self.win)
            self.refresh()
        except Exception:
            pass
        self.win.after(1500, self._tick)

    def _signature(self, jobs):
        sel = next((j for j in jobs if j['id'] == self.sel), None)
        s = buni_team.load_settings()
        base = tuple((j['id'], j['status'], j.get('busy')) for j in jobs) + (self.sel, s['window_start'], s['window_end'], s['enabled'])
        base += (self._board, tuple((c['id'], c['column'], c['recent'], c['auto'], c['progress'], c['state']) for c in self._cards),
                 int(time.time() // 30) if self._board else 0)
        if not sel:
            return base
        roles = tuple((k, v['status'], v.get('attempts'), len(v.get('notes') or []), bool(v.get('note_pending')))
                      for k, v in (sel.get('roles') or {}).items()) + (getattr(self, '_open_role', None), self._pane.get(sel['id']))
        try:
            wu = os.path.getmtime(buni_team.wrapup_path(sel['id']))
        except OSError:
            wu = 0
        return base + (wu, sel.get('phase'), sel.get('error'), sel.get('busy_msg'), len(sel.get('events', [])), roles,
                       len(sel['interview']['questions']), len(sel.get('requirements') or ''),
                       tuple((x['id'], x.get('status')) for x in sel.get('req_proposals', [])))

    def refresh(self, force=False):
        jobs = buni_team.list_jobs()
        self._cards = buni_team.board_cards(jobs)
        sig = self._signature(jobs)
        if sig == self._sig and not force:
            return
        self._sig = sig
        cw = getattr(self, '_composer_widget', None)             # 쓰던 글은 다시 그리기 전에 챙겨 둔다
        if cw:
            try:
                self._drafts[cw[0]] = cw[1].get('1.0', 'end-1c')
            except tk.TclError:
                pass
        try:
            fw = self.win.focus_get()
            self._want_focus = bool(getattr(fw, '_is_composer', False))
        except Exception:
            self._want_focus = False
        self._draw_schedule()
        self._draw_list(jobs)
        if self._board:
            self._show_board()
            return
        self._board_built = False
        for w in self.right.winfo_children():
            w.destroy()
        self._vars = {}
        job = next((j for j in jobs if j['id'] == self.sel), None)
        if job is None:
            self._draw_new()
        else:
            self._draw_job(job)

    def _toggle_global_pause(self):
        on = not buni_team.load_settings().get('paused')
        self._run_bg(lambda: buni_team.set_global_pause(on))
        self.win.after(500, lambda: self.refresh(force=True))

    def _draw_schedule(self):
        s = buni_team.load_settings(); t = self.t
        mode = s.get('schedule_mode', 'window')
        if s.get('paused'):
            txt = t('⏸ 전체 일시정지 중 — ⏸ 버튼으로 이어서', '⏸ All work paused — press ⏸ to resume')
        elif mode == 'anytime':
            txt = t(f"⚡ 언제든 자동 진행 · 동시 {s['concurrency']}명", f"⚡ Auto-run any time · {s['concurrency']} at a time")
        elif mode == 'window':
            txt = t(f"🌙 {s['window_start']}~{s['window_end']} 자동 진행 · 동시 {s['concurrency']}명", f"🌙 Auto-run {s['window_start']}–{s['window_end']} · {s['concurrency']} at a time")
        else:
            txt = t('내가 시작할 때만 진행해요', 'Runs only when I start it')
        self.sched_lbl.config(text=txt, fg=GOLD if s.get('paused') else '#6A6A78')
        try:
            self._gp_lbl.config(text='▶' if s.get('paused') else '⏸', fg=GOLD if s.get('paused') else DIM)
        except Exception:
            pass

    def _nav_row(self, parent, text, cmd, selected=False, sub='', sub_color=DIM, unread=0, indent=18, bold=False, tint=None):
        """사이드바 한 줄. tint 가 있으면(진행 중 = 초록, 확인 필요 = 주황) 행 전체를 그 색으로 물들여 눈에 띄게 한다."""
        base = ACCENT if selected else (tint or RAIL)
        row = tk.Frame(parent, bg=base, cursor='hand2', highlightthickness=1 if tint and not selected else 0,
                       highlightbackground=tint or RAIL); row.pack(fill='x', padx=8, pady=1)
        strong = selected or unread or bold or bool(tint)
        tk.Label(row, text=text, bg=base, fg=FG if strong else '#C4C4CE',
                 font=(FONT, 9, 'bold' if strong else 'normal'), anchor='w').pack(side='left', padx=(indent, 4), pady=4)
        if unread:
            tk.Label(row, text=str(min(unread, 99)), bg='#E04858', fg=FG, font=(FONT, 8, 'bold'), padx=5).pack(side='right', padx=6)
        if sub:
            tk.Label(row, text=sub, bg=base, fg=FG if selected else sub_color, font=(FONT, 8, 'bold' if tint else 'normal')).pack(side='right', padx=6)
        for w in (row,) + tuple(row.winfo_children()):
            w.bind('<Button-1>', lambda e: cmd())
        if not selected:
            hover = '#25252F' if not tint else tint

            def paint(color, r=row):
                for w in (r,) + tuple(r.winfo_children()):
                    if w.cget('bg') != '#E04858':
                        w.config(bg=color)
            row.bind('<Enter>', lambda e: paint(hover))
            row.bind('<Leave>', lambda e: paint(base))
        return row

    def _section(self, parent, text):
        tk.Label(parent, text=text.upper(), bg=RAIL, fg='#6A6A78', font=(FONT, 8, 'bold'), anchor='w').pack(fill='x', padx=16, pady=(12, 2))

    def _draw_list(self, jobs):
        for w in self.list_frame.winfo_children():
            w.destroy()
        t = self.t
        attention = sum(1 for c in self._cards if c['column'] == 'blocked')
        self._nav_row(self.list_frame, '📊 ' + t('업무 현황', 'Task board'), self._open_board, self._board,
                      sub=t('보드 · 목록', 'Board · List'), unread=attention, indent=10, bold=True)
        self._section(self.list_frame, t('프로젝트', 'Projects'))
        if not jobs:
            tk.Label(self.list_frame, text=t('아직 작업이 없어요.\n위의 ✎ 버튼으로 시작해 보세요.', 'No jobs yet.\nStart with the ✎ button.'),
                     bg=RAIL, fg=DIM, font=(FONT, 9), justify='left').pack(anchor='w', padx=16, pady=6)
        for j in reversed(jobs):
            ko, en, color = STATUS.get(j['status'], (j['status'], j['status'], DIM))
            open_ = j['id'] == self.sel and not self._board
            title = j['title'] if len(j['title']) <= 22 else j['title'][:21] + '…'
            attn = self._attn.get(j['id'])
            working = j['status'] == 'running' and not buni_team.load_settings().get('paused')
            tint = '#4A3A1C' if attn else ('#1F3A2A' if working else None)          # 확인 필요 = 주황, 진행 중 = 초록
            bg_ = tint or RAIL
            row = tk.Frame(self.list_frame, bg=bg_, cursor='hand2', highlightthickness=1 if tint else 0, highlightbackground='#8A6A2A' if attn else '#3F7A55')
            row.pack(fill='x', padx=8, pady=1)
            tk.Label(row, text=('▾ ' if open_ else '▸ ') + title, bg=bg_, fg=FG if (open_ or tint) else '#C4C4CE',
                     font=(FONT, 9, 'bold'), anchor='w').pack(side='left', padx=(8, 4), pady=5)
            tk.Label(row, text='●', bg=bg_, fg=color, font=(FONT, 8)).pack(side='right', padx=8)
            if attn:
                tk.Label(row, text=attn, bg=bg_, fg=GOLD, font=(FONT, 8, 'bold')).pack(side='right')
            elif working:
                tk.Label(row, text='⏳', bg=bg_, fg=GREEN, font=(FONT, 8)).pack(side='right')
            for w in (row,) + tuple(row.winfo_children()):
                w.bind('<Button-1>', lambda e, i=j['id']: self._select(i))
            if open_:
                self._draw_children(j, ko, en)

    def _draw_children(self, job, ko, en):
        t, lf = self.t, self.list_frame
        cur = self._cur_pane(job)
        st = job['status']
        title = (t('질문', 'Questions') if st in ('draft', 'interviewing') else t('요구서', 'Requirements') if st == 'review_requirements'
                 else t('업무 보드', 'Board'))
        attn = self._attn.get(job['id'])
        working = st == 'running' and not buni_team.load_settings().get('paused')
        self._nav_row(lf, ('📋 ' if st in ('draft', 'interviewing', 'review_requirements') else '🗂 ') + title, lambda: self.set_pane(job['id'], 'overview'),
                      cur == 'overview', sub=attn or (('⏳ ' if working else '') + t(ko, en)), sub_color=GOLD if attn else (GREEN if working else DIM),
                      tint='#4A3A1C' if attn else ('#1F3A2A' if working else None))
        pend = [x for x in job.get('req_proposals', []) if x.get('status') == 'pending']
        if job.get('requirements'):
            self._nav_row(lf, '📝 ' + t('사전요구서', 'Requirements'), lambda: self.set_pane(job['id'], 'requirements'),
                          cur == 'requirements', sub=(t('✋ 확인 필요', '✋ Confirm') if pend else ''), sub_color=GOLD, unread=len(pend))
        if not self._has_room(job):
            return
        msgs = buni_team.load_chat(job['id'])
        self._section(lf, t('채널', 'Channels'))
        self._nav_row(lf, '#  ' + t('스쿼드', 'squad'), lambda: self.set_pane(job['id'], 'channel'), cur == 'channel',
                      unread=self._unread(job, 'channel', msgs))
        self._section(lf, t('다이렉트 메시지', 'Direct messages'))
        lead_phase = {'planning': t('팀 구성 중', 'Planning'), 'reviewing': t('검토 중', 'Reviewing'),
                      'merging': t('합치는 중', 'Merging'), 'wrapup': t('정리 중', 'Wrapping up')}.get(job.get('phase'), '')
        self._nav_row(lf, '🐰  ' + t('팀장', 'Team lead'), lambda: self.set_pane(job['id'], 'lead'), cur == 'lead',
                      sub=lead_phase, sub_color=GREEN, unread=self._unread(job, 'lead', msgs))
        for r in job['plan']['roles']:
            rs = job['roles'].get(r['id'], {})
            rko, ren, color = ROLE_STATUS.get(rs.get('status', 'pending'), ('대기', 'Waiting', DIM))
            pane = 'dm:' + r['id']
            rst = rs.get('status')
            self._nav_row(lf, f"{r['icon']}  {r['name']}", lambda p=pane: self.set_pane(job['id'], p), cur == pane,
                          sub=('⏳ ' if rst == 'running' else '● ') + t(rko, ren), sub_color=color, unread=self._unread(job, pane, msgs),
                          tint='#1F3A2A' if rst == 'running' else ('#3A3320' if rst == 'done_unreviewed' else None))

    def _select(self, job_id):
        self._board = False
        self.sel = job_id
        self._open_role = None
        if job_id and job_id not in self._opened:
            self._opened[job_id] = time.time()
        self.refresh(force=True)

    def _new(self):
        self._select(None)

    # ── 새 작업 ──────────────────────────────────────────────
    def _draw_new(self):
        t, f = self.t, self.right
        pad = tk.Frame(f, bg=PANEL); pad.pack(fill='both', expand=True, padx=20, pady=16)
        self._label(pad, t('새 스쿼드 작업', 'New squad job'), size=13, bold=True).pack(anchor='w')
        self._label(pad, t('팀장 Claude가 필요한 역할(디자인·개발·마케팅 …)을 정해 일을 나누고, 검토하고, 합쳐서 결과물을 만들어요.\n'
                           '사람이 없는 시간대에 진행하므로, 시작 전에 먼저 필요한 것을 질문해서 "사전요구서"로 확정해요.',
                           'A team-lead Claude picks the roles it needs, splits the work, reviews and merges the results.\n'
                           'It runs while you are away, so it first asks what it needs and fixes it in a "requirements" document.'),
                    DIM, 9, wraplength=560).pack(anchor='w', pady=(4, 12))
        self._vars['title'] = tk.StringVar()
        self._label(pad, t('제목', 'Title')).pack(anchor='w')
        tk.Entry(pad, textvariable=self._vars['title'], bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 10)).pack(fill='x', ipady=4, pady=(2, 10))
        self._label(pad, t('맡길 내용 (자세할수록 좋아요)', 'What to build (the more detail the better)')).pack(anchor='w')
        goal = tk.Text(pad, height=6, bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 10), wrap='word')
        goal.pack(fill='x', pady=(2, 10)); self._vars['goal'] = goal
        self._label(pad, t('프로젝트 폴더', 'Project folder')).pack(anchor='w')
        row = tk.Frame(pad, bg=PANEL); row.pack(fill='x', pady=(2, 10))
        self._vars['project'] = tk.StringVar()
        tk.Entry(row, textvariable=self._vars['project'], bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 10)).pack(side='left', fill='x', expand=True, ipady=4)
        self._btn(row, t('찾아보기…', 'Browse…'), lambda: self._vars['project'].set(filedialog.askdirectory(parent=self.win) or self._vars['project'].get()), FIELD).pack(side='left', padx=(6, 0))
        self._vars['web'] = tk.BooleanVar(value=False)
        tk.Checkbutton(pad, text=t('웹 검색 허용 (시장 조사·자료 찾기가 필요할 때)', 'Allow web search (for research)'), variable=self._vars['web'],
                       bg=PANEL, fg=FG, selectcolor=FIELD, activebackground=PANEL, activeforeground=FG, font=(FONT, 9)).pack(anchor='w')
        self._label(pad, t('안전 장치: 프로젝트 폴더 안에서만 작업하고, 파일 삭제·프로그램 설치·외부 전송은 막아요. 결과는 새 git 브랜치(buni/…)에 모아요.',
                           'Safety: works only inside the project folder; deleting files, installing software and sending data out are blocked. Results go to a new git branch (buni/…).'),
                    DIM, 8, wraplength=560).pack(anchor='w', pady=(8, 12))
        self._btn(pad, t('사전요구서 만들기 →', 'Create requirements →'), self._create_job, ACCENT).pack(anchor='w')

    def _create_job(self):
        t = self.t
        goal = self._vars['goal'].get('1.0', 'end').strip()
        project = self._vars['project'].get().strip()
        if not goal or not project:
            messagebox.showinfo(t('부니 스쿼드', 'Buni Squad'), t('맡길 내용과 프로젝트 폴더를 입력해 주세요.', 'Please enter what to build and the project folder.'), parent=self.win)
            return
        job = buni_team.new_job(self._vars['title'].get(), goal, project, {'web': bool(self._vars['web'].get())})
        self.sel = job['id']
        threading.Thread(target=buni_team.start_interview, args=(job['id'],), daemon=True).start()
        self.refresh(force=True)

    # ── 작업 화면 ────────────────────────────────────────────
    def _draw_header(self, f, job, pane, ko, en, color):
        t = self.t
        bar = tk.Frame(f, bg=PANEL, height=46); bar.pack(fill='x'); bar.pack_propagate(False)
        if pane == 'channel':
            tk.Label(bar, text='#  ' + t('스쿼드', 'squad'), bg=PANEL, fg=FG, font=(FONT, 12, 'bold')).pack(side='left', padx=(16, 8))
            tk.Label(bar, text=t(f"{job['title']} · 팀원 {len(job['plan']['roles'])}명", f"{job['title']} · {len(job['plan']['roles'])} teammates"),
                     bg=PANEL, fg=DIM, font=(FONT, 9)).pack(side='left')
            tk.Label(bar, text='🐰 ' + ' '.join(r['icon'] for r in job['plan']['roles'][:6]), bg=PANEL, fg=FG, font=(FONT, 12)).pack(side='right', padx=16)
        elif pane == 'requirements':
            tk.Label(bar, text='📝  ' + t('사전요구서', 'Requirements'), bg=PANEL, fg=FG, font=(FONT, 12, 'bold')).pack(side='left', padx=16)
            tk.Label(bar, text=job['title'], bg=PANEL, fg=DIM, font=(FONT, 9)).pack(side='left')
        elif pane == 'lead':
            tk.Label(bar, text='🐰  ' + t('팀장', 'Team lead'), bg=PANEL, fg=FG, font=(FONT, 12, 'bold')).pack(side='left', padx=16)
        elif pane.startswith('dm:'):
            who = pane[3:]
            rs = job['roles'].get(who, {})
            rko, ren, rcolor = ROLE_STATUS.get(rs.get('status', 'pending'), ('대기', 'Waiting', DIM))
            tk.Label(bar, text=self._chat_name(job, who), bg=PANEL, fg=FG, font=(FONT, 12, 'bold')).pack(side='left', padx=(16, 10))
            tk.Label(bar, text='● ' + t(rko, ren), bg=PANEL, fg=rcolor, font=(FONT, 9, 'bold')).pack(side='left')
        else:
            tk.Label(bar, text=job['title'], bg=PANEL, fg=FG, font=(FONT, 12, 'bold')).pack(side='left', padx=16)
            tk.Label(bar, text='● ' + t(ko, en), bg=PANEL, fg=color, font=(FONT, 9, 'bold')).pack(side='left')
        tk.Frame(f, bg='#34343F', height=1).pack(fill='x')

    def _draw_job(self, job):
        t, f = self.t, self.right
        ko, en, color = STATUS.get(job['status'], (job['status'], job['status'], DIM))
        pane = self._cur_pane(job)
        self._draw_header(f, job, pane, ko, en, color)
        if pane == 'requirements':
            self._draw_requirements_view(f, job)
            return
        if pane != 'overview':
            self._draw_room(f, job, pane)
            return
        pad = tk.Frame(f, bg=PANEL); pad.pack(fill='both', expand=True, padx=20, pady=14)
        self._label(pad, job['goal'] if len(job['goal']) < 160 else job['goal'][:158] + '…', DIM, 8, wraplength=640).pack(anchor='w', pady=(0, 8))
        st = job['status']
        for ex in job.get('extra_requests') or []:
            self._label(pad, '➕ ' + str(ex.get('text', '')), DIM, 8, wraplength=640).pack(anchor='w')
        if job.get('error') and st not in ('failed',):
            self._label(pad, '⚠ ' + job['error'], RED, 9, wraplength=640).pack(anchor='w', pady=(0, 6))
        if job.get('busy') and st in ('draft', 'interviewing', 'review_requirements'):
            self._label(pad, '⏳ ' + (job.get('busy_msg') or t('Claude가 작업 중…', 'Claude is working…')), GOLD, 10).pack(anchor='w', pady=14)
            self._label(pad, t('보통 1~2분 걸려요. 창을 닫아도 계속돼요.', 'Usually takes a minute or two. It continues if you close this window.'), DIM, 8).pack(anchor='w')
            self._btn(pad, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(anchor='w', pady=(10, 0))
        elif st in ('draft', 'interviewing') and not job['interview']['questions']:
            self._label(pad, t('질문을 아직 받지 못했어요.', 'No questions yet.'), DIM).pack(anchor='w', pady=8)
            row = tk.Frame(pad, bg=PANEL); row.pack(anchor='w')
            self._btn(row, t('🔁 다시 시도', '🔁 Retry'), lambda: self._retry_interview(job), ACCENT).pack(side='left')
            self._btn(row, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(side='left', padx=8)
            if st == 'interviewing':
                self._add_request_box(pad, job, t('➕ 요청 추가하고 질문 다시 받기', '➕ Add request & re-ask'))
        elif st == 'interviewing':
            self._draw_questions(pad, job)
        elif st == 'review_requirements':
            self._draw_requirements(pad, job)
        elif st in ('queued', 'paused', 'waiting_limit', 'running', 'review', 'done', 'failed') and job.get('plan'):
            pad.destroy()
            self._draw_project_board(f, job)
        elif st in ('failed', 'cancelled'):
            self._draw_failed(pad, job)

    # ── 업무 보드 (Jira 처럼: 누가 지금 무슨 업무를 하고 있고, 어떤 업무가 끝났는지) ──────────────
    BOARD_COLS = (('todo', '대기', 'To do', '#6AA9FF'), ('doing', '진행 중', 'In progress', GREEN),
                  ('review', '검토 중', 'In review', GOLD), ('done', '완료', 'Done', DIM))

    PRIO = {'urgent': ('🔴', '긴급', 'Urgent', RED), 'high': ('🟠', '높음', 'High', GOLD), 'normal': ('🔵', '보통', 'Normal', '#6AA9FF'),
            'low': ('⚪', '낮음', 'Low', DIM)}
    PRIO_RANK = {'urgent': 0, 'high': 1, 'normal': 2, 'low': 3}

    @staticmethod
    def _board_tasks(job):
        """보드에 올릴 업무 — 엔진이 적어 둔 '내가 지시한 업무'. 옛 작업이면 팀원 미션을 업무로 본다."""
        if job.get('tasks'):
            return job['tasks']
        out = []
        for r in job['plan']['roles']:
            st = (job.get('roles') or {}).get(r['id'], {}).get('status', 'pending')
            s_ = {'running': 'doing', 'revise': 'doing' if job['status'] == 'running' else 'todo', 'done_unreviewed': 'review', 'accepted': 'done'}.get(st, 'todo')
            out.append({'id': r['id'], 'title': (r.get('mission') or r['name']).strip().splitlines()[0][:70], 'text': r.get('mission', ''), 'source': 'plan',
                        'priority': 'normal', 'created': job.get('created', 0), 'status': s_, 'part_status': {r['id']: s_}, 'parts': {r['id']: 0}})
        return out

    def _pause(self, job):
        self._run_bg(lambda: buni_team.pause_job(job['id']))
        self.win.after(600, lambda: self.refresh(force=True))

    def _resume(self, job):
        def run():
            if buni_team.load_settings().get('paused'):
                buni_team.set_global_pause(False)
            if job.get('user_paused'):
                buni_team.resume_job(job['id'])
        self._run_bg(run)
        self.win.after(600, lambda: self.refresh(force=True))

    def _board_headline(self, job):
        t, s = self.t, buni_team.load_settings()
        st = job['status']
        if s.get('paused'):
            return t('⏸ 모든 작업이 일시정지 중이에요 — ▶ 이어서 를 눌러 주세요', '⏸ All squad work is paused — press Resume'), GOLD
        if job.get('user_paused') and st not in ('review', 'done', 'cancelled'):
            limit = '한도' in ((job.get('events') or [{}])[-1].get('msg', ''))
            return (t('⏸ Claude 사용량 한도에 닿아 멈췄어요 — 한도가 풀리면 ▶ 이어서', '⏸ Stopped at the Claude usage limit — resume once it resets') if limit
                    else t('⏸ 멈춰 있어요 — ▶ 이어서 를 누르면 계속해요', '⏸ Paused — press Resume to continue')), GOLD
        if st == 'running':
            ph = {'planning': t('팀을 꾸리는 중', 'Building the team'), 'working': t('팀원들이 일하는 중', 'Team is working'),
                  'reviewing': t('팀장이 검토하는 중', 'Lead is reviewing'), 'merging': t('팀장이 결과를 합치는 중', 'Lead is merging'),
                  'wrapup': t('팀장이 다음 업무를 정리하는 중', 'Lead is planning next tasks')}.get(job.get('phase'), t('진행 중', 'Running'))
            return '● ' + ph, GREEN
        if st == 'waiting_limit':
            at = datetime.datetime.fromtimestamp(job['resume_at']).strftime('%m/%d %H:%M') if job.get('resume_at') else '?'
            return t(f'⏸ 플랜 사용량 한도 — {at} 이후에 이어서 해요', f'⏸ Plan limit — continues after {at}'), GOLD
        if st == 'paused' and job.get('phase') == 'waiting_start':
            return t('▶ 수동 진행 — 시작할 업무 카드의 [▶ 시작]을 눌러 주세요', '▶ Manual — press ▶ Start on a card'), GOLD
        if st in ('queued', 'paused'):
            if s['enabled']:
                nxt = buni_team.next_window_start(datetime.datetime.now(), s['window_start'])
                return t(f"🌙 {nxt.strftime('%m/%d %H:%M')} 에 시작해요", f"🌙 Starts {nxt.strftime('%m/%d %H:%M')}"), '#6AA9FF'
            return t('예약이 꺼져 있어요 — 지금 바로 시작을 눌러 주세요', 'Scheduling is off — press Start now'), '#6AA9FF'
        if st in ('review', 'done'):
            return t('✓ 모든 업무가 끝났어요', '✓ All tasks are done'), GREEN
        if st == 'failed':
            return t('✕ 오류로 멈췄어요', '✕ Stopped on an error'), RED
        return t('취소된 작업이에요', 'Cancelled'), DIM

    def _scroll_area(self, parent):
        """세로로 스크롤되는 안쪽 프레임."""
        cv = tk.Canvas(parent, bg=PANEL, highlightthickness=0)
        sb = tk.Scrollbar(parent, command=cv.yview); cv.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); cv.pack(side='left', fill='both', expand=True)
        inner = tk.Frame(cv, bg=PANEL)
        win = cv.create_window((0, 0), window=inner, anchor='nw')
        inner.bind('<Configure>', lambda e: cv.configure(scrollregion=cv.bbox('all')))
        cv.bind('<Configure>', lambda e: cv.itemconfigure(win, width=e.width))
        cv.bind_all('<MouseWheel>', lambda e: cv.yview_scroll(int(-e.delta / 120), 'units') if cv.winfo_exists() else None)
        return inner

    def _draw_project_board(self, f, job):
        t = self.t
        outer = tk.Frame(f, bg=PANEL); outer.pack(fill='both', expand=True)
        inner = self._scroll_area(outer)
        pad = tk.Frame(inner, bg=PANEL); pad.pack(fill='both', expand=True, padx=20, pady=14)
        # 머리 — 상태 · 방식 · 버튼
        text, color = self._board_headline(job)
        top = tk.Frame(pad, bg=PANEL); top.pack(fill='x')
        tk.Label(top, text=text, bg=PANEL, fg=color, font=(FONT, 11, 'bold'), anchor='w').pack(side='left')
        ast = buni_team.apply_state(job['id'])
        mode_names = {'smart': t('스마트', 'Smart'), 'auto': t('자동', 'Auto'), 'confirm': t('확인 후', 'Confirm'), 'manual': t('수동', 'Manual')}
        run_names = {'auto': t('자동', 'Auto'), 'manual': t('수동', 'Manual')}
        self._board_mode_menu(top, t('반영', 'Apply'), mode_names.get(ast['mode'], ''), job.get('apply_mode') or '',
                              [('', t('설정 따름', 'Follow settings')), ('smart', t('스마트 — 중요하면 확인', 'Smart')), ('auto', t('자동 — 전부 바로', 'Auto')),
                               ('confirm', t('확인 후 — 승인하면', 'Confirm')), ('manual', t('수동 — 브랜치로만', 'Manual'))],
                              lambda m: self._run_bg(lambda: buni_team.set_job_modes(job['id'], apply_mode=m))).pack(side='right', padx=(6, 0))
        self._board_mode_menu(top, t('진행', 'Run'), run_names.get(ast['run_mode'], ''), job.get('run_mode') or '',
                              [('', t('설정 따름', 'Follow settings')), ('auto', t('자동', 'Auto')), ('manual', t('수동 (업무마다 ▶ 시작)', 'Manual (▶ per task)'))],
                              lambda m: self._run_bg(lambda: buni_team.set_job_modes(job['id'], run_mode=m))).pack(side='right')
        bar = tk.Frame(pad, bg=PANEL); bar.pack(fill='x', pady=(8, 6))
        st = job['status']
        gp = buni_team.load_settings().get('paused')
        if job.get('user_paused') or gp:
            self._btn(bar, t('▶ 이어서', '▶ Resume'), lambda: self._resume(job), ACCENT).pack(side='left', padx=(0, 6))
        elif st in ('queued', 'running', 'waiting_limit') or (st == 'paused' and job.get('phase') != 'waiting_start'):
            self._btn(bar, t('⏸ 멈추기', '⏸ Pause'), lambda: self._pause(job), FIELD).pack(side='left', padx=(0, 6))
        if st in ('queued', 'paused', 'waiting_limit') and not job.get('user_paused'):
            self._btn(bar, t('▶ 지금 바로 시작', '▶ Start now'), lambda: self._run_now(job), ACCENT).pack(side='left')
        if st == 'failed':
            self._btn(bar, t('🔁 다시 시도', '🔁 Retry'), lambda: (buni_team.retry_job(job['id']), self.refresh(force=True)), ACCENT).pack(side='left')
        if st == 'review':
            self._btn(bar, t('✅ 완료 처리', '✅ Mark done'), lambda: (buni_team.mark_done(job['id']), self.refresh(force=True)), ACCENT).pack(side='left')
        if st in ('queued', 'running', 'paused', 'waiting_limit'):
            self._btn(bar, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(side='left', padx=6)
        self._btn(bar, t('🗑 삭제', '🗑 Delete'), lambda: self._delete(job), FIELD).pack(side='left')
        tk.Label(bar, text=t(f"약 ${job.get('cost_usd', 0):.2f}", f"≈ ${job.get('cost_usd', 0):.2f}"), bg=PANEL, fg=DIM, font=(FONT, 8)).pack(side='right')
        if job.get('error') and st == 'failed':
            self._label(pad, '⚠ ' + job['error'], RED, 9, wraplength=760).pack(anchor='w', pady=(0, 6))
        self._draw_apply_banner(pad, job, ast)
        if job['plan'].get('summary'):
            self._label(pad, job['plan']['summary'], DIM, 8, wraplength=760).pack(anchor='w', pady=(0, 8))
        # 칼럼
        cols = tk.Frame(pad, bg=PANEL); cols.pack(fill='x', pady=(4, 8))
        tasks = sorted(self._board_tasks(job), key=lambda x: (self.PRIO_RANK.get(x.get('priority', 'normal'), 2), x.get('created', 0)))
        for i, (key, ko, en, ccolor) in enumerate(self.BOARD_COLS):
            cols.grid_columnconfigure(i, weight=1, uniform='bcol')
            items = [x for x in tasks if x.get('status', 'todo') == key]
            if key == 'done':
                items.sort(key=lambda x: -(x.get('done_at') or 0))
            col = tk.Frame(cols, bg=FIELD); col.grid(row=0, column=i, sticky='nsew', padx=3)
            hd = tk.Frame(col, bg=FIELD); hd.pack(fill='x', padx=8, pady=(8, 4))
            tk.Label(hd, text='●', bg=FIELD, fg=ccolor, font=(FONT, 8)).pack(side='left')
            tk.Label(hd, text=' ' + t(ko, en), bg=FIELD, fg='#C4C4CE', font=(FONT, 8, 'bold')).pack(side='left')
            tk.Label(hd, text=str(len(items)), bg=FIELD, fg=DIM, font=(FONT, 8)).pack(side='left', padx=4)
            for tk_ in items:
                self._task_card(col, job, tk_, key)
            if not items:
                tk.Label(col, text=t('비어 있음', 'Empty'), bg=FIELD, fg='#55555F', font=(FONT, 8)).pack(pady=14)
            tk.Frame(col, bg=FIELD, height=6).pack()
        # 최근 활동
        evs = list(reversed(job.get('events', [])[-10:]))
        if evs:
            tk.Label(pad, text=t('최근 활동', 'Activity').upper(), bg=PANEL, fg=DIM, font=(FONT, 8, 'bold'), anchor='w').pack(fill='x', pady=(10, 2))
            for e in evs:
                tk.Label(pad, text=time.strftime('%m/%d %H:%M', time.localtime(e['ts'])) + '   ' + e['msg'], bg=PANEL, fg='#B0B0BC',
                         font=(FONT, 8), anchor='w', justify='left', wraplength=760).pack(fill='x')

    def _board_mode_menu(self, parent, title, shown, current, options, on_pick):
        mb = tk.Menubutton(parent, text=f'{title}  {shown} ▾', bg=FIELD, fg=FG, relief='flat', font=(FONT, 8, 'bold'), padx=8, pady=3,
                           activebackground=FIELD, activeforeground=FG, cursor='hand2')
        menu = tk.Menu(mb, tearoff=0); mb['menu'] = menu
        for val, label in options:
            menu.add_command(label=('✓ ' if val == current else '') + label, command=lambda v=val: on_pick(v))
        return mb

    def _draw_apply_banner(self, pad, job, ast):
        """아직 내 폴더에 안 들어온 변경 — 왜 안 들어왔는지(중요한 변경이라 확인 · 겹침 · 확인/수동 방식)를 제목에 그대로 쓴다."""
        t = self.t
        finished = job['status'] in ('review', 'done', 'failed')
        if not ast.get('pending') or not (finished or ast['mode'] in ('confirm', 'manual')):
            if ast.get('applied') and job['status'] in ('review', 'done') and not ast.get('pending'):
                self._label(pad, t('✓ 결과를 내 폴더에 반영했어요 (커밋은 안 했어요) — 앱은 다시 빌드해야 보여요', '✓ Applied to your folder (not committed) — rebuild to see it'),
                            GREEN, 8).pack(anchor='w', pady=(0, 6))
            return
        n = ast.get('count', 0)
        if ast['mode'] == 'manual':
            head = t(f"📦 수동 — 바뀐 파일 {n}개는 브랜치 {ast['branch']} 에만 있어요", f"📦 Manual — {n} files only on {ast['branch']}")
        elif ast.get('note'):
            head = t(f'⚠️ 자동 반영이 안 됐어요 (내 폴더와 겹침) — 바뀐 파일 {n}개', f"⚠️ Couldn't apply (conflicts) — {n} files")
        elif ast.get('reasons'):
            head = t(f'✋ 중요한 변경이라 확인이 필요해요 — 바뀐 파일 {n}개', f'✋ Important change — please confirm — {n} files')
        elif ast['mode'] == 'confirm':
            head = t(f'✋ 내 폴더에 반영할까요? 바뀐 파일 {n}개', f'✋ Apply to your folder? {n} files')
        else:
            head = t(f'⏳ 아직 반영되지 않았어요 — 바뀐 파일 {n}개 (곧 자동으로 반영해요)', f'⏳ Not applied yet — {n} files (will apply automatically)')
        box = tk.Frame(pad, bg='#3A3020', highlightthickness=1, highlightbackground='#8A6A2A'); box.pack(fill='x', pady=(0, 8))
        tk.Label(box, text=head, bg='#3A3020', fg=GOLD, font=(FONT, 9, 'bold'), anchor='w').pack(fill='x', padx=10, pady=(8, 2))
        for r in ast.get('reasons') or []:
            tk.Label(box, text='• ' + r, bg='#3A3020', fg='#D8CBA0', font=(FONT, 8), anchor='w', justify='left', wraplength=700).pack(fill='x', padx=10)
        if ast.get('note'):
            tk.Label(box, text=ast['note'], bg='#3A3020', fg=DIM, font=(FONT, 8), anchor='w', justify='left', wraplength=700).pack(fill='x', padx=10)
        shown = '\n'.join(ast['files'][:8]) + (t(f"\n… 외 {n - 8}개", f"\n… +{n - 8} more") if n > 8 else '')
        tk.Label(box, text=shown, bg='#3A3020', fg='#C4B890', font=('Consolas', 8), justify='left', anchor='w').pack(fill='x', padx=10, pady=(4, 0))
        row = tk.Frame(box, bg='#3A3020'); row.pack(anchor='w', padx=10, pady=8)
        if ast['mode'] != 'manual':
            self._btn(row, t('✅ 승인하고 내 폴더에 반영', '✅ Approve & apply'), lambda: self._apply_result(job), ACCENT).pack(side='left')
        self._btn(row, t('📄 변경 내용 보기', '📄 View changes'), lambda: self._run_bg(lambda: self._open_diff_result(job)), FIELD).pack(side='left', padx=6)
        self._btn(row, t('반영하지 않고 닫기', 'Dismiss'), lambda: (self._run_bg(lambda: buni_team.dismiss_apply(job['id'])), self.win.after(500, lambda: self.refresh(force=True))), FIELD).pack(side='left')
        if ast['mode'] == 'manual':
            tk.Label(row, text=f"git merge {ast['branch']}", bg='#3A3020', fg=DIM, font=('Consolas', 8)).pack(side='left', padx=8)

    def _task_card(self, col, job, task, key):
        """내가 지시한 업무 하나 — 우선순위, 담당 팀원별 처리 상태, 진행률, 반영 내역."""
        t = self.t
        icon, ko, en, pcolor = self.PRIO.get(task.get('priority', 'normal'), self.PRIO['normal'])
        card = tk.Frame(col, bg=PANEL, highlightthickness=1,
                        highlightbackground='#3F7A55' if key == 'doing' else ('#7A3F3F' if task.get('priority') == 'urgent' and key != 'done' else '#33333D'))
        card.pack(fill='x', padx=8, pady=4)
        head = tk.Frame(card, bg=PANEL); head.pack(fill='x', padx=8, pady=(8, 2))
        mb = tk.Menubutton(head, text=f'{icon} {t(ko, en)} ▾', bg=PANEL, fg=pcolor, relief='flat', font=(FONT, 8, 'bold'), padx=2,
                           activebackground=PANEL, activeforeground=pcolor, cursor='hand2')
        menu = tk.Menu(mb, tearoff=0); mb['menu'] = menu
        for pk, (pi, pko, pen, _pc) in self.PRIO.items():
            menu.add_command(label=('✓ ' if pk == task.get('priority', 'normal') else '') + f'{pi} {t(pko, pen)}',
                             command=lambda k=pk: (self._run_bg(lambda: buni_team.set_task_priority(job['id'], task['id'], k)), self.win.after(500, lambda: self.refresh(force=True))))
        mb.pack(side='left')
        if task.get('created'):
            tk.Label(head, text=time.strftime('%m/%d %H:%M', time.localtime(task['created'])), bg=PANEL, fg=DIM, font=(FONT, 8)).pack(side='right')
        tk.Label(card, text=task.get('title', ''), bg=PANEL, fg=FG, font=(FONT, 9, 'bold'), wraplength=190, justify='left', anchor='w').pack(fill='x', padx=8)
        parts = sorted((task.get('parts') or {}).items(), key=lambda kv: kv[1])
        roles = {r['id']: r for r in job['plan']['roles']}
        pst = task.get('part_status') or {}
        for rid, _since in parts:
            r = roles.get(rid, {'name': rid, 'icon': '🧑‍💻'})
            ps = pst.get(rid, 'todo')
            row = tk.Frame(card, bg=PANEL); row.pack(fill='x', padx=8, pady=(3, 0))
            tk.Label(row, text=f"{r.get('icon', '')} {r.get('name', rid)}", bg=PANEL, fg='#C4C4CE', font=(FONT, 8), anchor='w').pack(side='left')
            held = (job.get('roles') or {}).get(rid, {}).get('hold')
            txt, c = {'done': (t('✓ 처리됨', '✓ Done'), GREEN), 'doing': (t('⏳ 처리 중', '⏳ Working'), GREEN), 'review': (t('🔎 검토 중', '🔎 Review'), GOLD)}.get(
                ps, (t('시작 대기', 'Not started') if held else t('○ 대기', '○ Waiting'), GOLD if held else DIM))
            tk.Label(row, text=txt, bg=PANEL, fg=c, font=(FONT, 8, 'bold')).pack(side='right')
        if not parts:
            tk.Label(card, text=t('⏳ 담당 팀원 정하는 중 / 확인 대기', '⏳ Assigning / waiting for confirmation'), bg=PANEL, fg=DIM, font=(FONT, 8)).pack(fill='x', padx=8, pady=(3, 0))
        done_n = sum(1 for v in pst.values() if v == 'done')
        if len(parts) > 1:
            tk.Label(card, text=f'{done_n}/{len(parts)}', bg=PANEL, fg=DIM, font=(FONT, 8), anchor='w').pack(fill='x', padx=8)
        if key == 'doing':
            rid = next((r for r in pst if pst[r] == 'doing'), None)
            if rid:
                lines = buni_team.load_activity(job['id'], rid).get('lines', [])
                tk.Label(card, text='⏳ ' + (lines[-1]['text'] if lines else t('시작하는 중…', 'Starting…')), bg=PANEL, fg='#B0B0BC', font=(FONT, 8),
                         wraplength=190, justify='left', anchor='w').pack(fill='x', padx=8, pady=(3, 0))
        elif key in ('review', 'done'):
            rid = next((r for r in pst if pst[r] in ('done', 'review')), None)
            summ = (job.get('roles') or {}).get(rid, {}).get('summary') if rid else ''
            if summ:
                s_, _more = self._summary(summ, 110)
                tk.Label(card, text=s_, bg=PANEL, fg='#B0B0BC', font=(FONT, 8), wraplength=190, justify='left', anchor='w').pack(fill='x', padx=8, pady=(3, 0))
            if key == 'done':
                if task.get('done_at'):
                    tk.Label(card, text='✓ ' + time.strftime('%m/%d %H:%M', time.localtime(task['done_at'])) + t(' 완료', ' done'), bg=PANEL, fg=GREEN, font=(FONT, 8), anchor='w').pack(fill='x', padx=8)
                if task.get('applied'):
                    tk.Label(card, text='📥 ' + t(f"내 폴더에 반영됨 {len(task.get('files') or [])}개 파일", f"Applied {len(task.get('files') or [])} files"), bg=PANEL, fg='#6AA9FF',
                             font=(FONT, 8), anchor='w').pack(fill='x', padx=8)
                elif task.get('apply_note'):
                    tk.Label(card, text='✋ ' + t('반영 승인 대기 — ', 'Waiting for approval — ') + task['apply_note'][:120], bg=PANEL, fg=GOLD, font=(FONT, 8),
                             wraplength=190, justify='left', anchor='w').pack(fill='x', padx=8)
        acts = tk.Frame(card, bg=PANEL); acts.pack(fill='x', padx=8, pady=(6, 8))
        hold = next((r for r, _ in parts if (job.get('roles') or {}).get(r, {}).get('hold')), None)
        if hold:
            self._btn(acts, t('▶ 시작', '▶ Start'), lambda rid=hold: self._run_bg(lambda: buni_team.start_role(job['id'], rid)), ACCENT).pack(side='left', padx=(0, 4))
        if parts:
            self._btn(acts, t('대화', 'Chat'), lambda rid=parts[0][0]: self.set_pane(job['id'], 'dm:' + rid), FIELD).pack(side='left')

    def _add_request_box(self, pad, job, button, hint='', collect=None):
        """요청을 새로 적어 팀장에게 보낸다. collect() 는 (지금까지의 답, 고친 요구서)를 돌려준다."""
        t = self.t
        box = tk.Frame(pad, bg=FIELD); box.pack(fill='x', pady=(10, 0))
        if hint:
            self._label(box, hint, DIM, 8, wraplength=560).pack(anchor='w', padx=10, pady=(8, 2))
        txt = tk.Text(box, bg=PANEL, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9), wrap='word', height=3)
        txt.pack(fill='x', padx=10, pady=(4, 4))

        def send():
            text = txt.get('1.0', 'end').strip()
            if not text:
                return
            answers, reqs = collect() if collect else (None, None)

            def run():
                try:
                    buni_team.add_request(job['id'], text, answers, reqs)
                except ValueError as e:
                    self._note_error = str(e)
            threading.Thread(target=run, daemon=True).start()
            time.sleep(0.2)
            self.refresh(force=True)
        self._btn(box, button, send, FIELD).pack(anchor='w', padx=10, pady=(0, 8))

    def _retry_interview(self, job):
        threading.Thread(target=buni_team.resume_interview, args=(job['id'],), daemon=True).start()
        time.sleep(0.2)
        self.refresh(force=True)

    def _draw_questions(self, pad, job):
        t = self.t
        iv = job['interview']
        if iv.get('understanding'):
            self._label(pad, t('이해한 내용: ', 'Understanding: ') + iv['understanding'], DIM, 9, wraplength=580).pack(anchor='w', pady=(0, 8))
        self._label(pad, t('새벽에는 아무도 대답할 수 없어요. 아래 질문에 미리 답해 주세요. 모르겠으면 추천값 그대로 두면 돼요.',
                           'Nobody can answer at night. Please answer these now — leave the suggested value if unsure.'), FG, 9, wraplength=580).pack(anchor='w', pady=(0, 6))
        canvas = tk.Canvas(pad, bg=PANEL, highlightthickness=0, height=300)
        sb = tk.Scrollbar(pad, orient='vertical', command=canvas.yview)
        inner = tk.Frame(canvas, bg=PANEL)
        inner.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.create_window((0, 0), window=inner, anchor='nw')
        canvas.configure(yscrollcommand=sb.set)
        canvas.pack(side='top', fill='both', expand=True); sb.place(relx=1.0, rely=0.18, relheight=0.6, anchor='ne')
        answers = {}
        for q in iv['questions']:
            box = tk.Frame(inner, bg=FIELD); box.pack(fill='x', pady=4, padx=(0, 14))
            self._label(box, q['question'], FG, 10, True, wraplength=520).pack(anchor='w', padx=10, pady=(8, 0))
            if q.get('why'):
                self._label(box, q['why'], DIM, 8, wraplength=520).pack(anchor='w', padx=10)
            var = tk.StringVar(value=q.get('default') or (q['options'][0] if q['options'] else ''))
            custom = tk.StringVar()
            for opt in q['options']:
                tk.Radiobutton(box, text=opt, value=opt, variable=var, bg=FIELD, fg=FG, selectcolor=PANEL, activebackground=FIELD,
                               activeforeground=FG, font=(FONT, 9), anchor='w').pack(fill='x', padx=14)
            row = tk.Frame(box, bg=FIELD); row.pack(fill='x', padx=10, pady=(2, 8))
            self._label(row, t('직접 입력:', 'Other:'), DIM, 8).pack(side='left')
            tk.Entry(row, textvariable=custom, bg=PANEL, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9)).pack(side='left', fill='x', expand=True, padx=6, ipady=2)
            answers[q['id']] = (var, custom)

        def send():
            data = {qid: (c.get().strip() or v.get()) for qid, (v, c) in answers.items()}
            threading.Thread(target=buni_team.answer_interview, args=(job['id'], data), daemon=True).start()
            time.sleep(0.2)
            self.refresh(force=True)
        row = tk.Frame(pad, bg=PANEL); row.pack(fill='x', pady=(8, 0))
        self._btn(row, t('답변 보내기 →', 'Send answers →'), send, ACCENT).pack(side='left')
        self._btn(row, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(side='right')
        self._add_request_box(
            pad, job, t('➕ 요청 추가하고 질문 다시 받기', '➕ Add request & re-ask'),
            t('빠뜨린 요구사항이 있나요? 적어 주면 지금까지 적은 답과 함께 팀장에게 전달하고, 그에 맞는 질문을 다시 받아요.',
              "Missed something? Add it — it goes to the lead with your answers so far, and you'll get matching questions."),
            collect=lambda: ({qid: (c.get().strip() or v.get()) for qid, (v, c) in answers.items()}, None))

    def _draw_requirements(self, pad, job):
        t = self.t
        self._label(pad, t('사전요구서 — 팀이 새벽에 이 문서만 보고 일해요. 읽어 보고 고칠 곳이 있으면 직접 고쳐도 돼요.',
                           'Requirements — the team works from this document alone at night. Edit it if needed.'), FG, 9, wraplength=580).pack(anchor='w', pady=(0, 6))
        box = tk.Frame(pad, bg=PANEL); box.pack(fill='both', expand=True)
        txt = tk.Text(box, bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9), wrap='word')
        sb = tk.Scrollbar(box, command=txt.yview); txt.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); txt.pack(side='left', fill='both', expand=True)
        txt.insert('1.0', job['requirements'])
        s = buni_team.load_settings()
        self._label(pad, t(f"바로 시작하면 지금 곧 일을 시작하고, 예약을 고르면 {s['window_start']}~{s['window_end']} 사이에 자동으로 시작해요. 웹 검색: {'허용' if job['permissions'].get('web') else '안 함'}.",
                           f"Start now begins right away; schedule starts automatically between {s['window_start']} and {s['window_end']}. Web search: {'allowed' if job['permissions'].get('web') else 'off'}."), DIM, 8, wraplength=580).pack(anchor='w', pady=(6, 6))
        row = tk.Frame(pad, bg=PANEL); row.pack(fill='x')

        def approve(now):
            buni_team.approve_job(job['id'], txt.get('1.0', 'end'), start_now=now)
            self.refresh(force=True)
        self._btn(row, t('▶ 승인하고 지금 바로 시작', '▶ Approve & start now'), lambda: approve(True), ACCENT).pack(side='left')
        self._btn(row, t('🌙 승인하고 예약 시간에 시작', '🌙 Approve & start at scheduled time'), lambda: approve(False), FIELD).pack(side='left', padx=8)
        self._btn(row, t('↩ 질문부터 다시', '↩ Start over'), lambda: self._restart(job), FIELD).pack(side='left', padx=8)
        self._btn(row, t('🗑 삭제', '🗑 Delete'), lambda: self._delete(job), FIELD).pack(side='right')
        self._btn(row, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(side='right', padx=8)
        self._add_request_box(
            pad, job, t('➕ 요청 추가하고 팀장에게 다시 묻기', '➕ Add request & ask the lead'),
            t('요구사항을 더 추가하고 싶나요? 적어 주면 위에서 고친 내용을 그대로 두고, 팀장이 필요한 질문을 다시 정리해요.',
              'Need more? Add it — your edits above are kept and the lead asks what else is needed.'),
            collect=lambda: (None, txt.get('1.0', 'end')))

    def _restart(self, job):
        threading.Thread(target=buni_team.restart_interview, args=(job['id'],), daemon=True).start()
        time.sleep(0.2)
        self.refresh(force=True)

    def _draw_progress(self, pad, job):
        t = self.t
        s = buni_team.load_settings()
        st = job['status']
        now = datetime.datetime.now()
        if st == 'queued' or st == 'paused':
            if s['enabled'] and buni_team.in_window(now, s['window_start'], s['window_end']):
                msg = t('곧 시작해요…', 'Starting soon…')
            elif s['enabled']:
                nxt = buni_team.next_window_start(now, s['window_start'])
                msg = t(f"🌙 {nxt.strftime('%m/%d %H:%M')} 에 시작해요", f"🌙 Starts {nxt.strftime('%m/%d %H:%M')}")
            else:
                msg = t('예약 실행이 꺼져 있어요 — "지금 바로 시작"을 눌러 주세요', 'Scheduling is off — press "Start now"')
            if st == 'paused':
                msg += t(' (이어서 진행해요)', ' (will continue)')
            self._label(pad, msg, GOLD, 10, True).pack(anchor='w', pady=(0, 8))
        elif st == 'waiting_limit':
            at = datetime.datetime.fromtimestamp(job['resume_at']).strftime('%m/%d %H:%M') if job.get('resume_at') else '?'
            self._label(pad, t(f'⏸ 플랜 사용량 한도에 걸렸어요 — {at} 이후에 이어서 해요', f'⏸ Hit the plan limit — continues after {at}'), GOLD, 10, True).pack(anchor='w', pady=(0, 8))
        else:
            phase = {'planning': t('팀 구성 중', 'Building the team'), 'working': t('팀원들이 작업 중', 'Team is working'),
                     'reviewing': t('팀장이 검토 중', 'Lead is reviewing'), 'merging': t('팀장이 결과를 합치는 중', 'Lead is merging'),
                     'wrapup': t('팀장이 검토할 것을 정리하는 중', 'Lead is listing what to review')}.get(job.get('phase'), '')
            self._label(pad, '🛠 ' + phase + (f"  ·  {job['busy_msg']}" if job.get('busy_msg') else ''), GREEN, 10, True).pack(anchor='w', pady=(0, 8))
        if job.get('plan'):
            self._label(pad, job['plan'].get('summary', ''), DIM, 9, wraplength=580).pack(anchor='w', pady=(0, 6))
            self._draw_board(pad, job)
        self._events(pad, job, 7)
        row = tk.Frame(pad, bg=PANEL); row.pack(fill='x', side='bottom', pady=(10, 0))
        if st != 'running':
            self._btn(row, t('▶ 지금 바로 시작', '▶ Start now'), lambda: self._run_now(job), ACCENT).pack(side='left')
        self._btn(row, t('⛔ 프로젝트 취소', '⛔ Cancel project'), lambda: self._cancel(job), FIELD).pack(side='left', padx=8)

    # ── 팀원(세션)별 진행 · 요구사항 전달 ──────────────────────
    # ── 슬랙식 채팅: 단체방(요약) · 팀장/팀원 DM(전문) ──────────────────
    def _has_room(self, job):
        return bool(job.get('plan')) and job['status'] in ('queued', 'running', 'waiting_limit', 'paused', 'review', 'done', 'failed')

    def _cur_pane(self, job):
        p = self._pane.get(job['id'])
        room = self._has_room(job)
        if p == 'requirements' and job.get('requirements'):
            return p
        if p and p != 'requirements' and (p == 'overview' or room):
            return p
        if room and job['status'] in ('queued', 'running', 'waiting_limit', 'paused'):
            return 'channel'
        return 'overview'

    def set_pane(self, job_id, pane):
        self._board = False
        self._pane[job_id] = pane
        self.refresh(force=True)

    def _chat_name(self, job, who):
        if who == 'lead':
            return '🐰 ' + self.t('팀장', 'Lead')
        if who == 'user':
            return self.t('나', 'Me')
        if who == 'all':
            return self.t('모두', 'Everyone')
        for r in (job.get('plan') or {}).get('roles', []):
            if r['id'] == who:
                return f"{r['icon']} {r['name']}"
        return who

    @staticmethod
    def _summary(text, limit=110):
        """단체방에 보일 한두 줄 요약 — 마크다운 기호를 걷고 첫 줄을 자른다."""
        lines = [l.strip() for l in (text or '').splitlines() if l.strip()]
        if not lines:
            return '', False
        s = lines[0].lstrip('#>*-•` ').replace('**', '').replace('`', '')
        more = len(lines) > 1
        if len(s) > limit:
            s, more = s[:limit - 1] + '…', True
        return s, more

    def _unread(self, job, pane, msgs):
        if self._cur_pane(job) == pane:
            return 0
        since = self._seen.get((job['id'], pane), self._opened.get(job['id'], time.time()))
        n = 0
        for m in msgs:
            if m['ts'] <= since or m['from'] in ('user', 'system') or m['kind'] == 'status':
                continue
            if pane == 'channel':
                n += 1
            elif pane == 'lead':
                n += 1 if (m['from'] == 'lead' and m['to'] == 'user' and m['kind'] == 'say') else 0
            elif pane.startswith('dm:'):
                r = pane[3:]
                n += 1 if (m['from'] == r or (m['from'] == 'lead' and m['to'] == r)) else 0
        return n

    def _msgs_for(self, job, pane, msgs):
        if pane == 'channel':
            return msgs
        if pane == 'lead':
            return [m for m in msgs if (m['from'] == 'user' and m['to'] in ('lead', 'all'))
                    or (m['from'] == 'lead' and m['to'] == 'user' and m['kind'] != 'status')]
        r = pane[3:]
        return [m for m in msgs if m['from'] == r or m['to'] == r]

    def _draw_proposal_cards(self, parent, job):
        """사전요구서의 기존 내용과 다른 요청 — 내가 정해야 요구서를 고치고 보류했던 지시를 보낸다."""
        t = self.t
        for p in [x for x in job.get('req_proposals', []) if x.get('status') == 'pending']:
            card = tk.Frame(parent, bg='#3A3020', highlightthickness=1, highlightbackground='#8A6A2A')
            card.pack(fill='x', padx=14, pady=(8, 0))
            tk.Label(card, text=t('✋ 사전요구서와 달라요 — 수정할까요?', '✋ This differs from the requirements — change them?'),
                     bg='#3A3020', fg=GOLD, font=(FONT, 9, 'bold')).pack(anchor='w', padx=10, pady=(8, 2))
            if p.get('was'):
                tk.Label(card, text=t('기존  ', 'Was  ') + p['was'], bg='#3A3020', fg='#A09070', font=(FONT, 9, 'overstrike'),
                         wraplength=640, justify='left', anchor='w').pack(anchor='w', padx=10)
            tk.Label(card, text=t('바뀜  ', 'Now  ') + p.get('now', ''), bg='#3A3020', fg=FG, font=(FONT, 9, 'bold'),
                     wraplength=640, justify='left', anchor='w').pack(anchor='w', padx=10)
            if p.get('why'):
                tk.Label(card, text=p['why'], bg='#3A3020', fg=DIM, font=(FONT, 8), wraplength=640, justify='left').pack(anchor='w', padx=10)
            row = tk.Frame(card, bg='#3A3020'); row.pack(anchor='w', padx=10, pady=8)
            self._btn(row, t('✅ 요구서를 수정하고 진행', '✅ Change it and go ahead'),
                      lambda pid=p['id']: self._resolve_proposal(job, pid, True), ACCENT).pack(side='left')
            self._btn(row, t('기존 유지', 'Keep the original'),
                      lambda pid=p['id']: self._resolve_proposal(job, pid, False), FIELD).pack(side='left', padx=8)

    def _resolve_proposal(self, job, pid, accept):
        def run():
            try:
                buni_team.resolve_req_proposal(job['id'], pid, accept)
            except ValueError as e:
                self._note_error = str(e)
        threading.Thread(target=run, daemon=True).start()
        self.win.after(600, lambda: self.refresh(force=True))

    def _draw_requirements_view(self, f, job):
        """지금 적용 중인 사전요구서 (채팅으로 추가·변경된 내용 포함)."""
        t = self.t
        outer = tk.Frame(f, bg=PANEL); outer.pack(fill='both', expand=True)
        self._draw_proposal_cards(outer, job)
        self._label(outer, t('채팅으로 새 방향을 말하면 아래 "추가 방향"에 들어가고, 기존 내용과 다르면 먼저 확인을 받아 고쳐요.',
                             'New directions from chat are added under "Added directions"; anything that conflicts is confirmed before the text changes.'),
                    DIM, 8, wraplength=680).pack(anchor='w', padx=20, pady=(10, 4))
        box = tk.Frame(outer, bg=PANEL); box.pack(fill='both', expand=True, padx=14, pady=(0, 10))
        txt = tk.Text(box, bg=PANEL, fg=FG, relief='flat', font=(FONT, 10), wrap='word', padx=8, pady=6, highlightthickness=0)
        sb = tk.Scrollbar(box, command=txt.yview); txt.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); txt.pack(side='left', fill='both', expand=True)
        render_markdown(txt, job.get('requirements') or '', {'fg': FG, 'dim': DIM, 'accent': '#6AA9FF', 'code_bg': FIELD, 'font': FONT})
        txt.config(state='disabled')

    def _draw_room(self, f, job, pane):
        t = self.t
        who = 'lead' if pane == 'lead' else (pane[3:] if pane.startswith('dm:') else None)
        wrap = tk.Frame(f, bg=PANEL); wrap.pack(fill='both', expand=True)
        if pane.startswith('dm:'):
            self._draw_member_card(wrap, job, who)
        else:
            self._draw_proposal_cards(wrap, job)
        box = tk.Frame(wrap, bg=PANEL); box.pack(fill='both', expand=True)
        txt = tk.Text(box, bg=PANEL, fg=FG, relief='flat', font=(FONT, 10), wrap='word', padx=16, pady=6,
                      cursor='arrow', height=10, highlightthickness=0)
        sb = tk.Scrollbar(box, command=txt.yview); txt.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); txt.pack(side='left', fill='both', expand=True)
        txt.tag_configure('name', font=(FONT, 10, 'bold'), spacing1=10)
        txt.tag_configure('dim', font=(FONT, 8), foreground=DIM)
        txt.tag_configure('body', font=(FONT, 10), lmargin1=22, lmargin2=22, rmargin=24, spacing3=2)
        txt.tag_configure('h', font=(FONT, 11, 'bold'), lmargin1=22, lmargin2=22, spacing1=4)
        txt.tag_configure('bold', font=(FONT, 10, 'bold'))
        txt.tag_configure('code', font=('Consolas', 9), background=FIELD)
        txt.tag_configure('day', justify='center', foreground=DIM, font=(FONT, 8, 'bold'), spacing1=14, spacing3=4)
        txt.tag_configure('sys', justify='center', foreground=DIM, font=(FONT, 8), spacing1=3)
        txt.tag_configure('link', foreground='#6AA9FF', font=(FONT, 9, 'bold'), lmargin1=22, lmargin2=22)
        txt.tag_configure('tag_instruction', foreground=GOLD, font=(FONT, 8, 'bold'))
        txt.tag_configure('tag_report', foreground=GREEN, font=(FONT, 8, 'bold'))
        txt.tag_configure('tag_review', foreground='#6AA9FF', font=(FONT, 8, 'bold'))
        self._room_token += 1
        self._room = {'txt': txt, 'job': job, 'pane': pane, 'sig': None, 'token': self._room_token}
        self._fill_room()

        names = [('lead', t('팀장', 'Lead'))] + [(r['id'], r['name']) for r in job['plan']['roles']]
        if pane == 'channel':
            ph = t('#스쿼드 에 메시지 보내기 — 팀장이 듣고 필요한 팀원에게 나눠 지시해요', 'Message #squad — the lead splits work among teammates')
            hint = t('Enter 보내기 · Shift+Enter 줄바꿈 · @이름 으로 한 팀원에게만 지시', 'Enter to send · Shift+Enter new line · @name to instruct one teammate')

            def on_send(text):
                self._send_channel(job, text, names)
        elif pane == 'lead':
            ph = t('팀장에게 메시지 보내기', 'Message the lead')
            hint = t('팀장이 이해해서 답하고, 필요한 팀원에게 나눠 지시해요 (약 1분)', 'The lead replies and delegates as needed (about a minute)')

            def on_send(text):
                self._run_bg(lambda: buni_team.chat_send(job['id'], 'lead', text))
        else:
            nm = self._chat_name(job, who)
            status = job['roles'].get(who, {}).get('status', 'pending')
            ph = t(f'{nm} 에게만 지시하기', f'Instruct {nm} only')
            hint = (t('지금 하는 일이 끝나면 반영해서 다시 진행해요.', 'Applied by redoing the work once this run finishes.') if status == 'running'
                    else t('이 팀원이 시작할 때 반영해요.', 'Applied when this teammate starts.') if status in ('pending', 'revise')
                    else t('이미 끝난 팀원이면 다시 열어 반영해요. 이 팀원의 산출물을 쓰는 팀원도 다시 확인해요.', 'If already done, it is reopened. Teammates relying on it re-check too.'))

            def on_send(text):
                self._run_bg(lambda: buni_team.send_role_note(job['id'], who, text))
        self._composer(wrap, job, pane, ph, hint, on_send, disabled=job['status'] == 'cancelled')
        token = self._room_token
        self.win.after(1500, lambda: self._room_poll(token))

    def _run_bg(self, fn):
        def run():
            try:
                fn()
            except ValueError as e:
                self._note_error = str(e)                 # 화면 갱신(_tick)에서 보여 준다 — Tk 는 다른 스레드에서 만지지 않는다
        threading.Thread(target=run, daemon=True).start()

    def _send_channel(self, job, text, names):
        """단체방에서 보내기 — '@이름 …' 이면 그 팀원에게만, 아니면 팀장이 듣고 나눠 지시한다."""
        if text.startswith('@'):
            body = text[1:]
            for rid, nm in names:
                if body.startswith(nm):
                    rest = body[len(nm):].strip()
                    if rest:
                        if rid == 'lead':
                            self._run_bg(lambda: buni_team.chat_send(job['id'], 'lead', rest))
                        else:
                            self._run_bg(lambda: buni_team.send_role_note(job['id'], rid, rest))
                        return
        self._run_bg(lambda: buni_team.chat_send(job['id'], 'lead', text))

    def _composer(self, parent, job, pane, placeholder, hint, on_send, disabled=False):
        """슬랙식 입력창 — 여러 줄, Enter 보내기 · Shift+Enter 줄바꿈. 다시 그려도 쓰던 글은 남긴다."""
        key = (job['id'], pane)
        bar = tk.Frame(parent, bg=PANEL); bar.pack(fill='x', side='bottom', padx=14, pady=(4, 10))
        tk.Frame(parent, bg=LINE, height=1).pack(fill='x', side='bottom')
        border = tk.Frame(bar, bg=FIELD, highlightthickness=1, highlightbackground='#4A4A58', highlightcolor=ACCENT)
        border.pack(fill='x')
        ent = tk.Text(border, height=1, wrap='word', bg=FIELD, fg=FG, insertbackground=FG, relief='flat',
                      font=(FONT, 10), padx=8, pady=7, undo=True, highlightthickness=0)
        ent._is_composer = True
        self._composer_widget = (key, ent)
        ent.pack(side='left', fill='x', expand=True)
        ph = tk.Label(border, text=placeholder, bg=FIELD, fg='#6A6A78', font=(FONT, 10), anchor='w')
        ph.place(x=10, y=7)
        send_btn = tk.Button(border, text='➤', bg=ACCENT, fg=FG, relief='flat', bd=0, cursor='hand2', font=(FONT, 10, 'bold'),
                             padx=10, pady=2, activebackground=ACCENT, activeforeground=FG)
        send_btn.pack(side='right', padx=6, pady=5)
        tk.Label(bar, text=hint, bg=PANEL, fg='#6A6A78', font=(FONT, 8), anchor='w', wraplength=560, justify='left').pack(anchor='w', pady=(3, 0))

        def sync(_e=None):
            self._drafts[key] = ent.get('1.0', 'end-1c')
            if self._drafts[key]:
                ph.place_forget()
            else:
                ph.place(x=10, y=7)
            try:
                n = int(ent.count('1.0', 'end-1c', 'displaylines')[0])
            except Exception:
                n = 1
            ent.config(height=max(1, min(5, n)))

        def send(_e=None):
            if disabled:
                return 'break'
            text = ent.get('1.0', 'end-1c').strip()
            if not text:
                return 'break'
            ent.delete('1.0', 'end')
            sync()
            on_send(text)
            return 'break'

        def newline(_e=None):
            ent.insert('insert', '\n'); sync()
            return 'break'
        ent.bind('<Return>', send)
        ent.bind('<Shift-Return>', newline)
        ent.bind('<KeyRelease>', sync)
        send_btn.config(command=send)
        ph.bind('<Button-1>', lambda e: ent.focus_set())
        draft = self._drafts.get(key, '')
        if draft:
            ent.insert('1.0', draft)
        sync()
        if self._want_focus or draft:
            ent.focus_set()
        self._want_focus = False

    def _room_poll(self, token):
        w = getattr(self, '_room', None)
        if not w or w['token'] != token:
            return
        try:
            if not w['txt'].winfo_exists():
                return
            self._fill_room()
            self.win.after(1500, lambda: self._room_poll(token))
        except tk.TclError:
            pass

    def _fill_room(self):
        w = self._room
        if not w:
            return
        txt, job, pane = w['txt'], w['job'], w['pane']
        t = self.t
        allmsgs = buni_team.load_chat(job['id'])
        msgs = self._msgs_for(job, pane, allmsgs)
        typing = buni_team.chat_typing(job['id']) if pane in ('channel', 'lead') else ''
        sig = (len(msgs), typing)
        if sig == w['sig']:
            return
        w['sig'] = sig
        self._seen[(job['id'], pane)] = time.time()              # 지금 보고 있으니 읽은 것으로
        grouped = pane == 'channel'
        dm = pane != 'channel'
        txt.config(state='normal'); txt.delete('1.0', 'end')
        if not msgs:
            empty = (t('아직 대화가 없어요. 팀이 일을 시작하면 지시와 보고 요약이 여기에 쌓여요.', 'Nothing yet — summaries of instructions and reports will show up here.') if pane == 'channel'
                     else t('팀장과 나눈 대화가 여기에 모여요.', 'Your conversation with the lead.') if pane == 'lead'
                     else t('아직 이 팀원과 주고받은 대화가 없어요.', 'No messages with this teammate yet.'))
            txt.insert('end', '\n\n' + empty, 'sys')
        badges = {'instruction': (t('지시', 'ORDER'), 'tag_instruction'), 'report': (t('보고', 'REPORT'), 'tag_report'),
                  'review': (t('검토', 'REVIEW'), 'tag_review')}
        last_day, prev = '', None
        for i, m in enumerate(msgs):
            day = time.strftime('%Y-%m-%d', time.localtime(m['ts']))
            if day != last_day:
                today = time.strftime('%Y-%m-%d')
                label = t('오늘', 'Today') if day == today else time.strftime('%m/%d', time.localtime(m['ts']))
                txt.insert('end', f'\n── {label} ──\n', 'day'); last_day = day; prev = None
            clock = time.strftime('%H:%M', time.localtime(m['ts']))
            if m['from'] == 'system' or m['kind'] == 'status':
                who = m['to'] if m['from'] == 'system' else m['from']
                pre = '' if who in ('all', 'user', 'lead', 'system', '') else self._chat_name(job, who) + ' · '
                txt.insert('end', pre + self._summary(m['text'], 90 if grouped else 120)[0] + '\n', 'sys'); prev = None
                continue
            plain = m['kind'] in ('say', 'user')
            same = plain and prev is not None and prev['from'] == m['from'] and prev['kind'] == m['kind'] and m['ts'] - prev['ts'] < 300
            if not same:
                txt.insert('end', self._chat_name(job, m['from']), 'name')
                if grouped and m['kind'] != 'report' and m['to'] not in ('lead', 'all', 'user', ''):
                    txt.insert('end', '  → ' + self._chat_name(job, m['to']), 'dim')
                if m['kind'] in badges:
                    txt.insert('end', '  ' + badges[m['kind']][0], badges[m['kind']][1])
                txt.insert('end', '  ' + clock + '\n', 'dim')
            if grouped and m['kind'] in ('instruction', 'report', 'review'):
                s, more = self._summary(m['text'])
                txt.insert('end', s + '\n', 'body')
                member = m['from'] if m['kind'] == 'report' else m['to']
                if (more or m['kind'] != 'review') and member not in ('lead', 'all', 'user'):
                    tag = f'lnk{i}'
                    txt.insert('end', t('상세 보기 ›', 'Details ›') + '\n', ('link', tag))
                    txt.tag_bind(tag, '<Button-1>', lambda e, r=member: self.set_pane(job['id'], 'dm:' + r))
                    txt.tag_bind(tag, '<Enter>', lambda e: txt.config(cursor='hand2'))
                    txt.tag_bind(tag, '<Leave>', lambda e: txt.config(cursor='arrow'))
            elif dm and m['kind'] == 'report':
                self._md_lite(txt, m['text'])
            else:
                txt.insert('end', m['text'] + '\n', 'body')
            prev = m
        if typing:
            txt.insert('end', '\n' + self._chat_name(job, typing) + t(' 이(가) 입력하는 중…', ' is typing…') + '\n', 'sys')
        txt.config(state='disabled'); txt.see('end')
        self._refresh_sidebar_badges()

    @staticmethod
    def _md_lite(txt, text):
        """DM 의 보고서 전문 — 제목·목록·굵게·코드 기호를 걷어 읽기 좋게 넣는다."""
        for line in text.split('\n'):
            s = line.rstrip()
            if re.match(r'^#{1,6}\s', s):
                txt.insert('end', re.sub(r'^#{1,6}\s+', '', s) + '\n', 'h'); continue
            if re.match(r'^\s*[-*]\s+', s):
                s = '• ' + re.sub(r'^\s*[-*]\s+', '', s)
            pos = 0
            for m in re.finditer(r'\*\*(.+?)\*\*|`([^`]+)`', s):
                txt.insert('end', s[pos:m.start()], 'body')
                if m.group(1) is not None:
                    txt.insert('end', m.group(1), ('body', 'bold'))
                else:
                    txt.insert('end', m.group(2), ('body', 'code'))
                pos = m.end()
            txt.insert('end', s[pos:] + '\n', 'body')

    def _refresh_sidebar_badges(self):
        """대화가 늘면 사이드바의 안 읽은 표시만 다시 그린다 (입력창은 건드리지 않는다)."""
        try:
            jobs = buni_team.list_jobs()
            sig = tuple(self._unread(j, p, buni_team.load_chat(j['id'])) for j in jobs if j['id'] == self.sel
                        for p in self._pane_keys(j))
            if sig != getattr(self, '_badge_sig', None):
                self._badge_sig = sig
                self._draw_list(jobs)
        except Exception:
            pass

    def _pane_keys(self, job):
        if not self._has_room(job):
            return []
        return ['channel', 'lead'] + ['dm:' + r['id'] for r in job['plan']['roles']]

    def _draw_member_card(self, parent, job, who):
        """DM 위쪽 — 이 팀원의 상태 · 하는 일 · 실시간 활동 · Claude 에서 열기."""
        t = self.t
        rs = job['roles'].get(who, {})
        role = next((r for r in job['plan']['roles'] if r['id'] == who), {})
        ko, en, color = ROLE_STATUS.get(rs.get('status', 'pending'), ('대기', 'Waiting', DIM))
        card = tk.Frame(parent, bg='#2B2B35'); card.pack(fill='x')
        top = tk.Frame(card, bg='#2B2B35'); top.pack(fill='x', padx=14, pady=(8, 2))
        label = t(ko, en) + (f"  ({rs.get('attempts')}회)" if rs.get('attempts', 0) > 1 else '')
        tk.Label(top, text='● ' + label, bg='#2B2B35', fg=color, font=(FONT, 9, 'bold')).pack(side='left')
        if rs.get('note_pending'):
            tk.Label(top, text=t('  📨 반영 대기', '  📨 queued'), bg='#2B2B35', fg=GOLD, font=(FONT, 8)).pack(side='left')
        if role.get('depends_on'):
            tk.Label(top, text='  ← ' + ', '.join(role['depends_on']), bg='#2B2B35', fg=DIM, font=(FONT, 8)).pack(side='left')
        sessions = [s for s in buni_team.load_sessions(job['id']) if s.get('key') == who]
        if sessions:
            self._btn(top, t('💻 Claude에서 열기', '💻 Open in Claude'),
                      lambda sid=sessions[-1]['id']: self._open_session(job, sid), FIELD).pack(side='right')
        default_name = self._model_name(buni_team.load_settings().get('model', ''))
        mb = self._model_menu(top, role.get('model', ''), t(f'기본 ({default_name})', f'Default ({default_name})'),
                              lambda m: self._run_bg(lambda: buni_team.set_role_model(job['id'], who, m)))
        mb.pack(side='right', padx=(0, 8))
        tk.Label(top, text=t('모델', 'Model'), bg='#2B2B35', fg=DIM, font=(FONT, 8)).pack(side='right')
        if role.get('mission'):
            self._label(card, role['mission'] if len(role['mission']) < 200 else role['mission'][:198] + '…', '#B0B0BC', 8,
                        wraplength=640).pack(anchor='w', padx=14)
        atxt = tk.Text(card, bg='#22222A', fg=FG, relief='flat', font=('Consolas', 8), wrap='word', height=5, highlightthickness=0)
        atxt.pack(fill='x', padx=14, pady=(4, 8))
        self._act_widget = (atxt, job['id'], who)
        self._fill_activity()

    def _toggle_role(self, key):
        self._open_role = None if getattr(self, '_open_role', None) == key else key
        self.refresh(force=True)

    def _draw_board(self, pad, job):
        """팀장·팀원을 한 줄씩 보여 주고, 누르면 그 세션의 실시간 진행·Claude 에서 열기·요구사항 전달이 펼쳐진다."""
        t = self.t
        board = tk.Frame(pad, bg=PANEL); board.pack(fill='x')
        lead_phase = {'planning': t('팀 구성 중', 'Building the team'), 'reviewing': t('검토 중', 'Reviewing'),
                      'merging': t('결과 합치는 중', 'Merging'), 'wrapup': t('정리 중', 'Wrapping up')}.get(job.get('phase'), t('대기', 'Waiting'))
        rows = [('lead', '🐰', t('팀장', 'Team lead'), lead_phase, GREEN if job.get('phase') in ('planning', 'reviewing', 'merging', 'wrapup') else DIM, [], False)]
        for r in job['plan']['roles']:
            rs = job['roles'].get(r['id'], {})
            ko, en, color = ROLE_STATUS.get(rs.get('status', 'pending'), ('대기', 'Waiting', DIM))
            label = t(ko, en) + (f"  ({rs.get('attempts')}회)" if rs.get('attempts', 0) > 1 else '')
            if rs.get('note_pending'):
                label += t('  · 📨 반영 대기', '  · 📨 queued')
            rows.append((r['id'], r['icon'], r['name'], label, color, r.get('depends_on') or [], True))
        for key, icon, name, label, color, deps, can_send in rows:
            box = tk.Frame(board, bg=FIELD); box.pack(fill='x', pady=2)
            row = tk.Frame(box, bg=FIELD, cursor='hand2'); row.pack(fill='x')
            tk.Label(row, text=f"{icon}  {name}", bg=FIELD, fg=FG, font=(FONT, 10, 'bold'), width=16, anchor='w').pack(side='left', padx=10, pady=6)
            tk.Label(row, text=label, bg=FIELD, fg=color, font=(FONT, 9, 'bold')).pack(side='left')
            tk.Label(row, text='▲' if getattr(self, '_open_role', None) == key else '▼', bg=FIELD, fg=DIM, font=(FONT, 8)).pack(side='right', padx=10)
            if deps:
                tk.Label(row, text='← ' + ', '.join(deps), bg=FIELD, fg=DIM, font=(FONT, 8)).pack(side='right', padx=4)
            for w in (row,) + tuple(row.winfo_children()):
                w.bind('<Button-1>', lambda e, k=key: self._toggle_role(k))
            if getattr(self, '_open_role', None) == key:
                self._draw_session_panel(box, job, key, can_send)

    def _draw_session_panel(self, box, job, key, can_send):
        t = self.t
        panel = tk.Frame(box, bg=FIELD); panel.pack(fill='x', padx=10, pady=(0, 10))
        rs = job['roles'].get(key, {}) if can_send else {}
        if rs.get('summary'):
            self._label(panel, rs['summary'], DIM, 8, wraplength=540).pack(anchor='w', pady=(0, 4))
        txt = tk.Text(panel, bg=PANEL, fg=FG, relief='flat', font=('Consolas', 8), wrap='word', height=8)
        txt.pack(fill='x')
        self._act_widget = (txt, job['id'], key)
        self._fill_activity()
        sessions = [s for s in buni_team.load_sessions(job['id']) if s.get('key') == key]
        bar = tk.Frame(panel, bg=FIELD); bar.pack(fill='x', pady=(6, 0))
        if sessions:
            self._btn(bar, t('💻 Claude에서 열기', '💻 Open in Claude'),
                      lambda sid=sessions[-1]['id']: self._open_session(job, sid), PANEL).pack(side='left')
            if len(sessions) > 1:
                mb = tk.Menubutton(bar, text=t(f'이전 세션 {len(sessions) - 1}개', f'{len(sessions) - 1} earlier'), bg=PANEL, fg=FG,
                                   relief='flat', font=(FONT, 9), padx=10, pady=5)
                menu = tk.Menu(mb, tearoff=0); mb['menu'] = menu
                for sdata in reversed(sessions[:-1]):
                    menu.add_command(label=time.strftime('%H:%M:%S', time.localtime(sdata.get('started', 0))) + '  ' + str(sdata.get('label', '')),
                                     command=lambda sid=sdata['id']: self._open_session(job, sid))
                mb.pack(side='left', padx=6)
            self._label(bar, t('터미널에서 이 세션을 이어서 열어요', 'Opens this session in a terminal'), DIM, 8).pack(side='left', padx=8)
        if not can_send:
            return
        for n in rs.get('notes') or []:
            self._label(panel, '📨 ' + str(n.get('text', '')), DIM, 8, wraplength=540).pack(anchor='w', pady=(4, 0))
        row = tk.Frame(panel, bg=FIELD); row.pack(fill='x', pady=(8, 0))
        var = tk.StringVar()
        ent = tk.Entry(row, textvariable=var, bg=PANEL, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9))
        ent.pack(side='left', fill='x', expand=True, ipady=3)
        self._btn(row, t('📨 보내기', '📨 Send'), lambda: self._send_note(job, key, var), ACCENT).pack(side='left', padx=(6, 0))
        status = rs.get('status', 'pending')
        hint = (t('지금 하는 일이 끝나면 반영해서 다시 진행해요.', 'Applied by redoing the work once this run finishes.') if status == 'running'
                else t('이 팀원이 시작할 때 반영해요.', 'Applied when this teammate starts.') if status in ('pending', 'revise')
                else t('이미 끝난 팀원이면 다시 열어 반영해서 진행해요. 이 팀원의 산출물을 쓰는 팀원도 다시 확인해요.',
                       "If already done, it's reopened and redone. Teammates relying on it re-check too."))
        self._label(panel, t('이 팀원에게만 전할 요구사항 — ', 'A request just for this teammate — ') + hint, DIM, 8, wraplength=540).pack(anchor='w', pady=(4, 0))

    def _fill_activity(self):
        """열려 있는 팀원의 활동 기록을 보여 주고, 열려 있는 동안 2초마다 다시 읽는다."""
        w = getattr(self, '_act_widget', None)
        if not w:
            return
        txt, jid, key = w
        try:
            if not txt.winfo_exists():
                self._act_widget = None
                return
            act = buni_team.load_activity(jid, key)
            lines = act.get('lines', [])[-12:]
            body = '\n'.join(time.strftime('%H:%M:%S', time.localtime(l['ts'])) + '  ' + l['text'] for l in lines) \
                or self.t('아직 시작하지 않았어요.', 'Not started yet.')
            if act.get('state') == 'running':
                body += '\n' + self.t('● 지금 진행 중', '● Working now')
            txt.config(state='normal'); txt.delete('1.0', 'end'); txt.insert('1.0', body); txt.config(state='disabled')
            txt.see('end')
            self.win.after(2000, self._fill_activity)
        except tk.TclError:
            self._act_widget = None

    def _model_name(self, mid, default_label=None):
        for m, ko, en in buni_team.MODEL_CHOICES:
            if m == mid:
                return (default_label if (not mid and default_label) else self.t(ko, en))
        return mid or (default_label or self.t('기본 모델', 'Default'))

    def _model_menu(self, parent, current, default_label, on_pick):
        """모델 고르는 작은 메뉴 버튼 (빈 값 = 기본 모델)."""
        t = self.t
        mb = tk.Menubutton(parent, text=self._model_name(current, default_label) + ' ▾', bg=parent['bg'], fg=FG, relief='flat',
                           font=(FONT, 9, 'bold'), padx=6, activebackground=parent['bg'], activeforeground=FG, cursor='hand2')
        menu = tk.Menu(mb, tearoff=0); mb['menu'] = menu

        def pick(mid):
            mb.config(text=self._model_name(mid, default_label) + ' ▾')
            on_pick(mid)
        for mid, ko, en in buni_team.MODEL_CHOICES:
            menu.add_command(label=default_label if not mid else t(ko, en), command=lambda m=mid: pick(m))
        return mb

    def _open_session(self, job, sid):
        threading.Thread(target=buni_team.open_session_in_terminal, args=(job['id'], sid), daemon=True).start()

    # ── 업무 현황: 상태별 칼럼 보드 · 목록 · 검색/필터 · 상세 (판정은 buni_team.board_* — 맥과 같다) ──
    def _open_board(self):
        self._board, self._bsel = True, None
        self.refresh(force=True)

    def _board_goto(self, job_id, pane):
        """상세에서 프로젝트 화면(담당자 DM · 결과 · 스쿼드 채팅)으로 — 같은 프로젝트 안의 화면이다."""
        self._board = False
        self.sel = job_id
        self._pane[job_id] = pane
        if job_id not in self._opened:
            self._opened[job_id] = time.time()
        self.refresh(force=True)

    def _show_board(self):
        if not self._board_built:
            for w in self.right.winfo_children():
                w.destroy()
            self._vars = {}
            self._build_board_frame()
            self._board_built = True
        self._draw_board_results()

    def _bset(self, key, value):
        self._bf[key] = value
        if key == 'view' or key == 'scope':
            self._board_built = False                         # 눌림 표시를 다시 그리려고 틀부터 다시 만든다
            self._show_board()
        else:
            self._draw_board_results()

    def _build_board_frame(self):
        t, bf = self.t, self._bf
        top = tk.Frame(self.right, bg=PANEL); top.pack(fill='x', padx=16, pady=(12, 4))
        self._label(top, '📊 ' + t('업무 현황', 'Task board'), size=13, bold=True).pack(side='left')
        for view, ko, en in (('list', '목록', 'List'), ('board', '보드', 'Board')):
            on = bf['view'] == view
            b = self._btn(top, t(ko, en), lambda v=view: self._bset('view', v), ACCENT if on else FIELD)
            b.config(padx=10, pady=2); b.pack(side='right', padx=(4, 0))
        bar = tk.Frame(self.right, bg=PANEL); bar.pack(fill='x', padx=16, pady=(2, 4))
        q = tk.StringVar(value=bf['q'])
        ent = tk.Entry(bar, textvariable=q, bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9), width=26)
        ent.pack(side='left', ipady=3, padx=(0, 8))
        q.trace_add('write', lambda *a: self._bset('q', q.get()))
        self._bvars = {'q': q}
        self._label(bar, t('🔎 제목·담당자·내용', '🔎 title · assignee · text'), DIM, 8).pack(side='left', padx=(0, 10))
        self._bmenus = {}
        for key, ko, en in (('status', '상태', 'Status'), ('assignee', '담당자', 'Assignee'), ('sort', '정렬', 'Sort')):
            mb = tk.Menubutton(bar, bg=FIELD, fg=FG, relief='flat', font=(FONT, 9), padx=8, pady=3, cursor='hand2', activebackground=FIELD, activeforeground=FG)
            mb.pack(side='left', padx=2)
            menu = tk.Menu(mb, tearoff=0); mb['menu'] = menu
            self._bmenus[key] = (mb, menu, ko, en)
        sc = tk.Frame(bar, bg=PANEL); sc.pack(side='right')
        for scope, ko, en in (('active', '진행 중만', 'Active only'), ('finished', '끝난 것만', 'Finished only'), ('all', '전체', 'All')):
            on = bf['scope'] == scope
            b = self._btn(sc, t(ko, en), lambda s=scope: self._bset('scope', s), ACCENT if on else FIELD)
            b.config(padx=8, pady=2); b.pack(side='right', padx=1)
        self._bres = tk.Frame(self.right, bg=PANEL); self._bres.pack(fill='both', expand=True)

    def _fill_bmenu(self, key, options):
        """options: [(값, 글)] — 고른 값을 단추에 적는다."""
        t, bf = self.t, self._bf
        mb, menu, ko, en = self._bmenus[key]
        menu.delete(0, 'end')
        names = dict(options)
        for val, text in options:
            menu.add_command(label=text, command=lambda v=val: self._bset(key, v))
        mb.config(text=f"{t(ko, en)}: {names.get(bf[key], t('모두', 'All'))} ▾")

    def _scroll_area(self, parent):
        canvas = tk.Canvas(parent, bg=PANEL, highlightthickness=0)
        sb = tk.Scrollbar(parent, orient='vertical', command=canvas.yview)
        inner = tk.Frame(canvas, bg=PANEL)
        inner.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
        wid = canvas.create_window((0, 0), window=inner, anchor='nw')
        canvas.bind('<Configure>', lambda e: canvas.itemconfigure(wid, width=e.width))
        canvas.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); canvas.pack(side='left', fill='both', expand=True)
        wheel = lambda e: canvas.yview_scroll(int(-e.delta / 120) or (-1 if e.delta > 0 else 1), 'units')
        canvas.bind('<Enter>', lambda e: canvas.bind_all('<MouseWheel>', wheel))
        canvas.bind('<Leave>', lambda e: canvas.unbind_all('<MouseWheel>'))
        return inner

    def _board_color(self, col):
        return {'ready': '#6A9EF2', 'running': GREEN, 'review': '#EE9E40', 'done': '#9A9EB2', 'blocked': '#E65A66'}[col]

    def _draw_board_results(self):
        t, bf = self.t, self._bf
        cards = self._cards
        people = []
        for c in cards:
            if c['assignee_id'] not in [p[0] for p in people]:
                people.append((c['assignee_id'], c['assignee']))
        if bf['assignee'] and bf['assignee'] not in [p[0] for p in people]:
            bf['assignee'] = ''
        self._fill_bmenu('status', [('', t('모두', 'All'))] + [(c, t(*buni_team.BOARD_COLUMN_NAMES[c])) for c in buni_team.BOARD_COLUMNS])
        self._fill_bmenu('assignee', [('', t('모두', 'All'))] + people)
        self._fill_bmenu('sort', [('recent', t('최근 변경순', 'Recently updated')), ('oldest', t('오래된 순', 'Oldest first')),
                                  ('state', t('상태순', 'By status')), ('assignee', t('담당자순', 'By assignee'))])
        shown = buni_team.board_filter(cards, bf['q'], bf['status'], bf['assignee'], bf['scope'], bf['sort'])
        for w in self._bres.winfo_children():
            w.destroy()
        s = buni_team.board_summary(cards)
        row = tk.Frame(self._bres, bg=PANEL); row.pack(fill='x', padx=16, pady=(4, 8))
        for key, col, ko, en, color in (('total', '', '전체', 'Total', FG), ('running', 'running', '진행 중', 'In progress', self._board_color('running')),
                                        ('done', 'done', '완료', 'Done', self._board_color('done')),
                                        ('blocked', 'blocked', '확인 필요', 'Needs attention', self._board_color('blocked'))):
            on = bf['status'] == col and col != ''
            tile = tk.Frame(row, bg='#34343F' if on else FIELD, cursor='hand2', padx=12, pady=6); tile.pack(side='left', padx=(0, 8))
            tk.Label(tile, text=str(s[key]), bg=tile['bg'], fg=color, font=(FONT, 15, 'bold')).pack(anchor='w')
            tk.Label(tile, text=t(ko, en), bg=tile['bg'], fg=DIM, font=(FONT, 8)).pack(anchor='w')
            for w in (tile,) + tuple(tile.winfo_children()):
                w.bind('<Button-1>', lambda e, c=col, o=on: self._bset('status', '' if o else c))
        ids = {c['id']: c for c in cards}
        body = tk.Frame(self._bres, bg=PANEL); body.pack(fill='both', expand=True)
        if self._bsel in ids:
            side = tk.Frame(body, bg=FIELD, width=290); side.pack(side='right', fill='y', padx=(0, 12), pady=(0, 12)); side.pack_propagate(False)
            self._draw_board_detail(side, ids[self._bsel])
        main = tk.Frame(body, bg=PANEL); main.pack(side='left', fill='both', expand=True, padx=(16, 8))
        if not cards:
            self._label(main, t('아직 보여 줄 작업이 없어요.\n왼쪽 ✎ 버튼으로 새 작업을 시작해 보세요.', 'Nothing to show yet.\nStart a job with the ✎ button.'), DIM, 10).pack(pady=40)
        elif bf['view'] == 'list':
            self._draw_board_list(main, shown)
        else:
            self._draw_board_columns(main, shown)

    def _click_card(self, widget, card_id):
        def go(e=None):
            self._bsel = card_id
            self._draw_board_results()
        for w in (widget,) + tuple(widget.winfo_children()):
            w.bind('<Button-1>', go)
            try:
                w.config(cursor='hand2')
            except tk.TclError:
                pass
            for sub in w.winfo_children():
                sub.bind('<Button-1>', go)

    def _auto_chip(self, parent, c, bg):
        if c.get('auto') not in buni_team.BOARD_AUTO_NAMES:
            return None
        color = {'started': GREEN, 'confirm': GOLD, 'limit': '#E65A66'}[c['auto']]
        return tk.Label(parent, text='⟳ ' + self.t(*buni_team.BOARD_AUTO_NAMES[c['auto']]), bg=bg, fg=color, font=(FONT, 8, 'bold'))

    @staticmethod
    def _bar(c):
        d, n = c['progress']
        return f"{'▰' * d}{'▱' * (n - d)} {d}/{n}" if n else ''

    def _draw_board_columns(self, parent, shown):
        t = self.t
        inner = self._scroll_area(parent)
        now = time.time(); en = t('', 'x') == 'x'
        for i, col in enumerate(buni_team.BOARD_COLUMNS):
            inner.columnconfigure(i, weight=1, uniform='bcol')
            box = tk.Frame(inner, bg=RAIL, padx=6, pady=6); box.grid(row=0, column=i, sticky='nsew', padx=3)
            items = [c for c in shown if c['column'] == col]
            head = tk.Frame(box, bg=RAIL); head.pack(fill='x', pady=(0, 6))
            tk.Label(head, text='●', bg=RAIL, fg=self._board_color(col), font=(FONT, 8)).pack(side='left')
            tk.Label(head, text=' ' + t(*buni_team.BOARD_COLUMN_NAMES[col]), bg=RAIL, fg='#D8D8E2', font=(FONT, 9, 'bold')).pack(side='left')
            tk.Label(head, text=str(len(items)), bg=RAIL, fg=DIM, font=(FONT, 8, 'bold')).pack(side='left', padx=4)
            for c in items:
                bg = '#3A3A48' if c['id'] == self._bsel else FIELD
                card = tk.Frame(box, bg=bg, padx=8, pady=6, highlightthickness=1, highlightbackground=LINE); card.pack(fill='x', pady=3)
                tk.Label(card, text=c['job_title'], bg=bg, fg=FG, font=(FONT, 9, 'bold'), wraplength=140, justify='left', anchor='w').pack(fill='x')
                who = tk.Frame(card, bg=bg); who.pack(fill='x', pady=(3, 0))
                tk.Label(who, text=f"{c['icon']} {c['assignee']}", bg=bg, fg='#C4C4CE', font=(FONT, 8), anchor='w').pack(side='left')
                tk.Label(who, text='● ' + t(*c['state']), bg=bg, fg=self._board_color(c['column']), font=(FONT, 8, 'bold')).pack(side='right')
                chip = self._auto_chip(card, c, bg)
                if chip:
                    chip.pack(anchor='w', pady=(2, 0))
                if c['recent']:
                    tk.Label(card, text=_short_text(c['recent'], 70), bg=bg, fg=DIM, font=(FONT, 8), wraplength=140, justify='left', anchor='w').pack(fill='x', pady=(3, 0))
                foot = tk.Frame(card, bg=bg); foot.pack(fill='x', pady=(4, 0))
                tk.Label(foot, text=self._bar(c), bg=bg, fg=self._board_color(c['column']), font=(FONT, 8)).pack(side='left')
                tk.Label(foot, text='⏱ ' + buni_team.board_elapsed(c['since'], now, en), bg=bg, fg=DIM, font=(FONT, 8)).pack(side='right')
                self._click_card(card, c['id'])
            if not items:
                tk.Label(box, text=t('비어 있어요', 'Empty'), bg=RAIL, fg='#5A5A68', font=(FONT, 8)).pack(pady=14)

    def _draw_board_list(self, parent, shown):
        t = self.t
        inner = self._scroll_area(parent)
        now = time.time(); en = t('', 'x') == 'x'
        widths = (12, 26, 16, 14, 30, 9)
        head = tk.Frame(inner, bg=PANEL); head.pack(fill='x', pady=(0, 4))
        for (ko, e), w in zip((('상태', 'Status'), ('프로젝트', 'Project'), ('담당자', 'Assignee'), ('진행률', 'Progress'),
                               ('최근 활동', 'Recent'), ('경과', 'Elapsed')), widths):
            tk.Label(head, text=t(ko, e).upper(), bg=PANEL, fg='#6A6A78', font=(FONT, 8, 'bold'), width=w, anchor='w').pack(side='left')
        for c in shown:
            bg = '#3A3A48' if c['id'] == self._bsel else PANEL
            row = tk.Frame(inner, bg=bg, pady=4); row.pack(fill='x')
            tk.Label(row, text='● ' + t(*c['state']), bg=bg, fg=self._board_color(c['column']), font=(FONT, 8, 'bold'), width=widths[0], anchor='w').pack(side='left')
            tk.Label(row, text=_short_text(c['job_title'], 30), bg=bg, fg=FG, font=(FONT, 9, 'bold'), width=widths[1], anchor='w').pack(side='left')
            tk.Label(row, text=f"{c['icon']} {c['assignee']}", bg=bg, fg='#C4C4CE', font=(FONT, 8), width=widths[2], anchor='w').pack(side='left')
            tk.Label(row, text=self._bar(c) or '—', bg=bg, fg=self._board_color(c['column']), font=(FONT, 8), width=widths[3], anchor='w').pack(side='left')
            tk.Label(row, text=_short_text(c['recent'], 40) or '—', bg=bg, fg=DIM, font=(FONT, 8), width=widths[4], anchor='w').pack(side='left')
            tk.Label(row, text=buni_team.board_elapsed(c['since'], now, en), bg=bg, fg=DIM, font=(FONT, 8), width=widths[5], anchor='w').pack(side='left')
            chip = self._auto_chip(row, c, bg)
            if chip:
                chip.pack(side='left', padx=4)
            self._click_card(row, c['id'])
        if not shown:
            self._label(inner, t('조건에 맞는 항목이 없어요.', 'No items match.'), DIM, 9).pack(pady=24)

    def _draw_board_detail(self, side, c):
        """카드 상세 — 담당자 · 진행률 · 최근 활동 · 결과 · 관련 채팅 · 이동 버튼 (같은 프로젝트의 화면으로)."""
        t = self.t
        d = buni_team.board_detail(c)
        job = buni_team.load_job(c['job_id']) or {'id': c['job_id']}
        room = self._has_room(job) if job.get('status') else False
        head = tk.Frame(side, bg=FIELD); head.pack(fill='x', padx=10, pady=(10, 4))
        close = tk.Label(head, text='✕', bg=FIELD, fg=DIM, cursor='hand2'); close.pack(side='right')
        close.bind('<Button-1>', lambda e: (setattr(self, '_bsel', None), self._draw_board_results()))
        tk.Label(head, text=c['job_title'], bg=FIELD, fg=FG, font=(FONT, 10, 'bold'), wraplength=220, justify='left', anchor='w').pack(side='left', fill='x')
        info = tk.Frame(side, bg=FIELD); info.pack(fill='x', padx=10)
        self._label(info, f"{c['icon']} {c['assignee']}  ·  ● {t(*c['state'])}", '#C4C4CE', 9).pack(anchor='w')
        chip = self._auto_chip(info, c, FIELD)
        if chip:
            chip.pack(anchor='w')
        if c['progress'][1]:
            self._label(info, t('진행률 ', 'Progress ') + self._bar(c), self._board_color(c['column']), 9).pack(anchor='w')
        self._label(info, '⏱ ' + buni_team.board_elapsed(c['since'], time.time(), t('', 'x') == 'x'), DIM, 8).pack(anchor='w')
        def block(title, lines):
            if not lines:
                return
            self._label(info, title, '#6A6A78', 8, True).pack(anchor='w', pady=(8, 1))
            for ln in lines:
                tk.Label(info, text=ln, bg=FIELD, fg='#C4C4CE', font=(FONT, 8), wraplength=250, justify='left', anchor='w').pack(anchor='w')
        block(t('최근 활동', 'Recent activity'), [_short_text(x, 90) for x in d['activity'][-4:]] or ([_short_text(c['recent'], 90)] if c['recent'] else []))
        block(t('결과', 'Result'), [_short_text(d['summary'], 260)] if d['summary'] else [])
        block(t('관련 채팅', 'Related chat'), [f"{self._chat_name(job, m.get('from'))}: {_short_text(m.get('text', ''), 70)}" for m in d['chat'][-4:]])
        acts = tk.Frame(side, bg=FIELD); acts.pack(fill='x', padx=10, pady=10, side='bottom')
        def act(text, cmd):
            self._btn(acts, text, cmd, '#34343F').pack(fill='x', pady=2)
        if c['role_id'] and room:
            act('💬 ' + t(f"{c['assignee']} 대화 열기", f"Open {c['assignee']}'s chat"), lambda: self._board_goto(c['job_id'], 'dm:' + c['role_id']))
        elif room:
            act('🐰 ' + t('팀장 대화 열기', "Open lead's chat"), lambda: self._board_goto(c['job_id'], 'lead'))
        act('📄 ' + t('결과·진행 보기', 'Open result / progress'), lambda: self._board_goto(c['job_id'], 'overview'))
        if room:
            act('# ' + t('스쿼드 채팅 보기', 'Open squad chat'), lambda: self._board_goto(c['job_id'], 'channel'))
        if d['sessions']:
            sid = d['sessions'][-1].get('id')
            act('💻 ' + t('Claude에서 열기', 'Open in Claude'), lambda: self._open_session(job, sid))

    def _send_note(self, job, key, var):
        text = var.get().strip()
        if not text:
            return

        def run():
            try:
                buni_team.send_role_note(job['id'], key, text)
            except ValueError as e:
                self._note_error = str(e)                 # 화면 갱신(_tick)에서 보여 준다 — Tk 는 다른 스레드에서 만지지 않는다
        threading.Thread(target=run, daemon=True).start()

    def _events(self, pad, job, n):
        t = self.t
        ev = job.get('events', [])[-n:]
        if not ev:
            return
        self._label(pad, t('진행 기록', 'Log'), DIM, 8, True).pack(anchor='w', pady=(10, 2))
        for e in ev:
            self._label(pad, time.strftime('%H:%M', time.localtime(e['ts'])) + '  ' + e['msg'], DIM, 8, wraplength=580).pack(anchor='w')

    def _run_now(self, job):
        self.manager.team_sched.run_now(job['id'])
        self.manager.team_sched.tick()
        self.refresh(force=True)

    def _cancel(self, job):
        if messagebox.askyesno(self.t('부니 스쿼드', 'Buni Squad'), self.t('이 프로젝트를 취소할까요? 지금까지 만든 결과와 git 브랜치는 그대로 남아요.', 'Cancel this project? What has been made and the git branch stay.'), parent=self.win):
            self.manager.team_sched.cancel(job['id'])
            self.refresh(force=True)

    def _delete(self, job):
        if messagebox.askyesno(self.t('부니 스쿼드', 'Buni Squad'), self.t('이 작업 기록을 지울까요? (git 브랜치와 결과 파일은 남아요)', 'Delete this job record? (the git branch and result files remain)'), parent=self.win):
            buni_team.delete_job(job['id'])
            self.sel = None
            self.refresh(force=True)

    def _draw_result(self, pad, job):
        t = self.t
        done = job['status'] == 'done'
        # 끝난 작업을 열자마자 보고서에서 바로 누를 항목이 보이게 — 없으면 만들고, 팀장 정리는 뒤에서 한 번 돌린다
        if job['id'] not in self._wrapup_checked and not job.get('busy'):
            self._wrapup_checked.add(job['id'])
            threading.Thread(target=buni_team.ensure_wrapup, args=(job['id'],), daemon=True).start()
        # 내용이 길어지므로 스크롤되는 영역 안에 그린다
        canvas = tk.Canvas(pad, bg=PANEL, highlightthickness=0)
        sb = tk.Scrollbar(pad, orient='vertical', command=canvas.yview)
        inner = tk.Frame(canvas, bg=PANEL)
        inner.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
        wid = canvas.create_window((0, 0), window=inner, anchor='nw')
        canvas.bind('<Configure>', lambda e: canvas.itemconfigure(wid, width=e.width))
        canvas.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y'); canvas.pack(side='left', fill='both', expand=True)
        wheel = lambda e: canvas.yview_scroll(int(-e.delta / 120) or (-1 if e.delta > 0 else 1), 'units')
        canvas.bind('<Enter>', lambda e: canvas.bind_all('<MouseWheel>', wheel))
        canvas.bind('<Leave>', lambda e: canvas.unbind_all('<MouseWheel>'))

        self._label(inner, t('✅ 끝났어요' if not done else '검토를 마친 작업이에요', '✅ Finished' if not done else 'Reviewed'),
                    GREEN, 10, True).pack(anchor='w', pady=(0, 6))
        if job.get('busy'):
            self._label(inner, '⏳ ' + (job.get('busy_msg') or t('정리하는 중…', 'Working…')) + t('  — 다음 작업 제안이 곧 아래 보고서에 추가돼요', '  — next-step suggestions will appear below'),
                        GOLD, 9).pack(anchor='w', pady=(0, 6))

        # 보고서 한 장 — 안에 '지금 확인할 것' 버튼(열기·문제 없어요·피드백)과 '다음에 할 일' 버튼이 들어 있다
        rep = os.path.join(buni_team.jobs_dir(), job['id'], 'REPORT.md')
        md = None
        for name in ('report_view.md', 'REPORT.md'):
            try:
                with open(os.path.join(buni_team.jobs_dir(), job['id'], name), encoding='utf-8') as fh:
                    md = fh.read()
                break
            except OSError:
                continue
        if md is None:
            md = job.get('summary', '')

        def act(host, target):
            if host in ('open', 'run'):
                self._open_item(job, {'id': target})
            elif host == 'followup':
                self._start_followup(job, {'id': target})
            elif host == 'view':
                self._goto_job(target)
            elif host == 'apply':
                self._apply_result(job)
            elif host == 'diff':
                self._run_bg(lambda: self._open_diff_result(job))
            elif host == 'ok':
                threading.Thread(target=buni_team.review_feedback, args=(job['id'], target, 'ok'), daemon=True).start()
        txt = tk.Text(inner, bg=FIELD, fg=FG, relief='flat', font=(FONT, 9), wrap='word', padx=12, pady=8, cursor='arrow')
        txt.pack(fill='x')
        def feedback(item_id, text):
            def run():
                try:
                    buni_team.review_feedback(job['id'], item_id, 'fix', text)
                except ValueError as e:
                    self._note_error = str(e)
            threading.Thread(target=run, daemon=True).start()
        render_markdown(txt, md, {'fg': FG, 'dim': DIM, 'accent': '#6AA9FF', 'code_bg': PANEL, 'font': FONT},
                        on_action=act, on_feedback=feedback)
        txt.update_idletasks()
        try:
            # 버튼·입력창이 들어 있는 줄은 글줄보다 높아서 그만큼 여유를 둔다
            win_lines = {int(str(txt.index(w)).split('.')[0]) for w in txt.window_names()}
            txt.config(height=max(3, int(txt.count('1.0', 'end', 'displaylines')[0]) + 1 + len(win_lines)))
        except Exception:
            txt.config(height=20)
        txt.config(state='disabled')

        if job.get('plan'):
            self._draw_board(inner, job)
        self._label(inner, t(f"브랜치: {job.get('branch')}  ·  원래 브랜치: {job.get('base_ref')}  ·  비용 약 ${job.get('cost_usd', 0):.2f}",
                             f"Branch: {job.get('branch')}  ·  base: {job.get('base_ref')}  ·  cost ≈ ${job.get('cost_usd', 0):.2f}"),
                    DIM, 8, wraplength=560).pack(anchor='w', pady=(8, 4))
        row = tk.Frame(inner, bg=PANEL); row.pack(fill='x', pady=(0, 12))
        wd = buni_team.result_dir(job) or job['project_dir']
        self._btn(row, t('📄 보고서 파일 열기', '📄 Open report file'), lambda: open_path(rep), FIELD).pack(side='left')
        self._btn(row, t('📂 결과 폴더', '📂 Results folder'), lambda: open_path(os.path.join(wd, '.buni-team', job['slug'])), FIELD).pack(side='left', padx=6)
        if not done:
            self._btn(row, t('✅ 검토 완료', '✅ Mark reviewed'), lambda: (buni_team.mark_done(job['id']), self.refresh(force=True)), ACCENT).pack(side='left')
        self._btn(row, t('🔄 다시 정리', '🔄 Redo list'), lambda: self._wrap_up(job), FIELD).pack(side='left', padx=6)
        self._btn(row, t('🗑 삭제', '🗑 Delete'), lambda: self._delete(job), FIELD).pack(side='right')

    def _goto_job(self, job_id):
        self._select(job_id)

    def _open_item(self, job, item):
        def run():
            r = buni_team.open_review_item(job['id'], item['id'])
            if not r.get('ok'):
                self._note_error = r.get('error') or self.t('열지 못했어요', "Couldn't open it")
        threading.Thread(target=run, daemon=True).start()

    def _open_diff_result(self, job):
        r = buni_team.open_changes_diff(job['id'])
        if not r.get('ok'):
            self._note_error = r.get('error') or self.t('열지 못했어요', "Couldn't open it")

    def _apply_result(self, job):
        def run():
            try:
                r = buni_team.apply_result(job['id'])
            except Exception as e:
                r = {'ok': False, 'error': str(e)}
            if not r.get('ok'):
                self._note_error = r.get('error') or self.t('반영하지 못했어요', "Couldn't apply it")
        threading.Thread(target=run, daemon=True).start()

    def _start_followup(self, job, step):
        def run():
            try:
                buni_team.start_followup(job['id'], step['id'])      # 같은 프로젝트 안에서 이어서 진행 — 다른 프로젝트로 옮기지 않는다
            except ValueError as e:
                self._note_error = str(e)
                return
            try:
                self.manager.team_sched.tick()
            except Exception:
                pass
        threading.Thread(target=run, daemon=True).start()

    def _wrap_up(self, job):
        threading.Thread(target=buni_team.wrap_up_job, args=(job['id'],), daemon=True).start()
        time.sleep(0.2)
        self.refresh(force=True)

    def _draw_failed(self, pad, job):
        t = self.t
        self._label(pad, job.get('error') or t('취소된 작업이에요.', 'This job was cancelled.'), RED if job['status'] == 'failed' else DIM, 9, wraplength=580).pack(anchor='w', pady=8)
        self._events(pad, job, 6)
        row = tk.Frame(pad, bg=PANEL); row.pack(side='bottom', fill='x', pady=(10, 0))
        if job.get('requirements'):
            self._btn(row, t('🔁 다시 시도', '🔁 Retry'), lambda: (buni_team.retry_job(job['id']), self.refresh(force=True)), ACCENT).pack(side='left')
        else:
            self._btn(row, t('↩ 질문부터 다시', '↩ Start over'), lambda: self._restart(job), ACCENT).pack(side='left')
        self._btn(row, t('🗑 삭제', '🗑 Delete'), lambda: self._delete(job), FIELD).pack(side='left', padx=8)

    # ── 예약 설정 ────────────────────────────────────────────
    def _open_settings(self):
        """스쿼드 설정 — 왼쪽: 예약·진행·모델·자동 이어가기 / 오른쪽: 반영 방식과 '중요한 변경' 기준."""
        t = self.t
        s = buni_team.load_settings()
        d = tk.Toplevel(self.win)
        d.title(t('스쿼드 설정', 'Squad settings')); d.configure(bg=BG); d.resizable(False, False); d.transient(self.win)
        v_en = tk.BooleanVar(value=s['enabled']); v_s = tk.StringVar(value=s['window_start']); v_e = tk.StringVar(value=s['window_end'])
        v_c = tk.IntVar(value=s['concurrency'])
        outer = tk.Frame(d, bg=BG, padx=20, pady=16); outer.pack()
        left = tk.Frame(outer, bg=BG); left.grid(row=0, column=0, sticky='nw', padx=(0, 24))
        right = tk.Frame(outer, bg=BG); right.grid(row=0, column=1, sticky='nw')

        def head(parent, text, first=False):
            self._label(parent, text, FG, 9, True).pack(anchor='w', pady=(0 if first else 12, 3))

        def radio(parent, var, val, text):
            tk.Radiobutton(parent, text=text, variable=var, value=val, bg=BG, fg=FG, selectcolor=FIELD, activebackground=BG,
                           activeforeground=FG, font=(FONT, 9), anchor='w', justify='left').pack(anchor='w')

        def check(parent, var, text, bold=False):
            tk.Checkbutton(parent, text=text, variable=var, bg=BG, fg=FG, selectcolor=FIELD, activebackground=BG, activeforeground=FG,
                           font=(FONT, 9, 'bold' if bold else 'normal'), anchor='w').pack(anchor='w')

        # ── 왼쪽
        head(left, t('자동 진행 시간', 'When auto-run works'), True)
        v_sched = tk.StringVar(value=s.get('schedule_mode', 'window'))
        radio(left, v_sched, 'window', t('정해 둔 시간대 안에서만 (아래 시각)', 'Only inside the hours below'))
        radio(left, v_sched, 'anytime', t('언제든 바로 진행', 'Any time, right away'))
        radio(left, v_sched, 'off', t('내가 시작할 때만', 'Only when I start it'))
        row = tk.Frame(left, bg=BG); row.pack(anchor='w', pady=4)
        for lab, var in ((t('시작', 'Start'), v_s), (t('끝', 'End'), v_e)):
            self._label(row, lab).pack(side='left')
            tk.Entry(row, textvariable=var, width=6, bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 10)).pack(side='left', padx=(4, 12), ipady=2)
        row = tk.Frame(left, bg=BG); row.pack(anchor='w')
        self._label(row, t('동시에 일하는 팀원 수', 'Teammates at once')).pack(side='left')
        tk.Spinbox(row, from_=1, to=4, textvariable=v_c, width=3, bg=FIELD, fg=FG, relief='flat', font=(FONT, 10)).pack(side='left', padx=8)
        self._label(left, t('플랜 사용량을 아끼려면 2명을 권해요.', 'Two is recommended to save plan usage.'), DIM, 8).pack(anchor='w')
        head(left, t('Claude 사용량 한도(일일 제한)에 닿으면', 'When the Claude usage limit is reached'))
        v_limit = tk.StringVar(value=s.get('limit_action', 'stop'))
        radio(left, v_limit, 'stop', t('멈추고, 내가 ▶ 이어서 를 누를 때까지 쉬기 (기본)', 'Stop until I press Resume (default)'))
        radio(left, v_limit, 'wait', t('풀릴 때까지 기다렸다가 알아서 이어서', 'Wait for the reset and continue by itself'))

        head(left, t('업무 진행 방식', 'How tasks run'))
        v_run = tk.StringVar(value=s.get('run_mode', 'auto'))
        radio(left, v_run, 'auto', t('자동 — 팀이 알아서 순서대로 (기본)', 'Auto — the team runs tasks in order (default)'))
        radio(left, v_run, 'manual', t('수동 — 업무마다 내가 ▶ 시작을 눌러야', 'Manual — I press ▶ Start on each task'))

        head(left, t('모델', 'Models'))
        v_model = {'model': s.get('model', ''), 'lead_model': s.get('lead_model', '')}
        row = tk.Frame(left, bg=BG); row.pack(anchor='w')
        self._label(row, t('팀원 기본', 'Teammates')).pack(side='left')
        self._model_menu(row, v_model['model'], t('기본 모델', 'Default'), lambda m: v_model.__setitem__('model', m)).pack(side='left', padx=6)
        row = tk.Frame(left, bg=BG); row.pack(anchor='w')
        self._label(row, t('팀장', 'Lead')).pack(side='left')
        self._model_menu(row, v_model['lead_model'], t('팀원 기본과 같게', 'Same as teammates'), lambda m: v_model.__setitem__('lead_model', m)).pack(side='left', padx=6)
        self._label(left, t('팀원마다 다르게 하려면 그 팀원의 대화(DM) 위쪽에서 고르세요.', 'Per teammate: use the model menu at the top of their DM.'), DIM, 8, wraplength=300).pack(anchor='w')

        head(left, t('다음에 할 일 자동 진행', 'Auto-continue next steps'))
        v_auto = tk.IntVar(value=1 if s.get('auto_followup', True) else 0)
        check(left, v_auto, t('방향이 안 바뀌는 후속 작업은 이어서 시작', 'Continue follow-ups that keep the direction'))
        self._label(left, t('연속 3단계까지. 가격·정책 변경, 게시·발송, push·릴리스는 내가 누를 때까지 기다려요.',
                            'Up to 3 in a row. Pricing/policy, posting, push and release wait for you.'), DIM, 8, wraplength=300).pack(anchor='w')

        # ── 오른쪽
        head(right, t('결과를 내 폴더에 반영하는 방식', 'How results reach your folder'), True)
        v_mode = tk.StringVar(value=s.get('apply_mode', 'smart'))
        radio(right, v_mode, 'smart', t('스마트 — 중요하지 않으면 바로, 중요하면 확인 (기본)', 'Smart — auto unless important (default)'))
        radio(right, v_mode, 'auto', t('자동 — 무엇이든 끝나면 바로 반영', 'Auto — always apply when done'))
        radio(right, v_mode, 'confirm', t('확인 후 — 전부 보고 승인하면 반영', 'Confirm — review everything first'))
        radio(right, v_mode, 'manual', t('수동 — 반영하지 않고 브랜치로만', 'Manual — keep on a branch only'))
        head(right, t('스마트: 이런 변경이면 확인을 받아요', 'Smart: ask me first when a change involves'))
        v_rules = {k: tk.IntVar(value=1 if s.get(k, True) else 0) for k in ('smart_payments', 'smart_secrets', 'smart_build', 'smart_deletes', 'smart_big')}
        check(right, v_rules['smart_payments'], t('결제·가격·라이선스 파일', 'Payments, pricing, licensing'))
        check(right, v_rules['smart_secrets'], t('비밀값·키·인증·설정 파일', 'Secrets, keys, auth, config'))
        check(right, v_rules['smart_build'], t('빌드·설치·릴리스·훅·버전 파일', 'Build, install, release, hooks, version'))
        check(right, v_rules['smart_deletes'], t('파일 삭제', 'Deleting files'))
        check(right, v_rules['smart_big'], t('큰 변경', 'Large changes'))
        v_bf = tk.IntVar(value=int(s.get('smart_big_files', 30))); v_bl = tk.IntVar(value=int(s.get('smart_big_lines', 1500)))
        row = tk.Frame(right, bg=BG); row.pack(anchor='w', padx=(22, 0))
        tk.Spinbox(row, from_=5, to=300, increment=5, textvariable=v_bf, width=4, bg=FIELD, fg=FG, relief='flat', font=(FONT, 9)).pack(side='left')
        self._label(row, t(' 파일 이상 또는 ', ' files or ')).pack(side='left')
        tk.Spinbox(row, from_=100, to=50000, increment=250, textvariable=v_bl, width=6, bg=FIELD, fg=FG, relief='flat', font=(FONT, 9)).pack(side='left')
        self._label(row, t(' 줄 이상', ' lines')).pack(side='left')
        row = tk.Frame(right, bg=BG); row.pack(anchor='w', pady=(6, 0))
        self._label(row, t('그 밖에 확인받을 경로', 'Other paths')).pack(side='left')
        v_custom = tk.StringVar(value=s.get('smart_custom', ''))
        tk.Entry(row, textvariable=v_custom, width=22, bg=FIELD, fg=FG, insertbackground=FG, relief='flat', font=(FONT, 9)).pack(side='left', padx=6, ipady=2)
        self._label(right, t('쉼표로 구분, * 사용 가능 (예: docs/*, *.plist). 위에 해당하지 않으면 끝나는 대로 바로 반영해요.\n어느 방식이든 커밋은 하지 않고, 내 폴더의 커밋 안 한 변경과 겹치면 아무것도 바꾸지 않아요.',
                             'Comma-separated, * allowed. Anything else is applied right away.\nNo mode commits; nothing changes if it overlaps your uncommitted edits.'),
                    DIM, 8, wraplength=300).pack(anchor='w', pady=(4, 0))

        def save():
            try:
                buni_team._hm(v_s.get()); buni_team._hm(v_e.get())
            except ValueError as e:
                messagebox.showerror(t('예약 설정', 'Schedule'), str(e), parent=d)
                return
            patch = {'schedule_mode': v_sched.get(), 'limit_action': v_limit.get(), 'window_start': v_s.get().strip(), 'window_end': v_e.get().strip(),
                     'concurrency': int(v_c.get()), 'apply_mode': v_mode.get(), 'run_mode': v_run.get(), 'auto_followup': bool(v_auto.get()),
                     'model': v_model['model'], 'lead_model': v_model['lead_model'],
                     'smart_big_files': int(v_bf.get()), 'smart_big_lines': int(v_bl.get()), 'smart_custom': v_custom.get().strip()}
            patch.update({k: bool(v.get()) for k, v in v_rules.items()})
            buni_team.save_settings(patch)
            d.destroy()
            self.refresh(force=True)
        self._btn(outer, t('저장', 'Save'), save, ACCENT).grid(row=1, column=0, columnspan=2, sticky='e', pady=(12, 0))
        d.update_idletasks()
        d.geometry(f'+{self.win.winfo_x() + 80}+{self.win.winfo_y() + 60}')

