import CovaCore
import CovaUI
import SwiftUI
import UIKit
import UserNotifications

// MARK: - 05 歌单广场

/// 歌单广场（design 05）：场景 chips 吸顶 + 双列网格（16:10 封面）。
/// 契约事实：`GET /api/playlists` **一次给全量、没有分页字段** ⇒ 本屏不发明 `?scene=`/`?page=`，
/// 分类切换是**本地过滤**（不重骨架，快交叉淡入）。
public struct PlaylistsPlazaView: View {
    /// 05 §Dynamic Type：AX 档下网格由 2 列降为 1 列（卡宽 = 屏宽 − 2×页边距）。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var playlists: [PlaylistDto] = []
    /// §5 P3：这一屏从"只有官方"推到三条腿。`picks` 是 daily / 广场 两源共用的卡数组
    /// （换源就整本重取，不叠 —— 一份推荐位属于一个源，不是全局账）。
    @State private var source: PlazaSource = .previewDefault
    @State private var picks: [PlaylistPickDto] = []
    /// 一枚场景 chip：`key` 就是拿去和 `playlist.scene` 比的那个值，`label` 是屏上那两个字
    /// （今天两者同源，都来自 03 那份摊平的 `LibraryFilterTerm.value`）。
    @State private var scenes: [(key: String, label: String)] = []
    @State private var scene: String?
    /// `plazaSearch(q)` 路由带入的检索词（05 §1，2026-10-02）：回显行 + 网格本地过滤。
    @State private var activeQuery: String?

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(searchQuery: String? = nil) {
        // 去空白后为空 = 没带条件（等价 `plaza` 路由形态，不发空搜索键那一族的同一判据）。
        _activeQuery = State(initialValue: WorksListQuery.textIfPresent(searchQuery))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // §1：回显行在导航条下、三源段控件之上；✕/「清除搜索」同一个动作。
            if let activeQuery {
                CovaSearchEchoRow(query: activeQuery) { self.activeQuery = nil }
            }
            sourceRow
            if source.showsSceneChips { chipRow }
            content
        }
        // 非 .ready 各态（骨架/整屏错误/空态）自身不纵向扩展，缺这一行整个 VStack 会被
        // SwiftUI 居中，回显行与 chips 一起沉到屏幕中段（§2 布局图要求它们贴导航条）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .covaPage()
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.inline)
        // 键是**用户选的源**，不是 load 自己会写的 phase/picks ⇒ 不会重演 §7 #50 那种自我取消。
        .task(id: source) { await loadBoard() }
        .refreshable { await load(silent: true) }
    }

    /// 三源段控件。标签是本地词表（机器名 `official/daily/shared` 不上屏）。
    @ViewBuilder
    private var sourceRow: some View {
        HStack(spacing: CovaSpace.sm) {
            ForEach(PlazaSource.allCases) { item in
                CovaChip(item.label, isSelected: source == item) {
                    if source != item { source = item }
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.top, CovaSpace.sm)
        .accessibilityLabel("歌单来源")
    }

    /// 换源 = 整屏重取。官方那一本沿用原来的腿（含 taxonomy chips），另两源走 P3 的新腿。
    private func loadBoard() async {
        switch source {
        case .official: await load()
        case .daily, .shared: await loadPicks()
        }
    }

    private func loadPicks() async {
        let wanted = source   // 值捕获：回来时若用户已换源，这一趟只丢，不写（与任务轮询同一裁决）
        if phase != .loading { phase = .loading }
        do {
            let loaded: [PlaylistPickDto]
            switch wanted {
            case .official: return
            case .daily: loaded = (try await session.playlistDiscovery.dailyPicks()).items
            case .shared: loaded = (try await session.playlistDiscovery.sharedBoard()).playlists
            }
            guard wanted == source else { return }
            picks = loaded
            phase = .ready
        } catch let failure as CatalogFailure {
            guard wanted == source else { return }
            phase = .failed(failure)
        } catch {
            guard wanted == source else { return }
            phase = .failed(.network)
        }
    }

    @ViewBuilder
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.sm) {
                CovaChip("全部", isSelected: scene == nil) { scene = nil }
                ForEach(scenes, id: \.key) { item in
                    CovaChip(item.label, isSelected: scene == item.key) { scene = item.key }
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.sm)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            // 骨架用真实几何：4 枚 chips（已在上方）+ 6 张 16:10 卡。
            CovaSkeleton(rows: 6).padding(.top, CovaSpace.lg)
        case .failed(let failure):
            // 首载失败 = **整屏**错误态；下拉刷新失败只 Toast，两者不混用（design 05 明文）。
            // 剩余空间垂直居中（VStack 顶钉在上层，内容区剩下多少就在多少里居中）。
            CovaErrorState(kind: Self.kind(failure), retry: { Task { await load() } })
                .frame(maxHeight: .infinity)
        case .ready:
            grid
        }
    }

    @ViewBuilder
    private var grid: some View {
        switch source {
        case .official: officialGrid
        case .daily, .shared: pickGrid
        }
    }

    @ViewBuilder
    private var pickGrid: some View {
        let shown = filteredPicks
        if picks.isEmpty {
            CovaEmptyState(
                symbol: "music.note.list",
                title: source == .daily ? "今天还没有推荐位" : "还没有人把歌单分享出来",
                hint: source == .daily ? "明天这个时候再来看一次。" : "在官方歌单里挑一张，或自己去建一张。"
            )
            .frame(maxHeight: .infinity)
        } else if shown.isEmpty, let activeQuery {
            // 换源不换检索词：daily/广场两段同样按 `titleCn ?? title` 过滤（§1 的网格规则不分源）。
            CovaEmptyState(
                symbol: "magnifyingglass",
                title: "没有找到『\(activeQuery)』相关的歌单",
                hint: nil,
                actionTitle: "清除搜索",
                action: { self.activeQuery = nil }
            )
            .frame(maxHeight: .infinity)
        } else {
            pickGridList(shown)
        }
    }

    /// 与 `filtered` 同一把尺子的 picks 版（检索词落在内嵌的 `playlist` 上）。
    private var filteredPicks: [PlaylistPickDto] {
        guard let activeQuery else { return picks }
        return picks.filter {
            ($0.playlist.titleCn ?? $0.playlist.title).localizedCaseInsensitiveContains(activeQuery)
        }
    }

    private func pickGridList(_ shown: [PlaylistPickDto]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: axLayout
                    ? [GridItem(.flexible())]
                    : [GridItem(.flexible(), spacing: CovaSpace.md), GridItem(.flexible())],
                spacing: CovaSpace.lg
            ) {
                ForEach(Array(shown.enumerated()), id: \.element.playlist.id) { _, pick in
                    pickCard(pick)
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.top, CovaSpace.md)
            Text("已显示全部")
                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CovaSpace.lg)
        }
    }

    @ViewBuilder
    private var officialGrid: some View {
        let shown = filtered
        if playlists.isEmpty {
            CovaEmptyState(
                symbol: "music.note.list",
                title: "歌单还在准备中",
                hint: "官方歌单上线后这里会出现全部场景。"
            )
            .frame(maxHeight: .infinity)
        } else if shown.isEmpty, let activeQuery {
            // §1：检索过滤为空的空态是另一句话（场景空态是"这个场景还没有歌单"）。
            CovaEmptyState(
                symbol: "magnifyingglass",
                title: "没有找到『\(activeQuery)』相关的歌单",
                hint: nil,
                actionTitle: "清除搜索",
                action: { self.activeQuery = nil }
            )
            .frame(maxHeight: .infinity)
        } else if shown.isEmpty {
            CovaEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "这个场景还没有歌单",
                hint: "换一个场景看看，或直接说你想要什么氛围",
                actionTitle: "去首页说一句",
                action: { session.goToTabRoot(.home) }
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: axLayout
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible(), spacing: CovaSpace.md), GridItem(.flexible())],
                    spacing: CovaSpace.lg
                ) {
                    ForEach(shown, id: \.id) { playlist in
                        card(playlist)
                    }
                }
                .padding(.horizontal, CovaSpace.pageGutter)
                .padding(.top, CovaSpace.md)
                Text("已显示全部")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CovaSpace.lg)
            }
            .animation(.easeOut(duration: 0.18), value: scene)
        }
    }

    /// §7 明文「纯本地过滤，不发新请求」：先按场景 chip 收窄，再叠加检索词
    /// （`titleCn ?? title` 的大小写不敏感子串匹配 —— 歌单没有别的可搜字段，不猜）。
    private var filtered: [PlaylistDto] {
        var list = playlists
        if let scene {
            list = list.filter { $0.scene == scene }
        }
        if let activeQuery {
            list = list.filter {
                ($0.titleCn ?? $0.title).localizedCaseInsensitiveContains(activeQuery)
            }
        }
        return list
    }

    private func card(_ playlist: PlaylistDto) -> some View {
        Button { session.push(.playlist(playlist.id)) } label: {
            cardBody(playlist)
        }
        .buttonStyle(.plain)
    }

    /// P3 两源的卡：目的地由 `PlaylistBoard` 那一格判（分享腿只认 href 里的 token）。
    /// `.nowhere` ⇒ **渲染成不可点的静态卡**，而不是"点了再说"——点了没反应是骗人，
    /// 按官方那条腿打过去拿到 404 更是把客户端的猜测算成服务端的错。
    @ViewBuilder
    private func pickCard(_ pick: PlaylistPickDto) -> some View {
        switch PlaylistBoard.destination(for: pick) {
        case .officialPlaylist(let id):
            Button { session.push(.playlist(id)) } label: { cardBody(pick.playlist) }
                .buttonStyle(.plain)
        case .sharedPlaylist(let token):
            Button { session.push(.sharedPlaylist(token)) } label: { cardBody(pick.playlist) }
                .buttonStyle(.plain)
        case .nowhere:
            cardBody(pick.playlist)
                .accessibilityHint("这张卡暂时打不开")
        }
    }

    @ViewBuilder
    private func cardBody(_ playlist: PlaylistDto) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
                ZStack(alignment: .topTrailing) {
                    CovaArtwork(
                        resolution: CovaArtworkResolution(serverValues: [
                            playlist.cover, playlist.coverUrl, playlist.coverMedia?.imageUrl,
                        ]),
                        title: playlist.title
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                    // 角标只读；收藏动作在 06。游客恒无角标，且这**不是缺陷**（NEEDS-1/3 未闭合）。
                    if playlist.isSaved == true {
                        Image(systemName: "bookmark.fill")
                            .font(CovaSymbol.statusSmall)
                            .foregroundStyle(CovaColor.accent)
                            .padding(CovaSpace.xs)
                            .accessibilityLabel("已收藏")
                    }
                }
                Text(playlist.titleCn ?? playlist.title)
                    .font(CovaType.callout).foregroundStyle(CovaColor.fg)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta(playlist))
                    .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    .lineLimit(1)
        }
    }

    /// `trackCount` 空只显时长；时长秒 → `≥60`「N 分钟」（向下取整）、`<60`「N 秒」。
    private func meta(_ playlist: PlaylistDto) -> String {
        var parts: [String] = []
        if let count = playlist.trackCount { parts.append("\(count) 首") }
        if let total = playlist.totalDuration, total > 0 {
            let seconds = Int(total)
            parts.append(seconds >= 60 ? "\(seconds / 60) 分钟" : "\(seconds) 秒")
        }
        return parts.joined(separator: " · ")
    }

    private static func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .unauthenticated: return .unauthenticated
        case .backendGap(let id): return .backendGap(id)
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { phase = .loading }
        do {
            async let list = session.catalog.featuredPlaylists()
            async let taxonomy = session.catalog.taxonomy()
            let (items, tree) = (try await list, try? await taxonomy)
            playlists = items
            // 05 的场景 chips 现在吃 03 那份摊平（`LibraryFilterSchema.dimensions(from:)`），
            // 不再自己读 `taxonomy.scene` 的原始词条（审计那条「05 chips 取了全量 taxonomy」）。
            // 换过来实际差三件事，全是"少骗一点"：
            // · 词条走 `LibraryFilterTerm.value`（= `label ?? id` 去空白）：解出来是空的词条
            //   **不出 chip** —— 旧写法 `label ?? $0.id` 不判空，一枚空白胶囊点得动却筛不出东西；
            // · 顺序沿用服务端原序（03 同一口径）；旧写法在这里再按 `sortOrder` 排一次，
            //   而 `sortOrder ?? 0` 会把**没有**这个字段的词条排到最前面 —— 把"读不到"排成第一名；
            // · 03 那一维会把 `subscene` 并进来 ⇒ 后端补出子维度那天，05 与 03 是同一张表，
            //   不是 05 少一级（今天 `subscene` 还不在 DTO 里，见 `LibraryView` 顶部的数据事实）。
            // 筛选键 = 词条值，与 `playlist.scene` 的原文同一把尺子（线上 scene 词条的 id 就是
            // 那个中文标签，见 `Fixtures/taxonomy.json`；01 §4 分组的也是这串原文）。
            let sceneTerms = (tree.flatMap { taxonomy in
                LibraryFilterSchema.dimensions(from: taxonomy).first { $0.id == "scene" }?.terms
            } ?? []).map { (key: $0.value, label: $0.value) }
            if !sceneTerms.isEmpty { scenes = sceneTerms }
            phase = .ready
        } catch {
            if silent { session.showToast("刷新失败，可下拉重试", isError: true) }
            else { phase = .failed(CatalogService.classify(error)) }
        }
    }
}

