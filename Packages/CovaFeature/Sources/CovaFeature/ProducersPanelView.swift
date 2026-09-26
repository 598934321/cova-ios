import CovaCore
import CovaUI
import SwiftUI

// MARK: - 23 制作人入口：「+」面板里的制作人区（§5 P2-2 / §6 A10）
//
// 规格：`design/screens/23-producers-entry.md`。本文件施工的是 §3 的 **C–I 区**（分组标题 +
// 卡头 + tagline + 步骤列表 + 两段 chips 流），也就是"非空时面板里出现的那一组东西"。
//
// ⚠️ **宿主面尚未存在（23 §1 自陈，本任务不改 01/09）**：「+」钮（§3.A）与会话输入卡同排，
// 而 `01-home.md` §2 / `09-ai-session-detail.md` §J 今天都只有「找歌 / 做歌 / 深度思考」，
// **没有「+」**。所以：
// · 本文件**不**新增一个「+」钮 —— 那会长出第二个面板入口，而面板本体（§3.B）归宿主；
// · `ProducersPanelView` 是一段可嵌内容（宿主在自己的面板容器里放它即可），
//   取数由宿主发起（`session.loadProducerCards()`），本区只读 `session.producersEntranceVisible`；
// · 于是 **A10 的前半今天既无设备证据、也无宿主落点** —— 两条都已登记在交付说明里。
//
// ⚠️ **非空分支的设备证据仍在等待**（23 §7「必须说白」）：生产 `GET /api/studio/producers`
// 恒回 `{producers:[]}`（`PRODUCER_MODE` 未设 ⇒ 灰度关闭），本仓没有已开灰度的测试账号
// ⇒ 下面的卡面渲染路径**只被 fixture 单测覆盖过**（`ProducersEntryLegTests`），
// 没有一次在模拟器上真的画出来过。那不是"没做"，是"没有可驱动它的数据"（硬边界 7）。
//
// 三条渲染纪律（都在这一屏被规格点名，也都属于"错了会骗人"）：
// · **空 = 不可见**：`{producers:[]}` 时 C 到 I **连分组标题「制作人」都不出现**，
//   不骨架、不「暂未开放」、不「即将上线」（那本身就是一块露出的入口）；
// · **卡不可点**：P2 阶段没有任何合法落点（`projects`/`actions`/`surveys` 三条端点属 P3）
//   ⇒ 不渲染 `chevron.right`、不渲染任何钮、无按压态、无手势，并把"非交互"朗读出来（§6）；
// · **未释义字段不外露**：`fictional` / `audience` / `greeting` / `demoCount` / `cardCount` /
//   `id` 一律不渲染（§7 的逐槽位表：量词不知、释义不知、内部标识永不外露）。

/// 23 的上屏串（§8 文案清单，一句不多）。
///
/// 「更多」是 §3.A 那枚「+」钮的朗读标签 —— 它属宿主输入卡，不属本文件 ⇒ 这里不定义，
/// 免得两个屏各写一份而只有一处真会被念出来。
enum ProducersCopy {
    /// C 分组标题（仅 `producers` 非空时存在 —— §3.C「不留空标题」）。
    static let sectionTitle = "制作人"
    static let stagesTitle = "步骤"
    static let deliverablesTitle = "交付物"
    static let extensionsTitle = "可延展"
    static let expand = "展开"
    static let collapse = "收起"
    /// §6：卡不可点**必须被朗读出来**（VoiceOver 用户找到一张卡而屏上没有任何提示，
    /// 比屏上多一句话更糟）。这一串只进标签，不上屏。
    static let nonInteractiveSpoken = "非交互内容"
    /// 「+N」那枚（§3.H：最多 3 行 + 「+N」；点开 = 展开全部）。
    static func moreCount(_ dropped: Int) -> String { "+\(dropped)" }
}

// MARK: - 面板里的制作人区

