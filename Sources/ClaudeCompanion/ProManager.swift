import Foundation
import Combine

/// Pro 로 잠그는 기능. 기존 무료 기능(세션 패널·상태 표시·채팅·기본 캐릭터/테마)은 여기 없다.
enum ProFeature: String, CaseIterable {
    case squadSchedule      = "squad_schedule"
    case squadParallel      = "squad_parallel"
    case premiumCharacters  = "premium_characters"
    case premiumThemes      = "premium_themes"
    case cloudSync          = "cloud_sync"

    var title: String {
        switch self {
        case .squadSchedule:     return L.t("스쿼드 업무 예약", "Squad scheduled tasks")
        case .squadParallel:     return L.t("스쿼드 병렬 실행", "Squad parallel runs")
        case .premiumCharacters: return L.t("프리미엄 캐릭터", "Premium characters")
        case .premiumThemes:     return L.t("프리미엄 테마", "Premium themes")
        case .cloudSync:         return L.t("클라우드 동기화", "Cloud sync")
        }
    }

    /// 잠긴 기능을 눌렀을 때 보여줄 안내
    var lockMessage: String {
        L.t("\(title)은(는) Pro 기능이에요. 업그레이드하면 바로 쓸 수 있어요.",
            "\(title) is a Pro feature. Upgrade to unlock it.")
    }
}

enum ProStatus: Equatable {
    case subscribed(plan: String, expires: String?)  // 유효한 Pro 키 보유
    case trial(daysLeft: Int)                        // 무료 체험 중 (Pro 기능 사용 가능)
    case expired                                     // 체험 끝 — 무료 기능만

    var isPro: Bool { self != .expired }

    /// 상태 한 줄 요약
    var summary: String {
        switch self {
        case .subscribed(_, let expires):
            if let e = expires, e.count == 8 {
                let d = "\(e.prefix(4))-\(e.dropFirst(4).prefix(2))-\(e.suffix(2))"
                return L.t("Pro 구독 중 · \(d)까지", "Pro active · until \(d)")
            }
            return L.t("Pro 평생 이용권", "Pro lifetime")
        case .trial(let days):
            return L.t("Pro 체험 중 · \(days)일 남았어요", "Pro trial · \(days) day(s) left")
        case .expired:
            return L.t("무료 버전 · Pro 체험이 끝났어요", "Free · Pro trial ended")
        }
    }
}

/// 개별 판매 / Pro 전용 코스메틱 팩. 아이템 id 는 새로 추가하는 캐릭터·테마의 이름표다 — 기존 것은 무료.
struct CosmeticPack: Identifiable {
    let id: String
    let nameKo: String
    let nameEn: String
    let items: [String]
    /// 개별 판매가(센트). Pro 전용 팩은 0
    let priceCents: Int
    /// true 면 Pro 회원에게만 열리고 따로 팔지 않는다
    let proOnly: Bool

    var name: String { L.t(nameKo, nameEn) }
}

/// 부니 Pro — 체험·구독 상태, 잠금 게이트, 결제 링크, 팩 가격 (windows/buni_pro.py 와 같은 규칙).
///
/// 저장: ~/Library/Application Support/Buni/pro.json, 설정: 같은 폴더의 pro-config.json
///       {"stripe_links": {"monthly": "https://…", "yearly": …, "lifetime": …, "pack:sakura": …}}
final class ProManager: ObservableObject {
    static let shared = ProManager()

    // MARK: 가정 값 — 바꾸려면 여기 숫자만 고친다
    static let trialDaysExisting = 30        // [가정-A] 기존 사용자 Pro 체험 일수
    static let trialDaysNew = 14             // [가정-B] 신규 사용자 Pro 체험 일수
    static let proPackDiscountPercent = 30   // [가정-F] Pro 회원의 개별 팩 할인율

    static let planPriceCents = ["monthly": 300, "yearly": 2400, "lifetime": 4900]
    static let stripePlans = ["monthly", "yearly", "lifetime"]
    private static let stripeEnv = [
        "monthly": "BUNI_STRIPE_LINK_MONTHLY",
        "yearly": "BUNI_STRIPE_LINK_YEARLY",
        "lifetime": "BUNI_STRIPE_LINK_LIFETIME",
    ]

