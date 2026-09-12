#!/usr/bin/env bash
# Buni — SSH 원격 호스트용 훅 설치 스크립트
#
# VS Code(또는 Cursor 등)로 SSH Remote 접속해 그 원격 서버에서 Claude Code를
# 돌릴 때, 로컬 Buni 앱이 원격 세션 상태를 받아보려면 "이 스크립트를 원격
# 호스트에서 한 번" 실행해야 한다. 로컬 Buni(Mac/Windows)는 실행될 때
# 자기 자신의 VS Code settings.json에 `remote.SSH.extraArgs`로 포트 포워딩
# (-R 58765:localhost:58765)을 자동으로 추가해 두지만, 그건 로컬 절반일
# 뿐이고 원격 호스트에 Claude Code 훅이 설치돼 있어야 이벤트가 애초에
# 발생한다. Buni 앱 자체는 데스크톱용이라 원격 리눅스/맥 서버에서는 돌지
# 않으므로, 훅 스크립트만 따로 이 파일로 배포한다.
#
# 사용법 (로컬 맥/윈도우 터미널에서, 파일을 원격에 복사할 필요 없이 바로 실행):
#   ssh <원격호스트> 'bash -s' < remote-install.sh
#
# 또는 원격 호스트에 직접 올려서:
#   scp remote-install.sh <원격호스트>:~/ && ssh <원격호스트> 'bash ~/remote-install.sh'
#
# 요구사항: 원격 호스트에 python3 (훅 스크립트 실행용, 대부분의 리눅스/맥에 기본 포함)
set -e

HOOKS_DIR="$HOME/.claude"
SETTINGS_FILE="$HOOKS_DIR/settings.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Buni — SSH 원격 훅 설치"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v python3 >/dev/null 2>&1; then
    echo "✗ python3을 찾을 수 없습니다. 원격 호스트에 python3을 설치한 뒤 다시 실행하세요."
    exit 1
fi

mkdir -p "$HOOKS_DIR"

write_script() {
    local name="$1"
    local dest="$HOOKS_DIR/$name"
    if [ -f "$dest" ]; then
        echo "· $name — 이미 있음, 건드리지 않음 (사용자 커스터마이징 보호)"
        return
    fi
    cat > "$dest"
    chmod 755 "$dest"
    echo "✓ $name 설치됨"
}

write_script companion-pretool.py << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os, uuid, time

SAFE_TOOLS = {"Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch",
              "TodoRead", "NotebookRead", "AskUserQuestion"}
BUNI_PORT = 58765

