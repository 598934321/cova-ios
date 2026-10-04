import CovaCore
import CovaUI
import SwiftUI

// MARK: - 共用：计划卡 12 态的中文标签（design 09 §9 权威表）

/// 12 态 → 中文徽章文案。**不出现英文状态名**（spec 明令），未知值走「状态更新中」只读卡。
enum PlanStatusCopy {
    static func label(_ status: OneStepPlanStatus) -> String {
        switch status {
        case .analyzing: return "草拟中"
        case .ready: return "待确认"
        case .patching: return "修改中"
        case .starting: return "已启动"
        case .generating: return "生成中"
        case .mediaStaging: return "音频落位中"
        case .demosReady: return "Demo 就绪"
        case .deliveryPreparing: return "补充制作中"
        case .rehydrating: return "文件恢复中"
        case .manualRecovery: return "需人工处理"
        case .retryableFailure: return "未完成，可重试"
        case .archived: return "已归档"
        }
    }

    /// 「开始制作」是否可用：`ready` 可启动；`retryable_failure` 是「重新制作」
    /// （§9 行 11：幂等键**换新**，父层 `start()` 里 invalidate 同三元组）。
    /// 其余态一律禁用；归属校验 + snapshotHash 在视图层另算（两者缺一照样置灰）。
    static func canStart(_ status: OneStepPlanStatus) -> Bool {
        status == .ready || status == .retryableFailure
    }

    /// 「修改要求」是否可用（§9 第四列）：`analyzing / ready / demosReady / retryableFailure`
    /// 四态可点，其余禁用 —— 终态/在途态下"改要求"要么没意义要么会撞正在执行的写。
    static func canRevise(_ status: OneStepPlanStatus) -> Bool {
        switch status {
        case .analyzing, .ready, .demosReady, .retryableFailure: return true
        case .patching, .starting, .generating, .mediaStaging,
             .deliveryPreparing, .rehydrating, .manualRecovery, .archived:
            return false
        }
    }

    /// 主按钮文案：`retryable_failure` 时是「重新制作」（并换新幂等键，见 StudioService）。
    static func primaryAction(_ status: OneStepPlanStatus) -> String {
        status == .retryableFailure ? "重新制作" : "开始制作"
    }
}

/// 09 §3.F 的 `run_*` 事件 → 屏上那一行的**唯一映射表**（spec：本屏只允许这一张表）。
/// 表外事件名返回 nil = 「不显示、保持『处理中』不回落」，且不算坏事件（坏事件口径
/// 归解析器 `isMalformed`，不归这里）。
enum RunLineCopy {
    /// 行的三要素：短语 + SF Symbol + 语义色档。`Color` 不进这层（它属于展示层），
    /// 用这个小枚举把色意图带给视图（muted/warning/success/error 四档就是 §3.F 的色列）。
    struct Spec: Equatable {
        let label: String
        let symbol: String
        let tint: Tint
    }
    enum Tint: Equatable { case muted, warning, success, error }

    /// SSE `event:` 名 → 行内容。**逐字**对应 spec §3.F 那张表；默认 nil（未知名不显示）。
    static func line(forEvent name: String) -> Spec? {
        switch name {
        case "run_started": return Spec(label: "开始处理", symbol: "sparkles", tint: .muted)
        case "reasoning_summary": return Spec(label: "正在判断", symbol: "brain.head.profile", tint: .muted)
        case "run_waiting_user":
            return Spec(label: "等待你的决定", symbol: "person.crop.circle.badge.questionmark", tint: .warning)
        case "run_waiting_worker": return Spec(label: "歌曲制作中", symbol: "hammer", tint: .muted)
        case "run_completed": return Spec(label: "处理完成", symbol: "checkmark.circle", tint: .success)
        case "run_failed": return Spec(label: "处理失败", symbol: "xmark.octagon", tint: .error)
        default: return nil
        }
    }

    /// `run_completed` 的那一行在到达终态后 3s 淡出（§3.F 表注）。其余态不自动消失。
    static func fadesOut(forEvent name: String) -> Bool { name == "run_completed" }

