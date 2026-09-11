import Cocoa
import SwiftUI
import Combine

/// 하나의 Claude 세션에 대응하는 부니 패널 + 컨트롤러 + 이벤트 모니터
class SessionWindow {
    /// 다른 세션으로 전환(rebind)하면 바뀔 수 있어 var — 패널·슬롯은 그대로 두고
    /// 표시하는 세션만 바꾼다
    private(set) var sessionId: String

    /// 화면 위치 슬롯 — 0이 최상단, 이후 아래로 쌓임 (panelHeight + 8px 간격)
    let slot: Int

    let controller: CompanionController
    private var monitor: EventMonitor
    private(set) var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth:  CGFloat = 320
    private let panelHeight: CGFloat = 200

    /// 슬롯 0 전용 저장 위치 (nil = 기본 오른쪽 상단)
    var customOrigin: NSPoint?

    private var isDragging   = false
    private var lastMouseLoc: NSPoint = .zero
    private var dragMonitor:  Any?
    private var mouseMonitor: Any?

    /// 집중모드 — 대기 중일 때 화면을 돌아다니는 상태
    private var focusModeCancellable: AnyCancellable?
    private var wanderWorkItem: DispatchWorkItem?
    private var isWandering = false

    /// 세션 이름 → 메모 자동 연동용 폴링
    private var titleSyncTimer: DispatchSourceTimer?
    private let titleQueue = DispatchQueue(label: "buni.session.title", qos: .utility)

    // ── AppDelegate 에서 주입하는 콜백
    var onOpenClaude:         (() -> Void)?
    var onOpenSettings:       (() -> Void)?
    var onShowStatusBar:      (() -> Void)?
    var onSessionEnded:       (() -> Void)?   // 사용자 확인 / 프로세스 종료 → ignoredSessionIds 추가
    var onStaledSessionEnded: (() -> Void)?   // 비활동 타임아웃 → ignoredSessionIds 추가 안 함 (재탐지 허용)
    /// 슬롯 0이 드래그로 위치를 바꿀 때 저장 요청 (NSPoint(-1,-1) = 리셋)
    var onSaveOrigin:    ((NSPoint) -> Void)?
    var onRebuildMenu:   (() -> Void)?
    /// 사용자가 직접 숨긴 상태가 아닐 때만 true — 활동 재개 시 자동 재표시 판단용
    var shouldAutoShow:  (() -> Bool)?
    /// 패널 우클릭 메뉴의 "숨기기" — 메뉴바의 "부니 숨기기"와 동일하게 전체를
    /// 숨기고 자동 재표시를 끈다 (이 세션만 숨기면 isManuallyHidden과 어긋나
    /// 다른 상태 변화로 되살아나 버리는 문제가 있었음)
    var onGlobalHideRequest: (() -> Void)?
    /// 다른 세션으로 전환 요청 (우클릭 메뉴 "다른 세션으로 전환") — 대상 세션 id 전달
    var onSwitchSession: ((String) -> Void)?

    init(sessionId: String, slot: Int, eventFile: String, savedOrigin: NSPoint? = nil) {
        self.sessionId    = sessionId
        self.slot         = slot
        self.customOrigin = savedOrigin

        let ctrl = CompanionController()
        // 캐릭터 복원: 세션 UUID → 슬롯 기반 → 전역 기본값 순서로 시도
        if let raw  = UserDefaults.standard.string(forKey: "character.session.\(sessionId)"),
           let type = CharacterType(rawValue: raw) {
            ctrl.character = type
        } else if let raw  = UserDefaults.standard.string(forKey: "character.slot.\(slot)"),
                  let type = CharacterType(rawValue: raw) {
            ctrl.character = type
        }
        // 메모 복원
        // 이 세션에 사용자가 직접 지정한 메모가 있으면(빈 문자열 = 직접 지운 상태 포함)
        // 그대로 쓰고 자동 연동을 끈다. 없으면 슬롯 메모를 임시로 보여주되 자동 상태로
        // 두어, 잠시 뒤 세션 이름을 읽어오면 그것으로 대체되게 한다.
        if UserDefaults.standard.object(forKey: "memo.session.\(sessionId)") != nil {
            ctrl.memo       = UserDefaults.standard.string(forKey: "memo.session.\(sessionId)") ?? ""
            ctrl.memoIsAuto = false
        } else {
            ctrl.memo       = UserDefaults.standard.string(forKey: "memo.slot.\(slot)") ?? ""
            ctrl.memoIsAuto = true
        }
        // 전체 허용 모드 복원: 세션 UUID → 슬롯 기반 순서로 시도
        // (부니 재시작마다 꺼져서 실제로 필요 없는 승인 팝업이 재등장하는 것 방지)
        if UserDefaults.standard.object(forKey: "alwaysApprove.session.\(sessionId)") != nil {
            ctrl.alwaysApprove = UserDefaults.standard.bool(forKey: "alwaysApprove.session.\(sessionId)")
        } else if UserDefaults.standard.object(forKey: "alwaysApprove.slot.\(slot)") != nil {
            ctrl.alwaysApprove = UserDefaults.standard.bool(forKey: "alwaysApprove.slot.\(slot)")
        }
        self.controller = ctrl
        self.monitor    = EventMonitor(controller: ctrl, eventFile: eventFile)
        monitor.onSessionEnded = { [weak self] in
            DispatchQueue.main.async { self?.endSession() }
        }
    }

