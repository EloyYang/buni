import SwiftUI
import Cocoa
import Combine

// MARK: - 채팅 부니 한 명

/// 방에 있는 사람 한 명의 채팅용 부니 — 캐릭터 + 이름표 + (새 메시지가 있으면) 말풍선.
/// 상대의 옷차림은 서버에서 받은 아이템 id로 그린다(상점 미리보기와 같은 방식).
struct ChatAvatarView: View {
    @ObservedObject private var store = ChatStore.shared
    let member: ChatMember
    let isMe: Bool
    let now: Date

    /// 말풍선이 떠 있는 시간
    private static let bubbleSeconds: TimeInterval = 9
    /// 말풍선이 차지하는 자리 높이 (50자 = 6줄까지 들어간다)
    private static let bubbleSlot: CGFloat = 104

    private var latest: ChatMessage? {
        guard let m = store.messages.last(where: { $0.uid == member.id }),
              let at = store.receivedAt[m.id], now.timeIntervalSince(at) < Self.bubbleSeconds else { return nil }
        return m
    }

    private var tryOn: TryOnItems {
        var items: [ItemSlot: String] = [:]
        for (slot, id) in member.equip { if let s = ItemSlot(rawValue: slot) { items[s] = id } }
        return TryOnItems(items: items)
    }

    var body: some View {
        VStack(spacing: 3) {
            // 말풍선 자리는 늘 같은 높이로 비워 둔다 — 말풍선은 이 칸 위에 겹쳐 그려서(overlay) 있든 없든
            // 레이아웃 크기가 변하지 않는다. (빈 뷰에 frame 을 주면 칸이 접혀서 부니가 밀려 내려갔다)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.bubbleSlot)
                .overlay(alignment: .bottom) { bubble }
            character
                .environment(\.tryOn, tryOn)
                .environmentObject(store.avatars[member.id] ?? CompanionController())
                .frame(width: 60, height: 70)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isMe { store.inputActive.toggle() }
                    else { store.avatars[member.id]?.touch(.body) }          // 남의 부니는 간지럽히기만
                }
            // 이름표 자리는 늘 같은 높이 — 말하기 입력창이 열려도 닉네임 자리에서 바뀔 뿐 부니는 움직이지 않는다
            nameTag.frame(height: 22)
        }
        .frame(width: 108)
    }

    /// 이름표(레벨 + 닉네임) — 내 것을 누르면 그 자리에서 닉네임을 고칠 수 있고,
    /// 말하기를 누르면 같은 자리에 입력창이 나왔다가 입력이 없으면 다시 닉네임으로 돌아온다.
    @ViewBuilder
    private var nameTag: some View {
        if isMe && store.nameEditing {
            NameEditor()
        } else if isMe && store.inputActive {
            ChatInput()
        } else {
            HStack(spacing: 4) {
                Text("Lv.\(member.level)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.40))
                Text(member.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .frame(maxWidth: 108)
            .background(Capsule().fill(isMe ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.55)))
            .contentShape(Capsule())
            .onTapGesture { if isMe { store.nameEditing = true } }
            .help(isMe ? L.t("눌러서 닉네임 바꾸기", "Click to change your nickname") : "")
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if let m = latest {
            VStack(spacing: 0) {
                Text(m.text)
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)       // 글자 수만큼만 — 줄임표 없이 전부 보인다
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.96)))
                Triangle().fill(Color.white.opacity(0.96)).frame(width: 10, height: 6)
            }
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        }
    }

    private var character: some View { chatCharacterView(member.character) }
}

/// 캐릭터 종류(rawValue)에 맞는 토끼 그림
@ViewBuilder
func chatCharacterView(_ raw: String) -> some View {
    switch CharacterType(rawValue: raw) ?? .rabbit {
    case .rabbit:        RabbitCharacterView()
    case .brownRabbit:   BrownRabbitCharacterView()
    case .pinkRabbit:    PinkRabbitCharacterView()
    case .orangeRabbit:  OrangeRabbitCharacterView()
    case .yellowRabbit:  YellowRabbitCharacterView()
    case .greenRabbit:   GreenRabbitCharacterView()
    }
}

/// 방에 들어가기 전에 "다른 사람에게 내가 이렇게 보여요"를 미리 보여 준다.
/// 닉네임·캐릭터·옷차림·레벨이 바뀌면 바로 반영된다.
struct ChatProfilePreview: View {
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var shop = ShopStore.shared
    @StateObject private var controller = CompanionController()

