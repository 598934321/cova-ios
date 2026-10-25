import CovaCore
import Foundation

/// 「开始制作」失败 → 一句话（402 / 429 的判据落点）。
///
/// 为什么要一个独立类型、而不是把 402/429 塞进 `CovaAPIError`：
/// 那两个状态码在 `plans/start` 上**自带可上屏的数字**（本次需要多少 co、多少秒后再试），
/// 而 `CovaAPIError.httpStatus(code:apiCode:)` 按登录防枚举的取舍只保留业务码 ——
/// 信封里的 `balance`/`required` 与响应头的 `Retry-After` 在那一层就死了。
/// 分诊本身**复用** `StudioCreateRejection`（同一族判据：屏上无英文码、不编「未知错误」），
/// 不另写一份 402/429 词表 —— 两份词表迟早对不上（本仓 min-2 缺陷族）。
public struct StudioStartFailure: Error, Equatable, Sendable {
    /// 由状态码 + 信封分诊出的拒绝类别（与 `studio/create/generate` 同一套）。
    public let rejection: StudioCreateRejection
    /// 服务端 `Retry-After` 秒数（只有 429/503 且服务端给纯数字时才有值）。
    public let retryAfterSeconds: Int?

    public init(rejection: StudioCreateRejection, retryAfterSeconds: Int? = nil) {
        self.rejection = rejection
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// 上屏文案（09 §10：零余额那一段必须说清「这次没有扣费」）。
    public var userMessage: String {
        switch rejection {
        case .creditsInsufficient(_, let required):
            guard let required, required > 0 else { return "余额不足（这次没有扣费）" }
            return "余额不足，本次需要 \(required) co（这次没有扣费）"
        case .rateLimited:
            // 秒数只做「更具体」，不做「更宽松」：没有秒数时仍是一句完整的人话。
            if let seconds = retryAfterSeconds, seconds > 0 {
                return "请求过于频繁，请 \(seconds) 秒后再试"
            }
            return rejection.userMessage
        default:
            return rejection.userMessage
        }
    }

    /// 状态码 + 响应体 + `Retry-After` → 分诊（纯函数，脱网可测）。
    public static func classify(
        statusCode: Int, body: Data?, retryAfterSeconds: Int? = nil
    ) -> StudioStartFailure {
        StudioStartFailure(
            rejection: StudioCreateRejection.classify(statusCode: statusCode, body: body),
            retryAfterSeconds: retryAfterSeconds
        )
    }
}

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
    /// 启动制作的唯一路径（单测与文档引用同一常量，避免两处拼写）。
    public static let startPath = "/api/studio/one-step/plans/start"

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
        // 走 `performCoded` 而不是 `post`：start 的 402/429 承载着**上屏要用的数字与秒数**
        // （`credits_insufficient` 的 `balance`/`required`、`Retry-After`），而
        // `CovaAPIError.httpStatus` 只留业务码、把信封与响应头全丢掉 ⇒ 屏上只剩「HTTP 402」。
        let payload = try JSONEncoder().encode(body)
        let outcome = try await client.performCoded(
            method: .post, path: Self.startPath, jsonBody: payload
        )
        guard outcome.isSuccess else {
            throw StudioStartFailure.classify(
                statusCode: outcome.statusCode,
                body: outcome.body,
                retryAfterSeconds: outcome.retryAfterSeconds
            )
        }
        // 2xx 但读不出任务：写可能已经落地（与 `GenerationJobResponseDto.isUnresolvedSubmission`
        // 同一条钱路纪律）⇒ 交回调用方按「未拿到任务号」核对，不在这里编一句话。
        guard let response = try? JSONDecoder().decode(GenerationJobResponseDto.self, from: outcome.body) else {
            throw CovaAPIError.decoding(field: "studio-start")
        }
        return response
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
            insufficient: response.credits?.insufficient,
            turnId: response.credits?.turnId
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

    /// 把任意错误归类成 UI 可说的三句话（会话面的解码缺口是 NEEDS-23）。
    ///
    /// `StudioStartFailure` 必须**在这里**拦下：它的 402/429 文案是本端点自己算出来的
    /// （带 co 数与秒数），交给 `CatalogService.classify` 只会落回 `.server("HTTP 402")`。
    /// 401/403 仍交给目录层那一档：登录态过期是**跨屏**语义，不该由 start 这一屏另说一句。
    public static func classify(_ error: Error) -> CatalogFailure {
        if let start = error as? StudioStartFailure {
            if case .unauthenticated = start.rejection { return .unauthenticated }
            return .server(start.userMessage)
        }
        return CatalogService.classify(error, decodingNeeds: "NEEDS-23")
    }
}
