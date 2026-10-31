import Foundation

/// 이벤트 파일 목록에서 새로 패널을 만들 세션을 고른다 (windows/buni.py `pick_new_sessions` 와 같은 규칙).
/// - 이미 패널이 있는 세션 id 는 다시 만들지 않는다.
/// - 스쿼드 세션(`squad-<작업id>`)은 작업마다 파일이 생기지만 부니는 하나만 — 이미 스쿼드 패널이 있으면 더 만들지 않고,
///   없으면 가장 최근에 갱신된 스쿼드 파일 하나만 고른다.
enum SessionDedupe {
    static let squadPrefix = "squad-"

    static func newSessions(found: [String: Date], existing: Set<String>) -> [String] {
        var out = found.keys.filter { !existing.contains($0) && !$0.hasPrefix(squadPrefix) }
        if !existing.contains(where: { $0.hasPrefix(squadPrefix) }),
           let newest = found.filter({ $0.key.hasPrefix(squadPrefix) })
                             .max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            out.append(newest)
        }
        return out.sorted()
    }
}
