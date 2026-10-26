import SwiftUI

/// 툴사용(읽기) 상태일 때 토끼가 들고 읽는 문서 + 옆 바닥 서류 뭉치
struct DocumentView: View {
    let p:        CGFloat
    let bodyDY:   CGFloat
    var throwing: Bool = false   // true → 서류 던지기 애니메이션
    var docVisible: Bool = true  // false → 새 서류 대기 (투명)

    // 종이 색상
    private let paperCol  = Color(red: 0.93, green: 0.89, blue: 0.78)
    private let paperDark = Color(red: 0.80, green: 0.76, blue: 0.65)
    private let lineHeavy = Color(red: 0.55, green: 0.50, blue: 0.42).opacity(0.75)
    private let lineLight = Color(red: 0.55, green: 0.50, blue: 0.42).opacity(0.38)
    // 포스트잇 색상
    private let tabPink   = Color(red: 0.98, green: 0.40, blue: 0.60)
    private let tabYellow = Color(red: 0.98, green: 0.84, blue: 0.20)
    private let tabGreen  = Color(red: 0.28, green: 0.75, blue: 0.35)

    var body: some View {
        ZStack {
            // ── 바닥 서류 뭉치 (왼쪽) — 던질 때도 그대로 유지
            paperPileView
                .offset(x: -p * 5.4, y: p * 2.55 + bodyDY)

            // ── 들고 읽는 문서 — throwing 시 오른쪽 위로 날아가며 사라짐
            // offset: throwing일 때만 easeOut 적용, false로 돌아올 땐 즉시 스냅
            // opacity: docVisible 로 별도 제어 (새 문서 fade-in)
            heldDocumentView
                .offset(x: throwing ? p * 4 : 0,
                        y: throwing ? -p * 3 : 0)
                .animation(throwing ? .easeOut(duration: 0.22) : nil, value: throwing)
                .opacity(docVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: docVisible)
        }
    }

    // MARK: - 들고 읽는 문서

    private var heldDocumentView: some View {
        ZStack {
            // 그림자
            rect(w: 3.2, h: 2.80, c: paperDark.opacity(0.55))
                .offset(x: p * 0.16, y: p * 1.90 + bodyDY)
            // 문서 메인
            rect(w: 3.0, h: 2.80, c: paperCol)
                .offset(y: p * 1.80 + bodyDY)
            // 상단 구분선
            rect(w: 3.0, h: 0.13, c: lineHeavy)
                .offset(y: p * 0.55 + bodyDY)
            // 제목
            rect(w: 1.85, h: 0.25, c: lineHeavy)
                .offset(y: p * 0.78 + bodyDY)
            rect(w: 1.30, h: 0.16, c: lineLight)
                .offset(y: p * 1.06 + bodyDY)
            // 본문 줄
            rect(w: 2.55, h: 0.13, c: lineLight).offset(y: p * 1.35 + bodyDY)
            rect(w: 2.55, h: 0.13, c: lineLight).offset(y: p * 1.55 + bodyDY)
            rect(w: 2.55, h: 0.13, c: lineLight).offset(y: p * 1.75 + bodyDY)
            rect(w: 2.10, h: 0.13, c: lineLight).offset(y: p * 1.95 + bodyDY)
            // 하단 구분선
            rect(w: 3.0, h: 0.10, c: lineHeavy.opacity(0.45))
                .offset(y: p * 2.20 + bodyDY)
            rect(w: 2.55, h: 0.13, c: lineLight).offset(y: p * 2.36 + bodyDY)
            rect(w: 1.80, h: 0.13, c: lineLight).offset(y: p * 2.55 + bodyDY)
            // 우상단 접힌 코너
            rect(w: 0.42, h: 0.42, c: paperDark.opacity(0.65))
                .offset(x: p * 1.29, y: p * 0.47 + bodyDY)
        }
    }

    // MARK: - 바닥 서류 뭉치

