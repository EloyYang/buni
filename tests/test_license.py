"""
라이선스 검증 시험 — python3 tests/test_license.py   (표준 라이브러리 unittest만 사용)

시험 전용 키 쌍(RFC 8032 공개 시험 시드)을 쓴다. 실제 판매 키와 무관하다.
tests/license_vectors.json 이 있으면 맥(Swift)과 같은 벡터도 함께 검증한다.
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
import buni_license as lic  # noqa: E402

TEST_ONLY_SEED = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
TEST_ONLY_PUB = lic.public_from_seed(TEST_ONLY_SEED)
NOW = 1_800_000_000  # 2027-01-15 UTC


class Ed25519Rfc8032(unittest.TestCase):
    def test_rfc_vector_1(self):
        self.assertEqual(TEST_ONLY_PUB.hex(),
                         'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        sig = lic.sign(TEST_ONLY_SEED, b'')
        self.assertEqual(sig.hex(),
                         'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        self.assertTrue(lic.verify(TEST_ONLY_PUB, b'', sig))
        self.assertFalse(lic.verify(TEST_ONLY_PUB, b'x', sig))


class KeyVerify(unittest.TestCase):
    def check(self, key, **kw):
        return lic.verify_key(key, pubkey=TEST_ONLY_PUB, now=NOW, **kw)

    def test_valid_pro_plans(self):
        for plan, exp in (('monthly', '20270201'), ('yearly', '20271231'), ('lifetime', '0')):
            r = self.check(lic.make_key(TEST_ONLY_SEED, plan, exp))
            self.assertTrue(r.valid and r.is_pro, plan)
            self.assertEqual(r.plan, plan)

    def test_pack_key_is_not_pro(self):
        r = self.check(lic.make_key(TEST_ONLY_SEED, 'pack:sakura'))
        self.assertTrue(r.valid)
        self.assertFalse(r.is_pro)
        self.assertEqual(r.pack_id, 'sakura')

    def test_expiry_is_inclusive_through_that_day(self):
        self.assertTrue(self.check(lic.make_key(TEST_ONLY_SEED, 'monthly', '20270115')).valid)
        r = self.check(lic.make_key(TEST_ONLY_SEED, 'monthly', '20270114'))
        self.assertFalse(r.valid)
        self.assertEqual(r.reason, 'expired')

    def test_tampered_payload_rejected(self):
        key = lic.make_key(TEST_ONLY_SEED, 'monthly', '20270201')
        body, sig = key[len(lic.PREFIX):].split('.')
        parts = lic.b64u_decode(body).decode().split('|')
        parts[1], parts[2] = 'lifetime', '0'
        forged = f'{lic.PREFIX}{lic.b64u_encode("|".join(parts).encode())}.{sig}'
        r = self.check(forged)
        self.assertFalse(r.valid)
        self.assertEqual(r.reason, 'signature')

    def test_tampered_signature_rejected(self):
        key = lic.make_key(TEST_ONLY_SEED, 'lifetime')
        body, sig = key[len(lic.PREFIX):].split('.')
        bad = f'{lic.PREFIX}{body}.{"B" if sig[0] == "A" else "A"}{sig[1:]}'
        self.assertFalse(self.check(bad).valid)

    def test_wrong_signer_rejected(self):
        other = bytes(range(32))
        r = self.check(lic.make_key(other, 'lifetime'))
        self.assertFalse(r.valid)
        self.assertEqual(r.reason, 'signature')

    def test_format_errors_are_free(self):
        good = lic.make_key(TEST_ONLY_SEED, 'lifetime')
        for bad in ('', '   ', 'hello', 'BUNI-', 'BUNI-abc', 'BUNI-!!!.???',
                    good[len(lic.PREFIX):], good.replace('.', ''), good + '.extra',
                    good.replace('BUNI-', 'buni-'), None):
            r = self.check(bad)
            self.assertFalse(r.valid, repr(bad))
            self.assertEqual(r.reason, 'format', repr(bad))

    def test_unknown_plan_and_version_rejected(self):
        for payload in (b'v2|lifetime|0|0', b'v1|gold|0|0', b'v1|lifetime|soon|0', b'v1|lifetime|0'):
            key = f'{lic.PREFIX}{lic.b64u_encode(payload)}.{lic.b64u_encode(lic.sign(TEST_ONLY_SEED, payload))}'
            self.assertFalse(self.check(key).valid, payload)

    def test_surrounding_whitespace_ok(self):
        self.assertTrue(self.check('  ' + lic.make_key(TEST_ONLY_SEED, 'lifetime') + '\n').valid)

    def test_no_public_key_means_free(self):
        key = lic.make_key(TEST_ONLY_SEED, 'lifetime')
        r = lic.verify_key(key, pubkey=None, now=NOW)  # 내장 공개키가 비어 있다
        if lic.configured_public_key() is None:
            self.assertFalse(r.valid)
            self.assertEqual(r.reason, 'no_pubkey')

    def test_email_hash_not_plain(self):
        key = lic.make_key(TEST_ONLY_SEED, 'lifetime', '0', 'Buyer@Example.com')
        self.assertNotIn('example', lic.b64u_decode(key[5:].split('.')[0]).decode())
        self.assertEqual(lic.email_hash('Buyer@Example.com'), lic.email_hash(' buyer@example.com '))


class SharedVectors(unittest.TestCase):
    """맥 ProLicenseTests 와 같은 파일. gen_vectors.py 로 만든다."""

    def test_vectors(self):
        import gen_vectors
        gen_vectors.main()   # Ed25519 서명은 결정적이라 매번 같은 파일이 나온다
        path = HERE / 'license_vectors.json'
        data = json.loads(path.read_text())
        pub = bytes.fromhex(data['public_key_hex'])
        self.assertEqual(pub, TEST_ONLY_PUB)
        for c in data['cases']:
            r = lic.verify_key(c['key'], pubkey=pub, now=data['now'])
            self.assertEqual(r.valid, c['valid'], c['name'])
            self.assertEqual(r.reason, c['reason'], c['name'])
            if c['valid']:
                self.assertEqual(r.plan, c['plan'], c['name'])


if __name__ == '__main__':
    unittest.main()
