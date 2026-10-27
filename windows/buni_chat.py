"""
부니 채팅 — 방 코드로 모여서(최대 5명) 대화하는 기능 (macOS ChatStore.swift 포팅).

서버는 Firebase Realtime Database(cloud/database.rules.json). 로그인한 사용자만 쓸 수 있고,
방은 6자리 코드로 들어간다. 상대에게 보이는 것은 닉네임·캐릭터·옷차림·모션(대기/작업 중/완료)과
대화뿐이며, 어떤 세션에서 무슨 작업을 하는지는 전해지지 않는다.

화면(Tk)과 무관한 로직이라 단독으로 시험할 수 있다. 모든 통신은 작업 스레드에서 하고,
상태가 바뀌면 등록한 콜백이 불린다(어느 스레드에서든 — UI는 root.after로 넘겨 받는다).
"""
import json
import random
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import buni_cloud

MAX_MEMBERS = 5
MAX_NICKNAME = 20
CHARACTER_NAMES = {                 # 닉네임을 비워 두면 대화에 쓰는 이름 (한국어, English)
    'rabbit': ('부니', 'Buni'), 'brownRabbit': ('두니', 'Duni'), 'pinkRabbit': ('푸니', 'Puni'),
    'orangeRabbit': ('주니', 'Juni'), 'yellowRabbit': ('누니', 'Nuni'), 'greenRabbit': ('우니', 'Uni'),
}
MAX_TEXT = 50                  # 한 번에 보낼 수 있는 글자 수 — 말풍선이 잘려 보이지 않는 길이
MESSAGE_LIFETIME = 15.0        # 메시지가 서버에 남아 있는 시간(초). 그 뒤엔 보낸 사람이 지운다 — 기록은 남기지 않는다
HEARTBEAT = 20.0          # 생존 신호 주기
STALE_AFTER = 75.0        # 이만큼 신호가 안 바뀌면 떠난 것으로 본다
TOKEN_REFRESH = 50 * 60   # 토큰이 만료되기 전에 새 토큰으로 스트림을 다시 잇는다
MOTIONS = ('idle', 'working', 'done')

# 헷갈리는 글자(0·O·1·I)를 뺀 알파벳 — 규칙의 /^[A-Z2-9]{6}$/ 와 같아야 한다
_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
SERVER_TIME = {'.sv': 'timestamp'}


class ChatError(Exception):
    pass


def random_code() -> str:
    return ''.join(random.choice(_ALPHABET) for _ in range(6))


def normalize_code(raw: str):
    """사용자가 입력한 코드를 정리한다(공백·소문자 허용). 형식이 틀리면 None."""
    code = (raw or '').strip().upper()
    if len(code) == 6 and all(('A' <= c <= 'Z') or ('2' <= c <= '9') for c in code):
        return code
    return None


# ══════════════════════════════════════════════════════════════
# 인원 제한 — 데이터베이스 규칙으로는 인원을 셀 수 없어서 들어온 사람이 직접 확인한다
# ══════════════════════════════════════════════════════════════

ACTIVE_WINDOW_MS = 90_000      # 내가 방금 쓴 서버 시각(seen)에서 이만큼 안에 신호가 있던 사람만 활동 중


def has_seat(raw_members: dict, me: str, limit: int = MAX_MEMBERS) -> bool:
    """지금 활동 중인 사람들을 들어온 순서(서버 시각 joined, 같으면 uid)로 세워 내가 limit번째 안에
    드는지 본다. 모두가 같은 기준으로 계산하므로 동시에 들어와도 가장 늦은 사람이 물러난다."""
    mine = raw_members.get(me)
    if not isinstance(mine, dict):
        return False
    now = float(mine.get('seen') or 0)
    active = []
    for uid, d in raw_members.items():
        if not isinstance(d, dict):
            continue
        if uid == me or now - float(d.get('seen') or 0) < ACTIVE_WINDOW_MS:
            active.append((float(d.get('joined') or 0), uid))
    active.sort()
    return [u for _, u in active].index(me) < limit


# ══════════════════════════════════════════════════════════════
# 스트림 이벤트를 쌓아 현재 데이터를 만드는 트리 (순수 로직)
# ══════════════════════════════════════════════════════════════

