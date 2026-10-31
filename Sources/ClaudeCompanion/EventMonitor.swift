import Foundation
import Darwin

private struct ClaudeEvent: Decodable {
    let type: String
    let tool: String?
    let message: String?
    let count: Int?
    let percent: Double?
    let id: String?
    let sessionStartTs: String?
    let ts: Double?   // Unix timestamp — thinking 이벤트 신선도 판단용
    let file: String?      // background_start — 작업 출력 파일 경로
    let ids: [String]?     // background — 아직 돌고 있는 작업 ID 목록
    let dir: String?       // background — 세션 스크래치패드 경로
}

/// run_in_background로 띄워져 아직 돌고 있는 백그라운드 작업 하나
private struct BackgroundTask {
    let id: String
    /// Claude Code가 실시간 출력을 쓰는 파일. 비어 있으면(원격 세션 등) 추적 불가.
    var file: String
    var desc: String
}

class EventMonitor {
    private let controller: CompanionController
    let eventFile: String

    private let queue = DispatchQueue(label: "claude.companion.events", qos: .background)
    private var timer:       DispatchSourceTimer?
    private var serverTimer: DispatchSourceTimer?
    private var watcher:     DispatchSourceFileSystemObject?
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

    /// 지금 실행 중인(아직 tool_done이 안 온) 도구 이름 — "확인 대기" 추정에 쓴다.
    private var pendingToolName: String?
    /// 이번 도구 실행에 대해 "확인이 필요한 것 같다" 안내를 이미 띄웠는지
    private var waitHintShown = false
    /// 도구가 시작된 뒤 이만큼(초) 아무 이벤트도 없으면, 클로드가 확인 창을 띄우고
    /// 사용자를 기다리는 중으로 본다.
    ///
    /// 브라우저 사이트 권한("이 주소로 작업할까요?")이나 JavaScript 실행 확인처럼,
    /// 클로드가 PreToolUse 훅을 쏜 **뒤에** 자체 확인 창을 띄우는 경우가 있다.
    /// 그때는 훅 이벤트가 하나도 오지 않아(실측: 확인 창이 떠 있는 동안 기록 0건)
    /// 부니가 알 방법이 이것뿐이다. 도구가 조용히 멈춰 있다는 사실로 역추정한다.
    private let userWaitHintSeconds: TimeInterval = 20
    /// 확인 요청(ask_user·확인 대기 추정) 버블을 이만큼(초) 조용하면 정리한다.
    /// 이 버블은 승인 버튼이 없어 사용자가 터미널에서 답하는데, 답한 뒤에도
    /// 후속 훅 이벤트(tool_done 등)가 안 오는 경우가 있어 버블이 영영 남았다.
    private let askBubbleExpireSeconds: TimeInterval = 120
    /// 실행 중인 도구가 없는데 이 시간(초)만큼 새 이벤트가 없으면 대기 상태로 되돌린다.
    /// 훅이 누락되거나 세션이 조용히 끝났을 때 "도구 실행 중" 버블이 굳는 것을 방지.
    private let idleFallbackSeconds: TimeInterval = 300

    /// 출력 파일을 추적할 수 없는 백그라운드 작업(원격 세션, 구버전 훅)에만 쓰는
    /// 예비 타임아웃. 파일을 추적할 수 있으면 실제 종료 시점을 읽어서 판단하므로
    /// 이 값은 쓰이지 않는다.
    private let backgroundWorkStaleSeconds: TimeInterval = 90

    /// 아직 돌고 있는 백그라운드 작업 (id → 정보). queue에서만 접근한다.
    private var backgroundTasks: [String: BackgroundTask] = [:]
    /// Stop 훅이 백그라운드 작업 때문에 "완료" 표시를 미룬 상태 —
    /// 마지막 작업까지 끝나면 그때 완료 버블을 띄운다.
    private var completionDeferredByBackground = false

    /// 5시간 한도에 걸려 있는지 (queue에서만 접근하는 사본 — controller를 교차 스레드로 읽지 않기 위해)
    private var isLimitReachedSnapshot = false