    // MARK: - 다른 세션으로 전환

    /// 패널(위치·슬롯·NSPanel)은 그대로 두고 표시하는 세션만 바꾼다.
    /// init과 동일한 순서로 캐릭터·메모·전체 허용을 새 세션 기준으로 다시 불러오고,
    /// 이벤트 모니터를 새 파일로 교체해 새 세션의 실제 상태를 곧 반영하게 한다.
    func rebind(to newSessionId: String, eventFile: String) {
        guard newSessionId != sessionId else { return }

        monitor.stop()
        stopTitleSync()
        sessionId = newSessionId

        if let raw  = UserDefaults.standard.string(forKey: "character.session.\(sessionId)"),
           let type = CharacterType(rawValue: raw) {
            controller.character = type
        } else if let raw  = UserDefaults.standard.string(forKey: "character.slot.\(slot)"),
                  let type = CharacterType(rawValue: raw) {
            controller.character = type
        }

        if UserDefaults.standard.object(forKey: "memo.session.\(sessionId)") != nil {
            controller.memo       = UserDefaults.standard.string(forKey: "memo.session.\(sessionId)") ?? ""
            controller.memoIsAuto = false
        } else {
            controller.memo       = UserDefaults.standard.string(forKey: "memo.slot.\(slot)") ?? ""
            controller.memoIsAuto = true
        }

        if UserDefaults.standard.object(forKey: "alwaysApprove.session.\(sessionId)") != nil {
            controller.alwaysApprove = UserDefaults.standard.bool(forKey: "alwaysApprove.session.\(sessionId)")
        } else if UserDefaults.standard.object(forKey: "alwaysApprove.slot.\(slot)") != nil {
            controller.alwaysApprove = UserDefaults.standard.bool(forKey: "alwaysApprove.slot.\(slot)")
        } else {
            controller.alwaysApprove = false
        }

        controller.pendingPermissionId = nil
        controller.sessionStart = Date()
        controller.update(to: .ready)

        let newMonitor = EventMonitor(controller: controller, eventFile: eventFile)
        newMonitor.onSessionEnded = { [weak self] in
            DispatchQueue.main.async { self?.endSession() }
        }
        monitor = newMonitor
        monitor.start()
        startTitleSync()
        onRebuildMenu?()
    }

    // MARK: - Lifecycle

    /// autoShow: false이면 패널을 초기화하되 화면에 표시하지 않음 (사용자가 숨긴 상태 유지)
    func setup(autoShow: Bool = true) {
        setupPanel()
        setupControllerCallbacks()
        setupMousePassthrough()
        setupFocusMode()
        startTitleSync()
        monitor.start()
        DispatchQueue.main.async {
            self.controller.sessionStart = Date()
            if autoShow { self.showCompanion() }
            self.controller.update(to: .ready)
        }
    }

