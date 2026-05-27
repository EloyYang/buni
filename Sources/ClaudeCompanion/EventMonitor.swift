import Foundation
import Darwin

private struct ClaudeEvent: Decodable {
    let type: String
    let tool: String?
    let message: String?
    let percent: Double?
    let id: String?
    let sessionStartTs: String?
}

class EventMonitor {
    private let controller: CompanionController
    let eventFile: String

    private let queue = DispatchQueue(label: "claude.companion.events", qos: .background)
    private var timer:       DispatchSourceTimer?
    private var serverTimer: DispatchSourceTimer?
    private static let serverUsageFile = "/tmp/claude-companion-plan-usage.json"
    private static let fetchScript = NSHomeDirectory() + "/.claude/companion-fetch-usage.py"

    private var fileOffset    = 0
    private var lastEventDate = Date()
    private var isReplaying   = true   // 첫 poll에서 기존 이벤트 재생 중 — done 이벤트 건너뜀

    /// done 이벤트 + 30초 무활동 시, 또는 90초 강제 타임아웃 시 호출
    var onSessionEnded: (() -> Void)?

    // ── 레거시 단일 파일 경로 (하위 호환)
    static let legacyEventFile = "/tmp/claude-companion-events.jsonl"

    init(controller: CompanionController, eventFile: String) {
        self.controller = controller
        self.eventFile  = eventFile

        if !FileManager.default.fileExists(atPath: eventFile) {
            FileManager.default.createFile(atPath: eventFile, contents: nil)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: eventFile),
           let size  = attrs[.size] as? Int {
            // 파일 생성 후 90초 이내: 처음부터 읽어 세션 시작 초반(파일 탐색 등) 이벤트 누락 방지
            // 수정 날짜 대신 생성 날짜 사용 — 수정 날짜는 이벤트가 계속 쓰일수록 갱신되어 신뢰 불가
            // 90초 초과(오래된 세션): 끝에서부터 읽어 과거 이벤트 재생 방지
            let creationAge = (attrs[FileAttributeKey.creationDate] as? Date)
                .map { Date().timeIntervalSince($0) } ?? 9999
            fileOffset = creationAge < 90.0 ? 0 : size
        }
        restoreLastUsage()
    }

