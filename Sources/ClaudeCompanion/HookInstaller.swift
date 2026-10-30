import Foundation

/// 앱 최초 실행 시 Claude Code 훅 스크립트를 ~/.claude/ 에 자동 설치하고
/// ~/.claude/settings.json 에 hook 엔트리를 추가한다.
/// settings.json 패치는 멱등. 스크립트는 버전이 올라가면 자동 갱신한다(아래 scriptVersion).
enum HookInstaller {

    /// 훅 스크립트 내용 버전 — 스크립트를 고치면 반드시 올린다.
    /// 설치된 스크립트가 이 버전보다 낮으면 자동으로 새 내용으로 갱신해서,
    /// 이미 설치해 쓰던 사용자도 새 기능(예: 백그라운드 작업 추적)을 받게 된다.
    /// 갱신 전 원본은 <이름>.bak 으로 백업한다.
    static let scriptVersion = 6
    private static let versionMarker = "# buni-hook-version:"

    static func ensureInstalled() {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            // 스크립트는 매번 버전 확인 — 새 버전이면 갱신 (기존 설치 사용자 포함)
            try writeScripts(to: claudeDir)
            if !isInstalled(at: settingsURL) {
                try patchSettings(at: settingsURL, hookDir: claudeDir.path)
            }
        } catch {
            // 훅 설치 실패해도 Buni는 동작 — 무시
        }

