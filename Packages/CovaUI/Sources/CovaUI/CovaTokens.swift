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
    /// 浅橙衬底（tag 底 / 语义装饰；v2.65.0 起不再承担选中态——选中用 `selectedBg`）。
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
    /// 深色五值按 2026-10-06 裁定（`文档/设计/cova-tokens.json` `_meta.rulings`：web globals.css
    /// `.dark` 实际值为唯一准；无深色对应值的取与浅色同 token 色相/明度关系更近的一端，即 mac 同值），
    /// iOS 原分叉值全部被否决（旧值见 rulings 的 `rejected` 字段，这里不再复述免得 grep 误命中）。
    public static let memberGold = dynamic("#66511F", "#F2DDA2")
    public static let memberGoldSoft = dynamic("#F7F0D8", "#2A2413")
    public static let memberGoldBorder = dynamic("#C8AA5A", "#8A7440")
    public static let enterpriseBlue = dynamic("#006EDC", "#79BEFF")
    public static let enterpriseBlueSoft = dynamic("#EAF4FF", "#102A44")
    public static let enterpriseBlueBorder = dynamic("#84BDF3", "#3A6A9E")
    /// `color.tagScene` / `color.tagMood`：25 分类卡的左缘标识条色（03 §4 行内标签胶囊同源）。
    public static let tagScene = dynamic("#0D9488", "#2DD4BF")
    public static let tagMood = dynamic("#6366F1", "#818CF8")
    /// 25 §5 的深浅合成色：分类卡/封面占位在 Light 用 `surface`、Dark 用 `elevated`
    /// （「避免深底上更深的灰」——两格已在 tokens 里，这里只做那一档拼接，不新增色值）。
    public static let cardSurface = dynamic("#F5F5F7", "#1A1A24")
    /// `color.selected`：选中态文字色（web v2.65.0 `.cova-filter-current` 同值；
    /// 橙色不承担选中填充，见 design/README「与 web 的统一设计语言」）。
    public static let selected = dynamic("#1D1D1F", "#F2F0EC")
    /// `color.selectedBg`：选中态衬底（web `rgb(0,0,0,.08)`/`rgb(255,255,255,.12)`；
    /// #hex 带 alpha 逐值，不走 `opacity` 二次近似）。
    public static let selectedBg = dynamicAlpha(0x000000, 0.08, 0xFFFFFF, 0.12)
    /// `color.focusRing`：输入聚焦描边（web #8A8F98 中性灰，刻意不用橙）。
    public static let focusRing = dynamic("#8A8F98", "#8A8F98")

    /// `#RRGGBBAA` 逐值（含 alpha 的 token 用这支，避免 `opacity` 与底色叠加产生二次近似）。
    static func dynamicAlpha(_ lightRGB: UInt64, _ lightA: CGFloat, _ darkRGB: UInt64, _ darkA: CGFloat) -> Color {
        Color(uiColor: UIColor { trait in
            let v = trait.userInterfaceStyle == .dark ? darkRGB : lightRGB
            let a = trait.userInterfaceStyle == .dark ? darkA : lightA
            return UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: a
            )
        })
    }
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
    /// `radius.cover`：封面/曲目卡圆角（web `track-card` 16px + inset hairline 同档）。
    public static let cover: CGFloat = 16
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
    /// `type.display`（28/700，2026-10-02 入档）：**只给 01 问候区**（token 描述明写
    /// 「不进列表/表单屏」）。默认档 28pt ⇒ Apple `.title`；tracking −0.01 由调用侧的
    /// `.tracking(-0.28)` 表达（见 `HomeView` 问候区注释）。
    public static let display = Font.system(.title).weight(.bold)
    // 字阶：D24 第一刀下移一档，第二刀按用户验收定的**紧凑档**（参照网易云/QQ 音乐）再收一档：原 largeTitle 34 / title 28 在 402pt 宽的手机上会把
    // 一屏挤成两三块，且与 headline 17 之间没有过渡 ⇒ 整屏没有"小"的层次，读起来是堆叠。
    // 下移用**更小的文本样式**实现而不是 `Font.system(size:)`：固定 point 不跟随 Dynamic Type
    // （这条判据本仓已为它登记过一次，见上方注释）。iPhone 默认档实测：
    //   largeTitle 34→22(.title2)｜title 28→20(.title3)｜headline 17→15(.subheadline+半粗)
    //   body 17→16(.callout)｜callout 16→15(.subheadline)｜subhead 13、caption 11 不动
    public static let largeTitle = Font.system(.title3).weight(.bold)
    public static let title = Font.system(.headline).weight(.semibold)
    /// 区块标题与列表主行：15 半粗。与正文同 15pt，**层级由字重与间距承担**（中文没有
    /// 大小写可依赖，靠字号拉开就必然一路加到 17/20/28 —— 那正是上一版"整屏都大"的成因）。
    public static let headline = Font.system(.subheadline).weight(.semibold)
    public static let body = Font.system(.subheadline)
    public static let callout = Font.system(.footnote)
    public static let subhead = Font.system(.caption)
    /// 设计档 `caption` 是 11pt ⇒ Apple `.caption2`（`.caption` 为 12pt，不是这一档）。
    public static let caption = Font.system(.caption2)
    public static let mono = Font.system(.caption, design: .monospaced)

    /// 全局 tabular-nums：时间/余额/进度一律等宽数字。
    public static func digits(_ text: String) -> Text {
        Text(text).font(mono).monospacedDigit()
    }
}

