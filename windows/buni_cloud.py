"""
계정 연동(선택 기능) — Google 로그인 + Firestore 동기화 (macOS CloudSession/CloudSync 포팅).

로그인은 필수가 아니다. cloud-config.json이 없거나 로그인하지 않았으면 아무 일도 하지
않고, 앱은 로컬에서 그대로 동작한다. 앱을 켤 때는 저장된 로그인이 있을 때만 조용히
복원한다(로그인 창을 띄우거나 알림을 주는 일은 없다).

흐름: Google 로그인(기본 브라우저, PKCE + 127.0.0.1 루프백) → Google ID 토큰 →
Firebase Auth REST에 교환 → Firebase ID 토큰 → Firestore REST `users/{uid}`.
"""
import base64
import ctypes
import hashlib
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import buni_pro
import buni_shop


def _appdata_dir() -> Path:
    base = os.environ.get('APPDATA') or str(Path.home() / 'AppData' / 'Roaming')
    return Path(base) / 'Buni'


# ══════════════════════════════════════════════════════════════
# 설정 (cloud-config.json)
# ══════════════════════════════════════════════════════════════

class CloudConfig:
    def __init__(self, project_id, api_key, client_id, client_secret=None, database_url=None):
        self.project_id = project_id
        self.api_key = api_key
        self.client_id = client_id
        self.client_secret = client_secret
        self.database_url = database_url

    @property
    def rtdb_base(self) -> str:
        """채팅(Realtime Database) 기본 주소 — 비어 있으면 기본(미국 리전) 주소."""
        raw = self.database_url or f'https://{self.project_id}-default-rtdb.firebaseio.com'
        return raw.rstrip('/')

    _loaded = False
    _value = None

    @classmethod
    def shared(cls):
        """서버 설정. 없으면 None — 동기화 기능이 통째로 꺼진다."""
        if not cls._loaded:
            cls._value = cls._load()
            cls._loaded = True
        return cls._value

    @classmethod
    def _load(cls):
        candidates = []
        bundle = getattr(sys, '_MEIPASS', None)           # PyInstaller onefile 안
        if bundle:
            candidates.append(Path(bundle) / 'cloud-config.json')
        candidates.append(Path(sys.argv[0]).resolve().parent / 'cloud-config.json')
        candidates.append(Path(__file__).resolve().parent / 'cloud-config.json')
        candidates.append(_appdata_dir() / 'cloud-config.json')
        for path in candidates:
            try:
                d = json.loads(path.read_text(encoding='utf-8'))
                pid, key, cid = d.get('projectId'), d.get('apiKey'), d.get('googleClientId')
                if pid and key and cid:
                    return cls(pid, key, cid, d.get('googleClientSecret') or None, d.get('databaseURL') or None)
            except Exception:
                continue
        return None


# ══════════════════════════════════════════════════════════════
# 합치기 규칙 — 네트워크와 무관한 순수 함수
# ══════════════════════════════════════════════════════════════
#
# 서버 문서(doc): {'coins': int, 'owned': set, 'equipped': {캐릭터: {자리: id}},
#                  'equipped_updated_at': float(epoch), 'tokens': {월: {기기: 토큰}}}
#
#  · 구매 목록: 합집합 — 어느 기기에서 샀든 모든 기기에서 쓴다.
#  · 코인: 변화량 합산 — "지난 동기화 이후 이 기기에서 늘고 준 만큼"만 서버 값에 더한다.
#  · 착용: 나중에 바꾼 쪽이 이긴다.
#  · 토큰: 기기별로 따로 적고 합산 — 레벨은 부니를 켜둔 모든 PC의 사용량 합이다.

def new_doc():
    return {'coins': 0, 'owned': set(), 'equipped': {},
            'equipped_updated_at': 0.0, 'tokens': {}}


