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
                    CovaSectionHeader("推荐歌单", trailing: "全部 ›") {
                        session.path.append(.plaza)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CovaSpace.md) {
                            ForEach(playlists, id: \.id) { playlist in
                                PlaylistCard(playlist: playlist) {
                                    session.path.append(.playlist(playlist.id))
                                }
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
