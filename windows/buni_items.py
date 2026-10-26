"""
상점 아이템 그리기 — macOS EquipmentView.swift / WorkToolViews.swift 포팅.

캐릭터 그림과 같은 P(=6.5px) 단위계, 같은 중심 기준 오프셋을 쓴다.
Tk Canvas에는 회전·투명도가 없어서 블록은 필요할 때 다각형으로 그리고(회전),
반투명 색은 배경 위에 섞은 값으로 미리 계산해 쓴다.

기준 좌표(정면 포즈): 머리 y -2.1~0.5 · 귀 y -5.2~-1.8(x ±0.8~2.4) ·
눈 x ±1.4, y -0.9 · 몸통 y 0.25~2.75 · 오른팔 x 2.65, y 1.1
"""
import math

P = 6.5


def rgb(r, g, b):
    return '#%02X%02X%02X' % (round(r * 255), round(g * 255), round(b * 255))


def mix(a: str, b: str, t: float) -> str:
    """a 위에 b를 t(0~1)만큼 섞는다 — 반투명 색을 배경 위에서 미리 계산할 때."""
    ar, ag, ab = int(a[1:3], 16), int(a[3:5], 16), int(a[5:7], 16)
    br, bg, bb = int(b[1:3], 16), int(b[3:5], 16), int(b[5:7], 16)
    return '#%02X%02X%02X' % (round(ar + (br - ar) * t), round(ag + (bg - ag) * t), round(ab + (bb - ab) * t))


def osc(t: float, dur: float) -> float:
    """easeInOut 왕복(autoreverses) — 0↔1을 dur초에 한 번씩 오간다."""
    return 0.5 - 0.5 * math.cos(math.pi * t / dur)


class Painter:
    """픽셀 블록 하나(w·h는 P 단위, x·y는 중심에서의 오프셋)를 그린다.

    at()으로 좌표계를 옮기거나 돌리거나 좌우 반전할 수 있다 — SwiftUI의
    rotationEffect / scaleEffect / offset 순서와 같다(돌린 뒤 반전, 그다음 이동).
    """

    def __init__(self, cv, cx, cy, tag='char', dx=0.0, dy=0.0):
        self.cv = cv
        self.cx = cx + dx
        self.cy = cy + dy
        self.tag = tag
        self._stack = []          # (angle_deg, mirror, tx, ty)

    # ── 좌표계 ──────────────────────────────────────────────

    def at(self, x=0.0, y=0.0, angle=0.0, mirror=False):
        return _Frame(self, (angle, mirror, x, y))

    def _map(self, px, py):
        """지역 좌표(P 단위) → 캔버스 픽셀. 안쪽 좌표계부터 차례로 바깥으로 변환한다."""
        for angle, mirror, tx, ty in reversed(self._stack):
            if angle:
                a = math.radians(angle)
                ca, sa = math.cos(a), math.sin(a)
                px, py = px * ca - py * sa, px * sa + py * ca
            if mirror:
                px = -px
            px, py = px + tx, py + ty
        return self.cx + px * P, self.cy + py * P

    def _rotated(self):
        return any(a for a, _m, _x, _y in self._stack)

    # ── 그리기 ──────────────────────────────────────────────

    def blk(self, w, h, color, x=0.0, y=0.0):
        hw, hh = w / 2, h / 2
        if not self._rotated():
            x0, y0 = self._map(x - hw, y - hh)
            x1, y1 = self._map(x + hw, y + hh)
            self.cv.create_rectangle(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1),
                                     fill=color, outline='', tags=self.tag)
        else:
            pts = []
            for qx, qy in ((x - hw, y - hh), (x + hw, y - hh), (x + hw, y + hh), (x - hw, y + hh)):
                pts.extend(self._map(qx, qy))
            self.cv.create_polygon(pts, fill=color, outline='', tags=self.tag)

    def line(self, x0, y0, x1, y1, color, width):
        """두 점 사이의 선 (P 단위 좌표, width는 P 단위 굵기)."""
        ax, ay = self._map(x0, y0)
        bx, by = self._map(x1, y1)
        self.cv.create_line(ax, ay, bx, by, fill=color, width=max(1, round(width * P)),
                            capstyle='projecting', tags=self.tag)

    def frame_rect(self, w, h, thick, color, x=0.0, y=0.0):
        """속이 빈 사각 테두리 (안경테)."""
        self.blk(w, thick, color, x, y - h / 2 + thick / 2)
        self.blk(w, thick, color, x, y + h / 2 - thick / 2)
        self.blk(thick, h - 2 * thick, color, x - w / 2 + thick / 2, y)
        self.blk(thick, h - 2 * thick, color, x + w / 2 - thick / 2, y)


