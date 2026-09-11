import SwiftUI

/// 생각중/쓰기 도구 사용 시 — 다리 위 맥북 측면 타이핑 뷰
/// 구도: 살짝 측면에서 본 각도, 다리 위에 올려둔 느낌, 책상 없음
struct LaptopView: View {
    let p:      CGFloat
    let bodyDY: CGFloat

    private let silverCol  = Color(red: 0.76, green: 0.76, blue: 0.80)
    private let silverHi   = Color(red: 0.88, green: 0.88, blue: 0.92)
    private let silverDark = Color(red: 0.50, green: 0.50, blue: 0.54)
    private let silverMid  = Color(red: 0.64, green: 0.64, blue: 0.68)
    private let carrotCol  = Color(red: 0.95, green: 0.55, blue: 0.18)
    private let leafCol    = Color(red: 0.40, green: 0.70, blue: 0.35)

    var body: some View {
        ZStack {
            laptopBody
        }
        .offset(y: bodyDY)
    }

    private var laptopBody: some View {
        ZStack {
            // ── 뚜껑 뒷면 메인 (Apple 로고 있는 면)
            rect(w: 3.15, h: 2.15, c: silverCol)
                .offset(y: p * 1.48)

            // ── 뚜껑 상단 엣지 하이라이트
            rect(w: 3.15, h: 0.17, c: silverHi)
                .offset(y: p * 0.41)

            // ── 뚜껑 좌우 엣지
            rect(w: 0.12, h: 2.15, c: silverDark.opacity(0.40))
                .offset(x: -p * 1.52, y: p * 1.48)
            rect(w: 0.12, h: 2.15, c: silverDark.opacity(0.25))
                .offset(x: p * 1.52, y: p * 1.48)

            // ── 당근 로고 (뚜껑 중앙, 맥북 사과 로고 패러디)
            carrotLogoView
                .offset(y: p * 1.42)

            // ── 힌지
            rect(w: 3.50, h: 0.20, c: silverDark)
                .offset(y: p * 2.64)

            // ── 키보드 베이스 (뚜껑보다 살짝 넓어 원근감)
            rect(w: 3.80, h: 0.44, c: silverMid)
                .offset(y: p * 2.90)

            // ── 키보드 베이스 앞면 두께 (측면 시점 입체감)
            rect(w: 3.80, h: 0.16, c: silverDark)
                .offset(y: p * 3.13)

            // ── 키 배열 힌트
            rect(w: 3.10, h: 0.13, c: silverDark.opacity(0.32))
                .offset(y: p * 2.82)

            // ── 트랙패드
            rect(w: 1.0, h: 0.22, c: silverDark.opacity(0.20))
                .offset(y: p * 3.02)
        }
    }

    // MARK: - 당근 로고 (픽셀아트, 맥북 사과 로고 패러디 — 한 입 베어먹은 당근)

    private var carrotLogoView: some View {
        ZStack {
            // 당근 꼭지 잎 — 세 갈래
            rect(w: 0.12, h: 0.28, c: leafCol)
                .rotationEffect(.degrees(-20))
                .offset(x: -p * 0.10, y: -p * 0.56)
            rect(w: 0.12, h: 0.28, c: leafCol)
                .rotationEffect(.degrees(20))
                .offset(x:  p * 0.10, y: -p * 0.56)
            rect(w: 0.12, h: 0.24, c: leafCol)
                .offset(y: -p * 0.52)

            // 당근 몸통 — 위가 넓고 아래로 갈수록 좁아지는 계단식 픽셀 형태
            rect(w: 0.52, h: 0.14, c: carrotCol)
                .offset(y: -p * 0.28)
            rect(w: 0.46, h: 0.14, c: carrotCol)
                .offset(y: -p * 0.14)
            rect(w: 0.40, h: 0.14, c: carrotCol)
                .offset(y:  p * 0.00)
            rect(w: 0.32, h: 0.14, c: carrotCol)
                .offset(y:  p * 0.14)
            rect(w: 0.22, h: 0.14, c: carrotCol)
                .offset(y:  p * 0.28)
            rect(w: 0.12, h: 0.13, c: carrotCol)
                .offset(y:  p * 0.41)

            // 한 입 베어먹은 자국
            rect(w: 0.20, h: 0.18, c: silverCol)
                .offset(x: p * 0.22, y: -p * 0.20)
        }
    }

    private func rect(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }
}
