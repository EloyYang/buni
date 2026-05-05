import Cocoa

/// 9×9 도트 그리드로 토끼 얼굴 아이콘을 생성합니다.
///   E = 귀(몸통색)   p = 귀 안쪽(핑크)
///   W = 몸통(연회색) B = 눈(검정)   P = 코(핑크)
///   . = 투명
enum MenuBarIcon {
    private static let grid: [[Character]] = [
        [".", "E", "p", ".", ".", ".", "E", "p", "."],   // 0 귀 위
        [".", "E", "p", ".", ".", ".", "E", "p", "."],   // 1 귀
        [".", "E", "E", ".", ".", ".", "E", "E", "."],   // 2 귀 아래
        ["W", "W", "W", "W", "W", "W", "W", "W", "W"], // 3 머리 위
        ["W", "W", "W", "W", "W", "W", "W", "W", "W"], // 4 머리
        ["W", "B", "W", "W", "W", "W", "W", "B", "W"], // 5 눈
        ["W", "W", "W", "W", "W", "W", "W", "W", "W"], // 6 코 위
        ["W", "W", "W", "P", "P", "W", "W", "W", "W"], // 7 코
        [".", "W", "W", "W", "W", "W", "W", "W", "."], // 8 턱
    ]

    private static let body  = NSColor(red: 0.91, green: 0.91, blue: 0.94, alpha: 1)
    private static let pink  = NSColor(red: 0.95, green: 0.72, blue: 0.78, alpha: 1)
    private static let black = NSColor(white: 0.08, alpha: 1)

    static func make(size: CGFloat = 18) -> NSImage {
        let rows = grid.count
        let cols = grid[0].count
        let cell = size / CGFloat(cols)   // 18 / 9 = 2pt per dot

        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }

        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() {
                let color: NSColor
                switch ch {
                case "W": color = body
                case "E": color = body
                case "p": color = pink
                case "P": color = pink
                case "B": color = black
                default: continue
                }
                // CG 좌표는 좌하단 기준이므로 행을 뒤집음
                let rect = NSRect(
                    x: CGFloat(c) * cell,
                    y: CGFloat(rows - 1 - r) * cell,
                    width: cell, height: cell
                )
                color.setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
        return img
    }
}
