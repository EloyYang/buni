#!/bin/bash
# Claude Companion 설치 스크립트
# 빌드 후 Claude Code 훅을 설정하고 앱을 실행합니다

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS_FILE="/tmp/claude-companion-events.jsonl"
HOOKS_DIR="$HOME/.claude"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Companion 설치"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. 빌드
echo ""
echo "▶ Swift 빌드 중..."
cd "$SCRIPT_DIR"
swift build -c release
BINARY="$SCRIPT_DIR/.build/release/ClaudeCompanion"
echo "✓ 빌드 완료: $BINARY"

# 2. 이벤트 파일 초기화
touch "$EVENTS_FILE"
echo "✓ 이벤트 파일: $EVENTS_FILE"

# 3. 훅 헬퍼 스크립트 설치
mkdir -p "$HOOKS_DIR"

cat > "$HOOKS_DIR/companion-pretool.py" << 'PYEOF'
#!/usr/bin/env python3
import sys, json
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "tool")
    line = json.dumps({"type": "tool_use", "tool": tool})
    with open("/tmp/claude-companion-events.jsonl", "a") as f:
        f.write(line + "\n")
except Exception:
    pass
PYEOF

cat > "$HOOKS_DIR/companion-posttool.py" << 'PYEOF'
#!/usr/bin/env python3
import sys, json
try:
    sys.stdin.read()  # consume stdin
    with open("/tmp/claude-companion-events.jsonl", "a") as f:
        f.write('{"type":"tool_done"}\n')
except Exception:
    pass
PYEOF

cat > "$HOOKS_DIR/companion-notification.py" << 'PYEOF'
#!/usr/bin/env python3
import sys, json
try:
    d = json.load(sys.stdin)
    msg = d.get("message", "알림")[:120]
    line = json.dumps({"type": "notification", "message": msg})
    with open("/tmp/claude-companion-events.jsonl", "a") as f:
        f.write(line + "\n")
except Exception:
    pass
PYEOF

cat > "$HOOKS_DIR/companion-stop.py" << 'PYEOF'
#!/usr/bin/env python3
import sys
try:
    sys.stdin.read()
    with open("/tmp/claude-companion-events.jsonl", "a") as f:
        f.write('{"type":"done"}\n')
except Exception:
    pass
PYEOF

chmod +x "$HOOKS_DIR"/companion-*.py
echo "✓ 훅 헬퍼 스크립트 설치됨: $HOOKS_DIR/companion-*.py"

# 4. Claude Code settings.json에 훅 추가
SETTINGS="$HOOKS_DIR/settings.json"
python3 << PYEOF
import json, os, sys

settings_path = os.path.expanduser("~/.claude/settings.json")
hooks_dir = os.path.expanduser("~/.claude")

# 기존 설정 로드
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            settings = {}
    # 백업
    with open(settings_path + ".companion-backup", "w") as f:
        json.dump(settings, f, indent=2)
    print(f"✓ 기존 설정 백업: {settings_path}.companion-backup")
else:
    settings = {}

def hook(script):
    return {
        "type": "command",
        "command": f"python3 {hooks_dir}/{script}; exit 0"
    }

new_hooks = {
    "PreToolUse": [{"matcher": "", "hooks": [hook("companion-pretool.py")]}],
    "PostToolUse": [{"matcher": "", "hooks": [hook("companion-posttool.py")]}],
    "Notification": [{"matcher": "", "hooks": [hook("companion-notification.py")]}],
    "Stop": [{"matcher": "", "hooks": [hook("companion-stop.py")]}],
}

# 기존 훅과 병합 (companion 항목 교체)
existing = settings.get("hooks", {})
for event, entries in new_hooks.items():
    # 이전 companion 훅 제거 후 새 것 추가
    prev = [e for e in existing.get(event, [])
            if not any("companion-" in str(h) for h in e.get("hooks", []))]
    existing[event] = prev + entries
settings["hooks"] = existing

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print(f"✓ Claude Code 훅 설정 완료: {settings_path}")
PYEOF

# 5. 기존 인스턴스 종료 후 재시작
echo ""
echo "▶ Claude Companion 시작 중..."
pkill -f "ClaudeCompanion" 2>/dev/null || true
sleep 0.4
"$BINARY" &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ 설치 완료!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  화면 오른쪽 상단에 Claude 캐릭터가 나타납니다."
echo "  Claude를 사용하면 자동으로 애니메이션됩니다."
echo ""
echo "  종료: pkill ClaudeCompanion"
echo "  재시작: $BINARY &"
echo ""
