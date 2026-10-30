import Cocoa
import SwiftUI
import Combine

/// 패널 크기와 "화면 안에 반드시 남아야 하는" 기준값 — SessionWindow(배치·드래그)와
/// AppDelegate(저장된 위치 검증)가 같은 값을 써야 해서 한곳에 모아둔다.
enum PanelMetrics {
    static let width:  CGFloat = 320
    static let height: CGFloat = 200
    /// 캐릭터(+사용량 바) 영역의 대략적인 너비. 패널에서 실제로 눈에 보이는 부분이라
    /// 화면 밖으로 나가면 안 되는 기준이 되고, 말풍선 좌우 반전 시 패널을 미는 폭이기도 하다.
    static let characterAreaWidth: CGFloat = 72
    /// 캐릭터가 화면 가장자리에 걸칠 때 최소한 남겨야 하는 폭
    static let minVisible: CGFloat = 60

    /// 패널 원점(말풍선 반전 전 기준)에서 캐릭터가 차지하는 x 범위의 시작점까지의 거리.
    /// 반전 상태면 캐릭터가 패널 왼쪽 끝, 평소엔 오른쪽 끝에 온다.
    static func characterOffsetX(flipped: Bool) -> CGFloat {
        flipped ? 0 : width - characterAreaWidth
    }
}

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

    private let panelWidth  = PanelMetrics.width
    private let panelHeight = PanelMetrics.height
    /// 캐릭터(+사용량 바) 영역의 대략적인 너비 — 말풍선 좌우 반전 시, 이 너비만큼
    /// 패널을 밀어서 캐릭터의 화면상 위치는 그대로 유지한 채 말풍선만 반대쪽으로 옮긴다
    private let characterAreaWidth = PanelMetrics.characterAreaWidth

    /// 이 슬롯의 저장 위치 (nil = 기본 오른쪽 상단)
    var customOrigin: NSPoint?

    private var isDragging   = false
    private var lastMouseLoc: NSPoint = .zero
    private var dragMonitor:  Any?
    private var mouseMonitor: Any?

    /// 딴짓 방해모드 — 무입력 상태에서 화면을 돌아다니는 중
    private var focusModeCancellable: AnyCancellable?
    /// 마우스 통과 여부를 주기적으로 다시 판단하는 타이머
    private var passthroughTimer: Timer?
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
    /// 드래그로 위치를 바꿀 때 슬롯별 저장 요청 (NSPoint(-1,-1) = 리셋)
    var onSaveOrigin:    ((NSPoint) -> Void)?
    var onRebuildMenu:   (() -> Void)?
    /// 전역(메뉴바) "부니 숨기기" 여부 — 활동 재개 시 자동 재표시 판단용
    var shouldAutoShow:  (() -> Bool)?
    /// 사용자가 이 패널을 직접 숨겼는지 — 숨긴 뒤에는 "이 세션이 새로 시작될 때"
    /// (= 비진행 → 진행 전환)만 다시 나타난다. 진행 중에 숨겼다면 그 작업이
    /// 끝나고 다음 작업이 시작될 때가 되는데, 진행 중에는 시작 경계가 없으므로
    /// 별도 처리 없이 그렇게 된다. showCompanion()이 호출되면(부니 불러오기 등)
    /// 즉시 해제된다.
    private var isManuallyHidden = false
    /// 직전 상태가 "진행 중"이었는지 — 세션 시작(비진행 → 진행)을 가려내는 기준
    private var wasRunning = false
    /// 사용자가 이 패널을 직접 숨겼을 때 AppDelegate에 알린다 — 숨긴 직후
    /// 새로 만들어지는 패널(레거시 대기 세션 포함)이 대신 튀어나오지 않게 한다.
    var onUserHide: (() -> Void)?
    var onOpenSquad: ((String) -> Void)?
    /// 이 세션이 실제로 새 작업을 시작했을 때 알린다 — 전역 숨김도 함께 풀린다.
    var onRunStart: (() -> Void)?
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
        // 이 세션에 사용자가 직접 지정한 메모가 있으면 그대로 쓰고 자동 연동을 끈다.
        // 없거나 비어 있으면(= 메모를 지운 상태, 예전 버전이 남긴 빈 문자열 포함)
        // 슬롯 메모를 임시로 보여주되 자동 상태로 둬서, 잠시 뒤 세션 이름을
        // 읽어오면 그것으로 대체되게 한다.
        if let saved = UserDefaults.standard.string(forKey: "memo.session.\(sessionId)"), !saved.isEmpty {
            ctrl.memo       = saved
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

        if let saved = UserDefaults.standard.string(forKey: "memo.session.\(sessionId)"), !saved.isEmpty {
            controller.memo       = saved
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
        passthroughTimer?.invalidate(); passthroughTimer = nil
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
        // 명시적으로 다시 보이는 것이므로, 개별 숨김 상태였다면 해제한다
        isManuallyHidden = false
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

    /// 패널 우클릭 메뉴의 "숨기기" — 이 세션만 숨기고 다른 세션에는 영향 없음.
    /// 숨긴 뒤에는 이 세션이 새로 시작될 때까지(진행 중에 숨겼다면 그 작업이
    /// 끝나고 다음 작업이 시작될 때까지) 어떤 상태 변화로도 다시 나타나지 않는다.
    func hideThisCompanion() {
        markHiddenUntilNextStart()
        onUserHide?()
        hideCompanion()
    }

    /// 패널을 건드리지 않고 숨김 상태만 표시한다 —
    /// 전체 숨김, 그리고 숨긴 상태에서 새로 만들어진 패널에 쓴다.
    func markHiddenUntilNextStart() {
        isManuallyHidden = true
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

    /// 패널을 놓을 기준 좌표.
    /// 사용자가 드래그로 직접 정한 자리(customOrigin)가 있으면 그 자리를 그대로 쓰고,
    /// 없을 때만 기본 위치에서 슬롯 순서대로 아래로 쌓는다.
    /// (예전에는 customOrigin에도 슬롯 오프셋을 더해서, 슬롯 1 이상인 부니는
    ///  드래그로 놓을 때마다 slot×(panelHeight+8)만큼 아래로 내려앉았다.)
    private func baseOrigin(fallback: NSPoint) -> NSPoint {
        if let custom = customOrigin { return custom }
        return slottedOrigin(base: fallback)
    }

    /// 캐릭터가 화면 왼쪽 절반에 있는지 판단해 컨트롤러에 반영하고(말풍선을
    /// 어느 쪽에 그릴지는 CompanionView가 이 값을 보고 결정), 왼쪽이면 패널을
    /// characterAreaWidth만큼 오른쪽으로 밀어 캐릭터의 화면상 위치는 그대로 둔
    /// 채 말풍선이 들어갈 공간만 캐릭터 반대쪽(오른쪽)으로 옮긴다.
    /// - Parameter unshiftedX: customOrigin 기준(반전 전) 패널 x좌표
    private func resolvedOriginX(unshiftedX: CGFloat, screen: NSScreen) -> CGFloat {
        // 반전 전 배치를 기준으로 캐릭터가 실제로 놓일 중심 x (패널 오른쪽 끝 쪽)
        let characterCenterX = unshiftedX + panelWidth - characterAreaWidth / 2
        let isOnLeftHalf = characterCenterX < screen.visibleFrame.midX
        if controller.isNearLeftEdge != isOnLeftHalf {
            controller.isNearLeftEdge = isOnLeftHalf
        }
        return isOnLeftHalf ? unshiftedX + (panelWidth - characterAreaWidth) : unshiftedX
    }

    private func peekFrame(screen: NSScreen) -> NSRect {
        let origin = baseOrigin(fallback: NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                                  y: screen.visibleFrame.maxY - 40))
        let x = resolvedOriginX(unshiftedX: origin.x, screen: screen)
        return NSRect(origin: NSPoint(x: x, y: origin.y),
                      size: CGSize(width: panelWidth, height: panelHeight))
    }

    private func activeFrame(screen: NSScreen) -> NSRect {
        let origin = baseOrigin(fallback: NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                                  y: screen.visibleFrame.maxY - panelHeight))
        let x = resolvedOriginX(unshiftedX: origin.x, screen: screen)
        return NSRect(origin: NSPoint(x: x, y: origin.y),
                      size: CGSize(width: panelWidth, height: panelHeight))
    }

    private func offScreenRightFrame(screen: NSScreen) -> NSRect {
        let origin = baseOrigin(fallback: NSPoint(x: screen.visibleFrame.maxX - panelWidth,
                                                  y: screen.visibleFrame.maxY - panelHeight))
        return NSRect(x: screen.visibleFrame.maxX, y: origin.y,
                      width: panelWidth, height: panelHeight)
    }

    // MARK: - 딴짓 방해모드 (무입력 시간이 지나면 화면을 돌아다니며 주의 끌기)

    /// 모드가 켜져 있고 사용자의 마우스·키보드 입력이 설정 시간 이상 없으면 돌아다니고,
    /// 입력이 다시 감지되면 원래 자리로 복귀한다.
    private func setupFocusMode() {
        focusModeCancellable = FocusModeStore.shared.$isUserIdle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idle in
                self?.updateFocusMode(shouldWander: idle)
            }
    }

    private func updateFocusMode(shouldWander: Bool) {
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

    /// 모드가 꺼지거나 사용자 입력이 다시 감지되면 원래 지정된 자리(슬롯 위치)로 복귀
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
        guard !controller.isSliding, !isWandering else { return }
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

        // 전역 마우스 이벤트만으로는 상태가 굳을 수 있다 — 대기 상태로 바뀌며
        // 패널이 움직였는데 그 뒤로 마우스가 안 움직이면, 커서가 이미 캐릭터
        // 위에 있어도 클릭이 계속 통과해버린다(클로드가 안 돌 때 선택이 안 되던 원인).
        // 가볍게 주기적으로도 다시 판단한다.
        passthroughTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.updateMousePassthrough()
        }
    }

    func updateMousePassthrough() {
        // 애니메이션 중(isSliding)이라고 판단 자체를 건너뛰면, 완료 콜백이 끊겨
        // 플래그가 굳었을 때 부니를 영영 클릭할 수 없다. 이동 중에도 지금 위치로
        // 그냥 판단한다 — 커서가 캐릭터 위면 클릭을 받는 게 맞다.
        // 4초 넘게 "이동 중"이면 완료 콜백이 유실된 것으로 보고 풀어준다.
        if controller.isSliding, Date().timeIntervalSince(controller.slidingSince) > 4 {
            controller.isSliding = false
        }
        guard let panel = panel, panel.isVisible, !isDragging else { return }
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
        // 캐릭터는 말풍선 반전 여부에 따라 패널 왼쪽 끝/오른쪽 끝으로 옮겨간다.
        // 예전에는 항상 오른쪽 끝을 기준으로 잡아서, 부니를 화면 왼쪽으로 옮겨
        // 반전되고 나면 클릭 영역이 캐릭터가 없는 빈 쪽을 가리켜 영영 안 눌렸다.
        // 그리는 쪽과 같은 기준(characterOffsetX)을 써서 항상 캐릭터를 덮게 한다.
        let charOffset = PanelMetrics.characterOffsetX(flipped: controller.isNearLeftEdge)
        let margin     = (charWidth - PanelMetrics.characterAreaWidth) / 2
        return NSRect(x: f.minX + charOffset - margin, y: f.minY,
                      width: charWidth, height: charHeight)
    }

    // MARK: - Controller callbacks

    private func setupControllerCallbacks() {
        // 이 캐릭터만 숨김 — 다른 세션에는 영향 없음
        controller.onHideRequest          = { [weak self] in self?.hideThisCompanion() }
        controller.onShowRequest          = { [weak self] in self?.showCompanion() }
        controller.onOpenClaudeRequest    = { [weak self] in self?.onOpenClaude?() }
        controller.onOpenSettingsRequest  = { [weak self] in self?.onOpenSettings?() }
        controller.onShowStatusBarRequest = { [weak self] in self?.onShowStatusBar?() }
        controller.onEditMemoRequest      = { [weak self] in self?.showMemoEditDialog() }
        controller.onClearMemoRequest     = { [weak self] in self?.clearMemoToSessionDefault() }
        controller.onSwitchSessionRequest = { [weak self] targetId in self?.onSwitchSession?(targetId) }
        controller.onOpenSquadRequest     = { [weak self] jobId in self?.onOpenSquad?(jobId) }

        // 끝났을 때 이 세션이 스쿼드 작업의 것인지 확인한다 (파일을 읽으니 메인 스레드는 피한다)
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, case .completed = state else { return }
                let sid = self.sessionId
                DispatchQueue.global(qos: .utility).async {
                    let id = TeamStore.jobId(forSession: sid)
                    DispatchQueue.main.async { self.controller.squadJobId = id }
                }
            }
            .store(in: &cancellables)

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
                    // 메모를 비우면 기본값(세션 이름)으로 되돌아가므로 저장값을 남기지 않는다
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
            self.onSaveOrigin?(NSPoint(x: -1, y: -1))
        }

        // 모든 슬롯 드래그 가능, 위치도 슬롯별로 UserDefaults에 영속 저장
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

        // 숨겨진 패널을 다시 띄우는 유일한 통로.
        //  · 시스템이 숨긴 패널(Claude 종료 감지 등)은 예전처럼 활동이 감지되면 복구한다.
        //  · 사용자가 직접 숨긴 패널은 "이 세션이 새로 시작될 때"만 복구한다.
        //    진행 중에 숨겼다면 그 작업 안에는 시작 경계가 없으므로, 작업이 끝나고
        //    다음 작업이 시작되는 시점이 곧 복구 시점이 된다.
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let running  = state.isRunning
                let runStart = running && !self.wasRunning
                self.wasRunning = running

                // 실제로 새 작업이 시작됐다 — 전역 숨김도 여기서 함께 풀린다
                if runStart { self.onRunStart?() }

                if self.isManuallyHidden {
                    guard runStart else { return }
                    self.isManuallyHidden = false
                }
                guard state != .idle else { return }
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
        alert.messageText = L.t("메모 설정", "Set note")
        alert.informativeText = L.t("이 캐릭터의 메모를 입력하세요.\n(빈칸으로 두면 세션 이름으로 되돌아갑니다)",
                                    "Enter a note for this character.\n(Leave empty to go back to the session name)")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L.t("확인", "OK"))
        alert.addButton(withTitle: L.t("취소", "Cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = controller.memo
        input.placeholderString = L.t("예: 프로젝트명, 작업명...", "e.g. project or task name...")
        input.maximumNumberOfLines = 1
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // 비우면 "메모 없음"이 아니라 기본값(세션 이름)으로 되돌린다
                clearMemoToSessionDefault()
            } else {
                // 직접 입력한 순간부터 세션 이름 자동 연동을 끈다
                controller.memoIsAuto = false
                controller.memo = trimmed
            }
        }
    }

    /// 메모를 비웠을 때 — 사용자가 지정한 메모를 지우고 기본값인
    /// "세션 이름 자동 연동"으로 되돌린다. 저장된 메모 키를 남겨두면
    /// 다음 실행 때도 빈 메모로 복원되므로 둘 다 지운다.
    private func clearMemoToSessionDefault() {
        UserDefaults.standard.removeObject(forKey: "memo.session.\(sessionId)")
        UserDefaults.standard.removeObject(forKey: "memo.slot.\(slot)")
        // memoIsAuto를 먼저 켜야 아래 memo 변경이 "사용자 지정"으로 저장되지 않는다
        controller.memoIsAuto = true
        controller.memo = ""
        // 15초 주기 폴링을 기다리지 않고 지금 바로 세션 이름을 채운다
        titleQueue.async { [weak self] in self?.syncSessionTitle() }
    }

    // MARK: - Drag

    /// 드래그 중인 실제(화면상) x좌표를 customOrigin에 쓸 반전 전(캐릭터가 항상
    /// 패널 오른쪽 끝에 있다고 가정한) 좌표로 되돌린다. 말풍선이 반전된 상태로
    /// 드래그를 시작했다면 패널이 characterAreaWidth만큼 밀려 있으므로 그만큼 되돌려야
    /// customOrigin이 항상 같은 기준을 유지한다.
    private func unshiftedOrigin(from raw: NSPoint) -> NSPoint {
        guard controller.isNearLeftEdge else { return raw }
        return NSPoint(x: raw.x - (panelWidth - characterAreaWidth), y: raw.y)
    }

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
                    let logical = self.unshiftedOrigin(from: origin)
                    self.customOrigin = logical
                    self.onSaveOrigin?(logical)
                }
                // 드래그가 끝난 위치를 기준으로 말풍선 방향을 다시 판단하고,
                // 필요하면(왼쪽/오른쪽 반전이 바뀌었으면) 캐릭터 위치는 유지한 채
                // 패널을 알맞은 쪽으로 스냅시킨다.
                let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                    ?? NSScreen.main
                if let screen {
                    let target = self.controller.state == .idle
                        ? self.peekFrame(screen: screen)
                        : self.activeFrame(screen: screen)
                    self.panel?.setFrameOrigin(target.origin)
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
                // 마우스 커서가 있는 스크린 기준으로 클램핑 (멀티 모니터 대응).
                // 기준은 패널이 아니라 "캐릭터" — 패널 폭(320) 중 실제로 보이는 건
                // 캐릭터 영역뿐이라, 패널 기준으로 자르면 캐릭터가 통째로 화면 밖으로
                // 나가 부니가 사라진 것처럼 보인다.
                let screen = NSScreen.screens.first { $0.frame.contains(current) }
                    ?? NSScreen.main
                if let screen = screen {
                    let vf   = screen.visibleFrame
                    let minV = PanelMetrics.minVisible
                    // 캐릭터의 왼쪽 끝 = o.x + charOffset
                    let charOffset = PanelMetrics.characterOffsetX(flipped: self.controller.isNearLeftEdge)
                    o.x = max(vf.minX + minV - self.characterAreaWidth - charOffset,
                              min(vf.maxX - minV - charOffset, o.x))
                    o.y = max(vf.minY - self.panelHeight + 60,
                              min(screen.frame.maxY, o.y))
                }
                panel.setFrameOrigin(o)
                self.customOrigin = self.unshiftedOrigin(from: o)
            }
            return event
        }
    }
}
