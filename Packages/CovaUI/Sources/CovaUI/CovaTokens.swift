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
    /// 会员金（04 §3.F / components §9）。**Light 用深金、Dark 用亮金** —— 双值已在 tokens 里备好，
    /// 实现侧不得再自行挑一个（04 §5 明文）。
    public static let memberGold = dynamic("#66511F", "#D9A52F")
    public static let memberGoldSoft = dynamic("#F7F0D8", "#2A2210")
    public static let memberGoldBorder = dynamic("#C8AA5A", "#66511F")
    public static let enterpriseBlue = dynamic("#006EDC", "#79BEFF")
    public static let enterpriseBlueSoft = dynamic("#EAF4FF", "#0A2540")
    public static let enterpriseBlueBorder = dynamic("#84BDF3", "#1D4ED8")
}

/// 渐变（`tokens.json` 的 `gradient.*`，双主题同值 ⇒ 不走 `dynamic` 双值）。
///
/// **方向是近似**：CSS 的 `110deg`（自正北顺时针 110°，即「偏下的横向」）在 SwiftUI 里落成
/// `.topLeading → .bottomTrailing` 这条轴 —— 库里没有「任意角度线性渐变」的档位，
/// 而 110° 与这条 45° 轴同象限（向右下）。**色标与位置逐字照抄 JSON**，不重排不取整：
/// 未给位置的两个色标按 CSS 规则在 42%→100% 之间等分（61.3% / 80.7%）。
public enum CovaGradient {
    /// `gradient.ai`：AI 语境渐变。**只**用于创作入口与 agent 文字（design-language §2 红线）。
    public static let ai = LinearGradient(
        stops: [
            .init(color: CovaColor.dynamic("#FF9A3D", "#FF9A3D"), location: 0),
            .init(color: CovaColor.dynamic("#FF6B00", "#FF6B00"), location: 0.42),
            .init(color: CovaColor.dynamic("#E84E8A", "#E84E8A"), location: 0.613),
            .init(color: CovaColor.dynamic("#FF9A3D", "#FF9A3D"), location: 0.807),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// `gradient.brandButton`：主按钮深渐变（白字对比度达标）。
    public static let brandButton = LinearGradient(
        stops: [
            .init(color: CovaColor.dynamic("#D04E00", "#D04E00"), location: 0),
            .init(color: CovaColor.dynamic("#C24E00", "#C24E00"), location: 0.42),
            .init(color: CovaColor.dynamic("#C03470", "#C03470"), location: 0.613),
            .init(color: CovaColor.dynamic("#D04E00", "#D04E00"), location: 0.807),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
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

/// 字阶（SF Pro / SF Mono）。**每档映射到同名 Apple textStyle ⇒ 整站跟随 Dynamic Type**：
/// 默认档（Large）下与 `tokens.json` 的 point 一字不差 —— largeTitle 34 / title 28 /
/// headline 17 semibold / body 17 / callout 15 / subhead→footnote 13 / caption→caption2 11 /
/// mono→footnote 等宽 13；系统调到 AX 档时随之一并放大。
///
/// 这里刻意不用 `Font.system(size:)`：固定 point **不跟随 Dynamic Type**，
/// 而原先的实现正是"注释说全量适配、代码按死字号"的那种不一致（M3 可访问性审计抓到）。
///
/// `tokens.json` 里 largeTitle/title 的 `tracking: -0.01` **仍未落地**：SwiftUI 的字距是 `Text`
/// 侧修饰符，`Font` 上没有对应能力；原先那个 `tracking:` 形参是个从不读取的死参数（本次删掉），
/// 所以观感与既有验收截图一致 —— 字距保真留给 G2 逐屏验收按屏补，不在这里谎称已做。
public enum CovaType {
    public static let largeTitle = Font.system(.largeTitle).weight(.bold)
    public static let title = Font.system(.title).weight(.bold)
    public static let headline = Font.system(.headline)
    public static let body = Font.system(.body)
    public static let callout = Font.system(.callout)
    public static let subhead = Font.system(.footnote)
    /// 设计档 `caption` 是 11pt ⇒ Apple `.caption2`（`.caption` 为 12pt，不是这一档）。
    public static let caption = Font.system(.caption2)
    public static let mono = Font.system(.footnote, design: .monospaced)

    /// 全局 tabular-nums：时间/余额/进度一律等宽数字。
    public static func digits(_ text: String) -> Text {
        Text(text).font(mono).monospacedDigit()
    }
}

extension EnvironmentValues {
    /// 系统「文字大小」进入 AX 档（≥ AX1）时为真。各屏据此按 spec §可访问性 **改排版**
    /// （网格降列、右值另起一行、文本允许两行……），而不是让放大后的文字被 `lineLimit` 截掉。
    public var covaAXLayout: Bool { dynamicTypeSize >= .accessibility1 }
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
