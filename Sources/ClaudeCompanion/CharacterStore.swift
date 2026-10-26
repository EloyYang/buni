import Foundation
import Combine

// MARK: - Character type

enum CharacterType: String, CaseIterable {
    case rabbit      = "rabbit"
    case brownRabbit = "brownRabbit"
    case pinkRabbit   = "pinkRabbit"
    case orangeRabbit = "orangeRabbit"
    case yellowRabbit = "yellowRabbit"
    case greenRabbit  = "greenRabbit"

    /// 상점 캐릭터 선택 버튼처럼 좁은 곳에 쓰는 이름
    var shortName: String {
        switch self {
        case .rabbit:       return L.t("부니", "Buni")
        case .brownRabbit:  return L.t("두니", "Duni")
        case .pinkRabbit:   return L.t("푸니", "Puni")
        case .orangeRabbit: return L.t("주니", "Juni")
        case .yellowRabbit: return L.t("누니", "Nuni")
        case .greenRabbit:  return L.t("우니", "Uni")
        }
    }

    var displayName: String {
        switch self {
        case .rabbit:       return L.t("부니 (흰토끼)",   "Buni (white)")
        case .brownRabbit:  return L.t("두니 (갈색토끼)", "Duni (brown)")
        case .pinkRabbit:   return L.t("푸니 (핑크토끼)", "Puni (pink)")
        case .orangeRabbit: return L.t("주니 (주황토끼)", "Juni (orange)")
        case .yellowRabbit: return L.t("누니 (노란토끼)", "Nuni (yellow)")
        case .greenRabbit:  return L.t("우니 (연두토끼)", "Uni (green)")
        }
    }
}

// MARK: - Store

class CharacterStore: ObservableObject {
    static let shared = CharacterStore()

    @Published var selected: CharacterType = .rabbit {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "character.selected") }
    }

    init() {
        if let raw  = UserDefaults.standard.string(forKey: "character.selected"),
           let type = CharacterType(rawValue: raw) {
            selected = type
        } else {
            selected = .rabbit
        }
    }
}
