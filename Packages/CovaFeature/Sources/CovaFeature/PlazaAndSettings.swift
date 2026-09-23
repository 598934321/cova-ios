import CovaCore
import CovaUI
import SwiftUI
import UserNotifications

// MARK: - 05 歌单广场

/// 歌单广场（design 05）：场景 chips 吸顶 + 双列网格（16:10 封面）。
/// 契约事实：`GET /api/playlists` **一次给全量、没有分页字段** ⇒ 本屏不发明 `?scene=`/`?page=`，
/// 分类切换是**本地过滤**（不重骨架，快交叉淡入）。
public struct PlaylistsPlazaView: View {
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var playlists: [PlaylistDto] = []
    @State private var scenes: [(id: String, label: String)] = []
    @State private var scene: String?

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            chipRow
            content
        }
        .covaPage()
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load(silent: true) }
    }

    @ViewBuilder
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.sm) {
                CovaChip("全部", isSelected: scene == nil) { scene = nil }
                ForEach(scenes, id: \.id) { item in
                    CovaChip(item.label, isSelected: scene == item.id) { scene = item.id }
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
            CovaErrorState(kind: Self.kind(failure), retry: { Task { await load() } })
        case .ready:
            grid
        }
    }

    @ViewBuilder
    private var grid: some View {
        let shown = filtered
        if playlists.isEmpty {
            CovaEmptyState(
                symbol: "music.note.list",
                title: "歌单还在准备中",
                hint: "官方歌单上线后这里会出现全部场景。"
            )
        } else if shown.isEmpty {
            CovaEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "这个场景还没有歌单",
                hint: "换一个场景看看，或直接说你想要什么氛围",
                actionTitle: "去首页说一句",
                action: { session.path = []; session.tab = .home }
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: CovaSpace.md), GridItem(.flexible())],
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

    private var filtered: [PlaylistDto] {
        guard let scene else { return playlists }
        return playlists.filter { $0.scene == scene }
    }

    private func card(_ playlist: PlaylistDto) -> some View {
        Button { session.path.append(.playlist(playlist.id)) } label: {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                ZStack(alignment: .topTrailing) {
                    CovaArtwork(
                        url: URL(string: playlist.cover ?? playlist.coverUrl
                            ?? playlist.coverMedia?.imageUrl ?? ""),
                        title: playlist.title
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                    // 角标只读；收藏动作在 06。游客恒无角标，且这**不是缺陷**（NEEDS-1/3 未闭合）。
                    if playlist.isSaved == true {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CovaColor.accent)
                            .padding(CovaSpace.xs)
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
        .buttonStyle(.plain)
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
            // chips 顺序/中文来自 taxonomy 的 scene 维度；取不到就只剩「全部」——
            // 不硬编码一份中文表冒充后端。
            let sceneTerms = (tree?.taxonomy.scene ?? [])
                .sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
                .map { (id: $0.id, label: $0.label ?? $0.id) }
            if !sceneTerms.isEmpty { scenes = sceneTerms }
            phase = .ready
        } catch {
            if silent { session.showToast("刷新失败，可下拉重试", isError: true) }
            else { phase = .failed(CatalogService.classify(error, decodingNeeds: "NEEDS-1")) }
        }
    }
}

// MARK: - 15 设置

/// 设置（design 15）。这一屏**几乎全是客户端事实**：主题、缓存占用、通知授权回显、
/// 外链条款、版本号 —— 唯一需要的端点是登出 `POST /api/auth/logout`。
/// 按 spec：无骨架、无空态、无整屏错误态、无下拉刷新；离线全可用。
public struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var cacheBytes: Int64?
    @State private var notifyStatus = "未设置"
    @State private var confirmLogout = false
    @State private var confirmClear = false
    @State private var needWebsite = false

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
                Button("清除缓存" + (cacheText.map { "（\($0)）" } ?? "")) {
                    confirmClear = true
                }
                .foregroundStyle(CovaColor.fg)
            }
            Section("通知") {
                HStack {
                    Text("生成完成通知").foregroundStyle(CovaColor.fg)
                    Spacer()
                    Text(notifyStatus).foregroundStyle(CovaColor.secondary)
                }
            }
            Section("条款与说明") {
                link("隐私政策", "https://covalink.cn/privacy")
                link("服务条款", "https://covalink.cn/terms")
                link("版权说明", "https://covalink.cn/copyright")
            }
            // 账号段整段（含分组标题）仅已登录渲染；游客顶部不出现登录引导行。
            if case .signedIn = session.authPhase {
                Section("账号") {
                    Button("账号删除") { needWebsite = true }
                        .foregroundStyle(CovaColor.fg)
                    Button("登出", role: .destructive) { confirmLogout = true }
                }
            }
            Section("关于") {
                HStack {
                    Text("版本").foregroundStyle(CovaColor.fg)
                    Spacer()
                    Text(Self.versionString).foregroundStyle(CovaColor.secondary)
                }
                // I′ 开源许可：零第三方依赖 ⇒ 这一行**不渲染**（不是"暂无内容"）。
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .covaPage()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure(); await readNotifyStatus() }
        .confirmationDialog("清除缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await clearCache() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除封面与试听缓存，不影响已下载的音乐与登录状态。")
        }
        .confirmationDialog("登出", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("登出", role: .destructive) { Task { await session.signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            // D8 的四条副作用必须逐条列出，不能只说「确定要退出吗」。
            Text("退出这台设备上的账号\n正在播的音乐会停止，播放队列会清空\n"
                 + "AI 生成的试听音频与封面缓存会被删除\n"
                 + "离线记录（搜索历史、缓存的列表与偏好）将按账号清除")
        }
        .alert("需前往官网", isPresented: $needWebsite) {
            Button("复制账号页链接") {
                UIPasteboard.general.string = "https://covalink.cn/account"
                session.showToast("链接已复制")
            }
            Button("取消", role: .cancel) {}
        } message: {
            // NEEDS-4：账号删除端点未提供 ⇒ 不假装能在 App 内删号。
            Text("账号删除需前往官网完成（后端缺口 NEEDS-4 已登记）。")
        }
    }

    private var themeBinding: Binding<CovaThemeMode> {
        Binding(
            get: { session.themeMode },
            set: { session.setTheme($0) }
        )
    }

    private var cacheText: String? {
        guard let cacheBytes else { return nil }
        return Self.human(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .foregroundStyle(CovaColor.fg)
            .overlay(alignment: .trailing) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13)).foregroundStyle(CovaColor.muted)
            }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private static func human(_ raw: String) -> String {
        raw.replacingOccurrences(of: " bytes", with: " B")
            .replacingOccurrences(of: "KB", with: " KB")
            .replacingOccurrences(of: "MB", with: " MB")
            .replacingOccurrences(of: "GB", with: " GB")
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
        if failures == 0 {
            session.showToast("已经很干净了")
        } else {
            session.showToast("有些缓存正在使用，稍后再清", isError: true)
        }
        await measure()
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
