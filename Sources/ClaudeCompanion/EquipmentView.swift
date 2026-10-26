import SwiftUI

/// 상점에서 산 꾸미기 아이템·무기를 캐릭터 위에 그린다.
///
/// 캐릭터 뷰(각 *CharacterView)와 같은 p(=6.5) 단위계, 같은 중심 기준 오프셋을
/// 쓴다. 캐릭터 뷰 안의 ZStack에 그대로 끼워 넣어 bodyDY(들썩임)를 같이 받으므로
/// 모자가 머리와 따로 놀지 않는다.
///
/// 기준 좌표(정면 포즈): 머리 y -2.1~0.5 · 귀 y -5.2~-1.8(x ±0.8~2.4) ·
/// 눈 x ±1.4, y -0.9 · 몸통 y 0.25~2.75 · 오른팔 x 2.65, y 1.1

private let P: CGFloat = 6.5

/// 상점 미리보기에서 "사지 않은 아이템도 미리 입어보기"를 위한 덮어쓰기.
/// 환경값이 nil이면(실제로 떠 있는 부니) 저장된 착용 상태를 그대로 쓰고,
/// 값이 있으면(상점 미리보기) 그 안에 든 아이템만 보여준다 — 실제 부니에는 영향이 없다.
struct TryOnItems: Equatable {
    var items: [ItemSlot: String]
}

private struct TryOnKey: EnvironmentKey {
    static let defaultValue: TryOnItems? = nil
}

extension EnvironmentValues {
    var tryOn: TryOnItems? {
        get { self[TryOnKey.self] }
        set { self[TryOnKey.self] = newValue }
    }
}

extension ShopStore {
    /// 지금 이 자리에 보여줄 아이템 — 입어보기 중이면 그것, 아니면 실제 착용 상태
    func resolved(_ slot: ItemSlot, for character: CharacterType, tryOn: TryOnItems?) -> ShopItem? {
        if let tryOn { return tryOn.items[slot].flatMap { ShopCatalog.item($0) } }
        return equippedItem(in: slot, for: character)
    }

    /// 기본 당근이 아닌 무기를 들고 있는지 (캐릭터 뷰가 당근을 그릴지 정할 때)
    func hasCustomWeapon(for character: CharacterType, tryOn: TryOnItems?) -> Bool {
        if let tryOn {
            guard let id = tryOn.items[.weapon] else { return false }
            return id != "carrot"
        }
        return hasCustomWeapon(for: character)
    }
}

/// 픽셀 블록 하나 (w·h는 p 단위, x·y는 중심에서의 오프셋)
private func blk(_ w: CGFloat, _ h: CGFloat, _ c: Color,
                 x: CGFloat = 0, y: CGFloat = 0) -> some View {
    Rectangle().fill(c)
        .frame(width: w * P, height: h * P)
        .offset(x: x * P, y: y * P)
}

// MARK: - 뒤 레이어 (캐릭터 뒤 — 망토·날개)

struct EquipmentBackLayer: View {
    @ObservedObject private var shop = ShopStore.shared
    @Environment(\.tryOn) private var tryOn
    let character: CharacterType
    var bodyDY: CGFloat

    var body: some View {
        ZStack {
            switch shop.resolved(.back, for: character, tryOn: tryOn)?.id {
            case "cape":  cape
            case "devil_wings": devilWings
            case "wings": wings
            default:      EmptyView()
            }
        }
        .offset(y: bodyDY)
    }

    private var cape: some View {
        let red  = Color(red: 0.82, green: 0.16, blue: 0.20)
        let dark = Color(red: 0.58, green: 0.09, blue: 0.14)
        return ZStack {
            blk(5.9, 3.0, red,  y: 1.9)
            blk(6.5, 0.6, red,  y: 3.4)      // 아래로 퍼지는 밑단
            blk(4.4, 2.2, dark, y: 2.3)      // 안쪽 그늘
            blk(1.0, 0.5, Color(red: 0.95, green: 0.78, blue: 0.20), y: 0.25)   // 목 장식
        }
    }

