"""
맥 SquadBoard ↔ 엔진 보드 판정 자동 비교 시험 — python3 -m unittest tests/test_board_parity.py
엔진(windows/buni_team.py)의 board_column · board_filter 를 여러 가상 job 사례로 계산하고,
맥 SquadBoardViews.swift 의 `SquadBoard.column` · `filtered` 소스를 그대로 잘라 swiftc 로 컴파일해 같은 사례를 돌려 결과를 비교한다.
(맥 소스를 손으로 옮기지 않는다 — 소스가 바뀌면 이 시험이 바로 어긋남을 알린다. swiftc 가 없으면 건너뛴다.)
BUNI_TEAM_HOME 을 임시 폴더로 돌려 쓰고 실제 claude 는 부르지 않는다.
"""
import itertools
import json
import os
import re
import shutil
import subprocess
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

SWIFT_SRC = ROOT / 'Sources' / 'ClaudeCompanion' / 'SquadBoardViews.swift'

JOB_STATES = ('draft', 'interviewing', 'review_requirements', 'queued', 'running', 'waiting_limit',
              'paused', 'review', 'done', 'failed', 'cancelled')
ROLE_STATES = (None, 'pending', 'running', 'done_unreviewed', 'revise', 'accepted')


def _swift_pieces():
    src = SWIFT_SRC.read_text(encoding='utf-8')
    col = re.search(r'    static func column\(.*?\n    \}\n', src, re.S)
    flt = re.search(r'    private func filtered\(.*?\n    \}\n', src, re.S)
    less = re.search(r'    static func assigneeLess\(.*?\n    \}\n', src, re.S)
    assert less, 'SquadBoardViews.swift 에서 assigneeLess 를 찾지 못했어요'
    col = re.search(r'    static func column\(.*?\n    \}\n', src, re.S)
    col = type('M', (), {'group': lambda self, n=0, a=col, b=less: a.group(0) + b.group(0)})()
    cases = lambda name: re.search(r'enum %s\b[^{]*\{\s*case ([^\n]+)' % name, src).group(1)
    assert col and flt, 'SquadBoardViews.swift 에서 column/filtered 를 찾지 못했어요'
    return col.group(0), flt.group(0), cases('SquadColumn'), cases('SquadBoardScope'), cases('SquadBoardSort')


HARNESS = '''import Foundation
enum SquadColumn: String, CaseIterable, Hashable { case %(columns)s }
enum SquadBoardScope: String, CaseIterable { case %(scopes)s }
enum SquadBoardSort: String, CaseIterable { case %(sorts)s }
struct SquadItem { var id: String; var assigneeId: String; var assignee: String; var column: SquadColumn
                   var updated: Double; var since: Double; var searchText: String }
enum SquadBoard {
%(column)s}
struct Filt {
    var query = ""; var scope: SquadBoardScope = .all; var statusFilter: SquadColumn?
    var assigneeFilter = ""; var sort: SquadBoardSort = .recent
%(filtered)s}
@main struct Run {
    static func main() {
        let obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var cols: [String] = []
        for c in obj["columns"] as! [[String: Any]] {
            cols.append(SquadBoard.column(jobState: c["job"] as! String, roleStatus: c["role"] as? String).rawValue)
        }
        let items: [SquadItem] = (obj["cards"] as! [[String: Any]]).map { c in
            SquadItem(id: c["id"] as! String, assigneeId: c["assignee_id"] as! String, assignee: c["assignee"] as! String,
                      column: SquadColumn(rawValue: c["column"] as! String)!, updated: (c["updated"] as! NSNumber).doubleValue,
                      since: (c["since"] as! NSNumber).doubleValue, searchText: c["text"] as! String)
        }
        var filters: [[String]] = []
        for f in obj["filters"] as! [[String: Any]] {
            var m = Filt()
            m.query = f["query"] as! String
            m.scope = SquadBoardScope(rawValue: f["scope"] as! String)!
            m.statusFilter = (f["status"] as! String).isEmpty ? nil : SquadColumn(rawValue: f["status"] as! String)!
            m.assigneeFilter = f["assignee"] as! String
            m.sort = SquadBoardSort(rawValue: f["sort"] as! String)!
            filters.append(m.filtered(items).map { $0.id })
        }
        let out = try! JSONSerialization.data(withJSONObject: ["columns": cols, "filters": filters])
        print(String(data: out, encoding: .utf8)!)
    }
}
'''


