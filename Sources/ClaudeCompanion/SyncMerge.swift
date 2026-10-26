import Foundation

/// 서버(Firestore)에 저장되는 한 사용자의 문서
struct CloudDoc: Equatable {
    var coins: Int = 0
    var owned: Set<String> = []
    /// 캐릭터 rawValue → (자리 rawValue → 아이템 id)
    var equipped: [String: [String: String]] = [:]
    var equippedUpdatedAt: Date = .distantPast
    /// 월("2026-10") → (기기 id → 그 기기에서 센 이번 달 토큰)
    var tokens: [String: [String: Int]] = [:]
}

/// 이 기기의 현재 상태
struct LocalState {
    var coins: Int
    var owned: Set<String>
    var equipped: [String: [String: String]]
    /// 이 기기에서 착용을 마지막으로 바꾼 시각 (한 번도 안 바꿨으면 .distantPast)
    var equippedChangedAt: Date
    var deviceId: String
    var month: String
    var monthTokens: Int
}

struct MergeResult: Equatable {
    var doc: CloudDoc            // 서버에 쓸 값
    var tokensThisMonth: Int     // 모든 기기를 합친 이번 달 토큰 → 레벨 계산에 쓴다
}

/// 여러 기기의 상태를 하나로 합치는 규칙. 네트워크와 무관한 순수 함수라 단독으로 시험할 수 있다.
///
/// - 구매 목록: **합집합** — 어느 기기에서 샀든 모든 기기에서 쓸 수 있다.
/// - 코인: **변화량 합산** — "지난 동기화 이후 이 기기에서 늘고 준 만큼"만 서버 값에 더한다.
///   (값을 그대로 덮어쓰면 두 기기가 번 코인 중 한쪽이 사라진다)
/// - 착용: **나중에 바꾼 쪽**이 이긴다.
/// - 토큰: 기기별로 따로 적고 **합산** — 레벨은 부니를 켜둔 모든 PC의 사용량 합이다.
enum SyncMerge {

    /// - Parameters:
    ///   - baseline: 지난 동기화 때 서버와 맞춰둔 코인. nil이면 이 기기는 이 계정과 처음 연결하는 것.
    static func merge(local: LocalState, remote: CloudDoc?, baselineCoins: Int?) -> MergeResult {
        guard let remote else {
            // 서버에 아무것도 없다 — 이 기기 상태가 처음 올라간다
            var doc = CloudDoc(coins: max(0, local.coins), owned: local.owned, equipped: local.equipped,
                               equippedUpdatedAt: local.equippedChangedAt)
            doc.tokens[local.month] = [local.deviceId: local.monthTokens]
            return MergeResult(doc: doc, tokensThisMonth: local.monthTokens)
        }

        var doc = remote

        // 코인
        if let base = baselineCoins {
            doc.coins = max(0, remote.coins + (local.coins - base))
        } else {
            // 처음 연결 — 이 기기의 코인도 아직 서버에 반영된 적이 없으니 더한다
            // (새 PC는 보통 0이라 서버 값 그대로가 된다)
            doc.coins = max(0, remote.coins + local.coins)
        }

        // 구매 목록
        doc.owned = remote.owned.union(local.owned)

        // 착용 — 이 기기가 더 최근에 바꿨으면 이 기기 것, 아니면 서버 것.
        // 서버에 착용 기록이 비어 있으면(처음) 이 기기 것을 올린다.
        if remote.equipped.isEmpty || local.equippedChangedAt > remote.equippedUpdatedAt {
            doc.equipped = local.equipped
            doc.equippedUpdatedAt = max(local.equippedChangedAt, remote.equippedUpdatedAt)
        }

        // 토큰 — 이 기기 몫만 갱신하고(줄어들진 않게), 오래된 달은 정리한다
        var thisMonth = doc.tokens[local.month] ?? [:]
        thisMonth[local.deviceId] = max(thisMonth[local.deviceId] ?? 0, local.monthTokens)
        doc.tokens[local.month] = thisMonth
        doc.tokens = prune(doc.tokens, keeping: local.month)

        return MergeResult(doc: doc, tokensThisMonth: thisMonth.values.reduce(0, +))
    }

    /// 현재 달을 포함해 최근 3개월만 남긴다 (문서가 끝없이 커지지 않게)
    private static func prune(_ tokens: [String: [String: Int]], keeping current: String) -> [String: [String: Int]] {
        let months = tokens.keys.sorted(by: >).prefix(3)
        let keep = Set(months).union([current])
        return tokens.filter { keep.contains($0.key) }
    }
}
