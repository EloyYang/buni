import SwiftUI
import AppKit

/// 부니 디자인 시스템 토큰 (맥). 값의 기준은 docs/design-system.md,
/// Windows 는 windows/buni_theme.py, 사이트는 docs/index.html :root — 셋을 같이 고친다.
struct BuniPalette {
    let bg, rail, panel, field, raised, line: UInt32
    let ink, ink2, dim: UInt32
    let accent, accentInk: UInt32
    let info, ok, warn, danger: UInt32
}

enum BuniTheme {
    static let dark = BuniPalette(
        bg: 0x1E1E24, rail: 0x17171D, panel: 0x26262E, field: 0x2A2A34, raised: 0x34343F, line: 0x3A3A44,
        ink: 0xF2F2F6, ink2: 0xC4C4CE, dim: 0x8A8A98,
        accent: 0xF28C2E, accentInk: 0x1A1206,
        info: 0x6AA9FF, ok: 0x4DC780, warn: 0xD9B25A, danger: 0xE65A66)
    static let light = BuniPalette(
        bg: 0xF5F5F7, rail: 0xECECF0, panel: 0xFFFFFF, field: 0xF0F0F4, raised: 0xE4E4EA, line: 0xD8D8E0,
        ink: 0x1D1D22, ink2: 0x4A4A55, dim: 0x6A6A78,
        accent: 0xD9731A, accentInk: 0xFFFFFF,
        info: 0x2F6FD6, ok: 0x1F8F4E, warn: 0xA9791A, danger: 0xC8323F)

    /// 앱 창은 다크 고정 — 라이트는 정의만 해 둔다.
    static let c = dark

    // 간격 (4pt 격자)
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    // 모서리
    static let rSm: CGFloat = 6, rMd: CGFloat = 10, rLg: CGFloat = 14
    // 글자 크기
    static let title: CGFloat = 18, heading: CGFloat = 13, body: CGFloat = 12, small: CGFloat = 11, caption: CGFloat = 10

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 부니 버튼: primary 는 accent 면 + accent_ink 글자, 아니면 raised 면 + ink 글자. 꺼지면 흐리게.
struct BuniButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: BuniTheme.body, weight: .semibold))
            .foregroundColor(primary ? .buniAccentInk : .buniInk)
            .padding(.horizontal, BuniTheme.lg)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: BuniTheme.rMd)
                    .fill(primary ? Color.buniAccent : Color.buniRaised)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .opacity(enabled ? 1 : 0.45)
    }
}

extension Color {
    static let buniBg = BuniTheme.color(BuniTheme.c.bg)
    static let buniRail = BuniTheme.color(BuniTheme.c.rail)
    static let buniPanel = BuniTheme.color(BuniTheme.c.panel)
    static let buniField = BuniTheme.color(BuniTheme.c.field)
    static let buniRaised = BuniTheme.color(BuniTheme.c.raised)
    static let buniLine = BuniTheme.color(BuniTheme.c.line)
    static let buniInk = BuniTheme.color(BuniTheme.c.ink)
    static let buniInk2 = BuniTheme.color(BuniTheme.c.ink2)
    static let buniDim = BuniTheme.color(BuniTheme.c.dim)
    static let buniAccent = BuniTheme.color(BuniTheme.c.accent)
    static let buniAccentInk = BuniTheme.color(BuniTheme.c.accentInk)
    static let buniInfo = BuniTheme.color(BuniTheme.c.info)
    static let buniOk = BuniTheme.color(BuniTheme.c.ok)
    static let buniWarn = BuniTheme.color(BuniTheme.c.warn)
    static let buniDanger = BuniTheme.color(BuniTheme.c.danger)
}
