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
/// · 「开始制作」必须同时满足：状态 `ready` + 归因（`sourceMessage.messageId == 本次客户端消息号`）
///   + 带 `snapshotHash`，三者缺一律置灰，不放宽；
/// · 未知 `run_*` 事件**隐藏且不算坏事件**；未知计划卡状态渲染只读卡 + 「状态更新中」。
public struct AISessionDetailView: View {
    @Environment(AppSession.self) private var session
    private let sessionID: String

    @State private var phase: Phase = .loading
    @State private var lines: [TranscriptLine] = []
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
    /// 每次详情载荷到达就整包重播（与 ♡ 账同一口径）：留着上一轮的阶梯 = 把已经走过的环节
    /// 继续显示成没走过。`nil` 不是错误，是"这一格没有实测进度"⇒ 进度条退回 §3-I 的老样子。
    @State private var workflow: StudioWorkflowStateDto?
    /// 候选 ♡ 的账：键 = `mediaReferenceId`，**每次详情载荷到达都整本重新播种**
    /// （留下未确认的乐观翻转 = 把本地的谎继续显示成后端的谎）。
    @State private var favorites = CandidateFavoriteLedger()
    /// 计划启动的幂等键账本（D8）：同一 `(会话, 计划卡, revision)` 的**重试复用同一个键**，
    /// 这样"提交成功但响应没读出来"的情形不会被用户的第二次点击变成第二次扣费。
    @State private var startTokens = PlanStartTokenLedger()
    /// 09 §Dynamic Type：AX 档下气泡放到整行、候选卡组纵向堆叠。
    @Environment(\.covaAXLayout) private var axLayout
    @State private var creditsBalance: Int?
    @State private var runLabel: String?
    @State private var degradeLabel: String?
    @State private var draft = ""
    @State private var deepThinking = false
    @State private var busy = false
    @State private var thinkingSteps = 0
    /// 本轮是否**已经问过要挑哪一版**（09 §5 终态行：主钮按下去之后，已就绪的卡上才出「选这版继续制作」）。
    @State private var choosingVersion = false
    /// 失败卡「重试」的那一次**读**在不在途（连点吞后发，同 §10 对 ♡ 的口径）。
    @State private var reconciling = false
    /// 21 面板（会话路径）开没开。宿主只有这一个布尔：面板自己不管 sheet 之外的生命周期。
    @State private var extrasShown = false
    /// jobs 轮询那条腿的**归属号**（§5 P1-5）。每一次"有别的主人接管这一轮"（一轮流起来、
    /// 又读到一份载荷、屏不见了）都把它加一 ⇒ 在途那一趟回来时号对不上就直接丢。
    /// 靠号而不是只靠 `Task.cancel()`：`await` 已经返回的那一趟不受 cancel 影响，
    /// 而"取消任务 + 立刻发起新任务"这种竞态要的正是这一层。
    @State private var jobPollToken = 0
    @State private var jobPollTask: Task<Void, Never>?
    @State private var lineCounter = 0
    @State private var agentBuffer = ""

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(sessionID: String) { self.sessionID = sessionID }

    public var body: some View {
        VStack(spacing: 0) {
            if let degradeLabel { degradationBar(degradeLabel) }
            transcript
            composer
        }
        .covaPage()
        .navigationTitle("创作会话")
        .navigationBarTitleDisplayMode(.inline)
        .task { await openSession() }
        .sheet(isPresented: $extrasShown) {
            WorkExtrasPanelView(host: .session(id: sessionID, instrumental: nil)) {
                extrasShown = false
            }
        }
        .onDisappear {
            // 屏不在了就没有观察者 ⇒ 两条在途的腿一起收掉：流照旧取消，jobs 轮询也必须停
            // （屏上看不见的东西不许继续花请求，更不许回来写一份没人看的状态）。
            stopJobPoll()
            Task { await session.cancelStudioStream() }
        }
    }

    // MARK: 流式过程

