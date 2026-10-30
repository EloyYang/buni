import Foundation
import Combine
import SwiftUI

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

    /// 프리미엄 컬러 변형 id (ProManager.packs 의 rabbit_*). nil 이면 원래 색.
    /// 잠겨 있으면(Pro 종료 등) 값은 두고 그리지만 않는다 — 다시 Pro 가 되면 그대로 돌아온다.
    @Published var tint: String? = UserDefaults.standard.string(forKey: "character.tint") {
        didSet { UserDefaults.standard.set(tint, forKey: "character.tint") }
    }

    /// 지금 실제로 적용할 변형 (잠긴 것은 제외)
    var activeTint: CharacterTint? {
        guard let id = tint, ProManager.shared.itemUnlocked(id) else { return nil }
        return CharacterTint.all.first { $0.id == id }
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

// MARK: - 컬러 변형 (프리미엄)

/// 기존 캐릭터 그림에 색조만 입히는 변형 — 새 그림 없이 색만 바꾼다.
struct CharacterTint: Identifiable {
    let id: String          // ProManager.packs 의 아이템 id
    let nameKo: String
    let nameEn: String
    let hue: Double         // 도(degree)
    let saturation: Double
    let brightness: Double

    var name: String { L.t(nameKo, nameEn) }

    static let all: [CharacterTint] = [
        CharacterTint(id: "rabbit_mint",      nameKo: "민트",     nameEn: "Mint",      hue: 150, saturation: 1.0, brightness: 0.02),
        CharacterTint(id: "rabbit_lavender",  nameKo: "라벤더",   nameEn: "Lavender",  hue: 250, saturation: 0.9, brightness: 0.05),
        CharacterTint(id: "rabbit_midnight",  nameKo: "미드나잇", nameEn: "Midnight",  hue: 220, saturation: 0.8, brightness: -0.18),
        CharacterTint(id: "rabbit_sakura",    nameKo: "벚꽃",     nameEn: "Sakura",    hue: 330, saturation: 1.0, brightness: 0.06),
        CharacterTint(id: "rabbit_astronaut", nameKo: "우주",     nameEn: "Astronaut", hue: 190, saturation: 0.6, brightness: 0.0),
        CharacterTint(id: "rabbit_barista",   nameKo: "카페",     nameEn: "Barista",   hue: 25,  saturation: 0.8, brightness: -0.08),
    ]
}

/// 캐릭터 그림에 프리미엄 색 변형을 입히는 래퍼 — 잠겨 있거나 고르지 않았으면 그대로 둔다.
struct TintedCharacter<Content: View>: View {
    @ObservedObject private var store = CharacterStore.shared
    @ObservedObject private var pro = ProManager.shared
    let content: Content

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        if let t = store.activeTint {
            content.hueRotation(.degrees(t.hue)).saturation(t.saturation).brightness(t.brightness)
        } else {
            content
        }
    }
}
