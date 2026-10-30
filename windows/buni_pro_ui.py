"""
부니 Pro 화면 (Tk) — 업그레이드 창, 첫 실행 안내, 설정의 Pro 구역.
상태·잠금 규칙은 buni_pro.py, 여기는 그리기만 한다. 문구는 t(한국어, English) 로 받아 언어 전환을 따른다.
앱에는 분석·원격 수집이 없다 — 링크는 눌렀을 때 기본 브라우저로만 연다.
"""
import tkinter as tk
import webbrowser

import buni_pro

BG, PANEL, DIM, ACCENT = '#1E1E24', '#2A2A34', '#8A8A98', '#3377E0'
GOLD = '#FAB84D'
FONT = 'Malgun Gothic'


def _btn(parent, text, command, color=ACCENT, state='normal'):
    return tk.Button(parent, text=text, bg=color, fg='white', relief='flat', bd=0,
                     font=(FONT, 9), padx=12, pady=4, cursor='hand2' if state == 'normal' else 'arrow',
                     activebackground='#2255BB', activeforeground='white',
                     disabledforeground='#BBBBBB', state=state, command=command)


def _center(win):
    win.update_idletasks()
    sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
    w, h = win.winfo_reqwidth(), win.winfo_reqheight()
    win.geometry(f'+{(sw - w) // 2}+{(sh - h) // 2}')


# ═══════════════════════ 업그레이드 창 ═══════════════════════

