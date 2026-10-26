import SwiftUI

struct UsageBarView: View {
    let percent: Double        // 0–100
    var label: String = ""     // 예) "36%" — 바 아래 왼쪽 표시
    var resetTime: String = "" // 예) "4:32" — 바 아래 오른쪽 표시 (자정까지 남은 시간)
    var monthlyTokens: Int = 0 // 이번 달 누적 토큰 → 레벨 계산

    @Environment(\.colorScheme) private var colorScheme

    // 500K 토큰마다 1레벨 상승, 무한 증가
    private var monthlyLevel: Int { monthlyTokens / 500_000 + 1 }
    private let levelColor = Color(red: 0.95, green: 0.80, blue: 0.15)

    private let totalSegments = 10
    private let segmentH: CGFloat = 9
    private let segmentGap: CGFloat = 2
    private let borderW: CGFloat = 1.5

    // 테마별 색상
    private var borderColor: Color {
        colorScheme == .light
            ? Color.black.opacity(0.20)
            : Color.white.opacity(0.55)
    }
    private var emptySegmentColor: Color {
        colorScheme == .light
            ? Color.black.opacity(0.08)
            : Color.white.opacity(0.10)
    }
    private var labelColor: Color {
        colorScheme == .light
            ? Color(red: 0.35, green: 0.35, blue: 0.35)
            : Color.white.opacity(0.45)
    }
    private var resetColor: Color {
        colorScheme == .light
            ? Color(red: 0.50, green: 0.50, blue: 0.50)
            : Color.white.opacity(0.30)
    }

    private func segmentColor(_ index: Int) -> Color {
        let ratio = Double(index + 1) / Double(totalSegments)
        if ratio <= 0.5  { return Color(red: 0.3,  green: 0.85, blue: 0.35) }
        if ratio <= 0.75 { return Color(red: 0.95, green: 0.80, blue: 0.15) }
        return Color(red: 0.95, green: 0.30, blue: 0.20)
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
                    RoundedRectangle(cornerRadius: 3)
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
                                            .fill(Color.white.opacity(0.28))
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
