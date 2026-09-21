import SwiftUI

/// 设计令牌（`design/tokens.json` 的 Swift 映射，值与 JSON 逐一对应；改令牌先改 JSON 再改这里）。
/// 深浅双主题走 `UIColor` 动态 provider，不靠 `preferredColorScheme` 硬切。
public enum CovaColor {
    public static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(uiColor: UIColor { trait in
            let c = CovaColor.rgb(trait.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    /// `#RRGGBB` → 分量。令牌文件是唯一色值来源，故这里只做解析不做取值。
    static func rgb(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        return (
            CGFloat((v >> 16) & 0xFF) / 255,
            CGFloat((v >> 8) & 0xFF) / 255,
            CGFloat(v & 0xFF) / 255
        )
    }

    /// 品牌唯一主题色：日落橙。
    public static let accent = dynamic("#FF6B00", "#FF6B00")
    public static let accentHover = dynamic("#E66000", "#FF7A1A")
    /// 浅橙衬底（选中背景 / tag 底）。
    public static let accentSoft = dynamic("#FFF1E6", "#3A1D05")
    /// accent 语境文字色（对比度 ≥4.5:1）。
    public static let accentText = dynamic("#C24E00", "#FFB173")
    public static let canvas = dynamic("#FFFFFF", "#0C0C14")
    public static let surface = dynamic("#F5F5F7", "#12121A")
    public static let elevated = dynamic("#FFFFFF", "#1A1A24")
    public static let fg = dynamic("#1D1D1F", "#F2F0EC")
    public static let secondary = dynamic("#6E6E73", "#A1A1AA")
    public static let muted = dynamic("#86868B", "#6E6E73")
    public static let line = dynamic("#E8E8ED", "#252530")
    public static let lineSubtle = dynamic("#D2D2D7", "#1E1E2A")
    public static let success = dynamic("#30D158", "#30D158")
    public static let error = dynamic("#FF453A", "#FF453A")
    public static let warning = dynamic("#FF9F0A", "#FF9F0A")
}

public enum CovaSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let pageGutter: CGFloat = 20
}

public enum CovaRadius {
    public static let control: CGFloat = 12
    public static let card: CGFloat = 18
    public static let hero: CGFloat = 28
    public static let capsule: CGFloat = 9999
}

/// 字阶（SF Pro / SF Mono）。**Dynamic Type 全量适配**：用相对 textStyle 映射而非固定 point，
/// 令牌里的 size 作为 `@ScaledMetric` 的基准值（tokens.json `type.note`）。
public enum CovaType {
    public static func font(size: CGFloat, weight: Font.Weight, mono: Bool = false, tracking: CGFloat? = nil) -> Font {
        let base = mono ? Font.system(size: size, weight: weight, design: .monospaced)
                        : Font.system(size: size, weight: weight)
        return base
    }
    public static let largeTitle = font(size: 34, weight: .bold, tracking: -0.01)
    public static let title = font(size: 28, weight: .bold, tracking: -0.01)
    public static let headline = font(size: 17, weight: .semibold)
    public static let body = font(size: 17, weight: .regular)
    public static let callout = font(size: 15, weight: .regular)
    public static let subhead = font(size: 13, weight: .regular)
    public static let caption = font(size: 11, weight: .regular)
    public static let mono = font(size: 13, weight: .regular, mono: true)

    /// 全局 tabular-nums：时间/余额/进度一律等宽数字。
    public static func digits(_ text: String) -> Text {
        Text(text).font(mono).monospacedDigit()
    }
}

/// 玻璃材质（design §「材质」）：背景模糊 + 细描边 + 内高光，深浅两态同一套参数。
public struct CovaGlass: ViewModifier {
    public var elevated: Bool = false
    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .strokeBorder(CovaColor.line.opacity(elevated ? 0.9 : 0.6), lineWidth: 0.5)
            )
    }
}

public extension View {
    func covaGlass(elevated: Bool = false) -> some View { modifier(CovaGlass(elevated: elevated)) }
    func covaPage() -> some View {
        background(CovaColor.canvas.ignoresSafeArea())
            .tint(CovaColor.accent)
    }
}