    /// 악마 날개 — 천사 날개와 같은 뼈대(어깨에서 바깥·위로)에 가죽 질감의 어두운 붉은색,
    /// 아래 가장자리를 톱니처럼 파고, 엉덩이 쪽에 화살촉 꼬리를 붙인다.
    private var devilWings: some View {
        let crimson = Color(red: 0.66, green: 0.09, blue: 0.16)
        let dark    = Color(red: 0.40, green: 0.04, blue: 0.11)
        let edge    = Color(red: 0.90, green: 0.22, blue: 0.28)
        let rows: [(y: CGFloat, start: CGFloat, len: CGFloat)] = [
            ( 1.9, 2.0, 0.9), ( 1.2, 2.0, 1.7), ( 0.5, 2.1, 2.5), (-0.2, 2.3, 2.9),
            (-0.9, 2.7, 2.7), (-1.6, 3.1, 2.1), (-2.3, 3.6, 1.3), (-3.0, 4.2, 0.6),
        ]
        return ZStack {
            ForEach([-1, 1], id: \.self) { side in
                let sgn = CGFloat(side)
                ZStack {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        blk(r.len, 0.82, i % 2 == 0 ? crimson : dark,
                            x: sgn * (r.start + r.len / 2), y: r.y)
                        blk(0.45, 0.82, edge, x: sgn * (r.start + r.len - 0.22), y: r.y)
                    }
                    // 가죽 날개 뼈대(위로 뻗은 갈래)
                    blk(0.28, 2.0, dark, x: sgn * 3.7, y: -1.4)
                }
            }
            // 꼬리 — 오른쪽 엉덩이에서 위로 휘어 화살촉으로 끝난다
            blk(0.4, 0.4, dark, x: 2.55, y: 2.7)
            blk(0.4, 0.4, dark, x: 2.95, y: 3.05)
            blk(0.4, 0.4, dark, x: 3.4,  y: 3.05)
            blk(0.4, 0.4, dark, x: 3.75, y: 2.7)
            blk(0.9, 0.35, edge, x: 3.95, y: 2.25)
            blk(0.45, 0.45, edge, x: 3.95, y: 1.9)
        }
    }

    /// 날개 — 어깨 높이에서 몸 뒤에 붙어 시작해 **바깥·위로 솟아오르는** 깃털 계단.
    /// 아래 줄은 몸에 바짝 붙어 있고, 위로 갈수록 시작점이 바깥으로 밀려 윤곽이
    /// 위로 휘어 올라간다(끝이 위를 향한 날개 모양). 줄 두께를 간격보다 크게 해서
    /// 틈 없이 겹치고, 줄마다 흰색과 연한 푸른 흰색을 번갈아 깃털 결을 낸다.
    /// 예전 버전은 몸에서 떨어진 판자 두 장이라 "손에 쥔 막대"로 보였고, 그 다음엔
    /// 가로로 누운 타원이라 날개답지 않았다.
    private var wings: some View {
        let white = Color(red: 0.99, green: 0.99, blue: 1.00)
        let tint  = Color(red: 0.90, green: 0.94, blue: 1.00)
        let edge  = Color(red: 0.74, green: 0.82, blue: 0.96)

        // (y, 몸통 가장자리에서 시작하는 x, 뻗는 길이) — 아래에서 위로 갈수록 바깥으로 밀린다
        let rows: [(y: CGFloat, start: CGFloat, len: CGFloat)] = [
            ( 2.0, 2.0, 1.3), ( 1.3, 2.0, 2.1), ( 0.6, 2.1, 2.7), (-0.1, 2.3, 2.9),
            (-0.8, 2.7, 2.7), (-1.5, 3.1, 2.1), (-2.2, 3.6, 1.3), (-2.9, 4.2, 0.7),
        ]
        return ZStack {
            ForEach([-1, 1], id: \.self) { side in
                let sgn = CGFloat(side)
                ZStack {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        blk(r.len, 0.82, i % 2 == 0 ? white : tint,
                            x: sgn * (r.start + r.len / 2), y: r.y)
                        blk(0.5, 0.82, edge, x: sgn * (r.start + r.len - 0.25), y: r.y)   // 깃털 끝
                    }
                }
            }
        }
    }
}

// MARK: - 앞 레이어 (머리·얼굴·무기)

struct EquipmentFrontLayer: View {
    @EnvironmentObject var ctrl: CompanionController
    @ObservedObject private var shop = ShopStore.shared
    @Environment(\.tryOn) private var tryOn
    let character: CharacterType
    var bodyDY: CGFloat

