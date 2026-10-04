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

    /// 建会话（契约固定 `{workflowMode:'one-step', skipWelcome:true}`；`title` 可选——
    /// §7 #55：服务端收了就 `renameSession` 成真名，08 列表不再停在「新会话」）。
    /// 标题规范化在 `CovaCreateSessionRequestDto.normalizedTitle`（首行截 30，空 → nil）。
    public func createSession(title: String? = nil) async throws -> String {
        let response: StudioCreateSessionResponseDto = try await client.post(
            "/api/find-my-song/sessions",
            body: CovaCreateSessionRequestDto(title: title)
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
            throw CatalogFailure.backendGap("NEEDS-33（计划卡未文档化 revision/snapshotHash）")
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

    // MARK: 歌词编辑（design 09 §1「歌词编辑均在本屏内」）

    /// 就地保存歌词改动（`PATCH /api/studio/one-step/plans/:planCardId`）。
    ///
    /// **这一条不扣费**：写路径是纯补丁（`web/src/lib/one-step/patch.ts:55`），
    /// 一次模型调用都没有 ⇒ 没有 `credits` 那一段，与下面的重做**不是一类**。
    /// 幂等键在 `request` 里，由调用方的 `OneStepLyricsEditTokenLedger` 按载荷指纹分派
    /// （AGENTS 硬边界 5）：同键同载荷 = 后端重放，不产生第二次写。
    ///
    /// 三条口径值得写在签名旁边而不是注释里：
    /// · 本方法**不**在本屏之外缓存/回落任何卡面状态 —— 返回的就是后端刚给的那一份；
    /// · 2xx 但回显读不出来 ⇒ `.landedWithoutEcho`（写发生了。说"失败"会诱导用户再改一次，
    ///   而下一次是**新的一次写**、新键、真的会再改一遍数据）；
    /// · 非 2xx ⇒ 抛 `CovaAPIError` 原样，由 `OneStepLyricsEditRejection.classify` 分诊
    ///   （409 `conflict` 与 409 `idempotency_conflict` 必须分得开，两句话完全不同）。
    public func saveLyrics(_ request: OneStepLyricsPatchRequestDto) async throws
        -> OneStepLyricsEditOutcome {
        let response: OneStepLyricsPatchResponseDto
        do {
            response = try await client.patch(
                "/api/studio/one-step/plans/\(request.planCardId)", body: request
            )
        } catch {
            if Self.isUnreadableSuccessEcho(error) { return .landedWithoutEcho }
            throw error
        }
        guard let card = response.planCard else { return .landedWithoutEcho }
        return response.replayed == true ? .replayed(card) : .saved(card)
    }

    /// 回读 2xx 但响应形状解不开 ⇒ 记成「已落地、回显读不出」。
    ///
    /// 单独成函数只为了让那条判据可测：`CovaAPIClient` 只在 **2xx 之后**才解码
    /// （非 2xx 先抛 `.httpStatus`），所以 `.decoding` 落在这里时写已经成功了。
    static func isUnreadableSuccessEcho(_ error: Error) -> Bool {
        guard let api = error as? CovaAPIError else { return false }
        if case .decoding = api { return true }
        return false
    }

    /// 重做整篇歌词（`POST …/plans/:planCardId/lyrics/regenerate`）。
    ///
    /// **这一条按 token 实扣** —— 大声写一遍，因为它是本屏第二贵的动作：
    /// 服务端在 `web/src/app/api/studio/one-step/plans/[planCardId]/lyrics/regenerate/route.ts:34-60`
    /// 走 `enterLlmTurn → llmTurnPrecheck → 模型 → settleLlmTurn`，响应带
    /// `credits:{charged, balance, insufficient}`。三条由此而来的硬要求：
    /// · **调用前必须已经拿到用户的明确确认**（本方法不做确认，确认在 09 屏的
    ///   `confirmationPrompt` 上；绕开它直接调 = 替用户花钱）；
    /// · **失败绝不自动重试**：402 `topup_required` 是"预检就拦下、一次调用都没发"（没扣费），
    ///   而 2xx 后结算扣不动是另一件事（`insufficient:true`）—— 两句话必须能分开，
    ///   所以这里把 `credits` 原样带回，不替后端把"没读到"折算成"没扣"；
    /// · 幂等键同样必带（同一次确认的重发复用同键 ⇒ 后端重放，不会再扣一次）。
    public func regenerateLyrics(sessionID: String, plan: OneStepPlanCardDto, key: IdempotencyKey) async throws
        -> OneStepLyricsRegenerateOutcome {
        guard let revision = plan.revision else {
            // 没有 revision 就发 = 后端无法判断我看的是哪一份 ⇒ 宁可不发。
            throw CatalogFailure.backendGap("NEEDS-33（计划卡未文档化 revision）")
        }
        let response: OneStepLyricsRegenerateResponseDto = try await client.post(
            "/api/studio/one-step/plans/\(plan.planCardId)/lyrics/regenerate",
            body: OneStepLyricsRegenerateRequestDto(
                sessionId: sessionID, expectedRevision: revision, idempotencyKey: key
            )
        )
        return OneStepLyricsRegenerateOutcome(
            card: response.planCard,
            charged: response.credits?.charged,
            balance: response.credits?.balance,
            insufficient: response.credits?.insufficient
        )
    }

    /// 歌词字段的版本列表（`GET …/plans/:planCardId/versions?field=lyrics`，**只读**）。
    ///
    /// 本屏只拿它核一件事：「当前这一版还在不在列表里」。不做版本翻页 ——
    /// 那是 web 的段级版本导航（`VersionNavFrame.tsx`）那一整块产品面，09 没写。
    public func lyricVersions(planCardID: String) async throws -> [OneStepFieldVersionDto] {
        let response: OneStepFieldVersionsResponseDto = try await client.get(
            "/api/studio/one-step/plans/\(planCardID)/versions",
            queryItems: [URLQueryItem(name: "field", value: "lyrics")]
        )
        return response.versions ?? []
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
