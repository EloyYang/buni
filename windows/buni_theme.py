"""
부니 디자인 시스템 토큰 (Windows). 값의 기준은 docs/design-system.md,
맥은 Sources/ClaudeCompanion/BuniTheme.swift, 사이트는 docs/index.html :root — 셋을 같이 고친다.
"""

DARK = {
    'bg': '#1E1E24', 'rail': '#17171D', 'panel': '#26262E', 'field': '#2A2A34', 'raised': '#34343F',
    'line': '#3A3A44', 'ink': '#F2F2F6', 'ink2': '#C4C4CE', 'dim': '#8A8A98',
    'accent': '#F28C2E', 'accent_ink': '#1A1206',
    'info': '#6AA9FF', 'ok': '#4DC780', 'warn': '#D9B25A', 'danger': '#E65A66',
}
LIGHT = {
    'bg': '#F5F5F7', 'rail': '#ECECF0', 'panel': '#FFFFFF', 'field': '#F0F0F4', 'raised': '#E4E4EA',
    'line': '#D8D8E0', 'ink': '#1D1D22', 'ink2': '#4A4A55', 'dim': '#6A6A78',
    'accent': '#D9731A', 'accent_ink': '#FFFFFF',
    'info': '#2F6FD6', 'ok': '#1F8F4E', 'warn': '#A9791A', 'danger': '#C8323F',
}

SPACE = {'xs': 4, 'sm': 8, 'md': 12, 'lg': 16, 'xl': 24, 'xxl': 32}
RADIUS = {'sm': 6, 'md': 10, 'lg': 14}
# Tk 단위(pt) — 맥의 title 18 / heading 13 / body 12 / small 11 / caption 10 에 해당
FONT_SIZE = {'title': 14, 'heading': 10, 'body': 9, 'small': 8, 'caption': 8}


def mix(fg, bg, amount):
    """fg 를 bg 위에 amount(0~1) 만큼 올린 색 — 맥의 `색.opacity(amount)` 에 해당. Tk 는 투명도가 없어 미리 섞는다."""
    a = [int(fg[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(bg[i:i + 2], 16) for i in (1, 3, 5)]
    return '#' + ''.join('%02X' % round(x * amount + y * (1 - amount)) for x, y in zip(a, b))


def palette(dark=True):
    return DARK if dark else LIGHT


# 앱 창은 다크 고정 — 라이트는 정의만 해 둔다.
C = palette(True)
