import Foundation
import Darwin

private struct ClaudeEvent: Decodable {
    let type: String
    let tool: String?
    let message: String?
    let percent: Double?
    let id: String?
    let sessionStartTs: String?
    let ts: Double?   // Unix timestamp — thinking 이벤트 신선도 판단용
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
    /// 처리한 이벤트 순번 — 지연 전환이 최신 상태를 덮어쓰지 않도록 검증용
    private var eventSeq      = 0

    /// 아직 끝나지 않은 도구 실행 수 (tool_use 발생 - tool_done 도착).
    /// 0보다 크면 오래 걸리는 도구가 실제로 돌고 있는 것이라 이벤트가 없어도 작업 중이다.
    private var pendingTools  = 0

    /// 실행 중인 도구가 없는데 이 시간(초)만큼 새 이벤트가 없으면 대기 상태로 되돌린다.
    /// 훅이 누락되거나 세션이 조용히 끝났을 때 "도구 실행 중" 버블이 굳는 것을 방지.
    private let idleFallbackSeconds: TimeInterval = 300

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
            // 파일 생성 후 90초 이내: 처음부터 읽어 세션 시작 초반 이벤트 누락 방지
            // 90초 초과(오래된 세션): 끝에서 1KB 되돌아가 읽기
            //   — Buni 재시작 시 앱 초기화(~2s) 동안 쓰인 이벤트를 fileOffset=size로 놓치는 문제 방지
            let creationAge = (attrs[FileAttributeKey.creationDate] as? Date)
                .map { Date().timeIntervalSince($0) } ?? 9999
            fileOffset = creationAge < 90.0 ? 0 : max(0, size - 1024)
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
            // 한도 창이 새로 시작됐거나 아직 한도 전이면 숨김 상태 해제
            // (다음 한도 도달 때 안내 버블이 다시 뜨도록)
            if self.controller.serverResetsAt != resetsAt || utilization < 100 {
                self.controller.limitNoticeDismissed = false
            }
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
        let quietFor = Date().timeIntervalSince(lastEventDate)

        // 진행 중인 작업이 없는데 작업 상태로 남아 있으면 대기 상태로 되돌린다.
        // 오래 걸리는 도구가 실행 중(tool_use 후 tool_done 미도착)이면 이벤트가
        // 없는 게 정상이므로 건드리지 않는다.
        if pendingTools == 0, quietFor > idleFallbackSeconds {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch self.controller.state {
                case .thinking, .toolUse, .toolRead:
                    self.controller.update(to: .ready)
                default:
                    break   // 완료·권한·알림 버블은 사용자가 확인해야 하므로 유지
                }
            }
        }

        guard quietFor > 1800 else { return }
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

        // 뒤늦게 도착하는 지연 전환이 최신 이벤트를 덮어쓰지 않도록 순번을 올린다
        eventSeq += 1

        switch event.type {
        case "tool_use":
            // 과거 이벤트 재생으로 이미 끝난 도구 실행이 되살아나는 것 방지
            if isReplaying { break }
            pendingTools += 1
            let raw      = (event.tool ?? "tool").lowercased()
            let toolName = formatToolName(raw)
            let isRead   = ["read", "grep", "websearch", "webfetch", "glob"].contains(raw)
            let nextState: CompanionState = isRead ? .toolRead(toolName) : .toolUse(toolName)
            if case .ready = controller.state {
                let seq = eventSeq
                controller.update(to: .thinking)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    // 그 사이 다른 이벤트(tool_done 등)가 오면 전환을 취소 —
                    // 취소하지 않으면 도구 이름 버블이 그대로 굳는다
                    guard let self, self.eventSeq == seq,
                          case .thinking = self.controller.state else { return }
                    self.controller.update(to: nextState)
                }
            } else {
                controller.update(to: nextState)
            }
        case "tool_done":
            if isReplaying { break }
            pendingTools = max(0, pendingTools - 1)
            controller.update(to: .thinking)  // 도구 완료 후 항상 thinking(타이핑)으로 복귀
        case "thinking":
            // 30초 이내의 이벤트는 replay 중에도 처리 — 새 세션 시작 시 토큰 소비 구간부터 모션 적용
            let isStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && isStale { break }
            pendingTools = 0   // 새 턴 시작 — 이전 턴에서 남은 카운트 정리
            switch controller.state {
            case .ready, .completed:
                controller.update(to: .thinking)
            default:
                break
            }

        case "done":
            if isReplaying { break }   // 과거 done 재생 시 세션 조기 제거 방지
            pendingTools = 0
            controller.update(to: .completed)
        case "notification":
            let notifStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && notifStale { break }
            if case .permission = controller.state, controller.pendingPermissionId == nil { break }
            controller.update(to: .notification(event.message ?? "알림"), autohideAfter: 5)
        case "permission":
            if isReplaying { break }   // 과거 이벤트 재생으로 지난 권한 버블이 되살아나는 것 방지
            controller.update(to: .permission(event.message ?? "권한 요청"))
        case "ask_user":
            if isReplaying { break }   // 이미 답한 확인 요청이 재시작 때 다시 뜨는 것 방지
            let msg = event.message ?? "터미널에서 선택해 주세요"
            DispatchQueue.main.async {
                self.controller.pendingPermissionId = nil
                self.controller.update(to: .permission(msg))
            }
        case "permission_request":
            let permStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && permStale { break }
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
        // MCP 도구는 mcp__<서버>__<도구> 형태라 그대로 쓰면 말풍선이 지저분해진다
        if raw.hasPrefix("mcp__") {
            let parts = raw.components(separatedBy: "__")
            let tool  = parts.count > 2 ? parts[2...].joined(separator: " ") : raw
            return "\(tool.replacingOccurrences(of: "_", with: " ")) 실행 중"
        }
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