def make_job(title, status, roles, states, updated, **extra):
    job = bt.new_job(title, f'{title} 목표', TMP.name)
    job['status'] = status
    job['updated'] = updated
    job['plan'] = {'summary': '', 'roles': [{'id': i, 'name': n, 'icon': '🧑‍💻', 'kind': 'code', 'mission': m, 'deliverable': '', 'depends_on': []}
                                            for i, n, m in roles]} if roles else None
    job['roles'] = {i: {'status': s, 'summary': f'{i} 요약\n둘째 줄'} for i, s in states.items()}
    job.update(extra)
    bt.save_job(job)
    return job


def build_cases():
    """대기·진행 중·검토·완료·확인 필요가 모두 나오는 가상 job 들 → 카드 → 필터 조합."""
    t = 1_700_000_000.0
    jobs = [
        make_job('가격 페이지', 'running', [('dev', '결제 개발자', '결제 흐름'), ('qa', '검증 담당', '시험'), ('doc', '문서 담당', '보고서')],
                 {'dev': 'running', 'qa': 'pending', 'doc': 'accepted'}, t + 10),
        make_job('마케팅 초안', 'running', [('mk', '마케팅 작가', '소개문'), ('rs', '시장조사원', '경쟁 가격')],
                 {'mk': 'done_unreviewed', 'rs': 'revise'}, t + 20),
        make_job('릴리스 점검', 'review', [('dev', '결제 개발자', '점검')], {'dev': 'done_unreviewed'}, t + 30),
        make_job('지난 업무', 'done', [('dev', '결제 개발자', '끝남')], {'dev': 'accepted'}, t + 40),
        make_job('한도 걸림', 'waiting_limit', [('mk', '마케팅 작가', '글'), ('dev', '결제 개발자', '코드')],
                 {'mk': 'running', 'dev': 'accepted'}, t + 50, error='사용 한도'),
        make_job('실패한 작업', 'failed', [('rs', '시장조사원', '조사')], {'rs': 'revise'}, t + 60, error='중간에 실패'),
        make_job('잠시 멈춤', 'paused', [('qa', '검증 담당', '시험')], {'qa': 'pending'}, t + 70),
        make_job('팀 없는 작업\n둘째 줄', 'queued', None, {}, t + 80),
        make_job('진행 중 팀 없음', 'running', None, {}, t + 90),
        make_job('취소됨', 'cancelled', [('qa', '검증 담당', '시험')], {'qa': 'running'}, t + 100),
        make_job('질문 답변', 'interviewing', None, {}, t + 110),
        make_job('실패 팀 없음', 'failed', None, {}, t + 120, error='시작 실패'),
    ]
    # 담당자순 비교용 — 한글·영문 혼합 이름, 대소문자 섞임, 같은 이름 여러 카드(안정 정렬), 악센트·이모지
    mixed = [('a1', 'alice', '검색 Alpha'), ('b1', 'Bob', 'Beta 검색'), ('c1', '가나다', 'GAMMA'), ('d1', 'Zed', 'zeta'),
             ('e1', '결제 Dev', 'Épsilon'), ('f1', 'dev 결제', '🐰 eta'), ('g1', 'Éclair', 'THETA'), ('h1', '하나 one', 'Iota')]
    for k in range(3):
        jobs.append(make_job(f'이름 섞임 {k}', 'running', mixed, {i: 'running' for i, _, _ in mixed}, t + 200 + k))
    # 시작 전 '다음에 할 일' — 대기 · 확인 필요(방향 변경) · 상한
    wu = {'review_items': [], 'next_steps': [
        {'id': 's1', 'title': '후속 정리', 'goal': '정리해요', 'why': '이어서', 'auto': 'off'},
        {'id': 's2', 'title': '가격 변경', 'goal': '가격 조정', 'why': '방향 변경', 'auto': 'confirm'},
        {'id': 's3', 'title': '세 번째', 'goal': '상한', 'why': '', 'auto': 'limit'}]}
    Path(bt.wrapup_path(jobs[0]['id'])).write_text(json.dumps(wu, ensure_ascii=False), encoding='utf-8')
    cards = bt.board_cards([bt.load_job(j['id']) for j in jobs], now=t + 1000)
    return cards


