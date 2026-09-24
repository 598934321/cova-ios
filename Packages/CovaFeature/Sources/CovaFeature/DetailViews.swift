import CovaCore
import CovaUI
import SwiftUI
import UIKit

/// `sheet(item:)` 的包装：路由与 sheet 只带 ID，页面自己取数。
struct TrackSheetID: Identifiable, Equatable { let id: String }

// MARK: - 06 歌单详情

/// 歌单详情（design 06）：头图 + 标题元信息 + 简介 + 播放全部 + 曲目列表。
/// **书签不是爱心**（`saveAction.kind == "bookmark"`）；曲目行的心是**曲目收藏**。
/// 详情端点不给 `isSaved`（NEEDS-9）⇒ 收藏态取自列表端点的缓存，两者都没有时是
/// 「中性未选态」而不是「未收藏」。
public struct PlaylistDetailView: View {
    @Environment(AppSession.self) private var session
    /// 06 §Dynamic Type：AX 档下简介折叠行数由 3 放宽到 5（放大后 3 行装不下原来 3 行的信息）。
    @Environment(\.covaAXLayout) private var axLayout
    private let playlistID: String
    @State private var phase: Phase = .loading
    @State private var playlist: PlaylistDto?
    @State private var tracks: [TrackDto] = []
    @State private var descriptionExpanded = false

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(playlistID: String) { self.playlistID = playlistID }

