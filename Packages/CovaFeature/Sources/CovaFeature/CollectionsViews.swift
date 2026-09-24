import CovaCore
import CovaPlayer
import CovaUI
import SwiftUI

// MARK: - 12a 我的收藏

/// 我的收藏（design 12a）。骨架是 12a/12b 共用的一套：
/// A 导航条（‹ / 标题 / 编辑）→ B 摘要行 → C 行 → D 尾部状态行，E 左滑单枚 destructive。
///
/// 四条硬口径：
/// · **客户端不重排**（响应没有 `savedAt`、没有分页参数 ⇒ 以后端顺序为准）；
/// · 批量取消 = **逐条 DELETE + 幂等键，≤4 并发**，不发明 `POST /api/favorites/batch`；
/// · `GET /api/favorites` 是**合并 feed**（库曲 + 生成笔记，E3b）⇒ 两类都渲染成行，
///   服务端不发的字段（`favoriteCount`/`energy`/`tags`）一律不显，**不拿 0 顶**；
///   笔记条目也**不丢行** —— 丢的是用户自己的收藏；
/// · 收藏动作**按种类路由**：笔记走 `/api/notes/:id/favorite`，库曲走 `/api/favorites`；
///   取消动作这里统一用 `removeFavorites`（"这一屏里的条目必然已收藏"是本页的事实，
///   拿 `favoriteIDs` 反推会把笔记条目翻转成"再收藏一次"）。
public struct FavoritesView: View {
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var items: [FavoriteItemDto] = []
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var busy = false

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init() {}

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                CovaSkeleton(rows: 8)
            case .failed(let failure):
                CovaErrorState(kind: Self.kind(failure)) { Task { await load() } }
            case .ready:
                if items.isEmpty {
                    VStack(spacing: CovaSpace.sm) {
                        CovaEmptyState(
                            symbol: "heart",
                            title: "还没有收藏",
                            hint: "听到喜欢的歌点一下 ♡，就会出现在这里",
                            actionTitle: "去曲库挑歌",
                            action: { session.tab = .library }
                        )
                        // 12a §触控 要「空态两枚 CTA」，第二枚排在主 CTA **下面**。原先挂在
                        // `.overlay(alignment: .bottom)` 上，压在「去曲库挑歌」字样里 —— 是登录后的
                        // 截图实测抓到的重叠，不是猜的。
                        Button("先看看歌单") { session.path.append(.plaza) }
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                            .buttonStyle(.plain)
                    }
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .covaPage()
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { if editing { batchBar } }
        .task { await load() }
        .refreshable { await load(silent: true) }
    }