class _Frame:
    def __init__(self, painter, entry):
        self.p, self.entry = painter, entry

    def __enter__(self):
        self.p._stack.append(self.entry)
        return self.p

    def __exit__(self, *exc):
        self.p._stack.pop()


# ══════════════════════════════════════════════════════════════
# 뒤 레이어 (캐릭터 뒤 — 망토·날개)
# ══════════════════════════════════════════════════════════════

_WING_ROWS = [(2.0, 2.0, 1.3), (1.3, 2.0, 2.1), (0.6, 2.1, 2.7), (-0.1, 2.3, 2.9),
              (-0.8, 2.7, 2.7), (-1.5, 3.1, 2.1), (-2.2, 3.6, 1.3), (-2.9, 4.2, 0.7)]
_DEVIL_ROWS = [(1.9, 2.0, 0.9), (1.2, 2.0, 1.7), (0.5, 2.1, 2.5), (-0.2, 2.3, 2.9),
               (-0.9, 2.7, 2.7), (-1.6, 3.1, 2.1), (-2.3, 3.6, 1.3), (-3.0, 4.2, 0.6)]


def draw_back(p: Painter, item_id):
    if item_id == 'cape':
        red, dark = rgb(0.82, 0.16, 0.20), rgb(0.58, 0.09, 0.14)
        p.blk(5.9, 3.0, red, 0, 1.9)
        p.blk(6.5, 0.6, red, 0, 3.4)                 # 아래로 퍼지는 밑단
        p.blk(4.4, 2.2, dark, 0, 2.3)                # 안쪽 그늘
        p.blk(1.0, 0.5, rgb(0.95, 0.78, 0.20), 0, 0.25)   # 목 장식
    elif item_id == 'wings':
        # 어깨 높이에서 몸 뒤에 붙어 시작해 바깥·위로 솟아오르는 깃털 계단
        white, tint, edge = rgb(0.99, 0.99, 1.00), rgb(0.90, 0.94, 1.00), rgb(0.74, 0.82, 0.96)
        for sgn in (-1, 1):
            for i, (y, start, ln) in enumerate(_WING_ROWS):
                p.blk(ln, 0.82, white if i % 2 == 0 else tint, sgn * (start + ln / 2), y)
                p.blk(0.5, 0.82, edge, sgn * (start + ln - 0.25), y)          # 깃털 끝
    elif item_id == 'devil_wings':
        crimson, dark, edge = rgb(0.66, 0.09, 0.16), rgb(0.40, 0.04, 0.11), rgb(0.90, 0.22, 0.28)
        for sgn in (-1, 1):
            for i, (y, start, ln) in enumerate(_DEVIL_ROWS):
                p.blk(ln, 0.82, crimson if i % 2 == 0 else dark, sgn * (start + ln / 2), y)
                p.blk(0.45, 0.82, edge, sgn * (start + ln - 0.22), y)
            p.blk(0.28, 2.0, dark, sgn * 3.7, -1.4)                           # 가죽 날개 뼈대
        # 꼬리 — 오른쪽 엉덩이에서 위로 휘어 화살촉으로 끝난다
        p.blk(0.4, 0.4, dark, 2.55, 2.7)
        p.blk(0.4, 0.4, dark, 2.95, 3.05)
        p.blk(0.4, 0.4, dark, 3.4, 3.05)
        p.blk(0.4, 0.4, dark, 3.75, 2.7)
        p.blk(0.9, 0.35, edge, 3.95, 2.25)
        p.blk(0.45, 0.45, edge, 3.95, 1.9)


# ══════════════════════════════════════════════════════════════
# 옷 레이어 (몸통 바로 위 — 팔과 노트북이 그 위에 그려진다)
# 몸통 폭은 종마다 4.5~4.8이라 가장 좁은 4.5에 맞춘다. 몸통 y: 0.25 ~ 2.75
# ══════════════════════════════════════════════════════════════

