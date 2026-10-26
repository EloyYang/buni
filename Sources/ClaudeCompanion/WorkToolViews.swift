import SwiftUI

/// 작업 중(생각·도구 사용)에 노트북 대신 쓰는 "작업 도구" 모음.
///
/// 캐릭터 뷰의 노트북 자리(몸통 앞, 팔 위)에 그대로 들어간다. 팔 움직임(안쪽으로
/// 모아 번갈아 위아래)은 캐릭터 뷰가 이미 하고 있으므로, 여기서는 도구 자체의
/// 움직임(깃펜이 줄을 따라 쓰고, 뜨개 작품이 자라고, 그림이 채워지는 것)만 그린다.
///
/// 시간에 따라 계속 바뀌는 그림이라 TimelineView로 그린다 — 상태 변수·타이머를
/// 캐릭터 뷰 6종에 따로 둘 필요가 없다.

private let P: CGFloat = 6.5

private func blk(_ w: CGFloat, _ h: CGFloat, _ c: Color,
                 x: CGFloat = 0, y: CGFloat = 0) -> some View {
    Rectangle().fill(c)
        .frame(width: w * P, height: h * P)
        .offset(x: x * P, y: y * P)
}

/// 노트북 자리에 들어가는 도구 — 고른 아이템에 따라 바뀐다 (기본은 노트북)
struct WorkToolView: View {
    @ObservedObject private var shop = ShopStore.shared
    @Environment(\.tryOn) private var tryOn
    let character: CharacterType
    let p: CGFloat
    let bodyDY: CGFloat
    /// 두 팔의 세로 변위 — 뜨개질 바늘이 손을 따라 움직이게 하려고 받는다
    var leftArmDY: CGFloat = 0
    var rightArmDY: CGFloat = 0

    var body: some View {
        switch shop.resolved(.tool, for: character, tryOn: tryOn)?.id {
        case "book_writing": BookWritingView().offset(y: bodyDY)
        case "knitting":     KnittingToolView(leftDY: leftArmDY, rightDY: rightArmDY).offset(y: bodyDY)
        case "gamepad":      GamepadView().offset(y: bodyDY)
        default:             LaptopView(p: p, bodyDY: bodyDY)
        }
    }
}

// MARK: - 책에 글쓰기 (깃펜)

private struct BookWritingView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let t     = ctx.date.timeIntervalSinceReferenceDate * 1.5
            let done  = Int(t) % 5                                   // 다 쓴 줄 수 (0~4)
            let nib   = CGFloat(t - floor(t))                        // 지금 쓰는 줄의 진행도
            let rowY  = 1.3 + CGFloat(min(done, 3)) * 0.38

            ZStack {
                book
                writtenLines(done: done, nib: nib)
                quill(x: 0.35 + 1.2 * nib, y: rowY + 0.1 + (nib.truncatingRemainder(dividingBy: 0.25) < 0.12 ? 0.0 : -0.12))
            }
        }
    }

    private var book: some View {
        let paper = Color(red: 0.97, green: 0.95, blue: 0.87)
        let cover = Color(red: 0.45, green: 0.26, blue: 0.15)
        let ink   = Color(red: 0.25, green: 0.20, blue: 0.35).opacity(0.5)
        return ZStack {
            blk(4.0, 0.3, cover, y: 3.05)                       // 표지
            blk(1.8, 2.0, paper, x: -0.95, y: 2.0)
            blk(1.8, 2.0, paper, x:  0.95, y: 2.0)
            blk(0.14, 2.0, cover, y: 2.0)                       // 책등
            ForEach(0..<4, id: \.self) { i in                   // 왼쪽 쪽은 이미 쓴 글
                blk(1.2, 0.1, ink, x: -0.95, y: 1.3 + CGFloat(i) * 0.38)
            }
        }
    }

    private func writtenLines(done: Int, nib: CGFloat) -> some View {
        let ink = Color(red: 0.22, green: 0.18, blue: 0.40)
        return ZStack {
            ForEach(0..<4, id: \.self) { i in
                if i < done {
                    blk(1.2, 0.1, ink.opacity(0.9), x: 0.95, y: 1.3 + CGFloat(i) * 0.38)
                } else if i == done {
                    blk(max(0.05, 1.2 * nib), 0.1, ink,
                        x: 0.35 + 0.6 * nib, y: 1.3 + CGFloat(i) * 0.38)
                }
            }
        }
    }

    private func quill(x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            blk(0.14, 1.5, Color(red: 0.55, green: 0.38, blue: 0.20), y: -0.75)   // 대
            blk(0.5, 1.1, Color.white, x: 0.25, y: -1.0)                           // 깃털
            blk(0.3, 0.6, Color(red: 0.86, green: 0.90, blue: 0.98), x: 0.4, y: -1.5)
        }
        .rotationEffect(.degrees(28))
        .offset(x: x * P, y: y * P)
    }
}

// MARK: - 뜨개질

