import SwiftUI

/// 메뉴바 아이콘의 메뉴에 있는 기능을 화면에 떠 있는 부니(우클릭 메뉴)에서도 쓰게 이어 주는 다리.
/// 동작은 AppDelegate 가 closure 로 넣어 주고, 화면은 `state` 만 읽는다.
/// `state` 는 바뀔 때만 발행해서, 메뉴 내용이 바뀐 때에만 캐릭터 뷰가 다시 만들어지게 한다.
final class AppMenuBridge: ObservableObject {
    static let shared = AppMenuBridge()

    /// 메뉴에 보여줄 앱 전체 상태 (AppDelegate 가 메뉴를 다시 만들 때 갱신)
    struct State: Equatable {
        var updateVersion: String?
        var updateStatus: String?
        var statusBarHidden = false
        var anyAlwaysApprove = false
        var launchAtLogin = false
        var reviewCount = 0
        var chatRoom: String?
        var proSummary = ""
    }

    @Published private(set) var state = State()

    func update(_ new: State) {
        if new != state { state = new }
    }

    // 동작 (AppDelegate 가 채운다)
    var hideAll: () -> Void = {}
    var showAll: () -> Void = {}
    var openShop: () -> Void = {}
    var openChat: () -> Void = {}
    var openTeam: () -> Void = {}
    var openUpgrade: () -> Void = {}
    var openSettings: () -> Void = {}
    var toggleFocusMode: () -> Void = {}
    var setFocusIdleMinutes: (Int) -> Void = { _ in }
    var promptFocusIdleMinutes: () -> Void = {}
    var startKeepAwake: (TimeInterval?) -> Void = { _ in }
    var startKeepAwakeFollowing: () -> Void = {}
    var stopKeepAwake: () -> Void = {}
    var installAwakeHelper: () -> Void = {}
    var toggleLaunchAtLogin: () -> Void = {}
    var hideStatusBar: () -> Void = {}
    var showStatusBar: () -> Void = {}
    var disableAlwaysApprove: () -> Void = {}
    var downloadUpdate: () -> Void = {}
}

extension CompanionView {
    /// 우클릭 메뉴에 덧붙는 앱 전체 메뉴 — 메뉴바 아이콘 메뉴와 같은 구성:
    /// 자주 쓰는 3가지는 바로 보이고, 나머지는 접어 둔 묶음에서 펼친다.
    @ViewBuilder
    func appMenuItems() -> some View {
        let app = AppMenuBridge.shared
        let st = app.state
        let focus = FocusModeStore.shared
        let awake = AwakeManager.shared

        if st.anyAlwaysApprove {
            Button(L.t("⚡ 전체 허용 모드 끄기", "⚡ Turn off approve-all")) { app.disableAlwaysApprove() }
            Divider()
        }

        Button(st.reviewCount > 0
               ? L.t("🐰 부니 스쿼드…  (검토 대기 \(st.reviewCount))", "🐰 Buni Squad…  (\(st.reviewCount) to review)")
               : L.t("🐰 부니 스쿼드…", "🐰 Buni Squad…")) { app.openTeam() }
        Button(L.t("🛍 부니 상점  (🪙 \(ShopStore.shared.coins))", "🛍 Buni Shop  (🪙 \(ShopStore.shared.coins))")) { app.openShop() }
        Button(st.chatRoom.map { L.t("💬 부니 채팅  (방 \($0))", "💬 Buni Chat  (room \($0))") }
               ?? L.t("💬 부니 채팅…", "💬 Buni Chat…")) { app.openChat() }
        Button(L.t("⭐ 부니 Pro  (\(st.proSummary))", "⭐ Buni Pro  (\(st.proSummary))")) { app.openUpgrade() }
        Divider()

        Menu(L.t("부니 화면", "On screen")) {
            Button(L.t("전체 부니 숨기기", "Hide all Buni")) { app.hideAll() }
            Button(L.t("전체 부니 불러오기", "Show all Buni")) { app.showAll() }
            Button(L.t("위치 초기화", "Reset position")) { ctrl.onResetPositionRequest?() }
            Divider()
            Button(L.t("Claude 열기", "Open Claude")) { ctrl.onOpenClaudeRequest?() }
        }

        Menu(L.t("작업 도구", "Work tools") + ((awake.isActive || focus.enabled)
                                              ? "  " + (awake.isActive ? "☕️" : "") + (focus.enabled ? "🏃" : "") : "")) {
            keepAwakeMenu(awake: awake, app: app)
            Toggle(L.t("딴짓 방해모드", "Distraction mode"),
                   isOn: Binding(get: { focus.enabled }, set: { _ in app.toggleFocusMode() }))
            Menu(L.t("방해 시작 시간: \(focus.idleMinutes)분", "Starts after: \(focus.idleMinutes) min idle")) {
                ForEach(FocusModeStore.presetMinutes, id: \.self) { m in
                    Toggle(L.t("\(m)분", "\(m) min"),
                           isOn: Binding(get: { focus.idleMinutes == m }, set: { _ in app.setFocusIdleMinutes(m) }))
                }
                Divider()
                Toggle(L.t("직접 입력…", "Custom…"),
                       isOn: Binding(get: { !FocusModeStore.presetMinutes.contains(focus.idleMinutes) },
                                     set: { _ in app.promptFocusIdleMinutes() }))
            }
        }

        Menu(L.t("앱", "App")) {
            Button(L.t("설정...", "Settings...")) { ctrl.onOpenSettingsRequest?() }
            Toggle(L.t("부팅 시 자동 실행", "Launch at login"),
                   isOn: Binding(get: { st.launchAtLogin }, set: { _ in app.toggleLaunchAtLogin() }))
            if st.statusBarHidden {
                Button(L.t("메뉴바 아이콘 표시", "Show menu bar icon")) { app.showStatusBar() }
            } else {
                Button(L.t("메뉴바 아이콘 숨기기", "Hide menu bar icon")) { app.hideStatusBar() }
            }
            Divider()
            Text("Buni v\(UpdateChecker.currentVersion)")
        }

        if let ver = st.updateVersion {
            if let status = st.updateStatus {
                Text(status)
            } else {
                Button(L.t("🆕 v\(ver)로 업데이트…", "🆕 Update to v\(ver)…")) { app.downloadUpdate() }
            }
        }
    }

