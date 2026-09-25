import CovaCore
import Foundation

/// 目录/收藏/歌单的类型化访问（路径与 `docs/api-contracts.md` 对齐）。
/// 每个方法把失败分成三类：网络 / 服务端 / **后端缺口**（点名 NEEDS 编号），
/// 让 UI 的错误态能说真话（design §17）。
public enum CatalogFailure: Error, Equatable {
    case network
    case server(String)
    case unauthenticated
    case backendGap(String)
}

/// 端点**不读请求体**时用的空体（编码为 `{}`）。
///
/// 存在的理由：`CovaAPIClient` 的 post/delete 只有「带 body」形态，而
/// `POST/DELETE /api/notes/:id/favorite` 的参数全在路径里；发 `{}` 与不发体对服务端等价，
/// 但**不能**顺手把 `trackId` 塞进去——那是库曲端点的字段，混用就是第二个 E3b。
private struct EmptyRequestBody: Encodable {}

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

    /// 曲库分页列表（级联筛选 + 搜索 + 分页 + **按艺人筛**）。
    /// 分页用 **page/pageSize**（契约真实形状；没有 cursor）。`artistId` 是契约 §2 明列的筛选项，
    /// 16 艺人页就靠它 + 响应内嵌的 `tracks[].artist` 拿人设（**不发明** `/api/artists/:id`）。
    ///
    /// **查询编码不在本方法里发明**：一律走 `TrackListQuery`（E3a）。服务端读的是
    /// `search=<文本>` 与 `<维度名>=<词条>`，旧实现发的 `q=` / `dimension=` / `term=`
    /// 它三个键都不读 ⇒ 筛选静默失效，每个筛选页看到的都是未筛选的第一页。
    /// `term` 是 03 级联当前的单选形态；`terms` 是同维度多选（编码为重复同名参数，维度内 OR）。
    /// 两者同时给出时按 `term` 在前合并去重。
    public func tracks(
        dimension: String? = nil, term: String? = nil, terms: [String] = [], query: String? = nil,
        artistID: String? = nil, page: Int = 1, pageSize: Int = 20
    ) async throws -> TrackPageDto {
        let request = TrackListQuery(
            dimension: dimension,
            terms: [term].compactMap { $0 } + terms,
            search: query,
            artistID: artistID,
            page: page,
            pageSize: pageSize
        )
        return try await client.get("/api/tracks", queryItems: request.queryItems)
    }

    /// 曲库列表的**跨维度**那条腿：查询编码由调用方交进来（唯一作者
    /// `LibraryFilterSelection.queryItems(search:sort:artistID:page:pageSize:)`），
    /// 本方法只负责发到哪个端点、以及把响应解成 `TrackPageDto`。
    ///
    /// 为什么上面那条 `tracks(dimension:term:terms:)` 不够用（03 审计的那一条）：它是 E3a 的
    /// **单维**形态 —— 一个 `dimension` 配这一维的多个值。而 03 §1 的「咖啡馆 ✕ 平静 ✕」
    /// 是场景 + 情绪两维同时生效，走它只会把第一维发出去，剩下的 chips 就成了
    /// "画着但没发出去"的谎。**参数名一个都不在这里发明**：`page` / `pageSize` / `search` /
    /// `sort` / `artistId` / 维度名即参数名，全部由那条编码函数带着（E3a 的实测口径与用例在那边）。
    public func tracks(queryItems: [URLQueryItem]) async throws -> TrackPageDto {
        try await client.get("/api/tracks", queryItems: queryItems)
    }

    public func trackDetail(_ id: String) async throws -> TrackDetailDto {
        try await client.get("/api/tracks/\(id)")
    }

    public func playlistDetail(_ id: String) async throws -> PlaylistDetailDto {
        try await client.get("/api/playlists/\(id)")
    }

    /// 收藏列表：`{tracks}` 是**合并 feed**（库曲 + 生成笔记），逐条定类型见 `FavoritesListDto`。
    /// （NEEDS-18：批量接口缺口时退化为逐条状态。）
    public func favorites() async throws -> FavoritesListDto {
        try await client.get("/api/favorites")
    }

    /// 收藏/取消，**按条目种类路由**（E3b）。
    ///
    /// · 库曲：`POST` / `DELETE /api/favorites`，body `{trackId}`；
    /// · 生成笔记（`id` 形如 `note:<uuid>`）：`POST` / `DELETE /api/notes/:noteId/favorite`，
    ///   服务端**不读请求体**，故发一个空的 `{}`（`client` 的 post/delete 只有带 body 的形态）；
    /// · 认出是笔记但载荷不安全（会改写路径的那类字符）⇒ **抛错**，
    ///   绝不回落到 `/api/favorites`：实测拿笔记 id 打库曲端点回 404 `{error}`，
    ///   而回落还会把用户的收藏动作记到别人的账上。
    public func setFavorite(trackID: String, _ on: Bool) async throws -> FavoriteMutationResultDto {
        guard let route = FavoriteMutationRoute.route(favoriteID: trackID) else {
            throw CovaAPIError.invalidRequestURL
        }
        switch route {
        case .libraryTrack(let id):
            let body = FavoriteMutationRequestDto(trackId: id)
            return .library(
                on
                    ? try await client.post(FavoriteMutationRoute.libraryPath, body: body)
                    : try await client.delete(FavoriteMutationRoute.libraryPath, body: body)
            )
        case .generatedNote(let noteID):
            return .note(try await setNoteFavorite(noteID: noteID, on))
        }
    }

    /// 笔记收藏开关（独立入口：08/09 的候选卡与收藏页共用这一条腿）。
    /// 载荷按「能否安全进路径段」复核一次 —— 入口可能拿到的是没经判别的裸 noteId。
    public func setNoteFavorite(noteID: String, _ on: Bool) async throws -> NoteFavoriteMutationDto {
        guard let route = FavoriteMutationRoute.route(favoriteID: NoteFavoriteDto.idPrefix + noteID),
              case .generatedNote(let safeID) = route else {
            throw CovaAPIError.invalidRequestURL
        }
        return on
            ? try await client.post(route.path, body: EmptyRequestBody())
            : try await client.delete(route.path, body: EmptyRequestBody())
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
    /// 不一致」，说是哪一条缺口必须由调用方**自己登记过**才算数。
    /// · 默认值曾是 `"NEEDS-1"` ⇒ 任何一次客户端读不懂响应，屏幕上都写着「后端契约缺口
    ///   NEEDS-1 已登记，上线后此处自动可用」—— 2026-09-25 的 03 整屏错误态就是这么被记到
    ///   后端账上的（真实原因是 `TrackDto.bpm/energy` 被写成必填，而服务端成片发 `null`）。
    ///   仓里口径：**客户端的错不许记到后端账上** ⇒ 默认不再有编号，没编号就不指认。
    /// · 真的登记过 NEEDS 的调用点必须**显式**传编号（收藏页 NEEDS-11、曲目详情 NEEDS-8/10、
    ///   歌单详情 NEEDS-9、人设页 NEEDS-22、会话面 NEEDS-23），那条话才有据可依。
    public static func classify(_ error: Error, decodingNeeds: String? = nil) -> CatalogFailure {
        if let api = error as? CovaAPIError {
            switch api {
            case .offline, .timeout, .transport, .cancelled: return .network
            case .httpStatus(let code, _):
                // 401/403 是「你能自己解决」的一类：spec 要求说「登录状态已过期」，
                // 不混进服务端故障。
                if code == 401 || code == 403 { return .unauthenticated }
                // 501 是服务端自己说"没实现"；**404 不是** —— 它最常见的原因是**我们**拿着一个
                // 过期/错端的 id 去打（NEEDS-11 记的就是这个：用 note 的 id 打 `DELETE /api/favorites`
                // 得到 404，被读成"后端少端点"）。所以 404 默认落 `.server`，只有**自己拥有**
                // 一条已登记缺口的调用点才显式 opt-in（与 `decodingNeeds:` 同一个口径）。
                if code == 501 { return .backendGap("NEEDS-14…22") }
                if code == 404 { return .server("资源不存在（404）") }
                return .server("HTTP \(code)")
            case .decoding(let field):
                guard let decodingNeeds else { return .server(unverifiedDecodingCopy(field)) }
                return .backendGap(decodingNeeds)
            default: return .server(api.redactedDescription)
            }
        }
        if error is URLError { return .network }
        return .server(error.localizedDescription)
    }

    /// 「客户端读不了」这句话：只陈述自己知道的事实（哪个字段解不开），并明确**没有**登记为
    /// 后端缺口 —— 待核的是 DTO，不是服务端。
    static func unverifiedDecodingCopy(_ field: String?) -> String {
        "这份响应客户端读不了（字段 \(field ?? "未定位")）：按客户端 DTO 待核，未指认为后端契约缺口"
    }
}
