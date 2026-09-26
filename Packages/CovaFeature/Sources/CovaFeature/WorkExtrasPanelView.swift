import CovaCore
import CovaUI
import SwiftUI

// MARK: - 21 · 补充制作（extras 交付物 · 半屏面板 · P2-1 / A8）
//
// 规格：`design/screens/21-work-extras.md`。本文件施工 §3 的 **A–H 全部区块**：
// A 拖拽条（系统给，见 `detents` 那一段的理由）/ B 顶部条（✕ + 标题）/ C 已完成交付物组 /
// D 可选 key 组 + E key 行 / D2 合计行（仅会话路径）/ F 制作队列 / G 主钮 / H 事实行（仅作品路径）。
// 全部判据与文案住在 `WorkExtrasFlow.swift`（纯函数层），这一棵视图只负责摆。
//
// ⚠️ **两个宿主的"呼出位"都不在本任务的改动面内**（§1 入口① 归 20 的行 ⋯、入口② 归 09 的交付区，
// 两个文件都由别的工程在改）：`WorksListView.swift:480` 至今明写「补充制作属 P2-1 那一批 ⇒
// 本构建不渲染」。所以本文件交付的是**可呈现的面板本体**（`WorkExtrasPanelView(host:)`），
// 宿主接上 `.sheet` 即可用；接上之前 A8 的**设备**判据没有落点（已登记在交付说明）。
//
// 三条渲染纪律（都是"错了会骗人"那一类，判据在 Flow 侧，视图侧只保证不绕过）：
// · **作品路径不渲染任何 `co` 数字**：价目位与合计行的字面量在这一条腿上根本不存在
//   （`costText == nil` / `totalLine == nil`），只留一句「这里不消耗 co」（§3.H）；
// · **pending 行没有「保存到本机」**：F 组的行连钮都不构造（§3.F「整钮不渲染」，不是禁用态）；
// · **不可用的 key 整行不构造**：纯音乐作品那四项在视图树里不存在（不是置灰、不是"不支持"说明），
//   所以 §9 那条"视图树 / VoiceOver 序列 / 截图三处皆无"能机械判定。
//
// Reduce Motion（§4 命中 17-S5）：本视图**不写任何显式动画** ⇒ 勾选态一帧换色、行迁入 F 组
// 一帧到位、没有位移可退化；菊花按 spec 保留（指示性动效）。本屏也**没有进度条**
// （§7 无进度字段 ⇒ 不印百分比、不印 ETA）。

/// 21 面板（半屏 modal sheet，不入导航栈）。
public struct WorkExtrasPanelView: View {
    @Environment(AppSession.self) private var session
    /// AX 档（§6）：key 行的价目/副标换到标签下方、D2 的合计与余额两行堆叠。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: WorkExtraDeliveredRow?

    private let host: WorkExtrasHost
    /// 宿主的关闭钩子（`sheet(item:)` 那边置 nil 它自己的 @State）。
    ///
    /// 为什么是个闭包而不是只靠 `@Environment(\.dismiss)`：401/403 那一格要**面板主动请宿主关掉**
    /// （§4：关闭 sheet + 17-S6 会话层统一处理），而 dismiss 在 sheet 内容里能关自己的层，
    /// 但关掉之后宿主的 `sheet` 状态还得归零 —— 那一格只有宿主自己会做。
    private let onDismiss: (() -> Void)?

    public init(host: WorkExtrasHost, onDismiss: (() -> Void)? = nil) {
        self.host = host
        self.onDismiss = onDismiss
    }

    private var state: WorkExtrasState { session.workExtras }

