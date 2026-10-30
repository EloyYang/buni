"""
부니 Pro — 플랜·체험·라이선스 상태, 잠금 게이트, 결제 링크, 코스메틱 팩 (macOS ProManager.swift 와 같은 규칙).

화면(Tk)과 무관한 순수 로직이라 단독으로 시험할 수 있다.
저장 위치: %APPDATA%/Buni/pro.json (state.json·shop.json 과 분리)
설정 파일:  %APPDATA%/Buni/pro-config.json  — {"stripe_links": {"monthly": "https://…", …}}

기존 무료 기능(세션 패널·상태 표시·채팅·기본 캐릭터/테마)은 여기서 절대 잠그지 않는다.
잠그는 것은 FEATURES 에 적힌 것뿐이다.
"""
import json
import os
import threading
import time
from pathlib import Path

import buni_license

# ───────────────────────── 가정 값 — 바꾸려면 여기 숫자만 고친다 ─────────────────────────
TRIAL_DAYS_EXISTING = 30      # [가정-A] 기존 사용자 Pro 체험 일수
TRIAL_DAYS_NEW = 14           # [가정-B] 신규 사용자 Pro 체험 일수
PRO_PACK_DISCOUNT_PERCENT = 30  # [가정-F] Pro 회원의 개별 팩 할인율

# Pro 로 잠그는 기능 (id → (한국어, English))
FEATURES = {
    'squad_schedule':     ('스쿼드 업무 예약',   'Squad scheduled tasks'),
    'squad_parallel':     ('스쿼드 병렬 실행',   'Squad parallel runs'),
    'premium_characters': ('프리미엄 캐릭터',    'Premium characters'),
    'premium_themes':     ('프리미엄 테마',      'Premium themes'),
    'cloud_sync':         ('클라우드 동기화',    'Cloud sync'),
}

# 사용자가 체험 기간을 본 적 있는 파일 — 하나라도 있으면 "기존 사용자"로 본다
_EXISTING_USER_FILES = ('state.json', 'shop.json')

# 상태 종류
SUBSCRIBED = 'subscribed'   # 유효한 Pro 키 보유
TRIAL = 'trial'             # 무료 체험 중 (Pro 기능 사용 가능)
EXPIRED = 'expired'         # 체험 끝 — 무료 기능만

STRIPE_PLANS = ('monthly', 'yearly', 'lifetime')
STRIPE_ENV = {
    'monthly':  'BUNI_STRIPE_LINK_MONTHLY',
    'yearly':   'BUNI_STRIPE_LINK_YEARLY',
    'lifetime': 'BUNI_STRIPE_LINK_LIFETIME',
}
# 개별 팩 링크는 BUNI_STRIPE_LINK_PACK_<ID 대문자> 또는 설정 파일 "pack:<id>"

# 가격(센트) — 표시용 기본값. 실제 청구액은 Stripe 상품 설정이 정한다.
PLAN_PRICE_CENTS = {'monthly': 300, 'yearly': 2400, 'lifetime': 4900}


def data_dir() -> Path:
    base = os.environ.get('APPDATA') or str(Path.home() / 'AppData' / 'Roaming')
    return Path(base) / 'Buni'


# ───────────────────────── 코스메틱 팩 ─────────────────────────

class CosmeticPack:
    __slots__ = ('id', 'name_ko', 'name_en', 'kind', 'items', 'price_cents', 'pro_only')

    def __init__(self, id, name_ko, name_en, kind, items, price_cents, pro_only):
        self.id = id
        self.name_ko = name_ko
        self.name_en = name_en
        self.kind = kind              # 'character' | 'theme'
        self.items = items            # 이 팩이 여는 캐릭터/테마 id
        self.price_cents = price_cents  # 개별 판매가(센트). Pro 전용 팩은 0
        self.pro_only = pro_only      # True 면 Pro 회원에게만 열리고 따로 팔지 않는다


# (id, 한국어, English, 종류, 아이템 id들, 개별 가격(센트), Pro 전용)
# 아이템 id 는 새로 추가하는 캐릭터·테마의 이름표다 — 기존 캐릭터·테마는 무료로 남는다 [가정-E].
_PACKS = [
    ('pro_colors',   '프로 컬러 캐릭터',  'Pro color characters', 'character', ('rabbit_mint', 'rabbit_lavender', 'rabbit_midnight'), 0, True),
    ('pro_themes',   '프로 테마',          'Pro themes',           'theme',     ('theme_midnight', 'theme_sunset'),                     0, True),
    ('sakura',       '벚꽃 팩',            'Sakura pack',          'theme',     ('theme_sakura', 'rabbit_sakura'),                      299, False),
    ('space',        '우주 팩',            'Space pack',           'theme',     ('theme_space', 'rabbit_astronaut'),                    349, False),
    ('cafe',         '카페 팩',            'Cafe pack',            'theme',     ('theme_cafe', 'rabbit_barista'),                       399, False),
]
PACKS = [CosmeticPack(*row) for row in _PACKS]
_PACK_BY_ID = {p.id: p for p in PACKS}
_PACK_OF_ITEM = {i: p for p in PACKS for i in p.items}