    public var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                CovaSkeleton(rows: 6).padding(.top, CovaSpace.xl)
            case .failed(let failure):
                CovaErrorState(kind: Self.kind(failure)) { Task { await load() } }
                    .padding(.top, CovaSpace.xxl)
            case .ready:
                sections
            }
        }
        .covaPage()
        .navigationTitle(playlist.map { $0.titleCn ?? $0.title } ?? "歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { bookmarkButton }
        }
        .task { await session.refreshCollections(); await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: CovaSpace.lg) {
            hero
            if let playlist { meta(playlist) }
            if let description = playlist?.descriptionCn ?? playlist?.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    Text(description)
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        .lineLimit(descriptionExpanded ? nil : (axLayout ? 5 : 3))
                    Button(descriptionExpanded ? "收起" : "展开") {
                        descriptionExpanded.toggle()
                    }
                    .font(CovaType.caption).foregroundStyle(CovaColor.accent)
                }
                .padding(.horizontal, CovaSpace.pageGutter)
            }
            actions
            if tracks.isEmpty {
                CovaEmptyState(
                    symbol: "music.quarternote.3",
                    title: "这个歌单暂时还没有曲目",
                    hint: "歌单可能刚更新，下拉看看",
                    actionTitle: "返回歌单广场",
                    action: { session.path = [] }
                )
                .padding(.vertical, CovaSpace.xxl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        CovaListRow(
                            title: track.titleCn ?? track.title,
                            subtitle: "\(track.artistNameCn ?? track.artist.name) · \(Int(track.audioDuration ?? track.duration))s · BPM \(track.bpm)",
                            artwork: CovaArtwork(url: URL(string: track.cover), title: track.title)
                        ) {
                            heartButton(track.id)
                        } action: {
                            Task { await session.play(tracks: tracks, at: index) }
                        }
                        .contextMenu {
                            // 本屏是 ScrollView（整表一次返回、不做无限滚动），`swipeActions` 在
                            // 非 List 容器里是**静默失效**的控件 —— 不用它，改用长按菜单。
                            Button("曲目详情") { session.detailTrackID = track.id }
                        }
                    }
                    Text("已显示全部")
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, CovaSpace.lg)
                }
            }
        }
        .padding(.bottom, CovaSpace.xxl)
    }

    private var hero: some View {
        CovaArtwork(
            url: URL(string: playlist?.cover ?? playlist?.coverUrl ?? playlist?.coverMedia?.imageUrl ?? ""),
            title: playlist?.titleCn ?? playlist?.title ?? "歌单"
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.top, CovaSpace.md)
    }

    /// `trackCount` 与 `tracks.count` 不一致时**以 `tracks.count` 为准**（design 06 明文）。
    private func meta(_ playlist: PlaylistDto) -> some View {
        let count = tracks.isEmpty ? (playlist.trackCount ?? 0) : tracks.count
        var parts = ["\(count) 首"]
        if let total = playlist.totalDuration, total > 0 {
            let minutes = Int(total) / 60
            parts.append(minutes >= 60 ? "约 \(minutes / 60) 小时 \(minutes % 60) 分" : "约 \(minutes) 分")
        }
        if let curator = playlist.curator, !curator.isEmpty { parts.append(curator) }
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            Text(playlist.titleCn ?? playlist.title)
                .font(CovaType.title).foregroundStyle(CovaColor.fg)
            Text(parts.joined(separator: " · "))
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    private var actions: some View {
        HStack(spacing: CovaSpace.md) {
            CovaButton("播放全部", style: .primary) {
                Task { await session.play(tracks: tracks, at: 0) }
            }
            .disabled(tracks.isEmpty)
            .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    /// 书签按钮。`isSaved == nil` 且缓存里也没有 ⇒ **中性未选态**（轮廓），首点发 POST 回填。
    private var bookmarkButton: some View {
        let saved = session.savedPlaylistIDs.contains(playlistID)
        return Button {
            Task { await session.toggleSavedPlaylist(playlistID) }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .foregroundStyle(saved ? CovaColor.accent : CovaColor.secondary)
        }
        .accessibilityLabel(saved ? "已收藏" : "收藏")
    }

    private func heartButton(_ trackID: String) -> some View {
        let on = session.favoriteIDs.contains(trackID)
        return Button {
            Task { await session.toggleFavorite(trackID) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "取消收藏" : "收藏")
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
            let detail = try await session.catalog.playlistDetail(playlistID)
            playlist = detail.playlist
            tracks = detail.tracks ?? []
            phase = .ready
        } catch {
            phase = .failed(CatalogService.classify(error, decodingNeeds: "NEEDS-9"))
        }
    }
}

// MARK: - 07 曲目详情（半屏 sheet）

/// 曲目详情（design 07）：大封面 + 标题 + 艺人 + 播放/加入队列 + 标签 + 歌词 + 相似横滑。
/// 公开内容游客可看；收藏/加入队列要登录（弹登录而不是静默禁用）。
/// **不做 A/B 变体区块**（NEEDS-8：详情端点不给变体字段族，连占位文案都不给）。
public struct TrackDetailSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// 07 §6：AX 档下 sheet 高度、封面尺寸都换档（内容优先，别让放大的字把图挤出可视区）。
    @Environment(\.covaAXLayout) private var axLayout
    private let trackID: String
    @State private var phase: Phase = .loading
    @State private var track: TrackDto?
    @State private var similar: [SimilarTrackDto] = []
    @State private var lyricsExpanded = false

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(trackID: String) { self.trackID = trackID }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                switch phase {
                case .loading:
                    CovaSkeleton(rows: 5).padding(.top, CovaSpace.xl)
                case .failed(let failure):
                    // 首载失败 = sheet 内整屏错误态（替换内容区，顶部 ✕ 保留）。
                    CovaErrorState(kind: Self.kind(failure)) { Task { await load() } }
                        .padding(.top, CovaSpace.xxl)
                case .ready:
                    content
                }
            }
        }
        .covaPage()
        // 07 §2/§43：sheet 默认高 = 屏高 60%，上滑到 92%（**两档吸附**）。
        // 呈现机制这里先钉死一句：本屏**不是**自绘 overlay，也不是 fullScreenCover ——
        // 它是 `CovaRootView.mainShell` 上那个 `.sheet(item: $detailTrackID)` 的内容
        // （`TrackSheetID` 只带 trackID，页面自己取数），所以 `.presentationDetents`
        // 这条正路是**可用**的（此前"机制未确认"的记录到此为止）。
        // TG-15（sheet 高度档）未入 tokens ⇒ 60%/92% 按 spec 施工。
        .presentationDetents(detents)
        // §6：AX 档（≥ AX1）下默认高**自动接近全屏**（内容优先）—— 放大档 60% 高会把
        // 封面/操作行挤出可视区，那才是"AX5 把内容挤没"。这里给单一 `.large` 档：
        // 近全屏、无第二吸附点（吸附点本身在放大档没有意义，用户要的是整屏内容）。
        // §3.A 的拖拽指示条改由系统给：自绘那根 36×5 胶囊 + 两档吸附会画成**两根**条，
        // 而系统指示条正是"可拖到下一档"的官方语汇（TG-16 指示条几何档未入库）。
        .presentationDragIndicator(.visible)
        // §3.A/§5 要 sheet 底 `color.elevated`；本屏沿用的是公共 `covaPage()` 的 canvas
        // —— 那是既有偏差、不属于本批 AX 判据，留在这里说明而不是顺手改掉。
        .task { await session.refreshCollections(); await load() }
    }

    private var detents: Set<PresentationDetent> {
        axLayout ? [.large] : [.fraction(0.6), .fraction(0.92)]
    }

    /// C 区大封面。**非 AX 档与改造前逐字一致**（同一支 frame/aspectRatio/圆角/内边距）。
    /// AX 档（07 §6）：封面从"满宽"缩到容器宽的 **60%** 并居中 —— 放大档那张 1:1 方块
    /// 若保持满宽，会把操作行/标签/歌词整段顶出可视区，正是 §9 判据「AX5 无内容被挤出」
    /// 要抓的东西。比例 60% 是 spec 写的，不是自造；宽度参照用 `containerRelativeFrame`
    /// 拿**真实容器宽**（sheet 里就是 sheet 宽），不写死 point。
    @ViewBuilder
    private func cover(_ track: TrackDto) -> some View {
        let art = CovaArtwork(url: URL(string: track.cover), title: track.title)
        if axLayout {
            art.containerRelativeFrame(.horizontal) { length, _ in length * 0.6 }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CovaSpace.pageGutter)
        } else {
            art.frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
                .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
            }
            .accessibilityLabel("关闭")
            Spacer()
            Menu {
                Button("查看艺人") {
                    if let artist = track?.artist { session.path.append(.artist(artist.id)) }
                }
                Button("复制链接") {
                    UIPasteboard.general.string = "https://covalink.cn/tracks/\(trackID)"
                    session.showToast("链接已复制")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if let track {
            VStack(alignment: .leading, spacing: CovaSpace.lg) {
                cover(track)

                HStack(alignment: .top, spacing: CovaSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.titleCn ?? track.title)
                            .font(CovaType.title).foregroundStyle(CovaColor.fg)
                        Button { session.path.append(.artist(track.artist.id)) } label: {
                            Text(track.artistNameCn ?? track.artist.name)
                                .font(CovaType.callout).foregroundStyle(CovaColor.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    let on = session.favoriteIDs.contains(track.id)
                    Button {
                        Task {
                            if session.requireLoginForCollections() { await session.toggleFavorite(track.id) }
                        }
                    } label: {
                        Image(systemName: on ? "heart.fill" : "heart")
                            .font(.system(size: 22))
                            .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(on ? "取消收藏" : "收藏")
                }
                .padding(.horizontal, CovaSpace.pageGutter)

                HStack(spacing: CovaSpace.md) {
                    CovaButton("播放") {
                        Task { await session.play(tracks: [track], at: 0); dismiss() }
                    }
                    CovaButton("加入队列", style: .secondary) {
                        Task {
                            guard session.requireLoginForCollections(),
                                  let item = AppSession.playbackItem(from: track) else { return }
                            await session.enqueue(item)
                        }
                    }
                }
                .padding(.horizontal, CovaSpace.pageGutter)

                let labels = track.displayLabels.isEmpty
                    ? track.scenes + track.moods
                    : track.displayLabels
                if !labels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CovaSpace.sm) {
                            ForEach(labels, id: \.self) { label in
                                CovaChip(label, isSelected: false) {
                                    dismiss()
                                    session.tab = .library
                                }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }

                lyricsBlock(track)
                similarBlock
            }
            .padding(.bottom, CovaSpace.xxl)
        }
    }

    @ViewBuilder
    private func lyricsBlock(_ track: TrackDto) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            if let lyrics = track.lyrics, !lyrics.isEmpty {
                Text(lyrics)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .lineLimit(lyricsExpanded ? nil : 3)
                Button { lyricsExpanded.toggle() } label: {
                    HStack(spacing: 2) {
                        Text("全文").font(CovaType.caption)
                        Image(systemName: lyricsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(CovaColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lyricsExpanded ? "收起歌词" : "展开全文")
            } else {
                Text("纯音乐 · 无歌词").font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    @ViewBuilder
    private var similarBlock: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                CovaSectionHeader("相似曲目", trailing: "播放全部 ›") {
                    let items = similar.compactMap { AppSession.playbackItem(from: $0) }
                    Task {
                        await session.play(items: items, at: 0)
                        dismiss()
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CovaSpace.md) {
                        ForEach(similar, id: \.id) { item in
                            Button { session.detailTrackID = item.id } label: {
                                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                                    CovaArtwork(url: URL(string: item.cover), title: item.title)
                                        .frame(width: 112, height: 112)
                                        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                                    Text(item.titleCn ?? item.title)
                                        .font(CovaType.subhead).foregroundStyle(CovaColor.fg).lineLimit(1)
                                        .frame(width: 112)
                                    Text("\(item.artist.nameCn ?? item.artist.name) · \(Int(item.duration))s")
                                        .font(CovaType.caption).foregroundStyle(CovaColor.muted).lineLimit(1)
                                        .frame(width: 112)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                }
            }
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
            let detail = try await session.catalog.trackDetail(trackID)
            track = detail.track
            similar = detail.similar ?? []
            phase = .ready
        } catch {
            phase = .failed(CatalogService.classify(error, decodingNeeds: "NEEDS-8/10"))
        }
    }
}
