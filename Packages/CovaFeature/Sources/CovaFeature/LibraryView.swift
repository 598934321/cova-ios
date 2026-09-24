import CovaCore
import CovaUI
import SwiftUI

/// 曲库（design 03）：三级级联筛选（维度→词条→搜索）+ 分页 + 播放。
/// 级联状态用 chip 行表达；搜索防抖 300ms；分页用「加载更多」而非无限滚动（v1 求稳）。
public struct LibraryView: View {
    @Environment(AppSession.self) private var session
    private let catalog: CatalogService
    @State private var taxonomy: TaxonomyDto?
    @State private var dimension: String?
    @State private var term: String?
    @State private var query = ""
    @State private var tracks: [TrackDto] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var phase: Phase = .loading
    @State private var searchTask: Task<Void, Never>?

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure), appending }

    public init(catalog: CatalogService) { self.catalog = catalog }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let taxonomy { cascadeRows(taxonomy) }
            list
        }
        .covaPage()
        .task { await loadTaxonomy(); await reload() }
    }

    private var searchBar: some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(CovaColor.muted)
                .accessibilityHidden(true)
            TextField("搜索曲目 / 风格 / 情绪", text: $query)
                .font(CovaType.callout)
                .foregroundStyle(CovaColor.fg)
                .onChange(of: query) { _, newValue in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await reload()
                    }
                }
            if !query.isEmpty {
                Button { query = ""; Task { await reload() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CovaColor.muted)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(CovaSpace.md)
        .background(Capsule().fill(CovaColor.surface))
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.sm)
    }

    /// 契约里维度是**固定键集**（scene/mood/genre/…），不是数组；这里摊平成可遍历的级联源。
    private func dimensions(of taxonomy: TaxonomyDto) -> [(id: String, label: String, terms: [TaxonomyTermDto])] {
        let pairs: [(String, String, [TaxonomyTermDto]?)] = [
            ("scene", "场景", taxonomy.taxonomy.scene),
            ("mood", "情绪", taxonomy.taxonomy.mood),
            ("genre", "风格", taxonomy.taxonomy.genre),
            ("style", "子类", taxonomy.taxonomy.style),
            ("energy", "能量", taxonomy.taxonomy.energy),
            ("vocalType", "人声", taxonomy.taxonomy.vocalType),
        ]
        return pairs.compactMap { id, label, terms in
            guard let terms, !terms.isEmpty else { return nil }
            return (id, label, terms)
        }
    }

    @ViewBuilder
    private func cascadeRows(_ taxonomy: TaxonomyDto) -> some View {
        let dims = dimensions(of: taxonomy)
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CovaSpace.sm) {
                    CovaChip("全部", isSelected: dimension == nil) {
                        dimension = nil; term = nil; Task { await reload() }
                    }
                    ForEach(dims, id: \.id) { dim in
                        CovaChip(dim.label, isSelected: dimension == dim.id) {
                            dimension = dim.id; term = nil; Task { await reload() }
                        }
                    }
                }
                .padding(.horizontal, CovaSpace.pageGutter)
            }
            if let dimension, let dim = dims.first(where: { $0.id == dimension }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CovaSpace.sm) {
                        ForEach(dim.terms, id: \.id) { t in
                            CovaChip(t.label ?? t.id, isSelected: term == t.id) {
                                term = (term == t.id ? nil : t.id); Task { await reload() }
                            }
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                }
            }
        }
        .padding(.bottom, CovaSpace.sm)
    }

    @ViewBuilder
    private var list: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 6)
        case .failed(let failure):
            CovaErrorState(kind: kind(failure)) { Task { await reload() } }
        case .ready, .appending:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        CovaListRow(
                            title: track.titleCn ?? track.title,
                            subtitle: "\(track.artistNameCn ?? track.artist.name) · \(Int(track.duration))s · BPM \(track.bpm)",
                            artwork: CovaArtwork(url: URL(string: track.cover), title: track.title)
                        ) {
                            let on = session.favoriteIDs.contains(track.id)
                            Button {
                                Task {
                                    if session.requireLoginForCollections() {
                                        await session.toggleFavorite(track.id)
                                    }
                                }
                            } label: {
                                Image(systemName: on ? "heart.fill" : "heart")
                                    .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(on ? "取消收藏" : "收藏")
                        } action: {
                            Task { await session.play(tracks: tracks, at: index) }
                        }
                        .contextMenu {
                            Button("曲目详情") { session.detailTrackID = track.id }
                            Button("查看艺人") { session.path.append(.artist(track.artist.id)) }
                        }
                    }
                    if page < totalPages {
                        CovaButton(phase == .appending ? "加载中…" : "加载更多", style: .secondary) {
                            Task { await append() }
                        }
                        .padding(CovaSpace.lg)
                    }
                }
            }
        }
    }

    private func kind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
        switch failure {
        case .network: return .network
        case .server: return .server
        case .unauthenticated: return .unauthenticated
        case .backendGap(let id): return .backendGap(id)
        }
    }

    private func loadTaxonomy() async {
        taxonomy = try? await catalog.taxonomy()
    }

    private func reload() async {
        phase = .loading
        do {
            let loaded = try await catalog.tracks(
                dimension: dimension, term: term,
                query: query.isEmpty ? nil : query, page: 1
            )
            tracks = loaded.tracks
            page = 1
            totalPages = loaded.totalPages ?? 1
            phase = .ready
        } catch {
            phase = .failed(CatalogService.classify(error))
        }
    }

    private func append() async {
        phase = .appending
        do {
            let loaded = try await catalog.tracks(
                dimension: dimension, term: term,
                query: query.isEmpty ? nil : query, page: page + 1
            )
            tracks += loaded.tracks
            page += 1
            phase = .ready
        } catch {
            phase = .ready   // 追加分页失败不清空已有列表
            session.showToast("加载更多失败，可重试", isError: true)
        }
    }
}
