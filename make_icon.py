#!/usr/bin/env python3
"""
Buni 앱 아이콘 생성 — 픽셀 아트 토끼 캐릭터
사용: python3 make_icon.py <출력경로.png> <크기>

16×16 픽셀 그리드 범례:
  E = 귀 바깥쪽 (연한 흰색-회색)
  p = 귀 안쪽  (핑크)
  W = 몸통/얼굴 (연한 흰색-회색)
  B = 눈       (거의 검정)
  P = 코       (핑크)
  . = 배경     (소프트 라벤더)
"""
import sys, struct, zlib

GRID = [
    "....Ep....pE....",  # 0  귀
    "....Ep....pE....",  # 1  귀
    "....Ep....pE....",  # 2  귀
    "....Ep....pE....",  # 3  귀
    "....EE....EE....",  # 4  귀 아래
    "..WWWWWWWWWWWW..",  # 5  머리 위
    ".WWWWWWWWWWWWWW.",  # 6  머리
    ".WWWBBWWWWBBWWW.",  # 7  눈
    ".WWWBBWWWWBBWWW.",  # 8  눈
    ".WWWWWWPPWWWWWW.",  # 9  코
    ".WWWWWWPPWWWWWW.",  # 10 코
    ".WWWWWWWWWWWWWW.",  # 11 턱
    "..WWWWWWWWWWWW..",  # 12 턱
    "................",  # 13
    "................",  # 14
    "................",  # 15
]

BG    = (172, 144, 208, 255)  # 소프트 라벤더 (배경)
BODY  = (232, 232, 240, 255)  # 연한 흰-회색 (몸통/귀 바깥)
PINK  = (242, 182, 202, 255)  # 핑크 (귀 안쪽, 코)
EYE   = ( 28,  28,  30, 255)  # 거의 검정 (눈)
CLEAR = (  0,   0,   0,   0)  # 투명

COLOR_MAP = {
    'W': BODY, 'E': BODY,
    'p': PINK, 'P': PINK,
    'B': EYE,
    '.': None,   # → BG (inside rounded rect)
}

def png_bytes(size: int) -> bytes:
    W = H = size
    GRID_N = 16
    cell = size / GRID_N

    def in_rrect(x, y):
        """macOS 앱 아이콘 스타일 둥근 사각형 (바깥 = 투명)"""
        cx = (x + 0.5) / W * 2 - 1   # -1 ~ 1
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
        raw.append(0)          # PNG filter: None
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
