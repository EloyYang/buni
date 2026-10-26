"""
부니 상점 — 코인·레벨·구매·캐릭터별 착용 상태 (macOS ShopStore.swift 포팅).

화면(Tk)과 무관한 순수 로직이라 단독으로 시험할 수 있다.
저장 위치: %APPDATA%/Buni/shop.json (state.json과 분리 — 동기화 스레드가 따로 쓴다)
"""
import json
import os
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

# 아이템이 붙는 자리 — 자리마다 하나씩만 착용할 수 있다
SLOTS = ('head', 'face', 'outfit', 'back', 'weapon', 'tool')

SLOT_TITLES = {
    'head':   ('머리', 'Head'),
    'face':   ('얼굴', 'Face'),
    'outfit': ('옷',   'Outfit'),
    'back':   ('등',   'Back'),
    'weapon': ('무기', 'Weapon'),
    'tool':   ('작업', 'Work'),
}

# 작업 하나를 끝낼 때마다 주는 코인
COINS_PER_COMPLETION = 5

# 자리마다 "아무것도 안 골랐을 때 쓰는 기본 아이템" — 무료이고 항상 보유 상태다.
DEFAULT_ITEM = {'tool': 'laptop', 'weapon': 'carrot'}

TOKENS_PER_LEVEL = 500_000


class ShopItem:
    __slots__ = ('id', 'name_ko', 'name_en', 'slot', 'level', 'price')

    def __init__(self, id, name_ko, name_en, slot, level, price):
        self.id = id
        self.name_ko = name_ko
        self.name_en = name_en
        self.slot = slot
        self.level = level
        self.price = price

    def __repr__(self):
        return f'ShopItem({self.id})'


# (id, 한국어, English, 자리, 필요 레벨, 가격)
_CATALOG = [
    # ── 머리
    ('straw_hat',   '밀짚모자',    'Straw hat',    'head', 1, 40),
    ('wizard_hat',  '마법사 모자', 'Wizard hat',   'head', 3, 120),
    ('crown',       '황금 왕관',   'Golden crown', 'head', 6, 300),
    ('halo',        '천사링',      'Angel halo',   'head', 4, 200),
    ('devil_horns', '악마 뿔',     'Devil horns',  'head', 4, 200),
    ('fire_helmet', '소방 헬멧',   'Fire helmet',  'head', 3, 130),
    ('police_cap',  '경찰 모자',   'Police cap',   'head', 3, 130),
    # ── 얼굴
    ('glasses', '동그란 안경', 'Round glasses', 'face', 1, 50),
    ('shades',  '선글라스',    'Sunglasses',    'face', 4, 150),
    # ── 옷
    ('stripe_tee',     '줄무늬 티셔츠', 'Striped tee',      'outfit', 1, 70),
    ('hoodie',         '후드티',        'Hoodie',           'outfit', 2, 110),
    ('tuxedo',         '턱시도',        'Tuxedo',           'outfit', 3, 160),
    ('armor',          '기사 갑옷',     'Knight armor',     'outfit', 5, 260),
    ('robe',           '마법사 로브',   'Wizard robe',      'outfit', 7, 380),
    ('school_uniform', '학교 교복',     'School uniform',   'outfit', 2, 120),
    ('business_suit',  '사업가 정장',   'Business suit',    'outfit', 3, 170),
    ('firefighter',    '소방관 방화복', 'Firefighter gear', 'outfit', 4, 220),
    ('police',         '경찰 제복',     'Police uniform',   'outfit', 4, 220),
    ('angel_gown',     '천사 가운',     'Angel gown',       'outfit', 6, 320),
    ('devil_suit',     '악마 정장',     'Devil suit',       'outfit', 6, 320),
    # ── 등
    ('cape',        '빨간 망토', 'Red cape',    'back', 2, 90),
    ('wings',       '천사 날개', 'Angel wings', 'back', 8, 500),
    ('devil_wings', '악마 날개', 'Devil wings', 'back', 8, 500),
    # ── 무기 (작업 중에만 손에 든다)
    ('carrot',      '당근 (기본)', 'Carrot (default)',  'weapon', 1, 0),
    ('wood_sword',  '나무 검',     'Wooden sword',      'weapon', 1, 60),
    ('steel_sword', '강철 검',     'Steel sword',       'weapon', 4, 180),
    ('staff',       '마법 지팡이', 'Magic staff',       'weapon', 6, 280),
    ('flame_sword', '불꽃 대검',   'Flame greatsword',  'weapon', 10, 700),
    ('baton',       '경찰봉',      'Police baton',      'weapon', 2, 100),
    ('fire_axe',    '소방 도끼',   'Fire axe',          'weapon', 5, 240),
    ('trident',     '삼지창',      'Trident',           'weapon', 7, 360),
    # ── 작업 도구 (작업 중에 노트북 대신)
    ('laptop',       '노트북 (기본)',  'Laptop (default)', 'tool', 1, 0),
    ('book_writing', '책 쓰기 (깃펜)', 'Writing a book',   'tool', 2, 100),
    ('knitting',     '뜨개질',         'Knitting',         'tool', 2, 100),
    ('gamepad',      '휴대용 게임기',  'Handheld game',    'tool', 3, 150),
]

