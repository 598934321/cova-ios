import CovaCore
import CovaUI
import SwiftUI

/// 曲库（design 03）：级联筛选 + 已选 chips + 计数/排序 + 分页 + 播放。
///
/// 筛选的**判断**不在这里（维度表、级联树、选择态、请求编码全在 `CovaCore/LibraryFilter.swift`，
/// 那边有 31 条断言）；本文件只把它画出来：
/// · §1 已选 chips 行（有筛选才出现，逐个 ✕ 移除 + 「清除全部」）
/// · §2 维度 chip → 底部 **70% modal 面板**：风格维度是三栏级联（真数据支持，见下面"数据事实"），
///   其余维度是单栏多选网格；面板顶部搜索本维度词条，底部「清除」/「完成（已选 n）」
/// · §1/§5 结果计数（服务端 `total`）+ 排序 sheet（四档全部实测为服务端档位）
///
/// ## 数据事实（2026-09-26 只读探针 `GET /api/library/taxonomy`，只打印键名与数组长度）
/// 层级不是 children 字段，而是 `subgenre` 词条 `aliases` 里的 `parent:<父label>`：
/// 54/54 条 subgenre 都带 parent，其中 47 条挂在 genre 上（二级）、**7 条挂在另一条 subgenre
/// 上**（三级）⇒ 03 §2 的「一级大类 → 二级 subgenre → 三级延伸」在数据上成立，只是第三级稀疏。
/// 场景维度本应有同构的二级（`subscene` 60 条全带 parent），但 `TaxonomyDimensionsDto` 里
/// **没有 `subscene` 字段**、Codable 静默丢弃 ⇒ 场景今天只能画一级。这条不是这里能修的，
/// 已写进交给协调者的接线清单。
///
/// 面板的勾选与下钻是**两个钮**（行 = 勾选，右侧箭头 = 进入下一级）。这是 web 侧 M38 的用户
/// 定稿口径：「勾选和进入三级界面要做区分，现在是进入三级界面就默认勾选了一次二级界面选项」
/// （`web/src/components/taxonomy/TaxonomyCascadeMenu.tsx` 的 `drillAction` 注释）。
public struct LibraryView: View {
    @Environment(AppSession.self) private var session
    private let catalog: CatalogService
    /// 词表摊平结果（取到词表时算一次；DTO 原始载荷不留 —— 级联只认这一份）。
    /// 326 条词条 + 建树不在每次 body 里做。
    @State private var dimensions: [LibraryFilterDimension] = []
    @State private var selection = LibraryFilterSelection()
    /// 03 §7 的艺人预填（01 §6 音乐人栏点进来）：它是 `artistId` 参数，**不是** taxonomy 维度，
    /// 所以进不了 `selection`（那本账的键必须是维度名，硬塞会让 chips 与请求编码两头撒谎）。
    /// 但它同样是一枚**生效中的筛选** ⇒ 在 §1 的已选行里画得出、也撤得掉。
    @State private var presetArtistID: String?
    @State private var presetArtistLabel: String?
    @State private var sort: LibrarySort = .recommended
    @State private var query = ""
    @State private var tracks: [TrackDto] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var total: Int?
    @State private var phase: Phase = .loading
    @State private var searchTask: Task<Void, Never>?
    @State private var panel: Panel?

    private enum Phase: Equatable { case loading, ready, failed(CatalogFailure), appending }

    /// 屏上三种底部面板（同一时刻只有一个）。
    private enum Panel: Identifiable {
        case cascade(String)
        case sort
        case moreDimensions

        var id: String {
            switch self {
            case .cascade(let dimension): return "cascade:\(dimension)"
            case .sort: return "sort"
            case .moreDimensions: return "more"
            }
        }
    }

    public init(catalog: CatalogService) { self.catalog = catalog }

    // MARK: 可断言的判据（SwiftUI 装配本身不在覆盖之内，这几条是屏上真正说了算的数）