    @State private var sway  = false
    @State private var pulse = false
    @State private var swingAngle: Double = 0
    /// 보여주기가 끝나는 타이머가 새로 시작된 보여주기를 끊지 않도록 구분하는 표
    @State private var showToken = 0
    /// 몇 초마다 꺼낼지 고민하는 주기 — 확률로 걸러서 평균 12초 안팎에 한 번 나온다
    private let idleDrawTick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    /// 무기를 드는 자리
    private enum Hold: Hashable {
        case right        // 오른손 — 작업 중
        case raisedLeft   // 들어 올린 왼손 — 완료·권한 요청 때 당근을 들던 바로 그 자리
        case showOff      // 들어 올린 오른손 — 대기 중에 꺼내 보여줄 때 (캐릭터 뷰가 오른팔을 올린다)
    }

    private var hold: Hold? {
        switch ctrl.state {
        case .thinking, .toolUse, .toolRead, .backgroundWork: return .right
        case .completed, .permission:                         return .raisedLeft
        default:                                              return ctrl.isShowingWeapon ? .showOff : nil
        }
    }

    var body: some View {
        ZStack {
            face
            head
            if let hold, let weapon = shop.resolved(.weapon, for: character, tryOn: tryOn) {
                weaponView(weapon.id, hold: hold)
                    .id(hold)    // 자리가 바뀌면 새로 꺼내 드는 모션으로
                    .transition(.scale(scale: 0.3, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .offset(y: bodyDY)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hold)
        .onAppear { sway = true; pulse = true }
        .onReceive(idleDrawTick) { _ in maybeShowWeaponWhileIdle() }
        .onChange(of: ctrl.state) { _ in
            // 작업이 시작되는 등 대기 상태를 벗어나면 보여주기를 바로 접는다
            if ctrl.isShowingWeapon, !isIdleReady { ctrl.isShowingWeapon = false; swingAngle = 0 }
        }
    }

    private var isIdleReady: Bool {
        if case .ready = ctrl.state { return true }
        return false
    }

    /// 대기 중(.ready)에 가끔 무기를 꺼내 보여준다.
    ///  ① 오른팔을 들어 올리며 무기를 꺼낸다 → ② 천천히 좌우로 기울여 보여준다 →
    ///  ③ 팔을 내리며 집어넣는다. 팔 동작은 캐릭터 뷰가 isShowingWeapon에 맞춰 한다.
    private func maybeShowWeaponWhileIdle() {
        guard isIdleReady, !ctrl.isShowingWeapon, !ctrl.isSliding,
              shop.resolved(.weapon, for: character, tryOn: tryOn).map({ $0.id != "carrot" }) == true,
              Int.random(in: 0..<3) == 0 else { return }

        showToken += 1
        let token = showToken
        ctrl.isShowingWeapon = true

        let tilts: [Double] = [-8, 14, -6, 12, -4, 0]
        for (i, angle) in tilts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + 0.34 * Double(i)) {
                guard token == showToken, ctrl.isShowingWeapon else { return }
                withAnimation(.easeInOut(duration: 0.3)) { swingAngle = angle }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            guard token == showToken else { return }
            ctrl.isShowingWeapon = false
            swingAngle = 0
        }
    }

    // MARK: 머리

    @ViewBuilder
    private var head: some View {
        switch shop.resolved(.head, for: character, tryOn: tryOn)?.id {
        case "straw_hat":
            let straw = Color(red: 0.93, green: 0.80, blue: 0.45)
            let band  = Color(red: 0.78, green: 0.22, blue: 0.20)
            ZStack {
                blk(6.6, 0.45, straw, y: -2.2)
                blk(3.4, 1.0,  straw, y: -2.9)
                blk(3.4, 0.3,  band,  y: -2.45)
            }
        case "wizard_hat":
            let purple = Color(red: 0.36, green: 0.22, blue: 0.62)
            let light  = Color(red: 0.50, green: 0.34, blue: 0.80)
            ZStack {
                blk(5.8, 0.35, purple, y: -2.2)
                blk(4.0, 0.6,  purple, y: -2.65)
                blk(3.0, 0.6,  light,  y: -3.2)
                blk(2.0, 0.6,  purple, y: -3.75)
                blk(1.1, 0.6,  light,  x: 0.2, y: -4.3)
                blk(0.6, 0.5,  purple, x: 0.6, y: -4.8)
                blk(0.4, 0.4,  Color(red: 1.0, green: 0.88, blue: 0.25), x: -0.3, y: -3.2)   // 별
            }
        case "halo":
            let gold = Color(red: 1.00, green: 0.86, blue: 0.30)
            let glow = Color(red: 1.00, green: 0.96, blue: 0.62)
            ZStack {
                blk(3.0, 0.3, gold, y: -3.55)             // 윗변
                blk(3.0, 0.3, gold, y: -2.75)             // 아랫변
                blk(0.4, 0.5, gold, x: -1.6, y: -3.15)    // 양옆 (모서리를 깎아 동그랗게)
                blk(0.4, 0.5, gold, x:  1.6, y: -3.15)
                blk(1.8, 0.14, glow, y: -3.55)            // 윗변 하이라이트
            }
            .opacity(pulse ? 1.0 : 0.72)
            .offset(y: pulse ? -3 : 0)                    // 둥둥 떠 있는 느낌
            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: pulse)
        case "devil_horns":
            let red  = Color(red: 0.80, green: 0.10, blue: 0.14)
            let dark = Color(red: 0.48, green: 0.04, blue: 0.10)
            ZStack {
                ForEach([-1, 1], id: \.self) { side in
                    let sg = CGFloat(side)
                    blk(0.8, 0.7, red,  x: sg * 2.45, y: -2.30)
                    blk(0.6, 0.6, red,  x: sg * 2.75, y: -2.85)
                    blk(0.4, 0.5, dark, x: sg * 3.05, y: -3.35)
                }
            }
        case "fire_helmet":
            let red  = Color(red: 0.84, green: 0.14, blue: 0.12)
            let gold = Color(red: 0.98, green: 0.80, blue: 0.22)
            ZStack {
                blk(4.2, 0.9, red, y: -2.55)              // 돔
                blk(5.6, 0.45, red, y: -2.05)             // 챙
                blk(1.0, 0.3, red, y: -3.15)              // 꼭대기 볏
                blk(0.9, 0.7, gold, y: -2.55)             // 앞 방패 마크
                blk(4.2, 0.16, Color.white.opacity(0.35), y: -2.85)
            }
        case "police_cap":
            let navy  = Color(red: 0.12, green: 0.18, blue: 0.38)
            let black = Color(red: 0.07, green: 0.07, blue: 0.10)
            let gold  = Color(red: 0.98, green: 0.80, blue: 0.22)
            ZStack {
                blk(5.0, 0.55, navy, y: -2.95)            // 넓은 윗판
                blk(4.2, 0.7, navy, y: -2.50)
                blk(4.2, 0.22, black, y: -2.12)           // 띠
                blk(3.0, 0.28, black, y: -1.95)           // 챙
                blk(0.7, 0.6, gold, y: -2.55)             // 모표
            }
        case "crown":
            let gold = Color(red: 0.96, green: 0.78, blue: 0.20)
            let gem  = Color(red: 0.88, green: 0.18, blue: 0.30)
            ZStack {
                blk(4.4, 0.7, gold, y: -2.4)
                ForEach([-1, 0, 1], id: \.self) { i in
                    blk(0.8, 0.9, gold, x: CGFloat(i) * 1.6, y: -3.0)
                }
                blk(0.4, 0.4, gem, y: -3.15)
                blk(0.3, 0.3, Color(red: 0.25, green: 0.62, blue: 0.95), x: -1.4, y: -2.4)
                blk(0.3, 0.3, Color(red: 0.25, green: 0.62, blue: 0.95), x: 1.4, y: -2.4)
            }
        default:
            EmptyView()
        }
    }

    // MARK: 얼굴

    @ViewBuilder
    private var face: some View {
        switch shop.resolved(.face, for: character, tryOn: tryOn)?.id {
        case "glasses":
            let frame = Color(red: 0.22, green: 0.16, blue: 0.10)
            ZStack {
                ForEach([-1, 1], id: \.self) { side in
                    Rectangle()
                        .strokeBorder(frame, lineWidth: 1.6)
                        .background(Color.white.opacity(0.16))
                        .frame(width: 1.5 * P, height: 1.2 * P)
                        .offset(x: CGFloat(side) * 1.4 * P, y: -0.9 * P)
                }
                blk(0.6, 0.2, frame, y: -1.0)
                blk(0.35, 0.2, frame, x: -2.3, y: -1.0)
                blk(0.35, 0.2, frame, x: 2.3, y: -1.0)
            }
        case "shades":
            let black = Color(red: 0.06, green: 0.06, blue: 0.09)
            ZStack {
                ForEach([-1, 1], id: \.self) { side in
                    blk(1.6, 1.0, black, x: CGFloat(side) * 1.4, y: -0.9)
                    blk(0.5, 0.18, Color.white.opacity(0.45), x: CGFloat(side) * 1.1, y: -1.15)
                }
                blk(1.2, 0.25, black, y: -1.1)
            }
        default:
            EmptyView()
        }
    }

    // MARK: 무기 (오른손에 쥔다 — 손 위치 x 3.7, y 1.1)

    private func weaponView(_ id: String, hold: Hold) -> some View {
        // 쥔 손을 중심(회전축)으로 삼아 좌우로 살짝 흔들린다
        Group {
            switch id {
            case "wood_sword":  sword(blade: Color(red: 0.72, green: 0.52, blue: 0.30),
                                      edge: Color(red: 0.88, green: 0.70, blue: 0.46),
                                      guardC: Color(red: 0.50, green: 0.34, blue: 0.18), length: 3.0)
            case "steel_sword": sword(blade: Color(red: 0.74, green: 0.80, blue: 0.88),
                                      edge: Color.white.opacity(0.85),
                                      guardC: Color(red: 0.96, green: 0.78, blue: 0.20), length: 3.4)
            case "flame_sword": flameSword
            case "baton":       baton
            case "fire_axe":    fireAxe
            case "trident":     trident
            case "staff":       staff
            default:            EmptyView()
            }
        }
        .rotationEffect(.degrees(ctrl.isShowingWeapon ? swingAngle : 0))
        // 보여줄 때는 천천히 흔들림 없이, 작업 중에는 계속 살짝 흔들린다
        .rotationEffect(.degrees(hold == .showOff ? 0 : (sway ? 9 : 2)))
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: sway)
        // 왼손은 거울상으로 — 칼날이 바깥(왼쪽)으로 기울어야 자연스럽다
        .scaleEffect(x: hold == .raisedLeft ? -1 : 1, y: 1)
        .offset(x: (hold == .raisedLeft ? -3.7 : 3.7) * P,
                y: (hold == .raisedLeft ? -1.7 : (hold == .showOff ? -0.5 : 1.1)) * P)
    }