    /// 余额（`entitlements.creditsBalance`，与 09 §3.G 同一口径，只在会话路径的 D2 出现）。
    ///
    /// `/me` 还没回来 ⇒ `nil` ⇒ **余额位不渲染**（§3.D2 与 09 §8 同规则：不得显 0）。
    /// 本屏没有充值/购买入口，余额只是扣费事实的一句说明（D12 硬边界 9）。
    private var creditsBalance: Int? {
        state.chargesCredits ? session.me?.entitlements.creditsBalance : nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if state.showsOfflineStrip { offlineStrip }
            ScrollView {
                VStack(alignment: .leading, spacing: CovaSpace.lg) {
                    content
                }
                .padding(.horizontal, CovaSpace.pageGutter)
                .padding(.bottom, CovaSpace.xxl)
            }
        }
        // §5：sheet 底 `color.elevated`（07 那一条腿沿用的是 `covaPage()` 的 canvas，
        // 本屏按 §5 明写的 elevated 摆；深浅两态的差异全在 token 的双值里，屏内无常量色）。
        .background(CovaColor.elevated.ignoresSafeArea())
        // 面板本体给验收腿一个稳定的根选择器（宿主怎么 present 不影响这里能定位到）。
        .accessibilityIdentifier("cova.extras.panel")
        // §2：默认高 = 屏高 60%、上滑至 92%（两档吸附）。TG-15 的 sheet 高未入 tokens ⇒
        // 与 07 同一处欠账，这里按 spec 的字面值施工（几何档收在 `WorkExtrasMetrics`，不散落）。
        .presentationDetents(detents)
        // A 拖拽条：交回系统指示条（07 §3.A 的同一判断 —— 自绘一根胶囊 + 两档吸附会画成**两根**条，
        // 而系统那条正是"还能往上拖"的官方语汇；TG-16 指示条几何档同样未入库）。
        .presentationDragIndicator(.visible)
        // 取数键 = 身份 + 宿主（两宿主共用一个容器：换一行作品必须重取，见 Flow 侧的理由）。
        .task(id: session.workExtrasOwnerKey) { await session.openWorkExtras(host: host) }
        // §4 的 401/403：关面板（登录框由会话层统一 present，本屏不自建）。
        .onChange(of: state.dismissRequested) { _, wanted in
            if wanted { close() }
        }
        .confirmationDialog(
            WorkExtrasCopy.deleteLocal,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(WorkExtrasCopy.delete, role: .destructive) {
                if let row = pendingDelete {
                    let id = row.artifactID
                    pendingDelete = nil
                    Task { await session.removeSavedWorkExtraArtifact(artifactID: id) }
                }
            }
            .accessibilityIdentifier("cova.extras.delete.confirm")
            Button(WorkExtrasCopy.cancel, role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier("cova.extras.delete.cancel")
        }
    }

    private var detents: Set<PresentationDetent> {
        axLayout ? [.large] : [
            .fraction(WorkExtrasMetrics.sheetFraction),
            .fraction(WorkExtrasMetrics.sheetFractionExpanded),
        ]
    }