def draw_outfit(p: Painter, item_id):
    W = rgb(0.97, 0.97, 1.00)
    if item_id == 'stripe_tee':
        blue, white = rgb(0.22, 0.42, 0.86), rgb(0.96, 0.97, 1.00)
        p.blk(4.5, 2.1, blue, 0, 1.45)
        for y in (1.0, 1.7, 2.4):
            p.blk(4.5, 0.32, white, 0, y)
        p.blk(1.4, 0.35, white, 0, 0.4)                       # 둥근 목선
    elif item_id == 'hoodie':
        gray, dark = rgb(0.52, 0.56, 0.64), rgb(0.38, 0.42, 0.50)
        p.blk(4.5, 2.2, gray, 0, 1.5)
        p.blk(2.6, 0.95, dark, 0, 2.15)                       # 배 주머니
        p.blk(1.8, 0.3, gray, 0, 1.75)
        p.blk(2.2, 0.4, dark, 0, 0.4)                         # 후드 둘레
        p.blk(0.2, 0.9, '#FFFFFF', -0.55, 1.0)                # 끈
        p.blk(0.2, 0.9, '#FFFFFF', 0.55, 1.0)
    elif item_id == 'tuxedo':
        black, red = rgb(0.10, 0.10, 0.14), rgb(0.82, 0.14, 0.22)
        p.blk(4.5, 2.2, black, 0, 1.5)
        p.blk(1.5, 1.7, W, 0, 1.15)                           # 셔츠 V
        p.blk(0.5, 0.5, W, -0.3, 2.05)
        p.blk(0.5, 0.5, W, 0.3, 2.05)
        p.blk(0.9, 0.5, red, 0, 0.45)                         # 나비넥타이
        p.blk(0.3, 0.3, mix(red, black, 0.3), 0, 0.45)
        p.blk(0.25, 0.25, W, 0, 1.5)                          # 단추
        p.blk(0.25, 0.25, W, 0, 1.95)
    elif item_id == 'armor':
        steel, light = rgb(0.70, 0.76, 0.84), rgb(0.88, 0.92, 0.97)
        dark, gold = rgb(0.48, 0.54, 0.64), rgb(0.96, 0.78, 0.20)
        p.blk(4.5, 2.3, steel, 0, 1.5)
        p.blk(3.6, 0.3, light, 0, 0.55)                       # 가슴 하이라이트
        p.blk(0.3, 1.7, dark, 0, 1.35)                        # 가운데 이음선
        p.blk(4.5, 0.4, gold, 0, 2.3)                         # 허리띠
        p.blk(0.5, 0.45, light, 0, 2.3)                       # 버클
        p.blk(1.2, 0.7, dark, -2.35, 0.5)                     # 어깨 보호대
        p.blk(1.2, 0.7, dark, 2.35, 0.5)
        p.blk(1.0, 0.3, light, -2.35, 0.3)
        p.blk(1.0, 0.3, light, 2.35, 0.3)
    elif item_id == 'school_uniform':
        navy, red, gold = rgb(0.16, 0.22, 0.46), rgb(0.82, 0.14, 0.20), rgb(0.98, 0.80, 0.22)
        p.blk(4.5, 2.2, navy, 0, 1.5)
        p.blk(1.5, 1.3, W, 0, 0.95)                           # 셔츠 V
        p.blk(1.0, 0.45, red, 0, 0.5)                         # 리본
        p.blk(0.35, 0.6, red, -0.4, 0.95)                     # 리본 끝
        p.blk(0.35, 0.6, red, 0.4, 0.95)
        p.blk(0.45, 0.45, gold, -1.5, 1.4)                    # 학교 마크
        p.blk(0.25, 0.25, gold, 0, 1.8)                       # 단추
        p.blk(0.25, 0.25, gold, 0, 2.2)
    elif item_id == 'business_suit':
        suit, lapel = rgb(0.14, 0.18, 0.28), rgb(0.08, 0.11, 0.19)
        tie = rgb(0.78, 0.12, 0.20)
        p.blk(4.5, 2.2, suit, 0, 1.5)
        p.blk(1.4, 1.6, W, 0, 1.1)                            # 셔츠
        p.blk(0.7, 1.7, lapel, -1.05, 1.2)                    # 라펠
        p.blk(0.7, 1.7, lapel, 1.05, 1.2)
        p.blk(0.45, 1.4, tie, 0, 1.35)                        # 넥타이
        p.blk(0.6, 0.35, tie, 0, 0.5)                         # 매듭
        p.blk(0.5, 0.3, W, -1.5, 1.7)                         # 가슴 손수건
    elif item_id == 'firefighter':
        red, dark, yellow = rgb(0.84, 0.16, 0.12), rgb(0.42, 0.07, 0.06), rgb(0.98, 0.84, 0.20)
        p.blk(4.5, 2.2, red, 0, 1.5)
        p.blk(4.5, 0.38, yellow, 0, 1.15)                     # 반사띠
        p.blk(4.5, 0.38, yellow, 0, 2.05)
        p.blk(0.3, 2.1, dark, 0, 1.5)                         # 앞 지퍼
        p.blk(2.4, 0.4, dark, 0, 0.4)                         # 높은 옷깃
    elif item_id == 'police':
        navy, sky = rgb(0.12, 0.17, 0.34), rgb(0.62, 0.76, 0.94)
        black, gold = rgb(0.07, 0.07, 0.10), rgb(0.98, 0.80, 0.22)
        p.blk(4.5, 2.2, navy, 0, 1.5)
        p.blk(1.3, 1.3, sky, 0, 0.95)                         # 셔츠
        p.blk(0.4, 1.2, black, 0, 1.1)                        # 넥타이
        p.blk(0.7, 0.7, gold, -1.4, 1.3)                      # 배지
        p.blk(0.25, 0.25, gold, 1.4, 1.0)
        p.blk(1.0, 0.35, gold, -2.2, 0.4)                     # 견장
        p.blk(1.0, 0.35, gold, 2.2, 0.4)
        p.blk(4.5, 0.3, black, 0, 2.4)                        # 벨트
    elif item_id == 'angel_gown':
        white, tint, gold = rgb(0.99, 0.99, 1.00), rgb(0.88, 0.92, 1.00), rgb(0.98, 0.82, 0.30)
        p.blk(4.5, 2.2, white, 0, 1.5)
        p.blk(4.9, 0.5, tint, 0, 2.95)                        # 밑단
        p.blk(4.5, 0.25, gold, 0, 1.95)                       # 금빛 띠
        p.blk(2.0, 0.3, gold, 0, 0.4)                         # 금빛 목둘레
        p.blk(0.3, 0.9, tint, -0.9, 1.2)                      # 주름
        p.blk(0.3, 0.9, tint, 0.9, 1.2)
    elif item_id == 'devil_suit':
        black, red, gold = rgb(0.10, 0.06, 0.10), rgb(0.76, 0.10, 0.16), rgb(0.98, 0.80, 0.22)
        p.blk(4.5, 2.2, black, 0, 1.5)
        p.blk(1.5, 1.6, red, 0, 1.1)                          # 붉은 셔츠
        p.blk(0.4, 1.3, black, 0, 1.3)                        # 검은 넥타이
        p.blk(0.7, 1.7, black, -1.05, 1.2)                    # 뾰족한 라펠
        p.blk(0.7, 1.7, black, 1.05, 1.2)
        p.blk(0.3, 0.3, gold, 1.6, 2.2)                       # 금 단추
    elif item_id == 'robe':
        purple, dark, gold = rgb(0.40, 0.25, 0.70), rgb(0.28, 0.16, 0.52), rgb(0.98, 0.82, 0.25)
        p.blk(4.5, 2.2, purple, 0, 1.5)
        p.blk(4.9, 0.5, dark, 0, 2.95)                        # 밑단 — 발 쪽으로 살짝 퍼진다
        p.blk(0.6, 2.0, dark, 0, 1.55)                        # 앞트임
        p.blk(4.5, 0.3, gold, 0, 1.9)                         # 허리띠
        p.blk(0.55, 0.55, gold, 0, 0.95)                      # 가슴 별
        p.blk(0.25, 0.25, gold, -0.55, 0.95)
        p.blk(0.25, 0.25, gold, 0.55, 0.95)


