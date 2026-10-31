"""동기화 폴더(SynologyDrive 등) 안에서 빌드해도 앱 번들·ZIP 이 프로젝트 폴더에 생기지 않는다 — "Buni 2.app" 같은 충돌 복사본 방지."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class BuildOutputOutsideSyncedFolder(unittest.TestCase):
    def test_build_script_puts_bundle_in_out_dir(self):
        s = (ROOT / 'build_app.sh').read_text(encoding='utf-8')
        self.assertIn('/CloudStorage/', s)
        self.assertRegex(s, r'OUT_DIR="\$\{BUILD_DIR:-\$SCRIPT_DIR\}"')
        self.assertIn('APP_BUNDLE="$OUT_DIR/$APP_NAME.app"', s)
        self.assertNotRegex(s, r'APP_BUNDLE="\$SCRIPT_DIR')

    def test_release_script_uses_the_same_location(self):
        s = (ROOT / 'release.sh').read_text(encoding='utf-8')
        self.assertIn('/CloudStorage/', s)
        self.assertIn('APP_BUNDLE="$OUT_DIR/Buni.app"', s)
        self.assertIn('ZIP_PATH="$OUT_DIR/$ZIP_NAME"', s)
        self.assertIn('cd "$OUT_DIR"', s)


if __name__ == '__main__':
    unittest.main()
