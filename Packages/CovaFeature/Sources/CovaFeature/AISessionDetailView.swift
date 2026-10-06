import CovaCore
import CovaPlayer
import CovaUI
import Foundation
import SwiftUI

/// 会话详情（design 09）：对话流 + 深度思考折叠 + 唯一一条 run 行 + 计划卡 + 双 Demo + 输入框。
///
/// 这一屏的规则几乎全是「不许做什么」，逐条落进代码：
/// · **不做本地余额预检**（缺钱由服务端说，UI 只回显它给的）；
/// · 不出现「充值 / 购买 / 价格 / 客服」任何字样，也不显示英文状态名；
/// · `audioUrl` / `audioDownloadStatus` 的签名地址**不显示、不写日志、不落盘**（`SecretString` 三面脱敏）；
/// · 双 Demo 只渲染**前两个**候选，两个都 settled 才算终态（硬边界 6）—— 判定不在本屏写，
///   一律走 `DoubleDemoRule`（CovaCore，18 的本地通知读同一本账）；
/// · 「开始制作」按 §9 表：`ready` 可启动、`retryable_failure` 可「重新制作」（换新幂等键），
///   且必须已归因 + 带 `snapshotHash`，缺一置灰，不放宽；
/// · 未知 `run_*` 事件**隐藏且不算坏事件**；未知计划卡状态渲染只读卡 + 「状态更新中」。
public struct AISessionDetailView: View {
    @Environment(AppSession.self) private var session
    private let sessionID: String

    @State private var phase: Phase = .loading
    /// §3.A：标题来自后端；会话未文档化/没给名 ⇒ 「创作会话」（同 08 §7 降级口径）。
    @State private var sessionTitle = "创作会话"
    /// 导航 ⋯「查看会话信息」只读 sheet 的数据源（09 §3.A：v1.0 不做写操作）。
    @State private var sessionDto: StudioSessionDto?
    @State private var infoShown = false
    @State private var lines: [TranscriptLine] = []
    /// §10 窗口化：首载 >200 条时只渲染最近 100 条，被折叠的最旧行数记在这里；
    /// 顶部「加载更早消息」每点一次再放开 100 条（分页参数未文档化 ⇒ 本地已取集合承接）。
    @State private var historyHidden = 0
    @State private var plans: [OneStepPlanCardDto] = []
    @State private var candidates: [GenerationCandidateDto] = []
    /// 最近一轮生成任务：09 §I 的进度条用它读 6 态（§8「只驱动 I 进度条与 H 终态条」）。
    ///
    /// 写它的一律是"屏上刚拿到一份关于这一路的权威读数"：载荷两处（进屏 / 下拉对账）、
    /// `start` 核到任务那一处，以及 §5 P1-5 那条 jobs 轮询（`applyJobPoll` 里由
    /// `SessionJobPollReconcile.Decision.writesJob` 放行）。轮询**只**写这一行与（它自己带着
    /// 非空候选时）`candidates`，别的面向来不归它。
    @State private var latestJob: GenerationJobDto?
    /// `GET …/sessions/:id` 的 `session.workflowState`（E5：09 §3-I 那条进度的**真来源**）。
    @State private var workflow: StudioWorkflowStateDto?
    /// 候选 ♡ 的账：键 = `mediaReferenceId`，**每次详情载荷到达都整本重新播种**。
    @State private var favorites = CandidateFavoriteLedger()
    /// 计划启动的幂等键账本（D8）：同一 `(会话, 计划卡, revision)` 的**重试复用同一个键**；
    /// `retryable_failure` 的「重新制作」在 `start()` 开头 invalidate 换新（§9 行 11）。
    @State private var startTokens = PlanStartTokenLedger()
    /// 09 §Dynamic Type：AX 档下气泡放到整行、候选卡组纵向堆叠。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creditsBalance: Int?
    /// 断流恢复腿的三件（§5 P1-5 后半 / §7 #52）：号、归属令牌、在途那条腿。
    @State private var agentRunID: String?
    @State private var runPollToken = 0
    @State private var runPollTask: Task<Void, Never>?
    /// 降级条（§3.B）：同一容器承载 §4.2 四触发 + §10 长任务 + 轮询连败 + 局部提示。
    /// `nil` = 不渲染。文案全部来自 `DegradeVariant.text`（§10 固定文案清单内）。
    @State private var degradation: DegradeVariant?
    /// 降级轮询的**连续**失败计数（读数口 = `studioStreamState()` 的状态机事实；
    /// ≥4 时条内文案换 §4.2 那句「自动刷新也拿不到」并出「重试」）。
    @State private var pollFailures = 0
    /// 轮询期间定时重读状态机的节拍腿：轮询失败**不产生帧**，没有它计数永远上不了屏。
    @State private var degradationWatch: Task<Void, Never>?
    @State private var draft = ""
    @State private var deepThinking = false
    @FocusState private var composerFocused: Bool
    @State private var busy = false
    /// 本轮 thinking 折叠块的行 id（新一轮归零 ⇒ 每轮独立一块，不再发生
    /// `firstIndex` 误替第一轮那种缺陷）。
    @State private var thinkingLineID: Int?
    @State private var thinkingExpanded = false
    /// §3.F「只保留最后一条」的运行状态行 id + `run_completed` 3s 淡出的归属号。
    @State private var runLineID: Int?
    @State private var runFadeToken = 0
    /// 本轮是否**已经问过要挑哪一版**（09 §5 终态行）。
    @State private var choosingVersion = false
    /// 失败卡「重试」的那一次**读**在不在途（连点吞后发，同 §10 对 ♡ 的口径）。
    @State private var reconciling = false
    /// 21 面板（会话路径）开没开。
    @State private var extrasShown = false
    /// jobs 轮询那条腿的**归属号**（§5 P1-5）。
    @State private var jobPollToken = 0
    @State private var jobPollTask: Task<Void, Never>?
    @State private var lineCounter = 0
    @State private var agentBuffer = ""
    /// 本轮 agent 正文行的 id（逐 token 追加只改这一行）。
    @State private var agentLineID: Int?
    /// 「计划已在别处更新」的裁决底账：卡号 → 已播种的 revision（§10 并发冲突，
    /// 一次性 caption；进屏/本地写回显只播种不播报）。
    @State private var knownRevisions: [String: Int] = [:]
    @State private var elsewhereNoticeShown = false
    /// §7「1 条新回复 ⌄」浮钮 + 锚底判定（底标记 onAppear/onDisappear 近似——
    /// 屏上内容短于视口时恒锚底，上滚离开底部标记即非锚底）。
    @State private var pendingReplyNotice = false
    @State private var anchoredAtBottom = true
    /// 「开始制作」全局单在途（§10：多张 `ready` 卡并发点，后到者按钮 loading 且被吞）。
    @State private var startInFlight = false
    /// §10：计划卡 >5 张时最新一张默认展开，其余收为摘要行；点摘要行把它放进这里展开。
    @State private var expandedPlanIDs: Set<String> = []

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    /// §3.B 降级条的全部文案变体（§10「固定，禁改」文案清单内取值，除 `custom`）。
    private enum DegradeVariant: Equatable {
        /// §4.2 触发 1：10s 无首事件。
        case waiting
        /// §4.2 触发 2：30s 静默。
        case interrupted
        /// §4.2 触发 3：3 个坏事件。
        case unstable
        /// §4.2 触发 4：done 前 EOF。
        case resuming
        /// §4.2 注：轮询连续失败第 4 次起（条尾带「重试」）。
        case pollFailing
        /// §10 长任务：jobs 轮询到约 30min 上限仍非终态（复用同一容器，非 error）。
        case longTask
        /// §4.1 离线：网络类读失败 + 手里还有缓存消息（判定口径同 17-S4/22，不引入探活器）。
        case offline
        /// 局部读数提示（任务号没读到之类）：仍是"连接状态条"位，不是 error。
        case custom(String)

        var text: String {
            switch self {
            case .waiting: return "连接较慢，正在等待 Cova 回应"
            case .interrupted: return "连接中断，已切为自动刷新"
            case .unstable: return "连接不稳定，已切为自动刷新"
            case .resuming: return "本轮回复未结束，正在继续获取"
            case .pollFailing: return "自动刷新也拿不到，检查网络后点重试"
            case .longTask: return "这次制作时间超出预期，可以先离开，做好会在通知里找你"
            case .offline: return "离线，历史消息可看，暂不能继续"
            case .custom(let text): return text
            }
        }

        /// 是否随流生命周期收起：流降级四触发 + 连败在流恢复/结束时收；
        /// 长任务/离线/局部提示属于另一本账（jobs 轮询/一次读数/连通性），
        /// 不被 `refreshDegradation` 清掉。
        var persistsBeyondStream: Bool {
            switch self {
            case .longTask, .offline, .custom: return true
            case .waiting, .interrupted, .unstable, .resuming, .pollFailing: return false
            }
        }

        /// 对账成功后可以收掉的那一族（连败已手动补救 / 局部提示已被新读数覆盖 /
        /// 离线被这一次成功读数证伪）。
        var clearsOnReconcile: Bool {
            switch self {
            case .pollFailing, .offline, .custom: return true
            case .waiting, .interrupted, .unstable, .resuming, .longTask: return false
            }
        }
    }

    public init(sessionID: String) { self.sessionID = sessionID }

    /// §10 窗口化/折叠阈值（同一批常量集中在屏顶，抽查能对上 spec）。
    private static let historyWindow = 200
    private static let historyPage = 100
    private static let planCollapseThreshold = 5
    private static let bottomMarkerID = "cova.session.bottom"