def build_filters(cards):
    assignees = [''] + sorted({c['assignee_id'] for c in cards})
    queries = ['', '결제', '  결제   목표 ', '없는말', 'DEV 요약', 'waiting',
               # 검색 규칙: 소문자 · 단어 구분(공백·탭·줄바꿈·전각 공백) · 한영 섞임 · 악센트 · 이모지
               'ALPHA', 'alpha\t검색', '검색\nbeta', '검색\u3000alpha', 'épsilon', 'ÉPSILON', '🐰', '🐰 ETA', 'dev 결제', '결제 dev',
               'Waiting 진행', '진행 중', 'In progress', 'running', '\t', '\n  \u3000', 'z 가']
    # 상태 이름은 한글·영어 둘 다 검색 대상 (화면 언어와 상관없다)
    queries += ['review', 'REVIEW', '검토', '검토 대기', 'ready to review', 'in review', 'Working', '작업 중', '다시 작업', 'revising',
                '통과', 'accepted', 'Needs attention', '확인 필요', '한도 대기', 'waiting (limit)', '거절함', 'Rejected', '질문 답변 중', 'answering']
    out = []
    for q, status, scope, sort in itertools.product(queries, ('',) + bt.BOARD_COLUMNS, bt.BOARD_SCOPES, bt.BOARD_SORTS):
        out.append({'query': q, 'status': status, 'assignee': '', 'scope': scope, 'sort': sort})
    for q, status in itertools.product(('', '검색', 'dev', 'e'), ('', 'running', 'ready')):    # 담당자순 + 검색 겹침
        out.append({'query': q, 'status': status, 'assignee': '', 'scope': 'all', 'sort': 'assignee'})
    for a, scope, sort in itertools.product(assignees, bt.BOARD_SCOPES, bt.BOARD_SORTS):
        out.append({'query': '', 'status': '', 'assignee': a, 'scope': scope, 'sort': sort})
        out.append({'query': '결제', 'status': 'running', 'assignee': a, 'scope': scope, 'sort': sort})
    return out


class BoardParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cards = build_cases()
        cls.filters = build_filters(cls.cards)
        cls.columns = [{'job': j, 'role': r} for j in JOB_STATES for r in ROLE_STATES]
        cls.swift = None
        if shutil.which('swiftc'):
            cls.swift = cls._run_swift()

    @classmethod
    def _run_swift(cls):
        col, flt, columns, scopes, sorts = _swift_pieces()
        d = Path(TMP.name) / 'swift'
        d.mkdir(exist_ok=True)
        (d / 'main.swift').write_text(HARNESS % {'columns': columns, 'scopes': scopes, 'sorts': sorts, 'column': col, 'filtered': flt.replace('private func', 'func', 1)},
                                      encoding='utf-8')
        fields = ('id', 'assignee_id', 'assignee', 'column', 'updated', 'since', 'text')
        (d / 'in.json').write_text(json.dumps({'columns': cls.columns, 'filters': cls.filters,
                                               'cards': [{k: c[k] for k in fields} for c in cls.cards]}), encoding='utf-8')
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(d / 'mc'))
        b = subprocess.run(['swiftc', '-parse-as-library', '-o', str(d / 'run'), str(d / 'main.swift')],
                           capture_output=True, text=True, env=env, timeout=300)
        if b.returncode:
            raise AssertionError('맥 판정 소스를 컴파일하지 못했어요:\n' + b.stderr[-2000:])
        r = subprocess.run([str(d / 'run'), str(d / 'in.json')], capture_output=True, text=True, timeout=120)
        if r.returncode:
            raise AssertionError('맥 판정 실행 실패:\n' + r.stderr[-2000:])
        return json.loads(r.stdout)

    def test_cases_cover_every_column(self):
        got = {c['column'] for c in self.cards}
        self.assertEqual(got, set(bt.BOARD_COLUMNS), '대기·진행 중·검토·완료·확인 필요 사례가 모두 있어야 해요')
        kinds = {c['kind'] for c in self.cards}
        self.assertEqual(kinds, {'task', 'job', 'next'})          # 업무(task) 카드 — 팀원이 아니라 내가 지시한 업무마다 한 장
        self.assertGreater(len(self.filters), 100)

    def test_filter_cases_are_not_trivial(self):
        res = [[c['id'] for c in bt.board_filter(self.cards, **f)] for f in self.filters]
        self.assertTrue(any(len(r) == 0 for r in res))
        self.assertTrue(any(0 < len(r) < len(self.cards) for r in res))
        self.assertTrue(any(len(r) == len(self.cards) for r in res))

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc 가 없는 환경 — 맥 판정 비교는 건너뜀')
    def test_column_matches_mac(self):
        bad = []
        for c, mac in zip(self.columns, self.swift['columns']):
            eng = bt.board_column(c['job'], c['role'])
            if eng != mac:
                bad.append(f"{c['job']}/{c['role']}: 엔진 {eng} ≠ 맥 {mac}")
        self.assertEqual(bad, [], '맥 SquadBoard.column 이 엔진 board_column 과 달라요')

    def test_assignee_sort_cases_are_mixed(self):
        names = [c['assignee'] for c in bt.board_filter(self.cards, sort='assignee')]
        self.assertTrue(any(re.search('[가-힣]', n) for n in names) and any(re.fullmatch('[A-Za-z]+', n) for n in names))
        self.assertTrue(any(n.isupper() or n[:1].isupper() for n in names) and any(n[:1].islower() for n in names))
        self.assertGreater(len(names) - len(set(names)), 3, '같은 이름 카드가 여러 장 있어야 안정 정렬을 볼 수 있어요')
        self.assertLess(names.index('alice'), names.index('Bob'))                          # 대소문자 무시
        self.assertLess(names.index('Zed'), names.index('가나다'))                          # 영문 → 한글
        self.assertLess(names.index('Éclair'), names.index('가나다'))

    def test_search_cases_are_not_trivial(self):
        for q in ('ALPHA', 'alpha\t검색', '검색\u3000alpha', 'ÉPSILON', '🐰 ETA', 'In review', 'running', '\t'):
            self.assertTrue(bt.board_filter(self.cards, query=q), f'{q!r} 는 엔진에서 결과가 있어야 해요')
        self.assertEqual(bt.board_filter(self.cards, query='z 가'), [])

    def test_state_name_search_korean_and_english(self):
        """영어 'review' · 한글 '검토' 어느 쪽으로 쳐도 상태 이름이 검토인 카드가 나온다 (한·영 짝은 같은 카드)."""
        ids = lambda q: {c['id'] for c in bt.board_filter(self.cards, query=q)}
        self.assertTrue(ids('review') and ids('검토'))
        pairs = sorted({(c['state'][0], c['state'][1].lower()) for c in self.cards})       # 카드가 업무 단위로 바뀌어도 있는 상태 이름 전부
        self.assertGreaterEqual(len(pairs), 4)
        self.assertTrue(any(en == 'in review' for _ko, en in pairs))
        for ko, en in pairs:
            by_state = {c['id'] for c in self.cards if c['state'][0] == ko and c['state'][1].lower() == en}
            self.assertTrue(by_state, f'{ko}/{en} 사례 카드가 있어야 해요')
            self.assertTrue(by_state <= ids(ko) and by_state <= ids(en), f'{ko}/{en}: 한글·영어 검색에 같은 카드가 나와야 해요')
        for c in self.cards:                 # 어느 카드든 자기 상태 이름(한·영)으로 찾을 수 있다
            for name in c['state']:
                self.assertIn(c['id'], ids(name), f"{c['id']}: {name!r} 로 찾아져야 해요")

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc 가 없는 환경 — 맥 판정 비교는 건너뜀')
    def test_filter_matches_mac(self):
        bad = []
        for f, mac in zip(self.filters, self.swift['filters']):
            eng = [c['id'] for c in bt.board_filter(self.cards, **f)]
            if eng != mac:
                bad.append(f'{f}: 엔진 {eng} ≠ 맥 {mac}')
        self.assertEqual(bad, [], '맥 filtered 가 엔진 board_filter 와 달라요 (%d건)' % len(bad))


if __name__ == '__main__':
    unittest.main()