/// 「+」面板顶部的制作人卡组（§2 非空形态）。
///
/// 空 / 取不到 / 游客 ⇒ **本视图返回 `EmptyView`**：连容器都不显（§4「连容器都不显」）。
/// 这不是"隐藏"，是"不构造" —— 一条 `if` 在视图树里仍会留下一个占位元素，
/// 而 §6 要的是「空/取不到时序列里没有任何相关元素（不是 hidden，是不存在）」。
public struct ProducersPanelView: View {
    @Environment(AppSession.self) private var session

    public init() {}

    public var body: some View {
        // 取数**不在这里发起**（§4：非空结果在下一次展开生效，中途插内容会让面板跳动；
        // §9 又要两处宿主共用同一份缓存不重复发）⇒ 由宿主的冷启动调 `loadProducerCards()`。
        if session.producersEntranceVisible {
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                // §6：分组标题那一停念「制作人，N 位」。
                Text(ProducersCopy.sectionTitle)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
                    .accessibilityLabel(
                        "\(ProducersCopy.sectionTitle)，\(session.producerCards.count) 位"
                    )
                    .padding(.horizontal, CovaSpace.pageGutter)
                ForEach(session.producerCards, id: \.id) { card in
                    ProducerCardView(card: card)
                        .padding(.horizontal, CovaSpace.pageGutter)
                }
            }
        }
    }
}

// MARK: - 一张卡（D–I）

/// 制作人卡。**整卡不可点**：无 `Button`、无 `onTapGesture`、无 `chevron`、无按压态。
///
/// 理由不是"没做"，而是"无目标"（§1：可点的三条动作全在 P3 的端点上）。
/// 与本仓另一族判断同源（20 的分享钮、09 的参数 chip）：画一个点了没用的东西就是谎。
struct ProducerCardView: View {
    let card: ProducerCardDto

    var body: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            header
            stages
            chipSection(title: ProducersCopy.deliverablesTitle, labels: deliverableLabels)
            chipSection(title: ProducersCopy.extensionsTitle, labels: extensionLabels)
        }
        .padding(CovaSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .fill(CovaColor.surface)
        )
        // §5/§7：本屏**刻意不使用** `gradient.ai` / `memberGold` / `enterpriseBlue` ——
        // 金色调会把制作人读成"付费服务"，而本屏没有任何计费事实。
    }

    /// E 卡头 + F tagline。
    ///
    /// `displayName` 原样上屏（服务端给的中文名，不加「制作人」前缀、不"统一称谓"）；
    /// 拿不到 ⇒ 那一行不渲染（**不回落 `id`** —— 把内部 id 印上屏是 A15 那一类脏）。
    /// tagline 缺失 ⇒ 该行不渲染（§3.F）。
    private var header: some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            if let title = card.displayTitle {
                Text(title)
                    .font(CovaType.headline)
                    .foregroundStyle(CovaColor.fg)
                    .lineLimit(ProducersMetrics.titleLinesRegular)
            }
            if let tagline = ProducersPanelFacts.text(card.tagline) {
                Text(tagline)
                    .font(CovaType.callout)
                    .foregroundStyle(CovaColor.secondary)
                    .lineLimit(ProducersMetrics.taglineLines)
            }
        }
        // §6：一停 = 「<displayName>，制作人，<tagline>，非交互内容」。
        // 「制作人」这一格是**类别**（朗读用的域词），不是屏上文字。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProducersPanelFacts.headerSpokenLabel(card))
    }

    /// G 步骤列表。条目顺序 = 响应数组顺序，客户端**不重排**（`stages[].id` 未说明用途 ⇒
    /// 不做本地排序键）；序号由**数组下标 +1** 得出（契约无 `order` 字段）。
    @ViewBuilder
    private var stages: some View {
        let rows = ProducersPanelFacts.stageRows(card.stages)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                Text(ProducersCopy.stagesTitle)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
                    .accessibilityLabel("\(ProducersCopy.stagesTitle)，\(rows.count) 项")
                ForEach(rows) { row in
                    StageRow(row: row)
                }
            }
        }
    }

    /// H / I 两段 chips 流：`label` 取不到展示字段的条目**不渲染**（§3.H 的容忍解码口径），
    /// 整段取不到 ⇒ 整段连同标题一起消失（§3.H「两段皆空 ⇒ 两段标题一并消失」）。
    @ViewBuilder
    private func chipSection(title: String, labels: [String]) -> some View {
        if labels.isEmpty == false {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                Text(title)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
                    .accessibilityLabel("\(title)，\(labels.count) 项")
                ChipFlowContainer(labels: labels)
            }
        }
    }

    private var deliverableLabels: [String] {
        ProducersPanelFacts.deliverableLabels(card.deliverables)
    }

    private var extensionLabels: [String] {
        ProducersPanelFacts.extensionLabels(card.extensions)
    }
}

