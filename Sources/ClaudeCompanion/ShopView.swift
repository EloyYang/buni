import SwiftUI

/// 부니 상점 창 — 위에서 입혀보고, 아래에서 사고 입는다.
struct ShopView: View {
    @ObservedObject private var shop = ShopStore.shared
    /// 미리보기용 컨트롤러 — 실제 세션과 무관하게 지금 착용 상태를 그대로 보여준다
    @StateObject private var preview = CompanionController()
    @ObservedObject private var cloud = CloudSession.shared

    @State private var slot: ItemSlot = .head
    @State private var mode: PreviewMode = .idle
    /// 사지 않은 아이템을 미리 입어보는 중인 것 (자리 → 아이템). 미리보기에만 보이고 저장되지 않는다.
    @State private var tryOn: [ItemSlot: String] = [:]
    /// 지금 꾸미고 있는 캐릭터 — 착용은 캐릭터마다 따로 저장된다
    @State private var target: CharacterType = CharacterStore.shared.selected

    var body: some View {
        VStack(spacing: 0) {
            header
            characterPicker
            previewArea
            equippedSummary
            Divider().background(Color.white.opacity(0.15))
            slotPicker
            itemList
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            preview.character = target
            preview.state = .ready
            shop.refreshLevel()
        }
        .onChange(of: target) { newTarget in
            preview.character = newTarget
            tryOn = [:]                         // 입어보던 것은 그 캐릭터의 미리보기였다
        }
        // 탭을 넘기면 그 자리에 어울리는 모션으로 — 무기는 완료(들어 올린 모습), 작업 도구는 작업 중
        .onChange(of: slot) { mode = Self.previewMode(for: $0) }
    }

    /// 자리별로 가장 잘 보이는 모션 — 무기는 완료 때 들어 올린 모습, 작업 도구는 작업 중,
    /// 나머지(모자·안경·옷·등)는 가려지는 게 없는 대기 모습
    private static func previewMode(for slot: ItemSlot) -> PreviewMode {
        switch slot {
        case .weapon: return .done
        case .tool:   return .working
        default:      return .idle
        }
    }

    /// 미리보기에 실제로 보여줄 아이템 — 입어보는 것이 실제 착용보다 우선한다
    private func displayedItems() -> [ItemSlot: String] {
        var shown: [ItemSlot: String] = [:]
        for slot in ItemSlot.allCases {
            if let id = tryOn[slot] ?? shop.equipped[target]?[slot] { shown[slot] = id }
        }
        return shown
    }

    /// 행을 누르거나 `입어보기`를 눌렀을 때 — 이미 입어보는 중이면 취소
    private func tryOnItem(_ item: ShopItem) {
        if tryOn[item.slot] == item.id { tryOn.removeValue(forKey: item.slot) }
        else { tryOn[item.slot] = item.id }
        mode = Self.previewMode(for: item.slot)
    }

    /// 착용·해제·구매로 실제 상태가 바뀌었을 때 — 입어보기를 거두고 그 모습을 바로 보여준다
    private func settle(_ item: ShopItem) {
        tryOn.removeValue(forKey: item.slot)
        mode = Self.previewMode(for: item.slot)
    }

    // MARK: 캐릭터 선택

