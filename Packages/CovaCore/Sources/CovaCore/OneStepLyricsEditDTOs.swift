import Foundation

// MARK: - 一步模式「就地改歌词」的线格式（design 09 §1 歌词编辑 / §8 写操作）
//
// 形状**逐字抄已部署实现**，不猜键名。事实源是 `多端/web`（本后端唯一实现）：
// · 端点 `PATCH /api/studio/one-step/plans/:planCardId` —— `web/src/app/api/studio/one-step/plans/[planCardId]/route.ts:23`
// · 载荷校验 `assertValidOneStepPlanPatch` —— `web/src/lib/one-step/contracts.ts:781`
//   关键的一条：`Object.keys(changes)` 排序后必须**等于** `targetFields`（:806），
//   而歌词类补丁又必须同时换掉标题池（`web/src/lib/one-step/patch.ts:139` 的 `stale_title_pool`），
//   所以 `targetFields = ["lyrics","titlePool"]` 与 `changes` 的两个键是**绑死的一对**，
//   少一个键就是 400 —— 这一格不能"先只发歌词试试"。
// · `source: 'user'` / `operation: 'targeted_patch'` 取自闭合集
//   （`contracts.ts:281-284`），后者正是 web 自己改歌词时发的那个值
//   （`web/src/app/studio/components/chat/InteractivePlanCard.tsx:633`）。

/// `OneStepLyricsSectionDto` 的回带面。
///
/// 为什么是方法而不是新增一个 `init`：这个 DTO 没有显式 init，Swift 给它合成的是
/// **internal 的成员构造器**（`sectionId:type:label:text:order:`），在 CovaCore 里同签名的
/// 公开 init 会撞成 invalid redeclaration。而本屏真正要的只有一件事：
/// **只换正文，其余四个键原样带回**（后端拿这些段落记编辑历史，`patch.ts:89-103`），
/// 一个字段都不现编。
extension OneStepLyricsSectionDto {
    public func replacingText(_ text: String) -> OneStepLyricsSectionDto {
        OneStepLyricsSectionDto(
            sectionId: sectionId, type: type, label: label, text: text, order: order
        )
    }
}

/// 补丁里的 `changes.lyrics`。
///
/// **不带 `sourceHash`**：后端重算（`contracts.ts:499`），客户端算不出来也不该猜。
/// `revision` 发的是"当前查看的字段版本"（web 同一值，`InteractivePlanCard.tsx:485`）；
/// 服务端另会拿 `targetVersions.lyrics` 覆盖它（`patch.ts:37`），所以这一格只是回显基线。
public struct OneStepLyricsPatchDocumentDto: Encodable, Equatable, Sendable {
    /// 段落原文的来源（`user` / `imported` / `generated`）。发的是**读到的那个值**，原样带回。
    public let source: String?
    /// 用户导入的原始文本；没有就不发键（服务端会回落到当前文档的 sourceText，`patch.ts:44`）。
    public let sourceText: String?
    public let sections: [OneStepLyricsSectionDto]
    public let displayText: String
    public let generationText: String
    public let revision: Int?
    /// 固定 `manual_edit`：这次写是"人在卡上改了几个字"，不是模型重做。
    /// 值域是后端的闭合枚举（`contracts.ts:20-26`），`import` 被排除（`createLyricsDocument` 不接受它）。
    public let operation: String

    public init(
        source: String?,
        sourceText: String?,
        sections: [OneStepLyricsSectionDto],
        displayText: String,
        generationText: String,
        revision: Int?,
        operation: String = OneStepLyricsPatchDocumentDto.manualEditOperation
    ) {
        self.source = source
        self.sourceText = sourceText
        self.sections = sections
        self.displayText = displayText
        self.generationText = generationText
        self.revision = revision
        self.operation = operation
    }

    public static let manualEditOperation = "manual_edit"

    enum CodingKeys: String, CodingKey {
        case source
        case sourceText
        case sections
        case displayText
        case generationText
        case revision
        case operation
    }
}

