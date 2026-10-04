import SwiftUI

/// 主/次按钮（design/README「与 web 的统一设计语言」按钮族）：高度 44 命中区；
/// **primary = 中性液态玻璃**（web `.cova-liquid-glass-btn`：品牌橙不做按钮填充，
/// hero CTA 才用 `gradient.brandButton`）；secondary = 细描边；danger = error 语义。
/// 禁用态降透明度且不接收点击；loading 态用进度环替换标题但**保持宽度**（防布局跳）。
public struct CovaButton: View {
    /// `brand` = hero CTA 档（`gradient.brandButton` + 白字 + `primaryButtonShadow`）：
    /// web `data-glass-tint='brand'` 同位，只给登录/生成/播放全部这类高可见主行动。
    public enum Style { case primary, secondary, danger, brand }
    private let title: String
    private let style: Style
    private let isLoading: Bool
    private let action: () -> Void

    public init(_ title: String, style: Style = .primary, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: { if !isLoading { action() } }) {
            HStack(spacing: CovaSpace.sm) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(title).font(CovaType.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background { backgroundShape.fill(fillStyle) }
            .clipShape(backgroundShape)
            .overlay(backgroundShape.strokeBorder(borderColor, lineWidth: style == .primary ? 0.5 : 1))
            // 阴影必须落在 clipShape 之外（背景里的 shadow 会被裁掉）。
            .shadow(
                color: style == .brand ? CovaElevation.primaryButtonShadowColor : .clear,
                radius: style == .brand ? 9 : 0, x: 0, y: 6
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1)
    }

    /// hero CTA 一律胶囊（web `rounded-full` + 10 §3.H / 16 §3.E / 19 §3.C 的
    /// `radius.capsule` 钉法）；其余档 `radius.control`。
    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: style == .brand ? CovaRadius.capsule : CovaRadius.control,
            style: .continuous
        )
    }
    private var fillStyle: AnyShapeStyle {
        switch style {
        case .brand: return AnyShapeStyle(CovaGradient.brandButton)
        case .primary: return AnyShapeStyle(.ultraThinMaterial)
        case .secondary: return AnyShapeStyle(CovaColor.surface)
        case .danger: return AnyShapeStyle(CovaColor.error.opacity(0.12))
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return CovaColor.fg
        case .secondary: return CovaColor.fg
        case .danger: return CovaColor.error
        case .brand: return .white
        }
    }
    private var borderColor: Color {
        switch style {
        case .primary: return CovaColor.line
        case .secondary: return CovaColor.line
        case .danger: return CovaColor.error.opacity(0.4)
        case .brand: return .clear
        }
    }
}

/// 卡片容器：surface 底 + card 圆角 + 细描边；`glass` 时换玻璃材质（播放器/浮层用）。
public struct CovaCard<Content: View>: View {
    public var glass: Bool = false
    @ViewBuilder private let content: Content
    public init(glass: Bool = false, @ViewBuilder content: () -> Content) {
        self.glass = glass
        self.content = content()
    }
    public var body: some View {
        content
            .padding(CovaSpace.lg)
            .background(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .fill(glass ? .clear : CovaColor.surface)
            )
            .modifier(CovaGlass(elevated: glass))
    }
}

/// 标签/筛选 chip（曲库三级级联与搜索态共用）：选中 = `selectedBg` 底 + `selected` 字
/// + `line` 描边（web v2.65.0 `.cova-filter-current` 去橙化选中档）。
public struct CovaChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void
    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(CovaType.subhead)
                .padding(.horizontal, CovaSpace.md)
                .padding(.vertical, CovaSpace.xs + 2)
                .foregroundStyle(isSelected ? CovaColor.selected : CovaColor.secondary)
                .background(
                    Capsule().fill(isSelected ? CovaColor.selectedBg : CovaColor.surface)
                )
                .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// 区块标题（首页/曲库各 section 共用）：headline + 可选「更多 ›」。
/// 右侧入口 `type.subhead` / `color.secondary`（01 §6「分区公共规则」逐字档）。
public struct CovaSectionHeader: View {
    private let title: String
    private let trailing: String?
    private let onTrailing: (() -> Void)?
    public init(_ title: String, trailing: String? = nil, onTrailing: (() -> Void)? = nil) {
        self.title = title
        self.trailing = trailing
        self.onTrailing = onTrailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(CovaType.headline).foregroundStyle(CovaColor.fg)
            Spacer()
            if let trailing, let onTrailing {
                Button(trailing, action: onTrailing)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }
}

/// 「带入搜索条件」回显行（03 §3 / 05 §1 同一形态）：导航条下一整行
/// `color.surface` 底 + `color.fg` 字，正文「搜索：{query}」，行尾 ✕ 清掉条件回本屏筛选态。
/// 整行是一个按钮（✕ 不落第二焦点）——05 §6 把它列为整行命中（≥44pt）。
public struct CovaSearchEchoRow: View {
    private let query: String
    private let onClear: () -> Void

    public init(query: String, onClear: @escaping () -> Void) {
        self.query = query
        self.onClear = onClear
    }

    public var body: some View {
        Button(action: onClear) {
            HStack(spacing: CovaSpace.sm) {
                Text("搜索：\(query)")
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(CovaColor.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除搜索条件 \(query)")
        .accessibilityHint("回到筛选列表")
    }
}

/// 列表行（曲目/歌单/会话通用）：封面 + 两行文字 + 尾饰；点击整行命中。
public struct CovaListRow<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    /// 12a/12b/03 §Dynamic Type：AX 档下两行文本**各自**允许 2 行，行高自适应。
    @Environment(\.covaAXLayout) private var axLayout
    private let artwork: CovaArtwork?
    @ViewBuilder private let trailing: Trailing
    private let action: () -> Void

    public init(
        title: String, subtitle: String? = nil, artwork: CovaArtwork? = nil,
        @ViewBuilder trailing: () -> Trailing, action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.trailing = trailing()
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.sm) {
                if let artwork {
                    // 紧凑档（D24）：封面 44→40、纵向 padding 8→4 ⇒ 行高约 48pt，
                    // **仍在 ≥44pt 触控红线之上**（这条是本仓硬规矩，不为密度牺牲）。
                    artwork.frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CovaType.body).foregroundStyle(CovaColor.fg)
                        .lineLimit(axLayout ? 2 : 1)
                    if let subtitle {
                        Text(subtitle).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                            .lineLimit(axLayout ? 2 : 1)
                    }
                }
                Spacer(minLength: CovaSpace.sm)
                trailing
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
