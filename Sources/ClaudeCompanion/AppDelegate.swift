import Cocoa
import SwiftUI
import Combine
import CoreGraphics

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private let controller = CompanionController()
    private var eventMonitor: EventMonitor?
    private var keyMonitor:   Any?
    private var settingsWindow: NSWindow?
    private var accessibilityTimer: Timer?
    private var accessibilityGranted: Bool = true  // 기본 true — 실제 확인 후 갱신
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth: CGFloat  = 320
    private let panelHeight: CGFloat = 200

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestInputMonitoringIfNeeded()
        setupOverlayPanel()
        setupStatusBar()
        setupControllerCallbacks()
        startEventMonitor()
        setupKeyMonitor()
        setupSettingsCallbacks()
    }

    // MARK: - Input Monitoring permission
    // addGlobalMonitorForEvents는 "입력 모니터링" 권한이 필요 (손쉬운 사용 X)

    private func requestInputMonitoringIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkInputMonitoring(requestIfNeeded: true)
        }
    }

    private func checkInputMonitoring(requestIfNeeded: Bool) {
        let granted = CGPreflightListenEventAccess()
        let changed  = granted != accessibilityGranted
        accessibilityGranted = granted

        if granted {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            if changed { setupKeyMonitor(); rebuildMenu() }
            return
        }

        if requestIfNeeded { CGRequestListenEventAccess() }
        if changed { rebuildMenu() }

        guard accessibilityTimer == nil else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkInputMonitoring(requestIfNeeded: false)
        }
    }

    @objc private func openAccessibilityPrefs() {
        // 입력 모니터링 설정 페이지로 바로 이동
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkInputMonitoring(requestIfNeeded: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
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

        // 접근성 권한 없으면 경고 항목 표시
        if !accessibilityGranted {
            let warn = NSMenuItem(title: "⚠️ 단축키: 입력 모니터링 권한 필요",
                                  action: #selector(openAccessibilityPrefs),
                                  keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
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
        // 이미 숨겨져 있거나 슬라이드 중이면 그냥 숨김
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

    // 화면 오른쪽 밖 프레임
    private func offScreenRightFrame(screen: NSScreen) -> NSRect {
        NSRect(x: screen.visibleFrame.maxX,
               y: screen.visibleFrame.maxY - panelHeight,
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
        controller.onHideRequest        = { [weak self] in self?.hideCompanion() }
        controller.onShowRequest        = { [weak self] in self?.showCompanion() }
        controller.onOpenClaudeRequest  = { [weak self] in self?.openClaude() }
        controller.onOpenSettingsRequest = { [weak self] in self?.openSettings() }
    }

    private func setupSettingsCallbacks() {
        // 단축키 변경 시 모니터 재등록 — debounce로 연속 호출 1회로 묶음
        Publishers.CombineLatest3(
            ShortcutStore.shared.$approve,
            ShortcutStore.shared.$deny,
            ShortcutStore.shared.$hide
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.setupKeyMonitor() }
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
        panel.ignoresMouseEvents = false   // 클릭 허용
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let rootView = CompanionView()
            .environmentObject(controller)
        panel.contentView = NSHostingView(rootView: rootView)
        // Claude가 실행될 때만 표시 — 초기엔 숨김
        overlayPanel = panel

        controller.$state
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in self?.animatePanel(for: state) }
            .store(in: &cancellables)
    }

    private func peekFrame(screen: NSScreen) -> NSRect {
        NSRect(x: screen.visibleFrame.maxX - panelWidth,
               y: screen.visibleFrame.maxY - 40,
               width: panelWidth, height: panelHeight)
    }

    private func activeFrame(screen: NSScreen) -> NSRect {
        NSRect(x: screen.visibleFrame.maxX - panelWidth,
               y: screen.visibleFrame.maxY - panelHeight,
               width: panelWidth, height: panelHeight)
    }

    private func animatePanel(for state: CompanionState) {
        // 등장/퇴장 슬라이드 중에는 간섭하지 않음
        guard !controller.isSliding else { return }
        guard let panel = overlayPanel, let screen = NSScreen.main else { return }
        let targetFrame = (state == .idle) ? peekFrame(screen: screen) : activeFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Global key monitor

    private func setupKeyMonitor() {
        // 기존 모니터 해제
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let store = ShortcutStore.shared

            // 권한 허락 단축키
            if let sc = store.approve, sc.matches(event) {
                guard case .permission = self.controller.state else { return }
                DispatchQueue.main.async { self.controller.approvePermission() }
                return
            }

            // 권한 거부 단축키
            if let sc = store.deny, sc.matches(event) {
                guard case .permission = self.controller.state else { return }
                DispatchQueue.main.async { self.controller.denyPermission() }
                return
            }

            // 캐릭터 숨기기 단축키
            if let sc = store.hide, sc.matches(event) {
                DispatchQueue.main.async { self.hideCompanion() }
                return
            }
        }
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        eventMonitor = EventMonitor(controller: controller)
        eventMonitor?.start()
    }
}