    private var tryOn: TryOnItems {
        var items: [ItemSlot: String] = [:]
        for (slot, id) in shop.equipped[store.character] ?? [:] { items[slot] = id }
        return TryOnItems(items: items)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                chatCharacterView(store.character.rawValue)
                    .environment(\.tryOn, tryOn)
                    .environmentObject(controller)
                    .frame(width: 60, height: 70)
                HStack(spacing: 4) {
                    Text("Lv.\(shop.level)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.40))
                    Text(store.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .frame(maxWidth: 108)
                .background(Capsule().fill(Color.accentColor.opacity(0.85)))
            }
            .frame(width: 112)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("미리보기", "Preview")).font(.system(size: 11, weight: .semibold))
                Text(L.t("방에 들어가면 다른 사람에게 이렇게 보여요. 닉네임·캐릭터를 바꾸면 바로 바뀌어요. 옷차림은 상점에서 바꿔요.",
                         "This is how others will see you in the room. It updates as you change your nickname or character; outfits are changed in the shop."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.14)))
    }
}

/// 이름표 자리에 나오는 말하기 입력칸 — Enter로 보내고, Esc나 한동안 입력이 없으면 닫힌다
struct ChatInput: View {
    @ObservedObject private var store = ChatStore.shared
    @FocusState private var focused: Bool
    @State private var glow = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 9))
                .foregroundColor(.accentColor)
            TextField("", text: $store.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .focused($focused)
                .onChange(of: store.draft) {
                    store.inputTouched = Date()
                    if $0.count > ChatStore.maxTextLength { store.draft = String($0.prefix(ChatStore.maxTextLength)) }
                }
                .onSubmit { send() }
                .onExitCommand { store.inputActive = false }
            if store.draft.count >= 40 {
                Text("\(store.draft.count)/\(ChatStore.maxTextLength)")
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(store.draft.count >= ChatStore.maxTextLength ? 0.95 : 0.55))
            } else if store.draft.isEmpty {
                Text("↵").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: 106, height: 22)
        .background(Capsule().fill(Color(white: 0.10).opacity(0.94)))
        .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
        .shadow(color: Color.accentColor.opacity(glow ? 0.85 : 0.35), radius: glow ? 6 : 3)
        .onAppear {
            store.inputTouched = Date(); focused = true
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true }
        }
    }

    private func send() {
        store.send(store.draft)
        store.draft = ""
        store.inputTouched = Date()
        focused = true
    }
}

/// 이름표 자리에서 닉네임을 고치는 입력칸 — Enter로 확정, Esc로 취소
private struct NameEditor: View {
    @ObservedObject private var store = ChatStore.shared
    @State private var text = ""
    @State private var original = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(L.t("닉네임", "Nickname"), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundColor(.black)
            .focused($focused)
            .onChange(of: text) { if $0.count > ChatStore.maxNicknameLength { text = String($0.prefix(ChatStore.maxNicknameLength)) } }
            .onSubmit { commit() }
            .onExitCommand { store.nameEditing = false }
            .frame(width: 88)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.96)))
            .onAppear { original = store.displayName; text = original; focused = true }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != original { store.nickname = t }          // 비우면 캐릭터 이름으로 돌아간다
        store.nameEditing = false
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 방 화면 (화면 아래쪽에 뜨는 패널의 내용)

struct ChatRoomView: View {
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var lang = LanguageStore.shared
    @State private var now = Date()
    @State private var hover = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            // 한 줄에 5명까지 — 그보다 많으면 아래로 줄을 늘려서 패널이 화면보다 넓어지지 않게 한다
            VStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(row) { m in
                            ChatAvatarView(member: m, isMe: m.id == CloudSession.shared.user?.uid, now: now)
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.messages.count)

