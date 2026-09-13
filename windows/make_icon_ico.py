#!/usr/bin/env python3
"""
Buni Windows 앱 아이콘(.ico) 생성 — 맥 메뉴바 아이콘(MenuBarIcon.swift)과
동일한 9×9 픽셀 토끼 얼굴 실루엣을 흰색으로, 배경은 브랜드 오렌지(#f28c2e)로.
루트의 make_icon.py(macOS AppIcon용)와 동일한 디자인을 사용한다.

사용: python3 make_icon_ico.py <출력경로.ico>
빌드 의존성 없이(Pillow 불필요) 표준 PNG-in-ICO(Vista) 포맷으로 직접 패킹한다.
"""
import sys, struct, zlib

GRID = [
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

ORANGE = (242, 140, 46, 255)
WHITE  = (255, 255, 255, 255)
CLEAR  = (0, 0, 0, 0)

GRID_ROWS = len(GRID)
GRID_COLS = len(GRID[0])
PAD_RATIO = 0.20


def png_bytes(size: int) -> bytes:
    W = H = size

    def in_rrect(x, y):
        cx = (x + 0.5) / W * 2 - 1
        cy = (y + 0.5) / H * 2 - 1
        r, corner = 0.82, 0.20
        qx = abs(cx) - r + corner
        qy = abs(cy) - r + corner
        d = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** 0.5 + min(max(qx, qy), 0) - corner
        return d <= 0

    grid_w = size * (1 - 2 * PAD_RATIO)
    grid_h = grid_w * GRID_ROWS / GRID_COLS
    ox = (size - grid_w) / 2
    oy = (size - grid_h) / 2
    cell = grid_w / GRID_COLS

    def pixel(x, y):
        if not in_rrect(x, y):
            return CLEAR
        gx = (x - ox) / cell
        gy = (y - oy) / cell
        if 0 <= gx < GRID_COLS and 0 <= gy < GRID_ROWS:
            if GRID[int(gy)][int(gx)] == 'X':
                return WHITE
        return ORANGE

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


def ico_bytes(sizes) -> bytes:
    images = [png_bytes(s) for s in sizes]
    n = len(images)
    header = struct.pack('<HHH', 0, 1, n)
    entries = b''
    offset = 6 + 16 * n
    for s, img in zip(sizes, images):
        wh = s if s < 256 else 0  # 0 means 256 in ICO format
        entries += struct.pack('<BBBBHHII', wh, wh, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    return header + entries + b''.join(images)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'buni_icon.ico'
    with open(out, 'wb') as f:
        f.write(ico_bytes([16, 32, 48, 64, 128, 256]))
    print(f"  ICO → {out}")