// MARK: - 15 设置

/// 设置（design 15）。这一屏**几乎全是客户端事实**：主题、缓存占用、通知授权回显、
/// 外链条款、版本号 —— 唯一需要的端点是登出 `POST /api/auth/logout`。
/// 按 spec：无骨架、无空态、无整屏错误态、无下拉刷新；离线全可用。
public struct SettingsView: View {
    /// 15 §Dynamic Type：AX 档下「标签 + 右值」的行改成两行堆叠。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(AppSession.self) private var session
    /// 跳系统设置用同一个 `openURL` 出口（与 14 的两条外跳同形）；
    /// §4「错误」：系统拒绝（没浏览器/没邮件程序）由系统处理，**App 内不提示** ⇒ 不读返回值。
    @Environment(\.openURL) private var openURL
    @State private var cacheBytes: Int64?
    @State private var notifyStatus = "未设置"
    @State private var confirmLogout = false
    @State private var confirmClear = false
    // §3.G 注销链（2026-10-02 对齐 web v2.65.0）：后果 Dialog → POST 分流。
    // 端点无请求体、立即生效、无冷静期与撤销 ⇒ 本屏没有密码框、没有受理态。
    @State private var confirmDelete = false
    @State private var deleteBusy = false
    /// 一次逻辑注销操作的幂等凭据：可重试的失败（5xx/传输）**复用**，新操作才重建。
    @State private var deleteToken: IdempotentRequestToken?