    private func sword(blade: Color, edge: Color, guardC: Color, length: CGFloat) -> some View {
        ZStack {
            blk(0.4, 1.0, Color(red: 0.42, green: 0.28, blue: 0.16))                 // 손잡이
            blk(1.8, 0.35, guardC, y: -0.62)                                         // 날밑
            blk(0.7, length, blade, y: -0.8 - length / 2)                            // 칼날
            blk(0.2, length - 0.2, edge, x: -0.15, y: -0.8 - length / 2)             // 날 하이라이트
            blk(0.4, 0.4, blade, y: -0.8 - length - 0.2)                             // 칼끝
            blk(0.6, 0.4, guardC, y: 0.65)                                           // 자루 끝
        }
    }

    private var flameSword: some View {
        let hot  = Color(red: 1.00, green: 0.45, blue: 0.10)
        let core = Color(red: 1.00, green: 0.85, blue: 0.25)
        return ZStack {
            blk(0.4, 1.0, Color(red: 0.30, green: 0.14, blue: 0.10))
            blk(2.0, 0.4, Color(red: 0.55, green: 0.12, blue: 0.10), y: -0.62)
            blk(0.9, 3.8, hot,  y: -2.8)
            blk(0.4, 3.4, core, y: -2.8)
            blk(0.4, 0.4, hot,  y: -4.9)
            // 칼끝에서 일렁이는 불꽃
            blk(0.5, 0.7, core, x: -0.4, y: pulse ? -5.5 : -5.1)
            blk(0.4, 0.6, hot,  x: 0.4,  y: pulse ? -5.2 : -5.6)
        }
        .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: pulse)
    }

    private var baton: some View {
        let shaft = Color(red: 0.26, green: 0.28, blue: 0.36)
        let light = Color(red: 0.55, green: 0.58, blue: 0.68)
        return ZStack {
            blk(0.6, 3.4, shaft, y: -1.5)
            blk(0.18, 3.2, light, x: -0.18, y: -1.5)                         // 옆면 광택
            blk(0.35, 0.9, shaft, x: -0.45, y: -0.1)                         // 옆 손잡이
            blk(0.64, 0.3, Color.white.opacity(0.9), y: -2.6)                // 반사띠
            blk(0.64, 0.3, Color.white.opacity(0.9), y: -1.4)
        }
    }

    private var fireAxe: some View {
        let wood  = Color(red: 0.50, green: 0.32, blue: 0.16)
        let red   = Color(red: 0.84, green: 0.16, blue: 0.12)
        let steel = Color(red: 0.80, green: 0.84, blue: 0.90)
        return ZStack {
            // 날이 바깥(오른손 기준 오른쪽)을 본다 — 왼손으로 들 때는 좌우 반전돼 왼쪽 바깥을 본다
            blk(0.45, 4.6, wood, y: -1.6)
            blk(1.3, 1.2, red,   x: 0.8, y: -3.5)                            // 도끼 머리
            blk(0.35, 1.4, steel, x: 1.55, y: -3.5)                          // 날
            blk(0.9, 0.4, steel, x: -0.65, y: -3.7)                          // 뒤 곡괭이(안쪽)
        }
    }

    private var trident: some View {
        let pole  = Color(red: 0.42, green: 0.08, blue: 0.12)
        let metal = Color(red: 0.88, green: 0.28, blue: 0.30)
        return ZStack {
            blk(0.4, 5.0, pole, y: -1.4)
            blk(1.9, 0.3, metal, y: -3.8)                                    // 가로대
            blk(0.3, 1.2, metal, x: -0.8, y: -4.4)                           // 세 갈래
            blk(0.3, 1.6, metal, y: -4.6)
            blk(0.3, 1.2, metal, x:  0.8, y: -4.4)
            blk(0.2, 0.3, Color.white.opacity(pulse ? 0.9 : 0.4), y: -5.5)   // 끝 반짝임
        }
        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
    }

    private var staff: some View {
        let wood = Color(red: 0.50, green: 0.32, blue: 0.16)
        let orb  = Color(red: 0.35, green: 0.85, blue: 0.98)
        return ZStack {
            blk(0.45, 5.6, wood, y: -1.6)
            blk(0.35, 1.0, wood, x: -0.75, y: -4.2)       // 보주를 감싼 가지
            blk(0.35, 1.0, wood, x: 0.75,  y: -4.2)
            blk(1.4, 1.4, orb,  y: -4.4)
            blk(0.7, 0.7, Color.white.opacity(pulse ? 0.95 : 0.45), y: -4.4)
            // 반짝이는 마법 가루
            blk(0.25, 0.25, orb, x: -1.3, y: pulse ? -5.4 : -5.0)
            blk(0.25, 0.25, orb, x: 1.3,  y: pulse ? -4.8 : -5.3)
        }
        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
    }
}

