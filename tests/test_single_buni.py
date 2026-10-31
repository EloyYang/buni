"""스쿼드 작업 하나에는 부니가 하나만 — 지시를 여러 번 해도(팀장·팀원 claude 를 여러 번 불러도) 이벤트 파일·세션이 1개로 유지된다.
가짜 claude(스크립트)와 임시 BUNI_TEAM_HOME·BUNI_EVENTS_DIR 만 쓴다. 진짜 claude 는 부르지 않는다."""
import ast
import glob
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / 'windows'))

TMP = tempfile.TemporaryDirectory()
EVENTS = tempfile.mkdtemp(dir=TMP.name)
os.environ['BUNI_TEAM_HOME'] = TMP.name
os.environ['BUNI_EVENTS_DIR'] = EVENTS
import buni_team as bt  # noqa: E402

FAKE = '''#!/usr/bin/env python3
import json, os, sys
sys.stdin.read()
with open(os.environ["FAKE_ENV_LOG"], "a") as f:
    f.write(os.environ.get("BUNI_TEAM_RUN", "") + "\\n")
print(json.dumps({"type": "result", "result": "ok", "total_cost_usd": 0, "session_id": "x"}))
'''


def _events():
    return sorted(glob.glob(os.path.join(EVENTS, 'claude-companion-events-*.jsonl')))


class SingleBuni(unittest.TestCase):
    def setUp(self):
        for p in _events():
            os.remove(p)
        self.proj = tempfile.mkdtemp(dir=TMP.name)
        self.fake = os.path.join(TMP.name, 'fake_claude.py')
        with open(self.fake, 'w') as f:
            f.write(FAKE)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)
        self.envlog = os.path.join(TMP.name, 'env.log')
        if os.path.exists(self.envlog):
            os.remove(self.envlog)
        os.environ['FAKE_ENV_LOG'] = self.envlog
        os.environ['BUNI_CLAUDE'] = self.fake
        bt.save_settings({'model': '', 'lead_model': ''})
        self.job = bt.new_job('스쿼드', '목표', self.proj)
        bt.save_job(self.job)

    def _call(self, key, i):
        bt.ClaudeRunner().run('지시 %d' % i, self.proj, name='팀원 %d' % i,
                              track={'job_id': self.job['id'], 'key': key, 'label': f'🐰 스쿼드 · {key}{i}'})

    def test_repeated_instructions_keep_one_event_file_and_session(self):
        for i in range(4):
            self._call('lead' if i % 2 else 'dev', i)
        threads = [threading.Thread(target=self._call, args=('r%d' % i, i)) for i in range(3)]   # 병렬 팀원
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        files = _events()
        self.assertEqual([os.path.basename(p) for p in files],
                         [f"claude-companion-events-squad-{self.job['id']}.jsonl"])
        squads = [s for s in bt.load_sessions(self.job['id']) if s.get('key') == 'squad']
        self.assertEqual(len(squads), 1)
        self.assertEqual(squads[0]['id'], 'squad-' + self.job['id'])
        self.assertEqual(bt.find_job_for_session('squad-' + self.job['id']), self.job['id'])
        types = [json.loads(l)['type'] for l in open(files[0], encoding='utf-8')]
        self.assertEqual(types.count('tool_use'), 7)
        self.assertEqual(types[-1], 'done')

    def test_every_claude_call_is_marked_as_squad_run(self):
        for i in range(3):
            self._call('lead', i)
        self.assertEqual(open(self.envlog).read().split(), ['1', '1', '1'])

    def test_two_jobs_get_two_buni(self):
        other = bt.new_job('다른 스쿼드', '목표', self.proj)
        bt.save_job(other)
        self._call('lead', 0)
        bt.ClaudeRunner().run('x', self.proj, track={'job_id': other['id'], 'key': 'lead', 'label': '다른'})
        self.assertEqual(len(_events()), 2)

    def test_delete_removes_event_file(self):
        self._call('lead', 0)
        self.assertEqual(len(_events()), 1)
        bt.delete_job(self.job['id'])
        self.assertEqual(_events(), [])


class HooksSkipSquadRuns(unittest.TestCase):
    """스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 어느 훅도 이벤트를 적지 않는다 — 맥 파이썬 훅과 Windows exe 훅 모두."""

    def test_windows_exe_hook(self):
        tree = ast.parse((ROOT / 'windows' / 'buni.py').read_text(encoding='utf-8'))
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_run_hook')
        ns = {'sys': sys, 'os': os, 'json': json, 'time': __import__('time'), '_TEMP': Path(EVENTS),
              't': lambda a, b=None: a}
        exec(compile(ast.Module([fn], []), 'buni.py', 'exec'), ns)

        def run(env_on):
            ef = Path(EVENTS) / 'claude-companion-events-hooksid.jsonl'
            if ef.exists():
                ef.unlink()
            real_stdin, real_env = sys.stdin, os.environ.get('BUNI_TEAM_RUN')
            sys.stdin = type('S', (), {'buffer': io.BytesIO(json.dumps({'session_id': 'hooksid'}).encode())})()
            if env_on:
                os.environ['BUNI_TEAM_RUN'] = '1'
            else:
                os.environ.pop('BUNI_TEAM_RUN', None)
            try:
                ns['_run_hook']('prompt')
            except SystemExit:
                pass
            finally:
                sys.stdin = real_stdin
                if real_env is None:
                    os.environ.pop('BUNI_TEAM_RUN', None)
                else:
                    os.environ['BUNI_TEAM_RUN'] = real_env
            return ef.exists()

        self.assertTrue(run(False))        # 보통 세션은 이벤트를 적는다 (대조)
        self.assertFalse(run(True))        # 스쿼드 세션은 적지 않는다

    def test_mac_hook_scripts_have_the_skip(self):
        src = (ROOT / 'Sources' / 'ClaudeCompanion' / 'HookInstaller.swift').read_text(encoding='utf-8')
        scripts = re.findall(r'#"""\n(.*?)"""#', src, re.S)
        self.assertGreaterEqual(len(scripts), 5)
        for body in scripts:
            if 'claude-companion-events' not in body:
                continue
            self.assertIn('BUNI_TEAM_RUN', body)
            sid = 'squadhook' + str(abs(hash(body)))
            ef = Path('/tmp') / f'claude-companion-events-{sid}.jsonl'
            env = dict(os.environ, BUNI_TEAM_RUN='1')
            subprocess.run([sys.executable, '-c', body], input=json.dumps({'session_id': sid, 'tool_name': 'Read'}).encode(),
                           env=env, capture_output=True, timeout=20)
            self.assertFalse(ef.exists(), 'BUNI_TEAM_RUN 세션인데 이벤트를 적었어요')

    def test_windows_script_hooks_have_the_skip(self):
        src = (ROOT / 'windows' / 'install_hooks.py').read_text(encoding='utf-8')
        self.assertEqual(src.count('if _os.environ.get("BUNI_TEAM_RUN")'), 5)


if __name__ == '__main__':
    unittest.main()
