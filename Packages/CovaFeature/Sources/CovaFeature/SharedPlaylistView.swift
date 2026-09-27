import CovaCore
import CovaUI
import SwiftUI

/// 分享歌单详情（§5 P3：`GET /api/shared-playlists/[token]`，免登录可读）。
///
/// 05 的「每日推荐 / 歌单广场」两源里，`source: "shared"` 那张卡的目的地就是这里 ——
/// 它的 id 是**用户歌单 id**，打官方那条 `GET /api/playlists/:id` 只会 404，
/// 所以这一屏不是 06 的一个变体，是另一条腿的目的地。
///
/// 两件事刻意没做，都不是遗漏：
/// · **不给"下载全部"**：响应里有 `downloadsEnabled` / `downloadCredits`，但付费下载那一格
///   受 D12 与"门 1 未放行"约束（§1 硬边界），本屏读了也不画；
/// · **不给"收藏到我的歌单"**：那要走 `POST /api/shared-playlists/[token]/claim`，
///   是写操作，本轮只交付读面（已登记在 §5 P3 那张表的对应行）。
public struct SharedPlaylistView: View {
    @Environment(AppSession.self) private var session

    private enum Phase: Equatable {
        case loading
        case ready(SharedPlaylistResponseDto)
        /// 这一枚 token 不能安全进路径 ⇒ **没发过请求**。它与"服务端说没有"不是一回事。
        case unusableToken
        case failed(String)
    }

    @State private var phase: Phase = .loading
    private let token: String

    public init(token: String) { self.token = token }

    public var body: some View {
        content
            .covaPage()
            .navigationTitle("分享的歌单")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            CovaSkeleton(rows: 6)
        case .unusableToken:
            CovaEmptyState(
                symbol: "link.badge.plus",
                title: "这个分享链接读不了",
                hint: "链接里的标识不合规则，请求没有发出去。"
            )
        case .failed(let message):
            // `CovaErrorState` 只按档给一句通用话；这一屏要多说的那一句是**服务端给的原因**
            // （404 的原文就是「歌单不存在或未开启分享」），所以把原因单独摆在下面。
            VStack(spacing: CovaSpace.sm) {
                CovaErrorState(kind: .server, retry: { Task { await load() } })
                Text(message)
                    .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    .multilineTextAlignment(.center)
            }
        case .ready(let dto):
            detail(dto)
        }
    }

    @ViewBuilder
    private func detail(_ dto: SharedPlaylistResponseDto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.lg) {
                header(dto.playlist)
                if dto.viewerIsOwner {
                    // 服务端明确说了是主人 —— 这一句只在它真说过时出现（缺键按"不是主人"处理）。
                    Text("这是你自己分享出去的链接")
                        .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                }
                trackList(dto.tracks)
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.top, CovaSpace.md)
        }
    }

    @ViewBuilder
    private func header(_ playlist: SharedPlaylistDto?) -> some View {
        if let playlist {
            HStack(alignment: .top, spacing: CovaSpace.md) {
                CovaArtwork(
                    resolution: CovaArtworkResolution(serverValues: [
                        playlist.coverUrl, playlist.coverMedia?.imageUrl,
                    ]),
                    title: playlist.name ?? "分享的歌单"
                )
                .frame(width: 120)
                .aspectRatio(1.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CovaRadius.card, style: .continuous))
                VStack(alignment: .leading, spacing: CovaSpace.xs) {
                    Text(playlist.name ?? "未命名歌单")
                        .font(CovaType.title).foregroundStyle(CovaColor.fg)
                    if let creator = playlist.creatorName, !creator.isEmpty {
                        Text("来自 \(creator)")
                            .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                    }
                    if let description = playlist.description, !description.isEmpty {
                        Text(description).font(CovaType.subhead).foregroundStyle(CovaColor.fg)
                    }
                    Text(meta(playlist))
                        .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                }
            }
        } else {
            // 200 但没有 playlist 那一层：这是信封读不懂，不是"歌单是空的"。
            Text("这份响应里没有歌单头部").font(CovaType.subhead).foregroundStyle(CovaColor.muted)
        }
    }

    @ViewBuilder
    private func trackList(_ tracks: [TrackDto]?) -> some View {
        if let tracks, !tracks.isEmpty {
            VStack(alignment: .leading, spacing: CovaSpace.sm) {
                ForEach(tracks, id: \.id) { track in
                    HStack(spacing: CovaSpace.sm) {
                        Text(track.titleCn ?? track.title)
                            .font(CovaType.callout).foregroundStyle(CovaColor.fg)
                            .lineLimit(2)
                        Spacer(minLength: CovaSpace.sm)
                        Text(clock(track.duration))
                            .font(CovaType.caption).foregroundStyle(CovaColor.secondary)
                    }
                    .padding(.vertical, CovaSpace.xs)
                    Divider()
                }
            }
        } else {
            // 曲目层读不出（或缺）与"这是一份空歌单"在屏上画同一片空白，
            // 但**这句话不能说成"没有歌"** —— 前者是读失败，后者是服务端的事实。
            Text("曲目没取到，只有这份歌单的头部信息。")
                .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
        }
    }

    private func meta(_ playlist: SharedPlaylistDto) -> String {
        var parts: [String] = []
        if let count = playlist.trackCount { parts.append("\(count) 首") }
        parts.append("分享链接")
        return parts.joined(separator: " · ")
    }

    /// `mm:ss`。本屏不复用播放器那套格式化（那一层在 CovaPlayer，为三行字符串引一条依赖不值）。
    private func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func load() async {
        guard SharedPlaylistResponseDto.path(token: token) != nil else {
            phase = .unusableToken
            return
        }
        do {
            guard let dto = try await session.playlistDiscovery.sharedDetail(token: token) else {
                phase = .unusableToken
                return
            }
            phase = .ready(dto)
        } catch let failure as CatalogFailure {
            phase = .failed(Self.copy(for: failure))
        } catch {
            phase = .failed("这个歌单没读到")
        }
    }

    /// 404 是服务端自己那句话（`歌单不存在或未开启分享`）⇒ 屏上说同一句；
    /// 401 这一屏不该出现（免登录可读），真出现了也照实说，不偷偷去拉登录框。
    private static func copy(for failure: CatalogFailure) -> String {
        switch failure {
        case .network: return "网络不通，这个歌单没读到"
        case .unauthenticated: return "这个歌单要求登录才能看"
        case .server(let message): return message.isEmpty ? "这个歌单没读到" : message
        case .backendGap(let note): return "服务端这一格还没备好（\(note)）"
        }
    }
}
