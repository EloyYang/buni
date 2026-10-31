import Foundation
import AppKit
import Combine
import IOKit

/// 노트북 덮개를 닫아도 Claude가 계속 돌도록 시스템 절전을 막는다.
///
/// 맥북은 덮개를 닫으면 "클램셸 절전"이라는 별도 경로로 잠들기 때문에,
/// caffeinate나 IOKit 절전 방지 assertion으로는 막을 수 없다. 유일한 방법은
/// `pmset disablesleep 1`로 시스템 절전 자체를 끄는 것인데 root 권한이 필요하다.
/// 그래서 설치 시 sudoers에 이 두 명령만 비밀번호 없이 실행할 수 있도록
/// 등록해두고(installHelper), 이후에는 조용히 켜고 끈다.
///
/// 안전장치
///  · 켤 때 지정한 시간이 지나면 자동으로 되돌린다(무제한 선택 시 제외).
///  · 앱이 종료될 때 반드시 되돌린다 — 켜둔 채 꺼지면 맥이 영영 안 자게 된다.
///  · 앱이 뜰 때도 한 번 정리한다(지난번에 비정상 종료된 경우 대비).
///  · "세션이 끝날 때까지" 모드는 실행 중인 세션이 모두 끝나면 알아서 되돌린다.
final class AwakeManager: ObservableObject {
    static let shared = AwakeManager()

    // MARK: - 상태

    /// 지금 절전이 꺼져 있는지(= 덮개를 닫아도 계속 도는 상태)
    @Published private(set) var isActive = false
    /// 자동 해제 예정 시각 — nil이면 무제한
    @Published private(set) var activeUntil: Date?
    /// "세션이 끝날 때까지" 모드 — 실행 중인 세션이 있는 동안 유지하고, 모두 끝나면 같이 끈다
    @Published private(set) var followingSessions = false
    /// 마지막 실패 사유 (메뉴에 표시)
    @Published private(set) var lastError: String?
    /// 비밀번호 없이 pmset을 쓸 수 있게 등록돼 있는지 — 실제 실행으로 확인한 값
    @Published private(set) var isHelperInstalled: Bool = false

    // MARK: - 시간대 예약 (매일 같은 시간에 자동 on/off)

