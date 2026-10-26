import Foundation
import Combine

enum Language: String, CaseIterable {
    case korean  = "ko"
    case english = "en"

    /// 설정 화면에 보이는 이름 — 언어 이름은 그 언어로 적는 게 관례라 번역하지 않는다
    var displayName: String {
        switch self {
        case .korean:  return "한국어"
        case .english: return "English"
        }
    }
}

/// 부니 표시 언어. 설정에서 바꾸면 모든 부니와 메뉴바에 바로 반영된다.
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    private static let key = "language"
    /// 훅 스크립트(별도 프로세스)가 읽어가는 현재 언어 — 권한 버블 문구 등에 쓰인다
    private static let sharedFile = "/tmp/claude-companion-lang"

    @Published var current: Language {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
            exportForHooks()
        }
    }

    private init() {
        if let raw  = UserDefaults.standard.string(forKey: Self.key),
           let lang = Language(rawValue: raw) {
            current = lang
        } else {
            // 처음 실행 — 시스템 언어가 한국어면 한국어, 그 외에는 영어로 시작
            let system = Locale.preferredLanguages.first ?? "en"
            current = system.hasPrefix("ko") ? .korean : .english
        }
        exportForHooks()
    }

    private func exportForHooks() {
        try? current.rawValue.write(toFile: Self.sharedFile,
                                    atomically: true, encoding: .utf8)
    }
}

/// 짧은 번역 도우미. 문구가 몇십 개뿐이라 별도 키 없이 두 언어를 나란히 적는다.
/// 예) Text(L.t("완료했어요!", "All done!"))
enum L {
    static func t(_ ko: String, _ en: String) -> String {
        LanguageStore.shared.current == .english ? en : ko
    }
}
