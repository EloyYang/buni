import Foundation

// MARK: - 모델

/// 채팅용 부니의 모션 — 대화 상대에게는 이 값만 보인다 (어떤 작업인지는 알리지 않는다)
enum ChatMotion: String {
    case idle, working, done
}

struct ChatMember: Equatable, Identifiable {
    let id: String                 // Firebase uid
    var name: String
    var character: String          // CharacterType.rawValue
    var motion: ChatMotion
    var equip: [String: String]    // 자리 → 아이템 id (보는 쪽 화면에 같은 옷차림으로 그린다)
    var seen: Double               // 마지막 생존 신호(서버 시각, ms)
    var level: Int = 1             // 상점 레벨 — 이름표 옆에 보인다
}

struct ChatMessage: Equatable, Identifiable {
    let id: String                 // push key — 사전순이 곧 시간순
    let uid: String
    let name: String
    let text: String
    let ts: Double                 // ms
}

enum ChatError: LocalizedError {
    case notConfigured
    case notSignedIn
    case roomNotFound
    case roomFull
    case http(Int)
    case invalidCode

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L.t("서버 설정이 없어서 채팅을 쓸 수 없어요", "Chat isn't set up (cloud-config.json)")
        case .notSignedIn:   return L.t("채팅은 Google 로그인이 필요해요", "Chat needs a Google sign-in")
        case .roomNotFound:  return L.t("그런 방이 없어요. 코드를 다시 확인해 주세요", "No such room. Check the code")
        case .roomFull:      return L.t("방이 가득 찼어요 (최대 10명)", "The room is full (max 10)")
        case .http(let c):   return L.t("서버 오류 (\(c))", "Server error (\(c))")
        case .invalidCode:   return L.t("방 코드는 영문·숫자 6자리예요", "Room codes are 6 letters/digits")
        }
    }
}

// MARK: - 방 코드

enum RoomCode {
    /// 헷갈리는 글자(0·O·1·I)를 뺀 알파벳 — 규칙의 /^[A-Z2-9]{6}$/ 와 같아야 한다
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func random() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// 사용자가 입력한 코드를 정리한다 (공백·소문자 허용). 형식이 틀리면 nil.
    static func normalize(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.allSatisfy({ ($0 >= "A" && $0 <= "Z") || ($0 >= "2" && $0 <= "9") }) else { return nil }
        return code
    }
}

// MARK: - 인원 제한

/// 방은 최대 10명이다. 데이터베이스 규칙으로는 인원을 셀 수 없어서, 들어온 사람이 직접 확인한다:
/// 지금 활동 중인 사람들을 들어온 순서(서버 시각, 같으면 uid)로 세워 내가 5번째 안에 드는지 본다.
/// 모두가 같은 기준으로 계산하므로 동시에 들어와도 가장 늦은 사람이 물러난다.
enum RoomCapacity {
    /// 활동 중으로 보는 기준 — 내가 방금 쓴 서버 시각(seen)에서 이만큼 안에 신호가 있던 사람
    static let activeWindowMs: Double = 90_000

    static func seats(raw members: [String: Any], me: String, max: Int) -> Bool {
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        guard let mine = members[me] as? [String: Any] else { return false }
        let now = num(mine, "seen")
        let active = members.compactMap { uid, v -> (String, Double)? in
            guard let d = v as? [String: Any], uid == me || now - num(d, "seen") < activeWindowMs else { return nil }
            return (uid, num(d, "joined"))
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return (active.firstIndex { $0.0 == me } ?? Int.max) < max
    }
}

// MARK: - JSON 트리 (스트림 이벤트를 쌓아 현재 상태를 만든다)

/// Realtime Database 스트림은 "경로 + 값" 이벤트(put=교체, patch=병합)를 보낸다.
/// 그것을 순서대로 적용해 현재 데이터 전체를 유지한다. 네트워크와 무관한 순수 로직이라 단독 시험이 가능하다.
struct RTDBTree {
    private(set) var root: Any? = nil

