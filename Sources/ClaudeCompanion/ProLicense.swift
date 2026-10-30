import Foundation
import CryptoKit

/// 라이선스 키 검증 결과. valid 이면 plan·expires 가 채워지고, 아니면 reason 에 이유가 들어간다.
struct LicenseResult: Equatable {
    let valid: Bool
    /// "", "format", "signature", "expired", "no_pubkey" — windows/buni_license.py 와 같은 코드
    let reason: String
    let plan: String
    /// "YYYYMMDD"(UTC, 그날 끝까지) 또는 nil(만료 없음)
    let expires: String?

    var isPro: Bool { valid && ProLicense.proPlans.contains(plan) }
    var packID: String? { valid && plan.hasPrefix("pack:") ? String(plan.dropFirst(5)) : nil }

    static func invalid(_ reason: String, plan: String = "", expires: String? = nil) -> LicenseResult {
        LicenseResult(valid: false, reason: reason, plan: plan, expires: expires)
    }
}

/// Ed25519 오프라인 서명 라이선스 키 — Windows(buni_license.py)·발급 스크립트(tools/issue_license.py)와 같은 형식.
///
///     BUNI-<base64url(payload)>.<base64url(signature 64바이트)>       (패딩 '=' 없음)
///     payload = "v1|<plan>|<만료 YYYYMMDD 또는 0>|<이메일 해시 16자리 또는 0>"   (ASCII)
///
/// 공개키만 앱에 들어간다. 명세: docs/monetization/license-spec.md
enum ProLicense {
    static let prefix = "BUNI-"
    static let formatVersion = "v1"
    /// Pro 구독 플랜. 개별 코스메틱 팩은 "pack:<id>"
    static let proPlans = ["monthly", "yearly", "lifetime"]

    /// 배포용 공개키 (hex 64자). 비어 있으면 어떤 키도 통과하지 못해 모두 무료로 보인다.
    /// 키 쌍을 만든 뒤(tools/README.md) 여기에 공개키를 넣는다. 개발 중에는 환경변수로도 줄 수 있다.
    static let publicKeyHex = ""
    static let publicKeyEnv = "BUNI_LICENSE_PUBKEY"

    static func configuredPublicKey() -> Data? {
        let hex = (ProcessInfo.processInfo.environment[publicKeyEnv] ?? publicKeyHex)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = dataFromHex(hex), raw.count == 32 else { return nil }
        return raw
    }

    static func verify(_ rawKey: String?, publicKey: Data? = nil, now: Date = Date()) -> LicenseResult {
        let key = (rawKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(prefix), key.filter({ $0 == "." }).count == 1 else { return .invalid("format") }
        let halves = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count == 2,
              let payload = base64URLDecode(String(halves[0])),
              let sig = base64URLDecode(String(halves[1])), sig.count == 64,
              let text = String(data: payload, encoding: .ascii)
        else { return .invalid("format") }

        let parts = text.components(separatedBy: "|")
        guard parts.count == 4, parts[0] == formatVersion else { return .invalid("format") }
        let plan = parts[1], expires = parts[2]
        guard proPlans.contains(plan) || matches(plan, "^pack:[a-z0-9_]{1,40}$") else { return .invalid("format") }
        guard expires == "0" || matches(expires, "^[0-9]{8}$") else { return .invalid("format") }

        guard let pub = publicKey ?? configuredPublicKey() else { return .invalid("no_pubkey") }
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
              pubKey.isValidSignature(sig, for: payload)
        else { return .invalid("signature") }

        if expires != "0" && todayUTC(now) > expires {
            return .invalid("expired", plan: plan, expires: expires)
        }
        return LicenseResult(valid: true, reason: "", plan: plan, expires: expires == "0" ? nil : expires)
    }

    // MARK: - 도우미

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// 엄격한 base64url(패딩 없음). 형식이 틀리면 nil.
    static func base64URLDecode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count % 4 != 1 else { return nil }
        let allowed = text.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
        guard allowed else { return nil }
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// 만료일 비교용 "YYYYMMDD" (UTC)
    static func todayUTC(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: now)
    }
}
