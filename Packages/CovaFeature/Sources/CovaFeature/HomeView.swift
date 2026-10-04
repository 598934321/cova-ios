import CovaCore
import CovaUI
import SwiftUI

/// 首页（design 01，G2 2026-10-02 重写）：§2 问候区 → §3 模式切换 → §5 引导标签 →
/// §6 内容 feed（A 推荐歌单 / B 最近播放 / C 新歌上架 / D 你的创作 / E 场景精选 / F AI 音乐人），
/// §4 底置 CovaComposer（`safeAreaInset`，浮于 MiniPlayer accessory 之上）。
///
/// 三句必须说清的话：
/// · **登录专属分区（B/D）游客整区不渲染**（§6 公共规则：不留标题不留占位）；
/// · **生成交互不再在首页收**：§4 的提交建会话后落到 09（`navigate(to:.aiSession)`），
///   本屏只递 `pendingPrompt`/`pendingDeepThinking`，不渲染结果；
/// · **F 区的卡不可点**：`/api/studio/producers` 的 dto 没有 artistId 落点（23 §7 同一裁决），
///   画一个点了没用的东西就是谎。
public struct HomeView: View {
    @Environment(AppSession.self) private var session
    private let catalog: CatalogService

    // MARK: - §4 输入条状态（档位放 `AppSession`，会话内记忆 §3）
    @State private var composerText = ""
    @State private var deepThinking = false
    @State private var sending = false
    @FocusState private var composerFocused: Bool
    /// §3 大卡播放钮的在途标记（点一下要先发 `GET /api/playlists/:id` 取曲目）。
    @State private var featuredPlaying = false

    // MARK: - §6 分区账本（各自独立成败，§6 公共规则）
    /// A 歌单 + E 场景共享同一枪 `GET /api/playlists`（§10 数据契约：全量一次取）。
    @State private var playlistsPhase: FeedPhase<[PlaylistDto]> = .loading
    /// C 新歌。
    @State private var newestPhase: FeedPhase<[TrackDto]> = .loading
    /// D 你的创作（仅 signedIn 才发请求）。
    @State private var worksPhase: FeedPhase<[WorksListRowDto]> = .loading

    private enum FeedPhase<Payload>: Equatable where Payload: Equatable {
        case loading
        case ready(Payload)
        case failed(CatalogFailure)
    }