        // VS Code SSH RemoteForward 설정은 매번 체크 (기존 설치 사용자 포함)
        patchVSCodeSettings()
    }

    // MARK: - VS Code settings.json 패치

    /// VS Code 및 형제 에디터(Insiders, Cursor, VSCodium)를 모두 찾아 각각 패치한다.
    /// 사용자가 어느 걸 SSH Remote에 쓰는지 알 수 없으니 설치돼 있는 건 다 처리.
    private static let vscodeVariantDirNames = ["Code", "Code - Insiders", "Cursor", "VSCodium"]

    private static func patchVSCodeSettings() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        for dirName in vscodeVariantDirNames {
            patchVSCodeSettings(userDir: appSupport.appendingPathComponent("\(dirName)/User"))
        }
    }

    private static func patchVSCodeSettings(userDir vscodeDir: URL) {
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
            if let existing = try? String(contentsOf: url, encoding: .utf8) {
                guard shouldUpgrade(existing) else { continue }
                // 갱신 전 원본 백업 — 직접 손본 내용이 있었다면 되살릴 수 있게
                let backup = dir.appendingPathComponent(name + ".bak")
                try? fm.removeItem(at: backup)
                try? fm.copyItem(at: url, to: backup)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// 설치된 스크립트를 새 내용으로 덮어써야 하는지 판단.
    /// 버전 표시가 없던 초기 버전은 부니가 쓴 스크립트가 맞을 때만(이벤트 파일 경로 포함)
    /// 갱신하고, 그 외 알 수 없는 내용은 사용자 스크립트로 보고 건드리지 않는다.
    private static func shouldUpgrade(_ existing: String) -> Bool {
        guard let range = existing.range(of: versionMarker) else {
            return existing.contains("claude-companion-events")
        }
        let rest = existing[range.upperBound...].prefix(while: { $0 != "\n" })
        let installed = Int(rest.trimmingCharacters(in: .whitespaces)) ?? 0
        return installed < scriptVersion
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
# buni-hook-version: 6
import sys, json, os, uuid, time
# 부니 스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 부니를 따로 만들지 않는다 — 스쿼드 전체를 팀장 부니 하나가 대신 보여 주고 알려 준다.
if os.environ.get("BUNI_TEAM_RUN"):
    sys.exit(0)

SAFE_TOOLS = {"Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch",
              "TodoRead", "NotebookRead", "AskUserQuestion"}
BUNI_PORT = 58765

# ── Claude 자체가 이미 자동 승인하는 모드인지 판정 ──────────────────────
# 클로드가 사용자에게 안 묻는 상황에서 부니만 승인 창을 띄우는 문제 방지.
# dontAsk: 허용 목록에 없는 건 클로드가 묻지 않고 거절한다 — 부니 스쿼드(사람이 없는 시간)이 쓰는 모드라
# 부니가 승인 창을 띄우고 60초씩 기다리면 안 된다. BUNI_TEAM_RUN 은 부니 스쿼드이 띄운 세션 표시.
AUTO_APPROVE_MODES = {"auto", "bypassPermissions", "dontAsk"}
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def _lang():
    """부니가 써 둔 표시 언어 ("ko"/"en"). 훅은 별도 프로세스라 파일로 받는다."""
    try:
        with open("/tmp/claude-companion-lang") as f:
            return "en" if f.read().strip() == "en" else "ko"
    except Exception:
        return "ko"


def _t(ko, en):
    return en if _lang() == "en" else ko


def _skip_gate(tool, perm_mode):
    if os.environ.get("BUNI_TEAM_RUN") or perm_mode in AUTO_APPROVE_MODES:
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
                    # 사용자 선택이 필요한 상황 → 부니에 확인 요청 버블 표시.
                    # 질문 내용까지 같이 보내야 터미널을 안 보고도 뭘 묻는지 알 수 있다.
                    qs = tool_input.get("questions") or []
                    q  = qs[0] if isinstance(qs, list) and qs and isinstance(qs[0], dict) else {}
                    question = str(q.get("question") or q.get("header") or "").strip()[:120]
                    if len(qs) > 1:
                        question = f"{question} (+{len(qs) - 1})"
                    f.write(json.dumps({"type": "ask_user", "message": question,
                                        "ts": time.time()}) + "\n")
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
                message = f"{_t('[파일 쓰기]', '[Write]')} {path}"[:200]
            elif tool in ("Edit", "MultiEdit"):
                path = tool_input.get("file_path", tool_input.get("path", ""))
                message = f"{_t('[파일 수정]', '[Edit]')} {path}"[:200]
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
                print(json.dumps({"decision": "block", "reason": _t("사용자가 거부했습니다.", "The user denied this.")}))
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
# buni-hook-version: 6
import sys, json, os, re
# 부니 스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 부니를 따로 만들지 않는다 — 스쿼드 전체를 팀장 부니 하나가 대신 보여 주고 알려 준다.
if os.environ.get("BUNI_TEAM_RUN"):
    sys.exit(0)

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


def _background_start(d):
    """run_in_background로 띄운 Bash면 부니가 추적할 정보를 만들어 준다.

    Stop 훅의 background_tasks는 턴이 끝나야 오기 때문에, 작업이 시작되는
    시점은 여기서만 알 수 있다. 도구 응답에 작업 ID와 출력 파일 경로가
    들어 있어(“Command running in background with ID: ... written to: ...”)
    부니가 그 파일로 종료 여부까지 확인할 수 있다.
    """
    if d.get("tool_name") != "Bash":
        return None
    tool_input = d.get("tool_input") or {}
    if not tool_input.get("run_in_background"):
        return None

    resp = d.get("tool_response")
    text = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)
    text = text or ""

    tid  = re.search(r"background with ID:\s*([A-Za-z0-9_-]+)", text)
    path = re.search(r"written to:\s*(\S+\.output)", text)
    desc = tool_input.get("description") or tool_input.get("command", "")
    return {
        "type":    "background_start",
        "id":      tid.group(1) if tid else "",
        "file":    path.group(1) if path else "",
        "message": desc[:80],
    }


try:
    d = json.load(sys.stdin)
    session_id  = d.get("session_id", "") or "legacy"
    events_file = f"/tmp/claude-companion-events-{session_id}.jsonl"
    is_remote   = bool(os.environ.get("SSH_CLIENT") or os.environ.get("SSH_TTY"))
    bg          = _background_start(d)

    if is_remote:
        _send_tcp({"type": "tool_done", "session_id": session_id})
        if bg:
            # 원격은 출력 파일이 원격에 있어 부니가 못 읽는다 — 경로는 비워 보낸다
            bg["file"] = ""
            bg["session_id"] = session_id
            _send_tcp(bg)
    else:
        with open(events_file, "a") as f:
            f.write('{"type":"tool_done"}\n')
            if bg:
                f.write(json.dumps(bg) + "\n")
except Exception:
    pass
"""#

    private static let notificationScript = #"""
#!/usr/bin/env python3
# buni-hook-version: 6
import sys, json, os, time
# 부니 스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 부니를 따로 만들지 않는다 — 스쿼드 전체를 팀장 부니 하나가 대신 보여 주고 알려 준다.
if os.environ.get("BUNI_TEAM_RUN"):
    sys.exit(0)

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
# buni-hook-version: 6
import sys, json, os
# 부니 스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 부니를 따로 만들지 않는다 — 스쿼드 전체를 팀장 부니 하나가 대신 보여 주고 알려 준다.
if os.environ.get("BUNI_TEAM_RUN"):
    sys.exit(0)

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
    # status는 pending/running/completed/failed/killed/paused 중 하나 —
    # 아직 안 끝난 것(running/pending/paused)을 모두 진행 중으로 본다.
    ACTIVE = ("running", "pending", "paused")
    running = [t for t in (d.get("background_tasks") or [])
               if t.get("status") in ACTIVE]
    # 작업 ID와 스크래치패드 경로를 함께 넘겨, 부니가 각 작업의 출력 파일로
    # 실제 종료 시점까지 확인할 수 있게 한다.
    ids  = [t.get("task_id") for t in running if t.get("task_id")]
    desc = ""
    if running:
        desc = running[0].get("description") or running[0].get("command", "") or ""

    payload = {
        "type":    "background",
        "count":   len(running),
        "message": desc[:80],
        "ids":     ids,
        "dir":     d.get("scratchpad_dir", "") or "",
    }

    if is_remote:
        if running:
            payload["session_id"] = session_id
            payload["dir"] = ""   # 원격 경로는 부니가 못 읽는다
            _send_tcp(payload)
        else:
            _send_tcp({"type": "done", "session_id": session_id})
    else:
        with open(events_file, "a") as f:
            if running:
                f.write(json.dumps(payload) + "\n")
            else:
                f.write('{"type":"done"}\n')
except Exception:
    pass
"""#

    private static let promptScript = #"""
#!/usr/bin/env python3
# buni-hook-version: 6
import sys, json, os, time
# 부니 스쿼드가 띄운 세션(BUNI_TEAM_RUN)은 부니를 따로 만들지 않는다 — 스쿼드 전체를 팀장 부니 하나가 대신 보여 주고 알려 준다.
if os.environ.get("BUNI_TEAM_RUN"):
    sys.exit(0)

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
