import Foundation

/// 计划卡 12 态（逐字对齐后端契约 `OneStepPlanStatus`）。
///
/// 封闭枚举：契约外取值会解码失败（`CovaAPIError.decoding`），不静默降级。
public enum OneStepPlanStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case analyzing
    case ready
    case patching
    case starting
    case generating
    case mediaStaging = "media_staging"
    case demosReady = "demos_ready"
    case deliveryPreparing = "delivery_preparing"
    case rehydrating
    case manualRecovery = "manual_recovery"
    case retryableFailure = "retryable_failure"
    case archived
}

/// 计划类型（api-contracts 4：`type('vocal'|'instrumental')`）。
public enum OneStepPlanType: String, Codable, Equatable, Sendable {
    case vocal
    case instrumental
}

/// 计划卡来源消息（归属校验用：`sourceMessage.messageId`）。
public struct OneStepSourceMessageDto: Codable, Equatable, Sendable {
    public let messageId: String?
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case messageId
        case text
    }
}

/// 曲名选择（api-contracts 4：`title{selected, candidates}`）。
public struct OneStepTitleDto: Codable, Equatable, Sendable {
    public let selected: String?
    public let candidates: [String]?
    public let page: Int?
    public let pageSize: Int?
    public let total: Int?

    enum CodingKeys: String, CodingKey {
        case selected
        case candidates
        case page
        case pageSize
        case total
    }
}

/// 曲风分析（api-contracts 4：`style{analysisZh, promptEn}`）。
public struct OneStepStyleDto: Codable, Equatable, Sendable {
    public let analysisZh: String?
    public let promptEn: String?
    public let revision: Int?

    enum CodingKeys: String, CodingKey {
        case analysisZh
        case promptEn
        case revision
    }
}

/// 歌词分段（D15：静态展示，无时间轴）。
public struct OneStepLyricsSectionDto: Codable, Equatable, Sendable {
    public let sectionId: String?
    public let type: String?
    public let label: String?
    public let text: String?
    public let order: Int?

    enum CodingKeys: String, CodingKey {
        case sectionId
        case type
        case label
        case text
        case order
    }
}

/// 歌词文档（api-contracts 4：`lyrics（LyricsDocument 分 section）`）。
public struct OneStepLyricsDocumentDto: Codable, Equatable, Sendable {
    public let source: String?
    public let sourceText: String?
    public let sourceHash: String?
    public let sections: [OneStepLyricsSectionDto]?
    public let displayText: String?
    public let generationText: String?
    public let revision: Int?
    public let operation: String?

    enum CodingKeys: String, CodingKey {
        case source
        case sourceText
        case sourceHash
        case sections
        case displayText
        case generationText
        case revision
        case operation
    }
}

/// A/B 双版本方向（D1）。
public struct OneStepPlanVariantDto: Codable, Equatable, Sendable {
    public let title: String?
    public let direction: String?

    enum CodingKeys: String, CodingKey {
        case title
        case direction
    }
}

/// 计划参数（api-contracts 4 点名项 + 真实简单标量）。
///
/// `musicianId` 真实为 `String | String[]` 联合类型、`coverEligibility` 结构复杂，
/// 本轮不建模（由「未知字段忽略」承接），避免臆造联合类型。
public struct OneStepPlanParametersDto: Codable, Equatable, Sendable {
    public let operation: String?
    public let vocalGender: String?
    public let weirdness: Double?
    public let styleWeight: Double?
    public let targetDurationSec: Int?
    public let durationSec: Int?
    public let bpm: Int?
    public let availableCoverUploadIds: [String]?
    public let styleTags: [String]?

    enum CodingKeys: String, CodingKey {
        case operation
        case vocalGender
        case weirdness
        case styleWeight
        case targetDurationSec
        case durationSec
        case bpm
        case availableCoverUploadIds
        case styleTags
    }
}

/// 一步模式计划卡（api-contracts 4 / 后端 `cova.one-step-plan.v1` 投影）。
public struct OneStepPlanCardDto: Codable, Equatable, Sendable {
    public let planCardId: String
    public let status: OneStepPlanStatus

    public let contractVersion: String?
    public let sessionId: String?
    public let cardIndex: Int?
    public let revision: Int?
    public let sourceMessage: OneStepSourceMessageDto?
    public let type: OneStepPlanType?
    public let summary: String?
    public let title: OneStepTitleDto?
    public let style: OneStepStyleDto?
    public let variants: [OneStepPlanVariantDto]?
    public let lyrics: OneStepLyricsDocumentDto?
    public let parameters: OneStepPlanParametersDto?
    public let snapshotHash: String?
    public let updatedAt: String?
    public let credits: Int?

    enum CodingKeys: String, CodingKey {
        case planCardId
        case status
        case contractVersion
        case sessionId
        case cardIndex
        case revision
        case sourceMessage
        case type
        case summary
        case title
        case style
        case variants
        case lyrics
        case parameters
        case snapshotHash
        case updatedAt
        case credits
    }
}