    public init(catalog: CatalogService) { self.catalog = catalog }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.lg) {
                greetingSection
                VStack(alignment: .center, spacing: CovaSpace.md) {
                    modeTabs
                    tagRows
                }
                .frame(maxWidth: .infinity)
                feed
            }
            .padding(.vertical, CovaSpace.md)
        }
        .scrollDismissesKeyboard(.interactively)
        // §4 键盘交互：点 feed 任意处收键盘（在钮的命中判定之下 —— simultaneous 不吞点击）。
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        .covaPage()
        // 问候即标题区：系统大标题栏不用（§2），只留透明导航位。
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composerBar }
        // feed 首载：A/E/C/F 匿名可读（§10），B/D 跟着登录态走。
        .task {
            await loadPublicFeed()
            await loadRecentAndWorks()
        }
        // `authPhase` 是 Equatable ⇒ 只在 restoring → guest/signedIn 的跳变上重跑，
        // 不被别的状态变动牵着重发。
        .task(id: session.authPhase) {
            await loadRecentAndWorks()
            await session.loadProducerCards()
        }
        .refreshable {
            await loadPublicFeed()
            await loadRecentAndWorks()
            await session.loadProducerCards(force: true)
        }
    }

    // MARK: - §2 问候区（display 字阶；「Cova」的 o 着 accent）

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            // §2：未取到昵称时省略昵称与逗号（guest 或 me 未回的 signedIn 早期帧）。
            Text(greetingLine)
                .font(CovaType.display)
                .foregroundStyle(CovaColor.fg)
                // `type.display` 的 `tracking: -0.01`（tokens.json 逐字）：28pt × −0.01 = −0.28pt。
                .tracking(-0.28)
                .lineLimit(2)
            // 「今天想和 Cova 一起创作些什么？」—— spec 明写「Cova」中字母「o」着 accent。
            // iOS 26 起 `Text + Text` 弃用；内插 Text 段保留自己的着色。
            Text("今天想和 C\(Text("o").foregroundStyle(CovaColor.accent))va 一起创作些什么？")
                .foregroundStyle(CovaColor.fg)
        }
        .font(CovaType.display)
        .tracking(-0.28)
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    /// `{时段称呼}，{昵称}` 或纯时段称呼（§2 两档）。
    private var greetingLine: String {
        let salutation = HomeComposerCopy.salutation(
            hour: Calendar.current.component(.hour, from: Date())
        )
        guard let name = session.meUser?.name,
              let trimmed = Optional(name.trimmingCharacters(in: .whitespacesAndNewlines)),
              !trimmed.isEmpty
        else { return salutation }
        return "\(salutation)，\(trimmed)"
    }

    // MARK: - §3 模式切换 + §5 引导标签

    /// `CovaModeTabs`（居中）。档位记忆在 `session.homeComposerMode`（§3 会话内记忆）。
    private var modeTabs: some View {
        CovaModeTabs(selection: Binding(
            get: { session.homeComposerMode },
            set: { mode in
                // §9：标签区/输入条内容交叉淡化 duration.fast；Reduce Motion 由组件侧承担。
                withAnimation(CovaMotion.fast) { session.homeComposerMode = mode }
            }
        ))
    }

    /// §5 引导标签（随模式换词，wrap 居中；Reduce Motion 一帧切换由 withAnimation 之外的
    /// 环境层承担 —— matchedGeometryEffect 组件侧已自查，这里不再叠一层判据）。
    @ViewBuilder
    private var tagRows: some View {
        ChipFlowLayout(spacing: CovaSpace.sm, alignment: .center) {
            if session.homeComposerMode == .generate {
                ForEach(HomeComposerCopy.generateTags, id: \.self) { tag in
                    CovaTagChip(title: tag) { sendGenerate(tag) }
                }
            } else {
                ForEach(HomeComposerCopy.searchTags, id: \.self) { tag in
                    CovaTagChip(title: tag) { sendSearch(tag) }
                }
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .accessibilityElement(children: .contain)
    }

    // MARK: - §6 内容 feed（分区独立成败；feedEntrance 错峰 40ms/区）

    @ViewBuilder
    private var feed: some View {
        // A 推荐歌单：大卡 + 其余官方歌单 140 方卡带 +「更多 ›」→ 05。
        recommendedSection.feedEntrance(index: 0)
        // B 最近播放（登录态；游客/空都不渲染）。
        recentSection.feedEntrance(index: 1)
        // C 新歌上架。
        newestSection.feedEntrance(index: 2)
        // D 你的创作（登录态；空不渲染，空态引导并入 §5 生成档标签区）。
        worksSection.feedEntrance(index: 3)
        // E 场景精选（沿用原场景分组横滑）。
        sceneSection.feedEntrance(index: 4)
        // F AI 音乐人（producers 灰度空 ⇒ 整区不渲染）。
        producersSection.feedEntrance(index: 5)
    }

    // MARK: A 推荐歌单（§6.A）

    @ViewBuilder
    private var recommendedSection: some View {
        switch playlistsPhase {
        case .loading:
            sectionShell("推荐歌单", more: false) { HomeRailSkeleton() }
        case .failed(let failure):
            sectionShell("推荐歌单", more: false) { sectionError(failure) { Task { await loadPlaylists() } } }
        case .ready(let playlists):
            if !playlists.isEmpty {
                sectionShell("推荐歌单", more: true) {
                    VStack(alignment: .leading, spacing: CovaSpace.md) {
                        if let featured = HomeFeaturedCard.hero(of: playlists) {
                            featuredCard(featured)
                        }
                        // 大卡吃掉第一条：剩下的走 140 方卡带（§6.A「其余官方歌单横滑小卡带」）。
                        let rest = Array(playlists.dropFirst())
                        if !rest.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                // 线上 `GET /api/playlists` 无分页、给的是全量 ⇒ Lazy（同旧版同一条理由）。
                                LazyHStack(spacing: CovaSpace.md) {
                                    ForEach(rest, id: \.id) { playlist in
                                        PlaylistCard(playlist: playlist) {
                                            session.push(.playlist(playlist.id))
                                        }
                                    }
                                }
                                .padding(.horizontal, CovaSpace.pageGutter)
                            }
                        }
                    }
                }
            }
        }
    }

    /// §6.A 大卡：宽 = 屏宽 − 2×`pageGutter`、高 200、圆角 `hero`；封面全幅 + 底部 45%
    /// 深色渐变遮罩 + 歌单名/「曲数 · 总时长」+ 右上 44pt 玻璃圆播放钮。
    /// （沿用 G1 的实现面 —— spec 修订只改了它的位置，没改卡本身。）
    private func featuredCard(_ playlist: PlaylistDto) -> some View {
        let title = playlist.titleCn ?? playlist.title
        return Button { session.push(.playlist(playlist.id)) } label: {
            ZStack(alignment: .bottomLeading) {
                CovaArtwork(resolution: HomeArtwork.playlistCover(playlist), title: title)
                    .frame(height: HomeFeaturedCard.heroHeight)
                    .clipped()
                    .accessibilityHidden(true)
                LinearGradient(
                    colors: [.clear, Color.black.opacity(HomeFeaturedCard.scrimMaxAlpha)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: HomeFeaturedCard.heroHeight * HomeFeaturedCard.scrimHeightRatio)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    Text(title).font(CovaType.headline).foregroundStyle(.white)
                        .lineLimit(2)
                    if let meta = HomeFeaturedCard.metaLine(
                        trackCount: playlist.trackCount,
                        totalDuration: playlist.totalDuration
                    ) {
                        Text(meta).font(CovaType.subhead).foregroundStyle(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                .padding(CovaSpace.lg)
            }
            .frame(height: HomeFeaturedCard.heroHeight)
            .background(CovaColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CovaRadius.hero, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CovaSpace.pageGutter)
        // 播放钮挂在卡之外：嵌在同一个 Button 的 label 里内层命不中。
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await playFeatured(playlist) }
            } label: {
                Image(systemName: featuredPlaying ? "hourglass" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: HomeFeaturedCard.playButtonSide, height: HomeFeaturedCard.playButtonSide)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放整个歌单")
            .padding(CovaSpace.pageGutter + CovaSpace.md)
        }
    }

    /// 「点一下播整张歌单」= 取详情曲目 → `session.play(tracks:at:)`（播放唯一入口）。
    /// 游客不播（硬边界：未登录不播放），走既有登录门。
    private func playFeatured(_ playlist: PlaylistDto) async {
        guard !featuredPlaying else { return }
        guard session.requireLoginForCollections() else { return }
        featuredPlaying = true
        defer { featuredPlaying = false }
        do {
            let detail = try await catalog.playlistDetail(playlist.id)
            let queue = detail.tracks ?? []
            guard !queue.isEmpty else {
                session.showToast("这个歌单暂时还没有曲目")
                return
            }
            await session.play(tracks: queue, at: 0)
        } catch {
            session.showToast("歌单没取到：\(CatalogService.classify(error).uiMessage)", isError: true)
        }
    }

    // MARK: B 最近播放（§6.B，登录态专属）

    /// `/api/play-history` 前 12 条横卡带。游客**整区不渲染**（§6 公共规则），
    /// 取数由 `session.loadRecentHistory()` 承担（服务端为准、游客/离线回落本机账）；
    /// 空列表同样整区不渲染（「feed 没有空壳分区」）。
    @ViewBuilder
    private var recentSection: some View {
        if case .signedIn = session.authPhase {
            let rows = Array(session.recentRows.prefix(12))
            if session.recentHistoryState == .outOfSync && rows.isEmpty {
                // 分区级失败（§6 公共规则）：错误条 + 重试，不阻塞整页。
                sectionShell("最近播放", more: false) {
                    sectionError(.network) { Task { await session.loadRecentHistory(force: true) } }
                }
            } else if !rows.isEmpty {
                sectionShell("最近播放", more: false) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: CovaSpace.md) {
                            ForEach(rows) { row in
                                RecentPlayCard(row: row) {
                                    Task { await session.replay(row) }
                                }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }
            }
        }
    }

    // MARK: C 新歌上架（§6.C）

    /// `GET /api/tracks?sort=newest&pageSize=12`（sort 闭集内 `newest`，§10 明文不发明 `relevance`）。
    @ViewBuilder
    private var newestSection: some View {
        switch newestPhase {
        case .loading:
            sectionShell("新歌上架", more: false) { HomeRailSkeleton() }
        case .failed(let failure):
            sectionShell("新歌上架", more: false) {
                sectionError(failure) { Task { await loadNewest() } }
            }
        case .ready(let tracks):
            if !tracks.isEmpty {
                sectionShell("新歌上架", more: false) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: CovaSpace.md) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                HomeTrackCard(track: track) {
                                    Task { await session.play(tracks: tracks, at: index) }
                                }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }
            }
        }
    }

    // MARK: D 你的创作（§6.D，登录态专属）

    /// `GET /api/studio/create/works?limit=12`。空列表 → 整区不渲染（§6.D：
    /// 空态引导句并入 §5 生成档标签区，不在本区另做空态卡）。
    @ViewBuilder
    private var worksSection: some View {
        if case .signedIn = session.authPhase {
            switch worksPhase {
            case .loading:
                sectionShell("你的创作", more: false) { HomeRailSkeleton() }
            case .failed(let failure):
                sectionShell("你的创作", more: false) {
                    sectionError(failure) { Task { await loadWorks() } }
                }
            case .ready(let works):
                if !works.isEmpty {
                    sectionShell("你的创作", more: false) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: CovaSpace.md) {
                                ForEach(works, id: \.id) { row in
                                    HomeWorkCard(row: row) {
                                        // 落点是 20 的作品组（`jobID` 锚定那一档），不是某个不存在的详情页。
                                        session.navigate(to: .worksList(jobID: row.jobId))
                                    }
                                }
                            }
                            .padding(.horizontal, CovaSpace.pageGutter)
                        }
                    }
                }
            }
        }
    }

    // MARK: E 场景精选（§6.E，沿用原分组横滑）

    /// 「按 scene 分组」沿用 `HomeSceneRail` 的判据（可测）：按组相邻横滑 140 方卡，
    /// 标题条带 scene 原文。「更多 ›」→ 05（§6 公共规则：仅 A/E 有更多入口）。
    @ViewBuilder
    private var sceneSection: some View {
        if case .ready(let playlists) = playlistsPhase {
            let groups = HomeSceneRail.groups(of: playlists)
            if !groups.isEmpty {
                sectionShell("场景精选", more: true) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: CovaSpace.md) {
                            ForEach(groups, id: \.scene) { group in
                                ForEach(group.playlists, id: \.id) { playlist in
                                    ScenePlaylistCard(scene: group.scene, playlist: playlist) {
                                        session.push(.playlist(playlist.id))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }
            }
        }
        // playlists 加载中/失败：E 不自己再画一条错误 —— A 区的错误条已经是这份数据的
        // 失败面，同一枪的错误不该在屏上说两遍。
    }

    // MARK: F AI 音乐人（§6.F）

    /// `/api/studio/producers`：`producersEntranceVisible` 是唯一可见判据（23 §7/A10：
    /// 灰度空/读不到/游客 ⇒ **整区不构造**，连标题都不出现）。
    /// 卡 = 64 圆头像 + `displayTitle`（caption/secondary）。**不可点**：dto 没有
    /// artistId 落点（契约里根本没有艺人路由能承接它），按钮就是谎。
    @ViewBuilder
    private var producersSection: some View {
        if session.producersEntranceVisible {
            sectionShell("AI 音乐人", more: false) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: CovaSpace.md) {
                        ForEach(session.producerCards, id: \.id) { card in
                            VStack(spacing: CovaSpace.xs) {
                                // 契约里没有头像字段（`ProducerCardDto` 键集实测无 cover/avatar）
                                // ⇒ 恒像素占位，不发明一条不存在的图片腿。
                                CovaArtwork(resolution: .absent, title: card.displayTitle ?? "AI 音乐人")
                                    .frame(width: HomeArtistRail.avatarDiameter, height: HomeArtistRail.avatarDiameter)
                                    .clipShape(Circle())
                                if let name = card.displayTitle {
                                    Text(name)
                                        .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(width: HomeArtistCell.nameWidth)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(card.displayTitle ?? "AI 音乐人")，非交互内容")
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                }
            }
        }
    }

    // MARK: - §4 底置输入条（本屏灵魂）

    /// `CovaComposer` 挂 `safeAreaInset(.bottom)`：浮于标签栏/MiniPlayer accessory 之上
    /// （系统 inset 分层自动避让），浮层本体玻璃材质 + card 圆角（组件内）。
    private var composerBar: some View {
        CovaComposer(
            text: $composerText,
            mode: Binding(
                get: { session.homeComposerMode },
                set: { session.homeComposerMode = $0 }
            ),
            target: Binding(
                get: { session.homeSearchTarget },
                set: { session.homeSearchTarget = $0 }
            ),
            deepThinking: $deepThinking,
            sending: sending,
            onSend: sendComposer,
            focused: $composerFocused
        )
        // §4 选项行展开 = duration.fast；聚焦本身没有 spec 动画要求。
        .animation(CovaMotion.fast, value: composerFocused)
    }

    /// §4 发送行为：按当前档位分两条腿。
    private func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.homeComposerMode {
        case .generate:
            sendGenerate(text)
        case .search:
            sendSearch(text)
        }
    }

    /// 生成档：`POST /api/find-my-song/sessions` → 拿 sessionId → `navigate` 到 09，
    /// 首发文本与深度思考由 09 的既有 pending 机制发出（§4 发送行为第一行）。
    /// **游客点发送 = 17-S6 登录引导 sheet**（不建会话、不切页签、不清输入 ——
    /// 登完回来那句话还在，这是引导而不是没收）。
    private func sendGenerate(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard session.requireLoginForCollections() else { return }
        sending = true
        composerFocused = false
        Task {
            defer { sending = false }
            do {
                // §7 #55：首条 prompt 落成会话真名（规范化=首行截 30；空 → 不带键）。
                let id = try await session.studio.createSession(
                    title: CovaCreateSessionRequestDto.normalizedTitle(text))
                composerText = ""
                session.pendingPrompt = text
                session.pendingDeepThinking = deepThinking
                session.navigate(to: .aiSession(id))
            } catch {
                session.showToast("会话没建起来：\(StudioService.classify(error).uiMessage)", isError: true)
            }
        }
    }

    /// 搜索档：**空文本是合法发送**（§4：空文本 → push 无条件的列表页，对齐 web
    /// 「空查询只进对应页面」）。目标=曲库 → `library(preset)`；目标=歌单 → `plazaSearch`。
    /// 全档游客可用（公开内容，§4 游客态行）。
    private func sendSearch(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        composerFocused = false
        switch session.homeSearchTarget {
        case .library:
            session.push(.library(text.isEmpty ? nil : AppSession.LibraryPreset(search: text)))
        case .playlists:
            session.push(text.isEmpty ? .plaza : .plazaSearch(text))
        }
    }

    // MARK: - 分区公共件（§6 公共规则）

    /// 分区标题行：`headline`/`fg` 左；`more` 只在 A/E 用（「更多 ›」→ 05）。
    private func sectionShell<Content: View>(
        _ title: String, more: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            if more {
                CovaSectionHeader(title, trailing: "更多 ›") { session.push(.plaza) }
            } else {
                CovaSectionHeader(title)
            }
            content()
        }
    }

    /// 分区级错误条（§6 公共规则：error 色 icon + 「重试」，不阻塞整页）。
    private func sectionError(_ failure: CatalogFailure, retry: @escaping () -> Void) -> some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(CovaColor.error)
                .accessibilityHidden(true)
            Text(failure.uiMessage)
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重试", action: retry)
                .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                .buttonStyle(.plain)
                .frame(minHeight: ShellMetrics.touchMin)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    // MARK: - 取数

    /// A/E/C/F 的匿名可读分区：playlists 一枪供 A+E，`sort=newest` 一枪供 C。
    /// 两枪分账不合并成一个错误面（§6 各分区独立加载/失败）。
    private func loadPublicFeed() async {
        await loadPlaylists()
        await loadNewest()
    }

    private func loadPlaylists() async {
        playlistsPhase = .loading
        do {
            playlistsPhase = .ready(try await catalog.featuredPlaylists())
        } catch {
            playlistsPhase = .failed(CatalogService.classify(error))
        }
    }

    private func loadNewest() async {
        newestPhase = .loading
        do {
            let page = try await catalog.tracks(
                queryItems: LibraryFilterSelection().queryItems(
                    search: nil, sort: .newest, page: 1, pageSize: 12
                )
            )
            newestPhase = .ready(page.tracks)
        } catch {
            newestPhase = .failed(CatalogService.classify(error))
        }
    }

    /// B/D 的登录态分区（§6 公共规则：游客整区不渲染 ⇒ 游客**不发**这两枪；
    /// `GET /api/play-history` 与 `…/create/works` 在游客态分别是 401/无效请求）。
    private func loadRecentAndWorks() async {
        guard case .signedIn = session.authPhase else {
            worksPhase = .loading   // 回落默认档；反正游客态这一区不渲染
            return
        }
        await session.loadRecentHistory()
        await loadWorks()
    }

    private func loadWorks() async {
        worksPhase = .loading
        do {
            let page = try await session.worksService.page(WorksListQuery(limit: 12))
            worksPhase = .ready(Array(page.works.prefix(12)))
        } catch {
            worksPhase = .failed(CatalogService.classify(error))
        }
    }
}

