import SwiftUI
import AppKit

// MARK: - Key Recorder Field

/// 클릭 후 다음 키 입력을 단축키로 기록하는 컨트롤
struct KeyRecorderField: View {
    let label: String
    @Binding var shortcut: KeyShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundColor(.white.opacity(0.85))

            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if isRecording {
                        Text(L.t("키 입력 대기...", "Press a key..."))
                            .foregroundColor(.yellow)
                    } else if let sc = shortcut {
                        Text(sc.displayString)
                            .foregroundColor(.white)
                    } else {
                        Text(L.t("없음", "None"))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    if !isRecording {
                        Image(systemName: "pencil")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 10))
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.yellow.opacity(0.7))
                            .font(.system(size: 10))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 160)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording
                              ? Color.yellow.opacity(0.15)
                              : Color.white.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecording
                                        ? Color.yellow.opacity(0.6)
                                        : Color.white.opacity(0.25),
                                        lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if shortcut != nil && !isRecording {
                Button(action: { shortcut = nil }) {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ESC 누르면 취소
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let relevant = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
            shortcut = KeyShortcut(keyCode: event.keyCode,
                                   modifiers: relevant.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - Settings View

struct ShortcutSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var lang  = LanguageStore.shared
    @ObservedObject private var awake = AwakeManager.shared
    @ObservedObject private var cloud = CloudSession.shared
    @ObservedObject private var cloudSync = CloudSync.shared

    var body: some View {
        // 항목이 늘어도 창에 가려 잘리지 않도록 스크롤 안에 둔다
        ScrollView {
            content
        }
        .frame(minWidth: 380, minHeight: 360)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.t("설정", "Settings"))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            Divider().background(Color.white.opacity(0.2))

            // ── 언어
            HStack {
                Text(L.t("언어", "Language"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Picker("", selection: $lang.current) {
                    ForEach(Language.allCases, id: \.self) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Divider().background(Color.white.opacity(0.2))

            // ── 단축키
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("단축키", "Shortcuts"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))

                VStack(alignment: .leading, spacing: 12) {
                    KeyRecorderField(label: L.t("권한 허락", "Approve"),
                                     shortcut: $store.approve)
                    KeyRecorderField(label: L.t("전체 허용", "Approve all"),
                                     shortcut: $store.alwaysApprove)
                    KeyRecorderField(label: L.t("권한 거부", "Deny"),
                                     shortcut: $store.deny)
                    KeyRecorderField(label: L.t("숨기기/보이기", "Hide / show"),
                                     shortcut: $store.hide)
                }
            }

            Divider().background(Color.white.opacity(0.2))

            // ── 계정 · 다른 PC와 연동 (선택)
            accountSection

            Divider().background(Color.white.opacity(0.2))

            // ── 덮개 닫아도 계속 실행 (시간대 예약)
            keepAwakeSection

            Divider().background(Color.white.opacity(0.2))

            HStack {
                Text(L.t("단축키는 전역으로 동작합니다.",
                         "Shortcuts work system-wide."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
                Spacer()
                Button(L.t("닫기", "Close")) { NSApp.keyWindow?.close() }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
            }
        }
        .padding(20)
        // 높이를 고정하면 항목이 많을 때 아래 구역이 위 구역(단축키 칸) 위로 겹쳐 가린다 — 내용 높이대로 두고 스크롤한다
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: store.approve)       { _ in store.save() }
        .onChange(of: store.alwaysApprove) { _ in store.save() }
        .onChange(of: store.deny)          { _ in store.save() }
        .onChange(of: store.hide)          { _ in store.save() }
    }

    /// 선택 기능 — 로그인하지 않아도 모든 기능을 그대로 쓸 수 있고,
    /// 다른 PC에서도 같은 설정·레벨을 쓰고 싶을 때만 로그인한다.
    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("계정 · 다른 PC와 연동", "Account · Sync across PCs"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            if !cloud.isConfigured {
                Text(L.t("서버 설정이 없어서 지금은 이 PC에만 저장돼요. 연동을 쓰려면 cloud/SETUP.md의 설정이 필요해요.",
                         "No server configured, so data stays on this PC. See cloud/SETUP.md to enable sync."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
            } else if let user = cloud.user {
                HStack(spacing: 6) {
                    Text("☁️").font(.system(size: 12))
                    Text(user.name ?? L.t("로그인됨", "Signed in"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    if cloudSync.isSyncing || cloud.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(lastSyncText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
                HStack(spacing: 8) {
                    Button(L.t("지금 동기화", "Sync now")) { Task { await cloudSync.syncNow() } }
                        .buttonStyle(PillButtonStyle(color: .accentColor))
                    Button(L.t("로그아웃", "Sign out")) { cloud.signOut() }
                        .buttonStyle(PillButtonStyle(color: .gray))
                    Spacer()
                    Button(L.t("서버 데이터 삭제", "Delete server data")) { confirmDeleteServerData() }
                        .buttonStyle(PillButtonStyle(color: Color(red: 0.86, green: 0.30, blue: 0.30)))
                }
            } else {
                Text(L.t("로그인은 선택이에요. 안 해도 모든 기능을 그대로 쓸 수 있고, 다른 PC에서도 같은 설정·레벨을 쓰고 싶을 때만 로그인하세요.",
                         "Signing in is optional. Everything works without it — sign in only if you want the same settings and level on your other PCs."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
                Button(L.t("Google로 로그인", "Sign in with Google")) { Task { await cloud.signIn() } }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(cloud.isBusy)
            }

            if let message = cloud.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.95, green: 0.75, blue: 0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
            }
        }
    }

    private var lastSyncText: String {
        guard let t = cloudSync.lastSync else { return L.t("아직 동기화 전이에요", "Not synced yet") }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return L.t("마지막 동기화: ", "Last synced: ") + f.localizedString(for: t, relativeTo: Date())
    }

    private func confirmDeleteServerData() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("서버 데이터를 지울까요?", "Delete your server data?")
        alert.informativeText = L.t("서버에 저장된 코인·아이템·착용 정보가 지워져요. 이 PC에 있는 데이터는 그대로 남고, 다시 로그인하면 이 PC 기준으로 새로 올라가요.",
                                    "Your coins, items and outfits on the server will be removed. Data on this PC stays, and signing in again uploads it afresh.")
        alert.addButton(withTitle: L.t("삭제", "Delete"))
        alert.addButton(withTitle: L.t("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await cloud.deleteServerData() }
    }

    /// 매일 지정한 시간대에 자동으로 켜고 끄는 예약.
    /// 권한(sudoers) 등록 전에는 안내만 보여준다 — 메뉴바에서 1회 설정한다.
    @ViewBuilder
    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("덮개 닫아도 계속 실행", "Keep running with lid closed"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            if awake.isHelperInstalled {
                Toggle(isOn: $awake.scheduleEnabled) {
                    Text(L.t("시간대 예약", "Daily schedule"))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 6) {
                    timeField(L.t("시작", "From"), minute: $awake.scheduleStartMinute)
                    Text("~").foregroundColor(.white.opacity(0.5))
                    timeField(L.t("종료", "To"), minute: $awake.scheduleEndMinute)
                }
                .disabled(!awake.scheduleEnabled)
                .opacity(awake.scheduleEnabled ? 1 : 0.4)

                Text(L.t("예약된 시간에는 덮개를 닫아도 자지 않아요. 가방 안에서는 열이 오를 수 있어요.",
                         "It won't sleep during the scheduled window. It can get warm in a bag."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
            } else {
                Text(L.t("메뉴바 → 덮개 닫아도 계속 실행 → 권한 설정하기에서 먼저 1회 설정해 주세요.",
                         "Set it up once from the menu bar first."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)   // 줄바꿈이 되도록 — 한 줄로 잘리지 않게
            }
        }
    }

    private func timeField(_ label: String, minute: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
            Stepper(value: minute, in: 0...(24 * 60 - 1), step: 30) {
                Text(String(format: "%02d:%02d", minute.wrappedValue / 60, minute.wrappedValue % 60))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Button Style

struct PillButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
    }
}