// MARK: - 옷 레이어 (몸통 바로 위 — 팔과 노트북이 그 위에 그려진다)

struct EquipmentOutfitLayer: View {
    @ObservedObject private var shop = ShopStore.shared
    @Environment(\.tryOn) private var tryOn
    let character: CharacterType
    var bodyDY: CGFloat

    // 몸통 폭은 종마다 4.5~4.8이라, 가장 좁은 4.5에 맞춰 삐져나오지 않게 한다
    // 몸통 y: 0.25 ~ 2.75 (중심 1.5)
    var body: some View {
        ZStack {
            switch shop.resolved(.outfit, for: character, tryOn: tryOn)?.id {
            case "stripe_tee": stripeTee
            case "hoodie":     hoodie
            case "tuxedo":     tuxedo
            case "armor":      armor
            case "school_uniform": schoolUniform
            case "business_suit":  businessSuit
            case "firefighter":    firefighter
            case "police":         police
            case "angel_gown":     angelGown
            case "devil_suit":     devilSuit
            case "robe":       robe
            default:           EmptyView()
            }
        }
        .offset(y: bodyDY)
    }

    private var stripeTee: some View {
        let blue  = Color(red: 0.22, green: 0.42, blue: 0.86)
        let white = Color(red: 0.96, green: 0.97, blue: 1.00)
        return ZStack {
            blk(4.5, 2.1, blue, y: 1.45)
            blk(4.5, 0.32, white, y: 1.0)
            blk(4.5, 0.32, white, y: 1.7)
            blk(4.5, 0.32, white, y: 2.4)
            blk(1.4, 0.35, white, y: 0.4)       // 둥근 목선
        }
    }