    public var body: some View {
        VStack(spacing: 0) {
            if let degradation {
                degradationBar(
                    text: pollFailures >= 4 ? DegradeVariant.pollFailing.text : degradation.text,
                    retry: pollFailures >= 4 || degradation == .pollFailing
                )
            }
            transcript
            if showsEmptyGuide { emptyGuide }
            composer
        }
        .covaPage()
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { infoShown = true } label: {
                    Image(systemName: "ellipsis").foregroundStyle(CovaColor.fg)
                }
                .accessibilityLabel("会话信息")
            }
        }
        .task { await openSession() }
        .sheet(isPresented: $extrasShown) {
            WorkExtrasPanelView(host: .session(id: sessionID, instrumental: nil)) {
                extrasShown = false
            }
        }
        .sheet(isPresented: $infoShown) { sessionInfoSheet }
        // 他端登出/凭证吊销 ⇒ 本屏当帧终止流（D16 有界取消）并弹栈，
        // 由 17-S6/登录门槛接管（spec §4.1「他端登出」行）。
        .onChange(of: session.authPhase) { _, auth in
            guard case .signedIn = auth else {
                guard phase == .ready || phase == .loading else { return }
                Task {
                    stopJobPoll()
                    stopRunPoll()
                    await session.cancelStudioStream()
                    session.settleStudioJob(sessionID: sessionID)
                    session.pop()
                }
                return
            }
        }
        .onDisappear {
            // 屏不在了就没有观察者 ⇒ 三条在途的腿一起收掉：流照旧取消，
            // jobs/run 两条轮询也必须停（屏上看不见的东西不许继续花请求）。
            stopJobPoll()
            stopRunPoll()
            Task { await session.cancelStudioStream() }
        }
    }

    /// §3.A ⋯ 的「查看会话信息」：只读 sheet，不做写操作（08 待裁决 2 约束到 v1.0）。
    private var sessionInfoSheet: some View {
        NavigationStack {
            List {
                LabeledContent("标题", value: sessionTitle)
                if let sessionDto, let mode = sessionDto.workflowMode {
                    LabeledContent("模式", value: mode == "one-step" ? "一步模式" : mode)
                }
                if let created = sessionDto?.createdAt,
                   let text = StudioRelativeTime.text(created, now: Date(), calendar: .current) {
                    LabeledContent("创建时间", value: text)
                }
                if let updated = sessionDto?.updatedAt,
                   let text = StudioRelativeTime.text(updated, now: Date(), calendar: .current) {
                    LabeledContent("更新时间", value: text)
                }
                LabeledContent("消息数", value: "\(lines.count)")
            }
            .navigationTitle("会话信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { infoShown = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: 流式过程

    @ViewBuilder
    private var transcript: some View {
        switch phase {
        case .loading:
            SessionLoadingSkeleton()
        case .failed(let failure):
            CovaErrorState(kind: Self.kind(failure)) { Task { await openSession() } }
        case .ready:
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CovaSpace.md) {
                        if historyHidden > 0 {
                            Button {
                                historyHidden = max(0, historyHidden - Self.historyPage)
                            } label: {
                                Text("加载更早消息")
                                    .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                                    .frame(minHeight: 44)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(visibleLines) { line in
                            row(line).id(line.id)
                        }
                        planCardsBlock
                        if !candidates.isEmpty { candidateBlock }
                        if let deliveryProgress { deliveryProgressBar(deliveryProgress) }
                        // 锚底标记：出现在视口 ⇒ 用户在底部；离开 ⇒ 上滚了。
                        // spec §7 的「不打断朗读」锚定近似（注释见 `anchoredAtBottom`）。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomMarkerID)
                            .onAppear { anchoredAtBottom = true }
                            .onDisappear { anchoredAtBottom = false }
                    }
                    .padding(CovaSpace.pageGutter)
                }
                .refreshable { await reconcileRound(quietly: true) }
                .overlay(alignment: .bottom) {
                    // §7：新消息不打断朗读 —— 非锚底时才出这枚浮钮，点按回底。
                    if pendingReplyNotice {
                        Button {
                            pendingReplyNotice = false
                            scroll.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                        } label: {
                            Text("1 条新回复 ⌄")
                                .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                                .padding(.horizontal, CovaSpace.lg)
                                .frame(minHeight: 44)
                                .background(CovaColor.elevated)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, CovaSpace.sm)
                        .accessibilityLabel("1 条新回复，滚动到最新")
                    }
                }
                .onChange(of: lines.count) { old, new in
                    guard new > old else { return }   // 淡出移除/窗口化不视作"新回复"
                    contentAppended(scroll)
                }
                .onChange(of: plans.count) { _, _ in contentAppended(scroll) }
                .onChange(of: candidates.count) { _, _ in contentAppended(scroll) }
            }
        }
    }

    /// §10 窗口化的可见窗口 = 折叠了最旧 `historyHidden` 行之后的尾巴。
    private var visibleLines: ArraySlice<TranscriptLine> { lines.dropFirst(historyHidden) }

    /// §4.1「空会话」：新会话零消息零卡 ⇒ J 上方的一次性引导（不放空态插画）。
    private var showsEmptyGuide: Bool {
        phase == .ready && lines.isEmpty && plans.isEmpty && candidates.isEmpty
    }

    /// 新内容到达时的滚动裁决：锚底 ⇒ 直接跟到最新；非锚底 ⇒ 只出「1 条新回复」浮钮
    /// （§7：不打断 VoiceOver 朗读）。用户自己发出去的那一条不算"新回复"。
    private func contentAppended(_ scroll: ScrollViewProxy) {
        if anchoredAtBottom {
            pendingReplyNotice = false
            scroll.scrollTo(Self.bottomMarkerID, anchor: .bottom)
        } else if let last = lines.last, case .user = last.kind {
            // 用户自己的话到达时他在打字区，不弹浮钮
        } else {
            pendingReplyNotice = true
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine) -> some View {
        switch line.kind {
        case .user(let text):
            // §3.C：右对齐、`accentSoft` 底、`type.body`/`color.fg`；圆角 `radius.card`，
            // 靠尾角（指向说话人 = 底部朝发送区那一角）收 `radius.control`。
            // 最大宽 = 屏宽 × 78%（TG-01），AX 档放到整行（§7）。
            HStack {
                Spacer(minLength: 0)
                Text(text)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .padding(CovaSpace.md)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: CovaRadius.card,
                            bottomLeadingRadius: CovaRadius.card,
                            bottomTrailingRadius: CovaRadius.control,
                            topTrailingRadius: CovaRadius.card,
                            style: .continuous
                        )
                        .fill(CovaColor.accentSoft)
                    )
            }
            .containerRelativeFrame(
                .horizontal, count: 100, span: axLayout ? 100 : 78, spacing: 0, alignment: .trailing
            )
            // §7：每条消息一个容器元素 —— 「你，<文本>」。
            .accessibilityElement(children: .combine)
            .accessibilityLabel("你，\(text)")
        case .agentText(let text):
            // §3.D：无气泡、左对齐、`sparkles` 用 `gradient.ai` 着色（AI 渐变只用于创作语境），
            // 标识位 24pt 档（TG-18：头像位 24 ⇒ 符号本体 14pt 居中那一档）。
            HStack(alignment: .top, spacing: CovaSpace.sm) {
                Image(systemName: "sparkles")
                    .font(CovaSymbol.agentMark)
                    .foregroundStyle(CovaGradient.ai)
                    .frame(width: 24, height: 24, alignment: .topLeading)
                    .accessibilityHidden(true)
                Text(text)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cova，\(text)")
        case .thinking(let steps, let stalled):
            thinkingBlock(steps: steps, stalled: stalled)
        case .run(let event):
            runLine(event)
        case .system(let text):
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.muted)
        case .systemError(let text):
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.error)
        case .plan:
            EmptyView()   // 计划卡本体在 plans 那一层渲染，这里只留位置
        }
    }

    /// §3.E thinking 折叠块：收起一行「▸ 深度思考 · N 步」（≥44pt 热区），
    /// 展开逐条（callout/muted 正文 + mono 序号），左内缩 lg + 2pt `color.line` 竖线（TG-04）。
    /// 流式中收起态左侧脉冲（muted，Reduce Motion 静止）；触发 2/3 后定格加「（已停止更新）」。
    @ViewBuilder
    private func thinkingBlock(steps: [String], stalled: Bool) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            Button {
                withAnimation(reduceMotion ? nil : CovaMotion.fast) {
                    thinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: CovaSpace.xs) {
                    Text(thinkingExpanded ? "▾" : "▸")
                        .font(CovaType.subhead)
                        // §3.E 流式中收起态左侧一次性脉冲：busy && 未定格 ⇒ 呼吸；
                        // Reduce Motion 直接不给这一层（整段一次呈现口径同族）。
                        .opacity(!reduceMotion && busy && !stalled && !thinkingExpanded ? 0.35 : 1)
                        .animation(
                            busy && !stalled && !thinkingExpanded
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: busy
                        )
                    Text(
                        "深度思考 · \(steps.count) 步"
                            + (stalled ? "（已停止更新）" : "")
                    )
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "深度思考，\(steps.count) 步，\(thinkingExpanded ? "已展开" : "已收起")，按钮"
            )
            if thinkingExpanded {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(CovaColor.line)
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: CovaSpace.xs) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: CovaSpace.sm) {
                                Text("\(index + 1)")
                                    .font(CovaType.mono).foregroundStyle(CovaColor.muted)
                                Text(step)
                                    .font(CovaType.callout).foregroundStyle(CovaColor.muted)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("第 \(index + 1) 步，\(step)")
                        }
                    }
                    .padding(.leading, CovaSpace.lg)
                }
            }
        }
    }

    /// §3.F 运行状态行：符号 12pt 档 + caption/muted；内容**一律查 `RunLineCopy` 那张表**
    /// （spec 钉死它是本屏唯一允许的映射），表外事件名这一行不渲染。
    @ViewBuilder
    private func runLine(_ event: String) -> some View {
        if let spec = RunLineCopy.line(forEvent: event) {
            HStack(spacing: CovaSpace.xs) {
                Image(systemName: spec.symbol)
                    .font(CovaSymbol.statusSmall)
                    .foregroundStyle(runTint(spec.tint))
                Text(spec.label)
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
            .padding(.vertical, CovaSpace.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("运行状态，\(spec.label)")
        }
    }

    /// `RunLineCopy.Tint` → 具体色（意图枚举在这层才落到 token）。
    private func runTint(_ tint: RunLineCopy.Tint) -> Color {
        switch tint {
        case .muted: return CovaColor.muted
        case .warning: return CovaColor.warning
        case .success: return CovaColor.success
        case .error: return CovaColor.error
        }
    }

    /// §3.B 降级条（四触发同一容器、同一位置）：`accentSoft` 底 + `warning` 1pt 描边 +
    /// `radius.control` 内衬 + 慢旋 `arrow.triangle.2.circlepath`（Reduce Motion 静止）。
    /// 连败 ≥4 时文案换「自动刷新也拿不到」并出「重试」（§4.2 注）；AX 档允许 2 行（§7）。
    private func degradationBar(text: String, retry: Bool) -> some View {
        HStack(spacing: CovaSpace.sm) {
            SlowSpinSymbol()
            Text(text)
                .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                .lineLimit(axLayout ? 2 : 1)
            Spacer(minLength: CovaSpace.sm)
            if retry {
                Button("重试") { Task { await reconcileRound() } }
                    .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CovaSpace.md)
        .padding(.vertical, CovaSpace.md)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                .fill(CovaColor.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                .strokeBorder(CovaColor.warning, lineWidth: 1)
        )
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.top, CovaSpace.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连接状态，\(text)")
    }

    /// 降级条的慢旋符号（§4.2「慢旋」档；Reduce Motion 静止）。
    private struct SlowSpinSymbol: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var turning = false

        var body: some View {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(CovaType.subhead)
                .foregroundStyle(CovaColor.fg)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(
                        .linear(duration: 1.6).repeatForever(autoreverses: false)
                    ) { turning = true }
                }
                .accessibilityHidden(true)
        }
    }

    /// §4.1 空会话的一次性引导（`callout`/`secondary` + 3 枚 starter chips，08 §4 同源常量）。
    private var emptyGuide: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            Text("说一句你想要的歌：场景、情绪、时长")
                .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
            ForEach(StudioStarterChips.prompts, id: \.self) { chip in
                CovaTagChip(title: chip) {
                    Task { await submit(chip) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
    }
}

// MARK: - 行为 / 候选卡 / 计划卡（extension：与类型同一文件，private 互通）

extension AISessionDetailView {

    // MARK: 双 Demo（只渲染前两个候选，09 §3.H 大卡组）

    @ViewBuilder
    var candidateBlock: some View {
        // 「只取前两个」也归 `DoubleDemoRule` 管（§5 行 7：后端给 3+ 时界面只见 2）。
        let pair = DoubleDemoRule.pair(candidates)
        let terminal = DoubleDemoRule.isTerminal(pair)
        // §3.H：两张候选卡 + 底部终态条是**同一卡片框**（elevated + line + radius.card）。
        // AX 档横排 50/50 改纵向堆叠（§7），终态条仍居卡组底部。
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            Group {
                if axLayout {
                    VStack(spacing: CovaSpace.md) {
                        ForEach(pair.indices, id: \.self) { index in
                            candidateCard(pair[index], index: index, terminal: terminal)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: CovaSpace.sm) {
                        ForEach(pair.indices, id: \.self) { index in
                            candidateCard(pair[index], index: index, terminal: terminal)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(terminalText(pair))
                    .font(CovaType.subhead).foregroundStyle(terminalColor(pair))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 主行动钮只在**终态且至少有一版可挑**时出现（§5 行 4/5；行 6 两版全失败
                // 没得挑 ⇒ 不放一个点了没反应的钮）。档为 `CovaButton` primary ——
                // web v2.65.0 对齐批后是中性液态玻璃，不是品牌渐变（渐变只留 hero CTA）。
                if DoubleDemoRule.canChooseVersion(pair) {
                    CovaButton("选一版继续制作") { choosingVersion = true }
                        .fixedSize()
                        .accessibilityHint("选择后要挑一个版本")
                }
                // 21 面板的**第二个宿主**（会话路径，按 key 扣 co）。放在终态行而不是候选卡上：
                // 补充制作是"这一轮做完了再加工"，两版都还没收口时给它一个入口就是引导用户
                // 去花一笔还不该花的钱。
                if terminal {
                    Button("补充制作") { extrasShown = true }
                        .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("cova.session.extras")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CovaSpace.lg)
        .background(CovaColor.elevated)
        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .strokeBorder(CovaColor.line, lineWidth: 1)
        )
    }

    /// §3.H 单卡：1:1 封面方（TG-10）或像素呼吸占位 + 40pt 玻璃播放钮（仅 ready）+
    /// 标题（§10 截断表：恒 2 行）+ `type.mono` 时长 + 胶囊徽标 + 底部操作条。
    /// 候选数 <2 时外层 50% 槽位留空（只取前二、空位不渲染占位）。
    func candidateCard(
        _ candidate: GenerationCandidateDto, index: Int, terminal: Bool
    ) -> some View {
        let ready = DoubleDemoRule.isReady(candidate)
        let failed = DoubleDemoRule.isFailed(candidate)
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            candidateCover(candidate, ready: ready, failed: failed)
            Text(candidate.title ?? "版本 \(index + 1)")
                .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                .lineLimit(2)   // §10 截断表：候选卡标题恒 2 行（默认与 AX 同口径）
            HStack(spacing: CovaSpace.xs) {
                if let duration = TrackRowCopy.durationSegment(candidate.duration.map(Int.init)) {
                    Text(duration).font(CovaType.mono).foregroundStyle(CovaColor.muted)
                }
                candidateStatusCapsule(ready: ready, failed: failed)
                Spacer(minLength: 0)
            }
            candidateActionBar(candidate, index: index, ready: ready, terminal: terminal)
        }
        // error 遮罩（09 §5 / components §5）：盖整张候选卡，不吃点击（卡内控件自带命中）。
        .overlay { if failed { candidateErrorScrim } }
        // §7：每卡一个容器元素 —— 「版本 N，<标题>，<时长>，<状态>，试听 按钮」族。
        .accessibilityElement(children: .contain)
    }

    /// 封面区：ready → 真封面（无图落中性占位）+ 40pt 玻璃播放钮居中（视觉 40、热区 44）；
    /// pending → `CovaPixelCover` 像素呼吸占位；failed → 同 ready 的封面位，由卡级
    /// error 遮罩罩住，不摆播放图标（§5 行 3/5/6：失败卡面只有遮罩 + 「重试」）。
    /// 点封面 = 播放（ready）或对账（failed）；pending 封面不可点。
    @ViewBuilder
    func candidateCover(
        _ candidate: GenerationCandidateDto, ready: Bool, failed: Bool
    ) -> some View {
        let cover = ZStack {
            if !ready && !failed {
                CovaPixelCover()
            } else {
                CovaArtwork(
                    resolution: CovaArtworkResolution(serverValue: candidate.coverUrl),
                    title: candidate.title ?? "")
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.cover, style: .continuous))

        if ready {
            Button {
                guard let raw = candidate.audioUrl?.rawValue, let url = URL(string: raw),
                      let item = Self.playbackItem(for: candidate, url: url) else {
                    session.showToast("试听文件没取到，重试", isError: true)
                    return
                }
                Task { await session.play(items: [item], at: 0) }
            } label: {
                cover.overlay {
                    Image(systemName: "play.fill")
                        .font(CovaSymbol.control)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试听")
        } else if failed {
            Button { Task { await reconcileRound() } } label: { cover }
                .buttonStyle(.plain)
                .accessibilityLabel("重试这一版")
        } else {
            cover.accessibilityHidden(true)
        }
    }

    /// 候选卡状态徽标：与计划卡同一胶囊档（09 §3.G/H 共 §9 语义表）。
    func candidateStatusCapsule(ready: Bool, failed: Bool) -> some View {
        let text = failed ? Self.failedStatusText : (ready ? "可以试听" : "制作中")
        let color = failed ? CovaColor.error : (ready ? CovaColor.success : CovaColor.muted)
        return Text(text)
            .font(CovaType.caption)
            .foregroundStyle(color)
            .padding(.horizontal, CovaSpace.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(color == CovaColor.muted ? CovaColor.surface : color.opacity(0.15)))
    }

    /// 失败卡的状态文案。**不在这里再立一张中文表**：09 §9 行 11 的「未完成，可重试」
    /// 是本仓已有、语义正好对上的那一份（`PlanStatusCopy`，design 09 §9 权威表的实现）。
    static let failedStatusText = PlanStatusCopy.label(.retryableFailure)

    /// 失败卡的 error 遮罩。`color.errorSoft` 衬底档未入库（09 TG-21）⇒ 与 04 §2 的 scrim 同一处理。
    /// `.allowsHitTesting(false)`：遮罩是**表现层**，不许把整行的点击吞掉。
    var candidateErrorScrim: some View {
        RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
            .fill(CovaColor.error.opacity(Self.errorScrimOpacity))
            .allowsHitTesting(false)
    }

    /// TG-21（`errorSoft` 未入库）期间的占位强度。
    static let errorScrimOpacity: Double = 0.12

    /// 候选卡底部操作条（09 §3-H 列了三件：♡ 收藏 / ↓ 下载 / ⤴ 分享；§5 另要失败卡有「重试」）。
    ///
    /// · **↓ 下载** —— **不渲染**：D12 明令 v1.0 不开任何扣费入口。
    /// · **⤴ 分享** —— **不渲染，因为契约里没有任何可公开访问的候选页面**（NEEDS-24）。
    /// · **重试** —— 只挂在**失败**那一版上（§5 行 3/5/6），动作是只读对账。
    /// · **♡ 收藏** —— 「无 `mediaReferenceId` 时整钮不渲染」由 `canFavorite` 把关。
    @ViewBuilder
    func candidateActionBar(
        _ candidate: GenerationCandidateDto, index: Int, ready: Bool, terminal: Bool
    ) -> some View {
        let canFavorite = CandidateFavoriteLedger.canFavorite(candidate)
        let failed = DoubleDemoRule.isFailed(candidate)
        if canFavorite || failed || ready {
            HStack(spacing: CovaSpace.sm) {
                if canFavorite {
                    favoriteButton(candidate)
                }
                if failed {
                    retryControl()
                }
                versionChoice(candidate, index: index, ready: ready, terminal: terminal)
                Spacer(minLength: 0)
            }
        }
    }

    /// 失败卡上的「重试」（09 §5）：**只读对账** —— 契约没有"单候选重试"端点
    /// （§待裁决 4），走 `plans/start` 会撞幂等键语义（同三元组复用同键会被后端去重，
    /// 换新键则是为同一张卡再扣一次费）。这里做整轮重读，全程不出现扣费话术（D12）。
    @ViewBuilder
    func retryControl() -> some View {
        Button {
            Task { await reconcileRound() }
        } label: {
            HStack(spacing: CovaSpace.xs) {
                Image(systemName: reconciling ? "hourglass" : "arrow.clockwise")
                Text("重试")
            }
            .font(CovaType.callout)
            .foregroundStyle(CovaColor.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reconciling)
        .accessibilityLabel("重试这一版")
        .accessibilityHint("重新核对这一轮的制作结果，不会重新发起制作")
    }

    /// 「重试」的落地：一次**只读**的对账。与 `openSession()` 读同一批事实、用同一套播种
    /// 口径，但不进 `.loading`（整屏骨架会把已经在的对话流抽走）。`quietly` 给下拉刷新用：
    /// 原生菊花已经够说"在刷"，成功再叠一条 Toast 是噪音；失败仍说。
    func reconcileRound(quietly: Bool = false) async {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        do {
            let detail = try await session.studio.session(sessionID)
            let jobs = detail.generationJobs
            latestJob = jobs.last
            candidates = jobs.last?.candidates() ?? []
            workflow = detail.session?.decodedWorkflowState()
            sessionDto = detail.session
            if let title = detail.session?.displayTitle, title != "未命名会话" {
                sessionTitle = title
            }
            if let cards = try? await session.studio.planCards(sessionID: sessionID) {
                plans = cards
                plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
                // §10 并发冲突：对账读到别处前进的 revision ⇒ 一次性 caption 播报。
                notePlanRevisions(cards, announce: true)
            }
            favorites.reseed(from: candidates)
            choosingVersion = false
            syncStudioJobLedger()
            restartJobPoll()
            if degradation?.clearsOnReconcile == true { degradation = nil }
            if candidates.contains(where: { DoubleDemoRule.isFailed($0) }) {
                // §5 行 6 的引导，且只说这一句：不出现"扣费/退款"任何字样（D12）。
                session.showToast("这一版仍未完成，可以换一句话再来一次")
            } else if !quietly {
                session.showToast("已重新核对，这一轮的状态更新了")
            }
        } catch {
            // §4.1 离线：网络类读失败 + 手里还有缓存行 ⇒ B 位换离线条、J 发送禁用（`canSend`）。
            // 恢复靠下一次成功读数（`clearsOnReconcile`），条尾不放「重试」——下拉/发话就是重试。
            if StudioService.classify(error) == .network, !lines.isEmpty {
                degradation = .offline
            }
            session.showToast(
                "没读到最新状态：\(StudioService.classify(error).uiMessage)", isError: true
            )
        }
    }

    /// 「选这版继续制作」（§5 行 2/4/5）。**只对已就绪的那一版渲染** ——
    /// 占位卡与失败卡上没有可交付的音频。
    ///
    /// · 未到终态（`ready + pending`）：钮照 §5 摆着但**不放宽**，点击给规格那句
    ///   「两个版本都完成后可以继续」。刻意不用 `.disabled(true)` —— spec 要的是「点了要说原因」。
    /// · 已到终态但还没按主钮：不渲染；已按主钮：渲染主动作。
    @ViewBuilder
    func versionChoice(
        _ candidate: GenerationCandidateDto, index: Int, ready: Bool, terminal: Bool
    ) -> some View {
        if ready {
            if terminal, choosingVersion {
                Button("选这版继续制作") {
                    choosingVersion = false
                    Task { await chooseVersion(candidate, index: index) }
                }
                .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                .frame(minHeight: 44)
            } else if !terminal {
                Button("选这版继续制作") {
                    session.showToast("两个版本都完成后可以继续")
                }
                .font(CovaType.callout).foregroundStyle(CovaColor.muted)
                .frame(minHeight: 44)
            }
        }
    }

    func favoriteButton(_ candidate: GenerationCandidateDto) -> some View {
        let on = CandidateFavoriteLedger.isFavorite(candidate, in: favorites)
        return Button {
            Task { await toggleFavorite(candidate) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(CovaSymbol.controlPlain)
                .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏")
    }

    /// ♡ 的一次往返：乐观翻转 → 真发 `PATCH …/retention` → 失败**回落到服务端事实并说出来**。
    func toggleFavorite(_ candidate: GenerationCandidateDto) async {
        guard let intent = favorites.beginToggle(candidate) else { return }
        do {
            let response = try await session.studio.setCandidateFavorite(
                referenceID: intent.referenceID, intent.target
            )
            favorites.confirm(
                referenceID: intent.referenceID, sent: intent.target, echoed: response.favorite
            )
        } catch {
            favorites.reject(referenceID: intent.referenceID)
            session.showToast("收藏没保存上，再试一次", isError: true)
        }
    }

    /// 私有音频走 D7 硬顺序：交给 `PrivateAudioFetcher` 先 Bearer 下载 → 校验非空 → `file://`。
    static func playbackItem(
        for candidate: GenerationCandidateDto, url: URL
    ) -> PlaybackItem? {
        guard let audio = try? AudioURL(https: url) else { return nil }
        return try? PlaybackItem(
            id: candidate.mediaReferenceId ?? candidate.id,
            title: candidate.title ?? "生成候选",
            artist: "Cova AI",
            album: nil,
            duration: candidate.duration,
            coverURL: CovaEnvironment.resolveMediaURL(candidate.coverUrl)
                .flatMap { try? AudioURL(https: $0) },
            audioSource: .bearerRequired(audio),
            kind: .privateCandidate
        )
    }

    /// 终态文案（design 09 §H 的六句固定串）。
    func terminalText(_ pair: [GenerationCandidateDto]) -> String {
        guard pair.count == 2 else { return "两个版本制作中" }
        let readyCount = DoubleDemoRule.readyCount(pair)
        let failedCount = DoubleDemoRule.failedCount(pair)
        if readyCount == 2 { return "两个版本都好了，挑一版继续" }
        if failedCount == 2 { return "两个版本都没能完成" }
        if failedCount == 1, readyCount == 1 { return "一版完成，另一版失败" }
        if readyCount == 1 { return "就绪 1/2 · 等另一个版本完成" }
        if failedCount == 1 { return "1/2 遇到问题 · 等另一个版本完成" }
        return "两个版本制作中"
    }

    /// 终态条字色：§5 六行表的色列（muted/warning/success/error）。
    func terminalColor(_ pair: [GenerationCandidateDto]) -> Color {
        guard pair.count == 2 else { return CovaColor.muted }
        let readyCount = DoubleDemoRule.readyCount(pair)
        let failedCount = DoubleDemoRule.failedCount(pair)
        if readyCount == 2 { return CovaColor.success }
        if failedCount == 2 { return CovaColor.error }
        if failedCount == 1 || readyCount == 1 { return CovaColor.warning }
        return CovaColor.muted
    }

    /// 「选这版继续制作」的落地方式 = **把选择当成一句话发给 agent**，不是发明字段。
    private func reconcileStartedJob(sessionID: String, planCardID: String, revision: Int) async {
        guard let detail = try? await session.studio.session(sessionID) else {
            degradation = .custom("任务号没读到，稍后下拉核对会话")
            return
        }
        let jobs = detail.generationJobs
        if let newest = jobs.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) {
            startTokens.invalidate(sessionID: sessionID, planCardID: planCardID, revision: revision)
            latestJob = newest
            candidates = newest.candidates()
            degradation = nil
            append(.system("已核到任务：\(newest.status.userLabel)"))
            restartJobPoll()
        } else {
            degradation = .custom("会话里还没有任务，稍后再下拉核对")
        }
    }

    func chooseVersion(_ candidate: GenerationCandidateDto, index: Int) async {
        let title = candidate.title.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名版本"
        await submit("就选版本 \(index + 1)（\(title)）继续制作，按这一版补齐完整音频。")
    }

    // MARK: I 补充制作进度条（09 §3-I / §9 行 8–9）

    /// 本轮**最新那张计划卡**：`cardIndex` 最大者，同值取数组里靠后的。
    var latestPlan: OneStepPlanCardDto? {
        plans.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            return (candidate.cardIndex ?? 0) >= (current.cardIndex ?? 0) ? candidate : current
        }
    }

    /// 出现条件与格数全部由 CovaCore 的纯映射决定，本屏只负责画。
    var deliveryProgress: DeliveryProgress? {
        guard let plan = latestPlan else { return nil }
        return DeliveryProgressPlanner.progress(
            planStatus: plan.status, jobStatus: latestJob?.status, workflow: workflow
        )
    }

    /// 08 §3.C 那一格环的**唯一来源**：本设备内存里这一路的未终态 job。
    func syncStudioJobLedger() {
        if roundIsSettled {
            let watchedInFlight = session.liveStudioJobs.studioHasLiveJob(sessionID)
            let terminalJob = latestJob
            let terminalPlanCardID = latestPlan?.planCardId
            let terminalOwner = session.meUser?.id
            session.settleStudioJob(sessionID: sessionID)
            Task {
                await StudioNotifier.reconcileTerminal(
                    job: terminalJob,
                    sessionID: sessionID,
                    planCardID: terminalPlanCardID,
                    owner: terminalOwner,
                    watchedInFlight: watchedInFlight
                )
            }
            return
        }
        session.updateStudioJobProgress(
            sessionID: sessionID, progress: deliveryProgress?.fraction
        )
    }

    /// 终态只用本屏**已有**的两把尺子判：`DoubleDemoRule` 与 job 自身的终态词表。
    /// `busy`（本机正在读这一轮的流）时**一律算未收口**。
    var roundIsSettled: Bool {
        if busy { return false }
        if DoubleDemoRule.isTerminal(DoubleDemoRule.pair(candidates)) { return true }
        return latestJob.map { $0.status.isTerminal } ?? false
    }

    // MARK: 任务轮询（09 §8 / DEVELOPMENT.md §5 P1-5）

    func restartJobPoll() {
        restartJobPoll(jobID: latestJob?.id, tracked: latestJob?.status)
    }

    func restartJobPoll(jobID: String?, tracked: GenerationJobStatus?) {
        stopJobPoll()
        guard SessionJobPollReconcile.canArm(
            jobID: jobID, status: tracked, streamMidRound: busy
        ), let jobID else { return }
        let token = jobPollToken
        jobPollTask = Task { await runJobPoll(jobID: jobID, tracked: tracked, token: token) }
    }

    func stopJobPoll() {
        jobPollToken += 1
        jobPollTask?.cancel()
        jobPollTask = nil
    }

    // MARK: 断流之后的运行恢复轮询（§5 P1-5 后半 / §7 #52）

    func restartRunPoll() {
        stopRunPoll()
        guard AgentRunRecovery.shouldPoll(
            runID: agentRunID, streamOwnsRound: busy, lastTerminality: .unknown
        ), let runID = agentRunID else { return }
        let token = runPollToken
        runPollTask = Task { await runRunPoll(runID: runID, token: token) }
    }

    func stopRunPoll() {
        runPollToken += 1
        runPollTask?.cancel()
        runPollTask = nil
    }

    /// 循环本体。`run.status` 在屏上对应的格子是 §3.F 那张表：`RunLineCopy.event(forStatus:)`
    /// 把运行态名落到等价的事件名上，再共用同一行渲染（与 SSE 事件同一张文案表）。
    func runRunPoll(runID: String, token: Int) async {
        let schedule = StudioCreatePollSchedule()
        var attempt = 1
        while schedule.shouldPoll(attempt: attempt), !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(schedule.interval(forAttempt: attempt) * 1_000_000_000)
            )
            guard token == runPollToken, !Task.isCancelled, !busy else { return }
            let snapshot = try? await session.agentRunService.snapshot(runID: runID)
            guard token == runPollToken, !Task.isCancelled else { return }
            guard let run = snapshot?.run else {
                attempt += 1
                continue
            }
            if let observed = run.id, observed != runID { return }
            if let status = run.status, let event = RunLineCopy.event(forStatus: status) {
                appendOrReplaceRun(event)
                if RunLineCopy.fadesOut(forEvent: event) { scheduleRunLineFade() }
            }
            switch AgentRunRecovery.terminalVocabulary.terminality(of: run.status) {
            case .success, .failure: return
            case .running, .unknown: break
            }
            attempt += 1
        }
    }

    /// 循环本体。**这里没有任何判据**：什么时候写、写哪几个面、什么时候停，
    /// 一律问 `SessionJobPollReconcile.decide`，本方法只执行赋值。
    func runJobPoll(jobID: String, tracked: GenerationJobStatus?, token: Int) async {
        let schedule = StudioCreatePollSchedule()
        var previous = tracked
        var attempt = 1
        while !Task.isCancelled {
            let gate = SessionJobPollReconcile.decide(
                previous: previous, observation: .nothingRead,
                streamMidRound: busy, attempt: attempt, schedule: schedule
            )
            if gate.stops {
                if gate.reason == .capReached {
                    // §10 长任务：约 30min 仍非终态 ⇒ B 位（同一容器）显那句固定文案，
                    // 并按 18 兜底调度本地通知（未索权时静默跳过——spec 只许在
                    // 「开始制作」成功后索权一次，这里**不**再索）。
                    degradation = .longTask
                    Task {
                        if await StudioNotifier.authorization() == .allowed {
                            await StudioNotifier.scheduleFallback(
                                sessionID: sessionID,
                                jobID: jobID,
                                planCardID: latestPlan?.planCardId,
                                afterMinutes: 30
                            )
                        }
                    }
                }
                return
            }
            try? await Task.sleep(
                nanoseconds: UInt64(schedule.interval(forAttempt: attempt) * 1_000_000_000)
            )
            guard token == jobPollToken, !Task.isCancelled else { return }
            let polled = try? await session.studioCreateService.generationJob(id: jobID)
            guard token == jobPollToken, !Task.isCancelled else { return }
            let job = polled?.job
            let decision = SessionJobPollReconcile.decide(
                previous: previous,
                observation: SessionJobPollReconcile.Observation(job: job),
                streamMidRound: busy,
                attempt: attempt,
                schedule: schedule
            )
            applyJobPoll(decision, polled: job)
            if decision.stops { return }
            previous = job?.status ?? previous
            attempt += 1
        }
    }

    /// 执行一次判决：五个开关各自落到屏上那一个赋值点，本方法不自己加判据。
    func applyJobPoll(
        _ decision: SessionJobPollReconcile.Decision, polled job: GenerationJobDto?
    ) {
        if decision.writesJob, let job {
            latestJob = job
        }
        if decision.writesCandidates, let job {
            let fresh = job.candidates()
            if fresh != candidates {
                candidates = fresh
                favorites.reseed(from: fresh)
                choosingVersion = false
            }
        }
        if decision.settles { syncStudioJobLedger() }
    }

    /// §3-I 的形态：左文案（`type.subhead` / `color.secondary`）+ 右列（`type.mono` / `color.muted`）
    /// + 4pt 细轨道（`color.line`）配 `color.accent` 填充。
    func deliveryProgressBar(_ progress: DeliveryProgress) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.label)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                Spacer(minLength: CovaSpace.sm)
                Text(progress.rightColumnText)
                    .font(CovaType.mono).foregroundStyle(CovaColor.muted)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CovaColor.line)
                    Capsule()
                        .fill(CovaColor.accent)
                        .frame(width: proxy.size.width * CGFloat(progress.fraction))
                }
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.voiceOverLabel)
    }

    // MARK: §10 计划卡折疊（>5 张：最新一张默认展开，其余收为摘要行）

    @ViewBuilder
    var planCardsBlock: some View {
        let collapse = plans.count > Self.planCollapseThreshold
        ForEach(plans, id: \.planCardId) { plan in
            if collapse && plan.planCardId != latestPlan?.planCardId
                && !expandedPlanIDs.contains(plan.planCardId) {
                planSummaryRow(plan)
            } else {
                PlanCardView(
                    plan: plan,
                    sessionID: sessionID,
                    canStart: canStart(plan),
                    startBusy: startInFlight,
                    errorMessage: latestJob?.errorMessage,
                    creditsBalance: creditsBalance,
                    onStart: { Task { await start(plan) } },
                    onRevise: {
                        draft = "请修改："
                        composerFocused = true
                    },
                    onFocusComposer: { composerFocused = true },
                    onUpdated: { applyPlanUpdate($0) },
                    onBalanceOutOfDate: { Task { await refreshBalance() } }
                )
            }
        }
    }

    /// 折叠档摘要行（§10：标题 + 状态徽标，点开还原整卡）。
    func planSummaryRow(_ plan: OneStepPlanCardDto) -> some View {
        Button {
            expandedPlanIDs.insert(plan.planCardId)
        } label: {
            HStack(spacing: CovaSpace.sm) {
                Text(plan.title?.selected ?? plan.summary ?? "制作计划")
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .lineLimit(1)
                Spacer(minLength: CovaSpace.sm)
                planStatusCapsule(plan.status)
            }
            .padding(.horizontal, CovaSpace.lg)
            .frame(minHeight: 44)
            .background(CovaColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .strokeBorder(CovaColor.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("展开这张计划卡")
    }

    // MARK: 输入框（09 §3.J：与 01 §2 同族 —— 玻璃卡 + 模式 chips + 深度思考 + 40 圆钮）

    /// 「找歌/做歌」沿用 01 的会话内记忆（`session.homeComposerMode`，spec J「默认沿用上轮选择」）。
    /// ⚠️ 契约注：agent 请求体**没有** mode 字段（`StudioService.agentRequestBody` 只有
    /// sessionId/message/deepThinking）⇒ 这两枚 chip 只记意图 + 换占位语，
    /// **不**改提交语义（发送一律进 `submit`），也不发明 `mode` 键进请求体。
    var composer: some View {
        VStack(spacing: 0) {
            // §3.J：输入卡上沿 1px `color.lineSubtle` 分隔（TG-04）。
            Rectangle().fill(CovaColor.lineSubtle).frame(height: 1)
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                // §4.2 触发 1 的消息区附加表现：等待行出现在 composer 上方（不是降级条）。
                if degradation == .waiting {
                    Text("仍在处理刚才那句")
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                }
                HStack(spacing: CovaSpace.sm) {
                    CovaChip("找歌", isSelected: session.homeComposerMode == .search) {
                        session.homeComposerMode = .search
                    }
                    CovaChip("做歌", isSelected: session.homeComposerMode == .generate) {
                        session.homeComposerMode = .generate
                    }
                    if session.homeComposerMode == .generate {
                        CovaChip("深度思考", isSelected: deepThinking) { deepThinking.toggle() }
                    }
                    Spacer(minLength: 0)
                    if busy {
                        Button("停止生成") {
                            Task {
                                await session.cancelStudioStream()
                                session.settleStudioJob(sessionID: sessionID)
                            }
                        }
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
                HStack(spacing: CovaSpace.sm) {
                    TextField(composerPlaceholder, text: $draft, axis: .vertical)
                        .font(CovaType.body).foregroundStyle(CovaColor.fg)
                        .lineLimit(1...3)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onSubmit { Task { await send() } }
                    composerSendButton
                }
                .frame(minHeight: ShellMetrics.touchMin)
            }
            .padding(.horizontal, CovaSpace.md)
            .padding(.vertical, CovaSpace.sm)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .strokeBorder(CovaColor.line.opacity(0.6), lineWidth: 0.5)
            )
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.sm)
        }
    }

    /// 占位语只换说法、不改语义（见上面的契约注）。
    var composerPlaceholder: String {
        session.homeComposerMode == .search ? "想找哪首歌？说场景或歌名" : "继续说你的想法…"
    }

    /// §4.1 离线那一格的 J 发送禁用：离线横幅在 ⇒ 不允发送（其余降级态不拦，§4.2 由
    /// `busy`/停止钮承担）。
    var canSend: Bool {
        !busy && degradation != .offline
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发送钮 40 圆：`gradient.brandButton` + 白 ↑ + `primaryButtonShadow`；
    /// busy/空文 → `color.muted` 底禁用（§3.J「流式进行中发送钮禁用」）。
    var composerSendButton: some View {
        Button { Task { await send() } } label: {
            Image(systemName: busy ? "hourglass" : "arrow.up")
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
        .opacity(canSend ? 1 : 0.9)
        .accessibilityLabel("发送")
    }

    // MARK: 行为

    func openSession() async {
        phase = .loading
        do {
            async let detail = session.studio.session(sessionID)
            async let cards = session.studio.planCards(sessionID: sessionID)
            let result = try await detail
            let planList = ((try? await cards) ?? nil) ?? plans
            sessionDto = result.session
            // §3.A：会话名来自后端；`displayTitle` 的"未命名会话"回落链尾意味着"没有可用名"
            // ⇒ 本屏那一句回落用 §3.A 点名的「创作会话」，不把占位当名字挂上导航条。
            if let title = result.session?.displayTitle, title != "未命名会话" {
                sessionTitle = title
            } else {
                sessionTitle = "创作会话"
            }
            lineCounter = 0
            lines = result.messages.compactMap { message in
                guard let text = message.displayText else { return nil }
                lineCounter += 1
                return TranscriptLine(
                    id: lineCounter,
                    kind: message.isFromUser ? .user(text) : .agentText(text)
                )
            }
            // §10 窗口化：超窗口只留最近 `historyPage` 条 + 顶部「加载更早消息」。
            historyHidden = lines.count > Self.historyWindow
                ? lines.count - Self.historyPage
                : 0
            plans = planList
            plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
            let jobs = result.generationJobs
            latestJob = jobs.last
            candidates = jobs.last?.candidates() ?? []
            workflow = result.session?.decodedWorkflowState()
            favorites.reseed(from: candidates)
            choosingVersion = false
            // 「计划已在别处更新」账：进屏这份是**基准**，只播种不播报（一次性 caption
            // 归后续对账读到的 revision 前进所有）。
            knownRevisions = [:]
            notePlanRevisions(plans, announce: false)
            elsewhereNoticeShown = false
            expandedPlanIDs = []
            pendingReplyNotice = false
            await refreshBalance()
            phase = .ready
            syncStudioJobLedger()
            restartJobPoll()
            // 首页输入卡带过来的一句话：进屏后自动发一次。
            if let pending = session.pendingPrompt {
                session.pendingPrompt = nil
                deepThinking = session.pendingDeepThinking
                draft = pending
                await send()
            }
        } catch {
            phase = .failed(StudioService.classify(error))
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // §8 并发/§4.1 离线：发送禁用是行为约束，不只是按钮态——TextField 的
        // onSubmit 不走 `canSend`，闸必须落在这条必经腿上。
        guard !text.isEmpty, !busy, degradation != .offline else { return }
        draft = ""
        await submit(text)
    }

    /// 把**一句话**送进 agent 并消费回流帧。输入框那句话与「选这版继续制作」走同一条腿。
    /// 入口有三处（send/starter chips/选版继续），闸落在这层而不是 `canSend` 按钮态上：
    /// 流式中二次触发被吞（§8「发送禁用」是行为约束）；离线档同样吞（§4.1）。
    func submit(_ text: String) async {
        guard !busy, degradation != .offline else { return }
        busy = true
        defer {
            busy = false
            stopDegradationWatch()
        }
        stopJobPoll()
        stopRunPoll()
        append(.user(text))
        agentBuffer = ""
        agentLineID = nil
        thinkingLineID = nil
        thinkingExpanded = false
        do {
            let body = try StudioService.agentRequestBody(
                sessionID: sessionID, message: text, deepThinking: deepThinking
            )
            let request = try CovaSSERequests.agent(jsonBody: body)
            let stream = try await session.beginStudioStream(sessionID: sessionID, request: request)
            for try await frame in stream {
                await consume(frame)
                await refreshDegradation()
                if Task.isCancelled { break }
            }
        } catch {
            // 开不了流：降级条照状态机说真话；拿不到状态机 ⇒ 行内错句。
            let state = await session.studioStreamState()
            if state.phase == .polling {
                degradation = .pollFailing
            } else {
                append(.systemError("这次没有成功：\(StudioService.classify(error).uiMessage)"))
            }
        }
        await refreshDegradation()
        // 流的生命周期结束后：持久档（长任务/局部提示）留着，流族文案收掉。
        if let variant = degradation, !variant.persistsBeyondStream {
            degradation = nil
        }
        pollFailures = 0
        busy = false
        restartJobPoll()
        restartRunPoll()
    }

    /// 降级条的文案**由状态机的事实决定**（09 §B）：阶段 + 触发原因，不靠猜。
    /// 轮询阶段起一条节拍腿定时重读——轮询失败**不产生帧**，没人叫它这条函数就一直停在旧读数。
    func refreshDegradation() async {
        let state = await session.studioStreamState()
        pollFailures = state.pollFailures
        guard state.phase == .polling, let trigger = state.trigger else {
            if state.phase == .streaming || state.phase == nil,
               let variant = degradation, !variant.persistsBeyondStream {
                degradation = nil
            }
            if state.phase != .polling { stopDegradationWatch() }
            return
        }
        let variant: DegradeVariant
        switch trigger {
        case .firstEventTimeout: variant = .waiting
        case .silenceTimeout: variant = .interrupted
        case .malformedEvents: variant = .unstable
        case .eofBeforeDone: variant = .resuming
        }
        degradation = pollFailures >= 4 ? .pollFailing : variant
        // §4.2 触发 2/3：thinking 折叠块定格并追加「（已停止更新）」。
        if variant == .interrupted || variant == .unstable { stallThinking() }
        startDegradationWatch()
    }

    /// 轮询期的节拍腿：每 2s 重读一次状态机事实（失败计数自己不长出帧来）。
    func startDegradationWatch() {
        guard degradationWatch == nil else { return }
        degradationWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshDegradation()
            }
        }
    }

    func stopDegradationWatch() {
        degradationWatch?.cancel()
        degradationWatch = nil
    }

    /// §4.2 触发 2/3 的定格标记：本轮 thinking 块置 `stalled`（收起行追加「（已停止更新）」）。
    func stallThinking() {
        guard let id = thinkingLineID,
              let index = lines.firstIndex(where: { $0.id == id }),
              case .thinking(let steps, false) = lines[index].kind else { return }
        lines[index] = TranscriptLine(id: id, kind: .thinking(steps: steps, stalled: true))
    }

    func consume(_ frame: CovaSSEFrame) async {
        switch frame.event {
        case .text:
            if let chunk = Self.decodeText(frame.payload) {
                agentBuffer += chunk
                replaceLatestAgentText(agentBuffer)
            }
        case .thinking:
            // §3.E：载荷 `{text}` → `OneStepThinkingCopy` 裁决成公开短语（内部词到不了这一层），
            // 逐条进折叠块（展开态逐条可读；收起行只报步数）。
            let step = OneStepThinkingCopy.publicPhrase(Self.decodeText(frame.payload))
            appendOrUpdateThinking(step: step)
        case .planCard:
            if let cards = Self.decodeCards(frame.payload) {
                plans = cards
                plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
                // 本轮流自己推的卡只播种不播报（§10 的"别处更新"归对账路径）。
                notePlanRevisions(cards, announce: false)
                syncStudioJobLedger()
            }
        case .error:
            append(.systemError("这一步暂时卡住了，可以重新描述需求再来一次"))
        case .done:
            degradation = nil
        case .runLifecycle(let name):
            if let id = AgentRunRecovery.runID(from: frame) { agentRunID = id }
            // 只保留**唯一一条** run 行；未知 run_* 不显示、也不算坏事件。
            if RunLineCopy.line(forEvent: name) != nil {
                appendOrReplaceRun(name)
                if RunLineCopy.fadesOut(forEvent: name) { scheduleRunLineFade() }
            }
        case .unknown:
            break
        }
    }

    static func decodeText(_ payload: Data) -> String? {
        (try? JSONDecoder().decode(CovaSSETextEventDto.self, from: payload))?.text
    }

    static func decodeCards(_ payload: Data) -> [OneStepPlanCardDto]? {
        if let envelope = try? JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: payload) {
            return envelope.planCards
        }
        if let single = try? JSONDecoder().decode(OneStepPlanCardDto.self, from: payload) {
            return [single]
        }
        return try? JSONDecoder().decode([OneStepPlanCardDto].self, from: payload)
    }

    func canStart(_ plan: OneStepPlanCardDto) -> Bool {
        PlanStatusCopy.canStart(plan.status)
            && plan.snapshotHash != nil
            && plan.sourceMessage?.messageId != nil
    }

    /// 歌词保存/重做之后，**后端回显的那一张卡**就是那张卡的最新事实 ⇒ 只换那一张。
    func applyPlanUpdate(_ updated: OneStepPlanCardDto) {
        if let index = plans.firstIndex(where: { $0.planCardId == updated.planCardId }) {
            plans[index] = updated
            return
        }
        plans.append(updated)
        plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
    }

    /// §10 并发冲突裁决：每张卡登记已播种的 `revision`；`announce` 档读到**前进**时
    /// 放一次性 caption「计划已在别处更新」（进屏/流推/本地写回显一律 `announce:false` —
    /// 那些是本屏自己拿到的演进，不是"别处"）。
    func notePlanRevisions(_ cards: [OneStepPlanCardDto], announce: Bool) {
        var advanced = false
        for card in cards {
            guard let revision = card.revision else { continue }
            if let known = knownRevisions[card.planCardId] {
                if revision > known {
                    advanced = advanced || announce
                    knownRevisions[card.planCardId] = revision
                }
            } else {
                knownRevisions[card.planCardId] = revision
            }
        }
        if advanced && !elsewhereNoticeShown {
            elsewhereNoticeShown = true
            append(.system("计划已在别处更新"))
        }
    }

    /// 余额位重读（写操作可能改账，09 §8「启动成功后强制刷新」同一口径）。
    func refreshBalance() async {
        creditsBalance = try? await session.catalog.me().entitlements.creditsBalance
    }

    /// 「开始制作」/「重新制作」。**全局单在途**（§10：多张 `ready` 卡并发点，
    /// 后到者按钮 loading 且被吞——`startInFlight` 就是那把闸）。
    /// `retryable_failure` 是新逻辑操作 ⇒ 同三元组的幂等键先作废换新（§9 行 11）。
    func start(_ plan: OneStepPlanCardDto) async {
        guard !startInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        if plan.status == .retryableFailure {
            startTokens.invalidate(
                sessionID: sessionID, planCardID: plan.planCardId, revision: plan.revision ?? 0
            )
        }
        do {
            let response = try await session.studio.startPlan(
                sessionID: sessionID, plan: plan,
                token: startTokens.token(
                    sessionID: sessionID, planCardID: plan.planCardId, revision: plan.revision ?? 0
                )
            )
            // **2xx 但没拿到任务号**：扣费可能已经发生，绝不能说"没提交成功"——
            // 去核对权威任务列表（幂等键复用同键，重试不会产生第二次扣费）。
            guard let jobID = response.resolvedJobId else {
                append(.system("任务已提交，但没拿到任务编号，正在核对……"))
                await reconcileStartedJob(
                    sessionID: sessionID, planCardID: plan.planCardId, revision: plan.revision ?? 0
                )
                return
            }
            append(.system("已提交，正在排产"))
            session.markStudioJobLive(sessionID: sessionID, progress: nil)
            restartJobPoll(jobID: jobID, tracked: nil)
            if await StudioNotifier.requestPermissionAfterPlanStart() {
                await StudioNotifier.scheduleFallback(
                    sessionID: sessionID,
                    jobID: jobID,
                    planCardID: plan.planCardId,
                    afterMinutes: 30
                )
            }
            if let cards = try? await session.studio.planCards(sessionID: sessionID) {
                plans = cards
                plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
                notePlanRevisions(cards, announce: false)
            }
        } catch {
            append(.systemError("这次没提交成功：\(StudioService.classify(error).uiMessage)"))
        }
    }

    // MARK: 行内小工具（每轮一条 agent 正文 / 一条 thinking / 一条 run）

    @discardableResult
    func append(_ kind: TranscriptLine.Kind) -> Int {
        lineCounter += 1
        lines.append(TranscriptLine(id: lineCounter, kind: kind))
        return lineCounter
    }

    func replaceLatestAgentText(_ text: String) {
        if let id = agentLineID, let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index] = TranscriptLine(id: id, kind: .agentText(text))
        } else {
            agentLineID = append(.agentText(text))
        }
    }

    /// §3.E：新一轮的第一条 thinking 帧新建一行，之后逐条追加进同一行。
    func appendOrUpdateThinking(step: String) {
        if let id = thinkingLineID,
           let index = lines.firstIndex(where: { $0.id == id }),
           case .thinking(let steps, let stalled) = lines[index].kind {
            lines[index] = TranscriptLine(
                id: id, kind: .thinking(steps: steps + [step], stalled: stalled)
            )
        } else {
            thinkingLineID = append(.thinking(steps: [step], stalled: false))
        }
    }

    /// §3.F「只保留最后一条」：本轮的 run 行就这一个 id，新事件整行替换。
    func appendOrReplaceRun(_ event: String) {
        runFadeToken += 1
        if let id = runLineID, let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index] = TranscriptLine(id: id, kind: .run(event: event))
        } else {
            runLineID = append(.run(event: event))
        }
    }

    /// §3.F：`run_completed` 的那一行 3s 后淡出（token 守卫：期间被新事件顶替就作废）。
    func scheduleRunLineFade() {
        let token = runFadeToken
        let id = runLineID
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, runFadeToken == token else { return }
            lines.removeAll { $0.id == id }
        }
    }

    static func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .unauthenticated: return .unauthenticated
        case .backendGap(let id): return .backendGap(id)
        }
    }
}

