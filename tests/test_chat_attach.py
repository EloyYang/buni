"""스쿼드 채팅 첨부 — 파일 복사·이름 충돌·경로 거부·개수/크기/종류 상한·비밀 파일 경고·프롬프트의 절대경로·읽기 허용 규칙.
가짜 claude(BUNI_CLAUDE)와 임시 BUNI_TEAM_HOME 만 쓴다. 진짜 claude 는 부르지 않는다."""
import json
import os
import re
import stat
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / 'windows'))
sys.path.insert(0, str(HERE))

import buni_team as bt  # noqa: E402
from test_fake_claude_flow import FakeClaudeBase  # noqa: E402

# 가짜 claude — 받은 프롬프트(stdin)와 인자를 FAKE_LOG 에 적는다. 팀장(채팅)에게는 첫 팀원 'a' 에게 지시하는 답을 낸다.
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
name = a[a.index('--name') + 1] if '--name' in a else ''
prompt = sys.stdin.read()
with open(os.environ['FAKE_LOG'], 'a', encoding='utf-8') as f:
    f.write(json.dumps({'name': name, 'argv': a, 'prompt': prompt}, ensure_ascii=False) + '\n')
out = '작업을 마쳤어요.'
if '팀장(검토)' in name:
    out = json.dumps({'verdicts': [], 'summary': ''})
elif '팀장(정리)' in name:
    out = json.dumps({'review_items': [], 'next_steps': []})
elif '팀장(채팅)' in name:
    out = json.dumps({'reply': '확인했어요', 'requirements': {'add': [], 'change': []}, 'new_roles': [],
                      'assignments': [{'role': 'a', 'instruction': '첨부한 시안대로 고치세요'}]})
print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': out,
                  'total_cost_usd': 0.0, 'session_id': 'fake'}))