    /// §2：级联面板占屏 **70%**（第二档 92% 给词条多的风格维度）；AX 档（≥AX1）近全屏 ——
    /// 放大字下 70% 会把词条行挤出可视区。机制沿用 `DetailViews.swift` 的两档吸附 + AX 单档。
    static func cascadeDetents(axLayout: Bool) -> Set<PresentationDetent> {
        axLayout ? [.large] : [.fraction(0.7), .fraction(0.92)]
    }

    /// §5：排序 sheet 四行，不需要两档吸附。
    static func sortDetents(axLayout: Bool) -> Set<PresentationDetent> {
        axLayout ? [.large] : [.fraction(0.42)]
    }

    /// §2「+」展开全部维度的 sheet 高度档。
    static func dimensionListDetents(axLayout: Bool) -> Set<PresentationDetent> {
        axLayout ? [.large] : [.fraction(0.5)]
    }

    /// 点选被上限拒绝时的话术：说清是多少、以及下一步做什么（不能只说「太多了」）。
    static func limitToast(for dimension: LibraryFilterDimension) -> String {
        "\(dimension.title)最多选 \(LibraryFilterSelection.maxValuesPerDimension) 项，先移除一项"
    }

    /// §2 末「无结果」两行的口径：**没有筛选时不该劝人清除**（没东西可清）。
    static func emptyStateHint(selectionEmpty: Bool) -> String? {
        selectionEmpty ? nil : "试试放宽条件"
    }

