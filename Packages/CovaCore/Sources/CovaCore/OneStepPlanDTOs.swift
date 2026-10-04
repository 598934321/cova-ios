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

// MARK: - 计划卡参数行的展示文案（design 09 §3-G）

/// 09 §3-G「参数行」的**唯一裁决面**：后端键 → 中文标签、0–1 单位值 → 百分数。
///
/// 为什么在这层而不留在 `body` 里：上一版在 `AISessionDetailView` 直接
/// `chips.append("weirdness \(weirdness)")`，把英文键名与 0–1 原值一起印上了屏 ——
/// 那是「后端原值上屏」这一族在本仓的第三处（前两处同样是把判据挪进可测层才闭掉的）。
/// 留在视图里就永远没有用例能钉它。
///
/// 三条口径逐字对齐 spec：
/// · **只印 spec 点名的五项**（`operation / vocalGender / targetDurationSec / weirdness /
///   styleWeight`，09 §3-G）+ 由 `type` 决定的 演唱/纯音乐（§8「纯音乐由 `type` 决定并显
///   「纯音乐」参数 chip」、`components.md` §4）。DTO 里另外建模的 `bpm / styleTags /
///   availableCoverUploadIds` 不在这一行 ⇒ 不印；契约里**没建模**的键根本解不出来，
///   也就不可能被印成英文（`OneStepPlanParametersDto` 用显式 CodingKeys，未知字段忽略）。
/// · **不认识的取值不编中文名**：`operation`/`vocalGender` 命中不了下表 ⇒ 整枚 chip 不渲染，
///   而不是退回英文键名（那正是本轮要修的），也不是现编一个"看着像"的中文词。
/// · **不拿区间外的数硬造百分数**：`weirdness/styleWeight` 只按 0–1 单位值呈现（09 §3-G），
///   越界/非有限值没有规格形态 ⇒ 不渲染。
public enum OneStepPlanParameterCopy {
    /// 参数行的 chips，按 09 §3-G 点名的顺序。一条都取不到 ⇒ **空数组**
    /// （§3-G/§8：整段不渲染 —— 不出现空 chip 行，也不出现 `--` 这类占位）。
    public static func chips(
        parameters: OneStepPlanParametersDto?, type: OneStepPlanType?
    ) -> [String] {
        var chips: [String] = []
        if let type { chips.append(typeLabel(type)) }
        guard let parameters else { return chips }
        // `operation` 与 `type` 的值本身就是中文短词（新建 / 改编 / 续写 / 重制），
        // 而 spec 没给这一项的**键**名 ⇒ 只印值，不给自己发明的键名（「操作方式」这类话不在文案清单里）。
        if let operation = operationLabel(parameters.operation) { chips.append(operation) }
        if let vocal = vocalGenderLabel(parameters.vocalGender) { chips.append("演唱者 \(vocal)") }
        // 09 §3-G：两个时长键同时存在时**以 `targetDurationSec` 为准**（契约字段优先级），
        // 所以这一格永远只出一枚 chip。标签取 web 同一控件的 Field 名「时长」
        // （`PlanCardControls.tsx:562`，它管的正是 `parameters.durationSec` 那一格），
        // 而不用同文件 :575 那枚滑块的「目标时长」—— 值可能来自 `durationSec`，
        // 那一格并没有"目标"可言，标签不许超过数据本身。
        if let seconds = parameters.targetDurationSec ?? parameters.durationSec {
            chips.append("时长 \(seconds) 秒")
        }
        if let weirdness = percent(parameters.weirdness) { chips.append("自由度 \(weirdness)") }
        if let weight = percent(parameters.styleWeight) { chips.append("风格权重 \(weight)") }
        return chips
    }

    /// `type` → 中文（`components.md` §4「type（演唱/纯音乐）」与 09 §8 的第二行给的就是这两个词）。
    public static func typeLabel(_ type: OneStepPlanType) -> String {
        switch type {
        case .vocal: return "演唱"
        case .instrumental: return "纯音乐"
        }
    }

    /// 0–1 单位值 → 百分数（09 §3-G「`weirdness/styleWeight` 为 0–1 单位值 → 显示为百分数」）。
    /// **四舍五入而不是截断**：`0.7 * 100` 在二进制里是 69.99999999999999，截断会印成 69%。
    /// nil、越出 0–1、NaN/inf ⇒ nil（宁可不印，不把区间外的数伪装成百分比）。
    public static func percent(_ value: Double?) -> String? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return "\(Int((value * 100).rounded()))%"
    }

    /// `vocalGender` 的中文值。表源：web 同一步模式计划卡的同一枚控件
    /// （`web/src/app/studio/components/chat/one-step/PlanCardControls.tsx:507,558`
    /// —— 键名「演唱者」也在同一行），本仓不另立一词。
    /// 契约里另有的 `none` 在这里**刻意不映射**：器乐的表达走 `type` → 「纯音乐」
    /// （09 §8），而不是给一个我不认识的取值现编中文。
    public static func vocalGenderLabel(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "m": return "男声"
        case "f": return "女声"
        case "random": return "随机"
        default: return nil
        }
    }

    /// `operation` 的中文值。表源：web `CreateTrackDetailPanel.tsx:54-59` 的 `OPERATION_LABEL`
    /// （产品自己已在用的那张表，四项一字不改）。表外取值（`replace_section` 等）⇒ nil：
    /// 后端还有更多枚举而 web 只给了这四个，编下去就是把猜的中文当规格用。
    public static func operationLabel(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "create": return "新建"
        case "cover": return "改编"
        case "extend": return "续写"
        case "remaster": return "重制"
        default: return nil
        }
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

/// `POST /api/find-my-song/sessions` 请求体（契约：`{workflowMode:'one-step', skipWelcome:true}`，
/// `title` 为可选项 —— `web/.../sessions/route.ts:63`：给了就 `renameSession` 落成真名）。
///
/// v1.0 锁定一步模式（PRD 4.4），故默认值即契约形态。
public struct CovaCreateSessionRequestDto: Codable, Equatable, Sendable {
    /// 契约固定的工作流模式。
    public static let oneStepWorkflowMode = "one-step"

    public let workflowMode: String
    public let skipWelcome: Bool
    /// 会话真名（§7 #55，2026-10-02 接上）：首页生成档把首条 prompt 落成它，
    /// 08 列表就不再停在「新会话」。nil → 键不出现（合成 Codable 自动略 nil）。
    public let title: String?

    public init(
        workflowMode: String = CovaCreateSessionRequestDto.oneStepWorkflowMode,
        skipWelcome: Bool = true,
        title: String? = nil
    ) {
        self.workflowMode = workflowMode
        self.skipWelcome = skipWelcome
        self.title = title
    }

    /// prompt → 会话名的规范化（判据层，用例直钉）：
    /// 取**首行**去首尾空白 → 空串即 nil（空标题不该出站，服务端拿到空串也拒收真名）→
    /// 上限 30 个字符截断（与 08 行 `displayTitle` 的兜底链是同一条文案面，
    /// 长 prompt 不该整段糊上标题栏）。不发明词：原样截取，不改写、不总结。
    public static func normalizedTitle(_ raw: String) -> String? {
        let firstLine = raw
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return nil }
        return String(firstLine.prefix(30))
    }

    enum CodingKeys: String, CodingKey {
        case workflowMode
        case skipWelcome
        case title
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
