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
/// · `colorPalette` 只接受 `#RGB` / `#RRGGBB`，**不拿任意字符串当色值**试。
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
                action: { session.path = []; session.tab = .home }
            )
        case .emptyButKnown(let persona):
            VStack(spacing: CovaSpace.lg) {
                header(persona)
                CovaEmptyState(
                    symbol: "music.note.list",
                    title: "这位音乐人还没有公开曲目",
                    hint: "先去曲库听听别的",
                    actionTitle: "去曲库",
                    action: { session.path = []; session.tab = .library }
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

    @ViewBuilder
    private func header(_ artist: ArtistDto) -> some View {
        VStack(spacing: CovaSpace.md) {
            CovaArtwork(url: URL(string: artist.avatar ?? ""), title: artist.name)
                .frame(width: axLayout ? 88 : 112, height: axLayout ? 88 : 112)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(swash(artist.colorPalette), lineWidth: 2))
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

    /// `colorPalette` 在真实响应里是 JSON 字符串（可能是数组也可能是单值）⇒
    /// 只认 `#RGB` / `#RRGGBB`，其余一律视为"没有"，不去猜。
    private func swash(_ raw: String?) -> Color {
        guard let raw else { return CovaColor.line }
        guard let hex = firstHexColor(in: raw) else { return CovaColor.line }
        return Color(hexString: hex) ?? CovaColor.line
    }

    private func firstHexColor(in raw: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: "#[0-9a-fA-F]{6}|#[0-9a-fA-F]{3}")
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = pattern?.firstMatch(in: raw, range: range),
              let swiftRange = Range(match.range, in: raw) else { return nil }
        return String(raw[swiftRange])
    }

    private var actionBar: some View {
        HStack(spacing: CovaSpace.md) {
            CovaButton("播放全部") {
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
                        subtitle: "\(track.artistNameCn ?? track.artist.name) · \(Int(track.audioDuration ?? track.duration))s · BPM \(track.bpm)",
                        artwork: CovaArtwork(url: URL(string: track.cover), title: track.title)
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

extension Color {
    /// 只接受 `#RGB` / `#RRGGBB`；其余返回 `nil`（调用方必须准备"没有颜色"的样子）。
    init?(hexString: String) {
        var raw = hexString
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 3 || raw.count == 6 else { return nil }
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255
        )
    }
}