    public init() {}

    public var body: some View {
        List {
            Section("外观") {
                Picker("主题", selection: themeBinding) {
                    Text("跟随系统").tag(CovaThemeMode.system)
                    Text("浅").tag(CovaThemeMode.light)
                    Text("深").tag(CovaThemeMode.dark)
                }
                .pickerStyle(.segmented)
            }
            Section("播放与网络") {
                // design 15：`只连 Wi-Fi 下载` 这一行在**下载门（D12）未放行时整行不渲染**；
                // v1.0 没有下载入口 ⇒ 这里不出现该行，也不出现「上报」字样。
                // §3.D + §4：右值 = 本机算出的缓存占用，测量期显 `--`（TG-29）而不是 0 ——
                // "还没算出来"与"已经很干净"是两件事。
                valueRow("清除缓存", value: Self.cacheDisplay(cacheBytes), mono: true) {
                    guard Self.asksBeforeClearing(cacheBytes) else {
                        session.showToast("已经很干净了")   // §8：缓存 = 0 → 只 Toast，不弹 Dialog
                        return
                    }
                    confirmClear = true
                }
            }
            Section("通知") {
                // §3.E：**App 内不自建通知开关**（授权归系统管，自建 = "App 里关着、系统里开着"
                // 的双源真相）。这一行必须存在（NEEDS-7 未就绪时它是用户唯一的可控出口）；
                // 点击跳系统设置，右值 = 系统授权态回显。
                valueRow("生成完成通知", value: notifyStatus) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Section("条款与说明") {
                link("隐私政策", "https://covalink.cn/privacy")
                link("服务条款", "https://covalink.cn/terms")
                link("版权说明", "https://covalink.cn/copyright")
            }
            Section("关于") {
                // §3.I + §3.H：版本 = `CFBundleShortVersionString (CFBundleVersion)`，**只读**；
                // 两枚键任一取不到 ⇒ 整行不渲染（装配出错不该被印成产品信息）。
                if let version = MineCopy.versionValue(short: versionPair.short, build: versionPair.build) {
                    labeledRow("版本", version)
                        .accessibilityLabel(
                            MineCopy.versionSpoken(
                                short: versionPair.short, build: versionPair.build) ?? version)
                }
                // I′ 开源许可：零第三方依赖 ⇒ 这一行**不渲染**（不是"暂无内容"）。
            }
            // 账号段整段（含分组标题）仅已登录渲染，且是**最后一组**（11 §5 P3 组序：
            // 破坏性的登出/注销沉到最底，「关于」信息组在它之上）；游客顶部不出现登录引导行。
            if case .signedIn = session.authPhase {
                Section("账号") {
                    // §3.G（2026-10-02 对齐 web v2.65.0）：App 内注销 —— 行 → 后果 Dialog →
                    // `POST /api/auth/delete-account` 分流。无密码复核、无受理态（契约没有这两位）。
                    Button {
                        confirmDelete = true
                    } label: {
                        HStack(spacing: CovaSpace.sm) {
                            Text("注销账号")
                                .font(CovaType.headline).foregroundStyle(CovaColor.error)
                            Spacer(minLength: CovaSpace.sm)
                            Image(systemName: "chevron.right")
                                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("注销账号")
                    // §3.H：整行文字 error 色 = destructive 语义，无尾符号。
                    Button("登出", role: .destructive) { confirmLogout = true }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .covaPage()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure(); await readNotifyStatus() }
        .confirmationDialog("清除缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            // iOS 26：confirmationDialog 不再渲染 role:.cancel 钮（系统行为，实测 AX 0 命中），
            // 关闭通道是点 Dialog 之外或下滑 —— 留死代码不如不写。
            Button("清除", role: .destructive) { Task { await clearCache() } }
        } message: {
            Text("会清除封面与试听缓存，不影响已下载的音乐与登录状态。")
        }
        .confirmationDialog("登出？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("登出", role: .destructive) { Task { await session.signOut() } }
        } message: {
            // D8 的四条副作用必须**逐条**列出（§3.H：一行一条、符号 `•`），不能只说「确定要退出吗」。
            // 这四句是合规告知，不是装饰文案 —— §6 明令不得因长度被截断。
            Text("• 退出这台设备上的账号\n"
                 + "• 正在播的音乐会停止，播放队列会清空\n"
                 + "• AI 生成的试听音频与封面缓存会被删除\n"
                 + "• 离线记录（搜索历史、缓存的列表与偏好）将按账号清除")
        }
        .confirmationDialog("确认注销账号？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认注销", role: .destructive) {
                let token = deleteToken ?? IdempotentRequestToken(operation: .accountDeletion)
                deleteToken = token
                Task { await submitDeletion(token: token) }
            }
        } message: {
            // §3.G②：后果逐条列出（同登出 Dialog 的口径），且必须如实说「立即生效、不可撤销」——
            // 端点没有冷静期与撤销位，不许留下「还能反悔」的暗示。
            Text("• 注销后账号立即退出，邮箱、手机号和第三方登录都会解除\n"
                 + "• 授权订单与创作记录按法律要求保留，但不再关联可识别的个人信息\n"
                 + "• 正在播的音乐会停止，播放队列会清空\n"
                 + "• 离线记录与缓存将按账号清除")
        }
        .overlay {
            // 提交在途挡一层：确认框关了之后请求才出去，行不该还能再点。
            if deleteBusy {
                Color.black.opacity(0.15).ignoresSafeArea()
                ProgressView().controlSize(.large)
            }
        }
    }

    private var themeBinding: Binding<CovaThemeMode> {
        Binding(
            get: { session.themeMode },
            set: { session.setTheme($0) }
        )
    }

    /// §3.G③：`POST /api/auth/delete-account` → 按回执分流。
    /// **任何一档都不许把"没注销成"说成"注销了"**：unavailable/rejected/retryable 都留在本屏，
    /// 只有 `effective`（与 410）才真正改账号侧事实。
    private func submitDeletion(token: IdempotentRequestToken) async {
        deleteBusy = true
        defer { deleteBusy = false }
        do {
            let outcome = try await session.accountService.deleteAccount(token: token)
            switch outcome {
            case .effective:
                deleteToken = nil
                await session.signOut()
                session.showToast("账号已注销", isError: true)
            case .unauthenticated:
                // 401 = 凭证已失效（会话过期，或上一次注销已生效把会话吊销）。
                // 本地登出是实话；「已注销」客户端证不了，不说。
                deleteToken = nil
                await session.signOut()
                session.showToast("登录状态已过期", isError: true)
            case .unavailable:
                deleteToken = nil   // 端点不存在 ⇒ 这把键没有任何服务端状态可对应
                session.showToast("注销服务暂未上线，请联系客服", isError: true)
            case .rejected(let message):
                // 其余 4xx：键**保留**——同一逻辑操作的重试复用同一把。
                session.showToast(message ?? "注销失败", isError: true)
            case .retryable:
                // 5xx/未知码：可安全重试（注销幂等，重放至多撞 401），键保留。
                session.showToast("注销没成功，请稍后重试", isError: true)
            }
        } catch {
            session.showToast("注销没成功，请稍后重试", isError: true)
        }
    }

    /// §3.D + §8 的缓存占用读法（三档，各有用例钉一条）：
    /// · 测量还没回来（nil）→ `--`：§4「唯一异步值计算期右位显 `--`，完成即回填」，
    ///   把"还没算出来"印成 `0 MB` 会立刻让用户以为没东西可清；
    /// · 真 0 → 「0 MB」（§8 逐字，不是 ByteCountFormatter 的 "0 bytes"）；
    /// · ≥1 GB → 一位小数「1.2 GB」（§8），`ByteCountFormatter` 的有效位随量级变，
    ///   "一位小数"这一条得自己钉住，不交给它。
    /// `internal`（不是 private）：这三档是**读法判据**，留在 `body` 里就没有用例能钉。
    static func cacheDisplay(_ bytes: Int64?) -> String {
        guard let bytes else { return MineCopy.unknownValue }
        if bytes == 0 { return "0 MB" }
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return human(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    /// §8：缓存**已经是 0** 时点击不弹 Dialog（只 Toast 一句）。一个"要清除吗"的确认框去清
    /// 一个空的东西，等于暗示用户刚才看到的 0 不算数。`nil` = 还在测量，**不当它是 0** ⇒ 照常弹。
    static func asksBeforeClearing(_ bytes: Int64?) -> Bool { bytes != 0 }

    /// §7：版本来自本地 `Bundle`（非 API），两枚键的读法与 11 §3.H 共用 `MineCopy` 一个源。
    private var versionPair: (short: String?, build: String?) { MineCopy.bundleVersion() }

    /// §3 的设置行通用几何：左标签 `type.headline`/`fg` + 右值 `type.subhead`/`secondary`
    /// （数字走 `type.mono`）+ `chevron.right`；整行一个动作、≥44pt（TG-03）。
    /// §6：一行 = 一个元素，读成「清除缓存，128 MB，按钮」—— `按钮` 那半由 trait 给，
    /// 这里只钉前两段（把「按钮」写进 label 会变成 VoiceOver 念两遍）。
    @ViewBuilder
    private func valueRow(
        _ label: String, value: String?, mono: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: axLayout ? .top : .firstTextBaseline, spacing: CovaSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    // §Dynamic Type：AX 档下右值移到标签**下方第二行**（同 11 §6 E 行）。
                    if axLayout, let value {
                        Text(value).font(mono ? CovaType.mono : CovaType.subhead)
                            .foregroundStyle(CovaColor.secondary)
                    }
                }
                Spacer(minLength: CovaSpace.sm)
                if axLayout == false, let value {
                    Text(value).font(mono ? CovaType.mono : CovaType.subhead)
                        .foregroundStyle(CovaColor.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(label)，\($0)" } ?? label)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .foregroundStyle(CovaColor.fg)
            .overlay(alignment: .trailing) {
                Image(systemName: "arrow.up.right.square")
                    .font(CovaSymbol.linkExternal).foregroundStyle(CovaColor.muted)
                    .accessibilityHidden(true)
            }
    }

    /// 15 §Dynamic Type：AX 档下右值移到标签**下方第二行**（与 11 §6 E 行同一条规则），
    /// 免得放大后标签和右值在同一行里互相挤到截断。
    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String) -> some View {
        if axLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(CovaColor.fg)
                Text(value).foregroundStyle(CovaColor.secondary)
            }
        } else {
            HStack {
                Text(label).foregroundStyle(CovaColor.fg)
                Spacer()
                Text(value).foregroundStyle(CovaColor.secondary)
            }
        }
    }

    /// 单位与数字之间**恰好一个空格**：`ByteCountFormatter` 在不同版本上给不给空格并不一致，
    /// 而旧写法 `"MB" → " MB"` 在"已经带空格"的输出上会叠成「128␣␣MB」（用例实测到的正是这个）。
    /// 所以这里不按单位打补丁，而是**按空白切词再拼**（`isWhitespace` 连不换行空格一起吃掉）。
    private static func human(_ raw: String) -> String {
        let swapped = raw.replacingOccurrences(of: "bytes", with: "B")
        return swapped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func measure() async {
        let total = await Task.detached(priority: .utility) {
            Self.cachesSizeBytes()
        }.value
        cacheBytes = total
    }

    private func readNotifyStatus() async {
        let center = UNUserNotificationCenter.current()
        // UserNotifications 只提供 completion-handler 形态；不包一层就会漏授权结果。
        let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        switch status {
        case .authorized, .provisional, .ephemeral: notifyStatus = "已开启"
        case .denied: notifyStatus = "已关闭"
        default: notifyStatus = "未设置"
        }
    }

    private func clearCache() async {
        let failures = Self.clearCaches()
        // §4：只有"删不掉"才 Toast。「已经很干净了」这句在 §8 里属于**缓存本来就是 0** 那一支
        // （点击时就被早退了），删成功再补一句等于把同一个词用在两件事上。
        if failures > 0 {
            session.showToast("有些缓存正在使用，稍后再清", isError: true)
        }
        await measure()   // §3.D：清完回写占用数字，不进度的百分比不做动画
    }

    /// 缓存占用 = **本机 FileManager 计算**，不向后端要数（后端也没有这个端点）。
    /// `nonisolated` 是为了能放进 `Task.detached` —— 目录遍历不该压在 MainActor 上。
    private nonisolated static func cachesSizeBytes() -> Int64 {
        let roots = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        var total: Int64 = 0
        for root in roots {
            total += directorySize(root)
        }
        total += Int64(URLCache.shared.currentDiskUsage)
        return total
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// 返回**未能删除**的条目数（正在使用的文件会留在这里）。
    private nonisolated static func clearCaches() -> Int {
        let manager = FileManager.default
        URLCache.shared.removeAllCachedResponses()
        var failures = 0
        for root in manager.urls(for: .cachesDirectory, in: .userDomainMask) {
            guard let children = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for child in children {
                do { try manager.removeItem(at: child) } catch { failures += 1 }
            }
        }
        return failures
    }
}
