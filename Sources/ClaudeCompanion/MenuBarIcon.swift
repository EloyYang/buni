import Cocoa

/// 9×9 도트 그리드로 토끼 실루엣 아이콘을 생성합니다.
///   X = 흰색(불투명)   . = 투명   (눈·코는 투명 구멍으로 표현)
///
/// 귀: 4줄 × 폭 2칸 (강조)
/// 얼굴: 7칸 폭(슬림) / 눈·코 투명 구멍
enum MenuBarIcon {
    private static let grid: [[Character]] = [
        [".", "X", "X", ".", ".", ".", "X", "X", "."],  // 0 귀
        [".", "X", "X", ".", ".", ".", "X", "X", "."],  // 1 귀
        [".", "X", "X", ".", ".", ".", "X", "X", "."],  // 2 귀
        [".", "X", "X", ".", ".", ".", "X", "X", "."],  // 3 귀 아래
        [".", "X", "X", "X", "X", "X", "X", "X", "."], // 4 머리 (7칸)
        [".", "X", ".", "X", "X", "X", ".", "X", "."], // 5 눈 (투명 구멍)
        [".", "X", "X", "X", ".", "X", "X", "X", "."], // 6 코 (투명 구멍)
        [".", "X", "X", "X", "X", "X", "X", "X", "."], // 7 얼굴
        [".", ".", "X", "X", "X", "X", "X", ".", "."], // 8 턱 (5칸)
    ]

    static func make(size: CGFloat = 18) -> NSImage {
        let rows = grid.count
        let cols = grid[0].count
        let cell = size / CGFloat(cols)

        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor.white.setFill()
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() {
                guard ch == "X" else { continue }
                let rect = NSRect(
                    x: CGFloat(c) * cell,
                    y: CGFloat(rows - 1 - r) * cell,
                    width: cell, height: cell
                )
                NSBezierPath(rect: rect).fill()
            }
        }
        return img
    }

    /// 부니 아이콘 아래에 사용량 게이지 바를 붙인 이미지.
    /// 템플릿 이미지라 색은 못 쓰므로, 게이지의 빈 배경은 옅게(반투명),
    /// 채워진 부분은 불투명하게 그려서 라이트/다크 모드 어디서나
    /// 자연스러운 "채워지는 바"처럼 보이게 한다.
    static func makeWithGauge(iconSize: CGFloat = 14,
                              barWidth: CGFloat = 20, barHeight: CGFloat = 3,
                              gap: CGFloat = 2, percent: Double?) -> NSImage {
        let totalW = max(iconSize, barWidth)
        let totalH = iconSize + gap + barHeight
        let img = NSImage(size: NSSize(width: totalW, height: totalH))
        img.lockFocus()
        defer { img.unlockFocus() }

        // ── 아이콘 (위쪽, 가로 중앙 정렬)
        let rows = grid.count
        let cols = grid[0].count
        let cell = iconSize / CGFloat(cols)
        let iconX = (totalW - iconSize) / 2
        let iconY = barHeight + gap
        NSColor.white.setFill()
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() {
                guard ch == "X" else { continue }
                let rect = NSRect(
                    x: iconX + CGFloat(c) * cell,
                    y: iconY + CGFloat(rows - 1 - r) * cell,
                    width: cell, height: cell
                )
                NSBezierPath(rect: rect).fill()
            }
        }

        // ── 게이지 바 (아래쪽)
        let barX = (totalW - barWidth) / 2
        let r = barHeight / 2
        NSColor.white.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: 0, width: barWidth, height: barHeight),
                     xRadius: r, yRadius: r).fill()
        if let pct = percent {
            let ratio  = max(0, min(1, pct / 100))
            let fillW  = max(barHeight, barWidth * CGFloat(ratio))  // 둥근 모서리 안 뭉개질 최소 폭
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: 0, width: fillW, height: barHeight),
                         xRadius: r, yRadius: r).fill()
        }
        return img
    }
}