'''


class AttachBase(FakeClaudeBase):
    def setUp(self):
        super().setUp()
        exe = Path(os.environ['BUNI_CLAUDE'])
        exe.write_text(FAKE, encoding='utf-8')
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
        bt.save_settings({'auto_followup': False, 'model': '', 'lead_model': ''})
        self.job = self.make_job([('a', ''), ('b', '')])
        self.jid = self.job['id']
        self.src = Path(self.tmp.name) / 'src'
        self.src.mkdir()

    def mk(self, name, data=b'x', size=None):
        p = self.src / name
        if size is not None:
            with open(p, 'wb') as f:
                f.truncate(size)                       # 실제로 쓰지 않는 큰 파일
        else:
            p.write_bytes(data)
        return str(p)

    def chat(self):
        return bt.load_chat(self.jid)

    def att_files(self):
        d = Path(bt.attachments_dir(self.jid))
        return sorted(p.name for p in d.iterdir()) if d.is_dir() else []


class StoreAttachments(AttachBase):
    def test_copy_records_and_name_collision(self):
        a = self.mk('시안.png', b'\x89PNG')
        recs, warns = bt.store_attachments(self.jid, [a, a])
        self.assertEqual(warns, [])
        self.assertEqual([r['name'] for r in recs], ['시안.png', '시안 (2).png'])
        self.assertEqual(recs[0], {'name': '시안.png', 'path': 'attachments/시안.png', 'kind': 'image', 'size': 4})
        self.assertEqual(self.att_files(), ['시안 (2).png', '시안.png'])
        again, _ = bt.store_attachments(self.jid, [a])                 # 나중에 보낸 같은 이름도 덮어쓰지 않는다
        self.assertEqual(again[0]['name'], '시안 (3).png')
        self.assertEqual(Path(bt.attachment_path(self.jid, recs[0]['path'])).read_bytes(), b'\x89PNG')

    def test_kind_by_extension(self):
        recs, _ = bt.store_attachments(self.jid, [self.mk('a.md'), self.mk('b.JPG')])
        self.assertEqual([r['kind'] for r in recs], ['file', 'image'])

    def test_stored_record_is_not_copied_again(self):
        recs, _ = bt.store_attachments(self.jid, [self.mk('a.txt')])
        again, _ = bt.store_attachments(self.jid, recs)
        self.assertEqual(again[0]['path'], recs[0]['path'])
        self.assertEqual(self.att_files(), ['a.txt'])


class Rejections(AttachBase):
    def test_path_outside_attachments_is_rejected(self):
        outside = Path(self.tmp.name) / 'secret.txt'
        outside.write_text('x')
        bt.store_attachments(self.jid, [self.mk('ok.txt')])
        for rel in ('../job.json', 'attachments/../job.json', '/etc/passwd', str(outside), 'attachments/', 'attachments', '',
                    'attachments/없는파일.txt', 'attachments\\..\\job.json'):
            self.assertEqual(bt.attachment_path(self.jid, rel), '', rel)
        link = Path(bt.attachments_dir(self.jid)) / 'link.txt'            # 폴더 안 심볼릭 링크가 밖을 가리켜도 거부
        try:
            link.symlink_to(outside)
        except OSError:
            self.skipTest('심볼릭 링크를 만들 수 없는 환경')
        self.assertEqual(bt.attachment_path(self.jid, 'attachments/link.txt'), '')
        with self.assertRaises(ValueError):                                  # 보관된 기록인 척해도 밖이면 거부
            bt.store_attachments(self.jid, [{'name': 'x', 'path': '../job.json'}])

    def test_too_many(self):
        files = [self.mk(f'f{i}.txt') for i in range(bt.ATTACH_MAX_FILES + 1)]
        with self.assertRaises(ValueError) as cm:
            bt.store_attachments(self.jid, files)
        self.assertEqual(str(cm.exception), bt.ATTACH_TOO_MANY)
        self.assertEqual(self.att_files(), [])
        recs, _ = bt.store_attachments(self.jid, files[:bt.ATTACH_MAX_FILES])   # 상한 딱 맞으면 된다
        self.assertEqual(len(recs), 5)

    def test_too_big_names_reason_and_copies_nothing(self):
        ok = self.mk('ok.txt')
        big = self.mk('큰파일.pdf', size=bt.ATTACH_MAX_BYTES + 1)
        with self.assertRaises(ValueError) as cm:
            bt.store_attachments(self.jid, [ok, big])
        self.assertIn('큰파일.pdf', str(cm.exception))
        self.assertIn('20MB', str(cm.exception))
        self.assertEqual(self.att_files(), [])                                # 하나라도 안 되면 다 복사하지 않는다
        bt.store_attachments(self.jid, [self.mk('edge.pdf', size=bt.ATTACH_MAX_BYTES)])   # 정확히 20MB 는 된다

    def test_kind_and_folder_and_missing(self):
        for name in ('run.exe', 'a.dmg'):
            with self.assertRaisesRegex(ValueError, '실행 파일'):
                bt.store_attachments(self.jid, [self.mk(name)])
        with self.assertRaisesRegex(ValueError, '지원하지 않는 종류'):
            bt.store_attachments(self.jid, [self.mk('noext')])
        with self.assertRaisesRegex(ValueError, '폴더'):
            bt.store_attachments(self.jid, [str(self.src)])
        with self.assertRaisesRegex(ValueError, '찾지 못했어요'):
            bt.store_attachments(self.jid, [str(self.src / 'nope.txt')])

    def test_secret_like_names_warn_but_go_through(self):
        names = ['.env', '.env.local', 'server.pem', 'id_rsa', 'my-credentials.json']
        for n in names:
            kind, size, warn = bt.attach_check(self.mk(n))
            self.assertIn('비밀값', warn, n)
        for n in ('plain.txt', '시안.png', 'screenshot.png'):
            self.assertEqual(bt.attach_check(self.mk(n))[2], '', n)
        recs, warns = bt.store_attachments(self.jid, [self.mk('.env'), self.mk('plain.txt')])
        self.assertEqual([r['name'] for r in recs], ['.env', 'plain.txt'])
        self.assertEqual(len(warns), 1)

    def test_warning_shows_in_chat(self):
        bt.send_role_note(self.jid, 'a', '키 파일 참고', attachments=[self.mk('credentials.json')])
        warn = [m for m in self.chat() if m['kind'] == 'status' and '비밀값' in m['text']]
        self.assertEqual(len(warn), 1)
        self.assertEqual(self.att_files(), ['credentials.json'])


class PromptsAndPermissions(AttachBase):
    def test_read_rule_format(self):
        self.assertEqual(bt.read_rule('/Users/me/x/attachments'), 'Read(//Users/me/x/attachments/**)')
        if os.name == 'nt':
            self.assertEqual(bt.read_rule('C:\\Users\\me\\a'), 'Read(//c/Users/me/a/**)')
        allowed, _ = bt.permission_args('readonly', 's', False, ('/p/att',))
        self.assertIn('Read(//p/att/**)', allowed)
        allowed, _ = bt.permission_args('readonly', 's', False)
        self.assertFalse([a for a in allowed if a.startswith('Read(')])      # 첨부가 없으면 규칙을 늘리지 않는다

    def test_read_rule_keeps_spaces_and_is_one_argv_item(self):
        # 앱 데이터 폴더는 'Application Support' 처럼 공백이 있다 — 규칙 문자열에 그대로 들어가고 argv 한 칸으로 넘어간다
        d = '/Users/me/Library/Application Support/Buni/team/jobs/j1/attachments'
        self.assertEqual(bt.read_rule(d), 'Read(//Users/me/Library/Application Support/Buni/team/jobs/j1/attachments/**)')
        self.assertEqual(bt.read_rule(d + '/'), bt.read_rule(d))               # 끝 슬래시는 한 번만
        allowed, denied = bt.permission_args('code', 's', False, (d,))
        self.assertEqual([a for a in allowed if a.startswith('Read(//')], [bt.read_rule(d)])
        self.assertFalse([x for x in denied if x.startswith('Read(')])        # 금지 목록에는 Read 규칙을 넣지 않는다

    def test_lead_chat_prompt_paths_permission_and_forwarding(self):
        png = self.mk('시안.png', b'\x89PNG')
        res = bt.chat_send(self.jid, 'lead', '이 시안 봐 주세요', attachments=[png])
        self.assertTrue(res['ok'], res)
        full = bt.attachment_path(self.jid, 'attachments/시안.png')
        self.assertTrue(os.path.isabs(full))
        msgs = self.chat()
        user = next(m for m in msgs if m['from'] == 'user')
        self.assertEqual(user['attachments'], [{'name': '시안.png', 'path': 'attachments/시안.png', 'kind': 'image', 'size': 4}])
        call = next(c for c in self.calls() if '팀장(채팅)' in c['name'])
        self.assertIn(full, call['prompt'])                                   # 팀장 프롬프트에 절대경로
        argv = call['argv']
        self.assertEqual(argv[argv.index('--add-dir') + 1], bt.attachments_dir(self.jid))
        rule = bt.read_rule(bt.attachments_dir(self.jid))
        self.assertIn(rule, argv[argv.index('--allowedTools') + 1].split(','))   # dontAsk 허용 목록에 첨부 폴더 읽기
        self.assertIn('dontAsk', argv)
        # 팀장이 지시한 팀원 a 에게만 첨부가 같이 간다
        notes_a = bt.load_job(self.jid)['roles']['a']['notes']
        self.assertEqual(notes_a[0]['attachments'][0]['path'], 'attachments/시안.png')
        self.assertNotIn('notes', bt.load_job(self.jid)['roles']['b'])
        self.assertEqual(self.att_files(), ['시안.png'])                      # 팀원에게 전달할 때 다시 복사하지 않는다
        # 팀원이 일할 때 프롬프트에도 경로가 들어 있다
        self.calls_before = len(self.calls())
        self.run_job(self.jid)
        worker = next(c for c in self.calls()[self.calls_before:] if c['name'].endswith('팀원a'))
        self.assertIn(full, worker['prompt'])
        self.assertIn('Read', worker['prompt'])
        other = next(c for c in self.calls()[self.calls_before:] if c['name'].endswith('팀원b'))
        self.assertNotIn(full, other['prompt'])
        self.assertIn(bt.read_rule(bt.attachments_dir(self.jid)), worker['argv'][worker['argv'].index('--allowedTools') + 1].split(','))

    def test_dm_goes_only_to_that_member(self):
        bt.chat_send(self.jid, 'b', '이 문서 참고', attachments=[self.mk('명세.md', b'# hi')])
        job = bt.load_job(self.jid)
        self.assertEqual(job['roles']['b']['notes'][0]['attachments'][0]['name'], '명세.md')
        self.assertNotIn('notes', job['roles']['a'])
        m = next(m for m in self.chat() if m['to'] == 'b' and m['kind'] == 'user')
        self.assertEqual(m['attachments'][0]['path'], 'attachments/명세.md')
        self.assertFalse([c for c in self.calls() if '팀장(채팅)' in c['name']])      # 팀장은 부르지 않는다

    def test_attachment_only_message_and_failure_sends_nothing(self):
        bt.send_role_note(self.jid, 'a', '', attachments=[self.mk('a.txt')])
        self.assertEqual(self.chat()[0]['text'], bt.ATTACH_ONLY_NOTE)
        n = len(self.chat())
        with self.assertRaises(ValueError):
            bt.send_role_note(self.jid, 'a', '큰 파일', attachments=[self.mk('z.zip', size=bt.ATTACH_MAX_BYTES + 5)])
        with self.assertRaises(ValueError):
            bt.chat_send(self.jid, 'lead', '실행 파일', attachments=[self.mk('x.exe')])
        self.assertEqual(len(self.chat()), n)                                      # 거부되면 채팅에도 기록하지 않는다
        self.assertEqual(len(bt.load_job(self.jid)['roles']['a']['notes']), 1)
        with self.assertRaises(ValueError):
            bt.chat_send(self.jid, 'lead', '', attachments=[])                      # 글도 첨부도 없으면 거부

    def test_no_attachments_means_no_extra_args(self):
        bt.chat_send(self.jid, 'lead', '그냥 질문')
        call = next(c for c in self.calls() if '팀장(채팅)' in c['name'])
        self.assertNotIn('--add-dir', call['argv'])
        self.assertNotIn('[첨부 파일', call['prompt'])

    def test_cli_attach_option(self):
        p = Path(self.tmp.name) / 'note.txt'
        p.write_text('지시', encoding='utf-8')
        out = Path(self.tmp.name) / 'out.txt'
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bt.main(['role-note', self.jid, 'a', '--text-file', str(p), '--attach', self.mk('c.csv', b'1,2')])
        self.assertEqual(bt.load_job(self.jid)['roles']['a']['notes'][0]['attachments'][0]['name'], 'c.csv')
        out.write_text(buf.getvalue())

    def test_review_feedback_bad_attachment_keeps_item_state(self):
        wu = {'review_items': [{'id': 'r1', 'title': '화면', 'kind': 'file', 'target': 'a.md'}], 'next_steps': []}
        Path(bt.wrapup_path(self.jid)).write_text(json.dumps(wu), encoding='utf-8')
        with self.assertRaises(ValueError):
            bt.review_feedback(self.jid, 'r1', 'fix', '고쳐 주세요', attachments=[self.mk('x.exe')])
        self.assertNotIn('review', bt.load_wrapup(self.jid)['review_items'][0])
        bt.review_feedback(self.jid, 'r1', 'fix', '이 시안대로', attachments=[self.mk('s.png', b'1')])
        self.assertTrue(re.search('s.png', json.dumps(self.chat(), ensure_ascii=False)))


class TrayWidget(AttachBase):
    """Windows 첨부 칩 줄(Tk) — 화면을 띄울 수 없는 환경이면 건너뛴다."""

    def test_tray_add_remove_limits(self):
        try:
            import tkinter as tk
        except ImportError:
            self.skipTest('이 파이썬에는 Tk 가 없어요')
        try:
            root = tk.Tk()
        except tk.TclError:
            self.skipTest('Tk 화면을 열 수 없는 환경')
        try:
            import buni_team_ui as ui
            store = []
            tray = ui.AttachTray(root, store, lambda ko, en=None: ko)
            tray.add([self.mk('a.png'), self.mk('b.txt'), self.mk('run.exe')])
            self.assertEqual([os.path.basename(p) for p in store], ['a.png', 'b.txt'])      # 실행 파일은 못 올린다
            self.assertIn('실행 파일', tray.err.cget('text'))
            tray.add([self.mk('a.png')])                                                      # 같은 파일 두 번은 한 번만
            self.assertEqual(len(store), 2)
            tray.add([self.mk(f'f{i}.txt') for i in range(6)])
            self.assertEqual(len(store), bt.ATTACH_MAX_FILES)
            self.assertIn(bt.ATTACH_TOO_MANY, tray.err.cget('text'))
            tray.remove(store[0])
            self.assertEqual(len(store), bt.ATTACH_MAX_FILES - 1)
            self.assertEqual(len(tray.take()), bt.ATTACH_MAX_FILES - 1)
            self.assertEqual(store, [])
        finally:
            root.destroy()


class MacWindowsParity(unittest.TestCase):
    """맥(TeamAttach.swift)과 엔진·Windows 의 상한·종류·문구가 같다 — 한쪽만 고치면 여기서 걸린다."""

    @classmethod
    def setUpClass(cls):
        cls.swift = (ROOT / 'Sources' / 'ClaudeCompanion' / 'TeamAttach.swift').read_text(encoding='utf-8')

    def _set(self, name):
        body = re.search(rf'static let {name}: Set<String> = \[(.*?)\]', self.swift, re.S).group(1)
        return set(re.findall(r'"([^"]+)"', body))

    def test_limits_and_kinds(self):
        self.assertEqual(int(re.search(r'static let maxFiles = (\d+)', self.swift).group(1)), bt.ATTACH_MAX_FILES)
        self.assertEqual(eval(re.search(r'static let maxBytes = ([\d* ]+)', self.swift).group(1)), bt.ATTACH_MAX_BYTES)
        strip = lambda t: {e.lstrip('.') for e in t}
        self.assertEqual(self._set('imageExt'), strip(bt.ATTACH_IMAGE_EXT))
        self.assertEqual(self._set('fileExt'), strip(bt.ATTACH_FILE_EXT))
        self.assertEqual(self._set('blockedExt'), strip(bt.ATTACH_BLOCKED_EXT))

    def test_secret_pattern_is_identical(self):
        pat = re.search(r'pattern: #"(.*?)"#', self.swift, re.S).group(1)
        self.assertEqual(pat, bt.ATTACH_SECRET_RE.pattern)

    def test_messages_match(self):
        for msg in ("'\\(name)' 은(는) 폴더라서 첨부할 수 없어요 (파일만 가능해요)",
                    "'\\(name)' 은(는) 실행 파일이라 첨부할 수 없어요",
                    "'\\(name)' 은(는) 지원하지 않는 종류예요 (이미지·문서·코드·텍스트 파일만 가능해요)",
                    "'\\(name)' 파일을 찾지 못했어요",
                    "'\\(name)' 은(는) 비밀값(키·비밀번호)이 들어 있을 수 있는 파일 이름이에요 — 보내도 되는지 확인하세요"):
            self.assertIn(msg, self.swift)
        py = (ROOT / 'windows' / 'buni_team.py').read_text(encoding='utf-8')
        for msg in ("은(는) 폴더라서 첨부할 수 없어요 (파일만 가능해요)", "은(는) 실행 파일이라 첨부할 수 없어요",
                    "은(는) 지원하지 않는 종류예요 (이미지·문서·코드·텍스트 파일만 가능해요)", "파일을 찾지 못했어요",
                    "은(는) 비밀값(키·비밀번호)이 들어 있을 수 있는 파일 이름이에요 — 보내도 되는지 확인하세요", "라서 너무 커요 (파일당 최대"):
            self.assertIn(msg, py)
            self.assertIn(msg, self.swift)
        self.assertIn('한 번에 최대 \\(maxFiles)개까지 첨부할 수 있어요', self.swift)
        self.assertEqual(bt.ATTACH_TOO_MANY, '한 번에 최대 5개까지 첨부할 수 있어요')

    def test_both_uis_pass_attachments_for_all_rooms(self):
        ui = (ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        for call in ("chat_send(job['id'], 'lead', text, attachments=files)",
                     "send_role_note(job['id'], who, text, attachments=files)",
                     "review_feedback(job['id'], item_id, 'fix', text, attachments=list(files))"):
            self.assertIn(call, ui)
        views = (ROOT / 'Sources' / 'ClaudeCompanion' / 'SquadSlackViews.swift').read_text(encoding='utf-8')
        self.assertIn('store.sendChat(job, to: "lead", text: text, files: files)', views)
        self.assertIn('store.sendRoleNote(job, role: who, text: text, files: files)', views)
        self.assertIn('files: files', (ROOT / 'Sources' / 'ClaudeCompanion' / 'TeamViews.swift').read_text(encoding='utf-8'))

    def test_pending_attachments_never_touch_draft_saving(self):
        """보내기 전 첨부 목록은 메모리에만 — draft 저장(디스크)과 섞이지 않아 입력이 느려지지 않는다."""
        ui = (ROOT / 'windows' / 'buni_team_ui.py').read_text(encoding='utf-8')
        tray = ui[ui.index('class AttachTray'):ui.index('def show_image_large')]
        self.assertNotIn('save_draft', tray)
        self.assertNotIn('json.dump', tray)
        self.assertNotIn('save_draft', self.swift)


if __name__ == '__main__':
    unittest.main()
