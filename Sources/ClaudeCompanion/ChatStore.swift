import Foundation
import Combine

/// 채팅방 상태 — 방에 들어가고 나가기, 대화, 접속자(와 그들의 부니 모션)를 관리한다.
///
/// 서버는 Firebase Realtime Database(cloud/database.rules.json). 로그인한 사용자만 쓸 수 있고,
/// 방은 6자리 코드로 들어가며 최대 10명이다. 상대에게 보이는 것은 닉네임·캐릭터·옷차림·
/// 모션(대기/작업 중/완료)과 대화뿐이고, 어떤 세션에서 무슨 작업을 하는지는 전해지지 않는다.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    enum Status: Equatable { case off, connecting, online, reconnecting }

    @Published private(set) var roomCode: String?
    @Published private(set) var members: [ChatMember] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status: Status = .off
    @Published private(set) var lastError: String?
    /// 입력창이 열려 있는지 (내 채팅 부니를 누르면 열린다)
    @Published var inputActive = false
    /// 내 이름표를 눌러 닉네임을 고치는 중인지
    @Published var nameEditing = false
    /// 쓰다 만 메시지 — 입력창이 닫혀도 남아 있다
    @Published var draft = ""
    /// 입력창에 마지막으로 손댄 시각 — 한동안 입력이 없으면 입력창을 닫고 닉네임을 다시 보인다
    var inputTouched = Date()
    /// 사람(uid)마다 하나씩 — 채팅 부니를 그리는 컨트롤러. 모션 값이 상태로 바뀌어 들어간다.
    private(set) var avatars: [String: CompanionController] = [:]
    /// 메시지를 받은 시각 — 말풍선을 잠깐만 띄우는 기준 (서버 시각과 이 PC 시계가 달라도 안전하다)
    @Published private(set) var receivedAt: [String: Date] = [:]

    // 이 PC의 채팅 프로필
    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: UD.nickname) }
    }
    @Published var character: CharacterType {
        didSet { UserDefaults.standard.set(character.rawValue, forKey: UD.character) }
    }

    private enum UD {
        static let nickname = "chat.nickname"
        static let character = "chat.character"
        static let lastRoom = "chat.lastRoom"
    }

    static let maxMembers = 10
    private static let heartbeat: TimeInterval = 20
    private static let staleAfter: TimeInterval = 75
    private static let tokenRefresh: TimeInterval = 50 * 60

    private var rtdb: RTDB?
    private var uid: String?
    private var localMotion: ChatMotion = .idle

    private var memberTree = RTDBTree()
    private var messageTree = RTDBTree()
    private var memberStream: RTDBStream?
    private var messageStream: RTDBStream?
    private var messagesLoaded = false
    private var pendingKeys = Set<String>()            // 아직 서버에 남아 있는 내 메시지
    private var generation = 0                       // 방을 나갔다 들어오면 늦게 도착한 이벤트를 버리는 표
    private var seenChange: [String: (value: Double, at: Date)] = [:]
    private var timers: [Timer] = []
    private var lastSend = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let d = UserDefaults.standard
        nickname = d.string(forKey: UD.nickname) ?? ""
        character = CharacterType(rawValue: d.string(forKey: UD.character) ?? "") ?? CharacterStore.shared.selected
        // 닉네임을 고치면 잠깐 뒤 방 사람들에게도 바뀐다 (타자 칠 때마다 보내지 않도록 모아서)
        $nickname.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(700), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.isInRoom == true { self?.pushProfile() } }
            .store(in: &cancellables)
        // 내 이름·캐릭터·옷차림·레벨이 바뀌면 내 화면에는 곧바로, 상대에게는 바로 보낸다 (20초 생존 신호를 기다리지 않는다).
        // @Published 는 값이 바뀌기 직전에 알리므로 한 박자 뒤(main)에 읽는다.
        Publishers.Merge4(
            ShopStore.shared.$equipped.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ShopStore.shared.$level.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $character.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $nickname.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.isInRoom else { return }
                self.refreshMembers()
                self.pushProfile()
            }
            .store(in: &cancellables)
    }

    var isInRoom: Bool { roomCode != nil }
    var isAvailable: Bool { CloudConfig.shared != nil }
    var lastRoom: String? { UserDefaults.standard.string(forKey: UD.lastRoom) }

    static let maxNicknameLength = 20

    /// 대화에 쓰는 이름 — 직접 정한 닉네임, 비워 두면 고른 캐릭터의 이름(부니·우니 …)
    var displayName: String {
        let own = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return String(own.prefix(Self.maxNicknameLength)) }
        return character.shortName
    }

    // MARK: - 시작 (앱이 켜질 때)

    /// 로그인이 복원되면 마지막 방에 조용히 다시 들어간다. 로그아웃하면 방에서 나온다.
    func start() {
        guard isAvailable else { return }
        CloudSession.shared.$user
            .removeDuplicates()
            .sink { [weak self] user in
                guard let self else { return }
                if user == nil {
                    if self.isInRoom { self.leave(forget: false) }
                } else if !self.isInRoom, let code = self.lastRoom {
                    Task { await self.join(code: code, silent: true) }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 방 만들기 / 들어가기 / 나가기

    func createRoom() async {
        guard let (rtdb, uid, token) = await session() else { return }
        lastError = nil
        for _ in 0..<5 {
            let code = RoomCode.random()
            let url = rtdb.url("rooms/\(code)/meta", token: token)
            do {
                let (status, _) = try await rtdb.send("PUT", url, body: ["owner": uid, "createdAt": RTDB.serverTime])
                if status == 200 { await join(code: code); return }
                // 401 = 이미 있는 코드 — 다른 코드로 다시
            } catch {
                lastError = error.localizedDescription; return
            }
        }
        lastError = ChatError.http(0).localizedDescription
    }

    func join(code raw: String, silent: Bool = false) async {
        guard let code = RoomCode.normalize(raw) else {
            if !silent { lastError = ChatError.invalidCode.localizedDescription }
            return
        }
        if isInRoom { leave(forget: false) }
        guard let (rtdb, uid, token) = await session() else { return }
        lastError = nil
        status = .connecting
        do {
            // 방이 있는지 먼저 확인 (오타로 새 방이 생기지 않게 — 규칙도 막는다)
            let (s, data) = try await rtdb.send("GET", rtdb.url("rooms/\(code)/meta", token: token))
            guard s == 200 else { throw ChatError.http(s) }
            if String(data: data, encoding: .utf8) == "null" { throw ChatError.roomNotFound }

            // 내 자리를 먼저 쓰고(들어온 시각 joined 포함), 그 뒤에 10명을 넘지 않는지 확인한다
            var entry = profilePayload()
            entry["joined"] = RTDB.serverTime
            let memberURL = rtdb.url("rooms/\(code)/members/\(uid)", token: token)
            let (status, _) = try await rtdb.send("PUT", memberURL, body: entry)
            if status == 200 {
                let (s2, data2) = try await rtdb.send("GET", rtdb.url("rooms/\(code)/members", token: token))
                if s2 == 200, let raw = (try? JSONSerialization.jsonObject(with: data2)) as? [String: Any],
                   !RoomCapacity.seats(raw: raw, me: uid, max: Self.maxMembers) {
                    _ = try? await rtdb.send("DELETE", memberURL)           // 자리가 없다 — 내 자리를 거둔다
                    await pruneStale(rtdb: rtdb, code: code, token: token, except: uid)
                    throw ChatError.roomFull
                }
            }
            guard status == 200 else { throw ChatError.http(status) }
        } catch {
            status = .off
            if !silent || !(error is ChatError) { lastError = error.localizedDescription }
            if let e = error as? ChatError, case .roomNotFound = e { UserDefaults.standard.removeObject(forKey: UD.lastRoom) }
            return
        }

        self.rtdb = rtdb; self.uid = uid
        generation += 1
        roomCode = code
        UserDefaults.standard.set(code, forKey: UD.lastRoom)
        memberTree = RTDBTree(); messageTree = RTDBTree(); messagesLoaded = false
        seenChange = [:]; receivedAt = [:]; messages = []; members = []
        startStreams()
        startTimers()
    }

    /// 방에서 나온다. forget이 참이면 다음 실행 때 자동으로 다시 들어가지 않는다.
    func leave(forget: Bool = true) {
        let rtdb = self.rtdb, uid = self.uid, code = roomCode
        generation += 1
        stopTimers()
        memberStream?.stop(); messageStream?.stop()
        memberStream = nil; messageStream = nil
        roomCode = nil; members = []; messages = []; status = .off; inputActive = false; nameEditing = false
        avatars = [:]; receivedAt = [:]
        if forget { UserDefaults.standard.removeObject(forKey: UD.lastRoom) }
        // 내 자리를 비운다 (실패해도 90초 뒤 다른 사람이 정리할 수 있다)
        if let rtdb, let uid, let code {
            let keys = pendingKeys
            Task {
                guard let token = try? await CloudSession.shared.validIdToken() else { return }
                for k in keys { _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/messages/\(k)", token: token)) }
                _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/members/\(uid)", token: token))
            }
        }
        pendingKeys = []
        self.rtdb = nil; self.uid = nil
    }

    /// 앱을 끝낼 때 — 자리를 비우는 요청이 나갈 때까지 잠깐 기다린다
    func leaveBlocking() {
        guard let rtdb, let uid, let code = roomCode else { return }
        let sem = DispatchSemaphore(value: 0)
        let keys = pendingKeys
        Task.detached {
            if let token = try? await CloudSession.shared.validIdToken() {
                for k in keys { _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/messages/\(k)", token: token)) }
                _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/members/\(uid)", token: token))
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    private func session() async -> (RTDB, String, String)? {
        guard let cfg = CloudConfig.shared else { lastError = ChatError.notConfigured.localizedDescription; return nil }
        guard let user = CloudSession.shared.user else { lastError = ChatError.notSignedIn.localizedDescription; return nil }
        do {
            let token = try await CloudSession.shared.validIdToken()
            return (RTDB(base: cfg.rtdbBase), user.uid, token)
        } catch {
            lastError = error.localizedDescription; return nil
        }
    }

    private func pruneStale(rtdb: RTDB, code: String, token: String, except uid: String) async {
        guard let (s, data) = try? await rtdb.send("GET", rtdb.url("rooms/\(code)/members", token: token, query: ["shallow": "true"])),
              s == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for other in obj.keys where other != uid {
            _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/members/\(other)", token: token))   // 아직 활동 중이면 규칙이 거절한다
        }
    }

    // MARK: - 대화

    /// 한 번에 보낼 수 있는 글자 수 — 말풍선이 잘려 보이지 않는 길이
    static let maxTextLength = 50
    /// 메시지가 서버에 남아 있는 시간. 그 뒤엔 보낸 사람이 지운다 — 대화 기록은 남기지 않는다.
    private static let messageLifetime: TimeInterval = 15

    func send(_ raw: String) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTextLength))
        guard !text.isEmpty, let rtdb, let uid, let code = roomCode else { return }
        guard Date().timeIntervalSince(lastSend) > 0.4 else { return }       // 연타 방지
        lastSend = Date()
        let name = displayName
        Task {
            guard let token = try? await CloudSession.shared.validIdToken() else { return }
            let body: [String: Any] = ["uid": uid, "name": name, "text": text, "ts": RTDB.serverTime]
            guard let (s, data) = try? await rtdb.send("POST", rtdb.url("rooms/\(code)/messages", token: token), body: body) else { return }
            guard s == 200 else { lastError = ChatError.http(s).localizedDescription; return }
            if let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String {
                pendingKeys.insert(key)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageLifetime) { [weak self] in
                    self?.deleteMessage(key, code: code)
                }
            }
        }
    }

    /// 보낸 메시지를 서버에서 지운다 (이미 지워졌거나 방을 나갔으면 아무 일도 없다)
    private func deleteMessage(_ key: String, code: String) {
        pendingKeys.remove(key)
        guard let rtdb else { return }
        Task {
            guard let token = try? await CloudSession.shared.validIdToken() else { return }
            _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/messages/\(key)", token: token))
        }
    }

    // MARK: - 내 모션 · 프로필

    /// 내 세션들의 상태를 요약한 모션 — 하나라도 작업 중이면 working, 아니면 완료가 있으면 done
    func setLocalMotion(_ motion: ChatMotion) {
        guard motion != localMotion else { return }
        localMotion = motion
        if isInRoom { pushProfile() }
    }

    /// 닉네임·캐릭터·옷차림·모션을 서버에 올린다 (생존 신호도 겸한다)
    func pushProfile() {
        guard let rtdb, let uid, let code = roomCode else { return }
        let payload = profilePayload()
        Task {
            guard let token = try? await CloudSession.shared.validIdToken() else { return }
            do {
                let (s, _) = try await rtdb.send("PATCH", rtdb.url("rooms/\(code)/members/\(uid)", token: token), body: payload)
                if s == 200 { if status == .reconnecting { status = .online } }
                else if s == 401 { await rejoin() }       // 자리를 잃었다(오래 끊겨 정리됨) — 다시 앉는다
            } catch {
                if status == .online { status = .reconnecting }
            }
        }
    }

    private func rejoin() async {
        guard let code = roomCode else { return }
        await join(code: code, silent: true)
    }

    private func profilePayload() -> [String: Any] {
        var equip: [String: String] = [:]
        for (slot, id) in ShopStore.shared.equipped[character] ?? [:] { equip[slot.rawValue] = id }
        var p: [String: Any] = ["name": displayName, "char": character.rawValue,
                                "motion": localMotion.rawValue, "seen": RTDB.serverTime,
                                "level": ShopStore.shared.level]
        p["equip"] = equip.isEmpty ? NSNull() : equip as Any       // 다 벗으면 서버에서도 지운다
        return p
    }

    // MARK: - 스트림

    private func startStreams() {
        guard let rtdb, let code = roomCode else { return }
        let gen = generation
        Task { [weak self] in
            guard let self, let token = try? await CloudSession.shared.validIdToken(), gen == self.generation else { return }
            self.memberStream?.stop(); self.messageStream?.stop()

            let ms = RTDBStream()
            ms.start(url: rtdb.url("rooms/\(code)/members", token: token),
                     onEvent: { [weak self] kind, path, value in
                         Task { @MainActor in self?.apply(members: kind, path, value, gen) }
                     },
                     onEnd: { [weak self] end in Task { @MainActor in self?.streamEnded(end, gen) } })
            self.memberStream = ms

            let mg = RTDBStream()
            mg.start(url: rtdb.url("rooms/\(code)/messages", token: token,
                                   query: ["orderBy": "\"$key\"", "limitToLast": "10"]),
                     onEvent: { [weak self] kind, path, value in
                         Task { @MainActor in self?.apply(messages: kind, path, value, gen) }
                     },
                     onEnd: { [weak self] end in Task { @MainActor in self?.streamEnded(end, gen) } })
            self.messageStream = mg
            if self.status != .online { self.status = .online }
        }
    }

    private func streamEnded(_ end: RTDBStream.End, _ gen: Int) {
        guard gen == generation, isInRoom else { return }
        status = .reconnecting
        // 토큰이 끝났거나 연결이 끊겼다 — 잠깐 뒤 새 토큰으로 다시 잇는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.generation, self.isInRoom else { return }
            self.startStreams()
        }
    }

    private func apply(members kind: String, _ path: String, _ value: Any?, _ gen: Int) {
        guard gen == generation else { return }
        if kind == "patch", let dict = value as? [String: Any] { memberTree.patch(path: path, value: dict) }
        else { memberTree.put(path: path, value: value) }
        refreshMembers()
    }

    private func apply(messages kind: String, _ path: String, _ value: Any?, _ gen: Int) {
        guard gen == generation else { return }
        let before = Set(ChatDecode.messages(messageTree.children).map(\.id))
        if kind == "patch", let dict = value as? [String: Any] { messageTree.patch(path: path, value: dict) }
        else { messageTree.put(path: path, value: value) }
        let all = ChatDecode.messages(messageTree.children).suffix(50)
        // 처음 받은 묶음은 지난 대화 — 말풍선으로 띄우지 않는다. 그 뒤에 온 것만 새 메시지다.
        let initial = !messagesLoaded
        messagesLoaded = true
        var stamps = receivedAt
        for m in all where !before.contains(m.id) { stamps[m.id] = initial ? .distantPast : Date() }
        receivedAt = stamps.filter { key, _ in all.contains { $0.id == key } }
        messages = Array(all)
        if initial { purgeLeftovers(Array(all)) }
    }

    /// 들어올 때 남아 있던 지난 메시지(앱이 꺼지면서 못 지운 것)는 말풍선으로 띄우지 않고 서버에서도 지운다
    private func purgeLeftovers(_ old: [ChatMessage]) {
        guard let rtdb, let code = roomCode, let uid else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let doomed = old.filter { $0.uid == uid || nowMs - $0.ts > 60_000 }.map(\.id)
        guard !doomed.isEmpty else { return }
        Task {
            guard let token = try? await CloudSession.shared.validIdToken() else { return }
            for k in doomed { _ = try? await rtdb.send("DELETE", rtdb.url("rooms/\(code)/messages/\(k)", token: token)) }
        }
    }

    // MARK: - 접속자

    private func refreshMembers() {
        let now = Date()
        var visible: [ChatMember] = []
        for m in ChatDecode.members(memberTree.children) {
            // 생존 신호(seen)가 한동안 안 바뀐 사람은 떠난 것으로 본다 (이 PC 시계로 변화만 본다)
            if seenChange[m.id]?.value != m.seen { seenChange[m.id] = (m.seen, now) }
            let fresh = now.timeIntervalSince(seenChange[m.id]!.at) < Self.staleAfter
            if m.id == uid { visible.append(localized(m)) } else if fresh { visible.append(m) }
        }
        // 나를 맨 앞에, 나머지는 들어온 순서(= uid 순서로 고정)
        visible.sort { a, b in a.id == uid ? b.id != uid : (b.id == uid ? false : a.id < b.id) }
        if visible != members { members = visible }
        syncAvatars()
    }

    /// 내 칸은 서버를 거쳐 돌아오기를 기다리지 않고 이 PC의 값으로 바로 그린다
    private func localized(_ m: ChatMember) -> ChatMember {
        var me = m
        me.name = displayName
        me.character = character.rawValue
        me.level = ShopStore.shared.level
        var equip: [String: String] = [:]
        for (slot, id) in ShopStore.shared.equipped[character] ?? [:] { equip[slot.rawValue] = id }
        me.equip = equip
        return me
    }

    private func syncAvatars() {
        var next: [String: CompanionController] = [:]
        for m in members {
            let c = avatars[m.id] ?? CompanionController()
            if let type = CharacterType(rawValue: m.character), c.character != type { c.character = type }
            let state: CompanionState = { switch m.motion { case .working: return .thinking; case .done: return .completed; case .idle: return .ready } }()
            if c.state != state { c.state = state }
            next[m.id] = c
        }
        avatars = next
    }

    /// 화면 시험용 — 서버 없이 방 화면을 그려 볼 때 쓴다 (앱 동작에는 쓰이지 않는다)
    func loadPreview(code: String, members: [ChatMember], messages: [ChatMessage]) {
        roomCode = code
        self.members = members
        self.messages = messages
        receivedAt = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, Date()) })
        syncAvatars()
    }

    // MARK: - 타이머

    private func startTimers() {
        stopTimers()
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pushProfile() }
            },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshMembers() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.tokenRefresh, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startStreams() }    // 토큰이 만료되기 전에 새 토큰으로 다시 잇는다
            },
        ]
        timers.forEach { $0.tolerance = 1 }
    }

    private func stopTimers() { timers.forEach { $0.invalidate() }; timers = [] }
}