    /// 编辑态在 loading 时**不渲染**（design 12a：骨架期不给可点的编辑钮）。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch phase {
            case .loading, .failed:
                EmptyView()
            case .ready:
                if editing {
                    HStack(spacing: CovaSpace.md) {
                        Button(allSelected ? "取消全选" : "全选") {
                            selected = allSelected ? [] : Set(items.map(\.id))
                        }
                        Button("完成") { editing = false; selected = [] }
                    }
                    .foregroundStyle(CovaColor.accent)
                } else {
                    Button("编辑") { editing = true }
                        .foregroundStyle(CovaColor.accent)
                }
            }
        }
    }

    private var allSelected: Bool {
        !items.isEmpty && selected.count == items.count
    }

    /// 只取库曲条目（既有播放队列口径：`session.play(tracks:)` 吃的是 `[TrackDto]`）。
    private var libraryTracks: [TrackDto] {
        items.compactMap { if case .library(let track) = $0 { track } else { nil } }
    }

    private var list: some View {
        List {
            Section {
                Text(summary)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    .listRowInsets(EdgeInsets(
                        top: CovaSpace.xs, leading: CovaSpace.pageGutter,
                        bottom: CovaSpace.xs, trailing: CovaSpace.pageGutter))
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(items, id: \.id) { item in
                    row(item)
                }
                tailRow
            }
            .listRowSeparator(.visible)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: FavoriteItemDto) -> some View {
        return CovaListRow(
            title: title(of: item),
            subtitle: subtitle(of: item),
            artwork: CovaArtwork(url: artworkURL(of: item), title: title(of: item))
        ) {
            if editing {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(
                        selected.contains(item.id) ? CovaColor.accent : CovaColor.muted)
                    .accessibilityLabel("选择本曲")
                    .accessibilityValue(selected.contains(item.id) ? "已选择" : "未选择")
            } else {
                Button {
                    Task { await removeFavorite(item) }
                } label: {
                    Image(systemName: "heart.fill").foregroundStyle(CovaColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消收藏")
            }
        } action: {
            if editing {
                selected.formSymmetricDifference([item.id])
            } else {
                Task { await play(item) }
            }
        }
        .frame(minHeight: 64)
        .listRowInsets(EdgeInsets(
            top: 0, leading: CovaSpace.pageGutter, bottom: 0, trailing: CovaSpace.pageGutter))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("取消收藏", systemImage: "heart.slash") {
                Task { await removeFavorite(item) }
            }
            .tint(CovaColor.error)
        }
    }

    private var tailRow: some View {
        Text("已显示全部")
            .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
    }

    private var batchBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CovaColor.line).frame(height: 0.5)
            Button {
                Task { await batchRemove() }
            } label: {
                Text(busy ? "加载中…" : "取消收藏（\(selected.count)）")
                    .font(CovaType.headline)
                    .foregroundStyle(selected.isEmpty || busy ? CovaColor.muted : CovaColor.error)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CovaSpace.md)
            }
            .disabled(selected.isEmpty || busy)
            .padding(.horizontal, CovaSpace.pageGutter)
        }
        .background(CovaColor.canvas.opacity(0.95))
    }

    private func batchRemove() async {
        busy = true
        defer { busy = false }
        let ids = Array(selected)
        let failed = await session.removeFavorites(ids)
        if failed.isEmpty {
            selected = []
            editing = false
        } else {
            // 失败行**保持勾选**，让用户能原地重试而不是重选一遍。
            selected = failed
            session.showToast("\(failed.count) 首没取消成功，已保留在列表", isError: true)
        }
        await load(silent: true)
    }

    /// 单条取消收藏（♡ 与左滑共用一条腿）。
    ///
    /// 用 `removeFavorites` 而不是 `toggleFavorite`：这一屏里的条目**必然已收藏**（本页就是
    /// 收藏 feed），而 `toggleFavorite` 是按 `favoriteIDs` 反推目标态的 —— 那本账只认库曲 id
    /// （笔记收藏在 `/api/notes/:id/favorite` 那一侧），笔记条目会被翻成「再收藏一次」。
    private func removeFavorite(_ item: FavoriteItemDto) async {
        let failed = await session.removeFavorites([item.id])
        if failed.isEmpty { await load(silent: true) }
        else { session.showToast("取消收藏没保存上，再试一次", isError: true) }
    }

    private func play(_ item: FavoriteItemDto) async {
        switch item {
        case .library(let track):
            guard AppSession.playbackItem(from: track) != nil else {
                session.showToast("音频地址不可用，这首暂时播不了", isError: true)
                return
            }
            // 队列里只留**真的能建出条目**的行：旧筛选看的是 `audioUrl` 空不空，
            // 而相对地址（线上实测形态）非空却建不出来 ⇒ 空队列 + 零解释（R16-1）。
            await session.play(
                tracks: libraryTracks.filter { AppSession.playbackItem(from: $0) != nil },
                at: 0
            )
        case .note(let note):
            guard let playback = Self.playbackItem(for: note) else {
                session.showToast("这首暂时不能播", isError: true)
                return
            }
            await session.play(items: [playback], at: 0)
        }
    }

    // MARK: 一行的三面（两类条目各有各的"没有"）

    private func title(of item: FavoriteItemDto) -> String {
        switch item {
        case .library(let track): return track.titleCn ?? track.title
        case .note(let note): return note.displayTitle
        }
    }

    private func subtitle(of item: FavoriteItemDto) -> String {
        switch item {
        case .library(let track):
            let artist = track.artistNameCn ?? track.artist.name
            return "\(artist.isEmpty ? "未知艺人" : artist) · \(Int(track.audioDuration ?? track.duration))s"
        case .note(let note):
            // 笔记的 `duration` 服务端恒发 0（未分析）⇒ 不显「0s」，也不显 BPM/收藏数（根本不发）。
            let artist = Self.artist(of: note)
            guard let duration = note.displayDuration else { return artist }
            return "\(artist) · \(Int(duration))s"
        }
    }

    private func artworkURL(of item: FavoriteItemDto) -> URL? {
        switch item {
        case .library(let track): return Self.displayURL(track.cover)
        case .note(let note): return Self.displayURL(note.cover)
        }
    }

    private static func artist(of note: NoteFavoriteDto) -> String {
        if let cn = note.artistNameCn, !cn.isEmpty { return cn }
        if let name = note.artistName, !name.isEmpty { return name }
        return "未知艺人"
    }

    /// 本站**相对路径**补全成生产出口（绝对地址原样交出）。
    ///
    /// 必要性：笔记条目的 `cover` / `audioUrl` 实测形态是 `/api/proxy/audio?…&sig=…` 或
    /// `/audio/suno_*.mp3` 这类相对路径（`web` 仓 `resolveNoteAudioUrl` + `playableAudioUrl`
    /// 会把 Suno 资产改写成签名代理），相对地址既不能播也不能取。
    /// 补全只经 `CovaEnvironment.resolveMediaURL`（内部就是 `makeAPIURL`，D10 唯一出口），
    /// 补不出来就当没有 —— 不猜 host。
    ///
    /// R16-1：库曲 `audioUrl` 线上同样是相对路径（20/20 行），却走的是另一条腿
    /// （旧 `URL(string:)` + `AudioURL(https:)`，相对值必被 `.missingScheme` 拒绝）。
    /// 两条腿现在同一个口径，不再「笔记补全、库曲丢 null」。
    static func displayURL(_ raw: String?) -> URL? {
        CovaEnvironment.resolveMediaURL(raw)
    }

    /// 笔记条目 → `PlaybackItem`。
    ///
    /// **走 D7 私有顺序**（Bearer 下载 → 校验非空 → `file://`），不走公开直链：
    /// 服务端给的是本站签名代理/静态路径，本身不要求 Bearer，但生成音频在 iOS 侧的口径
    /// 就是先本地化（AGENTS 硬边界 6），且这一栏随时可能改回真正的私有直链 ⇒ 收敛到更严一侧。
    /// `kind` 取 `.privateCandidate`：它不是库曲，`POST /api/tracks/play` 只认库曲 id，
    /// 按 `.libraryTrack` 起播会拿 `note:<uuid>` 去打一个必然 404 的上报。
    static func playbackItem(for note: NoteFavoriteDto) -> PlaybackItem? {
        // 音频只认生产出口（D10）：`PrivateAudioFetcher` 那一层同样会按主机拒绝，
        // 这里先拒是为了让"不能播"落在能说话的地方，而不是变成一个网络错。
        guard let raw = note.audioUrl, let candidate = displayURL(raw),
              CovaEnvironment.isProductionOrigin(candidate),
              let audioURL = try? AudioURL(https: candidate) else { return nil }
        // `PlaybackItem.id` 的口径是 `[A-Za-z0-9_-]`（同时是缓存文件名），`note:` 前缀进不去。
        guard let noteID = note.noteIdentifier else { return nil }
        return try? PlaybackItem(
            id: noteID,
            title: note.displayTitle,
            artist: artist(of: note),
            album: nil,
            duration: note.displayDuration,
            coverURL: displayURL(note.cover).flatMap { try? AudioURL(https: $0) },
            audioSource: .bearerRequired(audioURL),
            kind: .privateCandidate
        )
    }

    /// B 摘要 = **客户端计算**（后端没有汇总字段）。
    /// 时长只累加"服务端真给了的"：笔记条目 `duration` 为 0/缺 ⇒ 不计入，也不按 0 假装算过。
    private var summary: String {
        let total = items.reduce(0.0) { sum, item in
            switch item {
            case .library(let track): return sum + (track.audioDuration ?? track.duration)
            case .note(let note): return sum + (note.displayDuration ?? 0)
            }
        }
        let minutes = Int(total) / 60
        let span: String
        if minutes >= 60 { span = "约 \(minutes / 60) 小时 \(minutes % 60) 分" }
        else { span = "约 \(minutes) 分钟" }
        return "\(items.count) 首 · \(span)"
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
            let page = try await session.catalog.favorites()
            items = page.items
            phase = .ready
        } catch {
            let failure = CatalogService.classify(error, decodingNeeds: "NEEDS-11")
            if silent { session.showToast("刷新收藏失败，可下拉重试", isError: true) }
            else { phase = .failed(failure) }
        }
    }
}

