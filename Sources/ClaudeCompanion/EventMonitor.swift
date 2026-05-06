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
    static let eventFile = "/tmp/claude-companion-events.jsonl"

    private let queue     = DispatchQueue(label: "claude.companion.events", qos: .background)
    private var timer:       DispatchSourceTimer?
    private var planTimer:   DispatchSourceTimer?
    private var serverTimer: DispatchSourceTimer?
    private static let serverUsageFile = "/tmp/claude-companion-plan-usage.json"
    private static let fetchScript = NSHomeDirectory() + "/.claude/companion-fetch-usage.py"
    private var fileOffset      = 0
    private var claudeWasRunning = false
    private var isInitialCheck   = true   // 앱 시작 시 이미 실행 중인 경우 구분
    private var hideTask:        DispatchWorkItem?

    init(controller: CompanionController) {
        self.controller = controller
        if !FileManager.default.fileExists(atPath: Self.eventFile) {
            FileManager.default.createFile(atPath: Self.eventFile, contents: nil)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.eventFile),
           let size  = attrs[.size] as? Int {
            fileOffset = size   // 새 이벤트만 읽음
        }
        // 앱 재시작 시 파일에서 마지막 usage 값 복원
        restoreLastUsage()
    }

    private func restoreLastUsage() {
        guard let text = try? String(contentsOfFile: Self.eventFile, encoding: .utf8) else { return }
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
            self?.checkProcess()
            self?.pollFile()
        }
        t.resume()
        timer = t

        // 플랜 사용량: 60초 간격으로 JSONL 파일 집계 (로컬 추정)
        let pt = DispatchSource.makeTimerSource(queue: queue)
        pt.schedule(deadline: .now(), repeating: .seconds(60))
        pt.setEventHandler { [weak self] in self?.updatePlanUsage() }
        pt.resume()
        planTimer = pt

        // 서버 플랜 사용량: 시작 즉시 + 5분마다 Python 스크립트로 가져옴
        let st = DispatchSource.makeTimerSource(queue: queue)
        st.schedule(deadline: .now() + 2, repeating: .seconds(300))
        st.setEventHandler { [weak self] in self?.fetchServerUsage() }
        st.resume()
        serverTimer = st
    }

    // MARK: - 서버 플랜 사용량 (claude.ai API)

    /// playwright가 설치된 python3 경로를 반환
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
        // 스크립트가 없으면 스킵
        guard FileManager.default.fileExists(atPath: Self.fetchScript) else { return }

        // playwright가 있는 python3로 실행
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.findPython3())
        proc.arguments = [Self.fetchScript]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()

        // 스크립트 완료 후 파일 읽기 (최대 30초 대기)
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

    // MARK: - 플랜 일일 사용량 (로컬 추정)

    private func updatePlanUsage() {
        let tokens  = TokenUsageReader.readToday()
        let limitK  = ShortcutStore.shared.planDailyLimitK
        let limit   = limitK * 1_000
        let percent = limit > 0
            ? min(100, Double(tokens.total) / Double(limit) * 100)
            : 0
        DispatchQueue.main.async {
            self.controller.planTokensToday  = tokens.total
            self.controller.planUsagePercent = percent
        }
    }

    // MARK: - 프로세스 감시

    private func checkProcess() {
        let running = isClaudeRunning()
        let wasInitial = isInitialCheck
        isInitialCheck = false

        guard running != claudeWasRunning else { return }
        claudeWasRunning = running

        if running {
            // 대기 중인 숨기기 취소 (세션 전환 등으로 잠깐 꺼졌다 켜지는 경우)
            hideTask?.cancel()
            hideTask = nil

            DispatchQueue.main.async {
                // 진짜 새 세션일 때만 리셋 (앱 시작 시 이미 실행 중이면 복원값 유지)
                if !wasInitial {
                    self.controller.usagePercent = 0
                }
                self.controller.sessionStart = Date()
                self.controller.onShowRequest?()
                // 시작 직후에는 응답 생성 중일 수 있으므로 thinking으로 시작
                self.controller.update(to: .thinking)
            }
        } else {
            // 2초 디바운스: 세션 전환 등으로 프로세스가 잠깐 사라졌다 복귀하면 숨기지 않음
            let task = DispatchWorkItem { [weak self] in
                guard let self, !self.isClaudeRunning() else { return }
                DispatchQueue.main.async {
                    self.controller.sessionStart = nil
                }
                self.controller.update(to: .idle)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.controller.onHideRequest?()
                }
            }
            hideTask = task
            queue.asyncAfter(deadline: .now() + 2.0, execute: task)
        }
    }

    /// sysctl로 커널 프로세스 목록을 직접 읽음 — 서브프로세스 없이 마이크로초 단위로 완료
    private func isClaudeRunning() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var len = 0
        guard sysctl(&mib, 4, nil, &len, nil, 0) == 0, len > 0 else { return false }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs  = [kinfo_proc](repeating: kinfo_proc(), count: len / stride + 1)
        guard sysctl(&mib, 4, &procs, &len, nil, 0) == 0 else { return false }

        let myPid = getpid()
        let count = len / stride

        for i in 0..<count {
            let p = procs[i].kp_proc
            guard p.p_pid > 0, p.p_pid != myPid else { continue }

            // p_comm: (Int8 × 17) 튜플 → String
            let name: String = withUnsafeBytes(of: p.p_comm) { buf in
                let bytes = buf.prefix(while: { $0 != 0 })
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }
            if name == "claude" { return true }
        }
        return false
    }

    // MARK: - 파일 폴링 (도구 사용·권한 등 상세 이벤트)

    private func pollFile() {
        guard let fh = FileHandle(forReadingAtPath: Self.eventFile) else { return }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: UInt64(fileOffset))
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        fileOffset += data.count

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
            let toolName = formatToolName(event.tool ?? "tool")
            if case .ready = controller.state {
                // 새 사용자 턴 시작: 잠깐 thinking 표시 후 tool 이름으로 전환
                controller.update(to: .thinking)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, case .thinking = self.controller.state else { return }
                    self.controller.update(to: .toolUse(toolName))
                }
            } else {
                controller.update(to: .toolUse(toolName))
            }
        case "tool_done":
            controller.update(to: .thinking)
        case "done":
            controller.update(to: .ready)
        case "notification":
            controller.update(to: .notification(event.message ?? "알림"), autohideAfter: 5)
        case "permission":
            controller.update(to: .permission(event.message ?? "권한 요청"))
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
                    // 트랜스크립트에서 읽은 정확한 세션 시작 시각으로 업데이트
                    if let tsStr = event.sessionStartTs,
                       let tsDate = Self.parseISO8601(tsStr) {
                        // 현재 sessionStart보다 더 이른 시각이면 교체 (더 정확)
                        if self.controller.sessionStart == nil ||
                           tsDate < self.controller.sessionStart! {
                            self.controller.sessionStart = tsDate
                        }
                    }
                    // 컨텍스트 압축 감지: 30%p 이상 급락 시 세션 리셋
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

    // "2026-04-18T13:50:58.153Z" 형식 파싱
    private static func parseISO8601(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }
}