/// 손 위치에서 정해진 점까지 이어지는 선. 손의 세로 변위(handDY)를 animatableData로
/// 노출해서, 팔이 움직이는 애니메이션과 같은 속도로 선도 함께 움직이게 한다.
/// (그냥 계산한 길이·각도는 애니메이션 없이 목표 값으로 바로 튀어서 손보다 먼저 움직인다)
private struct HandLine: Shape {
    var handDY: CGFloat
    let handX: CGFloat
    let handBaseY: CGFloat
    let tip: CGPoint

    var animatableData: CGFloat {
        get { handDY }
        set { handDY = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)          // 캐릭터 중심
        path.move(to: CGPoint(x: c.x + handX, y: c.y + handBaseY + handDY))
        path.addLine(to: CGPoint(x: c.x + tip.x, y: c.y + tip.y))
        return path
    }
}

private struct KnittingToolView: View {
    let leftDY: CGFloat
    let rightDY: CGFloat

    // 팔 애니메이션(0.28초 easeInOut)과 같은 곡선으로 맞춘다
    private let armAnim = Animation.easeInOut(duration: 0.28)

    // 주황 털실 — 줄무늬는 진한 주황과 연한 주황으로, 주황색 몸 위에서도 구분된다
    private let deep  = Color(red: 0.88, green: 0.40, blue: 0.06)
    private let light = Color(red: 1.00, green: 0.80, blue: 0.50)
    private let cream = Color(red: 0.96, green: 0.92, blue: 0.80)   // 바늘
    private let knob  = Color(red: 0.45, green: 0.30, blue: 0.14)

    /// 두 손의 기본 위치 (뜨개질 자세로 팔을 안쪽으로 모은 상태)
    private let handX: CGFloat = 1.15 * P
    private let handY: CGFloat = 1.1 * P
    /// 바늘 끝이 만나는 점 — 두 바늘이 X자로 교차한다
    private var leftTip:  CGPoint { CGPoint(x:  0.55 * P, y: 0.35 * P) }
    private var rightTip: CGPoint { CGPoint(x: -0.55 * P, y: 0.35 * P) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let t    = ctx.date.timeIntervalSinceReferenceDate
            let rows = 2 + Int(t * 1.5) % 4                    // 작품이 한 줄씩 길어진다
            let roll = sin(t * 3.0) * 4                        // 실을 당길 때마다 실뭉치가 살짝 구른다

            ZStack {
                piece(rows: rows)
                yarnBall(roll: roll)
                thread
                needles
            }
        }
    }

    // MARK: 뜨개 작품 — 바늘 교차점 아래로 늘어진다

    /// 한 가지 주황색으로만 짜고, 줄무늬 대신 **코(스티치)가 교차하는 질감**으로 털실 느낌을 낸다.
    /// 뜨개질의 기본 무늬인 V자 코를 기울인 작은 막대 두 개(왼쪽 -26°, 오른쪽 +26°)로 만들고,
    /// 코 사이에는 같은 주황의 짙은 색을 깔아 실이 겹친 그늘을 준다. 줄은 시간이 지날수록 늘어난다.
    private func piece(rows: Int) -> some View {
        let rowH: CGFloat = 0.42
        let cols = 5
        let top: CGFloat = 1.2
        let shade = Color(red: 0.72, green: 0.29, blue: 0.03)      // 코 사이 그늘 (주황)
        let wool  = Color(red: 0.97, green: 0.56, blue: 0.12)      // 털실 주황
        let sheen = Color(red: 1.00, green: 0.66, blue: 0.25)      // 실 결 (같은 주황, 한 톤 밝게)

        return ZStack {
            blk(1.95, CGFloat(rows) * rowH, shade, y: top + CGFloat(rows) * rowH / 2)
            ForEach(0..<rows, id: \.self) { r in
                ForEach(0..<cols, id: \.self) { c in
                    stitch(wool: wool, sheen: sheen)
                        .offset(x: (-0.76 + CGFloat(c) * 0.38) * P,
                                y: (top + rowH / 2 + CGFloat(r) * rowH) * P)
                }
            }
        }
    }

    /// V자 코 하나 — 두 가닥이 아래에서 만난다
    private func stitch(wool: Color, sheen: Color) -> some View {
        ZStack {
            blk(0.17, 0.5, wool).rotationEffect(.degrees(-26)).offset(x: -0.1 * P)
            blk(0.17, 0.5, sheen).rotationEffect(.degrees(26)).offset(x: 0.1 * P)
        }
    }

    // MARK: 실뭉치 — 왼발에서 조금 떨어진 바닥에 놓여 있다 (왼발: x -1.95 ~ -0.45, 바닥 y 3.35)

    /// 실뭉치 중심. 지름 1.6이라 바닥(3.4)에 닿도록 y 2.6 — 왼발과는 약 0.8 떨어뜨렸다.
    private let ballCenter = CGPoint(x: -3.55, y: 2.6)

    /// 네모 블록 한 덩어리로 그리면 상자처럼 보여서, 위·아래로 갈수록 좁아지는
    /// 5단 픽셀 원(0.9 · 1.4 · 1.6 · 1.4 · 0.9)으로 둥글게 만들고, 그 위에 대각선으로
    /// 감긴 실결과 하이라이트를 얹어 털실 공처럼 보이게 한다.
    private func yarnBall(roll: Double) -> some View {
        ZStack {
            // 둥근 윤곽
            blk(0.9, 0.32, deep, y: -0.64)
            blk(1.4, 0.32, deep, y: -0.32)
            blk(1.6, 0.32, deep, y: 0)
            blk(1.4, 0.32, deep, y: 0.32)
            blk(0.9, 0.32, deep, y: 0.64)
            // 대각선으로 감긴 연한 실결
            blk(0.7, 0.2, light, x: 0.15, y: -0.62)
            blk(1.0, 0.2, light, x: -0.15, y: -0.28)
            blk(1.1, 0.2, light, x: 0.2, y: 0.04)
            blk(0.9, 0.2, light, x: -0.1, y: 0.36)
            blk(0.5, 0.2, light, x: 0.15, y: 0.66)
            // 왼쪽 위 하이라이트
            blk(0.3, 0.2, Color.white.opacity(0.75), x: -0.4, y: -0.5)
        }
        .rotationEffect(.degrees(roll * 0.75))
        .offset(x: ballCenter.x * P, y: ballCenter.y * P)
    }

    /// 실뭉치 윗부분에서 왼손까지 이어지는 실 — 손이 움직이면 같이 당겨진다
    private var thread: some View {
        HandLine(handDY: leftDY, handX: -handX, handBaseY: handY,
                 tip: CGPoint(x: (ballCenter.x + 0.25) * P, y: (ballCenter.y - 0.8) * P))
            .stroke(deep, style: StrokeStyle(lineWidth: 0.14 * P, lineCap: .square))
            .frame(width: 16 * P, height: 16 * P)
            .animation(armAnim, value: leftDY)
    }

    // MARK: 바늘 — 손에서 시작해 손 높이를 따라 움직인다

    private var needles: some View {
        ZStack {
            HandLine(handDY: leftDY, handX: -handX, handBaseY: handY, tip: leftTip)
                .stroke(cream, style: StrokeStyle(lineWidth: 0.2 * P, lineCap: .square))
                .frame(width: 16 * P, height: 16 * P)
                .animation(armAnim, value: leftDY)
            HandLine(handDY: rightDY, handX: handX, handBaseY: handY, tip: rightTip)
                .stroke(cream, style: StrokeStyle(lineWidth: 0.2 * P, lineCap: .square))
                .frame(width: 16 * P, height: 16 * P)
                .animation(armAnim, value: rightDY)
            blk(0.35, 0.35, knob, x: 0.55, y: 0.35)            // 바늘 끝 마개
            blk(0.35, 0.35, knob, x: -0.55, y: 0.35)
        }
    }
}

