"""입력창 지연 방지 — 키 입력마다 drafts.json 을 읽고 쓰지 않고, 모아서 한 번에 쓴다. 임시 BUNI_TEAM_HOME 만 쓴다."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402


class BulkSave(unittest.TestCase):
    def test_bulk_writes_and_clears(self):
        bt.save_drafts({'bulk-a|lead': '안녕', 'bulk-b|channel': '둘째'})
        d = bt.load_drafts()
        self.assertEqual((d['bulk-a|lead'], d['bulk-b|channel']), ('안녕', '둘째'))
        bt.save_drafts({'bulk-a|lead': '  ', 'bulk-b|channel': '수정'})   # 보낸 뒤(빈 글)에는 지운다
        d = bt.load_drafts()
        self.assertNotIn('bulk-a|lead', d)
        self.assertEqual(d['bulk-b|channel'], '수정')


class SourceGuards(unittest.TestCase):
    def test_windows_debounces(self):
        src = (ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        body = src[src.index('def _save_draft'):src.index('def _flush_drafts')]
        self.assertNotIn('buni_team.save_draft(', body)       # 키마다 디스크 접근 금지
        self.assertIn('after(600', body)
        i = src.index('    def close(self)')
        self.assertIn('self._flush_drafts()', src[i:i + 120])

    def test_mac_debounces(self):
        src = (ROOT / 'Sources' / 'ClaudeCompanion' / 'TeamStore.swift').read_text(encoding='utf-8')
        s = src[src.index('final class TeamDrafts'):]
        setter = s[s.index('func set('):s.index('func flush(')]
        self.assertNotIn('.write(to:', setter)               # set 은 메모리만, 쓰기는 flush
        self.assertIn('asyncAfter', setter)
        self.assertIn('willTerminateNotification', s)


class TestTypingIsolation(unittest.TestCase):
    """추가 요청 입력 지연 — 글자 입력이 디스크 읽기·판정을 부르지 않도록 소스 가드"""

    ROOT = Path(__file__).resolve().parent.parent

    def test_mac_decision_box_owns_its_text(self):
        src = (self.ROOT / 'Sources' / 'ClaudeCompanion' / 'SquadBoardViews.swift').read_text(encoding='utf-8')
        self.assertIn('private struct SquadDecisionBox: View', src)
        detail = src[src.index('struct SquadItemDetail'):src.index('private struct SquadDecisionBox')]
        self.assertNotIn('@State private var note', detail)   # body 가 파일을 읽는 상세에 입력 상태를 두지 않는다

    def test_windows_tick_defers_while_typing(self):
        src = (self.ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        self.assertIn("bind_all('<Key>'", src)
        tick = src[src.index('def _tick'):src.index('HIDDEN_TICK_MS = 5000')]
        self.assertLess(tick.index('TYPING_IDLE_S'), tick.index('self.refresh()'))


if __name__ == '__main__':
    unittest.main()
