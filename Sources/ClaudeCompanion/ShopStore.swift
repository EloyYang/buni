import Foundation
import Combine

/// 아이템이 붙는 자리 — 자리마다 하나씩만 착용할 수 있다
enum ItemSlot: String, CaseIterable, Codable {
    case head    // 모자·왕관
    case face    // 안경류
    case outfit  // 옷 — 몸통 위, 노트북 아래에 그린다
    case back    // 망토·날개 (캐릭터 뒤에 그린다)
    case weapon  // 검·지팡이 — 작업 중에만 손에 든다
    case tool    // 작업 도구 — 작업 중에 노트북 대신 쓴다 (기본은 노트북)

    var title: String {
        switch self {
        case .head:   return L.t("머리", "Head")
        case .face:   return L.t("얼굴", "Face")
        case .outfit: return L.t("옷", "Outfit")
        case .back:   return L.t("등", "Back")
        case .weapon: return L.t("무기", "Weapon")
        case .tool:   return L.t("작업", "Work")
        }
    }
}

struct ShopItem: Identifiable, Equatable {
    let id: String
    let nameKo: String
    let nameEn: String
    let slot: ItemSlot
    /// 살 수 있게 되는 최소 레벨
    let level: Int
    let price: Int

    var name: String { L.t(nameKo, nameEn) }
}

/// 부니 상점 — 코인을 모아 꾸미기 아이템과 무기를 산다.
///
/// 코인은 작업을 한 번 끝낼 때마다(Stop 훅 → 완료) 쌓이고, 아이템은 레벨 조건을
/// 만족해야 살 수 있다. 레벨은 기존 게이지바와 같은 기준(이번 달 누적 토큰
/// 50만당 1레벨)을 쓴다 — 많이 일할수록 좋은 장비를 든다.
final class ShopStore: ObservableObject {
    static let shared = ShopStore()

    @Published private(set) var coins: Int {
        didSet { UserDefaults.standard.set(coins, forKey: UD.coins) }
    }
    @Published private(set) var owned: Set<String> {
        didSet { UserDefaults.standard.set(Array(owned), forKey: UD.owned) }
    }
    /// 캐릭터 → (자리 → 착용 중인 아이템 id). 구매는 공용이지만 착용은 캐릭터마다 따로다.
    @Published private(set) var equipped: [CharacterType: [ItemSlot: String]] {
        didSet {
            var raw: [String: [String: String]] = [:]
            for (character, slots) in equipped {
                raw[character.rawValue] = Dictionary(uniqueKeysWithValues:
                    slots.map { ($0.key.rawValue, $0.value) })
            }
            UserDefaults.standard.set(raw, forKey: UD.equippedByCharacter)
        }
    }
    /// 이번 달 누적 토큰 기준 레벨 (게이지바 표시와 동일)
    @Published private(set) var level: Int = 1

    /// 작업 하나를 끝낼 때마다 주는 코인
    static let coinsPerCompletion = 5

    /// 다른 PC까지 합친 이번 달 토큰 — 로그인해서 동기화한 경우에만 값이 있다
    @Published private(set) var cloudTokenTotal: Int?
    /// 이 기기에서 센 이번 달 토큰 (로컬 클로드 기록 기준)
    private(set) var localTokens: Int = 0
    /// 이 기기에서 착용을 마지막으로 바꾼 시각 — 동기화 때 "나중에 바꾼 쪽이 이긴다"에 쓴다
    private(set) var equippedChangedAt: Date = .distantPast

    /// 레벨·게이지에 쓸 토큰 — 이 PC만 센 값과, 다른 PC까지 합친 값 중 큰 쪽
    var effectiveTokens: Int { max(localTokens, cloudTokenTotal ?? 0) }

    private enum UD {
        static let coins               = "shop.coins"
        static let owned               = "shop.owned"
        static let equipped            = "shop.equipped"              // 예전: 모든 캐릭터 공용
        static let equippedByCharacter = "shop.equippedByCharacter"   // 지금: 캐릭터별
        static let equippedChangedAt   = "shop.equippedChangedAt"
        static let deviceId            = "cloud.deviceId"
        static func baseline(_ uid: String) -> String { "cloud.baselineCoins.\(uid)" }
    }