class RTDBTree:
    """put(교체)·patch(병합) 이벤트를 순서대로 적용해 현재 데이터 전체를 유지한다."""

    def __init__(self):
        self.root = None

    def put(self, path: str, value):
        parts = [p for p in path.split('/') if p]
        self.root = self._set(self.root, parts, value)

    def patch(self, path: str, value: dict):
        base = path if path.endswith('/') else path + '/'
        for k, v in value.items():
            self.put(base + k, v)

    @property
    def children(self) -> dict:
        return self.root if isinstance(self.root, dict) else {}

    @classmethod
    def _set(cls, node, parts, value):
        if not parts:
            return value
        d = dict(node) if isinstance(node, dict) else {}
        child = cls._set(d.get(parts[0]), parts[1:], value)
        if child is None:
            d.pop(parts[0], None)
        else:
            d[parts[0]] = child
        return d or None              # 빈 가지는 데이터베이스처럼 없는 것으로 본다


def decode_members(tree: dict) -> list:
    out = []
    for uid, d in tree.items():
        if not isinstance(d, dict):
            continue
        if not all(isinstance(d.get(k), str) for k in ('name', 'char', 'motion')):
            continue
        equip = {k: v for k, v in (d.get('equip') or {}).items() if isinstance(v, str)}
        seen = d.get('seen')
        out.append({'uid': uid, 'name': d['name'], 'char': d['char'],
                    'motion': d['motion'] if d['motion'] in MOTIONS else 'idle',
                    'equip': equip, 'seen': float(seen) if isinstance(seen, (int, float)) else 0.0,
                    'level': max(1, min(9999, int(d['level']))) if isinstance(d.get('level'), (int, float)) else 1})
    return sorted(out, key=lambda m: m['uid'])


def decode_messages(tree: dict) -> list:
    out = []
    for key, d in tree.items():
        if isinstance(d, dict) and all(isinstance(d.get(k), str) for k in ('uid', 'name', 'text')):
            ts = d.get('ts')
            out.append({'id': key, 'uid': d['uid'], 'name': d['name'], 'text': d['text'],
                        'ts': float(ts) if isinstance(ts, (int, float)) else 0.0})
    return sorted(out, key=lambda m: m['id'])          # push key는 사전순이 곧 시간순


# ══════════════════════════════════════════════════════════════
# 통신
# ══════════════════════════════════════════════════════════════

class RTDB:
    def __init__(self, base: str):
        self.base = base.rstrip('/')

    def url(self, path: str, token: str, **query) -> str:
        q = {'auth': token, **query}
        return f'{self.base}/{path}.json?' + urllib.parse.urlencode(q)

    @staticmethod
    def send(method: str, url: str, body=None, timeout=15):
        """(상태코드, 본문 문자열)."""
        data = json.dumps(body).encode('utf-8') if body is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={'Content-Type': 'application/json'} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode('utf-8', errors='replace')
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode('utf-8', errors='replace')


class Stream:
    """한 경로를 계속 듣는다(Server-Sent Events). 끊기면 on_end(종류)를 부르고 끝난다 —
    다시 잇는 일은 부르는 쪽이 한다."""

    def __init__(self):
        self._stop = threading.Event()
        self._resp = None

    def start(self, url: str, on_event, on_end):
        def run():
            kind = 'closed'
            try:
                req = urllib.request.Request(url, headers={'Accept': 'text/event-stream'})
                self._resp = urllib.request.urlopen(req, timeout=120)       # 서버가 30초마다 keep-alive를 보낸다
                event = ''
                for raw in self._resp:
                    if self._stop.is_set():
                        return
                    line = raw.decode('utf-8', errors='replace').rstrip('\r\n')
                    if line.startswith('event:'):
                        event = line[6:].strip()
                    elif line.startswith('data:'):
                        payload = line[5:].strip()
                        if event in ('put', 'patch'):
                            try:
                                obj = json.loads(payload)
                                on_event(event, obj['path'], obj.get('data'))
                            except (ValueError, KeyError, TypeError):
                                continue
                        elif event in ('auth_revoked', 'cancel'):
                            kind = 'auth'
                            break
            except urllib.error.HTTPError as e:
                kind = 'auth' if e.code in (401, 403) else 'failed'
            except Exception:
                kind = 'failed'
            if not self._stop.is_set():
                on_end(kind)

        threading.Thread(target=run, daemon=True).start()

    def stop(self):
        self._stop.set()
        try:
            if self._resp:
                self._resp.close()
        except Exception:
            pass


# ══════════════════════════════════════════════════════════════
# 채팅방 상태
# ══════════════════════════════════════════════════════════════