def merge(local: dict, remote, baseline_coins):
    """(서버에 쓸 문서, 모든 기기를 합친 이번 달 토큰)을 돌려준다."""
    month, dev = local['month'], local['device_id']
    if remote is None:
        # 서버에 아무것도 없다 — 이 기기 상태가 처음 올라간다
        doc = new_doc()
        doc['coins'] = max(0, local['coins'])
        doc['owned'] = set(local['owned'])
        doc['equipped'] = {c: dict(s) for c, s in local['equipped'].items()}
        doc['equipped_updated_at'] = local['equipped_changed_at']
        doc['tokens'] = {month: {dev: local['month_tokens']}}
        return doc, local['month_tokens']

    doc = {
        'coins': remote['coins'],
        'owned': set(remote['owned']),
        'equipped': {c: dict(s) for c, s in remote['equipped'].items()},
        'equipped_updated_at': remote['equipped_updated_at'],
        'tokens': {m: dict(d) for m, d in remote['tokens'].items()},
    }
    if baseline_coins is not None:
        doc['coins'] = max(0, remote['coins'] + (local['coins'] - baseline_coins))
    else:
        # 처음 연결 — 이 기기의 코인도 아직 서버에 반영된 적이 없으니 더한다
        doc['coins'] = max(0, remote['coins'] + local['coins'])

    doc['owned'] = set(remote['owned']) | set(local['owned'])

    if not remote['equipped'] or local['equipped_changed_at'] > remote['equipped_updated_at']:
        doc['equipped'] = {c: dict(s) for c, s in local['equipped'].items()}
        doc['equipped_updated_at'] = max(local['equipped_changed_at'], remote['equipped_updated_at'])

    this_month = doc['tokens'].setdefault(month, {})
    this_month[dev] = max(this_month.get(dev, 0), local['month_tokens'])
    # 현재 달을 포함해 최근 3개월만 남긴다 (문서가 끝없이 커지지 않게)
    keep = set(sorted(doc['tokens'], reverse=True)[:3]) | {month}
    doc['tokens'] = {m: d for m, d in doc['tokens'].items() if m in keep}
    return doc, sum(this_month.values())


# ══════════════════════════════════════════════════════════════
# Firestore 값 변환 (REST는 모든 값에 타입 이름을 붙인다)
# ══════════════════════════════════════════════════════════════

def _iso(ts: float) -> str:
    return datetime.fromtimestamp(max(ts, 0), tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def _parse_iso(s: str) -> float:
    try:
        s = s.rstrip('Z')
        if '.' in s:
            head, frac = s.split('.', 1)
            s = head + '.' + frac[:6]
        fmt = '%Y-%m-%dT%H:%M:%S.%f' if '.' in s else '%Y-%m-%dT%H:%M:%S'
        return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0.0


def _fs_map(fields: dict) -> dict:
    return {'mapValue': {'fields': fields} if fields else {}}


def encode_doc(doc: dict) -> dict:
    equipped = {c: _fs_map({slot: {'stringValue': iid} for slot, iid in slots.items()})
                for c, slots in doc['equipped'].items()}
    tokens = {m: _fs_map({dev: {'integerValue': str(int(n))} for dev, n in devs.items()})
              for m, devs in doc['tokens'].items()}
    owned = [{'stringValue': i} for i in sorted(doc['owned'])]
    return {
        'coins': {'integerValue': str(int(doc['coins']))},
        'owned': {'arrayValue': {'values': owned} if owned else {}},
        'equipped': _fs_map(equipped),
        'equippedUpdatedAt': {'timestampValue': _iso(doc['equipped_updated_at'])},
        'tokens': _fs_map(tokens),
        'schema': {'integerValue': '1'},
        'updatedAt': {'timestampValue': _iso(time.time())},
    }


def _map_fields(v) -> dict:
    return ((v or {}).get('mapValue') or {}).get('fields') or {}


def decode_doc(fields: dict) -> dict:
    doc = new_doc()
    try:
        doc['coins'] = int(((fields.get('coins') or {}).get('integerValue')) or 0)
    except ValueError:
        doc['coins'] = 0
    arr = (((fields.get('owned') or {}).get('arrayValue')) or {}).get('values') or []
    doc['owned'] = {v['stringValue'] for v in arr if 'stringValue' in v}
    for char, slots_v in _map_fields(fields.get('equipped')).items():
        slots = {}
        for slot, iv in _map_fields(slots_v).items():
            if 'stringValue' in iv:
                slots[slot] = iv['stringValue']
        doc['equipped'][char] = slots
    ts = (fields.get('equippedUpdatedAt') or {}).get('timestampValue')
    if ts:
        doc['equipped_updated_at'] = _parse_iso(ts)
    for month, devs_v in _map_fields(fields.get('tokens')).items():
        devs = {}
        for dev, cv in _map_fields(devs_v).items():
            try:
                devs[dev] = int(cv.get('integerValue'))
            except (TypeError, ValueError):
                pass
        doc['tokens'][month] = devs
    return doc


# ══════════════════════════════════════════════════════════════
# 갱신 토큰 보관 (Windows DPAPI — 이 사용자 계정으로만 풀린다)
# ══════════════════════════════════════════════════════════════

class _Blob(ctypes.Structure):
    _fields_ = [('cbData', ctypes.c_uint32), ('pbData', ctypes.POINTER(ctypes.c_char))]


def _dpapi(data: bytes, protect: bool):
    if sys.platform != 'win32':
        return data                                   # 시험용(비 Windows) — 그대로
    crypt32, kernel32 = ctypes.windll.crypt32, ctypes.windll.kernel32
    buf = ctypes.create_string_buffer(data, len(data))
    blob_in = _Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = _Blob()
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    if not fn(ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)):
        raise OSError('DPAPI failed')
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def _token_path() -> Path:
    return _appdata_dir() / 'cloud-token.bin'