    private var paperPileView: some View {
        ZStack {
            // ── 스택 그림자 (아래 퍼진 그림자)
            rect(w: 2.85, h: 0.26, c: paperDark.opacity(0.35))
                .offset(x: p * 0.12, y: p * 0.84)

            // ── 서류 낱장들 (아래부터 위로 — 각각 살짝 다른 각도)
            rect(w: 2.80, h: 0.24, c: paperDark.opacity(0.55))
                .rotationEffect(.degrees(-5), anchor: .center)
                .offset(x: -p * 0.18, y: p * 0.65)

            rect(w: 2.65, h: 0.24, c: paperCol.opacity(0.85))
                .rotationEffect(.degrees(4), anchor: .center)
                .offset(x: p * 0.10, y: p * 0.42)

            rect(w: 2.60, h: 0.24, c: paperCol.opacity(0.90))
                .rotationEffect(.degrees(-2), anchor: .center)
                .offset(x: -p * 0.06, y: p * 0.20)

            rect(w: 2.60, h: 0.24, c: paperDark.opacity(0.60))
                .rotationEffect(.degrees(3), anchor: .center)
                .offset(x: p * 0.08, y: -p * 0.02)

            // ── 위쪽 서류 뭉치 본체
            rect(w: 2.55, h: 1.45, c: paperCol)
                .offset(y: -p * 0.74)

            // ── 내용 줄 (맨 위 서류)
            rect(w: 1.90, h: 0.13, c: lineHeavy).offset(y: -p * 1.22)
            rect(w: 1.60, h: 0.10, c: lineLight).offset(y: -p * 1.04)
            rect(w: 1.90, h: 0.10, c: lineLight).offset(y: -p * 0.88)
            rect(w: 1.55, h: 0.10, c: lineLight).offset(y: -p * 0.72)
            rect(w: 1.90, h: 0.10, c: lineLight).offset(y: -p * 0.56)

            // ── 스택 측면 두께선 (종이 여러 장 느낌)
            rect(w: 2.55, h: 0.12, c: paperDark.opacity(0.40)).offset(y: -p * 0.03)
            rect(w: 2.55, h: 0.12, c: paperDark.opacity(0.28)).offset(y: p * 0.11)
            rect(w: 2.55, h: 0.12, c: paperDark.opacity(0.20)).offset(y: p * 0.24)

            // ── 포스트잇 탭 (옆으로 삐져나옴)
            rect(w: 0.26, h: 0.52, c: tabPink)
                .offset(x: p * 1.28, y: -p * 0.90)
            rect(w: 0.26, h: 0.46, c: tabYellow)
                .offset(x: p * 1.28, y: -p * 0.36)
            rect(w: 0.26, h: 0.44, c: tabGreen)
                .offset(x: p * 1.28, y: p * 0.14)

            // 포스트잇 탭 하이라이트
            rect(w: 0.10, h: 0.52, c: tabPink.opacity(0.45))
                .offset(x: p * 1.20, y: -p * 0.90)
            rect(w: 0.10, h: 0.46, c: tabYellow.opacity(0.45))
                .offset(x: p * 1.20, y: -p * 0.36)

            // ── 바닥에 떨어진 서류 한 장
            rect(w: 2.20, h: 1.55, c: paperCol.opacity(0.90))
                .rotationEffect(.degrees(14), anchor: .bottomTrailing)
                .offset(x: -p * 0.60, y: p * 1.55)
            rect(w: 1.60, h: 0.10, c: lineLight.opacity(0.70))
                .rotationEffect(.degrees(14), anchor: .bottomTrailing)
                .offset(x: -p * 0.60, y: p * 1.20)
            // 바닥 서류 포스트잇
            rect(w: 0.26, h: 0.36, c: tabPink.opacity(0.80))
                .rotationEffect(.degrees(14), anchor: .bottomTrailing)
                .offset(x: p * 0.30, y: p * 1.65)
        }
    }

    private func rect(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }
}