    private var hoodie: some View {
        let gray = Color(red: 0.52, green: 0.56, blue: 0.64)
        let dark = Color(red: 0.38, green: 0.42, blue: 0.50)
        return ZStack {
            blk(4.5, 2.2, gray, y: 1.5)
            blk(2.6, 0.95, dark, y: 2.15)        // 배 주머니
            blk(1.8, 0.3,  gray, y: 1.75)
            blk(2.2, 0.4,  dark, y: 0.4)         // 후드 둘레
            blk(0.2, 0.9, Color.white, x: -0.55, y: 1.0)   // 끈
            blk(0.2, 0.9, Color.white, x:  0.55, y: 1.0)
        }
    }

    private var tuxedo: some View {
        let black = Color(red: 0.10, green: 0.10, blue: 0.14)
        let white = Color(red: 0.97, green: 0.97, blue: 1.00)
        let red   = Color(red: 0.82, green: 0.14, blue: 0.22)
        return ZStack {
            blk(4.5, 2.2, black, y: 1.5)
            blk(1.5, 1.7, white, y: 1.15)         // 셔츠 V
            blk(0.5, 0.5, white, x: -0.3, y: 2.05)
            blk(0.5, 0.5, white, x:  0.3, y: 2.05)
            blk(0.9, 0.5, red, y: 0.45)           // 나비넥타이
            blk(0.3, 0.3, red.opacity(0.7), y: 0.45)
            blk(0.25, 0.25, white, y: 1.5)        // 단추
            blk(0.25, 0.25, white, y: 1.95)
        }
    }