            controls
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .frame(width: panelWidth)
        .onReceive(tick) {
            now = $0
            // 한동안 입력이 없으면 입력창을 닫고 닉네임을 다시 보인다
            if store.inputActive && $0.timeIntervalSince(store.inputTouched) > Self.inputIdleSeconds { store.inputActive = false }
        }
        .onHover { hover = $0 }
        .onChange(of: store.inputActive) { if $0 { store.inputTouched = Date() } }
    }

    private static let inputIdleSeconds: TimeInterval = 6

    /// 패널 가로 폭 — 사람 수에만 따라 바뀐다
    private var panelWidth: CGFloat { max(280, CGFloat(min(store.members.count, Self.perRow)) * 112 + 20) }

    private static let perRow = 5
    private var rows: [[ChatMember]] {
        stride(from: 0, to: store.members.count, by: Self.perRow).map {
            Array(store.members[$0..<min($0 + Self.perRow, store.members.count)])
        }
    }

    /// 방 코드·말하기·나가기 — 마우스를 올렸을 때만 또렷하게 보인다
    private var controls: some View {
        HStack(spacing: 6) {
            Button { store.inputActive.toggle() } label: { Text("💬 " + L.t("말하기", "Chat")) }
                .help(ShortcutStore.shared.chat.map { L.t("단축키: ", "Shortcut: ") + $0.displayString } ?? "")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.roomCode ?? "", forType: .string)
            } label: { Text("🏠 \(store.roomCode ?? "") · \(store.members.count)/\(ChatStore.maxMembers)") }
            .help(L.t("누르면 방 코드를 복사해요", "Click to copy the room code"))
            if store.status == .reconnecting { Text(L.t("다시 연결 중…", "Reconnecting…")).font(.system(size: 10)) }
            Button { store.leave() } label: { Text(L.t("나가기", "Leave")) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white)
        .opacity(hover || store.inputActive ? 0.95 : 0.35)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(hover || store.inputActive ? 0.6 : 0.3)))
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - 로비 창 (방 만들기 · 코드로 입장 · 내 채팅 프로필)