    @ViewBuilder
    private var transcript: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 5)
        case .failed(let failure):
            CovaErrorState(kind: Self.kind(failure)) { Task { await openSession() } }
        case .ready:
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CovaSpace.md) {
                        ForEach(lines) { line in
                            row(line).id(line.id)
                        }
                        ForEach(plans, id: \.planCardId) { plan in
                            PlanCardView(
                                plan: plan,
                                sessionID: sessionID,
                                canStart: canStart(plan),
                                creditsBalance: creditsBalance,
                                onStart: { Task { await start(plan) } },
                                onRevise: { draft = "请修改：" },
                                onUpdated: { applyPlanUpdate($0) },
                                onBalanceOutOfDate: { Task { await refreshBalance() } }
                            )
                        }
                        if !candidates.isEmpty { candidateBlock }
                        if let deliveryProgress { deliveryProgressBar(deliveryProgress) }
                    }
                    .padding(CovaSpace.pageGutter)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine) -> some View {
        switch line.kind {
        case .user(let text):
            // 09 §3-B / §Dynamic Type：用户气泡**最大宽 78%**，AX 档放到整行（屏宽 − 2×页边距）。
            // 外层容器取容器的 78%/100%，内层 Text 仍是固有宽度 + 右对齐 ⇒ 是"最大宽"而不是"固定宽"。
            // 原先写的是 `Spacer(minLength: 40)`：那只是"至少留 40pt"，长句照样铺满整行，不是 78%。
            HStack {
                Spacer(minLength: 0)
                Text(text)
                    .font(CovaType.body).foregroundStyle(CovaColor.accentText)
                    .padding(CovaSpace.md)
                    .background(
                        RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                            .fill(CovaColor.accentSoft)
                    )
            }
            .containerRelativeFrame(
                .horizontal, count: 100, span: axLayout ? 100 : 78, spacing: 0, alignment: .trailing
            )
        case .agentText(let text):
            Text(text)
                .font(CovaType.body).foregroundStyle(CovaColor.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let steps, _):
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                Text("▸ 深度思考 · \(steps) 步")
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            }
        case .run(let label):
            HStack(spacing: CovaSpace.sm) {
                Image(systemName: "circle.dashed").foregroundStyle(CovaColor.secondary)
                Text(label).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            }
        case .system(let text):
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.error)
        case .plan:
            EmptyView()   // 计划卡本体在 plans 那一层渲染，这里只留位置
        }
    }

    private func degradationBar(_ text: String) -> some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "wifi.slash").foregroundStyle(CovaColor.secondary)
            Text(text).font(CovaType.caption).foregroundStyle(CovaColor.secondary)
            Spacer()
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
        .background(CovaColor.surface)
    }

    // MARK: 双 Demo（只渲染前两个候选）

    @ViewBuilder
    private var candidateBlock: some View {
        // 「只取前两个」也归 `DoubleDemoRule` 管（§5 行 7：后端给 3+ 时界面只见 2）。
        let pair = DoubleDemoRule.pair(candidates)
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                Text(terminalText(pair))
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 主钮只在**终态且至少有一版可挑**时出现（§5 行 4「ready+ready 终态」/ 行 5
                // 「可用（唯一可选）」；行 6 两版全失败没得挑 ⇒ 不放一个点了没反应的钮）。
                if DoubleDemoRule.canChooseVersion(pair) {
                    Button("选一版继续制作") { choosingVersion = true }
                        .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                        .accessibilityHint("选择后要挑一个版本")
                }
                // 21 面板的**第二个宿主**（会话路径，按 key 扣 co）。放在终态行而不是候选卡上：
                // 补充制作是"这一轮做完了再加工"，两版都还没收口时给它一个入口就是引导用户
                // 去花一笔还不该花的钱。
                // `instrumental` 传 nil：这一格是**会话**，没有"某一行的器乐事实"可给，
                // 而面板的规则是"宿主给不出就不滤键集"——滤与不滤由服务端的权威答复决定。
                if DoubleDemoRule.isTerminal(pair) {
                    Button("补充制作") { extrasShown = true }
                        .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                        .accessibilityIdentifier("cova.session.extras")
                }
            }
            ForEach(pair.indices, id: \.self) { index in
                candidateRow(pair[index], index: index, terminal: DoubleDemoRule.isTerminal(pair))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateRow(
        _ candidate: GenerationCandidateDto, index: Int, terminal: Bool
    ) -> some View {
        // 「settled」与「可以试听」是两件事：`DoubleDemoRule.isSettled` 含 **failed**（D7 的终局定义），
        // 原实现把它当可播性用 ⇒ 失败卡印「可以试听」+ 播放图标、ready 形状套在 failed 数据上，
        // 正是 §5 行 3/5/6 要的「失败卡 error 遮罩 + 「重试」」没落地那一处。
        // 是否**可选**另说：占位卡与失败卡在操作条上不出选择钮（见 `versionChoice`）。
        let ready = DoubleDemoRule.isReady(candidate)
        let failed = DoubleDemoRule.isFailed(candidate)
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaListRow(
                title: candidate.title ?? "版本 \(index + 1)",
                subtitle: failed ? Self.failedStatusText : (ready ? "可以试听" : "制作中"),
                artwork: CovaArtwork(
                    resolution: CovaArtworkResolution(serverValue: candidate.coverUrl),
                    title: candidate.title ?? "")
            ) {
                // 失败卡不给 ▶ 也不给菊花：§5 的失败卡面只有 error 遮罩 + 重试，
                // 摆一个播放图标就是"这里能播"的谎。符号沿用本屏 §3-F 给 `run_failed` 定的一枚。
                // D24 构图：♡ 原来掉在行的**下面一行**，与行脱开（屏上就是一枚孤立的心）——
                // 这一屏的候选行不是卡片，没有容器把它兜在一起，所以"另起一行"直接读成堆叠。
                // 并回行内，排在试听钮左侧；「重试 / 选一版」仍留在下面那条动作条（它们有文字，
                // 挤进行内会把行高顶回去）。
                HStack(spacing: CovaSpace.xs) {
                    if CandidateFavoriteLedger.canFavorite(candidate) {
                        favoriteButton(candidate)
                    }
                    Image(systemName: failed ? "xmark.octagon" : (ready ? "play.circle" : "hourglass"))
                        .foregroundStyle(failed ? CovaColor.error : CovaColor.muted)
                }
            } action: {
                if failed {
                    // 点整张失败卡 = 点它那颗「重试」：只做一次重读，不碰任何写操作。
                    Task { await reconcileRound() }
                    return
                }
                guard ready, let raw = candidate.audioUrl?.rawValue, let url = URL(string: raw),
                      let item = Self.playbackItem(for: candidate, url: url) else {
                    session.showToast("试听文件没取到，重试", isError: true)
                    return
                }
                Task { await session.play(items: [item], at: 0) }
            }
            // error 遮罩（09 §5 / components §5）：只盖卡面，不吃点击（整行本身是按钮）。
            .overlay { if failed { candidateErrorScrim } }
            candidateActionBar(candidate, index: index, ready: ready, terminal: terminal)
        }
    }

    /// 失败卡的状态文案。**不在这里再立一张中文表**：09 §9 行 11 的「未完成，可重试」
    /// 是本仓已有、语义正好对上的那一份（`PlanStatusCopy`，design 09 §9 权威表的实现）。
    private static let failedStatusText = PlanStatusCopy.label(.retryableFailure)

    /// 失败卡的 error 遮罩。`color.errorSoft` 衬底档未入库（09 TG-21）⇒ 与 04 §2 的 scrim 同一处理：
    /// 不自己挑一个品牌色透明度配方，只取 `color.error` 的一层低不透明度衬底，
    /// 数值收在命名常量里，裁决落 token 时只改这一处。
    /// `.allowsHitTesting(false)`：遮罩是**表现层**，不许把整行的点击吞掉（那会藏掉「重试」这条路）。
    private var candidateErrorScrim: some View {
        RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
            .fill(CovaColor.error.opacity(Self.errorScrimOpacity))
            .allowsHitTesting(false)
    }

    /// TG-21（`errorSoft` 未入库）期间的占位强度：比 04 那层 30% 的屏遮罩更轻，
    /// 因为它压在卡面的标题行与状态行底下，还得让那两行照读。
    private static let errorScrimOpacity: Double = 0.12

    /// 候选卡底部操作条（09 §3-H 列了三件：♡ 收藏 / ↓ 下载 / ⤴ 分享；§5 另要失败卡有「重试」）。
    ///
    /// · **↓ 下载** —— **不渲染**：D12 明令 v1.0 不开任何扣费入口，09 §5 的终态行原文即
    ///   「下载入口仍按 D12 隐藏」，合规评审放行后再接。
    /// · **⤴ 分享** —— **不渲染，因为契约里没有任何可公开访问的候选页面**（NEEDS-24）。
    ///   `api-contracts.md` §4 全表只有 sessions / plans / generation-jobs / agent / retention，
    ///   既无「候选公开页」也无 share/短链端点。仓内另外两处能分享的东西用的都是**公开曲库资源**
    ///   的常量链接（16 的 `covalink.cn/artists/:id`、02 与 07 的 `covalink.cn/tracks/:id`），
    ///   而生成候选**不是**曲库曲目 —— 09 §1 自己就写着「若候选已被后端收录为库曲，v1.0 一般不可」。
    ///   剩下唯一能拿到的地址是 `audioUrl` / `audioDownloadUrl`，那是 Bearer 授权地址：
    ///   把它交给系统分享面板等于把凭证送出设备（硬边界 3 / D7 / TD-23 三面禁止）。
    ///   ⇒ 少一个钮，不编一个分享目标。后端补上公开页或分享端点后，在这里接 `ShareLink`。
    /// · **重试** —— 只挂在**失败**那一版上（§5 行 3/5/6）。它的动作不是 `plans/start`，
    ///   理由整段写在 `retryControl` 上（09 §待裁决 4 自己都没裁完，那一刀我不替它裁）。
    @ViewBuilder
    private func candidateActionBar(
        _ candidate: GenerationCandidateDto, index: Int, ready: Bool, terminal: Bool
    ) -> some View {
        HStack(spacing: CovaSpace.sm) {
            // ♡ 已并到行内（D24 构图），这里只剩**带文字**的动作：失败卡的「重试」与「选一版」。
            // 「无 mediaReferenceId 时整钮不渲染」（09 §5 / §8）那条判据跟着 moved 到行内那一处，
            // 由 `CandidateFavoriteLedger.canFavorite` 同一个入口把关，没有第二份口径。
            if DoubleDemoRule.isFailed(candidate) {
                retryControl()
            }
            versionChoice(candidate, index: index, ready: ready, terminal: terminal)
            Spacer(minLength: 0)
        }
        .padding(.leading, CovaSpace.pageGutter)
    }

    /// 失败卡上的「重试」（09 §5 卡面列「失败卡 error 遮罩 + 「重试」」；§7 触控目标清单里也有它）。
    ///
    /// **它按下的不是「再来一次制作」** —— 这一步必须说清，因为规格自己也没裁完：
    /// · 契约里没有任何"单候选重试"端点（`docs/api-contracts.md` §4 的一步模式全表 =
    ///   sessions / plans / plans/start / generation-jobs / retention / agent），
    ///   09 行 209 原文即「重试该候选需后端支持（未见端点）」；
    /// · 退一步按 §待裁决 4 的临时读法改走 `plans/start` 也**不成立**：那条要求**换新幂等键**，
    ///   而本屏对同一 `(会话, 计划卡, revision)` 的账是按 D8 **复用同一个键**的
    ///   （`startTokens` / `PlanStartTokenLedger`）。复用 ⇒ 后端把它当同一次操作去重，这颗钮永远
    ///   不会有结果（造的正是本仓最反对的那种点了没反应的假控件）；换新键 ⇒ 为同一张卡再扣一次费，
    ///   恰好是"重试不得变成第二次扣费"要防的那件事。
    /// · 何况产出失败候选的那一轮，计划卡状态是 `demos_ready` / `manual_recovery` /
    ///   `retryable_failure`，§9 行 7/10 明令「开始制作」禁用，而"重新制作"这颗本来就在
    ///   **计划卡**上（`PlanStatusCopy.primaryAction`），不该在候选卡上再长一颗。
    /// ⇒ 于是这一枚做本屏唯一**既有真实效果、又不碰钱**的动作：重新核对这一轮
    ///   （`GET sessions/:id` + `plans`，与 §8「下拉刷新」同一口径）。
    ///   2026-09-27 起本屏**已有** jobs 轮询那条腿（§5 P1-5，见「任务轮询」一节），这一枚
    ///   仍然不是空转：轮询只读 `generation-jobs?id=` 那**一行**，而这一枚读的是会话整包
    ///   —— 计划卡、消息流、workflow 阶梯都只有这一枚（与下拉刷新）会取回来。仍然失败时按
    ///   §5 行 6 引导「换一句话再来一次」，全程不出现扣费/退款话术（D12）。
    /// 这一枚不接 candidate 参数：今天它做的是**整轮**重读，与是哪一版无关。等后端真的补出
    /// 「只补做失败那一版」的端点（§待裁决 4 点名的那个缺口），这里才需要把候选身份带进动作。
    @ViewBuilder
    private func retryControl() -> some View {
        Button {
            Task { await reconcileRound() }
        } label: {
            HStack(spacing: CovaSpace.xs) {
                Image(systemName: reconciling ? "hourglass" : "arrow.clockwise")
                Text("重试")
            }
            .font(CovaType.callout)
            .foregroundStyle(CovaColor.accentText)
            // §7：文字钮的热区 ≥44pt（与 `versionChoice` 同一把尺子）。
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reconciling)
        .accessibilityLabel("重试这一版")
        .accessibilityHint("重新核对这一轮的制作结果，不会重新发起制作")
    }

    /// 「重试」的落地：一次**只读**的对账。与 `openSession()` 读同一批事实、用同一套播种口径，
    /// 但不进 `.loading`（整屏骨架会把已经在的对话流抽走，而这里只是核一眼后端），
    /// 也不重发首页带过来的那句话。`plans` 只在取到时覆盖（取不到 ≠ 后端说"没有卡"）。
    private func reconcileRound() async {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        do {
            let detail = try await session.studio.session(sessionID)
            let jobs = detail.generationJobs
            latestJob = jobs.last
            candidates = jobs.last?.candidates() ?? []
            workflow = detail.session?.decodedWorkflowState()
            if let cards = try? await session.studio.planCards(sessionID: sessionID) { plans = cards }
            // 服务端为事实源：♡ 账整本重播种，"已经问过挑哪一版"也随之作废（同 `openSession` 口径），
            // 免得用户按着一份刚被后端改掉的清单继续选。
            favorites.reseed(from: candidates)
            choosingVersion = false
            syncStudioJobLedger()   // 同 `openSession`：这份重读就是 08 那一格的对齐时机
            // 这份载荷就是这一路最新的一份权威状态 ⇒ 轮询以它为基准重来（旧号作废）。
            restartJobPoll()
            if candidates.contains(where: { DoubleDemoRule.isFailed($0) }) {
                // §5 行 6 的引导，且只说这一句：不出现"扣费/退款"任何字样（D12）。
                session.showToast("这一版仍未完成，可以换一句话再来一次")
            } else {
                session.showToast("已重新核对，这一轮的状态更新了")
            }
        } catch {
            session.showToast(
                "没读到最新状态：\(StudioService.classify(error).uiMessage)", isError: true
            )
        }
    }

    /// 「选这版继续制作」（§5 行 2/4/5）。**只对已就绪的那一版渲染** ——
    /// 占位卡与失败卡上没有可交付的音频，指着一团像素问「要这版吗」是造坏路径。
    ///
    /// · 未到终态（`ready + pending`）：钮照 §5 摆着但**不放宽**，点击给规格那句
    ///   「两个版本都完成后可以继续」。这里刻意不用 SwiftUI 的 `.disabled(true)` ——
    ///   spec 要的是「点了要说原因」，而真禁用会把点击整个吞掉，用户只得到一个没反应的灰钮。
    /// · 已到终态但还没按主钮：不渲染（先让用户走「选一版继续制作」这一步，避免误触直接改本轮方向）。
    /// · 已到终态且已按主钮：渲染主动作，点击 = 把这一版的选择发出去。
    @ViewBuilder
    private func versionChoice(
        _ candidate: GenerationCandidateDto, index: Int, ready: Bool, terminal: Bool
    ) -> some View {
        if ready {
            if terminal, choosingVersion {
                Button("选这版继续制作") {
                    choosingVersion = false
                    Task { await chooseVersion(candidate, index: index) }
                }
                .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                .frame(minHeight: 44)   // §7 触控目标
            } else if !terminal {
                Button("选这版继续制作") {
                    session.showToast("两个版本都完成后可以继续")
                }
                .font(CovaType.callout).foregroundStyle(CovaColor.muted)
                .frame(minHeight: 44)
            }
        }
    }

    private func favoriteButton(_ candidate: GenerationCandidateDto) -> some View {
        let on = CandidateFavoriteLedger.isFavorite(candidate, in: favorites)
        return Button {
            Task { await toggleFavorite(candidate) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 16))
                .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                // ♡ 是触控目标（09 §7「≥44pt」），图标 16pt 不能当热区。
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏")
    }

    /// ♡ 的一次往返：乐观翻转 → 真发 `PATCH …/retention` → 失败**回落到服务端事实并说出来**。
    ///
    /// 请求体就是契约给的 `{favorite}` 一个字段，**不带幂等键**：该端点按值幂等
    /// （反复 PUT 同一个布尔值不产生第二次副作用，与「下载 checkout / plans/start」不是一类写）。
    /// 若后端将来要求幂等键，那是改契约 ⇒ 先登记 NEEDS，不在客户端加字段。
    private func toggleFavorite(_ candidate: GenerationCandidateDto) async {
        guard let intent = favorites.beginToggle(candidate) else { return }   // 吞后发 / 无处可调
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
    private static func playbackItem(
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

    /// 终态文案（design 09 §H 的六句固定串）。**「哪一版算就绪 / 算不算终态」不在本屏判定** ——
    /// 那是 `DoubleDemoRule`（D7）的活，18 的本地通知读的是同一本账（用例在 CovaCore）。
    private func terminalText(_ pair: [GenerationCandidateDto]) -> String {
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

    /// 「选这版继续制作」的落地方式 = **把选择当成一句话发给 agent**，不是发明字段。
    ///
    /// 依据（逐条核对过契约，见 `docs/api-contracts.md` §4）：
    /// · `POST /api/studio/agent` 的请求体我们只发 `sessionId / message / deepThinking` 三件，
    ///   其 schema 本身就未文档化（NEEDS-13）；
    /// · `plans/start` 只带 `{sessionId, planCardId, revision, snapshotHash, idempotencyKey}` ——
    ///   它启动的是一张**计划卡**，没有任何候选/引用位；
    /// · `retention` 只有 `{favorite}`。
    /// ⇒ 契约里**不存在**能携带「哪一版」的结构化字段。所以选择以自然语言进同一句话的通道：
    ///   这与本屏其余部分的工作方式一致（用户想说的话都是这么发的），也不新增任何键。
    ///   「候选选择需要机器可读载体」记在 **NEEDS-13** 那条补充里（它登记的正是
    ///   agent 请求体 schema 未文档化）；后端补上之前，这里不猜字段名。
    /// 权威核对：start 的响应没给出任务号时，去读会话详情里的 `generationJobs`
    /// （它是后端的真账），而不是凭"我没解出来"就断言没提交。
    private func reconcileStartedJob(sessionID: String, planCardID: String, revision: Int) async {
        guard let detail = try? await session.studio.session(sessionID) else {
            degradeLabel = "任务号没读到，稍后下拉核对会话"
            return
        }
        let jobs = detail.generationJobs
        if let newest = jobs.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) {
            // 核到任务了 ⇒ 这一次逻辑操作已经结束，键可以作废：
            // 用户之后若真的「重新制作」，那是一次新操作，该拿一个新键。
            startTokens.invalidate(sessionID: sessionID, planCardID: planCardID, revision: revision)
            // 屏上那一路 job 的读数与候选清单**必须同源**：以前这里只换清单不换 `latestJob`，
            // 于是进度条与 08 那一格读的还是上一轮那一行，而清单已经是新一轮的空清单
            // —— 两个主人各说一段事实。核到的是哪一行，屏上就跟着认哪一行。
            latestJob = newest
            candidates = newest.candidates()
            degradeLabel = nil
            append(.system("已核到任务：\(newest.status.userLabel)"))
            // 这一行大概率正是 `submitted`（§5 P1-5 那条腿要跟的就是它）。
            restartJobPoll()
        } else {
            degradeLabel = "会话里还没有任务，若额度已变动请到官网核对"
        }
    }

    private func chooseVersion(_ candidate: GenerationCandidateDto, index: Int) async {
        // 标题为空回落「未命名版本」：§5 的回落口径是「版本 1 / 版本 2」，这里同一族说法，
        // 不把空字符串印进发给 agent 的话里（那是一句读不通的话）。
        let title = candidate.title.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名版本"
        await submit("就选版本 \(index + 1)（\(title)）继续制作，按这一版补齐完整音频。")
    }

    // MARK: I 补充制作进度条（09 §3-I / §9 行 8–9）

    /// 本轮**最新那张计划卡**：`cardIndex` 最大者，同值取数组里靠后的（后端按时间正序给列表）。
    /// 只看一张是有意的 —— 进度条表达的是「这一轮走到哪一格」，把旧卡的状态拿来画就是画历史。
    private var latestPlan: OneStepPlanCardDto? {
        plans.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            return (candidate.cardIndex ?? 0) >= (current.cardIndex ?? 0) ? candidate : current
        }
    }

    /// 出现条件与格数全部由 CovaCore 的纯映射决定（那里有 15 条用例钉住），本屏只负责画。
    ///
    /// 三个输入各自是什么：
    /// · `plan.status` —— §3-I 的**出现/收起**条件（只有 `delivery_preparing` / `rehydrating`）。
    /// · `latestJob.status` —— 只换一句文案（取消 ⇒ 「本轮已停止」）。
    ///   §8 另给的 `GET …/generation-jobs?id=` 轮询**本屏已经接上**（2026-09-27，
    ///   DEVELOPMENT.md §5 P1-5）：屏在、屏上那一行未终态、且本机没在读这一轮流的时候，
    ///   按 `StudioCreatePollSchedule` 的节拍读那一行 ⇒ 取消/失败这类**只出现在 job 上**的
    ///   事实不必离开再进来才看得见。整条腿在下一节「任务轮询」，判据在 CovaCore 的
    ///   `SessionJobPollReconcile`（那里有用例钉着"读到取消只收口一次""投到上限不说失败"
    ///   "行里没带着候选就不许动清单"这三条）。
    ///   （本节此前写着"该端点全仓零调用点"—— 那句话自 0.2.72 起就是假的：19 屏的
    ///   `StudioCreateFlow.pollStudioCreate` 一直在投它；剩下缺的只是**本屏**这一处，本轮补上。）
    /// · `workflow` —— 09 §3-I 那条进度的**真来源**（`session.workflowState`，E5 的更正）。
    ///   解不出/没有 ⇒ 映射自己退回契约状态那套数字，本屏不需要为它写分支。
    ///   与 job 同一节奏：只在进屏/下拉刷新时重取，**不**随 SSE 增量前进（那是客户端待办，
    ///   契约里没有任何"工作流增量"事件可锚，见 NEEDS-13）。
    private var deliveryProgress: DeliveryProgress? {
        guard let plan = latestPlan else { return nil }
        return DeliveryProgressPlanner.progress(
            planStatus: plan.status, jobStatus: latestJob?.status, workflow: workflow
        )
    }

    /// 08 §3.C 那一格环的**唯一来源**：本设备内存里这一路的未终态 job（§数据源行 140）。
    ///
    /// 写点**只**落在"屏上刚拿到一份权威状态"的那几处（进屏、下拉对账、计划卡帧、启动计划，
    /// 以及 jobs 轮询读到终态那一次），并且**只走 `syncStudioJobLedger` 这一条**：
    /// 08 §数据源明令不得 N+1 ⇒ 那一格的环**绝不**为它自己新增任何轮询。09 §8 那条
    /// `generation-jobs?id=` 轮询（本轮已接，见下一节）只在 09 自己屏上读**一行**，
    /// 它给 08 的贡献只是"顺带把账收口"，不是给每一格会话都投一次请求。
    /// 收口同处理由：`update…` 只更新已有那条的读数，本机没发起过的会话（冷启动、别人发起的）
    /// 在这里既不上环也不报错，与 §9 判据第 3 条同一形状。
    private func syncStudioJobLedger() {
        if roundIsSettled {
            // 「本机是否看着这一路跑过」必须在 `settleStudioJob` **之前**读：settle 会把这一路
            // 从在途账里摘掉，之后再问就永远是"没有" ⇒ 迟到的终态会被当成不该发的那一档。
            let watchedInFlight = session.liveStudioJobs.studioHasLiveJob(sessionID)
            let terminalJob = latestJob
            let terminalPlanCardID = latestPlan?.planCardId
            let terminalOwner = session.meUser?.id
            session.settleStudioJob(sessionID: sessionID)
            // 18 的真终态通知：`StudioNotificationPlanner` 此前**只有规划器没有调用点**，
            // 用户收到的只有那条 30 分钟兜底串。判据与账本都在 CovaCore，这里只交事实。
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

    /// 终态只用本屏**已有**的两把尺子判，不给计划卡的 12 态发明第二套"哪些算结束"：
    /// · `DoubleDemoRule` —— 硬边界 6 的「前两个候选都 settled 才算终态」（不足两个永不终态）；
    /// · `GenerationJobStatus` 自己的词表（`isTerminal`）—— succeeded / failed / cancelled
    ///   是后端说"这一路完了"。同一本词表也管 jobs 轮询该不该起腿，所以这里不写 case 列表。
    ///
    /// `busy`（本机正在读这一轮的流）时**一律算未收口**：那段时间里 `candidates / latestJob`
    /// 还是这一轮开始**之前**的那份载荷，拿它判终态会把刚上环的格子当场抹掉
    /// （症状 = 计划卡刚到、环闪一下就没了），而流一结束的下一次对账会说真话。
    private var roundIsSettled: Bool {
        if busy { return false }
        if DoubleDemoRule.isTerminal(DoubleDemoRule.pair(candidates)) { return true }
        return latestJob.map { $0.status.isTerminal } ?? false
    }

    // MARK: 任务轮询（09 §8 / DEVELOPMENT.md §5 P1-5）

    /// 起（或重新起）这条腿：判据全在 CovaCore 的 `SessionJobPollReconcile.canArm` ——
    /// 没有任务号、流正读这一轮、屏上那一行已经终态，三种情况都不起腿。
    ///
    /// "每一次取代都换一个新的归属号"是这条腿唯一的失效手段：载荷到达、一轮流起来、屏消失
    /// 都会走到这里（或 `stopJobPoll`），于是**同一件事实不会有两个主人**，
    /// 而慢回来的那一趟只会丢，不会写。
    private func restartJobPoll() {
        restartJobPoll(jobID: latestJob?.id, tracked: latestJob?.status)
    }

    /// `tracked` 是这条腿自己跟着看的那一份状态：载荷给的 `latestJob` 带着它；
    /// 而 `plans/start` 刚拿到任务号时屏上**还没有**那一行 ⇒ 传 `nil`（未知 ≠ 终态）。
    private func restartJobPoll(jobID: String?, tracked: GenerationJobStatus?) {
        stopJobPoll()
        guard SessionJobPollReconcile.canArm(
            jobID: jobID, status: tracked, streamMidRound: busy
        ), let jobID else { return }
        let token = jobPollToken
        jobPollTask = Task { await runJobPoll(jobID: jobID, tracked: tracked, token: token) }
    }

    /// 停腿但**留着屏上已经画着的东西**：屏已经不看这一路了，屏上那份已知状态仍然是已知状态。
    private func stopJobPoll() {
        jobPollToken += 1
        jobPollTask?.cancel()
        jobPollTask = nil
    }

    /// 循环本体。**这里没有任何判据**：什么时候写、写哪几个面、什么时候停，
    /// 一律问 `SessionJobPollReconcile.decide`（用例在 CovaCore 钉着），本方法只执行赋值。
    ///
    /// 节拍复用 `StudioCreatePollSchedule`（19 屏那本账：前 6 次 5s、之后 10s、上限约 30min），
    /// 不发明第二套表。第一趟**先等一个节拍**再投：载荷刚到就再投一次，只是把刚读到的东西
    /// 再读一遍（服务端那一趟还会替我们 `refreshGenerationJob`，不免费）。
    private func runJobPoll(jobID: String, tracked: GenerationJobStatus?, token: Int) async {
        let schedule = StudioCreatePollSchedule()
        var previous = tracked
        var attempt = 1
        while !Task.isCancelled {
            // 空观测 = 这一趟还没投。判决在这一次调用里回答"还该不该发"：
            // 到上限（`.capReached`）或流已经接管这一轮（`.streamOwnsRound`）都会停。
            let gate = SessionJobPollReconcile.decide(
                previous: previous, observation: .nothingRead,
                streamMidRound: busy, attempt: attempt, schedule: schedule
            )
            if gate.stops {
                // `.capReached` 这一档**什么都不写、也什么都不说**：服务端可能仍在跑，
                // 屏上保持最后一次已知状态。把"我没再读到"讲成"这一轮没能完成"是把
                // 观察者的预算冒充成被观察者的结论（19 屏那一档叫 `.unconfirmed`，
                // 而本屏连这一句都不需要 —— 屏上确实没有新事实）。
                return
            }
            try? await Task.sleep(
                nanoseconds: UInt64(schedule.interval(forAttempt: attempt) * 1_000_000_000)
            )
            guard token == jobPollToken, !Task.isCancelled else { return }
            // 单次读不到不终止整条腿（网络抖动不等于任务失败，19 屏同一口径），
            // 也不许它改屏上任何东西 —— 所以这里连 `catch` 都不必分支，只把"没读到"交给判决。
            let polled = try? await session.studioCreateService.generationJob(id: jobID)
            // 号对不上 ⇒ 这一趟属于已经被取代的那条腿：一个字都不写（`await` 已经回来的
            // 那一趟不受 `cancel()` 影响，所以这一道比较是必需的，不是双保险）。
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
    private func applyJobPoll(
        _ decision: SessionJobPollReconcile.Decision, polled job: GenerationJobDto?
    ) {
        if decision.writesJob, let job {
            // **整行**换上屏是有依据的：两个端点是同一个投影函数
            // （`projectGenerationJob = { ...withPlayableAudio(job), ...timing }` ——
            // `web/src/app/api/find-my-song/generation-jobs/route.ts:26-32` 与
            // `web/src/app/api/find-my-song/sessions/[id]/route.ts:40-46` 逐字相同，
            // 2026-09-27 真实账号双向只读 GET 实测同一个 succeeded 任务：键集合差为空、
            // 除签名地址一族外所有同名键逐字节相等）。核对记录全文在
            // `CovaCore/SessionJobPollReconcile.swift` 文件头。
            latestJob = job
        }
        if decision.writesCandidates, let job {
            let fresh = job.candidates()
            // 判决只会在"行里真的带着非空候选"时放行这一维（文件头事实二：submitted 那一行
            // 没有 `candidates` 键、重试那一行显式写 `[]`）⇒ 这里不可能拿空清单洗屏。
            // 再比一次才赋值：♡ 的乐观值经不起 5 秒一次的重播种，而"清单其实没变"是常态。
            if fresh != candidates {
                candidates = fresh
                // 清单换成服务端这一份 ⇒ ♡ 账与"已经问过挑哪一版"照 `openSession` 的同一口径
                // 重播种 / 作废：留着上一份清单上的乐观值或选择钮，就是让用户按着
                // 已经被后端改掉的清单继续操作。
                favorites.reseed(from: fresh)
                choosingVersion = false
            }
        }
        // 终态**只**走这条已有的收口腿：08 那一格的环收口 + `StudioNotifier.reconcileTerminal`。
        // 不在这里另发一次通知、也不在这里改屏上的失败话术（那一份仍归载荷）。
        if decision.settles { syncStudioJobLedger() }
    }

    /// §3-I 的形态：左文案（`type.subhead` / `color.secondary`）+ 右列（`type.mono` / `color.muted`）
    /// + 4pt 细轨道（`color.line`）配 `color.accent` 填充。
    ///
    /// **右列印什么由数据决定**（`rightColumnText`，CovaCore 那一层裁决）：
    /// 拿到 `session.workflowState`（2026-09-24 实测存在的 JSON 字符串）⇒ 印 §3-I 要的**百分比**，
    /// 分子是「5 个交付组收口了几组」，轨道**可以**走到 100%（那时左列说「已完成」）；
    /// 拿不到 ⇒ 退回旧的「第几格 / 共几格」计数且**不填满** —— 那时候确实没有可印的数字，
    /// 旧注释里"不印猜出来的数字"那一句在这一条腿上仍然成立。
    /// （旧版把这格写死成 `7/9` 且声明永不填满，是因为当时**没建模** `workflowState` 那个键，
    /// 把"客户端没读"当成"后端没有" —— 见 `DeliveryProgress.swift` 开头的 E5 更正与 NEEDS-25。）
    private func deliveryProgressBar(_ progress: DeliveryProgress) -> some View {
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
            // TG-23：细进度条的厚度档未入库 ⇒ 这里是 spec 点名的那个缺口，不是随手写的数。
            .frame(height: 4)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
        // §7：整条合成**一个**元素，读「补充制作中，第 N 步，共 M 步」；
        // 值变化不逐帧播报（SwiftUI 只在元素被聚焦时读当前值），轨道本身不再单独念。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.voiceOverLabel)
    }

    // MARK: 输入框

    private var composer: some View {
        VStack(spacing: CovaSpace.sm) {
            HStack(spacing: CovaSpace.sm) {
                CovaChip("深度思考", isSelected: deepThinking) { deepThinking.toggle() }
                Spacer()
                if busy {
                    Button("停止生成") {
                        Task {
                            await session.cancelStudioStream()
                            // 用户说停 ⇒ 本机这一路的在途账当场收口（08 §3.C 的环与竖条同灭）。
                            // 只清本机这一条，不替后端断言任务结束了：屏上其余事实仍以下次读为准。
                            session.settleStudioJob(sessionID: sessionID)
                        }
                    }
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
            }
            HStack(spacing: CovaSpace.sm) {
                TextField("想听什么？找歌或做歌，一句话搞定", text: $draft)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .padding(CovaSpace.md)
                    .background(
                        RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                            .fill(CovaColor.surface)
                    )
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CovaColor.accentText)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(CovaColor.accent))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                .opacity(draft.isEmpty ? 0.4 : 1)
            }
        }
        .padding(CovaSpace.pageGutter)
        .background(CovaColor.canvas.opacity(0.95))
    }

    // MARK: 行为

    private func openSession() async {
        phase = .loading
        do {
            async let detail = session.studio.session(sessionID)
            async let cards = session.studio.planCards(sessionID: sessionID)
            let result = try await detail
            // 同屏的 `reconcileRound`(:332) 与 `start`(:861) 都是 `if let` —— 取不到就保留上一份好值；
            // 这一条以前 `?? []` 把一次抖动变成"计划卡消失 + 没有任何错误"（第 20 轮 R20-6）。
            let planList = ((try? await cards) ?? nil) ?? plans
            lines = result.messages.compactMap { message in
                guard let text = message.displayText else { return nil }   // 取不到正文就跳过
                lineCounter += 1
                return TranscriptLine(
                    id: lineCounter,
                    kind: message.isFromUser ? .user(text) : .agentText(text)
                )
            }
            plans = planList
            let jobs = result.generationJobs
            latestJob = jobs.last
            candidates = jobs.last?.candidates() ?? []
            // 09 §3-I 的进度阶梯：整包重播，不保留上一轮的格位（同上 ♡ 账口径）。
            workflow = result.session?.decodedWorkflowState()
            // 服务端为事实源（PRD 4.2）⇒ 载荷一到就以它重播 ♡ 账，不保留上一轮的乐观值。
            favorites.reseed(from: candidates)
            // 「已经问过要挑哪一版」是**本轮界面**的临时态：重新对账后不得继续亮着选择钮，
            // 否则用户可能按着一份已经被后端改掉的候选清单往下选。
            choosingVersion = false
            await refreshBalance()
            phase = .ready            // 这份载荷是权威状态 ⇒ 顺手把 08 那一格的在途账对齐（收口/推进读数，不新发请求）。
            syncStudioJobLedger()
            // 这一路若还挂着未终态的那一行，就从这一刻起按节拍读它（§5 P1-5）：
            // 载荷是这一路的基准，所以**每次**载荷到达都重新起腿（旧号作废）。
            restartJobPoll()
            // 首页输入卡带过来的一句话：进屏后自动发一次（01 §2「提交后跳转创作会话详情」）。
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

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await submit(text)
    }

    /// 把**一句话**送进 agent 并消费回流帧。输入框那句话与「选这版继续制作」走同一条腿 ——
    /// 契约里只有这一个能携带本轮意图的通道（见 `chooseVersion` 的逐条核对），
    /// 所以两条路径共用同一套流处理，不各写一份。
    private func submit(_ text: String) async {
        busy = true
        defer { busy = false }
        // 一轮流起来 ⇒ 这一轮的主人换成流：正在途的那趟轮询回来也只能丢（号在这里作废）。
        stopJobPoll()
        append(.user(text))
        agentBuffer = ""
        thinkingSteps = 0
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
            // 降级之后仍然拿不到（轮询也失败）⇒ 说「自动刷新也拿不到」，而不是通用报错。
            let state = await session.studioStreamState()
            if state.phase == .polling {
                degradeLabel = "自动刷新也拿不到，检查网络后点重试"
            } else {
                append(.system("这次没有成功：\(StudioService.classify(error).uiMessage)"))
            }
        }
        await refreshDegradation()
        if await session.studioStreamState().phase == .finished { runLabel = nil }
        // 流读完这一轮 ⇒ 主人交还给"下一次读"：这时才允许重新起腿。
        // `busy` 在这里显式落回 false（上面那道 `defer` 仍在，重复赋 false 是幂等的）——
        // 不显式落就永远起不来：`canArm` 的第一条就是"流正读着这一轮不起腿"，
        // 而 defer 要到本函数返回之后才跑。
        busy = false
        restartJobPoll()
    }

    /// 降级条的文案**由状态机的事实决定**（09 §B）：阶段 + 触发原因，不靠猜。
    private func refreshDegradation() async {
        let state = await session.studioStreamState()
        guard state.phase == .polling, let trigger = state.trigger else {
            if state.phase == .streaming || state.phase == nil { degradeLabel = nil }
            return
        }
        switch trigger {
        case .firstEventTimeout: degradeLabel = "连接较慢，正在等待 Cova 回应"
        case .silenceTimeout: degradeLabel = "连接中断，已切为自动刷新"
        case .malformedEvents: degradeLabel = "连接不稳定，已切为自动刷新"
        case .eofBeforeDone: degradeLabel = "本轮回复未结束，正在继续获取"
        }
    }

    private func consume(_ frame: CovaSSEFrame) async {
        switch frame.event {
        case .text:
            if let chunk = Self.decodeText(frame.payload) {
                agentBuffer += chunk
                replaceLatestAgentText(agentBuffer)
            }
        case .thinking:
            thinkingSteps += 1
            appendOrReplaceThinking(steps: thinkingSteps)
        case .planCard:
            if let cards = Self.decodeCards(frame.payload) {
                plans = cards
                plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
                // 计划卡就是这一路"走到哪一格"的权威更新点 ⇒ 顺手对齐 08 的在途账读数。
                syncStudioJobLedger()
            }
        case .error:
            append(.system("这一步暂时卡住了，可以重新描述需求再来一次"))
        case .done:
            degradeLabel = nil
        case .runLifecycle(let name):
            // 只保留**唯一一条** run 行；未知 run_* 不显示、也不算坏事件。
            if let label = Self.runLabel(name) { runLabel = label; appendOrReplaceRun(label) }
        case .unknown:
            break
        }
    }

    private static func runLabel(_ raw: String) -> String? {
        switch raw {
        case "run_started": return "开始处理"
        case "reasoning_summary": return "正在判断"
        case "run_waiting_user": return "等待你的决定"
        case "run_waiting_worker": return "歌曲制作中"
        case "run_completed": return "处理完成"
        case "run_failed": return "处理失败"
        default: return nil
        }
    }

    private static func decodeText(_ payload: Data) -> String? {
        (try? JSONDecoder().decode(CovaSSETextEventDto.self, from: payload))?.text
    }

    private static func decodeCards(_ payload: Data) -> [OneStepPlanCardDto]? {
        if let envelope = try? JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: payload) {
            return envelope.planCards
        }
        if let single = try? JSONDecoder().decode(OneStepPlanCardDto.self, from: payload) {
            return [single]
        }
        return try? JSONDecoder().decode([OneStepPlanCardDto].self, from: payload)
    }

    private func canStart(_ plan: OneStepPlanCardDto) -> Bool {
        PlanStatusCopy.canStart(plan.status)
            && plan.snapshotHash != nil
            && plan.sourceMessage?.messageId != nil
    }

    /// 歌词保存/重做之后，**后端回显的那一张卡**就是那张卡的最新事实 ⇒ 只换那一张。
    /// 不整表重排、不重读会话：那是把"我自己排的顺序"当成后端事实（本仓反复纠的那类）。
    private func applyPlanUpdate(_ updated: OneStepPlanCardDto) {
        if let index = plans.firstIndex(where: { $0.planCardId == updated.planCardId }) {
            plans[index] = updated
            return
        }
        plans.append(updated)
        plans.sort { ($0.cardIndex ?? 0) < ($1.cardIndex ?? 0) }
    }

    /// 余额位重读（写操作可能改账，09 §8「启动成功后强制刷新」同一口径）。
    /// 取不到就**留空不渲染**：NEEDS-3 明令「余额 M」在未知时不出现，更不许印 0。
    private func refreshBalance() async {
        creditsBalance = try? await session.catalog.me().entitlements.creditsBalance
    }

    private func start(_ plan: OneStepPlanCardDto) async {
        do {
            // 用户主动点的这一次 = 一次新的逻辑操作 ⇒ 由服务侧生成新 token；
            // 本屏**不做自动重放**（design 09：hash 失配后不得自动重发写操作）。
            let response = try await session.studio.startPlan(
                sessionID: sessionID, plan: plan,
                token: startTokens.token(
                    sessionID: sessionID, planCardID: plan.planCardId, revision: plan.revision ?? 0
                )
            )
            // **2xx 但没拿到任务号**：扣费可能已经发生，绝不能说"没提交成功"——
            // 那句话会诱导用户再点一次，而重试现在复用同一个幂等键（D8），
            // 所以后端会把它当同一次操作。这里改为去核对权威任务列表。
            guard let jobID = response.resolvedJobId else {
                append(.system("任务已提交，但没拿到任务编号，正在核对……"))
                await reconcileStartedJob(
                    sessionID: sessionID, planCardID: plan.planCardId, revision: plan.revision ?? 0
                )
                return
            }
            append(.system("已提交，正在排产"))
            // 这一路从这一刻起是"本机发起且未收口"⇒ 08 §3.C 那一格的环上。
            // 读数此刻还没有（`deliveryProgress` 只在补充制作窗口里出现），传 nil 就是
            // §3.C 那一档「生成中」，不是 0%。
            session.markStudioJobLive(sessionID: sessionID, progress: nil)
            // 这一行的任务号是**后端刚给的**，屏上那份载荷里还没有它 ⇒ 轮询跟的是这个号，
            // 而"屏上现在显示的状态"要如实报成未知（`tracked: nil`）：未知不是终态，
            // 拿上一轮那一行的终态去挡这一条腿，就等于把用户正等着的那一路排除在补腿之外。
            restartJobPoll(jobID: jobID, tracked: nil)
            // 授权时机：spec 明令**只在开始制作成功之后**索权；被拒不再反复索。
            if await StudioNotifier.requestPermissionAfterPlanStart() {
                await StudioNotifier.scheduleFallback(
                    sessionID: sessionID,
                    jobID: jobID,
                    planCardID: plan.planCardId,
                    afterMinutes: 30
                )
            }
            if let cards = try? await session.studio.planCards(sessionID: sessionID) { plans = cards }
            degradeLabel = "仍在处理刚才那句"
        } catch {
            append(.system("这次没提交成功：\(StudioService.classify(error).uiMessage)"))
        }
    }

    // MARK: 行内小工具（保持 lines 只有一条 agent 正文 / 一条 thinking / 一条 run）

    private func append(_ kind: TranscriptLine.Kind) {
        lineCounter += 1
        lines.append(TranscriptLine(id: lineCounter, kind: kind))
    }

    private func replaceLatestAgentText(_ text: String) {
        if let index = lines.lastIndex(where: { if case .agentText = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .agentText(text))
        } else {
            append(.agentText(text))
        }
    }

    private func appendOrReplaceThinking(steps: Int) {
        if let index = lines.firstIndex(where: { if case .thinking = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .thinking(stepCount: steps, expanded: false))
        } else {
            append(.thinking(stepCount: steps, expanded: false))
        }
    }

    private func appendOrReplaceRun(_ label: String) {
        if let index = lines.firstIndex(where: { if case .run = $0.kind { return true } else { return false } }) {
            lines[index] = TranscriptLine(id: lines[index].id, kind: .run(label))
        } else {
            append(.run(label))
        }
    }

    private static func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .unauthenticated: return .unauthenticated
        case .backendGap(let id): return .backendGap(id)
        }
    }
}

