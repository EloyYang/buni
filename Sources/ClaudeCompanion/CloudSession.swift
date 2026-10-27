import Foundation
import AppKit
import Security

struct CloudUser: Equatable {
    let uid: String
    let name: String?
}

/// 선택 기능인 "계정 연동"의 로그인 상태.
///
/// 로그인하지 않아도 앱은 지금처럼 완전히 동작한다 — 이 객체는 사용자가 직접 로그인
/// 버튼을 눌렀을 때만 움직이고, 앱을 켤 때는 **저장된 로그인이 있을 때만 조용히 복원**한다.
/// (로그인 창을 띄우거나 알림을 주는 일은 없다)
///
/// 흐름: Google 로그인(브라우저) → Google ID 토큰 → Firebase Auth에 교환 → Firebase ID 토큰.
/// 갱신용 토큰(refresh token)은 키체인에 넣어 두고, 이후로는 비밀번호 없이 갱신한다.
@MainActor
final class CloudSession: ObservableObject {
    static let shared = CloudSession()

    @Published private(set) var user: CloudUser?
    @Published private(set) var isBusy = false
    /// 사용자에게 보여줄 마지막 결과·오류 문구
    @Published private(set) var message: String?

    var isConfigured: Bool { CloudConfig.shared != nil }
    var isSignedIn: Bool { user != nil }

    private var idToken: String?
    private var idTokenExpiry: Date = .distantPast

    private enum Keys {
        static let service  = "com.buni.companion.cloud"
        static let account  = "firebase-refresh-token"
        static let consent  = "cloud.consentGiven"
        static let lastUser = "cloud.lastUser"
    }

    private init() {}

    /// 동기화 같은 다른 곳에서 사용자에게 보여줄 문구를 남긴다
    func report(_ text: String) { message = text }

    // MARK: - 앱 시작 시: 저장된 로그인이 있을 때만 조용히 복원

    func restore() async {
        guard isConfigured, let refresh = Self.keychainRead() else { return }
        do {
            try await refreshTokens(using: refresh)
        } catch {
            // 만료·취소된 로그인 — 사용자를 방해하지 않고 로그아웃 상태로 둔다
            Self.keychainDelete()
            user = nil
        }
    }

    // MARK: - 로그인 / 로그아웃

