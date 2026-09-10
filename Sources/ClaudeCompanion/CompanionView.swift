import SwiftUI

struct CompanionView: View {
    @EnvironmentObject var ctrl: CompanionController

    // 리셋 시간 갱신 (30초마다)
    @State private var resetTimeTick = Date()
    private let resetTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // 한도 도달 시 카운트다운 갱신 (1초마다 — 안내 버블이 떠 있을 때만 반영)
    @State private var limitTick = Date()
    private let limitTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // 드래그 위치 조정
    @State private var dragActive = false

    private var isPermission: Bool {
        if case .permission = ctrl.state { return true }
        return false
    }

    private var isCompleted: Bool {
        if case .completed = ctrl.state { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.allowsHitTesting(false)

            HStack(alignment: .top, spacing: 19) {
                Group {
                    if isPermission {
                        permissionBubbleView
                    } else if isCompleted {
                        completionBubbleView
                    } else if ctrl.isLimitNoticeVisible {
                        limitBubbleView
                    } else {
                        regularBubbleView
                    }
                }
                .padding(.bottom, 6)
                .allowsHitTesting(isPermission || isCompleted || ctrl.isLimitNoticeVisible)

                // 캐릭터 + 플랜 사용량 바
                VStack(spacing: -5) {
                    characterView
                        .frame(width: 60, height: 70)

                    UsageBarView(percent: ctrl.displayUsagePercent,
                                 label: ctrl.planTokenLabel,
                                 resetTime: resetTimeString(from: resetTimeTick),
                                 monthlyTokens: ctrl.monthlyTokens)
                        .frame(width: 66)
                        .opacity(ctrl.state == .idle ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: ctrl.state == .idle)
                }
                // ── 메모 태그: 레이아웃에 영향 없이 캐릭터 위에 띄우기
                // alignmentGuide로 bottom을 VStack top에 맞춰 귀 위로 올림
                .overlay(alignment: .top) {
                    if !ctrl.memo.isEmpty {
                        memoTagView
                            .alignmentGuide(.top) { d in d[.bottom] }
                            .offset(y: -20)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                                removal:   .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.70), value: ctrl.memo.isEmpty)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { ctrl.onOpenClaudeRequest?() }
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
                // macOS SwiftUI의 .contextMenu는 동적(ForEach 등) 서브메뉴 내용이 한 번
                // 만들어진 뒤 안 바뀌는 경우가 있어(NSMenu 캐싱 문제로 보임), 전환 대상
                // 목록이 바뀔 때마다 뷰 자체를 새로 만들도록 강제해 메뉴가 항상 다시
                // 지어지게 한다.
                .id(ctrl.switchTargets.map(\.id).joined(separator: ","))
                .contextMenu {
                    Button("숨기기") { ctrl.onHideRequest?() }
                    Button("메뉴바 아이콘 표시") { ctrl.onShowStatusBarRequest?() }
                    Divider()
                    Button("Claude 열기") { ctrl.onOpenClaudeRequest?() }
                    Divider()
                    Menu("캐릭터 변경") {
                        ForEach(CharacterType.allCases, id: \.self) { type in
                            Button {
                                ctrl.character = type
                                // 새 세션의 기본값으로도 저장
                                UserDefaults.standard.set(type.rawValue, forKey: "character.selected")
                            } label: {
                                if ctrl.character == type {
                                    Label(type.displayName, systemImage: "checkmark")
                                } else {
                                    Text(type.displayName)
                                }
                            }
                        }
                    }
                    if !ctrl.switchTargets.isEmpty {
                        Menu("다른 세션으로 전환") {
                            ForEach(ctrl.switchTargets) { t in
                                Button(t.label) { ctrl.onSwitchSessionRequest?(t.id) }
                            }
                        }
                    }
                    Divider()
                    Button(ctrl.memo.isEmpty ? "메모 추가..." : "메모 편집...") {
                        ctrl.onEditMemoRequest?()
                    }
                    if !ctrl.memo.isEmpty {
                        Button("메모 지우기") {
                            // 직접 지운 것이므로 세션 이름 자동 연동을 끈다
                            ctrl.memoIsAuto = false
                            ctrl.memo = ""
                        }
                    }
                    Divider()
                    Button("단축키 설정...") { ctrl.onOpenSettingsRequest?() }
                    Divider()
                    Button("위치 초기화") { ctrl.onResetPositionRequest?() }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: bubbleMessage)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isCompleted)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ctrl.isLimitNoticeVisible)
        .onReceive(resetTimer) { t in resetTimeTick = t }
        // 한도 안내가 떠 있을 때만 상태를 갱신해 불필요한 재렌더 방지
        .onReceive(limitTimer) { t in if ctrl.isLimitNoticeVisible { limitTick = t } }
    }