    private init() {
        let d = UserDefaults.standard
        coins = d.integer(forKey: UD.coins)
        owned = Set(d.stringArray(forKey: UD.owned) ?? [])
        var loaded: [CharacterType: [ItemSlot: String]] = [:]
        let byCharacter = d.dictionary(forKey: UD.equippedByCharacter) as? [String: [String: String]] ?? [:]
        for (characterRaw, slots) in byCharacter {
            guard let character = CharacterType(rawValue: characterRaw) else { continue }
            loaded[character] = Dictionary(uniqueKeysWithValues: slots.compactMap { key, value in
                ItemSlot(rawValue: key).map { ($0, value) }
            })
        }
        // 캐릭터별로 나누기 전에 입혀둔 것이 있으면 모든 캐릭터에 한 번 그대로 옮겨준다
        if byCharacter.isEmpty, let legacy = d.dictionary(forKey: UD.equipped) as? [String: String], !legacy.isEmpty {
            let slots = Dictionary(uniqueKeysWithValues: legacy.compactMap { key, value in
                ItemSlot(rawValue: key).map { ($0, value) }
            })
            for character in CharacterType.allCases { loaded[character] = slots }
        }
        equipped = loaded
        if let t = d.object(forKey: UD.equippedChangedAt) as? Date { equippedChangedAt = t }
        retireRemovedItems()
        refreshLevel()   // 토큰 집계는 파일을 훑으므로 백그라운드에서
    }

    // MARK: - 클라우드 동기화 연결

    /// 이 기기를 구분하는 고정 ID — 기기별 토큰을 따로 적는 데 쓴다 (개인 정보가 아니다)
    var deviceId: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: UD.deviceId) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: UD.deviceId)
        return id
    }

    private static func monthKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// 합치기에 넘길 이 기기의 현재 상태
    func syncState() -> LocalState {
        var raw: [String: [String: String]] = [:]
        for (character, slots) in equipped {
            raw[character.rawValue] = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value) })
        }
        return LocalState(coins: coins, owned: owned, equipped: raw, equippedChangedAt: equippedChangedAt,
                          deviceId: deviceId, month: Self.monthKey(), monthTokens: localTokens)
    }

    func baselineCoins(for uid: String) -> Int? {
        UserDefaults.standard.object(forKey: UD.baseline(uid)) as? Int
    }

    func forgetCloudBaseline(for uid: String) {
        UserDefaults.standard.removeObject(forKey: UD.baseline(uid))
        cloudTokenTotal = nil
        recomputeLevel()
    }

    /// 합친 결과를 이 기기에 반영한다. 바뀐 것만 대입해서 불필요한 갱신(→ 또 동기화)이 생기지 않게 한다.
    func applyCloud(_ doc: CloudDoc, tokensThisMonth: Int, uid: String) {
        if coins != doc.coins { coins = doc.coins }
        if owned != doc.owned { owned = doc.owned }

        var newEquipped: [CharacterType: [ItemSlot: String]] = [:]
        for (characterRaw, slots) in doc.equipped {
            guard let character = CharacterType(rawValue: characterRaw) else { continue }
            newEquipped[character] = Dictionary(uniqueKeysWithValues: slots.compactMap { key, value in
                ItemSlot(rawValue: key).map { ($0, value) }
            })
        }
        if equipped != newEquipped { equipped = newEquipped }
        if doc.equippedUpdatedAt > equippedChangedAt {
            equippedChangedAt = doc.equippedUpdatedAt
            UserDefaults.standard.set(equippedChangedAt, forKey: UD.equippedChangedAt)
        }

        // 다음 동기화 때 "그 사이 이 기기에서 늘고 준 코인"만 서버에 더하기 위한 기준값
        UserDefaults.standard.set(doc.coins, forKey: UD.baseline(uid))

        if cloudTokenTotal != tokensThisMonth { cloudTokenTotal = tokensThisMonth }
        recomputeLevel()
    }

    // MARK: - 판매 종료된 아이템 정리

    /// 상점에서 뺀 아이템 → 구매가. 이미 샀다면 환불하고 착용도 푼다.
    /// (init 안에서는 프로퍼티 옵저버가 안 불려서 저장은 직접 한다)
    private static let retiredItems: [String: Int] = ["phone": 140, "painting": 150]

    private func retireRemovedItems() {
        var refund = 0
        for (id, price) in Self.retiredItems where owned.contains(id) {
            owned.remove(id)
            refund += price
        }
        var cleaned = equipped
        for (character, slots) in cleaned {
            cleaned[character] = slots.filter { Self.retiredItems[$0.value] == nil }
        }
        let changed = refund > 0 || cleaned != equipped
        guard changed else { return }
        coins += refund
        equipped = cleaned
        let d = UserDefaults.standard
        d.set(coins, forKey: UD.coins)
        d.set(Array(owned), forKey: UD.owned)
        var raw: [String: [String: String]] = [:]
        for (character, slots) in equipped {
            raw[character.rawValue] = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value) })
        }
        d.set(raw, forKey: UD.equippedByCharacter)
    }

    // MARK: - 레벨

    /// 이번 달 누적 토큰을 다시 읽어 레벨을 갱신한다 (파일을 훑으므로 백그라운드)
    func refreshLevel() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tokens = TokenUsageReader.readThisMonth()
            DispatchQueue.main.async { self?.updateLevel(fromTokens: tokens) }
        }
    }

    /// 이미 집계된 토큰 수로 레벨을 갱신 (EventMonitor가 5분마다 집계한 값을 재사용)
    func updateLevel(fromTokens tokens: Int) {
        localTokens = tokens
        recomputeLevel()
    }

    private func recomputeLevel() {
        let newLevel = effectiveTokens / 500_000 + 1
        if level != newLevel { level = newLevel }
    }

    // MARK: - 코인

    /// 작업 완료 — 코인을 준다 (EventMonitor의 완료 처리에서 호출)
    func rewardCompletion() {
        coins += Self.coinsPerCompletion
    }

    // MARK: - 구매 / 착용

    /// 자리마다 "아무것도 안 골랐을 때 쓰는 기본 아이템" — 무료이고 항상 보유 상태다.
    /// 작업 도구는 노트북, 무기는 당근(권한 요청·완료 때 드는 원래 소품).
    static let defaultItem: [ItemSlot: String] = [.tool: "laptop", .weapon: "carrot"]

    func isDefault(_ item: ShopItem) -> Bool { Self.defaultItem[item.slot] == item.id }

    func isOwned(_ item: ShopItem) -> Bool { item.price == 0 || owned.contains(item.id) }

    /// 기본 당근 대신 다른 무기를 들고 있는지 — 캐릭터 뷰가 당근을 그릴지 정할 때 쓴다
    func hasCustomWeapon(for character: CharacterType) -> Bool {
        equipped[character]?[.weapon] != nil
    }
    func isEquipped(_ item: ShopItem, for character: CharacterType) -> Bool {
        // 아무것도 안 골랐으면 그 자리의 기본 아이템(노트북·당근)을 쓰는 중이다
        if equipped[character]?[item.slot] == nil, let def = Self.defaultItem[item.slot] {
            return item.id == def
        }
        return equipped[character]?[item.slot] == item.id
    }
    /// 레벨이 모자라면 살 수 없다
    func isUnlocked(_ item: ShopItem) -> Bool { level >= item.level }
    func canBuy(_ item: ShopItem) -> Bool {
        !isOwned(item) && isUnlocked(item) && coins >= item.price
    }

    /// 구매는 공용 — 한 번 사면 어느 캐릭터든 입힐 수 있다.
    /// 사면 지금 꾸미고 있던 캐릭터에게 바로 입혀준다.
    @discardableResult
    func buy(_ item: ShopItem, equipFor character: CharacterType) -> Bool {
        guard canBuy(item) else { return false }
        coins -= item.price
        owned.insert(item.id)
        equipped[character, default: [:]][item.slot] = item.id
        markEquippedChanged()
        return true
    }

    private func markEquippedChanged() {
        equippedChangedAt = Date()
        UserDefaults.standard.set(equippedChangedAt, forKey: UD.equippedChangedAt)
    }

    func toggleEquip(_ item: ShopItem, for character: CharacterType) {
        guard isOwned(item) else { return }
        if isDefault(item) {                           // 기본 아이템을 고르면 = 선택을 푸는 것
            equipped[character]?.removeValue(forKey: item.slot)
            return
        }
        if equipped[character]?[item.slot] == item.id {
            equipped[character]?.removeValue(forKey: item.slot)
        } else {
            equipped[character, default: [:]][item.slot] = item.id
        }
        markEquippedChanged()
    }

    func equippedItem(in slot: ItemSlot, for character: CharacterType) -> ShopItem? {
        guard let id = equipped[character]?[slot] else { return nil }
        return ShopCatalog.item(id)
    }
}

