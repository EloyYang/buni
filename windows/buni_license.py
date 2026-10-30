"""
부니 라이선스 키 — Ed25519 오프라인 서명 검증 (표준 라이브러리만 사용).

키 형식 (맥 ProLicense.swift · tools/issue_license.py 와 같다. 명세: docs/monetization/license-spec.md)

    BUNI-<base64url(payload)>.<base64url(signature 64바이트)>       (패딩 '=' 없음)
    payload = "v1|<plan>|<만료 YYYYMMDD 또는 0>|<이메일 해시 16자리 또는 0>"   (ASCII)

공개키만 앱에 들어간다. 비밀키는 발급하는 사람만 갖고 저장소에 넣지 않는다.
화면(Tk)과 무관한 순수 로직이라 단독으로 시험할 수 있다.
"""
import base64
import hashlib
import os
import re
import time
from datetime import datetime, timezone

PREFIX = 'BUNI-'
FORMAT_VERSION = 'v1'

# Pro 구독 플랜(월·연·평생)과 개별 코스메틱 팩('pack:<팩 id>')
PRO_PLANS = ('monthly', 'yearly', 'lifetime')
_PACK_RE = re.compile(r'^pack:[a-z0-9_]{1,40}$')

# 배포용 공개키 (hex 64자). 비어 있으면 어떤 키도 통과하지 못해 모두 무료로 보인다.
# 키 쌍을 만든 뒤(tools/README.md) 여기에 공개키를 넣는다. 개발 중에는 환경변수로도 줄 수 있다.
PUBLIC_KEY_HEX = ''
PUBLIC_KEY_ENV = 'BUNI_LICENSE_PUBKEY'

_B64URL_RE = re.compile(r'^[A-Za-z0-9_-]+$')


# ───────────────────────── Ed25519 (RFC 8032, 순수 파이썬) ─────────────────────────
# 키 몇 개 검증하는 용도라 속도는 중요하지 않다(검증 1회 ≈ 수십 ms).

_P = 2 ** 255 - 19
_Q = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _add(a, b):
    A = (a[1] - a[0]) * (b[1] - b[0]) % _P
    B = (a[1] + a[0]) * (b[1] + b[0]) % _P
    C = 2 * a[3] * b[3] * _D % _P
    D = 2 * a[2] * b[2] % _P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


def _mul(s, pt):
    r = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        s >>= 1
    return r


def _equal(a, b):
    return ((a[0] * b[2] - b[0] * a[2]) % _P == 0
            and (a[1] * b[2] - b[1] * a[2]) % _P == 0)


def _compress(pt):
    zi = _inv(pt[2])
    x = pt[0] * zi % _P
    y = pt[1] * zi % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, 'little')


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, 'little')
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def _sha512_modq(data):
    return int.from_bytes(hashlib.sha512(data).digest(), 'little') % _Q


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], 'little')
    a &= (1 << 254) - 8
    a |= (1 << 254)
    return a, h[32:]


def public_from_seed(seed: bytes) -> bytes:
    a, _ = _expand(seed)
    return _compress(_mul(a, _G))


def sign(seed: bytes, msg: bytes) -> bytes:
    """발급 스크립트·시험에서만 쓴다. 앱은 verify만 호출한다."""
    a, prefix = _expand(seed)
    pub = _compress(_mul(a, _G))
    r = _sha512_modq(prefix + msg)
    big_r = _compress(_mul(r, _G))
    h = _sha512_modq(big_r + pub + msg)
    s = (r + h * a) % _Q
    return big_r + int.to_bytes(s, 32, 'little')


def verify(pub: bytes, msg: bytes, sig: bytes) -> bool:
    if len(pub) != 32 or len(sig) != 64:
        return False
    a_pt = _decompress(pub)
    r_pt = _decompress(sig[:32])
    if a_pt is None or r_pt is None:
        return False
    s = int.from_bytes(sig[32:], 'little')
    if s >= _Q:
        return False
    h = _sha512_modq(sig[:32] + pub + msg)
    return _equal(_mul(s, _G), _add(r_pt, _mul(h, a_pt)))


