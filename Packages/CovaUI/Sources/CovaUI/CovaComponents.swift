import SwiftUI

/// 主/次按钮（design §components 按钮族）：高度 44 命中区、accent 实心 / 描边两态、
/// 禁用态降透明度且不接收点击；loading 态用进度环替换标题但**保持宽度**（防布局跳）。
public struct CovaButton: View {
    public enum Style { case primary, secondary, danger }
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
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: style == .primary ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return CovaColor.fg
        case .danger: return CovaColor.error
        }
    }
    private var background: Color {
        switch style {
        case .primary: return CovaColor.accent
        case .secondary: return CovaColor.surface
        case .danger: return CovaColor.error.opacity(0.12)
        }
    }
    private var borderColor: Color {
        switch style {
        case .primary: return .clear
        case .secondary: return CovaColor.line
        case .danger: return CovaColor.error.opacity(0.4)
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

/// 标签/筛选 chip（曲库三级级联与搜索态共用）：选中 = accentSoft 底 + accentText 字。
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
                .foregroundStyle(isSelected ? CovaColor.accentText : CovaColor.secondary)
                .background(
                    Capsule().fill(isSelected ? CovaColor.accentSoft : CovaColor.surface)
                )
                .overlay(Capsule().strokeBorder(isSelected ? CovaColor.accent.opacity(0.5) : CovaColor.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// 区块标题（首页/曲库各 section 共用）：headline + 可选「查看全部」。
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
                    .foregroundStyle(CovaColor.accentText)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
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
