"""
업무 보드 변경 전·후 화면 — 바뀐 영역 계산 시험. python3 tests/test_screen_diff.py
엔진(png_read · diff_boxes · screen_diff · job_screens)과, 맥·Windows 화면이 같은 값을 쓰는지(소스 확인).
"""
import json
import os
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402


def write_png(path, w, h, paint=None, ctype=2, ftype=0):
    """paint(x, y) → (r, g, b) 로 w×h PNG 를 쓴다 (시험용 최소 인코더)."""
    chans = {0: 1, 2: 3, 6: 4}[ctype]
    rows = []
    prev = bytes(w * chans)
    for y in range(h):
        px = bytearray()
        for x in range(w):
            r, g, b = (paint or (lambda *_: (255, 255, 255)))(x, y)
            px += bytes({0: (r,), 2: (r, g, b), 6: (r, g, b, 255)}[ctype])
        if ftype == 2:     # Up 필터 — 읽는 쪽이 되돌리는지 확인
            line = bytes((px[i] - prev[i]) & 255 for i in range(len(px)))
        else:
            line = bytes(px)
        rows.append(bytes([ftype]) + line)
        prev = bytes(px)

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ctype, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(data)


def block(x0, y0, x1, y1, color=(200, 0, 0)):
    return lambda x, y: color if x0 <= x < x1 and y0 <= y < y1 else (255, 255, 255)


