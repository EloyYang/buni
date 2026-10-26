import Foundation

/// "한도에 도달했어요" 안내를 숨긴 상태를 세션 전체가 공유하는 저장소.
///
/// 예전에는 숨김 여부가 세션(CompanionController)마다 따로 있어서
/// ① 한 부니에서 숨겨도 다른 부니에는 그대로 떴고,
/// ② 사용량을 다시 읽을 때마다(resets_at 값이 조금만 달라져도) 숨김이 풀려
///    잠시 뒤 되살아났다.
/// 이제는 "이번 한도 창이 리셋될 때까지" 숨기고, 그 정보를 앱 전체가 공유한다.
final class LimitNoticeStore: ObservableObject {
    static let shared = LimitNoticeStore()

    private static let key = "limitNotice.dismissedUntil"

    /// 이 시각 전까지는 안내를 띄우지 않는다 (= 사용자가 숨긴 한도 창의 리셋 시각)
    @Published private(set) var dismissedUntil: Date?

    private init() {
        let ts = UserDefaults.standard.double(forKey: Self.key)
        dismissedUntil = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    /// 지금 숨김 상태인지 — 리셋 시각이 지나면 저절로 풀린다
    var isDismissed: Bool {
        guard let until = dismissedUntil else { return false }
        return Date() < until
    }

    /// 이번 한도 창을 숨긴다. resetAt을 모르면 5시간 뒤까지로 잡는다(한도 창 길이).
    /// 서버가 준 리셋 시각이 이미 지났을 수도 있어(사용량 정보가 낡은 경우) 최소 5분은
    /// 보장한다 — 안 그러면 숨기기를 눌러도 곧바로 다시 뜬다. 리셋 후에는 한도 상태가
    /// 풀려 어차피 안내가 안 뜨므로 넉넉히 잡아도 문제없다.
    func dismiss(until resetAt: Date?) {
        let fallback = Date().addingTimeInterval(5 * 3600)
        let until = max(resetAt ?? fallback, Date().addingTimeInterval(300))
        dismissedUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.key)
    }
}
