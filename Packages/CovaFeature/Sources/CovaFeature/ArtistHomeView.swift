import CovaCore
import CovaUI
import SwiftUI

/// AI 音乐人主页（design 16）。
///
/// **人设来源的硬裁决（16 §7，本屏最重要的一条）**：契约里**没有** `GET /api/artists` 或
/// `/api/artists/:id`，人设 = **首条曲目内嵌的 `artist` 对象**（`GET /api/tracks?artistId=`）。
/// 有曲目即有人设；不得为拿人设去发明端点。代价据实写在这里：
/// 当该艺人 `total == 0` 时头区无处取数 ⇒ 走「找不到这位音乐人」空态 2（16 待裁决 2 的同一件事）。
///
/// 三条禁令逐条落码：
/// · **不渲染** `stylePrompt` / `lyricsPrompt` / `sceneResponsibility` —— 那是内部提示词，
///   露出来就是泄漏（16 §7 硬性禁令），哪怕它们"看起来能填上 D/E 两行"；
/// · 右侧**不放「关注」**（无关注端点）；
/// · `colorPalette` 只接受 `#RGB` / `#RRGGBB`，**不拿任意字符串当色值**试
///   （解析只有一条腿：`ArtistSwash.swatch(fromPalette:)`，CovaCore，可测）。
public struct ArtistHomeView: View {
    /// 16 §Dynamic Type：AX 档下头像 112 → 88，把宽度让给文本（图像本身不随字号放大）。
    @Environment(\.covaAXLayout) private var axLayout
    @Environment(AppSession.self) private var session
    private let artistID: String
    @State private var phase: Phase = .loading
    @State private var tracks: [TrackDto] = []
    @State private var artist: ArtistDto?
    @State private var page = 1
    @State private var totalPages = 1
    @State private var pendingPlay: [TrackDto] = []

    private enum Phase: Equatable {
        case loading
        case ready
        case offlineWithoutCache          // 离线且没有可显示的内容
        case notFound                     // 空态 2：无曲目且人设无处可取 ⇒ 不给「重试」
        case emptyButKnown(ArtistDto)     // 空态 1：有人设、没曲目
        case failed(CatalogFailure)
    }

    public init(artistID: String) { self.artistID = artistID }