class ScreenDiff(unittest.TestCase):
    def setUp(self):
        self.d = Path(TMP.name) / 'case'
        self.d.mkdir(exist_ok=True)

    def pair(self, name, before, after, wh=(64, 48)):
        b, a = self.d / f'{name}.before.png', self.d / f'{name}.after.png'
        write_png(b, *wh, paint=before)
        write_png(a, *wh, paint=after)
        return str(b), str(a)

    def test_same_image_has_no_box(self):
        r = bt.screen_diff(*self.pair('same', block(4, 4, 20, 20), block(4, 4, 20, 20)))
        self.assertEqual((r['boxes'], r['error'], r['w'], r['h']), ([], '', 64, 48))

    def test_one_changed_area_is_boxed(self):
        r = bt.screen_diff(*self.pair('one', None, block(16, 16, 32, 24)))
        self.assertEqual(r['error'], '')
        self.assertEqual(len(r['boxes']), 1)
        x, y, w, h = r['boxes'][0]
        self.assertTrue(x <= 16 and y <= 16 and x + w >= 32 and y + h >= 24)
        self.assertTrue(w <= 16 + 2 * bt.SCREEN_PAD and h <= 8 + 2 * bt.SCREEN_PAD)

    def test_far_areas_stay_separate_near_areas_merge(self):
        far = lambda x, y: (0, 0, 0) if (x < 8 and y < 8) or (x >= 56 and y >= 40) else (255, 255, 255)
        self.assertEqual(len(bt.screen_diff(*self.pair('far', None, far))['boxes']), 2)
        near = lambda x, y: (0, 0, 0) if (x < 8 and y < 8) or (16 <= x < 24 and y < 8) else (255, 255, 255)
        self.assertEqual(len(bt.screen_diff(*self.pair('near', None, near))['boxes']), 1)

    def test_tiny_difference_below_threshold_is_ignored(self):
        r = bt.screen_diff(*self.pair('tiny', None, lambda x, y: (250, 255, 255)))
        self.assertEqual(r['boxes'], [])

    def test_boxes_stay_inside_image(self):
        r = bt.screen_diff(*self.pair('edge', None, block(0, 0, 64, 48)))
        x, y, w, h = r['boxes'][0]
        self.assertEqual((x, y, x + w, y + h), (0, 0, 64, 48))

    def test_size_mismatch_gives_reason_not_box(self):
        b, a = self.d / 'size.before.png', self.d / 'size.after.png'
        write_png(b, 64, 48)
        write_png(a, 80, 48, paint=block(0, 0, 10, 10))
        r = bt.screen_diff(str(b), str(a))
        self.assertEqual(r['boxes'], [])
        self.assertIn('크기가 달라', r['error'])
        self.assertIn('64×48', r['error'])
        self.assertIn('80×48', r['error'])

    def test_unreadable_file_gives_reason(self):
        bad = self.d / 'bad.png'
        bad.write_bytes(b'not a png')
        ok = self.d / 'ok.png'
        write_png(ok, 8, 8)
        for pair in ((str(bad), str(ok)), (str(ok), str(self.d / 'missing.png'))):
            r = bt.screen_diff(*pair)
            self.assertEqual(r['boxes'], [])
            self.assertIn('계산하지 못했어요', r['error'])

    def test_png_variants_decode_the_same(self):
        for ctype, ftype in ((0, 0), (2, 2), (6, 0), (6, 2)):
            p = self.d / f'v{ctype}{ftype}.png'
            write_png(p, 16, 8, paint=block(0, 0, 8, 8, (10, 10, 10)), ctype=ctype, ftype=ftype)
            w, h, rows = bt.png_read(str(p))
            self.assertEqual((w, h), (16, 8))
            self.assertEqual(rows[0][0:4], bytes((10, 10, 10, 255)))
            self.assertEqual(rows[0][8 * 4:8 * 4 + 4], bytes((255, 255, 255, 255)))

    def test_many_regions_collapse_to_limit(self):
        spots = lambda x, y: (0, 0, 0) if x % 40 < 8 and y % 40 < 8 else (255, 255, 255)
        r = bt.screen_diff(*self.pair('many', None, spots, wh=(400, 400)))
        self.assertLessEqual(len(r['boxes']), bt.SCREEN_MAX_BOXES)

    def test_job_screens_caches_into_screens_json(self):
        jid = 'job-shots'
        sd = Path(bt.job_path(jid, 'screens'))
        write_png(sd / 'home.before.png', 32, 32)
        write_png(sd / 'home.after.png', 32, 32, paint=block(8, 8, 16, 16))
        write_png(sd / 'lonely.before.png', 32, 32)             # 짝이 없으면 '캡처 아님'으로 보인다
        items = bt.job_screens(jid)
        self.assertEqual([i['name'] for i in items], ['home', 'lonely'])
        self.assertTrue(items[0]['captured'])
        self.assertFalse(items[1]['captured'])
        self.assertEqual(items[1]['missing'], ['after'])
        self.assertEqual(len(items[0]['boxes']), 1)
        cache = json.loads(Path(bt.job_path(jid, 'screens.json')).read_text(encoding='utf-8'))
        self.assertEqual(cache['items'], items)
        self.assertEqual(bt.job_screens(jid), items)             # 파일이 그대로면 같은 값
        self.assertEqual(bt.job_screens('job-without-shots'), [])

    def test_board_detail_carries_screens(self):
        job = bt.new_job('화면 작업', '목표', TMP.name)
        job['status'] = 'review'
        bt.save_job(job)
        sd = Path(bt.job_path(job['id'], 'screens'))
        write_png(sd / 'a.before.png', 16, 16)
        write_png(sd / 'a.after.png', 16, 16, paint=block(0, 0, 8, 8))
        card = next(c for c in bt.board_cards([job]) if c['job_id'] == job['id'])
        self.assertEqual(bt.board_detail(card)['screens'][0]['name'], 'a')


class ScreensInViews(unittest.TestCase):
    """맥·Windows 화면이 엔진이 저장한 값(boxes · error)을 같은 이름으로 읽고, 확대·테두리 토글 문구가 같다."""
    swift = (HERE.parent / 'Sources/ClaudeCompanion/SquadBoardViews.swift').read_text(encoding='utf-8')
    py = (HERE.parent / 'windows/buni_team_ui.py').read_text(encoding='utf-8')

    def test_both_read_engine_fields(self):
        for key in ('boxes', 'error', 'before', 'after'):
            self.assertIn(f'"{key}"', self.swift)
            self.assertIn(f"'{key}'", self.py)
        self.assertIn('screens.json', self.swift)
        self.assertIn("d['screens']", self.py)

    def test_same_labels(self):
        for ko in ('변경 전', '변경 후', '테두리 켜기', '테두리 끄기', '눌러서 크게 보기', '닫기'):
            self.assertIn(ko, self.swift, ko)
            self.assertIn(ko, self.py, ko)


if __name__ == '__main__':
    unittest.main()
