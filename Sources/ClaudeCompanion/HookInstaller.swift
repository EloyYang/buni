import Foundation

/// 앱 최초 실행 시 Claude Code 훅 스크립트를 ~/.claude/ 에 자동 설치하고
/// ~/.claude/settings.json 에 hook 엔트리를 추가한다.
/// 이미 설치된 경우 스킵 (멱등). 기존 스크립트 파일은 덮어쓰지 않아 사용자 커스터마이징을 보호.
enum HookInstaller {

    static func ensureInstalled() {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        if !isInstalled(at: settingsURL) {
            do {
                try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                try writeScripts(to: claudeDir)
                try patchSettings(at: settingsURL, hookDir: claudeDir.path)
            } catch {
                // 훅 설치 실패해도 Buni는 동작 — 무시
            }
        }

        // VS Code SSH RemoteForward 설정은 매번 체크 (기존 설치 사용자 포함)
        patchVSCodeSettings()
    }

    // MARK: - VS Code settings.json 패치

    private static func patchVSCodeSettings() {
        let vscodeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User")
        guard FileManager.default.fileExists(atPath: vscodeDir.path) else { return }

        let settingsURL = vscodeDir.appendingPathComponent("settings.json")

        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        var args = settings["remote.SSH.extraArgs"] as? [String] ?? []

        // 이미 설정돼 있으면 스킵 (args가 비어 있으면 0..<(count-1) 이 음수 범위가 되어 크래시하므로 가드)
        if args.count >= 2 {
            for i in 0..<(args.count - 1) where args[i] == "-R" {
                if args[i + 1] == "58765:localhost:58765" { return }
            }
        }

        args.append(contentsOf: ["-R", "58765:localhost:58765"])
        settings["remote.SSH.extraArgs"] = args

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted]) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - 설치 여부 확인

    private static func isInstalled(at settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return pre.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains { h in
                (h["command"] as? String)?.contains("companion-pretool") == true
            } ?? false
        }
    }

    // MARK: - 스크립트 파일 작성

    private static func writeScripts(to dir: URL) throws {
        let scripts: [(String, String)] = [
            ("companion-pretool.py",      pretoolScript),
            ("companion-posttool.py",     posttoolScript),
            ("companion-notification.py", notificationScript),
            ("companion-stop.py",         stopScript),
            ("companion-prompt.py",       promptScript),
        ]
        let fm = FileManager.default
        for (name, content) in scripts {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { continue }   // 기존 파일 보호
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - settings.json 패치

    private static func patchSettings(at url: URL, hookDir: String) throws {
        var settings: [String: Any]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        func makeHook(_ script: String) -> [String: Any] {
            ["type": "command", "command": "python3 \(hookDir)/\(script); exit 0"]
        }

        let additions: [(String, String)] = [
            ("PreToolUse",       "companion-pretool.py"),
            ("PostToolUse",      "companion-posttool.py"),
            ("Notification",     "companion-notification.py"),
            ("Stop",             "companion-stop.py"),
            ("UserPromptSubmit", "companion-prompt.py"),
        ]

        var existing = settings["hooks"] as? [String: Any] ?? [:]
        for (event, script) in additions {
            let newEntry: [String: Any] = ["matcher": "", "hooks": [makeHook(script)]]
            var prev = (existing[event] as? [[String: Any]] ?? [])
                .filter { entry in
                    !((entry["hooks"] as? [[String: Any]])?.contains { h in
                        (h["command"] as? String)?.contains("companion-") == true
                    } ?? false)
                }
            prev.append(newEntry)
            existing[event] = prev
        }
        settings["hooks"] = existing

        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 내장 스크립트

    private static let pretoolScript = #"""
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
"""#

    private static let posttoolScript = #"""
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
"""#

    private static let notificationScript = #"""
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
"""#

    private static let stopScript = #"""
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
        _send_tcp({"type": "done", "session_id": session_id})
    else:
        with open(events_file, "a") as f:
            f.write('{"type":"done"}\n')
except Exception:
    pass
"""#

    private static let promptScript = #"""
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
"""#
}
