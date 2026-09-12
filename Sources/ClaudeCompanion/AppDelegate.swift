import Cocoa
import SwiftUI
import Combine
import ServiceManagement
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyMonitor = HotkeyMonitor()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var availableUpdate: String? = nil

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

    // ── 사용자가 명시적으로 숨긴 상태 — true이면 새 세션도 자동 표시하지 않음
    private var isManuallyHidden = false

    // ── 위치 영속성 (슬롯 0 전용)
    private var savedOrigin: NSPoint? {
        get {
            guard UserDefaults.standard.object(forKey: "panel.x") != nil else { return nil }
            let p = NSPoint(x: UserDefaults.standard.double(forKey: "panel.x"),
                             y: UserDefaults.standard.double(forKey: "panel.y"))
            // 외장 모니터 분리 등으로 화면 구성이 바뀌어 저장된 위치가 모든 화면
            // 밖으로 완전히 벗어난 경우, 화면 밖에 갇히지 않도록 저장값을 버리고
            // 기본 위치(우측 상단)를 쓴다.
            let panelRect = NSRect(x: p.x, y: p.y, width: 320, height: 200)
            let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(panelRect) }
            guard onAnyScreen else {
                UserDefaults.standard.removeObject(forKey: "panel.x")
                UserDefaults.standard.removeObject(forKey: "panel.y")
                return nil
            }
            return p
        }
        set {
            if let p = newValue, p.x >= 0 {
                UserDefaults.standard.set(Double(p.x), forKey: "panel.x")
                UserDefaults.standard.set(Double(p.y), forKey: "panel.y")
            } else {
                UserDefaults.standard.removeObject(forKey: "panel.x")
                UserDefaults.standard.removeObject(forKey: "panel.y")
            }
        }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.ensureInstalled()
        setupSocketServer()
        if !UserDefaults.standard.bool(forKey: "statusBar.hidden") {
            setupStatusBar()
        }
        setupHotkeyMonitor()
        setupSettingsCallbacks()
        setupUpdateChecker()
        startSessionScanner()
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

        let origin = slot == 0 ? savedOrigin : nil
        let win = SessionWindow(sessionId: id, slot: slot,
                                eventFile: fileURL.path,
                                savedOrigin: origin)
        wire(win)
        sessions[id] = win
        slotOwner[slot] = id
        sessionOrder.insert(id, at: 0)
        // 사용자가 명시적으로 숨긴 상태라면 새 세션도 표시하지 않음
        win.setup(autoShow: !isManuallyHidden)
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
        win.shouldAutoShow  = { [weak self] in !(self?.isManuallyHidden ?? false) }
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
            guard win.slot == 0 else { return }
            self?.savedOrigin = origin
        }
    }

    /// 모든 세션 창의 "다른 세션으로 전환" 목록을 다시 계산해 반영한다.
    /// 세션 추가·제거·전환마다 호출 — 우클릭 메뉴가 항상 최신 목록을 보여주게 한다.
    private func refreshSwitchTargets() {
        for (sid, win) in sessions {
            win.controller.switchTargets = sessions.compactMap { (otherSid, otherWin) -> SessionSwitchTarget? in
                guard otherSid != sid else { return nil }
                let label = otherWin.controller.memo.isEmpty ? "세션 \(otherWin.slot + 1)" : otherWin.controller.memo
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
            let item = NSMenuItem(title: "🆕 업데이트 v\(ver) — 다운로드",
                                  action: #selector(downloadUpdate), keyEquivalent: "")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }

        // 전체 허용 모드 상태 표시
        let anyAlwaysApprove = sessions.values.contains { $0.controller.alwaysApprove }
        if anyAlwaysApprove {
            let item = NSMenuItem(title: "⚡ 전체 허용 모드 켜짐 — 클릭하여 끄기",
                                  action: #selector(disableAlwaysApprove), keyEquivalent: "")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }

        // 숨기기/불러오기를 하나로 토글하면, 세션 하나가 소리 없이(예: Claude
        // 종료 감지) 숨겨졌을 때 "불러오기" 항목 자체가 안 보여서 — 그걸
        // 보이게 하려고 전체를 숨겼다가 다시 불러와야 하는 번거로움이 생김.
        // 항상 둘 다 보여주고 각각 명시적으로 동작하게 한다.
        menu.addItem(NSMenuItem(title: "전체 부니 숨기기",
                                action: #selector(hideAllMenuAction), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "전체 부니 불러오기",
                                action: #selector(showAllMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Claude 열기",
                                action: #selector(openClaude), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "위치 초기화",
                                action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "단축키 설정...",
                                action: #selector(openSettings), keyEquivalent: ","))

        let focusItem = NSMenuItem(title: "딴짓 방해모드",
                                   action: #selector(toggleFocusMode), keyEquivalent: "")
        focusItem.state = FocusModeStore.shared.enabled ? .on : .off
        menu.addItem(focusItem)

        let loginItem = NSMenuItem(title: "부팅 시 자동 실행",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "메뉴바 아이콘 숨기기",
                                action: #selector(hideStatusBar), keyEquivalent: ""))
        menu.addItem(.separator())

        let verItem = NSMenuItem(title: "Buni v\(UpdateChecker.currentVersion)",
                                 action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)

        menu.addItem(NSMenuItem(title: "종료",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem?.menu = menu
    }

    @objc private func downloadUpdate() { UpdateChecker.openReleasePage() }

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
    /// isManuallyHidden을 켜서, 이후 어떤 상태 변화나 새 Claude 세션이 와도
    /// "전체 부니 불러오기"를 누르기 전까지는 자동으로 다시 나타나지 않게 한다.
    func hideAll() {
        isManuallyHidden = true
        sessions.values.forEach { $0.hideCompanion() }
    }

    func showAll() {
        isManuallyHidden = false
        sessions.values.forEach { $0.showCompanion() }
    }

    @objc func openClaude() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    @objc func openSettings() {
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hostingView = NSHostingView(rootView: ShortcutSettingsView())
        hostingView.autoresizingMask = [.width, .height]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "단축키 설정"
        win.contentView = hostingView
        win.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    @objc func resetPosition() {
        sessions.values.first { $0.slot == 0 }?.controller.onResetPositionRequest?()
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
                                      hide: store.hide, alwaysApprove: store.alwaysApprove)
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
        // 전체 허용: 모든 세션에 동시 적용 (완료 상태면 확인으로 동작)
        hotkeyMonitor.onAlwaysApprove = { [weak self] in
            self?.sessions.values.forEach {
                if case .completed = $0.controller.state { $0.controller.dismissCompleted() }
                else { $0.controller.approveAllPermissions() }
            }
        }
    }

    private func setupSettingsCallbacks() {
        Publishers.CombineLatest4(
            ShortcutStore.shared.$approve,
            ShortcutStore.shared.$deny,
            ShortcutStore.shared.$hide,
            ShortcutStore.shared.$alwaysApprove
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] approve, deny, hide, alwaysApprove in
            self?.hotkeyMonitor.updateShortcuts(approve: approve, deny: deny,
                                                hide: hide, alwaysApprove: alwaysApprove)
        }
        .store(in: &cancellables)
    }

    // MARK: - Update checker

    private func setupUpdateChecker() {
        UpdateChecker.shared.onUpdateFound = { [weak self] ver in
            guard let self, self.availableUpdate != ver else { return }
            self.availableUpdate = ver
            self.rebuildMenu()
            self.sessions.values.forEach {
                $0.controller.update(to: .notification("🆕 Buni v\(ver) 업데이트"), autohideAfter: 8)
            }
        }
        UpdateChecker.shared.startPeriodicCheck()
    }
}
