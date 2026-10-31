"""맥 SquadBoard(SquadBoardViews.swift) ↔ 엔진(windows/buni_team.py) 칼럼 판정·제목 요약 규칙 비교 시험.
test_parity_drafts_cards.py 처럼 Swift 소스에서 상수와 분기를 읽어 비교한다 (규칙을 손으로 옮기지 않는다).
  1. 칼럼·상태 이름(한/영)·자동 진행 이름이 양쪽에 같다.
  2. 시작 전 '다음에 할 일' 카드(대기·확인 필요·상한으로 멈춤·거절함)의 분기를 Swift 소스에서 읽어 엔진 board_cards 결과와 대응시킨다.
  3. column / shortTitle 은 Swift 소스를 잘라 swiftc 로 실제로 돌려 엔진 결과와 같은지 본다 (swiftc 가 없으면 이 부분만 건너뜀).
한쪽이 어긋나면 실패한다. 임시 BUNI_TEAM_HOME 만 쓰고 claude 는 부르지 않는다."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'windows'))

TMP = tempfile.TemporaryDirectory()
os.environ['BUNI_TEAM_HOME'] = TMP.name
import buni_team as bt  # noqa: E402

SWIFT = (ROOT / 'Sources/ClaudeCompanion/SquadBoardViews.swift').read_text(encoding='utf-8')

JOB_STATES = ('draft', 'interviewing', 'review_requirements', 'queued', 'running', 'waiting_limit',
              'paused', 'review', 'done', 'failed', 'cancelled')
ROLE_STATES = (None, 'pending', 'running', 'done_unreviewed', 'revise', 'accepted')

TITLES = [
    '', '   ', '\n\n', 'a', 'a' * 35, 'a' * 36, 'a' * 37, 'a' * 100,
    '가' * 36, '가' * 37, '첫 줄\n둘째 줄', '\n\n  앞 빈 줄 건너뜀\n다음', '  공백   여러   개  ',
    '탭\t섞인\t제목', ('단어 ' * 30), '앞  ' + 'b' * 40, '🐰' * 36, '🐰' * 37, '가격 페이지 › 후속 정리 작업을 이어서 진행합니다 길게',
    '\r\n윈도우 줄바꿈\r\n둘째', 'x' * 36 + '\n짧은',
]


def _func(name_re, src=SWIFT):
    m = re.search(name_re + r'.*?\n    \}\n', src, re.S)
    assert m, f'SquadBoardViews.swift 에서 {name_re} 를 찾지 못했어요'
    return m.group(0)


class Names(unittest.TestCase):
    def test_column_names_same(self):
        title = re.search(r'enum SquadColumn.*?var title: String \{(.*?)\n    \}', SWIFT, re.S).group(1)
        mac = {k: (a, b) for k, a, b in re.findall(r'case \.(\w+):\s+return L\.t\("([^"]*)", "([^"]*)"\)', title)}
        self.assertEqual(mac, dict(bt.BOARD_COLUMN_NAMES))
        order = re.search(r'enum SquadColumn: String, CaseIterable, Hashable \{\s*case ([^\n]+)', SWIFT).group(1)
        self.assertEqual(tuple(x.strip() for x in order.split(',')), bt.BOARD_COLUMNS)    # 칼럼 순서도 같다

    def test_auto_labels_same(self):
        label = re.search(r'var autoLabel: String \{(.*?)\n    \}', SWIFT, re.S).group(1)
        mac = {k: (a, b) for k, a, b in re.findall(r'case "(\w+)":\s+return L\.t\("([^"]*)", "([^"]*)"\)', label)}
        self.assertEqual(mac, dict(bt.BOARD_AUTO_NAMES))

    def test_title_max_same(self):
        self.assertEqual(int(re.search(r'static let titleMax = (\d+)', SWIFT).group(1)), bt.BOARD_TITLE_MAX)


class NextStepCards(unittest.TestCase):
    """대기 · 확인 필요 · 상한으로 멈춤 · 거절함 — 시작 전 '다음에 할 일' 카드의 분기."""

    # 입력 표: (이름, 단계 dict, 기대 칼럼, 기대 상태 한글, 기대 auto)
    TABLE = [
        ('대기-꺼짐', {'auto': 'off'}, 'ready', '대기', ''),
        ('대기-상한전', {'auto': 'cap'}, 'ready', '대기', ''),
        ('대기-없음', {}, 'ready', '대기', ''),
        ('확인 필요', {'auto': 'confirm'}, 'blocked', '확인 필요', 'confirm'),
        ('상한으로 멈춤', {'auto': 'limit'}, 'blocked', '확인 필요', 'limit'),
        ('거절함', {'auto': 'off', 'rejected': True}, 'done', '거절함', 'rejected'),
        ('확인 필요였다가 거절', {'auto': 'confirm', 'rejected': True}, 'done', '거절함', 'rejected'),
        ('상한이었다가 거절', {'auto': 'limit', 'rejected': True}, 'done', '거절함', 'rejected'),
    ]

    @classmethod
    def setUpClass(cls):
        job = bt.new_job('다음 업무 시험', '목표', TMP.name)
        job['status'] = 'review'
        job['plan'] = {'summary': '', 'roles': [{'id': 'dev', 'name': '개발', 'icon': '🧑‍💻', 'kind': 'code', 'mission': 'm',
                                                  'deliverable': '', 'depends_on': []}]}
        job['roles'] = {'dev': {'status': 'accepted', 'summary': 's'}}
        bt.save_job(job)
        steps = [dict(id=f's{i}', title=f'단계{i}', goal='g', why='w', **t) for i, (_, t, *_r) in enumerate(cls.TABLE)]
        steps.append({'id': 'sr', 'title': '이어 진행', 'goal': 'g', 'why': '', 'auto': 'confirm', 'role_id': 'dev'})   # 이미 맡겨진 항목은 카드가 따로 없다
        steps.append({'id': 'sj', 'title': '따로 만든 job', 'goal': 'g', 'why': '', 'auto': 'confirm', 'job_id': 'old'})
        Path(bt.wrapup_path(job['id'])).write_text(json.dumps({'review_items': [], 'next_steps': steps}, ensure_ascii=False), encoding='utf-8')
        cls.cards = {c['step_id']: c for c in bt.board_cards([bt.load_job(job['id'])], now=1.0) if c['kind'] == 'next'}

    def test_engine_table(self):
        for i, (name, _, col, ko, auto) in enumerate(self.TABLE):
            c = self.cards[f's{i}']
            self.assertEqual((c['column'], c['state'][0], c['auto']), (col, ko, auto), name)
        self.assertEqual(set(self.cards), {f's{i}' for i in range(len(self.TABLE))})        # role_id / job_id 항목은 카드 없음

    def _swift_branch(self):
        """Swift defer 블록의 분기를 소스에서 읽는다."""
        blk = re.search(r'for s in steps where (.*?) \{(.*?)\n                \}\n            \}', SWIFT, re.S)
        self.assertIsNotNone(blk, 'Swift 의 다음에 할 일 카드 분기를 찾지 못했어요')
        return blk.group(1), blk.group(2)

    def test_swift_branches_match_engine(self):
        cond, body = self._swift_branch()
        self.assertEqual(cond.replace(' ', ''), 's.roleId==nil&&s.jobId==nil')           # 엔진: role_id / job_id 있으면 건너뜀
        held = re.search(r'let held = (.*)', body).group(1)
        self.assertEqual(sorted(re.findall(r'"(\w+)"', held)), ['confirm', 'limit'])        # 엔진 a in ('confirm','limit')
        self.assertIn('let closed = s.rejected', body)
        col = re.search(r'column: closed \? \.(\w+) : held \? \.(\w+) : \.(\w+),', body)
        label = re.search(r'stateLabel: closed \? L\.t\("([^"]*)", "([^"]*)"\) : held \? SquadColumn\.(\w+)\.title : SquadColumn\.(\w+)\.title', body)
        auto = re.search(r'auto: closed \? "(\w+)" : held \? \(s\.auto \?\? ""\) : ""', body)
        self.assertTrue(col and label and auto, 'Swift 분기 모양이 바뀌었어요 — 엔진과 다시 맞춰 보세요')
        closed_col, held_col, else_col = col.groups()
        self.assertEqual(label.group(3), held_col)
        self.assertEqual(label.group(4), else_col)
        names = bt.BOARD_COLUMN_NAMES
        for i, (name, step, ecol, eko, eauto) in enumerate(self.TABLE):
            closed = bool(step.get('rejected'))
            held = step.get('auto') in ('confirm', 'limit')
            mcol = closed_col if closed else held_col if held else else_col
            mko = label.group(1) if closed else names[held_col][0] if held else names[else_col][0]
            mauto = auto.group(1) if closed else step.get('auto', '') if held else ''
            c = self.cards[f's{i}']
            self.assertEqual((mcol, mko, mauto), (c['column'], c['state'][0], c['auto']), f'{name}: 맥 ≠ 엔진')
        self.assertEqual(label.group(2), 'Rejected')
        self.assertEqual(label.group(1), bt.BOARD_AUTO_NAMES['rejected'][0])


# ── Swift 소스를 실제로 돌려 비교 ──
HARNESS = '''import Foundation
enum SquadColumn: String, CaseIterable, Hashable { case %(columns)s }
enum SquadBoard {
%(column)s
%(title)s
    static let titleMax = %(tmax)s
}
@main struct Run {
    static func main() {
        let obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let cols = (obj["columns"] as! [[String: Any]]).map { SquadBoard.column(jobState: $0["job"] as! String, roleStatus: $0["role"] as? String).rawValue }
        let titles = (obj["titles"] as! [String]).map { SquadBoard.shortTitle($0) }
        let small = (obj["titles"] as! [String]).map { SquadBoard.shortTitle($0, max: 10) }
        print(String(data: try! JSONSerialization.data(withJSONObject: ["columns": cols, "titles": titles, "small": small]), encoding: .utf8)!)
    }
}
'''


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc 가 없는 환경 — 맥 소스 실행 비교는 건너뜀')
class SwiftRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        d = Path(TMP.name) / 'swift_rules'
        d.mkdir(exist_ok=True)
        columns = re.search(r'enum SquadColumn: String, CaseIterable, Hashable \{\s*case ([^\n]+)', SWIFT).group(1)
        column = _func(r'    static func column\(')
        title = _func(r'    static func shortTitle\(')
        tmax = re.search(r'static let titleMax = (\d+)', SWIFT).group(1)
        (d / 'main.swift').write_text(HARNESS % {'columns': columns, 'column': column, 'title': title, 'tmax': tmax}, encoding='utf-8')
        cls.cols = [{'job': j, 'role': r} for j in JOB_STATES for r in ROLE_STATES]
        (d / 'in.json').write_text(json.dumps({'columns': cls.cols, 'titles': TITLES}), encoding='utf-8')
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / 'mc'))
        b = subprocess.run(['swiftc', '-parse-as-library', '-o', str(d / 'run'), str(d / 'main.swift')],
                           capture_output=True, text=True, env=env, timeout=300)
        if b.returncode:
            raise AssertionError('맥 판정 소스를 컴파일하지 못했어요:\n' + b.stderr[-2000:])
        r = subprocess.run([str(d / 'run'), str(d / 'in.json')], capture_output=True, text=True, timeout=120)
        if r.returncode:
            raise AssertionError('맥 판정 실행 실패:\n' + r.stderr[-2000:])
        cls.out = json.loads(r.stdout)

    def test_column_all_combinations(self):
        bad = [f"{c['job']}/{c['role']}: 엔진 {bt.board_column(c['job'], c['role'])} ≠ 맥 {m}"
               for c, m in zip(self.cols, self.out['columns']) if bt.board_column(c['job'], c['role']) != m]
        self.assertEqual(bad, [])

    def test_five_columns_all_reachable(self):
        self.assertEqual({bt.board_column(c['job'], c['role']) for c in self.cols}, set(bt.BOARD_COLUMNS))

    def test_short_title_default_length(self):
        bad = [f'{t!r}: 엔진 {bt.short_title(t)!r} ≠ 맥 {m!r}' for t, m in zip(TITLES, self.out['titles']) if bt.short_title(t) != m]
        self.assertEqual(bad, [])

    def test_short_title_small_length(self):
        bad = [f'{t!r}: 엔진 {bt.short_title(t, 10)!r} ≠ 맥 {m!r}' for t, m in zip(TITLES, self.out['small']) if bt.short_title(t, 10) != m]
        self.assertEqual(bad, [])


# ── searchText: Swift `searchable` 의 필드 구성·소문자 처리를 엔진 카드 'text' 와 비교 ──
SEARCH_SAMPLES = [
    ['Price Page', '목표 Goal', 'Bob', 'Recent', 'Summary', '진행 중'],
    ['가격 페이지 › 후속', '정리 ÉCLAIR', '결제 Dev', '', 'ß İSTANBUL', 'Waiting'],
    ['🐰 TITLE', '', '하나 ONE', '둘째\n줄', '탭\t섞임', 'Needs attention'],
]
SEARCH_EXTRA = ['MISSION Text', '단계 Title']

SEARCH_HARNESS = '''import Foundation
struct C { var jobTitle = ""; var assignee = ""; var recent = ""; var summary = ""; var stateLabel = ""; var searchText = "" }
struct J { var goal: String? }
func searchable(_ c: C, _ j: J, _ extra: [String]) -> String {
    var c = c
%(line)s
    return c.searchText
}
@main struct Run {
    static func main() {
        let obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let out = obj.map { o -> String in
            let f = o["fields"] as! [String]
            let c = C(jobTitle: f[0], assignee: f[2], recent: f[3], summary: f[4], stateLabel: f[5])
            return searchable(c, J(goal: f[1]), o["extra"] as! [String])
        }
        print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
    }
}
'''


class SearchText(unittest.TestCase):
    LINE = re.search(r'c\.searchText = \(\[(.*?)\] \+ extra\)\.joined\(separator: " "\)\.lowercased\(\)', SWIFT)

    def test_field_order_matches_engine(self):
        """엔진 card() 의 text 필드(제목·목표·담당자·최근·요약·미션·단계·상태 한/영) 중 맥이 쓰는 것은 같은 순서의 부분집합이다."""
        self.assertIsNotNone(self.LINE, 'Swift searchable 의 searchText 식을 찾지 못했어요')
        mac = [x.strip() for x in self.LINE.group(1).split(',')]
        self.assertEqual(mac, ['c.jobTitle', 'j.goal ?? ""', 'c.assignee', 'c.recent', 'c.summary', 'c.stateLabel'])
        src = Path(bt.__file__).read_text(encoding='utf-8')
        eng = re.search(r"c\['text'\] = ' '\.join\(str\(x\) for x in \((.*?)\)\)\.lower\(\)", src, re.S).group(1)
        flat = ' '.join(eng.split())
        pos = [flat.index(k) for k in ("c['job_title']", "job.get('goal', '')", "c['assignee']", "c['recent']", "c['summary']")]
        self.assertEqual(pos, sorted(pos))
        # 알려진 차이(기록): 엔진은 상태 이름을 한글·영어 둘 다 넣고, 맥은 화면 언어 하나만 넣는다 — NOTES.md 참고
        self.assertIn("c['state'][0], c['state'][1]", ' '.join(eng.split()))

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc 가 없는 환경 — 맥 소스 실행 비교는 건너뜀')
    def test_lowercase_join_matches_engine(self):
        d = Path(TMP.name) / 'swift_search'
        d.mkdir(exist_ok=True)
        (d / 'main.swift').write_text(SEARCH_HARNESS % {'line': '    ' + self.LINE.group(0)}, encoding='utf-8')
        (d / 'in.json').write_text(json.dumps([{'fields': f, 'extra': SEARCH_EXTRA} for f in SEARCH_SAMPLES]), encoding='utf-8')
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / 'mc'))
        b = subprocess.run(['swiftc', '-parse-as-library', '-o', str(d / 'run'), str(d / 'main.swift')],
                           capture_output=True, text=True, env=env, timeout=300)
        self.assertEqual(b.returncode, 0, b.stderr[-2000:])
        r = subprocess.run([str(d / 'run'), str(d / 'in.json')], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        mac = json.loads(r.stdout)
        # 엔진 식과 같은 순서로 (제목·목표·담당자·최근·요약, 상태, 미션·단계) 이어 붙여 소문자로 — 단어 비교에는 순서가 영향을 주지 않는다
        for f, m in zip(SEARCH_SAMPLES, mac):
            eng = ' '.join(f[:5] + [f[5]] + SEARCH_EXTRA).lower()
            self.assertEqual(m, eng, f'맥 searchText ≠ 엔진: {f}')


if __name__ == '__main__':
    unittest.main()
