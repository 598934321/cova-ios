import CovaCore
import Foundation

/// 创作闭环（M2）的类型化访问：会话建 / 列表 / 详情、计划卡、启动制作、候选收藏。
///
/// 与 `CatalogService` 同一把口径：失败分成「网络 / 服务端 / **后端缺口**」三类，
/// 让错误态能点名 NEEDS 编号而不是含糊报错（design 17）。
///
/// 三条硬边界写在这里，不靠调用方自觉：
/// · `POST …/plans/start` 必带**幂等键**（AGENTS 硬边界 5 / D8 防重复扣费）；
/// · 重试**换新键**（`retryable_failure` 的「重新制作」是一次新的真实播放请求，不是重放旧键）；
/// · 本服务**不提供**任何删除/重命名会话的方法 —— 契约没有这两个端点，
///   design 08 明令「手势、菜单项、VoiceOver 元素一律不出现」。
public struct StudioService: Sendable {
    private let client: CovaAPIClient
    public init(client: CovaAPIClient) { self.client = client }

    /// 会话列表（契约无分页参数 ⇒ 全量，客户端不重排、不发明 `?limit=`）。
    public func sessions() async throws -> [StudioSessionDto] {
        let page: StudioSessionListDto = try await client.get("/api/find-my-song/sessions")
        return page.sessions
    }

    public func session(_ id: String) async throws -> StudioSessionDetailDto {
        try await client.get("/api/find-my-song/sessions/\(id)")
    }

    /// 建会话（契约固定 `{workflowMode:'one-step', skipWelcome:true}`）。
    public func createSession() async throws -> String {
        let response: StudioCreateSessionResponseDto = try await client.post(
            "/api/find-my-song/sessions", body: CovaCreateSessionRequestDto()
        )
        return response.sessionId
    }

    /// 计划卡（也是 SSE 降级后的 5s 轮询端点）。
    public func planCards(sessionID: String) async throws -> [OneStepPlanCardDto] {
        let response: OneStepPlanCardsResponseDto = try await client.get(
            "/api/studio/one-step/plans",
            queryItems: [URLQueryItem(name: "sessionId", value: sessionID)]
        )
        return response.planCards
    }

    /// 启动制作。**一次逻辑操作 = 一个 token**（D8 / `IdempotencyKeyGenerator` 的约定：
    /// 生成一次，之后同一次操作的重放必须复用同一个键）：
    /// · 调用方**自己持有** token 时传进来（同一次提交的网络重放）；
    /// · 没传 = 一次**新的**逻辑操作 ⇒ 这里生成新键。用户点「重新制作」
    ///   （`retryable_failure`）就是新操作，而 UI 侧不做自动重放（design 09：
    ///   hash 失配后不得自动重发写操作），所以两条路径不会混。
    @discardableResult
    public func startPlan(
        sessionID: String, plan: OneStepPlanCardDto, token: IdempotentRequestToken? = nil
    ) async throws -> GenerationJobResponseDto {
        guard let revision = plan.revision, let snapshotHash = plan.snapshotHash else {
            // 缺 revision / snapshotHash 就发出去 = 后端无法校验计划版本 ⇒ 宁可报错也不猜。
            throw CatalogFailure.backendGap("NEEDS-13（计划卡缺 revision/snapshotHash）")
        }
        let body = try OneStepPlanStartRequestDto(
            sessionId: sessionID,
            planCardId: plan.planCardId,
            revision: revision,
            snapshotHash: snapshotHash,
            token: token ?? IdempotentRequestToken(operation: .planStart)
        )
        return try await client.post("/api/studio/one-step/plans/start", body: body)
    }

    /// 生成候选的收藏标记（`PATCH /api/media/references/:id/retention`）。
    @discardableResult
    public func setCandidateFavorite(referenceID: String, _ favorite: Bool) async throws
        -> MediaRetentionResponseDto {
        try await client.patch(
            "/api/media/references/\(referenceID)/retention",
            body: MediaRetentionRequestDto(favorite: favorite)
        )
    }

    /// agent 请求体（`POST /api/studio/agent`，SSE）。
    ///
    /// 字段族按 web 源码与推断实现（NEEDS-13 已登记「请求体 schema 未文档化」）：
    /// 这里只发**契约里确定的那三件**（sessionId / message / deepThinking），
    /// 不发明额外键 —— 后端多出来的字段由它自己决定。
    public static func agentRequestBody(
        sessionID: String, message: String, deepThinking: Bool
    ) throws -> Data {
        let payload = AgentRequestPayload(
            sessionId: sessionID, message: message, deepThinking: deepThinking
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private struct AgentRequestPayload: Encodable {
        let sessionId: String
        let message: String
        let deepThinking: Bool
    }

    /// 把 `CovaAPIError` 归类成 UI 可说的三句话（会话面的解码缺口是 NEEDS-23）。
    public static func classify(_ error: Error) -> CatalogFailure {
        CatalogService.classify(error, decodingNeeds: "NEEDS-23")
    }
}
