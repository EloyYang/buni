import SwiftUI

struct UsageBarView: View {
    let percent: Double      // 0–100

    private let totalSegments = 10
    private let segmentH: CGFloat = 9
    private let segmentGap: CGFloat = 2
    private let borderW: CGFloat = 1.5

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
        GeometryReader { geo in
            let totalGaps = CGFloat(totalSegments - 1) * segmentGap
            let segW = (geo.size.width - totalGaps) / CGFloat(totalSegments)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.55), lineWidth: borderW)
                    .frame(height: segmentH + borderW * 2)

                HStack(spacing: segmentGap) {
                    ForEach(0..<totalSegments, id: \.self) { i in
                        let filled = i < filledCount
                        Rectangle()
                            .fill(filled
                                  ? segmentColor(i)
                                  : Color.white.opacity(0.10))
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
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