    /// done(Stop 훅) 이벤트는 클로드가 한 번 응답을 마칠 때마다 매번 오므로,
    /// 그대로 바로 "완료했어요!"를 띄우면 아직 세션이 안 끝났는데(예: 클로드가
    /// 곧바로 다음 턴을 이어가는 경우) 중간에 완료 문구가 떴다 사라지는 것처럼
    /// 보인다. 잠깐 대기했다가, 그사이 새 작업(thinking/tool_use)이 시작되면
    /// 취소하고, 조용히 지나가면 그때 완료를 표시한다.
    private var pendingCompletionWork: DispatchWorkItem?
    private let completionDebounceSeconds: TimeInterval = 3.0

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
        // setup()과 showCompanion()이 둘 다 부르므로, 이미 돌고 있으면 타이머를 또 만들지 않는다
        // (예전에는 앞 타이머가 취소 못 하는 채로 남아 폴링이 두 배로 돌았다)
        guard timer == nil else { return }
        // 이벤트 파일에 줄이 덧붙으면 바로 읽는다 — 0.5초 폴링 대신 파일 변경 알림(vnode)을 쓴다.
        // 아래 타이머는 알림을 놓쳤을 때(파일 교체 등)와 오래 걸림·종료 판단용 안전망이라 느려도 된다.
        let fd = open(eventFile, O_EVTONLY)
        if fd >= 0 {
            let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                              eventMask: [.write, .extend],
                                                              queue: queue)
            w.setEventHandler { [weak self] in self?.pollFile() }
            w.setCancelHandler { close(fd) }
            w.resume()
            watcher = w
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // 파일 감시가 붙었으면 2초(판정 기준은 20초 이상), 못 붙었으면 예전처럼 0.5초
        let hasWatcher = watcher != nil
        t.schedule(deadline: .now(),
                   repeating: hasWatcher ? .seconds(2) : .milliseconds(500),
                   leeway: hasWatcher ? .milliseconds(500) : .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.pollFile()
            self?.reapFinishedBackgroundTasks()
            self?.checkStaleness()
        }
        t.resume()
        timer = t

