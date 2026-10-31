"""맥(Swift)·Windows(Python) 가 같은 규칙을 쓰는지 소스를 읽어 맞춰 본다 — 카드 제목 길이, 초안 열쇠(방 이름).
화면을 띄우지 않는다. 임시 BUNI_TEAM_HOME 만 쓴다."""
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402


def _read(rel):
    return (ROOT / rel).read_text(encoding='utf-8')


class CardTitleParity(unittest.TestCase):
    def test_title_max_same_on_mac_and_windows(self):
        swift = re.search(r'static let titleMax = (\d+)', _read('Sources/ClaudeCompanion/SquadBoardViews.swift'))
        self.assertIsNotNone(swift)
        self.assertEqual(int(swift.group(1)), bt.BOARD_TITLE_MAX)

    def test_boundary_lengths(self):
        n = bt.BOARD_TITLE_MAX
        self.assertEqual(bt.short_title('a' * n), 'a' * n)                 # 딱 맞으면 그대로
        out = bt.short_title('a' * (n + 1))                                # 하나라도 넘으면 줄임
        self.assertEqual(out, 'a' * (n - 1) + '…')

    def test_both_card_layouts_use_short_title_only(self):
        # 보드·목록 카드 모두 전체 제목(job_title/jobTitle)이 아니라 짧은 제목을 그린다
        ui = _read('windows/buni_team_ui.py')
        board = ui[ui.index('def _show_board'):]
        self.assertIn("c['short_title']", board)
        self.assertNotRegex(board[:board.index("c['short_title']") + 400], r"text=c\['job_title'\]")
        mac = _read('Sources/ClaudeCompanion/SquadBoardViews.swift')
        cards = mac[mac.index('private struct SquadCard'):mac.index('struct SquadItemDetail')]
        self.assertEqual(cards.count('Text(item.shortTitle)'), 2)         # 보드 카드·목록 줄
        self.assertNotIn('jobTitle', cards)                               # 카드에는 전체 제목을 안 그린다
        detail = mac[mac.index('struct SquadItemDetail'):mac.index('private struct SquadProgressBar')]
        self.assertIn('Text(item.jobTitle)', detail)                      # 눌러 연 상세에서 전체 제목


class DraftKeyParity(unittest.TestCase):
    def test_room_names_same_on_both_sides(self):
        slack = _read('Sources/ClaudeCompanion/SquadSlackViews.swift')
        views = _read('Sources/ClaudeCompanion/TeamViews.swift')
        md = _read('Sources/ClaudeCompanion/MarkdownView.swift')
        ui = _read('windows/buni_team_ui.py')
        # 단체방 · 팀장 · 팀원 DM
        self.assertIn('TeamDrafts.key(job.id, "channel")', slack)
        self.assertIn('isLead ? "lead" : "dm:" + who', slack)
        for pane in ("'channel'", "'lead'", "'dm:' + r['id']"):
            self.assertIn(pane, ui)
        self.assertEqual(bt.draft_key('j1', 'channel'), 'j1|channel')
        # 결과 화면 피드백 (팀원 개별 요구사항 입력칸은 팀원 DM 으로 옮겨졌다)
        self.assertIn('"fb:" + id', md)
        self.assertIn("'fb:' + iid", ui)

    def test_key_format_and_file_name_same(self):
        store = _read('Sources/ClaudeCompanion/TeamStore.swift')
        self.assertIn('static func key(_ jobId: String, _ room: String) -> String { jobId + "|" + room }', store)
        self.assertIn('drafts.json', store)
        self.assertTrue(bt._drafts_path().endswith('drafts.json'))

    def test_clear_only_when_blank_on_both_sides(self):
        store = _read('Sources/ClaudeCompanion/TeamStore.swift')
        self.assertIn('trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.removeValue', store)
        k = bt.draft_key('j-ws', 'lead')
        bt.save_draft(k, '   \n ')                                         # 공백뿐이면 보관하지 않는다
        self.assertNotIn(k, bt.load_drafts())
        bt.save_draft(k, '  앞 공백은 남아요')
        self.assertEqual(bt.load_drafts()[k], '  앞 공백은 남아요')


class DraftScope(unittest.TestCase):
    def test_per_project_and_per_room(self):
        a, b = bt.draft_key('proj-a', 'dm:dev'), bt.draft_key('proj-b', 'dm:dev')
        c = bt.draft_key('proj-a', 'dm:qa')
        for k, v in ((a, 'A 글'), (b, 'B 글'), (c, 'qa 글')):
            bt.save_draft(k, v)
        d = bt.load_drafts()                                               # 프로젝트·팀원을 옮겨 다녀도 서로 안 섞인다
        self.assertEqual((d[a], d[b], d[c]), ('A 글', 'B 글', 'qa 글'))
        bt.save_draft(a, '')                                               # A 를 보내면 A 만 비워진다
        d = bt.load_drafts()
        self.assertNotIn(a, d)
        self.assertEqual((d[b], d[c]), ('B 글', 'qa 글'))

    def test_delete_project_keeps_nothing_broken(self):
        # 초안 파일이 없어도 읽기가 죽지 않는다
        p = Path(bt._drafts_path())
        if p.exists():
            p.unlink()
        self.assertEqual(bt.load_drafts(), {})


if __name__ == '__main__':
    unittest.main()