// MARK: - 09 §3.G 计划卡徽标（卡面与 §10 折叠摘要行共用同一枚胶囊）

/// §3.G 状态徽标：胶囊档（caption 字 + 横向 `spacing.sm`；semantic 色字 + 同义 15% 衬底
/// [TG-27：soft 系衬底未入库，与 B 条/error 遮罩同一过渡配方]；muted 字 + `surface` 底）。
func planStatusCapsule(_ status: OneStepPlanStatus) -> some View {
    let color = planStatusColor(status)
    return Text(PlanStatusCopy.label(status))
        .font(CovaType.caption)
        .foregroundStyle(color)
        .padding(.horizontal, CovaSpace.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(color == CovaColor.muted ? CovaColor.surface : color.opacity(0.15)))
}

/// §9 徽标色列：success=demosReady；error=manualRecovery/retryableFailure；
/// warning=ready/starting/generating/mediaStaging/deliveryPreparing/rehydrating；
/// muted=analyzing/patching/archived。
func planStatusColor(_ status: OneStepPlanStatus) -> Color {
    switch status {
    case .demosReady: return CovaColor.success
    case .manualRecovery, .retryableFailure: return CovaColor.error
    case .ready, .starting, .generating, .mediaStaging, .deliveryPreparing, .rehydrating:
        return CovaColor.warning
    case .analyzing, .patching, .archived:
        return CovaColor.muted
    }
}

