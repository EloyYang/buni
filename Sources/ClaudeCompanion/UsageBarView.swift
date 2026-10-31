import SwiftUI

struct UsageBarView: View {
    let percent: Double        // 0–100
    var label: String = ""     // 예) "36%" — 바 아래 왼쪽 표시
    var resetTime: String = "" // 예) "4:32" — 바 아래 오른쪽 표시 (자정까지 남은 시간)
    var monthlyTokens: Int = 0 // 이번 달 누적 토큰 → 레벨 계산

    @Environment(\.colorScheme) private var colorScheme

    // 500K 토큰마다 1레벨 상승, 무한 증가
    private var monthlyLevel: Int { monthlyTokens / 500_000 + 1 }
    private let levelColor = Color.buniWarn

    private let totalSegments = 10
    private let segmentH: CGFloat = 9
    private let segmentGap: CGFloat = 2
    private let borderW: CGFloat = 1.5

    // 테마별 색상 — 디자인 토큰 (밝은 배경은 light, 어두운 배경은 dark 팔레트)
    private var palette: BuniPalette { colorScheme == .light ? BuniTheme.light : BuniTheme.dark }
    private var borderColor: Color { BuniTheme.color(palette.dim) }
    private var emptySegmentColor: Color { BuniTheme.color(palette.raised) }
    private var labelColor: Color { BuniTheme.color(palette.dim) }
    private var resetColor: Color { BuniTheme.color(palette.dim).opacity(0.75) }

    private func segmentColor(_ index: Int) -> Color {
        let ratio = Double(index + 1) / Double(totalSegments)
        if ratio <= 0.5  { return .buniOk }
        if ratio <= 0.75 { return .buniWarn }
        return .buniDanger
    }

    private var filledCount: Int {
        Int((percent / 100.0) * Double(totalSegments) + 0.5)
            .clamped(to: 0...totalSegments)
    }

    var body: some View {
        VStack(spacing: 2) {
            // 바 위: 레벨 표시
            HStack {
                Text("★ Lv.\(monthlyLevel)")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(levelColor)
                Spacer()
            }
            .padding(.horizontal, 6)

            // 게이지 바
            GeometryReader { geo in
                let totalGaps = CGFloat(totalSegments - 1) * segmentGap
                let segW = (geo.size.width - totalGaps) / CGFloat(totalSegments)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: BuniTheme.rSm / 2)
                        .stroke(borderColor, lineWidth: borderW)
                        .frame(height: segmentH + borderW * 2)

                    HStack(spacing: segmentGap) {
                        ForEach(0..<totalSegments, id: \.self) { i in
                            let filled = i < filledCount
                            Rectangle()
                                .fill(filled ? segmentColor(i) : emptySegmentColor)
                                .frame(width: segW, height: segmentH)
                                .overlay(alignment: .top) {
                                    if filled {
                                        Rectangle()
                                            .fill(Color.buniInk.opacity(0.28))
                                            .frame(height: 2)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, borderW)
                    .animation(.easeInOut(duration: 0.35), value: filledCount)
                }
            }
            .frame(height: segmentH + borderW * 2)
            .padding(.horizontal, 6)

            // 바 아래 라벨: 왼쪽 % + 오른쪽 리셋 시간
            if !label.isEmpty || !resetTime.isEmpty {
                HStack {
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(labelColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer()
                    if !resetTime.isEmpty {
                        Text("↺ \(resetTime)")
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(resetColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
