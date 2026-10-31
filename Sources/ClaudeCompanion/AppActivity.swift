import AppKit
import SwiftUI

/// 화면이 꺼졌는지(화면 잠자기·시스템 잠자기·세션 전환) 알려 주는 한 곳.
/// 화면이 꺼져 있으면 아무도 애니메이션을 못 보므로, 그릴 일을 멈추고 폴링도 느리게 한다.
/// (캐릭터 모습·동작의 의미는 그대로 — 화면이 켜지면 바로 이어서 그린다)
final class AppActivity {
    static let shared = AppActivity()

    /// 화면이 꺼졌거나 잠든 동안 true. 어느 스레드에서 읽어도 되도록 잠금으로 지킨다.
    private let lock = NSLock()
    private var _screenAsleep = false
    var screenAsleep: Bool {
        lock.lock(); defer { lock.unlock() }
        return _screenAsleep
    }

    /// 화면 상태가 바뀌었을 때(꺼짐/켜짐) 메인 스레드에서 불린다
    static let didChange = Notification.Name("buni.appActivity.didChange")

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.set(true) }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.set(false) }
        }
    }

    private func set(_ asleep: Bool) {
        lock.lock()
        let changed = _screenAsleep != asleep
        _screenAsleep = asleep
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

private struct BuniPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 창이 가려졌거나 화면이 꺼져 있어 애니메이션을 멈춰야 하면 true
    var buniPaused: Bool {
        get { self[BuniPausedKey.self] }
        set { self[BuniPausedKey.self] = newValue }
    }
}
