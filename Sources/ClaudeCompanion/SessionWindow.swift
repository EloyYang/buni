import Cocoa
import SwiftUI
import Combine

/// 하나의 Claude 세션에 대응하는 부니 패널 + 컨트롤러 + 이벤트 모니터
class SessionWindow {
    let sessionId: String

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

    // ── AppDelegate 에서 주입하는 콜백
    var onOpenClaude:    (() -> Void)?
    var onOpenSettings:  (() -> Void)?
    var onShowStatusBar: (() -> Void)?
    var onSessionEnded:  (() -> Void)?
    /// 슬롯 0이 드래그로 위치를 바꿀 때 저장 요청 (NSPoint(-1,-1) = 리셋)
    var onSaveOrigin:    ((NSPoint) -> Void)?
    var onRebuildMenu:   (() -> Void)?

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
        // 메모 복원: 세션 UUID → 슬롯 기반 순서로 시도
        if let savedMemo = UserDefaults.standard.string(forKey: "memo.session.\(sessionId)") {
            ctrl.memo = savedMemo
        } else if let savedMemo = UserDefaults.standard.string(forKey: "memo.slot.\(slot)") {
            ctrl.memo = savedMemo
        }
        self.controller = ctrl
        self.monitor    = EventMonitor(controller: ctrl, eventFile: eventFile)
        monitor.onSessionEnded = { [weak self] in
            DispatchQueue.main.async { self?.endSession() }
        }
    }

    // MARK: - Lifecycle

    /// autoShow: false이면 패널을 초기화하되 화면에 표시하지 않음 (사용자가 숨긴 상태 유지)
    func setup(autoShow: Bool = true) {
        setupPanel()
        setupControllerCallbacks()
        setupMousePassthrough()
        monitor.start()
        DispatchQueue.main.async {
            self.controller.sessionStart = Date()
            if autoShow { self.showCompanion() }
            self.controller.update(to: .ready)
        }
    }

    func teardown() {
        monitor.stop()
        removeMouseMonitors()
        DispatchQueue.main.async { [weak self] in
            self?.slideOut { self?.panel?.orderOut(nil) }
        }
    }

    private func endSession() {
        controller.update(to: .idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hideCompanion()
        }
        onSessionEnded?()
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.85
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel?.animator().setFrame(targetFrame, display: true)
        } completionHandler: {
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
        let exitFrame = NSRect(x: screen.visibleFrame.maxX,
                               y: panel.frame.origin.y,
                               width: panelWidth, height: panelHeight)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.55
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(exitFrame, display: true)
        } completionHandler: {
            self.controller.isSliding = false
            completion()
        }
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
        return NSRect(x: f.maxX - charWidth, y: f.minY, width: charWidth, height: charHeight)
    }

    // MARK: - Controller callbacks

    private func setupControllerCallbacks() {
        controller.onHideRequest          = { [weak self] in self?.hideCompanion() }
        controller.onShowRequest          = { [weak self] in self?.showCompanion() }
        controller.onOpenClaudeRequest    = { [weak self] in self?.onOpenClaude?() }
        controller.onOpenSettingsRequest  = { [weak self] in self?.onOpenSettings?() }
        controller.onShowStatusBarRequest = { [weak self] in self?.onShowStatusBar?() }
        controller.onEditMemoRequest      = { [weak self] in self?.showMemoEditDialog() }

        // 메모 변경 시 세션 UUID + 슬롯 키 모두 저장 (슬롯 키로 다음 세션에 복원)
        controller.$memo
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] memo in
                guard let self else { return }
                let sessionKey = "memo.session.\(self.sessionId)"
                let slotKey    = "memo.slot.\(self.slot)"
                if memo.isEmpty {
                    UserDefaults.standard.removeObject(forKey: sessionKey)
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
            }
            .store(in: &cancellables)

        controller.$alwaysApprove
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onRebuildMenu?() }
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

            if let panel = self.panel, let screen = NSScreen.main {
                var o = panel.frame.origin
                o.x = max(screen.visibleFrame.minX - self.panelWidth + 60,
                          min(screen.visibleFrame.maxX - 60, o.x + dx))
                o.y = max(screen.visibleFrame.minY - self.panelHeight + 60,
                          min(screen.frame.maxY, o.y + dy))
                panel.setFrameOrigin(o)
                self.customOrigin = o
            }
            return event
        }
    }
}
