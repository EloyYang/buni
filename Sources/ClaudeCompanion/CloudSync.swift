import Foundation
import Combine

/// 로그인한 사용자의 상점 데이터를 Firestore의 `users/{uid}` 문서와 맞춘다.
///
/// 로그인하지 않았거나 서버 설정이 없으면 아무 일도 하지 않는다 — 앱은 로컬에서 그대로 동작한다.
/// 읽은 문서의 updateTime을 조건으로 걸어 쓰기 때문에, 두 PC가 동시에 쓰다가 서로의 변경을
/// 덮어쓰는 일이 없다(충돌하면 다시 읽어서 합친다).
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false

    private var cancellables = Set<AnyCancellable>()
    private var periodic: Timer?
    /// 동기화 결과를 반영하느라 생긴 변경이 또 다른 동기화를 부르지 않도록 잠시 무시한다
    private var suppressUntil: Date = .distantPast

    private init() {}

    // MARK: - 시작

    /// 앱 시작 때 한 번. 서버 설정이 없으면 아무것도 연결하지 않는다.
    func start() {
        guard CloudConfig.shared != nil else { return }

        Task {
            await CloudSession.shared.restore()
            if CloudSession.shared.isSignedIn { await syncNow() }
        }

        // 로그인되면 바로 한 번 맞춘다
        CloudSession.shared.$user
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] user in
                guard user != nil else { return }
                Task { await self?.syncNow() }
            }
            .store(in: &cancellables)

        // 코인·구매·착용·레벨이 바뀌면 잠깐 모았다가 올린다
        ShopStore.shared.objectWillChange
            .debounce(for: .seconds(4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, Date() > self.suppressUntil, CloudSession.shared.isSignedIn else { return }
                Task { await self.syncNow() }
            }
            .store(in: &cancellables)

        // 다른 PC에서 바뀐 것도 받아오도록 가끔 한 번씩 맞춘다
        periodic = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard CloudSession.shared.isSignedIn else { return }
            Task { @MainActor in await self?.syncNow() }
        }
        periodic?.tolerance = 60
    }

    // MARK: - 동기화

    func syncNow() async {
        guard !isSyncing, let config = CloudConfig.shared, let user = CloudSession.shared.user else { return }
        // Pro 가 아니면 동기화만 멈춘다 — 서버·로컬 데이터는 그대로 두고, 오류도 띄우지 않는다
        guard ProManager.shared.cloudSyncPolicy() == "allow" else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let token = try await CloudSession.shared.validIdToken()
            // 두 PC가 동시에 쓰면 조건부 쓰기가 실패한다 — 다시 읽어서 합치기를 몇 번 시도한다
            for _ in 0..<3 {
                let (remote, updateTime) = try await fetch(config: config, uid: user.uid, token: token)
                let local    = ShopStore.shared.syncState()
                let baseline = ShopStore.shared.baselineCoins(for: user.uid)
                let result   = SyncMerge.merge(local: local, remote: remote, baselineCoins: baseline)

                if remote != result.doc {
                    let ok = try await write(result.doc, config: config, uid: user.uid, token: token, precondition: updateTime)
                    if !ok { continue }                       // 그 사이 다른 PC가 썼다 → 다시
                }
                suppressUntil = Date().addingTimeInterval(8)
                ShopStore.shared.applyCloud(result.doc, tokensThisMonth: result.tokensThisMonth, uid: user.uid)
                lastSync = Date()
                ProManager.shared.markCloudSynced()
                return
            }
            CloudSession.shared.report(L.t("다른 PC와 동시에 바뀌어서 잠시 후 다시 맞출게요",
                                           "Changed on another PC at the same time — will retry shortly"))
        } catch {
            CloudSession.shared.report(L.t("동기화하지 못했어요: ", "Could not sync: ") + error.localizedDescription)
        }
    }

    /// 서버에 저장된 내 문서를 지운다
    func deleteRemote() async throws {
        guard let config = CloudConfig.shared, let user = CloudSession.shared.user else { return }
        let token = try await CloudSession.shared.validIdToken()
        _ = try await request("DELETE", url: documentURL(config, user.uid), token: token, body: nil)
        ShopStore.shared.forgetCloudBaseline(for: user.uid)
        lastSync = nil
    }

    // MARK: - Firestore REST

    private func documentURL(_ config: CloudConfig, _ uid: String) -> URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(config.projectId)/databases/(default)/documents/users/\(uid)")!
    }

    private func fetch(config: CloudConfig, uid: String, token: String) async throws -> (CloudDoc?, String?) {
        let (status, data) = try await request("GET", url: documentURL(config, uid), token: token, body: nil)
        if status == 404 { return (nil, nil) }
        guard status == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GoogleSignInError.server("HTTP \(status)")
        }
        let fields = json["fields"] as? [String: Any] ?? [:]
        return (FS.decode(fields), json["updateTime"] as? String)
    }

    /// 조건부 쓰기 — 읽은 뒤 문서가 바뀌었으면 false(다시 합쳐야 한다)
    private func write(_ doc: CloudDoc, config: CloudConfig, uid: String, token: String, precondition: String?) async throws -> Bool {
        var comps = URLComponents(url: documentURL(config, uid), resolvingAgainstBaseURL: false)!
        if let precondition {
            comps.queryItems = [.init(name: "currentDocument.updateTime", value: precondition)]
        } else {
            comps.queryItems = [.init(name: "currentDocument.exists", value: "false")]
        }
        let body = try JSONSerialization.data(withJSONObject: ["fields": FS.encode(doc)])
        let (status, data) = try await request("PATCH", url: comps.url!, token: token, body: body)
        if status == 200 { return true }
        let text = String(data: data, encoding: .utf8) ?? ""
        if status == 409 || (status == 400 && text.contains("FAILED_PRECONDITION")) { return false }
        throw GoogleSignInError.server("HTTP \(status)")
    }

    private func request(_ method: String, url: URL, token: String, body: Data?) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
