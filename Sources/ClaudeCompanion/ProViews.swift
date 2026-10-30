import SwiftUI
import AppKit

// MARK: - 잠긴 기능 안내

extension ProManager {
    /// 잠긴 캐릭터·테마를 눌렀을 때 보여줄 안내
    func itemLockMessage(_ itemID: String) -> String {
        if let pack = Self.packs.first(where: { $0.items.contains(itemID) }), !pack.proOnly {
            return L.t("\(pack.name)은(는) Pro이거나 개별 구매하면 쓸 수 있어요.",
                       "\(pack.name) unlocks with Pro or as a one-time purchase.")
        }
        return L.t("이 꾸미기는 Pro 전용이에요. 업그레이드하면 바로 쓸 수 있어요.",
                   "This cosmetic is Pro-only. Upgrade to unlock it.")
    }

    /// 키 등록 실패 코드를 사람이 읽을 문장으로
    static func activationMessage(_ reason: String) -> String {
        switch reason {
        case "format":    return L.t("키 형식이 올바르지 않아요. BUNI-로 시작하는 키를 통째로 붙여 넣어 주세요.",
                                     "That doesn't look like a Buni key. Paste the whole key starting with BUNI-.")
        case "signature": return L.t("키를 확인하지 못했어요. 바뀌었거나 다른 키일 수 있어요.",
                                     "Couldn't verify this key. It may be altered or not a Buni key.")
        case "expired":   return L.t("이미 만료된 키예요.", "This key has expired.")
        case "no_pubkey": return L.t("아직 라이선스 확인 준비가 안 된 빌드예요.",
                                     "This build isn't set up to verify license keys yet.")
        default:          return L.t("키를 등록하지 못했어요.", "Couldn't activate the key.")
        }
    }
}

/// 잠긴 기능을 눌렀을 때: 안내 문구와 함께 업그레이드 화면을 연다.
enum ProGate {
    /// Pro 가 아니면 업그레이드 화면을 띄우고 false. 호출하는 쪽은 false 면 기능을 실행하지 않는다.
    @discardableResult
    static func require(_ feature: ProFeature) -> Bool {
        if ProManager.shared.can(feature) { return true }
        DispatchQueue.main.async { ProUpgradeWindow.show(reason: feature.lockMessage) }
        return false
    }
}

// MARK: - 업그레이드 창

enum ProUpgradeWindow {
    private static var window: NSWindow?

    static func show(reason: String? = nil) {
        let host = NSHostingController(rootView: ProUpgradeView(reason: reason))
        if let win = window, win.isVisible {
            win.contentViewController = host
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 440, height: 640))
        win.contentMinSize = NSSize(width: 400, height: 460)
        win.title = L.t("부니 Pro", "Buni Pro")
        win.backgroundColor = NSColor(BT.bgCanvas)
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct ProUpgradeView: View {
    var reason: String?

    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var lang = LanguageStore.shared
    @State private var keyText = ""
    @State private var message: String?
    @State private var messageIsError = false

    private let accent = Color(red: 0.98, green: 0.72, blue: 0.30)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let reason {
                    Text("🔒 " + reason)
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.12)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                featureList
                Divider().background(Color.white.opacity(0.2))
                plans
                Divider().background(Color.white.opacity(0.2))
                licenseField
                Divider().background(Color.white.opacity(0.2))
                packList
                Text(L.t("무료 기능(세션 패널·상태 표시·채팅·기본 캐릭터)은 Pro가 없어도 그대로 쓸 수 있어요. 앱은 사용 정보를 수집하지 않아요.",
                         "Free features (session panels, status, chat, base characters) keep working without Pro. The app collects no usage data."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 400, minHeight: 460)
        .background(BT.bgCanvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⭐ " + L.t("부니 Pro", "Buni Pro"))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(pro.status().summary)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ProFeature.allCases, id: \.self) { f in
                HStack(spacing: 8) {
                    Text(pro.can(f) ? "✅" : "🔒").font(.system(size: 11))
                    Text(f.title).font(.system(size: 12)).foregroundColor(.white.opacity(0.9))
                }
            }
        }
    }

    // MARK: 플랜

