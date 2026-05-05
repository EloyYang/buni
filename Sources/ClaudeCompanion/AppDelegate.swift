import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private let controller = CompanionController()
    private var eventMonitor: EventMonitor?
    private let hotkeyMonitor = HotkeyMonitor()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth: CGFloat  = 320
    private let panelHeight: CGFloat = 200

    // 사용자가 지정한 패널 위치 (nil이면 기본 오른쪽 상단)
    private var customPanelOrigin: NSPoint?
    private var dragStartOrigin: NSPoint = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        customPanelOrigin = loadSavedOrigin()
        setupOverlayPanel()
        setupStatusBar()
        setupControllerCallbacks()
        startEventMonitor()
        setupHotkeyMonitor()
        setupSettingsCallbacks()
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "face.smiling.inverse",
                                   accessibilityDescription: "Claude Companion")
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 전체 허용 모드 활성 시 상태 표시 + 해제 버튼
        if controller.alwaysApprove {
            let item = NSMenuItem(title: "⚡ 전체 허용 모드 켜짐 — 클릭하여 끄기",
                                  action: #selector(disableAlwaysApprove),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let isVisible = overlayPanel?.isVisible ?? false
        menu.addItem(NSMenuItem(title: isVisible ? "숨기기" : "보이기",
                                action: #selector(toggleVisibility),
                                keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Claude 열기",
                                action: #selector(openClaude),
                                keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "단축키 설정...",
                                action: #selector(openSettings),
                                keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem?.menu = menu
    }

    @objc private func disableAlwaysApprove() {
        controller.alwaysApprove = false
    }

    @objc func toggleVisibility() {
        if overlayPanel?.isVisible == true {
            hideCompanion()
        } else {
            showCompanion()
        }
    }

    func hideCompanion() {
        guard let panel = overlayPanel, let screen = NSScreen.main else {
            overlayPanel?.orderOut(nil); rebuildMenu(); return
        }
        guard panel.isVisible, !controller.isSliding else {
            panel.orderOut(nil); rebuildMenu(); return
        }

        controller.isSliding = true
        let exitFrame = offScreenRightFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.55
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(exitFrame, display: true)
        } completionHandler: {
            panel.orderOut(nil)
            self.controller.isSliding = false
            self.rebuildMenu()
        }
    }

    func showCompanion() {
        guard let screen = NSScreen.main else { return }
        guard overlayPanel?.isVisible != true, !controller.isSliding else { return }

        let startFrame  = offScreenRightFrame(screen: screen)
        let targetFrame = activeFrame(screen: screen)

        overlayPanel?.setFrame(startFrame, display: false)
        overlayPanel?.orderFrontRegardless()

        controller.isSliding = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.85
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlayPanel?.animator().setFrame(targetFrame, display: true)
        } completionHandler: {
            self.controller.isSliding = false
        }
        rebuildMenu()
    }

    private func offScreenRightFrame(screen: NSScreen) -> NSRect {
        let originY = customPanelOrigin?.y ?? (screen.visibleFrame.maxY - panelHeight)
        return NSRect(x: screen.visibleFrame.maxX,
                      y: originY,
                      width: panelWidth, height: panelHeight)
    }

    @objc func openClaude() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    @objc func openSettings() {
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: ShortcutSettingsView())
        hostingView.autoresizingMask = [.width, .height]

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 200),
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

    // MARK: - Controller callbacks

    private func setupControllerCallbacks() {
        controller.onHideRequest         = { [weak self] in self?.hideCompanion() }
        controller.onShowRequest         = { [weak self] in self?.showCompanion() }
        controller.onOpenClaudeRequest   = { [weak self] in self?.openClaude() }
        controller.onOpenSettingsRequest = { [weak self] in self?.openSettings() }

        // 드래그로 위치 조정
        controller.onPanelDragStart = { [weak self] in
            self?.dragStartOrigin = self?.overlayPanel?.frame.origin ?? .zero
        }
        controller.onPanelDrag = { [weak self] translation in
            guard let self, let panel = self.overlayPanel,
                  let screen = NSScreen.main else { return }
            let newX = self.dragStartOrigin.x + translation.width
            let newY = self.dragStartOrigin.y - translation.height  // SwiftUI Y축 반전
            // 화면 밖으로 완전히 벗어나지 않도록 클램프
            let clampedX = max(screen.visibleFrame.minX - self.panelWidth + 60,
                               min(screen.visibleFrame.maxX - 60, newX))
            let clampedY = max(screen.visibleFrame.minY - self.panelHeight + 60,
                               min(screen.visibleFrame.maxY - 20, newY))
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
            self.customPanelOrigin = panel.frame.origin
        }
        controller.onPanelDragEnd = { [weak self] in
            guard let self, let origin = self.overlayPanel?.frame.origin else { return }
            self.saveOrigin(origin)
        }
        controller.onResetPositionRequest = { [weak self] in
            guard let self else { return }
            self.customPanelOrigin = nil
            UserDefaults.standard.removeObject(forKey: "panel.x")
            UserDefaults.standard.removeObject(forKey: "panel.y")
            if let screen = NSScreen.main {
                self.overlayPanel?.setFrameOrigin(self.activeFrame(screen: screen).origin)
            }
        }

        controller.$alwaysApprove
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        // 권한 버블 상태 변화 시 단축키 활성/비활성
        controller.$state
            .receive(on: DispatchQueue.main)
            .map { if case .permission = $0 { return true }; return false }
            .removeDuplicates()
            .sink { [weak self] isPermission in
                self?.hotkeyMonitor.updatePermissionState(isPermission)
            }
            .store(in: &cancellables)
    }

    // MARK: - Position persistence

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "panel.x")
        UserDefaults.standard.set(Double(origin.y), forKey: "panel.y")
    }

    private func loadSavedOrigin() -> NSPoint? {
        guard UserDefaults.standard.object(forKey: "panel.x") != nil else { return nil }
        return NSPoint(x: UserDefaults.standard.double(forKey: "panel.x"),
                       y: UserDefaults.standard.double(forKey: "panel.y"))
    }

    // MARK: - Hotkey monitor

    private func setupHotkeyMonitor() {
        let store = ShortcutStore.shared
        hotkeyMonitor.updateShortcuts(approve: store.approve,
                                      deny: store.deny,
                                      hide: store.hide)
        hotkeyMonitor.onApprove = { [weak self] in self?.controller.approvePermission() }
        hotkeyMonitor.onDeny    = { [weak self] in self?.controller.denyPermission() }
        hotkeyMonitor.onHide    = { [weak self] in self?.toggleVisibility() }
    }

    private func setupSettingsCallbacks() {
        Publishers.CombineLatest3(
            ShortcutStore.shared.$approve,
            ShortcutStore.shared.$deny,
            ShortcutStore.shared.$hide
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] approve, deny, hide in
            self?.hotkeyMonitor.updateShortcuts(approve: approve, deny: deny, hide: hide)
        }
        .store(in: &cancellables)
    }

    // MARK: - Overlay panel

    private func setupOverlayPanel() {
        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: peekFrame(screen: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let rootView = CompanionView()
            .environmentObject(controller)
        panel.contentView = NSHostingView(rootView: rootView)
        overlayPanel = panel

        controller.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in self?.animatePanel(for: state) }
            .store(in: &cancellables)
    }

    private func peekFrame(screen: NSScreen) -> NSRect {
        // 사용자 지정 위치가 있으면 peek 없이 그대로 유지
        if let origin = customPanelOrigin {
            return NSRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))
        }
        return NSRect(x: screen.visibleFrame.maxX - panelWidth,
                      y: screen.visibleFrame.maxY - 40,
                      width: panelWidth, height: panelHeight)
    }

    private func activeFrame(screen: NSScreen) -> NSRect {
        let origin = customPanelOrigin ?? NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                                   y: screen.visibleFrame.maxY - panelHeight)
        return NSRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))
    }

    private func animatePanel(for state: CompanionState) {
        guard !controller.isSliding else { return }
        guard let panel = overlayPanel, let screen = NSScreen.main else { return }
        let targetFrame = (state == .idle) ? peekFrame(screen: screen) : activeFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        eventMonitor = EventMonitor(controller: controller)
        eventMonitor?.start()
    }
}