class ProUpgradeWindow:
    """플랜·결제 링크 버튼·라이선스 키 입력·꾸미기 팩. 링크가 없으면 버튼은 비활성 '준비 중'."""

    def __init__(self, parent, t, store=None, reason=None, on_change=None):
        self._parent, self._t = parent, t
        self._store = store or buni_pro.shared()
        self._on_change = on_change
        self._win = None
        self.show(reason)

    def is_open(self):
        return bool(self._win and self._win.winfo_exists())

    def show(self, reason=None):
        if self.is_open():
            self._win.destroy()
        self._build(reason)

    def close(self):
        if self.is_open():
            self._win.destroy()

    def _build(self, reason):
        t, store = self._t, self._store
        win = tk.Toplevel(self._parent)
        self._win = win
        win.title(t('부니 Pro', 'Buni Pro'))
        win.configure(bg=BG)
        win.resizable(False, False)
        win.attributes('-topmost', True)

        body = tk.Frame(win, bg=BG)
        body.pack(padx=20, pady=16, anchor='w')

        tk.Label(body, text='⭐ ' + t('부니 Pro', 'Buni Pro'), bg=BG, fg='white',
                 font=(FONT, 14, 'bold')).pack(anchor='w')
        tk.Label(body, text=t(*buni_pro.status_text(store.status())), bg=BG, fg=DIM,
                 font=(FONT, 9)).pack(anchor='w', pady=(2, 8))

        if reason:
            tk.Label(body, text='🔒 ' + reason, bg='#3A3220', fg=GOLD, font=(FONT, 9),
                     justify='left', anchor='w', wraplength=360, padx=10, pady=8).pack(fill='x', pady=(0, 8))

        for fid, (ko, en) in buni_pro.FEATURES.items():
            tk.Label(body, text=('✅ ' if store.can(fid) else '🔒 ') + t(ko, en), bg=BG, fg='#DDDDDD',
                     font=(FONT, 9)).pack(anchor='w')

        self._sep(body)
        tk.Label(body, text=t('플랜', 'Plans'), bg=BG, fg='white', font=(FONT, 10, 'bold')).pack(anchor='w')
        for plan, ko, en, note_ko, note_en in (
                ('monthly',  '월간', 'Monthly',  '매달', 'per month'),
                ('yearly',   '연간', 'Yearly',   '1년 · 약 33% 저렴', 'per year · ~33% less'),
                ('lifetime', '평생', 'Lifetime', '한 번 결제', 'one-time')):
            self._plan_row(body, plan, t(ko, en), t(note_ko, note_en))

        self._sep(body)
        tk.Label(body, text=t('라이선스 키', 'License key'), bg=BG, fg='white',
                 font=(FONT, 10, 'bold')).pack(anchor='w')
        row = tk.Frame(body, bg=BG)
        row.pack(anchor='w', pady=(4, 0))
        self._key = tk.StringVar()
        entry = tk.Entry(row, textvariable=self._key, width=34, bg=PANEL, fg='white', relief='flat',
                         insertbackground='white', font=('Consolas', 9))
        entry.pack(side='left', ipady=3)
        _btn(row, t('등록', 'Activate'), self._activate).pack(side='left', padx=(6, 0))
        self._msg = tk.Label(body, text='', bg=BG, fg=DIM, font=(FONT, 8), justify='left',
                             wraplength=360, anchor='w')
        self._msg.pack(anchor='w', pady=(4, 0))

        self._sep(body)
        tk.Label(body, text=t('꾸미기 팩', 'Cosmetic packs'), bg=BG, fg='white',
                 font=(FONT, 10, 'bold')).pack(anchor='w')
        for p in buni_pro.PACKS:
            self._pack_row(body, p)

        tk.Label(body, text=t('무료 기능(세션 패널·상태 표시·채팅·기본 캐릭터)은 Pro가 없어도 그대로 쓸 수 있어요.\n'
                              '앱은 사용 정보를 수집하지 않아요.',
                              'Free features (session panels, status, chat, base characters) keep working without Pro.\n'
                              'The app collects no usage data.'),
                 bg=BG, fg='#555566', font=(FONT, 8), justify='left').pack(anchor='w', pady=(12, 0))
        _btn(body, t('닫기', 'Close'), self.close, color='#444455').pack(anchor='e', pady=(8, 0))

        win.bind('<Escape>', lambda _: self.close())
        _center(win)

    @staticmethod
    def _sep(parent):
        tk.Frame(parent, bg='#3A3A44', height=1).pack(fill='x', pady=10)

    def _open_link(self, link):
        try:
            webbrowser.open(link)
        except Exception:
            pass

    def _plan_row(self, parent, plan, name, note):
        enabled, link, label = buni_pro.checkout_button(plan)
        price = buni_pro.format_usd(buni_pro.PLAN_PRICE_CENTS[plan])
        row = tk.Frame(parent, bg=BG)
        row.pack(fill='x', pady=3)
        col = tk.Frame(row, bg=BG)
        col.pack(side='left')
        tk.Label(col, text=f'{name}  {price}', bg=BG, fg='white', font=(FONT, 9, 'bold')).pack(anchor='w')
        tk.Label(col, text=note, bg=BG, fg=DIM, font=(FONT, 8)).pack(anchor='w')
        _btn(row, self._t(*label), (lambda l=link: self._open_link(l)) if enabled else (lambda: None),
             color=ACCENT if enabled else '#555566',
             state='normal' if enabled else 'disabled').pack(side='right')

    def _pack_row(self, parent, p):
        t, store = self._t, self._store
        row = tk.Frame(parent, bg=BG)
        row.pack(fill='x', pady=3)
        col = tk.Frame(row, bg=BG)
        col.pack(side='left')
        tk.Label(col, text=t(p.name_ko, p.name_en), bg=BG, fg='white', font=(FONT, 9)).pack(anchor='w')
        if p.pro_only:
            note = t('Pro 전용 · 구독하면 포함', 'Pro only · included with Pro')
        else:
            cents = store.pack_price_cents(p.id)
            pct = buni_pro.PRO_PACK_DISCOUNT_PERCENT
            note = buni_pro.format_usd(cents)
            if store.status().kind == buni_pro.SUBSCRIBED:
                note += t(f' (Pro 할인 {pct}%)', f' (Pro {pct}% off)')
            else:
                note += t(f' · Pro 회원은 {pct}% 할인', f' · {pct}% off for Pro')
            if p.id in store.owned_packs():
                note += t(' · 보유 중', ' · owned')
        tk.Label(col, text=note, bg=BG, fg=DIM, font=(FONT, 8)).pack(anchor='w')
        if not p.pro_only:
            enabled, link, label = buni_pro.checkout_button('pack:' + p.id)
            _btn(row, t('구매', 'Buy') if enabled else t(*label),
                 (lambda l=link: self._open_link(l)) if enabled else (lambda: None),
                 color=ACCENT if enabled else '#555566',
                 state='normal' if enabled else 'disabled').pack(side='right')

    def _activate(self):
        t = self._t
        ok, reason = self._store.activate(self._key.get())
        if ok:
            if self._on_change:
                try: self._on_change()
                except Exception: pass
            self.show()
            self._msg.config(text=t('등록됐어요! 고마워요 🐰', 'Activated! Thank you 🐰'), fg='#4DC780')
        else:
            self._msg.config(text=t(*buni_pro.activation_message(reason)), fg='#E6665A')


# ═══════════════════════ 첫 실행 안내 ═══════════════════════