    static let packs: [CosmeticPack] = [
        CosmeticPack(id: "pro_colors", nameKo: "프로 컬러 캐릭터", nameEn: "Pro color characters",
                     items: ["rabbit_mint", "rabbit_lavender", "rabbit_midnight"], priceCents: 0, proOnly: true),
        CosmeticPack(id: "pro_themes", nameKo: "프로 테마", nameEn: "Pro themes",
                     items: ["theme_midnight", "theme_sunset"], priceCents: 0, proOnly: true),
        CosmeticPack(id: "sakura", nameKo: "벚꽃 팩", nameEn: "Sakura pack",
                     items: ["theme_sakura", "rabbit_sakura"], priceCents: 299, proOnly: false),
        CosmeticPack(id: "space", nameKo: "우주 팩", nameEn: "Space pack",
                     items: ["theme_space", "rabbit_astronaut"], priceCents: 349, proOnly: false),
        CosmeticPack(id: "cafe", nameKo: "카페 팩", nameEn: "Cafe pack",
                     items: ["theme_cafe", "rabbit_barista"], priceCents: 399, proOnly: false),
    ]

    private let directory: URL
    private let publicKey: Data?
    private let clock: () -> Date
    private var data: [String: Any]

    /// 테스트·미리보기에서는 폴더·공개키·시계를 바꿔 끼울 수 있다.
    init(directory: URL? = nil, publicKey: Data? = nil, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buni", isDirectory: true)
        self.publicKey = publicKey
        self.clock = clock
        self.data = [:]
        self.data = load()
        ensureTrialStarted()
    }

    // MARK: - 저장

    private var file: URL { directory.appendingPathComponent("pro.json") }

    private func load() -> [String: Any] {
        guard let raw = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let raw = try? JSONSerialization.data(withJSONObject: data) {
            try? raw.write(to: file, options: .atomic)
        }
    }