    private func close() {
        // 「重开面板即重取」落在这里：作品腿没有版本计数器 ⇒ 关掉时必须把手里那份丢掉（Flow 侧注释）。
        session.closeWorkExtras()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    // MARK: B 顶部条（✕ + 标题）

    /// §3.B：✕ ≥44pt；标题两条措辞都**不带**计费字样。
    private var topBar: some View {
        HStack(spacing: CovaSpace.sm) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
                    .frame(width: WorkExtrasMetrics.touchMin, height: WorkExtrasMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(WorkExtrasCopy.close)
            .accessibilityIdentifier("cova.extras.close")
            Text(state.title)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
                .accessibilityIdentifier("cova.extras.title")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
    }

    // MARK: 内容三态（§4）

    @ViewBuilder
    private var content: some View {
        if state.showsWholePanelFailure {
            // ③ sheet 内整块替换（07 §4 先例）：error 符号 + 「补充制作没取到」+ 重试 + 关闭。
            wholePanelFailure
        } else if state.showsSkeleton {
            // §4 首载：C/F **不骨架**（它们可能整组不存在）；D 组骨架 + B/G 轮廓呼吸。
            loadingSkeleton
        } else {
            if state.showsDeliveredSection { deliveredSection }
            if state.showsOfflineStrip == false {
                if state.showsSelectableSection { selectableSection }
                if state.showsQueueSection { queueSection }
                trailingLines
            }
        }
    }

    // MARK: C 已经做好的（`files`，§3.C）

    private var deliveredSection: some View {
        let rows = state.deliveredRows
        return VStack(alignment: .leading, spacing: CovaSpace.sm) {
            // §6：分组标题那一停念「已经做好的，N 项」。
            sectionHeader(WorkExtrasCopy.deliveredHeader, count: rows.count)
            ForEach(rows) { row in
                deliveredRow(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cova.extras.delivered")
    }

    /// 一条交付物行（最小高 52，TG-19）。
    ///
    /// 副行**默认不渲染**（§3.C：体积/时长/分辨率/容器格式一个都不猜 —— `files[]` 的字段名
    /// 未文档化，那是待答 1）。上图里的「48.2 MB」是形态占位，实现不依赖它。
    private func deliveredRow(_ row: WorkExtraDeliveredRow) -> some View {
        let saving = state.savingArtifactIDs.contains(row.artifactID)
        return HStack(alignment: .center, spacing: CovaSpace.md) {
            if let symbol = row.symbol {
                // 20pt 档符号（TG-18），`color.secondary`；纯装饰 ⇒ 不进朗读序列（§6 那一停
                // 只念标签与动作，不念图标名）。
                Image(systemName: symbol)
                    .font(.system(size: WorkExtrasMetrics.symbolSize))
                    .foregroundStyle(CovaColor.secondary)
                    .frame(width: WorkExtrasMetrics.symbolSize)
                    .accessibilityHidden(true)
            }
            Text(row.label)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
                .lineLimit(WorkExtrasMetrics.labelLines)
            Spacer(minLength: CovaSpace.sm)
            saveAction(row, saving: saving)
        }
        .frame(minHeight: WorkExtrasMetrics.rowMinHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WorkExtrasPanelFacts.deliveredSpokenLabel(row))
        .accessibilityIdentifier("cova.extras.delivered.\(row.artifactID)")
        // 行内失败原文（§4 最后两行：取件失败 / 空间不足，都是**行内**不是 Toast）。
        .overlay(alignment: .bottomLeading) { rowMessage(row.artifactID) }
    }

    /// 「保存到本机」/「已在本机」两态（≥44pt；已在本机再点 = 删除本机文件，二次确认）。
    ///
    /// 措辞沿用 19 已定稿的那三串（§1 D12 第 3 条：不写「下载（需要 co）」「解锁文件」这类
    /// 把交付物和扣费绑在一起的话）。取件在途给菊花，不给百分比（§7 无进度字段）。
    @ViewBuilder
    private func saveAction(_ row: WorkExtraDeliveredRow, saving: Bool) -> some View {
        Button {
            if row.isSaved {
                pendingDelete = row
            } else {
                Task { await session.saveWorkExtraArtifact(artifactID: row.artifactID) }
            }
        } label: {
            HStack(spacing: CovaSpace.xs) {
                if saving {
                    ProgressView().controlSize(.small)
                } else if row.isSaved {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(CovaColor.success)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(CovaColor.accentText)
                        .accessibilityHidden(true)
                }
                Text(row.isSaved ? WorkExtrasCopy.saved : WorkExtrasCopy.save)
                    .font(CovaType.callout)
                    .foregroundStyle(CovaColor.accentText)
            }
            .frame(minHeight: WorkExtrasMetrics.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityLabel(row.isSaved ? "删除本机文件" : WorkExtrasCopy.save)
        .accessibilityIdentifier("cova.extras.delivered.\(row.artifactID).save")
    }

    // MARK: D 可以再做的 + E key 行（§3.D/§3.E）

    private var selectableSection: some View {
        let rows = state.selectableRows
        return VStack(alignment: .leading, spacing: CovaSpace.sm) {
            // §6：「可以再做的，N 项，多选」。
            sectionHeader(WorkExtrasCopy.selectableHeader, count: rows.count, suffix: "，多选")
            ForEach(rows) { row in
                keyRow(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cova.extras.selectable")
    }

    /// 一行 key（整行一个触控目标，≥44pt，§6）。
    ///
    /// 勾选态**不靠颜色**表达（§6）：语义在朗读标签里（「复选框，已勾选/未勾选」）+
    /// `.isSelected` 特征两件事上。iOS 没有 `.checkbox` 那个 `ToggleStyle`（它是 macOS 的），
    /// 所以圈的形状由 12a / 歌单选择那一族的手画态承担：未选 `color.line` 描边（`circle`）、
    /// 已选 `color.accent` 填充 + 白勾（`checkmark.circle.fill`），22pt 档（TG-18）。
    /// 整行是**一个** `Button`：勾选圈自己 22pt 吃不满 §6 要的 44pt，命中区必须挂在整行上。
    private func keyRow(_ row: WorkExtraSelectableRow) -> some View {
        Button(action: { session.toggleWorkExtra(row.key) }) {
            HStack(alignment: axLayout ? .top : .center, spacing: CovaSpace.md) {
                checkbox(row.isSelected)
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    Text(row.label)
                        .font(CovaType.headline)
                        .foregroundStyle(CovaColor.fg)
                        .lineLimit(
                            axLayout
                                ? WorkExtrasMetrics.labelLinesAX : WorkExtrasMetrics.labelLines
                        )
                    Text(row.caption)
                        .font(CovaType.caption)
                        .foregroundStyle(CovaColor.muted)
                        .lineLimit(
                            axLayout
                                ? WorkExtrasMetrics.captionLinesAX : WorkExtrasMetrics.captionLines
                        )
                    // §6 AX 档：价目换到标签下方第二行（非 AX 档留在右侧那一格）。
                    if axLayout, let costText = row.costText {
                        Text(costText)
                            .font(CovaType.subhead)
                            .foregroundStyle(CovaColor.accentText)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: CovaSpace.sm)
                if axLayout == false, let costText = row.costText {
                    // `type.subhead` / `color.accentText` + 等宽数字（TG-48 未入库 ⇒ 收在本屏几何档）。
                    // 价目是**事实陈述**：不进错误色、不进告警衬底（§6 末段 + D12 的精神）。
                    Text(costText)
                        .font(CovaType.subhead)
                        .foregroundStyle(CovaColor.accentText)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minHeight: WorkExtrasMetrics.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WorkExtrasPanelFacts.selectableSpokenLabel(row))
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        // 稳定选择器：验收腿按 key 的线格式拼写点名（`lyrics_timing`），不是屏上的中文标签。
        .accessibilityIdentifier("cova.extras.key.\(row.key.rawValue)")
    }

    /// 勾选圈（TG-18 的 22pt 档）。装饰件：朗读由整行的标签负责，所以它自己不进朗读序列。
    private func checkbox(_ checked: Bool) -> some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: WorkExtrasMetrics.checkboxSize))
            .foregroundStyle(checked ? CovaColor.accent : CovaColor.line)
            .frame(
                width: WorkExtrasMetrics.checkboxSize, height: WorkExtrasMetrics.checkboxSize
            )
            .accessibilityHidden(true)
    }

    // MARK: F 制作队列（§3.F）

    private var queueSection: some View {
        let rows = state.queueRows
        return VStack(alignment: .leading, spacing: CovaSpace.sm) {
            sectionHeader(WorkExtrasCopy.queueHeader, count: rows.count)
            ForEach(rows) { row in
                queueRow(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cova.extras.queue")
    }

    /// 一行在途：符号 + 标签 +「制作中」+ 菊花。**没有**「保存到本机」（pending 没有 url，
    /// 而 `WorkExtraQueueRow.showsSaveAction` 在类型面上就是 false）；也没有百分比与剩余时间
    /// （§7 没有进度字段 ⇒ 不印，19 §3.D 同规则）。
    private func queueRow(_ row: WorkExtraQueueRow) -> some View {
        HStack(alignment: .center, spacing: CovaSpace.md) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: WorkExtrasMetrics.symbolSize))
                    .foregroundStyle(CovaColor.secondary)
                    .frame(width: WorkExtrasMetrics.symbolSize)
                    .accessibilityHidden(true)
            }
            Text(row.label)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
                .lineLimit(WorkExtrasMetrics.labelLines)
            Spacer(minLength: CovaSpace.sm)
            if let statusText = row.statusText {
                Text(statusText)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.warning)
            }
            if row.showsIndeterminate {
                // 17-S8 的"不确定指示"专用规则；Reduce Motion 下**保留**（指示性动效，§4）。
                // `color.warning` 的衬底不铺：`warningSoft` 未入库（TG-21 欠账在 09/12d/17-S4
                // 已经记过，本屏不再自造色 —— §5 末段）。
                ProgressView().controlSize(.mini)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: WorkExtrasMetrics.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WorkExtrasPanelFacts.queueSpokenLabel(row))
        .accessibilityIdentifier("cova.extras.queue.\(row.id)")
    }

    // MARK: D2 合计行 + G 主钮 + 行内话 + H 事实行

    /// 最后四格的顺序（§2）：D2 合计在 G 上方；G 下方依次是行内失败原文、409 的行内话、H 事实行。
    @ViewBuilder
    private var trailingLines: some View {
        if let total = state.totalLine(balance: creditsBalance) {
            totalLine(total)
        }
        if state.showsSelectableSection {
            mainButton
        }
        if let message = state.submitMessage {
            // §4 的 ② 行（400 / 429 / 502 / 503）：主钮下方一行服务端 `error` 原文，勾选保留。
            Text(message)
                .font(CovaType.subhead)
                .foregroundStyle(CovaColor.error)
                .lineLimit(WorkExtrasCopyLines.serverError)   // §8：≤3 行后中段截断
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("cova.extras.error")
        }
        if let note = state.waitingNote {
            // 「这个已经在做了」是**事实陈述**：不进错误色（§6 末段 + D12 的精神）。
            Text(note)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("cova.extras.note")
        }
        if let fact = state.factLine {
            // H（仅作品路径）：主钮下方 `spacing.sm`。价目与「不消耗 co」都是中性事实。
            Text(fact)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, CovaSpace.xs)
                .accessibilityIdentifier("cova.extras.fact")
        }
    }

    /// D2（仅会话路径、勾选数 > 0）：合计 + 余额位。
    ///
    /// 余额位是**另一个可选片段**：`creditsBalance` 取不到 ⇒ 只显合计，不显 0、也不显 `--`
    /// （§3.D2 + 09 §8）。AX 档两行堆叠（§6）。合计 `type.subhead` / `color.secondary`，
    /// 余额位低一档（`type.caption` / `color.muted`），数字等宽。
    @ViewBuilder
    private func totalLine(_ total: WorkExtrasTotalLine) -> some View {
        if axLayout {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                Text(total.text)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.secondary)
                if let balanceText = total.balanceText { balanceSlot(balanceText) }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(total.spokenLabel)
            .accessibilityIdentifier("cova.extras.total")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(total.text)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.secondary)
                if let balanceText = total.balanceText { balanceSlot(balanceText) }
                Spacer(minLength: 0)
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(total.spokenLabel)
            .accessibilityIdentifier("cova.extras.total")
        }
    }

    /// 余额位（两档排版共用同一份色/字级，避免"非 AX 档对了、AX 档跟着默认字级跑"）。
    private func balanceSlot(_ text: String) -> some View {
        Text(text)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.muted)
            .accessibilityIdentifier("cova.extras.balance")
    }

    /// G 主钮：胶囊高 50 + `gradient.brandButton` + 白字 `type.headline`（§3.G）。
    ///
    /// 在途 ⇒ 菊花替换文字且**不可二次点击**（`.disabled` + Flow 侧的 `submissionInFlight` 双保险：
    /// 一次点击 = 一个提交代号，绕不过去）。勾选 0 项 ⇒ disabled 形态（muted 底/字）且
    /// **不显示任何解释文案**（§3.G：空选择不需要教训用户）。
    private var mainButton: some View {
        Button(action: session.submitWorkExtras) {
            HStack(spacing: CovaSpace.sm) {
                if state.submissionInFlight { ProgressView().controlSize(.small) }
                Text(WorkExtrasCopy.start).font(CovaType.headline)
            }
            .foregroundStyle(state.canSubmit ? Color.white : CovaColor.muted)
            .frame(maxWidth: .infinity)
            .frame(height: WorkExtrasMetrics.primaryButtonHeight)
            .background {
                if state.canSubmit {
                    CovaGradient.brandButton
                } else {
                    CovaColor.surface
                }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    state.canSubmit ? Color.clear : CovaColor.line, lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.canSubmit == false)
        .accessibilityIdentifier("cova.extras.submit")
        .accessibilityHint(
            state.submissionInFlight ? "这次提交还在跑" : "一次点击提交一组补充制作"
        )
    }

    // MARK: 首载骨架 / 整块错误 / 离线条

    /// §4 首载：D 组 4–6 行勾选圈骨架 + 两条文本条（`color.surface` 呼吸）；B 与主钮轮廓呼吸。
    /// C/F **不骨架** —— 它们可能整组不存在（12c §4 / 17-S1「不骨架可能不存在的可选区」）。
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            ForEach(0..<WorkExtrasMetrics.skeletonRows, id: \.self) { _ in
                HStack(spacing: CovaSpace.md) {
                    Circle().fill(CovaColor.surface).frame(width: WorkExtrasMetrics.checkboxSize)
                    VStack(alignment: .leading, spacing: CovaSpace.xs) {
                        Capsule().fill(CovaColor.surface).frame(height: 14)
                            .frame(maxWidth: 150, alignment: .leading)
                        Capsule().fill(CovaColor.surface).frame(height: 10)
                            .frame(maxWidth: 96, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: WorkExtrasMetrics.rowMinHeight)
            }
            // G 的轮廓（只呼吸，不画出一个还没有文案的钮）。
            Capsule().fill(CovaColor.surface).frame(height: WorkExtrasMetrics.primaryButtonHeight)
        }
        .padding(.top, CovaSpace.md)
        // 骨架是占位形状，不是内容：整块不进朗读序列（§6 的朗读顺序里没有"骨架"这一停）。
        .accessibilityHidden(true)
    }

    /// ③ sheet 内整块替换（§4）：error 符号 +「补充制作没取到」+ 主钮「重试」+ 次钮「关闭」。
    private var wholePanelFailure: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: failureSymbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.error.opacity(0.8))
                .accessibilityHidden(true)
            Text(WorkExtrasCopy.readFailed)
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
            if let hint = failureHint {
                Text(hint)
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.secondary)
                    .multilineTextAlignment(.center)
            }
            CovaButton(WorkExtrasCopy.retry, style: .secondary) {
                Task { await session.loadWorkExtras() }
            }
            .frame(maxWidth: 220)
            .accessibilityIdentifier("cova.extras.retry")
            Button(WorkExtrasCopy.close, action: close)
                .font(CovaType.callout)
                .foregroundStyle(CovaColor.accentText)
                .frame(minHeight: WorkExtrasMetrics.touchMin)
                .accessibilityIdentifier("cova.extras.dismiss")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CovaSpace.xxl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cova.extras.failed")
    }

    /// 整块那一句只说「补充制作没取到」；副行只在**服务端自己给了话**时才多一行（透传原文，
    /// 不编「未知错误」—— A4/A15）。离线的形态走上面那条细条，不在这里重复一次。
    private var failureHint: String? {
        switch state.readFailure {
        case .server(let message), .clientSide(let message): return message
        case .network, .unauthenticated, .unreadable, nil: return nil
        }
    }

    private var failureSymbol: String {
        switch state.readFailure {
        case .network: return "wifi.slash"
        case .unauthenticated: return "person.crop.circle.badge.xmark"
        default: return "server.rack"
        }
    }

    /// 17-S4 离线条（sheet 内为**细条**形态，§4 离线行）。
    ///
    /// 衬底沿用 17-S4 的 `color.accentSoft` 过渡并计入 **TG-21**（`warningSoft` 未入库，
    /// 09/12d/17-S4 同一条欠账，本屏不再自造色 —— §5 末段）。
    private var offlineStrip: some View {
        Text(WorkExtrasCopy.offline)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.sm)
            .background(CovaColor.accentSoft)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CovaColor.warning).frame(height: 1)
            }
            .accessibilityIdentifier("cova.extras.offline")
    }

    /// 分组的 `type.caption` / `color.muted` 标题（03/19 同档），§6 那一停带计数。
    private func sectionHeader(_ title: String, count: Int, suffix: String = "") -> some View {
        Text(title)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.muted)
            .accessibilityLabel("\(title)，\(count) 项\(suffix)")
    }

    /// 行内失败原文（右对齐那一格下面，不抢标签的位置）。
    @ViewBuilder
    private func rowMessage(_ artifactID: String) -> some View {
        if let message = state.rowMessages[artifactID] {
            Text(message)
                .font(CovaType.caption)
                .foregroundStyle(CovaColor.error)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(y: WorkExtrasMetrics.rowMessageOffset)
                .accessibilityIdentifier("cova.extras.row.\(artifactID).message")
        }
    }
}