// MARK: - 12b 我的歌单

/// 我的歌单（design 12b）：与 12a 同骨架，唯一差异是 C 区换成 88×88 的歌单卡。
/// 与 12a 不同，本屏**可以**按 `savedAt` 倒序稳定排（缺失项落尾并保持后端相对顺序）。
public struct MyPlaylistsView: View {
    @Environment(AppSession.self) private var session
    @State private var phase: Phase = .loading
    @State private var playlists: [PlaylistDto] = []
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var busy = false

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
                if playlists.isEmpty {
                    CovaEmptyState(
                        symbol: "bookmark",
                        title: "还没收藏歌单",
                        hint: "在歌单广场点书签，就会出现在这里",
                        actionTitle: "去歌单广场",
                        action: { session.path.append(.plaza) }
                    )
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .covaPage()
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch phase {
                case .loading, .failed: EmptyView()
                case .ready:
                    if editing {
                        HStack(spacing: CovaSpace.md) {
                            Button(selected.count == playlists.count ? "取消全选" : "全选") {
                                selected = selected.count == playlists.count
                                    ? [] : Set(playlists.map(\.id))
                            }
                            Button("完成") { editing = false; selected = [] }
                        }
                        .foregroundStyle(CovaColor.accent)
                    } else {
                        Button("编辑") { editing = true }.foregroundStyle(CovaColor.accent)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if editing { batchBar } }
        .task { await load() }
        .refreshable { await load(silent: true) }
    }

    private var list: some View {
        List {
            Section {
                Text(summary).font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(sorted, id: \.id) { playlist in
                    card(playlist)
                }
                Text("已显示全部")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// `savedAt` 倒序；缺失项落尾且保持后端相对顺序（稳定排序，不引入第二事实源）。
    private var sorted: [PlaylistDto] {
        playlists.enumerated()
            .sorted { lhs, rhs in
                // 缺席用 distantPast 参与比较 ⇒ 倒序时自然排到最后，不需要额外的落尾腿。
                let l = Self.date(lhs.element.savedAt) ?? .distantPast
                let r = Self.date(rhs.element.savedAt) ?? .distantPast
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    @ViewBuilder
    private func card(_ playlist: PlaylistDto) -> some View {
        // `title*` 全空 ⇒ 该行不渲染（脏数据不"修正"）。
        if (playlist.titleCn ?? playlist.title).isEmpty {
            EmptyView()
        } else {
            CovaListRow(
                title: playlist.titleCn ?? playlist.title,
                subtitle: metaLine(playlist),
                artwork: CovaArtwork(
                    url: URL(string: playlist.cover ?? playlist.coverUrl
                        ?? playlist.coverMedia?.imageUrl ?? ""),
                    title: playlist.title)
            ) {
                if editing {
                    Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected.contains(playlist.id) ? CovaColor.accent : CovaColor.muted)
                        .accessibilityLabel("选择本歌单")
                        .accessibilityValue(selected.contains(playlist.id) ? "已选择" : "未选择")
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(CovaColor.muted)
                        .accessibilityHidden(true)
                }
            } action: {
                if editing {
                    selected.formSymmetricDifference([playlist.id])
                } else {
                    session.path.append(.playlist(playlist.id))
                }
            }
            .frame(minHeight: 88)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("取消收藏", systemImage: "bookmark.slash") {
                    Task {
                        let failed = await session.removeSavedPlaylists([playlist.id])
                        if failed.isEmpty { await load(silent: true) }
                        else { session.showToast("取消收藏没保存上，再试一次", isError: true) }
                    }
                }
                .tint(CovaColor.error)
            }
        }
    }

    private func metaLine(_ playlist: PlaylistDto) -> String {
        var parts: [String] = []
        if let count = playlist.trackCount { parts.append("\(count) 首") }
        if let savedAt = Self.date(playlist.savedAt) {
            parts.append("收藏于 \(savedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// B 摘要 = `N 个歌单 · 约 M 首`；M 是 `trackCount` 之和（**不做跨歌单去重**），
    /// 缺失项不计入；全缺则只显 `N 个歌单`。
    private var summary: String {
        let counts = playlists.compactMap(\.trackCount)
        if counts.isEmpty { return "\(playlists.count) 个歌单" }
        return "\(playlists.count) 个歌单 · 约 \(counts.reduce(0, +)) 首"
    }

    private var batchBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CovaColor.line).frame(height: 0.5)
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    let failed = await session.removeSavedPlaylists(Array(selected))
                    if failed.isEmpty {
                        selected = []; editing = false
                    } else {
                        selected = failed
                        session.showToast("\(failed.count) 个没取消成功，已保留在列表", isError: true)
                    }
                    await load(silent: true)
                }
            } label: {
                Text(busy ? "加载中…" : "取消收藏（\(selected.count)）")
                    .font(CovaType.headline)
                    .foregroundStyle(selected.isEmpty || busy ? CovaColor.muted : CovaColor.error)
                    .frame(maxWidth: .infinity).padding(.vertical, CovaSpace.md)
            }
            .disabled(selected.isEmpty || busy)
            .padding(.horizontal, CovaSpace.pageGutter)
        }
        .background(CovaColor.canvas.opacity(0.95))
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withZone = ISO8601DateFormatter()
        if let date = withZone.date(from: iso) { return date }
        let noZone = ISO8601DateFormatter()
        noZone.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return noZone.date(from: iso)
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
            let page = try await session.catalog.savedPlaylists()
            playlists = page.playlists.filter { ($0.isSaved ?? true) }
            phase = .ready
        } catch {
            if silent { session.showToast("刷新失败，可下拉重试", isError: true) }
            else { phase = .failed(CatalogService.classify(error, decodingNeeds: "NEEDS-1")) }
        }
    }
}
