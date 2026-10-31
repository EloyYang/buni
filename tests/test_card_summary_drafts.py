"""업무현황판 카드 제목 요약(short_title)과 입력 초안 보관·복원. 임시 BUNI_TEAM_HOME 만 쓴다."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402


class ShortTitle(unittest.TestCase):
    def test_short_stays(self):
        self.assertEqual(bt.short_title('가격 페이지 정비'), '가격 페이지 정비')

    def test_long_is_ellipsized(self):
        out = bt.short_title('가' * 100)
        self.assertEqual(len(out), bt.BOARD_TITLE_MAX)
        self.assertTrue(out.endswith('…'))

    def test_first_line_and_spaces(self):
        self.assertEqual(bt.short_title('\n  첫   줄 \n둘째 줄'), '첫 줄')
        self.assertEqual(bt.short_title(None), '')

    def test_card_has_short_title_and_detail_has_full(self):
        proj = tempfile.mkdtemp(dir=TMP.name)
        long_title = ('아주 긴 제목 ' * 20).strip()
        j = bt.new_job(long_title, '전체 설명입니다\n여러 줄', proj)
        bt.save_job(j)
        cards = [c for c in bt.board_cards() if c['job_id'] == j['id']]
        self.assertEqual(len(cards), 1)
        c = cards[0]
        self.assertLessEqual(len(c['short_title']), bt.BOARD_TITLE_MAX)
        self.assertEqual(c['job_title'], long_title)           # 전체는 그대로
        d = bt.board_detail(c)
        self.assertEqual(d['title'], long_title)
        self.assertIn('전체 설명입니다', d['goal'])


class Drafts(unittest.TestCase):
    def test_round_trip_and_clear_after_send(self):
        k = bt.draft_key('job-a', 'dm:dev')
        self.assertEqual(k, 'job-a|dm:dev')
        bt.save_draft(k, '쓰던 글\n두 줄')
        bt.save_draft(bt.draft_key('job-a', 'channel'), '단체방 글')
        d = bt.load_drafts()                                   # 다시 읽어도(앱을 껐다 켜도) 남아 있다
        self.assertEqual(d[k], '쓰던 글\n두 줄')
        self.assertEqual(d['job-a|channel'], '단체방 글')
        bt.save_draft(k, '')                                   # 보낸 뒤에만 비워진다
        d = bt.load_drafts()
        self.assertNotIn(k, d)
        self.assertIn('job-a|channel', d)                      # 다른 방 초안은 그대로

    def test_broken_file_is_ignored(self):
        # 여러 시험 모듈이 BUNI_TEAM_HOME 을 각자 바꾸고 임시폴더를 지우므로, 날것으로 쓰기 전에 폴더부터 만든다
        # (엔진 쪽 save_draft 는 _atomic_write 가 폴더를 만든다 — 아래 시험이 확인).
        os.makedirs(bt.team_home(), exist_ok=True)
        with open(os.path.join(bt.team_home(), 'drafts.json'), 'w') as f:
            f.write('{broken')
        self.assertEqual(bt.load_drafts(), {})

    def test_save_draft_creates_missing_home(self):
        old = os.environ.get('BUNI_TEAM_HOME')
        with tempfile.TemporaryDirectory() as t:
            os.environ['BUNI_TEAM_HOME'] = os.path.join(t, 'nope', 'home')   # 아직 없는 폴더
            try:
                bt.save_draft('j|lead', '글')
                self.assertEqual(bt.load_drafts(), {'j|lead': '글'})
            finally:
                if old is None:
                    os.environ.pop('BUNI_TEAM_HOME', None)
                else:
                    os.environ['BUNI_TEAM_HOME'] = old


if __name__ == '__main__':
    unittest.main()