/// 计划卡（design 09 §3.G + §9 十二态 × UI 映射）。缺 `snapshotHash` / 归因 ⇒ 主按钮置灰，**不放宽**。
struct PlanCardView: View {
    let plan: OneStepPlanCardDto
    let sessionID: String
    /// §9「开始制作」列 + 归属/snapshotHash 的合取（父层 `canStart(_:)` 已算完）。
    let canStart: Bool
    /// §10 并发：start 全局单在途 —— 在途时本卡主钮呈"已提交"形（后到者 loading 且被吞）。
    let startBusy: Bool
    /// §10 零余额：`retryable_failure` 且 `job.errorMessage` 命中余额类 ⇒ 费用行整行 error。
    let errorMessage: String?
    let creditsBalance: Int?
    let onStart: () -> Void
    let onRevise: () -> Void
    /// §9 行 10 manualRecovery 的「聚焦 J」引导钮 —— 只聚焦，不预填（预填归 `onRevise`）。
    let onFocusComposer: () -> Void
    /// 歌词编辑/重做拿到后端回显的那一张卡时，交回父层替换（**不在本卡里自存一份卡面**）。
    let onUpdated: (OneStepPlanCardDto) -> Void
    /// 重做可能改余额账 ⇒ 请父层重读一次（本屏不自己猜扣了多少）。
    let onBalanceOutOfDate: () -> Void
    @Environment(\.covaAXLayout) private var axLayout
    @State private var promptExpanded = false
    /// §10：analysisZh 收起 4 行 + 「展开」。
    @State private var analysisExpanded = false

