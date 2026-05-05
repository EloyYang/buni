#!/usr/bin/env python3
"""
Buni 앱 아이콘 — RabbitCharacterView 비율 기반 픽셀 아트
사용: python3 make_icon.py <출력경로.png> <크기>

캐릭터 원본 비율 (p=6.5 단위):
  귀  1.6p × 3.4p  (핑크 inner: 0.8p × 2.7p)
  머리 5.5p × 2.5p
  눈   0.65p × 0.75p  at ±1.4p 수평 (세로가 약간 긴 작은 직사각)
  코   0.55p × 0.4p   중앙 약간 아래

20×20 그리드 사용 (각 셀 = size/20).

범례:
  E = 귀 바깥쪽 (몸통색, 연한 회색-흰색)
  p = 귀 안쪽   (핑크)
  W = 머리/얼굴 (몸통색)
  B = 눈        (거의 검정)
  P = 코        (핑크)
  . = 배경      (라벤더)
"""
import sys, struct, zlib

# ── 20×20 픽셀 그리드 ────────────────────────────────────────────
# 행 구성:
#   0     : 상단 여백
#   1–5   : 귀 기둥 (5행, E/p 각 1셀)
#   6     : 귀 아래 (E만, 머리와 연결)
#   7     : 머리 위 (14셀 폭)
#   8–14  : 머리 (16셀 폭)
#             10–11행: 눈 (세로로 긴 1×2, col 7 / col 12)
#             13행   : 코 (2×1, col 9–10)
#   15    : 턱 (14셀 폭)
#   16    : 턱 (12셀 폭, 둥근 효과)
#   17–19 : 하단 여백

def _row(cells: dict, width: int = 20) -> str:
    r = ['.'] * width
    for col, ch in cells.items():
        if isinstance(col, range):
            for c in col:
                r[c] = ch
        else:
            r[col] = ch
    return ''.join(r)

GRID = [
    _row({}),                                              # 0  여백
    _row({6:'E', 7:'p', 12:'p', 13:'E'}),                 # 1  귀
    _row({6:'E', 7:'p', 12:'p', 13:'E'}),                 # 2  귀
    _row({6:'E', 7:'p', 12:'p', 13:'E'}),                 # 3  귀
    _row({6:'E', 7:'p', 12:'p', 13:'E'}),                 # 4  귀
    _row({6:'E', 7:'p', 12:'p', 13:'E'}),                 # 5  귀
    _row({6:'E', 7:'E', 12:'E', 13:'E'}),                 # 6  귀 아래 (몸통색)
    _row({range(3,17):'W'}),                              # 7  머리 위 (14셀)
    _row({range(2,18):'W'}),                              # 8  머리
    _row({range(2,18):'W'}),                              # 9  머리
    _row({range(2,18):'W', 7:'B', 12:'B'}),               # 10 눈 (1×2 상)
    _row({range(2,18):'W', 7:'B', 12:'B'}),               # 11 눈 (1×2 하)
    _row({range(2,18):'W'}),                              # 12 눈 아래
    _row({range(2,18):'W', 9:'P', 10:'P'}),               # 13 코 (2×1)
    _row({range(2,18):'W'}),                              # 14 턱
    _row({range(3,17):'W'}),                              # 15 턱 (14셀)
    _row({range(4,16):'W'}),                              # 16 턱 (12셀, 둥근)
    _row({}),                                              # 17 여백
    _row({}),                                              # 18 여백
    _row({}),                                              # 19 여백
]

# ── 색상 ──────────────────────────────────────────────────────────
BG    = (172, 144, 208, 255)  # 라벤더 배경
BODY  = (232, 232, 240, 255)  # 연한 흰-회색 (몸통/귀 바깥)
PINK  = (242, 182, 202, 255)  # 핑크 (귀 안쪽, 코)
EYE   = ( 28,  28,  30, 255)  # 거의 검정 (눈)
CLEAR = (  0,   0,   0,   0)  # 투명

COLOR_MAP = {
    'W': BODY, 'E': BODY,
    'p': PINK, 'P': PINK,
    'B': EYE,
    '.': None,   # → BG (둥근 사각형 안쪽)
}

# ── PNG 생성 ──────────────────────────────────────────────────────
def png_bytes(size: int) -> bytes:
    W = H = size
    GRID_N = 20
    cell = size / GRID_N

    def in_rrect(x, y):
        """macOS 앱 아이콘 스타일 둥근 사각형 마스크"""
        cx = (x + 0.5) / W * 2 - 1
        cy = (y + 0.5) / H * 2 - 1
        r, corner = 0.82, 0.20
        qx = abs(cx) - r + corner
        qy = abs(cy) - r + corner
        d = (max(qx, 0)**2 + max(qy, 0)**2)**0.5 + min(max(qx, qy), 0) - corner
        return d <= 0

    def pixel(x, y):
        if not in_rrect(x, y):
            return CLEAR
        col = int(x / cell)
        row = int(y / cell)
        if 0 <= row < GRID_N and 0 <= col < GRID_N:
            ch = GRID[row][col]
            c  = COLOR_MAP.get(ch)
            return c if c else BG
        return BG

    raw = bytearray()
    for y in range(H):
        raw.append(0)
        for x in range(W):
            raw.extend(pixel(x, y))

    def chunk(name, data):
        c = struct.pack('>I', len(data)) + name + data
        return c + struct.pack('>I', zlib.crc32(name + data) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', idat)
            + chunk(b'IEND', b''))


if __name__ == '__main__':
    out  = sys.argv[1]
    size = int(sys.argv[2])
    with open(out, 'wb') as f:
        f.write(png_bytes(size))
    print(f"  {size}×{size} → {out}")
