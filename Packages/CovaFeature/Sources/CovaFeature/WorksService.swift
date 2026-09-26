import CovaCore
import Foundation

/// works 列表与七项行内动作的读写出腿（§5 P1-1 / §6 A7）。
///
/// 三条口径写在这一层而不是留给调用方自觉：
/// · **行内动作一律带身份校验的路径**：`WorkActionRoute.validatedPath(workID:)` 会先过
///   `WorksPathEncoding` 的字符集闸（伪 id `{jobId}:{candidateId}` 里那枚 `:` 在路径段里
///   是合法的，但空白/控制字符/超长必须**不发**，而不是发出去让服务端 404 再猜为什么）。
/// · **非 2xx 拿原始信封自己分诊**：`CovaAPIError.httpStatus` 只留状态码，而这一族
///   服务端把话说在 body 里（409「作品尚未生成完成，暂不能执行此操作」与 404「作品不存在」
///   处置方式完全不同：一个是"等一等"，一个是"这行该没了"）⇒ 走 `performCoded` +
///   `WorkActionRejection.classify`，与 19 屏那条 402 同一个套路。
/// · **2xx 不等于办成**：favorite/dislike/note 的回执都带 `ok`，读不出 `ok:true` 由调用方
///   按各 DTO 的 `isAcknowledged` 判（本层不替它编成功）。
public struct WorksService: Sendable {

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    // MARK: - 列表

    /// 一页作品行。`query` 已经把 `filter`/`sort`/`cursor`/`limit` 钳到服务端认的形状，
    /// 这里只负责发出去、把响应整页交给 `WorksPageDto` 的逐行容错解码。
    public func page(_ query: WorksListQuery) async throws -> WorksPageDto {
        try await client.get(WorksListQuery.path, queryItems: query.queryItems)
    }

    // MARK: - 行内动作

    public func setFavorite(
        workID: String, _ toggle: WorkActionToggle
    ) async throws -> WorkFavoriteResponseDto {
        try await post(WorkFavoriteRequestDto(toggle), route: .favorite, workID: workID)
    }

    public func setDislike(
        workID: String, _ toggle: WorkActionToggle
    ) async throws -> WorkDislikeResponseDto {
        try await post(WorkDislikeRequestDto(toggle), route: .dislike, workID: workID)
    }

    /// 「收藏到笔记」是**物化**：只回一个 `noteId`，备注文本要另走 `PATCH /api/notes/:id`
    /// （§4.7：那条腿未进契约 ⇒ 本屏不接文本编辑）。
    public func materializeNote(workID: String) async throws -> WorkNoteMaterializationDto {
        try await post(EmptyBody(), route: .note, workID: workID)
    }

    public func timing(workID: String) async throws -> WorkTimingResponseDto {
        try await request(.timing, workID: workID)
    }

    /// 开或复用同一条分享链接（服务端幂等：已开就回既有 `sharePath`）。
    public func openShare(workID: String) async throws -> WorkShareEnableResponseDto {
        try await post(EmptyBody(), route: .shareOpen, workID: workID)
    }

    public func shareStatus(workID: String) async throws -> WorkShareStatusResponseDto {
        try await request(.shareStatus, workID: workID)
    }

    public func closeShare(workID: String) async throws -> WorkActionAcknowledgementDto {
        try await request(.shareClose, workID: workID)
    }

    /// 改名。**这是 job 级写操作**：一次生成产两行，改一行等于改两行（§4.7）⇒
    /// 调用方必须在发之前就把这件事告诉用户，而不是发完再解释屏上为什么两行一起变。
    public func rename(workID: String, title: String) async throws -> WorkRenameResponseDto {
        let path = try validatedPath(.rename, workID: workID)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(WorkRenameRequestDto(title: title))
        } catch let error as WorkActionRequestError {
            throw WorksActionError.localValidation(error)
        }
        return try await exchange(.patch, path: path, jsonBody: payload)
    }

    /// 删除。同样是 job 级（软删整个任务 ⇒ 两行一起消失）。
    public func delete(workID: String) async throws -> WorkActionAcknowledgementDto {
        try await request(.delete, workID: workID)
    }

    // MARK: - 共用的收发

    private func post<Body: Encodable, Response: Decodable>(
        _ body: Body, route: WorkActionRoute, workID: String
    ) async throws -> Response {
        let path = try validatedPath(route, workID: workID)
        return try await exchange(
            route.method, path: path,
            jsonBody: try JSONEncoder().encode(body)
        )
    }

    private func request<Response: Decodable>(
        _ route: WorkActionRoute, workID: String
    ) async throws -> Response {
        try await exchange(
            route.method, path: try validatedPath(route, workID: workID), jsonBody: nil
        )
    }

    /// 身份不合格 ⇒ **不发**，并且报的是"为什么没发"（空白/非法字符/超长是三回事，
    /// 让它们都长成"服务端 404"就是把客户端的账记到后端头上）。
    private func validatedPath(_ route: WorkActionRoute, workID: String) throws -> String {
        do {
            return try route.validatedPath(workID: workID)
        } catch let error as WorkActionRequestError {
            throw WorksActionError.localValidation(error)
        }
    }

    /// 一次收发：传输层/出口裁决照常抛（那些压根没有一个 HTTP 结果可交），
    /// 有 HTTP 结果的**一律先分诊再决定抛什么**，成功才解码。
    private func exchange<Response: Decodable>(
        _ method: HTTPMethod, path: String, jsonBody: Data?
    ) async throws -> Response {
        let outcome: CovaHTTPOutcome
        do {
            outcome = try await client.performCoded(
                method: method, path: path, jsonBody: jsonBody
            )
        } catch {
            throw WorksActionError.transport(CatalogService.classify(error))
        }
        guard outcome.isSuccess else {
            throw WorksActionError.rejected(
                WorkActionRejection.classify(statusCode: outcome.statusCode, body: outcome.body)
            )
        }
        // 解码失败不许记到后端账上（CatalogService 那条口径：客户端 DTO 待核是我们自己的账）。
        guard let decoded = try? JSONDecoder().decode(Response.self, from: outcome.body) else {
            throw WorksActionError.unreadableResponse
        }
        return decoded
    }

    /// 无请求体的 POST（note / share 两条腿服务端不读 body，但客户端的 `post` 通道要一个
    /// 可编码对象）⇒ 发一个空的 JSON 对象，而不是发明字段。
    private struct EmptyBody: Encodable {}
}

/// 行内动作的失败面：三类，各有各的处置，不并成一锅「操作失败」。
public enum WorksActionError: Error, Equatable, Sendable {
    case rejected(WorkActionRejection)
    case transport(CatalogFailure)
    /// 本地就拦下的（标题空/超长、伪 id 不能安全进路径）—— 请求**一次都没发出去**。
    case localValidation(WorkActionRequestError)
    /// 2xx 但读不出回执：这是**我们**的解码器与他们的形状没对上，
    /// 不许说成"服务端错误"，也不许当成成功。
    case unreadableResponse

    public var userMessage: String {
        switch self {
        case .rejected(let rejection): return rejection.userMessage
        case .transport(let failure): return failure.userText
        case .localValidation(let error): return String(describing: error)
        case .unreadableResponse: return "服务端回话了，但我没读懂（客户端待核）"
        }
    }
}
