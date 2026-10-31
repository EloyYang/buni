"""진짜 claude 로 첨부 Read 허용 목록을 확인하는 실측 시험 — 기본은 건너뛴다 (BUNI_REAL_CLAUDE=1 일 때만, 네트워크·로그인 필요).
첨부 폴더에 작은 파일을 두고 `claude -p --permission-mode dontAsk` + `Read(//절대경로/**)` 로 읽히는지 본다."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'windows'))


@unittest.skipUnless(os.environ.get('BUNI_REAL_CLAUDE') == '1', '진짜 claude 실측 — BUNI_REAL_CLAUDE=1 일 때만')
class RealClaudeAttachRead(unittest.TestCase):
    def test_attachment_is_readable_under_dontask(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.environ.pop('BUNI_CLAUDE', None)
            os.environ['BUNI_TEAM_HOME'] = tmp + '/home'
            import buni_team as bt
            proj = tmp + '/proj'
            os.makedirs(proj)
            job = bt.new_job('p', 'g', proj)
            bt.save_job(job)
            att = bt.attachments_dir(job['id'])
            os.makedirs(att)
            with open(att + '/메모 test.txt', 'w', encoding='utf-8') as f:
                f.write('비밀 토큰은 ZEBRA-4417 입니다.\n')
            out = bt.ClaudeRunner(bt.load_settings()).run(
                f'첨부 파일 {att}/메모 test.txt 를 Read 도구로 읽고 안에 적힌 토큰만 답하세요.', proj,
                role_kind='readonly', slug='probe', name='probe', timeout=150,
                track={'job_id': job['id'], 'key': 'probe', 'label': 'probe'})
            self.assertIn('ZEBRA-4417', out['result'])
            self.assertEqual(out['denials'], [])


if __name__ == '__main__':
    unittest.main()
