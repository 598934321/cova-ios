import CovaCore
import CovaUI
import SwiftUI

/// 22 · co 币明细（§5 P2-3 / §6 A9）。规格：`design/screens/22-credits-ledger.md`。
///
/// 骨架是 12a 那一套同构列表页（A 导航条 / B 摘要行 / C 主体 / E 尾部状态行），
/// 但**本屏的 D 区与 E 区各自钉了一条"不许假装"的判据**：
/// · **不假装分页**（§7 硬规则）：契约只有 `limit`、没有 `cursor`/`offset`/`total` ⇒
///   本屏一次读满 100 条就是全部可读的东西，屏上**没有**「加载更多」/「下一页」，
///   滚动到底不触发任何请求；取满时尾部行说的是**服务端边界**（「这里只有最近 100 条变动」），
///   只有没取满时才说「已显示全部」。
/// · **不假装关联**（§7 / 手册 §7 #38）：「任务」钮的出现条件只有 `jobId != null`。
///   生产实测 `studio_create_generation` 这一支恒为 null ⇒ 今天整屏一枚都不出现，
///   那是事实而不是遗漏；缺位时不留空位、不留「—」、不留「不可用」说明。
///
/// 全部文案与判据在 `CreditsLedgerFlow.swift`（可测的纯函数层），这一棵视图只负责摆。
public struct CreditsLedgerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.covaAXLayout) private var axLayout

    public init() {}

    private var state: CreditsLedgerState { session.creditsLedger }

    /// 行的派生值。**每次求值都现算相对时间**：把 `Date()` 存进状态会让一份快照活过
    /// 它自己的新鲜度，而本屏按 §7 没有轮询、没有"停在某个时刻"的语义。
    private var rows: [CreditsLedgerRow] {
        state.rows(now: Date(), calendar: Calendar.current)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.bottom, CovaSpace.xxl)
        }
        .covaPage()
        .navigationTitle(CreditsLedgerCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        // §3.A「无右侧动作」：不挂筛选、不挂搜索、不挂导出 —— 契约一条都不支持。
        // 于是这里**没有** `.toolbar`：挂一枚点下去什么都不发生的按钮，就是本仓反对的假控件。
        // 身份变了要重取（含"深链落在会话还在恢复的那一帧"）：键 = 当前登录身份，见
        // `AppSession.creditsLedgerOwnerKey` 的理由。
        .task(id: session.creditsLedgerOwnerKey) { await session.loadCreditsLedger() }
        // §4 下拉刷新：重取**同一个** `limit=100` 请求、整表替换（不是追加，本屏没有追加语义）。
        .refreshable { await session.loadCreditsLedger(refresh: true) }
    }

    @ViewBuilder
    private var content: some View {
        if state.showsSkeleton {
            skeleton
        } else if state.showsWholeScreenFailure {
            wholeScreenFailure
        } else {
            // 17-S4 横幅（§4 离线那一格）：网络类失败 + 手里还有旧行。
            if state.showsOfflineBanner { offlineBanner }
            if state.showsEmptyState {
                emptyState
            } else {
                summary
                ledgerList
            }
        }
    }

    // MARK: 17-S1 骨架

    /// B 一条 + C 六条（§4 首载）。**E 不骨架** —— 尾部那句是取到数据才知道的事实，
    /// 给一个还没有的事实先让位就是画饼。A 无动作 ⇒ A 也不骨架。
    /// 呼吸与 Reduce Motion 的退化由 `CovaSkeleton` 自己承担（17-S1 的唯一实现点）。
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
                .fill(CovaColor.surface)
                .frame(width: 120, height: 12)
                .accessibilityHidden(true)
            CovaSkeleton(rows: 6)
        }
        .padding(.top, CovaSpace.lg)
    }

    // MARK: 17-S4 离线条

    /// 配色由 17-S4 钉（`color.warning` 1pt 描边 + `color.accentSoft` 底 —— TG-21 `warningSoft`
    /// 缺档，按 17 的原文用 accentSoft 顶上），文字 `type.subhead` / `color.fg`。
    /// 与 B 行那枚「未同步」的**分工**要分清：后者是 `color.muted`（§5：账目旧了不是告警），
    /// 前者才是"这一屏的内容是缓存"的那一条。
    private var offlineBanner: some View {
        Text(CreditsLedgerCopy.offlineBanner)
            .font(CovaType.subhead)
            .foregroundStyle(CovaColor.fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CovaSpace.md)
            .padding(.horizontal, CovaSpace.md)
            .background(CovaColor.accentSoft)
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
                    .strokeBorder(CovaColor.warning, lineWidth: CreditsLedgerMetrics.hairline)
            )
            .padding(.bottom, CovaSpace.md)
    }

    // MARK: B 摘要行

    /// 「%d 条变动」——值是**本地已渲染条目数**（响应没有 `total` ⇒ 本屏说不出"一共多少条"，
    /// 也不假装能说）。`entries` 为空 ⇒ 整行不渲染（§3.B：空态自己说话）。
    @ViewBuilder
    private var summary: some View {
        if let summary = state.summaryText {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(summary)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.muted)
                    // 数字等宽（TG-49 的近旁一档）；`monospacedDigit` 不影响中文那一段。
                    .monospacedDigit()
                // §4「未同步」：一次性缓存时限标记，`color.muted` 而**不是** `color.warning`
                // （§5 的理由：把它做成橙色会诱导用户去找刷新按钮之外的东西）。
                if state.showsUnsyncedMark {
                    Text(CreditsLedgerCopy.unsynced)
                        .font(CovaType.caption)
                        .foregroundStyle(CovaColor.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, CovaSpace.lg)
            .padding(.bottom, CovaSpace.md)
        }
    }

    // MARK: C 明细行 + 尾部两行

    private var ledgerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // §2：行分隔 `color.lineSubtle` 1pt，**首行不加**。
                if index > 0 {
                    Rectangle().fill(CovaColor.lineSubtle)
                        .frame(height: CreditsLedgerMetrics.hairline)
                }
                entryRow(row)
            }
            // 「有 N 条没读出来」：**不静默缩表**。服务端给了 100 条而本层只认出 97 条时，
            // 少掉那 3 条必须看得见（`CreditLedgerPageDto` 的口径：这是"少了几行"唯一的可见面）。
            if let unreadable = state.unreadableText {
                Text(unreadable)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.muted)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, CovaSpace.md)
            }
            // E 尾部行：列表**之后**的独立静态元素。§6 明令不得因装饰性考虑设 `accessibilityHidden`
            // —— 它是本屏最重要的一句事实（"这里只有最近 100 条"）。
            if let tail = state.tailText {
                Text(tail)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CovaSpace.xl)
            }
        }
    }

    // MARK: 一行

    /// C 区一行 = 四要素各归其位（§3.C）：
    /// 第一行 `reasonLabel` + 带/不带符号的 `amount`；第二行 时间 + 「余额 `balanceAfter`」。
    /// **颜色纪律**（D12 的直接落点）：金额一律 `color.fg` —— 不用 `color.error`
    /// （扣费不是错误）、不用 `color.success`（签到/退款不是奖励）；方向由符号表达，不由颜色表达。
    private func entryRow(_ row: CreditsLedgerRow) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(row.reasonText)
                    .font(CovaType.headline)
                    .foregroundStyle(CovaColor.fg)
                    // §8：`reasonLabel` 1 行截断（AX 2 行）；金额不被挤出（§6）。
                    .lineLimit(axLayout ? 2 : 1)
                    .layoutPriority(1)
                Spacer(minLength: CovaSpace.sm)
                amount(row.amount)
                    .fixedSize()
            }
            if axLayout {
                // §6 Dynamic Type：AX 档下第二行的时间与「余额」上下堆叠。
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    timeText(row)
                    balance(row.balanceValue)
                }
                // 「任务」钮恒换到第三行满宽。
                if row.showsJobLink {
                    jobLink(row, stretches: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                    timeText(row)
                    Spacer(minLength: CovaSpace.sm)
                    // §3.D：与「余额」同一行时余额位左移。
                    balance(row.balanceValue)
                    if row.showsJobLink {
                        jobLink(row)
                    }
                }
            }
        }
        // TG-19 行最小高 52（上下内边距 `spacing.md`）。行**不可点**：明细是终点。
        .frame(maxWidth: .infinity, minHeight: CreditsLedgerMetrics.rowMinHeight, alignment: .leading)
        .padding(.vertical, CovaSpace.md)
        // §6：**每行单元素**复合标签（原因，金额（带方向词），余额，时间〔，任务〕）。
        // 唯一的交互是 D 钮，所以那一枚在这里以"行的一次动作"的形式暴露给 VoiceOver，
        // 避免同一行上出现两个可聚焦元素；屏上看得见的那一枚仍然自己承担 44pt 触控热区。
        // 动作**只在有链接时存在**（`RowActionModifier`）：挂一个什么都不发生的空动作，
        // 就是 §7 禁止的"钮常驻、点击后报错"的可访问性版本。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .modifier(RowActionModifier(action: rowLinkAction(for: row)))
    }

    /// 行 → 那条可选的 VoiceOver 动作。`nil` = 这一行没有可跳的地方（`jobId` 为 null）
    /// ⇒ 既不加 `.isButton` 也不挂动作（同一行"存在两个停"与"念得出却点不动"都不许发生）。
    private func rowLinkAction(for row: CreditsLedgerRow) -> (() -> Void)? {
        guard let jobID = row.linkedJobID else { return nil }
        return { session.openCreditsLedgerJob(jobID) }
    }

    /// 时间位（`createdAt`，口径 = 08 §8 唯一源 `StudioRelativeTime`）。
    /// 缺失 ⇒ **不渲染**（不显示「—」噪声，§7 异常值条）。
    @ViewBuilder
    private func timeText(_ row: CreditsLedgerRow) -> some View {
        if let timeText = row.timeText {
            Text(timeText)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.muted)
        }
    }

    /// 金额位：`±amount`（`type.mono` / `color.fg`）+ 单位「co」（`type.caption` / `color.muted`），
    /// 两者间距 `spacing.sm`。`amount` 缺失 ⇒ **整段不渲染**（行仍保留，§7 异常值条）。
    @ViewBuilder
    private func amount(_ amount: CreditsLedgerAmount?) -> some View {
        if let amount {
            HStack(alignment: .lastTextBaseline, spacing: CovaSpace.sm) {
                // 判不出方向时 `symbolPrefix` 是空串 ⇒ 符号位**不渲染**（宁缺不猜，§7「±」第 ③ 档）。
                Text(amount.displayText)
                    .font(CovaType.mono)
                    .foregroundStyle(CovaColor.fg)
                Text(CreditsLedgerCopy.creditUnit)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
            }
        }
    }

    /// 「余额 %d」：标签 `type.caption` / `color.muted`，数字 `type.mono`。
    /// 可疑值（缺 / 负）⇒ 那一位是 `--`（TG-29）：不显示可疑数字，也**不**告警。
    /// 余额 0 与余额 128 布局同构（§9 判据）：这一位对 0 不做任何特殊处理。
    private func balance(_ raw: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.xs) {
            Text(CreditsLedgerCopy.balanceLabel)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.muted)
            Text(CreditsLedgerCopy.balanceValueText(raw))
                .font(CovaType.mono)
                .foregroundStyle(CovaColor.muted)
        }
    }

    /// D 「任务」钮：文字钮 `type.callout` / `color.accentText` + `chevron.right`（`color.muted`），
    /// ≥44pt 热区（TG-03）。**出现条件 = `jobId != null`**（`CreditLedgerRow.showsJobLink`）。
    ///
    /// 内层按钮对 VoiceOver 隐藏：行的复合标签末尾已带「任务」并挂了 `.isButton` 与一个动作，
    /// 再让内层按钮进序列就是同一件事念两遍（§6 的序列里没有第二停）。
    ///
    /// ⚠️ 落点与 22 §1 有一处**已登记的偏差**：规格要的是 20 的任务定位形态（`?job=`），
    /// 而路由值 `AppSession.Route.worksList` 今天不带关联值 ⇒ 落最近的已存在目的地
    /// （20 的常规定位形态）。理由与后果写在 `AppSession.openCreditsLedgerJob(_:)`。
    private func jobLink(_ row: CreditsLedgerRow, stretches: Bool = false) -> some View {
        Button {
            if let jobID = row.linkedJobID { session.openCreditsLedgerJob(jobID) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.xs) {
                Text(CreditsLedgerCopy.jobLink)
                    .font(CovaType.callout)
                    .foregroundStyle(CovaColor.accentText)
                Image(systemName: "chevron.right")
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: CreditsLedgerMetrics.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    // MARK: 17-S2 空态

    /// 三段（插画位 TG-43 + 标题 + 引导 + 主 CTA）。
    ///
    /// **只有一枚 CTA**：不放「签到领 co」类第二枚 —— 签到属手册 §5 P3 未接（画出来就是假入口），
    /// 而且那是把用户往「赚 co」方向推，与 D12 的最小化合规口径相悖。
    /// 主 CTA 落 19「做一首歌」（`Route.studioCreate` 已存在），用 `gradient.brandButton`：
    /// 本屏唯一允许的品牌渐变落点。
    private var emptyState: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.muted)
                .accessibilityHidden(true)
            Text(CreditsLedgerCopy.emptyTitle)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
            Text(CreditsLedgerCopy.emptyHint)
                .font(CovaType.callout)
                .foregroundStyle(CovaColor.secondary)
                .multilineTextAlignment(.center)
            GradientCTA(CreditsLedgerCopy.emptyAction) {
                session.navigate(to: .studioCreate)
            }
            .padding(.top, CovaSpace.md)
        }
        .padding(CovaSpace.xxl)
        .frame(maxWidth: .infinity)
        .padding(.top, CovaSpace.xl)
    }

    // MARK: 17-S3 整屏错误

    /// 首载失败且无缓存 ⇒ 整屏「明细没取到」+「重试」（§4 的④形态）。
    ///
    /// 为什么这里不直接用 `CovaErrorState`：它的标题是 17-S3 的通用四类（「网络不可用」/
    /// 「服务暂时不可用」…），而 22 §4/§8 给本屏钉的是「明细没取到」这一句 —— 屏的措辞赢。
    /// 分类本身没丢：副行仍由 `CatalogService.classify` 分派（网络 / 服务端消息 / 401 / 契约缺口），
    /// 401 说「登录状态已过期」并交给会话层统一处理（§4：各屏不各自弹登录框 ⇒ 这里不 present 登录）。
    private var wholeScreenFailure: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.error.opacity(0.8))
                .accessibilityHidden(true)
            Text(CreditsLedgerCopy.readFailed)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
            Text(state.failure?.userText ?? CreditsLedgerCopy.offlineNoCache)
                .font(CovaType.subhead)
                .foregroundStyle(CovaColor.secondary)
                .multilineTextAlignment(.center)
            CovaButton(CreditsLedgerCopy.retry, style: .secondary) {
                Task { await session.loadCreditsLedger() }
            }
            .frame(maxWidth: 180)
        }
        .padding(CovaSpace.xxl)
        .frame(maxWidth: .infinity)
        .padding(.top, CovaSpace.xl)
    }
}

