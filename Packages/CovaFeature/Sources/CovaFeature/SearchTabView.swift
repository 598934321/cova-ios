import CovaCore
import CovaUI
import SwiftUI

/// 搜索页签根屏（design 25）：落地页（历史 + 分类浏览）与输入态（结果列表 +
/// 吸顶筛选条）共用一屏。`Tab(role:.search)` 的栏位由系统在 `CovaRootView` 声明，
/// 本屏只是那棵 `NavigationStack` 的根视图。
///
/// 三条本屏特有的判据：
/// · **`sort` 不传**（§7：服务端默认，禁 `relevance` —— 无 search 的 relevance 已知 500）。
///   实现上是先走 `LibraryFilterSelection.queryItems` 的闭集编码再把 `sort`/`artistId`
///   两键剔掉：参数名的合法集仍由那一处作者，本屏只减不增。
/// · **历史只记「执行过」的词**（§3.C 沿用原 03 口径）：`.searchable` 的 submit 与历史
///   chip 的点击记；300ms 防抖驱动的搜索**不记**（取消回退的词不入账）。
/// · **分类区失败静默隐藏**（§4：浏览入口是增强件，不是本体）。
public struct SearchTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.covaAXLayout) private var axLayout
    private let catalog: CatalogService

    @State private var query = ""
    /// 词表（分类卡 + 输入态筛选条共用同一份摊平结果，326 词条不在 body 里反复摊）。
    @State private var dimensions: [LibraryFilterDimension] = []
    /// 词表取数的三格：加载中（骨架卡）/ 就绪 / 失败（静默隐藏 §4）。
    @State private var taxonomyPhase: TaxonomyPhase = .loading
    /// 输入态的跨维度筛选（叠加进同一请求，§3.B）。
    @State private var selection = LibraryFilterSelection()
    @State private var results: [TrackDto] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var total: Int?
    @State private var phase: Phase = .idle
    /// 已真正发起过的那个词（防抖去重的判据：chip 填入已立即执行过的话，
    /// onChange 排下的防抖任务到期时认得出来、不再重发一枪）。
    @State private var executedQuery: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var panel: Panel?

    private enum Phase: Equatable { case idle, loading, ready, appending, failed(CatalogFailure) }
    private enum TaxonomyPhase: Equatable { case loading, ready, failed }

    /// 屏上两种底部面板（复用 03 §2 的件；没有「排序」那一档 —— 本屏不发 sort）。
    private enum Panel: Identifiable {
        case cascade(String)
        case moreDimensions
        var id: String {
            switch self {
            case .cascade(let dimension): return "cascade:\(dimension)"
            case .moreDimensions: return "more"
            }
        }
    }

    public init(catalog: CatalogService) { self.catalog = catalog }

    /// 去空白后的检索词；`nil` = 落地页（§3.A：输入即搜只对非空词生效）。
    private var trimmedQuery: String? {
        WorksListQuery.textIfPresent(query)
    }

    public var body: some View {
        Group {
            if trimmedQuery != nil {
                resultsBody
            } else {
                landingBody
            }
        }
        .covaPage()
        .navigationTitle("搜索")
        .toolbarTitleDisplayMode(.large)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "搜索曲名 / 艺人 / 标签"
        )
        // 显式执行（Return/搜索键）= 记历史 + 立即搜（§3.C「执行过搜索的词才入历史」）。
        .onSubmit(of: .search) { executeCurrentQuery() }
        // 300ms 防抖（§3.B 输入即搜）；空文本回落落地页。
        .onChange(of: query) { _, _ in scheduleDebouncedSearch() }
        .task { await loadTaxonomy() }
        .sheet(item: $panel) { presented in
            switch presented {
            case .cascade(let id):
                if let dimension = dimensions.first(where: { $0.id == id }) {
                    LibraryCascadePanel(
                        dimension: dimension,
                        initial: selection,
                        onCommit: { committed in
                            selection = committed
                            panel = nil
                            // 筛选叠加进同一请求（§3.B）：换筛选立即重搜。
                            execute(trimmedQuery, record: false)
                        }
                    )
                }
            case .moreDimensions:
                LibraryDimensionListPanel(
                    dimensions: Array(dimensions.dropFirst(LibraryFilterSchema.inlineDimensionCount)),
                    counts: { selection.count(in: $0) },
                    onPick: { panel = .cascade($0) }
                )
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - 落地页（C 搜索历史 + D 分类浏览）

    @ViewBuilder
    private var landingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.xl) {
                historySection
                categoriesSection
            }
            .padding(.vertical, CovaSpace.md)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// C 搜索历史（§3.C）：最多 10 条本地账（owner 绑定在 `AppSession` 那侧），
    /// 行尾「清空」、单删走 chip 内 ✕；点 chip = 填入并**立即**执行 + 记历史。
    /// 空历史 → 整区不渲染（不留标题）。
    @ViewBuilder
    private var historySection: some View {
        let history = session.librarySearchHistory
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                HStack {
                    Text("最近搜索")
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    Spacer()
                    Button("清空") { session.clearLibrarySearchHistory() }
                        .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                        .buttonStyle(.plain)
                        .frame(minHeight: ShellMetrics.touchMin)
                        .accessibilityLabel("清空搜索历史")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("最近搜索，\(history.count) 项")
                ChipFlowLayout(spacing: CovaSpace.sm) {
                    ForEach(history, id: \.self) { term in
                        historyChip(term)
                    }
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
        }
    }

    /// 历史 chip：点词条本体 = 填入 + 立即搜 + 记历史；chip 内 ✕ = 单删。
    private func historyChip(_ term: String) -> some View {
        HStack(spacing: 0) {
            Button {
                runFromHistory(term)
            } label: {
                Text(term)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .padding(.leading, CovaSpace.md)
                    .padding(.vertical, CovaSpace.sm)
                    .frame(minHeight: ShellMetrics.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索 \(term)")
            Button {
                session.removeLibrarySearchTerm(term)
            } label: {
                Image(systemName: "xmark")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除搜索记录 \(term)")
        }
        .background(Capsule().fill(CovaColor.surface))
        .contentShape(Capsule())
    }

    /// D 分类浏览（§3.D）：三维各取 `parent == nil` 的前 8 项；不足 4 项整组不渲染；
    /// 词表加载中 = 6 张呼吸卡，失败 = 静默隐藏（§4）。
    @ViewBuilder
    private var categoriesSection: some View {
        switch taxonomyPhase {
        case .loading:
            categorySkeleton
        case .ready:
            let groups = categoryGroups
            if groups.isEmpty, session.librarySearchHistory.isEmpty {
                // §8：两区皆空 → 落地页只留搜索栏 + 17-S2 简版空态。
                CovaEmptyState(symbol: "magnifyingglass", title: "输入关键词找歌")
                    .padding(.top, CovaSpace.xxl)
            } else {
                ForEach(groups) { group in
                    categoryGroup(group)
                }
            }
        case .failed:
            // 分类区失败 → 该区静默隐藏；若历史也空，同样落到简版空态。
            if session.librarySearchHistory.isEmpty {
                CovaEmptyState(symbol: "magnifyingglass", title: "输入关键词找歌")
                    .padding(.top, CovaSpace.xxl)
            }
        }
    }

    /// 分类卡骨架（§4：6 张卡块呼吸，形状照真实卡 72 高双列）。
    private var categorySkeleton: some View {
        LazyVGrid(columns: gridColumns, spacing: CovaSpace.md) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .fill(CovaColor.cardSurface)
                    .frame(height: SearchBrowseMetrics.cardHeight)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .accessibilityLabel("加载中")
    }

    /// 一组分类卡：标题 `headline`/`fg` + 双列（AX 单列）72 高卡，左缘 3pt 标识条。
    private func categoryGroup(_ group: SearchCategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            Text(group.title)
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            LazyVGrid(columns: gridColumns, spacing: CovaSpace.md) {
                ForEach(group.terms, id: \.self) { term in
                    categoryCard(term, in: group)
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .accessibilityElement(children: .contain)
    }

    /// §6：AX 档降为单列（卡宽 = 屏宽 − 2×`pageGutter`，高 72 不变）。
    private var gridColumns: [GridItem] {
        axLayout
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: CovaSpace.md), GridItem(.flexible())]
    }

    /// 分类卡：`cardSurface` 底 + 左缘 3pt 标识竖条 + 词条名 `headline` 居中，无封面图
    /// （§3.D：taxonomy 无图数据）。点卡 → 本栈 push `library(preset)`（不切页签）。
    private func categoryCard(_ term: String, in group: SearchCategoryGroup) -> some View {
        Button {
            session.push(.library(AppSession.LibraryPreset(
                dimensions: [group.dimensionID: [term]],
                title: term
            )))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous)
                    .fill(CovaColor.cardSurface)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(group.barColor)
                        .frame(width: 3)
                        .padding(.vertical, CovaSpace.md)
                        .padding(.leading, CovaSpace.md)
                    Spacer(minLength: 0)
                }
                Text(term)
                    .font(CovaType.headline)
                    .foregroundStyle(group.usesAccentText ? CovaColor.accentText : CovaColor.fg)
                    .lineLimit(1)
                    .padding(.horizontal, CovaSpace.lg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SearchBrowseMetrics.cardHeight)
            .contentShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(term)，\(group.spokenDimension)筛选")
    }

    /// 三维卡组的取值表（§3.D 逐字：场景 `tagScene` 条 / 情绪 `tagMood` 条 /
    /// 风格 `accentSoft` 条 + `accentText` 字标）。
    private var categoryGroups: [SearchCategoryGroup] {
        let specs: [(id: String, title: String, bar: Color, accentText: Bool, spoken: String)] = [
            ("scene", "按场景浏览", CovaColor.tagScene, false, "按场景"),
            ("mood", "按情绪浏览", CovaColor.tagMood, false, "按情绪"),
            ("genre", "按风格浏览", CovaColor.accentSoft, true, "按风格"),
        ]
        return specs.compactMap { spec in
            guard let dimension = dimensions.first(where: { $0.id == spec.id }) else { return nil }
            // 「一级」= 无 parent 的词条（genre 的词表把 subgenre 也摊进了同一数组）。
            let terms = dimension.terms.filter { $0.parent == nil }.map(\.value)
            let shown = Array(terms.prefix(SearchBrowseMetrics.groupLimit))
            // 不足 4 项 → 整组不渲染（不出现稀稀拉拉的半行）。
            guard shown.count >= SearchBrowseMetrics.minimumTerms else { return nil }
            return SearchCategoryGroup(
                dimensionID: spec.id, title: spec.title, barColor: spec.bar,
                usesAccentText: spec.accentText, spokenDimension: spec.spoken, terms: shown
            )
        }
    }

    // MARK: - 输入态（B 搜索栏下：吸顶筛选条 + E 结果列表）

    @ViewBuilder
    private var resultsBody: some View {
        VStack(spacing: 0) {
            // §3.B 输入态：筛选条吸顶于搜索栏下（复用 03 §2 件，已选行同规）。
            if !dimensions.isEmpty {
                LibraryDimensionStrip(
                    dimensions: dimensions,
                    selection: selection,
                    onPick: { panel = .cascade($0) },
                    onMore: { panel = .moreDimensions }
                )
            }
            if !selection.isEmpty {
                LibrarySelectedChipsRow(
                    selection: selection,
                    onRemove: { chip in
                        selection.remove(dimension: chip.dimension, value: chip.value)
                        execute(trimmedQuery, record: false)
                    },
                    onClearAll: {
                        selection.clearAll()
                        execute(trimmedQuery, record: false)
                    }
                ) { EmptyView() }
            }
            resultsContent
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        switch phase {
        case .idle, .loading:
            // §4：结果加载 = 8 行骨架（17-S1）。
            CovaSkeleton(rows: 8)
        case .failed(let failure):
            sectionFailure(failure)
        case .ready, .appending:
            if results.isEmpty {
                // §3.E 无结果（17-S2 变体）：「清除搜索回浏览页」= 清空 query 回落地页。
                CovaEmptyState(
                    symbol: "magnifyingglass",
                    title: "没有找到『\(trimmedQuery ?? "")』相关的歌",
                    hint: "换个词，或按分类浏览",
                    actionTitle: "清除搜索回浏览页"
                ) {
                    query = ""
                }
            } else {
                resultList
            }
        }
    }

    /// §4：首载失败 = 列表区错误条 + 重试（不整屏 —— 分类与历史仍能点）；
    /// `.network` 用本屏自己的文案「离线，搜索需要联网」。
    private func sectionFailure(_ failure: CatalogFailure) -> some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(CovaColor.error)
                .accessibilityHidden(true)
            Text(failure == .network ? "离线，搜索需要联网" : failure.uiMessage)
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重试") { execute(trimmedQuery, record: false) }
                .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                .buttonStyle(.plain)
                .frame(minHeight: ShellMetrics.touchMin)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.md)
    }

    /// E 结果列表：行与 03 §4 同一枚 `CovaListRow`（♡ 尾饰 + 详情/艺人菜单），
    /// 分页 = 滚到底自动加载（§5 同 03 的「已加载全部」尾注）。
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                    CovaListRow(
                        title: track.titleCn ?? track.title,
                        subtitle: TrackRowCopy.subtitle(
                            artist: track.artistNameCn ?? track.artist.name,
                            durationSeconds: Int(track.duration),
                            bpm: track.bpm
                        ),
                        artwork: CovaArtwork(
                            resolution: LibraryArtwork.cover(track), title: track.title
                        )
                    ) {
                        let on = session.favoriteIDs.contains(track.id)
                        Button {
                            Task {
                                // §4 未登录行：♡ 仍按 03 §6 弹登录引导。
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
                        Task { await session.play(tracks: results, at: index) }
                    }
                    .contextMenu {
                        Button("曲目详情") { session.detailTrackID = track.id }
                        Button("查看艺人") { session.push(.artist(track.artist.id)) }
                    }
                }
                if page < totalPages {
                    // 自动分页哨兵（§3.E「滚到底自动加载」）：可见即发下一页，
                    // `phase == .appending` 档吞掉滚动抖动带来的重入。
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            guard phase == .ready else { return }
                            searchTask = Task { await loadResults(page: page + 1, appending: true) }
                        }
                    if phase == .appending {
                        ProgressView().padding(CovaSpace.lg)
                    }
                } else {
                    Text("已加载全部")
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                        .accessibilityLabel("已加载全部 \(LibraryResultCount.text(total: total) ?? "")")
                        .padding(CovaSpace.lg)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 取数

    private func loadTaxonomy() async {
        do {
            let loaded = try await catalog.taxonomy()
            dimensions = LibraryFilterSchema.dimensions(from: loaded)
            taxonomyPhase = .ready
        } catch {
            // 分类区失败 → 静默隐藏（§4）。`dimensions` 留空，输入态筛选条也不出现。
            taxonomyPhase = .failed
        }
    }

    /// onChange 防抖腿：词变了先作废在途，300ms 后若词还没变才发。
    /// 与 chip 立即执行的协作：防抖到期时若 `executedQuery` 已等于当前词，说明刚才
    /// 显式执行过 ⇒ 不再重发（同一词的两次请求只是浪费，不是新语义）。
    private func scheduleDebouncedSearch() {
        searchTask?.cancel()
        guard let text = trimmedQuery else {
            executedQuery = nil
            phase = .idle
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard executedQuery != text else { return }
            await loadResults(page: 1, appending: false)
        }
    }

    /// 显式执行（submit / 历史 chip）：记历史 + 立即发，不等防抖。
    private func executeCurrentQuery() {
        guard let text = trimmedQuery else { return }
        session.recordLibrarySearch(text)
        execute(text, record: false)
    }

    /// 历史 chip：填入（触发 onChange 的防抖，但 `executedQuery` 会让它到期自我作废）+
    /// 记历史 + 立即搜（§3.C「点 chip = 填入搜索框并立即执行」）。
    private func runFromHistory(_ term: String) {
        guard let text = WorksListQuery.textIfPresent(term) else { return }
        session.recordLibrarySearch(text)
        query = text
        searchTask?.cancel()
        execute(text, record: false)
    }

    private func execute(_ text: String?, record: Bool) {
        guard let text else { return }
        if record { session.recordLibrarySearch(text) }
        searchTask?.cancel()
        executedQuery = text
        searchTask = Task { await loadResults(page: 1, appending: false) }
    }

    /// 结果的查询编码：`LibraryFilterSelection.queryItems` 负责合法闭集（维度名即参数名、
    /// 注入面校验全在那边），本屏只把 `sort`/`artistId` 两键剔掉 —— §7 明文「sort 不传
    /// （服务端默认），禁 relevance」；本屏也不存在 artistId 预填。
    private func resultQueryItems(text: String, page: Int) -> [URLQueryItem] {
        selection
            .queryItems(search: text, sort: .recommended, page: page)
            .filter { $0.name != "sort" && $0.name != "artistId" }
    }

    private func loadResults(page requested: Int, appending: Bool) async {
        guard let text = trimmedQuery else { phase = .idle; return }
        phase = appending ? .appending : .loading
        do {
            let loaded = try await catalog.tracks(
                queryItems: resultQueryItems(text: text, page: requested)
            )
            executedQuery = text
            if appending {
                results += loaded.tracks
                page += 1
                total = loaded.total ?? total
            } else {
                results = loaded.tracks
                page = 1
                total = loaded.total
            }
            totalPages = loaded.totalPages ?? 1
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            if appending {
                // 追加失败不清列表（03 §5 同一口径）。
                phase = .ready
                session.showToast("加载更多失败，可重试", isError: true)
            } else {
                phase = .failed(CatalogService.classify(error))
            }
        }
    }
}

/// D 区一组分类卡的视图参数（`SearchTabView.categoryGroups` 的返回值形状）。
private struct SearchCategoryGroup: Identifiable {
    let dimensionID: String
    let title: String
    let barColor: Color
    /// 风格组的名字用 `accentText`（§3.D 逐字）；其余两组用 `fg`。
    let usesAccentText: Bool
    /// 朗读用的维度名（「{词条}，按场景筛选，按钮」）。
    let spokenDimension: String
    let terms: [String]
    var id: String { dimensionID }
}

/// 本屏的几何档（Token 缺口 TG-07 分类卡高 72 / TG-03 触控 44，spec 文末登记）。
private enum SearchBrowseMetrics {
    static let cardHeight: CGFloat = 72
    /// §3.D：每维度前 8 项；不足 4 项整组不渲染。
    static let groupLimit = 8
    static let minimumTerms = 4
}
