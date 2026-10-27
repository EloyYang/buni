#!/usr/bin/env python3
"""
Buni for Windows v1.5.0
Claude Code companion – pixel-art rabbit mascot
https://github.com/EloyYang/buni
"""
import tkinter as tk
from tkinter import simpledialog
from tkinter import font as tkfont
import threading
import json, time, os, sys, math, glob, random, re, base64, shutil, uuid
import ctypes, datetime, queue
from pathlib import Path

import buni_shop
import buni_items

# ── Pixel unit (matches macOS p = 6.5)
P = 6.5

# ── Window geometry
WIN_W, WIN_H = 340, 240
CHAR_CX      = WIN_W - 52    # character center-X
CHAR_CY      = WIN_H - 80    # character center-Y
SLOT_STEP    = WIN_H + 8     # vertical spacing between session slots

# ── Transparent key color
TRANSP = '#010101'

# ── Character palettes: (body, ear, nose, extras_dict)
#    extras keys: 'brow' (hex color), 'blush' (bool)
CHARACTERS = {
    'rabbit':       ('#E8E8F0', '#F3B8C7', '#E09090', {}),
    'brownRabbit':  ('#9A6633', '#C47844', '#C47844', {'brow': '#35180A'}),
    'pinkRabbit':   ('#FAC7E0', '#FFEAF5', '#F25999', {}),
    'orangeRabbit': ('#F28520', '#FFD199', '#FFE6CC', {}),
    'yellowRabbit': ('#F5DB38', '#FFF5B8', '#FFF2BF', {'blush': True}),
    'greenRabbit':  ('#73CC61', '#C7F2AD', '#D1F2C7', {}),
}
#    (한국어, English) — 표시 언어에 따라 골라 쓴다 (char_display_name)
CHAR_DISPLAY_NAMES = {
    'rabbit':       ('부니 (흰토끼)',   'Buni (white)'),
    'brownRabbit':  ('두니 (갈색토끼)', 'Duni (brown)'),
    'pinkRabbit':   ('푸니 (핑크토끼)', 'Puni (pink)'),
    'orangeRabbit': ('주니 (주황토끼)', 'Juni (orange)'),
    'yellowRabbit': ('누니 (노란토끼)', 'Nuni (yellow)'),
    'greenRabbit':  ('우니 (연두토끼)', 'Uni (green)'),
}

# ── Tool classification: read tools → toolRead state
READ_TOOLS = {'read', 'glob', 'grep', 'ls', 'webfetch', 'websearch', 'todoread'}

# ── Laptop colors (from LaptopView.swift)
LAP_SILVER = '#C2C2CC'  # silverCol rgb(0.76,0.76,0.80)
LAP_HI     = '#E0E0EB'  # silverHi  rgb(0.88,0.88,0.92)
LAP_DARK   = '#808089'  # silverDark rgb(0.50,0.50,0.54)
LAP_MID    = '#A3A3AD'  # silverMid  rgb(0.64,0.64,0.68)
LAP_CARROT = '#F28C2E'  # carrotCol  rgb(0.95,0.55,0.18)
LAP_LEAF   = '#66B359'  # leafCol    rgb(0.40,0.70,0.35)

# ── Document colors (from DocumentView.swift)
DOC_PAPER  = '#EDE3C7'  # paperCol  rgb(0.93,0.89,0.78)
DOC_DARK   = '#CCC1A6'  # paperDark rgb(0.80,0.76,0.65)
DOC_LINE_H = '#8C8069'  # lineHeavy rgb(0.55,0.50,0.42)
DOC_LINE_L = '#9E9078'  # lineLight (lighter)
TAB_PINK   = '#FA6699'
TAB_YELLOW = '#FAD633'
TAB_GREEN  = '#47BF59'

# ── Paths
_TEMP      = Path(os.environ.get('TEMP', os.environ.get('TMP', 'C:/temp')))
STATE_FILE = Path.home() / 'AppData' / 'Roaming' / 'Buni' / 'state.json'
PID_FILE   = _TEMP / 'buni.pid'


# ══════════════════════════════════════════════════════════════
# 표시 언어 (한국어 / English)
# ══════════════════════════════════════════════════════════════
# buni.py는 앱으로도, Claude Code 훅(--hook)으로도 실행되는데 훅은 별도
# 프로세스라 앱 메모리를 못 본다. 그래서 언어는 state.json에서 직접 읽는다.

_LANG = {'value': None}


def _detect_system_lang() -> str:
    """시스템 언어가 한국어면 'ko', 아니면 'en'."""
    try:
        import locale
        loc = (locale.getdefaultlocale()[0] or '')
    except Exception:
        loc = ''
    if not loc:
        loc = os.environ.get('LANG', '')
    return 'ko' if loc.lower().startswith('ko') else 'en'


def get_lang() -> str:
    """현재 표시 언어 ('ko' | 'en'). 저장값 → 없으면 시스템 언어."""
    if _LANG['value'] is None:
        saved = None
        try:
            if STATE_FILE.exists():
                saved = json.loads(
                    STATE_FILE.read_text(encoding='utf-8')).get('language')
        except Exception:
            saved = None
        _LANG['value'] = saved if saved in ('ko', 'en') else _detect_system_lang()
    return _LANG['value']


def set_lang(lang: str):
    """언어를 바꾸고 state.json에 저장한다 (훅 프로세스도 같은 파일을 읽는다)."""
    _LANG['value'] = 'en' if lang == 'en' else 'ko'
    try:
        data = {}
        if STATE_FILE.exists():
            data = json.loads(STATE_FILE.read_text(encoding='utf-8'))
        data['language'] = _LANG['value']
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False),
                              encoding='utf-8')
    except Exception:
        pass


def t(ko: str, en: str) -> str:
    """문구가 수십 개뿐이라 별도 키 없이 두 언어를 나란히 적는다."""
    return en if get_lang() == 'en' else ko


def char_display_name(char_id: str) -> str:
    names = CHAR_DISPLAY_NAMES.get(char_id)
    if not names:
        return char_id
    return names[1] if get_lang() == 'en' else names[0]

# ══════════════════════════════════════════════════════════════
# Claude Code 훅 자동 설치 (최초 실행 시 1회, 멱등)
# ══════════════════════════════════════════════════════════════

_CLAUDE_DIR = Path.home() / '.claude'

# ── 내장 훅 스크립트 ─────────────────────────────────────────

_HOOK_PRETOOL = '''\
#!/usr/bin/env python3
import sys, json, os, uuid, time
from pathlib import Path

TEMP = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/temp")))
PID_FILE = TEMP / "buni.pid"
SAFE_TOOLS = {"Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch",
              "TodoRead", "NotebookRead", "AskUserQuestion"}
BUNI_PORT = 58765


def _is_buni_running():
    try:
        pid = int(PID_FILE.read_text(encoding="utf-8").strip())
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x0400, False, pid)
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
        return False
    except Exception:
        return False


def _events_file(session_id):
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{safe}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    tool_name  = d.get("tool_name", "tool")
    tool_input = d.get("tool_input", {}) or {}
    session_id = d.get("session_id", "")
    events     = _events_file(session_id)
    is_remote  = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    if is_remote:
        # SSH Remote — 권한 UI 없이 tool_use 이벤트만 TCP 전송
        _send_tcp({"type": "tool_use", "tool": tool_name, "session_id": session_id})
    else:
        if not events.exists():
            events.touch()

        if tool_name in SAFE_TOOLS or not _is_buni_running():
            with events.open("a", encoding="utf-8") as f:
                f.write(json.dumps({"type": "tool_use", "tool": tool_name}) + "\\n")
        else:
            if tool_name == "Bash":
                message = tool_input.get("command", "")[:200]
            elif tool_name == "Write":
                path = tool_input.get("file_path", tool_input.get("path", ""))
                message = f"[파일 쓰기] {path}"[:200]
            elif tool_name in ("Edit", "MultiEdit"):
                path = tool_input.get("file_path", tool_input.get("path", ""))
                message = f"[파일 수정] {path}"[:200]
            else:
                first_val = next(iter(tool_input.values()), "") if tool_input else ""
                message = f"[{tool_name}] {first_val}"[:200] if first_val else tool_name

            req_id    = str(uuid.uuid4())[:8]
            resp_file = TEMP / f"claude-companion-decision-{req_id}"

            with events.open("a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "type":    "permission_request",
                    "id":      req_id,
                    "tool":    tool_name,
                    "message": message,
                    "ts":      time.time()
                }) + "\\n")

            approved = True
            for _ in range(120):
                if resp_file.exists():
                    try:
                        decision = resp_file.read_text(encoding="utf-8").strip()
                        resp_file.unlink(missing_ok=True)
                        approved = (decision != "deny")
                    except Exception:
                        pass
                    break
                time.sleep(0.5)

            if not approved:
                print(json.dumps({"decision": "block", "reason": "사용자가 거부했습니다."}))
                sys.exit(2)

            with events.open("a", encoding="utf-8") as f:
                f.write(json.dumps({"type": "tool_use", "tool": tool_name}) + "\\n")

except Exception:
    pass
'''

_HOOK_POSTTOOL = '''\
#!/usr/bin/env python3
import sys, json, os
from pathlib import Path

TEMP = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/temp")))
BUNI_PORT = 58765


def _events_file(session_id):
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{safe}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    is_remote  = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    if is_remote:
        _send_tcp({"type": "tool_done", "session_id": session_id})
    else:
        events = _events_file(session_id)
        with events.open("a", encoding="utf-8") as f:
            f.write(\'{"type":"tool_done"}\\n\')
except Exception:
    pass
'''

_HOOK_NOTIFICATION = '''\
#!/usr/bin/env python3
import sys, json, os, time
from pathlib import Path

TEMP = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/temp")))
BUNI_PORT = 58765


def _events_file(session_id):
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{safe}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    msg        = d.get("message", "알림")[:120]
    is_remote  = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))
    event      = {"type": "notification", "message": msg, "ts": time.time()}

    if is_remote:
        event["session_id"] = session_id
        _send_tcp(event)
    else:
        events = _events_file(session_id)
        with events.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event) + "\\n")
except Exception:
    pass
'''

_HOOK_STOP = '''\
#!/usr/bin/env python3
import sys, json, os
from pathlib import Path

TEMP = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/temp")))
BUNI_PORT = 58765


def _events_file(session_id):
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{safe}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    is_remote  = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    if is_remote:
        _send_tcp({"type": "done", "session_id": session_id})
    else:
        events = _events_file(session_id)
        with events.open("a", encoding="utf-8") as f:
            f.write(\'{"type":"done"}\\n\')
except Exception:
    pass
'''

_HOOK_PROMPT = '''\
#!/usr/bin/env python3
import sys, json, os, time
from pathlib import Path

TEMP = Path(os.environ.get("TEMP", os.environ.get("TMP", "C:/temp")))
BUNI_PORT = 58765


def _events_file(session_id):
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{safe}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    is_remote  = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))
    event      = {"type": "thinking", "ts": time.time()}

    if is_remote:
        event["session_id"] = session_id
        _send_tcp(event)
    else:
        events = _events_file(session_id)
        with events.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event) + "\\n")
except Exception:
    pass
'''


def _run_hook(hook_type: str):
    """Claude Code 훅으로 호출될 때 실행 (GUI 없이 경량 동작).
    예: Buni-Windows.exe --hook pretool
    Python 설치 불필요 — exe 자체가 훅을 처리한다.
    """
    try:
        raw = sys.stdin.buffer.read()
        d   = json.loads(raw.decode('utf-8', errors='replace'))
    except Exception:
        sys.exit(0)

    session_id = d.get('session_id', '') or 'legacy'
    safe_sid   = ''.join(c for c in session_id if c.isalnum() or c in '-_') or 'legacy'
    ef         = _TEMP / f'claude-companion-events-{safe_sid}.jsonl'
    is_remote  = bool(os.environ.get('SSH_CLIENT') or os.environ.get('SSH_TTY'))
    perm_mode  = d.get('permission_mode', '') or ''  # default/auto/acceptEdits/bypassPermissions/plan

    def _write(ev):
        try:
            if not ef.exists():
                ef.touch()
            with ef.open('a', encoding='utf-8') as f:
                f.write(json.dumps(ev, ensure_ascii=False) + '\n')
        except Exception:
            pass

    def _tcp(ev):
        try:
            import socket as _s
            s = _s.socket(_s.AF_INET, _s.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(('127.0.0.1', 58765))
            payload = dict(ev); payload['session_id'] = session_id
            s.sendall((json.dumps(payload) + '\n').encode('utf-8'))
            s.close()
        except Exception:
            pass

    emit = _tcp if is_remote else _write

    if hook_type == 'prompt':
        emit({'type': 'thinking', 'ts': time.time()})

    elif hook_type == 'posttool':
        emit({'type': 'tool_done'})

    elif hook_type == 'stop':
        # 백그라운드 작업이 아직 돌고 있으면 완료가 아니라 "백그라운드 작업 중"으로
        # 표시 — Stop 훅은 클로드 응답 한 턴이 끝날 때마다 오는데, run_in_background로
        # 띄운 작업은 그 뒤에도 계속 실행될 수 있어 완료 문구를 그대로 띄우면 오해를 준다.
        running = [t for t in (d.get('background_tasks') or [])
                   if t.get('status') == 'running']
        if running:
            desc = running[0].get('description') or running[0].get('command', '')
            emit({'type': 'background', 'count': len(running), 'message': desc[:80]})
        else:
            emit({'type': 'done'})

    elif hook_type == 'notification':
        msg = d.get('message', t(t('알림', 'Notification'), 'Notification'))[:120]
        emit({'type': 'notification', 'message': msg, 'ts': time.time()})

    elif hook_type == 'pretool':
        tool  = d.get('tool_name', 'tool')
        inp   = d.get('tool_input', {}) or {}
        SAFE  = {'Read', 'Glob', 'Grep', 'LS', 'WebSearch', 'WebFetch',
                 'TodoRead', 'NotebookRead', 'AskUserQuestion'}
        # 클로드 자체가 이미 자동 승인하는 모드에서는 부니 게이트를 건너뛴다
        # (클로드가 안 묻는데 부니만 물어보는 문제 방지)
        AUTO_APPROVE_MODES = {'auto', 'bypassPermissions'}
        EDIT_TOOLS = {'Write', 'Edit', 'MultiEdit', 'NotebookEdit'}
        skip_gate = (perm_mode in AUTO_APPROVE_MODES or
                     (perm_mode == 'acceptEdits' and tool in EDIT_TOOLS))

        if tool == 'AskUserQuestion':
            # 터미널에 선택지가 나타날 예정 → 부니에 확인 요청 버블 표시.
            # 질문 내용까지 같이 보내야 터미널을 안 보고도 뭘 묻는지 알 수 있다.
            qs = inp.get('questions') or []
            q  = qs[0] if isinstance(qs, list) and qs and isinstance(qs[0], dict) else {}
            question = str(q.get('question') or q.get('header') or '').strip()[:120]
            if len(qs) > 1:
                question = f'{question} (+{len(qs) - 1})'
            emit({'type': 'ask_user', 'message': question, 'ts': time.time()})
        elif tool in SAFE or is_remote or skip_gate:
            emit({'type': 'tool_use', 'tool': tool})
        else:
            if tool == 'Bash':
                msg = inp.get('command', '')[:200]
            elif tool == 'Write':
                msg = f"{t('[파일 쓰기]', '[Write]')} {inp.get('file_path', inp.get('path',''))}"[:200]
            elif tool in ('Edit', 'MultiEdit'):
                msg = f"{t('[파일 수정]', '[Edit]')} {inp.get('file_path', inp.get('path',''))}"[:200]
            else:
                fv  = next(iter(inp.values()), '') if inp else ''
                msg = f'[{tool}] {fv}'[:200] if fv else tool

            req_id = str(uuid.uuid4())[:8]
            rf     = _TEMP / f'claude-companion-decision-{req_id}'
            _write({'type': 'permission_request', 'id': req_id,
                    'tool': tool, 'message': msg, 'ts': time.time()})

            approved = True
            for _ in range(120):
                if rf.exists():
                    try:
                        dec = rf.read_text(encoding='utf-8').strip()
                        rf.unlink(missing_ok=True)
                        approved = (dec != 'deny')
                    except Exception:
                        pass
                    break
                time.sleep(0.5)

            if not approved:
                print(json.dumps({'decision': 'block', 'reason': t('사용자가 거부했습니다.', 'The user denied this.')}))
                sys.exit(2)

            _write({'type': 'tool_use', 'tool': tool})

    sys.exit(0)


def _tcp_event_server(manager: 'BuniManager'):
    """SSH Remote 이벤트 수신용 TCP 서버 (127.0.0.1:58765)."""
    import socket as _sock
    try:
        srv = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
        srv.setsockopt(_sock.SOL_SOCKET, _sock.SO_REUSEADDR, 1)
        srv.bind(('127.0.0.1', 58765))
        srv.listen(10)
        srv.settimeout(1.0)
    except Exception:
        return

    def _handle(conn):
        buf = b''
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
        except Exception:
            pass
        finally:
            conn.close()
        for raw in buf.decode('utf-8', errors='replace').splitlines():
            line = raw.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                sid = ev.get('session_id', '')
                if not sid:
                    continue
                safe = ''.join(c for c in sid if c.isalnum() or c in '-_')
                if not safe:
                    continue
                event_file = _TEMP / f'claude-companion-events-{safe}.jsonl'
                with event_file.open('a', encoding='utf-8') as f:
                    f.write(line + '\n')
                manager.root.after(0, lambda s=safe, fp=event_file: (
                    manager._add_session(s, fp) if s not in manager.sessions else None
                ))
            except Exception:
                pass

    while True:
        try:
            conn, _ = srv.accept()
            threading.Thread(target=_handle, args=(conn,), daemon=True).start()
        except _sock.timeout:
            continue
        except Exception:
            break


# VS Code 및 형제 에디터(Insiders, Cursor, VSCodium) — 사용자가 어느 걸 SSH
# Remote에 쓰는지 알 수 없으니 설치돼 있는 건 다 패치한다.
_VSCODE_VARIANT_DIR_NAMES = ['Code', 'Code - Insiders', 'Cursor', 'VSCodium']


def _patch_vscode_settings():
    """VS Code(및 형제 에디터) settings.json에 SSH RemoteForward 설정 자동 추가."""
    appdata = Path(os.environ.get('APPDATA', ''))
    for dir_name in _VSCODE_VARIANT_DIR_NAMES:
        _patch_one_vscode_settings(appdata / dir_name / 'User')


def _patch_one_vscode_settings(vscode_dir):
    if not vscode_dir.exists():
        return
    settings_path = vscode_dir / 'settings.json'
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text(encoding='utf-8'))
        except Exception:
            return  # JSONC 등 파싱 불가 시 스킵
    else:
        settings = {}
    args = settings.get('remote.SSH.extraArgs', [])
    if not isinstance(args, list):
        args = []
    for i in range(len(args) - 1):
        if args[i] == '-R' and args[i + 1] == '58765:localhost:58765':
            return  # 이미 설정됨
    args.extend(['-R', '58765:localhost:58765'])
    settings['remote.SSH.extraArgs'] = args
    try:
        settings_path.write_text(
            json.dumps(settings, indent=2, ensure_ascii=False), encoding='utf-8')
    except Exception:
        pass


def _ensure_hooks_installed():
    """Buni 실행 시 Claude Code 훅 자동 설치/갱신.
    Python 설치 불필요 — Buni exe 자체를 훅 핸들러로 사용한다.
    exe 경로가 바뀌면(이동/재설치) 자동으로 훅 명령 갱신.
    """
    settings_path = _CLAUDE_DIR / 'settings.json'
    exe_path      = str(Path(sys.executable).resolve())

    # 현재 exe 경로로 이미 설치돼 있으면 스킵
    try:
        if settings_path.exists():
            d   = json.loads(settings_path.read_text(encoding='utf-8'))
            pre = d.get('hooks', {}).get('PreToolUse', [])
            for entry in pre:
                for h in entry.get('hooks', []):
                    cmd = h.get('command', '').replace('\\', '/')
                    if '--hook pretool' in cmd and exe_path.replace('\\', '/') in cmd:
                        _patch_vscode_settings()
                        return
    except Exception:
        pass

    try:
        _CLAUDE_DIR.mkdir(parents=True, exist_ok=True)

        if settings_path.exists():
            try:
                settings = json.loads(settings_path.read_text(encoding='utf-8'))
            except Exception:
                settings = {}
        else:
            settings = {}

        def _hook(htype):
            # exe 자체를 --hook 모드로 호출 (Python 설치 불필요)
            return {'type': 'command', 'command': f'"{exe_path}" --hook {htype}'}

        additions = [
            ('PreToolUse',       'pretool'),
            ('PostToolUse',      'posttool'),
            ('Notification',     'notification'),
            ('Stop',             'stop'),
            ('UserPromptSubmit', 'prompt'),
        ]
        existing = settings.get('hooks', {})
        for event, htype in additions:
            # 기존 Buni 훅 제거 (Python 스크립트·이전 exe 경로 모두)
            prev = [e for e in existing.get(event, [])
                    if not any('companion-' in str(h) or '--hook' in str(h)
                               for h in e.get('hooks', []))]
            existing[event] = prev + [{'matcher': '', 'hooks': [_hook(htype)]}]
        settings['hooks'] = existing

        settings_path.write_text(
            json.dumps(settings, indent=2, ensure_ascii=False),
            encoding='utf-8'
        )
    except Exception:
        pass  # 훅 설치 실패해도 Buni는 동작

    _patch_vscode_settings()


# ── Windows API for click-through transparent window
_u32              = ctypes.windll.user32
GWL_EXSTYLE       = -20
WS_EX_LAYERED     = 0x00080000
WS_EX_TRANSPARENT = 0x00000020


def _get_hwnd(widget: tk.Widget) -> int:
    return _u32.GetParent(widget.winfo_id())


def _set_click_through(hwnd: int, enable: bool) -> None:
    style = _u32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    if enable:
        style |= WS_EX_LAYERED | WS_EX_TRANSPARENT
    else:
        style = (style | WS_EX_LAYERED) & ~WS_EX_TRANSPARENT
    _u32.SetWindowLongW(hwnd, GWL_EXSTYLE, style)


# ── 메모 태그 텍스트 ──────────────────────────────────────────
# Malgun Gothic은 같은 포인트 크기라도 macOS의 SF Rounded보다 시각적으로
# 크게 보여서, 8pt로 한 단계 낮춰 macOS 10pt semibold rounded와 크기를 맞췄다.
_memo_font_cache = None


def _memo_font():
    """tkinter.font.Font는 Tk 루트가 생긴 뒤에만 만들 수 있어 지연 생성 + 캐시."""
    global _memo_font_cache
    if _memo_font_cache is None:
        _memo_font_cache = tkfont.Font(family='Malgun Gothic', size=8, weight='bold')
    return _memo_font_cache


def _wrap_memo_lines(text, font, max_width_px, max_lines=2):
    """세션 이름이 길어져도 메모가 잘려 보이지 않도록, 단어 단위로 최대
    max_lines줄까지 감싸고 그래도 넘치면 마지막 줄 끝을 잘라 … 를 붙인다."""
    words = text.split()
    if not words:
        return []

    lines, current, i = [], '', 0
    while i < len(words) and len(lines) < max_lines:
        w = words[i]
        trial = f'{current} {w}'.strip()
        if not current or font.measure(trial) <= max_width_px:
            current = trial
            i += 1
        else:
            lines.append(current)
            current = ''
    if len(lines) < max_lines and current:
        lines.append(current)
        current = ''

    leftover_words = i < len(words)
    last_too_wide  = bool(lines) and font.measure(lines[-1]) > max_width_px

    if leftover_words or last_too_wide or current:
        last = lines.pop() if lines else ''
        if current:
            last = f'{last} {current}'.strip() if last else current
        while last and font.measure(last + '…') > max_width_px:
            last = last[:-1].rstrip()
        lines.append((last + '…') if last else '…')

    return lines[:max_lines]


# ══════════════════════════════════════════════════════════════
class GlobalHotkeyManager:
    """Windows RegisterHotKey 기반 전역 단축키 관리자."""

    WM_HOTKEY    = 0x0312
    MOD_ALT      = 0x0001
    MOD_CTRL     = 0x0002
    MOD_SHIFT    = 0x0004
    MOD_WIN      = 0x0008
    MOD_NOREPEAT = 0x4000

    _VK_NAMES: dict = {
        0x08:'Back', 0x09:'Tab', 0x0D:'Enter', 0x1B:'Esc', 0x20:'Space',
        0x25:'←', 0x26:'↑', 0x27:'→', 0x28:'↓',
        **{0x70+i: f'F{i+1}' for i in range(12)},
        **{0x41+i: chr(65+i)  for i in range(26)},
        **{0x30+i: str(i)      for i in range(10)},
    }

    def __init__(self):
        self._pending : list  = []
        self._lock            = threading.Lock()
        self._q               = queue.SimpleQueue()
        self._reg    : dict   = {}   # action → (mods, vk, hid)
        self._id_map : dict   = {}   # hid → action
        self._next_id         = 300
        self._callbacks: dict = {}

    @classmethod
    def label(cls, mods: int, vk: int) -> str:
        parts = []
        if mods & cls.MOD_CTRL:  parts.append('Ctrl')
        if mods & cls.MOD_ALT:   parts.append('Alt')
        if mods & cls.MOD_SHIFT: parts.append('Shift')
        if mods & cls.MOD_WIN:   parts.append('Win')
        parts.append(cls._VK_NAMES.get(vk, f'[{vk}]'))
        return '+'.join(parts)

    def set_shortcut(self, action: str, mods: int, vk: int):
        with self._lock:
            self._pending.append(('set', action, mods, vk))

    def clear_shortcut(self, action: str):
        with self._lock:
            self._pending.append(('clear', action))

    def start(self, tk_root: tk.Tk, callbacks: dict):
        self._callbacks = callbacks
        threading.Thread(target=self._loop, daemon=True).start()
        self._poll(tk_root)

    def _poll(self, tk_root: tk.Tk):
        try:
            while True:
                action = self._q.get_nowait()
                cb = self._callbacks.get(action)
                if cb:
                    cb()
        except queue.Empty:
            pass
        tk_root.after(50, lambda: self._poll(tk_root))

    def _loop(self):
        class _P(ctypes.Structure):
            _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]
        class _M(ctypes.Structure):
            _fields_ = [
                ('hwnd',    ctypes.c_void_p),
                ('message', ctypes.c_uint),
                ('wParam',  ctypes.c_size_t),
                ('lParam',  ctypes.c_ssize_t),
                ('time',    ctypes.c_ulong),
                ('pt',      _P),
            ]
        u32 = ctypes.windll.user32
        msg = _M()
        while True:
            with self._lock:
                pending, self._pending = self._pending[:], []
            for item in pending:
                op = item[0]
                if op == 'set':
                    _, action, mods, vk = item
                    if action in self._reg and self._reg[action][2] != -1:
                        u32.UnregisterHotKey(None, self._reg[action][2])
                        self._id_map.pop(self._reg[action][2], None)
                    hid = self._next_id; self._next_id += 1
                    ok = u32.RegisterHotKey(None, hid, mods | self.MOD_NOREPEAT, vk)
                    if ok:
                        self._reg[action] = (mods, vk, hid)
                        self._id_map[hid] = action
                    else:
                        self._reg[action] = (mods, vk, -1)  # 저장만
                elif op == 'clear':
                    _, action = item
                    if action in self._reg:
                        hid = self._reg[action][2]
                        if hid != -1:
                            u32.UnregisterHotKey(None, hid)
                            self._id_map.pop(hid, None)
                        del self._reg[action]
            if u32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
                if msg.message == self.WM_HOTKEY:
                    action = self._id_map.get(msg.wParam)
                    if action:
                        self._q.put(action)
            else:
                time.sleep(0.005)