class OnboardingWindow:
    """처음 켰을 때 세 장짜리 안내. 끝내거나 건너뛰면 다시 뜨지 않는다 (설정에서 다시 볼 수 있다)."""

    def __init__(self, parent, t, store=None, on_upgrade=None):
        self._parent, self._t = parent, t
        self._store = store or buni_pro.shared()
        self._on_upgrade = on_upgrade
        self._page = 0
        self._win = None
        self._build()

    def _pages(self):
        t = self._t
        return [
            ('🐰', t('안녕, 나는 부니야!', "Hi, I'm Buni!"),
             t('Claude Code 세션마다 화면 한쪽에 나타나서 지금 뭘 하는지 알려줄게요.\n생각 중, 도구 사용, 완료까지 한눈에 볼 수 있어요.',
               "I show up beside each Claude Code session and tell you what it's doing\n— thinking, using tools, or done.")),
            ('🎛', t('트레이에서 다 할 수 있어요', 'Everything lives in the tray'),
             t('작업 표시줄 트레이의 토끼 아이콘에서 상점, 채팅, 설정을 열 수 있어요.\n부니를 오른쪽 클릭하면 캐릭터도 바꿀 수 있어요.',
               'Open the shop, chat and settings from the rabbit icon in the tray.\nRight-click Buni to change characters.')),
            ('⭐', t('Pro 체험 중이에요', "You're on a Pro trial"),
             t(f'지금은 모든 Pro 기능을 써볼 수 있어요 ({self._t(*buni_pro.status_text(self._store.status()))}).\n체험이 끝나도 기존 기능은 계속 무료예요.',
               f'Every Pro feature is open for now ({self._t(*buni_pro.status_text(self._store.status()))}).\nExisting features stay free after the trial.')),
        ]

    def is_open(self):
        return bool(self._win and self._win.winfo_exists())

    def _build(self):
        t = self._t
        win = tk.Toplevel(self._parent)
        self._win = win
        win.title(t('부니에 오신 걸 환영해요', 'Welcome to Buni'))
        win.configure(bg=BG)
        win.resizable(False, False)
        win.attributes('-topmost', True)
        win.protocol('WM_DELETE_WINDOW', self._finish)
        self._body = tk.Frame(win, bg=BG, width=420, height=260)
        self._body.pack(padx=24, pady=(20, 6))
        self._body.pack_propagate(False)
        self._bar = tk.Frame(win, bg=BG)
        self._bar.pack(fill='x', padx=24, pady=(0, 16))
        self._render()
        _center(win)

    def _render(self):
        t = self._t
        for w in self._body.winfo_children() + self._bar.winfo_children():
            w.destroy()
        icon, title, text = self._pages()[self._page]
        tk.Label(self._body, text=icon, bg=BG, font=(FONT, 36)).pack(anchor='w')
        tk.Label(self._body, text=title, bg=BG, fg='white', font=(FONT, 14, 'bold')).pack(anchor='w', pady=(8, 6))
        tk.Label(self._body, text=text, bg=BG, fg='#CCCCCC', font=(FONT, 10), justify='left').pack(anchor='w')

        dots = ''.join('●' if i == self._page else '○' for i in range(3))
        tk.Label(self._bar, text=dots, bg=BG, fg=DIM, font=(FONT, 9)).pack(side='left')
        last = self._page == 2
        if last:
            _btn(self._bar, t('시작하기', 'Get started'), self._finish).pack(side='right')
            _btn(self._bar, t('Pro 알아보기', 'See Pro'), self._see_pro, color='#444455').pack(side='right', padx=(0, 6))
        else:
            _btn(self._bar, t('다음', 'Next'), self._next).pack(side='right')
            _btn(self._bar, t('건너뛰기', 'Skip'), self._finish, color='#444455').pack(side='right', padx=(0, 6))

    def _next(self):
        self._page += 1
        self._render()

    def _see_pro(self):
        self._finish()
        if self._on_upgrade:
            self._on_upgrade()

    def _finish(self):
        self._store.mark_onboarded()
        if self.is_open():
            self._win.destroy()


# ═══════════════════════ 설정 창의 Pro 구역 ═══════════════════════

def fill_settings_section(f, t, store, open_upgrade, open_onboarding):
    """설정 창의 Pro 구역을 (다시) 채운다 — 상태가 바뀌면 같은 Frame 에 다시 불러도 된다."""
    for w in f.winfo_children():
        w.destroy()
    tk.Label(f, text=t('부니 Pro', 'Buni Pro'), bg=BG, fg='white', font=(FONT, 10, 'bold')).pack(anchor='w')
    tk.Label(f, text=t(*buni_pro.status_text(store.status())), bg=BG, fg=DIM, font=(FONT, 9)).pack(anchor='w', pady=(2, 4))
    row = tk.Frame(f, bg=BG)
    row.pack(anchor='w')
    _btn(row, t('플랜 보기 · 키 등록', 'Plans & license key'), lambda: open_upgrade()).pack(side='left')
    _btn(row, t('처음 안내 다시 보기', 'Replay intro'), lambda: open_onboarding(), color=PANEL).pack(side='left', padx=(6, 0))
    return f