    private func restoreLastUsage() {
        guard let text = try? String(contentsOfFile: eventFile, encoding: .utf8) else { return }
        let lastUsage = text.components(separatedBy: "\n")
            .reversed()
            .first(where: { $0.contains("\"usage\"") })
        guard let line = lastUsage,
              let data  = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data),
              let pct   = event.percent else { return }
        controller.usagePercent = pct
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            self?.pollFile()
            self?.checkStaleness()
        }
        t.resume()
        timer = t

        let st = DispatchSource.makeTimerSource(queue: queue)
        st.schedule(deadline: .now() + 2, repeating: .seconds(300))
        st.setEventHandler { [weak self] in
            self?.fetchServerUsage()
            self?.updateMonthlyTokens()
        }
        st.resume()
        serverTimer = st

        queue.async { [weak self] in self?.updateMonthlyTokens() }
    }

    func stop() {
        timer?.cancel();       timer = nil
        serverTimer?.cancel(); serverTimer = nil
    }

    private func updateMonthlyTokens() {
        let total = TokenUsageReader.readThisMonth()
        DispatchQueue.main.async { self.controller.monthlyTokens = total }
    }

    // MARK: - 서버 플랜 사용량

    private static func findPython3() -> String {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/usr/bin/python3"
    }

    private func fetchServerUsage() {
        guard FileManager.default.fileExists(atPath: Self.fetchScript) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.findPython3())
        proc.arguments = [Self.fetchScript]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.readServerUsageFile()
        }
    }

    private func readServerUsageFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.serverUsageFile)),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let utilization = obj["utilization"] as? Double ?? 0
        let resetsAt: Date? = (obj["resets_at"] as? String).flatMap { s in
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.date(from: s) ?? {
                fmt.formatOptions = [.withInternetDateTime]
                return fmt.date(from: s)
            }()
        }
        DispatchQueue.main.async {
            self.controller.serverUtilization = utilization
            self.controller.serverResetsAt    = resetsAt
        }
    }

    // MARK: - 세션 종료 감지

    /// 파일이 30분 이상 변화 없으면 크래시·강제종료로 간주하여 세션 종료
    /// 정상 종료는 AppDelegate의 프로세스 감지가 담당.
    /// Claude가 유저 입력을 기다리는 동안(idle)에는 이벤트가 없으므로
    /// 짧은 타임아웃은 false positive를 유발함.
    private func checkStaleness() {
        guard Date().timeIntervalSince(lastEventDate) > 1800 else { return }
        fireSessionEnded()
    }

    private func fireSessionEnded() {
        stop()
        DispatchQueue.main.async { [weak self] in self?.onSessionEnded?() }
    }

    // MARK: - 파일 폴링

    private func pollFile() {
        defer { isReplaying = false }   // 첫 poll 완료 후 재생 모드 해제
        guard let fh = FileHandle(forReadingAtPath: eventFile) else { return }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: UInt64(fileOffset))
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        fileOffset    += data.count
        lastEventDate  = Date()

        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            handleEvent(line)
        }
    }

    private func handleEvent(_ json: String) {
        guard let data  = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data)
        else { return }

        switch event.type {
        case "tool_use":
            let raw      = (event.tool ?? "tool").lowercased()
            let toolName = formatToolName(raw)
            let isRead   = ["read", "grep", "websearch", "webfetch", "glob"].contains(raw)
            let nextState: CompanionState = isRead ? .toolRead(toolName) : .toolUse(toolName)
            if case .ready = controller.state {
                controller.update(to: .thinking)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, case .thinking = self.controller.state else { return }
                    self.controller.update(to: nextState)
                }
            } else {
                controller.update(to: nextState)
            }
        case "tool_done":
            controller.update(to: .thinking)  // 도구 완료 후 항상 thinking(타이핑)으로 복귀
        case "thinking":
            if isReplaying { break }   // 과거 thinking 이벤트 재생 건너뜀
            switch controller.state {
            case .ready, .completed:
                controller.update(to: .thinking)
            default:
                break
            }

        case "done":
            if isReplaying { break }   // 과거 done 재생 시 세션 조기 제거 방지
            controller.update(to: .completed)
        case "notification":
            // ask_user 상태 중(pendingPermissionId == nil인 permission)에는 덮어쓰지 않음
            if case .permission = controller.state, controller.pendingPermissionId == nil { break }
            controller.update(to: .notification(event.message ?? "알림"), autohideAfter: 5)
        case "permission":
            controller.update(to: .permission(event.message ?? "권한 요청"))
        case "ask_user":
            let msg = event.message ?? "터미널에서 선택해 주세요"
            DispatchQueue.main.async {
                self.controller.pendingPermissionId = nil
                self.controller.update(to: .permission(msg))
            }
        case "permission_request":
            if let reqId = event.id {
                if controller.alwaysApprove {
                    let file = "/tmp/claude-companion-decision-\(reqId)"
                    try? "approve".write(toFile: file, atomically: true, encoding: .utf8)
                } else {
                    let cmd = event.message ?? "명령"
                    DispatchQueue.main.async {
                        self.controller.pendingPermissionId = reqId
                        self.controller.update(to: .permission(cmd))
                    }
                }
            }
        case "usage":
            if let pct = event.percent {
                DispatchQueue.main.async {
                    if let tsStr = event.sessionStartTs,
                       let tsDate = Self.parseISO8601(tsStr) {
                        if self.controller.sessionStart == nil ||
                           tsDate < self.controller.sessionStart! {
                            self.controller.sessionStart = tsDate
                        }
                    }
                    let prev = self.controller.usagePercent
                    if prev > 20 && pct < prev - 30 {
                        self.controller.sessionStart = Date()
                    }
                    self.controller.usagePercent = pct
                }
            }
        default:
            break
        }
    }

    private func formatToolName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bash":      return "터미널 명령 실행 중"
        case "read":      return "파일 읽는 중"
        case "write":     return "파일 쓰는 중"
        case "edit":      return "파일 수정 중"
        case "glob":      return "파일 검색 중"
        case "grep":      return "코드 검색 중"
        case "websearch": return "웹 검색 중"
        case "webfetch":  return "페이지 읽는 중"
        case "todowrite": return "할 일 정리 중"
        default:          return "\(raw) 실행 중"
        }
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }
}
