import SwiftUI
import Combine

struct CompanionView: View {
    @EnvironmentObject var ctrl: CompanionController
    /// 로그인해서 다른 PC까지 합친 토큰이 있으면 게이지 레벨도 그 값을 쓴다 (상점 레벨과 같게)
    @ObservedObject private var shop = ShopStore.shared
    /// 언어를 바꾸면 모든 문구가 바로 다시 그려지도록 구독
    @ObservedObject private var lang = LanguageStore.shared
    /// 메뉴바 아이콘 메뉴와 같은 앱 전체 메뉴를 우클릭 메뉴에 붙이기 위한 상태 구독
    @ObservedObject private var appMenu = AppMenuBridge.shared
    @ObservedObject private var focusMode = FocusModeStore.shared
    @ObservedObject private var awake = AwakeManager.shared
    @ObservedObject private var team = TeamStore.shared

    // 리셋 시간 갱신 (30초마다)
    @State private var resetTimeTick = Date()
    private let resetTimer = Timer.publish(every: 30, tolerance: 10, on: .main, in: .common).autoconnect()

    // 한도 도달 시 카운트다운 갱신 (1초마다 — 안내 버블이 떠 있고 보일 때만 돌린다)
    @State private var limitTick = Date()
    private let limitTimer = Timer.publish(every: 1, tolerance: 0.5, on: .main, in: .common)
    @State private var limitTimerRun: Cancellable?

