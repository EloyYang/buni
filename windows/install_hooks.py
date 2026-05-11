#!/usr/bin/env python3
"""
Buni Windows - Claude Code 훅 설치 스크립트
훅 스크립트를 %APPDATA%\Claude에 설치하고 settings.json을 업데이트합니다.
"""
import json, os, sys, shutil
from pathlib import Path

# 이벤트 파일: Windows TEMP
TEMP = Path(os.environ.get('TEMP', os.environ.get('TMP', 'C:/temp')))
EVENTS_FILE = TEMP / 'claude-companion-events.jsonl'

# Claude Code 설정 디렉터리
CLAUDE_DIR = Path.home() / '.claude'
SETTINGS   = CLAUDE_DIR / 'settings.json'

# ── 훅 스크립트 내용 ──────────────────────────────────────────

PRETOOL = f'''\
#!/usr/bin/env python3
import sys, json, uuid, time, fnmatch, os
from pathlib import Path

TEMP     = Path(r"{TEMP}")
CLAUDE   = Path.home() / ".claude"
PID_FILE = TEMP / "buni.pid"


def _is_buni_running() -> bool:
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


def _events_file(session_id: str) -> Path:
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{{safe}}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


def _load_allow_list() -> list:
    patterns = []
    for fname in ("settings.json", "settings.local.json"):
        try:
            data = json.loads((CLAUDE / fname).read_text(encoding="utf-8"))
            patterns += data.get("permissions", {{}}).get("allow", [])
        except Exception:
            pass
    return patterns


def _is_allowed(tool_name, tool_input, patterns) -> bool:
    rep = ""
    try:
        rep = tool_input.get("command") or tool_input.get("file_path") or ""
    except Exception:
        pass
    for pat in patterns:
        try:
            if "(" in pat:
                pname, parg = pat.split("(", 1)
                parg = parg.rstrip(")")
                if pname.strip() == tool_name and fnmatch.fnmatch(str(rep), parg):
                    return True
            elif pat.strip() == tool_name:
                return True
        except Exception:
            continue
    return False


def _write_event(events_file, line) -> bool:
    try:
        with events_file.open("a", encoding="utf-8") as f:
            f.write(line + "\\n")
        return True
    except Exception:
        return False


def _safe_json(obj) -> str:
    try:
        return json.dumps(obj, ensure_ascii=False, default=str)
    except Exception:
        return json.dumps(str(obj))


def _approve():
    print(json.dumps({{"decision": "approve"}}), flush=True)
    sys.exit(0)


def _block(reason=""):
    print(json.dumps({{"decision": "block", "reason": reason}}), flush=True)
    sys.exit(0)


def main():
    try:
        raw = sys.stdin.buffer.read()
        d   = json.loads(raw.decode("utf-8", errors="replace"))
    except Exception:
        _approve()
        return

    tool_name  = d.get("tool_name", "tool")
    tool_input = d.get("tool_input", {{}}) or {{}}
    session_id = d.get("session_id", "")
    EVENTS     = _events_file(session_id)

    try:
        allow_list = _load_allow_list()
        if _is_allowed(tool_name, tool_input, allow_list):
            _write_event(EVENTS, _safe_json({{"type": "tool_use", "tool": tool_name}}))
            _approve()
            return
    except Exception:
        pass

    if not _is_buni_running():
        _write_event(EVENTS, _safe_json({{"type": "tool_use", "tool": tool_name}}))
        _approve()
        return

    req_id = str(uuid.uuid4())
    try:
        cmd = tool_name + " " + _safe_json(tool_input)
    except Exception:
        cmd = tool_name
    cmd = cmd[:300]

    written = _write_event(EVENTS, _safe_json({{
        "type": "permission_request", "id": req_id, "message": cmd
    }}))

    if not written:
        sys.exit(0)
        return

    decision_file = TEMP / f"claude-companion-decision-{{req_id}}"
    for _ in range(120):
        try:
            if decision_file.exists():
                decision = decision_file.read_text(encoding="utf-8").strip()
                decision_file.unlink(missing_ok=True)
                if decision == "deny":
                    _block("buni에서 거부됨")
                    return
                _write_event(EVENTS, _safe_json({{"type": "tool_use", "tool": tool_name}}))
                _approve()
                return
        except Exception:
            pass
        time.sleep(0.5)

    _block("시간 초과 (60초)")


if __name__ == "__main__":
    main()
'''

POSTTOOL = f'''\
#!/usr/bin/env python3
import sys, json
from pathlib import Path

TEMP = Path(r"{TEMP}")


def _events_file(session_id: str) -> Path:
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{{safe}}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    events_file = _events_file(session_id)
    with events_file.open("a", encoding="utf-8") as f:
        f.write('{{"type":"tool_done"}}\\n')
except Exception:
    pass
'''

