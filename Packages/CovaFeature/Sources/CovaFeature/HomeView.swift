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
    @State private var prompt = ""
    @State private var promptMode: PromptMode = .auto
    @State private var deepThinking = false
    @State private var creatingSession = false
    /// §3 播放钮的在途标记：点一下要先发 `GET /api/playlists/:id` 取曲目，
    /// 期间吞掉第二次点击（连点会建出两条队列，第二条盖掉第一条）。
    @State private var featuredPlaying = false
    /// §5「你的创作」：**分区独立加载**（§8），这一格走的是**要登录**的会话列表，
    /// 与上面那两段匿名内容不共命运 —— 它失败只该盖住它自己那一格。
    @State private var creations: CreationPhase = .pending
    /// §5 空态的 CTA 是「聚焦会话框」⇒ 输入框得先有一个可被聚焦的身份。
    @FocusState private var promptFocused: Bool

    /// §5 + §8 的登录门槛四档。`pending` 单独存在（而不是并进 `loading`）的理由：
    /// 登录态回读期间既不是"游客"也不该发一个必 401 的请求 —— 那是硬边界里
    /// 「未登录不播放/不写」的同一条判据在取数侧的形态。
    private enum CreationPhase: Equatable {
        case pending
        case guest
        case loading
        case ready([StudioSessionDto])
        case failed(CatalogFailure)
    }

    /// 输入卡的三种模式。**只有 UI 状态**：`POST /api/studio/agent` 的请求体 schema 未文档化
    /// （NEEDS-13），所以这里**不发明** `mode` 之类的键去发后端 —— 默认「自动」由 agent 自己判意图。
    enum PromptMode { case auto, find, make }

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
                promptCard
                content
                recentlyPlayed
                creationsSection
            }
            .padding(.vertical, CovaSpace.lg)
        }
        .covaPage()
        // 04 §1 入口①：顶层屏顶栏左上的字标钮（01 §1 顶栏那一行的 logo 位）。
        // 01 顶栏的其余部分（玻璃材质、右侧 32pt 头像位）本轮**没有**一并施工 —— 那是另一条
        // 未实现项，不在"抽屉不可达"这一刀的范围内；这里只把入口接上，不留一个假装的顶栏。
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DrawerTrigger(opener: .home)
            }
        }
        .task { await load() }
        // 登录态一落定就决定这一格取不取：`authPhase` 是 Equatable ⇒ `task(id:)` 只在
        // restoring → guest / signedIn 那一次跳变上重跑，不被别的状态变动牵着重发。
        .task(id: session.authPhase) { await loadCreations() }
        .refreshable {
            await load()
            await loadCreations()
        }
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
                if let featured = HomeFeaturedCard.hero(of: playlists) {
                    featuredSection(featured)
                }
                if !playlists.isEmpty {
                    CovaSectionHeader("推荐歌单", trailing: "全部 ›") {
                        session.path.append(.plaza)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        // `LazyHStack`：这一条轨道在线上给的是**全量 593 条**歌单
                        // （`GET /api/playlists` 无分页），`HStack` 会把 593 张卡一次性建出来，
                        // 首屏就卡在还没滚到的卡上。
                        LazyHStack(spacing: CovaSpace.md) {
                            ForEach(playlists, id: \.id) { playlist in
                                PlaylistCard(playlist: playlist) {
                                    session.path.append(.playlist(playlist.id))
                                }
                            }
                        }
                        .padding(.horizontal, CovaSpace.pageGutter)
                    }
                }
                let scenes = HomeSceneRail.groups(of: playlists)
                if !scenes.isEmpty {
                    sceneRail(scenes)
                }
                if !tracks.isEmpty {
                    CovaSectionHeader("曲库精选")
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.prefix(8).enumerated()), id: \.element.id) { index, track in
                            CovaListRow(
                                title: track.titleCn ?? track.title,
                                subtitle: "\(track.artistNameCn ?? track.artist.name) · \(track.scenes.joined(separator: "/"))",
                                artwork: CovaArtwork(resolution: HomeArtwork.cover(track), title: track.title)
                            ) {
                                Text(track.vocalType).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                            } action: {
                                Task { await session.play(tracks: tracks, at: index) }
                            }
                            .contextMenu {
                                Button("曲目详情") { session.detailTrackID = track.id }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 今日推荐（design 01 §3 / components §2 大卡）：宽 = 屏宽 − 2×`pageGutter`、高 200、
    /// 圆角 `hero`；封面全幅裁切 + 底部 45% 深色渐变遮罩；遮罩上歌单名（headline/白）
    /// 与「曲数 · 总时长」（subhead/白 80%、tabular-nums）；右上 44pt 玻璃圆播放钮；
    /// 点卡进歌单详情。
    ///
    /// **封面焦点裁剪做不到**：`CovaArtwork`（CovaStates，本批不可改）没有 alignment/focal 入参，
    /// 所以 `coverMedia.focalX/focalY` 今天进不了裁剪那一手 ⇒ 这里是中心裁剪。
    /// 需要的是 `CovaArtwork(resolution:title:focal:)`（`UnitPoint`），已在本批报告里点名。
    private func featuredSection(_ playlist: PlaylistDto) -> some View {
        let title = playlist.titleCn ?? playlist.title
        let meta = HomeFeaturedCard.metaLine(
            trackCount: playlist.trackCount,
            totalDuration: playlist.totalDuration
        )
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaSectionHeader("今日推荐", trailing: "更多 ›") {
                session.path.append(.plaza)
            }
            Button { session.path.append(.playlist(playlist.id)) } label: {
                ZStack(alignment: .bottomLeading) {
                    CovaArtwork(resolution: HomeArtwork.playlistCover(playlist), title: title)
                        // 中心裁剪：让封面铺满 200 高的槽再截掉溢出（`CovaArtwork` 自己是 scaledToFill）。
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
                        if let meta {
                            // §3 的 tabular-nums：等宽数字只加在这一行（时长/曲数会随刷新变位宽）。
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
            // 播放钮挂在**卡之外**：嵌在同一个 Button 的 label 里，内层命不中（点了只会进详情）。
            .overlay(alignment: .topTrailing) {
                featuredPlayButton(playlist)
                    .padding(CovaSpace.md)
            }
        }
    }

    /// §3 右上玻璃圆播放钮（44pt = TG-03 的最小触控档）。
    private func featuredPlayButton(_ playlist: PlaylistDto) -> some View {
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
    }

    /// 「点一下播整张歌单」= 取详情曲目 → 交给 `session.play(tracks:at:)`。
    ///
    /// **不开第二条播放入口**：06 的「播放全部」、03/16 的曲目行走的都是这一个函数，
    /// 队列构造、地址裁决、歌词归属、播放上报全在它里面（`AppSession.swift` 「播放意图（UI 唯一入口）」。
    /// 游客**不播**（未登录不播放），走既有的登录门槛：`requireLoginForCollections()`
    /// 弹登录并返回 false，这里就直接不发起请求。
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

    /// 场景精选（design 01 §4）：140×140 横滑卡，封面 + 底部标题条。
    ///
    /// **「按 scene 分组」落成的形状**（§1 的版面只给这一区画了**一条**横滑轨道，
    /// 所以分组不做成一堆子标题，也不给场景造一个落地页 —— 那需要一个契约里不存在的
    /// 「场景 → 歌单」入口）：轨道里的卡**按组相邻**，每张卡的标题条上把 `scene`
    /// 原样写出来，读得出"这几张是同一组"。分组与挑选的判据全在 `HomeSceneRail`（CovaCore，可测），
    /// 线上 593 条里只有 101 条带非空 `scene` ⇒ 另外 492 条不进这一区，也不给它们编一个「其他」桶。
    private func sceneRail(_ groups: [HomeSceneRail.Group]) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaSectionHeader("场景精选")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CovaSpace.md) {
                    ForEach(groups, id: \.scene) { group in
                        // 组内相邻 = 「按 scene 分组」在这一条轨道里的全部落地形式（见上方说明）。
                        ForEach(group.playlists, id: \.id) { playlist in
                            ScenePlaylistCard(scene: group.scene, playlist: playlist) {
                                session.path.append(.playlist(playlist.id))
                            }
                        }
                    }
                }
                .padding(.horizontal, CovaSpace.pageGutter)
            }
        }
    }

    /// 会话输入卡（design 01 §2，「本屏灵魂」）：sparkle + 占位文案 + 模式 chip +
    /// 深度思考开关 + 圆形发送钮（空输入置灰）。
    /// 提交后**首页不展示结果**（spec 明令）：建会话 → 落到 09 会话详情。
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            HStack(spacing: CovaSpace.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CovaColor.accent)
                    .accessibilityHidden(true)
                if prompt.isEmpty {
                    Text("想听什么？找歌或做歌，一句话搞定")
                        .font(CovaType.body).foregroundStyle(CovaColor.muted)
                }
                TextField("", text: $prompt, axis: .vertical)
                    .font(CovaType.body).foregroundStyle(CovaColor.fg)
                    .lineLimit(1...3)
                    .labelsHidden()
                    // §5 空态 CTA 的落点：「CTA 聚焦会话框」要有真东西可聚焦，
                    // 而不是一个把用户丢在原地、什么都不发生的按钮。
                    .focused($promptFocused)
                Spacer(minLength: 0)
            }
            HStack(spacing: CovaSpace.sm) {
                CovaChip("找歌", isSelected: promptMode == .find) {
                    promptMode = promptMode == .find ? .auto : .find
                }
                CovaChip("做歌", isSelected: promptMode == .make) {
                    promptMode = promptMode == .make ? .auto : .make
                }
                Spacer()
                CovaChip("深度思考", isSelected: deepThinking) { deepThinking.toggle() }
                Button {
                    Task { await submitPrompt() }
                } label: {
                    Image(systemName: creatingSession ? "hourglass" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CovaColor.accentText)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(canSubmit ? CovaColor.accent : CovaColor.line))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || creatingSession)
                .accessibilityLabel("发送")
            }
        }
        .padding(CovaSpace.lg)
        .covaGlass(elevated: true)
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard session.requireLoginForCollections() else { return }
        creatingSession = true
        defer { creatingSession = false }
        do {
            let id = try await session.studio.createSession()
            prompt = ""
            session.pendingPrompt = text
            session.pendingDeepThinking = deepThinking
            session.path.append(.aiSession(id))
        } catch {
            session.showToast("会话没建起来：\(StudioService.classify(error).uiMessage)", isError: true)
        }
    }

    /// 你的创作（design 01 §5）：双列网格（卡宽 = (屏宽−2×gutter−md)/2，圆角 `card`）
    /// + 封面 + 标题（subhead）+ 状态徽标。
    ///
    /// **封面今天恒为像素占位**，这一句是实话不是保守：会话列表载荷里没有任何封面字段
    /// （`StudioSessionCover.hasCoverFieldInListPayload == false`），而 §数据源明令不得为封面
    /// 逐行发详情请求（N+1）⇒ 不发明 cover URL，按 §5 的另一支走 PixelCard 式像素占位呼吸。
    /// 同理，**状态徽标今天也不会出现**：`HomeCreationGrid.statusFieldInListPayload == false`
    /// （线上 `listOwnedSessions` 连 status 列都没有）⇒ 映射与色档已照 spec 施工好，
    /// 字段一上线就点亮，界面上不出现"猜出来的状态"。
    @ViewBuilder
    private var creationsSection: some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaSectionHeader("你的创作", trailing: "全部 ›") {
                guard session.requireLoginForCollections() else { return }
                session.path.append(.aiSessions)
            }
            switch creations {
            case .pending, .loading:
                CovaSkeleton(rows: 2)
            case .guest:
                creationGuide
            case .failed(let failure):
                // §8：分区级错误（error 色 + 「重试」），不阻塞整页。
                CovaErrorState(kind: errorKind(failure)) { Task { await loadCreations() } }
            case .ready(let items):
                if items.isEmpty {
                    creationGuide
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: CovaSpace.md),
                            count: HomeCreationGrid.columnCount
                        ),
                        spacing: CovaSpace.md
                    ) {
                        ForEach(items.prefix(HomeCreationGrid.cardLimit)) { item in
                            CreationCard(item: item) {
                                session.path.append(.aiSession(item.id))
                            }
                        }
                    }
                    .padding(.horizontal, CovaSpace.pageGutter)
                }
            }
        }
    }

    /// §5 的空态引导：未登录 / 无创作两支共用同一句话，CTA 是把焦点交给会话输入框
    /// （spec 原话「CTA 聚焦会话框」），**不是**替用户建一个会话 —— 建会话是 POST，
    /// 游客点了就该先被带去登录，而不是凭空多出一条会话。
    private var creationGuide: some View {
        CovaEmptyState(
            symbol: "sparkles",
            title: "用一句话开始你的第一首歌",
            hint: "说场景、说情绪、说时长都行，剩下的交给 Cova。",
            actionTitle: "写一句话",
            action: { promptFocused = true }
        )
    }

    /// §5 的取数：游客**不发**这一枪（`GET /api/find-my-song/sessions` 实测回 401），
    /// 直接把这一格切成空态引导 —— 把「你还没登录」演成一个错误态是撒谎，也是噪音。
    private func loadCreations() async {
        switch session.authPhase {
        case .restoring:
            creations = .pending
            return
        case .guest, .failed:
            creations = .guest
            return
        case .signedIn:
            break
        }
        creations = .loading
        do {
            creations = .ready(try await session.studio.sessions())
        } catch {
            creations = .failed(StudioService.classify(error))
        }
    }

    /// 继续聆听（design 01）：本机真的响过的曲目。点一行 = **回读**曲目再播
    /// （本地账里刻意不存音频地址：它可能带签名，硬边界 3）。
    @ViewBuilder
    private var recentlyPlayed: some View {
        if !session.recents.isEmpty {
            CovaSectionHeader("继续聆听")
            VStack(spacing: 0) {
                ForEach(session.recents) { track in
                    CovaListRow(
                        title: track.title,
                        subtitle: track.artist,
                        artwork: CovaArtwork(resolution: HomeArtwork.recentCover(track), title: track.title)
                    ) {
                        Image(systemName: "play.circle").foregroundStyle(CovaColor.muted)
                            .accessibilityHidden(true)
                    } action: {
                        Task { await replay(track) }
                    }
                }
            }
        }
    }

    private func replay(_ track: RecentTrack) async {
        do {
            let detail = try await catalog.trackDetail(track.id)
            await session.play(tracks: [detail.track], at: 0)
        } catch {
            session.showToast("这首暂时不能播", isError: true)
        }
    }

    private func errorKind(_ failure: CatalogFailure) -> CovaErrorState.Kind {
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
                CovaArtwork(resolution: HomeArtwork.playlistCover(playlist), title: playlist.title)
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

/// 场景精选卡（design 01 §4）：140×140、圆角 `card`，封面铺满 + **底部标题条**（subhead / fg）。
///
/// 标题条自带 `elevated` 底：§4 给的是 `fg`（不是 §3 大卡那种白字），而 `fg` 在浅主题下
/// 是深色 —— 直接压在来路不明的封面上没有对比度保证，加一层不透明底条是这一档文字色的
/// 唯一读法。`scene` 那一行是后端原文（不翻译、不改写），它就是"这几张卡是同一组"的记号。
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

// MARK: - 01 §5 你的创作（候选小卡）

/// 徽标三档 → token 色（§5：生成中 `warning` / 完成 `success` / 失败 `error`）。
///
/// 形状**沿用本仓已有的那一档状态徽标**（`PlayerViews.swift` 的「生成候选 · 仅本人可见」：
/// `caption` 字 + 同色 12% 胶囊底），不再为首页长第二种徽标形状。
enum CreationBadgeFacts {
    static func color(_ badge: HomeCreationGrid.Badge) -> Color {
        switch badge {
        case .generating: return CovaColor.warning
        case .done: return CovaColor.success
        case .failed: return CovaColor.error
        }
    }
    /// §5 徽标的胶囊底不透明度：与 02 §8 那一枚同一个值（同一个组件族就该同一个数）。
    static let backgroundAlpha = 0.12
}

/// §5 的小卡：像素占位封面 + 标题（subhead）+ 状态徽标。
///
/// 封面腿在这里**不接任何 URL**：会话列表没有封面字段（见 `HomeView.creationsSection`
/// 的说明），而 §数据源禁止为封面逐行发详情请求 ⇒ 像素占位是这一格今天的正确形态。
/// 点了进 09 会话详情（08/12c 同一条路由，不另开入口）。
struct CreationCard: View {
    private let item: StudioSessionDto
    private let action: () -> Void
    /// §Dynamic Type：网格里的标题在 AX 档多给一行（图不放大，字要放得下）。
    @Environment(\.covaAXLayout) private var axLayout

    init(item: StudioSessionDto, action: @escaping () -> Void) {
        self.item = item
        self.action = action
    }

    private var badge: HomeCreationGrid.Badge? { HomeCreationGrid.badge(forStatus: item.status) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                ZStack(alignment: .topTrailing) {
                    CovaPixelCover()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
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
                Text(item.displayTitle)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    .lineLimit(axLayout ? 3 : 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    /// 一张卡一个可聚焦元素（08 §6 同口径）；没有徽标时**不**念一个"没有状态"。
    private var accessibilityText: String {
        guard let badge else { return item.displayTitle }
        return "\(item.displayTitle)，\(HomeCreationGrid.label(of: badge))"
    }
}

// MARK: - 美术腿（R18-2）

/// 01 屏的三条封面腿：场景精选 `track.cover`、继续聆听 `recent.coverURLString`、
/// 推荐歌单 `playlist.cover`/`coverUrl`。
///
/// 判据一律在 `CovaArtworkResolution`（CovaUI 唯一裁决面）：本屏只回答「哪个字段进哪个槽」。
/// 线上事实（2026-09-25 只读核对，见 D23 名单补充）：`GET /api/tracks` 内嵌的 `artist.avatar`
/// 是**站内相对**（20 行里 11 行相对 / 9 行没有），`GET /api/user-playlists` 的 `coverUrl` /
/// `imageUrl` 是**站内相对 + 带查询串** —— 相对串没有 scheme，直接 `URL(string:)` 交给
/// `CovaArtworkCache.fetch` 就是出口判定为假 ⇒ 一次请求都不发、只剩占位（R16-1 同族）。
/// 三条腿因此一律先裁决再交图。
enum HomeArtwork {
    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }

    /// 继续聆听：账里存的是 `item.coverURL?.value.absoluteString`（`AppSession` 写入时已过
    /// `resolveMediaURL`，见 `AppSession.swift:473`），形态是**绝对 + 可能带查询** ⇒
    /// 这条腿同样先裁决再交图，不因"是本机自己写的"而免检。
    static func recentCover(_ track: RecentTrack) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.coverURLString)
    }

    /// 歌单图有两个候选字段：`cover` 与 `coverUrl`（先到的**非空**值赢）。
    static func playlistCover(_ playlist: PlaylistDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValues: [playlist.cover, playlist.coverUrl])
    }
}