// MARK: - 几何档（本屏的 TG 欠账收在一处）

/// 21 的几何档。
///
/// TG-47（多选清单行的排版档）与 TG-48（费用/合计行的字级与色档）**未入库**（§「Token 缺口」），
/// TG-15/TG-16/TG-18/TG-19 也从 07/12a 继承着没有值 ⇒ 本屏的字面值全部收在这一个 enum 里，
/// 不在 `body` 里散落裸数；入库时只改这一处。
enum WorkExtrasMetrics {
    /// TG-15（sheet 高，继承 07）：默认 60%、上滑 92%。
    static let sheetFraction: CGFloat = 0.6
    static let sheetFractionExpanded: CGFloat = 0.92
    /// TG-19（行最小高，继承 12a）：交付物 / key / 队列三种行同一个档。
    static let rowMinHeight: CGFloat = 52
    /// 触控最小高（§6：✕ / 每枚文字钮 / 主钮之外的钮都吃这一档）。
    static let touchMin: CGFloat = 44
    /// G 主钮胶囊高（§3.G）。
    static let primaryButtonHeight: CGFloat = 50
    /// TG-18 符号 20pt 档 / 勾选圈 22pt 档。
    static let symbolSize: CGFloat = 20
    static let checkboxSize: CGFloat = 22
    /// §8 截断：标签 1 行（AX 不截）；副标 1 行（AX 2 行）。
    static let labelLines = 1
    static let labelLinesAX = 2
    static let captionLines = 1
    static let captionLinesAX = 2
    /// 首载骨架的行数（§4「4–6 行」；取 5 落在区间中间，不假装我们知道有几格）。
    static let skeletonRows = 5
    /// 行内原文的偏移（贴着行底，不另起一行高度）。
    static let rowMessageOffset: CGFloat = 14
}

/// §8「服务端 `error` 原文 ≤3 行后中段截断」。单独立一档是为了不和上面的排版档混读。
private enum WorkExtrasCopyLines {
    static let serverError = 3
}