    private var armor: some View {
        let steel = Color(red: 0.70, green: 0.76, blue: 0.84)
        let light = Color(red: 0.88, green: 0.92, blue: 0.97)
        let dark  = Color(red: 0.48, green: 0.54, blue: 0.64)
        let gold  = Color(red: 0.96, green: 0.78, blue: 0.20)
        return ZStack {
            blk(4.5, 2.3, steel, y: 1.5)
            blk(3.6, 0.3, light, y: 0.55)         // 가슴 하이라이트
            blk(0.3, 1.7, dark, y: 1.35)          // 가운데 이음선
            blk(4.5, 0.4, gold, y: 2.3)           // 허리띠
            blk(0.5, 0.45, light, y: 2.3)         // 버클
            blk(1.2, 0.7, dark, x: -2.35, y: 0.5) // 어깨 보호대
            blk(1.2, 0.7, dark, x:  2.35, y: 0.5)
            blk(1.0, 0.3, light, x: -2.35, y: 0.3)
            blk(1.0, 0.3, light, x:  2.35, y: 0.3)
        }
    }

    private var schoolUniform: some View {
        let navy  = Color(red: 0.16, green: 0.22, blue: 0.46)
        let white = Color(red: 0.97, green: 0.97, blue: 1.00)
        let red   = Color(red: 0.82, green: 0.14, blue: 0.20)
        let gold  = Color(red: 0.98, green: 0.80, blue: 0.22)
        return ZStack {
            blk(4.5, 2.2, navy, y: 1.5)
            blk(1.5, 1.3, white, y: 0.95)             // 셔츠 V
            blk(1.0, 0.45, red, y: 0.5)               // 리본
            blk(0.35, 0.6, red, x: -0.4, y: 0.95)     // 리본 끝
            blk(0.35, 0.6, red, x:  0.4, y: 0.95)
            blk(0.45, 0.45, gold, x: -1.5, y: 1.4)    // 학교 마크
            blk(0.25, 0.25, gold, y: 1.8)             // 단추
            blk(0.25, 0.25, gold, y: 2.2)
        }
    }

    private var businessSuit: some View {
        let suit  = Color(red: 0.14, green: 0.18, blue: 0.28)
        let lapel = Color(red: 0.08, green: 0.11, blue: 0.19)
        let white = Color(red: 0.97, green: 0.97, blue: 1.00)
        let tie   = Color(red: 0.78, green: 0.12, blue: 0.20)
        return ZStack {
            blk(4.5, 2.2, suit, y: 1.5)
            blk(1.4, 1.6, white, y: 1.1)              // 셔츠
            blk(0.7, 1.7, lapel, x: -1.05, y: 1.2)    // 라펠
            blk(0.7, 1.7, lapel, x:  1.05, y: 1.2)
            blk(0.45, 1.4, tie, y: 1.35)              // 넥타이
            blk(0.6, 0.35, tie, y: 0.5)               // 매듭
            blk(0.5, 0.3, white, x: -1.5, y: 1.7)     // 가슴 손수건
        }
    }