# ══════════════════════════════════════════════════════════════
# 앞 레이어 — 얼굴·머리
# ══════════════════════════════════════════════════════════════

def draw_face(p: Painter, item_id):
    if item_id == 'glasses':
        frame = rgb(0.22, 0.16, 0.10)
        for side in (-1, 1):
            p.frame_rect(1.5, 1.2, 1.6 / P, frame, side * 1.4, -0.9)
        p.blk(0.6, 0.2, frame, 0, -1.0)
        p.blk(0.35, 0.2, frame, -2.3, -1.0)
        p.blk(0.35, 0.2, frame, 2.3, -1.0)
    elif item_id == 'shades':
        black = rgb(0.06, 0.06, 0.09)
        for side in (-1, 1):
            p.blk(1.6, 1.0, black, side * 1.4, -0.9)
            p.blk(0.5, 0.18, mix(black, '#FFFFFF', 0.45), side * 1.1, -1.15)   # 렌즈 반사
        p.blk(1.2, 0.25, black, 0, -1.1)


def draw_head(p: Painter, item_id, t=0.0):
    if item_id == 'straw_hat':
        straw, band = rgb(0.93, 0.80, 0.45), rgb(0.78, 0.22, 0.20)
        p.blk(6.6, 0.45, straw, 0, -2.2)
        p.blk(3.4, 1.0, straw, 0, -2.9)
        p.blk(3.4, 0.3, band, 0, -2.45)
    elif item_id == 'wizard_hat':
        purple, light = rgb(0.36, 0.22, 0.62), rgb(0.50, 0.34, 0.80)
        p.blk(5.8, 0.35, purple, 0, -2.2)
        p.blk(4.0, 0.6, purple, 0, -2.65)
        p.blk(3.0, 0.6, light, 0, -3.2)
        p.blk(2.0, 0.6, purple, 0, -3.75)
        p.blk(1.1, 0.6, light, 0.2, -4.3)
        p.blk(0.6, 0.5, purple, 0.6, -4.8)
        p.blk(0.4, 0.4, rgb(1.0, 0.88, 0.25), -0.3, -3.2)     # 별
    elif item_id == 'halo':
        gold, glow = rgb(1.00, 0.86, 0.30), rgb(1.00, 0.96, 0.62)
        s = osc(t, 1.3)                                       # 둥둥 떠 있는 느낌
        lift = -3.0 * s / P
        # 반투명 대신 밝기를 오간다 (불투명도 0.72↔1.0)
        c = mix('#B8962A', gold, s)
        with p.at(0, lift):
            p.blk(3.0, 0.3, c, 0, -3.55)                      # 윗변
            p.blk(3.0, 0.3, c, 0, -2.75)                      # 아랫변
            p.blk(0.4, 0.5, c, -1.6, -3.15)                   # 양옆 (모서리를 깎아 동그랗게)
            p.blk(0.4, 0.5, c, 1.6, -3.15)
            p.blk(1.8, 0.14, glow, 0, -3.55)                  # 윗변 하이라이트
    elif item_id == 'devil_horns':
        red, dark = rgb(0.80, 0.10, 0.14), rgb(0.48, 0.04, 0.10)
        for sg in (-1, 1):
            p.blk(0.8, 0.7, red, sg * 2.45, -2.30)
            p.blk(0.6, 0.6, red, sg * 2.75, -2.85)
            p.blk(0.4, 0.5, dark, sg * 3.05, -3.35)
    elif item_id == 'fire_helmet':
        red, gold = rgb(0.84, 0.14, 0.12), rgb(0.98, 0.80, 0.22)
        p.blk(4.2, 0.9, red, 0, -2.55)                        # 돔
        p.blk(5.6, 0.45, red, 0, -2.05)                       # 챙
        p.blk(1.0, 0.3, red, 0, -3.15)                        # 꼭대기 볏
        p.blk(0.9, 0.7, gold, 0, -2.55)                       # 앞 방패 마크
        p.blk(4.2, 0.16, mix(red, '#FFFFFF', 0.35), 0, -2.85)
    elif item_id == 'police_cap':
        navy, black, gold = rgb(0.12, 0.18, 0.38), rgb(0.07, 0.07, 0.10), rgb(0.98, 0.80, 0.22)
        p.blk(5.0, 0.55, navy, 0, -2.95)                      # 넓은 윗판
        p.blk(4.2, 0.7, navy, 0, -2.50)
        p.blk(4.2, 0.22, black, 0, -2.12)                     # 띠
        p.blk(3.0, 0.28, black, 0, -1.95)                     # 챙
        p.blk(0.7, 0.6, gold, 0, -2.55)                       # 모표
    elif item_id == 'crown':
        gold, gem = rgb(0.96, 0.78, 0.20), rgb(0.88, 0.18, 0.30)
        blue = rgb(0.25, 0.62, 0.95)
        p.blk(4.4, 0.7, gold, 0, -2.4)
        for i in (-1, 0, 1):
            p.blk(0.8, 0.9, gold, i * 1.6, -3.0)
        p.blk(0.4, 0.4, gem, 0, -3.15)
        p.blk(0.3, 0.3, blue, -1.4, -2.4)
        p.blk(0.3, 0.3, blue, 1.4, -2.4)