/// SF Symbol 图标尺寸档（`tokens.json` 的 `symbol.*` 区，2026-10-06 任务25 新增）。
///
/// **刻意偏差：图标一律固定 point、不跟随 Dynamic Type。** 图标的尺寸由触控目标（≥44pt）
/// 与版式位置决定——随文字放大会撑破 hit-target 框、让 overlay 角标偏离定位点；
/// 需要无障碍放大的文本已由 `CovaType` 走 Apple text style，图标侧 `imageScale` 只有
/// small/medium/large 三档，表达不了 9–64pt 的版式谱系。与「紧凑字档/tracking 未落地」
/// 同族登记于 `文档/设计/刻意偏差登记.md` D-01/D-02（iOS 端载体为 `Font.system(size:)`）。
///
/// 档按站点语义归并，同一尺寸不同语义的给不同名；`…Point` 常量为 `.frame(width:)`
/// 复用同值（图标框与符号同档，避免两处数字漂移）。
public enum CovaSymbol {
    /// 空态/错误态的插图位大符号：`CovaEmptyState`/`CovaErrorState` 与各屏局部错误块共用。
    public static let state = Font.system(size: 34, weight: .light)
    public static let statePoint: CGFloat = 34

    // MARK: 02 播放页传输控制族（同屏一组，不拆散）

    /// 播放/暂停主钮（02 §3，屏上唯一 64 档）。
    public static let playerMain = Font.system(size: 64, weight: .regular)
    /// 上一首/下一首。
    public static let playerControl = Font.system(size: 26, weight: .semibold)
    /// 15s 快退/快进（与主钮/次钮同族）。
    public static let playerSeek = Font.system(size: 24, weight: .medium)
    /// 循环三态钮（02 §5：repeat / repeat+accent 点 / repeat.1）。
    public static let loopControl = Font.system(size: 22, weight: .medium)
    /// 迷你播放条主钮与播放页收藏心（20 半粗，行外大触控位）。
    public static let playerAction = Font.system(size: 20, weight: .semibold)

    // MARK: 行级控件与装饰符号

    /// 行级大控件：收藏心（详情页）、多选勾选圈（收藏/歌单/补充制作清单）。
    public static let controlLarge = Font.system(size: 22)
    public static let controlLargePoint: CGFloat = 22
    /// 行首装饰符号（21 补充制作 TG-18 档）：队列/交付物行的语义图标。
    public static let rowSymbol = Font.system(size: 20)
    public static let rowSymbolPoint: CGFloat = 20
    /// 强调小控件：大卡播放钮、播放页 ⋯ 菜单、创作入口 sparkles（18 半粗）。
    public static let controlProminent = Font.system(size: 18, weight: .semibold)
    /// 常规行内控件：✕ / ⋯ / 试听钮 / 发送钮（16 半粗）。
    public static let control = Font.system(size: 16, weight: .semibold)
    /// 常规行内控件的无字重档（09 候选卡收藏心）。
    public static let controlPlain = Font.system(size: 16)
    /// 状态对号（16 §签到态 checkmark.circle，15 档）。
    public static let status = Font.system(size: 15)
    /// agent 消息标识位（09 §3.D：24pt 框内居中 sparkles，符号本体 14 半粗）。
    public static let agentMark = Font.system(size: 14, weight: .semibold)
    /// 外链指示（设置页 arrow.up.right.square）。
    public static let linkExternal = Font.system(size: 13)
    /// 小型状态符：09 运行状态行 12 / 05 已收藏角标 12。
    public static let statusSmall = Font.system(size: 12)
    /// 角标（01 作品卡 sparkles 圆章，11 半粗）。
    public static let badge = Font.system(size: 11, weight: .semibold)
    /// 展开/收起箭头（详情页歌词「全文」旁 10pt chevron）。
    public static let chevron = Font.system(size: 10)
    /// 菜单档位指示（01 搜索目标 chevron.up.chevron.down，9 半粗）。
    public static let chevronCompact = Font.system(size: 9, weight: .semibold)
}

/// 动效（`tokens.json` 的 `motion.*`）。`motion.curve` = cubic-bezier(0.32,0.72,0.24,1)；
/// 时长档按 token 毫秒转秒。Reduce Motion 的替代态由各调用点执行（token `motion.reduceMotion`）。
public enum CovaMotion {
    public static let instant = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.20)
    public static let fast = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.24)
    public static let normal = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.30)
    public static let slow = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.36)
    /// 01 §9 feed 分区的错峰步长（40ms，屏级裁决，不入 token）。
    public static let feedStaggerStep = 0.04
}

/// 阴影（`tokens.json` 的 `elevation.*`）。CSS `blur 18` → SwiftUI `radius` 取半 = 9。
public enum CovaElevation {
    /// `elevation.primaryButtonShadow`：`0 6pt 18pt rgba(230,96,0,0.22)`，双色同值。
    /// `#E66000` = `rgba(230,96,0)` 的逐字值，不是 `accentHover` 的别名（深色那支不同）。
    public static let primaryButtonShadowColor =
        CovaColor.dynamic("#E66000", "#E66000").opacity(0.22)
}

public extension View {
    /// `elevation.primaryButtonShadow`：发送/主行动钮那一档（01 §4 发送钮）。
    func covaPrimaryButtonShadow() -> some View {
        shadow(color: CovaElevation.primaryButtonShadowColor, radius: 9, x: 0, y: 6)
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