    func teardown() {
        monitor.stop()
        stopTitleSync()
        removeMouseMonitors()
        wanderWorkItem?.cancel(); wanderWorkItem = nil
        focusModeCancellable?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.slideOut { self?.panel?.orderOut(nil) }
        }
    }

    private func endSession() {
        controller.update(to: .idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hideCompanion()
        }
        onStaledSessionEnded?()
    }

    // MARK: - 세션 이름 → 메모 자동 연동

    /// 메모를 직접 지정하지 않은 세션은 Claude Code 세션 이름을 메모로 보여준다.
    /// 이름은 대화가 시작된 뒤에야 정해지고 나중에 바뀔 수도 있어 주기적으로 확인한다.
    private func startTitleSync() {
        guard sessionId != "__legacy__" else { return }
        let t = DispatchSource.makeTimerSource(queue: titleQueue)
        t.schedule(deadline: .now(), repeating: .seconds(15))
        t.setEventHandler { [weak self] in self?.syncSessionTitle() }
        t.resume()
        titleSyncTimer = t
    }

    private func stopTitleSync() {
        titleSyncTimer?.cancel()
        titleSyncTimer = nil
    }

    private func syncSessionTitle() {
        guard let title = SessionTitleReader.title(for: sessionId), !title.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 사용자가 직접 지정하거나 지운 메모는 건드리지 않는다
            guard self.controller.memoIsAuto, self.controller.memo != title else { return }
            self.controller.memo = title
        }
    }

    private func removeMouseMonitors() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let m = dragMonitor  { NSEvent.removeMonitor(m); dragMonitor  = nil }
    }

    // MARK: - Panel setup

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let p = UnconstrainedPanel(
            contentRect: peekFrame(screen: screen),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.isMovable          = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 5)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let rootView = CompanionView().environmentObject(controller)
        p.contentView = ClickThroughHostingView(rootView: rootView)
        panel = p

        // idle ↔ non-idle 전환 때만 패널 위치를 애니메이션
        // (thinking→toolUse 같은 sub-state 변화마다 호출하면 슬롯 1+ 패널이 아래로 밀리는 버그 발생)
        controller.$state
            .receive(on: DispatchQueue.main)
            .map { $0 == .idle }
            .removeDuplicates()
            .sink { [weak self] isIdle in self?.animatePanel(isIdle: isIdle) }
            .store(in: &cancellables)
    }

    // MARK: - Show / Hide

    func showCompanion() {
        guard let screen = NSScreen.main else { return }
        guard panel?.isVisible != true, !controller.isSliding else { return }

        let startFrame  = offScreenRightFrame(screen: screen)
        let targetFrame = activeFrame(screen: screen)
        panel?.setFrame(startFrame, display: false)
        panel?.orderFrontRegardless()

        controller.isSliding = true
        hoppingSlide(from: startFrame, to: targetFrame, hops: 3, hopHeight: 22, perHopDuration: 0.28) {
            self.controller.isSliding = false
            self.updateMousePassthrough()
        }
        onRebuildMenu?()
    }

    func hideCompanion() {
        guard let panel = panel, NSScreen.main != nil else {
            self.panel?.orderOut(nil); onRebuildMenu?(); return
        }
        guard panel.isVisible, !controller.isSliding else {
            panel.orderOut(nil); onRebuildMenu?(); return
        }
        slideOut { panel.orderOut(nil); self.onRebuildMenu?() }
    }

    private func slideOut(completion: @escaping () -> Void) {
        guard let panel = panel, let screen = NSScreen.main else { completion(); return }
        guard !controller.isSliding else { completion(); return }
        controller.isSliding = true
        let startFrame = panel.frame
        let exitFrame = NSRect(x: screen.visibleFrame.maxX,
                               y: panel.frame.origin.y,
                               width: panelWidth, height: panelHeight)
        hoppingSlide(from: startFrame, to: exitFrame, hops: 2, hopHeight: 18, perHopDuration: 0.28) {
            self.controller.isSliding = false
            completion()
        }
    }

    /// 토끼가 깡총깡총 뛰어서 이동하는 것처럼, 목표 지점까지 가로로 이동하는 동안
    /// 위아래로 여러 번 튀어 오르는(포물선) 애니메이션. y는 매 홉마다 baseY로 착지해
    /// 마지막엔 targetFrame과 정확히 일치한다.
    private func hoppingSlide(from startFrame: NSRect, to targetFrame: NSRect,
                               hops: Int, hopHeight: CGFloat,
                               perHopDuration: TimeInterval,
                               completion: @escaping () -> Void) {
        guard let panel = panel, hops > 0 else {
            self.panel?.setFrame(targetFrame, display: true)
            completion()
            return
        }
        let baseY = targetFrame.origin.y
        let dx = targetFrame.origin.x - startFrame.origin.x

        func doHop(_ index: Int, currentX: CGFloat) {
            guard index < hops else {
                panel.setFrame(targetFrame, display: true)
                completion()
                return
            }
            let nextX = startFrame.origin.x + dx * CGFloat(index + 1) / CGFloat(hops)
            let midX  = (currentX + nextX) / 2
            let riseFrame = NSRect(x: midX, y: baseY + hopHeight,
                                   width: targetFrame.width, height: targetFrame.height)
            let landFrame = NSRect(x: nextX, y: baseY,
                                   width: targetFrame.width, height: targetFrame.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration       = perHopDuration * 0.45
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(riseFrame, display: true)
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration       = perHopDuration * 0.55
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(landFrame, display: true)
                } completionHandler: {
                    doHop(index + 1, currentX: nextX)
                }
            }
        }
        doHop(0, currentX: startFrame.origin.x)
    }

    // MARK: - Position

    /// 슬롯 오프셋 적용 — 슬롯 0이 최상위, 이후 아래로 쌓임
    private func slottedOrigin(base: NSPoint) -> NSPoint {
        NSPoint(x: base.x, y: base.y - CGFloat(slot) * (panelHeight + 8))
    }

    private func peekFrame(screen: NSScreen) -> NSRect {
        let base = customOrigin ?? NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                           y: screen.visibleFrame.maxY - 40)
        return NSRect(origin: slottedOrigin(base: base),
                      size: CGSize(width: panelWidth, height: panelHeight))
    }

    private func activeFrame(screen: NSScreen) -> NSRect {
        let base = customOrigin ?? NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                           y: screen.visibleFrame.maxY - panelHeight)
        return NSRect(origin: slottedOrigin(base: base),
                      size: CGSize(width: panelWidth, height: panelHeight))
    }

    private func offScreenRightFrame(screen: NSScreen) -> NSRect {
        let base = customOrigin ?? NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                           y: screen.visibleFrame.maxY - panelHeight)
        let origin = slottedOrigin(base: base)
        return NSRect(x: screen.visibleFrame.maxX, y: origin.y,
                      width: panelWidth, height: panelHeight)
    }

    // MARK: - 집중모드 (대기 중일 때 화면을 돌아다니며 주의 끌기)

    /// 전역 켜짐/꺼짐 상태(FocusModeStore)와 세션 상태를 함께 구독해,
    /// "대기(ready) 상태 + 모드 켜짐"일 때만 돌아다니게 한다.
    private func setupFocusMode() {
        focusModeCancellable = Publishers.CombineLatest(FocusModeStore.shared.$enabled, controller.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, state in
                self?.updateFocusMode(enabled: enabled, state: state)
            }
    }

    private func updateFocusMode(enabled: Bool, state: CompanionState) {
        let shouldWander = enabled && state == .ready
        guard shouldWander != isWandering else { return }
        isWandering = shouldWander
        if shouldWander {
            scheduleWander()
        } else {
            wanderWorkItem?.cancel()
            wanderWorkItem = nil
            returnToAssignedPosition()
        }
    }

    private func scheduleWander() {
        guard isWandering else { return }
        let delay = Double.random(in: 4.0...8.0)
        let work = DispatchWorkItem { [weak self] in self?.performWanderStep() }
        wanderWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performWanderStep() {
        guard isWandering else { return }
        guard !isDragging, let panel = panel, panel.isVisible,
              !controller.isSliding, let screen = NSScreen.main else {
            scheduleWander()   // 조건이 안 맞으면 잠시 후 다시 시도
            return
        }
        let vf   = screen.visibleFrame
        let maxX = vf.maxX - panelWidth
        let maxY = vf.maxY - panelHeight
        guard maxX > vf.minX, maxY > vf.minY else { scheduleWander(); return }
        let target = NSRect(x: CGFloat.random(in: vf.minX...maxX),
                            y: CGFloat.random(in: vf.minY...maxY),
                            width: panelWidth, height: panelHeight)
        controller.isSliding = true
        hoppingSlide(from: panel.frame, to: target, hops: 2, hopHeight: 16, perHopDuration: 0.26) { [weak self] in
            guard let self else { return }
            self.controller.isSliding = false
            self.updateMousePassthrough()
            self.scheduleWander()
        }
    }

    /// 모드가 꺼지거나 세션이 다시 진행 상태가 되면 원래 지정된 자리(슬롯 위치)로 복귀
    private func returnToAssignedPosition() {
        guard let panel = panel, panel.isVisible, !isDragging, let screen = NSScreen.main else { return }
        controller.isSliding = true
        hoppingSlide(from: panel.frame, to: activeFrame(screen: screen),
                     hops: 2, hopHeight: 16, perHopDuration: 0.26) { [weak self] in
            self?.controller.isSliding = false
            self?.updateMousePassthrough()
        }
    }

    private func animatePanel(isIdle: Bool) {
        guard !controller.isSliding else { return }
        guard let panel = panel, let screen = NSScreen.main else { return }
        // 사용자가 숨긴 패널은 애니메이션 금지 — animator()가 hidden 패널을 깨울 수 있음
        guard panel.isVisible else { return }
        let target = isIdle ? peekFrame(screen: screen) : activeFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Mouse passthrough

    private func setupMousePassthrough() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in self?.updateMousePassthrough() }
    }

    func updateMousePassthrough() {
        guard let panel = panel, panel.isVisible,
              !controller.isSliding, !isDragging else { return }
        let mouse  = NSEvent.mouseLocation
        let rect   = interactiveRect(for: panel)
        // 마우스가 rect 안에 있으면 즉시 활성화, 벗어날 때는 10px 여유(hysteresis)를 두어
        // 드래그 직전 미세한 마우스 이동으로 passthrough가 켜지는 현상 방지
        let shouldIgnore: Bool
        if rect.contains(mouse) {
            shouldIgnore = false
        } else {
            let buffer: CGFloat = 10
            let expanded = rect.insetBy(dx: -buffer, dy: -buffer)
            shouldIgnore = !expanded.contains(mouse)
        }
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
    }

    private func interactiveRect(for panel: NSWindow) -> NSRect {
        let f = panel.frame
        let charWidth:  CGFloat = 80
        let charHeight: CGFloat = 110   // 캐릭터 상단 7px 여유 포함
        if case .permission = controller.state {
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: charHeight)
        }
        if case .completed = controller.state {
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: charHeight)
        }
        // 한도 안내 버블의 숨기기 버튼도 클릭 가능해야 함
        if controller.isLimitNoticeVisible {
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: charHeight)
        }
        return NSRect(x: f.maxX - charWidth, y: f.minY, width: charWidth, height: charHeight)
    }

    // MARK: - Controller callbacks

    private func setupControllerCallbacks() {
        // 메뉴바 "부니 숨기기"와 동일한 전체 숨김으로 위임 (isManuallyHidden 동기화)
        controller.onHideRequest          = { [weak self] in self?.onGlobalHideRequest?() }
        controller.onShowRequest          = { [weak self] in self?.showCompanion() }
        controller.onOpenClaudeRequest    = { [weak self] in self?.onOpenClaude?() }
        controller.onOpenSettingsRequest  = { [weak self] in self?.onOpenSettings?() }
        controller.onShowStatusBarRequest = { [weak self] in self?.onShowStatusBar?() }
        controller.onEditMemoRequest      = { [weak self] in self?.showMemoEditDialog() }
        controller.onSwitchSessionRequest = { [weak self] targetId in self?.onSwitchSession?(targetId) }

        // 메모 변경 시 세션 UUID + 슬롯 키 모두 저장 (슬롯 키로 다음 세션에 복원)
        controller.$memo
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] memo in
                guard let self else { return }
                // 세션 이름에서 자동으로 채운 값은 저장하지 않는다 —
                // 저장하면 사용자가 지정한 메모와 구분할 수 없어진다.
                guard !self.controller.memoIsAuto else { return }
                let sessionKey = "memo.session.\(self.sessionId)"
                let slotKey    = "memo.slot.\(self.slot)"
                if memo.isEmpty {
                    // 빈 문자열을 남겨 "사용자가 직접 지웠음"을 표시 —
                    // 키를 지우면 다음 실행 때 세션 이름이 다시 채워진다.
                    UserDefaults.standard.set("", forKey: sessionKey)
                    UserDefaults.standard.removeObject(forKey: slotKey)
                } else {
                    UserDefaults.standard.set(memo, forKey: sessionKey)
                    UserDefaults.standard.set(memo, forKey: slotKey)
                }
            }
            .store(in: &cancellables)

        controller.onDismissCompleted = { [weak self] in
            DispatchQueue.main.async { self?.onSessionEnded?() }
        }

        controller.onResetPositionRequest = { [weak self] in
            guard let self else { return }
            self.customOrigin = nil
            if let screen = NSScreen.main {
                self.panel?.setFrameOrigin(self.activeFrame(screen: screen).origin)
            }
            if self.slot == 0 { self.onSaveOrigin?(NSPoint(x: -1, y: -1)) }
        }

        // 모든 슬롯 드래그 가능 (슬롯 0만 UserDefaults에 영속 저장)
        controller.onPanelDragStart = { [weak self] in self?.startDrag() }
        controller.onPanelDrag      = { _ in }
        controller.onPanelDragEnd   = { }

        // 캐릭터 변경 시 세션 UUID + 슬롯 키 모두 저장 (슬롯 키로 다음 세션에 복원)
        controller.$character
            .receive(on: DispatchQueue.main)
            .dropFirst()   // 초기값은 이미 복원된 값이므로 저장 건너뜀
            .sink { [weak self] type in
                guard let self else { return }
                UserDefaults.standard.set(type.rawValue,
                                          forKey: "character.session.\(self.sessionId)")
                UserDefaults.standard.set(type.rawValue,
                                          forKey: "character.slot.\(self.slot)")
                // 직접 바꾼 캐릭터도 "최근 사용" 취급 — 다음 새 세션의 기본값이 된다
                UserDefaults.standard.set(type.rawValue, forKey: "character.lastUsed")
            }
            .store(in: &cancellables)

        controller.$alwaysApprove
            .receive(on: DispatchQueue.main)
            .sink { [weak self] approve in
                guard let self else { return }
                UserDefaults.standard.set(approve, forKey: "alwaysApprove.session.\(self.sessionId)")
                UserDefaults.standard.set(approve, forKey: "alwaysApprove.slot.\(self.slot)")
                self.onRebuildMenu?()
            }
            .store(in: &cancellables)

        controller.$state
            .receive(on: DispatchQueue.main)
            .map { s -> Bool in
                if case .permission = s { return true }
                if case .completed  = s { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] _ in self?.onRebuildMenu?() }
            .store(in: &cancellables)

        // 숨겨진 패널이 세션 활동 재개 시 다시 나타나도록 복구
        // (Claude 종료 감지로 숨긴 뒤 같은 세션이 다시 일할 때 영영 안 보이던 문제)
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state != .idle else { return }
                guard self.panel?.isVisible != true, !self.controller.isSliding else { return }
                guard self.shouldAutoShow?() ?? true else { return }
                self.showCompanion()
            }
            .store(in: &cancellables)
    }

    // MARK: - 메모 편집 다이얼로그

    private func showMemoEditDialog() {
        // 앱을 포그라운드로 활성화해야 텍스트 필드에 키보드 입력 가능
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "메모 설정"
        alert.informativeText = "이 캐릭터의 메모를 입력하세요.\n(빈칸으로 두면 메모가 삭제됩니다)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = controller.memo
        input.placeholderString = "예: 프로젝트명, 작업명..."
        input.maximumNumberOfLines = 1
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // 직접 입력(빈칸으로 지우는 것 포함)한 순간부터 세션 이름 자동 연동을 끈다
            controller.memoIsAuto = false
            controller.memo = trimmed
        }
    }

    // MARK: - Drag (슬롯 0 전용)

    private func startDrag() {
        isDragging = true
        panel?.ignoresMouseEvents = false
        lastMouseLoc = NSEvent.mouseLocation

        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .leftMouseUp {
                if let m = self.dragMonitor { NSEvent.removeMonitor(m) }
                self.dragMonitor = nil
                self.isDragging  = false
                if let origin = self.panel?.frame.origin {
                    self.customOrigin = origin
                    self.onSaveOrigin?(origin)
                }
                self.updateMousePassthrough()
                return event
            }

            let current = NSEvent.mouseLocation
            let dx = current.x - self.lastMouseLoc.x
            let dy = current.y - self.lastMouseLoc.y
            self.lastMouseLoc = current

            if let panel = self.panel {
                var o = panel.frame.origin
                o.x += dx
                o.y += dy
                // 마우스 커서가 있는 스크린 기준으로 클램핑 (멀티 모니터 대응)
                let screen = NSScreen.screens.first { $0.frame.contains(current) }
                    ?? NSScreen.main
                if let screen = screen {
                    o.x = max(screen.visibleFrame.minX - self.panelWidth + 60,
                              min(screen.visibleFrame.maxX - 60, o.x))
                    o.y = max(screen.visibleFrame.minY - self.panelHeight + 60,
                              min(screen.frame.maxY, o.y))
                }
                panel.setFrameOrigin(o)
                self.customOrigin = o
            }
            return event
        }
    }
}