# ══════════════════════════════════════════════════════════════
# 무기 (손에 쥔다)
# ══════════════════════════════════════════════════════════════

# 쥐는 자리 — 손 위치와 회전축은 모두 손잡이 중심이다
HOLD_RIGHT, HOLD_RAISED_LEFT, HOLD_SHOW_OFF = 'right', 'raisedLeft', 'showOff'


def draw_weapon(p: Painter, item_id, hold, t=0.0, swing=0.0, showing=False):
    """hold: 어디에 쥐었는지. swing: 보여주기 때의 기울임(도). t: 애니메이션 시계(초)."""
    if item_id not in _WEAPONS:
        return
    # 보여줄 때는 천천히 흔들림 없이, 작업 중에는 계속 살짝 흔들린다(2°↔9°)
    sway = 0.0 if hold == HOLD_SHOW_OFF else 2 + 7 * osc(t, 0.7)
    angle = (swing if showing else 0.0) + sway
    left = hold == HOLD_RAISED_LEFT
    # 왼손은 거울상으로 — 칼날이 바깥(왼쪽)으로 기울어야 자연스럽다
    ox = -3.7 if left else 3.7
    oy = -1.7 if left else (-0.5 if hold == HOLD_SHOW_OFF else 1.1)
    with p.at(ox, oy, 0, mirror=left):
        with p.at(0, 0, angle):
            _WEAPONS[item_id](p, t)