/// 歌单卡（§6.A 卡带单元）：140 方封面 + 名称 + 曲目数；沿用原首页横滑卡规格。
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
                CovaArtwork(resolution: HomeArtwork.playlistCover(playlist), title: playlist.title)
                    .frame(width: CGFloat(HomeSceneRail.cardSide), height: CGFloat(HomeSceneRail.cardSide))
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                Text(playlist.titleCn ?? playlist.title).font(CovaType.headline).foregroundStyle(CovaColor.fg).lineLimit(1)
                // 「没给曲数」与「0 首」是两件事：缺席不印读数（第 20 轮 R20-4 同口径）。
                if let count = playlist.trackCount {
                    Text("\(count) 首").font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                }
            }
            .frame(width: CGFloat(HomeSceneRail.cardSide), alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// 场景精选卡（design 01 §6.E）：140×140、圆角 `card`，封面铺满 + **底部标题条**。
///
/// 标题条自带 `elevated` 底：spec 给的 `fg` 文字色在浅主题下是深色 —— 直接压在来路不明的
/// 封面上没有对比度保证，加一层不透明底条是这一档文字色的唯一读法。`scene` 那一行是
/// 后端原文（不翻译、不改写），它就是"这几张卡是同一组"的记号。
public struct ScenePlaylistCard: View {
    private static let side = CGFloat(HomeSceneRail.cardSide)
    private let scene: String
    private let playlist: PlaylistDto
    private let action: () -> Void

    public init(scene: String, playlist: PlaylistDto, action: @escaping () -> Void) {
        self.scene = scene
        self.playlist = playlist
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CovaArtwork(resolution: HomeArtwork.playlistCover(playlist), title: playlist.title)
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(scene).font(CovaType.caption).foregroundStyle(CovaColor.muted).lineLimit(1)
                    Text(playlist.titleCn ?? playlist.title)
                        .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                        .lineLimit(2)
                }
                .padding(.horizontal, CovaSpace.sm)
                .padding(.vertical, CovaSpace.xs)
                .frame(width: Self.side, alignment: .leading)
                .background(CovaColor.elevated)
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scene)，\(playlist.titleCn ?? playlist.title)")
    }
}