    /// §9 行 4 `starting` 的主钮位：菊花 + 「已提交，正在排产」。
    /// `startBusy`（本屏 start 在途）并入同一形态——它在等的就是一次 starting 回显。
    private var startingLike: Bool { plan.status == .starting || (canStart && startBusy) }

    /// §10 零余额判词：retryable_failure + 余额类 errorMessage 才命中（词表在 CovaCore）。
    private var balanceRefused: Bool {
        plan.status == .retryableFailure && OneStepPlanFailureCopy.isBalanceRefusal(errorMessage)
    }

    var body: some View {
        // §3.G：elevated 底 + 1pt line 边 + radius.card + 顶部 2pt gradient.ai 装饰条，
        // 独立容器，不用通用 CovaCard。§9 行 12：archived 换 `surface` 底 + 整卡 50% 透明。
        VStack(spacing: 0) {
            Rectangle()
                .fill(CovaGradient.ai)
                .frame(height: 2)
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                HStack(alignment: .top) {
                    // §3.G 契约注：`title` 只有 `selected` 一个键 ⇒ 只上屏选中项。
                    // §10 截断表：选中项 2 行。
                    Text(plan.title?.selected ?? plan.summary ?? "制作计划")
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                        .lineLimit(2)
                    Spacer()
                    planStatusCapsule(plan.status)
                }
                stateNotices
                if plan.status == .analyzing {
                    analyzingSkeleton
                } else {
                    contentBlock
                }
            }
            .padding(CovaSpace.lg)
        }
        .background(plan.status == .archived ? CovaColor.surface : CovaColor.elevated)
        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                .strokeBorder(CovaColor.line, lineWidth: 1)
        )
        .opacity(plan.status == .archived ? 0.5 : 1)   // TG-26：只读置灰 50% 档
    }

    /// §9 各态卡顶/行内提示（patching 的「正在按你的批注修改」、manualRecovery 的 error 条、
    /// 零余额的行内判词）——都在固定文案清单内，不是 error 态滥用。
    @ViewBuilder
    private var stateNotices: some View {
        if plan.status == .patching {
            Text("正在按你的批注修改")
                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
        }
        if plan.status == .manualRecovery {
            Text("这一步暂时卡住了，可以重新描述需求再来一次")
                .font(CovaType.caption).foregroundStyle(CovaColor.error)
            Button("重新描述需求", action: onFocusComposer)
                .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                .frame(minHeight: 44)
        }
        if balanceRefused {
            // §10：费用行整行转 error + 固定文案；禁止任何充值/购买话术（D12）。
            Text(OneStepPlanFailureCopy.balanceRefusalNotice)
                .font(CovaType.caption).foregroundStyle(CovaColor.error)
        }
    }

    /// §9 行 1 `analyzing`：标题/分析/歌词位 `surface` 骨架条，**无费用行**。
    /// 修订钮按 §9 第四列仍然可用（在 `actionRow` 里，骨架只替内容位）。
    private var analyzingSkeleton: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            SessionSkeletonBar(width: 200, height: 16)
            SessionSkeletonBar(width: .infinity, height: 44)
            SessionSkeletonBar(width: 240, height: 40)
            actionRow
        }
    }

    /// `ready` 等常态卡的完整内容（分析 / promptEn 折叠 / 歌词区 / 参数行 / 费用行 / 操作行）。
    private var contentBlock: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            if let analysis = plan.style?.analysisZh, !analysis.isEmpty {
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    Text(analysis)
                        .font(CovaType.callout).foregroundStyle(CovaColor.fg)
                        .lineLimit(analysisExpanded ? nil : 4)
                    Button(analysisExpanded ? "收起" : "展开") {
                        withAnimation(CovaMotion.fast) { analysisExpanded.toggle() }
                    }
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            if let promptEn = plan.style?.promptEn, !promptEn.isEmpty {
                Button(promptExpanded ? "收起提示词" : "查看提示词") { promptExpanded.toggle() }
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                if promptExpanded {
                    Text(promptEn).font(CovaType.mono).foregroundStyle(CovaColor.muted)
                }
            }
            PlanCardLyricsBlock(
                plan: plan,
                sessionID: sessionID,
                onUpdated: onUpdated,
                onBalanceOutOfDate: onBalanceOutOfDate
            )
            let chips = parameterChips(plan)
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CovaSpace.sm) {
                        ForEach(chips, id: \.self) { chip in
                            parameterChip(chip)
                        }
                    }
                }
            }
            if !balanceRefused {
                HStack {
                    if let credits = plan.credits {
                        Text("预计消耗 \(credits) co")
                            .font(CovaType.mono).foregroundStyle(CovaColor.accentText)
                    }
                    if let balance = creditsBalance {
                        Text("余额 \(balance)")
                            .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    }
                    Spacer()
                }
            }
            actionRow
        }
    }

    /// 底部操作行（AX 档上下堆叠，§7）：主钮 50pt `gradient.brandButton` 胶囊
    /// + 「修改要求」文字钮（`canRevise` 决定可不可用）。
    @ViewBuilder
    private var actionRow: some View {
        let layout = axLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CovaSpace.sm))
            : AnyLayout(HStackLayout(spacing: CovaSpace.sm))
        layout {
            Button(action: onStart) {
                if startingLike {
                    // §9 行 4：主钮位 = 菊花 + 「已提交，正在排产」（防重扣，D8）。
                    HStack(spacing: CovaSpace.sm) {
                        ProgressView().controlSize(.small)
                        Text("已提交，正在排产")
                            .font(CovaType.callout).foregroundStyle(CovaColor.muted)
                    }
                    .padding(.horizontal, CovaSpace.lg)
                    .frame(minHeight: 50)
                    .background(Capsule().fill(CovaColor.surface))
                } else {
                    Text(PlanStatusCopy.primaryAction(plan.status))
                        .font(CovaType.callout)
                        .foregroundStyle(canStart ? Color.white : CovaColor.muted)
                        .padding(.horizontal, CovaSpace.lg)
                        .frame(minHeight: 50)
                        .background(
                            Capsule()
                                .fill(
                                    canStart
                                        ? AnyShapeStyle(CovaGradient.brandButton)
                                        : AnyShapeStyle(CovaColor.surface)
                                )
                        )
                        .shadow(
                            color: canStart ? CovaElevation.primaryButtonShadowColor : .clear,
                            radius: 9, x: 0, y: 6
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!canStart || startBusy)
            Button("修改要求", action: onRevise)
                .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                .frame(minHeight: 44)
                .disabled(!PlanStatusCopy.canRevise(plan.status))
        }
    }

    /// 参数胶囊的取值与文案一律不在本屏拼：裁决面在 CovaCore `OneStepPlanParameterCopy`。
    private func parameterChips(_ plan: OneStepPlanCardDto) -> [String] {
        OneStepPlanParameterCopy.chips(parameters: plan.parameters, type: plan.type)
    }

    /// 参数行的一枚 chip（展示形态，不是可点控件）。
    private func parameterChip(_ text: String) -> some View {
        Text(text)
            .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
            .padding(.horizontal, CovaSpace.md)
            .padding(.vertical, CovaSpace.xs)
            .background(Capsule().fill(CovaColor.surface))
            .fixedSize()
    }
}