# ══════════════════════════════════════════════════════════════
class ShortcutSettingsWindow:
    """전역 단축키 설정 다이얼로그."""

    ACTIONS = [
        ('approve',        ('권한 허락',     'Approve')),
        ('always_approve', (t('전체 허용', 'Allow all'),     'Approve all')),
        ('deny',           ('권한 거부',     'Deny')),
        ('hide',           ('숨기기/보이기', 'Hide / show')),
    ]

    def __init__(self, parent: tk.Tk, persist: 'PersistenceManager',
                 hotkey_mgr: GlobalHotkeyManager, manager: 'BuniManager | None' = None):
        self._manager   = manager
        self._parent    = parent
        self._persist   = persist
        self._hotkey    = hotkey_mgr
        self._shortcuts : dict = {}  # action → (mods, vk) | None
        self._recording : str | None = None
        self._btns      : dict = {}
        self._win       : tk.Toplevel | None = None
        self._load()
        self._build()

    # ── 저장/불러오기 ─────────────────────────────────────
    def _load(self):
        saved = self._persist.get('shortcuts', {})
        defaults = {'approve': (GlobalHotkeyManager.MOD_CTRL, 0x0D)}  # Ctrl+Enter
        for action, _ in self.ACTIONS:
            v = saved.get(action)
            if v:
                self._shortcuts[action] = (v['mods'], v['vk'])
            elif action in defaults:
                self._shortcuts[action] = defaults[action]
            else:
                self._shortcuts[action] = None
        # 초기 단축키 등록
        for action, v in self._shortcuts.items():
            if v:
                self._hotkey.set_shortcut(action, v[0], v[1])

    def _save(self):
        data = {}
        for action, _ in self.ACTIONS:
            v = self._shortcuts.get(action)
            data[action] = {'mods': v[0], 'vk': v[1]} if v else None
        self._persist.set('shortcuts', data)
        for action, _ in self.ACTIONS:
            v = self._shortcuts.get(action)
            if v:
                self._hotkey.set_shortcut(action, v[0], v[1])
            else:
                self._hotkey.clear_shortcut(action)

    # ── UI 구성 ───────────────────────────────────────────
    def _build(self):
        if self._win and self._win.winfo_exists():
            self._win.lift(); self._win.focus_force(); return

        win = tk.Toplevel(self._parent)
        self._win = win
        win.title(t('설정', 'Settings'))
        win.resizable(False, False)
        win.configure(bg='#1E1E24')
        win.protocol('WM_DELETE_WINDOW', self._close)
        win.attributes('-topmost', True)

        tk.Label(win, text=t('설정', 'Settings'), bg='#1E1E24', fg='white',
                 font=('Malgun Gothic', 13, 'bold')).grid(
            row=0, column=0, columnspan=3, pady=(16,4), padx=20, sticky='w')
        tk.Frame(win, bg='#3A3A44', height=1).grid(
            row=1, column=0, columnspan=3, sticky='ew', padx=16, pady=(0,10))

        # ── 언어 선택
        tk.Label(win, text=t('언어', 'Language'), bg='#1E1E24', fg='#CCCCCC',
                 font=('Malgun Gothic', 10), width=11, anchor='w').grid(
            row=2, column=0, padx=(20,8), pady=6, sticky='w')
        lang_box = tk.Frame(win, bg='#1E1E24')
        lang_box.grid(row=2, column=1, columnspan=2, padx=4, pady=6, sticky='w')
        self._lang_btns = {}
        for col, (code, name) in enumerate((('ko', '한국어'), ('en', 'English'))):
            b = tk.Button(lang_box, text=name, relief='flat',
                          font=('Malgun Gothic', 9), width=8, cursor='hand2',
                          activeforeground='white',
                          command=lambda c=code: self._set_lang(c))
            b.grid(row=0, column=col, padx=(0 if col == 0 else 4, 0))
            self._lang_btns[code] = b
        self._refresh_lang_btns()

        tk.Frame(win, bg='#3A3A44', height=1).grid(
            row=3, column=0, columnspan=3, sticky='ew', padx=16, pady=(8,8))

        for i, (action, labels) in enumerate(self.ACTIONS):
            tk.Label(win, text=t(*labels), bg='#1E1E24', fg='#CCCCCC',
                     font=('Malgun Gothic', 10), width=11, anchor='w').grid(
                row=4+i, column=0, padx=(20,8), pady=6, sticky='w')

            btn = tk.Button(win, text=self._btn_text(action),
                            bg='#2A2A34', fg='white', relief='flat',
                            font=('Consolas', 9), width=16,
                            activebackground='#3A3A50', activeforeground='white',
                            cursor='hand2',
                            command=lambda a=action: self._toggle_record(a))
            btn.grid(row=4+i, column=1, padx=4, pady=6)
            self._btns[action] = btn

            tk.Button(win, text='✕', bg='#1E1E24', fg='#FF6666', relief='flat',
                      font=('Consolas', 10), activebackground='#1E1E24',
                      activeforeground='#FF4444', cursor='hand2',
                      command=lambda a=action: self._clear(a)).grid(
                row=4+i, column=2, padx=(2,16), pady=6)

        r = 4 + len(self.ACTIONS)
        if self._manager:
            r = self._build_extra_sections(win, r)
        tk.Frame(win, bg='#3A3A44', height=1).grid(
            row=r, column=0, columnspan=3, sticky='ew', padx=16, pady=(8,4))
        tk.Label(win, text=t('단축키는 전역으로 동작합니다.',
                      'Shortcuts work system-wide.'),
                 bg='#1E1E24', fg='#555566',
                 font=('Malgun Gothic', 8)).grid(
            row=r+1, column=0, columnspan=2, padx=20, sticky='w', pady=(4,0))
        tk.Button(win, text=t('닫기', 'Close'), bg='#3377E0', fg='white', relief='flat',
                  font=('Malgun Gothic', 10), activebackground='#2255BB',
                  activeforeground='white', cursor='hand2', padx=12, pady=3,
                  command=self._close).grid(
            row=r+1, column=2, padx=16, pady=(4,16), sticky='e')

        win.bind('<Escape>', lambda _: self._close())
        win.update_idletasks()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        w, h   = win.winfo_reqwidth(),    win.winfo_reqheight()
        win.geometry(f'+{(sw-w)//2}+{(sh-h)//2}')

    # ── 계정 연동 · 덮개 닫아도 계속 실행 ────────────────────
    def _build_extra_sections(self, win, r: int) -> int:
        """설정 창 아래쪽 두 구역. 다음 빈 행 번호를 돌려준다."""
        import buni_awake
        BG, DIM = '#1E1E24', '#8A8A98'
        mgr = self._manager

        def sep(row):
            tk.Frame(win, bg='#3A3A44', height=1).grid(
                row=row, column=0, columnspan=3, sticky='ew', padx=16, pady=(8, 6))

        # ── 계정 연동 (선택)
        sep(r); r += 1
        tk.Label(win, text=t('계정 연동 (선택)', 'Account sync (optional)'), bg=BG, fg='white',
                 font=('Malgun Gothic', 10, 'bold')).grid(
            row=r, column=0, columnspan=3, padx=20, sticky='w'); r += 1
        self._acct = tk.Frame(win, bg=BG)
        self._acct.grid(row=r, column=0, columnspan=3, sticky='ew', padx=20, pady=(2, 2)); r += 1

        # ── 덮개 닫아도 계속 실행
        sep(r); r += 1
        tk.Label(win, text=t('덮개 닫아도 계속 실행', 'Keep running with lid closed'), bg=BG, fg='white',
                 font=('Malgun Gothic', 10, 'bold')).grid(
            row=r, column=0, columnspan=3, padx=20, sticky='w'); r += 1
        awake = mgr.awake
        if not awake.supported:
            tk.Label(win, text=t('Windows에서만 쓸 수 있어요', 'Only available on Windows'),
                     bg=BG, fg=DIM, font=('Malgun Gothic', 8)).grid(
                row=r, column=0, columnspan=3, padx=20, sticky='w'); r += 1
            self._awake_lbl = None
            return r
        self._awake_lbl = tk.Label(win, bg=BG, font=('Malgun Gothic', 9), anchor='w')
        self._awake_lbl.grid(row=r, column=0, columnspan=3, padx=20, pady=(2, 4), sticky='w'); r += 1

        row = tk.Frame(win, bg=BG)
        row.grid(row=r, column=0, columnspan=3, padx=20, sticky='w'); r += 1
        for i, (minutes, ko, en) in enumerate(buni_awake.DURATIONS):
            tk.Button(row, text=t(ko, en), bg='#2A2A34', fg='white', relief='flat', bd=0,
                      font=('Malgun Gothic', 8), padx=7, pady=3, cursor='hand2',
                      activebackground='#3A3A50', activeforeground='white',
                      command=lambda m=minutes: awake.enable(m)).grid(
                row=0, column=i, padx=(0 if i == 0 else 3, 0))
        self._awake_off = tk.Button(
            row, text=t('끄기', 'Off'), bg='#8A3A3A', fg='white', relief='flat', bd=0,
            font=('Malgun Gothic', 8), padx=7, pady=3, cursor='hand2',
            activebackground='#A04848', activeforeground='white', command=awake.disable)
        self._awake_off.grid(row=0, column=len(buni_awake.DURATIONS), padx=(8, 0))

        # 시간대 예약 — 매일 같은 시간에 자동으로 켜고 끈다
        sch = tk.Frame(win, bg=BG)
        sch.grid(row=r, column=0, columnspan=3, padx=20, pady=(8, 0), sticky='w'); r += 1
        self._sch_var = tk.BooleanVar(value=awake.schedule_enabled)
        tk.Checkbutton(sch, text=t('시간대 예약', 'Schedule'), variable=self._sch_var,
                       bg=BG, fg='#CCCCCC', selectcolor='#2A2A34', activebackground=BG,
                       activeforeground='white', font=('Malgun Gothic', 9),
                       command=self._apply_schedule).pack(side='left')

        def spin(parent, hi, init):
            var = tk.StringVar(value=f'{init:02d}')
            sp = tk.Spinbox(parent, from_=0, to=hi, width=3, textvariable=var, wrap=True,
                            format='%02.0f', bg='#2A2A34', fg='white', relief='flat',
                            buttonbackground='#2A2A34', insertbackground='white',
                            font=('Consolas', 10), command=self._apply_schedule)
            sp.bind('<Return>', lambda e: self._apply_schedule())
            sp.bind('<FocusOut>', lambda e: self._apply_schedule())
            return var, sp
        sh, sm = divmod(awake.schedule_start, 60)
        eh, em = divmod(awake.schedule_end, 60)
        self._sh, w1 = spin(sch, 23, sh); self._sm, w2 = spin(sch, 59, sm)
        self._eh, w3 = spin(sch, 23, eh); self._em, w4 = spin(sch, 59, em)
        w1.pack(side='left', padx=(10, 0)); tk.Label(sch, text=':', bg=BG, fg='#CCCCCC').pack(side='left'); w2.pack(side='left')
        tk.Label(sch, text=' ~ ', bg=BG, fg='#CCCCCC').pack(side='left')
        w3.pack(side='left'); tk.Label(sch, text=':', bg=BG, fg='#CCCCCC').pack(side='left'); w4.pack(side='left')

        self._awake_note = tk.Label(
            win, bg=BG, fg='#555566', font=('Malgun Gothic', 8), justify='left', anchor='w',
            text=t('덮개를 닫아도 잠들지 않도록 전원 옵션의 "덮개 닫을 때" 동작을 잠시 바꿉니다.\n'
                   '끄거나 부니를 종료하면 원래대로 되돌려요.',
                   'Temporarily sets the power plan\'s "when I close the lid" action to do nothing.\n'
                   'It is restored when you turn it off or quit Buni.'))
        self._awake_note.grid(row=r, column=0, columnspan=3, padx=20, pady=(6, 0), sticky='w'); r += 1

        self.refresh_dynamic()
        self._status_tick()
        return r

    def _apply_schedule(self):
        try:
            start = int(self._sh.get()) * 60 + int(self._sm.get())
            end   = int(self._eh.get()) * 60 + int(self._em.get())
        except ValueError:
            return
        self._manager.awake.set_schedule(enabled=bool(self._sch_var.get()), start=start, end=end)

    def _status_tick(self):
        """"N분 남음" 문구를 주기적으로 갱신 — 창이 열려 있는 동안만."""
        if self.is_open():
            self.refresh_dynamic()
            self._win.after(30_000, self._status_tick)

    def refresh_dynamic(self):
        """로그인 상태·절전 방지 상태가 바뀌면 그 부분만 다시 맞춘다 (입력 중인 칸은 건드리지 않는다)."""
        if not (self._manager and self.is_open() and getattr(self, '_acct', None)):
            return
        BG, DIM = '#1E1E24', '#8A8A98'
        mgr, cloud = self._manager, self._manager.cloud
        for w in self._acct.winfo_children():
            w.destroy()

        if not cloud.is_configured:
            tk.Label(self._acct, bg=BG, fg=DIM, font=('Malgun Gothic', 8), justify='left', anchor='w',
                     text=t('서버 설정(cloud-config.json)이 없어서 쓸 수 없어요.\n'
                            '로컬로는 모든 기능을 그대로 쓸 수 있어요.',
                            'Server config (cloud-config.json) not found.\n'
                            'Everything still works locally.')).pack(anchor='w')
        elif cloud.is_signed_in:
            name = (cloud.user or {}).get('name') or ''
            tk.Label(self._acct, bg=BG, fg='#4DC780', font=('Malgun Gothic', 9, 'bold'),
                     text=t('☁ 연동됨', '☁ Synced') + (f' — {name}' if name else '')).pack(anchor='w')
            row = tk.Frame(self._acct, bg=BG); row.pack(anchor='w', pady=(4, 0))
            # 같은 줄에 나란히
            for txt, cmd, color in ((t('지금 동기화', 'Sync now'),
                                     lambda: threading.Thread(target=cloud.sync_now, daemon=True).start(), '#2A2A34'),
                                    (t('로그아웃', 'Sign out'), cloud.sign_out, '#2A2A34'),
                                    (t('서버 데이터 삭제', 'Delete server data'), self._confirm_delete, '#6A3A3A')):
                tk.Button(row, text=txt, bg=color, fg='white', relief='flat', bd=0,
                          font=('Malgun Gothic', 9), padx=10, pady=3, cursor='hand2',
                          activebackground='#3A3A50', activeforeground='white',
                          command=cmd).pack(side='left', padx=(0, 6))
        else:
            tk.Label(self._acct, bg=BG, fg=DIM, font=('Malgun Gothic', 8), justify='left', anchor='w',
                     text=t('다른 PC에서도 같은 캐릭터·레벨을 이어가려면 로그인하세요.\n'
                            '안 해도 모든 기능을 그대로 쓸 수 있어요.',
                            'Sign in to carry your characters and level to other PCs.\n'
                            'Everything works without it.')).pack(anchor='w')
            b = tk.Button(self._acct, text=t('Google로 로그인', 'Sign in with Google'),
                          bg='#3377E0', fg='white', relief='flat', bd=0, font=('Malgun Gothic', 9),
                          padx=12, pady=4, cursor='hand2', activebackground='#2255BB',
                          activeforeground='white', command=mgr.cloud_sign_in_ui,
                          state='disabled' if cloud.busy else 'normal')
            b.pack(anchor='w', pady=(6, 0))
        if cloud.message:
            tk.Label(self._acct, text=cloud.message, bg=BG, fg='#D9B25A', font=('Malgun Gothic', 8),
                     wraplength=330, justify='left', anchor='w').pack(anchor='w', pady=(4, 0))

        a = mgr.awake
        lbl = getattr(self, '_awake_lbl', None)
        if lbl is not None:
            if a.is_active:
                lbl.config(text=t(f'● 실행 중 — {a.status_text()}', f'● ON — {a.status_text()}'), fg='#4DC780')
            else:
                lbl.config(text=t('○ 꺼짐', '○ Off'), fg='#8A8A98')
            if a.last_error:
                lbl.config(text='⚠️ ' + a.last_error, fg='#E6665A')
            self._awake_off.config(state='normal' if a.is_active else 'disabled')
            self._sch_var.set(a.schedule_enabled)

    def _confirm_delete(self):
        from tkinter import messagebox
        if messagebox.askokcancel(t('서버 데이터 삭제', 'Delete server data'),
                                  t('서버에 저장된 코인·아이템·착용 정보를 지울까요?\n(이 PC의 데이터는 그대로예요)',
                                    'Delete the coins, items and outfits stored on the server?\n(Data on this PC is kept)'),
                                  parent=self._win):
            threading.Thread(target=self._manager.cloud.delete_server_data, daemon=True).start()

    # ── 언어 ──────────────────────────────────────────────
    def _refresh_lang_btns(self):
        """선택된 언어 버튼만 강조."""
        cur = get_lang()
        for code, b in getattr(self, '_lang_btns', {}).items():
            on = (code == cur)
            b.config(bg='#3377E0' if on else '#2A2A34',
                     fg='white' if on else '#AAAAAA',
                     activebackground='#2255BB' if on else '#3A3A50')

    def _set_lang(self, code: str):
        """언어를 바꾸고 설정 창·트레이 메뉴를 새 언어로 다시 만든다.
        (부니 우클릭 메뉴는 열 때마다 새로 만들어져 자동 반영된다)"""
        if code == get_lang():
            return
        set_lang(code)
        # 설정 창은 자기 문구도 바뀌어야 하므로 통째로 다시 그린다
        try:
            if self._win and self._win.winfo_exists():
                self._win.destroy()
        except Exception:
            pass
        self._win = None
        self._btns = {}
        self._build()
        cb = getattr(self, 'on_language_changed', None)
        if cb:
            try: cb()
            except Exception: pass

    def _btn_text(self, action: str) -> str:
        v = self._shortcuts.get(action)
        return GlobalHotkeyManager.label(v[0], v[1]) if v else t('(없음)', '(none)')

    def _toggle_record(self, action: str):
        if self._recording == action:
            self._stop_record(action); return
        if self._recording:
            self._stop_record(self._recording)
        self._recording = action
        self._btns[action].config(text=t('키 입력 대기...', 'Press a key...'),
                                  bg='#4A3A00', fg='#FFDD00')
        self._win.bind('<KeyPress>', self._on_key)
        self._win.focus_force()

    def _stop_record(self, action: str):
        self._recording = None
        self._btns[action].config(text=self._btn_text(action),
                                   bg='#2A2A34', fg='white')
        try: self._win.unbind('<KeyPress>')
        except Exception: pass

    def _on_key(self, e: tk.Event):
        # 수정자 단독 입력 무시
        if e.keysym in ('Control_L','Control_R','Alt_L','Alt_R',
                        'Shift_L','Shift_R','Super_L','Super_R'):
            return
        action = self._recording
        if not action: return
        if e.keysym == 'Escape':           # ESC = 취소
            self._stop_record(action); return
        mods = 0
        if e.state & 0x0001:   mods |= GlobalHotkeyManager.MOD_SHIFT
        if e.state & 0x0004:   mods |= GlobalHotkeyManager.MOD_CTRL
        if e.state & 0x20000:  mods |= GlobalHotkeyManager.MOD_ALT
        vk = e.keycode
        self._shortcuts[action] = (mods, vk)
        self._stop_record(action)
        self._save()

    def _clear(self, action: str):
        if self._recording == action:
            self._stop_record(action)
        self._shortcuts[action] = None
        self._btns[action].config(text=t('(없음)', '(none)'))
        self._save()

    def _close(self):
        if self._recording:
            self._stop_record(self._recording)
        if self._win:
            try: self._win.destroy()
            except Exception: pass
            self._win = None

    def show(self):
        if self._win and self._win.winfo_exists():
            self._win.lift(); self._win.focus_force()
        else:
            self._build()

    def is_open(self) -> bool:
        return bool(self._win and self._win.winfo_exists())


# ══════════════════════════════════════════════════════════════
# Claude Code 세션 이름 읽기 (메모 자동 연동용)
# ══════════════════════════════════════════════════════════════

_TITLE_MAX_LEN = 24


def _read_session_title(session_id: str) -> str | None:
    """트랜스크립트(~/.claude/projects/<프로젝트>/<세션id>.jsonl)에서
    세션 이름을 읽는다. 이름은 아래 형태로 대화 중 계속 덧붙는다.
        {"type": "custom-title", "customTitle": "...", "sessionId": "..."}
        {"type": "ai-title",     "aiTitle": "...",     "sessionId": "..."}
    사용자가 지정한 이름(custom-title) 우선, 같은 종류는 최신 값을 쓴다.
    제목 줄은 보통 파일 꼬리에 있으므로 꼬리 256KB만 먼저 훑고,
    거기서 못 찾을 때만 전체를 읽는다."""
    projects_dir = Path.home() / '.claude' / 'projects'
    transcript: Path | None = None
    try:
        for d in projects_dir.iterdir():
            candidate = d / f'{session_id}.jsonl'
            if candidate.exists():
                transcript = candidate
                break
    except Exception:
        return None
    if transcript is None:
        return None

    def _parse(text: str) -> str | None:
        custom = ai = None
        for line in text.splitlines():
            if '-title' not in line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            sid = ev.get('sessionId')
            if sid is not None and sid != session_id:
                continue
            ct = ev.get('customTitle')
            at = ev.get('aiTitle')
            if ct:
                custom = ct
            if at:
                ai = at
        return custom or ai

    try:
        size = transcript.stat().st_size
        tail_bytes = 256 * 1024
        with transcript.open('rb') as f:
            if size > tail_bytes:
                f.seek(size - tail_bytes)
                f.readline()  # 중간부터 읽으면 첫 줄은 잘려 있으므로 버림
            data = f.read()
        title = _parse(data.decode('utf-8', errors='replace'))
        if title is None and size > tail_bytes:
            full  = transcript.read_text(encoding='utf-8', errors='replace')
            title = _parse(full)
    except Exception:
        return None

    if not title:
        return None
    title = title.strip()
    if not title:
        return None
    return title if len(title) <= _TITLE_MAX_LEN else title[:_TITLE_MAX_LEN - 1] + '…'


# ══════════════════════════════════════════════════════════════
class PersistenceManager:
    """JSON-backed key-value store (character, memo, window position)."""

    def __init__(self):
        self._data: dict = {}
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        try:
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            if STATE_FILE.exists():
                self._data = json.loads(
                    STATE_FILE.read_text(encoding='utf-8'))
        except Exception:
            self._data = {}

    def save(self):
        try:
            with self._lock:
                STATE_FILE.write_text(
                    json.dumps(self._data, indent=2, ensure_ascii=False),
                    encoding='utf-8')
        except Exception:
            pass

    def get(self, key, default=None):
        with self._lock:
            return self._data.get(key, default)

    def set(self, key, value):
        with self._lock:
            self._data[key] = value
        self.save()

    def remove(self, key):
        with self._lock:
            self._data.pop(key, None)
        self.save()


