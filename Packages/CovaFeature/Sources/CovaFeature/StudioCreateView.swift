import CovaCore
import CovaUI
import SwiftUI

/// 19 · 创作台（一句话做歌 · P0 最小闭环）。
///
/// 规格：`design/screens/19-studio-create.md`。这一屏只施工 `mode:'simple'` +
/// `operation:'create'`，advanced / melody / cover / extend / remaster 的入口与控件
/// **一律不渲染**（不是置灰）—— 画着但发不出去的东西就是谎。
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
            .disabled(
                session.studioCreatePrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty || state.isBusy
            )
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
            if let charge = state.charge, charge > 0 {
                // `charge == 0` 不渲染这一行，也**不写「免费」**：0 也可能只是开发环境
                // 的开关关闭，客户端无从判别（19 §3.D）。
                Text("本次消耗 \(charge) co")
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
        .task { await session.refreshSavedWorks() }
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