def _sword(p, blade, edge, guard, length):
    p.blk(0.4, 1.0, rgb(0.42, 0.28, 0.16), 0, 0)                        # 손잡이
    p.blk(1.8, 0.35, guard, 0, -0.62)                                   # 날밑
    p.blk(0.7, length, blade, 0, -0.8 - length / 2)                     # 칼날
    p.blk(0.2, length - 0.2, edge, -0.15, -0.8 - length / 2)            # 날 하이라이트
    p.blk(0.4, 0.4, blade, 0, -0.8 - length - 0.2)                      # 칼끝
    p.blk(0.6, 0.4, guard, 0, 0.65)                                     # 자루 끝


def _wood_sword(p, t):
    _sword(p, rgb(0.72, 0.52, 0.30), rgb(0.88, 0.70, 0.46), rgb(0.50, 0.34, 0.18), 3.0)


def _steel_sword(p, t):
    blade = rgb(0.74, 0.80, 0.88)
    _sword(p, blade, mix(blade, '#FFFFFF', 0.85), rgb(0.96, 0.78, 0.20), 3.4)


def _flame_sword(p, t):
    hot, core = rgb(1.00, 0.45, 0.10), rgb(1.00, 0.85, 0.25)
    pulse = osc(t, 0.35)
    p.blk(0.4, 1.0, rgb(0.30, 0.14, 0.10), 0, 0)
    p.blk(2.0, 0.4, rgb(0.55, 0.12, 0.10), 0, -0.62)
    p.blk(0.9, 3.8, hot, 0, -2.8)
    p.blk(0.4, 3.4, core, 0, -2.8)
    p.blk(0.4, 0.4, hot, 0, -4.9)
    # 칼끝에서 일렁이는 불꽃
    p.blk(0.5, 0.7, core, -0.4, -5.1 + (-5.5 + 5.1) * pulse)
    p.blk(0.4, 0.6, hot, 0.4, -5.6 + (-5.2 + 5.6) * pulse)


def _baton(p, t):
    shaft, light = rgb(0.26, 0.28, 0.36), rgb(0.55, 0.58, 0.68)
    band = mix(shaft, '#FFFFFF', 0.9)
    p.blk(0.6, 3.4, shaft, 0, -1.5)
    p.blk(0.18, 3.2, light, -0.18, -1.5)                                # 옆면 광택
    p.blk(0.35, 0.9, shaft, -0.45, -0.1)                                # 옆 손잡이
    p.blk(0.64, 0.3, band, 0, -2.6)                                     # 반사띠
    p.blk(0.64, 0.3, band, 0, -1.4)


def _fire_axe(p, t):
    wood, red, steel = rgb(0.50, 0.32, 0.16), rgb(0.84, 0.16, 0.12), rgb(0.80, 0.84, 0.90)
    # 날이 바깥(오른손 기준 오른쪽)을 본다 — 왼손으로 들 때는 좌우 반전돼 왼쪽 바깥을 본다
    p.blk(0.45, 4.6, wood, 0, -1.6)
    p.blk(1.3, 1.2, red, 0.8, -3.5)                                     # 도끼 머리
    p.blk(0.35, 1.4, steel, 1.55, -3.5)                                 # 날
    p.blk(0.9, 0.4, steel, -0.65, -3.7)                                 # 뒤 곡괭이(안쪽)


def _trident(p, t):
    pole, metal = rgb(0.42, 0.08, 0.12), rgb(0.88, 0.28, 0.30)
    p.blk(0.4, 5.0, pole, 0, -1.4)
    p.blk(1.9, 0.3, metal, 0, -3.8)                                     # 가로대
    p.blk(0.3, 1.2, metal, -0.8, -4.4)                                  # 세 갈래
    p.blk(0.3, 1.6, metal, 0, -4.6)
    p.blk(0.3, 1.2, metal, 0.8, -4.4)
    p.blk(0.2, 0.3, mix(metal, '#FFFFFF', 0.4 + 0.5 * osc(t, 0.6)), 0, -5.5)   # 끝 반짝임


