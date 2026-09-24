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
                        .lineLimit(descriptionExpanded ? nil : 3)
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
    private let trackID: String
    @State private var phase: Phase = .loading
    @State private var track: TrackDto?
    @State private var similar: [SimilarTrackDto] = []
    @State private var lyricsExpanded = false

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure) }

    public init(trackID: String) { self.trackID = trackID }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(CovaColor.line).frame(width: 36, height: 5).padding(.top, CovaSpace.sm)
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
        .task { await session.refreshCollections(); await load() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
            }
            Spacer()
            Menu {
                Button("查看艺人") { session.showToast("艺人页在下一版接入（当前仅登记入口）") }
                Button("复制链接") {
                    UIPasteboard.general.string = "https://covalink.cn/tracks/\(trackID)"
                    session.showToast("链接已复制")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.secondary)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if let track {
            VStack(alignment: .leading, spacing: CovaSpace.lg) {
                CovaArtwork(url: URL(string: track.cover), title: track.title)
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
                    .padding(.horizontal, CovaSpace.pageGutter)

                HStack(alignment: .top, spacing: CovaSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.titleCn ?? track.title)
                            .font(CovaType.title).foregroundStyle(CovaColor.fg)
                        Button { session.showToast("艺人页在下一版接入（当前仅登记入口）") } label: {
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