def _token_write(value: str):
    try:
        p = _token_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(_dpapi(value.encode('utf-8'), True))
    except Exception:
        pass


def _token_read():
    try:
        return _dpapi(_token_path().read_bytes(), False).decode('utf-8')
    except Exception:
        return None


def _token_delete():
    try:
        _token_path().unlink(missing_ok=True)
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════
# 작은 HTTP 도우미
# ══════════════════════════════════════════════════════════════

def _http(method: str, url: str, *, headers=None, body: bytes | None = None, timeout=20):
    """(상태코드, 본문 bytes). 네트워크 오류는 예외로 던진다."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _json(data: bytes) -> dict:
    try:
        return json.loads(data.decode('utf-8'))
    except Exception:
        return {}


def _form(pairs) -> bytes:
    return '&'.join(f'{k}={urllib.parse.quote(str(v), safe="-._~")}' for k, v in pairs).encode('utf-8')


class CloudError(Exception):
    pass


# ══════════════════════════════════════════════════════════════
# Google 로그인 — OAuth 2.0 + PKCE + 루프백
# ══════════════════════════════════════════════════════════════

def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')


_PAGE = ('<!doctype html><html><head><meta charset="utf-8"><title>Buni</title></head>'
         '<body style="font-family:Segoe UI,sans-serif;background:#14161a;color:#eef1f6;'
         'display:grid;place-items:center;height:100vh;margin:0"><div style="text-align:center">'
         '<h2>{title}</h2><p style="color:#8b93a6">{hint}</p></div></body></html>')


def google_sign_in(cfg: CloudConfig, t, timeout=180) -> str:
    """기본 브라우저에서 로그인하고 Google ID 토큰을 돌려준다 (블로킹 — 스레드에서 부른다).
    t(ko, en): 표시 언어에 맞는 문구 선택."""
    verifier = _b64url(secrets.token_bytes(48))
    challenge = _b64url(hashlib.sha256(verifier.encode('ascii')).digest())
    state = _b64url(secrets.token_bytes(18))

    result = {}
    got = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
            if 'code' not in q and 'error' not in q:      # 파비콘 같은 요청은 무시
                self.send_response(404); self.end_headers(); return
            ok = 'error' not in q
            page = _PAGE.format(
                title=t('로그인이 완료됐어요 🐰', 'Sign-in complete 🐰') if ok else t('로그인을 취소했어요', 'Sign-in cancelled'),
                hint=t('이 창은 닫아도 돼요. 부니로 돌아가세요.', 'You can close this tab and go back to Buni.') if ok
                     else t('부니에서 다시 시도할 수 있어요.', 'You can try again from Buni.')).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(page)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(page)
            result.update(q)
            got.set()

        def log_message(self, *a):
            pass

    server = HTTPServer(('127.0.0.1', 0), Handler)       # 이 컴퓨터 안에서만 받는다
    port = server.server_address[1]
    redirect = f'http://127.0.0.1:{port}'
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        params = [('client_id', cfg.client_id), ('redirect_uri', redirect), ('response_type', 'code'),
                  ('scope', 'openid email profile'), ('code_challenge', challenge),
                  ('code_challenge_method', 'S256'), ('state', state)]
        webbrowser.open('https://accounts.google.com/o/oauth2/v2/auth?' + _form(params).decode('ascii'))
        if not got.wait(timeout):
            raise CloudError(t('로그인 시간이 지났어요. 다시 시도해 주세요', 'Sign-in timed out. Please try again'))
    finally:
        server.shutdown()
        server.server_close()

    if 'error' in result:
        raise CloudError(t('로그인을 취소했어요', 'Sign-in was cancelled'))
    # state가 다르면 다른 곳에서 온 요청이다 — 코드를 쓰지 않는다
    if result.get('state') != state or 'code' not in result:
        raise CloudError(t('로그인 응답을 확인하지 못했어요', 'Could not verify the sign-in response'))

    form = [('code', result['code']), ('client_id', cfg.client_id), ('redirect_uri', redirect),
            ('grant_type', 'authorization_code'), ('code_verifier', verifier)]
    if cfg.client_secret:
        form.append(('client_secret', cfg.client_secret))
    status, data = _http('POST', 'https://oauth2.googleapis.com/token',
                         headers={'Content-Type': 'application/x-www-form-urlencoded'}, body=_form(form))
    j = _json(data)
    if status != 200 or 'id_token' not in j:
        detail = j.get('error_description') or j.get('error') or 'HTTP error'
        raise CloudError(t(f'Google 로그인에 실패했어요: {detail}', f'Google sign-in failed: {detail}'))
    return j['id_token']


# ══════════════════════════════════════════════════════════════
# 로그인 상태 + 동기화
# ══════════════════════════════════════════════════════════════

class CloudSession:
    """선택 기능인 "계정 연동"의 로그인 상태와 Firestore 동기화.

    모든 공개 메서드는 블로킹이므로 UI 스레드가 아니라 작업 스레드에서 부른다.
    상태가 바뀌면 등록한 콜백이 불린다(어느 스레드에서든 — UI는 root.after로 넘겨 받는다).
    """

    SYNC_DEBOUNCE = 4.0        # 변경 후 이만큼 모았다가 올린다
    SYNC_PERIOD = 300.0        # 다른 PC에서 바뀐 것도 받아오도록 가끔 맞춘다

    def __init__(self, shop: 'buni_shop.ShopStore', t):
        self.shop = shop
        self.t = t
        self.user = None                 # {'uid':..., 'name':...}
        self.busy = False
        self.message = None
        self.last_sync = None
        self._id_token = None
        self._id_expiry = 0.0
        self._lock = threading.RLock()
        self._syncing = False
        self._suppress_until = 0.0
        self._debounce = None
        self._listeners = []
        self._prefs_path = _appdata_dir() / 'cloud.json'

    # ── 상태 ────────────────────────────────────────────────

    @property
    def is_configured(self) -> bool:
        return CloudConfig.shared() is not None

    @property
    def is_signed_in(self) -> bool:
        return self.user is not None

    def add_listener(self, cb):
        self._listeners.append(cb)

    def _notify(self):
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass

    def report(self, text):
        self.message = text
        self._notify()

    def _prefs(self) -> dict:
        try:
            return json.loads(self._prefs_path.read_text(encoding='utf-8'))
        except Exception:
            return {}

    def _set_pref(self, key, value):
        d = self._prefs()
        d[key] = value
        try:
            self._prefs_path.parent.mkdir(parents=True, exist_ok=True)
            self._prefs_path.write_text(json.dumps(d), encoding='utf-8')
        except Exception:
            pass

    @property
    def consent_given(self) -> bool:
        return bool(self._prefs().get('consent'))

    def give_consent(self):
        self._set_pref('consent', True)

    # ── 시작: 저장된 로그인이 있을 때만 조용히 복원 ──────────

    def start(self):
        """앱 시작 때 한 번. 서버 설정이 없으면 아무것도 연결하지 않는다."""
        if not self.is_configured:
            return
        self.shop.add_listener(self._on_shop_changed)

        def boot():
            self.restore()
            if self.is_signed_in:
                self.sync_now()
            self._periodic()
        threading.Thread(target=boot, daemon=True).start()

    def _periodic(self):
        while True:
            time.sleep(self.SYNC_PERIOD)
            if self.is_signed_in:
                self.sync_now()

    def _on_shop_changed(self):
        # 동기화 결과를 반영하느라 생긴 변경은 또 다른 동기화를 부르지 않게 무시한다
        if not self.is_signed_in or time.time() < self._suppress_until:
            return
        with self._lock:
            if self._debounce:
                self._debounce.cancel()
            self._debounce = threading.Timer(self.SYNC_DEBOUNCE, self.sync_now)
            self._debounce.daemon = True
            self._debounce.start()

    def restore(self):
        refresh = _token_read()
        if not self.is_configured or not refresh:
            return
        try:
            self._refresh_tokens(refresh)
        except Exception:
            # 만료·취소된 로그인 — 사용자를 방해하지 않고 로그아웃 상태로 둔다
            _token_delete()
            self.user = None
        self._notify()

    # ── 로그인 / 로그아웃 ───────────────────────────────────

    def sign_in(self):
        """사용자가 로그인 버튼을 눌렀을 때만 호출한다 (동의는 UI가 먼저 받는다)."""
        t = self.t
        cfg = CloudConfig.shared()
        if cfg is None:
            self.report(t('서버 설정이 없어서 로그인할 수 없어요 (cloud-config.json)',
                          "Cloud isn't configured (cloud-config.json)"))
            return
        if self.busy:
            return
        self.busy, self.message = True, None
        self._notify()
        try:
            google_token = google_sign_in(cfg, t)
            self._firebase_sign_in(google_token, cfg)
            self.message = t('로그인했어요', 'Signed in')
            self._notify()
            self.sync_now()
        except Exception as e:
            self.message = str(e)
        finally:
            self.busy = False
            self._notify()

    def sign_out(self):
        _token_delete()
        self._id_token, self._id_expiry = None, 0.0
        self.user = None
        self.message = self.t('로그아웃했어요. 이 PC의 설정은 그대로 남아 있어요.',
                              'Signed out. Your settings on this PC are kept.')
        self._notify()

    def delete_server_data(self):
        """서버에 저장된 내 데이터를 지운다 (이 PC의 데이터는 그대로)."""
        if not self.user:
            return
        self.busy = True
        self._notify()
        try:
            self._delete_remote()
            self.message = self.t('서버에 저장된 데이터를 지웠어요', 'Server data deleted')
        except Exception as e:
            self.message = str(e)
        finally:
            self.busy = False
            self._notify()

    # ── Firebase Auth (REST) ────────────────────────────────

    def _firebase_sign_in(self, google_id_token: str, cfg: CloudConfig):
        t = self.t
        url = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=' + urllib.parse.quote(cfg.api_key)
        body = json.dumps({
            'postBody': f'id_token={google_id_token}&providerId=google.com',
            'requestUri': 'http://localhost',
            'returnIdpCredential': True,
            'returnSecureToken': True,
        }).encode('utf-8')
        status, data = _http('POST', url, headers={'Content-Type': 'application/json'}, body=body)
        j = _json(data)
        if status != 200 or not all(k in j for k in ('idToken', 'refreshToken', 'localId')):
            detail = (j.get('error') or {}).get('message') or 'HTTP error'
            raise CloudError(t(f'서버 로그인에 실패했어요: {detail}', f'Server sign-in failed: {detail}'))
        self._apply_token(j['idToken'], float(j.get('expiresIn') or 3600))
        self.user = {'uid': j['localId'], 'name': j.get('displayName')}
        _token_write(j['refreshToken'])
        self._set_pref('lastUser', j['localId'])

    def _refresh_tokens(self, refresh: str):
        cfg = CloudConfig.shared()
        if cfg is None:
            raise CloudError('no config')
        url = 'https://securetoken.googleapis.com/v1/token?key=' + urllib.parse.quote(cfg.api_key)
        status, data = _http('POST', url,
                             headers={'Content-Type': 'application/x-www-form-urlencoded'},
                             body=_form([('grant_type', 'refresh_token'), ('refresh_token', refresh)]))
        j = _json(data)
        if status != 200 or 'id_token' not in j or 'user_id' not in j:
            raise CloudError('refresh failed')
        self._apply_token(j['id_token'], float(j.get('expires_in') or 3600))
        if j.get('refresh_token'):
            _token_write(j['refresh_token'])
        # 이름은 갱신 응답에 없으니 직전 값을 유지한다
        self.user = {'uid': j['user_id'], 'name': (self.user or {}).get('name')}

    def _apply_token(self, token: str, expires_in: float):
        self._id_token = token
        self._id_expiry = time.time() + expires_in - 60       # 만료 1분 전에 미리 갱신

    def valid_id_token(self) -> str:
        """다른 기능(채팅)이 쓰는 유효한 ID 토큰 — 만료됐으면 먼저 갱신한다."""
        return self._valid_id_token()

    def _valid_id_token(self) -> str:
        if self._id_token and time.time() < self._id_expiry:
            return self._id_token
        refresh = _token_read()
        if not refresh:
            raise CloudError(self.t('로그인이 필요해요', 'Sign-in required'))
        self._refresh_tokens(refresh)
        return self._id_token

    # ── Firestore REST ──────────────────────────────────────

    def _doc_url(self, cfg, uid):
        return (f'https://firestore.googleapis.com/v1/projects/{cfg.project_id}'
                f'/databases/(default)/documents/users/{uid}')

    def _request(self, method, url, token, body=None):
        headers = {'Authorization': f'Bearer {token}'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        return _http(method, url, headers=headers, body=body)

    def _fetch(self, cfg, uid, token):
        status, data = self._request('GET', self._doc_url(cfg, uid), token)
        if status == 404:
            return None, None
        if status != 200:
            raise CloudError(f'HTTP {status}')
        j = _json(data)
        return decode_doc(j.get('fields') or {}), j.get('updateTime')

    def _write(self, doc, cfg, uid, token, precondition) -> bool:
        """조건부 쓰기 — 읽은 뒤 문서가 바뀌었으면 False(다시 합쳐야 한다)."""
        if precondition:
            q = 'currentDocument.updateTime=' + urllib.parse.quote(precondition, safe='')
        else:
            q = 'currentDocument.exists=false'
        body = json.dumps({'fields': encode_doc(doc)}).encode('utf-8')
        status, data = self._request('PATCH', self._doc_url(cfg, uid) + '?' + q, token, body)
        if status == 200:
            return True
        text = data.decode('utf-8', errors='replace')
        if status == 409 or (status == 400 and 'FAILED_PRECONDITION' in text):
            return False
        raise CloudError(f'HTTP {status}')

    def _delete_remote(self):
        cfg = CloudConfig.shared()
        if cfg is None or not self.user:
            return
        token = self._valid_id_token()
        self._request('DELETE', self._doc_url(cfg, self.user['uid']), token)
        self.shop.forget_cloud_baseline(self.user['uid'])
        self.last_sync = None

    # ── 동기화 ──────────────────────────────────────────────

    def sync_now(self):
        cfg = CloudConfig.shared()
        if self._syncing or cfg is None or not self.user:
            return
        # Pro 가 아니면 동기화만 멈춘다 — 서버·로컬 데이터는 그대로 두고, 오류도 띄우지 않는다
        if buni_pro.shared().cloud_policy() != 'allow':
            return
        self._syncing = True
        t = self.t
        try:
            uid = self.user['uid']
            token = self._valid_id_token()
            # 두 PC가 동시에 쓰면 조건부 쓰기가 실패한다 — 다시 읽어서 합치기를 몇 번 시도한다
            for _ in range(3):
                remote, update_time = self._fetch(cfg, uid, token)
                local = self.shop.sync_state()
                baseline = self.shop.baseline_coins(uid)
                doc, tokens_total = merge(local, remote, baseline)
                if remote is None or not _same(remote, doc):
                    if not self._write(doc, cfg, uid, token, update_time):
                        continue                         # 그 사이 다른 PC가 썼다 → 다시
                self._suppress_until = time.time() + 8
                self.shop.apply_cloud(doc, tokens_total, uid)
                self.last_sync = time.time()
                buni_pro.shared().mark_cloud_synced()
                self._notify()
                return
            self.report(t('다른 PC와 동시에 바뀌어서 잠시 후 다시 맞출게요',
                          'Changed on another PC at the same time — will retry shortly'))
        except Exception as e:
            self.report(t('동기화하지 못했어요: ', 'Could not sync: ') + str(e))
        finally:
            self._syncing = False


def _same(a: dict, b: dict) -> bool:
    return (a['coins'] == b['coins'] and a['owned'] == b['owned']
            and a['equipped'] == b['equipped']
            and abs(a['equipped_updated_at'] - b['equipped_updated_at']) < 0.001
            and a['tokens'] == b['tokens'])
