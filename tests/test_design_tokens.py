"""디자인 시스템 토큰이 문서·Windows·맥·사이트에서 같은 값인지 확인한다 (docs/design-system.md 기준)."""
import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'windows'))

import buni_theme  # noqa: E402


def _read(*parts):
    with open(os.path.join(ROOT, *parts), encoding='utf-8') as f:
        return f.read()


# Swift 필드 이름 → Python 토큰 이름
SWIFT_NAMES = {'bg': 'bg', 'rail': 'rail', 'panel': 'panel', 'field': 'field', 'raised': 'raised', 'line': 'line',
               'ink': 'ink', 'ink2': 'ink2', 'dim': 'dim', 'accent': 'accent', 'accentInk': 'accent_ink',
               'info': 'info', 'ok': 'ok', 'warn': 'warn', 'danger': 'danger'}
# 사이트 CSS 변수 → Python 토큰 이름 (다크)
SITE_VARS = {'bg': 'bg', 'rail': 'rail', 'surface': 'panel', 'surface-2': 'field', 'raised': 'raised',
             'line': 'line', 'ink': 'ink', 'ink-2': 'ink2', 'muted': 'dim', 'carrot': 'accent',
             'accent-ink': 'accent_ink', 'info': 'info', 'ok': 'ok', 'warn': 'warn', 'danger': 'danger'}


class DesignTokenParity(unittest.TestCase):
    def test_same_keys_dark_and_light(self):
        self.assertEqual(set(buni_theme.DARK), set(buni_theme.LIGHT))

    def test_swift_matches_python(self):
        src = _read('Sources', 'ClaudeCompanion', 'BuniTheme.swift')
        for mode, palette in (('dark', buni_theme.DARK), ('light', buni_theme.LIGHT)):
            block = re.search(r'static let %s = BuniPalette\((.*?)\)\n' % mode, src, re.S).group(1)
            found = dict(re.findall(r'(\w+): 0x([0-9A-Fa-f]{6})', block))
            self.assertEqual(set(found), set(SWIFT_NAMES), mode)
            for sw, py in SWIFT_NAMES.items():
                self.assertEqual('#' + found[sw].upper(), palette[py].upper(), f'{mode}.{py}')

    def test_site_matches_python_dark(self):
        css = _read('docs', 'index.html')
        root = re.search(r':root\{(.*?)\n  \}', css, re.S).group(1)
        for var, py in SITE_VARS.items():
            m = re.search(r'--%s:\s*(#[0-9A-Fa-f]{6})' % re.escape(var), root)
            self.assertIsNotNone(m, var)
            self.assertEqual(m.group(1).upper(), buni_theme.DARK[py].upper(), var)

    def test_spacing_and_radius(self):
        css = _read('docs', 'index.html')
        for name, px in buni_theme.SPACE.items():
            m = re.search(r'--space-%s:\s*(\d+)px' % name, css)
            self.assertIsNotNone(m, name)
            self.assertEqual(int(m.group(1)), px, name)
        swift = _read('Sources', 'ClaudeCompanion', 'BuniTheme.swift')
        for name, px in buni_theme.SPACE.items():
            self.assertRegex(swift, r'\b%s: CGFloat = %d\b' % (name, px))
        for name, px in buni_theme.RADIUS.items():
            m = re.search(r'--radius-%s:\s*(\d+)px' % name, css)
            self.assertEqual(int(m.group(1)), px, name)
            self.assertRegex(swift, r'\br%s: CGFloat = %d\b' % (name.capitalize(), px))

    def test_doc_lists_every_dark_color(self):
        doc = _read('docs', 'design-system.md')
        for name, value in buni_theme.DARK.items():
            self.assertIn(value.upper(), doc.upper(), name)
        for name, value in buni_theme.LIGHT.items():
            self.assertIn(value.upper(), doc.upper(), name)

    def test_no_external_brand_assets(self):
        for rel in (('docs', 'design-system.md'), ('windows', 'buni_theme.py'), ('Sources', 'ClaudeCompanion', 'BuniTheme.swift')):
            text = _read(*rel)
            self.assertNotRegex(text, r'(?i)https?://')

    def test_swift_views_use_tokens(self):
        """채팅방·UsageBar·설정 화면은 색을 BuniTheme 토큰으로만 쓴다 (캐릭터 그림은 범위 밖)."""
        banned = re.compile(r'Color\(red:|Color\(white:|\.white\b(?!Space)|\.black\b|\.gray\b|\.yellow\b(?!Rabbit)'
                            r'|\.red\b|\.secondary\b|\.primary\b|\.accentColor\b')
        for name in ('ChatViews.swift', 'UsageBarView.swift', 'ShortcutSettingsView.swift'):
            src = _read('Sources', 'ClaudeCompanion', name)
            for no, line in enumerate(src.splitlines(), 1):
                code = line.split('//')[0]
                if 'trimmingCharacters' in code or 'yellowRabbit' in code:
                    continue
                self.assertIsNone(banned.search(code), f'{name}:{no} 하드코드 색: {line.strip()}')

    def test_windows_shop_and_chat_use_tokens(self):
        """상점·채팅 창(ShopWindow ~ ChatLobbyWindow)은 색을 buni_theme 토큰으로만 쓴다."""
        src = _read('windows', 'buni.py')
        self.assertIn('from buni_theme import C', src)
        start = src.index('class ShopWindow:')
        end = src.index('class BuniManager:')
        for no, line in enumerate(src[start:end].splitlines(), 1):
            code = line.split('#')[0] if "'#" not in line else line
            self.assertNotRegex(code, r"'#[0-9A-Fa-f]{3,6}'", f'ShopWindow~ChatLobbyWindow +{no}: {line.strip()}')
            self.assertNotRegex(line, r"(fg|bg|fill|foreground)\s*=\s*'(white|black)'", line.strip())

    def test_windows_settings_bubbles_permission_use_tokens(self):
        """설정 창·상태 말풍선·사용량 바·완료/질문/한도/권한 창은 색 글자 값(#RRGGBB, 'white'…)을 쓰지 않는다 (투명 키색 #010101 만 예외)."""
        src = _read('windows', 'buni.py')
        parts = [
            ('설정 창', src[src.index('class ShortcutSettingsWindow:'):src.index('def _read_session_title')]),
            ('상태 말풍선', src[src.index('    def _draw_bubble(self):'):src.index('    def _draw_memo(self):')]),
            ('사용량 바', src[src.index('    def _draw_bar(self):'):src.index('    def _reset_time_str(self)')]),
            ('완료·질문·한도·권한 창', src[src.index('    def _show_completion_popup(self):'):src.index('    def _show_menu(self')]),
        ]
        for label, text in parts:
            for no, line in enumerate(text.splitlines(), 1):
                code = line.split('  #')[0] if '  #' in line else line
                code = code.replace('#010101', '')
                self.assertNotRegex(code, r"'#[0-9A-Fa-f]{3,6}'", f'{label} +{no}: {line.strip()}')
                self.assertNotRegex(code, r"'(white|black)'", f'{label} +{no}: {line.strip()}')
        self.assertIn('LT = palette(False)', src)

    def test_mix(self):
        self.assertEqual(buni_theme.mix('#FFFFFF', '#000000', 0.5), '#808080')


if __name__ == '__main__':
    unittest.main()