    mutating func put(path: String, value: Any?) {
        let parts = Self.split(path)
        root = Self.set(root, parts[...], value)
    }

    mutating func patch(path: String, value: [String: Any]) {
        for (k, v) in value {
            put(path: path.hasSuffix("/") ? path + k : path + "/" + k, value: v is NSNull ? nil : v)
        }
    }

    var children: [String: Any] { root as? [String: Any] ?? [:] }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func set(_ node: Any?, _ parts: ArraySlice<String>, _ value: Any?) -> Any? {
        guard let head = parts.first else { return value is NSNull ? nil : value }
        var dict = node as? [String: Any] ?? [:]
        let child = set(dict[head], parts.dropFirst(), value)
        if let child { dict[head] = child } else { dict.removeValue(forKey: head) }
        return dict.isEmpty ? nil : dict          // 빈 가지는 데이터베이스처럼 없는 것으로 본다
    }
}

enum ChatDecode {
    static func members(_ tree: [String: Any]) -> [ChatMember] {
        tree.compactMap { uid, raw -> ChatMember? in
            guard let d = raw as? [String: Any],
                  let name = d["name"] as? String, let char = d["char"] as? String,
                  let motionRaw = d["motion"] as? String else { return nil }
            let equip = (d["equip"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let seen = (d["seen"] as? NSNumber)?.doubleValue ?? 0
            let level = max(1, min(9999, (d["level"] as? NSNumber)?.intValue ?? 1))
            return ChatMember(id: uid, name: name, character: char,
                              motion: ChatMotion(rawValue: motionRaw) ?? .idle, equip: equip, seen: seen, level: level)
        }.sorted { $0.id < $1.id }
    }

    static func messages(_ tree: [String: Any]) -> [ChatMessage] {
        tree.compactMap { key, raw -> ChatMessage? in
            guard let d = raw as? [String: Any],
                  let uid = d["uid"] as? String, let name = d["name"] as? String,
                  let text = d["text"] as? String else { return nil }
            return ChatMessage(id: key, uid: uid, name: name, text: text,
                               ts: (d["ts"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - 실시간 스트림 (Server-Sent Events)

/// 한 경로를 계속 듣는다. 끊기면 onEnd를 부르고 끝난다 — 다시 잇는 일은 부르는 쪽이 한다.
final class RTDBStream {
    enum End { case closed, authRevoked, failed(String) }

    private var task: Task<Void, Never>?

    /// - Parameter onEvent: (이벤트 종류 "put"/"patch", 경로, 값)
    func start(url: URL, onEvent: @escaping (String, String, Any?) -> Void, onEnd: @escaping (End) -> Void) {
        task = Task {
            var req = URLRequest(url: url)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 120                         // 서버가 30초마다 keep-alive를 보낸다
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    onEnd(code == 401 || code == 403 ? .authRevoked : .failed("HTTP \(code)")); return
                }
                var event = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        switch event {
                        case "put", "patch":
                            guard let data = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let path = obj["path"] as? String else { continue }
                            let value = obj["data"]
                            onEvent(event, path, value is NSNull ? nil : value)
                        case "auth_revoked", "cancel":
                            onEnd(.authRevoked); return
                        default: break                        // keep-alive
                        }
                    }
                }
                onEnd(.closed)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                onEnd(.failed(error.localizedDescription))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}

// MARK: - REST

/// Realtime Database REST 호출 — 인증은 Firebase ID 토큰(`?auth=`)으로 한다.
struct RTDB {
    let base: String

    func url(_ path: String, token: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: base + "/" + path + ".json")!
        var items = [URLQueryItem(name: "auth", value: token)]
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        return comps.url!
    }

    /// (상태코드, 본문)
    func send(_ method: String, _ url: URL, body: Any? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static let serverTime: [String: String] = [".sv": "timestamp"]
}