// MARK: - 零件与档位

/// 「有落点才挂动作」的一档行内动作（22 §6 与 23 §6 共用同一族判断）。
///
/// 为什么必须有这一层：SwiftUI 的 `accessibilityAction` 没有"可选动作"的重载，
/// 而条件性地挂它需要两个不同的返回类型 —— `ViewModifier` 的 `@ViewBuilder body`
/// 正好是那个合法的分叉点。
/// 反面做法有两个：① 永远挂一个空动作（VO 用户激活后什么都没发生，
/// 与 §7 禁止的「钮常驻、点击后报错」同一族）；② 永远加 `.isButton`
/// （屏上根本没有那一枚的行会被念成按钮）。
struct RowActionModifier: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content
                .accessibilityAddTraits([.isButton])
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// 本屏的几何档（TG 未入库 ⇒ 收在一处，不散落裸字面量。同 `MineMetrics` / `ShellMetrics`）。
enum CreditsLedgerMetrics {
    /// TG-19 列表行最小高。
    static let rowMinHeight: CGFloat = 52
    /// TG-03 触控最小高（「任务」钮 / 空态与重试 CTA）。
    static let touchMin: CGFloat = 44
    /// §2 行分隔与 17-S4 描边的 1pt 档。
    static let hairline: CGFloat = 1
}

/// 空态主 CTA：`gradient.brandButton` + 白字 + 高 44（TG-07 按钮高度档未入库）。
///
/// 为什么不在这里用 `CovaButton`：那一支是 `color.accent` 实心（17 组件族），
/// 而 22 §4 给本屏空态钉的是渐变主钮；私改公共按钮组件会连带动到已验收的 12 屏观感
/// —— 与 `PlaylistPrimaryCapsuleButton` / 抽屉「登录」钮同一个先例：几何落在屏侧。
private struct GradientCTA: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CovaType.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: 220, minHeight: CreditsLedgerMetrics.touchMin)
                .background(CovaGradient.brandButton, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
