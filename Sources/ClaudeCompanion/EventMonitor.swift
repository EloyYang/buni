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
    private var timer:      DispatchSourceTimer?
    private var fileOffset      = 0
    private var claudeWasRunning = false
    private var isInitialCheck   = true   // 앱 시작 시 이미 실행 중인 경우 구분

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
            self?.checkProcess()   // claude 프로세스 감시
            self?.pollFile()       // 상세 이벤트 파일 폴링
        }
        t.resume()
        timer = t
    }

    // MARK: - 프로세스 감시

    private func checkProcess() {
        let running = isClaudeRunning()
        let wasInitial = isInitialCheck
        isInitialCheck = false

        guard running != claudeWasRunning else { return }
        claudeWasRunning = running

        if running {
            DispatchQueue.main.async {
                // 진짜 새 세션일 때만 리셋 (앱 시작 시 이미 실행 중이면 복원값 유지)
                if !wasInitial {
                    self.controller.usagePercent = 0
                }
                self.controller.sessionStart = Date()
                self.controller.onShowRequest?()
                self.controller.update(to: .ready)
            }
        } else {
            // claude가 종료됨 → 캐릭터 숨김
            DispatchQueue.main.async {
                self.controller.sessionStart = nil
            }
            controller.update(to: .idle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.controller.onHideRequest?()
            }
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
            controller.update(to: .toolUse(formatToolName(event.tool ?? "tool")))
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