// MARK: - 휴대용 게임기

private struct GamepadView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let t      = ctx.date.timeIntervalSinceReferenceDate
            let hop    = CGFloat(max(0, sin(t * 6)))              // 캐릭터가 통통 뛴다
            let scroll = CGFloat((t * 1.2).truncatingRemainder(dividingBy: 1))
            let press  = Int(t * 5) % 2 == 0

            ZStack {
                console
                screen(hop: hop, scroll: scroll)
                buttons(press: press)
            }
        }
    }

    private var console: some View {
        blk(3.4, 1.7, Color(red: 0.20, green: 0.24, blue: 0.58), y: 1.9)
    }

    private func screen(hop: CGFloat, scroll: CGFloat) -> some View {
        ZStack {
            blk(1.7, 1.2, Color(red: 0.08, green: 0.10, blue: 0.14), y: 1.85)          // 화면 테두리
            blk(1.5, 1.0, Color(red: 0.60, green: 0.86, blue: 0.56), y: 1.85)          // 화면
            blk(0.28, 0.28, Color(red: 0.10, green: 0.25, blue: 0.12),
                x: -0.45, y: 2.1 - hop * 0.45)                                          // 캐릭터
            blk(0.2, 0.32, Color(red: 0.10, green: 0.25, blue: 0.12),
                x: 0.7 - scroll * 1.3, y: 2.1)                                          // 장애물
        }
    }

    private func buttons(press: Bool) -> some View {
        let gray = Color(red: 0.80, green: 0.82, blue: 0.90)
        return ZStack {
            blk(0.55, 0.18, gray, x: -1.45, y: 1.9)                                     // 십자키
            blk(0.18, 0.55, gray, x: -1.45, y: 1.9)
            blk(0.3, 0.3, Color(red: 0.92, green: 0.25, blue: 0.30).opacity(press ? 1 : 0.55), x: 1.35, y: 1.75)
            blk(0.3, 0.3, Color(red: 0.98, green: 0.84, blue: 0.25).opacity(press ? 0.55 : 1), x: 1.65, y: 2.05)
        }
    }
}
