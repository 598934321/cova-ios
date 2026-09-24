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

    /// 「开始制作」是否可用：**只有 `ready`**，且必须已归因 + 带 snapshotHash（不放宽）。
    static func canStart(_ status: OneStepPlanStatus) -> Bool { status == .ready }

    /// 主按钮文案：`retryable_failure` 时是「重新制作」（并换新幂等键，见 StudioService）。
    static func primaryAction(_ status: OneStepPlanStatus) -> String {
        status == .retryableFailure ? "重新制作" : "开始制作"
    }
}

/// 流式过程的一行（09 的渲染单元）。**不持久化任何音频地址**（硬边界 3）。
struct TranscriptLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case agentText(String)
        case thinking(stepCount: Int, expanded: Bool)
        case run(String)
        case plan(String)          // 计划卡 id，卡片本体由 plans 渲染
        case system(String)
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
    @State private var inFlightTitles: Set<String> = []

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init() {}

    public var body: some View {
        content
            .covaPage()
            .navigationTitle("创作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新会话") { Task { await startNewSession() } }
                        .foregroundStyle(CovaColor.accent)
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
                        ForEach([
                            "做一首夏日广告配乐，30 秒，轻快",
                            "来一段适合深夜写作的纯音乐",
                            "给短视频做一首中国风 BGM",
                        ], id: \.self) { chip in
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
                        ForEach(sessions) { item in
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
        CovaListRow(
            title: item.displayTitle,
            subtitle: item.displaySummary,
            artwork: CovaArtwork(url: nil, title: item.displayTitle)
        ) {
            if inFlightTitles.contains(item.id) {
                HStack(spacing: CovaSpace.xs) {
                    ProgressView().controlSize(.mini)
                    Text("生成中").font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                }
            } else {
                Image(systemName: "chevron.right").foregroundStyle(CovaColor.muted)
            }
        } action: {
            session.path.append(.aiSession(item.id))
        }
    }

    /// 建会话再进详情；失败点名 NEEDS-23（会话条目 schema 未文档化）。
    private func startNewSession() async {
        guard session.requireLoginForCollections() else { return }
        do {
            let id = try await session.studio.createSession()
            // pendingPrompt 由 09 进屏后消费并清空（示例 chip 点进来时带着那句话）；
            // 这里不清，否则 chip 白点。
            session.path.append(.aiSession(id))
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
                            action: { session.path.append(.aiSessions) }
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sessions.prefix(3)) { item in
                                // 12c 的三行是**只读**：没有 ⋯、没有左滑、没有进度环。
                                CovaListRow(
                                    title: item.displayTitle,
                                    subtitle: item.displaySummary,
                                    artwork: CovaArtwork(url: nil, title: item.displayTitle)
                                ) { EmptyView() } action: {
                                    session.path.append(.aiSession(item.id))
                                }
                            }
                        }
                        if sessions.count > 3 {
                            Button("查看全部创作") { session.path.append(.aiSessions) }
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
