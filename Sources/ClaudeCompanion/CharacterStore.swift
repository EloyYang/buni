import Foundation
import Combine

// MARK: - Character type

enum CharacterType: String, CaseIterable {
    case crab      = "crab"
    case jellyfish = "jellyfish"
    case rabbit    = "rabbit"

    var displayName: String {
        switch self {
        case .crab:      return "클로디 (게)"
        case .jellyfish: return "젤리 (해파리)"
        case .rabbit:    return "라비 (토끼)"
        }
    }
}

// MARK: - Store

class CharacterStore: ObservableObject {
    static let shared = CharacterStore()

    @Published var selected: CharacterType = .crab {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "character.selected") }
    }

    init() {
        if let raw  = UserDefaults.standard.string(forKey: "character.selected"),
           let type = CharacterType(rawValue: raw) {
            selected = type
        }
    }
}
