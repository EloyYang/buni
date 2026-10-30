#!/usr/bin/env python3
"""
시험 전용 — tests/license_vectors.json 을 (재)생성한다.
시험 키 쌍의 비밀 시드는 RFC 8032 시험 벡터 1번의 공개된 값이다. 절대 실제 판매에 쓰지 않는다.
시각은 고정(NOW)이라 결과가 항상 같다.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
import buni_license as lic  # noqa: E402

TEST_ONLY_SEED = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
NOW = 1_800_000_000          # 2027-01-15 08:00:00 UTC 근처
OTHER_SEED = bytes.fromhex('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb')


def upgrade_plan(key):
    """서명은 그대로 두고 페이로드의 플랜만 lifetime 으로 바꾼다 (형식은 여전히 올바름)."""
    body, sig = key[len(lic.PREFIX):].split('.')
    payload = lic.b64u_decode(body).decode('ascii').split('|')
    payload[1], payload[2] = 'lifetime', '0'
    return f'{lic.PREFIX}{lic.b64u_encode("|".join(payload).encode("ascii"))}.{sig}'


def flip_sig(key):
    """서명 첫 글자를 바꾼다."""
    body, sig = key[len(lic.PREFIX):].split('.')
    return f'{lic.PREFIX}{body}.{"B" if sig[0] == "A" else "A"}{sig[1:]}'


def main():
    good_pro = lic.make_key(TEST_ONLY_SEED, 'yearly', '20271231', 'buyer@example.com')
    good_life = lic.make_key(TEST_ONLY_SEED, 'lifetime')
    good_pack = lic.make_key(TEST_ONLY_SEED, 'pack:sakura')
    expired = lic.make_key(TEST_ONLY_SEED, 'monthly', '20260101')
    wrong_signer = lic.make_key(OTHER_SEED, 'lifetime')
    cases = [
        {'name': 'yearly_valid', 'key': good_pro, 'valid': True, 'plan': 'yearly', 'reason': ''},
        {'name': 'lifetime_valid', 'key': good_life, 'valid': True, 'plan': 'lifetime', 'reason': ''},
        {'name': 'pack_valid', 'key': good_pack, 'valid': True, 'plan': 'pack:sakura', 'reason': ''},
        {'name': 'expired', 'key': expired, 'valid': False, 'plan': 'monthly', 'reason': 'expired'},
        {'name': 'tampered_payload', 'key': upgrade_plan(expired), 'valid': False, 'plan': '', 'reason': 'signature'},
        {'name': 'tampered_signature', 'key': flip_sig(good_life), 'valid': False, 'plan': '', 'reason': 'signature'},
        {'name': 'signed_by_other_key', 'key': wrong_signer, 'valid': False, 'plan': '', 'reason': 'signature'},
        {'name': 'no_prefix', 'key': good_life[len(lic.PREFIX):], 'valid': False, 'plan': '', 'reason': 'format'},
        {'name': 'no_dot', 'key': good_life.replace('.', ''), 'valid': False, 'plan': '', 'reason': 'format'},
        {'name': 'garbage', 'key': 'BUNI-!!!.???', 'valid': False, 'plan': '', 'reason': 'format'},
        {'name': 'empty', 'key': '', 'valid': False, 'plan': '', 'reason': 'format'},
    ]
    out = {
        '_note': '시험 전용 벡터 — 맥(Swift)·Windows(Python)가 같은 파일로 검증한다. 실제 키가 아니다.',
        'public_key_hex': lic.public_from_seed(TEST_ONLY_SEED).hex(),
        'now': NOW,
        'cases': cases,
    }
    (HERE / 'license_vectors.json').write_text(json.dumps(out, indent=2, ensure_ascii=False) + '\n')
    print('wrote license_vectors.json')


if __name__ == '__main__':
    main()