    @Published var scheduleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: UD.scheduleEnabled)
            applySchedule()
        }
    }
    /// 자정 기준 분 단위 (예: 9시 = 540)
    @Published var scheduleStartMinute: Int {
        didSet {
            UserDefaults.standard.set(scheduleStartMinute, forKey: UD.scheduleStart)
            applySchedule()
        }
    }
    @Published var scheduleEndMinute: Int {
        didSet {
            UserDefaults.standard.set(scheduleEndMinute, forKey: UD.scheduleEnd)
            applySchedule()
        }
    }

    private enum UD {
        static let scheduleEnabled = "awake.schedule.enabled"
        static let scheduleStart   = "awake.schedule.start"
        static let scheduleEnd     = "awake.schedule.end"
    }

    private static let pmsetPath   = "/usr/bin/pmset"
    private static let sudoersPath = "/etc/sudoers.d/buni-keepawake"

    /// 지금 일하는 세션이 있는지 알려 주는 쪽 (AppDelegate 가 채운다 — 부니 세션 + 스쿼드 작업)
    var sessionsRunningProvider: (() -> Bool)?
    private var followTimer: Timer?
    private var followSawRunning = false
    private var followIdleSince: Date?
    /// 세션이 끝난 뒤 잠깐 더 기다린다 — 도구 사이의 짧은 틈에 끄지 않도록
    private static let followGrace: TimeInterval = 60
    /// 켰는데 세션이 한 번도 시작되지 않으면 이만큼 기다렸다 포기한다
    private static let followStartWait: TimeInterval = 10 * 60

    private var expiryTimer: Timer?
    private var scheduleTimer: Timer?
    /// 덮개 여닫힘 감시 — 켜져 있는 동안에만 돈다
    private var lidTimer: Timer?
    private var lidWasClosed = false
    /// 시간대 예약으로 켜진 상태인지 — 자동 해제 판단과 메뉴 문구에 쓴다
    @Published private(set) var activatedBySchedule = false

    private init() {
        let d = UserDefaults.standard
        scheduleEnabled     = d.bool(forKey: UD.scheduleEnabled)
        scheduleStartMinute = d.object(forKey: UD.scheduleStart) as? Int ?? 9 * 60
        scheduleEndMinute   = d.object(forKey: UD.scheduleEnd) as? Int ?? 18 * 60

        // 등록 여부 확인 + 지난번에 켜둔 채 비정상 종료된 경우 뒷정리를 겸한다
        isActive = false
        refreshHelperState()

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.applySchedule()
        }
        scheduleTimer?.tolerance = 10
        applySchedule()
    }

    // MARK: - 켜기 / 끄기

    /// - Parameter duration: 유지할 시간. nil이면 직접 끌 때까지 무제한.
    @discardableResult
    func enable(duration: TimeInterval?, bySchedule: Bool = false) -> Bool {
        guard isHelperInstalled else {
            lastError = L.t("권한 설정이 필요합니다", "Permission setup required")
            return false
        }
        guard runPmset(disable: true) else {
            lastError = L.t("절전 해제에 실패했습니다", "Could not disable sleep")
            return false
        }
        lastError = nil
        activatedBySchedule = bySchedule
        isActive = true
        stopFollowing()                       // 시간·무제한·예약으로 켜면 "세션 따라가기"는 해제

        expiryTimer?.invalidate(); expiryTimer = nil
        if let duration {
            let until = Date().addingTimeInterval(duration)
            activeUntil = until
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.disable()
            }
        } else {
            activeUntil = nil
        }
        startLidWatch()
        return true
    }

    /// 실행 중인 세션이 있는 동안만 켜 둔다 — 모두 끝나고 잠시 지나면 자동으로 끈다.
    /// 시간 제한 없이 켜지만 세션이 없으면 알아서 풀리므로 "깜빡 켜 두고 가방에 넣는" 일이 없다.
    @discardableResult
    func enableUntilSessionsFinish() -> Bool {
        guard enable(duration: nil) else { return false }
        followingSessions = true
        followSawRunning = false
        followIdleSince = Date()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.evaluateFollowing()
        }
        followTimer?.tolerance = 2
        return true
    }

    private func evaluateFollowing() {
        guard followingSessions else { return }
        if sessionsRunningProvider?() == true {
            followSawRunning = true
            followIdleSince = nil
            return
        }
        let since = followIdleSince ?? Date()
        followIdleSince = since
        let limit = followSawRunning ? Self.followGrace : Self.followStartWait
        if Date().timeIntervalSince(since) >= limit { disable() }
    }

    private func stopFollowing() {
        followTimer?.invalidate(); followTimer = nil
        followingSessions = false
        followSawRunning = false
        followIdleSince = nil
    }

    func disable() {
        stopFollowing()
        stopLidWatch()
        expiryTimer?.invalidate(); expiryTimer = nil
        activeUntil = nil
        activatedBySchedule = false
        guard isActive || systemSleepDisabled else { isActive = false; return }
        _ = runPmset(disable: false)
        isActive = false
    }

    /// 앱 종료 시 반드시 호출 — 켜둔 채 꺼지면 맥이 계속 안 자게 된다
    func restoreOnQuit() {
        if systemSleepDisabled { _ = runPmset(disable: false) }
    }

    /// 메뉴에 보여줄 상태 문구 — 언제 끝나는지가 항상 드러나게 한다.
    ///  · 시간을 골라 켠 경우: "1시간 23분 남음"
    ///  · 시간대 예약으로 켜진 경우: "18:00까지 (3시간 12분 남음)"
    ///  · 직접 무제한으로 켠 경우만 "무제한"
    var statusText: String {
        if followingSessions {
            return followSawRunning
                ? L.t("세션이 끝나면 자동 해제", "off when sessions finish")
                : L.t("세션이 시작되길 기다리는 중", "waiting for a session to start")
        }
        if let until = activeUntil {
            return Self.leftText(Int(max(0, until.timeIntervalSinceNow)) / 60)
        }
        if activatedBySchedule {
            let end = Self.hhmm(scheduleEndMinute)
            return L.t("\(end)까지 (\(Self.leftText(minutesUntilScheduleEnd())))",
                       "until \(end) (\(Self.leftText(minutesUntilScheduleEnd())))")
        }
        return L.t("무제한", "no limit")
    }

    private static func leftText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return L.t("\(h)시간 \(m)분 남음", "\(h)h \(m)m left") }
        return L.t("\(m)분 남음", "\(m)m left")
    }

    static func hhmm(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// 예약 종료까지 남은 분 (자정을 넘는 구간도 처리)
    private func minutesUntilScheduleEnd() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var diff = scheduleEndMinute - now
        if diff <= 0 { diff += 24 * 60 }
        return diff
    }

    // MARK: - 시간대 예약

    // ── 덮개를 닫으면 화면만 끄기 ─────────────────────────────
    //
    // 시스템 절전을 꺼두면 덮개를 닫아도 macOS가 "자러 가는" 경로를 타지 않아
    // 내장 화면이 켜진 채로 남는다. 덮개가 닫히는 순간을 잡아 화면만 따로
    // 재워서, 평소처럼 화면은 꺼지고 작업만 계속되게 한다.
    // (pmset displaysleepnow는 관리자 권한이 필요 없다)

    private func startLidWatch() {
        lidWasClosed = isLidClosed()
        lidTimer?.invalidate()
        lidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkLid()
        }
        lidTimer?.tolerance = 1
    }

    private func stopLidWatch() {
        lidTimer?.invalidate(); lidTimer = nil
        lidWasClosed = false
    }

    private func checkLid() {
        let closed = isLidClosed()
        defer { lidWasClosed = closed }
        guard closed, !lidWasClosed else { return }   // 방금 닫힌 순간에만
        sleepDisplayNow()
        // 닫는 순간 들어오는 다른 이벤트에 화면이 다시 켜지는 경우가 있어
        // 잠시 뒤 한 번 더 재운다. 그 사이 열렸으면 건너뛴다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isActive, self.isLidClosed() else { return }
            self.sleepDisplayNow()
        }
    }

    /// 덮개가 닫혀 있는지 — IOPMrootDomain의 AppleClamshellState를 직접 읽는다
    private func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let closed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool
        else { return false }
        return closed
    }

    private func sleepDisplayNow() {
        _ = runCommand("/usr/bin/pmset", ["displaysleepnow"])
    }

    private func applySchedule() {
        guard scheduleEnabled else {
            // 예약으로 켜진 상태였다면 예약을 끌 때 같이 끈다
            if activatedBySchedule { disable() }
            return
        }
        guard isHelperInstalled else { return }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let inWindow = isInWindow(minute)

        if inWindow, !isActive {
            enable(duration: nil, bySchedule: true)
        } else if !inWindow, isActive, activatedBySchedule {
            disable()
        }
    }

    /// 종료 시각이 시작보다 빠르면 자정을 넘는 구간으로 본다 (예: 22:00~06:00)
    private func isInWindow(_ minute: Int) -> Bool {
        if scheduleStartMinute == scheduleEndMinute { return false }
        if scheduleStartMinute < scheduleEndMinute {
            return minute >= scheduleStartMinute && minute < scheduleEndMinute
        }
        return minute >= scheduleStartMinute || minute < scheduleEndMinute
    }

    // MARK: - pmset 실행

    /// 현재 시스템 절전이 꺼져 있는지 (pmset -g의 SleepDisabled)
    var systemSleepDisabled: Bool {
        guard let out = runCommand("/usr/bin/pmset", ["-g"]) else { return false }
        guard let line = out.split(separator: "\n").first(where: { $0.contains("SleepDisabled") })
        else { return false }
        return line.contains("1")
    }

    private func runPmset(disable: Bool) -> Bool {
        // sudoers에 등록해둔 그대로의 명령만 실행한다 (-n: 비밀번호 요구 시 즉시 실패)
        let result = runCommand("/usr/bin/sudo",
                                ["-n", Self.pmsetPath, "disablesleep", disable ? "1" : "0"])
        return result != nil
    }

    @discardableResult
    private func runCommand(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 권한(sudoers) 설치

    /// 등록 여부를 실제로 한 번 실행해 확인하고 캐시한다.
    ///
    /// 파일 존재(/etc/sudoers.d/...)로는 확인할 수 없다 — 그 디렉터리는 root만
    /// 들여다볼 수 있어 일반 사용자에게는 항상 "없음"으로 보인다. 등록한 명령도
    /// disablesleep 1|0 둘뿐이라 다른 pmset 명령으로 떠보면 거부당한다.
    /// disablesleep 0은 원래 기본 상태로 되돌리는 것뿐이라 그대로 탐침으로 쓴다
    /// (앱 시작 때 호출하면 지난번 비정상 종료 뒷정리까지 겸한다).
    @discardableResult
    func refreshHelperState() -> Bool {
        guard !isActive else { return isHelperInstalled }   // 켜져 있을 땐 건드리지 않는다
        let ok = runCommand("/usr/bin/sudo",
                            ["-n", Self.pmsetPath, "disablesleep", "0"]) != nil
        if isHelperInstalled != ok { isHelperInstalled = ok }
        return ok
    }

    /// 관리자 비밀번호를 한 번 받아 sudoers에 예외를 등록한다.
    /// 잘못된 sudoers 파일은 sudo 자체를 망가뜨리므로, 반드시 visudo로 검사한 뒤
    /// install로 올바른 소유자·권한(root:wheel 0440)으로 설치한다.
    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        let user = NSUserName()
        let rule = """
        # Buni — 덮개를 닫아도 Claude가 계속 돌도록 절전만 켜고 끌 수 있게 한다.
        # 아래 두 명령 외에는 어떤 권한도 주지 않는다.
        \(user) ALL=(root) NOPASSWD: \(Self.pmsetPath) disablesleep 1
        \(user) ALL=(root) NOPASSWD: \(Self.pmsetPath) disablesleep 0
        """
        let tmp = NSTemporaryDirectory() + "buni-keepawake.sudoers"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { completion(false, error.localizedDescription); return }

        // visudo -cf 로 문법 검사 → 통과해야만 설치
        let script = """
        /usr/sbin/visudo -cf '\(tmp)' >/dev/null 2>&1 && \
        /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(Self.sudoersPath)'
        """
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

        DispatchQueue.global().async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: apple)?.executeAndReturnError(&errorInfo)
            try? FileManager.default.removeItem(atPath: tmp)
            let message = errorInfo?["NSAppleScriptErrorMessage"] as? String
            DispatchQueue.main.async {
                let ok = self.refreshHelperState()
                completion(ok, ok ? nil : (message ?? L.t("설치하지 못했습니다", "Install failed")))
            }
        }
    }

    /// 등록해둔 sudoers 예외를 제거한다 (기능을 더 안 쓸 때)
    func removeHelper(completion: @escaping (Bool) -> Void) {
        disable()
        let apple = "do shell script \"/bin/rm -f '\(Self.sudoersPath)'\" with administrator privileges"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: apple)?.executeAndReturnError(&err)
            DispatchQueue.main.async { completion(!self.refreshHelperState()) }
        }
    }
}