def _staff(p, t):
    wood, orb = rgb(0.50, 0.32, 0.16), rgb(0.35, 0.85, 0.98)
    s = osc(t, 0.6)
    p.blk(0.45, 5.6, wood, 0, -1.6)
    p.blk(0.35, 1.0, wood, -0.75, -4.2)                                 # 보주를 감싼 가지
    p.blk(0.35, 1.0, wood, 0.75, -4.2)
    p.blk(1.4, 1.4, orb, 0, -4.4)
    p.blk(0.7, 0.7, mix(orb, '#FFFFFF', 0.45 + 0.5 * s), 0, -4.4)
    # 반짝이는 마법 가루
    p.blk(0.25, 0.25, orb, -1.3, -5.0 + (-5.4 + 5.0) * s)
    p.blk(0.25, 0.25, orb, 1.3, -5.3 + (-4.8 + 5.3) * s)


_WEAPONS = {
    'wood_sword': _wood_sword, 'steel_sword': _steel_sword, 'flame_sword': _flame_sword,
    'baton': _baton, 'fire_axe': _fire_axe, 'trident': _trident, 'staff': _staff,
}


def draw_carrot(p: Painter, left_arm_dy_px=0.0):
    """기본 무기 — 권한 요청·완료 때 들어 올린 왼손에 쥐는 당근 소품."""
    leaf, carrot = rgb(0.28, 0.70, 0.28), rgb(0.96, 0.55, 0.18)
    with p.at(-4.0, 0.1 + left_arm_dy_px / P):
        p.blk(1.5, 0.6, leaf, 0, -1.25)
        p.blk(0.7, 0.55, leaf, 0, -1.75)
        p.blk(0.7, 2.1, carrot, 0, 0)


# ══════════════════════════════════════════════════════════════
# 작업 도구 — 노트북 자리(몸통 앞, 팔 위)에 들어간다. 노트북(기본)은 캐릭터 쪽에서 그린다.
# 팔 움직임은 캐릭터가 하므로 여기서는 도구 자체의 움직임만 그린다.
# ══════════════════════════════════════════════════════════════

def draw_work_tool(p: Painter, tool_id, t=0.0, left_dy=0.0, right_dy=0.0) -> bool:
    """그렸으면 True. 노트북(기본)이거나 모르는 도구면 False — 호출한 쪽이 노트북을 그린다."""
    if tool_id == 'book_writing':
        _book_writing(p, t)
    elif tool_id == 'knitting':
        _knitting(p, t, left_dy, right_dy)
    elif tool_id == 'gamepad':
        _gamepad(p, t)
    else:
        return False
    return True


def _book_writing(p, now):
    t = now * 1.5
    done = int(t) % 5                                  # 다 쓴 줄 수 (0~4)
    nib = t - math.floor(t)                            # 지금 쓰는 줄의 진행도
    row_y = 1.3 + min(done, 3) * 0.38

    paper, cover = rgb(0.97, 0.95, 0.87), rgb(0.45, 0.26, 0.15)
    old_ink = mix(paper, rgb(0.25, 0.20, 0.35), 0.5)
    ink = rgb(0.22, 0.18, 0.40)
    p.blk(4.0, 0.3, cover, 0, 3.05)                    # 표지
    p.blk(1.8, 2.0, paper, -0.95, 2.0)
    p.blk(1.8, 2.0, paper, 0.95, 2.0)
    p.blk(0.14, 2.0, cover, 0, 2.0)                    # 책등
    for i in range(4):                                 # 왼쪽 쪽은 이미 쓴 글
        p.blk(1.2, 0.1, old_ink, -0.95, 1.3 + i * 0.38)
    for i in range(4):
        if i < done:
            p.blk(1.2, 0.1, mix(paper, ink, 0.9), 0.95, 1.3 + i * 0.38)
        elif i == done:
            p.blk(max(0.05, 1.2 * nib), 0.1, ink, 0.35 + 0.6 * nib, 1.3 + i * 0.38)
    # 깃펜
    qy = row_y + 0.1 + (0.0 if (nib % 0.25) < 0.12 else -0.12)
    with p.at(0.35 + 1.2 * nib, qy, 28):
        p.blk(0.14, 1.5, rgb(0.55, 0.38, 0.20), 0, -0.75)             # 대
        p.blk(0.5, 1.1, '#FFFFFF', 0.25, -1.0)                        # 깃털
        p.blk(0.3, 0.6, rgb(0.86, 0.90, 0.98), 0.4, -1.5)


