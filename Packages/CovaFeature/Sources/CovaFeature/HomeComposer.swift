import CovaCore
import CovaUI
import SwiftUI

/// 01 §3/§4/§5 的输入区三件套（CovaModeTabs / CovaTagChip / CovaComposer）+ 屏级文案表。
/// 组件只画、不碰网络：发送语义（建会话 / 路由 push / 登录门）全在 `HomeView`。
enum HomeComposerMode: String, CaseIterable, Hashable, Sendable {
    case generate
    case search

    var title: String {
        switch self {
        case .generate: return "生成"
        case .search: return "搜索"
        }
    }
}

/// 01 §4 搜索档的目标档（左钮 menu 的两项；`shortTitle` 是钮上那两个字）。
enum HomeSearchTarget: String, CaseIterable, Hashable, Sendable {
    case library
    case playlists

    var shortTitle: String {
        switch self {
        case .library: return "曲库"
        case .playlists: return "歌单"
        }
    }
}

/// §5 引导标签文案（本地常量，与 web `MODE_TAGS` 逐字；改词只改这张表）。
enum HomeComposerCopy {
    static let generateTags = [
        "一首治愈的钢琴曲", "国风纯音乐，短视频配乐", "轻快电子，品牌广告", "电影感弦乐",
    ]
    static let searchTags = ["轻音乐", "Lo-fi", "中国风", "商务科技"]

    /// §2 时段称呼（`<5 夜深了 / <12 早上好 / <18 下午好 / 其余 晚上好`，本地时间）。
    static func salutation(hour: Int) -> String {
        switch hour {
        case ..<5: return "夜深了"
        case ..<12: return "早上好"
        case ..<18: return "下午好"
        default: return "晚上好"
        }
    }
}

// MARK: - §3 模式切换（胶囊托盘 + 滑动选中片）