    private var plans: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("플랜", "Plans"))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            planRow("monthly",  L.t("월간", "Monthly"),  L.t("매달", "per month"))
            planRow("yearly",   L.t("연간", "Yearly"),   L.t("1년 · 약 33% 저렴", "per year · ~33% less"))
            planRow("lifetime", L.t("평생", "Lifetime"), L.t("한 번 결제", "one-time"))
        }
    }

    private func planRow(_ plan: String, _ name: String, _ note: String) -> some View {
        let btn = pro.checkoutButton(plan)
        let price = ProManager.formatUSD(ProManager.planPriceCents[plan] ?? 0)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name)  \(price)").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text(note).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Button(btn.label) { if let u = btn.url { NSWorkspace.shared.open(u) } }
                .buttonStyle(PillButtonStyle(color: btn.enabled ? .accentColor : .gray))
                .disabled(!btn.enabled)
        }
    }

    // MARK: 라이선스 키

    private var licenseField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("라이선스 키", "License key"))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            HStack(spacing: 8) {
                TextField("BUNI-…", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                Button(L.t("등록", "Activate")) { activate() }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(messageIsError ? BT.danger : BT.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activate() {
        let r = pro.activate(keyText)
        if r.ok {
            message = L.t("등록됐어요! 고마워요 🐰", "Activated! Thank you 🐰")
            messageIsError = false
            keyText = ""
        } else {
            message = ProManager.activationMessage(r.reason)
            messageIsError = true
        }
    }

    // MARK: 코스메틱 팩

    private var packList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("꾸미기 팩", "Cosmetic packs"))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            ForEach(ProManager.packs) { pack in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.name).font(.system(size: 12)).foregroundColor(.white)
                        Text(packNote(pack)).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    if !pack.proOnly {
                        let btn = pro.checkoutButton("pack:" + pack.id)
                        Button(btn.enabled ? L.t("구매", "Buy") : btn.label) {
                            if let u = btn.url { NSWorkspace.shared.open(u) }
                        }
                        .buttonStyle(PillButtonStyle(color: btn.enabled ? .accentColor : .gray))
                        .disabled(!btn.enabled)
                    }
                }
            }
        }
    }

    private func packNote(_ pack: CosmeticPack) -> String {
        if pack.proOnly { return L.t("Pro 전용 · 구독하면 포함", "Pro only · included with Pro") }
        guard let cents = pro.packPriceCents(pack.id) else { return "" }
        let owned = pro.ownedPacks().contains(pack.id) ? L.t(" · 보유 중", " · owned") : ""
        let base = ProManager.formatUSD(cents)
        if case .subscribed = pro.status() {
            return base + L.t(" (Pro 할인 \(ProManager.proPackDiscountPercent)%)", " (Pro \(ProManager.proPackDiscountPercent)% off)") + owned
        }
        return base + L.t(" · Pro 회원은 \(ProManager.proPackDiscountPercent)% 할인", " · \(ProManager.proPackDiscountPercent)% off for Pro") + owned
    }
}

// MARK: - 첫 실행 안내

enum OnboardingWindow {
    private static var window: NSWindow?

    /// 한 번도 안내를 보지 않았을 때만 연다
    static func showIfNeeded() {
        guard !ProManager.shared.onboardingDone else { return }
        show()
    }

    static func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView {
            ProManager.shared.markOnboarded()
            window?.close()
        }))
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 420, height: 420))
        win.title = L.t("부니에 오신 걸 환영해요", "Welcome to Buni")
        win.backgroundColor = NSColor(BT.bgCanvas)
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct OnboardingView: View {
    var onDone: () -> Void

    @ObservedObject private var lang = LanguageStore.shared
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                switch page {
                case 0:
                    step("🐰", L.t("안녕, 나는 부니야!", "Hi, I'm Buni!"),
                         L.t("Claude Code 세션마다 화면 한쪽에 나타나서 지금 뭘 하는지 알려줄게요. 생각 중, 도구 사용, 완료까지 한눈에 볼 수 있어요.",
                             "I show up beside each Claude Code session and tell you what it's doing — thinking, using tools, or done."))
                case 1:
                    step("🎛", L.t("메뉴바에서 다 할 수 있어요", "Everything lives in the menu bar"),
                         L.t("메뉴바의 토끼 아이콘에서 상점, 채팅, 설정을 열 수 있어요. 부니를 오른쪽 클릭하면 캐릭터도 바꿀 수 있어요.",
                             "Open the shop, chat and settings from the rabbit icon in the menu bar. Right-click Buni to change characters."))
                default:
                    let days = ProManager.shared.status()
                    step("⭐", L.t("Pro 체험 중이에요", "You're on a Pro trial"),
                         L.t("지금은 모든 Pro 기능을 써볼 수 있어요 (\(days.summary)). 체험이 끝나도 기존 기능은 계속 무료예요.",
                             "Every Pro feature is open for now (\(days.summary)). Existing features stay free after the trial."))
                }
            }
            Spacer()
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        Circle().fill(Color.white.opacity(i == page ? 0.9 : 0.25)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if page < 2 {
                    Button(L.t("건너뛰기", "Skip")) { onDone() }
                        .buttonStyle(PillButtonStyle(color: .gray))
                    Button(L.t("다음", "Next")) { page += 1 }
                        .buttonStyle(PillButtonStyle(color: .accentColor))
                } else {
                    Button(L.t("Pro 알아보기", "See Pro")) { onDone(); ProUpgradeWindow.show() }
                        .buttonStyle(PillButtonStyle(color: .gray))
                    Button(L.t("시작하기", "Get started")) { onDone() }
                        .buttonStyle(PillButtonStyle(color: .accentColor))
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 420)
        .background(BT.bgCanvas)
    }

    private func step(_ icon: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(icon).font(.system(size: 48))
            Text(title).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            Text(body)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 설정 화면의 Pro 구역

struct ProSettingsSection: View {
    @ObservedObject private var pro = ProManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("부니 Pro", "Buni Pro"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text(pro.status().summary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
            HStack(spacing: 8) {
                Button(L.t("플랜 보기 · 키 등록", "Plans & license key")) { ProUpgradeWindow.show() }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                Button(L.t("처음 안내 다시 보기", "Replay intro")) { OnboardingWindow.show() }
                    .buttonStyle(PillButtonStyle(color: .gray))
            }
        }
    }
}