// MARK: - 09 §1「标题候选 / 歌词编辑均在本屏内（不跳屏）」

/// 计划卡上的歌词区：只读平铺 **+ 就地编辑**，全程不跳屏。
///
/// 视图只负责摆：能不能编辑、脏跟踪、拼载荷、幂等键、拒绝分诊全在 CovaCore
/// （`OneStepLyricsEditor`，25 条用例钉着）。本屏只守三条：
/// · **未确认成功前不改本地态** —— 卡面只在后端回显到达那一步才换（`onUpdated`），
///   失败路径一个字段都不动，用户写的字原地留着；
/// · 拿不到编辑基线的那几种形态**不给编辑钮**，并把原因说出来；唯一闭嘴的那一种是
///   "这张卡没有歌词"（09 §8：整段不渲染，也不显「无歌词」）；
/// · 每个钮都有中文 `accessibilityLabel` 与 ≥44pt 热区（09 §7），AX 档下动作行上下堆叠。
struct PlanCardLyricsBlock: View {
    let plan: OneStepPlanCardDto
    let sessionID: String
    let onUpdated: (OneStepPlanCardDto) -> Void
    let onBalanceOutOfDate: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.covaAXLayout) private var axLayout

    @State private var editor: OneStepLyricsEditor?
    @State private var phase: OneStepLyricsPanelPhase = .readOnly
    @State private var notice: String?
    @State private var tokens = OneStepLyricsEditTokenLedger()
    @State private var askedToRegenerate = false
    /// 版本读数是**读来的**：没读到就只报当前版，不印"共 0 版"（不编造边界）。
    @State private var versionReadout: String?

    private var block: OneStepLyricsEditingBlock? {
        OneStepLyricsEditor.block(for: plan, sessionID: sessionID)
    }

    private var sections: [OneStepLyricsSectionDto] {
        OneStepLyricsEditor.orderedSections(of: plan)
    }

    var body: some View {
        if block == .noLyrics {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                header
                if let editor {
                    editingRows(editor)
                } else {
                    readOnlyRows
                }
                if editor == nil, let reason = block?.userCopy {
                    Text(reason)
                        .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow
                if let notice { noticeLine(notice) }
            }
            .onChange(of: plan) { _, latest in reconcile(with: latest) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
            Text("歌词").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            if let versionReadout {
                Text(versionReadout).font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
            Spacer(minLength: CovaSpace.sm)
            if phase != .readOnly {
                Text(phase.userLabel).font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
        }
        // §7 朗读顺序里计划卡那一条要能念到「歌词 N 段」，段数与读数合成一个元素。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "歌词，\(sections.count) 段"
                + (versionReadout.map { "，\($0)" } ?? "")
                + (phase == .readOnly ? "" : "，\(phase.userLabel)")
        )
    }

    private var readOnlyRows: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            VStack(alignment: .leading, spacing: 2) {
                Text(OneStepLyricsEditingCopy.sectionTitle(label: section.label, order: index))
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                let body = OneStepLyricsEditor.bodyText(of: section)
                if !body.isEmpty {
                    Text(body).font(CovaType.body).foregroundStyle(CovaColor.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func editingRows(_ snapshot: OneStepLyricsEditor) -> some View {
        ForEach(Array(snapshot.drafts.enumerated()), id: \.offset) { index, draft in
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                Text(OneStepLyricsEditingCopy.sectionTitle(label: draft.label, order: index))
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                TextEditor(text: bodyBinding(at: index))
                    .font(CovaType.body)
                    .foregroundStyle(CovaColor.fg)
                    .scrollContentBackground(.hidden)
                    .padding(CovaSpace.xs)
                    // AX 档给到 5 行高：字号放大后两行的框会把第三行藏起来（看不见 ≠ 没内容）。
                    .frame(minHeight: axLayout ? 132 : 72)
                    .background(
                        RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                            .fill(CovaColor.surface)
                    )
                    .accessibilityLabel("第 \(index + 1) 段歌词，可编辑")
            }
        }
    }

    /// 一格的读写口：改的是**这一屏的草稿**，不是卡面。卡面要等后端回显（见类型注释）。
    private func bodyBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let editor, editor.drafts.indices.contains(index) else { return "" }
                return editor.drafts[index].body
            },
            set: { value in editor?.editBody(value, at: index) }
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        // §Dynamic Type：动作行在 AX 档上下堆叠（与费用行/操作行同一处理）。
        let row = axLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CovaSpace.sm))
            : AnyLayout(HStackLayout(spacing: CovaSpace.sm))
        row {
            if editor != nil {
                covaTextButton(
                    title: phase == .saving ? "正在保存…" : "保存歌词",
                    label: "保存歌词改动",
                    hint: "只提交你改动过的那几段，不会重新生成整篇",
                    tint: CovaColor.accentText,
                    busy: phase == .saving
                ) { Task { await save() } }
                covaTextButton(
                    title: "取消编辑",
                    label: "取消编辑，丢弃未保存的改动",
                    hint: nil,
                    tint: CovaColor.secondary,
                    busy: phase == .saving
                ) { cancelEditing() }
            } else if block == nil {
                covaTextButton(
                    title: "编辑歌词",
                    label: "编辑歌词",
                    hint: "在本屏内改歌词，不需要离开",
                    tint: CovaColor.accentText,
                    busy: false
                ) { startEditing() }
                covaTextButton(
                    title: phase == .regenerating ? "正在重做…" : "重做歌词",
                    label: "重做整篇歌词",
                    hint: "会先确认，因为这一条按实际用量扣费",
                    tint: CovaColor.secondary,
                    busy: phase == .regenerating
                ) { askedToRegenerate = true }
            }
        }
        .confirmationDialog(regenerateWarning, isPresented: $askedToRegenerate, titleVisibility: .visible) {
            Button("确认重做") { Task { await regenerate() } }
            Button("先不重做", role: .cancel) {}
        }
    }

    /// 本屏统一的文字钮形状：≥44pt 热区（09 §7）+ 中文读法。
    private func covaTextButton(
        title: String,
        label: String,
        hint: String?,
        tint: Color,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(CovaType.callout)
                .foregroundStyle(tint)
                .frame(minHeight: 44)
                .frame(maxWidth: axLayout ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }

    private func noticeLine(_ text: String) -> some View {
        Text(text)
            .font(CovaType.caption)
            .foregroundStyle(phase == .failed || phase == .stale ? CovaColor.error : CovaColor.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("歌词编辑状态，\(text)")
    }

    /// **扣费确认**话术（AGENTS 硬边界 5 + D12）：只说这一条会按实际用量扣、会出新版本，
    /// 不说任何"去哪补余额"的话。
    private var regenerateWarning: String {
        "重做会由后端按这一次的实际用量扣费，并生成新版歌词；现在这份会被替换掉。确认要重做吗？"
    }

    // MARK: 行为

    private func startEditing() {
        guard let fresh = OneStepLyricsEditor(plan: plan, sessionID: sessionID) else { return }
        editor = fresh
        phase = .editing
        notice = nil
        readVersionReadout()
    }

    private func cancelEditing() {
        editor = nil
        phase = .readOnly
        notice = nil
    }

    /// 回读版本清单（**只读**）。拿不到就停在"只报当前版"。
    private func readVersionReadout() {
        versionReadout = OneStepLyricsEditingCopy.versionLabel(plan.lyrics?.revision)
        Task {
            guard let versions = try? await session.studio.lyricVersions(planCardID: plan.planCardId)
            else { return }
            versionReadout = OneStepLyricsEditingCopy.versionSummary(
                versions, current: plan.lyrics?.revision
            )
        }
    }

    private func save() async {
        guard let editor else { return }
        if let reason = editor.saveBlock() {
            notice = reason
            return
        }
        phase = .saving
        notice = nil
        do {
            let key = try tokens.token(
                planCardID: plan.planCardId, fingerprint: editor.payloadFingerprint
            ).key
            switch try await session.studio.saveLyrics(editor.patchRequest(key: key)) {
            case .saved(let card), .replayed(let card):
                self.editor = nil
                phase = .saved
                onUpdated(card)
            case .landedWithoutEcho:
                self.editor = nil
                phase = .savedWithoutEcho
                notice = "改动已经保存，但这份响应没带回卡面；下拉刷新或下次进入才会看到新内容。"
            }
        } catch {
            if let rejection = OneStepLyricsEditRejection.classify(error) {
                phase = rejection == .staleCard ? .stale : .failed
                notice = rejection.userCopy
            } else {
                phase = .failed
                notice = "这次没保存上：\(StudioService.classify(error).uiMessage)；你写的字还在草稿里。"
            }
        }
    }

    /// 重做整篇歌词。**必须先在 `confirmationDialog` 上按过「确认重做」**。
    /// 失败绝不自动重试。
    private func regenerate() async {
        guard let revision = plan.revision else {
            phase = .failed
            notice = OneStepLyricsEditingBlock.cardRevisionUnknown.userCopy
            return
        }
        phase = .regenerating
        notice = nil
        do {
            let key = try tokens.token(
                planCardID: plan.planCardId, fingerprint: "regen|\(revision)"
            ).key
            let outcome = try await session.studio.regenerateLyrics(
                sessionID: sessionID, plan: plan, key: key
            )
            if let card = outcome.card {
                phase = .saved
                onUpdated(card)
            } else {
                phase = .savedWithoutEcho
            }
            notice = outcome.chargeCopy
            onBalanceOutOfDate()
        } catch {
            if let rejection = OneStepLyricsEditRejection.classify(error) {
                phase = .failed
                notice = rejection.userCopy
            } else {
                phase = .failed
                notice = "这次没走通：\(StudioService.classify(error).uiMessage)；没有自动重试，要再来一次请再按一次并确认。"
            }
        }
    }

    /// 卡面在别处变了（SSE 又推一张、或另一台设备改过）。
    /// **有未保存改动时一律不覆盖**：只把"这一份基线已经不新鲜"说出来。
    private func reconcile(with latest: OneStepPlanCardDto) {
        guard let editor else { return }
        guard editor.isDirty else {
            self.editor = OneStepLyricsEditor(plan: latest, sessionID: sessionID)
            return
        }
        phase = .stale
        notice = OneStepLyricsEditRejection.staleCard.userCopy
    }
}

// MARK: - §4.1 首载骨架（三段轮廓：短文本条 + 计划卡轮廓 + 候选卡组轮廓，surface 呼吸）

/// 首载骨架。与 `CovaSkeleton` 同一节奏（0.9s 整块互换、Reduce Motion 静止），
/// 但形状照 §4.1 点名的三段，不是五行灰条 —— 「形状照真实卡」的同一口径。
private struct SessionLoadingSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            SessionSkeletonBar(width: 160, height: 14, lit: lit)
            skeletonCard(lit: lit) {
                VStack(alignment: .leading, spacing: CovaSpace.md) {
                    SessionSkeletonBar(width: 200, height: 16, lit: lit)
                    SessionSkeletonBar(width: .infinity, height: 44, lit: lit)
                    SessionSkeletonBar(width: 240, height: 40, lit: lit)
                }
            }
            skeletonCard(lit: lit) {
                HStack(spacing: CovaSpace.sm) {
                    SessionSkeletonBar(width: .infinity, height: 120, lit: lit)
                    SessionSkeletonBar(width: .infinity, height: 120, lit: lit)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CovaSpace.pageGutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
        }
        .accessibilityLabel("加载中")
    }

    private func skeletonCard<Content: View>(
        lit: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(CovaSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CovaColor.surface.opacity(lit ? 1 : 0.6))
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .strokeBorder(CovaColor.line, lineWidth: 1)
            )
    }
}

/// 一根 `surface` 呼吸条（计划卡 analyzing 骨架位与首载骨架共用）。
struct SessionSkeletonBar: View {
    let width: CGFloat
    let height: CGFloat
    var lit = true

    var body: some View {
        RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
            .fill(CovaColor.surface)
            .opacity(lit ? 0.9 : 0.5)
            .frame(maxWidth: width == .infinity ? .infinity : width)
            .frame(height: height)
    }
}
