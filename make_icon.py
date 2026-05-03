#!/usr/bin/env python3
"""
Claudy 앱 아이콘 생성 (PIL 불필요 — 순수 stdlib PNG 생성)
사용: python3 make_icon.py <출력경로.png> <크기>
"""
import sys, struct, zlib

def png_bytes(size: int) -> bytes:
    W = H = size
    s = size

    def px(x, y):
        # ── 좌표를 -1~1로 정규화
        cx = (x - W / 2) / (W / 2)
        cy = (y - H / 2) / (H / 2)

        # ── 배경: 둥근 사각형 마스크
        r = 0.82
        def rr(cx, cy, rad, corner=0.18):
            qx = abs(cx) - rad + corner
            qy = abs(cy) - rad + corner
            d = (max(qx,0)**2 + max(qy,0)**2)**0.5 + min(max(qx,qy),0) - corner
            return d

        bg_d = rr(cx, cy, r)
        if bg_d > 0:
            return (0, 0, 0, 0)          # 투명 배경

        # ── 배경색: 따뜻한 주황
        bg = (193, 133, 95, 255)

        # ── 몸통 (타원)
        body_w, body_h = 0.52, 0.32
        in_body = (cx/body_w)**2 + (cy/body_h)**2 < 1.0

        # ── 집게 (왼쪽/오른쪽)
        def in_claw(side):
            ox = -0.62 if side == -1 else 0.62
            oy = -0.04
            lx, ly = cx - ox, cy - oy
            return (lx/(0.13))**2 + (ly/0.09)**2 < 1.0

        # ── 눈 (작은 검은 원)
        def in_eye(side):
            ox = side * 0.19
            oy = -0.13
            return (cx - ox)**2 + (cy - oy)**2 < (0.065)**2

        # ── 다리 (4쌍 → 간단히 타원 4개)
        def in_leg(i):
            xs = [-0.44, -0.22, 0.22, 0.44]
            ox, oy = xs[i], 0.30
            return ((cx - ox)/0.07)**2 + ((cy - oy)/0.14)**2 < 1.0

        dark = (120, 72, 40, 255)
        black = (20, 20, 20, 255)

        if in_eye(-1) or in_eye(1):
            return black
        if in_body:
            return dark
        if in_claw(-1) or in_claw(1):
            return dark
        for i in range(4):
            if in_leg(i):
                return dark
        return bg

    # PNG 인코딩
    raw = bytearray()
    for y in range(H):
        raw.append(0)  # filter type: None
        for x in range(W):
            raw.extend(px(x, y))

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