/// 胶囊托盘（`color.fg` 5% 底、`radius.capsule`、内边距 `spacing.xs`）+ 滑动选中片
/// （`color.elevated` 底，`matchedGeometryEffect` 位移，`motion.curve`+`duration.normal`）。
/// 选中档文字 `fg` 半粗、未选 `secondary` —— **不用** accent 底（spec 原话：
/// 着色靠对比不靠品牌色）。
struct CovaModeTabs: View {
    @Binding var selection: HomeComposerMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    init(selection: Binding<HomeComposerMode>) {
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeComposerMode.allCases, id: \.self) { mode in
                Button {
                    if reduceMotion { selection = mode }
                    else { withAnimation(CovaMotion.normal) { selection = mode } }
                } label: {
                    Text(mode.title)
                        .font(CovaType.subhead.weight(.semibold))
                        .foregroundStyle(selection == mode ? CovaColor.fg : CovaColor.secondary)
                        .padding(.horizontal, CovaSpace.lg)
                        .frame(minHeight: 36)
                        .background {
                            if selection == mode {
                                Capsule()
                                    .fill(CovaColor.elevated)
                                    .matchedGeometryEffect(id: "cova.modeTabs.pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // §3 VoiceOver：「已选中」由 segmented trait 承担，不手拼朗读串。
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(CovaSpace.xs)
        .background(Capsule().fill(CovaColor.fg.opacity(0.05)))
    }
}

// MARK: - §5 引导标签（圆角胶囊，横排流式）

/// §5 卡：1pt `color.line` 描边、半透底（`color.elevated` 60%）、`type.caption`/`color.secondary`。
/// 按下交给调用方（生成档 = 直接发送该句；搜索档 = 按当前目标执行）——组件不知道去向。
struct CovaTagChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.secondary)
                .padding(.horizontal, CovaSpace.md)
                .frame(minHeight: 36)
                .background(Capsule().fill(CovaColor.elevated.opacity(0.6)))
                .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - §4 底置输入条（本屏灵魂）

/// `safeAreaInset(edge:.bottom)` 常驻底部。单行 44pt 控件区 + 聚焦时的选项行
/// （生成档 =「深度思考」chip；搜索档 = 无选项行，目标选择并入左钮 menu）。
///
/// **发送可用性两档不同**：生成档空文本置灰（spec §4 表右列）；搜索档允许空文本发送
/// （§4 发送行为：空文本 → push 无条件的曲库/歌单列表）⇒ `canSend` 按模式分。
struct CovaComposer: View {
    @Binding var text: String
    @Binding var mode: HomeComposerMode
    @Binding var target: HomeSearchTarget
    @Binding var deepThinking: Bool
    let sending: Bool
    let onSend: () -> Void
    @FocusState.Binding var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            // §4 选项行：只有生成档有内容；聚焦时在输入区上方展开（duration.fast 由
            // `HomeView` 的 withAnimation 施加，这里只声明内容）。
            if focused, mode == .generate {
                HStack(spacing: CovaSpace.sm) {
                    // 开 = selectedBg 底 + selected 字 + line 描边（01 §4；v2.65.0 去橙化，
                    // 开关态按「播放列表当前项」同档走中性选中）。
                    Button {
                        deepThinking.toggle()
                    } label: {
                        Text("深度思考")
                            .font(CovaType.caption)
                            .foregroundStyle(deepThinking ? CovaColor.selected : CovaColor.secondary)
                            .padding(.horizontal, CovaSpace.md)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(deepThinking ? CovaColor.selectedBg : .clear))
                            .overlay(
                                Capsule().strokeBorder(
                                    deepThinking ? CovaColor.selected : CovaColor.line,
                                    lineWidth: deepThinking ? 1 : 0.5
                                )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(deepThinking ? .isSelected : [])
                    .accessibilityLabel(deepThinking ? "深度思考，已开启" : "深度思考")
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: CovaSpace.sm) {
                leadingControl
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(CovaType.body)
                    .foregroundStyle(CovaColor.fg)
                    .lineLimit(1...3)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { onSend() }
                sendButton
            }
            .frame(minHeight: ShellMetrics.touchMin)
        }
        .padding(.horizontal, CovaSpace.md)
        .padding(.vertical, CovaSpace.sm)
        // `material.glass`（token 原文：系统 Liquid Glass / regularMaterial，不自建模糊）
        // → regularMaterial + card 圆角；左右 `pageGutter`、下缘 `sm` 由 §4 逐字给出。
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .strokeBorder(CovaColor.line.opacity(0.6), lineWidth: 0.5)
        )
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.bottom, CovaSpace.sm)
    }

    /// 左钮：生成档 = `sparkles`（`gradient.ai` 着色，创作入口控件的红线内用法）；
    /// 搜索档 = `menu` 显示当前目标短名（`type.caption`/`color.secondary`）。
    @ViewBuilder
    private var leadingControl: some View {
        switch mode {
        case .generate:
            Image(systemName: "sparkles")
                .font(CovaSymbol.controlProminent)
                .foregroundStyle(CovaGradient.ai)
                .frame(width: ShellMetrics.touchMin, height: ShellMetrics.touchMin)
                .accessibilityHidden(true)
        case .search:
            Menu {
                ForEach(HomeSearchTarget.allCases, id: \.self) { item in
                    Button {
                        target = item
                    } label: {
                        if item == target {
                            Label(item.shortTitle, systemImage: "checkmark")
                        } else {
                            Text(item.shortTitle)
                        }
                    }
                }
            } label: {
                HStack(spacing: CovaSpace.xs) {
                    Text(target.shortTitle)
                        .font(CovaType.caption)
                        .foregroundStyle(CovaColor.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(CovaSymbol.chevronCompact)
                        .foregroundStyle(CovaColor.muted)
                }
                .frame(minHeight: ShellMetrics.touchMin)
                .padding(.horizontal, CovaSpace.xs)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("搜索目标，当前 \(target.shortTitle)")
        }
    }

    private var placeholder: String {
        mode == .generate ? "说出你的音乐灵感…" : "搜索曲名 / 艺人 / 标签"
    }

    /// §4 表右列：「空输入置灰 `color.muted`」管的是生成档（没有可发的话）；
    /// 搜索档空文本是合法发送（无条件 push 列表页），所以只有生成档空字才降档。
    private var canSend: Bool {
        if mode == .search { return !sending }
        return sending == false && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 圆形发送钮 40pt：`gradient.brandButton` + 白 ↑ + `elevation.primaryButtonShadow`；
    /// 不可用态 = `color.muted` 圆底（不发阴影 —— 置灰的钮不该还有"可点"的浮起感）。
    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: sending ? "hourglass" : "arrow.up")
                .font(CovaSymbol.control)
                .foregroundStyle(canSend ? .white : CovaColor.fg.opacity(0.4))
                .frame(width: 40, height: 40)
                .background {
                    if canSend {
                        Circle().fill(CovaGradient.brandButton)
                    } else {
                        Circle().fill(CovaColor.muted.opacity(0.3))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .covaPrimaryButtonShadow()
        .opacity(canSend ? 1 : 0.9)
        .accessibilityLabel("发送")
    }
}

// MARK: - 分区骨架（§6 公共规则：一条横排骨架卡，形状照真实卡）

/// feed 横卡带的分区级骨架：四个 140 方块的呼吸（`CovaSkeleton` 同一节奏，0.9s 整块互换）。
/// 不用通用灰条 —— §6「形状照真实卡」。
struct HomeRailSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.md) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                        .fill(CovaColor.line.opacity(lit ? 0.9 : 0.5))
                        .frame(width: CGFloat(HomeSceneRail.cardSide), height: CGFloat(HomeSceneRail.cardSide))
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
        }
        .accessibilityLabel("加载中")
    }
}

// MARK: - §9 feed 分区入场（自下而上错峰淡入 40ms/区）

/// 每分区一颗自己的 `@State`：出现时（含骨架档）延迟 `index × 40ms` 淡入上抬；
/// Reduce Motion 直接呈现（`motion.reduceMotion` 的替代态）。
struct FeedEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(CovaMotion.normal.delay(Double(index) * CovaMotion.feedStaggerStep)) {
                        appeared = true
                    }
                }
            }
    }
}

extension View {
    func feedEntrance(index: Int) -> some View { modifier(FeedEntrance(index: index)) }
}
