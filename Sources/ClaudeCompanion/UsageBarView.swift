import SwiftUI

struct UsageBarView: View {
    let percent: Double      // 0–100
    let sessionStart: Date?

    @State private var elapsed: TimeInterval = 0
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var blink = false
    private let blinkTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let totalSegments = 10

    private func segmentColor(_ index: Int) -> Color {
        let ratio = Double(index + 1) / Double(totalSegments)
        if ratio <= 0.5  { return Color(red: 0.3,  green: 0.85, blue: 0.35) }
        if ratio <= 0.75 { return Color(red: 0.95, green: 0.80, blue: 0.15) }
        return Color(red: 0.95, green: 0.30, blue: 0.20)
    }

    private let segmentH: CGFloat = 9
    private let segmentGap: CGFloat = 2
    private let borderW: CGFloat = 1.5

    private var filledCount: Int {
        Int((percent / 100.0) * Double(totalSegments) + 0.5)
            .clamped(to: 0...totalSegments)
    }

    /// 현재 사용률 기반 남은 시간 추정 (분)
    /// rate = percent / elapsed_min → remaining = (100 - percent) / rate
    private var remainingMinutes: Int? {
        let elapsedMin = elapsed / 60
        guard elapsedMin >= 1, percent >= 1 else { return nil }
        let rate = percent / elapsedMin          // %/분
        let remaining = (100.0 - percent) / rate  // 남은 분
        guard remaining >= 0 else { return 0 }
        return Int(remaining.rounded())
    }

    private var countdownText: String {
        guard sessionStart != nil else { return "" }
        guard let mins = remainingMinutes else { return "--분" }
        if mins == 0 { return "곧 초기화" }
        let h = mins / 60
        let m = mins % 60
        if h > 0 && m > 0 { return "\(h)시간 \(m)분" }
        if h > 0           { return "\(h)시간" }
        return "\(m)분"
    }

    // 남은 시간에 따른 점 색상
    private var dotColor: Color {
        guard let mins = remainingMinutes else {
            return Color(red: 0.3, green: 0.85, blue: 0.35)
        }
        if mins <= 5  { return Color(red: 0.95, green: 0.30, blue: 0.20) }
        if mins <= 30 { return Color(red: 0.95, green: 0.80, blue: 0.15) }
        return Color(red: 0.3, green: 0.85, blue: 0.35)
    }

    var body: some View {
        VStack(spacing: 3) {
            // ── 상단: 남은 시간 ────────────────────────
            if sessionStart != nil {
                HStack(spacing: 4) {
                    Spacer()
                    Circle()
                        .fill(dotColor)
                        .frame(width: 4, height: 4)
                        .opacity(blink ? 1 : 0.25)
                    Text(countdownText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .animation(.none, value: countdownText)
                }
            }

            // ── 세그먼트 바 ────────────────────────────
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
        }
        .padding(.horizontal, 6)
        // 30초마다 카운트다운 재계산
        .onReceive(ticker) { _ in
            guard let start = sessionStart else { elapsed = 0; return }
            elapsed = Date().timeIntervalSince(start)
        }
        // 1초마다 점 깜빡임
        .onReceive(blinkTimer) { _ in
            blink.toggle()
        }
        .onAppear {
            blink = true
            if let start = sessionStart {
                elapsed = Date().timeIntervalSince(start)
            }
        }
        .onChange(of: sessionStart) { newVal in
            elapsed = newVal.map { Date().timeIntervalSince($0) } ?? 0
        }
        .onChange(of: percent) { _ in
            // 사용률 바뀔 때마다 즉시 재계산
            if let start = sessionStart {
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