def _knitting(p, now, left_dy, right_dy):
    # 주황 털실 — 한 가지 주황으로만 짜고, 코(스티치)가 교차하는 질감으로 털실 느낌을 낸다
    deep, light = rgb(0.88, 0.40, 0.06), rgb(1.00, 0.80, 0.50)
    cream, knob = rgb(0.96, 0.92, 0.80), rgb(0.45, 0.30, 0.14)
    shade, wool, sheen = rgb(0.72, 0.29, 0.03), rgb(0.97, 0.56, 0.12), rgb(1.00, 0.66, 0.25)

    rows = 2 + int(now * 1.5) % 4                      # 작품이 한 줄씩 길어진다
    roll = math.sin(now * 3.0) * 4                     # 실을 당길 때마다 실뭉치가 살짝 구른다

    # 뜨개 작품 — 바늘 교차점 아래로 늘어진다
    row_h, cols, top = 0.42, 5, 1.2
    p.blk(1.95, rows * row_h, shade, 0, top + rows * row_h / 2)
    for r in range(rows):
        for c in range(cols):
            x = -0.76 + c * 0.38
            y = top + row_h / 2 + r * row_h
            with p.at(x - 0.1, y, -26):                # V자 코 — 두 가닥이 아래에서 만난다
                p.blk(0.17, 0.5, wool)
            with p.at(x + 0.1, y, 26):
                p.blk(0.17, 0.5, sheen)

    # 실뭉치 — 왼발에서 조금 떨어진 바닥에 놓여 있다 (지름 1.6, 바닥에 닿도록 y 2.6)
    bx, by = -3.55, 2.6
    with p.at(bx, by, roll * 0.75):
        for w, y in ((0.9, -0.64), (1.4, -0.32), (1.6, 0.0), (1.4, 0.32), (0.9, 0.64)):
            p.blk(w, 0.32, deep, 0, y)                 # 둥근 윤곽(5단 픽셀 원)
        for w, x, y in ((0.7, 0.15, -0.62), (1.0, -0.15, -0.28), (1.1, 0.2, 0.04),
                        (0.9, -0.1, 0.36), (0.5, 0.15, 0.66)):
            p.blk(w, 0.2, light, x, y)                 # 대각선으로 감긴 연한 실결
        p.blk(0.3, 0.2, mix(deep, '#FFFFFF', 0.75), -0.4, -0.5)   # 왼쪽 위 하이라이트

    hand_x, hand_y = 1.15, 1.1
    lhx, lhy = -hand_x, hand_y + left_dy / P
    rhx, rhy = hand_x, hand_y + right_dy / P
    # 실뭉치 윗부분에서 왼손까지 이어지는 실 — 손이 움직이면 같이 당겨진다
    p.line(lhx, lhy, bx + 0.25, by - 0.8, deep, 0.14)
    # 바늘 — 손에서 시작해 손 높이를 따라 움직인다. 끝이 X자로 교차한다
    p.line(lhx, lhy, 0.55, 0.35, cream, 0.2)
    p.line(rhx, rhy, -0.55, 0.35, cream, 0.2)
    p.blk(0.35, 0.35, knob, 0.55, 0.35)                # 바늘 끝 마개
    p.blk(0.35, 0.35, knob, -0.55, 0.35)


def _gamepad(p, now):
    hop = max(0.0, math.sin(now * 6))                  # 캐릭터가 통통 뛴다
    scroll = (now * 1.2) % 1.0
    press = int(now * 5) % 2 == 0
    console = rgb(0.20, 0.24, 0.58)
    p.blk(3.4, 1.7, console, 0, 1.9)
    p.blk(1.7, 1.2, rgb(0.08, 0.10, 0.14), 0, 1.85)                     # 화면 테두리
    p.blk(1.5, 1.0, rgb(0.60, 0.86, 0.56), 0, 1.85)                     # 화면
    dark = rgb(0.10, 0.25, 0.12)
    p.blk(0.28, 0.28, dark, -0.45, 2.1 - hop * 0.45)                    # 캐릭터
    p.blk(0.2, 0.32, dark, 0.7 - scroll * 1.3, 2.1)                     # 장애물
    gray = rgb(0.80, 0.82, 0.90)
    p.blk(0.55, 0.18, gray, -1.45, 1.9)                                 # 십자키
    p.blk(0.18, 0.55, gray, -1.45, 1.9)
    red, yellow = rgb(0.92, 0.25, 0.30), rgb(0.98, 0.84, 0.25)
    p.blk(0.3, 0.3, red if press else mix(console, red, 0.55), 1.35, 1.75)
    p.blk(0.3, 0.3, mix(console, yellow, 0.55) if press else yellow, 1.65, 2.05)


# ══════════════════════════════════════════════════════════════
# 애니메이션이 필요한 아이템인지 — 그렇다면 호출한 쪽이 주기적으로 다시 그린다
# ══════════════════════════════════════════════════════════════

ANIMATED_HEAD = {'halo'}
ANIMATED_TOOLS = {'book_writing', 'knitting', 'gamepad'}
