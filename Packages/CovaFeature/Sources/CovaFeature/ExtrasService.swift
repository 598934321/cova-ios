import CovaCore
import Foundation

/// 补充制作（母带 / 分轨 / 伴奏 / 歌词视频 / 时间轴歌词）的两条腿（§5 P2-1 / §6 A8）。
///
/// 两条腿**不是**同一件事，返回类型也不共用：
/// · **作品级** `works/{id}/extras` —— **只认伪 id**（裸 jobId 服务端 404，而那句 404 与
///   "作品不存在"在屏上分不开 ⇒ 本地先拦），响应里**没有** `deliveryRevision`，
///   且**服务端这一支不扣费**（`extras-service.ts` 的作品级路径里没有 `consumeCredits`）
///   ⇒ UI 不许在这条腿上写消耗。
/// · **会话级** `/api/studio/extras` —— 带 `sessionId`，回 `deliveryRevision`
///   （工作流计数器，驱动版本比对的唯一依据），且**按 key 扣费**
///   （wav 20 / accompaniment 30 / stems 50 / vocal_stems 50 / lyrics_timing 10 / lyrics_video 100）。
///
/// `files[].url` 里的 jobId 是 **worker job** 不是生成 job ⇒ 只许**原样消费**；
/// 任何"我们自己拼一条产物地址"的写法都会指到别的工作流上去（§4.7）。
public struct ExtrasService: Sendable {

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    // MARK: - 作品级

    /// 发起作品级补充制作。键集必须先用 `WorkExtraKey.allowedKeys(instrumental:)` 过一遍
    /// （纯音乐那四项不合法），空集在本地就拒。
    public func request(workID: String, keys: [WorkExtraKey]) async throws -> WorkExtrasResponseDto {
        let path = try workPath(workID: workID)
        let payload = try encoded(WorkExtrasRequestDto(keys: keys))
        return try await exchange(.post, path: path, jsonBody: payload)
    }

    /// 复列作品级产物。A8 的幂等半条是"同一个键集重复 POST 不重复制作"，
    /// 但面板打开时仍要先读这一次：拿上一次留在内存里的清单装成服务端事实，
    /// 就会把"其实还在做"的那格画成"已经好了"。
    public func files(workID: String) async throws -> WorkExtrasResponseDto {
        try await exchange(.get, path: try workPath(workID: workID), jsonBody: nil)
    }

    // MARK: - 会话级

    public func request(sessionID: String, keys: [WorkExtraKey]) async throws
        -> SessionExtrasResponseDto
    {
        let payload = try encoded(SessionExtrasRequestDto(sessionId: sessionID, keys: keys))
        return try await exchange(
            .post, path: WorkExtrasEndpoint.sessionPath, jsonBody: payload
        )
    }

    public func files(sessionID: String) async throws -> SessionExtrasResponseDto {
        guard let items = WorkExtrasEndpoint.sessionQueryItems(sessionId: sessionID) else {
            throw ExtrasFailure.localValidation(
                sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .missingSessionID : .unsafeWorkIdentifier
            )
        }
        return try await exchange(
            .get, path: WorkExtrasEndpoint.sessionPath, jsonBody: nil, queryItems: items
        )
    }

    // MARK: - 共用收发

    private func workPath(workID: String) throws -> String {
        do {
            return try WorkExtrasEndpoint.workPath(workID: workID)
        } catch let error as WorkExtrasRequestError {
            throw ExtrasFailure.localValidation(error)
        }
    }

    /// 请求体的本地校验失败（空键集 / 裸 jobId / 缺 sessionId）都归到 `localValidation`：
    /// 这些**一次请求都没发出去**，不许长成"服务端 400"的样子。
    private func encoded<Body: Encodable & Sendable>(
        _ make: @autoclosure () throws -> Body
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(try make())
        } catch let error as WorkExtrasRequestError {
            throw ExtrasFailure.localValidation(error)
        }
    }

    private func exchange<Response: Decodable>(
        _ method: HTTPMethod, path: String, jsonBody: Data?,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let outcome: CovaHTTPOutcome
        do {
            outcome = try await client.performCoded(
                method: method, path: path, queryItems: queryItems, jsonBody: jsonBody
            )
        } catch {
            throw ExtrasFailure.transport(CatalogService.classify(error))
        }
        guard outcome.isSuccess else {
            throw ExtrasFailure.rejected(
                ExtrasRejection.classify(statusCode: outcome.statusCode, body: outcome.body)
            )
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: outcome.body) else {
            throw ExtrasFailure.unreadableResponse
        }
        return decoded
    }
}

/// extras 的失败面。四类各有各的处置，不并成一句「操作失败」：
/// `rejected` 里还分「等一等」与"这行做不了"（`ExtrasRejection.shouldKeepWaiting`）。
public enum ExtrasFailure: Error, Equatable, Sendable {
    case rejected(ExtrasRejection)
    case transport(CatalogFailure)
    case localValidation(WorkExtrasRequestError)
    /// 2xx 但读不出回执：是我们的解码器没对上他们的形状，不记到后端账上，也不算成功。
    case unreadableResponse

    public var userMessage: String {
        switch self {
        case .rejected(let rejection): return rejection.userMessage
        case .transport(let failure): return failure.userText
        case .localValidation(let error): return String(describing: error)
        case .unreadableResponse: return "服务端回话了，但我没读懂（客户端待核）"
        }
    }

    /// 「还在做」不是失败：面板要保留这一格、下次进来继续看，而不是弹一条错误。
    public var shouldKeepWaiting: Bool {
        if case .rejected(let rejection) = self { return rejection.shouldKeepWaiting }
        return false
    }
}