// MARK: - §6.B/C 横卡带单元（140 方封面 + 标题 2 行 + 一行 caption）

/// §6.B 最近播放卡。work 行（`kind == .work`）封面右上挂 `sparkles` 角标
/// （创作产物标记，§6.B 逐字）。不可播的行照常渲染（A1 口径：点不开要说得出为什么，
/// 而不是让它凭空消失 —— `session.replay` 会 toast 解释）。
struct RecentPlayCard: View {
    let row: AppSession.RecentPlayRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                ZStack(alignment: .topTrailing) {
                    CovaArtwork(resolution: HomeArtwork.recentCover(row), title: row.title)
                        .frame(width: CGFloat(HomeSceneRail.cardSide), height: CGFloat(HomeSceneRail.cardSide))
                        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                        .accessibilityHidden(true)
                    if row.kind == .work {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(CovaSpace.xs)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(CovaSpace.xs)
                            .accessibilityHidden(true)
                    }
                }
                Text(row.title)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .lineLimit(2)
                Text(caption)
                    .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    .lineLimit(1)
            }
            .frame(width: CGFloat(HomeSceneRail.cardSide), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.kind == .work ? "\(row.title)，作品" : row.title)
    }

    /// 「艺人/来源」行：作品行没有艺人名（服务端投影恒 null）⇒ 说它是「作品」，
    /// 不编一个艺人名字；时长有就带，没有就不占位。
    private var caption: String {
        var parts: [String] = []
        if let artist = row.artist {
            parts.append(artist)
        } else if row.kind == .work {
            parts.append("作品")
        }
        if let duration = row.duration {
            parts.append(PlayerTime.elapsed(duration))
        }
        return parts.joined(separator: " · ")
    }
}