# ───────────────────────── 키 형식 ─────────────────────────

def b64u_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')


def b64u_decode(text: str):
    """엄격한 base64url(패딩 없음). 형식이 틀리면 None."""
    if not text or not _B64URL_RE.match(text) or len(text) % 4 == 1:
        return None
    try:
        return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))
    except Exception:
        return None


def email_hash(email: str) -> str:
    """이메일 원문은 키에 넣지 않는다. 소문자 정규화 sha256 앞 16자리만."""
    e = (email or '').strip().lower()
    return hashlib.sha256(e.encode('utf-8')).hexdigest()[:16] if e else '0'


def make_payload(plan: str, expires: str = '0', email: str = '') -> bytes:
    """expires: 'YYYYMMDD'(그날 끝까지 유효, UTC) 또는 '0'(만료 없음)."""
    return f'{FORMAT_VERSION}|{plan}|{expires}|{email_hash(email)}'.encode('ascii')


def make_key(seed: bytes, plan: str, expires: str = '0', email: str = '') -> str:
    payload = make_payload(plan, expires, email)
    return f'{PREFIX}{b64u_encode(payload)}.{b64u_encode(sign(seed, payload))}'


class LicenseResult:
    """valid 이면 plan·expires 가 채워진다. 아니면 reason 에 이유(format·signature·expired·no_pubkey)."""
    __slots__ = ('valid', 'reason', 'plan', 'expires', 'email_hash')

    def __init__(self, valid, reason='', plan='', expires=None, email_hash='0'):
        self.valid = valid
        self.reason = reason
        self.plan = plan
        self.expires = expires        # 'YYYYMMDD' 또는 None(만료 없음)
        self.email_hash = email_hash

    @property
    def is_pro(self):
        return self.valid and self.plan in PRO_PLANS

    @property
    def pack_id(self):
        return self.plan[5:] if self.valid and self.plan.startswith('pack:') else None

    def __repr__(self):
        return f'LicenseResult({self.valid}, {self.reason or self.plan})'


def configured_public_key():
    """환경변수 → 내장 상수 순서. 없거나 형식이 틀리면 None."""
    hex_key = (os.environ.get(PUBLIC_KEY_ENV) or PUBLIC_KEY_HEX).strip()
    try:
        raw = bytes.fromhex(hex_key)
    except ValueError:
        return None
    return raw if len(raw) == 32 else None


def _today_utc(now):
    ts = now if now is not None else time.time()
    return datetime.fromtimestamp(ts, timezone.utc).strftime('%Y%m%d')


def verify_key(key, pubkey=None, now=None) -> LicenseResult:
    """키 문자열을 검증한다. 올바르면 valid, 변조·만료·형식 오류는 invalid(= 무료)."""
    key = (key or '').strip()
    if not key.startswith(PREFIX) or key.count('.') != 1:
        return LicenseResult(False, 'format')
    body_b64, sig_b64 = key[len(PREFIX):].split('.')
    payload = b64u_decode(body_b64)
    sig = b64u_decode(sig_b64)
    if payload is None or sig is None or len(sig) != 64:
        return LicenseResult(False, 'format')
    try:
        parts = payload.decode('ascii').split('|')
    except UnicodeDecodeError:
        return LicenseResult(False, 'format')
    if len(parts) != 4 or parts[0] != FORMAT_VERSION:
        return LicenseResult(False, 'format')
    _, plan, expires, ehash = parts
    if plan not in PRO_PLANS and not _PACK_RE.match(plan):
        return LicenseResult(False, 'format')
    if expires != '0' and not re.match(r'^\d{8}$', expires):
        return LicenseResult(False, 'format')

    pub = pubkey if pubkey is not None else configured_public_key()
    if pub is None:
        return LicenseResult(False, 'no_pubkey')
    if not verify(pub, payload, sig):
        return LicenseResult(False, 'signature')
    if expires != '0' and _today_utc(now) > expires:
        return LicenseResult(False, 'expired', plan, expires, ehash)
    return LicenseResult(True, '', plan, None if expires == '0' else expires, ehash)