# ── Claude 자체가 이미 자동 승인하는 모드인지 판정 ──────────────────────
# 클로드가 사용자에게 안 묻는 상황에서 부니만 승인 창을 띄우는 문제 방지.
AUTO_APPROVE_MODES = {"auto", "bypassPermissions"}
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def _skip_gate(tool, perm_mode):
    if perm_mode in AUTO_APPROVE_MODES:
        return True
    # acceptEdits는 편집 도구만 자동 승인 — Bash 등은 그대로 승인 UI 사용
    return perm_mode == "acceptEdits" and tool in EDIT_TOOLS


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    d = json.load(sys.stdin)
    tool        = d.get("tool_name", "tool")
    tool_input  = d.get("tool_input", {})
    session_id  = d.get("session_id", "") or "legacy"
    perm_mode   = d.get("permission_mode", "") or ""  # default/auto/acceptEdits/bypassPermissions/plan
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    if is_remote:
        # SSH Remote — 권한 UI 없이 tool_use 이벤트만 TCP 전송 (자동 승인)
        _send_tcp({"type": "tool_use", "tool": tool, "session_id": session_id})
    else:
        # 로컬 — 파일 기반 전체 흐름
        if not os.path.exists(events_file):
            open(events_file, "a").close()

        if tool in SAFE_TOOLS:
            with open(events_file, "a") as f:
                if tool == "AskUserQuestion":
                    # 사용자 선택이 필요한 상황 → 부니에 확인 요청 버블 표시
                    f.write(json.dumps({"type": "ask_user", "message": ""}) + "\n")
                else:
                    f.write(json.dumps({"type": "tool_use", "tool": tool}) + "\n")
        elif _skip_gate(tool, perm_mode):
            # Claude가 이미 자동 승인하는 모드 — 승인 게이트 없이 tool_use만 기록
            with open(events_file, "a") as f:
                f.write(json.dumps({"type": "tool_use", "tool": tool}) + "\n")
        else:
            if tool == "Bash":
                message = tool_input.get("command", "")[:200]
            elif tool == "Write":
                path = tool_input.get("file_path", tool_input.get("path", ""))
                message = f"[파일 쓰기] {path}"[:200]
            elif tool in ("Edit", "MultiEdit"):
                path = tool_input.get("file_path", tool_input.get("path", ""))
                message = f"[파일 수정] {path}"[:200]
            else:
                first_val = next(iter(tool_input.values()), "") if tool_input else ""
                message = f"[{tool}] {first_val}"[:200] if first_val else tool

            req_id    = str(uuid.uuid4())[:8]
            resp_file = f"/tmp/claude-companion-decision-{req_id}"

            with open(events_file, "a") as f:
                f.write(json.dumps({
                    "type":    "permission_request",
                    "id":      req_id,
                    "tool":    tool,
                    "message": message,
                    "ts":      time.time()
                }) + "\n")

            approved = True
            for _ in range(120):
                if os.path.exists(resp_file):
                    try:
                        decision = open(resp_file).read().strip()
                        os.remove(resp_file)
                        approved = (decision != "deny")
                    except Exception:
                        pass
                    break
                time.sleep(0.5)

            if not approved:
                print(json.dumps({"decision": "block", "reason": "사용자가 거부했습니다."}))
                sys.exit(2)

            with open(events_file, "a") as f:
                f.write(json.dumps({"type": "tool_use", "tool": tool}) + "\n")

        # 컨텍스트 사용량 계산
        transcript_path = d.get("transcript_path", "")
        if transcript_path and os.path.exists(transcript_path):
            input_tokens     = None
            session_start_ts = None
            try:
                with open(transcript_path, "rb") as tf:
                    tf.seek(0, 2)
                    size = tf.tell()
                    tf.seek(max(0, size - 32768))
                    chunk = tf.read().decode("utf-8", errors="ignore")
                lines = chunk.splitlines()
                for line in reversed(lines):
                    try:
                        ev = json.loads(line)
                        usage = ev.get("message", {}).get("usage", {})
                        if "input_tokens" in usage:
                            input_tokens = (
                                usage.get("input_tokens", 0) +
                                usage.get("cache_read_input_tokens", 0) +
                                usage.get("cache_creation_input_tokens", 0)
                            )
                            break
                    except Exception:
                        continue
                if session_id and session_id != "legacy":
                    for line in lines:
                        try:
                            ev = json.loads(line)
                            if ev.get("sessionId") == session_id and ev.get("timestamp"):
                                session_start_ts = ev["timestamp"]
                                break
                        except Exception:
                            continue
                    if not session_start_ts:
                        with open(transcript_path, "rb") as tf:
                            head = tf.read(8192).decode("utf-8", errors="ignore")
                        for line in head.splitlines():
                            try:
                                ev = json.loads(line)
                                if ev.get("sessionId") == session_id and ev.get("timestamp"):
                                    session_start_ts = ev["timestamp"]
                                    break
                            except Exception:
                                continue
            except Exception:
                pass

            if input_tokens is not None:
                percent = min(100.0, round(input_tokens / 200_000 * 100, 1))
            else:
                percent = min(100.0, round(os.path.getsize(transcript_path) / 800_000 * 100, 1))

            event = {"type": "usage", "percent": percent}
            if session_start_ts:
                event["sessionStartTs"] = session_start_ts
            with open(events_file, "a") as f:
                f.write(json.dumps(event) + "\n")

except Exception:
    pass
PYEOF

write_script companion-posttool.py << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os

BUNI_PORT = 58765


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    d = json.load(sys.stdin)
    session_id  = d.get("session_id", "") or "legacy"
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    if is_remote:
        _send_tcp({"type": "tool_done", "session_id": session_id})
    else:
        with open(events_file, "a") as f:
            f.write('{"type":"tool_done"}\n')
except Exception:
    pass
PYEOF