NOTIFICATION = f'''\
#!/usr/bin/env python3
import sys, json
from pathlib import Path

TEMP = Path(r"{TEMP}")


def _events_file(session_id: str) -> Path:
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{{safe}}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    msg = d.get("message", "알림")[:120]
    line = json.dumps({{"type": "notification", "message": msg}})
    events_file = _events_file(session_id)
    with events_file.open("a", encoding="utf-8") as f:
        f.write(line + "\\n")
except Exception:
    pass
'''

STOP = f'''\
#!/usr/bin/env python3
import sys, json
from pathlib import Path

TEMP = Path(r"{TEMP}")


def _events_file(session_id: str) -> Path:
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{{safe}}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    events_file = _events_file(session_id)
    with events_file.open("a", encoding="utf-8") as f:
        f.write('{{"type":"done"}}\\n')
except Exception:
    pass
'''

PERMISSION = f'''\
#!/usr/bin/env python3
import sys, json, uuid, time
from pathlib import Path

TEMP = Path(r"{TEMP}")


def _events_file(session_id: str) -> Path:
    sid = (session_id or "").strip()
    if sid:
        safe = "".join(c for c in sid if c.isalnum() or c in "-_")
        if safe:
            return TEMP / f"claude-companion-events-{{safe}}.jsonl"
    return TEMP / "claude-companion-events.jsonl"


try:
    raw = sys.stdin.buffer.read()
    d = json.loads(raw.decode("utf-8", errors="replace"))
    session_id = d.get("session_id", "")
    events_file = _events_file(session_id)
    req_id = str(uuid.uuid4())
    cmd = d.get("tool_name", "") + " " + json.dumps(d.get("tool_input", {{}}))
    line = json.dumps({{"type": "permission_request", "id": req_id, "message": cmd[:300]}})
    with events_file.open("a", encoding="utf-8") as f:
        f.write(line + "\\n")
    # 결정 파일 대기 (최대 60초)
    decision_file = TEMP / f"claude-companion-decision-{{req_id}}"
    for _ in range(120):
        if decision_file.exists():
            decision = decision_file.read_text().strip()
            decision_file.unlink(missing_ok=True)
            if decision == "deny":
                sys.exit(1)   # Claude Code에 거부 신호
            sys.exit(0)
        time.sleep(0.5)
    sys.exit(1)   # 타임아웃 = 거부
except Exception:
    sys.exit(0)
'''

SCRIPTS = {
    'companion-pretool.py':      PRETOOL,
    'companion-posttool.py':     POSTTOOL,
    'companion-notification.py': NOTIFICATION,
    'companion-stop.py':         STOP,
    'companion-permission.py':   PERMISSION,
}

def main():
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    EVENTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    # EVENTS_FILE.touch() 제거 — touch()가 mtime을 갱신하면 Buni가
    # 고정 파일을 유효한 세션으로 오해해 유령 세션(중복 창)을 생성함

    # 훅 스크립트 작성
    for name, content in SCRIPTS.items():
        path = CLAUDE_DIR / name
        path.write_text(content, encoding='utf-8')
        print(f'  ✓ {path}')

    # settings.json 업데이트
    if SETTINGS.exists():
        try:
            with SETTINGS.open(encoding='utf-8') as f:
                settings = json.load(f)
        except json.JSONDecodeError:
            settings = {}
        # 백업
        shutil.copy(SETTINGS, str(SETTINGS) + '.buni-backup')
    else:
        settings = {}

    python = sys.executable

    def hook(script):
        return {'type': 'command',
                'command': f'"{python}" "{CLAUDE_DIR / script}"; exit 0'}

    def perm_hook(script):
        # PermissionRequest는 exit code를 Claude Code에 그대로 전달해야 함
        # (exit 0 = 허용, exit 1 = 거부) → ; exit 0 붙이지 않음
        return {'type': 'command',
                'command': f'"{python}" "{CLAUDE_DIR / script}"'}

    new_hooks = {
        'PreToolUse':        [{'matcher': '', 'hooks': [hook('companion-pretool.py')]}],
        'PostToolUse':       [{'matcher': '', 'hooks': [hook('companion-posttool.py')]}],
        'Notification':      [{'matcher': '', 'hooks': [hook('companion-notification.py')]}],
        'Stop':              [{'matcher': '', 'hooks': [hook('companion-stop.py')]}],
        'PermissionRequest': [{'matcher': '', 'hooks': [perm_hook('companion-permission.py')]}],
    }

    existing = settings.get('hooks', {})
    for event, entries in new_hooks.items():
        prev = [e for e in existing.get(event, [])
                if not any('companion-' in str(h) for h in e.get('hooks', []))]
        existing[event] = prev + entries
    settings['hooks'] = existing

    with SETTINGS.open('w', encoding='utf-8') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print(f'  ✓ {SETTINGS}')
    print()
    print('훅 설치 완료.')

if __name__ == '__main__':
    main()