/// 补丁里的 `changes.titlePool` —— **改歌词必须同时把它换掉**（`patch.ts:139`）。
///
/// 发的是"这张卡现在的那一池"（候选 + 页码原样回带），不新增候选、不重排：
/// 服务端会按新的 lyrics/style 版本重绑（`patch.ts:146` → `createOneStepTitlePool`）。
public struct OneStepLyricsPatchTitlePoolDto: Encodable, Equatable, Sendable {
    public let candidates: [String]
    public let pageSize: Int
    public let page: Int

    public init(candidates: [String], pageSize: Int = OneStepLyricsPatchTitlePoolDto.projectedPageSize, page: Int) {
        self.candidates = candidates
        self.pageSize = pageSize
        self.page = page
    }

    /// 投影里的 `title.pageSize` 是常量 10（`contracts.ts:831`），不是可变量。
    public static let projectedPageSize = 10

    enum CodingKeys: String, CodingKey {
        case candidates
        case pageSize
        case page
    }
}

/// `PATCH /api/studio/one-step/plans/:planCardId` 的请求体。
///
/// D8 / AGENTS 硬边界 5：`idempotencyKey` 必填。这里的幂等语义不是"我猜的"，
/// 是服务端的账（`web/src/lib/one-step/store.ts:373-381`）：
/// **同键 + 同载荷** ⇒ 走重放（`replayed: true`，不产生第二次写）；
/// **同键 + 不同载荷** ⇒ 409 `idempotency_conflict`。所以"改完再存"必须是新键，
/// 而"存失败后原样再存一次"必须是旧键 —— 由 `OneStepLyricsEditTokenLedger` 按载荷指纹分派。
public struct OneStepLyricsPatchRequestDto: Encodable, Equatable, Sendable {
    public let sessionId: String
    public let planCardId: String
    /// 卡当前的聚合 revision（乐观并发基线，`store.ts:388` 比对的就是它）。
    public let expectedRevision: Int
    public let idempotencyKey: IdempotencyKey
    public let targetFields: [String]
    public let source: String
    public let operation: String
    public let changes: Changes
    /// 「就地改的是我正在看的这一版」；读不到歌词版本时**不发这个键**（服务端按聚合版本落）。
    public let targetVersions: TargetVersions?

    public struct Changes: Encodable, Equatable, Sendable {
        public let lyrics: OneStepLyricsPatchDocumentDto
        public let titlePool: OneStepLyricsPatchTitlePoolDto

        public init(lyrics: OneStepLyricsPatchDocumentDto, titlePool: OneStepLyricsPatchTitlePoolDto) {
            self.lyrics = lyrics
            self.titlePool = titlePool
        }

        enum CodingKeys: String, CodingKey {
            case lyrics
            case titlePool
        }
    }

    public struct TargetVersions: Encodable, Equatable, Sendable {
        public let lyrics: Int

        public init(lyrics: Int) { self.lyrics = lyrics }

        enum CodingKeys: String, CodingKey {
            case lyrics
        }
    }

    /// 后端字段名 `lyrics` / `titlePool` 必须是 `targetFields` 的那两个值（`contracts.ts:790,806`）。
    public static let lyricsTargetField = "lyrics"
    public static let titlePoolTargetField = "titlePool"

    public init(
        sessionId: String,
        planCardId: String,
        expectedRevision: Int,
        idempotencyKey: IdempotencyKey,
        lyrics: OneStepLyricsPatchDocumentDto,
        titlePool: OneStepLyricsPatchTitlePoolDto,
        targetVersions: TargetVersions?
    ) {
        self.sessionId = sessionId
        self.planCardId = planCardId
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
        // 顺序按 web 的写法（lyrics 在前）；服务端比较的是排序后的集合，顺序不参与判定。
        self.targetFields = [Self.lyricsTargetField, Self.titlePoolTargetField]
        self.source = "user"
        self.operation = "targeted_patch"
        self.changes = Changes(lyrics: lyrics, titlePool: titlePool)
        self.targetVersions = targetVersions
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case planCardId
        case expectedRevision
        case idempotencyKey
        case targetFields
        case source
        case operation
        case changes
        case targetVersions
    }
}