    public var body: some View {
        content
            .covaPage()
            .navigationTitle(artist.map { $0.nameCn ?? $0.name } ?? "AI 音乐人")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load(reset: true) }
            .refreshable { await load(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 6).padding(.top, CovaSpace.lg)
        case .failed(let failure):
            CovaErrorState(kind: Self.kind(failure)) { Task { await load(reset: true) } }
        case .offlineWithoutCache:
            CovaErrorState(kind: .network) { Task { await load(reset: true) } }
        case .notFound:
            CovaEmptyState(
                symbol: "person.dashed",
                title: "找不到这位音乐人",
                hint: "TA 可能还没有公开曲目。",
                actionTitle: "回首页",
                action: { session.goToTabRoot(.home) }
            )
        case .emptyButKnown(let persona):
            VStack(spacing: CovaSpace.lg) {
                header(persona)
                CovaEmptyState(
                    symbol: "music.note.list",
                    title: "这位音乐人还没有公开曲目",
                    hint: "先去曲库听听别的",
                    actionTitle: "去曲库",
                    action: { session.goToTabRoot(.library) }
                )
            }
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: CovaSpace.lg) {
                    if let artist { header(artist) }
                    list
                }
                .padding(.bottom, CovaSpace.xxl)
            }
        }
    }

    // MARK: B–F 头区

    /// §3 头区容器（B–F）：**底为「艺人主色 → `color.canvas`」的柔和铺底**（TG-40 的两档
    /// 叠加强度在 `CovaSwashBackdrop` 里，解析口径在 `ArtistSwash`），下内边距 `spacing.xl`。
    ///
    /// 顺带按 §5 把**头像边框去掉**：「头像不加边框（两主题均由 `radius.capsule` 与铺底差值
    /// 分离）」—— 这一格以前没有铺底，那圈描边是给"没有差值"打的补丁；铺底来了，
    /// 补丁就该跟着撤掉，否则同一屏同时存在两种分离手段。
    @ViewBuilder
    private func header(_ artist: ArtistDto) -> some View {
        VStack(spacing: CovaSpace.md) {
            CovaArtwork(resolution: ArtistHomeArtwork.avatar(artist), title: artist.name)
                .frame(width: axLayout ? 88 : 112, height: axLayout ? 88 : 112)
                .clipShape(Circle())
                .accessibilityLabel("\(artist.nameCn ?? artist.name) 的头像")
            Text(artist.nameCn ?? artist.name)
                .font(CovaType.largeTitle).foregroundStyle(CovaColor.fg)
                .multilineTextAlignment(.center)
            // D 风格短语：styleCn + coreInstruments 两个都空 ⇒ 整行不渲染（不补占位）。
            if let styleLine = stylePhrase(artist) {
                Text(styleLine).font(CovaType.callout).foregroundStyle(CovaColor.secondary)
            }
            // E 人设一句话：空 ⇒ 不渲染。**绝不**用内部提示词字段填这一行。
            if let persona = artist.personality, !persona.isEmpty {
                Text(persona).font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            }
            actionBar
        }
        .frame(maxWidth: .infinity)
        .padding(.top, CovaSpace.md)
        .padding(.bottom, CovaSpace.xl)   // §3：头区容器下内边距 spacing.xl
        .background(
            CovaSwashBackdrop(tint: swatchColor(artist), identity: swashIdentity(artist))
        )
    }

    /// 主色：`artist.colorPalette` → 只认 `#RGB`/`#RRGGBB`（§7）；解不出 ⇒ `nil`
    /// （铺底那侧回落 `color.surface`）。**不**在这里补"看起来像品牌色"的默认值。
    private func swatchColor(_ artist: ArtistDto) -> Color? {
        guard let swatch = ArtistSwash.swatch(fromPalette: artist.colorPalette) else { return nil }
        return Color(red: swatch.red, green: swatch.green, blue: swatch.blue)
    }

    /// 交叉淡入的触发身份：艺人与那串调色板一起进键 —— 同一个人换了主色也要淡一次。
    private func swashIdentity(_ artist: ArtistDto) -> String {
        "\(artist.id)|\(artist.colorPalette ?? "-")"
    }

    private func stylePhrase(_ artist: ArtistDto) -> String? {
        // `coreInstruments` 在真实响应里是 **JSON 字符串**（不是数组）⇒ 先解析再显示；
        // 解不出来就当没有这一项，而不是把 `["电子钢琴",…]` 这种原始串直接印在文案位上。
        let instruments = Self.jsonStringList(artist.coreInstruments).joined(separator: "、")
        let parts = [artist.styleCn, instruments.isEmpty ? nil : instruments]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 只接受「字符串数组」这一种形态；其它（对象、数字、坏 JSON）一律返回空 ——
    /// 宁可少显示一行，也不把没解析的东西当文案。
    static func jsonStringList(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// F 主操作行。
    private var actionBar: some View {
        HStack(spacing: CovaSpace.md) {
            // 16 §3.E：「播放全部」是 hero CTA 档（gradient.brandButton + 橙投影）。
            CovaButton("播放全部", style: .brand) {
                Task { await playAll() }
            }
            // 右侧**不放「关注」**：没有关注端点，放一个点了没反应的按钮比不放更糟。
            ShareLink(item: URL(string: "https://covalink.cn/artists/\(artistID)") ?? URL(string: "https://covalink.cn")!) {
                Text("分享")
                    .font(CovaType.callout).foregroundStyle(CovaColor.accent)
            }
        }
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    /// 「播放全部」按 16 §5：已加载的全部曲目一起进队列；不足一页时先播已加载的部分。
    private func playAll() async {
        let playable = pendingPlay.isEmpty ? tracks : pendingPlay
        guard !playable.isEmpty else { return }
        await session.play(tracks: playable, at: 0)
        if playable.count < tracks.count { session.showToast("先播已加载的部分") }
    }

    // MARK: G–I 曲目区

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            CovaSectionHeader("曲目（\(tracks.count)）")
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                // 某条曲目标题全空 ⇒ 该行不渲染（脏数据不"修正"）。
                if (track.titleCn ?? track.title).isEmpty {
                    EmptyView()
                } else {
                    CovaListRow(
                        title: track.titleCn ?? track.title,
                        subtitle: TrackRowCopy.subtitle(
                            artist: track.artistNameCn ?? track.artist.name,
                            durationSeconds: Int(track.audioDuration ?? track.duration),
                            bpm: track.bpm
                        ),
                        artwork: CovaArtwork(resolution: ArtistHomeArtwork.cover(track), title: track.title)
                    ) {
                        let on = session.favoriteIDs.contains(track.id)
                        Button {
                            Task { if session.requireLoginForCollections() { await session.toggleFavorite(track.id) } }
                        } label: {
                            Image(systemName: on ? "heart.fill" : "heart")
                                .foregroundStyle(on ? CovaColor.accent : CovaColor.muted)
                        }
                        .buttonStyle(.plain)
                    } action: {
                        Task { await session.play(tracks: tracks, at: index) }
                    }
                    .contextMenu {
                        Button("曲目详情") { session.detailTrackID = track.id }
                        // 下载项在 D12 合规放行前**不渲染**。
                    }
                }
            }
            if page < totalPages {
                CovaButton(phase == .loading ? "加载中…" : "加载更多", style: .secondary) {
                    Task { await loadMore() }
                }
                .padding(CovaSpace.lg)
            } else {
                Text("已显示全部")
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CovaSpace.lg)
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

    private func load(reset: Bool) async {
        if reset {
            phase = .loading
            page = 1
        }
        do {
            let first = try await session.catalog.tracks(artistID: artistID, page: page)
            tracks = reset ? first.tracks : tracks + first.tracks
            totalPages = first.totalPages ?? 1
            artist = first.tracks.first?.artist ?? artist
            if let artist, tracks.isEmpty {
                phase = .emptyButKnown(artist)
            } else if tracks.isEmpty {
                // 无曲目 ⇒ 人设也无处可取（16 §7 的来源裁决在这里的必然结果）⇒ 空态 2，不给重试。
                phase = .notFound
            } else {
                phase = .ready
            }
        } catch {
            let failure = CatalogService.classify(error, decodingNeeds: "NEEDS-22")
            if !reset || !tracks.isEmpty {
                session.showToast("音乐人页没取到，可下拉重试", isError: true)
            }
            phase = tracks.isEmpty ? .failed(failure) : .ready
        }
    }

    private func loadMore() async {
        guard page < totalPages else { return }
        do {
            let next = try await session.catalog.tracks(artistID: artistID, page: page + 1)
            tracks += next.tracks
            page += 1
            totalPages = next.totalPages ?? totalPages
            phase = .ready
        } catch {
            session.showToast("加载更多失败，可重试", isError: true)
        }
    }
}

// MARK: - 美术腿（R18-2）

/// 16 屏的两条封面腿：`artist.avatar`（头区圆像）与 `track.cover`（曲目行）。
///
/// 这里**只有「哪个字段进哪个槽」**这一件事，出口判据一律在 `CovaArtworkResolution`
/// （CovaUI 的唯一裁决面）：本屏不许长出第二条补全规则，也不许把原文直接喂 `URL(string:)`。
///
/// 为什么把腿单独抽出来（而不是在视图体里内联）：线上 `GET /api/artists` 的 `artist.avatar`
/// 实测 **13 行里 12 行是站内相对路径**（2026-09-25 只读核对，见 D23 的名单补充），
/// 而相对串直接 `URL(string:)` 没有 scheme ⇒ 出口判定为假 ⇒ **一次请求都不发**、只剩占位
/// （R16-1 同族、同一种看不见的失效）。抽成可命名、可 `@testable` 调用的腿，
/// 是让这一条**能在测试里红**的最低成本做法 —— 不是给 UI 造快照框架。
enum ArtistHomeArtwork {
    static func avatar(_ artist: ArtistDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: artist.avatar)
    }

    static func cover(_ track: TrackDto) -> CovaArtworkResolution {
        CovaArtworkResolution(serverValue: track.cover)
    }
}