class ChatStore:
    def __init__(self, cloud, shop, persist, t):
        self.cloud, self.shop, self.persist, self.t = cloud, shop, persist, t
        self.room_code = None
        self.members = []          # 화면에 보일 사람들(나 포함) — 나를 맨 앞에
        self.messages = []
        self.received_at = {}      # 메시지 id → 받은 시각(이 PC 시계) — 말풍선을 잠깐만 띄우는 기준
        self.status = 'off'        # off / connecting / online / reconnecting
        self.last_error = None
        self.motion = 'idle'
        self._lock = threading.RLock()
        self._rtdb = None
        self._uid = None
        self._gen = 0              # 방을 나갔다 들어오면 늦게 도착한 이벤트를 버리는 표
        self._member_tree = RTDBTree()
        self._message_tree = RTDBTree()
        self._messages_loaded = False
        self._pending_keys = set()                     # 아직 서버에 남아 있는 내 메시지
        self._streams = []
        self._seen_change = {}
        self._last_send = 0.0
        self._listeners = []
        self._beat = None

    # ── 프로필(이 PC) ───────────────────────────────────────

    @property
    def nickname(self) -> str:
        return self.persist.get('chat.nickname', '') or ''

    @nickname.setter
    def nickname(self, value: str):
        self.persist.set('chat.nickname', (value or '').strip()[:20])


    @property
    def character(self) -> str:
        return self.persist.get('chat.character', 'rabbit') or 'rabbit'

    @character.setter
    def character(self, value: str):
        self.persist.set('chat.character', value)

    @property
    def display_name(self) -> str:
        own = self.nickname.strip()
        if own:
            return own[:MAX_NICKNAME]
        return self.character_name(self.character)         # 비워 두면 캐릭터 이름(부니·우니 …)

    def character_name(self, char_id: str) -> str:
        ko, en = CHARACTER_NAMES.get(char_id, CHARACTER_NAMES['rabbit'])
        return self.t(ko, en)

    @property
    def is_available(self) -> bool:
        return self.cloud.is_configured

    @property
    def is_in_room(self) -> bool:
        return self.room_code is not None

    @property
    def my_uid(self):
        return (self.cloud.user or {}).get('uid')

    @property
    def last_room(self):
        return self.persist.get('chat.lastRoom')

    def add_listener(self, cb):
        self._listeners.append(cb)

    def _notify(self):
        for cb in list(self._listeners):
            try:
                cb()
            except Exception:
                pass

    def _fail(self, text):
        self.last_error = text
        self._notify()

    # ── 시작: 로그인이 복원되면 마지막 방에 조용히 다시 들어간다 ──

    def start(self):
        if not self.is_available:
            return

        def boot():
            for _ in range(60):                      # 로그인 복원을 잠깐 기다린다
                if self.cloud.is_signed_in:
                    break
                time.sleep(1)
            code = self.last_room
            if code and self.cloud.is_signed_in and not self.is_in_room:
                self.join(code, silent=True)
        threading.Thread(target=boot, daemon=True).start()
        self.cloud.add_listener(self._on_cloud_changed)

    def _on_cloud_changed(self):
        if not self.cloud.is_signed_in and self.is_in_room:
            self.leave(forget=False)

    # ── 방 만들기 / 들어가기 / 나가기 ────────────────────────

    def _session(self):
        cfg = buni_cloud.CloudConfig.shared()
        if not cfg:
            self._fail(self.t('서버 설정이 없어서 채팅을 쓸 수 없어요', "Chat isn't set up (cloud-config.json)"))
            return None
        if not self.cloud.is_signed_in:
            self._fail(self.t('채팅은 Google 로그인이 필요해요', 'Chat needs a Google sign-in'))
            return None
        try:
            return RTDB(cfg.rtdb_base), self.cloud.user['uid'], self.cloud.valid_id_token()
        except Exception as e:
            self._fail(str(e))
            return None

    def create_room(self):
        sess = self._session()
        if not sess:
            return
        rtdb, uid, token = sess
        self.last_error = None
        for _ in range(5):
            code = random_code()
            try:
                status, _ = rtdb.send('PUT', rtdb.url(f'rooms/{code}/meta', token),
                                      {'owner': uid, 'createdAt': SERVER_TIME})
            except Exception as e:
                self._fail(str(e))
                return
            if status == 200:
                self.join(code)
                return                               # 401 = 이미 있는 코드 — 다른 코드로 다시
        self._fail(self.t('방을 만들지 못했어요', "Couldn't create a room"))

    def join(self, raw_code: str, silent=False):
        t = self.t
        code = normalize_code(raw_code)
        if not code:
            if not silent:
                self._fail(t('방 코드는 영문·숫자 6자리예요', 'Room codes are 6 letters/digits'))
            return
        if self.is_in_room:
            self.leave(forget=False)
        sess = self._session()
        if not sess:
            return
        rtdb, uid, token = sess
        self.last_error = None
        self.status = 'connecting'
        self._notify()
        try:
            # 방이 있는지 먼저 확인 (오타로 새 방이 생기지 않게 — 규칙도 막는다)
            status, body = rtdb.send('GET', rtdb.url(f'rooms/{code}/meta', token))
            if status != 200:
                raise ChatError(t(f'서버 오류 ({status})', f'Server error ({status})'))
            if body.strip() == 'null':
                self.persist.remove('chat.lastRoom')
                raise ChatError(t('그런 방이 없어요. 코드를 다시 확인해 주세요', 'No such room. Check the code'))

            # 내 자리를 먼저 쓰고(들어온 시각 joined 포함), 그 뒤에 5명을 넘지 않는지 확인한다
            member_url = rtdb.url(f'rooms/{code}/members/{uid}', token)
            entry = self._profile()
            entry['joined'] = SERVER_TIME
            status, _ = rtdb.send('PUT', member_url, entry)
            if status == 200:
                s2, body2 = rtdb.send('GET', rtdb.url(f'rooms/{code}/members', token))
                if s2 == 200 and not has_seat(json.loads(body2) or {}, uid):
                    rtdb.send('DELETE', member_url)                      # 자리가 없다 — 내 자리를 거둔다
                    self._prune_stale(rtdb, code, token, uid)
                    raise ChatError(t('방이 가득 찼어요 (최대 5명)', 'The room is full (max 5)'))
            if status != 200:
                raise ChatError(t(f'서버 오류 ({status})', f'Server error ({status})'))
        except ChatError as e:
            self.status = 'off'
            self.last_error = str(e)
            self._notify()
            return
        except Exception as e:
            self.status = 'off'
            self.last_error = str(e)
            self._notify()
            return

        with self._lock:
            self._rtdb, self._uid = rtdb, uid
            self._gen += 1
            self.room_code = code
            self._member_tree, self._message_tree = RTDBTree(), RTDBTree()
            self._messages_loaded = False
            self._seen_change, self.received_at = {}, {}
            self.messages, self.members = [], []
        self.persist.set('chat.lastRoom', code)
        self._start_streams()
        self._start_beat()
        self._notify()

    def leave(self, forget=True):
        """방에서 나온다. forget이면 다음 실행 때 자동으로 다시 들어가지 않는다."""
        with self._lock:
            rtdb, uid, code = self._rtdb, self._uid, self.room_code
            keys, self._pending_keys = list(self._pending_keys), set()
            self._gen += 1
            self._stop_streams()
            self._stop_beat()
            self.room_code, self.members, self.messages = None, [], []
            self.received_at, self.status = {}, 'off'
            self._rtdb = self._uid = None
        if forget:
            self.persist.remove('chat.lastRoom')
        if rtdb and uid and code:
            def bye():                                # 내 자리를 비운다 (실패해도 90초 뒤 다른 사람이 정리한다)
                for k in keys:                        # 남아 있는 내 메시지도 함께 지운다
                    self._delete_message(k, code, rtdb)
                try:
                    rtdb.send('DELETE', rtdb.url(f'rooms/{code}/members/{uid}', self.cloud.valid_id_token()), timeout=4)
                except Exception:
                    pass
            threading.Thread(target=bye, daemon=True).start()
        self._notify()

    def leave_blocking(self):
        """앱을 끝낼 때 — 자리를 비우는 요청이 나갈 때까지 잠깐 기다린다."""
        rtdb, uid, code = self._rtdb, self._uid, self.room_code
        if rtdb and uid and code:
            for k in list(self._pending_keys):
                self._delete_message(k, code, rtdb)
            try:
                rtdb.send('DELETE', rtdb.url(f'rooms/{code}/members/{uid}', self.cloud.valid_id_token()), timeout=2)
            except Exception:
                pass

    def _prune_stale(self, rtdb, code, token, uid):
        try:
            status, body = rtdb.send('GET', rtdb.url(f'rooms/{code}/members', token, shallow='true'))
            others = [k for k in (json.loads(body) or {}) if k != uid] if status == 200 else []
        except Exception:
            return
        for other in others:
            try:
                rtdb.send('DELETE', rtdb.url(f'rooms/{code}/members/{other}', token))   # 활동 중이면 규칙이 거절한다
            except Exception:
                pass

    # ── 대화 ────────────────────────────────────────────────

    def send(self, raw: str):
        text = (raw or '').strip()[:MAX_TEXT]
        rtdb, uid, code = self._rtdb, self._uid, self.room_code
        if not text or not rtdb or not code or time.time() - self._last_send < 0.4:     # 연타 방지
            return
        self._last_send = time.time()
        name = self.display_name

        def post():
            try:
                status, body = rtdb.send('POST', rtdb.url(f'rooms/{code}/messages', self.cloud.valid_id_token()),
                                         {'uid': uid, 'name': name, 'text': text, 'ts': SERVER_TIME})
                if status != 200:
                    self._fail(self.t(f'서버 오류 ({status})', f'Server error ({status})'))
                    return
                key = (json.loads(body) or {}).get('name')
                if key:
                    self._pending_keys.add(key)
                    timer = threading.Timer(MESSAGE_LIFETIME, self._delete_message, (key, code, rtdb))
                    timer.daemon = True
                    timer.start()
            except Exception as e:
                self._fail(str(e))
        threading.Thread(target=post, daemon=True).start()

    def _delete_message(self, key, code, rtdb):
        """보낸 메시지를 서버에서 지운다 (이미 지워졌거나 방을 나갔으면 아무 일도 없다)."""
        self._pending_keys.discard(key)
        if not rtdb:
            return
        try:
            rtdb.send('DELETE', rtdb.url(f'rooms/{code}/messages/{key}', self.cloud.valid_id_token()), timeout=4)
        except Exception:
            pass

    def _purge_leftovers(self, old):
        """들어올 때 남아 있던 지난 메시지(앱이 꺼지면서 못 지운 것)는 서버에서도 지운다."""
        rtdb, uid, code = self._rtdb, self._uid, self.room_code
        now_ms = time.time() * 1000
        doomed = [m['id'] for m in old if m['uid'] == uid or now_ms - m['ts'] > 60_000]
        if not (rtdb and code and doomed):
            return

        def run():
            for k in doomed:
                self._delete_message(k, code, rtdb)
        threading.Thread(target=run, daemon=True).start()

    # ── 내 모션 · 프로필 ────────────────────────────────────

    def set_motion(self, motion: str):
        """내 세션들을 요약한 모션 — 하나라도 작업 중이면 working, 아니면 완료가 있으면 done."""
        if motion == self.motion:
            return
        self.motion = motion
        if self.is_in_room:
            self.push_profile()

    def _profile(self) -> dict:
        equip = dict(self.shop.equipped.get(self.character, {}))
        p = {'name': self.display_name, 'char': self.character,
             'motion': self.motion, 'seen': SERVER_TIME, 'level': int(self.shop.level)}
        p['equip'] = equip or None                 # 다 벗으면 서버에서도 지운다 (null)
        return p

    def _local_member(self, m: dict) -> dict:
        """내 칸은 서버를 거쳐 돌아오기를 기다리지 않고 이 PC의 값으로 바로 그린다."""
        return dict(m, name=self.display_name, char=self.character, level=int(self.shop.level),
                    equip=dict(self.shop.equipped.get(self.character, {})))

    def _profile_sig(self):
        eq = self.shop.equipped.get(self.character, {})
        return (self.display_name, self.character, int(self.shop.level), tuple(sorted(eq.items())))

    def sync_profile(self):
        """이름·캐릭터·옷차림·레벨이 바뀌었으면 바로 서버에 올린다 (20초 생존 신호를 기다리지 않는다)."""
        sig = self._profile_sig()
        if sig != getattr(self, '_pushed_sig', None):
            first = getattr(self, '_pushed_sig', None) is None
            self._pushed_sig = sig
            if not first and self.is_in_room:
                self.push_profile()

    def push_profile(self):
        """닉네임·캐릭터·옷차림·모션을 서버에 올린다(생존 신호도 겸한다)."""
        rtdb, uid, code = self._rtdb, self._uid, self.room_code
        if not rtdb or not code:
            return
        payload = self._profile()

        def go():
            try:
                status, _ = rtdb.send('PATCH', rtdb.url(f'rooms/{code}/members/{uid}', self.cloud.valid_id_token()), payload)
                if status == 200:
                    if self.status == 'reconnecting':
                        self.status = 'online'
                        self._notify()
                elif status == 401:                   # 자리를 잃었다(오래 끊겨 정리됨) — 다시 앉는다
                    self.join(code, silent=True)
            except Exception:
                if self.status == 'online':
                    self.status = 'reconnecting'
                    self._notify()
        threading.Thread(target=go, daemon=True).start()

    # ── 스트림 ──────────────────────────────────────────────

    def _start_streams(self):
        gen = self._gen
        rtdb, code = self._rtdb, self.room_code
        if not rtdb or not code:
            return

        def go():
            try:
                token = self.cloud.valid_id_token()
            except Exception:
                self._ended('failed', gen)
                return
            if gen != self._gen:
                return
            self._stop_streams()
            ms, mg = Stream(), Stream()
            ms.start(rtdb.url(f'rooms/{code}/members', token),
                     lambda k, p, v: self._apply_members(k, p, v, gen), lambda kind: self._ended(kind, gen))
            mg.start(rtdb.url(f'rooms/{code}/messages', token, orderBy='"$key"', limitToLast='10'),
                     lambda k, p, v: self._apply_messages(k, p, v, gen), lambda kind: self._ended(kind, gen))
            self._streams = [ms, mg]
            if self.status != 'online':
                self.status = 'online'
                self._notify()
        threading.Thread(target=go, daemon=True).start()

    def _stop_streams(self):
        for s in self._streams:
            s.stop()
        self._streams = []

    def _ended(self, kind, gen):
        if gen != self._gen or not self.is_in_room:
            return
        self.status = 'reconnecting'
        self._notify()

        def retry():
            time.sleep(3)                             # 토큰이 끝났거나 연결이 끊겼다 — 새 토큰으로 다시 잇는다
            if gen == self._gen and self.is_in_room:
                self._start_streams()
        threading.Thread(target=retry, daemon=True).start()

    def _apply_members(self, kind, path, value, gen):
        with self._lock:
            if gen != self._gen:
                return
            if kind == 'patch' and isinstance(value, dict):
                self._member_tree.patch(path, value)
            else:
                self._member_tree.put(path, value)
        self.refresh_members()

    def _apply_messages(self, kind, path, value, gen):
        with self._lock:
            if gen != self._gen:
                return
            before = {m['id'] for m in decode_messages(self._message_tree.children)}
            if kind == 'patch' and isinstance(value, dict):
                self._message_tree.patch(path, value)
            else:
                self._message_tree.put(path, value)
            allm = decode_messages(self._message_tree.children)[-50:]
            # 처음 받은 묶음은 지난 대화 — 말풍선으로 띄우지 않는다. 그 뒤에 온 것만 새 메시지다.
            initial = not self._messages_loaded
            self._messages_loaded = True
            stamps = dict(self.received_at)
            for m in allm:
                if m['id'] not in before:
                    stamps[m['id']] = 0.0 if initial else time.time()
            ids = {m['id'] for m in allm}
            self.received_at = {k: v for k, v in stamps.items() if k in ids}
            self.messages = allm
        if initial:
            self._purge_leftovers(allm)
        self._notify()

    # ── 접속자 ──────────────────────────────────────────────

    def refresh_members(self):
        now = time.time()
        with self._lock:
            uid = self._uid
            visible = []
            for m in decode_members(self._member_tree.children):
                # 생존 신호(seen)가 한동안 안 바뀐 사람은 떠난 것으로 본다 (이 PC 시계로 변화만 본다)
                prev = self._seen_change.get(m['uid'])
                if not prev or prev[0] != m['seen']:
                    self._seen_change[m['uid']] = (m['seen'], now)
                fresh = now - self._seen_change[m['uid']][1] < STALE_AFTER
                if m['uid'] == uid or fresh:
                    visible.append(m)
            # 나를 맨 앞에, 나머지는 uid 순서로 고정
            visible.sort(key=lambda m: (m['uid'] != uid, m['uid']))
            changed = visible != self.members
            self.members = visible
        if changed:
            self._notify()

    # ── 주기 작업 ───────────────────────────────────────────

    def _start_beat(self):
        self._stop_beat()
        gen = self._gen
        stop = threading.Event()
        self._beat = stop

        def loop():
            last_token_restart = time.time()
            while not stop.wait(HEARTBEAT):
                if gen != self._gen:
                    return
                self.push_profile()
                self.refresh_members()
                if time.time() - last_token_restart > TOKEN_REFRESH:
                    last_token_restart = time.time()
                    self._start_streams()
        threading.Thread(target=loop, daemon=True).start()

    def _stop_beat(self):
        if self._beat:
            self._beat.set()
            self._beat = None
