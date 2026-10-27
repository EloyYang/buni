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
    private var claudeNotRunningStreak  = 0      // sysctl 경합 방지 디바운스 카운터
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.ensureInstalled()
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
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.scanForSessions() }
        t.resume()
        scanTimer = t
    }

    private func scanForSessions() {
        let claudeRunning = isClaudeRunning()
        let wasInitial    = isInitialScan
        isInitialScan     = false

        // ── Claude 종료 감지 (디바운스: sysctl 경합 등으로 인한 false negative 방지)
        // 3초(6틱) 연속 "실행 중 아님"일 때만 반응.
        if claudeRunning {
            claudeNotRunningStreak = 0
            claudeWasRunning = true
        } else {
            claudeNotRunningStreak += 1
        }

        if claudeWasRunning && claudeNotRunningStreak >= 6 {
            // Claude 종료 확인 — 활성 세션(thinking/toolUse 등) 제거, 완료·권한 버블은 유지
            claudeWasRunning = false
            DispatchQueue.main.async {
                self.cleanupInactiveSessions()
            }
        }

        guard claudeRunning else { return }

        // ── 세션 파일 스캔
        let tmp = URL(fileURLWithPath: "/tmp")
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
                if now.timeIntervalSince(modDate) < threshold {
                    hasRecentSession = true
                    DispatchQueue.main.async {
                        self.ignoredSessionIds.removeValue(forKey: sid)
                        self.addSession(id: sid, fileURL: url)
                    }
                }
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

    private func addSession(id: String, fileURL: URL) {
        guard sessions[id] == nil else { return }

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
        rebuildMenu()
        syncHotkeyPermissionState()
    }

    private func wire(_ win: SessionWindow) {
        win.onOpenClaude    = { [weak self] in self?.openClaude() }
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

    /// 비활동 타임아웃으로 자동 종료된 세션 제거 — ignoredSessionIds에 추가하지 않아 재탐지 허용
    private func removeStaledSession(id: String) {
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

    private func rebuildMenu() {
        syncHotkeyPermissionState()
        refreshSwitchTargets()
        let menu = NSMenu()

        if let ver = availableUpdate {
            if let status = updateStatus {
                let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            } else {
                let item = NSMenuItem(title: L.t("🆕 v\(ver)로 업데이트…", "🆕 Update to v\(ver)…"),
                                      action: #selector(downloadUpdate), keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 전체 허용 모드 상태 표시
        let anyAlwaysApprove = sessions.values.contains { $0.controller.alwaysApprove }
        if anyAlwaysApprove {
            let item = NSMenuItem(title: L.t("⚡ 전체 허용 모드 켜짐 — 클릭하여 끄기",
                                             "⚡ Approve-all is ON — click to turn off"),
                                  action: #selector(disableAlwaysApprove), keyEquivalent: "")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }

        /// 기능별 묶음 머리글 — 눌리지 않는 작은 제목
        func header(_ ko: String, _ en: String) {
            if #available(macOS 14.0, *) {
                menu.addItem(NSMenuItem.sectionHeader(title: L.t(ko, en)))
            } else {
                let h = NSMenuItem(title: L.t(ko, en), action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
            }
        }

        // ── 부니 화면
        // 숨기기/불러오기를 하나로 토글하면, 세션 하나가 소리 없이(예: Claude
        // 종료 감지) 숨겨졌을 때 "불러오기" 항목 자체가 안 보여서 — 그걸
        // 보이게 하려고 전체를 숨겼다가 다시 불러와야 하는 번거로움이 생김.
        // 항상 둘 다 보여주고 각각 명시적으로 동작하게 한다.
        header("부니 화면", "On screen")
        menu.addItem(NSMenuItem(title: L.t("전체 부니 숨기기", "Hide all Buni"),
                                action: #selector(hideAllMenuAction), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: L.t("전체 부니 불러오기", "Show all Buni"),
                                action: #selector(showAllMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.t("위치 초기화", "Reset position"),
                                action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.t("Claude 열기", "Open Claude"),
                                action: #selector(openClaude), keyEquivalent: "o"))
        menu.addItem(.separator())

        // ── 꾸미기 · 함께하기
        header("꾸미기 · 함께하기", "Style & together")
        let shopItem = NSMenuItem(title: L.t("🛍 부니 상점  (🪙 \(ShopStore.shared.coins))",
                                             "🛍 Buni Shop  (🪙 \(ShopStore.shared.coins))"),
                                  action: #selector(openShop), keyEquivalent: "")
        shopItem.target = self
        menu.addItem(shopItem)

        let chatRoom = MainActor.assumeIsolated { ChatStore.shared.roomCode }
        let chatTitle = chatRoom.map { L.t("💬 부니 채팅  (방 \($0))", "💬 Buni Chat  (room \($0))") }
                        ?? L.t("💬 부니 채팅…", "💬 Buni Chat…")
        let chatItem = NSMenuItem(title: chatTitle, action: #selector(openChat), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)
        menu.addItem(.separator())

        // ── 작업 도구
        header("작업 도구", "Work tools")
        menu.addItem(buildKeepAwakeMenuItem())

        let focusItem = NSMenuItem(title: L.t("딴짓 방해모드", "Distraction mode"),
                                   action: #selector(toggleFocusMode), keyEquivalent: "")
        focusItem.state = FocusModeStore.shared.enabled ? .on : .off
        menu.addItem(focusItem)
        menu.addItem(.separator())

        // ── 앱 설정
        header("앱", "App")
        menu.addItem(NSMenuItem(title: L.t("설정...", "Settings..."),
                                action: #selector(openSettings), keyEquivalent: ","))

        let loginItem = NSMenuItem(title: L.t("부팅 시 자동 실행", "Launch at login"),
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: L.t("메뉴바 아이콘 숨기기", "Hide menu bar icon"),
                                action: #selector(hideStatusBar), keyEquivalent: ""))
        menu.addItem(.separator())

        let verItem = NSMenuItem(title: "Buni v\(UpdateChecker.currentVersion)",
                                 action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)

        menu.addItem(NSMenuItem(title: L.t("종료", "Quit"),
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem?.menu = menu
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
        win.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
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
        win.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
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

    private var isLaunchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - 딴짓 방해모드

    @objc private func toggleFocusMode() {
        FocusModeStore.shared.enabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else                      { try SMAppService.mainApp.register() }
        } catch {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
        rebuildMenu()
    }

    // MARK: - Hotkey monitor

    private func setupHotkeyMonitor() {
        let store = ShortcutStore.shared
        hotkeyMonitor.updateShortcuts(approve: store.approve, deny: store.deny,
                                      hide: store.hide, alwaysApprove: store.alwaysApprove, chat: store.chat)
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
            ShortcutStore.shared.$chat
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] four, chat in
            self?.hotkeyMonitor.updateShortcuts(approve: four.0, deny: four.1,
                                                hide: four.2, alwaysApprove: four.3, chat: chat)
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