    /// 첫 실행이면 체험을 시작한다. 이미 쓰던 사용자(앱 설정이 남아 있음)는 30일, 아니면 14일.
    private func ensureTrialStarted() {
        if data["trial_start"] is NSNumber { return }
        let existing: Bool
        if let id = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: id) {
            existing = !domain.isEmpty
        } else {
            existing = false
        }
        data["trial_start"] = clock().timeIntervalSince1970
        data["trial_days"] = existing ? Self.trialDaysExisting : Self.trialDaysNew
        data["was_existing_user"] = existing
        save()
    }

    var wasExistingUser: Bool { data["was_existing_user"] as? Bool ?? false }

    // MARK: - 라이선스

    private var storedKeys: [String] { data["licenses"] as? [String] ?? [] }

    private func validLicenses(_ now: Date) -> [LicenseResult] {
        storedKeys.map { ProLicense.verify($0, publicKey: publicKey, now: now) }.filter { $0.valid }
    }

    /// 키를 등록한다. 실패하면 reason 코드("format"·"signature"·"expired"·"no_pubkey")를 돌려준다.
    @discardableResult
    func activate(_ key: String) -> (ok: Bool, reason: String) {
        let r = ProLicense.verify(key, publicKey: publicKey, now: clock())
        guard r.valid else { return (false, r.reason) }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = storedKeys
        if !keys.contains(trimmed) {
            keys.append(trimmed)
            data["licenses"] = keys
            save()
        }
        objectWillChange.send()
        return (true, "")
    }

    func removeLicenses() {
        data["licenses"] = [String]()
        save()
        objectWillChange.send()
    }

    // MARK: - 상태

    func status(now: Date? = nil) -> ProStatus {
        let now = now ?? clock()
        let pros = validLicenses(now).filter { $0.isPro }
        if !pros.isEmpty {
            // 평생(만료 없음)이 있으면 그것을, 아니면 가장 늦게 끝나는 키를 보여준다
            var best = pros[0]
            for r in pros {
                if r.expires == nil { best = r; break }
                if let e = r.expires, e > (best.expires ?? "") { best = r }
            }
            return .subscribed(plan: best.plan, expires: best.expires)
        }
        let start = (data["trial_start"] as? NSNumber)?.doubleValue ?? now.timeIntervalSince1970
        let days = (data["trial_days"] as? NSNumber)?.doubleValue ?? Double(Self.trialDaysNew)
        let left = start + days * 86400 - now.timeIntervalSince1970
        return left > 0 ? .trial(daysLeft: Int(ceil(left / 86400))) : .expired
    }

    var isPro: Bool { status().isPro }

    func ownedPacks(now: Date? = nil) -> Set<String> {
        Set(validLicenses(now ?? clock()).compactMap { $0.packID })
    }

    // MARK: - 잠금 게이트

    func can(_ feature: ProFeature) -> Bool { isPro }

    /// 캐릭터·테마 id 를 쓸 수 있는가. 팩에 속하지 않은 기존 것은 항상 무료.
    func itemUnlocked(_ itemID: String) -> Bool {
        guard let pack = Self.packs.first(where: { $0.items.contains(itemID) }) else { return true }
        if isPro { return true }   // Pro(체험 포함)는 모든 팩을 쓴다
        return !pack.proOnly && ownedPacks().contains(pack.id)
    }

    /// 클라우드 동기화 정책 [가정-G]: "allow" · "pause_keep_data"(이미 쓰던 사용자 — 멈추기만 하고 데이터는 그대로) · "blocked"(새로 켜기 불가)
    func cloudSyncPolicy(alreadySyncing: Bool) -> String {
        if can(.cloudSync) { return "allow" }
        return alreadySyncing ? "pause_keep_data" : "blocked"
    }

    /// 동기화를 한 번이라도 한 사용자인가 — 체험이 끝나도 데이터는 지우지 않고 멈추기만 한다
    var cloudWasSyncing: Bool { data["cloud_synced"] as? Bool ?? false }

    func markCloudSynced() {
        guard !cloudWasSyncing else { return }
        data["cloud_synced"] = true
        save()
    }

    /// 지금 동기화를 돌려도 되는가 (로그인 상태이면 이미 쓰던 사용자로 본다)
    func cloudSyncPolicy() -> String { cloudSyncPolicy(alreadySyncing: cloudWasSyncing) }

    // MARK: - 첫 실행 안내

    var onboardingDone: Bool { data["onboarded"] as? Bool ?? false }

    func markOnboarded() {
        data["onboarded"] = true
        save()
    }

    // MARK: - 팩 가격

    /// 개별 판매 팩의 가격(센트). Pro 구독자는 할인(센트 반올림). 판매하지 않는 팩은 nil.
    func packPriceCents(_ packID: String) -> Int? {
        guard let p = Self.packs.first(where: { $0.id == packID }), !p.proOnly else { return nil }
        if case .subscribed = status() {
            return (p.priceCents * (100 - Self.proPackDiscountPercent) + 50) / 100
        }
        return p.priceCents
    }

    static func formatUSD(_ cents: Int) -> String {
        let rest = cents % 100
        return "$\(cents / 100)." + (rest < 10 ? "0\(rest)" : "\(rest)")
    }

    // MARK: - 결제 링크

    private func configLinks() -> [String: Any] {
        let url = directory.appendingPathComponent("pro-config.json")
        guard let raw = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let links = obj["stripe_links"] as? [String: Any]
        else { return [:] }
        return links
    }

    /// https 링크만 인정한다. 비었거나 이상하면 nil → 버튼은 "준비 중".
    private static func clean(_ value: Any?) -> URL? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("https://"), s.count > "https://x".count, !s.contains(" ")
        else { return nil }
        return URL(string: s)
    }

    /// plan: monthly · yearly · lifetime · "pack:<id>". 환경변수 → 설정 파일 순서.
    func checkoutLink(_ plan: String) -> URL? {
        let envName: String
        if plan.hasPrefix("pack:") {
            envName = "BUNI_STRIPE_LINK_PACK_" + plan.dropFirst(5).uppercased()
        } else if let name = Self.stripeEnv[plan] {
            envName = name
        } else {
            return nil
        }
        if let url = Self.clean(ProcessInfo.processInfo.environment[envName]) { return url }
        return Self.clean(configLinks()[plan])
    }

    /// 업그레이드 버튼 표시용. 링크가 없으면 비활성 + "준비 중".
    func checkoutButton(_ plan: String) -> (enabled: Bool, url: URL?, label: String) {
        if let url = checkoutLink(plan) { return (true, url, L.t("구독하기", "Subscribe")) }
        return (false, nil, L.t("준비 중", "Coming soon"))
    }
}
