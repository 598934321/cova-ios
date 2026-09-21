import CovaCore
import CovaUI
import SwiftUI

/// 首页（design 01）：推荐歌单 / 继续聆听 / 场景精选三段；匿名可读。
/// 加载=骨架、空=空态、失败=三分类错误态；**不伪造数据**。
public struct HomeView: View {
    @Environment(AppSession.self) private var session
    private let catalog: CatalogService
    @State private var phase: Phase = .loading
    @State private var search = ""

    private enum Phase {
        case loading
        case ready(playlists: [PlaylistDto], tracks: [TrackDto])
        case failed(CatalogFailure)
    }

    public init(catalog: CatalogService) { self.catalog = catalog }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                header
                content
            }
            .padding(.vertical, CovaSpace.lg)
        }
        .covaPage()
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            Text("晚上好").font(CovaType.largeTitle).foregroundStyle(CovaColor.fg)
            Text("找一首能用的曲子").font(CovaType.callout).foregroundStyle(CovaColor.secondary)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 4)
        case .failed(let failure):
            CovaErrorState(kind: errorKind(failure)) { Task { await load() } }
        case .ready(let playlists, let tracks):
            if playlists.isEmpty && tracks.isEmpty {
                CovaEmptyState(
                    symbol: "music.quarternote.3",
                    title: "还没有可推荐的内容",
                    hint: "曲库上线后这里会出现推荐歌单与场景精选。"
                )
            } else {
                if !playlists.isEmpty {
                    CovaSectionHeader("推荐歌单")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CovaSpace.md) {
                            ForEach(playlists, id: \.id) { playlist in
                                PlaylistCard(playlist: playlist) { }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }
                if !tracks.isEmpty {
                    CovaSectionHeader("场景精选")
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.prefix(8).enumerated()), id: \.element.id) { index, track in
                            CovaListRow(
                                title: track.titleCn ?? track.title,
                                subtitle: "\(track.artistNameCn ?? track.artist.name) · \(track.scenes.joined(separator: "/"))",
                                artwork: CovaArtwork(url: URL(string: track.cover), title: track.title)
                            ) {
                                Text(track.vocalType).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                            } action: {
                                Task { await session.play(tracks: tracks, at: index) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func errorKind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .backendGap(let id): return .backendGap(id)
        }
    }

    private func load() async {
        phase = .loading
        do {
            async let playlists = catalog.featuredPlaylists()
            async let page = catalog.tracks(pageSize: 8)
            phase = .ready(playlists: try await playlists, tracks: try await page.tracks)
        } catch {
            phase = .failed(CatalogService.classify(error))
        }
    }
}

/// 歌单卡（横向滚动单元）：封面 + 名称 + 曲目数；玻璃底。
public struct PlaylistCard: View {
    private let playlist: PlaylistDto
    private let action: () -> Void
    public init(playlist: PlaylistDto, action: @escaping () -> Void) {
        self.playlist = playlist
        self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                CovaArtwork(url: URL(string: playlist.cover ?? playlist.coverUrl ?? ""), title: playlist.title)
                    .frame(width: 148, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                Text(playlist.titleCn ?? playlist.title).font(CovaType.headline).foregroundStyle(CovaColor.fg).lineLimit(1)
                Text("\(playlist.trackCount ?? 0) 首").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
            }
            .frame(width: 148)
        }
        .buttonStyle(.plain)
    }
}
