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
        .onDisappear { Task { await session.cancelStudioStream() } }
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
                                canStart: canStart(plan),
                                creditsBalance: creditsBalance,
                                onStart: { Task { await start(plan) } },
                                onRevise: { draft = "请修改：" }
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
        // 「settled」只有一处定义（`DoubleDemoRule`，D7），终态条 / 主钮 / 这一行读同一本账；
        // 是否**可选**另说：占位卡与失败卡在操作条上不出选择钮（见 `versionChoice`）。
        let settled = DoubleDemoRule.isSettled(candidate)
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaListRow(
                title: candidate.title ?? "版本 \(index + 1)",
                subtitle: settled ? "可以试听" : "制作中",
                artwork: CovaArtwork(url: URL(string: candidate.coverUrl ?? ""), title: candidate.title ?? "")
            ) {
                Image(systemName: settled ? "play.circle" : "hourglass").foregroundStyle(CovaColor.muted)
            } action: {
                guard settled, let raw = candidate.audioUrl?.rawValue, let url = URL(string: raw),
                      let item = Self.playbackItem(for: candidate, url: url) else {
                    session.showToast("试听文件没取到，重试", isError: true)
                    return
                }
                Task { await session.play(items: [item], at: 0) }
            }
            candidateActionBar(
                candidate, index: index, ready: DoubleDemoRule.isReady(candidate), terminal: terminal
            )
        }
    }

    /// 候选卡底部操作条（09 §3-H 列了三件：♡ 收藏 / ↓ 下载 / ⤴ 分享）。
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
    @ViewBuilder
    private func candidateActionBar(
        _ candidate: GenerationCandidateDto, index: Int, ready: Bool, terminal: Bool
    ) -> some View {
        HStack(spacing: CovaSpace.sm) {
            // 「无 mediaReferenceId 时整钮不渲染」（09 §5 / §8）：不是 disabled，是不进视图树。
            if CandidateFavoriteLedger.canFavorite(candidate) {
                favoriteButton(candidate)
            }
            versionChoice(candidate, index: index, ready: ready, terminal: terminal)
            Spacer(minLength: 0)
        }
        .padding(.leading, CovaSpace.pageGutter)
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
            coverURL: URL(string: candidate.coverUrl ?? "").flatMap { try? AudioURL(https: $0) },
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
            candidates = newest.candidates()
            degradeLabel = nil
            append(.system("已核到任务：\(newest.status.rawValue)"))
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
    ///   §8 另给的 `GET …/generation-jobs?id=` 轮询节奏（前 6 次 5s、之后 10s）**本屏尚未接** ——
    ///   该端点目前全仓零调用点（DTO 有、服务方法没有），所以取消/失败这类只出现在 job 上的
    ///   事实要等下一次进屏 / 下拉刷新才会被看到。这是**客户端待办**，不是后端缺口，
    ///   也不拿轮询冒充：见 `docs/log` 当日「没做的（据实）」。
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
                    Button("停止生成") { Task { await session.cancelStudioStream() } }
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
            let planList = (try? await cards) ?? []
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
            creditsBalance = try? await session.catalog.me().entitlements.creditsBalance
            phase = .ready
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
    let canStart: Bool
    let creditsBalance: Int?
    let onStart: () -> Void
    let onRevise: () -> Void
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
                ForEach(Array(sectionsOf(plan).enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 2) {
                        // 段名与正文都只在**后端给了**的时候渲染（不补占位）。
                        if let label = section.label, !label.isEmpty {
                            Text(label).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                        }
                        if let text = section.text, !text.isEmpty {
                            Text(text).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                        }
                    }
                }
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

    private func sectionsOf(_ plan: OneStepPlanCardDto) -> [OneStepLyricsSectionDto] {
        (plan.lyrics?.sections ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }
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
