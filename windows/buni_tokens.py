"""부니 디자인 토큰 (docs/design-system.md 와 같은 이름·같은 값).

맥 `BuniTokens.swift`, 사이트 CSS 변수와 값이 어긋나지 않게 문서를 기준으로 한다.
Tk 는 그림자·둥근 모서리·투명도를 못 그려 색·글꼴·간격 위주로 쓴다.
"""

TOKENS = {
    'dark': {
        'bg.canvas': '#121214', 'bg.sidebar': '#0E0E10',
        'surface.1': '#1A1A1D', 'surface.2': '#232326', 'surface.3': '#2C2C30',
        'border.subtle': '#28282C', 'border.strong': '#3C3C42',
        'text.primary': '#F5F5F7', 'text.secondary': '#C7C7CC', 'text.tertiary': '#8E8E93',
        'text.onAccent': '#1A1206',
        'accent.base': '#F28C2E', 'accent.hover': '#FFB066', 'accent.text': '#FFB066',
        'accent.soft': '#33261A', 'success': '#4DC780', 'warning': '#E8C34A',
        'danger': '#E6665A', 'info': '#6AA9FF', 'leaf': '#6BBF59',
    },
    'light': {
        'bg.canvas': '#F5F5F7', 'bg.sidebar': '#ECECEE',
        'surface.1': '#FFFFFF', 'surface.2': '#F2F2F4', 'surface.3': '#E5E5E8',
        'border.subtle': '#E2E2E6', 'border.strong': '#C9C9CF',
        'text.primary': '#1D1D1F', 'text.secondary': '#515154', 'text.tertiary': '#6E6E73',
        'text.onAccent': '#1A1206',
        'accent.base': '#F28C2E', 'accent.hover': '#D97A1F', 'accent.text': '#A85500',
        'accent.soft': '#FDEBD6', 'success': '#1F8A4C', 'warning': '#9A6B00',
        'danger': '#C93A2E', 'info': '#2255BB', 'leaf': '#4E9A3F',
    },
}

SPACE = {1: 2, 2: 4, 3: 8, 4: 12, 5: 16, 6: 20, 7: 24, 8: 32}
RADIUS = {'none': 0, 'sm': 4, 'md': 8, 'lg': 12, 'xl': 16, 'pill': 999}

FONT_FAMILY = {'body': 'Malgun Gothic', 'display': 'Malgun Gothic', 'mono': 'Consolas'}
# tk pt (문서 4장 표)
FONT_SIZE = {'xs': 8, 'sm': 9, 'md': 10, 'lg': 11, 'xl': 13, '2xl': 17}


def system_mode():
    """Windows 앱 테마(레지스트리 AppsUseLightTheme). 감지 실패 시 다크."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') as k:
            return 'light' if winreg.QueryValueEx(k, 'AppsUseLightTheme')[0] == 1 else 'dark'
    except Exception:
        return 'dark'


def palette(mode=None):
    return TOKENS.get(mode or system_mode(), TOKENS['dark'])


def mix(a, b, ratio):
    """a 를 ratio(0~1) 만큼 b 에 섞은 hex (상태색 옅은 배경용)."""
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return '#%02X%02X%02X' % tuple(round(x * ratio + y * (1 - ratio)) for x, y in zip(ca, cb))