# ══════════════════════════════════════════════════════════════
class CharacterDrawMixin:
    """캐릭터 그림 — 실제 세션 창(SessionWindow)과 상점 미리보기가 함께 쓴다.

    쓰는 쪽이 갖춰야 하는 것: cv, cx, cy, character, state, shop, try_on,
    body_dx/dy, larm/rarm dx/dy, show_laptop, show_reading, show_carrot,
    doc_visible, throw_dx/dy, blinking, wide_eyes, ear_scale,
    showing_weapon, weapon_swing
    """

    def _equip(self, slot: str):
        """지금 이 자리에 보여줄 아이템 id — 입어보는 중이면 그것, 아니면 실제 착용 상태."""
        return self.shop.resolved(slot, self.character, self.try_on)

    def _hold(self):
        """무기를 어디에 쥐고 있는지 — 작업 중엔 오른손, 완료·권한 요청엔 들어 올린 왼손,
        대기 중 꺼내 보여줄 땐 들어 올린 오른손."""
        st = self.state
        if st in ('thinking', 'toolUse', 'toolRead', 'backgroundWork'):
            return buni_items.HOLD_RIGHT
        if st in ('completed', 'permission', 'ask_user'):
            return buni_items.HOLD_RAISED_LEFT
        if self.showing_weapon:
            return buni_items.HOLD_SHOW_OFF
        return None

    def _painter(self):
        return buni_items.Painter(self.cv, self.cx, self.cy, dx=self.body_dx, dy=self.body_dy)

    def _needs_anim(self) -> bool:
        """시간에 따라 계속 바뀌는 그림(무기 흔들림·뜨개질·후광 등)이 있는지."""
        weapon = self._equip('weapon')
        if self._hold() and weapon and weapon != 'carrot':
            return True
        if self.show_laptop and self._equip('tool') in buni_items.ANIMATED_TOOLS:
            return True
        return self._equip('head') in buni_items.ANIMATED_HEAD

    def _draw_character(self):
        now = time.time()
        if self.show_reading:                       # 문서 더미 (맨 뒤, 왼쪽)
            self._draw_doc_pile()
        p = self._painter()
        buni_items.draw_back(p, self._equip('back'))        # 뒤 레이어 — 망토·날개
        self._draw_ears()                                    # 귀 (머리 뒤)
        self._draw_body()
        buni_items.draw_outfit(p, self._equip('outfit'))     # 옷 (몸통 위, 팔·노트북 아래)
        self._draw_arms()
        # 들어 올린 왼손의 소품 — 기본은 당근, 무기를 입었으면 그 무기가 대신 쥐어진다
        if self.show_carrot and not self.shop.has_custom_weapon(self.character, self.try_on):
            buni_items.draw_carrot(p, self.larm_dy)
        if self.show_laptop:                                 # 작업 도구 — 기본은 노트북
            if not buni_items.draw_work_tool(p, self._equip('tool'), now, self.larm_dy, self.rarm_dy):
                self._draw_laptop()
        self._draw_feet()
        if self.show_reading and self.doc_visible:
            self._draw_held_doc()
        self._draw_head()
        # 앞 레이어 — 얼굴·머리·무기
        buni_items.draw_face(p, self._equip('face'))
        buni_items.draw_head(p, self._equip('head'), now)
        hold, weapon = self._hold(), self._equip('weapon')
        if hold and weapon:
            buni_items.draw_weapon(p, weapon, hold, now, self.weapon_swing, self.showing_weapon)

    # ── Drawing helpers ───────────────────────────────────────

    def _rect(self, ox: float, oy: float, w: float, h: float,
              color: str, tag: str = 'char') -> None:
        """Pixel block at character-center offset (body_dx/dy applied)."""
        x = self.cx + ox + self.body_dx
        y = self.cy + oy + self.body_dy
        self.cv.create_rectangle(x - w*P/2, y - h*P/2,
                                  x + w*P/2, y + h*P/2,
                                  fill=color, outline='', tags=tag)

    def _oval(self, ox: float, oy: float, w: float, h: float,
              color: str, tag: str = 'char') -> None:
        """Ellipse at character-center offset (body_dx/dy applied)."""
        x = self.cx + ox + self.body_dx
        y = self.cy + oy + self.body_dy
        self.cv.create_oval(x - w*P/2, y - h*P/2,
                             x + w*P/2, y + h*P/2,
                             fill=color, outline='', tags=tag)

    def _rounded_rect(self, x0, y0, x1, y1, r, fill, outline, tag='misc'):
        pts = [x0+r, y0,  x1-r, y0,  x1,  y0,   x1,  y0+r,
               x1,  y1-r, x1,  y1,   x1-r, y1,  x0+r, y1,
               x0,  y1,   x0,  y1-r, x0,  y0+r, x0,  y0]
        self.cv.create_polygon(pts, smooth=True,
                                fill=fill, outline=outline, width=1, tags=tag)

    # ── Character parts ───────────────────────────────────────

    def _draw_ears(self):
        body, ear, *_ = CHARACTERS[self.character]
        ch = self.character
        # Ear dimensions per character (matching Swift views)
        if ch == 'pinkRabbit':
            ow, oh, iw, ih, xo, yo = 1.65, 3.4, 0.85, 2.7, P*1.55, P*3.5
        elif ch == 'orangeRabbit':
            ow, oh, iw, ih, xo, yo = 1.6,  3.3, 0.8,  2.6, P*1.7,  P*3.4
        elif ch == 'yellowRabbit':
            ow, oh, iw, ih, xo, yo = 1.6,  3.8, 0.8,  3.1, P*1.5,  P*3.8
        elif ch == 'greenRabbit':
            ow, oh, iw, ih, xo, yo = 1.8,  3.2, 1.0,  2.5, P*1.5,  P*3.3
        else:  # rabbit, brownRabbit
            ow, oh, iw, ih, xo, yo = 1.6,  3.4, 0.8,  2.7, P*1.6,  P*3.5
        # 귀 접기(쓰다듬기 반응) — 귀 아래쪽을 고정하고 위가 줄어든다
        s  = self.ear_scale
        yb = -yo + oh * P / 2                       # 바깥 귀의 아래 끝 (고정점)
        for sx in (-xo, xo):
            self._rect(sx, yb + (-yo - yb) * s,           ow, oh * s, body)
            self._rect(sx, yb + (-yo - P*0.1 - yb) * s,   iw, ih * s, ear)

    def _draw_body(self):
        body, ear, nose, extras = CHARACTERS[self.character]
        ch = self.character
        # Body size per character
        if ch == 'orangeRabbit':
            self._rect(0, P*1.5, 4.7, 2.6, body)
        elif ch in ('pinkRabbit', 'greenRabbit'):
            self._rect(0, P*1.5, 4.6, 2.5, body)
        else:
            self._rect(0, P*1.5, 4.5, 2.5, body)

    def _draw_arms(self):
        body = CHARACTERS[self.character][0]
        ch = self.character
        # Arms (with dark outline when holding laptop/doc)
        arm_x = P*2.70 if ch == 'orangeRabbit' else P*2.68 if ch == 'greenRabbit' else P*2.65
        lx = -arm_x + self.larm_dx;  ly = P*1.1 + self.larm_dy
        rx =  arm_x + self.rarm_dx;  ry = P*1.1 + self.rarm_dy
        if self.show_laptop or self.show_reading:
            self._rect(lx, ly, 1.9, 1.2, '#3A3A3A')   # outline
            self._rect(rx, ry, 1.9, 1.2, '#3A3A3A')
        self._rect(lx, ly, 1.5, 0.9, body)
        self._rect(rx, ry, 1.5, 0.9, body)

    def _draw_feet(self):
        body = CHARACTERS[self.character][0]
        ch = self.character
        # Foot size per character
        if ch in ('orangeRabbit', 'greenRabbit'):
            self._rect(-P*1.2, P*2.9, 1.6, 1.0, body)
            self._rect( P*1.2, P*2.9, 1.6, 1.0, body)
        else:
            self._rect(-P*1.2, P*2.9, 1.5, 0.9, body)
            self._rect( P*1.2, P*2.9, 1.5, 0.9, body)

    def _draw_head(self):
        body, ear, nose, extras = CHARACTERS[self.character]
        ch = self.character

        # ── Head size (per-character, matching each Swift view)
        if ch in ('pinkRabbit', 'orangeRabbit', 'greenRabbit'):
            self._rect(0, -P*0.8, 5.6, 2.6, body)
        else:
            self._rect(0, -P*0.8, 5.5, 2.5, body)

        # ── Eyebrows + stubble (두니 only)
        if 'brow' in extras:
            brow = extras['brow']
            self._rect(-P*1.45, -P*1.35, 0.95, 0.24, brow)
            self._rect( P*1.45, -P*1.35, 0.95, 0.24, brow)
            self._rect(-P*0.85, -P*0.10, 0.20, 0.20, brow)
            self._rect( P*0.85, -P*0.10, 0.20, 0.20, brow)

        # ── Blush / cheeks (character-specific, drawn before eyes)
        if ch == 'pinkRabbit':
            # 푸니: 크고 부드러운 타원형 볼 홍조
            # pre-blended: Color(0.98,0.62,0.75).opacity(0.55) over #FAC7E0
            self._oval(-P*1.9, -P*0.30, 1.6, 1.0, '#FAB0CE')
            self._oval( P*1.9, -P*0.30, 1.6, 1.0, '#FAB0CE')
        elif ch == 'orangeRabbit':
            # 주니: 발랄한 둥근 볼터치
            # pre-blended: Color(1.0,0.70,0.50).opacity(0.55) over #F28520
            self._oval(-P*1.8, -P*0.35, 1.4, 1.0, '#F9A055')
            self._oval( P*1.8, -P*0.35, 1.4, 1.0, '#F9A055')
        elif ch == 'yellowRabbit':
            # 누니: 작고 따뜻한 타원형 볼 홍조 (위치 맥버전 기준으로 수정)
            self._oval(-P*1.55, -P*0.42, 0.68, 0.28, '#F5B06E')
            self._oval( P*1.55, -P*0.42, 0.68, 0.28, '#F5B06E')

        # ── Eye parameters (per-character, matching each Swift eyeBlock)
        if ch == 'pinkRabbit':
            ew, ex, ey_off = 0.75, P*1.45, P*0.92
            eh_n, eh_w, eh_b = 0.90, 1.20, 0.10
        elif ch == 'orangeRabbit':
            ew, ex, ey_off = 0.68, P*1.42, P*0.88
            eh_n, eh_w, eh_b = 0.78, 1.10, 0.10
        elif ch == 'yellowRabbit':
            ew, ex, ey_off = 0.68, P*1.4,  P*0.90
            eh_n, eh_w, eh_b = 0.82, 1.15, 0.11
        elif ch == 'greenRabbit':
            ew, ex, ey_off = 0.72, P*1.42, P*0.90
            eh_n, eh_w, eh_b = 0.60, 1.05, 0.10
        else:  # rabbit, brownRabbit
            ew, ex, ey_off = 0.65, P*1.4,  P*0.90
            eh_n, eh_w, eh_b = 0.75, 1.10, 0.12

        ey = -ey_off
        if self.blinking:    eh = eh_b
        elif self.wide_eyes: eh = eh_w
        else:                eh = eh_n

        self._rect(-ex, ey, ew, eh, '#000000')
        self._rect( ex, ey, ew, eh, '#000000')

        # ── Eye sparkle highlights (푸니, 누니)
        if not self.blinking:
            if ch == 'pinkRabbit':
                self._rect(-P*1.60, ey - P*0.28, 0.22, 0.22, '#FFEAF5')
                self._rect( P*1.30, ey - P*0.28, 0.22, 0.22, '#FFEAF5')
            elif ch == 'yellowRabbit':
                self._rect(-P*1.54, ey - P*0.22, 0.22, 0.22, '#FFFFFF')
                self._rect( P*1.26, ey - P*0.22, 0.22, 0.22, '#FFFFFF')

        # ── Nose (per-character shape and size)
        if ch == 'pinkRabbit':
            # 픽셀아트 하트 코 (PinkRabbitCharacterView.heartNoseView)
            ny = -P*0.22
            self._rect(-P*0.17, ny - P*0.17, 0.30, 0.30, nose)
            self._rect( P*0.17, ny - P*0.17, 0.30, 0.30, nose)
            self._rect(0,       ny,           0.52, 0.28, nose)
            self._rect(0,       ny + P*0.22,  0.30, 0.24, nose)
            self._rect(0,       ny + P*0.40,  0.16, 0.18, nose)
        elif ch in ('orangeRabbit', 'yellowRabbit'):
            self._rect(0, -P*0.24, 0.58, 0.40, nose)
        elif ch == 'greenRabbit':
            self._rect(0, -P*0.24, 0.60, 0.40, nose)
        else:
            self._rect(0, -P*0.25, 0.55, 0.40, nose)

    # ── Laptop ────────────────────────────────────────────────

    def _draw_laptop(self):
        """MacBook on character's lap — positions from LaptopView.swift."""
        cx = self.cx + self.body_dx
        cy = self.cy + self.body_dy

        def r(oy, w, h, color):
            y = cy + P * oy
            self.cv.create_rectangle(cx - P*w/2, y - P*h/2,
                                      cx + P*w/2, y + P*h/2,
                                      fill=color, outline='', tags='char')

        r(1.48, 3.15, 2.15, LAP_SILVER)   # Lid back
        r(0.41, 3.15, 0.17, LAP_HI)       # Lid top highlight
        r(2.64, 3.50, 0.20, LAP_DARK)     # Hinge
        r(2.90, 3.80, 0.44, LAP_MID)      # Keyboard base
        r(3.13, 3.80, 0.16, LAP_DARK)     # Keyboard front thickness
        r(2.82, 3.10, 0.13, '#909099')    # Key hint
        r(3.02, 1.00, 0.22, '#9090A0')    # Trackpad
        # Carrot logo (macOS 사과 로고 패러디 — 한 입 베어먹은 당근)
        def rl(ox, oy, w, h, color):
            x = cx + P*ox
            y = cy + P*1.42 + P*oy
            self.cv.create_rectangle(x - P*w/2, y - P*h/2,
                                      x + P*w/2, y + P*h/2,
                                      fill=color, outline='', tags='char')

        # 당근 꼭지 잎 (Canvas는 회전을 안 쓰므로 단순화한 세 갈래)
        rl(-0.10, -0.56, 0.12, 0.28, LAP_LEAF)
        rl( 0.10, -0.56, 0.12, 0.28, LAP_LEAF)
        rl( 0.00, -0.52, 0.12, 0.24, LAP_LEAF)
        # 당근 몸통 — 위가 넓고 아래로 갈수록 좁아지는 계단식
        rl(0, -0.28, 0.52, 0.14, LAP_CARROT)
        rl(0, -0.14, 0.46, 0.14, LAP_CARROT)
        rl(0,  0.00, 0.40, 0.14, LAP_CARROT)
        rl(0,  0.14, 0.32, 0.14, LAP_CARROT)
        rl(0,  0.28, 0.22, 0.14, LAP_CARROT)
        rl(0,  0.41, 0.12, 0.13, LAP_CARROT)
        # 한 입 베어먹은 자국
        rl(0.22, -0.20, 0.20, 0.18, LAP_SILVER)

    # ── Document ──────────────────────────────────────────────

    def _draw_doc_pile(self):
        """Paper pile on the left — static, behind character."""
        pile_cx = self.cx + self.body_dx - P*5.4
        pile_cy = self.cy + self.body_dy + P*2.55

        def r(ox, oy, w, h, color):
            x = pile_cx + ox*P;  y = pile_cy + oy*P
            self.cv.create_rectangle(x - w*P/2, y - h*P/2,
                                      x + w*P/2, y + h*P/2,
                                      fill=color, outline='', tags='char')

        r(0.12,  0.84, 2.85, 0.26, DOC_DARK)    # shadow
        r(0,    -0.74, 2.55, 1.45, DOC_PAPER)   # pile body
        r(0,    -1.22, 1.90, 0.13, DOC_LINE_H)
        r(0,    -1.04, 1.60, 0.10, DOC_LINE_L)
        r(0,    -0.88, 1.90, 0.10, DOC_LINE_L)
        r(0,    -0.56, 1.90, 0.10, DOC_LINE_L)
        r(0,    -0.03, 2.55, 0.12, DOC_DARK)    # thickness lines
        r(0,     0.11, 2.55, 0.12, DOC_DARK)
        r(1.28, -0.90, 0.26, 0.52, TAB_PINK)    # post-it tabs
        r(1.28, -0.36, 0.26, 0.46, TAB_YELLOW)
        r(1.28,  0.14, 0.26, 0.44, TAB_GREEN)

    def _draw_held_doc(self):
        """Document the character is holding — affected by throw offset."""
        doc_cx = self.cx + self.body_dx + self.throw_dx
        doc_cy = self.cy + self.body_dy + self.throw_dy

        def r(oy, w, h, color):
            y = doc_cy + P * oy
            self.cv.create_rectangle(doc_cx - P*w/2, y - P*h/2,
                                      doc_cx + P*w/2, y + P*h/2,
                                      fill=color, outline='', tags='char')

        r(1.90, 3.2, 2.80, DOC_DARK)    # shadow
        r(1.80, 3.0, 2.80, DOC_PAPER)   # paper main
        r(0.55, 3.0, 0.13, DOC_LINE_H)  # top separator
        r(0.78, 1.85, 0.25, DOC_LINE_H) # title
        r(1.06, 1.30, 0.16, DOC_LINE_L)
        r(1.35, 2.55, 0.13, DOC_LINE_L) # body lines
        r(1.55, 2.55, 0.13, DOC_LINE_L)
        r(1.75, 2.55, 0.13, DOC_LINE_L)
        r(1.95, 2.10, 0.13, DOC_LINE_L)
        r(2.36, 2.55, 0.13, DOC_LINE_L)
        r(2.55, 1.80, 0.13, DOC_LINE_L)
        # Corner fold
        corner_x = doc_cx + P*1.29
        corner_y = doc_cy + P*0.47
        self.cv.create_rectangle(corner_x - P*0.21, corner_y - P*0.21,
                                  corner_x + P*0.21, corner_y + P*0.21,
                                  fill=DOC_DARK, outline='', tags='char')


