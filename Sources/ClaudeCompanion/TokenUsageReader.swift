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

    // MARK: - 이번 달 합계 (세션이 여러 개여도 한 번에 하나만, 바뀐 파일만 다시 읽는다)

    private static let lock = NSLock()
    /// 파일별로 (크기, 수정 시각) 이 같으면 다시 읽지 않는다 — 대화 기록은 수 GB 가 될 수 있다
    private static var fileCache: [String: (size: Int, mtime: Date, tokens: Int)] = [:]
    private static var lastScan = Date.distantPast
    private static var lastTotal: Int?
    private static var scanning = false

    /// 이번 달 누적 input+output 토큰 합계 (백그라운드에서 호출하세요).
    /// 세션마다 따로 부르더라도 최근(minInterval 초 이내)에 계산한 값을 돌려주고, 다른 곳에서 계산 중이면
    /// 기다리지 않고 nil 을 돌려준다 — 부니 스쿼드처럼 세션이 한꺼번에 많이 생겨도 전체 기록을 동시에 읽지 않는다.
    static func readThisMonthShared(minInterval: TimeInterval = 240) -> Int? {
        lock.lock()
        if scanning { lock.unlock(); return nil }
        if let v = lastTotal, Date().timeIntervalSince(lastScan) < minInterval { lock.unlock(); return v }
        scanning = true
        lock.unlock()
        let total = readThisMonth()
        lock.lock()
        lastTotal = total
        lastScan = Date()
        scanning = false
        lock.unlock()
        return total
    }

    /// 이번 달 누적 input+output 토큰 합계 (직접 부르면 매번 훑는다 — 보통은 readThisMonthShared 를 쓴다)
    static func readThisMonth() -> Int {
        let cal  = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        guard let monthStart = cal.date(from: comps) else { return 0 }
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        var seen = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let rv   = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mods = rv.contentModificationDate,
                  mods >= monthStart else { continue }
            let size = rv.fileSize ?? 0
            seen.insert(url.path)

            lock.lock(); let cached = fileCache[url.path]; lock.unlock()
            if let c = cached, c.size == size, c.mtime == mods { total += c.tokens; continue }

            var fileTotal = 0
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                for line in content.components(separatedBy: "\n") where !line.isEmpty {
                    guard let data = line.data(using: .utf8),
                          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }

                    let usage: [String: Any]? =
                        obj["usage"] as? [String: Any]
                        ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    if let u = usage {
                        fileTotal += u["input_tokens"]  as? Int ?? 0
                        fileTotal += u["output_tokens"] as? Int ?? 0
                    }
                }
            }
            lock.lock(); fileCache[url.path] = (size, mods, fileTotal); lock.unlock()
            total += fileTotal
        }
        lock.lock()
        fileCache = fileCache.filter { seen.contains($0.key) }          // 사라진 파일은 잊는다
        lock.unlock()
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