    private var firefighter: some View {
        let red    = Color(red: 0.84, green: 0.16, blue: 0.12)
        let dark   = Color(red: 0.42, green: 0.07, blue: 0.06)
        let yellow = Color(red: 0.98, green: 0.84, blue: 0.20)
        return ZStack {
            blk(4.5, 2.2, red, y: 1.5)
            blk(4.5, 0.38, yellow, y: 1.15)           // 반사띠
            blk(4.5, 0.38, yellow, y: 2.05)
            blk(0.3, 2.1, dark, y: 1.5)               // 앞 지퍼
            blk(2.4, 0.4, dark, y: 0.4)               // 높은 옷깃
        }
    }

    private var police: some View {
        let navy  = Color(red: 0.12, green: 0.17, blue: 0.34)
        let sky   = Color(red: 0.62, green: 0.76, blue: 0.94)
        let black = Color(red: 0.07, green: 0.07, blue: 0.10)
        let gold  = Color(red: 0.98, green: 0.80, blue: 0.22)
        return ZStack {
            blk(4.5, 2.2, navy, y: 1.5)
            blk(1.3, 1.3, sky, y: 0.95)               // 셔츠
            blk(0.4, 1.2, black, y: 1.1)              // 넥타이
            blk(0.7, 0.7, gold, x: -1.4, y: 1.3)      // 배지
            blk(0.25, 0.25, gold, x: 1.4, y: 1.0)
            blk(1.0, 0.35, gold, x: -2.2, y: 0.4)     // 견장
            blk(1.0, 0.35, gold, x:  2.2, y: 0.4)
            blk(4.5, 0.3, black, y: 2.4)              // 벨트
        }
    }

    private var angelGown: some View {
        let white = Color(red: 0.99, green: 0.99, blue: 1.00)
        let tint  = Color(red: 0.88, green: 0.92, blue: 1.00)
        let gold  = Color(red: 0.98, green: 0.82, blue: 0.30)
        return ZStack {
            blk(4.5, 2.2, white, y: 1.5)
            blk(4.9, 0.5, tint, y: 2.95)              // 밑단
            blk(4.5, 0.25, gold, y: 1.95)             // 금빛 띠
            blk(2.0, 0.3, gold, y: 0.4)               // 금빛 목둘레
            blk(0.3, 0.9, tint, x: -0.9, y: 1.2)      // 주름
            blk(0.3, 0.9, tint, x:  0.9, y: 1.2)
        }
    }

    private var devilSuit: some View {
        let black = Color(red: 0.10, green: 0.06, blue: 0.10)
        let red   = Color(red: 0.76, green: 0.10, blue: 0.16)
        let gold  = Color(red: 0.98, green: 0.80, blue: 0.22)
        return ZStack {
            blk(4.5, 2.2, black, y: 1.5)
            blk(1.5, 1.6, red, y: 1.1)                // 붉은 셔츠
            blk(0.4, 1.3, black, y: 1.3)              // 검은 넥타이
            blk(0.7, 1.7, black, x: -1.05, y: 1.2)    // 뾰족한 라펠
            blk(0.7, 1.7, black, x:  1.05, y: 1.2)
            blk(0.3, 0.3, gold, x: 1.6, y: 2.2)       // 금 단추
        }
    }

    private var robe: some View {
        let purple = Color(red: 0.40, green: 0.25, blue: 0.70)
        let dark   = Color(red: 0.28, green: 0.16, blue: 0.52)
        let gold   = Color(red: 0.98, green: 0.82, blue: 0.25)
        return ZStack {
            blk(4.5, 2.2, purple, y: 1.5)
            blk(4.9, 0.5, dark, y: 2.95)          // 밑단 — 발 쪽으로 살짝 퍼진다
            blk(0.6, 2.0, dark, y: 1.55)          // 앞트임
            blk(4.5, 0.3, gold, y: 1.9)           // 허리띠
            blk(0.55, 0.55, gold, y: 0.95)        // 가슴 별
            blk(0.25, 0.25, gold, x: -0.55, y: 0.95)
            blk(0.25, 0.25, gold, x:  0.55, y: 0.95)
        }
    }
}