/// 补丁的响应：`{planCard, replayed}`（`[planCardId]/route.ts:43`）。
///
/// 两个键都建模成可选：2xx 已经证明**写落地了**，回显读不出来是客户端的读法问题，
/// 不能反过来把成功的一次写说成失败（那会诱导用户再点一次）。怎么承接见
/// `OneStepLyricsEditOutcome`。
public struct OneStepLyricsPatchResponseDto: Decodable, Equatable, Sendable {
    public let planCard: OneStepPlanCardDto?
    public let replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case planCard
        case replayed
    }
}

// MARK: - 歌词重做（**这条按 token 实扣**，与上面的免费编辑不是一类）
//
// 端点存在：`web/src/app/api/studio/one-step/plans/[planCardId]/lyrics/regenerate/route.ts:25`。
// 扣费事实在同文件 :34-60：`enterLlmTurn` → `llmTurnPrecheck` → 模型调用 → `settleLlmTurn`，
// 响应额外带 `credits:{turnId, charged, balance, insufficient}`。
// 三条从实现里读出来的口径，直接决定 UI 怎么说：
// · 预检不过回 **402 `topup_required`**（:41）⇒ 那一刻**还没扣**，本轮一次模型调用都没发；
// · `charged` 是结算后的真实扣数（`llm-metering.ts:141-158`，扣不动时 `charged:0` + `insufficient:true`）；
// · 载荷只有共享信封 `{sessionId, expectedRevision, idempotencyKey}`（`shared.ts:81`）——
//   多出来的键后端不读，所以一个都不发明。

/// `POST …/plans/:planCardId/lyrics/regenerate` 请求体。
public struct OneStepLyricsRegenerateRequestDto: Encodable, Equatable, Sendable {
    public let sessionId: String
    public let expectedRevision: Int
    public let idempotencyKey: IdempotencyKey

    public init(sessionId: String, expectedRevision: Int, idempotencyKey: IdempotencyKey) {
        self.sessionId = sessionId
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case expectedRevision
        case idempotencyKey
    }
}

/// 重做的响应（`{planCard, replayed, credits}`）。
public struct OneStepLyricsRegenerateResponseDto: Decodable, Equatable, Sendable {
    public let planCard: OneStepPlanCardDto?
    public let replayed: Bool?
    public let credits: Credits?

    public struct Credits: Decodable, Equatable, Sendable {
        /// 本次真实扣掉的 co。**可选而不是默认 0**：读不到就是读不到，
        /// 把"没读到"印成"没扣"是本仓最反对的那类谎（D12 只展示余额，账目更要如实）。
        public let charged: Int?
        public let balance: Int?
        public let insufficient: Bool?

        enum CodingKeys: String, CodingKey {
            case charged
            case balance
            case insufficient
        }
    }

    enum CodingKeys: String, CodingKey {
        case planCard
        case replayed
        case credits
    }
}

// MARK: - 歌词字段版本（design 09 §9「版本」话术的唯一来源）
//
// 端点存在：`GET …/plans/:planCardId/versions?field=lyrics`
// （`web/src/app/api/studio/one-step/plans/[planCardId]/versions/route.ts:10`，
//  返回 `{versions, sectionHistory}`，实现见 `store.ts:520-560`：按 version **升序**、
//  并且会把缺号用上一版内容补齐 ⇒ 「版本列表连续」是后端的承诺，不是客户端的假设）。
// 本屏**只用它来核"当前这一版是不是还在列表里"**，不做版本翻页（那是另一屏的事）。

public struct OneStepFieldVersionsResponseDto: Decodable, Equatable, Sendable {
    public let versions: [OneStepFieldVersionDto]?

    enum CodingKeys: String, CodingKey {
        case versions
    }
}

/// 一条字段版本。`content` 是 `unknown`（style 与 lyrics 两种形状共用一个端点）⇒
/// **不建模就不解**：本屏要的是编号与时间，取不到内容不是错误，不猜内容结构。
public struct OneStepFieldVersionDto: Decodable, Equatable, Sendable {
    public let field: String?
    public let version: Int?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case field
        case version
        case createdAt
    }
}