    /// run 恢复轮询那一腿的 `run.status` → 等价的 SSE 事件名（`nil` = 在途态，
    /// §3.F 对没进表的状态一律"不显示、保持上一条"）。映射完仍走 `line(forEvent:)` 渲染，
    /// 两端同一张文案表，不长出第二份短语。
    static func event(forStatus status: String) -> String? {
        switch status {
        case "waiting_user": return "run_waiting_user"
        case "waiting_worker": return "run_waiting_worker"
        case "completed": return "run_completed"
        case "failed": return "run_failed"
        default: return nil
        }
    }

}

/// 08 §4 与 09 §4.1「空会话引导」共用的三枚示例 prompt（spec 点名「08 §4 同源常量」
/// ⇒ 一份字面量、两处引用，不再各写一份漂移）。
enum StudioStarterChips {
    static let prompts = [
        "做一首夏日广告配乐，30 秒，轻快",
        "来一段适合深夜写作的纯音乐",
        "给短视频做一首中国风 BGM",
    ]
}

/// 流式过程的一行（09 的渲染单元）。**不持久化任何音频地址**（硬边界 3）。
struct TranscriptLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case agentText(String)
        /// `steps` = 逐条公开短语（已过 `OneStepThinkingCopy` 裁决，内部词到不了这层）；
        /// `stalled` = §4.2 触发 2/3 的「（已停止更新）」定格标记。
        case thinking(steps: [String], stalled: Bool)
        /// 运行状态行存**事件名**（不是短语）：§3.F 的符号/色/淡出都按事件名判，
        /// 展示前走 `RunLineCopy.line(forEvent:)`。
        case run(event: String)
        case plan(String)          // 计划卡 id，卡片本体由 plans 渲染
        /// 中性行内句（caption/muted）：流程读数与引导语走这一条。
        case system(String)
        /// 写操作失败的行内错句（caption/error）：只承载"本会话内可修复的失败"。
        case systemError(String)
    }
    let id: Int
    let kind: Kind
}

// MARK: - 08 创作会话列表

/// 创作会话列表（design 08）。
/// 三条 spec 硬约束落进代码：**没有删除/重命名**（契约无端点 ⇒ 手势、菜单、VoiceOver
/// 元素一律不出现）；**不做 N+1**（列表就是列表，不逐行去拉详情）；**不发明字段**。
/// 进度环只由**本机本次运行**里在途的任务点亮（冷启动没有这个事实 ⇒ 不显示，不猜）。
public struct AISessionsView: View {
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var sessions: [StudioSessionDto] = []

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init() {}

