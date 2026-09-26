import CovaCore
import Foundation

/// studio/create 提交失败的四类（DEVELOPMENT.md A3/A4）。
///
/// 分四类的理由是**每一类的下一步动作不同**，混成一类就会给出错误的建议：
/// · `.invalidInput` —— 请求压根没发出去，改输入就行；
/// · `.rejected` —— 服务端明确说不，**不要自动重试**（尤其 402：重试只会再撞一次余额）；
/// · `.unresolvedSubmission` —— 2xx 但读不到任务号：**扣费可能已经发生**，
///   说「没提交成功」会诱导用户再点一次 ⇒ 第二次真的扣费（与
///   `GenerationJobResponseDto.isUnresolvedSubmission` 同一条钱路纪律）；
/// · `.unreachable` —— 没有 HTTP 结果，落地与否未知 ⇒ 重试**必须复用同一把幂等键**。
public enum StudioCreateSubmissionFailure: Error, Equatable, Sendable {
    case invalidInput(StudioCreateRequestError)
    case rejected(StudioCreateRejection)
    case unresolvedSubmission
    case unreachable(CatalogFailure)

    /// 上屏文案（`design/screens/19-studio-create.md` §4/§8）。
    ///
    /// `.invalidInput` 的两句与服务端 400 的原文**逐字相同**（`generate.ts:63,105,107`）——
    /// 客户端明知不合法就不该花一次往返去换一个 400，但也不许自己另编一套说法。
    public var userMessage: String {
        switch self {
        case .invalidInput(let error):
            switch error {
            case .emptyPrompt: return "请填写音乐描述"
            case .promptTooLong(let limit, _): return "音乐描述过长（最多 \(limit) 字）"
            case .operationMismatch: return "这次提交没被接受（客户端幂等键配错）"
            }
        case .rejected(let rejection):
            return rejection.userMessage
        case .unresolvedSubmission:
            return "提交发出去了，但没读到任务号——先别重复提交，稍后到作品里核对"
        case .unreachable(let failure):
            switch failure {
            case .network:
                return "网络没通，这次提交没确认；重试用同一把幂等键，不会重复扣费"
            case .unauthenticated:
                return "登录状态已过期"
            case .server(let message), .backendGap(let message):
                return message
            }
        }
    }

    /// 是不是「同一把键重试就有意义」的那一类（只有 `.unreachable`）。
    public var isRetryableWithSameKey: Bool {
        if case .unreachable(.network) = self { return true }
        return false
    }
}

/// `POST /api/studio/create/generate` + 作品/任务读回（DEVELOPMENT.md §4.4）。
///
/// 三条硬边界写在类型上而不是留给调用方自觉：
/// · **扣费写操作必带幂等键**（硬边界 5）：`generate` 只接受 `IdempotentRequestToken`，
///   且 operation 必须是 `.studioCreateGenerate`；
/// · **错误文案不经过 `CovaAPIError`**：那条归一化会把服务端的 `error` 文案与
///   `balance`/`required` 全丢掉（`.httpStatus(code:apiCode:)` 只留 `code`，而 402 那一档
///   服务端根本不给 `code`）⇒ 这里走 `performCoded` 拿原始信封，交
///   `StudioCreateRejection.classify` 分诊；
/// · **2xx 读不出任务号不算失败**：`.unresolvedSubmission` 是一个独立类别，
///   UI 不许把它渲染成「没提交成功」。
public struct StudioCreateService: Sendable {
    public static let generatePath = "/api/studio/create/generate"
    public static let worksPath = "/api/studio/create/works"
    /// 任务轮询腿（`?id=<jobId>` → `{job}`）。一步创作的任务也在这个端点上、同一形状
    /// （同表同投影），所以 P1 的会话详情轮询可以直接复用本方法。
    public static let generationJobPath = "/api/find-my-song/generation-jobs"

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// 一次逻辑提交。**调用方持有 token**：同一次提交的重试必须传同一把键，
    /// 「重新生成」才新建一把（`Idempotency.swift` 的 D8 口径）。
    public func generate(
        prompt: String, token: IdempotentRequestToken
    ) async throws -> StudioCreateGenerateResponseDto {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                StudioCreateGenerateRequestDto(prompt: prompt, token: token)
            )
        } catch let error as StudioCreateRequestError {
            throw StudioCreateSubmissionFailure.invalidInput(error)
        }

        let outcome: CovaHTTPOutcome
        do {
            outcome = try await client.performCoded(
                method: .post, path: Self.generatePath, jsonBody: payload
            )
        } catch {
            throw StudioCreateSubmissionFailure.unreachable(
                StudioCreateService.classifyTransport(error)
            )
        }

        guard outcome.isSuccess else {
            throw StudioCreateSubmissionFailure.rejected(
                StudioCreateRejection.classify(statusCode: outcome.statusCode, body: outcome.body)
            )
        }
        guard let response = try? JSONDecoder().decode(
            StudioCreateGenerateResponseDto.self, from: outcome.body
        ), !response.isUnresolvedSubmission else {
            // 2xx 却拿不到任务号：写可能已经落地、费可能已经扣 ⇒ 独立类别，不并入失败。
            throw StudioCreateSubmissionFailure.unresolvedSubmission
        }
        return response
    }

    /// 作品行读回：`id` 含 `:` = 单行详情，纯 jobId = 该任务全部行（works/route.ts:18-25）。
    public func works(id: String) async throws -> CreateWorksResponseDto {
        try await client.get(Self.worksPath, queryItems: [URLQueryItem(name: "id", value: id)])
    }

    /// 任务读回（轮询用）。响应 `{job}`；404 = 任务不存在。
    public func generationJob(id: String) async throws -> GenerationJobResponseDto {
        try await client.get(
            Self.generationJobPath, queryItems: [URLQueryItem(name: "id", value: id)]
        )
    }

    /// 传输层错误 → 目录层那三句话（复用 `CatalogService.classify` 的口径，
    /// 但**不带**任何 NEEDS 编号：读不出响应是客户端 DTO 待核，不许记到后端账上）。
    static func classifyTransport(_ error: Error) -> CatalogFailure {
        CatalogService.classify(error)
    }
}