    @ViewBuilder
    private func keepAwakeMenu(awake: AwakeManager, app: AppMenuBridge) -> some View {
        let title = awake.isActive
            ? L.t("☕️ 덮개 닫아도 실행 중 — \(awake.statusText)", "☕️ Staying awake — \(awake.statusText)")
            : L.t("덮개 닫아도 계속 실행", "Keep running with lid closed")
        Menu(title) {
            if !awake.isHelperInstalled {
                Button(L.t("권한 설정하기… (최초 1회)", "Set up permission… (one time)")) { app.installAwakeHelper() }
                Text(L.t("덮개를 닫아도 자지 않으려면 관리자 권한이 필요해요",
                         "Admin rights are needed to stay awake with the lid closed"))
            } else {
                Toggle(L.t("세션 실행 중에만 (끝나면 자동 해제)", "While sessions run (auto-off when done)"),
                       isOn: Binding(get: { awake.followingSessions }, set: { _ in app.startKeepAwakeFollowing() }))
                Divider()
                Button(L.t("30분", "30 min")) { app.startKeepAwake(30 * 60) }
                Button(L.t("1시간", "1 hour")) { app.startKeepAwake(60 * 60) }
                Button(L.t("2시간", "2 hours")) { app.startKeepAwake(2 * 3600) }
                Button(L.t("4시간", "4 hours")) { app.startKeepAwake(4 * 3600) }
                Button(L.t("무제한", "No limit")) { app.startKeepAwake(nil) }
                Divider()
                Button(L.t("지금 끄기", "Turn off now")) { app.stopKeepAwake() }
                    .disabled(!awake.isActive)
                Button(awake.scheduleEnabled
                       ? L.t("시간대 예약 켜짐 (\(AwakeManager.hhmm(awake.scheduleStartMinute))~\(AwakeManager.hhmm(awake.scheduleEndMinute)))",
                             "Schedule on (\(AwakeManager.hhmm(awake.scheduleStartMinute))–\(AwakeManager.hhmm(awake.scheduleEndMinute)))")
                       : L.t("시간대 예약 설정…", "Set daily schedule…")) { app.openSettings() }
                if let err = awake.lastError { Text("⚠️ " + err) }
            }
        }
    }
}
