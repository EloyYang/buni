import Cocoa
import SwiftUI
import Combine
import ServiceManagement
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyMonitor = HotkeyMonitor()
    private var settingsWindow: NSWindow?
    private var shopWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var availableUpdate: String? = nil
    private var updateStatus: String? = nil          // 업데이트 내려받는 동안 메뉴에 보일 진행 문구

    // ── 다중 세션 관리
    private var sessions:          [String: SessionWindow] = [:]
    private var slotOwner:         [Int: String] = [:]          // slot → sessionId
    private var sessionOrder:      [String] = []               // 생성 순서 (최신이 앞)
    // 종료(완료 버블 닫기)된 세션 재탐지 방지 — sid → 닫은 시각.
    // Claude Code는 --resume으로 같은 session id를 계속 재사용하므로, 닫은 이후
    // 그 세션이 다시 활동(이벤트 파일 갱신)하면 재탐지를 허용해야 함(무기한 차단 금지).
    private var ignoredSessionIds: [String: Date] = [:]
    private let appStartTime       = Date()                     // 비초기 스캔 기준 시각
    private var scanTimer:         DispatchSourceTimer?
    private let scanQueue = DispatchQueue(label: "buni.session.scanner", qos: .background)
    private var claudeWasRunning        = false
    private var claudeLastSeen          = Date.distantPast   // sysctl 경합 방지 디바운스 기준(마지막으로 Claude를 본 시각)
    private var lastTmpMod              = Date.distantPast   // /tmp 폴더가 마지막으로 바뀐 시각 (바뀐 게 없으면 목록을 다시 안 읽는다)
    private var lastTmpScan             = Date.distantPast
    private var isInitialScan           = true

    // ── SSH Remote 이벤트 수신용 TCP 소켓 서버
    private let socketServer = EventSocketServer()
    /// TCP로 수신된 원격 세션 ID — Claude 프로세스 없이도 유지
    private var remoteSessionIds: Set<String> = []

    // ── 사용자가 "숨기기"를 누른 뒤인지. true인 동안에는 새로 만들어지는 패널
    // (Claude만 켜져 있을 때 뜨는 레거시 대기 세션 포함)도 자동으로 나타나지
    // 않는다 — 숨겼는데 진행 중인 세션도 없이 부니가 다시 튀어나오던 문제.
    // 어느 세션이든 실제로 작업을 시작하면(SessionWindow.onRunStart) 풀린다.
    private var hiddenUntilNextRunStart = false

    // ── 위치 영속성 (슬롯별로 저장 — 세션이 어느 슬롯에 배정되든 이전에
    // 지정한 위치에서 다시 나타나게 한다. 예전에는 슬롯 0만 저장해서, 세션이
    // 다른 슬롯에 배정되면 위치가 초기화되는 문제가 있었다.)
    private func savedOrigin(forSlot slot: Int) -> NSPoint? {
        let xKey = "panel.\(slot).x", yKey = "panel.\(slot).y"
        // 슬롯 0은 구버전(panel.x/panel.y)에 저장된 위치도 그대로 이어받는다
        let useLegacy = slot == 0
            && UserDefaults.standard.object(forKey: xKey) == nil
            && UserDefaults.standard.object(forKey: "panel.x") != nil
        let readX = useLegacy ? "panel.x" : xKey
        let readY = useLegacy ? "panel.y" : yKey
        guard UserDefaults.standard.object(forKey: readX) != nil else { return nil }
        let p = NSPoint(x: UserDefaults.standard.double(forKey: readX),
                         y: UserDefaults.standard.double(forKey: readY))
        // 저장된 위치에서 "캐릭터"가 실제로 보이는지 확인한다.
        // 패널(320x200) 중 눈에 보이는 건 캐릭터 영역뿐이라, 패널이 화면에 걸쳐
        // 있어도 캐릭터만 화면 밖이면 부니가 사라진 것처럼 보인다. 외장 모니터
        // 분리처럼 화면 구성이 바뀐 경우도 여기서 함께 걸러진다.
        // 저장값은 항상 말풍선 반전 전(캐릭터가 패널 오른쪽 끝) 기준이다.
        let characterRect = NSRect(x: p.x + PanelMetrics.characterOffsetX(flipped: false),
                                   y: p.y,
                                   width: PanelMetrics.characterAreaWidth,
                                   height: PanelMetrics.height)
        let characterVisible = NSScreen.screens.contains { screen in
            let hit = screen.frame.intersection(characterRect)
            return hit.width >= 40 && hit.height >= 40
        }
        guard characterVisible else {
            setSavedOrigin(nil, forSlot: slot)
            return nil
        }
        return p
    }

    private func setSavedOrigin(_ origin: NSPoint?, forSlot slot: Int) {
        let xKey = "panel.\(slot).x", yKey = "panel.\(slot).y"
        if let p = origin, p.x >= 0 {
            UserDefaults.standard.set(Double(p.x), forKey: xKey)
            UserDefaults.standard.set(Double(p.y), forKey: yKey)
        } else {
            UserDefaults.standard.removeObject(forKey: xKey)
            UserDefaults.standard.removeObject(forKey: yKey)
        }
        // 구버전 슬롯 0 전용 키는 더 이상 쓰지 않으므로 정리
        if slot == 0 {
            UserDefaults.standard.removeObject(forKey: "panel.x")
            UserDefaults.standard.removeObject(forKey: "panel.y")
        }
    }

    // MARK: - Launch

    /// 켜둔 채 종료되면 맥이 영영 안 자게 되므로 반드시 되돌린다
    func applicationWillTerminate(_ notification: Notification) {
        AwakeManager.shared.restoreOnQuit()
        MainActor.assumeIsolated { ChatStore.shared.leaveBlocking() }     // 채팅방 자리를 비운다
        MainActor.assumeIsolated { TeamStore.shared.stopDaemon() }       // 부니 스쿼드 상주 프로세스도 함께 끝낸다
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.ensureInstalled()
        installEditMenu()
        wireAppMenuBridge()
        setupSocketServer()
        if !UserDefaults.standard.bool(forKey: "statusBar.hidden") {
            setupStatusBar()
        }
        setupHotkeyMonitor()
        ShopStore.shared.$coins
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        setupSettingsCallbacks()
        setupUpdateChecker()
        startSessionScanner()
        // 선택 기능 — 서버 설정이 있고 이전에 로그인해 둔 사람만 조용히 이어진다
        Task { @MainActor in CloudSync.shared.start() }
        Task { @MainActor in
            ChatStore.shared.start()
            ChatWindowController.shared.start()
        }
        startChatMotionTimer()
        // 처음 실행이면 짧은 안내를 보여준다 (이미 본 사람에게는 뜨지 않는다)
        DispatchQueue.main.async { OnboardingWindow.showIfNeeded() }
        // 부니 스쿼드(에이전트 모드 · 업무 예약) — 예약 시간대에 알아서 시작하는 상주 프로세스를 띄운다
        Task { @MainActor in
            TeamStore.shared.start()
            TeamStore.shared.$jobs
                .map { jobs in jobs.filter { $0.state == "review" }.count }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rebuildMenu() }
                .store(in: &self.cancellables)
        }
    }

    private func setupSocketServer() {
        socketServer.onNewSession = { [weak self] sessionId, fileURL in
            guard let self else { return }
            DispatchQueue.main.async {
                self.remoteSessionIds.insert(sessionId)
                guard self.sessions[sessionId] == nil else { return }
                // 새 원격 이벤트 자체가 곧 새 활동이므로 예전에 닫혔던 세션이어도 재탐지 허용
                self.ignoredSessionIds.removeValue(forKey: sessionId)
                self.addSession(id: sessionId, fileURL: fileURL)
            }
        }
        socketServer.start()
    }

    // MARK: - Session Scanner

    private func startSessionScanner() {
        let t = DispatchSource.makeTimerSource(queue: scanQueue)
        t.schedule(deadline: .now(), repeating: scanInterval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.scanForSessions() }
        t.resume()
        scanTimer = t
    }

    /// 스캔 주기 — Claude도 세션 창도 없는 대기 중에는 2초, 화면이 꺼져 있으면 4초로 늦춘다.
    /// (예전에는 늘 0.5초마다 전체 프로세스 목록을 읽었다)
    private var scanInterval: DispatchTimeInterval = .seconds(1)

    private func adaptScanInterval(busy: Bool) {
        let next: DispatchTimeInterval = AppActivity.shared.screenAsleep ? .seconds(4)
                                       : (busy ? .seconds(1) : .seconds(2))
        guard next != scanInterval else { return }
        scanInterval = next
        scanTimer?.schedule(deadline: .now() + next, repeating: next, leeway: .milliseconds(250))
    }

    private func scanForSessions() {
        let claudeRunning = isClaudeRunning()
        let wasInitial    = isInitialScan
        isInitialScan     = false
        adaptScanInterval(busy: claudeRunning || claudeWasRunning || !sessions.isEmpty)

        // ── Claude 종료 감지 (디바운스: sysctl 경합 등으로 인한 false negative 방지)
        // 마지막으로 Claude를 본 뒤 3초 연속 "실행 중 아님"일 때만 반응 (주기가 바뀌어도 시간 기준).
        let nowTick = Date()
        if claudeRunning {
            claudeLastSeen = nowTick
            claudeWasRunning = true
        }

        if claudeWasRunning && nowTick.timeIntervalSince(claudeLastSeen) >= 3 {
            // Claude 종료 확인 — 활성 세션(thinking/toolUse 등) 제거, 완료·권한 버블은 유지
            claudeWasRunning = false
            DispatchQueue.main.async {
                self.cleanupInactiveSessions()
            }
        }

        guard claudeRunning else { return }

        // ── 세션 파일 스캔
        // /tmp 에 파일이 새로 생기거나 사라지지 않았으면 목록을 매번 다시 읽지 않고 5초에 한 번만 본다
        // (이어서 재개된 세션처럼 기존 파일만 갱신되는 경우도 5초 안에 잡힌다)
        let tmp = URL(fileURLWithPath: "/tmp")
        let tmpMod = (try? FileManager.default.attributesOfItem(atPath: "/private/tmp"))?[.modificationDate] as? Date
        if let tmpMod, tmpMod == lastTmpMod, nowTick.timeIntervalSince(lastTmpScan) < 5, !wasInitial { return }
        if let tmpMod { lastTmpMod = tmpMod }
        lastTmpScan = nowTick
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            // 파일 스캔 실패해도 Claude 실행 중이면 레거시 세션 보장
            DispatchQueue.main.async { self.ensureLegacySession() }
            return
        }

        var found: [String: URL] = [:]
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix("claude-companion-events-") && name.hasSuffix(".jsonl") {
                let id = String(name.dropFirst("claude-companion-events-".count).dropLast(".jsonl".count))
                if !id.isEmpty { found[id] = url }
            }
        }

        let now = Date()
        var hasRecentSession = false

        // 새 세션 후보: 패널이 없고, 무시 중이 아니고, 충분히 최근인 파일만
        var candidates: [String: Date] = [:]
        for (sid, url) in found {
            guard sessions[sid] == nil else { hasRecentSession = true; continue }
            if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                // 완료 버블을 닫아 무시 중인 세션이라도, 닫은 이후 파일이 다시 갱신됐다면
                // (--resume으로 같은 세션이 재개돼 새 이벤트가 쌓인 경우) 재탐지를 허용
                if let dismissedAt = ignoredSessionIds[sid], modDate <= dismissedAt { continue }
                // 앱 시작 시 : 90초 이내 수정된 파일만 복원
                // 이후 스캔   : 앱 시작 이후에 수정된 파일만 신규 세션으로 인식
                //              (오래된 잔존 파일이 나중에 탐지되는 것을 방지)
                let threshold: TimeInterval = wasInitial
                    ? 90
                    : now.timeIntervalSince(appStartTime) + 10  // 앱 시작 10초 전까지 허용
                if now.timeIntervalSince(modDate) < threshold { candidates[sid] = modDate }
            }
        }
        // 스쿼드 파일(squad-<작업id>)은 작업마다 생겨도 부니는 하나만 만든다
        // 고르는 일은 메인에서 한다 — 이 큐에서 sessions 를 읽으면 직전 스캔이 예약한 패널이 아직 없어
        // 다른 squad-* 파일로 두 번째 패널이 만들어질 수 있었다.
        if !candidates.isEmpty { hasRecentSession = true }
        DispatchQueue.main.async {
            self.collapseSquadPanels()
            for sid in SessionDedupe.newSessions(found: candidates, existing: Set(self.sessions.keys)) {
                guard let url = found[sid] else { continue }
                self.ignoredSessionIds.removeValue(forKey: sid)
                self.addSession(id: sid, fileURL: url)
            }
        }

        // ── 세션 파일이 없으면 레거시 단일 파일로 폴백
        if !hasRecentSession && sessions.isEmpty {
            DispatchQueue.main.async { self.ensureLegacySession() }
        }
    }

    /// Claude가 실행 중이지만 세션 파일이 없을 때 레거시 이벤트 파일로 단일 세션 보장
    private func ensureLegacySession() {
        guard sessions["__legacy__"] == nil else { return }
        let legacyURL = URL(fileURLWithPath: EventMonitor.legacyEventFile)
        if !FileManager.default.fileExists(atPath: legacyURL.path) {
            FileManager.default.createFile(atPath: legacyURL.path, contents: nil)
        }
        addSession(id: "__legacy__", fileURL: legacyURL)
    }

    // MARK: - Process detection (sysctl, 서브프로세스 없이 마이크로초 완료)

    private func isClaudeRunning() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var len = 0
        guard sysctl(&mib, 4, nil, &len, nil, 0) == 0, len > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs  = [kinfo_proc](repeating: kinfo_proc(), count: len / stride + 1)
        guard sysctl(&mib, 4, &procs, &len, nil, 0) == 0 else { return false }
        let myPid = getpid()
        for i in 0..<(len / stride) {
            let p = procs[i].kp_proc
            guard p.p_pid > 0, p.p_pid != myPid else { continue }
            let name = withUnsafeBytes(of: p.p_comm) { buf in
                String(bytes: buf.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            if name == "claude" { return true }
            // Claude가 버전 바이너리(예: "2.1.150")로 실행될 때를 처리
            // p_comm이 버전 패턴이면 proc_pidpath로 경로 확인
            if looksLikeVersion(name), isClaudePath(pid: p.p_pid) { return true }
        }
        return false
    }

    private func looksLikeVersion(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func isClaudePath(pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(MAXPATHLEN)) > 0 else { return false }
        let path = String(cString: buf)
        return path.contains("/claude/") || path.contains(".claude")
    }

    /// Claude 종료 시 대기·작업 중 세션만 제거, completed/permission 버블 및 원격 세션은 유지
    private func cleanupInactiveSessions() {
        let toRemove = sessions.compactMap { (id, win) -> String? in
            if remoteSessionIds.contains(id) { return nil }  // SSH Remote 세션은 유지
            switch win.controller.state {
            case .completed, .permission: return nil   // 사용자 응답 필요 — 유지
            default: return id
            }
        }
        for id in toRemove { removeSession(id: id) }
        // 남아있는 세션(completed/permission) 패널 숨기기
        sessions.values.forEach { $0.hideCompanion() }
    }

    /// 새 세션 추가 전 종료된(idle/completed) 세션 제거
    /// — ready는 병렬 실행 중인 세션일 수 있으므로 유지
    private func cleanupFinishedSessions() {
        let toRemove = sessions.compactMap { (id, win) -> String? in
            switch win.controller.state {
            case .idle, .completed: return id
            default: return nil   // ready/thinking/tool/permission/notification 은 유지
            }
        }
        for id in toRemove { removeSession(id: id) }
    }

    /// 스쿼드 패널(`squad-<작업id>`)은 앱 전체에서 하나 — 생성 시점에 이미 있으면 새로 만들지 않는다 (소켓·스캐너 어느 경로든).
    private func hasSquadPanel() -> Bool {
        sessions.keys.contains { $0.hasPrefix(SessionDedupe.squadPrefix) }
    }

    /// 이미 떠 있는 스쿼드 패널이 둘 이상이면 가장 최근에 갱신된 이벤트 파일 하나만 남기고 패널만 닫는다.
    /// 이벤트 파일·작업 데이터는 지우지 않고, 닫은 id 는 무시 목록에 올려 스캐너가 되살리지 않게 한다.
    private func collapseSquadPanels() {
        let ids = sessions.keys.filter { $0.hasPrefix(SessionDedupe.squadPrefix) }
        guard ids.count > 1 else { return }
        func mtime(_ id: String) -> Date {
            let p = "/tmp/claude-companion-events-\(id).jsonl"
            return ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
        }
        let keep = ids.max { (mtime($0), $0) < (mtime($1), $1) }
        for id in ids where id != keep { removeSession(id: id) }
    }

    private func addSession(id: String, fileURL: URL) {
        guard sessions[id] == nil else { return }
        if id.hasPrefix(SessionDedupe.squadPrefix), hasSquadPanel() { return }

        // 실제 Claude 세션이 추가될 때 레거시 대기 세션 및 완료된 세션 교체
        if id != "__legacy__" {
            dismissLegacySession()
            cleanupFinishedSessions()
        }

        let slot = nextAvailableSlot()

        // 캐릭터 우선순위: 세션 UUID 저장값(충돌 없을 때) → 가장 최근 세션에서 쓰던 캐릭터
        // (충돌 없을 때) → 슬롯 저장값(충돌 없을 때) → pickCharacter.
        // 이미 활성 세션이 같은 캐릭터를 사용 중이면 저장값 무시하고 새 캐릭터 배정
        let inUse = Set(sessions.values.map { $0.controller.character })
        let characterToUse: CharacterType
        if let raw  = UserDefaults.standard.string(forKey: "character.session.\(id)"),
           let type = CharacterType(rawValue: raw), !inUse.contains(type) {
            characterToUse = type
        } else if let raw  = UserDefaults.standard.string(forKey: "character.lastUsed"),
                  let type = CharacterType(rawValue: raw), !inUse.contains(type) {
            characterToUse = type
        } else if let raw  = UserDefaults.standard.string(forKey: "character.slot.\(slot)"),
                  let type = CharacterType(rawValue: raw), !inUse.contains(type) {
            characterToUse = type
        } else {
            characterToUse = pickCharacter(for: id)
        }
        UserDefaults.standard.set(characterToUse.rawValue, forKey: "character.session.\(id)")
        UserDefaults.standard.set(characterToUse.rawValue, forKey: "character.lastUsed")

        let origin = savedOrigin(forSlot: slot)
        let win = SessionWindow(sessionId: id, slot: slot,
                                eventFile: fileURL.path,
                                savedOrigin: origin)
        wire(win)
        sessions[id] = win
        slotOwner[slot] = id
        sessionOrder.insert(id, at: 0)
        // 사용자가 숨긴 직후라면 새 패널도 조용히 대기시킨다 —
        // 이 세션이 실제로 작업을 시작할 때 비로소 나타난다.
        if hiddenUntilNextRunStart { win.markHiddenUntilNextStart() }
        win.setup(autoShow: !hiddenUntilNextRunStart)
        publishLiveState()
        rebuildMenu()
        syncHotkeyPermissionState()
    }

    /// 레거시 대기 세션을 조용히 제거 (ignoredSessionIds에 추가하지 않아 재생성 가능)
    private func dismissLegacySession() {
        guard let win = sessions["__legacy__"] else { return }
        win.teardown()
        slotOwner.removeValue(forKey: win.slot)
        sessions.removeValue(forKey: "__legacy__")
        sessionOrder.removeAll { $0 == "__legacy__" }
    }

    /// 현재 활성 세션이 사용하지 않는 캐릭터를 순서대로 선택
    private func pickCharacter(for sessionId: String) -> CharacterType {
        let inUse = Set(sessions.values.map { $0.controller.character })
        let all   = CharacterType.allCases
        // 사용 안 된 캐릭터 중 첫 번째 선택
        if let available = all.first(where: { !inUse.contains($0) }) {
            return available
        }
        // 6개 모두 사용 중이면 슬롯 번호 기반 순환
        return all[nextAvailableSlot() % all.count]
    }

    /// EventMonitor가 세션 종료를 확인 시 호출 — 재탐지 방지를 위해 ignoredSessionIds에 추가
    private func removeSession(id: String) {
        ignoredSessionIds[id] = Date()   // 종료된 세션 파일 재탐지 방지 (이후 새 활동 있으면 해제)
        remoteSessionIds.remove(id)
        guard let win = sessions[id] else { return }
        win.teardown()
        slotOwner.removeValue(forKey: win.slot)
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        publishLiveState()
        rebuildMenu()
        syncHotkeyPermissionState()
    }

    /// 지금 떠 있는 패널 목록을 파일로 남긴다 — 스쿼드 엔진의 `tools/live-state.sh` 가 읽어 "부니가 여러 개" 같은 어긋남을 스스로 알아챈다.
    private func publishLiveState() {
        let panels = sessions.keys.sorted().map { ["id": $0, "kind": $0.hasPrefix(SessionDedupe.squadPrefix) ? "squad" : "claude"] }
        let info: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "updated": Date().timeIntervalSince1970, "panels": panels]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
              let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Buni") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("live-state.json"), options: .atomic)
    }

    private func wire(_ win: SessionWindow) {
        win.onOpenClaude    = { [weak self] in self?.openClaude() }
        win.onOpenSquad     = { id in Task { @MainActor in TeamWindowController.shared.show(jobId: id) } }
        win.onOpenSettings  = { [weak self] in self?.openSettings() }
        win.onShowStatusBar = { [weak self] in self?.showStatusBar() }
        win.onRebuildMenu   = { [weak self] in self?.rebuildMenu() }
        win.shouldAutoShow  = { [weak self] in !(self?.hiddenUntilNextRunStart ?? false) }
        win.onUserHide      = { [weak self] in self?.hiddenUntilNextRunStart = true }
        win.onRunStart      = { [weak self] in self?.hiddenUntilNextRunStart = false }
        win.onSwitchSession = { [weak self, weak win] targetId in
            guard let self, let win else { return }
            self.switchSession(win, to: targetId)
        }
        win.onSessionEnded  = { [weak self] in
            DispatchQueue.main.async { self?.removeSession(id: win.sessionId) }
        }
        win.onStaledSessionEnded = { [weak self] in
            DispatchQueue.main.async { self?.removeStaledSession(id: win.sessionId) }
        }
        win.onSaveOrigin = { [weak self] origin in
            self?.setSavedOrigin(origin, forSlot: win.slot)
        }
    }

    /// 모든 세션 창의 "다른 세션으로 전환" 목록을 다시 계산해 반영한다.
    /// 세션 추가·제거·전환마다 호출 — 우클릭 메뉴가 항상 최신 목록을 보여주게 한다.
    private func refreshSwitchTargets() {
        for (sid, win) in sessions {
            win.controller.switchTargets = sessions.compactMap { (otherSid, otherWin) -> SessionSwitchTarget? in
                guard otherSid != sid else { return nil }
                let label = otherWin.controller.memo.isEmpty
                    ? L.t("세션 \(otherWin.slot + 1)", "Session \(otherWin.slot + 1)")
                    : otherWin.controller.memo
                return SessionSwitchTarget(id: otherSid, label: label)
            }.sorted { $0.label < $1.label }
        }
    }

    /// 패널(위치·화면상 자리)은 그대로 두고 표시하는 세션만 다른 세션과 맞바꾼다.
    /// 대상 세션도 자기 패널이 있어야만 우클릭 메뉴에 나열되므로 항상 맞바꾸기다
    /// — 어느 세션도 패널을 잃지 않는다.
    private func switchSession(_ win: SessionWindow, to targetId: String) {
        let sourceId = win.sessionId
        guard sourceId != targetId, let targetWin = sessions[targetId] else { return }

        let sourceFile = "/tmp/claude-companion-events-\(sourceId).jsonl"
        let targetFile = "/tmp/claude-companion-events-\(targetId).jsonl"

        sessions.removeValue(forKey: sourceId)
        sessions.removeValue(forKey: targetId)

        win.rebind(to: targetId, eventFile: targetFile)
        targetWin.rebind(to: sourceId, eventFile: sourceFile)

        sessions[targetId] = win
        sessions[sourceId] = targetWin
        slotOwner[win.slot]      = targetId
        slotOwner[targetWin.slot] = sourceId
        if let i = sessionOrder.firstIndex(of: sourceId) { sessionOrder[i] = targetId }
        if let i = sessionOrder.firstIndex(of: targetId) { sessionOrder[i] = sourceId }

        rebuildMenu()
    }

    /// 비활동 타임아웃으로 자동 종료된 세션 제거 — 파일에 새 활동이 생길 때만 재탐지
    /// (기록을 안 남기면 안 바뀐 파일이 다음 스캔마다 새 패널로 되살아난다)
    private func removeStaledSession(id: String) {
        ignoredSessionIds[id] = Date()
        remoteSessionIds.remove(id)
        guard let win = sessions[id] else { return }
        win.teardown()
        slotOwner.removeValue(forKey: win.slot)
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        rebuildMenu()
        syncHotkeyPermissionState()
    }

    private func nextAvailableSlot() -> Int {
        var s = 0
        while slotOwner[s] != nil { s += 1 }
        return s
    }

    // MARK: - Active session (단축키 등 라우팅 기준)

    private var activeSession: SessionWindow? {
        // 권한 버블이 떠 있는 세션 우선, 없으면 가장 최근 세션
        for id in sessionOrder {
            if let win = sessions[id],
               case .permission = win.controller.state { return win }
        }
        return sessionOrder.first.flatMap { sessions[$0] }
    }

    private func syncHotkeyPermissionState() {
        let anyActive = sessions.values.contains {
            if case .permission = $0.controller.state { return true }
            if case .completed  = $0.controller.state { return true }
            return false
        }
        hotkeyMonitor.updatePermissionState(anyActive)
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = ""
            let icon = MenuBarIcon.make(size: 18)
            icon.isTemplate = true
            button.image = icon
            button.imageScaling = .scaleProportionallyDown
        }
        rebuildMenu()
    }

    /// 화면의 부니 우클릭 메뉴도 메뉴바 메뉴와 같은 기능을 쓰도록 동작을 이어 준다
    private func wireAppMenuBridge() {
        let b = AppMenuBridge.shared
        // 켜짐·꺼짐이 저절로 바뀌어도(세션 종료·시간 만료) 메뉴 제목이 맞게 바뀐다
        AwakeManager.shared.$isActive.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }.store(in: &cancellables)
        b.hideAll                = { [weak self] in self?.hideAll() }
        b.showAll                = { [weak self] in self?.showAll() }
        b.openShop               = { [weak self] in self?.openShop() }
        b.openChat               = { [weak self] in self?.openChat() }
        b.openTeam               = { [weak self] in self?.openTeam() }
        b.openUpgrade            = { [weak self] in self?.openUpgrade() }
        b.openSettings           = { [weak self] in self?.openSettings() }
        b.toggleFocusMode        = { [weak self] in self?.toggleFocusMode() }
        b.setFocusIdleMinutes    = { [weak self] m in
            FocusModeStore.shared.idleMinutes = m; self?.rebuildMenu()
        }
        b.promptFocusIdleMinutes = { [weak self] in self?.promptFocusIdleMinutes() }
        b.startKeepAwake         = { [weak self] sec in
            AwakeManager.shared.enable(duration: sec); self?.rebuildMenu()
        }
        b.startKeepAwakeFollowing = { [weak self] in self?.startKeepAwakeFollowing() }
        b.stopKeepAwake          = { [weak self] in self?.stopKeepAwake() }
        // 덮개 닫아도 계속 실행 — "세션이 끝날 때까지" 모드가 보는 '일하는 중' 판단
        AwakeManager.shared.sessionsRunningProvider = { [weak self] in
            let visible = self?.sessions.values.contains { $0.controller.state.isRunning } ?? false
            let squad = MainActor.assumeIsolated { TeamStore.shared.runningJob != nil }
            return visible || squad
        }
        b.installAwakeHelper     = { [weak self] in self?.installAwakeHelper() }
        b.toggleLaunchAtLogin    = { [weak self] in self?.toggleLaunchAtLogin() }
        b.hideStatusBar          = { [weak self] in
            guard self?.statusItem != nil else { return }
            self?.hideStatusBar(); self?.rebuildMenu()
        }
        b.showStatusBar          = { [weak self] in self?.showStatusBar() }
        b.disableAlwaysApprove   = { [weak self] in self?.disableAlwaysApprove() }
        b.downloadUpdate         = { [weak self] in self?.downloadUpdate() }
    }

    private func rebuildMenu() {
        syncHotkeyPermissionState()
        refreshSwitchTargets()
        publishAppMenuState()
        let menu = NSMenu()

        // 전체 허용 모드 상태 표시
        let anyAlwaysApprove = sessions.values.contains { $0.controller.alwaysApprove }
        if anyAlwaysApprove {
            let item = NSMenuItem(title: L.t("⚡ 전체 허용 모드 켜짐 — 클릭하여 끄기",
                                             "⚡ Approve-all is ON — click to turn off"),
                                  action: #selector(disableAlwaysApprove), keyEquivalent: "")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }

        /// 메뉴를 짧게 유지하려고 자주 쓰는 3가지만 바로 보이게 하고, 나머지는 접어 둔다
        func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            return it
        }
        func folder(_ title: String, _ build: (NSMenu) -> Void) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            build(sub)
            it.submenu = sub
            menu.addItem(it)
        }

        // ── 자주 쓰는 것: 스쿼드 · 상점 · 채팅
        let reviewCount = MainActor.assumeIsolated { TeamStore.shared.reviewCount }
        let squadItem = action(reviewCount > 0
                                ? L.t("🐰 부니 스쿼드…  (검토 대기 \(reviewCount))", "🐰 Buni Squad…  (\(reviewCount) to review)")
                                : L.t("🐰 부니 스쿼드…", "🐰 Buni Squad…"),
                            #selector(openTeam))
        // 단축키를 메뉴 옆에 보여 준다 (실제 동작은 전역 단축키가 맡는다)
        if let sc = ShortcutStore.shared.squad {
            let name = KeyShortcut.keyName(for: sc.keyCode)
            if name.count == 1 {
                squadItem.keyEquivalent = name.lowercased()
                squadItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: sc.modifiers)
            }
        }
        menu.addItem(squadItem)
        menu.addItem(action(L.t("🛍 부니 상점  (🪙 \(ShopStore.shared.coins))",
                                "🛍 Buni Shop  (🪙 \(ShopStore.shared.coins))"),
                            #selector(openShop)))
        let chatRoom = MainActor.assumeIsolated { ChatStore.shared.roomCode }
        menu.addItem(action(chatRoom.map { L.t("💬 부니 채팅  (방 \($0))", "💬 Buni Chat  (room \($0))") }
                                ?? L.t("💬 부니 채팅…", "💬 Buni Chat…"),
                            #selector(openChat)))
        let proSummary = ProManager.shared.status().summary
        menu.addItem(action(L.t("⭐ 부니 Pro  (\(proSummary))", "⭐ Buni Pro  (\(proSummary))"), #selector(openUpgrade)))
        menu.addItem(.separator())

        // ── 접어 둔 묶음 (눌러서 펼친다)
        folder(L.t("부니 화면", "On screen")) { sub in
            // 숨기기/불러오기를 하나로 토글하면, 세션 하나가 소리 없이(예: Claude
            // 종료 감지) 숨겨졌을 때 "불러오기" 항목 자체가 안 보여서 — 그걸
            // 보이게 하려고 전체를 숨겼다가 다시 불러와야 하는 번거로움이 생김.
            // 항상 둘 다 보여주고 각각 명시적으로 동작하게 한다.
            sub.addItem(action(L.t("전체 부니 숨기기", "Hide all Buni"), #selector(hideAllMenuAction), key: "h"))
            sub.addItem(action(L.t("전체 부니 불러오기", "Show all Buni"), #selector(showAllMenuAction)))
            sub.addItem(action(L.t("위치 초기화", "Reset position"), #selector(resetPosition)))
            sub.addItem(.separator())
            sub.addItem(action(L.t("Claude 열기", "Open Claude"), #selector(openClaude), key: "o"))
        }

        // 켜 둔 기능은 접힌 제목에서도 보이게 한다
        var toolBadges: [String] = []
        if AwakeManager.shared.isActive { toolBadges.append("☕️") }
        if FocusModeStore.shared.enabled { toolBadges.append("🏃") }
        folder(L.t("작업 도구", "Work tools") + (toolBadges.isEmpty ? "" : "  " + toolBadges.joined(separator: " "))) { sub in
            sub.addItem(buildKeepAwakeMenuItem())

            let focusItem = action(L.t("딴짓 방해모드", "Distraction mode"), #selector(toggleFocusMode))
            focusItem.state = FocusModeStore.shared.enabled ? .on : .off
            sub.addItem(focusItem)

            let idleItem = NSMenuItem(title: L.t("   방해 시작 시간: \(FocusModeStore.shared.idleMinutes)분",
                                                 "   Starts after: \(FocusModeStore.shared.idleMinutes) min idle"),
                                      action: nil, keyEquivalent: "")
            let idleMenu = NSMenu()
            let current = FocusModeStore.shared.idleMinutes
            for m in FocusModeStore.presetMinutes {
                let it = action(L.t("\(m)분", "\(m) min"), #selector(setFocusIdleMinutes(_:)))
                it.tag = m
                it.state = m == current ? .on : .off
                idleMenu.addItem(it)
            }
            idleMenu.addItem(.separator())
            let customIt = action(L.t("직접 입력…", "Custom…"), #selector(promptFocusIdleMinutes))
            customIt.state = FocusModeStore.presetMinutes.contains(current) ? .off : .on
            idleMenu.addItem(customIt)
            idleItem.submenu = idleMenu
            sub.addItem(idleItem)
        }

        folder(L.t("앱", "App")) { sub in
            sub.addItem(action(L.t("설정...", "Settings..."), #selector(openSettings), key: ","))
            let loginItem = action(L.t("부팅 시 자동 실행", "Launch at login"), #selector(toggleLaunchAtLogin))
            loginItem.state = isLaunchAtLoginEnabled ? .on : .off
            sub.addItem(loginItem)
            sub.addItem(action(L.t("메뉴바 아이콘 숨기기", "Hide menu bar icon"), #selector(hideStatusBar)))
        }
        menu.addItem(.separator())

        let verItem = NSMenuItem(title: "Buni v\(UpdateChecker.currentVersion)",
                                 action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)

        // 새 버전이 있으면 지금 버전 바로 아래(종료 위)에 보인다
        if let ver = availableUpdate {
            if let status = updateStatus {
                let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            } else {
                menu.addItem(action(L.t("🆕 v\(ver)로 업데이트…", "🆕 Update to v\(ver)…"), #selector(downloadUpdate)))
            }
        }

        menu.addItem(NSMenuItem(title: L.t("종료", "Quit"),
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem?.menu = menu
    }

    /// 부니 우클릭 메뉴가 보여줄 앱 전체 상태를 내보낸다 (바뀐 때만 반영됨)
    private func publishAppMenuState() {
        let anyAlways = sessions.values.contains { $0.controller.alwaysApprove }
        let (review, room) = MainActor.assumeIsolated { (TeamStore.shared.reviewCount, ChatStore.shared.roomCode) }
        AppMenuBridge.shared.update(.init(updateVersion: availableUpdate,
                                          updateStatus: updateStatus,
                                          statusBarHidden: statusItem == nil,
                                          anyAlwaysApprove: anyAlways,
                                          launchAtLogin: isLaunchAtLoginEnabled,
                                          reviewCount: review,
                                          chatRoom: room,
                                          proSummary: ProManager.shared.status().summary))
    }

    // MARK: - 덮개 닫아도 계속 실행

    /// 맥북 덮개를 닫아도 Claude가 계속 돌게 하는 메뉴.
    /// 시스템 절전을 끄는 일이라 상태와 남은 시간을 항상 보이게 하고,
    /// 권한 등록 전에는 안내 항목만 띄운다.
    private func buildKeepAwakeMenuItem() -> NSMenuItem {
        let awake = AwakeManager.shared
        let title: String
        if awake.isActive {
            let remain = awake.statusText
            title = L.t("☕️ 덮개 닫아도 실행 중 — \(remain)",
                        "☕️ Staying awake — \(remain)")
        } else {
            title = L.t("덮개 닫아도 계속 실행", "Keep running with lid closed")
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub  = NSMenu()

        if !awake.isHelperInstalled {
            let setup = NSMenuItem(title: L.t("권한 설정하기… (최초 1회)", "Set up permission… (one time)"),
                                   action: #selector(installAwakeHelper), keyEquivalent: "")
            setup.target = self
            sub.addItem(setup)
            let note = NSMenuItem(title: L.t("덮개를 닫아도 자지 않으려면 관리자 권한이 필요해요",
                                             "Admin rights are needed to stay awake with the lid closed"),
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
            item.submenu = sub
            return item
        }

        // 세션이 도는 동안만 켜 두고, 다 끝나면 같이 끈다 (시간을 정하지 않아도 되는 쪽)
        let follow = NSMenuItem(title: L.t("세션 실행 중에만 (끝나면 자동 해제)", "While sessions run (auto-off when done)"),
                                action: #selector(startKeepAwakeFollowing), keyEquivalent: "")
        follow.target = self
        follow.state = awake.followingSessions ? .on : .off
        sub.addItem(follow)
        sub.addItem(.separator())

        let durations: [(String, String, TimeInterval?)] = [
            ("30분",    "30 min", 30 * 60),
            ("1시간",   "1 hour", 60 * 60),
            ("2시간",   "2 hours", 2 * 3600),
            ("4시간",   "4 hours", 4 * 3600),
            ("무제한",  "No limit", nil),
        ]
        for (ko, en, seconds) in durations {
            let m = NSMenuItem(title: L.t(ko, en), action: #selector(startKeepAwake(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = seconds.map { NSNumber(value: $0) } ?? NSNull()
            sub.addItem(m)
        }
        sub.addItem(.separator())

        let off = NSMenuItem(title: L.t("지금 끄기", "Turn off now"),
                             action: #selector(stopKeepAwake), keyEquivalent: "")
        off.target = self
        off.isEnabled = awake.isActive
        sub.addItem(off)

        let sched = NSMenuItem(title: awake.scheduleEnabled
                                 ? L.t("시간대 예약 켜짐 (\(AwakeManager.hhmm(awake.scheduleStartMinute))~\(AwakeManager.hhmm(awake.scheduleEndMinute)))",
                                       "Schedule on (\(AwakeManager.hhmm(awake.scheduleStartMinute))–\(AwakeManager.hhmm(awake.scheduleEndMinute)))")
                                 : L.t("시간대 예약 설정…", "Set daily schedule…"),
                               action: #selector(openSettings), keyEquivalent: "")
        sched.target = self
        sub.addItem(sched)

        if let err = awake.lastError {
            let e = NSMenuItem(title: "⚠️ " + err, action: nil, keyEquivalent: "")
            e.isEnabled = false
            sub.addItem(e)
        }
        item.submenu = sub
        return item
    }

    @objc private func startKeepAwake(_ sender: NSMenuItem) {
        let seconds = (sender.representedObject as? NSNumber)?.doubleValue
        AwakeManager.shared.enable(duration: seconds)
        rebuildMenu()
    }

    @objc private func startKeepAwakeFollowing() {
        AwakeManager.shared.enableUntilSessionsFinish()
        rebuildMenu()
    }

    @objc private func stopKeepAwake() {
        AwakeManager.shared.disable()
        rebuildMenu()
    }

    @objc private func installAwakeHelper() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.t("덮개 닫아도 계속 실행", "Keep running with lid closed")
        alert.informativeText = L.t(
            "맥북은 덮개를 닫으면 바로 잠들기 때문에, 이를 막으려면 관리자 권한이 한 번 필요합니다.\n\n"
            + "확인을 누르면 비밀번호를 물어보고, 절전을 켜고 끄는 명령 두 개만 비밀번호 없이 쓸 수 있도록 등록합니다. "
            + "그 외의 권한은 주지 않으며, 설정에서 언제든 해제할 수 있어요.\n\n"
            + "덮개를 닫은 채 오래 돌리면 가방 안에서 열이 오를 수 있으니 시간을 정해두는 걸 권합니다.",
            "A MacBook sleeps as soon as the lid closes, so preventing that needs admin rights once.\n\n"
            + "Click OK to enter your password; only the two commands that turn sleep off and on are registered "
            + "for password-free use. Nothing else is granted, and you can remove it anytime in Settings.\n\n"
            + "Running for long with the lid closed can get hot in a bag — setting a time limit is recommended.")
        alert.addButton(withTitle: L.t("확인", "OK"))
        alert.addButton(withTitle: L.t("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        AwakeManager.shared.installHelper { [weak self] ok, message in
            self?.rebuildMenu()
            let done = NSAlert()
            done.messageText = ok ? L.t("설정 완료", "All set")
                                  : L.t("설정하지 못했어요", "Setup failed")
            done.informativeText = ok
                ? L.t("이제 메뉴에서 시간을 골라 켜고 끌 수 있어요.",
                      "You can now turn it on and off from the menu.")
                : (message ?? "")
            done.runModal()
        }
    }

    /// 새 버전을 앱 안에서 내려받아 설치하고 다시 시작한다. 실패하면 이유를 알리고 릴리스 페이지를 열 수 있다.
    @objc private func downloadUpdate() {
        guard let ver = availableUpdate, updateStatus == nil else { return }
        let ask = NSAlert()
        ask.messageText = L.t("Buni v\(ver)로 업데이트할까요?", "Update to Buni v\(ver)?")
        ask.informativeText = L.t("새 버전을 내려받아 설치하고 Buni를 다시 시작해요. 채팅 방에 있다면 잠시 나갔다 다시 들어와야 해요. "
                                  + "다시 시작한 뒤 키체인 허용 창이 뜨면 '항상 허용'을 눌러 주세요.",
                                  "Buni will download the new version, install it and restart. If you're in a chat room you'll need to rejoin. "
                                  + "If a Keychain prompt appears after restarting, choose “Always Allow”.")
        ask.addButton(withTitle: L.t("업데이트", "Update"))
        ask.addButton(withTitle: L.t("나중에", "Later"))
        ask.addButton(withTitle: L.t("릴리스 페이지 열기", "Open release page"))
        NSApp.activate(ignoringOtherApps: true)
        switch ask.runModal() {
        case .alertFirstButtonReturn:
            updateStatus = L.t("⬇ 업데이트 준비 중…", "⬇ Preparing update…")
            rebuildMenu()
            SelfUpdater.shared.start(expectedVersion: ver, progress: { [weak self] text in
                self?.updateStatus = text; self?.rebuildMenu()
            }, completion: { [weak self] failure in
                guard let self, let failure else { return }
                self.updateStatus = nil; self.rebuildMenu()
                let err = NSAlert()
                err.messageText = L.t("업데이트하지 못했어요", "Update failed")
                err.informativeText = failure.localizedDescription + "\n\n"
                    + L.t("지금 쓰던 앱은 그대로예요. 릴리스 페이지에서 직접 받을 수 있어요.", "Your current app is unchanged. You can download it from the release page.")
                err.addButton(withTitle: L.t("릴리스 페이지 열기", "Open release page"))
                err.addButton(withTitle: L.t("닫기", "Close"))
                if err.runModal() == .alertFirstButtonReturn { UpdateChecker.openReleasePage() }
            })
        case .alertThirdButtonReturn:
            UpdateChecker.openReleasePage()
        default: break
        }
    }

    @objc private func hideStatusBar() {
        NSStatusBar.system.removeStatusItem(statusItem!)
        statusItem = nil
        UserDefaults.standard.set(true, forKey: "statusBar.hidden")
    }

    func showStatusBar() {
        guard statusItem == nil else { return }
        setupStatusBar()
        UserDefaults.standard.set(false, forKey: "statusBar.hidden")
    }

    @objc private func disableAlwaysApprove() {
        sessions.values.forEach { $0.controller.alwaysApprove = false }
    }

    @objc func toggleVisibility() {
        let anyVisible = sessions.values.contains { $0.panel?.isVisible == true }
        anyVisible ? hideAll() : showAll()
    }

    @objc private func hideAllMenuAction() { hideAll() }
    @objc private func showAllMenuAction() { showAll() }

    /// 전체 숨김 — 메뉴바의 "전체 부니 숨기기".
    /// 각 패널은 "그 세션이 새로 시작될 때"까지 숨어 있고(진행 중에 숨겼다면 그
    /// 작업이 끝나고 다음 작업이 시작될 때), 그 사이에 새로 만들어지는 패널도
    /// 나타나지 않는다. "전체 부니 불러오기"를 누르면 즉시 다시 보인다.
    func hideAll() {
        hiddenUntilNextRunStart = true
        sessions.values.forEach { $0.hideThisCompanion() }
    }

    func showAll() {
        hiddenUntilNextRunStart = false
        sessions.values.forEach { $0.showCompanion() }
    }

    @objc func openClaude() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    @objc func openChat() {
        Task { @MainActor in ChatWindowController.shared.showLobby() }
    }

    /// 메뉴바가 없는(accessory) 앱은 ⌘C·⌘V·⌘X·⌘A·⌘Z 가 어디서도 안 먹는다 — 글씨 복사, 입력창 붙여넣기가 되도록 보이지 않는 편집 메뉴를 단다.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L.t("편집", "Edit"))
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            edit.addItem(it)
        }
        add(L.t("실행 취소", "Undo"), Selector(("undo:")), "z")
        add(L.t("다시 실행", "Redo"), Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(L.t("잘라내기", "Cut"), #selector(NSText.cut(_:)), "x")
        add(L.t("복사", "Copy"), #selector(NSText.copy(_:)), "c")
        add(L.t("붙여넣기", "Paste"), #selector(NSText.paste(_:)), "v")
        add(L.t("전체 선택", "Select All"), #selector(NSText.selectAll(_:)), "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc func openUpgrade() { ProUpgradeWindow.show() }

    @objc func openTeam() {
        Task { @MainActor in TeamWindowController.shared.show() }
    }

    // MARK: - 채팅 부니 모션

    private var chatMotionTimer: Timer?

    /// 내 세션들의 상태를 한 가지 모션으로 요약해 채팅방에 알린다.
    /// 하나라도 작업 중이면 작업 중, 아니면 완료된 세션이 있으면 완료, 그 밖엔 대기.
    /// (세션 이름·작업 내용은 보내지 않는다 — 모션만 간다)
    private func startChatMotionTimer() {
        chatMotionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let states = self.sessions.values.map { $0.controller.state }
            let motion: ChatMotion
            if states.contains(where: { $0.isRunning }) { motion = .working }
            else if states.contains(where: { if case .completed = $0 { return true } else { return false } }) { motion = .done }
            else { motion = .idle }
            Task { @MainActor in
                ChatStore.shared.setLocalMotion(motion)
                self.rebuildMenuIfChatChanged()
            }
        }
        chatMotionTimer?.tolerance = 1
    }

    private var lastChatMenuRoom: String?
    @MainActor private func rebuildMenuIfChatChanged() {
        let room = ChatStore.shared.roomCode
        if room != lastChatMenuRoom { lastChatMenuRoom = room; rebuildMenu() }
    }

    @objc func openShop() {
        if let win = shopWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: ShopView()))
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 440, height: 600))
        win.contentMinSize = NSSize(width: 420, height: 520)
        win.title = L.t("부니 상점", "Buni Shop")
        win.backgroundColor = NSColor(BT.bgCanvas)
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shopWindow = win
    }

    @objc func openSettings() {
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        // 창에 올리기 전의 fittingSize는 실제보다 작게 나와 내용이 잘렸다.
        // 크기 계산은 NSHostingController에 맡기고, 넉넉한 기본 크기 + 스크롤로
        // 설정 항목이 늘어도 잘리지 않게 한다.
        let hosting = NSHostingController(rootView: ShortcutSettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 400, height: 560))
        win.contentMinSize = NSSize(width: 380, height: 360)
        win.title = L.t("설정", "Settings")
        win.backgroundColor = NSColor(BT.bgCanvas)
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    @objc func resetPosition() {
        // 모든 슬롯이 위치를 저장하므로, 메뉴의 "위치 초기화"도 떠 있는
        // 세션 전부를 기본 위치로 되돌린다.
        sessions.values.forEach { $0.controller.onResetPositionRequest?() }
    }

    // MARK: - 부팅 시 자동 실행

    /// 메뉴를 다시 만들 때마다 시스템(XPC)에 묻지 않도록 잠깐 기억해 둔다 — 세션이 자주 생기고 사라질 때 메인 스레드가 막히지 않게
    private var loginStatusCache: (at: Date, enabled: Bool)?
    private var isLaunchAtLoginEnabled: Bool {
        if let c = loginStatusCache, Date().timeIntervalSince(c.at) < 30 { return c.enabled }
        let v = SMAppService.mainApp.status == .enabled
        loginStatusCache = (Date(), v)
        return v
    }

    // MARK: - 딴짓 방해모드

    @objc private func toggleFocusMode() {
        FocusModeStore.shared.enabled.toggle()
        rebuildMenu()
    }

    @objc private func setFocusIdleMinutes(_ sender: NSMenuItem) {
        FocusModeStore.shared.idleMinutes = sender.tag
        rebuildMenu()
    }

    @objc private func promptFocusIdleMinutes() {
        let alert = NSAlert()
        alert.messageText = L.t("딴짓 방해모드", "Distraction mode")
        alert.informativeText = L.t("마우스·키보드 입력이 몇 분 이상 없으면 부니가 돌아다닐까요?",
                                    "After how many minutes without mouse/keyboard input should Buni start wandering?")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(FocusModeStore.shared.idleMinutes)"
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("확인", "OK"))
        alert.addButton(withTitle: L.t("취소", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), m > 0 else { return }
        FocusModeStore.shared.idleMinutes = min(m, 24 * 60)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        loginStatusCache = nil                       // 바꾸기 직전에는 기억해 둔 값을 믿지 않는다
        do {
            if isLaunchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else                      { try SMAppService.mainApp.register() }
        } catch {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
        loginStatusCache = nil
        rebuildMenu()
    }

    // MARK: - Hotkey monitor

    private func setupHotkeyMonitor() {
        let store = ShortcutStore.shared
        hotkeyMonitor.updateShortcuts(approve: store.approve, deny: store.deny,
                                      hide: store.hide, alwaysApprove: store.alwaysApprove, chat: store.chat,
                                      squad: store.squad)
        // 승인·거부: 권한 요청 중인 모든 세션에 동시 적용
        hotkeyMonitor.onApprove = { [weak self] in
            self?.sessions.values.forEach {
                if case .permission = $0.controller.state { $0.controller.approvePermission() }
                else if case .completed = $0.controller.state { $0.controller.dismissCompleted() }
            }
        }
        hotkeyMonitor.onDeny = { [weak self] in
            self?.sessions.values.forEach {
                if case .permission = $0.controller.state { $0.controller.denyPermission() }
            }
        }
        hotkeyMonitor.onHide          = { [weak self] in self?.toggleVisibility() }
        hotkeyMonitor.onSquad = { Task { @MainActor in TeamWindowController.shared.toggle() } }
        // 채팅 입력: 방에 있으면 닉네임 자리에 입력창을 열고, 방 밖이면 채팅 창(로비)을 연다
        hotkeyMonitor.onChat = {
            Task { @MainActor in
                let chat = ChatStore.shared
                if chat.isInRoom {
                    chat.nameEditing = false
                    chat.inputActive = true
                    chat.inputTouched = Date()
                    ChatWindowController.shared.focusInput()
                } else {
                    ChatWindowController.shared.showLobby()
                }
            }
        }
        // 전체 허용: 모든 세션에 동시 적용 (완료 상태면 확인으로 동작)
        hotkeyMonitor.onAlwaysApprove = { [weak self] in
            self?.sessions.values.forEach {
                if case .completed = $0.controller.state { $0.controller.dismissCompleted() }
                else { $0.controller.approveAllPermissions() }
            }
        }
    }

    private func setupSettingsCallbacks() {
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                ShortcutStore.shared.$approve,
                ShortcutStore.shared.$deny,
                ShortcutStore.shared.$hide,
                ShortcutStore.shared.$alwaysApprove
            ),
            Publishers.CombineLatest(ShortcutStore.shared.$chat, ShortcutStore.shared.$squad)
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] four, extra in
            self?.hotkeyMonitor.updateShortcuts(approve: four.0, deny: four.1,
                                                hide: four.2, alwaysApprove: four.3,
                                                chat: extra.0, squad: extra.1)
            self?.rebuildMenu()          // 메뉴 옆 단축키 표시도 바뀐 값으로
        }
        .store(in: &cancellables)

        // 메뉴바 메뉴는 AppKit이라 SwiftUI처럼 저절로 다시 그려지지 않는다 —
        // 언어가 바뀌면 직접 다시 만들어 준다.
        LanguageStore.shared.$current
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    // MARK: - Update checker

    private func setupUpdateChecker() {
        UpdateChecker.shared.onUpdateFound = { [weak self] ver in
            guard let self, self.availableUpdate != ver else { return }
            self.availableUpdate = ver
            self.rebuildMenu()
            self.sessions.values.forEach {
                $0.controller.update(to: .notification(L.t("🆕 Buni v\(ver) 업데이트",
                                                          "🆕 Buni v\(ver) available")),
                                     autohideAfter: 8)
            }
        }
        UpdateChecker.shared.startPeriodicCheck()
    }
}