    public var body: some View {
        content
            .covaPage()
            .navigationTitle("创作")
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新会话") { Task { await startNewSession() } }
                        .foregroundStyle(CovaColor.accent)
                }
                // 19 §1 入口①：创作台与「跟它聊」是**两条通道**（`studio/create/generate`
                // 直下任务 vs `studio/agent` 的 SSE 会话），所以两个钮并列、各说各的话，
                // 不把「做歌」塞进新会话的流程里（那会让用户以为它也是聊出来的）。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("直接做歌") { session.push(.studioCreate) }
                        .foregroundStyle(CovaColor.accentText)
                }
            }
            .task { await load() }
            .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            // 骨架 5 行；**不给进度环打骨架**（环是事实，不是装饰）。
            CovaSkeleton(rows: 5).padding(.top, CovaSpace.lg)
        case .failed(let failure):
            CovaErrorState(kind: Self.kind(failure)) { Task { await load() } }
        case .ready:
            if sessions.isEmpty {
                VStack(spacing: CovaSpace.lg) {
                    CovaEmptyState(
                        symbol: "sparkles",
                        title: "还没有你的创作",
                        hint: "一句话就能开始：说场景、说情绪、说时长",
                        actionTitle: "开始新会话",
                        action: { Task { await startNewSession() } }
                    )
                    VStack(alignment: .leading, spacing: CovaSpace.sm) {
                        Text("试试这些说法").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                        ForEach(StudioStarterChips.prompts, id: \.self) { chip in
                            CovaChip(chip, isSelected: false) {
                                session.pendingPrompt = chip
                                Task { await startNewSession() }
                            }
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // §3.C 行间分隔：`color.lineSubtle` 1pt（TG-04），**首行不加**。
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle()
                                    .fill(CovaColor.lineSubtle)
                                    .frame(height: SessionRowMetrics.separatorHeight)
                            }
                            row(item)
                        }
                        Text("已显示全部")
                            .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CovaSpace.lg)
                    }
                }
            }
        }
    }

    private func row(_ item: StudioSessionDto) -> some View {
        let ring = liveRing(for: item)
        return SessionRow(item: item, ring: ring, trailing: {
            HStack(spacing: CovaSpace.xs) {
                // §3.C「进度环在 ⋯ 左」；而 ⋯ 菜单在删除/重命名端点未文档化期间**整项不渲染**
                // （§7 + 待裁决 4）⇒ 状态区今天只有环。行尾那枚 chevron 是「整行可点」的提示，
                // 不是一枚控件，也不进 VoiceOver 元素序列（整行只有一个元素，§6）。
                if StudioSessionProgressRing.showsInProgressBar(of: ring) {
                    SessionProgressRing(ring: ring)
                }
                Image(systemName: "chevron.right").foregroundStyle(CovaColor.muted)
            }
        }, action: {
            session.push(.aiSession(item.id))
        })
    }

    /// 08 §数据源行 140 只承认**一个**进行中来源：本设备内存里未终态的 job（由 09 的发起者持有）。
    ///
    /// 那一本账就是 `AppSession.liveStudioJobs`（会话号 → 未终态进度，`nil` = 有 job 无读数）：
    /// 09 在 `beginStudioStream` 与计划卡刷新处写，终态/停止/登出/换号处清。
    /// 这里**只读**：不逐行发详情请求（N+1 禁令）、也不从 `updatedAt` 之类推出"应该在跑"。
    /// 冷启动账本是空的 ⇒ 每一行都落 `.idle`（环、2pt 竖条、「生成中」三者都不出现），
    /// 这一档按 §9 判据第 3 条是**正确行为**，不是待补的显示缺陷。
    private func liveRing(for item: StudioSessionDto) -> StudioSessionRing {
        session.liveStudioJobs.studioRing(for: item.id)
    }

    /// 建会话再进详情；失败点名 NEEDS-23（会话条目 schema 未文档化）。
    private func startNewSession() async {
        guard session.requireLoginForCollections() else { return }
        do {
            let id = try await session.studio.createSession()
            // pendingPrompt 由 09 进屏后消费并清空（示例 chip 点进来时带着那句话）；
            // 这里不清，否则 chip 白点。
            session.push(.aiSession(id))
        } catch {
            session.showToast("会话没建起来：\(StudioService.classify(error).uiMessage)", isError: true)
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

    private func load() async {
        phase = .loading
        do {
            sessions = try await session.studio.sessions()
            phase = .ready
        } catch {
            phase = .failed(StudioService.classify(error))
        }
    }
}

// MARK: - 08 §3.C 会话行（SessionRow）

/// 会话行的几何档（08 §3.C + §6 + §8）。**每个数都点名 spec 或 token 缺口**，
/// 因为 §9 的判据就是「抽查进度环线宽、行内边距、胶囊高度」——抽查要能在源码里找到出处。
enum SessionRowMetrics {
    /// §3.C：封面 48 方；§6 的 AX 档收至 `spacing.xxl`+`spacing.lg` = 48 ⇒ **同一档**，不两值。
    static let coverSide: CGFloat = 48
    /// §3.C / TG-19：行最小高 64。
    static let minRowHeight: CGFloat = 64
    /// §3.C / TG-18：进度环直径 20。
    static let ringDiameter: CGFloat = 20
    /// §3.C / TG-04：进度环线宽 2。
    static let ringLineWidth: CGFloat = 2
    /// §3.C / §5 / components §7：进行中行的左缘竖条 2pt（与抽屉选中指示条同规格）。
    static let inProgressStripWidth: CGFloat = 2
    /// §3.C / TG-04：行间分隔 1pt。
    static let separatorHeight: CGFloat = 1
    /// §4：Reduce Motion 下那条不确定条的高。
    static let fallbackBarHeight: CGFloat = 2
    /// 无定值时环上那段可见弧的比例。**不是进度读数** —— 这一档就是「没有可报的百分比」，
    /// 弧只是让「环在转」这件事看得见（§3.C 环内不放百分数）。
    static let indeterminateSweep: CGFloat = 0.25
    /// 一圈 / 一次扫动的时长：tokens 里**没有**「无限旋转周期」与「一次性进度条时长」两档
    /// （08 的 Token 缺口表也没给），故取已有的最长一档 `motion.duration.hero` = 700ms，
    /// 而不是新造一个数。
    static let sweepDuration: Double = 0.7
}

/// 08 §3.C 的会话行，12c §3.D **完全复用**同一份几何（差异只有尾饰与左滑）。
///
/// 为什么不走 `CovaListRow`：那一支是通用曲目行几何 —— 封面 44 + `radius.control − 4` +
/// 标题 `type.body` + 两行文本，而 §3.C 要的是 48 + `radius.control` + `type.headline`
/// + **第三条时间线** + 最小高 64 + 2pt 进行中竖条。CovaUI 不在本批可改面内，
/// 所以几何先落在屏侧（要不要抬进 `CovaListRow` 由协调者裁决，别在这里替它决定）。
struct SessionRow<Trailing: View>: View {
    private let item: StudioSessionDto
    private let ring: StudioSessionRing
    @ViewBuilder private let trailing: Trailing
    private let action: () -> Void
    /// §6 Dynamic Type：AX 档下摘要 1→2 行、时间移到标题行右端。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        item: StudioSessionDto,
        ring: StudioSessionRing,
        trailing: () -> Trailing,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.ring = ring
        self.trailing = trailing()
        self.action = action
    }

    private var relativeTime: String? {
        // §数据源行 138：时间拿不到 ⇒ **整条不渲染**（不显示「—」噪声）。
        StudioRelativeTime.text(item.updatedAt ?? item.createdAt, now: Date(), calendar: .current)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: CovaSpace.md) {
                SessionCoverSlot(
                    serverValue: StudioSessionCover.usableCover(item.firstCoverUrl),
                    title: item.displayTitle
                )
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    // §6：AX 档把时间搬到标题行右端，避免「标题/摘要/时间」三块同时长高。
                    if axLayout {
                        HStack(alignment: .firstTextBaseline, spacing: CovaSpace.sm) {
                            title
                            Spacer(minLength: CovaSpace.xs)
                            if let time = relativeTime { timeText(time) }
                        }
                    } else {
                        title
                    }
                    if let summary = item.displaySummary {
                        Text(summary)
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                            .lineLimit(axLayout ? 2 : 1)   // §8 / TG-17
                    }
                    if !axLayout, let time = relativeTime { timeText(time) }
                    // §4：Reduce Motion 时不确定环退化为静态环 **+ 一条一次性 2pt 高的不确定条**。
                    if StudioSessionProgressRing.showsIndeterminateFallbackBar(of: ring, reduceMotion: reduceMotion) {
                        OneShotIndeterminateBar().frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: CovaSpace.sm)
                trailing
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.md)
            .frame(minHeight: SessionRowMetrics.minRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            // §3.C / §5：进行中行的左缘 2pt `color.accent` 竖条（与环同判据、同色值，双主题同值）；
            // **不**用底色高亮 —— 底色留给「当前所在会话」的一次性高亮，那个信号要 09 回传，本批没有来源。
            .overlay(alignment: .leading) {
                if StudioSessionProgressRing.showsInProgressBar(of: ring) {
                    Rectangle()
                        .fill(CovaColor.accent)
                        .frame(width: SessionRowMetrics.inProgressStripWidth)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        // §6：**整行一个可聚焦元素**，复合标签「<标题>，<摘要>，<相对时间>，生成中，约 68%」；
        // 环与竖条都不单独占焦点（旋转动画上重复播报是 §6 行 117 明令要避免的）。
        .accessibilityLabel(
            StudioSessionProgressRing.rowVoiceOverLabel(
                title: item.displayTitle,
                summary: item.displaySummary,
                relativeTime: relativeTime,
                ring: ring
            )
        )
    }

    private var title: some View {
        Text(item.displayTitle)
            .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            .lineLimit(axLayout ? 2 : 1)   // §3.C 标题 1 行；TG-17 的 AX 档给 2 行
    }

    private func timeText(_ time: String) -> some View {
        Text(time).font(CovaType.caption).foregroundStyle(CovaColor.muted)
    }
}

/// §3.C 的 48 方封面槽：`firstCoverUrl` **有值才上图**，没值仍然是 §3.C 行 62 的那枚符号。
///
/// 为什么"没值"这一支必须长期留着（不是保守，是实测）：2026-09-26 用 owner 给的测试账号读线上
/// 列表，5 条会话（全 `workflowMode:"one-step"`）的 `firstCoverUrl` 逐条是 `null`。
/// 地址一律走 `CovaArtworkResolution(serverValue:)` —— 站内相对补全、查询串**逐字节**带走、
/// host 出口名单裁决三件事都只在那一道里（D23；`%2B` 那个缺陷就是从这里绕过去才发生的），
/// 这里不 `URL(string:)`、不裁剪查询、也不为封面逐行补发详情请求（§数据源行 140 禁 N+1）。
struct SessionCoverSlot: View {
    private let resolution: CovaArtworkResolution
    private let title: String

    init(serverValue raw: String?, title: String) {
        self.resolution = CovaArtworkResolution(serverValue: raw)
        self.title = title
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                .fill(CovaColor.surface)
            switch resolution {
            case .absent:
                // 「这一行没给封面」= 正确行为 ⇒ §3.C 的符号占位。
                Image(systemName: StudioSessionCover.placeholderSymbol)
                    .foregroundStyle(CovaColor.accentText)
            case .resolved, .refused:
                // `.refused` 不在这里改写成占位：出口拒绝必须长得跟"没图"不一样（R18-2），
                // 那一档由 `CovaArtwork` 自己画警示三角并在标签里点名 host。
                CovaArtwork(resolution: resolution, title: title)
            }
        }
        .frame(width: SessionRowMetrics.coverSide, height: SessionRowMetrics.coverSide)
        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous))
        // §6：整行单元素 ⇒ 封面不单独占焦点（标题已经在行标签里）。
        .accessibilityHidden(true)
    }
}