/// §6.C 新歌卡：同 B 的卡规格（140 方 + 标题两行 + 艺人·时长一行）。
struct HomeTrackCard: View {
    let track: TrackDto
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                CovaArtwork(resolution: HomeArtwork.cover(track), title: track.title)
                    .frame(width: CGFloat(HomeSceneRail.cardSide), height: CGFloat(HomeSceneRail.cardSide))
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                    .accessibilityHidden(true)
                Text(track.titleCn ?? track.title)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .lineLimit(2)
                Text(caption)
                    .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    .lineLimit(1)
            }
            .frame(width: CGFloat(HomeSceneRail.cardSide), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var caption: String {
        var parts = [track.artistNameCn ?? track.artist.name]
        let duration = Int(track.duration)
        if duration > 0 { parts.append(PlayerTime.elapsed(track.duration)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - §6.D 你的创作（横卡带单元）

/// 徽标三档 → token 色（§6.D：生成中 `warning` / 完成 `success` / 失败 `error`）。
/// 映射本身在 `HomeCreationGrid.badge(forStatus:)`（CovaCore，可测）——这里只钉色。
enum CreationBadgeFacts {
    static func color(_ badge: HomeCreationGrid.Badge) -> Color {
        switch badge {
        case .generating: return CovaColor.warning
        case .done: return CovaColor.success
        case .failed: return CovaColor.error
        }
    }
    /// 胶囊底不透明度：与 02 §8「生成候选 · 仅本人可见」那一枚同一个值。
    static let backgroundAlpha = 0.12
}

/// §6.D 卡：生成封面（`coverUrl`，公开读桶直链）/像素占位 + 标题（subhead 2 行）+
/// 状态徽标（占位行 `{jobId}:pending-N` 按「生成中」读 —— 它本来就是还没做出音频的那一档）。
struct HomeWorkCard: View {
    let row: WorksListRowDto
    let action: () -> Void

    private var badge: HomeCreationGrid.Badge? {
        if row.isPendingPlaceholder { return .generating }
        return HomeCreationGrid.badge(forStatus: row.status?.rawValue)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                ZStack(alignment: .topTrailing) {
                    CovaArtwork(
                        resolution: CovaArtworkResolution(serverValue: row.coverUrl),
                        title: row.displayTitle ?? "未命名作品"
                    )
                    .frame(width: CGFloat(HomeSceneRail.cardSide), height: CGFloat(HomeSceneRail.cardSide))
                    .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                    .accessibilityHidden(true)
                    if let badge {
                        Text(HomeCreationGrid.label(of: badge))
                            .font(CovaType.caption)
                            .foregroundStyle(CreationBadgeFacts.color(badge))
                            .padding(.horizontal, CovaSpace.sm).padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    CreationBadgeFacts.color(badge)
                                        .opacity(CreationBadgeFacts.backgroundAlpha)
                                )
                            )
                            .padding(CovaSpace.xs)
                    }
                }
                Text(row.displayTitle ?? "未命名作品")
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .lineLimit(2)
            }
            .frame(width: CGFloat(HomeSceneRail.cardSide), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    /// 一张卡一个可聚焦元素；没有徽标时不念一个"没有状态"。
    private var accessibilityText: String {
        let title = row.displayTitle ?? "未命名作品"
        guard let badge else { return title }
        return "\(title)，\(HomeCreationGrid.label(of: badge))"
    }
}

// MARK: - 01 §6 AI 音乐人栏的一格（16/25 的 LibraryPreset 入口仍走它）

/// §6（G1）：圆形头像 64pt + 名字（caption / secondary）。
///
/// 今天 F 区改读 `/api/studio/producers`（`producersSection`，卡不可点），
/// 本卡**不再被 01 使用**：留下的唯一理由是 `HomeArtistRailLegTests` 钉着
/// `side`/`nameWidth` 两档几何，而它同时是 `ArtistDto → LibraryPreset` 那条
/// 旧腿（16 曲目行「查看艺人」之外、其他屏递 `pendingLibraryPreset` 时）的展示件。
public struct HomeArtistCell: View {
    /// §6 的头像档。
    static let side = CGFloat(HomeArtistRail.avatarDiameter)
    /// 名字行的宽度档：spec 没给 ⇒ 取"比头像宽一点、让这一格仍是一根柱子"的 76pt。
    static let nameWidth: CGFloat = 76

    private let artist: ArtistDto
    private let action: () -> Void

    public init(artist: ArtistDto, action: @escaping () -> Void) {
        self.artist = artist
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: CovaSpace.xs) {
                CovaArtwork(resolution: HomeArtwork.artistAvatar(artist), title: name)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(Circle())
                    .accessibilityLabel("\(name) 的头像")
                Text(name)
                    .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: Self.nameWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 名字优先级与 16 §3.C 同一条：`nameCn ?? name`。
    private var name: String { HomeArtistRail.displayName(artist) ?? artist.name }
}

// MARK: - 美术腿（R18-2）

/// 01 屏的封面腿：新歌卡 `track.cover`、最近播放 `recent.coverURLString`、
/// 推荐歌单 `playlist.cover`/`coverUrl`、音乐人头像 `track.artist.avatar`。
///
/// 判据一律在 `CovaArtworkResolution`（CovaUI 唯一裁决面）：本屏只回答「哪个字段进哪个槽」。
/// 线上事实（2026-09-25 只读核对）：`GET /api/tracks` 内嵌的 `artist.avatar` 是**站内相对**
/// （20 行里 11 行相对 / 9 行没有），`GET /api/user-playlists` 的 `coverUrl`/`imageUrl` 是
/// 站内相对 + 带查询串 —— 相对串没有 scheme，直接 `URL(string:)` 交给 `CovaArtworkCache.fetch`
/// 就是出口判定为假 ⇒ 一次请求都不发、只剩占位（R16-1 同族）。四条腿因此一律先裁决再交图。
enum HomeArtwork {
    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }

    /// 最近播放。两个来源共用这一条腿：本机账存的是绝对地址，服务端历史行的 `track.cover`
    /// 两种形态都给过 ⇒ **先裁决再交图**，不因"来源看着已经是绝对地址"而免检（R18-2 同族）。
    static func recentCover(_ row: AppSession.RecentPlayRow) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: row.coverURLString)
    }

    /// 歌单图有两个候选字段：`cover` 与 `coverUrl`（先到的**非空**值赢）。
    static func playlistCover(_ playlist: PlaylistDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValues: [playlist.cover, playlist.coverUrl])
    }

    /// AI 音乐人/艺人头像腿：**必须**先裁决 —— `/api/tracks` 内嵌 `artist.avatar` 有值的行
    /// 全部是站内相对路径（2026-09-25 只读核对），直接 `URL(string:)` 正中"一次请求都不发"。
    static func artistAvatar(_ artist: ArtistDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: artist.avatar)
    }
}