    private func syncLimitTimer() {
        let need = ctrl.isLimitNoticeVisible && !ctrl.isPaused
        if need, limitTimerRun == nil { limitTimerRun = limitTimer.connect() }
        else if !need { limitTimerRun?.cancel(); limitTimerRun = nil }
    }

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
        // 캐릭터가 화면 왼쪽에 있으면(SessionWindow가 판단) 순서와 정렬을 통째로
        // 반전해, 말풍선이 항상 캐릭터를 기준으로 화면 안쪽을 향하게 한다.
        ZStack(alignment: ctrl.isNearLeftEdge ? .bottomLeading : .bottomTrailing) {
            Color.clear.allowsHitTesting(false)

            Group {
                if ctrl.isNearLeftEdge {
                    HStack(alignment: .top, spacing: 19) {
                        characterBlock
                        bubbleSlot
                    }
                } else {
                    HStack(alignment: .top, spacing: 19) {
                        bubbleSlot
                        characterBlock
                    }
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
        .onAppear { syncLimitTimer() }
        .onChange(of: ctrl.isLimitNoticeVisible) { _ in syncLimitTimer() }
        .onChange(of: ctrl.isPaused) { _ in syncLimitTimer() }
        // 애니메이션을 멈춘 동안(가려짐·화면 꺼짐)에는 작업 도구 등 하위 뷰도 같이 멈춘다
        .environment(\.buniPaused, ctrl.isPaused)
    }

    /// 상태에 맞는 말풍선(권한 요청/완료/한도 안내/일반) 하나
    /// 메모 태그의 실제 높이 — 2줄이 돼도 캐릭터를 덮지 않도록 이 값만큼 띄운다
    @State private var memoTagHeight: CGFloat = 0

    @ViewBuilder
    private var bubbleSlot: some View {
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
    }

    /// 캐릭터 + 플랜 사용량 바 + 메모 태그 + 드래그/우클릭 메뉴
    private var characterBlock: some View {
        VStack(spacing: -5) {
            TintedCharacter { characterView }
                .frame(width: 60, height: 70)

            UsageBarView(percent: ctrl.displayUsagePercent,
                         label: ctrl.planTokenLabel,
                         resetTime: resetTimeString(from: resetTimeTick),
                         monthlyTokens: max(ctrl.monthlyTokens, shop.cloudTokenTotal ?? 0))
                .frame(width: 66)
                .opacity(ctrl.state == .idle ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: ctrl.state == .idle)
        }
        // ── 메모 태그: 레이아웃에 영향 없이 캐릭터 위에 띄우기.
        // 예전에는 alignmentGuide로 올렸는데, 세션 이름이 길어 2줄이 되면
        // 측정된 높이와 실제 높이가 어긋나 아랫줄이 캐릭터에 겹쳤다.
        // 이제 태그의 실제 높이를 재서 그 높이 + 여백만큼 위로 올린다.
        .overlay(alignment: .top) {
            if !ctrl.memo.isEmpty {
                memoTagView
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MemoTagHeightKey.self, value: g.size.height)
                    })
                    .offset(y: -(memoTagHeight + 8))
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                        removal:   .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .onPreferenceChange(MemoTagHeightKey.self) { memoTagHeight = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.70), value: ctrl.memo.isEmpty)
        // 말풍선이 있는 안쪽이 아니라 화면 바깥쪽 가장자리에 살짝 여백을 둔다
        .padding(ctrl.isNearLeftEdge ? .leading : .trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { ctrl.onOpenClaudeRequest?() }
        // 쓰다듬기 — 누른 높이로 부위를 가린다. 캐릭터는 위에서부터 70pt를
        // 차지하고 귀가 위쪽 26pt를 쓰므로, 그 위를 누르면 귀로 본다.
        .gesture(
            SpatialTapGesture(count: 1, coordinateSpace: .local)
                .onEnded { value in
                    guard value.location.y <= 70 else { return }   // 게이지 바는 제외
                    ctrl.touch(value.location.y < 26 ? .ear : .body)
                }
        )
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
        // 앱 전체 메뉴의 체크 표시·상태도 같은 방식으로 최신으로 유지한다.
        .id(ctrl.switchTargets.map(\.id).joined(separator: ",")
            + "|\(appMenu.state)|\(focusMode.enabled)|\(focusMode.idleMinutes)"
            + "|\(awake.isActive)|\(awake.followingSessions)|\(awake.isHelperInstalled)|\(awake.scheduleEnabled)")
        .contextMenu {
            // 이 부니에만 해당하는 것
            Button(L.t("숨기기", "Hide")) { ctrl.onHideRequest?() }
            Button(ctrl.memo.isEmpty ? L.t("메모 추가...", "Add note...") : L.t("메모 편집...", "Edit note...")) {
                ctrl.onEditMemoRequest?()
            }
            if !ctrl.memo.isEmpty {
                Button(L.t("메모 지우기", "Clear note")) {
                    // 지우면 빈 메모가 아니라 기본값(세션 이름)으로 되돌린다
                    ctrl.onClearMemoRequest?()
                }
            }
            Menu(L.t("캐릭터 변경", "Change character")) {
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
            Menu(L.t("컬러 변형 (Pro)", "Color variant (Pro)")) {
                Button(L.t("원래 색", "Original")) { CharacterStore.shared.tint = nil }
                ForEach(CharacterTint.all) { t in
                    let open = ProManager.shared.itemUnlocked(t.id)
                    Button {
                        if open { CharacterStore.shared.tint = t.id }
                        else { ProUpgradeWindow.show(reason: ProManager.shared.itemLockMessage(t.id)) }
                    } label: {
                        Text((open ? "" : "🔒 ") + t.name)
                    }
                }
            }
            if !ctrl.switchTargets.isEmpty {
                Menu(L.t("다른 세션으로 전환", "Switch session")) {
                    ForEach(ctrl.switchTargets) { t in
                        Button(t.label) { ctrl.onSwitchSessionRequest?(t.id) }
                    }
                }
            }
            Divider()
            // 메뉴바 아이콘 메뉴와 같은 기능 (접어 둔 묶음)
            appMenuItems()
        }
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
        SpeechBubbleShell(flipped: ctrl.isNearLeftEdge) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("✅")
                    Text(L.t("완료했어요!", "All done!"))
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                }
                if let jobId = ctrl.squadJobId {
                    // 부니 스쿼드가 돌린 세션이면 — 눌러서 스쿼드 화면의 그 작업으로 간다
                    let finished = ["review", "done"].contains(team.jobs.first { $0.id == jobId }?.state ?? "")
                    confirmButton(finished ? L.t("🐰 스쿼드 결과 보기", "🐰 See squad result") : L.t("🐰 스쿼드 보기", "🐰 Open squad"),
                                  color: Color(red: 0.45, green: 0.30, blue: 0.85)) {
                        ctrl.onOpenSquadRequest?(jobId)
                        ctrl.dismissCompleted()
                    }
                }
                HStack {
                    Spacer()
                    confirmButton(L.t("확인", "OK"), color: Color(red: 0.20, green: 0.70, blue: 0.35)) {
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
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: ctrl.isNearLeftEdge ? .topLeading : .topTrailing).combined(with: .opacity),
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
                    onDeny:       { ctrl.denyPermission() },
                    flipped: ctrl.isNearLeftEdge
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.8, anchor: ctrl.isNearLeftEdge ? .topLeading : .topTrailing).combined(with: .opacity),
                        removal:   .opacity
                    )
                )
            } else {
                askUserBubble(message: cmd)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: ctrl.isNearLeftEdge ? .topLeading : .topTrailing).combined(with: .opacity),
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
        guard let resetAt = ctrl.limitResetAt else { return L.t("재설정 시각 확인 중", "Checking reset time") }
        let diff = Int(resetAt.timeIntervalSince(now))
        guard diff > 0 else { return L.t("곧 재설정돼요", "Resetting soon") }
        let h = diff / 3600
        let m = (diff % 3600) / 60
        let s = diff % 60
        let fmtH = L.t("%d:%02d:%02d 후 재설정", "resets in %d:%02d:%02d")
        let fmtM = L.t("%d:%02d 후 재설정", "resets in %d:%02d")
        return h > 0 ? String(format: fmtH, h, m, s)
                     : String(format: fmtM, m, s)
    }

    private var limitBubbleView: some View {
        SpeechBubbleShell(flipped: ctrl.isNearLeftEdge) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("⏳")
                    Text(L.t("한도에 도달했어요", "Usage limit reached"))
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
                    confirmButton(L.t("숨기기", "Dismiss"), color: Color(red: 0.45, green: 0.45, blue: 0.50)) {
                        ctrl.dismissLimitNotice()
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
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: ctrl.isNearLeftEdge ? .topLeading : .topTrailing).combined(with: .opacity),
                removal:   .opacity
            )
        )
    }

    // MARK: - 입력 대기 버블 (AskUserQuestion — 클로드 열기 버튼 제공)

    @ViewBuilder
    private func askUserBubble(message: String) -> some View {
        SpeechBubbleShell(flipped: ctrl.isNearLeftEdge) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("✅")
                    Text(L.t("확인이 필요해요!", "Needs your input!"))
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
                // 클로드로 가서 답할 것이므로 버블도 같이 정리한다 —
                // 안 그러면 답한 뒤에도 버블이 그대로 남는다
                Button {
                    ctrl.onOpenClaudeRequest?()
                    ctrl.dismissAskUser()
                } label: {
                    Text(L.t("클로드 열기", "Open Claude"))
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
        }
    }

    // MARK: - 메모 태그 (캐릭터 머리 위)

    private var memoTagView: some View {
        // 세션 이름이 길면(자동 연동 메모) 끝없이 길어지는 대신 최대 2줄까지만
        // 보여주고, 그래도 안 들어가면 말줄임표로 자연스럽게 자른다.
        Text(ctrl.memo)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(width: 66)
            .shadow(color: .black.opacity(0.60), radius: 2, x: 0, y: 1)
    }

    // MARK: - 일반 말풍선

    private var bubbleMessage: String? {
        // 한도에 걸리면 이벤트가 끊겨 마지막 상태("코딩중")가 그대로 남으므로,
        // 안내를 숨긴 경우에도 잘못된 상태를 계속 보여주지 않는다.
        if ctrl.isLimitReached { return nil }
        switch ctrl.state {
        case .thinking:              return L.t("코딩중", "Coding")
        case .toolUse(let name):     return name
        case .toolRead(let name):    return name
        case .notification(let msg):     return msg
        case .backgroundWork(let msg):   return msg
        case .permission, .completed:    return nil
        case .idle, .ready:              return nil
        }
    }

    @ViewBuilder
    private var regularBubbleView: some View {
        if let msg = bubbleMessage {
            ChatBubbleView(message: msg, flipped: ctrl.isNearLeftEdge)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.8, anchor: ctrl.isNearLeftEdge ? .topLeading : .topTrailing).combined(with: .opacity),
                        removal:   .opacity
                    )
                )
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// 메모 태그 높이를 부모로 올려보내는 키
private struct MemoTagHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