/// §3.C 的 20pt 进度环：轨道 `color.line`、进度 `color.accent`、线宽 2（TG-04）。
/// 环内**不放百分数**（空间不足，§3.C），百分比只进行标签（§6）。
struct SessionProgressRing: View {
    private let ring: StudioSessionRing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    init(ring: StudioSessionRing) { self.ring = ring }

    var body: some View {
        ZStack {
            Circle()
                .stroke(CovaColor.line, lineWidth: SessionRowMetrics.ringLineWidth)
            Circle()
                .trim(from: 0, to: StudioSessionProgressRing.arcFraction(of: ring) ?? SessionRowMetrics.indeterminateSweep)
                .stroke(
                    CovaColor.accent,
                    style: StrokeStyle(lineWidth: SessionRowMetrics.ringLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(
            width: SessionRowMetrics.ringDiameter,
            height: SessionRowMetrics.ringDiameter
        )
        // §6 行 117：环**不设独立可聚焦元素**，数值并进行标签。
        .accessibilityHidden(true)
        .onAppear {
            guard StudioSessionProgressRing.spins(of: ring, reduceMotion: reduceMotion) else { return }
            // §4：Reduce Motion 下不转（静态环 + 不确定条那一档由行负责）。
            withAnimation(.linear(duration: SessionRowMetrics.sweepDuration).repeatForever(autoreverses: false)) {
                turning = true
            }
        }
    }
}

/// §4 行 101：Reduce Motion 时替代旋转环的那条**一次性** 2pt 高不确定进度条。
/// 「一次性」是硬要求：`repeatForever` 在这一档就是违规。
struct OneShotIndeterminateBar: View {
    @State private var swept = false

    var body: some View {
        GeometryReader { proxy in
            let segment = max(8, proxy.size.width / 3)
            ZStack(alignment: .leading) {
                Capsule().fill(CovaColor.line)
                Capsule()
                    .fill(CovaColor.accent)
                    .frame(width: segment)
                    .offset(x: swept ? max(0, proxy.size.width - segment) : 0)
            }
        }
        .frame(height: SessionRowMetrics.fallbackBarHeight)
        .onAppear {
            withAnimation(.easeOut(duration: SessionRowMetrics.sweepDuration)) { swept = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 12c 我的创作

/// 我的创作（design 12c）：08 的只读前 3 行 + 「查看全部创作」。
/// 摘要只显**取得到的**计数：`N 个作品` 没有端点 ⇒ 整段不渲染（连标题也不出现），
/// 「收藏的版本」同理。
public struct MyCreationsView: View {
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var sessions: [StudioSessionDto] = []

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init() {}

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                CovaSkeleton(rows: 4)
            case .failed(let failure):
                CovaErrorState(kind: Self.kind(failure)) { Task { await load() } }
            case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: CovaSpace.lg) {
                    Text("\(sessions.count) 个会话")
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        .padding(.horizontal, CovaSpace.pageGutter)
                    CovaSectionHeader("最近创作")
                    if sessions.isEmpty {
                        CovaEmptyState(
                            symbol: "sparkles",
                            title: "还没有你的创作",
                            hint: "一句话就能开始：说场景、说情绪、说时长",
                            actionTitle: "开始新会话",
                            action: { session.navigate(to: .aiSessions) }
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.prefix(3).enumerated()), id: \.element.id) { index, item in
                                // §3.D 连分隔线一起复用：1pt `color.lineSubtle`，首行不加。
                                if index > 0 {
                                    Rectangle()
                                        .fill(CovaColor.lineSubtle)
                                        .frame(height: SessionRowMetrics.separatorHeight)
                                }
                                // 12c §3.D：**完全复用** 08 §3.C 的行（48 封面、相对时间、最小高 64、
                                // 1pt 分隔），差异只有「不渲染 ⋯ 与左滑」⇒ 尾饰给空。
                                // 环同样读同一本账（`liveStudioJobs`）：12c 与 08 共用数据源，
                                // 也共用"只有本机在途的 job 才配一格进行中"这一条判据。
                                SessionRow(
                                    item: item,
                                    ring: session.liveStudioJobs.studioRing(for: item.id),
                                    trailing: { EmptyView() }
                                ) {
                                    session.navigate(to: .aiSession(item.id))
                                }
                            }
                        }
                        if sessions.count > 3 {
                            Button("查看全部创作") { session.navigate(to: .aiSessions) }
                                .font(CovaType.callout).foregroundStyle(CovaColor.accent)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, CovaSpace.lg)
            }
            }
        }
        .covaPage()
        .navigationTitle("我的创作")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private static func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .unauthenticated: return .unauthenticated
        case .backendGap(let id): return .backendGap(id)
        }
    }

    private func load() async {
        phase = .loading
        do {
            sessions = try await session.studio.sessions()
            phase = .ready
        } catch {
            phase = .failed(StudioService.classify(error))
        }
    }
}

extension CatalogFailure {
    /// 错误态要说人话（design 17）。
    var uiMessage: String {
        switch self {
        case .network: return "网络不通"
        case .server(let detail): return detail
        case .unauthenticated: return "登录状态已过期，请重新登录"
        case .backendGap(let id): return "后端字段缺口（\(id) 已登记）"
        }
    }
}