    /// 사용자가 로그인 버튼을 눌렀을 때만 호출한다
    func signIn() async {
        guard let config = CloudConfig.shared else {
            message = L.t("서버 설정이 없어서 로그인할 수 없어요 (cloud-config.json)",
                          "Cloud isn't configured (cloud-config.json)")
            return
        }
        guard !isBusy else { return }
        guard confirmConsent() else { return }

        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            let googleIdToken = try await GoogleSignIn().signIn(config: config)
            try await firebaseSignIn(googleIdToken: googleIdToken, config: config)
            message = L.t("로그인했어요", "Signed in")
            await CloudSync.shared.syncNow()
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() {
        Self.keychainDelete()
        idToken = nil; idTokenExpiry = .distantPast
        user = nil
        message = L.t("로그아웃했어요. 이 PC의 설정은 그대로 남아 있어요.",
                      "Signed out. Your settings on this PC are kept.")
    }

    /// 서버에 저장된 내 데이터를 지운다 (이 PC의 데이터는 그대로)
    func deleteServerData() async {
        guard user != nil else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await CloudSync.shared.deleteRemote()
            message = L.t("서버에 저장된 데이터를 지웠어요", "Server data deleted")
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - 로그인 안내

    /// 로그인 전에 확인 창을 띄우지 않는다 — 서버에 저장되는 정보는 설정 창의 계정 영역에 글로 안내한다.
    private func confirmConsent() -> Bool {
        UserDefaults.standard.set(true, forKey: Keys.consent)
        return true
    }

    // MARK: - Firebase Auth (REST)

    private func firebaseSignIn(googleIdToken: String, config: CloudConfig) async throws {
        var comps = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp")!
        comps.queryItems = [.init(name: "key", value: config.apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let token = json["idToken"] as? String, let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP error"
            throw GoogleSignInError.server(L.t("서버 로그인에 실패했어요: \(detail)", "Server sign-in failed: \(detail)"))
        }
        let seconds = Double(json["expiresIn"] as? String ?? "") ?? 3600
        apply(idToken: token, expiresIn: seconds)
        user = CloudUser(uid: uid, name: json["displayName"] as? String)
        Self.keychainWrite(refresh)
        UserDefaults.standard.set(uid, forKey: Keys.lastUser)
    }

    private func refreshTokens(using refresh: String) async throws {
        guard let config = CloudConfig.shared else { throw GoogleSignInError.badCallback }
        var comps = URLComponents(string: "https://securetoken.googleapis.com/v1/token")!
        comps.queryItems = [.init(name: "key", value: config.apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(refresh)".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let token = json["id_token"] as? String, let uid = json["user_id"] as? String else {
            throw GoogleSignInError.badCallback
        }
        apply(idToken: token, expiresIn: Double(json["expires_in"] as? String ?? "") ?? 3600)
        if let newRefresh = json["refresh_token"] as? String { Self.keychainWrite(newRefresh) }
        // 이름은 갱신 응답에 없으니 직전 값을 유지한다
        user = CloudUser(uid: uid, name: user?.name)
    }

    private func apply(idToken token: String, expiresIn seconds: Double) {
        idToken = token
        idTokenExpiry = Date().addingTimeInterval(seconds - 60)   // 만료 1분 전에 미리 갱신
    }

    /// 요청에 쓸 유효한 ID 토큰 — 만료됐으면 먼저 갱신한다
    func validIdToken() async throws -> String {
        if let idToken, Date() < idTokenExpiry { return idToken }
        guard let refresh = Self.keychainRead() else { throw GoogleSignInError.cancelled }
        try await refreshTokens(using: refresh)
        guard let idToken else { throw GoogleSignInError.badCallback }
        return idToken
    }

    // MARK: - 키체인 (갱신 토큰 보관)

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Keys.service,
         kSecAttrAccount as String: Keys.account]
    }

    private static func keychainWrite(_ value: String) {
        keychainDelete()
        var query = baseQuery()
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    /// 이번 실행에서 키체인 안내를 이미 보여 줬는지
    private static var keychainExplained = false

    /// macOS가 허용 창을 띄우게 될 상황인지 — 창 없이 조용히 읽어 보고, 물어봐야 한다면 true
    private static func keychainWouldPrompt() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail      // 허용 창을 띄우지 말고 실패로 알려 달라
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecInteractionNotAllowed
    }

    /// 허용 창이 뜨기 직전에, 그 창이 왜 뜨는지 먼저 알려 준다 (앱이 새로 설치·업데이트되면 macOS가 다시 묻는다)
    private static func explainKeychainPromptIfNeeded() {
        guard !keychainExplained, keychainWouldPrompt() else { return }
        keychainExplained = true
        let show = {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L.t("Google 로그인을 이어가려고 키체인을 확인해요", "Buni needs to check your Keychain")
            a.informativeText = L.t(
                "곧 macOS가 “Buni가 키체인에서 com.buni.companion.cloud에 저장된 비밀 정보를 사용하려고 합니다”라는 창을 띄워요.\n\n"
                + "• 이 항목은 Buni가 Google 로그인 상태를 유지하려고 보관해 둔 로그인 토큰이에요. 비밀번호는 저장하지 않아요.\n"
                + "• Buni를 새로 설치하거나 업데이트하면 macOS가 한 번 다시 물어봐요.\n"
                + "• Mac 로그인 암호를 입력하고 ‘항상 허용’을 누르면 다음부터 묻지 않아요.\n"
                + "• 거절해도 Buni의 다른 기능은 그대로 쓸 수 있고, 채팅·계정 연동만 로그아웃 상태가 돼요.",
                "macOS is about to ask whether Buni may use “com.buni.companion.cloud” in your Keychain.\n\n"
                + "• That item is the sign-in token Buni stores to keep you signed in with Google. No password is stored.\n"
                + "• macOS asks again once after Buni is installed or updated.\n"
                + "• Enter your Mac password and choose “Always Allow” so it won't ask again.\n"
                + "• If you decline, everything else keeps working — only chat and account sync stay signed out.")
            a.addButton(withTitle: L.t("확인", "OK"))
            a.runModal()
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.sync(execute: show) }
    }

    private static func keychainRead() -> String? {
        explainKeychainPromptIfNeeded()
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
