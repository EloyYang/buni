import SwiftUI
import AppKit

// 부니 디자인 시스템 토큰 — docs/design-system.md 의 값과 같다 (Windows `buni_tokens.py`·사이트 CSS 와 공통).
// 새 hex 는 여기에만 쓰고 뷰에서는 토큰만 쓴다. 캐릭터 그림(*CharacterView)은 이 시스템 밖이다.

enum BuniTokens {
    // MARK: 색 (다크/라이트 자동)
    enum Color {
        typealias C = SwiftUI.Color

        static let bgCanvas     = dynamic(dark: 0x121214, light: 0xF5F5F7)
        static let bgSidebar    = dynamic(dark: 0x0E0E10, light: 0xECECEE)
        static let surface1     = dynamic(dark: 0x1A1A1D, light: 0xFFFFFF)
        static let surface2     = dynamic(dark: 0x232326, light: 0xF2F2F4)
        static let surface3     = dynamic(dark: 0x2C2C30, light: 0xE5E5E8)
        static let borderSubtle = dynamic(dark: 0x28282C, light: 0xE2E2E6)
        static let borderStrong = dynamic(dark: 0x3C3C42, light: 0xC9C9CF)

        static let textPrimary   = dynamic(dark: 0xF5F5F7, light: 0x1D1D1F)
        static let textSecondary = dynamic(dark: 0xC7C7CC, light: 0x515154)
        static let textTertiary  = dynamic(dark: 0x8E8E93, light: 0x6E6E73)
        static let textOnAccent  = dynamic(dark: 0x1A1206, light: 0x1A1206)

        static let accentBase  = dynamic(dark: 0xF28C2E, light: 0xF28C2E)
        /// PillButtonStyle 의 '조용한 보조 버튼' 표시 — 색 자체는 textTertiary 와 같다.
        static let quiet       = textTertiary
        static let accentHover = dynamic(dark: 0xFFB066, light: 0xD97A1F)
        static let accentText  = dynamic(dark: 0xFFB066, light: 0xA85500)
        static let accentSoft  = dynamic(dark: 0x33261A, light: 0xFDEBD6)
        static let success     = dynamic(dark: 0x4DC780, light: 0x1F8A4C)
        static let warning     = dynamic(dark: 0xE8C34A, light: 0x9A6B00)
        static let danger      = dynamic(dark: 0xE6665A, light: 0xC93A2E)
        static let info        = dynamic(dark: 0x6AA9FF, light: 0x2255BB)
        static let leaf        = dynamic(dark: 0x6BBF59, light: 0x4E9A3F)

        /// 글자가 전부 흰색이던 곳(색 면 위 글자) — 상태색 면 위에서는 항상 밝은 글자.
        static let onSolid = C(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)

        static func nsColor(dark: UInt32, light: UInt32) -> NSColor {
            NSColor(name: nil) { ap in
                let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) != .aqua
                return NSColor(hex: isDark ? dark : light)
            }
        }
        static func dynamic(dark: UInt32, light: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: nsColor(dark: dark, light: light))
        }
    }

    // MARK: 간격 (4 단위)
    enum Space {
        static let s1: CGFloat = 2
        static let s2: CGFloat = 4
        static let s3: CGFloat = 8
        static let s4: CGFloat = 12
        static let s5: CGFloat = 16
        static let s6: CGFloat = 20
        static let s7: CGFloat = 24
        static let s8: CGFloat = 32
    }

    // MARK: 반경
    enum Radius {
        static let none: CGFloat = 0
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: 타이포 (시스템 글꼴만)
    enum Font {
        static let sizeXs: CGFloat = 11
        static let sizeSm: CGFloat = 12
        static let sizeMd: CGFloat = 13
        static let sizeLg: CGFloat = 15
        static let sizeXl: CGFloat = 18
        static let size2xl: CGFloat = 24

        static let body    = SwiftUI.Font.system(size: sizeMd)
        static let caption = SwiftUI.Font.system(size: sizeXs, weight: .medium)
        static let small   = SwiftUI.Font.system(size: sizeSm)
        static let title   = SwiftUI.Font.system(size: sizeLg, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: sizeXl, weight: .semibold, design: .rounded)
        static let display = SwiftUI.Font.system(size: size2xl, weight: .bold, design: .rounded)
        static let mono    = SwiftUI.Font.system(size: sizeSm, design: .monospaced)
    }

    // MARK: 그림자 (다크/라이트 불투명도)
    struct ShadowSpec { let radius: CGFloat; let x: CGFloat; let y: CGFloat; let dark: Double; let light: Double }
    enum Shadow {
        static let e1 = ShadowSpec(radius: 2,  x: 0, y: 1,  dark: 0.40, light: 0.08)
        static let e2 = ShadowSpec(radius: 12, x: 0, y: 4,  dark: 0.45, light: 0.12)
        static let e3 = ShadowSpec(radius: 32, x: 0, y: 12, dark: 0.55, light: 0.18)
    }

    // MARK: 움직임
    enum Motion {
        static let fast = 0.12
        static let base = 0.20
        static let slow = 0.32
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// 토큰 그림자 — 다크/라이트에서 불투명도가 달라진다 (잉크색 #1C1B1F 기준).
    func buniShadow(_ s: BuniTokens.ShadowSpec) -> some View {
        modifier(BuniShadowModifier(spec: s))
    }
}

private struct BuniShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let spec: BuniTokens.ShadowSpec
    func body(content: Content) -> some View {
        content.shadow(color: scheme == .dark ? .black.opacity(spec.dark)
                                              : SwiftUI.Color(.sRGB, red: 28/255, green: 27/255, blue: 31/255, opacity: spec.light),
                       radius: spec.radius, x: spec.x, y: spec.y)
    }
}

/// 짧은 별칭 — 뷰에서 `BT.textPrimary` 처럼 쓴다.
typealias BT = BuniTokens.Color