/// 计划卡（design 09 §G）。缺 `snapshotHash` / 归因 ⇒ 主按钮置灰，**不放宽**。
struct PlanCardView: View {
    let plan: OneStepPlanCardDto
    let sessionID: String
    let canStart: Bool
    let creditsBalance: Int?
    let onStart: () -> Void
    let onRevise: () -> Void
    /// 歌词编辑/重做拿到后端回显的那一张卡时，交回父层替换（**不在本卡里自存一份卡面**）。
    let onUpdated: (OneStepPlanCardDto) -> Void
    /// 重做可能改余额账 ⇒ 请父层重读一次（本屏不自己猜扣了多少）。
    let onBalanceOutOfDate: () -> Void
    @State private var promptExpanded = false

    var body: some View {
        CovaCard {
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                HStack(alignment: .top) {
                    Text(plan.title?.selected ?? plan.summary ?? "制作计划")
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    Spacer()
                    Text(PlanStatusCopy.label(plan.status))
                        .font(CovaType.caption)
                        .foregroundStyle(badgeColor)
                }
                if let analysis = plan.style?.analysisZh, !analysis.isEmpty {
                    Text(analysis).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
                if let promptEn = plan.style?.promptEn, !promptEn.isEmpty {
                    Button(promptExpanded ? "收起提示词" : "查看提示词") { promptExpanded.toggle() }
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    if promptExpanded {
                        Text(promptEn).font(CovaType.caption).foregroundStyle(CovaColor.muted)
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
                HStack {
                    if let credits = plan.credits {
                        Text("预计消耗 \(credits) co")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    }
                    if let balance = creditsBalance {
                        Text("余额 \(balance)")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: CovaSpace.sm) {
                    Button(action: onStart) {
                        Text(PlanStatusCopy.primaryAction(plan.status))
                            .font(CovaType.callout)
                            .foregroundStyle(canStart ? CovaColor.accentText : CovaColor.muted)
                            .padding(.horizontal, CovaSpace.lg).padding(.vertical, CovaSpace.sm)
                            .background(Capsule().fill(canStart ? CovaColor.accent : CovaColor.surface))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    Button("修改要求", action: onRevise)
                        .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    /// 参数胶囊的**取值与文案一律不在本屏拼**：裁决面在 CovaCore 的
    /// `OneStepPlanParameterCopy`（09 §3-G 的中文标签 + 百分数 + 「不认识的取值不渲染」三条口径，
    /// 那边有用例钉着），本屏只负责摆。
    /// 这里曾是「后端原值上屏」在本仓的第三处：上一版直接
    /// `chips.append("weirdness \(weirdness)")`，把英文键名和 0–1 原值一起印上屏
    /// （另两处 `LoginAndMine` 的 `plan.rawValue`、`status.rawValue` 同样是把判据挪进可测层才闭的）。
    /// 只由契约里真实存在的字段拼、一个都不发明；全取不到 ⇒ 空数组 ⇒ 整段不渲染。
    private func parameterChips(_ plan: OneStepPlanCardDto) -> [String] {
        OneStepPlanParameterCopy.chips(parameters: plan.parameters, type: plan.type)
    }

    /// 参数行的一枚 chip。09 §3-G 给的是**展示形态**（`type.caption` / `color.secondary` +
    /// `color.surface` 底），不是可点控件 ⇒ 不再借 `CovaChip(action:)`：
    /// 原先写的是 `CovaChip(chip, isSelected: false) {}`，一个 action 为空的按钮，
    /// VoiceOver 念它是"按钮"、按下什么都没有（本仓反对的就是这种假控件），字号也是 subhead 不是 caption。
    /// 横滑容器沿用原结构 —— §7「AX 档下参数 chips 换行」这一条**本轮未做**（要另起一个换行容器），
    /// 记在交付说明里，不在这一刀里静默扩大改动面。
    private func parameterChip(_ text: String) -> some View {
        Text(text)
            .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
            .padding(.horizontal, CovaSpace.md)
            .padding(.vertical, CovaSpace.xs)
            .background(Capsule().fill(CovaColor.surface))
            .fixedSize()
    }

    private var badgeColor: Color {
        switch plan.status {
        case .demosReady: return CovaColor.success
        case .manualRecovery, .retryableFailure: return CovaColor.error
        case .ready, .starting, .generating, .mediaStaging, .deliveryPreparing, .rehydrating:
            return CovaColor.warning
        case .analyzing, .patching, .archived:
            return CovaColor.muted
        }
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
                // 正文只印**后端给了**的那一份（不补占位、不印空行）。
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
    /// 不说任何"去哪补余额"的话。确认只此一次入口，失败也不自动重试（见 `regenerate`）。
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

    /// 回读版本清单（**只读**）。拿不到就停在"只报当前版"：这一格是可选项，
    /// 而写路径自己带 `expectedRevision` 基线，不靠这份清单保正确 ⇒ 不因此挡住编辑。
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
        // 先自核再出站：明知会被拒的写不发（也顺便不替服务端做它自己的判据）。
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
                self.editor = nil      // 草稿已成为后端事实 ⇒ 就地作废，卡面以回显为准
                phase = .saved
                onUpdated(card)
            case .landedWithoutEcho:
                self.editor = nil
                phase = .savedWithoutEcho
                notice = "改动已经保存，但这份响应没带回卡面；下拉刷新或下次进入才会看到新内容。"
            }
        } catch {
            // 失败**不动草稿**：一次抖动就把用户写的字洗掉，比不保存更糟。
            if let rejection = OneStepLyricsEditRejection.classify(error) {
                phase = rejection == .staleCard ? .stale : .failed
                notice = rejection.userCopy
            } else {
                phase = .failed
                notice = "这次没保存上：\(StudioService.classify(error).uiMessage)；你写的字还在草稿里。"
            }
        }
    }

    /// 重做整篇歌词。**必须先在 `confirmationDialog` 上按过「确认重做」**：
    /// 这一条按 token 实扣（`web/…/lyrics/regenerate/route.ts:34-60`）。
    /// 失败绝不自动重试，且两种"没扣成"分得开：402 是预检就拦下（一次模型调用都没发），
    /// 2xx 后 `insufficient:true` 是结算时扣不动。
    private func regenerate() async {
        guard let revision = plan.revision else {
            phase = .failed
            notice = OneStepLyricsEditingBlock.cardRevisionUnknown.userCopy
            return
        }
        phase = .regenerating
        notice = nil
        do {
            // 同一次确认的重发复用同一把键 ⇒ 后端按重放处理，不会扣第二次；
            // 成功之后 revision 前进，用户若真再重做一次自然换新键（那是一次新的计费）。
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
            onBalanceOutOfDate()   // 扣了钱就得重读余额（09 §8「启动成功后强制刷新」同口径）
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
    /// **有未保存改动时一律不覆盖**：只把"这一份基线已经不新鲜"说出来，让用户自己决定
    /// —— 静默用新载荷重建草稿，等于把用户刚写的字洗掉。
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
