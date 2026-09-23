import CovaCore
import Foundation

/// 目录/收藏/歌单的类型化访问（路径与 `docs/api-contracts.md` 对齐）。
/// 每个方法把失败分成三类：网络 / 服务端 / **后端缺口**（点名 NEEDS 编号），
/// 让 UI 的错误态能说真话（design §17）。
public enum CatalogFailure: Error, Equatable {
    case network
    case server(String)
    case backendGap(String)
}

public struct CatalogService: Sendable {
    private let client: CovaAPIClient
    public init(client: CovaAPIClient) { self.client = client }

    /// 首页推荐歌单（匿名可读）。
    public func featuredPlaylists() async throws -> [PlaylistDto] {
        let page: PlaylistListDto = try await client.get("/api/playlists")
        return page.playlists
    }

    /// 曲库三级级联的维度树（风格/情绪/场景）。
    public func taxonomy() async throws -> TaxonomyDto {
        try await client.get("/api/library/taxonomy")
    }

    /// 曲库分页列表（级联筛选 + 搜索 + 分页）。
    /// 分页用 **page/pageSize**（契约真实形状；没有 cursor）。
    public func tracks(
        dimension: String? = nil, term: String? = nil, query: String? = nil,
        page: Int = 1, pageSize: Int = 20
    ) async throws -> TrackPageDto {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let dimension { items.append(URLQueryItem(name: "dimension", value: dimension)) }
        if let term { items.append(URLQueryItem(name: "term", value: term)) }
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        return try await client.get("/api/tracks", queryItems: items)
    }

    public func trackDetail(_ id: String) async throws -> TrackDetailDto {
        try await client.get("/api/tracks/\(id)")
    }

    public func playlistDetail(_ id: String) async throws -> PlaylistDetailDto {
        try await client.get("/api/playlists/\(id)")
    }

    /// 收藏列表（NEEDS-18：批量接口缺口时退化为逐条状态）。
    public func favorites() async throws -> FavoritesListDto {
        try await client.get("/api/favorites")
    }

    /// 收藏/取消（契约：`POST /api/favorites` 加、`DELETE` 删；body 只有 trackId）。
    public func setFavorite(trackID: String, _ on: Bool) async throws -> FavoriteMutationResponseDto {
        let body = FavoriteMutationRequestDto(trackId: trackID)
        return on
            ? try await client.post("/api/favorites", body: body)
            : try await client.delete("/api/favorites", body: body)
    }

    /// 我收藏的歌单（12b）。契约响应 `{playlists[]}` + `savedAt`。
    public func savedPlaylists() async throws -> SavedPlaylistsListDto {
        try await client.get("/api/saved-playlists")
    }

    /// 歌单书签（06/12b）：`POST /api/saved-playlists` 加、`DELETE` 删，body 只有 playlistId。
    public func setSavedPlaylist(playlistID: String, _ on: Bool) async throws
        -> SavedPlaylistMutationResponseDto {
        let body = SavedPlaylistMutationRequestDto(playlistId: playlistID)
        return on
            ? try await client.post("/api/saved-playlists", body: body)
            : try await client.delete("/api/saved-playlists", body: body)
    }

    public func me() async throws -> CovaMeResponse {
        try await client.get("/api/auth/me")
    }

    /// 把 `CovaAPIError` 归类成 UI 可说的三句话。
    ///
    /// `decodingNeeds` 是**调用点**的事实，不是错误自己的事实：解码失败只说明「响应和 DTO
    /// 不一致」，说是哪一条缺口必须由调用的是哪个端点决定。旧实现把一切 `.decoding` 都写成
    /// NEEDS-1，于是收藏页（NEEDS-11 混条目）会指着登录缺口撒谎。
    public static func classify(_ error: Error, decodingNeeds: String = "NEEDS-1") -> CatalogFailure {
        if let api = error as? CovaAPIError {
            switch api {
            case .offline, .timeout, .transport, .cancelled: return .network
            case .httpStatus(let code, _):
                if code == 404 || code == 501 { return .backendGap("NEEDS-14…22") }
                return .server("HTTP \(code)")
            case .decoding: return .backendGap(decodingNeeds)
            default: return .server(api.redactedDescription)
            }
        }
        if error is URLError { return .network }
        return .server(error.localizedDescription)
    }
}
