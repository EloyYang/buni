import Foundation
import Network
import CryptoKit
import AppKit

enum GoogleSignInError: LocalizedError {
    case cancelled
    case timeout
    case badCallback
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:      return L.t("로그인을 취소했어요", "Sign-in was cancelled")
        case .timeout:        return L.t("로그인 시간이 지났어요. 다시 시도해 주세요", "Sign-in timed out. Please try again")
        case .badCallback:    return L.t("로그인 응답을 확인하지 못했어요", "Could not verify the sign-in response")
        case .server(let m):  return m
        }
    }
}

/// 데스크톱 앱용 Google 로그인 — OAuth 2.0 + PKCE + 루프백 리다이렉트.
///
/// 앱 안에 웹뷰를 띄우지 않고 **기본 브라우저**에서 로그인한다(Google이 권장하는 방식이라
/// 비밀번호가 앱을 거치지 않는다). 브라우저가 로그인을 마치면 127.0.0.1의 임시 포트로
/// 돌아오고, 앱은 그때 받은 일회용 코드를 ID 토큰으로 바꾼다.
final class GoogleSignIn {

    /// 로그인을 끝내고 Google ID 토큰을 돌려준다
    func signIn(config: CloudConfig) async throws -> String {
        let verifier  = Self.randomURLSafe(64)
        let challenge = Self.sha256Base64URL(verifier)
        let state     = Self.randomURLSafe(24)

        let server = try LoopbackServer()
        let port   = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.googleClientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        await MainActor.run { _ = NSWorkspace.shared.open(comps.url!) }

        let params: [String: String]
        do { params = try await server.waitForCallback(timeout: 180) }
        catch { server.stop(); throw error }
        server.stop()

        if params["error"] != nil { throw GoogleSignInError.cancelled }
        // state가 다르면 다른 곳에서 온 요청이다 — 코드를 쓰지 않는다
        guard params["state"] == state, let code = params["code"] else { throw GoogleSignInError.badCallback }

        return try await exchange(code: code, verifier: verifier, redirect: redirect, config: config)
    }

    // MARK: 코드 → ID 토큰

    private func exchange(code: String, verifier: String, redirect: String, config: CloudConfig) async throws -> String {
        var form: [(String, String)] = [
            ("code", code), ("client_id", config.googleClientId), ("redirect_uri", redirect),
            ("grant_type", "authorization_code"), ("code_verifier", verifier),
        ]
        if let secret = config.googleClientSecret, !secret.isEmpty { form.append(("client_secret", secret)) }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let idToken = json?["id_token"] as? String else {
            let detail = (json?["error_description"] as? String) ?? (json?["error"] as? String) ?? "HTTP error"
            throw GoogleSignInError.server(L.t("Google 로그인에 실패했어요: \(detail)", "Google sign-in failed: \(detail)"))
        }
        return idToken
    }

    // MARK: 보조

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncodedString().prefix(length).description
    }

    private static func sha256Base64URL(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 루프백 서버 (브라우저가 로그인 뒤 돌아오는 127.0.0.1 임시 포트)

final class LoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "buni.google.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var finished = false

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback      // 이 컴퓨터 안에서만 받는다
        listener = try NWListener(using: params)
    }

    /// 서버를 띄우고 배정된 포트를 돌려준다
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume(returning: self.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(GoogleSignInError.timeout)) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let pending = self.pending { cont.resume(with: pending) }   // 이미 도착했다면 바로 돌려준다
                else { self.continuation = cont }
            }
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        if let continuation { continuation.resume(with: result); self.continuation = nil }
        else { pending = result }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            // 첫 줄: "GET /?code=...&state=... HTTP/1.1"
            let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                self.reply(conn, status: "400 Bad Request", body: ""); return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }

            // 파비콘 같은 곳 요청은 무시하고 계속 기다린다
            guard params["code"] != nil || params["error"] != nil else {
                self.reply(conn, status: "404 Not Found", body: ""); return
            }
            let ok = params["error"] == nil
            self.reply(conn, status: "200 OK", body: Self.page(success: ok))
            self.finish(.success(params))
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "로그인이 완료됐어요 🐰" : "로그인을 취소했어요"
        let hint  = success ? "이 창은 닫아도 돼요. 부니로 돌아가세요." : "부니에서 다시 시도할 수 있어요."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Buni</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#14161a;color:#eef1f6;display:grid;place-items:center;height:100vh;margin:0">
        <div style="text-align:center"><h2>\(title)</h2><p style="color:#8b93a6">\(hint)</p></div></body></html>
        """
    }
}