CATALOG = [ShopItem(*row) for row in _CATALOG]
_BY_ID = {it.id: it for it in CATALOG}


def item(item_id):
    return _BY_ID.get(item_id)


def items_in(slot):
    return [it for it in CATALOG if it.slot == slot]


def month_key(ts=None) -> str:
    d = datetime.fromtimestamp(ts if ts is not None else time.time())
    return f'{d.year:04d}-{d.month:02d}'


def _shop_file() -> Path:
    base = os.environ.get('APPDATA') or str(Path.home() / 'AppData' / 'Roaming')
    return Path(base) / 'Buni' / 'shop.json'


class ShopStore:
    """코인·구매·착용·레벨. 구매는 공용이고 착용은 캐릭터마다 따로다."""

    def __init__(self, path: Path | None = None):
        self._path = path or _shop_file()
        self._lock = threading.RLock()
        self._listeners = []

        self.coins = 0
        self.owned: set = set()
        # 캐릭터 id → (자리 → 아이템 id)
        self.equipped: dict = {}
        # 이 기기에서 착용을 마지막으로 바꾼 시각(epoch 초) — 동기화 때 "나중에 바꾼 쪽이 이긴다"
        self.equipped_changed_at = 0.0
        self.device_id = ''
        self.baselines: dict = {}      # uid → 지난 동기화 때 서버와 맞춘 코인

        # 이 기기에서 센 이번 달 토큰 / 다른 PC까지 합친 값(로그인 동기화한 경우만)
        self.local_tokens = 0
        self.cloud_token_total = None
        self.level = 1

        self._load()
        if not self.device_id:
            self.device_id = str(uuid.uuid4())
            self._save()
        self._recompute_level()

    # ── 저장 / 알림 ─────────────────────────────────────────

    def _load(self):
        try:
            if self._path.exists():
                d = json.loads(self._path.read_text(encoding='utf-8'))
                self.coins = int(d.get('coins', 0))
                self.owned = set(d.get('owned', []))
                eq = d.get('equipped', {})
                self.equipped = {c: dict(s) for c, s in eq.items() if isinstance(s, dict)}
                self.equipped_changed_at = float(d.get('equippedChangedAt', 0.0))
                self.device_id = d.get('deviceId', '')
                self.baselines = {k: int(v) for k, v in d.get('baselines', {}).items()}
        except Exception:
            pass

    def _save(self):
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            data = {
                'coins': self.coins,
                'owned': sorted(self.owned),
                'equipped': self.equipped,
                'equippedChangedAt': self.equipped_changed_at,
                'deviceId': self.device_id,
                'baselines': self.baselines,
            }
            tmp = self._path.with_suffix('.tmp')
            tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
            os.replace(tmp, self._path)
        except Exception:
            pass

    def add_listener(self, cb):
        """상태가 바뀔 때마다 cb()를 부른다 (어느 스레드에서든 불릴 수 있다)."""
        self._listeners.append(cb)

    def _changed(self, persist=True):
        if persist:
            self._save()
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass

    # ── 레벨 ────────────────────────────────────────────────

    @property
    def effective_tokens(self) -> int:
        return max(self.local_tokens, self.cloud_token_total or 0)

    def _recompute_level(self):
        new_level = self.effective_tokens // TOKENS_PER_LEVEL + 1
        if new_level != self.level:
            self.level = new_level
            return True
        return False

    def update_level(self, tokens: int):
        """이 PC에서 집계한 이번 달 토큰 수로 레벨을 갱신한다."""
        with self._lock:
            self.local_tokens = tokens
            changed = self._recompute_level()
        if changed:
            self._changed(persist=False)

    # ── 코인 ────────────────────────────────────────────────

    def reward_completion(self):
        with self._lock:
            self.coins += COINS_PER_COMPLETION
        self._changed()

    # ── 구매 / 착용 ─────────────────────────────────────────

    @staticmethod
    def is_default(it: ShopItem) -> bool:
        return DEFAULT_ITEM.get(it.slot) == it.id

    def is_owned(self, it: ShopItem) -> bool:
        return it.price == 0 or it.id in self.owned

    def is_unlocked(self, it: ShopItem) -> bool:
        return self.level >= it.level

    def can_buy(self, it: ShopItem) -> bool:
        return (not self.is_owned(it)) and self.is_unlocked(it) and self.coins >= it.price

    def is_equipped(self, it: ShopItem, character: str) -> bool:
        cur = self.equipped.get(character, {}).get(it.slot)
        # 아무것도 안 골랐으면 그 자리의 기본 아이템(노트북·당근)을 쓰는 중이다
        if cur is None and it.slot in DEFAULT_ITEM:
            return it.id == DEFAULT_ITEM[it.slot]
        return cur == it.id

    def buy(self, it: ShopItem, equip_for: str) -> bool:
        """구매는 공용 — 한 번 사면 어느 캐릭터든 입힐 수 있다. 사면 바로 입혀준다."""
        with self._lock:
            if not self.can_buy(it):
                return False
            self.coins -= it.price
            self.owned.add(it.id)
            self.equipped.setdefault(equip_for, {})[it.slot] = it.id
            self.equipped_changed_at = time.time()
        self._changed()
        return True

    def toggle_equip(self, it: ShopItem, character: str):
        with self._lock:
            if not self.is_owned(it):
                return
            slots = self.equipped.setdefault(character, {})
            if self.is_default(it):          # 기본 아이템을 고르면 = 선택을 푸는 것
                slots.pop(it.slot, None)
            elif slots.get(it.slot) == it.id:
                slots.pop(it.slot, None)
            else:
                slots[it.slot] = it.id
            self.equipped_changed_at = time.time()
        self._changed()

    def equipped_id(self, slot: str, character: str):
        return self.equipped.get(character, {}).get(slot)

    def resolved(self, slot: str, character: str, try_on=None):
        """지금 이 자리에 보여줄 아이템 id — 입어보기 중이면 그것, 아니면 실제 착용 상태."""
        if try_on is not None:
            return try_on.get(slot)
        return self.equipped_id(slot, character)

    def has_custom_weapon(self, character: str, try_on=None) -> bool:
        """기본 당근이 아닌 무기를 들고 있는지."""
        wid = self.resolved('weapon', character, try_on)
        return wid is not None and wid != 'carrot'

    # ── 클라우드 동기화 연결 ────────────────────────────────

    def sync_state(self) -> dict:
        with self._lock:
            return {
                'coins': self.coins,
                'owned': set(self.owned),
                'equipped': {c: dict(s) for c, s in self.equipped.items()},
                'equipped_changed_at': self.equipped_changed_at,
                'device_id': self.device_id,
                'month': month_key(),
                'month_tokens': self.local_tokens,
            }

    def baseline_coins(self, uid: str):
        return self.baselines.get(uid)

    def forget_cloud_baseline(self, uid: str):
        with self._lock:
            self.baselines.pop(uid, None)
            self.cloud_token_total = None
            self._recompute_level()
        self._changed()

    def apply_cloud(self, doc: dict, tokens_this_month: int, uid: str):
        """합친 결과를 이 기기에 반영한다."""
        with self._lock:
            self.coins = doc['coins']
            self.owned = set(doc['owned'])
            self.equipped = {c: dict(s) for c, s in doc['equipped'].items()
                             if c and isinstance(s, dict)}
            if doc['equipped_updated_at'] > self.equipped_changed_at:
                self.equipped_changed_at = doc['equipped_updated_at']
            # 다음 동기화 때 "그 사이 이 기기에서 늘고 준 코인"만 서버에 더하기 위한 기준값
            self.baselines[uid] = doc['coins']
            self.cloud_token_total = tokens_this_month
            self._recompute_level()
        self._changed()
