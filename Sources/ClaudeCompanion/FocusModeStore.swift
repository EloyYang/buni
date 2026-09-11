import Foundation
import Combine

/// "딴짓 금지 모드" 전역 켜짐/꺼짐 상태 — 모든 세션 패널이 공유해서 구독한다.
/// 켜져 있으면 세션이 대기(ready) 상태일 때 부니가 화면을 돌아다니며 주의를 끌고,
/// 세션이 다시 진행되면(생각중/툴사용 등) 원래 지정된 자리로 돌아온다.
final class FocusModeStore: ObservableObject {
    static let shared = FocusModeStore()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "focusMode.enabled") }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "focusMode.enabled")
    }
}