        let st = DispatchSource.makeTimerSource(queue: queue)
        st.schedule(deadline: .now() + 2, repeating: .seconds(300), leeway: .seconds(30))
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
        watcher?.cancel();     watcher = nil
        pendingCompletionWork?.cancel(); pendingCompletionWork = nil
    }

    /// 작업을 하나 끝냈을 때 코인을 준다. 이미 완료 표시 중이면(같은 완료가
    /// 두 경로로 들어오는 경우) 중복 지급하지 않는다.
    private func rewardIfNewCompletion() {
        if case .completed = controller.state { return }
        ShopStore.shared.rewardCompletion()
    }

    private func updateMonthlyTokens() {
        guard let total = TokenUsageReader.readThisMonthShared() else { return }   // 다른 세션이 계산 중이면 건너뛴다
        DispatchQueue.main.async {
            self.controller.monthlyTokens = total
            ShopStore.shared.updateLevel(fromTokens: total)
        }
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

    /// 세션마다 따로 부르지만 서버 사용량은 계정 전체 값이라, 최근에 가져왔다면 건너뛴다
    private static let fetchLock = NSLock()
    private static var lastFetch = Date.distantPast

    private func fetchServerUsage() {
        guard FileManager.default.fileExists(atPath: Self.fetchScript) else { return }
        Self.fetchLock.lock()
        let recent = Date().timeIntervalSince(Self.lastFetch) < 240
        if !recent { Self.lastFetch = Date() }
        Self.fetchLock.unlock()
        if recent {                                  // 다른 세션이 막 가져왔다 — 그 결과 파일만 읽는다
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readServerUsageFile() }
            return
        }
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
        // 한도에 걸린 동안에는 세션을 살려둬야 리셋을 알려줄 수 있다 (checkStaleness에서 사용)
        let wasLimited = isLimitReachedSnapshot
        isLimitReachedSnapshot = utilization >= 100
        // 한도 → 한도 해제로 바뀐 순간 한 번만 알린다
        let justReset = wasLimited && utilization < 100

        DispatchQueue.main.async {
            self.controller.serverUtilization = utilization
            self.controller.serverResetsAt    = resetsAt
            // 숨김은 "이번 한도 창이 리셋될 때까지"라 시간이 지나면 저절로 풀린다.
            // (예전에는 여기서 resets_at이 조금만 달라져도 숨김을 풀어버려,
            //  숨긴 안내가 잠시 뒤 다시 뜨는 문제가 있었다)
            self.controller.refreshLimitNoticeDismissal()
            if justReset { self.controller.announceLimitReset() }
        }
    }

    // MARK: - 백그라운드 작업 추적
    //
    // Claude Code는 run_in_background로 띄운 작업의 출력을
    // <스크래치패드>/tasks/<작업ID>.output 에 실시간으로 쓰고, 끝나면 파일 끝에
    // "[exited with code N]" (강제 종료면 "[killed]") 을 붙인다. 훅에는 종료 신호가
    // 없지만 이 마커를 보면 실제 종료 시점을 정확히 알 수 있다.

    /// Stop 훅이 알려준 "아직 돌고 있는 작업" 목록에 맞춰 추적 목록을 갱신한다.
    private func reconcileBackgroundTasks(ids: [String]?, dir: String?,
                                          desc: String?, count: Int) {
        let fallbackDesc = (desc?.isEmpty == false) ? desc! : L.t("백그라운드 작업", "Background task")

        guard let ids, !ids.isEmpty else {
            // 구버전 훅이라 작업 ID가 없다 — 파일 추적을 못 하므로 타임아웃에 맡긴다
            if backgroundTasks.isEmpty {
                backgroundTasks["_untracked"] = BackgroundTask(id: "_untracked",
                                                               file: "", desc: fallbackDesc)
            }
            return
        }

        var next: [String: BackgroundTask] = [:]
        for id in ids {
            var task = backgroundTasks[id] ?? BackgroundTask(id: id, file: "", desc: fallbackDesc)
            if task.file.isEmpty, let dir, !dir.isEmpty {
                task.file = "\(dir)/tasks/\(id).output"
            }
            next[id] = task
        }
        backgroundTasks = next   // Stop에 없는 작업은 이미 끝난 것
    }

    private func backgroundLabel() -> String {
        let base = backgroundTasks.values.first?.desc ?? L.t("백그라운드 작업", "Background task")
        let n    = backgroundTasks.count
        return n > 1 ? L.t("⏳ \(base) 외 \(n - 1)건", "⏳ \(base) +\(n - 1) more") : "⏳ \(base)"
    }

    /// 출력 파일에 종료 마커가 찍힌 작업을 추적 목록에서 걷어낸다.
    private func reapFinishedBackgroundTasks() {
        guard !backgroundTasks.isEmpty else { return }

        let finished = backgroundTasks.values
            .filter { !$0.file.isEmpty && Self.isTaskFinished(file: $0.file) }
            .map(\.id)
        guard !finished.isEmpty else { return }

        for id in finished { backgroundTasks.removeValue(forKey: id) }

        let remaining   = backgroundTasks.count
        let label       = backgroundLabel()
        let showDone    = remaining == 0 && completionDeferredByBackground
        if remaining == 0 { completionDeferredByBackground = false }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 백그라운드 표시 중일 때만 건드린다 — 그사이 새 작업이 시작됐으면 그대로 둔다
            guard case .backgroundWork = self.controller.state else { return }
            if remaining > 0 {
                self.controller.update(to: .backgroundWork(label))
            } else if showDone {
                self.rewardIfNewCompletion()
                self.controller.update(to: .completed)
            } else {
                self.controller.update(to: .ready)
            }
        }
    }

    /// 파일 끝에 Claude Code가 붙이는 종료 마커가 있으면 끝난 작업
    private static func isTaskFinished(file: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let size  = attrs[.size] as? Int, size > 0,
              let fh    = FileHandle(forReadingAtPath: file) else { return false }
        defer { fh.closeFile() }
        fh.seek(toFileOffset: UInt64(max(0, size - 256)))
        let tail = String(data: fh.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return tail.contains("[exited with code") || tail.contains("[killed]")
    }

    // MARK: - 세션 종료 감지

    /// 파일이 30분 이상 변화 없으면 크래시·강제종료로 간주하여 세션 종료
    /// 정상 종료는 AppDelegate의 프로세스 감지가 담당.
    /// Claude가 유저 입력을 기다리는 동안(idle)에는 이벤트가 없으므로
    /// 짧은 타임아웃은 false positive를 유발함.
    private func checkStaleness() {
        let quietFor = Date().timeIntervalSince(lastEventDate)

        // 도구가 시작됐는데 한참 아무 소식이 없다 = 클로드가 확인 창을 띄우고
        // 기다리는 중일 가능성이 높다. 훅이 오지 않는 확인 창(브라우저 사이트
        // 권한 등)을 사용자에게 알리는 유일한 방법이라 여기서 추정한다.
        // Bash처럼 원래 오래 도는 도구까지 잡으면 오탐이 잦아, 보통 몇 초 안에
        // 끝나는 MCP 도구에만 적용한다.
        if pendingTools > 0, !waitHintShown, quietFor > userWaitHintSeconds,
           let tool = pendingToolName, Self.mayPromptWithoutHook(tool) {
            waitHintShown = true
            let label: String = formatToolName(tool.lowercased())
            let suffix: String = L.t(" — 클로드 창에서 확인을 기다리는 중일 수 있어요",
                                     " — Claude may be waiting for your confirmation")
            let hint: String = label + suffix
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch self.controller.state {
                case .toolUse, .toolRead, .thinking:
                    self.controller.pendingPermissionId = nil
                    self.controller.update(to: .permission(hint))
                default:
                    break
                }
            }
        }

        // 승인 버튼 없는 확인 버블(ask_user·확인 대기 추정)은 터미널에서 답해도
        // 후속 이벤트가 안 올 수 있어, 한동안 조용하면 스스로 정리한다.
        if quietFor > askBubbleExpireSeconds {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard case .permission = self.controller.state,
                      self.controller.pendingPermissionId == nil else { return }
                self.controller.update(to: .ready)
            }
        }

        // 진행 중인 작업이 없는데 작업 상태로 남아 있으면 대기 상태로 되돌린다.
        // 오래 걸리는 도구가 실행 중(tool_use 후 tool_done 미도착)이면 이벤트가
        // 없는 게 정상이므로 건드리지 않는다.
        if pendingTools == 0 {
            // 출력 파일을 추적 중인 작업이 하나라도 있으면, 조용하다고 해서 끝난 게
            // 아니다(오래 걸리는 빌드 등) — 실제 종료는 reap 쪽이 판단한다.
            let hasTrackedBackground = backgroundTasks.values.contains { !$0.file.isEmpty }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch self.controller.state {
                case .thinking, .toolUse, .toolRead:
                    if quietFor > self.idleFallbackSeconds { self.controller.update(to: .ready) }
                case .backgroundWork:
                    if !hasTrackedBackground, quietFor > self.backgroundWorkStaleSeconds {
                        self.controller.update(to: .ready)
                    }
                default:
                    break   // 완료·권한·알림 버블은 사용자가 확인해야 하므로 유지
                }
            }
        }

        // 오래 도는 백그라운드 작업이 남아 있으면 조용해도 세션이 끝난 게 아니다
        guard backgroundTasks.isEmpty else { return }
        // 한도에 걸려 대기 중인 세션도 살려둔다 — 리셋되면 다시 알려줘야 하므로
        guard !isLimitReachedSnapshot else { return }
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
            // 새 작업이 시작됐으니 대기 중이던 "완료" 표시는 취소 — 아직 세션이
            // 안 끝났는데 중간에 완료 문구가 떴다 사라지는 것 방지
            pendingCompletionWork?.cancel(); pendingCompletionWork = nil
            pendingTools += 1
            pendingToolName = event.tool
            waitHintShown   = false
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
            if pendingTools == 0 { pendingToolName = nil }
            waitHintShown = false
            controller.update(to: .thinking)  // 도구 완료 후 항상 thinking(타이핑)으로 복귀
        case "thinking":
            // 30초 이내의 이벤트는 replay 중에도 처리 — 새 세션 시작 시 토큰 소비 구간부터 모션 적용
            let isStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && isStale { break }
            pendingCompletionWork?.cancel(); pendingCompletionWork = nil
            pendingTools = 0   // 새 턴 시작 — 이전 턴에서 남은 카운트 정리
            pendingToolName = nil
            waitHintShown   = false
            // 새 턴이 시작됐으니 "백그라운드 끝나면 완료 띄우기"는 더 이상 유효하지 않다
            // (안 끄면 작업 중에 난데없이 완료 버블이 뜬다)
            completionDeferredByBackground = false
            switch controller.state {
            case .ready, .completed:
                controller.update(to: .thinking)
            default:
                break
            }

        case "done":
            if isReplaying { break }   // 과거 done 재생 시 세션 조기 제거 방지
            pendingTools = 0
            pendingToolName = nil
            waitHintShown   = false
            // Stop이 백그라운드 작업 없이 done을 보냈다 = 남은 작업이 없다는 뜻
            backgroundTasks.removeAll()
            completionDeferredByBackground = false
            pendingCompletionWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.rewardIfNewCompletion()
                self?.controller.update(to: .completed)
            }
            pendingCompletionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + completionDebounceSeconds, execute: work)

        case "background_start":
            // PostToolUse에서 온 "백그라운드 작업이 시작됐다" 신호.
            // 클로드는 아직 작업 중이므로 버블은 그대로 두고, 추적 목록에만 넣는다.
            // (버블 전환은 턴이 끝나는 Stop 시점의 background 이벤트가 담당)
            if isReplaying { break }
            let id = (event.id?.isEmpty == false) ? event.id! : UUID().uuidString
            backgroundTasks[id] = BackgroundTask(id: id,
                                                 file: event.file ?? "",
                                                 desc: event.message ?? L.t("백그라운드 작업", "Background task"))

        case "background":
            // Stop 훅이 왔지만 run_in_background로 띄운 작업이 아직 돌고 있는 경우 —
            // 완료가 아니라 "백그라운드 작업 중"으로 표시. 대기 중이던 완료 표시도 취소.
            if isReplaying { break }
            pendingTools = 0
            pendingCompletionWork?.cancel(); pendingCompletionWork = nil
            // Stop이 알려준 목록이 가장 정확하므로 그것으로 맞춘다
            reconcileBackgroundTasks(ids: event.ids, dir: event.dir,
                                     desc: event.message, count: event.count ?? 1)
            completionDeferredByBackground = true
            let label = backgroundLabel()
            DispatchQueue.main.async { [weak self] in
                self?.controller.update(to: .backgroundWork(label))
            }
        case "notification":
            let notifStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && notifStale { break }
            if case .permission = controller.state, controller.pendingPermissionId == nil { break }
            controller.update(to: .notification(event.message ?? L.t("알림", "Notification")), autohideAfter: 5)
        case "permission":
            if isReplaying { break }   // 과거 이벤트 재생으로 지난 권한 버블이 되살아나는 것 방지
            controller.update(to: .permission(event.message ?? L.t("권한 요청", "Permission request")))
        case "ask_user":
            // 이미 답한 확인 요청이 재시작 때 되살아나는 건 막되, 방금 온 질문은
            // 재생 중이라도 띄운다 — 완료 버블을 닫아 세션이 사라진 뒤 클로드가
            // "다음엔 뭘 할까요?"를 물으면 세션이 새로 감지되면서 첫 폴링이
            // 재생 모드라, 예전에는 그 질문이 통째로 무시됐다.
            let askStale = event.ts.map { Date().timeIntervalSince1970 - $0 > 30 } ?? true
            if isReplaying && askStale { break }
            // 질문 내용이 비어 올 수도 있다(구버전 훅, 질문 텍스트가 없는 경우) —
            // ?? 는 빈 문자열을 걸러내지 못해 예전엔 빈 버블이 떴다.
            let asked = (event.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = asked.isEmpty
                ? L.t("터미널에서 선택해 주세요", "Please choose in the terminal")
                : asked
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

    /// 훅 없이 클로드가 자체 확인 창을 띄울 수 있는 도구인지.
    /// MCP 도구(브라우저 등)는 보통 몇 초 안에 끝나므로, 오래 멈춰 있으면
    /// 확인 창을 기다리는 중으로 봐도 오탐이 적다. Bash처럼 원래 오래 도는
    /// 도구는 제외해서 빌드·설치 중에 엉뚱한 안내가 뜨지 않게 한다.
    private static func mayPromptWithoutHook(_ tool: String) -> Bool {
        tool.hasPrefix("mcp__")
    }

    private func formatToolName(_ raw: String) -> String {
        // MCP 도구는 mcp__<서버>__<도구> 형태라 그대로 쓰면 말풍선이 지저분해진다
        if raw.hasPrefix("mcp__") {
            let parts = raw.components(separatedBy: "__")
            let tool  = parts.count > 2 ? parts[2...].joined(separator: " ") : raw
            let name = tool.replacingOccurrences(of: "_", with: " ")
            return L.t("\(name) 실행 중", "Running \(name)")
        }
        // 부니 스쿼드 엔진이 적는 팀장 부니 이벤트 — 문구가 이미 완성돼 있다
        if raw.hasPrefix("squad:") { return String(raw.dropFirst("squad:".count)) }
        switch raw.lowercased() {
        case "bash":      return L.t("터미널 명령 실행 중", "Running command")
        case "read":      return L.t("파일 읽는 중", "Reading file")
        case "write":     return L.t("파일 쓰는 중", "Writing file")
        case "edit":      return L.t("파일 수정 중", "Editing file")
        case "glob":      return L.t("파일 검색 중", "Finding files")
        case "grep":      return L.t("코드 검색 중", "Searching code")
        case "websearch": return L.t("웹 검색 중", "Searching the web")
        case "webfetch":  return L.t("페이지 읽는 중", "Reading page")
        case "todowrite": return L.t("할 일 정리 중", "Updating to-dos")
        default:          return L.t("\(raw) 실행 중", "Running \(raw)")
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
