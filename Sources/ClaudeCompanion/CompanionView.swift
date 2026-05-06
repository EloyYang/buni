import SwiftUI

struct CompanionView: View {
    @EnvironmentObject var ctrl: CompanionController
    @ObservedObject private var characterStore = CharacterStore.shared

    // 생각 중 점 애니메이션 (1·2·3 순환)
    @State private var dotCount = 1
    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // 리셋 시간 갱신 (1분마다)
    @State private var resetTimeTick = Date()
    private let resetTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // 드래그 위치 조정
    @State private var dragActive = false

    private var isPermission: Bool {
        if case .permission = ctrl.state { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 19) {
                // 권한 요청 중: 인터랙티브 버블 / 그 외: 일반 버블
                Group {
                    if isPermission {
                        permissionBubbleView
                            .allowsHitTesting(true)
                    } else {
                        regularBubbleView
                            .allowsHitTesting(false)
                    }
                }
                .padding(.bottom, 6)

                // 캐릭터 + 플랜 사용량 바
                VStack(spacing: 1) {
                    characterView
                        .frame(width: 60, height: 70)

                    UsageBarView(percent: ctrl.displayUsagePercent,
                                 label: ctrl.planTokenLabel,
                                 resetTime: resetTimeString(from: resetTimeTick))
                        .frame(width: 66)
                        .opacity(ctrl.state == .idle ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: ctrl.state == .idle)
                }
                .padding(.trailing, 6)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    ctrl.onOpenClaudeRequest?()
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { value in
                            if !dragActive {
                                dragActive = true
                                ctrl.onPanelDragStart?()
                            }
                            ctrl.onPanelDrag?(value.translation)
                        }
                        .onEnded { _ in
                            dragActive = false
                            ctrl.onPanelDragEnd?()
                        }
                )
                .contextMenu {
                    Button("숨기기") { ctrl.onHideRequest?() }
                    Button("메뉴바 아이콘 표시") { ctrl.onShowStatusBarRequest?() }
                    Divider()
                    Button("Claude 열기") { ctrl.onOpenClaudeRequest?() }
                    Divider()
                    Menu("캐릭터 변경") {
                        ForEach(CharacterType.allCases, id: \.self) { type in
                            Button {
                                characterStore.selected = type
                            } label: {
                                if characterStore.selected == type {
                                    Label(type.displayName, systemImage: "checkmark")
                                } else {
                                    Text(type.displayName)
                                }
                            }
                        }
                    }
                    Button("단축키 설정...") { ctrl.onOpenSettingsRequest?() }
                    Divider()
                    Button("위치 초기화") { ctrl.onResetPositionRequest?() }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: bubbleMessage)
        .onReceive(dotTimer) { _ in
            guard case .thinking = ctrl.state else { return }
            dotCount = dotCount % 3 + 1
        }
        .onReceive(resetTimer) { t in resetTimeTick = t }
        .onChange(of: ctrl.state) { newState in
            if case .thinking = newState { dotCount = 1 }
        }
    }

    // MARK: - 리셋 시간 계산 (서버 resets_at 우선, 없으면 sessionStart+5h)

    private func resetTimeString(from now: Date) -> String {
        // 서버에서 받은 resets_at 우선
        let resetAt: Date
        if let serverReset = ctrl.serverResetsAt {
            resetAt = serverReset
        } else if let start = ctrl.sessionStart {
            resetAt = start.addingTimeInterval(5 * 3600)
        } else {
            return ""
        }
        let diff = Int(resetAt.timeIntervalSince(now))
        guard diff > 0 else { return "" }
        let h = diff / 3600
        let m = (diff % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%dm", m)
        }
    }

    // MARK: - 캐릭터 선택

    @ViewBuilder
    private var characterView: some View {
        switch characterStore.selected {
        case .rabbit:
            RabbitCharacterView()
        case .jellyfish:
            JellyfishCharacterView()
        }
    }

    // MARK: - 권한 요청 버블 (버튼 포함)

    @ViewBuilder
    private var permissionBubbleView: some View {
        if case .permission(let cmd) = ctrl.state {
            PermissionBubbleView(
                command: cmd,
                onApprove:    { ctrl.approvePermission() },
                onApproveAll: { ctrl.approveAllPermissions() },
                onDeny:       { ctrl.denyPermission() }
            )
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                    removal:   .opacity
                )
            )
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: - 일반 말풍선

    private var bubbleMessage: String? {
        switch ctrl.state {
        case .thinking:              return String(repeating: ".", count: dotCount)
        case .toolUse(let name):     return name
        case .notification(let msg): return msg
        case .permission:            return nil   // permissionBubbleView가 담당
        case .idle, .ready:          return nil
        }
    }

    @ViewBuilder
    private var regularBubbleView: some View {
        if let msg = bubbleMessage {
            ChatBubbleView(message: msg)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                        removal:   .opacity
                    )
                )
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
