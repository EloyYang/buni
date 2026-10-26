import Foundation

/// 오늘 날짜의 Claude 세션 JSONL 파일을 스캔해 토큰 사용량을 집계합니다.
/// 읽는 값: input_tokens + output_tokens (cache_read는 무료에 가까워 제외)
struct DailyTokens {
    let input:  Int
    let output: Int
    var total:  Int { input + output }

    var shortLabel: String {
        let t = total
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000     { return "\(t / 1_000)K" }
        return "\(t)"
    }

    static let zero = DailyTokens(input: 0, output: 0)
}

final class TokenUsageReader {

    private static let projectsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// 이번 달 누적 input+output 토큰 합계 (백그라운드에서 호출하세요)
    static func readThisMonth() -> Int {
        let cal  = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        guard let monthStart = cal.date(from: comps) else { return 0 }
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let rv   = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mods = rv.contentModificationDate,
                  mods >= monthStart else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let usage: [String: Any]? =
                    obj["usage"] as? [String: Any]
                    ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                if let u = usage {
                    total += u["input_tokens"]  as? Int ?? 0
                    total += u["output_tokens"] as? Int ?? 0
                }
            }
        }
        return total
    }

    /// 백그라운드에서 호출하세요.
    static func readToday() -> DailyTokens {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fm    = FileManager.default

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return .zero }

        var totalInput  = 0
        var totalOutput = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }

            // 오늘 수정된 파일만
            guard let rv   = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mods = rv.contentModificationDate,
                  cal.startOfDay(for: mods) == today else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // usage 필드는 최상위 또는 message 하위에 있을 수 있음
                let usage: [String: Any]? =
                    obj["usage"] as? [String: Any]
                    ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]

                if let u = usage {
                    totalInput  += u["input_tokens"]  as? Int ?? 0
                    totalOutput += u["output_tokens"]  as? Int ?? 0
                }
            }
        }

        return DailyTokens(input: totalInput, output: totalOutput)
    }
}