def pack(pack_id):
    return _PACK_BY_ID.get(pack_id)


def pack_price_cents(pack_id, is_pro: bool):
    """개별 판매 팩의 가격(센트). Pro 회원은 PRO_PACK_DISCOUNT_PERCENT 할인(센트 반올림). 판매 안 하는 팩은 None."""
    p = _PACK_BY_ID.get(pack_id)
    if p is None or p.pro_only:
        return None
    if not is_pro:
        return p.price_cents
    return (p.price_cents * (100 - PRO_PACK_DISCOUNT_PERCENT) + 50) // 100


def format_usd(cents: int) -> str:
    return f'${cents // 100}.{cents % 100:02d}'


# ───────────────────────── 결제 링크 ─────────────────────────

def _config() -> dict:
    try:
        with open(data_dir() / 'pro-config.json', encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _clean_link(value):
    """https 링크만 인정한다. 비었거나 이상하면 None → 버튼은 '준비 중'."""
    if isinstance(value, str):
        value = value.strip()
        if value.startswith('https://') and ' ' not in value and len(value) > len('https://x'):
            return value
    return None


def checkout_link(plan, config=None):
    """plan: monthly · yearly · lifetime · 'pack:<id>'. 환경변수 → 설정 파일 순서. 없으면 None."""
    if plan.startswith('pack:'):
        env_name = 'BUNI_STRIPE_LINK_PACK_' + plan[5:].upper()
    else:
        env_name = STRIPE_ENV.get(plan)
        if env_name is None:
            return None
    link = _clean_link(os.environ.get(env_name))
    if link:
        return link
    links = (config if config is not None else _config()).get('stripe_links')
    return _clean_link(links.get(plan)) if isinstance(links, dict) else None


def checkout_button(plan, config=None):
    """업그레이드 버튼 표시용 (눌러도 되는지, 링크, 라벨). 링크가 없으면 비활성 + '준비 중'."""
    link = checkout_link(plan, config)
    if link:
        return True, link, ('구독하기', 'Subscribe')
    return False, None, ('준비 중', 'Coming soon')


# ───────────────────────── 상태 ─────────────────────────

class ProStatus:
    """kind: subscribed · trial · expired. is_pro 는 Pro 기능을 쓸 수 있는지(구독 또는 체험 중)."""
    __slots__ = ('kind', 'days_left', 'plan', 'expires')

    def __init__(self, kind, days_left=0, plan='', expires=None):
        self.kind = kind
        self.days_left = days_left    # 체험 중일 때 남은 일수(올림, 오늘 포함)
        self.plan = plan              # 구독 중일 때 플랜
        self.expires = expires        # 구독 만료일 'YYYYMMDD' 또는 None(평생)

    @property
    def is_pro(self):
        return self.kind in (SUBSCRIBED, TRIAL)

    def __repr__(self):
        return f'ProStatus({self.kind}, days_left={self.days_left}, plan={self.plan})'


class ProStore:
    """체험 시작 시각·라이선스 키를 파일에 두고 상태를 판정한다. 스레드 안전."""

    def __init__(self, base_dir=None, pubkey=None, clock=None):
        self._dir = Path(base_dir) if base_dir else data_dir()
        self._file = self._dir / 'pro.json'
        self._pubkey = pubkey            # None 이면 buni_license 의 내장/환경변수 공개키
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self._data = self._load()
        self._ensure_trial_started()

    # ── 저장 ──
    def _load(self) -> dict:
        try:
            with open(self._file, encoding='utf-8') as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self):
        try:
            self._dir.mkdir(parents=True, exist_ok=True)
            tmp = self._file.with_suffix('.tmp')
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(self._data, f, ensure_ascii=False)
            os.replace(tmp, self._file)
        except OSError:
            pass  # 저장 실패해도 앱은 계속 — 다음 실행에 체험 시작이 다시 기록된다

    def _ensure_trial_started(self):
        """첫 실행이면 체험을 시작한다. state.json/shop.json 이 이미 있으면 기존 사용자(30일), 아니면 신규(14일)."""
        if isinstance(self._data.get('trial_start'), (int, float)):
            return
        existing = any((self._dir / n).exists() for n in _EXISTING_USER_FILES)
        self._data['trial_start'] = self._clock()
        self._data['trial_days'] = TRIAL_DAYS_EXISTING if existing else TRIAL_DAYS_NEW
        self._data['was_existing_user'] = existing
        self._save()

    @property
    def was_existing_user(self) -> bool:
        return bool(self._data.get('was_existing_user'))

    # ── 라이선스 ──
    def _valid_licenses(self, now=None):
        out = []
        for key in self._data.get('licenses', []):
            r = buni_license.verify_key(key, pubkey=self._pubkey, now=now if now is not None else self._clock())
            if r.valid:
                out.append(r)
        return out

    def activate(self, key):
        """키를 등록한다. (성공 여부, 이유) — 이유는 buni_license 의 reason 코드."""
        r = buni_license.verify_key(key, pubkey=self._pubkey, now=self._clock())
        if not r.valid:
            return False, r.reason
        key = key.strip()
        with self._lock:
            keys = self._data.setdefault('licenses', [])
            if key not in keys:
                keys.append(key)
                self._save()
        return True, ''

    def remove_licenses(self):
        with self._lock:
            self._data['licenses'] = []
            self._save()

    # ── 상태 ──
    def status(self, now=None) -> ProStatus:
        now = now if now is not None else self._clock()
        pros = [r for r in self._valid_licenses(now) if r.is_pro]
        if pros:
            # 평생(만료 없음)이 있으면 그것을, 아니면 가장 늦게 끝나는 키를 보여준다
            best = next((r for r in pros if r.expires is None), None) or max(pros, key=lambda r: r.expires)
            return ProStatus(SUBSCRIBED, plan=best.plan, expires=best.expires)
        total = float(self._data.get('trial_days', TRIAL_DAYS_NEW)) * 86400
        left = self._data['trial_start'] + total - now
        if left > 0:
            return ProStatus(TRIAL, days_left=int(-(-left // 86400)))
        return ProStatus(EXPIRED)

    def is_pro(self, now=None) -> bool:
        return self.status(now).is_pro

    def owned_packs(self, now=None):
        return {r.pack_id for r in self._valid_licenses(now) if r.pack_id}

    # ── 잠금 게이트 ──
    def can(self, feature, now=None) -> bool:
        if feature not in FEATURES:
            return True        # 잠금 목록에 없는 기능은 항상 무료
        return self.is_pro(now)

    def item_unlocked(self, item_id, now=None) -> bool:
        """캐릭터·테마 id 가 쓸 수 있는 상태인가. 팩에 속하지 않은 기존 것은 항상 무료."""
        p = _PACK_OF_ITEM.get(item_id)
        if p is None:
            return True
        if self.is_pro(now):
            return True        # Pro(체험 포함)는 모든 팩을 쓴다
        return (not p.pro_only) and p.id in self.owned_packs(now)

    def pack_price_cents(self, pack_id, now=None):
        return pack_price_cents(pack_id, self.status(now).kind == SUBSCRIBED)

    def cloud_sync_policy(self, already_syncing: bool, now=None) -> str:
        """[가정-G] 'allow' · 'pause_keep_data'(기존 사용자: 동기화만 멈추고 데이터는 그대로) · 'blocked'(새로 켜기 불가)."""
        if self.can('cloud_sync', now):
            return 'allow'
        return 'pause_keep_data' if already_syncing else 'blocked'

    # ── 클라우드 동기화 기록 · 첫 실행 안내 · 컬러 변형 선택 ──
    @property
    def cloud_was_syncing(self) -> bool:
        """동기화를 한 번이라도 한 사용자인가 — 체험이 끝나도 데이터는 지우지 않고 멈추기만 한다."""
        return bool(self._data.get('cloud_synced'))

    def mark_cloud_synced(self):
        with self._lock:
            if not self._data.get('cloud_synced'):
                self._data['cloud_synced'] = True
                self._save()

    def cloud_policy(self, now=None) -> str:
        return self.cloud_sync_policy(self.cloud_was_syncing, now)

    @property
    def onboarding_done(self) -> bool:
        return bool(self._data.get('onboarded'))

    def mark_onboarded(self):
        with self._lock:
            self._data['onboarded'] = True
            self._save()

    @property
    def tint(self):
        return self._data.get('tint')

    def set_tint(self, tint_id):
        """고른 변형을 기록한다 (잠겨 있어도 값은 둔다 — 다시 Pro 가 되면 그대로 돌아온다). None 이면 원래 색."""
        with self._lock:
            if tint_id is None:
                self._data.pop('tint', None)
            else:
                self._data['tint'] = tint_id
            self._save()

    def active_tint(self, now=None):
        """지금 실제로 입힐 변형 id (잠긴 것은 None)."""
        tid = self.tint
        return tid if tid in _TINT_BY_ID and self.item_unlocked(tid, now) else None


def lock_message(feature):
    """잠긴 기능을 눌렀을 때 보여줄 안내 (한국어, English)."""
    ko, en = FEATURES.get(feature, (feature, feature))
    return (f'{ko}은(는) Pro 기능이에요. 업그레이드하면 바로 쓸 수 있어요.',
            f'{en} is a Pro feature. Upgrade to unlock it.')


def status_text(status: ProStatus):
    """상태 한 줄 요약 (한국어, English)."""
    if status.kind == SUBSCRIBED:
        if status.expires:
            e = status.expires
            return (f'Pro 구독 중 · {e[:4]}-{e[4:6]}-{e[6:]}까지', f'Pro active · until {e[:4]}-{e[4:6]}-{e[6:]}')
        return ('Pro 평생 이용권', 'Pro lifetime')
    if status.kind == TRIAL:
        return (f'Pro 체험 중 · {status.days_left}일 남았어요', f'Pro trial · {status.days_left} day(s) left')
    return ('무료 버전 · Pro 체험이 끝났어요', 'Free · Pro trial ended')


# ───────────────────────── 프리미엄 컬러 변형 ─────────────────────────
# 기존 캐릭터 그림에 색조만 입힌다 (새 그림 없이). macOS CharacterTint 와 같은 값.
# (id, 한국어, English, 색조 도, 채도 배율, 밝기 가감)
TINTS = [
    ('rabbit_mint',      '민트',     'Mint',      150, 1.0,  0.02),
    ('rabbit_lavender',  '라벤더',   'Lavender',  250, 0.9,  0.05),
    ('rabbit_midnight',  '미드나잇', 'Midnight',  220, 0.8, -0.18),
    ('rabbit_sakura',    '벚꽃',     'Sakura',    330, 1.0,  0.06),
    ('rabbit_astronaut', '우주',     'Astronaut', 190, 0.6,  0.0),
    ('rabbit_barista',   '카페',     'Barista',   25,  0.8, -0.08),
]
_TINT_BY_ID = {row[0]: row for row in TINTS}


def tint_hex(color, tint_id):
    """'#RRGGBB' 에 컬러 변형을 입힌 색. 모르는 id 면 그대로."""
    row = _TINT_BY_ID.get(tint_id)
    if row is None or not (isinstance(color, str) and len(color) == 7 and color[0] == '#'):
        return color
    import colorsys
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    h = (h + row[3] / 360.0) % 1.0
    s = min(1.0, s * row[4])
    v = min(1.0, max(0.0, v + row[5]))
    return '#%02X%02X%02X' % tuple(round(c * 255) for c in colorsys.hsv_to_rgb(h, s, v))


def item_lock_message(item_id):
    """잠긴 캐릭터·테마를 눌렀을 때 보여줄 안내 (한국어, English)."""
    p = _PACK_OF_ITEM.get(item_id)
    if p is not None and not p.pro_only:
        return (f'{p.name_ko}은(는) Pro이거나 개별 구매하면 쓸 수 있어요.',
                f'{p.name_en} unlocks with Pro or as a one-time purchase.')
    return ('이 꾸미기는 Pro 전용이에요. 업그레이드하면 바로 쓸 수 있어요.',
            'This cosmetic is Pro-only. Upgrade to unlock it.')


_ACTIVATION_MESSAGES = {
    'format':    ('키 형식이 올바르지 않아요. BUNI-로 시작하는 키를 통째로 붙여 넣어 주세요.',
                  "That doesn't look like a Buni key. Paste the whole key starting with BUNI-."),
    'signature': ('키를 확인하지 못했어요. 바뀌었거나 다른 키일 수 있어요.',
                  "Couldn't verify this key. It may be altered or not a Buni key."),
    'expired':   ('이미 만료된 키예요.', 'This key has expired.'),
    'no_pubkey': ('아직 라이선스 확인 준비가 안 된 빌드예요.',
                  "This build isn't set up to verify license keys yet."),
}


def activation_message(reason):
    """키 등록 실패 코드를 사람이 읽을 문장으로 (한국어, English)."""
    return _ACTIVATION_MESSAGES.get(reason, ('키를 등록하지 못했어요.', "Couldn't activate the key."))


# ───────────────────────── 앱 공용 인스턴스 ─────────────────────────
_shared = None
_shared_lock = threading.Lock()


def shared() -> 'ProStore':
    """앱 전체가 같이 쓰는 ProStore (처음 부를 때 만든다)."""
    global _shared
    with _shared_lock:
        if _shared is None:
            _shared = ProStore()
        return _shared
