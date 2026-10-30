#!/usr/bin/env python3
"""
부니 라이선스 키 발급 도구 (판매자 본인 PC에서만 쓴다).

    python3 tools/issue_license.py keygen --out ~/buni-license-secret.key
    python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan yearly --days 365 --email a@b.com
    python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan lifetime
    python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan pack:sakura
    python3 tools/issue_license.py verify --pubkey <hex> BUNI-....

비밀키 파일은 저장소 밖에 보관한다(이 도구는 저장소 안 경로에는 쓰기를 거부한다).
자세한 설명은 tools/README.md.
"""
import argparse
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'windows'))
import buni_license as lic  # noqa: E402


def _inside_repo(path: Path) -> bool:
    try:
        path.resolve().relative_to(REPO)
        return True
    except ValueError:
        return False


def _read_seed(path: str) -> bytes:
    raw = bytes.fromhex(Path(path).expanduser().read_text().strip())
    if len(raw) != 32:
        sys.exit('비밀키 파일 형식이 틀렸습니다 (hex 64자여야 합니다).')
    return raw


def cmd_keygen(args):
    out = Path(args.out).expanduser()
    if _inside_repo(out):
        sys.exit('저장소 안에는 비밀키를 저장하지 않습니다. 저장소 밖 경로를 쓰세요.')
    if out.exists():
        sys.exit(f'{out} 가 이미 있습니다. 덮어쓰지 않습니다.')
    seed = secrets.token_bytes(32)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(seed.hex() + '\n')
    print(f'비밀키 저장: {out}  (절대 공유·커밋 금지)')
    print(f'공개키(hex): {lic.public_from_seed(seed).hex()}')
    print('→ windows/buni_license.py 의 PUBLIC_KEY_HEX 와 맥 ProLicense.swift 의 publicKeyHex 에 넣으세요.')


def cmd_issue(args):
    plan = args.plan
    if plan not in lic.PRO_PLANS and not plan.startswith('pack:'):
        sys.exit('plan 은 monthly · yearly · lifetime · pack:<id> 중 하나여야 합니다.')
    if plan == 'lifetime' and args.days:
        sys.exit('lifetime 은 --days 를 쓰지 않습니다.')
    expires = '0'
    if args.days:
        end = datetime.now(timezone.utc) + timedelta(days=args.days)
        expires = end.strftime('%Y%m%d')
    elif args.expires:
        expires = args.expires
    key = lic.make_key(_read_seed(args.secret), plan, expires, args.email or '')
    print(key)


def cmd_verify(args):
    pub = bytes.fromhex(args.pubkey) if args.pubkey else None
    r = lic.verify_key(args.key, pubkey=pub)
    if r.valid:
        print(f'유효: plan={r.plan} 만료={r.expires or "없음"}')
    else:
        print(f'무효: {r.reason}')
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description='부니 라이선스 키 발급')
    sub = ap.add_subparsers(dest='cmd', required=True)

    k = sub.add_parser('keygen', help='새 키 쌍 만들기 (비밀키는 파일로, 공개키는 화면에)')
    k.add_argument('--out', required=True, help='비밀키를 저장할 파일 (저장소 밖)')
    k.set_defaults(fn=cmd_keygen)

    i = sub.add_parser('issue', help='라이선스 키 하나 발급')
    i.add_argument('--secret', required=True, help='비밀키 파일')
    i.add_argument('--plan', required=True)
    i.add_argument('--days', type=int, help='오늘부터 N일 뒤까지 유효 (월 구독 31, 연 366 등)')
    i.add_argument('--expires', help='만료일 YYYYMMDD (UTC, 그날 끝까지)')
    i.add_argument('--email', help='구매자 이메일 (해시 16자리만 키에 들어감)')
    i.set_defaults(fn=cmd_issue)

    v = sub.add_parser('verify', help='키 확인')
    v.add_argument('--pubkey', help='공개키 hex (생략하면 앱 내장값/환경변수)')
    v.add_argument('key')
    v.set_defaults(fn=cmd_verify)

    args = ap.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
