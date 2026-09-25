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
    /// §8 并发：收藏写请求在途 ⇒ 按钮内嵌菊花、第二次点击被吞。
    @State private var saveInFlight = false

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
                            artwork: CovaArtwork(resolution: PlaylistDetailArtwork.cover(track), title: track.title)
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
            resolution: PlaylistDetailArtwork.hero(playlist),
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
                // §8「头图标题中文优先 **2 行**」+ §6「AX 档 C 文本换 2 行」⇒ 上限就是 2 行，
                // 不是不限行：旧实现没写 `lineLimit`，长标题把元信息/简介一路顶出首屏。
                // 截断读法按 TG-17（中文按字、英文按词）由系统尾截承担，不自行加「…」文案。
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(parts.joined(separator: " · "))
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    /// 06 §3.E 操作行：**两**枚按钮（播放全部 / 收藏），不是只有一枚主钮。
    /// §6 + §9 判据第 6 条：AX 档下两钮**上下堆叠、各占满宽**；默认档一行两钮，
    /// 主钮吃掉「屏宽 − 2×`spacing.pageGutter` − 收藏钮占位」那一段。
    private var actions: some View {
        let stacked = PlaylistActionRowFacts.stacksVertically(axLayout: axLayout)
        return Group {
            if stacked {
                VStack(spacing: CovaSpace.sm) {
                    playAllButton(stretches: true)
                    saveButton(stretches: true)
                }
            } else {
                HStack(spacing: CovaSpace.md) {
                    playAllButton(stretches: true)
                    saveButton(stretches: false)
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    private func playAllButton(stretches: Bool) -> some View {
        PlaylistPrimaryCapsuleButton(
            title: "播放全部",
            symbol: "play.fill",
            stretches: stretches,
            // §4 空态：「播放全部」置灰禁用（`color.muted` 底，components §10）；§9 判据
            // 「无 0 首播放队列被建立」由这一条 `disabled` 兜住，队列构建在 `session.play` 那一侧。
            isDisabled: !PlaylistActionRowFacts.playAllEnabled(hasTracks: !tracks.isEmpty)
        ) {
            Task { await session.play(tracks: tracks, at: 0) }
        }
    }

    /// NEEDS-9 未解锁：详情端点不给 `isSaved` ⇒ 收藏态取自 05/12b 列表缓存（§7 第 1 条）。
    /// 缓存也没有（深链直入 / 游客）时读到的就是 `false`，而 §7 第 2 条要的**中性未选态**
    /// 与「未收藏」在这一档共用同一个书签轮廓（`bookmark`），所以画面与读法都不冒充「已收藏」；
    /// 首次点击发 POST，以响应回填真实态。
    private func saveButton(stretches: Bool) -> some View {
        let saved = session.savedPlaylistIDs.contains(playlistID)
        return PlaylistSecondaryCapsuleButton(
            title: PlaylistActionRowFacts.saveTitle(saved: saved),
            symbol: PlaylistActionRowFacts.bookmarkSymbol(saved: saved),
            isSaved: saved,
            stretches: stretches,
            isLoading: saveInFlight
        ) {
            // §8 并发：连点收藏第二次**被吞**（按钮进入 loading，响应回来按最终态渲染）。
            guard PlaylistActionRowFacts.acceptsSaveTap(inFlight: saveInFlight) else { return }
            saveInFlight = true
            Task {
                await session.toggleSavedPlaylist(playlistID)
                saveInFlight = false
            }
        }
        // §6 朗读：「收藏歌单，按钮，已选中/未选中」。
        .accessibilityLabel("收藏歌单")
        .accessibilityValue(PlaylistActionRowFacts.saveValue(saved: saved))
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

// MARK: - 06 §3.E 操作行（两钮 · AX 堆叠）

/// 操作行的判据面（§3.E / §4 / §6 / §8）。视图只负责摆，**哪个符号、哪句话、什么时候禁用、
/// 第二次点击要不要吞**都收在这一个面里 —— §9 判据「歌单收藏用书签、曲目收藏用爱心，全站无混用」
/// 是一句可测的话，就不该散在 `body` 里。
enum PlaylistActionRowFacts {
    /// §3.E 符号裁决：歌单收藏是**书签**语义（后端 `saveAction.kind == "bookmark"`），
    /// 爱心留给曲目收藏（03/07）。`inventory.md` 行 06 那句「♡」以本条为准（spec 待裁决 1）。
    static func bookmarkSymbol(saved: Bool) -> String { saved ? "bookmark.fill" : "bookmark" }

    /// §8 文案清单：`收藏` / `已收藏`。
    static func saveTitle(saved: Bool) -> String { saved ? "已收藏" : "收藏" }

    /// §6 朗读：「收藏歌单，按钮，**已选中/未选中**」。
    static func saveValue(saved: Bool) -> String { saved ? "已选中" : "未选中" }

    /// §6 Dynamic Type + §9 判据：AX 档 ⇒ 上下堆叠各占满宽；默认档 ⇒ 一行两钮。
    static func stacksVertically(axLayout: Bool) -> Bool { axLayout }

    /// §4 空态：0 首时只有「播放全部」禁用；**收藏照常可点**（空歌单也可以收藏这个歌单）。
    static func playAllEnabled(hasTracks: Bool) -> Bool { hasTracks }

    /// §8 并发冲突：连点收藏时第二次点击**被吞**（按钮已在 loading 里）。
    static func acceptsSaveTap(inFlight: Bool) -> Bool { !inFlight }
}

/// §3.E / components §10 主按钮：高 50（TG-07）、`radius.capsule`、`gradient.brandButton` 底 + 白字 +
/// `elevation.primaryButtonShadow`、图标 `play.fill`。禁用态换 `color.muted` 底（§4 空态 + §10 禁用态），
/// 而不是只降透明度 —— 那一条 spec 点名的就是"置灰"。
///
/// 为什么不在这里用 `CovaButton`：那一支是 44 高 / `radius.control` / `color.accent` 实心，
/// 与本屏这一档三处都不同，而 CovaUI 不在本批可改面内 ⇒ 几何落在屏侧。
struct PlaylistPrimaryCapsuleButton: View {
    /// TG-07 按钮高度档。
    static let height: CGFloat = 50
    private let title: String
    private let symbol: String
    private let stretches: Bool
    private let isDisabled: Bool
    private let action: () -> Void

    init(
        title: String, symbol: String, stretches: Bool = true,
        isDisabled: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.stretches = stretches
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.sm) {
                Image(systemName: symbol)
                Text(title).font(CovaType.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: Self.height)
            .background(
                isDisabled ? AnyShapeStyle(CovaColor.muted) : AnyShapeStyle(CovaGradient.brandButton),
                in: Capsule()
            )
            // `elevation.primaryButtonShadow = 0 6pt 18pt rgba(230,96,0,0.22)`：
            // CSS 的 18pt 是**模糊半径**（=2× 标准差），SwiftUI 的 shadow radius 取一半 ⇒ 9；
            // 颜色那个 rgba 的三个分量正是 `color.accentHover`（#E66000）。
            .shadow(color: isDisabled ? .clear : CovaColor.accentHover.opacity(0.22), radius: 9, x: 0, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// §3.E 次按钮：同高 50、`color.surface` 底 + `color.fg` 字 + 1pt `color.line` 描边（TG-04）；
/// 已收藏态 `color.accentSoft` 底 + `color.accentText` 字 + 1pt `color.accent` 描边。
struct PlaylistSecondaryCapsuleButton: View {
    static let height: CGFloat = 50
    private let title: String
    private let symbol: String
    private let isSaved: Bool
    private let stretches: Bool
    private let isLoading: Bool
    private let action: () -> Void

    init(
        title: String, symbol: String, isSaved: Bool, stretches: Bool = false,
        isLoading: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isSaved = isSaved
        self.stretches = stretches
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.sm) {
                // §8：连点期间**内嵌菊花**并保持宽度（标题换菊花而不塌成一小截）。
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol) }
                Text(title).font(CovaType.headline)
            }
            .foregroundStyle(isSaved ? CovaColor.accentText : CovaColor.fg)
            // 内边距在 `frame` **之前**：先给文字加横向余量，再决定这一枚要不要吃满宽。
            // 反过来写（padding 在 frame 之后）会让满宽那档在 AX5 下溢出左右 pageGutter
            // —— §9 判据第 6 条点名的就是「AX5 档下无横向溢出」。
            .padding(.horizontal, CovaSpace.lg)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: Self.height)
            .background(isSaved ? CovaColor.accentSoft : CovaColor.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSaved ? CovaColor.accent : CovaColor.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        let art = CovaArtwork(resolution: TrackDetailArtwork.cover(track), title: track.title)
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
                            guard session.requireLoginForCollections() else { return }
                            // 补不出可播地址就明说 —— 静默 `return` 会让「点了没反应」变成用户的问题
                            // 而不是后端契约问题（R16-1 的可见面）。
                            guard let item = AppSession.playbackItem(from: track) else {
                                session.showToast("音频地址不可用，这首暂时播不了", isError: true)
                                return
                            }
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
                                    CovaArtwork(resolution: TrackDetailArtwork.similarCover(item), title: item.title)
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

// MARK: - 美术腿（R18-2）

/// 06 歌单详情的两条封面腿：头图 + 曲目行。
///
/// 判据一律在 `CovaArtworkResolution`（CovaUI 唯一裁决面），这里只回答「哪个字段进哪个槽」。
enum PlaylistDetailArtwork {
    /// 头图有三个候选字段，按 `cover` → `coverUrl` → `coverMedia.imageUrl` 取第一个**非空**原文。
    ///
    /// 这一腿是全层唯一「站内相对 **且带查询串**」的形态（`docs/decisions.md` §S补充3：
    /// 第 18 轮以测试账号只读实测 `GET /api/user-playlists` 的 `coverUrl` / `imageUrl`；
    /// 匿名直接打该端点是 401，本仓复现不了那一行的原文）。查询串逐字节是硬要求：
    /// 补全若把它重编码或丢掉，拿到的就是另一张图或一张没有 —— 而**画面只是"没图"**，
    /// 与 R16-1 的相对 `audioUrl` 同一个失效形状。
    static func hero(_ playlist: PlaylistDto?) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValues: [
            playlist?.cover,
            playlist?.coverUrl,
            playlist?.coverMedia?.imageUrl,
        ])
    }

    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }
}

/// 07 曲目详情的两条封面腿：C 区大封面 + 相似曲目横滑。
enum TrackDetailArtwork {
    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }

    /// `similar` 是**另一套投影**（NEEDS-10/12，见 `LibraryDTOs` 的 `SimilarTrackDto` 注释），
    /// 字段同名不保证同形态 ⇒ 独立一腿，不借用上面那条。
    static func similarCover(_ similar: SimilarTrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: similar.cover)
    }
}