/// 一条步骤（G 的行）。展开态住在 `@State`（一次性 UI 态，不属于任何一本数据账）。
private struct StageRow: View {
    let row: ProducerStageRow

    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
            // 序号 `type.mono` / `color.muted`，值 = 数组下标 +1。
            Text("\(row.number)")
                .font(CovaType.mono)
                .foregroundStyle(CovaColor.muted)
                .fixedSize()
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                if let label = row.label {
                    Text(label)
                        .font(CovaType.subhead)
                        .foregroundStyle(CovaColor.fg)
                }
                if let summary = row.summary {
                    Text(summary)
                        .font(CovaType.caption)
                        .foregroundStyle(CovaColor.muted)
                        // 收起 2 行（§3.G）；AX 档同样给 2 行放大版，不靠截断消化长文。
                        .lineLimit(expanded ? nil : ProducersMetrics.summaryCollapsedLines)
                }
                if row.hasSummary {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded ? ProducersCopy.collapse : ProducersCopy.expand)
                            .font(CovaType.caption)
                            .foregroundStyle(CovaColor.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: ProducersMetrics.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 行已经是"一个元素 + 一个动作"，这里再进序列就是念两遍（§6 同一族判断）。
                    .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel(expanded: expanded))
        .modifier(RowActionModifier(action: toggleAction))
    }

    /// 「没有 summary 就没有展开动作」⇒ 既不加 `.isButton` 也不挂动作（同 22 那一族的判断）。
    private var toggleAction: (() -> Void)? {
        guard row.hasSummary else { return nil }
        return { expanded.toggle() }
    }
}

// MARK: - chips 流（H / I）

/// chip 流容器：换行摆 + 计数档截断。
///
/// ⚠️ **已知偏差（登记在交付说明）**：§3.H 要的是「最多 3 行 + 「+N」（点开 = 展开全部）」，
/// 那是**行**档 —— 需要"这一屏放下了第几行"的反馈，而 SwiftUI 的 `Layout` 不能把
/// 「摆下了几枚」回写成视图状态（会在布局期改 `@State`）。今天按 §8 极值那一档的
/// **计数**档施工（`chips > 30 ⇒ 前 20 + 「+N」`，`ProducersPanelFacts.chipWindow`），
/// 行档未做：卡内容全部列完，靠宿主面板自己的滚动消化。
/// 不自造"猜一个宽度来切行"的实现 —— 那会在窄机上把用户正在看的条目切掉。
struct ChipFlowContainer: View {
    let labels: [String]

    @State private var showsAll = false