write_script companion-notification.py << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os, time

BUNI_PORT = 58765


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    d = json.load(sys.stdin)
    session_id  = d.get("session_id", "") or "legacy"
    msg         = d.get("message", "알림")[:120]
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))
    event       = {"type": "notification", "message": msg, "ts": time.time()}

    if is_remote:
        event["session_id"] = session_id
        _send_tcp(event)
    else:
        with open(events_file, "a") as f:
            f.write(json.dumps(event) + "\n")
except Exception:
    pass
PYEOF

write_script companion-stop.py << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os

BUNI_PORT = 58765


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    d = json.load(sys.stdin)
    session_id  = d.get("session_id", "") or "legacy"
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))

    # 백그라운드 작업이 아직 돌고 있으면 완료가 아니라 "백그라운드 작업 중"으로 표시.
    # Stop 훅은 클로드 응답 한 턴이 끝날 때마다 오는데, run_in_background로 띄운
    # 작업은 그 뒤에도 계속 실행될 수 있어 완료 문구를 그대로 띄우면 오해를 준다.
    running = [t for t in (d.get("background_tasks") or [])
               if t.get("status") == "running"]

    if is_remote:
        if running:
            desc = running[0].get("description") or running[0].get("command", "")
            _send_tcp({"type": "background", "count": len(running),
                       "message": desc[:80], "session_id": session_id})
        else:
            _send_tcp({"type": "done", "session_id": session_id})
    else:
        with open(events_file, "a") as f:
            if running:
                desc = running[0].get("description") or running[0].get("command", "")
                f.write(json.dumps({
                    "type": "background",
                    "count": len(running),
                    "message": desc[:80],
                }) + "\n")
            else:
                f.write('{"type":"done"}\n')
except Exception:
    pass
PYEOF

write_script companion-prompt.py << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os, time

BUNI_PORT = 58765


def _send_tcp(payload):
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(("127.0.0.1", BUNI_PORT))
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        s.close()
    except Exception:
        pass


try:
    d = json.load(sys.stdin)
    session_id  = d.get("session_id", "") or "legacy"
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))
    event       = {"type": "thinking", "ts": time.time()}

    if is_remote:
        event["session_id"] = session_id
        _send_tcp(event)
    else:
        with open(events_file, "a") as f:
            f.write(json.dumps(event) + "\n")
except Exception:
    pass
PYEOF

echo ""
echo "▶ ~/.claude/settings.json 에 훅 등록 중..."

python3 - "$SETTINGS_FILE" "$HOOKS_DIR" << 'PYEOF'
import json, os, sys

settings_path, hooks_dir = sys.argv[1], sys.argv[2]

settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except Exception:
        settings = {}

def make_hook(script):
    return {"type": "command", "command": f"python3 {hooks_dir}/{script}; exit 0"}

additions = [
    ("PreToolUse",       "companion-pretool.py"),
    ("PostToolUse",      "companion-posttool.py"),
    ("Notification",     "companion-notification.py"),
    ("Stop",             "companion-stop.py"),
    ("UserPromptSubmit", "companion-prompt.py"),
]

hooks = settings.get("hooks", {})
for event, script in additions:
    prev = [
        entry for entry in hooks.get(event, [])
        if not any("companion-" in h.get("command", "")
                   for h in entry.get("hooks", []))
    ]
    prev.append({"matcher": "", "hooks": [make_hook(script)]})
    hooks[event] = prev
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, sort_keys=True, ensure_ascii=False)

print("✓ settings.json 업데이트 완료")
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 설치 완료!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "로컬 쪽도 준비됐는지 확인하세요:"
echo "  1. 로컬 맥/윈도우에서 Buni 앱을 한 번 실행한 적 있어야 합니다"
echo "     (VS Code settings.json에 remote.SSH.extraArgs 포트 포워딩이 자동 추가됨)"
echo "  2. VS Code(Cursor 등)로 이 호스트에 새로 SSH 접속하세요"
echo "     (이미 접속 중이었다면 포트 포워딩 설정 반영을 위해 재접속 필요)"
echo "  3. 이 호스트에서 claude 명령을 실행하면 로컬 Buni에 자동으로 나타납니다"