    static func emptyStateActionTitle(selectionEmpty: Bool) -> String? {
        selectionEmpty ? nil : "清除全部筛选"
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !dimensions.isEmpty {
                dimensionStrip
            }
            if hasActiveFilters {
                selectedChipsRow
            }
            resultHeader
            list
        }
        .covaPage()
        // 04 §1 入口①：曲库是**顶层屏**，按 04 的口径这一屏的顶栏左上就是抽屉入口。
        // 03 §1 的导航条画的是 `[←] 曲库 [搜索]`（Tab 根屏的 `←` 在本 App 里没有对应动作，
        // 搜索栏则已在 §3 以页面内常驻的形式实现）⇒ 左上这个空位给触发钮，不与 03 的既有元素抢位。
        // 03 的整条玻璃导航条（标题 + 右上搜索钮）仍是未实现项，这枚钮不替它充数。
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerTrigger(opener: .library)
            }
        }
        .task {
            consumeLibraryPreset()
            await loadTaxonomy()
            await reload()
        }
        .sheet(item: $panel) { presented in
            switch presented {
            case .cascade(let id):
                if let dimension = dimension(named: id) {
                    LibraryCascadePanel(
                        dimension: dimension,
                        initial: selection,
                        onCommit: { committed in
                            selection = committed
                            panel = nil
                            Task { await reload() }
                        }
                    )
                }
            case .sort:
                LibrarySortPanel(sort: sort) { picked in
                    sort = picked
                    panel = nil
                    Task { await reload() }
                }
            case .moreDimensions:
                LibraryDimensionListPanel(
                    dimensions: hiddenDimensions,
                    counts: { selection.count(in: $0) },
                    onPick: { id in panel = .cascade(id) }
                )
            }
        }
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

    // MARK: - §2 维度 chips 条

    @ViewBuilder
    private var dimensionStrip: some View {
        let inline = Array(dimensions.prefix(LibraryFilterSchema.inlineDimensionCount))
        let hidden = dimensions.dropFirst(LibraryFilterSchema.inlineDimensionCount)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.sm) {
                ForEach(inline, id: \.id) { dim in
                    CovaChip(dim.title, isSelected: selection.count(in: dim.id) > 0) {
                        panel = .cascade(dim.id)
                    }
                    .accessibilityLabel(
                        selection.count(in: dim.id) > 0
                            ? "筛选维度 \(dim.title)，已选 \(selection.count(in: dim.id)) 项"
                            : "筛选维度 \(dim.title)"
                    )
                }
                if !hidden.isEmpty {
                    CovaChip("＋ 更多", isSelected: false) { panel = .moreDimensions }
                        .accessibilityLabel("展开全部筛选维度")
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .frame(minHeight: 44)
        }
    }

    private var hiddenDimensions: [LibraryFilterDimension] {
        Array(dimensions.dropFirst(LibraryFilterSchema.inlineDimensionCount))
    }

    private func dimension(named id: String) -> LibraryFilterDimension? {
        dimensions.first { $0.id == id }
    }

    // MARK: - §1 已选 chips 行

    private var selectedChipsRow: some View {
        let chips = selection.chips()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.sm) {
                Text("已选：").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                ForEach(chips, id: \.self) { chip in
                    Button {
                        selection.remove(dimension: chip.dimension, value: chip.value)
                        Task { await reload() }
                    } label: {
                        HStack(spacing: CovaSpace.xs) {
                            Text(chip.value).font(CovaType.subhead)
                                .foregroundStyle(CovaColor.accentText)
                            Image(systemName: "xmark").font(CovaType.caption)
                                .foregroundStyle(CovaColor.accentText)
                        }
                        .padding(.horizontal, CovaSpace.md)
                        .padding(.vertical, CovaSpace.sm)
                        .background(Capsule().fill(CovaColor.accentSoft))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除筛选 \(chip.dimensionTitle) \(chip.value)")
                }
                // 艺人预填也是"已选"里的一项：发出去了却不上屏的筛选，用户没法解释
                // 也没法撤（03 §1 那一行的全部意义就是让生效中的筛选看得见）。
                if let presetArtistID {
                    Button {
                        clearArtistPreset()
                        Task { await reload() }
                    } label: {
                        HStack(spacing: CovaSpace.xs) {
                            Text("艺人 · \(presetArtistLabel ?? presetArtistID)").font(CovaType.subhead)
                                .foregroundStyle(CovaColor.accentText)
                            Image(systemName: "xmark").font(CovaType.caption)
                                .foregroundStyle(CovaColor.accentText)
                        }
                        .padding(.horizontal, CovaSpace.md)
                        .padding(.vertical, CovaSpace.sm)
                        .background(Capsule().fill(CovaColor.accentSoft))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除筛选 艺人 \(presetArtistLabel ?? presetArtistID)")
                }
                Button {
                    clearAllFilters()
                    Task { await reload() }
                } label: {
                    Text("清除全部").font(CovaType.subhead)
                        .foregroundStyle(CovaColor.secondary)
                        .padding(.horizontal, CovaSpace.md)
                        .padding(.vertical, CovaSpace.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除全部筛选")
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .frame(minHeight: 44)
        }
    }

    // MARK: - §1/§5 计数 + 排序

    private var resultHeader: some View {
        HStack {
            // 计数只说服务端给的 `total`；没给就留空，不拿本页行数冒充全库数。
            Text(LibraryResultCount.text(total: total) ?? " ")
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .accessibilityLabel(total.map { "共 \(LibraryResultCount.grouped($0)) 首" } ?? "曲目数量未知")
            Spacer()
            Button { panel = .sort } label: {
                HStack(spacing: CovaSpace.xs) {
                    Text("排序 · \(sort.label)").font(CovaType.subhead)
                        .foregroundStyle(CovaColor.fg)
                    Image(systemName: "chevron.down").font(CovaType.caption)
                        .foregroundStyle(CovaColor.muted)
                }
                .padding(.horizontal, CovaSpace.md)
                .padding(.vertical, CovaSpace.sm)
                .background(Capsule().fill(CovaColor.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("排序，当前 \(sort.label)，\(sort.detail)")
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .frame(minHeight: 44)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 6)
        case .failed(let failure):
            CovaErrorState(kind: kind(failure)) { Task { await reload() } }
        case .ready, .appending:
            if tracks.isEmpty {
                CovaEmptyState(
                    symbol: "magnifyingglass",
                    title: "没有符合条件的曲目",
                    hint: LibraryView.emptyStateHint(selectionEmpty: !hasActiveFilters),
                    actionTitle: LibraryView.emptyStateActionTitle(selectionEmpty: !hasActiveFilters)
                ) {
                    guard hasActiveFilters else { return }
                    clearAllFilters()
                    Task { await reload() }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        CovaListRow(
                            title: track.titleCn ?? track.title,
                            subtitle: "\(track.artistNameCn ?? track.artist.name) · \(Int(track.duration))s · BPM \(track.bpm)",
                            artwork: CovaArtwork(resolution: LibraryArtwork.cover(track), title: track.title)
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
                    } else if !tracks.isEmpty {
                        // §5：到底了要说一句，别让人以为还能往下刷。
                        Text("已加载全部")
                            .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                            .accessibilityLabel("已加载全部 \(LibraryResultCount.text(total: total) ?? "")")
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

    // MARK: - 取数

    // MARK: - 03 §7 的跨屏预填（01 §6 音乐人栏 → 曲库）

    /// 屏上有**任何**一枚生效中的筛选吗（维度 chips + 那颗艺人预填）。
    /// §1 的已选行、空态那句「试试放宽条件」与「清除全部」都读这一条 —— 否则艺人筛选单独
    /// 生效时，那一行既不存在也撤不掉。
    private var hasActiveFilters: Bool { !selection.isEmpty || presetArtistID != nil }

    /// 只撤艺人那一枚：它不在 `selection` 里，`clearAll()` 碰不到它。
    private func clearArtistPreset() {
        presetArtistID = nil
        presetArtistLabel = nil
    }

    /// 「清除全部」清的是屏上画得出的**每一项**，漏掉那颗预填就是一句做不到的承诺。
    private func clearAllFilters() {
        selection.clearAll()
        clearArtistPreset()
    }

    /// 取走 01 递过来的预填载荷：`consumeLibraryPreset()` **读到即销**，所以第二次进屏
    /// （用户已经自己筛过一轮）不会被同一个 artistId 悄悄重放一遍。
    /// 维度部分走 `LibraryFilterSelection.merge`（合并去重、带上限），艺人是独立参数键。
    private func consumeLibraryPreset() {
        guard let preset = session.consumeLibraryPreset() else { return }
        presetArtistID = preset.artistID
        presetArtistLabel = preset.artistLabel
        selection.merge(preset.dimensions)
    }

    private func loadTaxonomy() async {
        guard let loaded = try? await catalog.taxonomy() else { return }
        dimensions = LibraryFilterSchema.dimensions(from: loaded)
    }

    /// 03 §2 的取数腿：**跨维度**多选（场景 AND 情绪 AND 风格…）。
    ///
    /// 为什么不走 `catalog.tracks(dimension:term:terms:)`：那条腿只能带**一个**维度（E3a 的
    /// 形态），而 §1 的「已选：咖啡馆 ✕ 平静 ✕」是场景 + 情绪两维同时生效 —— 走它会让第二个
    /// 维度的 chips 变成屏上的谎（画着但没发出去）。本批的文件边界不允许改 `CatalogService`，
    /// 所以这里按同一份实测编码（`LibraryFilterSelection.queryItems`）直连一次：路径、
    /// 分页两键、`search` 键名与 `CatalogService.tracks` 逐字相同，失败分类也复用它。
    /// 交给协调者的接线：把它折进 `CatalogService.tracks(query:page:pageSize:)` 后删掉本函数。
    private func requestTracks(page: Int) async throws -> TrackPageDto {
        try await session.client.get(
            "/api/tracks",
            queryItems: selection.queryItems(
                search: query, sort: sort, artistID: presetArtistID, page: page
            )
        )
    }

    private func reload() async {
        phase = .loading
        do {
            let loaded = try await requestTracks(page: 1)
            tracks = loaded.tracks
            page = 1
            total = loaded.total
            totalPages = loaded.totalPages ?? 1
            phase = .ready
        } catch {
            phase = .failed(CatalogService.classify(error))
        }
    }

    private func append() async {
        phase = .appending
        do {
            let loaded = try await requestTracks(page: page + 1)
            tracks += loaded.tracks
            page += 1
            total = loaded.total ?? total
            phase = .ready
        } catch {
            phase = .ready   // 追加分页失败不清空已有列表
            session.showToast("加载更多失败，可重试", isError: true)
        }
    }
}

// MARK: - §2 级联选择面板

/// 维度选择面板：风格维度 = 三栏级联（有 `parent:` 链才画，没链就退回单栏网格），
/// 其余维度 = 单栏多选网格。面板改的是**草稿**，「完成」才提交 —— 与 §2 底部那颗
/// 「完成（已选 n）」胶囊一致，也避免每点一个词条就打一次网络。
private struct LibraryCascadePanel: View {
    @Environment(AppSession.self) private var session
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dimension: LibraryFilterDimension
    private let tree: [LibraryCascadeNode]
    private let onCommit: (LibraryFilterSelection) -> Void
    @State private var draft: LibraryFilterSelection
    @State private var search = ""
    /// `path[level]` = 该栏当前展开的节点值。
    @State private var path: [String] = []

    init(
        dimension: LibraryFilterDimension,
        initial: LibraryFilterSelection,
        onCommit: @escaping (LibraryFilterSelection) -> Void
    ) {
        self.dimension = dimension
        self.tree = LibraryFilterSchema.cascadeTree(of: dimension)
        self.onCommit = onCommit
        _draft = State(initialValue: initial)
    }

    private var hasHierarchy: Bool { tree.contains { !$0.children.isEmpty } }

    /// tokens `motion.duration.fast` = 240ms；Reduce Motion 时退化为淡入（§6）。
    private var cascadeAnimation: Animation? {
        reduceMotion ? .easeIn(duration: 0.24) : .spring(response: 0.24, dampingFraction: 0.9)
    }

    private var filteredTree: [LibraryCascadeNode] {
        LibraryFilterSchema.filtering(tree, matching: search)
    }

    /// 单栏网格用的平铺词表（非级联维度，或级联维度里搜索命中的叶子）。
    private var flatTerms: [LibraryFilterTerm] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return dimension.terms }
        return dimension.terms.filter { $0.value.localizedCaseInsensitiveContains(needle) }
    }

    private var columns: [[LibraryCascadeNode]] {
        var cols: [[LibraryCascadeNode]] = [filteredTree]
        var level = filteredTree
        for value in path {
            guard let node = level.first(where: { $0.term.value == value }),
                  !node.children.isEmpty else { break }
            cols.append(node.children)
            level = node.children
        }
        return cols
    }

    private var selectedCount: Int { draft.count(in: dimension.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CovaColor.line)
            content
            footer
        }
        .background(CovaColor.elevated)
        .presentationDetents(LibraryView.cascadeDetents(axLayout: axLayout))
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            Text(dimension.title)
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            HStack(spacing: CovaSpace.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(CovaColor.muted)
                    .accessibilityHidden(true)
                TextField("搜索\(dimension.title)词条", text: $search)
                    .font(CovaType.callout).foregroundStyle(CovaColor.fg)
                    .onChange(of: search) { _, newValue in
                        withAnimation(cascadeAnimation) {
                            path = LibraryFilterSchema.expansionPath(tree, matching: newValue)
                        }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(CovaColor.muted)
                    }
                    .accessibilityLabel("清除词条搜索")
                }
            }
            .padding(CovaSpace.md)
            .background(Capsule().fill(CovaColor.surface))
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.top, CovaSpace.lg)
        .padding(.bottom, CovaSpace.md)
    }

    @ViewBuilder
    private var content: some View {
        if hasHierarchy && axLayout {
            // AX 档：三栏并排在放大字下必然被挤没 ⇒ 一层一屏 + 「上一层」返回行
            // （web 侧 `drillDown` 模式同一个解法）。
            let depth = max(0, columns.count - 1)
            columnView(columns[depth], level: depth, showBack: depth > 0)
        } else if hasHierarchy {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(columns.indices, id: \.self) { level in
                        columnView(columns[level], level: level, showBack: false)
                            .frame(width: 148)
                    }
                }
                .animation(cascadeAnimation, value: path)
                .padding(.horizontal, CovaSpace.pageGutter)
            }
        } else {
            flatGrid
        }
    }

    private func columnView(
        _ nodes: [LibraryCascadeNode], level: Int, showBack: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CovaSpace.xs) {
                if showBack {
                    Button {
                        withAnimation(cascadeAnimation) { path = Array(path.dropLast()) }
                    } label: {
                        HStack(spacing: CovaSpace.xs) {
                            Image(systemName: "chevron.left")
                            Text("上一层")
                        }
                        .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回上一层")
                }
                if nodes.isEmpty {
                    Text("这一级没有词条")
                        .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                        .padding(.vertical, CovaSpace.md)
                }
                ForEach(nodes) { node in
                    termRow(node, level: level)
                }
            }
            .padding(.vertical, CovaSpace.sm)
        }
        .frame(maxWidth: .infinity)
    }

    /// 一行：**行本身只勾选**，右侧箭头才下钻（web M38 的用户定稿口径）。
    private func termRow(_ node: LibraryCascadeNode, level: Int) -> some View {
        let checked = draft.isSelected(dimension: dimension.id, value: node.term.value)
        let expanded = path.indices.contains(level) && path[level] == node.term.value
        return HStack(spacing: 0) {
            Button { toggle(node) } label: {
                HStack(spacing: CovaSpace.sm) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? CovaColor.accent : CovaColor.muted)
                    Text(node.term.value)
                        .font(CovaType.subhead)
                        .foregroundStyle(CovaColor.fg)
                        .lineLimit(axLayout ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, CovaSpace.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(node.term.value)\(checked ? "，已选" : "")")
            .accessibilityAddTraits(checked ? .isSelected : [])
            if !node.children.isEmpty {
                Button { drill(node, level: level) } label: {
                    Image(systemName: "chevron.right")
                        .font(CovaType.subhead)
                        .foregroundStyle(CovaColor.secondary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("进入 \(node.term.value) 下一级")
            }
        }
        .padding(.horizontal, CovaSpace.sm)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.control - 4, style: .continuous)
                .fill(expanded ? CovaColor.accentSoft : .clear)
        )
    }

    private var flatGrid: some View {
        let terms = flatTerms
        return ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: axLayout ? 200 : 132), spacing: CovaSpace.sm)],
                spacing: CovaSpace.sm
            ) {
                ForEach(terms, id: \.value) { term in
                    let checked = draft.isSelected(dimension: dimension.id, value: term.value)
                    Button { toggle(term.value) } label: {
                        HStack(spacing: CovaSpace.sm) {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? CovaColor.accent : CovaColor.muted)
                            Text(term.value)
                                .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                                .lineLimit(axLayout ? 2 : 1)
                            Spacer(minLength: 0)
                        }
                        .padding(CovaSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                                .fill(checked ? CovaColor.accentSoft : CovaColor.surface)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(term.value)\(checked ? "，已选" : "")")
                    .accessibilityAddTraits(checked ? .isSelected : [])
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.md)
        }
    }

    private var footer: some View {
        HStack(spacing: CovaSpace.md) {
            Button {
                draft.clear(dimension: dimension.id)
            } label: {
                Text("清除")
                    .font(CovaType.headline)
                    .foregroundStyle(CovaColor.fg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(CovaColor.surface))
                    .overlay(Capsule().strokeBorder(CovaColor.line, lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除本维度已选 \(selectedCount) 项")
            Button {
                onCommit(draft)
            } label: {
                Text("完成（已选 \(selectedCount)）")
                    .font(CovaType.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(CovaColor.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成选择，应用 \(selectedCount) 项筛选")
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .padding(.vertical, CovaSpace.md)
    }

    private func toggle(_ node: LibraryCascadeNode) { toggle(node.term.value) }

    private func toggle(_ value: String) {
        switch draft.toggle(dimension: dimension.id, value: value) {
        case .rejectedByLimit:
            session.showToast(LibraryView.limitToast(for: dimension), isError: true)
        case .ignored:
            break
        case .added, .removed:
            break
        }
    }

    private func drill(_ node: LibraryCascadeNode, level: Int) {
        withAnimation(cascadeAnimation) {
            path = Array(path.prefix(level)) + [node.term.value]
        }
    }
}

// MARK: - §5 排序面板

/// 四档排序 = 服务端 `sort` 的四个实测存在的档位（客户端不做二次排序，见 `LibrarySort`）。
private struct LibrarySortPanel: View {
    @Environment(\.covaAXLayout) private var axLayout
    private let sort: LibrarySort
    private let onPick: (LibrarySort) -> Void

    init(sort: LibrarySort, onPick: @escaping (LibrarySort) -> Void) {
        self.sort = sort
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("排序")
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                .padding(.horizontal, CovaSpace.pageGutter)
                .padding(.top, CovaSpace.lg)
                .padding(.bottom, CovaSpace.md)
            ForEach(LibrarySort.allCases) { option in
                Button { onPick(option) } label: {
                    HStack(spacing: CovaSpace.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(CovaType.body).foregroundStyle(CovaColor.fg)
                                .lineLimit(axLayout ? 2 : 1)
                            Text(option.detail)
                                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                                .lineLimit(axLayout ? 2 : 1)
                        }
                        Spacer()
                        if option == sort {
                            Image(systemName: "checkmark")
                                .foregroundStyle(CovaColor.accent)
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("按\(option.label)排序，\(option.detail)")
                .accessibilityAddTraits(option == sort ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(CovaColor.elevated)
        .presentationDetents(LibraryView.sortDetents(axLayout: axLayout))
        .presentationDragIndicator(.visible)
    }
}

// MARK: - §2「+」展开全部维度

private struct LibraryDimensionListPanel: View {
    @Environment(\.covaAXLayout) private var axLayout
    private let dimensions: [LibraryFilterDimension]
    private let counts: (String) -> Int
    private let onPick: (String) -> Void

    init(
        dimensions: [LibraryFilterDimension],
        counts: @escaping (String) -> Int,
        onPick: @escaping (String) -> Void
    ) {
        self.dimensions = dimensions
        self.counts = counts
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("全部筛选维度")
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                .padding(.horizontal, CovaSpace.pageGutter)
                .padding(.top, CovaSpace.lg)
                .padding(.bottom, CovaSpace.md)
            ForEach(dimensions, id: \.id) { dim in
                let picked = counts(dim.id)
                Button { onPick(dim.id) } label: {
                    HStack {
                        Text(dim.title).font(CovaType.body).foregroundStyle(CovaColor.fg)
                            .lineLimit(axLayout ? 2 : 1)
                        Spacer()
                        if picked > 0 {
                            Text("\(picked)").font(CovaType.mono).foregroundStyle(CovaColor.accentText)
                        }
                        Image(systemName: "chevron.right").font(CovaType.subhead)
                            .foregroundStyle(CovaColor.muted)
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(picked > 0 ? "筛选维度 \(dim.title)，已选 \(picked) 项" : "筛选维度 \(dim.title)")
            }
            Spacer(minLength: 0)
        }
        .background(CovaColor.elevated)
        .presentationDetents(LibraryView.dimensionListDetents(axLayout: axLayout))
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 美术腿（R18-2）

/// 03 屏曲库行的封面腿（`track.cover`）。
///
/// 判据在 `CovaArtworkResolution`（CovaUI 唯一裁决面），这里只回答「哪个字段进哪个槽」。
/// 线上实测（2026-09-25 只读核对，见 D23 的名单补充）：`GET /api/tracks` 的 `cover` 是
/// **绝对地址且 20/20 落在封面桶**，而同一份响应里**内嵌**的 `artist.avatar` 是 11 行站内相对
/// + 9 行没有 —— 同一屏两种形态并存，所以每一腿都得先裁决再交图，不能按"这张一直是绝对"押注。
/// 押错的代价落在**分页列表**上：一屏封面全空，而画面读起来只是"没图"（R16-1 同族）。
enum LibraryArtwork {
    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }
}
