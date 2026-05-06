import Foundation
import AppKit
import UserNotifications

final class UpdateChecker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    private static let apiURL      = "https://api.github.com/repos/EloyYang/buni/releases/latest"
    private static let releasePage = "https://github.com/EloyYang/buni/releases/latest"
    private static let notifID     = "buni.update.available"
    private static let checkIntervalSec: TimeInterval = 6 * 3600  // 6시간마다

    private var checkTimer: DispatchSourceTimer?
    private var notifiedVersion: String? = nil  // 이미 알림 보낸 버전 (중복 방지)

    // 새 버전 발견 시 외부에서 처리할 콜백 (AppDelegate가 주입)
    var onUpdateFound: ((String) -> Void)?

    // MARK: - 공개 API

    /// 앱 번들에서 현재 버전 읽기
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(URL(string: releasePage)!)
    }

    /// 알림 권한 요청 + 주기적 업데이트 체크 시작
    func startPeriodicCheck() {
        requestNotificationPermission()

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

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func performCheck() {
        Self.fetchLatestVersion { [weak self] latest in
            guard let self, let ver = latest else { return }
            DispatchQueue.main.async {
                self.onUpdateFound?(ver)
                self.sendNotificationIfNeeded(version: ver)
            }
        }
    }

    /// GitHub API로 최신 릴리즈 버전 확인.
    /// 새 버전이 있으면 버전 문자열("1.2.3")을 completion에 전달, 없으면 nil.
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

    // MARK: - 시스템 알림

    private func sendNotificationIfNeeded(version: String) {
        // 이미 이 버전으로 알림을 보냈다면 중복 전송 안 함
        guard notifiedVersion != version else { return }
        notifiedVersion = version

        let content = UNMutableNotificationContent()
        content.title = "Buni 업데이트 available"
        content.body  = "v\(version)이 출시됐어요. 클릭해서 다운로드하세요."
        content.sound = .default
        // 알림 클릭 시 릴리즈 페이지 열기를 위한 식별자
        content.userInfo = ["action": "openRelease", "version": version]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notifID,
                                            content: content,
                                            trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 포그라운드(앱이 열려 있을 때)에서도 알림 배너 표시
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    /// 알림 클릭 → 릴리즈 페이지 열기
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["action"] as? String == "openRelease" {
            Self.openReleasePage()
        }
        handler()
    }
}
