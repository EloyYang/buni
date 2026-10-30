import Foundation
import Combine
import CoreGraphics

/// "딴짓 방해모드" 전역 상태 — 모든 세션 패널이 공유해서 구독한다.
/// 켜져 있으면 마우스·키보드 입력이 `idleMinutes`분 이상 없을 때 부니가 화면을 돌아다니며 방해하고,
/// 입력이 다시 감지되면 원래 지정된 자리로 돌아온다.
final class FocusModeStore: ObservableObject {
    static let shared = FocusModeStore()

    static let presetMinutes = [1, 3, 5, 10, 15, 30]

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "focusMode.enabled")
            updatePolling()
        }
    }

    /// 방해를 시작하기까지의 무입력 시간(분)
    @Published var idleMinutes: Int {
        didSet {
            UserDefaults.standard.set(idleMinutes, forKey: "focusMode.idleMinutes")
            checkIdle()
        }
    }

    /// 모드가 켜져 있고 무입력 시간이 기준을 넘은 상태
    @Published private(set) var isUserIdle = false

    private var timer: Timer?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "focusMode.enabled")
        let saved = UserDefaults.standard.integer(forKey: "focusMode.idleMinutes")
        idleMinutes = saved > 0 ? saved : 5
        updatePolling()
    }

    private func updatePolling() {
        timer?.invalidate()
        timer = nil
        guard enabled else { isUserIdle = false; return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkIdle() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkIdle()
    }

    /// 마지막 마우스·키보드 입력 이후 경과 시간 (권한 불필요)
    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel,
                                    .keyDown, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
                    .min() ?? 0
    }

    private func checkIdle() {
        let idle = enabled && Self.secondsSinceLastInput() >= Double(idleMinutes) * 60
        if idle != isUserIdle { isUserIdle = idle }
    }
}
