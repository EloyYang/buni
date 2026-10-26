import Foundation
import AppKit

final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let apiURL      = "https://api.github.com/repos/EloyYang/buni/releases/latest"
    private static let releasePage = "https://github.com/EloyYang/buni/releases/latest"
    private static let checkIntervalSec: TimeInterval = 6 * 3600  // 6시간마다

    private var checkTimer: DispatchSourceTimer?

    var onUpdateFound: ((String) -> Void)?

    // MARK: - 공개 API

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(URL(string: releasePage)!)
    }

    func startPeriodicCheck() {
        // 앱 시작 3초 후 첫 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.performCheck()
        }

        // 이후 6시간마다 반복
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + Self.checkIntervalSec,
                   repeating: Self.checkIntervalSec)
        t.setEventHandler { [weak self] in self?.performCheck() }
        t.resume()
        checkTimer = t
    }

    // MARK: - 내부 로직

    private func performCheck() {
        Self.fetchLatestVersion { [weak self] latest in
            guard let self, let ver = latest else { return }
            DispatchQueue.main.async { self.onUpdateFound?(ver) }
        }
    }

    static func check(completion: @escaping (String?) -> Void) {
        fetchLatestVersion(completion: completion)
    }

    private static func fetchLatestVersion(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: apiURL) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag  = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let latest  = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = currentVersion
            let newer   = latest.compare(current, options: .numeric) == .orderedDescending
            DispatchQueue.main.async { completion(newer ? latest : nil) }
        }.resume()
    }
}