struct ChatLobbyView: View {
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var cloud = CloudSession.shared
    @ObservedObject private var lang = LanguageStore.shared
    @State private var codeInput = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("부니 채팅", "Buni Chat")).font(.system(size: 17, weight: .bold))

            if !store.isAvailable {
                note(L.t("서버 설정(cloud-config.json)이 없어서 채팅을 쓸 수 없어요.", "Chat needs the server config (cloud-config.json)."))
            } else if !cloud.isSignedIn {
                note(L.t("채팅은 Google 로그인이 필요해요. 로그인하면 같은 방 사람들과 이름이 보여요.",
                         "Chat needs a Google sign-in so people in the room can tell you apart."))
                Button(L.t("Google로 로그인", "Sign in with Google")) { Task { await cloud.signIn() } }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(cloud.isBusy)
            } else {
                profile
                Divider()
                if let code = store.roomCode { inRoom(code) } else { lobby }
            }

            if let err = store.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(BT.danger)
            }
            Spacer(minLength: 0)
            note(L.t("방에는 최대 10명까지 들어올 수 있어요. 다른 사람에게는 내 닉네임·캐릭터·옷차림·대화와 "
                     + "작업 모션(대기/작업 중/완료)만 보이고, 어떤 작업을 하는지는 전해지지 않아요.",
                     "Up to 10 people per room. Others only see your nickname, character, outfit, messages and a work "
                     + "motion (idle / working / done) — never what you're working on."))
        }
        .padding(20)
        .frame(width: 400)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // 닉네임 · 캐릭터
    private var profile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("닉네임", "Nickname")).font(.system(size: 12)).frame(width: 56, alignment: .leading)
                TextField(L.t("비워 두면 캐릭터 이름 (\(store.character.shortName))", "Empty = character name (\(store.character.shortName))"), text: $store.nickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.nickname) { if $0.count > ChatStore.maxNicknameLength { store.nickname = String($0.prefix(ChatStore.maxNicknameLength)) } }
                    .onSubmit { store.pushProfile() }
            }
            HStack(spacing: 6) {
                Text(L.t("캐릭터", "Character")).font(.system(size: 12)).frame(width: 56, alignment: .leading)
                ForEach(CharacterType.allCases, id: \.self) { type in
                    Button { store.character = type; store.pushProfile() } label: {
                        Text(type.shortName)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(store.character == type ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.22)))
                            .foregroundColor(store.character == type ? .white : .primary)
                    }.buttonStyle(.plain)
                }
            }
            ChatProfilePreview()
        }
    }

    // 방 밖
    private var lobby: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(L.t("새 방 만들기", "Create a room")) {
                busy = true; Task { await store.createRoom(); busy = false }
            }
            .buttonStyle(PillButtonStyle(color: .accentColor))
            .disabled(busy)

            HStack {
                TextField(L.t("방 코드 6자리", "6-character room code"), text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { enter() }
                Button(L.t("입장", "Join")) { enter() }
                    .buttonStyle(PillButtonStyle(color: BT.accentBase))
                    .disabled(busy || codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func enter() {
        busy = true
        Task { await store.join(code: codeInput); busy = false; if store.isInRoom { codeInput = "" } }
    }

    // 방 안
    private func inRoom(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("방 코드", "Room code")).font(.system(size: 12))
                Text(code).font(.system(size: 22, weight: .bold, design: .monospaced))
                Button(L.t("복사", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }.buttonStyle(PillButtonStyle(color: .gray))
                Spacer()
                Text("\(store.members.count)/\(ChatStore.maxMembers)").font(.system(size: 12, design: .monospaced))
            }
            ForEach(store.members) { m in
                HStack(spacing: 8) {
                    Circle().fill(color(m.motion)).frame(width: 8, height: 8)
                    Text(m.name).font(.system(size: 12, weight: .semibold))
                    Text(label(m.motion)).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
            }
            Button(L.t("방 나가기", "Leave room")) { store.leave() }
                .buttonStyle(PillButtonStyle(color: BT.danger))
        }
    }

    private func color(_ m: ChatMotion) -> Color {
        switch m { case .idle: return .gray; case .working: return Color(red: 0.95, green: 0.75, blue: 0.2); case .done: return BT.success }
    }
    private func label(_ m: ChatMotion) -> String {
        switch m { case .idle: return L.t("대기", "Idle"); case .working: return L.t("작업 중", "Working"); case .done: return L.t("완료", "Done") }
    }
}

// MARK: - 창 관리

/// 방 안에서 화면에 뜨는 채팅 패널과, 방을 고르는 로비 창을 관리한다.
@MainActor
final class ChatWindowController {
    static let shared = ChatWindowController()

    private var panel: UnconstrainedPanel?
    private var hosting: ClickThroughHostingView<ChatRoomView>?
    private var lobby: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private static let originKey = "chat.panelOrigin"

    func start() {
        let store = ChatStore.shared
        // 방에 들어가면 패널을 띄우고, 나오면 내린다. 접속자·메시지·입력창이 바뀔 때마다 크기를 맞춘다.
        store.$roomCode
            .removeDuplicates()
            .sink { [weak self] code in
                if code != nil { self?.showPanel() } else { self?.hidePanel() }
            }
            .store(in: &cancellables)
        store.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitPanel() }
            .store(in: &cancellables)
        // 입력창이나 닉네임 칸이 열리면 패널이 키 입력을 받게 한다
        store.$inputActive.combineLatest(store.$nameEditing)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self, let p = self.panel else { return }
                if active { NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil) }
            }
            .store(in: &cancellables)
    }

    // MARK: 로비

    func showLobby() {
        if lobby == nil {
            // 내용 높이에 창이 맞춰지도록 NSHostingController 에 맡긴다 (미리보기·접속자 목록이 늘어도 잘리지 않게)
            let w = NSWindow(contentViewController: NSHostingController(rootView: ChatLobbyView()))
            w.styleMask = [.titled, .closable]
            w.title = L.t("부니 채팅", "Buni Chat")
            w.isReleasedWhenClosed = false
            w.center()
            lobby = w
        }
        NSApp.activate(ignoringOtherApps: true)
        lobby?.makeKeyAndOrderFront(nil)
    }

    // MARK: 방 패널

    private func showPanel() {
        if panel == nil {
            let p = UnconstrainedPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.isMovable = true
            p.isMovableByWindowBackground = true
            p.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 4)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let host = ClickThroughHostingView(rootView: ChatRoomView())
            p.contentView = host
            hosting = host
            panel = p
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                guard let self, let p = self.panel, p.isVisible else { return }
                UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: Self.originKey)
            }
        }
        fitPanel(initial: true)
        panel?.orderFrontRegardless()
    }

    private func hidePanel() { panel?.orderOut(nil) }

    /// 단축키로 입력창을 열 때 — 패널이 바로 키 입력을 받게 한다 (이미 열려 있어도 다시 포커스)
    func focusInput() {
        guard let p = panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// 내용 크기에 패널을 맞춘다. 아래쪽 중앙을 기준으로 늘어난다.
    private func fitPanel(initial: Bool = false) {
        guard let p = panel, let host = hosting, p.isVisible || initial else { return }
        let size = host.fittingSize
        guard size.width > 10, size.height > 10 else { return }
        var origin = p.frame.origin
        if initial {
            if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
                origin = NSPointFromString(saved)
            } else if let screen = NSScreen.main {
                origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 6)
            }
        } else {
            origin.x += (p.frame.width - size.width) / 2        // 가운데를 기준으로 좌우로 늘고 줄게
        }
        // 화면 밖으로 나가 있으면 되돌린다
        if let screen = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
