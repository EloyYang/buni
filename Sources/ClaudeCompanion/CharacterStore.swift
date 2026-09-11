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

    var displayName: String {
        switch self {
        case .rabbit:       return "부니 (흰토끼)"
        case .brownRabbit:  return "두니 (갈색토끼)"
        case .pinkRabbit:   return "푸니 (핑크토끼)"
        case .orangeRabbit: return "주니 (주황토끼)"
        case .yellowRabbit: return "누니 (노란토끼)"
        case .greenRabbit:  return "우니 (연두토끼)"
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
