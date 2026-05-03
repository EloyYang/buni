import SwiftUI

struct CompanionView: View {
    @EnvironmentObject var ctrl: CompanionController
    @ObservedObject private var characterStore = CharacterStore.shared

    // 생각 중 점 애니메이션 (1·2·3 순환)
    @State private var dotCount = 1
    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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
                .padding(.top, 6)

                // 캐릭터 + 사용량 바
                VStack(spacing: 2) {
                    characterView
                        .frame(width: 60, height: 70)

                    UsageBarView(percent: ctrl.usagePercent,
                                 sessionStart: ctrl.sessionStart)
                        .frame(width: 66)
                        .opacity(ctrl.state == .idle ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: ctrl.state == .idle)
                }
                .padding(.trailing, 6)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { ctrl.onOpenClaudeRequest?() }
                .contextMenu {
                    Button("숨기기") { ctrl.onHideRequest?() }
                    Divider()
                    Button("Claude 열기") { ctrl.onOpenClaudeRequest?() }
                    Divider()
                    // 캐릭터 선택
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
        .onChange(of: ctrl.state) { newState in
            if case .thinking = newState { dotCount = 1 }
        }
    }

    // MARK: - 캐릭터 선택

    @ViewBuilder
    private var characterView: some View {
        switch characterStore.selected {
        case .crab:
            ClaudeCharacterView()
        case .jellyfish:
            JellyfishCharacterView()
        case .rabbit:
            RabbitCharacterView()
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