// MARK: - 상품 목록

enum ShopCatalog {
    static let items: [ShopItem] = [
        // ── 머리
        ShopItem(id: "straw_hat",  nameKo: "밀짚모자",     nameEn: "Straw hat",    slot: .head, level: 1, price: 40),
        ShopItem(id: "wizard_hat", nameKo: "마법사 모자",  nameEn: "Wizard hat",   slot: .head, level: 3, price: 120),
        ShopItem(id: "crown",      nameKo: "황금 왕관",    nameEn: "Golden crown", slot: .head, level: 6, price: 300),
        ShopItem(id: "halo",        nameKo: "천사링",        nameEn: "Angel halo",    slot: .head, level: 4, price: 200),
        ShopItem(id: "devil_horns", nameKo: "악마 뿔",       nameEn: "Devil horns",   slot: .head, level: 4, price: 200),
        ShopItem(id: "fire_helmet", nameKo: "소방 헬멧",     nameEn: "Fire helmet",   slot: .head, level: 3, price: 130),
        ShopItem(id: "police_cap",  nameKo: "경찰 모자",     nameEn: "Police cap",    slot: .head, level: 3, price: 130),
        // ── 얼굴
        ShopItem(id: "glasses",    nameKo: "동그란 안경",  nameEn: "Round glasses", slot: .face, level: 1, price: 50),
        ShopItem(id: "shades",     nameKo: "선글라스",     nameEn: "Sunglasses",    slot: .face, level: 4, price: 150),
        // ── 옷
        ShopItem(id: "stripe_tee", nameKo: "줄무늬 티셔츠", nameEn: "Striped tee",  slot: .outfit, level: 1, price: 70),
        ShopItem(id: "hoodie",     nameKo: "후드티",        nameEn: "Hoodie",        slot: .outfit, level: 2, price: 110),
        ShopItem(id: "tuxedo",     nameKo: "턱시도",        nameEn: "Tuxedo",        slot: .outfit, level: 3, price: 160),
        ShopItem(id: "armor",      nameKo: "기사 갑옷",     nameEn: "Knight armor",  slot: .outfit, level: 5, price: 260),
        ShopItem(id: "robe",       nameKo: "마법사 로브",   nameEn: "Wizard robe",   slot: .outfit, level: 7, price: 380),
        ShopItem(id: "school_uniform", nameKo: "학교 교복",     nameEn: "School uniform",  slot: .outfit, level: 2, price: 120),
        ShopItem(id: "business_suit",  nameKo: "사업가 정장",   nameEn: "Business suit",   slot: .outfit, level: 3, price: 170),
        ShopItem(id: "firefighter",    nameKo: "소방관 방화복", nameEn: "Firefighter gear",slot: .outfit, level: 4, price: 220),
        ShopItem(id: "police",         nameKo: "경찰 제복",     nameEn: "Police uniform",  slot: .outfit, level: 4, price: 220),
        ShopItem(id: "angel_gown",     nameKo: "천사 가운",     nameEn: "Angel gown",      slot: .outfit, level: 6, price: 320),
        ShopItem(id: "devil_suit",     nameKo: "악마 정장",     nameEn: "Devil suit",      slot: .outfit, level: 6, price: 320),
        // ── 등
        ShopItem(id: "cape",       nameKo: "빨간 망토",    nameEn: "Red cape",      slot: .back, level: 2, price: 90),
        ShopItem(id: "wings",      nameKo: "천사 날개",    nameEn: "Angel wings",   slot: .back, level: 8, price: 500),
        ShopItem(id: "devil_wings", nameKo: "악마 날개",     nameEn: "Devil wings",   slot: .back, level: 8, price: 500),
        // ── 무기 (작업 중에만 손에 든다)
        ShopItem(id: "carrot",     nameKo: "당근 (기본)",  nameEn: "Carrot (default)", slot: .weapon, level: 1, price: 0),
        ShopItem(id: "wood_sword", nameKo: "나무 검",      nameEn: "Wooden sword",  slot: .weapon, level: 1, price: 60),
        ShopItem(id: "steel_sword",nameKo: "강철 검",      nameEn: "Steel sword",   slot: .weapon, level: 4, price: 180),
        ShopItem(id: "staff",      nameKo: "마법 지팡이",  nameEn: "Magic staff",   slot: .weapon, level: 6, price: 280),
        ShopItem(id: "flame_sword",nameKo: "불꽃 대검",    nameEn: "Flame greatsword", slot: .weapon, level: 10, price: 700),
        ShopItem(id: "baton",     nameKo: "경찰봉",     nameEn: "Police baton",slot: .weapon, level: 2, price: 100),
        ShopItem(id: "fire_axe",  nameKo: "소방 도끼",  nameEn: "Fire axe",    slot: .weapon, level: 5, price: 240),
        ShopItem(id: "trident",   nameKo: "삼지창",     nameEn: "Trident",     slot: .weapon, level: 7, price: 360),
        // ── 작업 도구 (작업 중에 노트북 대신)
        ShopItem(id: "laptop",       nameKo: "노트북 (기본)",   nameEn: "Laptop (default)", slot: .tool, level: 1, price: 0),
        ShopItem(id: "book_writing", nameKo: "책 쓰기 (깃펜)",  nameEn: "Writing a book",   slot: .tool, level: 2, price: 100),
        ShopItem(id: "knitting",     nameKo: "뜨개질",          nameEn: "Knitting",         slot: .tool, level: 2, price: 100),
        ShopItem(id: "gamepad",      nameKo: "휴대용 게임기",   nameEn: "Handheld game",    slot: .tool, level: 3, price: 150),
    ]

    static func item(_ id: String) -> ShopItem? { items.first { $0.id == id } }
    static func items(in slot: ItemSlot) -> [ShopItem] { items.filter { $0.slot == slot } }
}