# ══════════════════════════════════════════════════════════════
class SessionWindow(CharacterDrawMixin):
    """One Toplevel window per active Claude session."""

    def __init__(self, manager: 'BuniManager', session_id: str, slot: int,
                 event_file: Path, persist: PersistenceManager):
        self.manager    = manager
        self.session_id = session_id
        self.slot       = slot
        self.event_file = event_file
        self.persist    = persist

        # ── Toplevel
        self.win = tk.Toplevel(manager.root)
        self._setup_window()
        self.cv = tk.Canvas(self.win, width=WIN_W, height=WIN_H,
                            bg=TRANSP, highlightthickness=0)
        self.cv.pack()

        # ── 그림 기준점·상점 (CharacterDrawMixin이 쓴다)
        self.cx, self.cy = CHAR_CX, CHAR_CY
        self.shop    = manager.shop
        self.try_on  = None            # 실제 부니는 입어보기 없음 (상점 미리보기만 쓴다)
        self.show_carrot    = False    # 권한 요청·완료 때 들어 올린 손의 소품
        self.ear_scale      = 1.0      # 귀 접기 (쓰다듬기 반응)
        self.showing_weapon = False    # 대기 중 무기 꺼내 보여주는 중
        self.weapon_swing   = 0.0
        self._swing_target  = 0.0
        self._show_token    = 0
        self._weapon_job    = None
        self._anim_job      = None
        self._dragged       = False
        self._press_xy      = (0, 0)

        # ── Character & memo
        self.character: str = self._load_character()
        self.memo, self.memo_is_auto = self._load_memo()

        # ── Body/arm animation floats
        self.body_dy  = 0.0;  self.body_dx  = 0.0
        self.larm_dx  = 0.0;  self.larm_dy  = 0.0
        self.rarm_dx  = 0.0;  self.rarm_dy  = 0.0

        # ── Laptop typing state
        self.show_laptop  = False
        self.laptop_phase = False

        # ── Document reading state
        self.show_reading = False
        self._reading_step = 0
        self.throw_dx  = 0.0;  self.throw_dy = 0.0
        self.doc_visible  = True

        # ── Eyes
        self.blinking   = False
        self.wide_eyes  = False

        # ── App state
        self.state          = 'idle'
        # 사용자가 직접 숨긴 부니인지 — 숨긴 뒤에는 "이 세션이 새로 시작될 때"
        # (= 비진행 → 진행 전환)만 다시 나타난다. 진행 중에 숨겼다면 그 작업
        # 안에는 시작 경계가 없으므로, 작업이 끝나고 다음 작업이 시작될 때다.
        self._manually_hidden = False
        self._was_running     = False
        self.msg: str | None = None
        self.perm_id: str | None   = None
        self.perm_cmd: str | None  = None
        self.ask_msg: str          = ''   # AskUserQuestion 질문 내용
        self.always_approve = self._load_always_approve()
        # 한도 도달 안내를 사용자가 직접 숨긴 상태 — 다음 한도 창이 시작되면 해제
        self._limit_notice_dismissed = False
        self._limit_win: tk.Toplevel | None = None
        self._limit_job = None
        # 진행 중인(끝나지 않은) 도구 실행 수 — tool_use +1 / tool_done -1.
        # 0보다 크면 오래 걸리는 도구가 실행 중이라 이벤트가 없어도 정상이다.
        self._pending_tools = 0
        # "확인 대기" 추정용 — 마지막으로 시작된 도구 이름과, 이미 안내했는지
        self._pending_tool_name: str | None = None
        self._wait_hint_shown = False
        self._ask_is_hint     = False   # 현재 ask_user 버블이 추정 안내(훅 없는 확인 창)인지
        # 뒤늦게 도착하는 지연 전환이 최신 이벤트를 덮어쓰지 않도록 순번을 올린다
        self._event_seq = 0

        # ── Usage
        self._usage                = 0.0
        self._session_start: datetime.datetime | None = None
        self._monthly_tokens: int  = 0
        self._server_utilization: float | None        = None
        self._server_resets_at: datetime.datetime | None = None

        # ── After handles
        self._laptop_job   = None
        self._reading_job  = None
        self._blink_job    = None
        self._idle_job     = None
        self._title_job    = None
        # done(Stop 훅)은 클로드가 한 번 응답을 마칠 때마다 매번 와서, 그대로 바로
        # "완료했어요!"를 띄우면 세션이 아직 안 끝났는데(곧바로 다음 턴이 이어지는
        # 경우) 중간에 완료 문구가 떴다 사라지는 것처럼 보인다. 잠깐 기다렸다가
        # 그 사이 새 작업이 시작되면 취소한다.
        self._completion_job = None
        self._completion_debounce_ms = 3000
        # "백그라운드 작업 중" 표시가 이만큼(초) 갱신되지 않으면 대기로 되돌린다.
        # idle 폴백(300초)보다 짧게 잡아, 실제로는 끝났는데 문구만 남는 것을 방지.
        self._background_stale_seconds = 90
        self._perm_win:        tk.Toplevel | None = None
        self._completion_win: tk.Toplevel | None = None
        self._ask_user_win:   tk.Toplevel | None = None
        self._destroyed    = False

        # ── File monitoring
        self._file_offset = 0
        self._is_replaying = True   # 첫 poll에서 기존 이벤트 재생 중 — done/thinking 건너뜀
        self._last_event_time = time.time()
        self._init_file_offset()

        # ── HWND (after window is mapped)
        self._hwnd: int | None = None
        self.win.after(300, self._init_hwnd)

        # ── Position & initial draw
        self._position_window()
        self._draw()

        # ── Bindings
        self._build_menu()
        self.cv.bind('<Button-3>',        self._show_menu)
        self.cv.bind('<Double-Button-1>', lambda _: self._open_claude())
        self.cv.bind('<ButtonPress-1>',   self._drag_press)
        self.cv.bind('<B1-Motion>',       self._drag_motion)
        self.cv.bind('<ButtonRelease-1>', self._drag_release)
        self._drag_start: tuple | None = None

        # ── Start
        self._apply_state('ready')
        self._schedule_blink()
        self._schedule_idle_hop()
        self._tick_bar_refresh()
        self._schedule_title_sync()
        self._tick_anim()
        self._schedule_weapon_show()

    # ── Persistence ───────────────────────────────────────────

    def _load_character(self) -> str:
        char = (self.persist.get(f'character.session.{self.session_id}') or
                self.persist.get(f'character.slot.{self.slot}') or 'rabbit')
        return char if char in CHARACTERS else 'rabbit'

    def _load_memo(self) -> tuple[str, bool]:
        """(메모, 자동연동여부) 반환.
        이 세션에 사용자가 직접 지정한 메모가 있으면 그대로 쓰고 자동 연동을
        끈다. 없거나 비어 있으면(= 메모를 지운 상태, 예전 버전이 남긴 빈
        문자열 포함) 슬롯 메모를 임시로 보여주되 자동 상태로 두어, 곧 세션
        이름을 읽어오면 대체되게 한다."""
        ks = f'memo.session.{self.session_id}'
        saved = self.persist.get(ks)
        if saved:
            return (saved, False)
        return (self.persist.get(f'memo.slot.{self.slot}') or '', True)

    def _load_always_approve(self) -> bool:
        ks = f'alwaysApprove.session.{self.session_id}'
        if self.persist.get(ks) is not None:
            return bool(self.persist.get(ks))
        return bool(self.persist.get(f'alwaysApprove.slot.{self.slot}', False))

    def _save_always_approve(self):
        self.persist.set(f'alwaysApprove.session.{self.session_id}', self.always_approve)
        self.persist.set(f'alwaysApprove.slot.{self.slot}', self.always_approve)

    def _save_character(self):
        self.persist.set(f'character.session.{self.session_id}', self.character)
        self.persist.set(f'character.slot.{self.slot}', self.character)

    def _save_memo(self):
        ks = f'memo.session.{self.session_id}'
        kl = f'memo.slot.{self.slot}'
        if self.memo:
            self.persist.set(ks, self.memo)
            self.persist.set(kl, self.memo)
        else:
            # 메모를 비우면 기본값(세션 이름)으로 되돌아가므로 저장값을 남기지 않는다
            self.persist.remove(ks)
            self.persist.remove(kl)

    # ── 세션 이름 → 메모 자동 연동 ──────────────────────────────

    def _schedule_title_sync(self):
        if self.session_id in ('legacy', 'windows-default'):
            return
        self._sync_session_title()

    def _sync_session_title(self):
        if self._destroyed:
            return
        title = _read_session_title(self.session_id)
        if title and self.memo_is_auto and self.memo != title:
            self.memo = title
            self._draw()
        self._title_job = self.win.after(15_000, self._sync_session_title)

    # ── Window setup ──────────────────────────────────────────

    def _setup_window(self):
        w = self.win
        w.overrideredirect(True)
        w.wm_attributes('-topmost', True)
        w.wm_attributes('-transparentcolor', TRANSP)
        w.config(bg=TRANSP)
        w.resizable(False, False)
        w.title(f'Buni-{self.slot}')

    def _position_window(self):
        sw = self.win.winfo_screenwidth()
        sh = self.win.winfo_screenheight()
        if self.slot == 0:
            saved = self.persist.get('window_pos')
            if saved and isinstance(saved, (list, tuple)) and len(saved) == 2:
                try:
                    x, y = int(saved[0]), int(saved[1])
                    # 모니터 구성이 바뀌어(외장 모니터 분리 등) 저장된 위치가
                    # 현재 화면 밖으로 완전히 벗어났으면 버리고 기본 위치를 쓴다
                    on_screen = (x + WIN_W > 0 and x < sw and
                                 y + WIN_H > 0 and y < sh)
                    if on_screen:
                        self.win.geometry(f'{WIN_W}x{WIN_H}+{x}+{y}')
                        return
                    self.persist.remove('window_pos')
                except Exception:
                    pass
        # Top-right corner, slots stack downward
        x = sw - WIN_W - 10
        y = 50 + self.slot * SLOT_STEP
        self.win.geometry(f'{WIN_W}x{WIN_H}+{x}+{y}')

    def _init_hwnd(self):
        try:
            self._hwnd = _get_hwnd(self.win)
            _set_click_through(self._hwnd, True)
        except Exception:
            pass
        # <Enter>/<Leave>는 WS_EX_TRANSPARENT 상태에서 OS 이벤트가 도달하지 않아
        # 절대 발생하지 않음 → 30ms 폴링으로 마우스 위치를 직접 확인
        self._poll_click_through()

    def _poll_click_through(self):
        """30ms마다 마우스가 창 위에 있는지 확인해 클릭 투과를 토글."""
        if self._destroyed or not self._hwnd:
            return
        try:
            mx = self.win.winfo_pointerx()
            my = self.win.winfo_pointery()
            wx = self.win.winfo_rootx()
            wy = self.win.winfo_rooty()
            over = wx <= mx < wx + WIN_W and wy <= my < wy + WIN_H
            _set_click_through(self._hwnd, not over)
        except Exception:
            pass
        self.win.after(30, self._poll_click_through)

    # ── Drag ─────────────────────────────────────────────────

    def _drag_press(self, e: tk.Event):
        self._drag_start = (e.x_root, e.y_root,
                            self.win.winfo_x(), self.win.winfo_y())
        self._dragged  = False
        self._press_xy = (e.x, e.y)
        if self._hwnd:
            _set_click_through(self._hwnd, False)

    def _drag_motion(self, e: tk.Event):
        if not self._drag_start:
            return
        sx, sy, wx, wy = self._drag_start
        if abs(e.x_root - sx) > 4 or abs(e.y_root - sy) > 4:
            self._dragged = True
        new_x = wx + e.x_root - sx
        new_y = wy + e.y_root - sy
        self.win.geometry(f'+{new_x}+{new_y}')
        # 권한 팝업도 같이 이동
        if self._perm_win and self._perm_win.winfo_exists():
            self._reposition_perm_popup(new_x, new_y)

    def _reposition_perm_popup(self, win_x: int, win_y: int):
        """캐릭터 창 좌표(win_x, win_y) 기준으로 권한 팝업 재배치."""
        if not (self._perm_win and self._perm_win.winfo_exists()):
            return
        try:
            BW, TAIL_W = 230, 15
            ph = self._perm_win.winfo_height()
            if ph < 10:
                ph = 156  # 초기 렌더 전 폴백 높이
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            px = win_x + tail_tip_x - (BW + TAIL_W)
            py = win_y + int(CHAR_CY - P * 3.5) - ph // 2
            self._perm_win.geometry(f'+{px}+{py}')
        except Exception:
            pass

    def _touch_region(self, x: int, y: int):
        """누른 자리로 부위를 가린다 — 머리 위(귀)와 몸. 그 밖(게이지 바 등)은 반응 없음."""
        dx, dy = x - self.cx, y - self.cy
        if abs(dx) > P * 4 or dy < -P * 5.5 or dy > P * 3.6:
            return None
        return 'ear' if dy < -P * 2.1 else 'body'

    def _touch(self, region: str):
        """쓰다듬기 반응 — 귀는 쫑긋, 몸은 간지러워 몸을 비튼다."""
        if region == 'ear':
            # 귀가 확 접혔다가 통통 튀며 펴진다
            steps = [(0, 0.45), (120, 1.14), (200, 0.94), (270, 1.03), (340, 1.0)]
            for delay, scale in steps:
                self.win.after(delay, lambda sc=scale: self._set_ear_scale(sc))
        elif region == 'body':
            # 간지러움 — 눈을 질끈 감고 몸을 좌우로 떤다
            self.blinking = True
            wiggle = [-3, 3, -2.2, 2.2, -1.2, 0]
            for i, dx in enumerate(wiggle):
                self.win.after(80 * i, lambda d=dx: self._set_body_dx(d))
            self.win.after(80 * len(wiggle) + 120, self._end_tickle)

    def _set_ear_scale(self, sc: float):
        if not self._destroyed:
            self.ear_scale = sc; self._draw()

    def _set_body_dx(self, dx: float):
        if not self._destroyed:
            self.body_dx = dx; self._draw()

    def _end_tickle(self):
        if not self._destroyed:
            self.blinking = False; self._draw()

    def _drag_release(self, _e: tk.Event):
        # 끌지 않고 눌렀다 뗀 것 = 쓰다듬기
        if self._drag_start and not self._dragged:
            region = self._touch_region(*self._press_xy)
            if region:
                self._touch(region)
        self._drag_start = None
        if self._hwnd:
            _set_click_through(self._hwnd, True)
        if self.slot == 0:
            self.persist.set('window_pos',
                             [self.win.winfo_x(), self.win.winfo_y()])

    # ── Full redraw (draw order matches macOS z-order) ────────

    def _draw(self):
        if self._destroyed:
            return
        self.cv.delete('all')
        self._draw_bubble()        # 1. Speech bubble (behind everything)
        self._draw_character()     # 2~8. 캐릭터 본체 + 꾸미기 아이템
        self._draw_bar()           # 9. Usage bar
        self._draw_memo()          # 10. Memo tag (above ears)

    # ── Speech bubble ─────────────────────────────────────────

    def _draw_bubble(self):
        if not self.msg:
            return
        bx  = CHAR_CX - P*5 + self.body_dx
        by  = CHAR_CY - P*3.5 + self.body_dy
        pad = 10
        font = ('Malgun Gothic', 10)
        tmp = self.cv.create_text(0, 0, text=self.msg, font=font)
        bb  = self.cv.bbox(tmp); self.cv.delete(tmp)
        tw  = (bb[2] - bb[0]) if bb else 60
        bw  = tw + pad*2;  bh = 28;  r = 8
        x0  = bx - bw;    x1 = bx
        y0  = by - bh/2;  y1 = by + bh/2
        # ① 테두리용 외곽 레이어 (body+꼬리 모두 border 색으로, outline='')
        self._rounded_rect(x0-1, y0-1, x1+1, y1+1, r+1, '#cccccc', '', 'bubble')
        self.cv.create_polygon(x1-3, by-6, x1+10, by, x1-3, by+6,
                                fill='#cccccc', outline='', tags='bubble')
        # ② 흰색 채움 레이어 (접합부 포함) — 바깥 border만 보임
        self._rounded_rect(x0, y0, x1, y1, r, 'white', '', 'bubble')
        self.cv.create_polygon(x1-2, by-5, x1+9, by, x1-2, by+5,
                                fill='white', outline='', tags='bubble')
        # ③ 텍스트
        self.cv.create_text(x0+pad, (y0+y1)/2, text=self.msg,
                             anchor='w', font=font, fill='#222222', tags='bubble')

    # ── Memo tag ──────────────────────────────────────────────

    MEMO_MAX_WIDTH_PX = 70   # macOS memoTagView의 .frame(width: 66)와 맞춤
    MEMO_MAX_LINES    = 2

    def _draw_memo(self):
        if not self.memo:
            return
        cx   = CHAR_CX + self.body_dx
        cy   = CHAR_CY + self.body_dy - P*7.0   # 귀 끝보다 넉넉히 위에 배치
        font = _memo_font()
        lines = _wrap_memo_lines(self.memo, font,
                                  self.MEMO_MAX_WIDTH_PX, self.MEMO_MAX_LINES)
        if not lines:
            return
        # 마지막 줄이 기존 단일 줄 위치(cy)에 오도록 하고, 앞 줄들은 위로 쌓는다
        line_h = font.metrics('linespace')
        n = len(lines)
        for idx, line in enumerate(lines):
            ly = cy - (n - 1 - idx) * line_h
            self.cv.create_text(cx+1, ly+1, text=line, anchor='center',
                                 font=font, fill='#999999', tags='memo')
            self.cv.create_text(cx, ly, text=line, anchor='center',
                                 font=font, fill='#FFFFFF', tags='memo')

    # ── Usage bar ─────────────────────────────────────────────

    def _draw_bar(self):
        if self.state == 'idle':
            return

        SH = 6          # 바 높이 (pill 형태)
        R  = 3          # 모서리 반지름
        # 이전보다 조금 작게: P*9 ≈ 58px
        bx = CHAR_CX - P * 4.5
        w  = P * 9

        display_pct = (self._server_utilization
                       if self._server_utilization is not None
                       else self._usage * 100)

        feet_y  = CHAR_CY + P * 3.35
        lv_y    = feet_y + 8
        bar_y   = lv_y + 8      # 레벨 텍스트와 바 간격 축소
        label_y = bar_y + SH + 6

        # ── 텍스트 그리기 헬퍼: 1px 쉐도우 + 본문 ──────────────
        def _txt(x, y, text, anchor, font, color, shadow='#555555'):
            self.cv.create_text(x+1, y+1, text=text, anchor=anchor,
                                font=font, fill=shadow, tags='bar')
            self.cv.create_text(x,   y,   text=text, anchor=anchor,
                                font=font, fill=color,  tags='bar')

        # 레벨 텍스트
        _txt(bx, lv_y,
             text=f'Lv.{self.shop.level}',
             anchor='w', font=('Consolas', 6, 'bold'), color='#F2CC25')

        # 트랙 (어두운 pill)
        self._rounded_rect(bx, bar_y, bx + w, bar_y + SH, R, '#2A2A2A', '', 'bar')

        # 채움 (컬러 pill)
        if display_pct > 0:
            fill_ratio = min(1.0, display_pct / 100)
            fill_w = max(w * fill_ratio, R * 2 + 2)   # 최소 너비 확보
            fc = ('#4DDA59' if display_pct <= 50
                  else '#F2CC25' if display_pct <= 75
                  else '#F24D33')
            self._rounded_rect(bx, bar_y, bx + fill_w, bar_y + SH, R, fc, '', 'bar')
            # 상단 하이라이트 (맥 버전 광택)
            if fill_w > R * 2 + 4:
                self.cv.create_rectangle(
                    bx + R + 1, bar_y + 1,
                    bx + fill_w - R - 1, bar_y + 2,
                    fill='#FFFFFF', outline='', tags='bar')

        # 라벨: % (왼쪽), ↺ (오른쪽)
        _lf = ('Consolas', 6, 'bold')
        label_pct = (f'{round(display_pct)}%'
                     if self._server_utilization is not None else t('동기화중', 'syncing'))
        _txt(bx, label_y, text=label_pct,
             anchor='w', font=_lf, color='#AAAAAA')
        rst = self._reset_time_str()
        if rst:
            _txt(bx + w, label_y, text=f'↺ {rst}',
                 anchor='e', font=_lf, color='#AAAAAA')

    def _reset_time_str(self) -> str:
        # 맥과 동일하게: 서버 resets_at 우선, 없으면 session_start + 5시간으로 추정
        if self._server_resets_at is not None:
            reset_at = self._server_resets_at
        elif self._session_start is not None:
            reset_at = self._session_start + datetime.timedelta(hours=5)
        else:
            return ''
        now  = datetime.datetime.now(datetime.timezone.utc)
        diff = int((reset_at - now).total_seconds())
        if diff <= 0:
            return ''
        h = diff // 3600; m = (diff % 3600) // 60
        return f'{h}:{m:02d}' if h > 0 else f'{m}m'

    def _tick_bar_refresh(self):
        if self._destroyed:
            return
        if self.state != 'idle':
            self._draw()
        self.win.after(30_000, self._tick_bar_refresh)

    # ── Blink ─────────────────────────────────────────────────

    def _schedule_blink(self):
        if self._destroyed:
            return
        self._blink_job = self.win.after(random.randint(2500, 6000), self._do_blink)

    def _do_blink(self):
        if self._destroyed:
            return
        self.blinking = True;  self._draw()
        self.win.after(130, self._end_blink)

    def _end_blink(self):
        if self._destroyed:
            return
        self.blinking = False; self._draw()
        self._schedule_blink()

    # ── Idle hop ──────────────────────────────────────────────

    def _schedule_idle_hop(self):
        if self._destroyed:
            return
        self._idle_job = self.win.after(random.randint(5000, 14000), self._do_idle_hop)

    def _do_idle_hop(self):
        if self._destroyed:
            return
        if self.state != 'ready':
            self._schedule_idle_hop(); return
        if random.random() < 0.5:
            self._hop_anim(on_done=self._schedule_idle_hop)
        else:
            self._ear_anim(on_done=self._schedule_idle_hop)

    def _hop_anim(self, on_done=None):
        frames = [0, -P*0.8, -P*1.5, -P*1.8, -P*1.5, -P*0.8, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dy = 0; self._draw()
                if on_done: on_done(); return
            self.body_dy = frames[i]; self._draw()
            self.win.after(40, lambda: step(i+1))
        step()

    def _ear_anim(self, on_done=None):
        frames = [0, P*0.5, P*1.0, P*0.5, 0, -P*0.5, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dx = 0; self._draw()
                if on_done: on_done(); return
            self.body_dx = frames[i]; self._draw()
            self.win.after(60, lambda: step(i+1))
        step()

    def _bounce(self, high: bool = False):
        amp = -P*2.5 if high else -P*2.0
        frames = [0, P*0.5*amp/(-P*2), amp*0.8, amp, amp*0.8, P*0.5*amp/(-P*2), 0]
        frames = [0, amp*0.35, amp*0.80, amp, amp*0.80, amp*0.35, 0]
        def step(i=0):
            if self._destroyed: return
            if i >= len(frames):
                self.body_dy = 0; self._draw(); return
            self.body_dy = frames[i]; self._draw()
            self.win.after(30, lambda: step(i+1))
        step()

    # ── Laptop typing ─────────────────────────────────────────

    def _start_laptop(self):
        if self.show_laptop:
            return
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self.larm_dy =  P*1.00; self.rarm_dy =  P*1.00
        self.show_laptop  = True
        self.laptop_phase = False
        self._draw()
        self._tick_laptop()

    def _tick_laptop(self):
        if self._destroyed:
            return
        if self.state not in ('thinking', 'toolUse'):
            self._laptop_job = None; return
        self.laptop_phase = not self.laptop_phase
        base = P*1.00; swing = P*0.60
        if self.laptop_phase:
            self.larm_dy = base - swing; self.rarm_dy = base + swing
        else:
            self.larm_dy = base + swing; self.rarm_dy = base - swing
        self._draw()
        self._laptop_job = self.win.after(360, self._tick_laptop)

    def _stop_laptop(self):
        if self._laptop_job:
            self.win.after_cancel(self._laptop_job); self._laptop_job = None
        self.show_laptop = False
        if not self.show_reading:
            self.larm_dx = self.larm_dy = 0.0
            self.rarm_dx = self.rarm_dy = 0.0

    # ── Document reading ──────────────────────────────────────

    def _start_reading(self):
        if self.show_reading:
            return
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self.larm_dy =  P*0.25; self.rarm_dy =  P*0.25
        self.show_reading = True
        self.throw_dx = 0.0; self.throw_dy = 0.0
        self.doc_visible  = True
        self._reading_step = 0
        self._draw()
        self._step_reading()

    def _step_reading(self):
        if self._destroyed or self.state != 'toolRead':
            return
        self._reading_step += 1
        if self._reading_step % 3 == 0:
            self._throw_and_replace()
        else:
            phase = (self._reading_step % 2) == 0
            self.larm_dy = P*0.18 if phase else P*0.30
            self.rarm_dy = P*0.30 if phase else P*0.18
            self._draw()
            self._reading_job = self.win.after(1300, self._step_reading)

    def _throw_and_replace(self):
        if self._destroyed or self.state != 'toolRead':
            return
        # Arms up for the throw
        self.larm_dy = -P*0.30; self.rarm_dy = -P*0.30
        self.larm_dx =  P*1.80; self.rarm_dx = -P*1.80

        # Step through throw offset
        throw_frames = [(P*1.5, -P*1.0), (P*3.0, -P*2.0), (P*4.0, -P*3.0)]

        def step_throw(i=0):
            if self._destroyed: return
            if i < len(throw_frames):
                self.throw_dx, self.throw_dy = throw_frames[i]
                self._draw()
                self.win.after(65, lambda: step_throw(i+1))
            else:
                # Doc thrown away — hide and snap back
                self.doc_visible = False
                self.throw_dx = 0.0; self.throw_dy = 0.0
                self._draw()
                self.win.after(300, self._replace_doc)

        step_throw()

    def _replace_doc(self):
        if self._destroyed or self.state != 'toolRead':
            return
        self.doc_visible = True
        self.larm_dy =  P*0.25; self.rarm_dy =  P*0.25
        self.larm_dx =  P*1.55; self.rarm_dx = -P*1.55
        self._draw()
        self._reading_job = self.win.after(400, self._step_reading)

    def _stop_reading(self):
        if self._reading_job:
            self.win.after_cancel(self._reading_job); self._reading_job = None
        self.show_reading = False
        self.throw_dx = 0.0; self.throw_dy = 0.0
        self.doc_visible  = True
        if not self.show_laptop:
            self.larm_dx = self.larm_dy = 0.0
            self.rarm_dx = self.rarm_dy = 0.0

    # ── State machine ─────────────────────────────────────────

    def _apply_state(self, new_state: str, *, tool=None, notif=None,
                     perm_cmd=None, perm_id=None):
        if not self._destroyed:
            self.win.after(0, lambda: self._do_apply(
                new_state, tool, notif, perm_cmd, perm_id))

    # 세션이 실제로 "돌고 있는" 상태 — 비진행 → 진행으로 바뀌는 순간이 곧
    # "세션 시작"이고, 사용자가 숨긴 부니는 그 시점에만 다시 나타난다.
    RUNNING_STATES = ('thinking', 'toolUse', 'toolRead', 'permission',
                      'backgroundWork', 'ask_user')

    def _do_apply(self, new_state, tool, notif, perm_cmd, perm_id):
        if self._destroyed:
            return
        self.state = new_state
        self.wide_eyes = False

        # ── 숨김 해제 판정 — 새 작업이 시작될 때만 다시 나타난다
        running   = new_state in self.RUNNING_STATES
        run_start = running and not self._was_running
        self._was_running = running
        if run_start:
            # 실제로 새 작업이 시작됐다 — 전역 숨김도 여기서 함께 풀린다.
            # thinking/toolUse 상태는 아래에서 _auto_show()를 부르지 않으므로
            # (ready·permission에서만 호출) 여기서 직접 다시 띄운다.
            self.manager._is_manually_hidden = False
            self._manually_hidden = False
            self._auto_show()

        # Stop animations that are no longer relevant
        if new_state not in ('thinking', 'toolUse', 'backgroundWork'):
            self._stop_laptop()
        if new_state != 'toolRead':
            self._stop_reading()

        # 권한 요청·완료·확인 요청 — 왼팔을 들어 올리고 당근(입은 무기가 있으면 그 무기)을 쥔다
        if new_state in ('permission', 'completed', 'ask_user'):
            self.larm_dy = -P * 2.8
            self.show_carrot = True
        elif self.show_carrot:
            self.show_carrot = False
            if not (self.show_laptop or self.show_reading):
                self.larm_dy = 0.0
        # 대기를 벗어나면 무기 보여주기는 바로 접는다
        if new_state != 'ready' and self.showing_weapon:
            self._end_weapon_show()
        if new_state != 'ask_user':
            self._ask_is_hint = False

        # 관련 없는 상태로 넘어가면 떠 있던 팝업을 정리한다 — Windows는 각 상태가
        # 독립된 Toplevel 팝업이라, 정리하지 않으면 화면에 붕 뜬 채로 남는다.
        if new_state != 'permission' and self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()
        if new_state != 'completed' and self._completion_win and self._completion_win.winfo_exists():
            self._completion_win.destroy()
        if new_state != 'ask_user' and self._ask_user_win and self._ask_user_win.winfo_exists():
            self._ask_user_win.destroy()

        if new_state == 'idle':
            self.msg = None
            self._draw()
            # 자동 숨기기 제거 — 사용자가 직접 숨기기 전까지 표시 유지

        elif new_state == 'thinking':
            self.msg = t('코딩중', 'Coding')
            self._start_laptop()
            self._draw()

        elif new_state == 'toolUse':
            self.msg = tool or t('작업 중...', 'Working...')
            self._start_laptop()
            self._draw()

        elif new_state == 'toolRead':
            self.msg = tool or t('읽는 중...', 'Reading...')
            self._start_reading()
            self._draw()

        elif new_state == 'notification':
            self.msg = notif
            self._draw()
            self._bounce()
            self.win.after(5000, lambda: self._clear_msg_if(notif))

        elif new_state == 'backgroundWork':
            self.msg = notif
            self._start_laptop()
            self._draw()

        elif new_state == 'permission':
            self.wide_eyes = True
            self.msg = None
            self.perm_cmd = perm_cmd
            self.perm_id  = perm_id
            self._auto_show()
            self._draw()
            if not self.hidden_by_user:
                self._show_perm_popup()

        elif new_state == 'completed':
            self.msg = None
            self.wide_eyes = True
            self._bounce(high=True)
            self._draw()
            if not self.hidden_by_user:
                self._show_completion_popup()

        elif new_state == 'ask_user':
            self.wide_eyes = True
            self.msg = None
            self.ask_msg = notif or ''
            self._draw()
            if not self.hidden_by_user:
                self._show_ask_user_popup()

        elif new_state == 'ready':
            self.msg = None
            self._draw()
            self._auto_show()

        # completed/permission/ask_user 버블이 방금 사라졌다면, 밀려 있던
        # 한도 도달 안내를 지금 띄운다 (조건은 내부에서 다시 확인)
        if new_state not in ('permission', 'completed', 'ask_user'):
            self._maybe_show_limit_popup()

    @property
    def hidden_by_user(self) -> bool:
        """사용자가 숨긴 상태인지 — 이 세션 개별 숨김이거나 전체 숨김."""
        return self._manually_hidden or self.manager._is_manually_hidden

    def hide_until_next_start(self):
        """패널을 숨기고, 이 세션이 새로 시작될 때까지 숨김 상태를 유지한다."""
        self._manually_hidden = True
        self.hide()

    def _auto_show(self):
        """숨긴 상태가 아닐 때만 표시 — 사용자가 숨긴 뒤에는 이 세션이 새로
        시작되거나(위 _do_apply) "부니 불러오기"를 누르기 전까지는 어떤 상태
        변화(권한 요청 포함)로도 자동으로 다시 나타나지 않게 한다."""
        if not self.hidden_by_user:
            self.show()

    def _clear_msg_if(self, old_msg):
        if not self._destroyed and self.msg == old_msg:
            self.msg = None; self._draw()

    # ── Completion popup ─────────────────────────────────────────

    def _dismiss_completed(self):
        if self._completion_win:
            try: self._completion_win.destroy()
            except Exception: pass
            self._completion_win = None
        if self.state == 'completed':
            self._apply_state('ready')
            # 확인 버튼 클릭 시 세션 제거 (macOS onDismissCompleted 동작 일치)
            sid = self.session_id
            self.manager.root.after(0, lambda: self.manager.remove_session(sid))

    def _show_completion_popup(self):
        if self._completion_win and self._completion_win.winfo_exists():
            self._completion_win.destroy()

        TRANSP_  = '#010101'
        WHITE    = '#FFFFFF'
        SHADOW   = '#BBBBBB'
        BW       = 160
        TAIL_W   = 15
        R        = 14
        PAD      = 12
        TITLE_H  = 20
        BTN_H    = 28
        GAP      = 6
        WIN_H_   = PAD + TITLE_H + GAP + BTN_H + PAD

        def _get_geometry(h):
            self.win.update_idletasks()
            rx = self.win.winfo_rootx(); ry = self.win.winfo_rooty()
            pw = BW + TAIL_W
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            wx = rx + tail_tip_x - pw
            wy = ry + int(CHAR_CY - P * 3.5) - h // 2
            return pw, wx, wy

        def _bubble(cv, ox, oy, h, color):
            x0, y0, x1, y1 = ox, oy, ox + BW, oy + h
            cv.create_arc(x0, y0, x0+2*R, y0+2*R, start=90, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y0, x1, y0+2*R, start=0, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x0, y1-2*R, x0+2*R, y1, start=180, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y1-2*R, x1, y1, start=270, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0+R, y0, x1-R, y1,   fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0, y0+R, x1, y1-R,   fill=color, outline=color, tags='bubble')
            mid = oy + h // 2
            cv.create_polygon(x1, mid-7, x1+TAIL_W+ox, mid, x1, mid+7,
                              fill=color, outline=color, tags='bubble')

        WIN_W_, wx, wy = _get_geometry(WIN_H_)
        win = tk.Toplevel(self.win)
        self._completion_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.wm_attributes('-transparentcolor', TRANSP_)
        win.config(bg=TRANSP_)
        win.geometry(f'{WIN_W_}x{WIN_H_}+{wx}+{wy}')

        cv = tk.Canvas(win, width=WIN_W_, height=WIN_H_,
                       bg=TRANSP_, highlightthickness=0)
        cv.pack()

        _bubble(cv, 2, 3, WIN_H_, SHADOW)
        _bubble(cv, 0, 0, WIN_H_, WHITE)

        cv.create_text(PAD + 4, PAD + 2, text=t('✅ 완료했어요!', '✅ All done!'),
                       anchor='nw', font=('Consolas', 10, 'bold'),
                       fill='#000000', tags='bubble')

        def _darken(hex_color):
            r = max(0, int(hex_color[1:3], 16) - 30)
            g = max(0, int(hex_color[3:5], 16) - 30)
            b = max(0, int(hex_color[5:7], 16) - 30)
            return f'#{r:02X}{g:02X}{b:02X}'

        btn_y = PAD + TITLE_H + GAP
        bg    = '#2DB357'
        label = t('확인', 'OK')
        bw    = len(label) * 9 + 20
        bx    = PAD
        br    = 7
        by0, by1 = btn_y, btn_y + BTN_H
        for dx0,dy0,dx1,dy1,st in [
            (bx,by0,bx+2*br,by0+2*br,90),(bx+bw-2*br,by0,bx+bw,by0+2*br,0),
            (bx,by1-2*br,bx+2*br,by1,180),(bx+bw-2*br,by1-2*br,bx+bw,by1,270)]:
            cv.create_arc(dx0,dy0,dx1,dy1, start=st, extent=90,
                          fill=bg, outline=bg, tags=('btn', 'btnbg', 'bubble'))
        cv.create_rectangle(bx+br, by0, bx+bw-br, by1, fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_rectangle(bx, by0+br, bx+bw, by1-br,  fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_text(bx + bw//2, btn_y + BTN_H//2, text=label,
                       font=('Consolas', 9, 'bold'), fill='white', tags=('btn','bubble'))
        cv.tag_bind('btn', '<Button-1>', lambda _: self._dismiss_completed())
        cv.tag_bind('btn', '<Enter>',
                    lambda _: cv.itemconfig('btnbg', fill=_darken(bg), outline=_darken(bg)))
        cv.tag_bind('btn', '<Leave>',
                    lambda _: cv.itemconfig('btnbg', fill=bg, outline=bg))

    # ── Ask-user popup (AskUserQuestion — 클로드 열기 버튼 제공) ──

    def _show_ask_user_popup(self):
        if self._ask_user_win and self._ask_user_win.winfo_exists():
            self._ask_user_win.destroy()

        TRANSP_  = '#010101'
        WHITE    = '#FFFFFF'
        SHADOW   = '#BBBBBB'
        BW       = 170
        TAIL_W   = 15
        R        = 14
        PAD      = 12
        TITLE_H  = 20
        BTN_H    = 28
        GAP      = 6
        QLINE_H  = 15
        # 훅이 실어 보낸 AskUserQuestion 질문을 제목 아래에 최대 2줄까지 보여준다
        q_font   = tkfont.Font(family='Malgun Gothic', size=8)
        q_lines  = (_wrap_memo_lines(self.ask_msg, q_font, BW - PAD * 2 - 8, max_lines=2)
                    if self.ask_msg else [])
        WIN_H_   = PAD + TITLE_H + len(q_lines) * QLINE_H + GAP + BTN_H + PAD

        def _get_geometry(h):
            self.win.update_idletasks()
            rx = self.win.winfo_rootx(); ry = self.win.winfo_rooty()
            pw = BW + TAIL_W
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            wx = rx + tail_tip_x - pw
            wy = ry + int(CHAR_CY - P * 3.5) - h // 2
            return pw, wx, wy

        def _bubble(cv, ox, oy, h, color):
            x0, y0, x1, y1 = ox, oy, ox + BW, oy + h
            cv.create_arc(x0, y0, x0+2*R, y0+2*R, start=90, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y0, x1, y0+2*R, start=0, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x0, y1-2*R, x0+2*R, y1, start=180, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y1-2*R, x1, y1, start=270, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0+R, y0, x1-R, y1,   fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0, y0+R, x1, y1-R,   fill=color, outline=color, tags='bubble')
            mid = oy + h // 2
            cv.create_polygon(x1, mid-7, x1+TAIL_W+ox, mid, x1, mid+7,
                              fill=color, outline=color, tags='bubble')

        def _darken(hex_color):
            r = max(0, int(hex_color[1:3], 16) - 30)
            g = max(0, int(hex_color[3:5], 16) - 30)
            b = max(0, int(hex_color[5:7], 16) - 30)
            return f'#{r:02X}{g:02X}{b:02X}'

        WIN_W_, wx, wy = _get_geometry(WIN_H_)
        win = tk.Toplevel(self.win)
        self._ask_user_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.wm_attributes('-transparentcolor', TRANSP_)
        win.config(bg=TRANSP_)
        win.geometry(f'{WIN_W_}x{WIN_H_}+{wx}+{wy}')

        cv = tk.Canvas(win, width=WIN_W_, height=WIN_H_,
                       bg=TRANSP_, highlightthickness=0)
        cv.pack()

        _bubble(cv, 2, 3, WIN_H_, SHADOW)
        _bubble(cv, 0, 0, WIN_H_, WHITE)

        cv.create_text(PAD + 4, PAD + 2, text=t('✅ 확인이 필요해요!', '✅ Needs your input!'),
                       anchor='nw', font=('Consolas', 10, 'bold'),
                       fill='#000000', tags='bubble')

        for i, line in enumerate(q_lines):
            cv.create_text(PAD + 4, PAD + TITLE_H + i * QLINE_H, text=line,
                           anchor='nw', font=q_font, fill='#404040', tags='bubble')

        btn_y = PAD + TITLE_H + len(q_lines) * QLINE_H + GAP
        bg    = '#3377E0'
        label = t('클로드 열기', 'Open Claude')
        bw    = len(label) * 9 + 20
        bx    = PAD
        br    = 7
        by0, by1 = btn_y, btn_y + BTN_H
        for dx0,dy0,dx1,dy1,st in [
            (bx,by0,bx+2*br,by0+2*br,90),(bx+bw-2*br,by0,bx+bw,by0+2*br,0),
            (bx,by1-2*br,bx+2*br,by1,180),(bx+bw-2*br,by1-2*br,bx+bw,by1,270)]:
            cv.create_arc(dx0,dy0,dx1,dy1, start=st, extent=90,
                          fill=bg, outline=bg, tags=('btn', 'btnbg', 'bubble'))
        cv.create_rectangle(bx+br, by0, bx+bw-br, by1, fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_rectangle(bx, by0+br, bx+bw, by1-br,  fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_text(bx + bw//2, btn_y + BTN_H//2, text=label,
                       font=('Consolas', 9, 'bold'), fill='white', tags=('btn','bubble'))
        cv.tag_bind('btn', '<Button-1>', lambda _: self._open_claude())
        cv.tag_bind('btn', '<Enter>',
                    lambda _: cv.itemconfig('btnbg', fill=_darken(bg), outline=_darken(bg)))
        cv.tag_bind('btn', '<Leave>',
                    lambda _: cv.itemconfig('btnbg', fill=bg, outline=bg))

    # ── Limit-reached popup (한도 도달 — 카운트다운 + 숨기기 버튼) ──

    def _maybe_show_limit_popup(self):
        """서버 사용률이 100%에 도달하면 안내 팝업을 띄운다.
        완료/권한/확인 요청 버블과 겹치지 않도록, 그런 상태가 아닐 때만 띄운다."""
        reached = (self._server_utilization is not None and
                   self._server_utilization >= 100)
        if not reached or self._limit_notice_dismissed:
            self._hide_limit_popup()
            return
        if self.state in ('permission', 'completed', 'ask_user'):
            return
        if self.hidden_by_user:
            return
        if self._limit_win and self._limit_win.winfo_exists():
            self._tick_limit_popup()
            return
        self._show_limit_popup()

    def _hide_limit_popup(self):
        if self._limit_job:
            try: self.win.after_cancel(self._limit_job)
            except Exception: pass
            self._limit_job = None
        if self._limit_win and self._limit_win.winfo_exists():
            self._limit_win.destroy()
        self._limit_win = None

    def _limit_countdown_str(self) -> str:
        if self._server_resets_at is None:
            return t('재설정 시각 확인 중', 'Checking reset time')
        now  = datetime.datetime.now(datetime.timezone.utc)
        diff = int((self._server_resets_at - now).total_seconds())
        if diff <= 0:
            return t('곧 재설정돼요', 'Resetting soon')
        h = diff // 3600; m = (diff % 3600) // 60; s = diff % 60
        return (f'{h}:{m:02d}:{s:02d} 후 재설정' if h > 0
                else f'{m}:{s:02d} 후 재설정')

    def _show_limit_popup(self):
        if self._limit_win and self._limit_win.winfo_exists():
            self._limit_win.destroy()

        TRANSP_  = '#010101'
        WHITE    = '#FFFFFF'
        SHADOW   = '#BBBBBB'
        BW       = 190
        TAIL_W   = 15
        R        = 14
        PAD      = 12
        TITLE_H  = 20
        TXT_H    = 18
        BTN_H    = 26
        GAP      = 6
        WIN_H_   = PAD + TITLE_H + GAP + TXT_H + GAP + BTN_H + PAD

        def _get_geometry(h):
            self.win.update_idletasks()
            rx = self.win.winfo_rootx(); ry = self.win.winfo_rooty()
            pw = BW + TAIL_W
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            wx = rx + tail_tip_x - pw
            wy = ry + int(CHAR_CY - P * 3.5) - h // 2
            return pw, wx, wy

        def _bubble(cv, ox, oy, h, color):
            x0, y0, x1, y1 = ox, oy, ox + BW, oy + h
            cv.create_arc(x0, y0, x0+2*R, y0+2*R, start=90, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y0, x1, y0+2*R, start=0, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x0, y1-2*R, x0+2*R, y1, start=180, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y1-2*R, x1, y1, start=270, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0+R, y0, x1-R, y1,   fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0, y0+R, x1, y1-R,   fill=color, outline=color, tags='bubble')
            mid = oy + h // 2
            cv.create_polygon(x1, mid-7, x1+TAIL_W+ox, mid, x1, mid+7,
                              fill=color, outline=color, tags='bubble')

        def _darken(hex_color):
            r = max(0, int(hex_color[1:3], 16) - 30)
            g = max(0, int(hex_color[3:5], 16) - 30)
            b = max(0, int(hex_color[5:7], 16) - 30)
            return f'#{r:02X}{g:02X}{b:02X}'

        WIN_W_, wx, wy = _get_geometry(WIN_H_)
        win = tk.Toplevel(self.win)
        self._limit_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.wm_attributes('-transparentcolor', TRANSP_)
        win.config(bg=TRANSP_)
        win.geometry(f'{WIN_W_}x{WIN_H_}+{wx}+{wy}')

        cv = tk.Canvas(win, width=WIN_W_, height=WIN_H_,
                       bg=TRANSP_, highlightthickness=0)
        cv.pack()

        _bubble(cv, 2, 3, WIN_H_, SHADOW)
        _bubble(cv, 0, 0, WIN_H_, WHITE)

        cv.create_text(PAD + 4, PAD + 2, text=t('⏳ 한도에 도달했어요', '⏳ Usage limit reached'),
                       anchor='nw', font=('Consolas', 10, 'bold'),
                       fill='#000000', tags='bubble')

        txt_y = PAD + TITLE_H + GAP
        cv.create_text(PAD + 4, txt_y, text=self._limit_countdown_str(),
                       anchor='nw', font=('Consolas', 9, 'bold'),
                       fill='#444444', tags=('bubble', 'limit_countdown'))

        btn_y = txt_y + TXT_H + GAP
        bg    = '#73737F'
        label = t('숨기기', 'Hide')
        bw    = len(label) * 9 + 20
        bx    = PAD
        br    = 7
        by0, by1 = btn_y, btn_y + BTN_H
        for dx0,dy0,dx1,dy1,st in [
            (bx,by0,bx+2*br,by0+2*br,90),(bx+bw-2*br,by0,bx+bw,by0+2*br,0),
            (bx,by1-2*br,bx+2*br,by1,180),(bx+bw-2*br,by1-2*br,bx+bw,by1,270)]:
            cv.create_arc(dx0,dy0,dx1,dy1, start=st, extent=90,
                          fill=bg, outline=bg, tags=('btn', 'btnbg', 'bubble'))
        cv.create_rectangle(bx+br, by0, bx+bw-br, by1, fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_rectangle(bx, by0+br, bx+bw, by1-br,  fill=bg, outline=bg, tags=('btn','btnbg','bubble'))
        cv.create_text(bx + bw//2, btn_y + BTN_H//2, text=label,
                       font=('Consolas', 9, 'bold'), fill='white', tags=('btn','bubble'))
        cv.tag_bind('btn', '<Button-1>', lambda _: self._dismiss_limit_notice())
        cv.tag_bind('btn', '<Enter>',
                    lambda _: cv.itemconfig('btnbg', fill=_darken(bg), outline=_darken(bg)))
        cv.tag_bind('btn', '<Leave>',
                    lambda _: cv.itemconfig('btnbg', fill=bg, outline=bg))

        self._tick_limit_popup()

    def _tick_limit_popup(self):
        if self._destroyed or not (self._limit_win and self._limit_win.winfo_exists()):
            return
        try:
            cv = self._limit_win.children['!canvas']
            cv.itemconfig('limit_countdown', text=self._limit_countdown_str())
        except Exception:
            pass
        self._limit_job = self.win.after(1000, self._tick_limit_popup)

    def _dismiss_limit_notice(self):
        self._limit_notice_dismissed = True
        self._hide_limit_popup()

    # ── Permission popup ──────────────────────────────────────

    def _show_perm_popup(self):
        if self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()

        # ── 상수 ──────────────────────────────────────────────
        TRANSP   = '#010101'
        WHITE    = '#FFFFFF'
        SHADOW   = '#BBBBBB'
        CMD_BG   = '#F0F0F0'
        BW       = 230          # 말풍선 너비 (꼬리 제외)
        TAIL_W   = 15           # 꼬리 너비
        R        = 14           # 모서리 반지름
        PAD      = 12           # 내부 여백
        TITLE_H  = 20
        BTN_H    = 28
        GAP      = 6
        CMD_H    = 72           # 명령 영역 고정 높이 (스크롤)

        cmd = (self.perm_cmd or '').strip()

        # ── 위치 계산 ─────────────────────────────────────────
        _bubble_by = int(CHAR_CY - P * 3.5)

        def _get_geometry(h: int):
            self.win.update_idletasks()
            rx = self.win.winfo_rootx(); ry = self.win.winfo_rooty()
            pw = BW + TAIL_W
            tail_tip_x = int(CHAR_CX - P * 5) + 9 - 30
            wx = rx + tail_tip_x - pw
            wy = ry + _bubble_by - h // 2
            return pw, wx, wy

        # ── 헬퍼: 말풍선 + 꼬리 ───────────────────────────────
        def _bubble(cv, ox, oy, h, color):
            x0, y0, x1, y1 = ox, oy, ox + BW, oy + h
            cv.create_arc(x0, y0, x0+2*R, y0+2*R, start=90, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y0, x1, y0+2*R, start=0, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x0, y1-2*R, x0+2*R, y1, start=180, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_arc(x1-2*R, y1-2*R, x1, y1, start=270, extent=90,
                          fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0+R, y0, x1-R, y1,   fill=color, outline=color, tags='bubble')
            cv.create_rectangle(x0, y0+R, x1, y1-R,   fill=color, outline=color, tags='bubble')
            mid = oy + h // 2
            cv.create_polygon(x1, mid-7, x1+TAIL_W+ox, mid, x1, mid+7,
                              fill=color, outline=color, tags='bubble')

        def _darken(hex_color: str) -> str:
            r = max(0, int(hex_color[1:3], 16) - 30)
            g = max(0, int(hex_color[3:5], 16) - 30)
            b = max(0, int(hex_color[5:7], 16) - 30)
            return f'#{r:02X}{g:02X}{b:02X}'

        # ── 윈도우 생성 ───────────────────────────────────────
        WIN_H         = PAD + TITLE_H + GAP + CMD_H + GAP + BTN_H + PAD
        WIN_W, wx, wy = _get_geometry(WIN_H)

        win = tk.Toplevel(self.win)
        self._perm_win = win
        win.overrideredirect(True)
        win.wm_attributes('-topmost', True)
        win.wm_attributes('-transparentcolor', TRANSP)
        win.config(bg=TRANSP)
        win.geometry(f'{WIN_W}x{WIN_H}+{wx}+{wy}')

        cv = tk.Canvas(win, width=WIN_W, height=WIN_H,
                       bg=TRANSP, highlightthickness=0)
        cv.pack()

        # 말풍선 배경
        _bubble(cv, 2, 3, WIN_H, SHADOW)
        _bubble(cv, 0, 0, WIN_H, WHITE)

        # 제목
        cv.create_text(PAD + 4, PAD + 2, text=t('🔐 실행 허용?', '🔐 Run this?'),
                       anchor='nw', font=('Consolas', 10, 'bold'),
                       fill='#000000', tags='bubble')

        # 명령 박스 배경 (둥근 사각형)
        cmd_y = PAD + TITLE_H + GAP
        cx0, cy0 = PAD, cmd_y
        cx1, cy1 = BW - PAD, cmd_y + CMD_H
        cr = 6
        for dx0, dy0, dx1, dy1, start in [
            (cx0,cy0,cx0+2*cr,cy0+2*cr,90),(cx1-2*cr,cy0,cx1,cy0+2*cr,0),
            (cx0,cy1-2*cr,cx0+2*cr,cy1,180),(cx1-2*cr,cy1-2*cr,cx1,cy1,270)]:
            cv.create_arc(dx0,dy0,dx1,dy1, start=start, extent=90,
                          fill=CMD_BG, outline=CMD_BG, tags='bubble')
        cv.create_rectangle(cx0+cr, cy0, cx1-cr, cy1, fill=CMD_BG, outline=CMD_BG, tags='bubble')
        cv.create_rectangle(cx0, cy0+cr, cx1, cy1-cr, fill=CMD_BG, outline=CMD_BG, tags='bubble')

        # 스크롤 가능한 텍스트 위젯
        txt = tk.Text(win, bg=CMD_BG, fg='#333333',
                      font=('Consolas', 8), bd=0, highlightthickness=0,
                      wrap='word', relief='flat', cursor='arrow',
                      padx=5, pady=4)
        txt.insert('1.0', cmd)
        txt.config(state='disabled')
        cv.create_window(cx0 + cr, cy0 + 3, anchor='nw', window=txt,
                         width=cx1 - cx0 - cr * 2, height=CMD_H - 6)

        def _on_wheel(e):
            txt.yview_scroll(int(-1 * (e.delta / 120)), 'units')
        txt.bind('<MouseWheel>', _on_wheel)
        cv.bind('<MouseWheel>', _on_wheel)

        # 버튼
        btn_y = cmd_y + CMD_H + GAP
        btns  = [(t('거부', 'Deny'), '#DA3733', 'deny'),
                 (t('허용', 'Allow'), '#2DB357', 'approve'),
                 (t('전체 허용', 'Allow all'), '#3377E0', 'approve_all')]
        bx = PAD
        for label, bg, action in btns:
            bw = len(label) * 9 + 16
            by0, by1 = btn_y, btn_y + BTN_H
            br = 7
            tag    = f'btn_{action}'
            tag_bg = f'btnbg_{action}'
            for dx0,dy0,dx1,dy1,st in [
                (bx,by0,bx+2*br,by0+2*br,90),(bx+bw-2*br,by0,bx+bw,by0+2*br,0),
                (bx,by1-2*br,bx+2*br,by1,180),(bx+bw-2*br,by1-2*br,bx+bw,by1,270)]:
                cv.create_arc(dx0,dy0,dx1,dy1, start=st, extent=90,
                              fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_rectangle(bx+br, by0, bx+bw-br, by1, fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_rectangle(bx, by0+br, bx+bw, by1-br, fill=bg, outline=bg, tags=(tag, tag_bg, 'bubble'))
            cv.create_text(bx + bw//2, btn_y + BTN_H//2, text=label,
                           font=('Consolas', 9, 'bold'), fill='white', tags=(tag, 'bubble'))
            cv.tag_bind(tag, '<Button-1>', lambda _, a=action: self._decide(a))
            cv.tag_bind(tag, '<Enter>',
                        lambda _, tb=tag_bg, b=bg: cv.itemconfig(tb, fill=_darken(b), outline=_darken(b)))
            cv.tag_bind(tag, '<Leave>',
                        lambda _, tb=tag_bg, b=bg: cv.itemconfig(tb, fill=b, outline=b))
            bx += bw + 6

    def _decide(self, action: str):
        if self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.destroy()
        pid = self.perm_id
        if not pid:
            return
        if action == 'approve_all':
            self.always_approve = True
            self._save_always_approve()
            action = 'approve'
        decision = 'approve' if action == 'approve' else 'deny'
        try:
            (_TEMP / f'claude-companion-decision-{pid}').write_text(decision)
        except Exception:
            pass
        self.perm_id = None
        self._apply_state('thinking')

    # ── Context menu ──────────────────────────────────────────

    def _build_menu(self):
        self._menu = tk.Menu(self.win, tearoff=0)
        # 트레이의 "부니 숨기기"와 동일한 전체 숨김으로 위임 — 이 창만 hide()하면
        # manager._is_manually_hidden이 안 켜져서, 다른 상태 변화나 새 Claude
        # 세션으로 언제든 되살아나 버린다.
        # ── 이 부니
        self._menu.add_command(label=t('숨기기', 'Hide'),  command=self.manager.hide_all)
        self._menu.add_command(label=t('위치 초기화', 'Reset position'),  command=self._reset_position)

        char_menu = tk.Menu(self._menu, tearoff=0)
        for cid in CHAR_DISPLAY_NAMES:
            name = char_display_name(cid)
            char_menu.add_command(label=name,
                                   command=lambda c=cid: self._set_character(c))
        self._menu.add_cascade(label=t('캐릭터 변경', 'Change character'), menu=char_menu)

        label = t('메모 추가...', 'Add note...') if not self.memo else t('메모 편집...', 'Edit note...')
        self._menu.add_command(label=label, command=self._edit_memo)
        if self.memo:
            self._menu.add_command(label=t('메모 지우기', 'Clear note'), command=self._clear_memo)

        # ── 꾸미기 · 함께하기
        self._menu.add_separator()
        self._menu.add_command(label=t(f'🛍 부니 상점  (🪙 {self.shop.coins})', f'🛍 Buni Shop  (🪙 {self.shop.coins})'),
                               command=lambda: self.manager.open_shop(self.character))
        self._menu.add_command(label=t('💬 부니 채팅...', '💬 Buni Chat...'), command=self.manager.open_chat)

        # ── 앱
        self._menu.add_separator()
        self._menu.add_command(label=t('Claude 열기', 'Open Claude'), command=self._open_claude)
        self._menu.add_command(label=t('설정...', 'Settings...'), command=self.manager._open_shortcut_settings)
        self._menu.add_separator()
        self._menu.add_command(label=t('세션 끊기', 'Disconnect session'),    command=self._disconnect)
        self._menu.add_command(label=t('종료', 'Quit'), command=self.manager.quit)

    def _show_menu(self, e: tk.Event):
        self._build_menu()
        try:
            self._menu.tk_popup(e.x_root, e.y_root)
        finally:
            self._menu.grab_release()

    def _open_claude(self):
        try:
            os.startfile('claude')
        except Exception:
            pass

    def _set_character(self, char_id: str):
        self.character = char_id
        self._save_character()
        self._draw()

    def _edit_memo(self):
        result = simpledialog.askstring(
            t('메모 설정', 'Set note'),
            t('이 캐릭터의 메모를 입력하세요:\n(빈칸으로 두면 세션 이름으로 되돌아갑니다)',
              'Enter a note for this character:\n(Leave empty to go back to the session name)'),
            initialvalue=self.memo, parent=self.win)
        if result is None:
            return
        trimmed = result.strip()
        if not trimmed:
            # 비우면 "메모 없음"이 아니라 기본값(세션 이름)으로 되돌린다
            self._clear_memo()
            return
        # 직접 입력한 순간부터 세션 이름 자동 연동을 끈다
        self.memo_is_auto = False
        self.memo = trimmed
        self._save_memo()
        self._draw()

    def _clear_memo(self):
        """메모를 비웠을 때 — 저장된 메모를 지우고 기본값인
        "세션 이름 자동 연동"으로 되돌린다."""
        self.memo_is_auto = True
        self.memo = ''
        self._save_memo()
        self._draw()
        # 15초 주기 폴링을 기다리지 않고 지금 바로 세션 이름을 채운다
        title = _read_session_title(self.session_id)
        if title:
            self.memo = title
            self._draw()

    def _reset_position(self):
        if self.slot == 0:
            self.persist.remove('window_pos')
        self._position_window()

    # ── Usage ─────────────────────────────────────────────────

    def set_usage(self, pct: float, session_start_ts=None):
        self._usage = max(0.0, min(1.0, pct / 100.0))
        if session_start_ts:
            try:
                parsed = datetime.datetime.fromisoformat(
                    session_start_ts.replace('Z', '+00:00'))
                if self._session_start is None or parsed < self._session_start:
                    self._session_start = parsed
            except Exception:
                pass
        self._draw()

    def set_monthly_tokens(self, tokens: int):
        self._monthly_tokens = tokens
        self._draw()

    def set_server_usage(self, utilization: float | None, resets_at: datetime.datetime | None):
        # 한도 창이 새로 시작됐거나 아직 한도 전이면 숨김 상태 해제
        # (다음 한도 도달 때 안내가 다시 뜨도록)
        if self._server_resets_at != resets_at or (utilization or 0) < 100:
            self._limit_notice_dismissed = False
        self._server_utilization = utilization
        self._server_resets_at   = resets_at
        self._draw()
        self._maybe_show_limit_popup()

    # ── Event file polling ────────────────────────────────────

    def _init_file_offset(self):
        try:
            if self.event_file.exists():
                st = self.event_file.stat()
                # Windows: st_ctime는 생성 시각 — 90초 이내 파일은 처음부터 읽어
                # 세션 시작 초반 이벤트(파일 탐색 등) 누락 방지
                # 오래된 파일은 마지막 1KB만 읽어 직전 이벤트 복원
                creation_age = time.time() - st.st_ctime
                self._file_offset = 0 if creation_age < 90.0 else max(0, st.st_size - 1024)
        except Exception:
            pass

    def poll_events(self) -> bool:
        """Read new lines from event file. Returns False if file gone."""
        if self._destroyed:
            return False
        try:
            size = self.event_file.stat().st_size
        except FileNotFoundError:
            # 파일이 삭제됐어도 창은 유지 — 사용자가 숨길 때까지
            return True

        if size > self._file_offset:
            try:
                with self.event_file.open('r', encoding='utf-8', errors='replace') as f:
                    f.seek(self._file_offset)
                    data = f.read()
                self._file_offset = self.event_file.stat().st_size
            except Exception:
                data = ''
            for line in data.splitlines():
                if line.strip():
                    self._last_event_time = time.time()
                    self._handle_event(line)
            self._is_replaying = False   # 첫 poll(에서 읽은 데이터) 처리 후 재생 모드 해제

        # 새 이벤트 유무와 무관하게 매 호출마다 검사 (기존엔 새 데이터가 있을 때만
        # 검사해서, 정작 "한동안 이벤트가 없는" 상황에는 절대 작동하지 않았음).
        # 5분간 새 이벤트가 없으면 조용한 상태로 되돌린다 (훅 누락·조용히 끝난
        # 세션 등에 대한 안전망). 오래 걸리는 도구가 실행 중
        # (tool_use 후 tool_done 미도착)이면 이벤트가 없는 게 정상이므로 건드리지 않는다.
        quiet_for = time.time() - self._last_event_time

        # 도구가 시작됐는데 한참 아무 소식이 없다 = 클로드가 확인 창을 띄우고 기다리는 중일
        # 가능성이 높다. 훅이 오지 않는 확인 창(브라우저 사이트 권한 등)을 알리는 유일한
        # 방법이라 여기서 추정한다. Bash처럼 원래 오래 도는 도구까지 잡으면 오탐이 잦아,
        # 보통 몇 초 안에 끝나는 MCP 도구에만 적용한다.
        if (self._pending_tools > 0 and not self._wait_hint_shown and quiet_for > 20
                and self._pending_tool_name and self._pending_tool_name.startswith('mcp__')
                and self.state in ('thinking', 'toolUse', 'toolRead')):
            self._wait_hint_shown = True
            self._ask_is_hint = True
            hint = (self._fmt_tool(self._pending_tool_name.lower())
                    + t(' — 클로드 창에서 확인을 기다리는 중일 수 있어요',
                        ' — Claude may be waiting for your confirmation'))
            self._apply_state('ask_user', notif=hint)

        # 승인 버튼 없는 확인 버블(ask_user·확인 대기 추정)은 터미널에서 답해도 후속
        # 이벤트가 안 올 수 있어, 한동안 조용하면 스스로 정리한다.
        if self.state == 'ask_user' and quiet_for > 120:
            self._pending_tools = 0
            self._apply_state('ready')

        if self._pending_tools == 0:
            if (self.state not in ('idle', 'completed', 'permission', 'ask_user', 'backgroundWork')
                    and quiet_for > 300):
                self._apply_state('idle')
            elif self.state == 'backgroundWork' and quiet_for > self._background_stale_seconds:
                # 훅에는 "백그라운드 작업이 끝났다"는 신호가 따로 없어(다음 Stop이
                # 와야 최신 상태를 알 수 있음), 오래 조용하면 정보가 낡았다고 보고
                # "완료"로 단정하지 않고 조용한 대기 상태로 되돌린다.
                self._apply_state('ready')

        return True

    def _handle_event(self, raw: str):
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            return
        et = ev.get('type', '')

        # 뒤늦게 도착하는 지연 전환이 최신 이벤트를 덮어쓰지 않도록 순번을 올린다
        self._event_seq += 1

        if et == 'tool_use':
            # 과거 이벤트 재생으로 이미 끝난 도구 실행이 되살아나는 것 방지
            if self._is_replaying:
                return
            # 권한/확인 요청 중에는 도구 이벤트 무시 — 말풍선 겹침 방지
            # (훅 없는 확인 창을 추정해 띄운 안내는 예외 — 도구가 진행되면 걷는다)
            if self.state == 'permission' or (self.state == 'ask_user' and not self._ask_is_hint):
                return
            # 새 작업이 시작됐으니 대기 중이던 "완료" 표시는 취소
            if self._completion_job:
                self.win.after_cancel(self._completion_job)
                self._completion_job = None
            self._pending_tools += 1
            tool_raw   = ev.get('tool', 'tool')
            self._pending_tool_name = tool_raw
            self._wait_hint_shown   = False
            label      = self._fmt_tool(tool_raw)
            next_state = 'toolRead' if tool_raw.lower() in READ_TOOLS else 'toolUse'
            # macOS처럼 ready 상태에서는 thinking 0.6초 후 도구 상태로 전환
            if self.state == 'ready':
                seq = self._event_seq
                self._apply_state('thinking')
                self.win.after(600, lambda ns=next_state, lb=label, s=seq: (
                    self._apply_state(ns, tool=lb)
                    if self._event_seq == s and self.state == 'thinking' else None
                ))
            else:
                self._apply_state(next_state, tool=label)

        elif et == 'tool_done':
            if self._is_replaying:
                return
            if self.state == 'permission' or (self.state == 'ask_user' and not self._ask_is_hint):
                return
            self._pending_tools = max(0, self._pending_tools - 1)
            if self._pending_tools == 0:
                self._pending_tool_name = None
            self._wait_hint_shown = False
            self._apply_state('thinking')

        elif et == 'thinking':
            is_stale = (time.time() - ev.get('ts', 0) > 30) if 'ts' in ev else True
            if self._is_replaying and is_stale:
                return
            if self._completion_job:
                self.win.after_cancel(self._completion_job)
                self._completion_job = None
            self._pending_tools = 0   # 새 턴 시작 — 이전 턴에서 남은 카운트 정리
            self._pending_tool_name = None
            self._wait_hint_shown = False
            if self.state in ('ready', 'completed'):
                self._apply_state('thinking')

        elif et == 'done':
            if self._is_replaying:
                return   # 과거 done 재생 시 세션 조기 제거 방지
            self._pending_tools = 0
            self._pending_tool_name = None
            self._wait_hint_shown = False
            if self._completion_job:
                self.win.after_cancel(self._completion_job)
            self._completion_job = self.win.after(
                self._completion_debounce_ms, self._show_completion_if_pending)
            # 자동 파일 삭제·세션 제거 없음 — 사용자가 숨기기 전까지 유지

        elif et == 'background':
            # Stop 훅은 왔지만 run_in_background로 띄운 작업이 아직 돌고 있는 경우 —
            # 완료가 아니라 "백그라운드 작업 중"으로 표시. 대기 중이던 완료 표시도 취소.
            if self._is_replaying:
                return
            self._pending_tools = 0
            if self._completion_job:
                self.win.after_cancel(self._completion_job)
                self._completion_job = None
            count = ev.get('count', 1)
            base  = ev.get('message') or t('백그라운드 작업', 'Background task')
            label = f'{base} 외 {count - 1}건' if count > 1 else base
            self._apply_state('backgroundWork', notif=f'⏳ {label}')

        elif et == 'ask_user':
            # 이미 답한 질문이 재시작 때 되살아나는 건 막되, 방금 온 질문은
            # 재생 중이라도 띄운다 — 완료 뒤 세션이 다시 감지될 때 첫 폴링이
            # 재생 모드라, 예전에는 그 질문이 통째로 무시됐다.
            is_stale = (time.time() - ev.get('ts', 0) > 30) if 'ts' in ev else True
            if self._is_replaying and is_stale:
                return
            self._ask_is_hint = False
            self._apply_state('ask_user', notif=(ev.get('message') or '').strip())

        elif et == 'notification':
            is_stale = (time.time() - ev.get('ts', 0) > 30) if 'ts' in ev else True
            if self._is_replaying and is_stale:
                return
            if self.state == 'ask_user':
                return   # 확인 요청 버블이 알림에 덮이지 않도록
            self._apply_state('notification', notif=ev.get('message', t('알림', 'Notification')))

        elif et == 'permission_request':
            is_stale = (time.time() - ev.get('ts', 0) > 30) if 'ts' in ev else True
            if self._is_replaying and is_stale:
                return
            pid = ev.get('id');  cmd = ev.get('message', t('명령', 'command'))
            if pid and self.always_approve:
                try:
                    (_TEMP / f'claude-companion-decision-{pid}').write_text('approve')
                except Exception:
                    pass
            elif pid:
                self._apply_state('permission', perm_cmd=cmd, perm_id=pid)

        elif et == 'usage':
            pct = ev.get('percent', 0)
            sts = ev.get('sessionStartTs', None)
            self.win.after(0, lambda p=pct, s=sts: self.set_usage(p, s))

    def _show_completion_if_pending(self):
        self._completion_job = None
        if not self._destroyed:
            # 같은 완료가 두 번 들어와도 코인은 한 번만
            if self.state != 'completed':
                self.shop.reward_completion()
            self._apply_state('completed')

    def _cleanup_event_file(self):
        """세션 이벤트 파일 삭제 → poll_events가 False를 반환해 세션 자동 제거."""
        if self._destroyed:
            return
        try:
            self.event_file.unlink(missing_ok=True)
        except Exception:
            pass

    @staticmethod
    def _fmt_tool(raw: str) -> str:
        # MCP 도구는 mcp__<서버>__<도구> 형태라 그대로 쓰면 말풍선이 지저분해진다
        if raw.startswith('mcp__'):
            parts = raw.split('__')
            tool  = ' '.join(parts[2:]) if len(parts) > 2 else raw
            return f"{tool.replace('_', ' ')} 실행 중"
        return {
            'bash':      t('터미널 명령 실행 중', 'Running command'),
            'read':      t('파일 읽는 중', 'Reading file'),
            'write':     t('파일 쓰는 중', 'Writing file'),
            'edit':      t('파일 수정 중', 'Editing file'),
            'multiedit': t('파일 수정 중', 'Editing file'),
            'glob':      t('파일 검색 중', 'Finding files'),
            'grep':      t('코드 검색 중', 'Searching code'),
            'ls':        t('폴더 탐색 중', 'Browsing folder'),
            'websearch': t('웹 검색 중', 'Searching the web'),
            'webfetch':  t('페이지 읽는 중', 'Reading page'),
            'todowrite': t('할 일 정리 중', 'Updating to-dos'),
            'todoread':  t('할 일 확인 중', 'Checking to-dos'),
        }.get(raw.lower(), f'{raw} 실행 중')

    # ── Visibility ────────────────────────────────────────────

    def hide(self):
        self.win.withdraw()
        # 팝업은 self.win의 자식 Toplevel일 뿐 부모를 따라 자동으로 숨지
        # 않으므로 직접 숨긴다 (안 그러면 캐릭터는 안 보이는데 말풍선만 뜸)
        for w in (self._perm_win, self._completion_win, self._ask_user_win, self._limit_win):
            if w and w.winfo_exists():
                w.withdraw()

    def show(self):
        self.win.deiconify()
        # 현재 상태에 맞는 팝업만 복원
        if self.state == 'permission' and self._perm_win and self._perm_win.winfo_exists():
            self._perm_win.deiconify()
        elif self.state == 'completed' and self._completion_win and self._completion_win.winfo_exists():
            self._completion_win.deiconify()
        elif self.state == 'ask_user' and self._ask_user_win and self._ask_user_win.winfo_exists():
            self._ask_user_win.deiconify()
        self._maybe_show_limit_popup()

    @property
    def is_visible(self) -> bool:
        try:
            return self.win.state() == 'normal'
        except Exception:
            return False

    # ── 무기 보여주기 (대기 중) ───────────────────────────────

    def _schedule_weapon_show(self):
        if self._destroyed:
            return
        # 몇 초마다 꺼낼지 고민한다 — 확률로 걸러서 평균 12초 안팎에 한 번 나온다
        self._weapon_job = self.win.after(4000, self._maybe_show_weapon)

    def _maybe_show_weapon(self):
        if self._destroyed:
            return
        self._schedule_weapon_show()
        weapon = self._equip('weapon')
        if (self.state != 'ready' or self.showing_weapon or not weapon or weapon == 'carrot'
                or not self.is_visible or random.randrange(3) != 0):
            return
        self._start_weapon_show()

    def _start_weapon_show(self):
        """① 오른팔을 들어 올리며 무기를 꺼낸다 → ② 천천히 좌우로 기울여 보여준다 →
        ③ 팔을 내리며 집어넣는다."""
        self._show_token += 1
        tok = self._show_token
        self.showing_weapon = True
        self.rarm_dy = -P * 1.6
        self._swing_target = 0.0
        self._draw()
        for i, angle in enumerate([-8, 14, -6, 12, -4, 0]):
            self.win.after(700 + 340 * i, lambda a=angle, k=tok: self._set_swing(a, k))
        self.win.after(3200, lambda k=tok: self._end_weapon_show(k))

    def _set_swing(self, angle: float, token: int):
        if token == self._show_token and self.showing_weapon:
            self._swing_target = angle

    def _end_weapon_show(self, token=None):
        if self._destroyed or (token is not None and token != self._show_token):
            return
        if not self.showing_weapon:
            return
        self.showing_weapon = False
        self.weapon_swing = self._swing_target = 0.0
        if not self.show_laptop and not self.show_reading:
            self.rarm_dy = 0.0
        self._draw()

    def _tick_anim(self):
        """시간에 따라 계속 바뀌는 아이템(무기 흔들림·뜨개질·후광)이 있을 때만 다시 그린다."""
        if self._destroyed:
            return
        try:
            if self._needs_anim() and self.is_visible:
                # 기울임은 목표 각도로 부드럽게 따라간다
                self.weapon_swing += (self._swing_target - self.weapon_swing) * 0.5
                self._draw()
        except Exception:
            pass
        self._anim_job = self.win.after(90, self._tick_anim)

    # ── Disconnect ────────────────────────────────────────────

    def _disconnect(self):
        """사용자가 이 세션을 수동으로 끊습니다.
        이벤트 파일을 삭제하고 매니저의 차단 목록에 세션 ID를 추가해
        같은 세션 파일이 다시 감지돼도 재생성되지 않도록 합니다.
        Claude를 새로 시작하면 새 session_id로 새 부니가 생성됩니다."""
        import tkinter.messagebox as mb
        if not mb.askyesno(
                t('세션 끊기', 'Disconnect session'),
                t('이 세션을 끊으시겠습니까?\n\n'
                  '창이 닫히며, 이 세션에 대한 알림은 더 이상 표시되지 않습니다.\n'
                  'Claude를 새로 시작하면 새 부니가 생성됩니다.',
                  'Disconnect this session?\n\n'
                  'The window closes and this session stops notifying you.\n'
                  'Starting Claude again creates a new Buni.'),
                parent=self.win):
            return
        self.manager.disconnect_session(self.session_id, self.event_file)

    # ── Cleanup ───────────────────────────────────────────────

    def destroy(self):
        if self._destroyed:
            return
        self._destroyed = True
        for job_attr in ('_laptop_job', '_reading_job', '_blink_job', '_idle_job',
                          '_title_job', '_limit_job', '_completion_job'):
            job = getattr(self, job_attr, None)
            if job:
                try: self.win.after_cancel(job)
                except Exception: pass
        if self._perm_win:
            try: self._perm_win.destroy()
            except Exception: pass
        if self._completion_win:
            try: self._completion_win.destroy()
            except Exception: pass
        if self._ask_user_win:
            try: self._ask_user_win.destroy()
            except Exception: pass
        if self._limit_win:
            try: self._limit_win.destroy()
            except Exception: pass
        try: self.win.destroy()
        except Exception: pass


# ══════════════════════════════════════════════════════════════
# 부니 상점 — 위에서 입혀보고, 아래에서 사고 입는다
# ══════════════════════════════════════════════════════════════

class ShopPreview(CharacterDrawMixin):
    """상점 미리보기 캐릭터 — 실제 세션과 무관하게 입어보는 모습을 그대로 보여준다."""

    SCALE = 1.9

    def __init__(self, cv: tk.Canvas, shop: 'buni_shop.ShopStore', cx: int, cy: int):
        self.cv, self.shop = cv, shop
        self.cx, self.cy = cx, cy
        self.character = 'rabbit'
        self.try_on: dict = {}
        self.state = 'ready'
        self.mode  = 'idle'
        self.body_dx = self.body_dy = 0.0
        self.larm_dx = self.larm_dy = self.rarm_dx = self.rarm_dy = 0.0
        self.show_laptop = self.show_reading = self.show_carrot = False
        self.doc_visible = True
        self.throw_dx = self.throw_dy = 0.0
        self.blinking = self.wide_eyes = False
        self.ear_scale = 1.0
        self.showing_weapon = False
        self.weapon_swing = 0.0

    def set_mode(self, mode: str):
        """idle(대기) / working(작업 중) / done(완료) — 무기·작업 도구가 보이는 모습을 고른다."""
        self.mode = mode
        self.show_laptop = self.show_carrot = False
        self.wide_eyes = False
        self.larm_dx = self.rarm_dx = 0.0
        self.larm_dy = self.rarm_dy = 0.0
        if mode == 'working':
            self.state = 'thinking'
            self.show_laptop = True
            self.larm_dx, self.rarm_dx = P * 1.55, -P * 1.55
            self.larm_dy = self.rarm_dy = P
        elif mode == 'done':
            self.state = 'completed'
            self.show_carrot = True
            self.wide_eyes = True
            self.larm_dy = -P * 2.8
        else:
            self.state = 'ready'

    def paint(self):
        """캔버스를 지우지 않고 이 캐릭터만 그린다 (한 캔버스에 여럿을 그릴 때)."""
        if self.mode == 'working':               # 팔이 번갈아 위아래 — 뜨개질 바늘이 손을 따라 움직인다
            swing = P * 0.6 if int(time.time() / 0.36) % 2 else -P * 0.6
            self.larm_dy, self.rarm_dy = P - swing, P + swing
        self._draw_character()

    def redraw(self):
        self.cv.delete('all')
        self.paint()
        self.cv.scale('all', self.cx, self.cy, self.SCALE, self.SCALE)


class ShopWindow:
    """부니 상점 창."""

    WEAR  = '#4DC780'     # 착용 중 — 초록
    TRY   = '#599EFA'     # 입어보는 중 — 파랑 (착용 중과 구분)
    BG    = '#1E1E24'
    CARD  = '#2A2A33'
    DIM   = '#7A7A88'
    GOLD  = '#F2CC25'
    COIN  = '#FAD238'
    ACCENT = '#3377E0'
    BUY   = '#F29926'
    OFF   = '#DB4D4D'

    MODE_FOR_SLOT = {'weapon': 'done', 'tool': 'working'}

    def __init__(self, manager: 'BuniManager', character: str):
        self.manager = manager
        self.shop    = manager.shop
        self.target  = character if character in CHARACTERS else 'rabbit'
        self.slot    = 'head'
        self.try_on: dict = {}
        self._job    = None

        win = self.win = tk.Toplevel(manager.root)
        win.title(t('부니 상점', 'Buni Shop'))
        win.configure(bg=self.BG)
        win.geometry('480x740')
        win.minsize(440, 620)
        win.attributes('-topmost', True)
        win.protocol('WM_DELETE_WINDOW', self.close)
        win.bind('<Escape>', lambda _: self.close())

        self._font   = ('Malgun Gothic', 10)
        self._fontb  = ('Malgun Gothic', 10, 'bold')

        # ── 머리말: 제목 · 클라우드 · 코인 · 레벨
        head = tk.Frame(win, bg=self.BG)
        head.pack(fill='x', padx=18, pady=(14, 6))
        tk.Label(head, text=t('부니 상점', 'Buni Shop'), bg=self.BG, fg='white',
                 font=('Malgun Gothic', 14, 'bold')).pack(side='left')
        self._lv = tk.Label(head, bg=self.BG, fg=self.GOLD, font=('Consolas', 11, 'bold'))
        self._lv.pack(side='right')
        self._coins = tk.Label(head, bg=self.BG, fg='#FAE080', font=('Consolas', 12, 'bold'))
        self._coins.pack(side='right', padx=(0, 12))
        self._cloud_box = tk.Frame(head, bg=self.BG)
        self._cloud_box.pack(side='right', padx=(0, 12))

        # ── 캐릭터 선택
        self._char_btns = {}
        picker = tk.Frame(win, bg=self.BG)
        picker.pack(fill='x', padx=18, pady=(0, 8))
        for i, cid in enumerate(CHARACTERS):
            b = tk.Button(picker, text=self._short_name(cid), relief='flat', cursor='hand2',
                          font=('Malgun Gothic', 9, 'bold'), bd=0, pady=5,
                          command=lambda c=cid: self._set_target(c))
            b.grid(row=0, column=i, sticky='ew', padx=(0 if i == 0 else 4, 0))
            picker.grid_columnconfigure(i, weight=1, uniform='ch')
            self._char_btns[cid] = b

        # ── 미리보기
        pv = tk.Frame(win, bg=self.CARD)
        pv.pack(fill='x', padx=18, pady=(0, 8))
        self._cv = tk.Canvas(pv, width=444, height=180, bg=self.CARD, highlightthickness=0)
        self._cv.pack()
        self.preview = ShopPreview(self._cv, self.shop, 222, 96)
        self._mode_btns = {}
        modes = tk.Frame(pv, bg=self.CARD)
        modes.place(relx=1.0, rely=1.0, x=-8, y=-8, anchor='se')
        for i, (m, ko, en) in enumerate((('idle', '대기', 'Idle'), ('working', '작업 중', 'Working'),
                                         ('done', '완료', 'Done'))):
            b = tk.Button(modes, text=t(ko, en), relief='flat', cursor='hand2', bd=0,
                          font=('Malgun Gothic', 8), padx=7, pady=2,
                          command=lambda mm=m: self._set_mode(mm))
            b.grid(row=0, column=i, padx=(0 if i == 0 else 2, 0))
            self._mode_btns[m] = b

        # ── 지금 입은 것
        self._summary = tk.Frame(win, bg=self.BG)
        self._summary.pack(fill='x', padx=20, pady=(0, 6))
        self._sum_tag = tk.Label(self._summary, bg=self.BG, font=('Malgun Gothic', 9, 'bold'))
        self._sum_tag.pack(side='left')
        self._sum_txt = tk.Label(self._summary, bg=self.BG, font=('Malgun Gothic', 9),
                                 justify='left', anchor='w', wraplength=300)
        self._sum_txt.pack(side='left', padx=(6, 0))
        self._sum_reset = tk.Button(self._summary, text=t('원래대로', 'Reset'), relief='flat', bd=0,
                                    bg='#555566', fg='white', cursor='hand2',
                                    font=('Malgun Gothic', 8), padx=8, pady=1,
                                    command=self._reset_try)

        tk.Frame(win, bg='#3A3A44', height=1).pack(fill='x', padx=16)

        # ── 자리 선택
        self._slot_btns = {}
        tabs = tk.Frame(win, bg=self.BG)
        tabs.pack(fill='x', padx=18, pady=(10, 8))
        for i, sl in enumerate(buni_shop.SLOTS):
            b = tk.Button(tabs, text=t(*buni_shop.SLOT_TITLES[sl]), relief='flat', cursor='hand2',
                          font=('Malgun Gothic', 9, 'bold'), bd=0, pady=5,
                          command=lambda s=sl: self._set_slot(s))
            b.grid(row=0, column=i, sticky='ew', padx=(0 if i == 0 else 3, 0))
            tabs.grid_columnconfigure(i, weight=1, uniform='sl')
            self._slot_btns[sl] = b

        # ── 목록 (스크롤)
        holder = tk.Frame(win, bg=self.BG)
        holder.pack(fill='both', expand=True, padx=(18, 4), pady=(0, 14))
        self._list_cv = tk.Canvas(holder, bg=self.BG, highlightthickness=0)
        sb = tk.Scrollbar(holder, orient='vertical', command=self._list_cv.yview)
        self._list_cv.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y')
        self._list_cv.pack(side='left', fill='both', expand=True)
        self._list = tk.Frame(self._list_cv, bg=self.BG)
        self._list_id = self._list_cv.create_window((0, 0), window=self._list, anchor='nw')
        self._list.bind('<Configure>', lambda e: self._list_cv.configure(
            scrollregion=self._list_cv.bbox('all')))
        self._list_cv.bind('<Configure>', lambda e: self._list_cv.itemconfigure(self._list_id, width=e.width))
        win.bind('<MouseWheel>', lambda e: self._list_cv.yview_scroll(-int(e.delta / 120), 'units'))

        win.update_idletasks()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f'+{(sw - 480) // 2}+{max(20, (sh - 740) // 2 - 20)}')

        self._apply_target()
        self.preview.set_mode(self.MODE_FOR_SLOT.get(self.slot, 'idle'))
        self.refresh()
        self._tick()

    # ── 창 ───────────────────────────────────────────────────

    def is_open(self) -> bool:
        try:
            return bool(self.win.winfo_exists())
        except Exception:
            return False

    def show(self, character=None):
        if character and character in CHARACTERS and character != self.target:
            self._set_target(character)
        self.win.deiconify(); self.win.lift(); self.win.focus_force()

    def close(self):
        if self._job:
            try: self.win.after_cancel(self._job)
            except Exception: pass
        try: self.win.destroy()
        except Exception: pass

    def _tick(self):
        if not self.is_open():
            return
        self.preview.try_on = self._displayed()
        self.preview.redraw()
        self._job = self.win.after(100, self._tick)

    # ── 상태 ─────────────────────────────────────────────────

    @staticmethod
    def _short_name(cid: str) -> str:
        return char_display_name(cid).split(' ')[0]

    def _displayed(self) -> dict:
        """미리보기에 실제로 보여줄 아이템 — 입어보는 것이 실제 착용보다 우선한다."""
        shown = {}
        for sl in buni_shop.SLOTS:
            iid = self.try_on.get(sl) or self.shop.equipped_id(sl, self.target)
            if iid:
                shown[sl] = iid
        return shown

    def _apply_target(self):
        self.preview.character = self.target

    def _set_target(self, cid: str):
        self.target = cid
        self.try_on = {}          # 입어보던 것은 그 캐릭터의 미리보기였다
        self._apply_target()
        self.refresh()

    def _set_mode(self, mode: str):
        self.preview.set_mode(mode)
        self._refresh_modes()

    def _set_slot(self, slot: str):
        self.slot = slot
        # 탭을 넘기면 그 자리에 어울리는 모션으로 — 무기는 완료, 작업 도구는 작업 중
        self.preview.set_mode(self.MODE_FOR_SLOT.get(slot, 'idle'))
        self.refresh()

    def _try_on_item(self, it):
        if self.try_on.get(it.slot) == it.id:
            self.try_on.pop(it.slot, None)
        else:
            self.try_on[it.slot] = it.id
        self.preview.set_mode(self.MODE_FOR_SLOT.get(it.slot, 'idle'))
        self.refresh()

    def _settle(self, it):
        """착용·해제·구매로 실제 상태가 바뀌었을 때 — 입어보기를 거두고 그 모습을 바로 보여준다."""
        self.try_on.pop(it.slot, None)
        self.preview.set_mode(self.MODE_FOR_SLOT.get(it.slot, 'idle'))
        self.refresh()

    def _reset_try(self):
        self.try_on = {}
        self.refresh()

    # ── 그리기 ───────────────────────────────────────────────

    def refresh(self):
        """상태가 바뀔 때마다(코인·레벨·구매·착용·로그인) 화면 전체를 맞춘다."""
        if not self.is_open():
            return
        self._coins.config(text=f'🪙 {self.shop.coins}')
        self._lv.config(text=f'★ Lv.{self.shop.level}')
        self._refresh_cloud()
        for cid, b in self._char_btns.items():
            on = cid == self.target
            b.config(bg=self.ACCENT if on else '#2F2F3A', fg='white' if on else '#AAAAB4',
                     activebackground=self.ACCENT if on else '#3A3A48', activeforeground='white')
        for sl, b in self._slot_btns.items():
            on = sl == self.slot
            b.config(bg=self.ACCENT if on else '#2F2F3A', fg='white' if on else '#AAAAB4',
                     activebackground=self.ACCENT if on else '#3A3A48', activeforeground='white')
        self._refresh_modes()
        self._refresh_summary()
        self._refresh_list()

    def _refresh_modes(self):
        for m, b in self._mode_btns.items():
            on = m == self.preview.mode
            b.config(bg=self.ACCENT if on else '#3A3A48', fg='white' if on else '#BBBBC4',
                     activebackground=self.ACCENT, activeforeground='white')

    def _refresh_cloud(self):
        for w in self._cloud_box.winfo_children():
            w.destroy()
        cloud = self.manager.cloud
        if not cloud.is_configured:
            return
        if cloud.is_signed_in:
            tk.Label(self._cloud_box, text=t('☁ 연동됨', '☁ Synced'), bg=self.BG, fg=self.WEAR,
                     font=('Malgun Gothic', 9, 'bold')).pack()
        else:
            tk.Button(self._cloud_box, text=t('☁ 다른 PC와 연동', '☁ Sync'), relief='flat', bd=0,
                      bg='#555566', fg='white', cursor='hand2', font=('Malgun Gothic', 8),
                      padx=8, pady=2, command=self.manager.cloud_sign_in_ui).pack()

    def _refresh_summary(self):
        shown = self._displayed()
        parts = []
        for sl in buni_shop.SLOTS:
            iid = shown.get(sl)
            it = buni_shop.item(iid) if iid else None
            if not it or (self.shop.is_default(it) and sl not in self.try_on):
                continue
            name = t(it.name_ko, it.name_en)
            parts.append(name + t(' (미리보기)', ' (preview)') if self.try_on.get(sl) == iid else name)
        trying = bool(self.try_on)
        self._sum_tag.config(text=t('미리보기', 'Preview') if trying else t('착용 중', 'Wearing'),
                             fg=self.TRY if trying else self.WEAR)
        self._sum_txt.config(text='  ·  '.join(parts) if parts else t('없음 — 기본 모습', 'Nothing — default look'),
                             fg='#DDDDE4' if parts else '#666672')
        if trying:
            self._sum_reset.pack(side='right')
        else:
            self._sum_reset.pack_forget()

    def _refresh_list(self):
        for w in self._list.winfo_children():
            w.destroy()
        for it in buni_shop.items_in(self.slot):
            self._row(it)
        note = {'tool': t('작업 도구는 생각하거나 도구를 쓰는 동안 노트북 대신 사용합니다. 팔 동작은 그대로예요.',
                          'Work tools replace the laptop while Claude is working.'),
                'weapon': t('무기는 생각하거나 도구를 쓰는 작업 중에만 손에 듭니다.',
                            'Weapons are only drawn while Claude is working.')}.get(self.slot)
        if note:
            tk.Label(self._list, text=note, bg=self.BG, fg='#5C5C6A', font=('Malgun Gothic', 8),
                     wraplength=380, justify='left').pack(anchor='w', pady=(4, 8))

    def _row(self, it):
        shop = self.shop
        owned, equipped = shop.is_owned(it), shop.is_equipped(it, self.target)
        unlocked = shop.is_unlocked(it)
        trying = self.try_on.get(it.slot) == it.id

        edge = self.WEAR if equipped else (self.TRY if trying else self.CARD)
        card = tk.Frame(self._list, bg=self.CARD, highlightthickness=2, highlightbackground=edge,
                        highlightcolor=edge, cursor='hand2')
        card.pack(fill='x', pady=4, padx=(0, 10))
        if equipped:                                         # 왼쪽 굵은 띠 — 입은 항목이 바로 보이게
            tk.Frame(card, bg=self.WEAR, width=5).pack(side='left', fill='y')
        if equipped:
            card.config(bg='#23382E')
        body = tk.Frame(card, bg=card['bg'])
        body.pack(side='left', fill='x', expand=True, padx=12, pady=10)

        top = tk.Frame(body, bg=card['bg'])
        top.pack(anchor='w')
        tk.Label(top, text=t(it.name_ko, it.name_en), bg=card['bg'],
                 fg='white' if unlocked else '#6A6A76', font=self._fontb).pack(side='left')
        if trying:
            tk.Label(top, text=t('👀 미리보기 중', '👀 Previewing'), bg=self.TRY, fg='white',
                     font=('Malgun Gothic', 8, 'bold'), padx=6).pack(side='left', padx=(8, 0))
        if equipped:
            tk.Label(top, text=(t('✓ 사용 중', '✓ In use') if shop.is_default(it) else t('✓ 착용 중', '✓ Equipped')),
                     bg=self.WEAR, fg='#10261A', font=('Malgun Gothic', 8, 'bold'),
                     padx=6).pack(side='left', padx=(8, 0))
        info = tk.Frame(body, bg=card['bg'])
        info.pack(anchor='w', pady=(3, 0))
        tk.Label(info, text=f'Lv.{it.level}', bg=card['bg'],
                 fg=self.GOLD if unlocked else '#E6665A', font=('Consolas', 9)).pack(side='left')
        if not owned:
            tk.Label(info, text=f'🪙 {it.price}', bg=card['bg'], fg=self.COIN,
                     font=('Consolas', 9, 'bold')).pack(side='left', padx=(10, 0))

        # 오른쪽: 동작 버튼
        acts = tk.Frame(card, bg=card['bg'])
        acts.pack(side='right', padx=10)

        def pill(parent, text, color, cmd):
            return tk.Button(parent, text=text, bg=color, fg='white', relief='flat', bd=0, cursor='hand2',
                             font=('Malgun Gothic', 9, 'bold'), padx=10, pady=3,
                             activebackground=color, activeforeground='white', command=cmd)

        if shop.is_default(it) and equipped:
            pass                                             # 기본 아이템을 쓰는 중 — 배지가 대신 알려준다
        elif owned:
            label = (t('해제', 'Take off') if equipped
                     else (t('사용', 'Use') if shop.is_default(it) else t('착용', 'Equip')))
            # 해제는 빨강, 착용은 파랑 — 색만 봐도 누르면 어떻게 되는지 구분된다
            pill(acts, label, self.OFF if equipped else self.ACCENT,
                 lambda i=it: (shop.toggle_equip(i, self.target), self._settle(i))).pack()
        else:
            if not unlocked:
                tk.Label(acts, text=t(f'Lv.{it.level} 필요', f'Needs Lv.{it.level}'), bg=card['bg'],
                         fg='#6A6A76', font=('Malgun Gothic', 8)).pack(side='left', padx=(0, 6))
            elif shop.coins < it.price:
                tk.Label(acts, text=t('코인 부족', 'Not enough'), bg=card['bg'],
                         fg='#6A6A76', font=('Malgun Gothic', 8)).pack(side='left', padx=(0, 6))
            # 아직 내 것이 아닌 아이템 — 레벨·코인이 모자라도 입어볼 수는 있다
            pill(acts, t('취소', 'Cancel') if trying else t('입어보기', 'Try on'), self.TRY,
                 lambda i=it: self._try_on_item(i)).pack(side='left')
            if unlocked and shop.coins >= it.price:
                pill(acts, t('구매', 'Buy'), self.BUY,
                     lambda i=it: (shop.buy(i, self.target), self._settle(i))).pack(side='left', padx=(6, 0))

        # 행을 누르면 사기 전에 미리 입어본다
        def bind_all(w):
            if not isinstance(w, tk.Button):
                w.bind('<Button-1>', lambda e, i=it: self._try_on_item(i))
            for c in w.winfo_children():
                bind_all(c)
        bind_all(card)


# ══════════════════════════════════════════════════════════════
# 부니 채팅 — 방 안의 채팅 부니들 + 로비 창
# ══════════════════════════════════════════════════════════════

class ChatAvatar(ShopPreview):
    """채팅방에 있는 사람 한 명의 부니. 모션(대기/작업 중/완료)은 서버에서 받은 값으로,
    옷차림은 받은 아이템 id로 그린다(상점 미리보기와 같은 방식)."""

    SCALE = 1.0

    def __init__(self, cv: tk.Canvas, shop, cx: int, cy: int):
        super().__init__(cv, shop, cx, cy)
        self.uid = ''
        self._blink_left = 0

    def apply(self, member: dict):
        self.uid = member['uid']
        self.character = member['char'] if member['char'] in CHARACTERS else 'rabbit'
        self.try_on = dict(member['equip'])
        mode = {'working': 'working', 'done': 'done'}.get(member['motion'], 'idle')
        if mode != self.mode:
            self.set_mode(mode)

    def tick_blink(self):
        if self._blink_left > 0:
            self._blink_left -= 1
            self.blinking = self._blink_left > 0
        elif random.random() < 0.025:
            self._blink_left = 2
            self.blinking = True


class ChatWindow:
    """방 안에서 화면 아래쪽에 뜨는 채팅 패널 — 사람마다 부니 한 마리, 머리 위에 말풍선."""

    COL      = 108          # 사람 한 명이 차지하는 가로 폭
    BUBBLE_H = 100          # 말풍선 영역 높이
    AV_CY    = 142          # 캐릭터 중심 y
    H        = 236
    BUBBLE_SECONDS = 9
    INPUT_IDLE_SECONDS = 6
    NAME_DY  = 38           # 캐릭터 중심에서 이름표까지

    def __init__(self, manager: 'BuniManager'):
        self.manager = manager
        self.chat    = manager.chat
        self.shop    = manager.shop
        self.avatars: dict[str, ChatAvatar] = {}
        self._input: tk.Toplevel | None = None
        self._entry: tk.Entry | None = None
        self._draft = ''                   # 쓰다 만 메시지 — 입력창이 닫혀도 남는다
        self._input_touched = 0.0
        self._job = None
        self._width = 0
        self._press = None
        self._moved = False

        win = self.win = tk.Toplevel(manager.root)
        win.overrideredirect(True)
        win.attributes('-topmost', True)
        win.configure(bg=TRANSP)
        try:
            win.wm_attributes('-transparentcolor', TRANSP)
        except tk.TclError:
            pass
        self.cv = tk.Canvas(win, width=300, height=self.H, bg=TRANSP, highlightthickness=0)
        self.cv.pack()
        self.cv.bind('<ButtonPress-1>',   self._press_cb)
        self.cv.bind('<B1-Motion>',       self._motion_cb)
        self.cv.bind('<ButtonRelease-1>', self._release_cb)
        self._place(first=True)
        self._tick()

    # ── 위치 · 크기 ──────────────────────────────────────────

    def _size(self) -> int:
        return max(300, max(1, len(self.chat.members)) * self.COL + 20)

    def _place(self, first=False):
        w = self._size()
        if w != self._width or first:
            old_w = self._width or w
            self.win.update_idletasks()
            x, y = self.win.winfo_x(), self.win.winfo_y()
            self._width = w
            self.cv.config(width=w)
            if first:
                saved = self.manager.persist.get('chat.window_pos')
                sw, sh = self.win.winfo_screenwidth(), self.win.winfo_screenheight()
                x, y = (saved if saved else [(sw - w) // 2, sh - self.H - 56])
            else:
                x += (old_w - w) // 2          # 가운데를 기준으로 좌우로 늘고 줄게
            sw, sh = self.win.winfo_screenwidth(), self.win.winfo_screenheight()
            x = max(0, min(x, sw - w)); y = max(0, min(y, sh - self.H))
            self.win.geometry(f'{w}x{self.H}+{x}+{y}')

    def close(self):
        if self._job:
            try: self.win.after_cancel(self._job)
            except Exception: pass
        self.close_input()
        try: self.win.destroy()
        except Exception: pass

    def is_open(self) -> bool:
        try:
            return bool(self.win.winfo_exists())
        except Exception:
            return False

    # ── 그리기 ───────────────────────────────────────────────

    def _tick(self):
        if not self.is_open():
            return
        try:
            self._place()
            self.chat.sync_profile()
            self.redraw()
            if self._input and self._input.winfo_exists():
                if time.time() - self._input_touched > self.INPUT_IDLE_SECONDS:
                    self.close_input()                   # 한동안 입력이 없으면 다시 닉네임을 보인다
                else:
                    self._place_input()
        except Exception:
            pass
        self._job = self.win.after(100, self._tick)

    def redraw(self):
        chat, cv = self.chat, self.cv
        cv.delete('all')
        members = chat.members
        now = time.time()
        for i, m in enumerate(members):
            if m['uid'] == chat.my_uid:
                m = chat._local_member(m)              # 내 칸은 바로바로 반영
            cx = 10 + self.COL * i + self.COL // 2
            av = self.avatars.get(m['uid'])
            if av is None:
                av = self.avatars[m['uid']] = ChatAvatar(cv, self.shop, cx, self.AV_CY)
            av.cx, av.cy = cx, self.AV_CY
            av.apply(m)
            av.tick_blink()
            av.paint()
            me = m['uid'] == chat.my_uid
            if not (me and self._input and self._input.winfo_exists()):    # 입력창이 열려 있으면 그 자리가 입력창
                self._name_tag(cx, m['name'], me=me, level=m.get('level', 1))
            # 새 메시지가 있으면 머리 위에 말풍선
            last = next((x for x in reversed(chat.messages) if x['uid'] == m['uid']), None)
            if last and now - chat.received_at.get(last['id'], 0.0) < self.BUBBLE_SECONDS:
                self._bubble(cx, last['text'])
        for uid in [u for u in self.avatars if u not in {m['uid'] for m in members}]:
            del self.avatars[uid]
        self._controls()

    def _name_tag(self, cx, name, me, level=1):
        y = self.AV_CY + self.NAME_DY
        lv = self.cv.create_text(0, y, text=f'Lv.{level}', font=('Malgun Gothic', 7, 'bold'), fill='#FFD966', anchor='w')
        tid = self.cv.create_text(0, y, text=name, font=('Malgun Gothic', 8, 'bold'), fill='white', anchor='w')
        lw = self.cv.bbox(lv)[2] - self.cv.bbox(lv)[0]
        nw = self.cv.bbox(tid)[2] - self.cv.bbox(tid)[0]
        left = cx - (lw + 4 + nw) / 2
        self.cv.coords(lv, left, y)
        self.cv.coords(tid, left + lw + 4, y)
        x0, y0, x1, y1 = self.cv.bbox(lv, tid)
        pill = self.cv.create_polygon(
            [x0-6, y0, x1+6, y0, x1+8, y0+2, x1+8, y1-2, x1+6, y1, x0-6, y1, x0-8, y1-2, x0-8, y0+2],
            smooth=True, fill='#3377E0' if me else '#2E2E36', outline='')
        self.cv.tag_lower(pill, tid)

    def _bubble(self, cx, text):
        # 글자 수만큼만 감싼다 — 줄임표 없이 전부 보이고, 짧으면 말풍선도 짧아진다
        tid = self.cv.create_text(cx, 0, text=text, width=90, justify='center',
                                  font=('Malgun Gothic', 8), fill='#222222', anchor='s')
        x0, y0, x1, y1 = self.cv.bbox(tid)
        # 말풍선은 캐릭터 귀 위쪽(영역 아래 끝)에 붙인다
        bottom = self.BUBBLE_H - 6
        self.cv.move(tid, 0, bottom - 6 - y1 + 0)
        x0, y0, x1, y1 = self.cv.bbox(tid)
        pad = 6
        L, T, R, B = x0 - pad, y0 - pad, x1 + pad, y1 + pad
        r = 8
        pts = [L+r, T, R-r, T, R, T, R, T+r, R, B-r, R, B, R-r, B, L+r, B, L, B, L, B-r, L, T+r, L, T]
        poly = self.cv.create_polygon(pts, smooth=True, fill='#FFFFFF', outline='#CCCCCC')
        tail = self.cv.create_polygon(cx-5, B-1, cx+5, B-1, cx, B+6, fill='#FFFFFF', outline='')
        self.cv.tag_lower(tail, tid); self.cv.tag_lower(poly, tid)

    def _controls(self):
        chat = self.chat
        y = self.H - 14
        labels = [('talk', '💬 ' + t('말하기', 'Chat')),
                  ('code', f'🏠 {chat.room_code} · {len(chat.members)}/{buni_chat.MAX_MEMBERS}'),
                  ('leave', t('나가기', 'Leave'))]
        if chat.status == 'reconnecting':
            labels.insert(2, ('retry', t('다시 연결 중…', 'Reconnecting…')))
        items = []
        total = 0
        for tag, text in labels:
            tid = self.cv.create_text(0, y, text=text, font=('Malgun Gothic', 8, 'bold'), fill='white', tags=('ctl', tag))
            bb = self.cv.bbox(tid)
            items.append((tag, tid, bb[2] - bb[0]))
            total += bb[2] - bb[0] + 14
        x = (self._width - total) // 2 + 7
        pill_l = x - 8
        for tag, tid, w in items:
            self.cv.coords(tid, x + w / 2, y)
            self.cv.tag_bind(tid, '<Enter>', lambda e, i=tid: self.cv.itemconfig(i, fill='#FFDD66'))
            self.cv.tag_bind(tid, '<Leave>', lambda e, i=tid: self.cv.itemconfig(i, fill='white'))
            x += w + 14
        pill = self.cv.create_polygon(
            [pill_l+8, y-9, x-6, y-9, x+2, y-9, x+2, y+9, x-6, y+9, pill_l+8, y+9, pill_l, y+9, pill_l, y-9],
            smooth=True, fill='#26262E', outline='')
        self.cv.tag_lower(pill)
        self._ctl = {tag: tid for tag, tid, _ in items}

    # ── 마우스: 끌어서 옮기기 · 누르기 ───────────────────────

    def _press_cb(self, e):
        self._press = (e.x_root, e.y_root, self.win.winfo_x(), self.win.winfo_y(), e.x, e.y)
        self._moved = False

    def _motion_cb(self, e):
        if not self._press:
            return
        sx, sy, wx, wy, *_ = self._press
        if abs(e.x_root - sx) > 4 or abs(e.y_root - sy) > 4:
            self._moved = True
        if self._moved:
            self.win.geometry(f'+{wx + e.x_root - sx}+{wy + e.y_root - sy}')

    def _release_cb(self, e):
        press, self._press = self._press, None
        if not press:
            return
        if self._moved:
            self.manager.persist.set('chat.window_pos', [self.win.winfo_x(), self.win.winfo_y()])
            return
        item = self.cv.find_closest(e.x, e.y)
        tags = self.cv.gettags(item) if item else ()
        if 'talk' in tags:
            self.toggle_input()
        elif 'code' in tags:
            self.manager.root.clipboard_clear()
            self.manager.root.clipboard_append(self.chat.room_code or '')
        elif 'leave' in tags:
            threading.Thread(target=self.chat.leave, daemon=True).start()
        else:
            # 캐릭터를 눌렀다 — 내 부니면 말하기, 남의 부니는 간지럽히기
            idx = (e.x - 10) // self.COL
            if 0 <= idx < len(self.chat.members) and self.AV_CY + 28 <= e.y <= self.AV_CY + 50:
                if self.chat.members[idx]['uid'] == self.chat.my_uid:
                    self.edit_nickname()               # 내 이름표를 누르면 닉네임 바꾸기
            elif 0 <= idx < len(self.chat.members) and 100 <= e.y <= 170:
                m = self.chat.members[idx]
                if m['uid'] == self.chat.my_uid:
                    self.toggle_input()
                else:
                    av = self.avatars.get(m['uid'])
                    if av:
                        av._blink_left = 6; av.blinking = True

    def edit_nickname(self):
        result = simpledialog.askstring(
            t('닉네임', 'Nickname'),
            t(f'채팅에 쓸 이름 ({buni_chat.MAX_NICKNAME}자까지)', f'Name shown in chat (up to {buni_chat.MAX_NICKNAME} characters)'),
            initialvalue=self.chat.display_name, parent=self.win)
        if result is None:                                   # 취소
            return
        name = result.strip()[:buni_chat.MAX_NICKNAME]       # 비우면 캐릭터 이름으로 돌아간다
        if name != self.chat.display_name:
            self.chat.nickname = name
            self.chat.push_profile()

    # ── 입력창 ───────────────────────────────────────────────

    def toggle_input(self):
        if self._input and self._input.winfo_exists():
            self.close_input()
        else:
            self.open_input()

    def open_input(self):
        """내 닉네임 자리에 작은 입력칸이 겹쳐 뜬다 — 캐릭터는 그대로, 입력이 없으면 닉네임으로 돌아온다."""
        if self._input and self._input.winfo_exists():
            self._input.lift(); self._entry.focus_force(); return
        w = self._input = tk.Toplevel(self.manager.root)
        w.overrideredirect(True)
        w.attributes('-topmost', True)
        w.configure(bg='#3377E0')                          # 파란 테두리 — 입력칸이라는 걸 알아보게
        inner = tk.Frame(w, bg='#17171C')
        inner.pack(padx=2, pady=2)
        tk.Label(inner, text='💬', bg='#17171C', fg='#6FA3FF', font=('Segoe UI Emoji', 8)).pack(side='left', padx=(5, 0))
        self._text_var = tk.StringVar(value=self._draft)
        self._entry = tk.Entry(inner, textvariable=self._text_var, width=12, font=('Malgun Gothic', 9),
                               relief='flat', bd=0, bg='#17171C', fg='white', insertbackground='#6FA3FF')
        self._entry.pack(side='left', padx=(3, 0), ipady=3)
        self._hint = tk.Label(inner, text='↵', bg='#17171C', fg='#6A6A78', font=('Consolas', 9, 'bold'), width=2)
        self._hint.pack(side='left', padx=(0, 3))
        self._text_var.trace_add('write', self._on_text)
        self._entry.bind('<Return>', lambda e: self._send())
        self._entry.bind('<Escape>', lambda e: self.close_input())
        self._input_touched = time.time()
        self._place_input()
        self._entry.focus_force()
        self._entry.icursor('end')

    def _place_input(self):
        w = self._input
        if not w:
            return
        me = next((i for i, m in enumerate(self.chat.members) if m['uid'] == self.chat.my_uid), None)
        if me is None:
            return
        w.update_idletasks()
        cx = 10 + self.COL * me + self.COL // 2
        x = self.win.winfo_x() + cx - w.winfo_reqwidth() // 2
        y = self.win.winfo_y() + self.AV_CY + self.NAME_DY - w.winfo_reqheight() // 2
        w.geometry(f'+{max(0, x)}+{max(0, y)}')

    def _on_text(self, *_):
        """글자 수 제한 — 넘치는 만큼은 입력되지 않는다."""
        self._input_touched = time.time()
        v = self._text_var.get()
        if len(v) > buni_chat.MAX_TEXT:
            self._text_var.set(v[:buni_chat.MAX_TEXT])
            return
        n = len(v)                                    # 비었으면 ↵ 안내, 40자부터는 글자 수
        self._hint.config(text=f'{n}/{buni_chat.MAX_TEXT}' if n >= 40 else ('↵' if n == 0 else ''),
                          width=6 if n >= 40 else 2)

    def close_input(self):
        if self._input:
            try: self._draft = self._text_var.get()
            except Exception: pass
            try: self._input.destroy()
            except Exception: pass
        self._input = self._entry = None

    def _send(self):
        if not self._entry:
            return
        text = self._entry.get()
        self._entry.delete(0, 'end')
        self._draft = ''
        self._input_touched = time.time()
        self.chat.send(text)


class ChatLobbyWindow:
    """방 만들기 · 코드로 입장 · 내 채팅 프로필."""

    BG = '#1E1E24'

    def __init__(self, manager: 'BuniManager'):
        self.manager = manager
        self.chat    = manager.chat
        self._sig    = None
        win = self.win = tk.Toplevel(manager.root)
        win.title(t('부니 채팅', 'Buni Chat'))
        win.configure(bg=self.BG)
        win.resizable(False, False)
        win.attributes('-topmost', True)
        win.protocol('WM_DELETE_WINDOW', self.close)
        win.bind('<Escape>', lambda _: self.close())
        self.body = tk.Frame(win, bg=self.BG, padx=20, pady=16)
        self.body.pack(fill='both', expand=True)
        self.refresh(force=True)
        win.update_idletasks()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f'+{(sw - win.winfo_reqwidth()) // 2}+{(sh - win.winfo_reqheight()) // 3}')

    def is_open(self) -> bool:
        try:
            return bool(self.win.winfo_exists())
        except Exception:
            return False

    def show(self):
        self.win.deiconify(); self.win.lift(); self.win.focus_force()

    def close(self):
        try: self.win.destroy()
        except Exception: pass

    def _signature(self):
        c = self.chat
        return (c.is_available, c.cloud.is_signed_in, c.room_code, c.last_error, c.status,
                tuple((m['uid'], m['name'], m['motion']) for m in c.members), c.cloud.busy)

    def refresh(self, force=False):
        """방·접속자·로그인 상태가 바뀔 때만 다시 그린다 (메시지가 올 때마다 그리면 입력 중인 칸이 풀린다)."""
        if not self.is_open():
            return
        sig = self._signature()
        if sig == self._sig and not force:
            return
        self._sig = sig
        for w in self.body.winfo_children():
            w.destroy()
        c, B = self.chat, self.BG
        tk.Label(self.body, text=t('부니 채팅', 'Buni Chat'), bg=B, fg='white',
                 font=('Malgun Gothic', 13, 'bold')).pack(anchor='w')

        def note(text, fg='#8A8A98'):
            tk.Label(self.body, text=text, bg=B, fg=fg, font=('Malgun Gothic', 8), justify='left',
                     wraplength=360, anchor='w').pack(anchor='w', pady=(6, 0))

        def button(parent, text, color, cmd, **kw):
            return tk.Button(parent, text=text, bg=color, fg='white', relief='flat', bd=0, cursor='hand2',
                             font=('Malgun Gothic', 9, 'bold'), padx=12, pady=4,
                             activebackground=color, activeforeground='white', command=cmd, **kw)

        if not c.is_available:
            note(t('서버 설정(cloud-config.json)이 없어서 채팅을 쓸 수 없어요.',
                   'Chat needs the server config (cloud-config.json).'), '#D9B25A')
        elif not c.cloud.is_signed_in:
            note(t('채팅은 Google 로그인이 필요해요. 로그인하면 같은 방 사람들과 이름이 보여요.',
                   'Chat needs a Google sign-in so people in the room can tell you apart.'))
            button(self.body, t('Google로 로그인', 'Sign in with Google'), '#3377E0',
                   self.manager.cloud_sign_in_ui,
                   state='disabled' if c.cloud.busy else 'normal').pack(anchor='w', pady=(10, 0))
        else:
            self._profile(button)
            tk.Frame(self.body, bg='#3A3A44', height=1).pack(fill='x', pady=12)
            if c.room_code:
                self._in_room(button)
            else:
                self._lobby(button)
        if c.last_error:
            note(c.last_error, '#F28C70')
        note(t('방에는 최대 5명까지 들어올 수 있어요. 다른 사람에게는 내 닉네임·캐릭터·옷차림·대화와 '
               '작업 모션(대기/작업 중/완료)만 보이고, 어떤 작업을 하는지는 전해지지 않아요.',
               'Up to 5 people per room. Others only see your nickname, character, outfit, messages and a work '
               'motion (idle / working / done) — never what you are working on.'), '#555566')

    def _profile(self, button):
        c, B = self.chat, self.BG
        row = tk.Frame(self.body, bg=B); row.pack(fill='x', pady=(10, 0))
        tk.Label(row, text=t('닉네임', 'Nickname'), bg=B, fg='#CCCCCC', width=8, anchor='w',
                 font=('Malgun Gothic', 9)).pack(side='left')
        var = tk.StringVar(value=c.nickname)
        ent = tk.Entry(row, textvariable=var, width=24, font=('Malgun Gothic', 10), relief='flat',
                       bg='#2A2A34', fg='white', insertbackground='white')
        ent.pack(side='left', ipady=3)
        ent.insert(0, '') if c.nickname else None

        def save(_e=None):
            c.nickname = var.get()
            c.push_profile()
        ent.bind('<Return>', save); ent.bind('<FocusOut>', save)
        tk.Label(row, text=t(f'(비우면 {c.character_name(c.character)})', f'(empty = {c.character_name(c.character)})'),
                 bg=B, fg='#8A8A98', font=('Malgun Gothic', 8)).pack(side='left', padx=6)

        row2 = tk.Frame(self.body, bg=B); row2.pack(fill='x', pady=(8, 0))
        tk.Label(row2, text=t('캐릭터', 'Character'), bg=B, fg='#CCCCCC', width=8, anchor='w',
                 font=('Malgun Gothic', 9)).pack(side='left')
        for cid in CHARACTERS:
            on = cid == c.character
            def pick(cid=cid):
                c.character = cid
                c.push_profile()
                self.refresh(force=True)
            tk.Button(row2, text=char_display_name(cid).split(' ')[0], relief='flat', bd=0, cursor='hand2',
                      bg='#3377E0' if on else '#2F2F3A', fg='white' if on else '#AAAAB4',
                      font=('Malgun Gothic', 8, 'bold'), padx=6, pady=3,
                      activebackground='#3377E0', activeforeground='white', command=pick).pack(side='left', padx=(0, 3))

    def _lobby(self, button):
        c, B = self.chat, self.BG
        button(self.body, t('새 방 만들기', 'Create a room'), '#3377E0',
               lambda: threading.Thread(target=c.create_room, daemon=True).start()).pack(anchor='w')
        row = tk.Frame(self.body, bg=B); row.pack(fill='x', pady=(12, 0))
        var = tk.StringVar()
        ent = tk.Entry(row, textvariable=var, width=14, font=('Consolas', 13), relief='flat',
                       bg='#2A2A34', fg='white', insertbackground='white')
        ent.pack(side='left', ipady=4)

        def enter(_e=None):
            code = var.get()
            threading.Thread(target=lambda: c.join(code), daemon=True).start()
        ent.bind('<Return>', enter)
        button(row, t('입장', 'Join'), '#F29926', enter).pack(side='left', padx=(8, 0))
        tk.Label(self.body, text=t('방 코드 6자리', '6-character room code'), bg=B, fg='#666672',
                 font=('Malgun Gothic', 8)).pack(anchor='w', pady=(2, 0))

    def _in_room(self, button):
        c, B = self.chat, self.BG
        row = tk.Frame(self.body, bg=B); row.pack(fill='x')
        tk.Label(row, text=t('방 코드', 'Room code'), bg=B, fg='#CCCCCC', font=('Malgun Gothic', 9)).pack(side='left')
        tk.Label(row, text=c.room_code, bg=B, fg='white', font=('Consolas', 20, 'bold')).pack(side='left', padx=10)

        def copy():
            self.manager.root.clipboard_clear(); self.manager.root.clipboard_append(c.room_code)
        button(row, t('복사', 'Copy'), '#555566', copy).pack(side='left')
        tk.Label(row, text=f'{len(c.members)}/{buni_chat.MAX_MEMBERS}', bg=B, fg='#CCCCCC',
                 font=('Consolas', 10)).pack(side='right')
        colors = {'idle': '#8A8A98', 'working': '#F2BF33', 'done': '#4DC780'}
        labels = {'idle': t('대기', 'Idle'), 'working': t('작업 중', 'Working'), 'done': t('완료', 'Done')}
        for m in c.members:
            r = tk.Frame(self.body, bg=B); r.pack(fill='x', pady=(6, 0))
            tk.Label(r, text='●', bg=B, fg=colors[m['motion']], font=('Malgun Gothic', 8)).pack(side='left')
            tk.Label(r, text=m['name'], bg=B, fg='white', font=('Malgun Gothic', 10, 'bold')).pack(side='left', padx=6)
            tk.Label(r, text=labels[m['motion']], bg=B, fg='#8A8A98', font=('Malgun Gothic', 9)).pack(side='left')
        button(self.body, t('방 나가기', 'Leave room'), '#DB4D4D',
               lambda: threading.Thread(target=c.leave, daemon=True).start()).pack(anchor='w', pady=(14, 0))


# ══════════════════════════════════════════════════════════════
class BuniManager:
    """Root application — manages multiple SessionWindows."""

    def __init__(self):
        self.root = tk.Tk()
        self.root.withdraw()   # hidden background window

        # PID 파일 기록 — 훅이 부니 실행 여부 확인에 사용
        try:
            PID_FILE.write_text(str(os.getpid()), encoding='utf-8')
        except Exception:
            pass

        _ensure_hooks_installed()
        threading.Thread(target=_tcp_event_server, args=(self,), daemon=True).start()

        self.persist  = PersistenceManager()
        # ── 상점·계정 연동·덮개 닫아도 실행 (cloud/awake는 앱으로 실행할 때만 불러온다 —
        #    훅(--hook)은 도구를 부를 때마다 이 파일을 실행하므로 가볍게 둔다)
        import buni_cloud, buni_awake
        global buni_chat
        import buni_chat
        self.shop     = buni_shop.ShopStore()
        self.cloud    = buni_cloud.CloudSession(self.shop, t)
        self.chat     = buni_chat.ChatStore(self.cloud, self.shop, self.persist, t)
        self._chat_window:  'ChatWindow | None' = None
        self._chat_lobby:   'ChatLobbyWindow | None' = None
        self.chat.add_listener(lambda: self._ui(self._on_chat_changed))
        self.awake    = buni_awake.AwakeManager(self.persist, self.root, t)
        self._shop_window: 'ShopWindow | None' = None
        self.shop.add_listener(lambda: self._ui(self._on_shop_changed))
        self.cloud.add_listener(lambda: self._ui(self._on_cloud_changed))
        self.awake.add_listener(lambda: self._ui(self._on_awake_changed))
        self.cloud.start()
        self.chat.start()
        self.sessions: dict[str, SessionWindow] = {}
        self._slot_map: dict[int, str] = {}
        self._disconnected: set[str] = set()   # 수동으로 끊긴 세션 ID 차단 목록
        self._is_manually_hidden = False
        self._monthly_tokens = 0
        self._claude_was_running = False
        self._claude_not_running_streak = 0
        self._server_utilization: float | None = None
        self._server_resets_at:   datetime.datetime | None = None
        self._tray_icon = None   # _start_tray()에서 채움 — 트레이 툴팁에 한도 표시용

        # ── 단축키 ─────────────────────────────────────────
        self._hotkey_mgr = GlobalHotkeyManager()
        self._shortcut_settings: 'ShortcutSettingsWindow | None' = None
        self._init_hotkeys()

        # Start threads
        threading.Thread(target=self._monitor_loop,      daemon=True).start()
        threading.Thread(target=self._token_loop,        daemon=True).start()
        threading.Thread(target=self._server_usage_loop, daemon=True).start()

        # Poll sessions on main thread
        self._poll_sessions()
        self.root.after(2000, self._chat_motion_tick)

        # System tray
        self._start_tray()

        self.root.mainloop()

    # ── Session management ────────────────────────────────────

    def _next_slot(self) -> int:
        for i in range(20):
            if i not in self._slot_map:
                return i
        return len(self._slot_map)

    def _add_session(self, session_id: str, event_file: Path):
        if session_id in self.sessions:
            return
        if session_id in self._disconnected:
            return

        # 30분 이상 수정되지 않은 오래된 파일은 유령 세션이므로 건너뜀
        try:
            if time.time() - event_file.stat().st_mtime > 1800:
                return
        except Exception:
            return

        # 실제 Claude 세션 추가 시 이미 완료된 세션 제거 (새 세션이 이전 부니 덮어씀)
        if session_id != 'windows-default':
            self.cleanup_finished_sessions()

        slot = self._next_slot()
        self._slot_map[slot] = session_id

        # ── 캐릭터 배정 ─────────────────────────────────────
        # 우선순위: ① 슬롯 저장값(재시작 유지) ② 미사용 캐릭터 자동 배정
        # character.session.{id} 는 세션마다 새 UUID라 재시작 시 항상 없음 →
        # character.slot.{slot} 을 실질적인 영구 저장소로 사용
        in_use    = {sw.character for sw in self.sessions.values()}
        slot_char = self.persist.get(f'character.slot.{slot}')
        if slot_char and slot_char in CHARACTERS and slot_char not in in_use:
            assigned = slot_char
        else:
            # 슬롯 저장값이 없거나 이미 사용 중 → 미사용 캐릭터 자동 선택
            assigned = next(
                (cid for cid in CHARACTERS if cid not in in_use),
                list(CHARACTERS.keys())[slot % len(CHARACTERS)]   # 최후 폴백
            )
        # 두 키 모두 저장 (slot 기준 영구 유지)
        self.persist.set(f'character.session.{session_id}', assigned)
        self.persist.set(f'character.slot.{slot}',          assigned)

        win = SessionWindow(self, session_id, slot, event_file, self.persist)
        win.set_monthly_tokens(self._monthly_tokens)
        win.set_server_usage(self._server_utilization, self._server_resets_at)
        self.sessions[session_id] = win

        # 사용자가 숨긴 직후라면 새 부니도 조용히 대기 —
        # 이 세션이 실제로 작업을 시작할 때 비로소 나타난다.
        if self._is_manually_hidden:
            win.hide_until_next_start()

    def remove_session(self, session_id: str):
        win = self.sessions.pop(session_id, None)
        if win:
            self._slot_map.pop(win.slot, None)
            win.destroy()

    def cleanup_finished_sessions(self):
        """새 세션 추가 전 종료된(idle/completed) 세션 제거.
        ready는 병렬 실행 중인 세션일 수 있으므로 유지."""
        to_remove = [sid for sid, win in list(self.sessions.items())
                     if win.state in ('idle', 'completed')]
        for sid in to_remove:
            self.remove_session(sid)

    def cleanup_inactive_sessions(self):
        """Claude 종료 시 대기·작업 중 세션만 제거, completed/permission 버블은 유지."""
        to_remove = [sid for sid, win in list(self.sessions.items())
                     if win.state not in ('completed', 'permission')]
        for sid in to_remove:
            self.remove_session(sid)
        for win in self.sessions.values():
            win.hide()

    def disconnect_session(self, session_id: str, event_file: Path):
        """세션을 수동으로 끊고 차단 목록에 추가합니다.
        이벤트 파일을 삭제해 훅 이벤트가 재감지되지 않도록 하고,
        session_id를 차단 목록에 등록해 파일이 다시 생겨도 무시합니다."""
        self._disconnected.add(session_id)
        try:
            event_file.unlink(missing_ok=True)
        except Exception:
            pass
        self.remove_session(session_id)

    def hide_all(self):
        """전체 숨김 — 각 부니는 "그 세션이 새로 시작될 때"까지 숨어 있고
        (진행 중에 숨겼다면 그 작업이 끝나고 다음 작업이 시작될 때),
        그 사이에 새로 만들어지는 부니도 나타나지 않는다."""
        self._is_manually_hidden = True
        for win in self.sessions.values():
            win.hide_until_next_start()

    def show_all(self):
        self._is_manually_hidden = False
        for win in self.sessions.values():
            win._manually_hidden = False
            win.show()

    def quit(self):
        try:
            self.awake.restore_on_quit()     # 켜둔 채 꺼지면 덮개를 닫아도 계속 안 자게 된다
        except Exception:
            pass
        try:
            self.chat.leave_blocking()       # 채팅방 자리를 비운다
        except Exception:
            pass
        try:
            PID_FILE.unlink(missing_ok=True)
        except Exception:
            pass
        self.root.quit()
        sys.exit(0)

    # ── Session polling (main thread) ─────────────────────────

    def _poll_sessions(self):
        for sid in list(self.sessions.keys()):
            win = self.sessions.get(sid)
            if win and not win.poll_events():
                # event file gone — remove session
                self.root.after(0, lambda s=sid: self.remove_session(s))
        self.root.after(500, self._poll_sessions)

    # ── File monitor (background thread) ─────────────────────

    def _monitor_loop(self):
        """Detect new/removed event files and Claude process state."""
        while True:
            try:
                found: dict[str, Path] = {}
                for p in glob.glob(str(_TEMP / 'claude-companion-events-*.jsonl')):
                    fp  = Path(p)
                    sid = self._sid_from_file(fp)
                    if sid in self._disconnected:
                        continue
                    found[sid] = fp
                # 세션 ID 없이 쓴 고정 파일 — 세션별 파일이 하나도 없을 때만 폴백으로 사용
                fixed = _TEMP / 'claude-companion-events.jsonl'
                if fixed.exists() and not found:
                    found['windows-default'] = fixed

                # 세션별 파일이 있으면 windows-default 유령 세션 제거
                real_sids = [s for s in found if s != 'windows-default']
                if real_sids and 'windows-default' in self.sessions:
                    self.root.after(0, lambda: self.remove_session('windows-default'))

                # New sessions
                for sid, fp in found.items():
                    if sid not in self.sessions:
                        self.root.after(0, lambda s=sid, f=fp: self._add_session(s, f))

                # Claude process state (for idle detection)
                running = self._is_claude_running()
                if running:
                    self._claude_not_running_streak = 0
                    self._claude_was_running = True
                else:
                    self._claude_not_running_streak += 1

                if self._claude_was_running and self._claude_not_running_streak >= 3:
                    # 3틱(~3초) 연속 미감지 시 비활성 세션 제거, completed/permission 유지
                    self._claude_was_running = False
                    if self.sessions:
                        self.root.after(0, self.cleanup_inactive_sessions)

            except Exception:
                pass
            time.sleep(1.0)

    def _all_sessions_idle(self):
        for win in list(self.sessions.values()):
            win._apply_state('idle')

    @staticmethod
    def _sid_from_file(f: Path) -> str:
        m = re.search(r'claude-companion-events-(.+)\.jsonl$', f.name)
        if m:
            return m.group(1)
        if f.name == 'claude-companion-events.jsonl':
            return 'windows-default'
        return f.stem

    @staticmethod
    def _is_claude_running() -> bool:
        try:
            import subprocess
            CREATE_NO_WINDOW = 0x08000000
            out = subprocess.check_output(
                ['tasklist', '/FI', 'IMAGENAME eq node.exe', '/NH'],
                stderr=subprocess.DEVNULL, text=True,
                creationflags=CREATE_NO_WINDOW)
            return 'node.exe' in out.lower()
        except Exception:
            return False

    # ── Monthly token refresh (background thread) ─────────────

    def _token_loop(self):
        while True:
            try:
                total = 0
                projects_dir = Path.home() / '.claude' / 'projects'
                if projects_dir.exists():
                    now = datetime.datetime.now()
                    for jf in projects_dir.rglob('*.jsonl'):
                        try:
                            for line in jf.read_text(
                                    encoding='utf-8', errors='replace').splitlines():
                                if not line.strip():
                                    continue
                                obj = json.loads(line)
                                ts_str = obj.get('timestamp', '')
                                if ts_str:
                                    try:
                                        ts = datetime.datetime.fromisoformat(
                                            ts_str.replace('Z', '+00:00'))
                                        if ts.year != now.year or ts.month != now.month:
                                            continue
                                    except Exception:
                                        continue
                                usage = (obj.get('message', {}) or {}).get('usage', {})
                                total += usage.get('input_tokens', 0)
                                total += usage.get('output_tokens', 0)
                        except Exception:
                            continue
                self._monthly_tokens = total
                self.root.after(0, self._broadcast_tokens)
            except Exception:
                pass
            time.sleep(300)

    def _broadcast_tokens(self):
        self.shop.update_level(self._monthly_tokens)
        for win in self.sessions.values():
            win.set_monthly_tokens(self._monthly_tokens)

    # ── 상점 · 계정 · 절전 방지 ───────────────────────────────

    def _ui(self, fn):
        """어느 스레드에서 불려도 Tk 메인 스레드에서 실행되게 넘긴다."""
        try:
            self.root.after(0, fn)
        except Exception:
            pass

    def _on_shop_changed(self):
        for win in list(self.sessions.values()):
            win._draw()
        if self._shop_window and self._shop_window.is_open():
            self._shop_window.refresh()
        self._refresh_settings()

    def _on_cloud_changed(self):
        if self._shop_window and self._shop_window.is_open():
            self._shop_window.refresh()
        self._refresh_settings()
        self._refresh_tray_menu()

    def _on_awake_changed(self):
        self._refresh_settings()
        self._refresh_tray_menu()

    def _refresh_settings(self):
        ss = self._shortcut_settings
        if ss and ss.is_open():
            ss.refresh_dynamic()

    def open_shop(self, character: str | None = None):
        if self._shop_window and self._shop_window.is_open():
            self._shop_window.show(character)
            return
        char = character
        if not char:
            sw = next(iter(self.sessions.values()), None)
            char = sw.character if sw else 'rabbit'
        self._shop_window = ShopWindow(self, char)

    # ── 채팅 ──────────────────────────────────────────────────

    def _on_chat_changed(self):
        """방에 들어가면 채팅 패널을 띄우고, 나오면 내린다."""
        if self.chat.is_in_room:
            if not (self._chat_window and self._chat_window.is_open()):
                self._chat_window = ChatWindow(self)
        elif self._chat_window:
            self._chat_window.close()
            self._chat_window = None
        if self._chat_lobby and self._chat_lobby.is_open():
            self._chat_lobby.refresh()
        self._refresh_tray_menu()

    def open_chat(self):
        if self._chat_lobby and self._chat_lobby.is_open():
            self._chat_lobby.show()
            return
        self._chat_lobby = ChatLobbyWindow(self)

    def _chat_motion_tick(self):
        """내 세션들의 상태를 한 가지 모션으로 요약해 채팅방에 알린다.
        하나라도 작업 중이면 작업 중, 아니면 완료된 세션이 있으면 완료, 그 밖엔 대기.
        (세션 이름·작업 내용은 보내지 않는다 — 모션만 간다)"""
        states = [w.state for w in self.sessions.values()]
        if any(s in SessionWindow.RUNNING_STATES for s in states):
            motion = 'working'
        elif any(s == 'completed' for s in states):
            motion = 'done'
        else:
            motion = 'idle'
        self.chat.set_motion(motion)
        self.root.after(2000, self._chat_motion_tick)

    def cloud_sign_in_ui(self):
        """"다른 PC와 연동" — 어떤 정보가 서버에 저장되는지 먼저 알리고 동의를 받는다."""
        from tkinter import messagebox
        cloud = self.cloud
        if cloud.busy:
            return
        if not cloud.consent_given:
            ok = messagebox.askokcancel(
                t('다른 PC와 연동할까요?', 'Sync with your other PCs?'),
                t('Google로 로그인하면 아래 정보가 서버에 저장되어 다른 PC에서도 이어집니다.\n\n'
                  '• 코인, 산 아이템, 캐릭터별 착용 상태\n'
                  '• 기기별 이번 달 토큰 사용량(레벨 계산용 숫자)\n'
                  '• 로그인 계정의 고유 ID와 표시 이름\n\n'
                  '대화 내용이나 코드는 저장하지 않으며, 이메일 주소도 저장하지 않아요. '
                  '로그인은 선택이라 안 해도 모든 기능을 그대로 쓸 수 있고, 설정에서 언제든 '
                  '로그아웃하거나 서버 데이터를 지울 수 있어요.',
                  'Signing in with Google stores the following on a server so it carries over to your other PCs:\n\n'
                  '• Coins, owned items and per-character outfits\n'
                  '• Per-device token usage for this month (a number used for your level)\n'
                  "• Your account's unique ID and display name\n\n"
                  'Conversations and code are never stored, and neither is your email address. '
                  'Signing in is optional, and you can sign out or delete your server data any time in Settings.'),
                icon='question', parent=self.root)
            if not ok:
                return
            cloud.give_consent()
        threading.Thread(target=cloud.sign_in, daemon=True).start()

    # ── Server plan usage (5분마다 fetch) ─────────────────────

    # ── Chromium AES key 복호화 (1회 캐시) ───────────────────
    _aes_key_cache: bytes | None = None

    @staticmethod
    def _find_claude_dir() -> 'Path | None':
        r"""%APPDATA%\Claude 또는 MSIX 패키지 경로 중 config.json이 있는 곳을 반환."""
        candidates = [Path(os.environ.get('APPDATA', '')) / 'Claude']
        local_app = Path(os.environ.get('LOCALAPPDATA', ''))
        packages_dir = local_app / 'Packages'
        if packages_dir.exists():
            for pkg in packages_dir.iterdir():
                if pkg.name.startswith('Claude_'):
                    msix_claude = pkg / 'LocalCache' / 'Roaming' / 'Claude'
                    if msix_claude.exists():
                        candidates.insert(0, msix_claude)
        for d in candidates:
            if (d / 'config.json').exists():
                return d
        return candidates[0]

    @staticmethod
    def _get_aes_key() -> 'bytes | None':
        if BuniManager._aes_key_cache is not None:
            return BuniManager._aes_key_cache
        try:
            import ctypes, ctypes.wintypes as wt
            claude_dir = BuniManager._find_claude_dir()
            local_state = claude_dir / 'Local State'
            data = json.loads(local_state.read_text(encoding='utf-8'))
            enc_b64 = data['os_crypt']['encrypted_key']
            dpapi_blob = base64.b64decode(enc_b64)[5:]  # strip 'DPAPI' prefix

            class _BLOB(ctypes.Structure):
                _fields_ = [('cbData', wt.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]

            blob_in  = _BLOB(len(dpapi_blob), ctypes.cast(ctypes.c_char_p(dpapi_blob), ctypes.POINTER(ctypes.c_char)))
            blob_out = _BLOB()
            ok = ctypes.windll.crypt32.CryptUnprotectData(
                ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out))
            if not ok:
                return None
            key = ctypes.string_at(blob_out.pbData, blob_out.cbData)
            ctypes.windll.kernel32.LocalFree(blob_out.pbData)
            BuniManager._aes_key_cache = key
            return key
        except Exception:
            return None

    @staticmethod
    def _get_oauth_token() -> 'str | None':
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
            aes_key = BuniManager._get_aes_key()
            if not aes_key:
                return None
            config = BuniManager._find_claude_dir() / 'config.json'
            cfg = json.loads(config.read_text(encoding='utf-8'))
            enc_b64 = cfg.get('oauth:tokenCache', '')
            if not enc_b64:
                return None
            enc = base64.b64decode(enc_b64 + '==')
            plaintext = AESGCM(aes_key).decrypt(enc[3:15], enc[15:], None).decode('utf-8')
            token_data = json.loads(plaintext)
            best_key = max(token_data.keys(), key=lambda k: len(k))
            return token_data[best_key]['token']
        except Exception:
            return None

    def _server_usage_loop(self):
        import urllib.request, urllib.error
        plan_file = _TEMP / 'claude-companion-plan-usage.json'
        while True:
            try:
                token = BuniManager._get_oauth_token()
                if token:
                    req = urllib.request.Request(
                        'https://api.anthropic.com/api/oauth/usage',
                        headers={'Authorization': f'Bearer {token}',
                                 'anthropic-beta': 'oauth-2025-04-20'}
                    )
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        api_data = json.loads(resp.read().decode())
                    fh = api_data.get('five_hour', {})
                    result = {'utilization': fh.get('utilization', 0),
                              'resets_at':   fh.get('resets_at', '')}
                    plan_file.write_text(json.dumps(result), encoding='utf-8')

                if plan_file.exists():
                    data     = json.loads(plan_file.read_text(encoding='utf-8'))
                    util     = float(data.get('utilization', 0))
                    ra       = data.get('resets_at', '')
                    resets_at: datetime.datetime | None = None
                    if ra:
                        try:
                            resets_at = datetime.datetime.fromisoformat(
                                ra.replace('Z', '+00:00'))
                        except Exception:
                            pass
                    # resets_at이 이미 지났으면 캐시 데이터 만료 → 둘 다 None으로
                    now_utc = datetime.datetime.now(datetime.timezone.utc)
                    if resets_at is not None and resets_at <= now_utc:
                        util      = None
                        resets_at = None
                    self._server_utilization = util
                    self._server_resets_at   = resets_at
                    self.root.after(0, self._broadcast_server_usage)
            except Exception:
                pass
            time.sleep(300)

    def _broadcast_server_usage(self):
        for win in self.sessions.values():
            win.set_server_usage(self._server_utilization, self._server_resets_at)
        # Windows 트레이는 macOS 메뉴바처럼 아이콘 옆에 상시 텍스트를 못 붙이므로
        # (아이콘 하나뿐) 마우스를 올렸을 때 보이는 툴팁에 한도를 표시한다.
        if self._tray_icon is not None and self._server_utilization is not None:
            try:
                self._tray_icon.title = f'Buni — 한도 {round(self._server_utilization)}%'
            except Exception:
                pass

    # ── 단축키 ────────────────────────────────────────────────

    def _init_hotkeys(self):
        callbacks = {
            'approve':        self._hk_approve,
            'always_approve': self._hk_always_approve,
            'deny':           self._hk_deny,
            'hide':           self._hk_hide,
        }
        self._hotkey_mgr.start(self.root, callbacks)
        # 저장된 단축키 로드 (ShortcutSettingsWindow 생성 전 직접 적용)
        saved = self.persist.get('shortcuts', {})
        defaults = {'approve': {'mods': GlobalHotkeyManager.MOD_CTRL, 'vk': 0x0D}}
        for action in ('approve', 'always_approve', 'deny', 'hide'):
            v = saved.get(action) or defaults.get(action)
            if v:
                self._hotkey_mgr.set_shortcut(action, v['mods'], v['vk'])

    def _hk_approve(self):
        for win in self.sessions.values():
            if win.state == 'permission':
                win._decide('approve')
            elif win.state == 'completed':
                win._dismiss_completed()

    def _hk_deny(self):
        for win in self.sessions.values():
            if win.state == 'permission':
                win._decide('deny')

    def _hk_always_approve(self):
        for win in self.sessions.values():
            if win.state == 'completed':
                win._dismiss_completed()
            elif win.state == 'permission':
                win._decide('approve_all')

    def _hk_hide(self):
        if any(w.is_visible for w in self.sessions.values()):
            self.hide_all()
        else:
            self.show_all()

    def _refresh_tray_menu(self):
        """언어 변경 후 트레이 메뉴 라벨을 다시 평가시킨다."""
        icon = getattr(self, '_tray_icon', None)
        if not icon:
            return
        try:
            icon.update_menu()
        except Exception:
            pass

    def _open_shortcut_settings(self):
        if self._shortcut_settings and self._shortcut_settings.is_open():
            self._shortcut_settings.show()
            return
        self._shortcut_settings = ShortcutSettingsWindow(
            self.root, self.persist, self._hotkey_mgr, manager=self)
        # 언어를 바꾸면 트레이 메뉴도 새 언어로 다시 그린다
        self._shortcut_settings.on_language_changed = self._refresh_tray_menu

    def _open_claude(self):
        try:
            os.startfile('claude')
        except Exception:
            pass

    # ── 덮개 닫아도 계속 실행 (트레이 하위 메뉴) ──────────────

    def _awake_menu_title(self, item=None) -> str:
        a = self.awake
        if a.is_active:
            return t(f'🔋 덮개 닫아도 계속 실행 — 실행 중 ({a.status_text()})',
                     f'🔋 Keep running with lid closed — ON ({a.status_text()})')
        return t('🔋 덮개 닫아도 계속 실행', '🔋 Keep running with lid closed')

    def _awake_menu_items(self, pystray):
        import buni_awake

        def start(minutes):
            def _cb(icon, item):
                self.root.after(0, lambda: self.awake.enable(minutes))
            return _cb

        def off(icon, item):
            self.root.after(0, self.awake.disable)

        def toggle_schedule(icon, item):
            self.root.after(0, lambda: self.awake.set_schedule(enabled=not self.awake.schedule_enabled))

        items = [pystray.MenuItem(
                    (lambda ko, en: (lambda i: t(ko, en)))(ko, en), start(minutes))
                 for minutes, ko, en in buni_awake.DURATIONS]
        items += [
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(lambda i: t('지금 끄기', 'Turn off now'), off,
                             visible=lambda i: self.awake.is_active),
            pystray.MenuItem(
                lambda i: t(f'시간대 예약 {buni_awake.hhmm(self.awake.schedule_start)}'
                            f'–{buni_awake.hhmm(self.awake.schedule_end)}',
                            f'Schedule {buni_awake.hhmm(self.awake.schedule_start)}'
                            f'–{buni_awake.hhmm(self.awake.schedule_end)}'),
                toggle_schedule, checked=lambda i: self.awake.schedule_enabled),
            pystray.MenuItem(lambda i: '⚠️ ' + self.awake.last_error, None,
                             visible=lambda i: bool(self.awake.last_error), enabled=False),
        ]
        return items

    # ── System tray ───────────────────────────────────────────

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except ImportError:
            return   # pystray/Pillow not installed

        def make_icon():
            # 9×10 픽셀아트 토끼 (맥 버전 MenuBarIcon 포팅)
            grid = [
                ".XX...XX.",
                ".XX...XX.",
                ".XX...XX.",
                ".XX...XX.",
                ".XXXXXXX.",
                ".X.XXX.X.",
                ".XXX.XXX.",
                ".XXXXXXX.",
                "..XXXXX..",
            ]
            size = 32
            rows, cols = len(grid), len(grid[0])
            cw = size / cols;  ch = size / rows
            img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
            d   = ImageDraw.Draw(img)
            for r, row in enumerate(grid):
                for c, px in enumerate(row):
                    if px == 'X':
                        x0, y0 = int(c*cw), int(r*ch)
                        x1, y1 = int((c+1)*cw)-1, int((r+1)*ch)-1
                        d.rectangle([x0, y0, x1, y1], fill=(232, 232, 240, 255))
            return img

        # 숨기기/불러오기를 하나로 토글하면, 세션 하나가 소리 없이(예: Claude
        # 종료 감지) 숨겨졌을 때 "불러오기" 항목 자체가 안 보여서 — 그걸
        # 보이게 하려고 전체를 숨겼다가 다시 불러와야 하는 번거로움이 생김.
        # 항상 둘 다 보여주고 각각 명시적으로 동작하게 한다.
        def on_hide(icon, item):
            self.root.after(0, self.hide_all)

        def on_show(icon, item):
            self.root.after(0, self.show_all)

        def on_claude(icon, item):
            self.root.after(0, self._open_claude)

        def on_settings(icon, item):
            self.root.after(0, self._open_shortcut_settings)

        def on_shop(icon, item):
            self.root.after(0, self.open_shop)

        def on_chat(icon, item):
            self.root.after(0, self.open_chat)

        def on_reset(icon, item):
            self.root.after(0, lambda: [
                w._reset_position() for w in self.sessions.values()])

        def on_quit(icon, item):
            icon.stop()
            self.root.after(0, self.quit)

        def _any_always_approve(item=None):
            return any(w.always_approve for w in self.sessions.values())

        def on_disable_always_approve(icon, item):
            def _do():
                for w in self.sessions.values():
                    if w.always_approve:
                        w.always_approve = False
                        w._save_always_approve()
            self.root.after(0, _do)

        # 라벨을 호출형으로 둬야 언어를 바꿨을 때 update_menu()로 다시 평가된다
        icon = pystray.Icon('Buni', make_icon(), 'Buni', pystray.Menu(
            pystray.MenuItem(lambda i: t('⚡ 전체 허용 모드 켜짐 — 클릭하여 끄기',
                                         '⚡ Approve-all is ON — click to turn off'),
                              on_disable_always_approve, visible=_any_always_approve),
            # 기능별로 묶고, 묶음마다 눌리지 않는 작은 제목을 단다
            pystray.MenuItem(lambda i: t('부니 화면', 'On screen'), None, enabled=False),
            pystray.MenuItem(lambda i: t('부니 숨기기', 'Hide Buni'),   on_hide, default=True),
            pystray.MenuItem(lambda i: t('부니 불러오기', 'Show Buni'), on_show),
            pystray.MenuItem(lambda i: t('위치 초기화', 'Reset position'), on_reset),
            pystray.MenuItem(lambda i: t('Claude 열기', 'Open Claude'), on_claude),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(lambda i: t('꾸미기 · 함께하기', 'Style & together'), None, enabled=False),
            pystray.MenuItem(lambda i: t(f'🛍 부니 상점  (🪙 {self.shop.coins})',
                                         f'🛍 Buni Shop  (🪙 {self.shop.coins})'), on_shop),
            pystray.MenuItem(lambda i: (t(f'💬 부니 채팅  (방 {self.chat.room_code})', f'💬 Buni Chat  (room {self.chat.room_code})')
                                        if self.chat.room_code else t('💬 부니 채팅...', '💬 Buni Chat...')), on_chat),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(lambda i: t('작업 도구', 'Work tools'), None, enabled=False,
                             visible=lambda i: self.awake.supported),
            pystray.MenuItem(self._awake_menu_title, pystray.Menu(*self._awake_menu_items(pystray)),
                             visible=lambda i: self.awake.supported),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(lambda i: t('설정...', 'Settings...'),     on_settings),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(lambda i: t('종료', 'Quit'),               on_quit),
        ))
        self._tray_icon = icon
        threading.Thread(target=icon.run, daemon=True).start()


# ── Entry point ───────────────────────────────────────────────

if __name__ == '__main__':
    # Claude Code 훅으로 호출될 때: --hook <type>
    if len(sys.argv) >= 3 and sys.argv[1] == '--hook':
        _run_hook(sys.argv[2])
    else:
        BuniManager()
