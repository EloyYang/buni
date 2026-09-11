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
}