    private var characterPicker: some View {
        HStack(spacing: 6) {
            ForEach(CharacterType.allCases, id: \.self) { type in
                Button { target = type } label: {
                    Text(type.shortName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(target == type ? Color.accentColor.opacity(0.85)
                                                 : Color.white.opacity(0.07)))
                        .foregroundColor(.white.opacity(target == type ? 1 : 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    // MARK: 머리말 — 코인과 레벨

    private var header: some View {
        HStack {
            Text(L.t("부니 상점", "Buni Shop"))
                .font(.system(size: 15, weight: .bold))
            Spacer()
            if cloud.isConfigured {
                // 선택 기능 — 로그인하면 다른 PC에서도 같은 설정·레벨이 이어진다
                if cloud.isSignedIn {
                    Text(L.t("☁️ 연동됨", "☁️ Synced"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.30, green: 0.78, blue: 0.50))
                        .padding(.trailing, 10)
                } else {
                    Button(L.t("☁️ 다른 PC와 연동", "☁️ Sync")) { Task { await cloud.signIn() } }
                        .buttonStyle(PillButtonStyle(color: .gray))
                        .padding(.trailing, 8)
                }
            }
            Label("\(shop.coins)", systemImage: "circle.fill")
                .labelStyle(CoinLabelStyle())
            Text("★ Lv.\(shop.level)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.95, green: 0.80, blue: 0.15))
                .padding(.leading, 10)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: 미리보기

    private var previewArea: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
            characterPreview
                .environment(\.tryOn, TryOnItems(items: displayedItems()))
                .environmentObject(preview)
                .frame(width: 60, height: 70)
                .scaleEffect(1.9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 무기·작업 도구는 상태에 따라 보이니, 대기·작업 중·완료 모습을 골라 볼 수 있게 한다
            Picker("", selection: $mode) {
                ForEach(PreviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 190)
            .padding(10)
            .onChange(of: mode) { preview.state = $0.state }
        }
        .frame(height: 170)
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    @ViewBuilder
    private var characterPreview: some View {
        switch preview.character {
        case .rabbit:        RabbitCharacterView()
        case .brownRabbit:   BrownRabbitCharacterView()
        case .pinkRabbit:    PinkRabbitCharacterView()
        case .orangeRabbit:  OrangeRabbitCharacterView()
        case .yellowRabbit:  YellowRabbitCharacterView()
        case .greenRabbit:   GreenRabbitCharacterView()
        }
    }

    // MARK: 지금 입은 것

    /// 이 캐릭터가 지금 착용 중인 아이템 — 탭을 넘겨 다니지 않아도 한눈에 보이게.
    /// 입어보는 중인 아이템은 (미리보기)로 구분해서 보여준다.
    private var equippedSummary: some View {
        let shown = displayedItems()
        let parts: [String] = ItemSlot.allCases.compactMap { slot in
            guard let id = shown[slot], let item = ShopCatalog.item(id),
                  !(shop.isDefault(item) && tryOn[slot] == nil) else { return nil }
            return tryOn[slot] == id ? item.name + L.t(" (미리보기)", " (preview)") : item.name
        }
        return HStack(spacing: 6) {
            Text(tryOn.isEmpty ? L.t("착용 중", "Wearing") : L.t("미리보기", "Preview"))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tryOn.isEmpty ? wearColor : tryColor)
            Text(parts.isEmpty ? L.t("없음 — 기본 모습", "Nothing — default look")
                               : parts.joined(separator: "  ·  "))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(parts.isEmpty ? 0.4 : 0.85))
                .lineLimit(2)
            Spacer()
            if !tryOn.isEmpty {
                Button(L.t("원래대로", "Reset")) { tryOn = [:] }
                    .buttonStyle(PillButtonStyle(color: Color.gray))
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 10)
    }

    // MARK: 자리 선택 + 목록

    private var slotPicker: some View {
        Picker("", selection: $slot) {
            ForEach(ItemSlot.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(ShopCatalog.items(in: slot)) { item in
                    row(item)
                }
                if slot == .tool {
                    Text(L.t("작업 도구는 생각하거나 도구를 쓰는 동안 노트북 대신 사용합니다. 팔 동작은 그대로예요.",
                             "Work tools replace the laptop while Claude is working."))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 4)
                }
                if slot == .weapon {
                    Text(L.t("무기는 생각하거나 도구를 쓰는 작업 중에만 손에 듭니다.",
                             "Weapons are only drawn while Claude is working."))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    /// 착용 중 강조색 — 목록 어디서든 눈에 띄도록 초록 계열로 통일한다
    private let wearColor = Color(red: 0.30, green: 0.78, blue: 0.50)
    /// 입어보는 중 강조색 — 착용 중(초록)과 구분되도록 파랑
    private let tryColor  = Color(red: 0.35, green: 0.62, blue: 0.98)

    private func row(_ item: ShopItem) -> some View {
        let owned    = shop.isOwned(item)
        let equipped = shop.isEquipped(item, for: target)
        let unlocked = shop.isUnlocked(item)
        let trying   = tryOn[item.slot] == item.id

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(unlocked ? 1 : 0.45))
                    if trying {
                        Text(L.t("👀 미리보기 중", "👀 Previewing"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(tryColor))
                    }
                    if equipped {
                        // 지금 이 캐릭터가 입고·쓰고 있는 아이템
                        Text(shop.isDefault(item) ? L.t("✓ 사용 중", "✓ In use")
                                                  : L.t("✓ 착용 중", "✓ Equipped"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black.opacity(0.78))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(wearColor))
                    }
                }
                HStack(spacing: 8) {
                    Text("Lv.\(item.level)")
                        .foregroundColor(unlocked ? Color(red: 0.95, green: 0.80, blue: 0.15)
                                                  : Color(red: 0.90, green: 0.40, blue: 0.35))
                    if !owned {
                        Label("\(item.price)", systemImage: "circle.fill")
                            .labelStyle(CoinLabelStyle(small: true))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            Spacer()
            actionButton(item, owned: owned, equipped: equipped, unlocked: unlocked)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(equipped ? wearColor.opacity(0.16)
                           : (trying ? tryColor.opacity(0.16) : Color.white.opacity(0.05))))
        .contentShape(Rectangle())
        .onTapGesture { tryOnItem(item) }       // 행을 누르면 사기 전에 미리 입어본다
        .overlay(alignment: .leading) {
            // 왼쪽 굵은 띠 — 스크롤하면서도 입은 항목이 바로 보이게
            if equipped {
                RoundedRectangle(cornerRadius: 2).fill(wearColor).frame(width: 4).padding(.vertical, 8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(equipped ? wearColor.opacity(0.85) : (trying ? tryColor.opacity(0.85) : .clear),
                    lineWidth: 1.6))
    }

    @ViewBuilder
    private func actionButton(_ item: ShopItem, owned: Bool, equipped: Bool, unlocked: Bool) -> some View {
        if shop.isDefault(item) && equipped {
            EmptyView()          // 기본 아이템을 쓰는 중 — 배지가 대신 알려준다
        } else if owned {
            Button(equipped ? L.t("해제", "Take off")
                            : (shop.isDefault(item) ? L.t("사용", "Use") : L.t("착용", "Equip"))) {
                shop.toggleEquip(item, for: target)
                settle(item)
            }
            // 해제는 빨강, 착용은 파랑 — 색만 봐도 누르면 어떻게 되는지 구분된다
            .buttonStyle(PillButtonStyle(color: equipped ? Color(red: 0.86, green: 0.30, blue: 0.30)
                                                         : .accentColor))
        } else {
            // 아직 내 것이 아닌 아이템 — 레벨·코인이 모자라도 입어볼 수는 있다
            HStack(spacing: 8) {
                if !unlocked {
                    Text(L.t("Lv.\(item.level) 필요", "Needs Lv.\(item.level)"))
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                } else if shop.coins < item.price {
                    Text(L.t("코인 부족", "Not enough"))
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                }
                Button(tryOn[item.slot] == item.id ? L.t("취소", "Cancel") : L.t("입어보기", "Try on")) {
                    tryOnItem(item)
                }
                .buttonStyle(PillButtonStyle(color: tryColor))
                if unlocked && shop.coins >= item.price {
                    Button(L.t("구매", "Buy")) {
                        shop.buy(item, equipFor: target)
                        settle(item)
                    }
                    .buttonStyle(PillButtonStyle(color: Color(red: 0.95, green: 0.60, blue: 0.15)))
                }
            }
        }
    }
}

/// 노란 동전 + 숫자
private struct CoinLabelStyle: LabelStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: small ? 4 : 6) {
            configuration.icon
                .font(.system(size: small ? 8 : 12))
                .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.22))
            configuration.title
                .font(.system(size: small ? 10 : 13, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.98, green: 0.88, blue: 0.50))
        }
    }
}

/// 상점 미리보기에서 보여줄 캐릭터 상태
private enum PreviewMode: CaseIterable {
    case idle, working, done

    var title: String {
        switch self {
        case .idle:    return L.t("대기", "Idle")
        case .working: return L.t("작업 중", "Working")
        case .done:    return L.t("완료", "Done")
        }
    }

    var state: CompanionState {
        switch self {
        case .idle:    return .ready
        case .working: return .thinking
        case .done:    return .completed
        }
    }
}