    var body: some View {
        let window = ProducersPanelFacts.chipWindow(labels, showsAll: showsAll)
        ChipFlowLayout(spacing: CovaSpace.sm) {
            ForEach(Array(window.shown.enumerated()), id: \.offset) { _, label in
                chip(label)
            }
            if let dropped = window.droppedCount, dropped > 0 {
                // 点它 = 展开全部（§3.H「点开 = 展开全部」）。
                Button {
                    showsAll = true
                } label: {
                    Text(ProducersCopy.moreCount(dropped))
                        .font(CovaType.caption)
                        .foregroundStyle(CovaColor.accentText)
                        .padding(.horizontal, CovaSpace.md)
                        .frame(minHeight: ProducersMetrics.touchMin)
                        .background(Capsule().fill(CovaColor.elevated))
                        .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(ProducersCopy.moreCount(dropped))，\(ProducersCopy.expand)")
            }
        }
    }

    /// 一枚只读 chip：`color.elevated` 底 + 1pt `color.line` 描边（TG-04）+
    /// `type.caption` / `color.secondary`，高 36（TG-07）。
    /// **不是按钮**：它没有任何落点，借 `CovaChip(action:)` 会造出一枚按下什么都不发生的
    /// 控件（09 的参数 chip 已经为这件事纠过一次，同一条判据）。
    private func chip(_ label: String) -> some View {
        Text(label)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.secondary)
            .padding(.horizontal, CovaSpace.md)
            .frame(minHeight: ProducersMetrics.chipHeight)
            .fixedSize()
            .background(Capsule().fill(CovaColor.elevated))
            .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 1))
            // §6：每条念「<条目>，标签」。「标签」那两个字由 `.isStaticText` 特征交给
            // VoiceOver 自己加，不写进标签串里（写进去就会在两处口径不一致时说不清）。
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// 换行容器（第一方 `Layout`，零依赖）。行高取该行最高的一枚，间距 `spacing.sm`。
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = CovaSpace.sm

    struct Cache: Sendable {
        var sizes: [CGSize] = []
        var width: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGSize {
        let rows = layoutRows(proposal: proposal, subviews: subviews, cache: &cache)
        let width = proposal.replacingUnspecifiedDimensions().width
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (row.indices.isEmpty ? 0 : spacing)
        }
        return CGSize(width: width, height: max(0, height - spacing))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let rows = layoutRows(proposal: proposal, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.height
            for index in row.indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    /// 行切分（同一份逻辑给 `sizeThatFits` 与 `placeSubviews` 用，两遍必须给出同一个结果，
    /// 否则高度与摆放会对不上 —— 那是 chip 流最经典的"重叠半枚"症状）。
    private func layoutRows(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> [(indices: [Int], height: CGFloat)] {
        let limit = max(1, proposal.replacingUnspecifiedDimensions().width)
        if cache.width != limit || cache.sizes.count != subviews.count {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            cache.width = limit
        }
        // 先取一份本地副本：下面只读，不再回写 `cache`（inout 的独占访问在切行途中被改写
        // 会直接编译期红，而这里没有任何需要在切行途中改缓存的理由）。
        let sizes = cache.sizes
        var rows: [(indices: [Int], height: CGFloat)] = []
        var current: [Int] = []
        var lineWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = lineWidth + (current.isEmpty ? 0 : spacing) + size.width
            if !current.isEmpty, needed > limit {
                rows.append((current, rowHeight))
                current = [index]
                lineWidth = size.width
                rowHeight = size.height
            } else {
                current.append(index)
                lineWidth = needed
                rowHeight = max(rowHeight, size.height)
            }
        }
        if !current.isEmpty { rows.append((current, rowHeight)) }
        return rows
    }
}

// MARK: - 几何档

/// 本屏几何档（TG-51「制作人卡多段结构」未入库 ⇒ 收在一处，不散落裸字面量）。
enum ProducersMetrics {
    /// §3.E `displayName` 1 行（AX 2 行由宿主面板的 AX 档处理，见下方注）。
    static let titleLinesRegular: Int = 1
    /// §3.F `tagline` 2 行。
    static let taglineLines: Int = 2
    /// §3.G `summary` 收起 2 行。
    static let summaryCollapsedLines: Int = 2
    /// TG-07 chip 高度档。
    static let chipHeight: CGFloat = 36
    /// TG-03 触控最小高（「展开」/「+N」/ 宿主 ✕）。
    static let touchMin: CGFloat = 44
}
