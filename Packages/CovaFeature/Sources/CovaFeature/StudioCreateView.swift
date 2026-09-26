import CovaCore
import CovaUI
import SwiftUI

/// 19 · 创作台（一句话做歌）。
///
/// 规格：`design/screens/19-studio-create.md`。P0 施工 `mode:'simple'` + `operation:'create'`；
/// **P1-2 起**这一屏多了「翻唱 / 续写 / 重制」三档与源选择器（19 待裁决 1 原本就把 B 区
/// 预留给"歌词+风格双输入与 `continueAt` 选择器"，这次落的是后者那一半）。
/// 仍未渲染的是 `advanced`（歌词/风格分栏）与 `melody` —— 画着但发不出去的东西就是谎，
/// 所以那两档的入口继续不出现，不是置灰。
///
/// 三条硬规矩都落在这棵视图之外，所以这里没有绕过的入口：
/// · 幂等键（一次点击一把、重试复用）住在 `AppSession.submitStudioCreate()` /
///   `retryStudioCreateSubmission()`；
/// · 轮询腿归会话层（退屏继续跑，钱已扣的任务不能因为退屏就看不见）；
/// · 上报（伪 trackId）在播放层，本屏只是起播方。
struct StudioCreateView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var promptFocused: Bool
    @State private var pendingDelete: CreateWorkItemDto?
    @State private var sourcePickerShown = false
    /// 23 制作人面板开没开（宿主 = 下面那一枚「+」；灰度关闭时那枚「+」根本不渲染）。
    @State private var producersShown = false

    private var state: AppSession.StudioCreateState { session.studioCreate }

    /// 输入框与 `session.studioCreatePrompt` 的双向腿。刻意用显式 `Binding(get:set:)`
    /// 而不是 `@Bindable var session = session`：本地属性包装器在这个工程里没有先例，
    /// 而 `$session` 的投影在函数体内也拿不到（编译期就红）。
    private var promptBinding: Binding<String> {
        Binding(
            get: { session.studioCreatePrompt },
            set: { session.studioCreatePrompt = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                operationCard
                promptCard
                if state.phase != .idle { taskSection }
                if !state.works.isEmpty { worksSection }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.bottom, CovaSpace.xxl)
        }
        .covaPage()
        .navigationTitle("做一首歌")
        .navigationBarTitleDisplayMode(.inline)
        // 20「我的作品」的**生产入口**。没有它，20 就只能靠走查键 `COVA_PREVIEW_ROUTE` 到达 ——
        // 那等于"有一张截图但没有这一屏"（04 抽屉就是这么被记为生产不可达的）。
        // 放在导航条而不是结果区：结果区只有刚生成完才存在，而"看我所有的作品"
        // 与"这一次刚做出两首"是两件事。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部作品") { session.path.append(.worksList(jobID: nil)) }
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.accentText)
                    .accessibilityIdentifier("cova.works.open")
            }
        }
        .confirmationDialog(
            "删除本机文件？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let work = pendingDelete {
                    Task { await session.removeSavedWork(work) }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .sheet(isPresented: $sourcePickerShown) { sourcePickerSheet }
    }

    // MARK: - P1-2：操作档位 + 源选择 + 续写起点

    /// 四档操作。**只有 `create` 之外的三档需要源**，所以源那一格跟着档位出现/消失，
    /// 而不是常驻一个"选了也没用"的选择器。
    private var operationCard: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            HStack(spacing: CovaSpace.sm) {
                ForEach(StudioCreateOperation.allCases, id: \.self) { operation in
                    CovaChip(
                        Self.operationLabel(operation),
                        isSelected: session.studioCreateOperation == operation
                    ) {
                        session.studioCreateOperation = operation
                        // 从"要源"的档位切回创作 ⇒ 清掉源与起点，
                        // 否则下一次提交会带着一个屏上已经看不见的 sourceClipId。
                        if operation == .create { session.clearStudioCreateSource() }
                        if operation != .extend { session.studioCreateContinueAt = nil }
                    }
                    .accessibilityIdentifier("cova.operation.\(operation.rawValue)")
                }
                Spacer()
            }
            if session.studioCreateOperation != .create { sourceRow }
            if session.studioCreateOperation == .extend,
               let duration = session.studioCreateSource?.duration, duration > 0 {
                continueAtRow(duration: duration)
            }
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        if let source = session.studioCreateSource {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    Text("续作要以它为源").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                }
                Spacer()
                Button("换一首") { sourcePickerShown = true }
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.accentText)
                Button("清除") { session.clearStudioCreateSource() }
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.secondary)
            }
            .accessibilityIdentifier("cova.source.row")
        } else {
            CovaButton("选择源作品", style: .secondary) {
                Task {
                    await session.loadStudioCreateSources()
                    sourcePickerShown = true
                }
            }
            .accessibilityIdentifier("cova.source.pick")
        }
    }

    /// 起点：**默认是"结尾"**（不送 `continueAt`，服务端自己接），所以滑杆的初值就停在最右，
    /// 而不是 0 —— 从 0 开始续写在语义上是"整首重来"，那是另一件事。
    private func continueAtRow(duration: Double) -> some View {
        let upper = min(duration, StudioCreateGenerateRequestDto.continueAtMaximumSeconds)
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            HStack {
                Text("续写起点").font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                Spacer()
                Text(
                    session.studioCreateContinueAt.map(Self.time) ?? "结尾"
                )
                .font(CovaType.caption.monospacedDigit())
                .foregroundStyle(CovaColor.muted)
            }
            Slider(
                value: Binding(
                    get: { session.studioCreateContinueAt ?? upper },
                    set: { session.studioCreateContinueAt = $0 }
                ),
                in: 0...max(upper, 1), step: 1
            ) {
                Text("续写起点")
            }
            .accessibilityIdentifier("cova.source.continueAt")
            Button(session.studioCreateContinueAt == nil ? "改为从指定位置" : "回到「结尾」") {
                session.studioCreateContinueAt = nil
            }
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.accentText)
        }
    }

    private var sourcePickerSheet: some View {
        NavigationStack {
            Group {
                if session.studioCreateSources.isEmpty {
                    VStack(spacing: CovaSpace.md) {
                        Text(
                            session.studioCreateSourcesFailed
                                ? "源作品没读到，可以重试" : "还没有可以当源的作品"
                        )
                        .font(CovaType.body)
                        .foregroundStyle(CovaColor.secondary)
                        if session.studioCreateSourcesFailed {
                            Button("重试") {
                                Task {
                                    await session.loadStudioCreateSources()
                                }
                            }
                            .foregroundStyle(CovaColor.accentText)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(session.studioCreateSources, id: \.id) { row in
                        Button {
                            session.chooseStudioCreateSource(workID: row.id)
                            sourcePickerShown = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayTitle ?? "未命名作品")
                                    .font(CovaType.subhead)
                                    .foregroundStyle(CovaColor.fg)
                                Text(
                                    row.displayDuration.map(Self.time) ?? "时长未知"
                                )
                                .font(CovaType.caption)
                                .foregroundStyle(CovaColor.muted)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选一首作源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { sourcePickerShown = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    static func operationLabel(_ operation: StudioCreateOperation) -> String {
        switch operation {
        case .create: return "创作"
        case .cover: return "翻唱"
        case .extend: return "续写"
        case .remaster: return "重制"
        }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - B 描述卡 + C 主 CTA

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            ZStack(alignment: .topLeading) {
                if session.studioCreatePrompt.isEmpty {
                    Text("说场景、说情绪、说人声…（例如：夏夜城市里的合成器流行，女声，中速）")
                        .font(CovaType.body)
                        .foregroundStyle(CovaColor.muted)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: promptBinding)
                    .font(CovaType.body)
                    .foregroundStyle(CovaColor.fg)
                    .focused($promptFocused)
                    // 验收腿的稳定选择器（`CovaAcceptanceTests` 靠它注入文本；
                    // 只加标识符，不改任何可见行为与样式）。
                    .accessibilityIdentifier("cova.prompt")
                    .frame(minHeight: 96, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .onChange(of: session.studioCreatePrompt) { _, value in
                        // 超长由**输入端截断**：不发出一个明知会换 400 的请求（19 §3.B）。
                        if value.count > StudioCreateGenerateRequestDto.promptMaximumLength {
                            session.studioCreatePrompt = String(
                                value.prefix(StudioCreateGenerateRequestDto.promptMaximumLength)
                            )
                        }
                    }
                    .accessibilityLabel("音乐描述")
            }
            HStack {
                // 23 的宿主：创作输入「+」（§5 P2-2 的原文落点）。
                // **灰度关闭 ⇒ 这一枚整个不出现**，不是置灰、不是"点了说没有"——
                // A10 那句「普通账号 {producers:[]} ⇒ 入口不可见（不是置灰）」就是这个意思。
                // 读失败也不出现：把"没读到"画成"没有"是替后端下了结论。
                if session.producersEntranceVisible {
                    Button {
                        producersShown = true
                    } label: {
                        Image(systemName: "plus")
                            .font(CovaType.subhead)
                            .foregroundStyle(CovaColor.accentText)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("制作人")
                    .accessibilityIdentifier("cova.producers.plus")
                }
                Spacer()
                Text("\(session.studioCreatePrompt.count)/\(StudioCreateGenerateRequestDto.promptMaximumLength)")
                    .font(CovaType.caption.monospacedDigit())
                    .foregroundStyle(atLimit ? CovaColor.warning : CovaColor.muted)
                    .accessibilityLabel("\(session.studioCreatePrompt.count)，共 \(StudioCreateGenerateRequestDto.promptMaximumLength) 字")
            }
            CovaButton(
                state.phase == .idle ? "开始生成" : "再做一首",
                style: .primary,
                isLoading: state.phase == .submitting
            ) {
                if state.phase == .idle {
                    session.submitStudioCreate()
                } else {
                    session.resetStudioCreate()
                    promptFocused = true
                }
            }
            .disabled(!session.canSubmitStudioCreate)
            .accessibilityHint(state.isBusy ? "这次提交还在跑" : "一次点击提交一次任务")
        }
        .padding(CovaSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .fill(CovaColor.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .strokeBorder(
                    promptFocused ? CovaColor.accent : CovaColor.line,
                    lineWidth: 1
                )
        )
    }

    private var atLimit: Bool {
        session.studioCreatePrompt.count >= StudioCreateGenerateRequestDto.promptMaximumLength
    }

    // MARK: - D 任务区

    @ViewBuilder
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            CovaSectionHeader("本次任务")
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(statusLabel)
                    .font(CovaType.subhead)
                    .foregroundStyle(statusIsError ? CovaColor.error : CovaColor.secondary)
                if state.phase == .submitting || state.isPolling {
                    Text("已等 \(PlayerTime.elapsed(state.elapsed))")
                        .font(CovaType.subhead.monospacedDigit())
                        .foregroundStyle(CovaColor.secondary)
                        .accessibilityLabel(PlayerTime.elapsed(state.elapsed))
                }
                Spacer(minLength: 0)
            }
            if state.phase == .submitting || state.isPolling {
                CovaIndeterminateBar(moves: !reduceMotion)
                    .frame(height: 4)
            }
            if let message = state.message {
                Text(message)
                    .font(CovaType.callout)
                    .foregroundStyle(statusIsError ? CovaColor.error : CovaColor.secondary)
            }
            if let line = state.chargeLine {
                // 那句话由 `AppSession.studioCreateChargeLine` 派生（不照抄 `charge`：
                // 重放时服务端照样回 `charge`，见 §7 #40）。nil ⇒ 整行不渲染，
                // 也**不写「免费」**：0 也可能只是开发环境的开关关闭（19 §3.D）。
                Text(line)
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
            }
            if state.canRetrySameSubmission {
                Button("重试这次提交") { session.retryStudioCreateSubmission() }
                    .font(CovaType.callout)
                    .foregroundStyle(CovaColor.accentText)
            }
            if state.phase == .failed {
                Button("重新生成") { session.submitStudioCreate() }
                    .font(CovaType.callout)
                    .foregroundStyle(CovaColor.accentText)
            }
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .idle: return ""
        case .submitting: return "已提交，正在排产"
        case .polling(let status): return status.userLabel
        case .succeeded: return GenerationJobStatus.succeeded.userLabel
        case .failed: return state.jobId == nil ? "没能完成" : GenerationJobStatus.failed.userLabel
        case .unconfirmed: return "还在做，稍后回来看"
        }
    }

    private var statusIsError: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    // MARK: - E 结果区

    private var worksSection: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            CovaSectionHeader("作品（\(state.works.count)）")
            ForEach(Array(state.works.enumerated()), id: \.element.id) { index, work in
                workRow(work, index: index)
            }
        }
        .task {
            await session.refreshSavedWorks()
            // 制作人卡只在 19 被打开时读一次：它是灰度开关的读数，服务端一改灰度
            // 下一次进这一屏就该看到，不留长期缓存。
            await session.loadProducerCards()
        }
        .sheet(isPresented: $producersShown) {
            ProducersPanelView()
        }
    }

    /// 行点击 = 播放（19 §3.E）；↓/✓ 是**独立一格**的按钮，不与播放共用热区
    /// —— 两件事混在一个 tap 里，用户按下去之前不知道按的是哪个。
    private func workRow(_ work: CreateWorkItemDto, index: Int) -> some View {
        let saved = session.savedWorkIDs.contains(work.id)
        let title = work.displayTitle ?? "未命名作品"
        return CovaListRow(
            title: title,
            subtitle: workSubtitle(work),
            artwork: CovaArtwork(
                resolution: CovaArtworkResolution(serverValue: work.coverUrl), title: title
            )
        ) {
            HStack(spacing: CovaSpace.md) {
                Image(systemName: "play.circle")
                    .foregroundStyle(CovaColor.accent)
                    .accessibilityHidden(true)
                Button {
                    if saved {
                        pendingDelete = work
                    } else {
                        Task { await session.saveWork(work) }
                    }
                } label: {
                    Image(systemName: saved ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(saved ? CovaColor.success : CovaColor.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? "删除本机文件" : "保存到本机")
            }
        } action: {
            Task { await session.playWork(work) }
        }
        .frame(minHeight: 64)
        // 验收腿的稳定选择器：结果行的标题是服务端生成的，测试事先不知道 ⇒ 只能按行号定位。
        .accessibilityIdentifier("cova.work.row.\(index)")
    }

    private func workSubtitle(_ work: CreateWorkItemDto) -> String {
        var parts: [String] = []
        if let duration = work.duration { parts.append(PlayerTime.elapsed(duration)) }
        if work.instrumental == true { parts.append("纯音乐") }
        return parts.joined(separator: " · ")
    }
}

/// 不确定条：**不是**进度条。契约里没有进度字段 ⇒ 不印百分比（19 §3.D）。
/// Reduce Motion 下退化成静态满条（60% 透明度），不再左右往返。
private struct CovaIndeterminateBar: View {
    var moves: Bool = true
    @State private var leading = false

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(CovaColor.accent.opacity(moves ? 1 : 0.6))
                .frame(width: moves ? max(24, geo.size.width * 0.32) : geo.size.width)
                .offset(x: moves ? (leading ? 0 : geo.size.width * 0.68) : 0)
                .onAppear {
                    guard moves else { return }
                    withAnimation(
                        .easeInOut(duration: 0.36)
                            .repeatForever(autoreverses: true)
                    ) { leading = true }
                }
        }
        .background(Capsule().fill(CovaColor.surface))
        .accessibilityHidden(true)
    }
}

/// 任务态的两个派生判据（放这里而不是塞进 `StudioCreateState` 的字段：
/// 它们是**从 phase 推出来的**，多存一份就多一个能与 phase 打架的账）。
extension AppSession.StudioCreateState {
    var isPolling: Bool {
        if case .polling = phase { return true }
        return false
    }

    /// 「重试这次提交」只在**没确认结果**的那一格出现 —— 那一格复用同一把幂等键，
    /// 服务端同键重放返回已有 jobId、不二次扣费（A11）。
    /// `.failed`（服务端明确说不）走的是「重新生成」= 新键，两句话不能混。
    var canRetrySameSubmission: Bool { phase == .unconfirmed }
}
