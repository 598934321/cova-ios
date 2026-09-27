import CovaCore
import Foundation

/// §5 P3「每日推荐 / 歌单广场 / 分享歌单」的读腿（三条都是**只读**）。
///
/// 为什么不塞进 `CatalogService`：那一位的 `client` 是私有的，而这三条腿的失败分档
/// 与官方目录那条不一样 —— 分享详情**免登录可读**（服务端对未登录也回内容），
/// 把它接进"401 就要求登录"的那套分类会把一个公开页面画成登录墙。
public struct PlaylistDiscoveryService: Sendable {
    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// 每日推荐位。`date` 只在接受 `YYYY-MM-DD` 时才带上（别的形状服务端回 400，
    /// 不带参数则由服务端自己取今日 —— 客户端不替它挑日期）。
    public func dailyPicks(date: String? = nil) async throws -> DailyPlaylistsResponseDto {
        try await client.get(DailyPlaylistsResponseDto.path, queryItems: DailyPlaylistsResponseDto.queryItems(date: date))
    }

    /// 广场：已开启分享的用户歌单（最近更新在前）。
    public func sharedBoard() async throws -> PublicPlaylistsResponseDto {
        try await client.get(PublicPlaylistsResponseDto.path)
    }

    /// 分享歌单详情。`path(token:)` 判定这枚 token 不能安全进路径段 ⇒ **不发**（`nil`）。
    public func sharedDetail(token: String) async throws -> SharedPlaylistResponseDto? {
        guard let path = SharedPlaylistResponseDto.path(token: token) else { return nil }
        return try await client.get(path)
    }
}

/// 05 屏的三个来源（本轮把原来"只有官方"的那一屏推到三条腿）。
public enum PlazaSource: String, CaseIterable, Identifiable, Sendable {
    case official
    case daily
    case shared

    public var id: String { rawValue }

    /// 屏上那三个字。段控件的标签**不**从服务端字段来（服务端给的是 `source: "official"`
    /// 这种机器名，直接上屏就是把工程词给用户看）。
    public var label: String {
        switch self {
        case .official: return "官方歌单"
        case .daily: return "每日推荐"
        case .shared: return "歌单广场"
        }
    }

    /// 只为模拟器逐屏截图存在的默认源（§6.1 同族的走查键）：
    /// `COVA_PREVIEW_PLAZA_SOURCE=daily|shared`。段控件要点一下才换源，而 `simctl` 不给点击
    /// ⇒ 没有这一格，A14 就拍不到这两源的深浅两张（"有一张默认态的图"不等于"这一屏拍过了"）。
    public static var previewDefault: PlazaSource {
        switch ProcessInfo.processInfo.environment["COVA_PREVIEW_PLAZA_SOURCE"] {
        case "daily": return .daily
        case "shared": return .shared
        default: return .official
        }
    }

    /// 场景 chips 只对**官方**那一本账成立：`/api/playlists` 的卡带 `scene`，
    /// 而 daily / public 两支的投影里都没有这个键（逐条核过 web 的 select）。
    /// ⇒ 另两源不给 chips，而不是给一排点了必然为空的分类。
    public var showsSceneChips: Bool { self == .official }
}

/// 一张卡该跳去哪。**不**返回 `AppSession.Route`（那属于视图层），这样这一格能在
/// 纯单测里判，不必把 MainActor 的会话对象拖进来。
public enum PlaylistBoardDestination: Equatable, Sendable {
    case officialPlaylist(String)
    case sharedPlaylist(String)
    /// 这张卡**今天没有可去的地方**：官方卡没 id，或分享卡的 href 不是我们认的那个形状。
    /// 视图据此把卡片渲染成不可点，而不是"点了再说"。
    case nowhere
}

public enum PlaylistBoard {
    /// 来源那一格是**决定性的**：分享腿的 id 是用户歌单 id，拿它打 `GET /api/playlists/:id`
    /// 只会 404 ⇒ 不许"先按官方试一下"。
    public static func destination(for pick: PlaylistPickDto) -> PlaylistBoardDestination {
        switch pick.source {
        case .official:
            guard !pick.playlist.id.isEmpty else { return .nowhere }
            return .officialPlaylist(pick.playlist.id)
        case .shared:
            guard let token = pick.shareToken else { return .nowhere }
            return .sharedPlaylist(token)
        case .unknown:
            // 服务端加了一类新来源 ⇒ 不猜它是官方还是分享（猜错就是打错端点 + 404）。
            return .nowhere
        }
    }
}