/// `GET /api/studio/one-step/plans?sessionId=` 响应封套（真实响应：`{planCards}`）。
public struct OneStepPlanCardsResponseDto: Codable, Equatable, Sendable {
    public let planCards: [OneStepPlanCardDto]

    enum CodingKeys: String, CodingKey {
        case planCards
    }
}

// MARK: - 一步模式写请求（api-contracts 4；D8 幂等键）

/// 「一次逻辑操作 = 一个幂等键」（D8）在**计划启动**这条扣费路径上的落地。
///
/// 为什么需要它：`StudioService.startPlan` 不传 token 时会现生成一个新键 ——
/// 对"用户主动重新制作"是对的（那确实是一次新操作），但对"同一次点击的失败重试"是**错的**：
/// 上一次可能已经 2xx 并扣了费（本仓 2026-09-24 实测到的正是这条：响应形态解不出 ⇒
/// UI 说"没提交成功" ⇒ 用户再点 ⇒ 换键 ⇒ 第二次扣费）。
/// 所以按 `(sessionId, planCardId, revision)` 记账：同一三元组**复用同一个键**，
/// 三元组变了才发新键（改要求会抬 revision ⇒ 新操作，语义正确）。
public struct PlanStartTokenLedger: Sendable {
    private var tokens: [String: IdempotentRequestToken] = [:]

    public init() {}

    private static func key(_ sessionID: String, _ planCardID: String, _ revision: Int) -> String {
        "\(sessionID)|\(planCardID)|\(revision)"
    }

    /// 取该三元组的键；没有就生成一个并记住。
    public mutating func token(
        sessionID: String, planCardID: String, revision: Int
    ) -> IdempotentRequestToken {
        let k = Self.key(sessionID, planCardID, revision)
        if let existing = tokens[k] { return existing }
        let fresh = IdempotentRequestToken(operation: .planStart)
        tokens[k] = fresh
        return fresh
    }

    /// 该三元组已确认终结、用户要**重新发起一次制作**时才作废（换一次新操作的新键）。
    public mutating func invalidate(sessionID: String, planCardID: String, revision: Int) {
        tokens[Self.key(sessionID, planCardID, revision)] = nil
    }
}
/// `POST /api/studio/one-step/plans/start` 请求体
/// （契约：`{sessionId, planCardId, revision, snapshotHash, idempotencyKey}`）。
///
/// D8：计划启动属扣费写操作，幂等键字段名与契约一致（`idempotencyKey`）。
///
/// TD-24：只接受 `IdempotentRequestToken`（operation 必须为 `.planStart`），
/// 直接构造错配键会在 init 抛 `operationMismatch`；仅 `Encodable`。
public struct OneStepPlanStartRequestDto: Encodable, Equatable, Sendable {
    public let sessionId: String
    public let planCardId: String
    public let revision: Int
    public let snapshotHash: String
    public let idempotencyKey: IdempotencyKey

    public init(
        sessionId: String,
        planCardId: String,
        revision: Int,
        snapshotHash: String,
        token: IdempotentRequestToken
    ) throws {
        guard token.operation == .planStart else {
            throw IdempotencyKeyError.operationMismatch
        }
        self.sessionId = sessionId
        self.planCardId = planCardId
        self.revision = revision
        self.snapshotHash = snapshotHash
        self.idempotencyKey = token.key
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case planCardId
        case revision
        case snapshotHash
        case idempotencyKey
    }
}

/// `POST /api/find-my-song/sessions` 请求体（契约：`{workflowMode:'one-step', skipWelcome:true}`）。
///
/// v1.0 锁定一步模式（PRD 4.4），故默认值即契约形态。
public struct CovaCreateSessionRequestDto: Codable, Equatable, Sendable {
    /// 契约固定的工作流模式。
    public static let oneStepWorkflowMode = "one-step"

    public let workflowMode: String
    public let skipWelcome: Bool

    public init(
        workflowMode: String = CovaCreateSessionRequestDto.oneStepWorkflowMode,
        skipWelcome: Bool = true
    ) {
        self.workflowMode = workflowMode
        self.skipWelcome = skipWelcome
    }

    enum CodingKeys: String, CodingKey {
        case workflowMode
        case skipWelcome
    }
}

/// `PATCH /api/media/references/:id/retention` 请求体（契约：`{favorite}`）——生成候选收藏。
public struct MediaRetentionRequestDto: Codable, Equatable, Sendable {
    public let favorite: Bool

    public init(favorite: Bool) {
        self.favorite = favorite
    }

    enum CodingKeys: String, CodingKey {
        case favorite
    }
}

/// 同一端点的响应。**契约只写了请求体，没写响应字段** ⇒ 这里全部可选：
/// 取不到就当「请求已发出、回显状态未知」，由调用方回读列表，而不是相信一个猜出来的值。
/// 缺口登记在 `docs/NEEDS.md`（NEEDS-23）。
public struct MediaRetentionResponseDto: Decodable, Equatable, Sendable {
    public let favorite: Bool?
    public let message: String?
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case favorite
        case message
        case id
    }
}