    // MARK: - 리셋 시간 계산

    private func resetTimeString(from now: Date) -> String {
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
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "%dm", m)
    }

    // MARK: - 캐릭터 선택

    @ViewBuilder
    private var characterView: some View {
        switch ctrl.character {
        case .rabbit:        RabbitCharacterView()
        case .brownRabbit:   BrownRabbitCharacterView()
        case .pinkRabbit:    PinkRabbitCharacterView()
        case .orangeRabbit:  OrangeRabbitCharacterView()
        case .yellowRabbit:  YellowRabbitCharacterView()
        case .greenRabbit:   GreenRabbitCharacterView()
        }
    }

    // MARK: - 완료 버블

    @ViewBuilder
    private var completionBubbleView: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("✅")
                    Text("완료했어요!")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                }
                HStack {
                    Spacer()
                    confirmButton("확인", color: Color(red: 0.20, green: 0.70, blue: 0.35)) {
                        ctrl.dismissCompleted()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.20), radius: 8, x: -2, y: 3)
            )

            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .offset(x: 14, y: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                removal:   .opacity
            )
        )
    }

    private func confirmButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(color))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 권한 요청 버블

    @ViewBuilder
    private var permissionBubbleView: some View {
        if case .permission(let cmd) = ctrl.state {
            if ctrl.pendingPermissionId != nil {
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
                askUserBubble(message: cmd)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                            removal:   .opacity
                        )
                    )
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: - 한도 도달 버블 (재설정까지 카운트다운 + 숨기기)

    /// 한도 재설정까지 남은 시간 — "1:23:45" / "23:45" 형식
    private func limitCountdownString(from now: Date) -> String {
        guard let resetAt = ctrl.limitResetAt else { return "재설정 시각 확인 중" }
        let diff = Int(resetAt.timeIntervalSince(now))
        guard diff > 0 else { return "곧 재설정돼요" }
        let h = diff / 3600
        let m = (diff % 3600) / 60
        let s = diff % 60
        return h > 0 ? String(format: "%d:%02d:%02d 후 재설정", h, m, s)
                     : String(format: "%d:%02d 후 재설정", m, s)
    }

    private var limitBubbleView: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("⏳")
                    Text("한도에 도달했어요")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                }
                Text(limitCountdownString(from: limitTick))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                    )
                HStack {
                    Spacer()
                    confirmButton("숨기기", color: Color(red: 0.45, green: 0.45, blue: 0.50)) {
                        ctrl.limitNoticeDismissed = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.20), radius: 8, x: -2, y: 3)
            )

            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .offset(x: 14, y: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                removal:   .opacity
            )
        )
    }

    // MARK: - 입력 대기 버블 (AskUserQuestion — 클로드 열기 버튼 제공)

    @ViewBuilder
    private func askUserBubble(message: String) -> some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("✅")
                    Text("확인이 필요해요!")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                        )
                }
                Button { ctrl.onOpenClaudeRequest?() } label: {
                    Text("클로드 열기")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.25, green: 0.50, blue: 0.90))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.20), radius: 8, x: -2, y: 3)
            )

            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .offset(x: 14, y: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 메모 태그 (캐릭터 머리 위)

    private var memoTagView: some View {
        Text(ctrl.memo)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 66)
            .shadow(color: .black.opacity(0.60), radius: 2, x: 0, y: 1)
    }

    // MARK: - 일반 말풍선

    private var bubbleMessage: String? {
        // 한도에 걸리면 이벤트가 끊겨 마지막 상태("코딩중")가 그대로 남으므로,
        // 안내를 숨긴 경우에도 잘못된 상태를 계속 보여주지 않는다.
        if ctrl.isLimitReached { return nil }
        switch ctrl.state {
        case .thinking:              return "코딩중"
        case .toolUse(let name):     return name
        case .toolRead(let name):    return name
        case .notification(let msg): return msg
        case .permission, .completed: return nil
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
