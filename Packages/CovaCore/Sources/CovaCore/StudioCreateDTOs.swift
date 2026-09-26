import Foundation

/// `POST /api/studio/create/generate` 的 `mode`（服务端闭合三值，`generate.ts:98-124`）。
///
/// P0 只施工 `.simple`（DEVELOPMENT.md §5 P0-2 / `design/screens/19-studio-create.md` §1）。
/// 另两值建模但**当前没有任何构造点**：advanced 要歌词+风格双输入，melody 语义是哼唱 cover
/// 且 `operation` 强制 `cover`（显式传别的值服务端 400）—— 都是 P1 的表单，
/// 提前给它们造入口就是「画着但发不出去」的谎。
public enum StudioCreateMode: String, Codable, Equatable, Sendable, CaseIterable {
    case simple
    case advanced
    case melody
}

/// `operation`（默认 create；非 create 必须带 `sourceClipId` 或 `uploadAudioId`）。
public enum StudioCreateOperation: String, Codable, Equatable, Sendable, CaseIterable {
    case create
    case cover
    case extend
    case remaster
}

/// 提交前的本地校验失败（**不发请求**就拦下，省一次 400 往返）。
public enum StudioCreateRequestError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyPrompt
    case promptTooLong(limit: Int, actual: Int)
    /// token 的 operation 不是 `.studioCreateGenerate`（串用别的写操作的键）。
    case operationMismatch
    /// 翻唱/续写/重制没带源（服务端 400 的原文是「翻唱 / 续写 / 重制需要先选择源音乐或上传音频」）。
    case missingSourceClip
    case sourceClipIDTooLong(limit: Int, actual: Int)
    /// 续写起点不在 0…3600 秒（服务端会静默取整到 0.1，越界则不消费）。
    case continueAtOutOfRange(limit: Double)

    public var description: String {
        switch self {
        case .emptyPrompt: return "音乐描述为空"
        case .promptTooLong(let limit, let actual): return "音乐描述过长（\(actual) > \(limit)）"
        case .operationMismatch: return "幂等键与操作类型不匹配"
        case .missingSourceClip: return "翻唱、续写或重制需要先选一首源作品"
        case .sourceClipIDTooLong(let limit, let actual):
            return "源音乐标识过长（\(actual) > \(limit)）"
        case .continueAtOutOfRange(let limit):
            return "续写起点要在 0 到 \(Int(limit)) 秒之间"
        }
    }
}

/// `POST /api/studio/create/generate` 请求体（P0 形态：`mode:'simple'` + `operation:'create'`）。
///
/// 字段集**只发契约确定会读的那几个**（`generate.ts:98-184` 的读取清单），不发明键；
/// 可选字段为 nil 时由合成 `encode(to:)` 的 `encodeIfPresent` 语义自动省略。
///
/// 幂等（TD-24 同族纪律）：只接受 `IdempotentRequestToken`，且 operation 必须是
/// `.studioCreateGenerate` —— 从任意 JSON 灌不进任意键，串用别的写操作的键在 init 就抛。
/// **一次点击 = 一个 token**；同一次提交的重试复用同一 token（服务端同键重放直接返回
/// 已有 jobId、不二次扣费）；「重新生成」是新的逻辑提交 ⇒ 新 token。
public struct StudioCreateGenerateRequestDto: Encodable, Equatable, Sendable {
    /// 服务端上限（`generate.ts:105`）：超出 ⇒ 400「音乐描述过长（最多 2000 字）」。
    public static let promptMaximumLength = 2000
    /// `sourceClipId` 上限（`generate.ts:121` 的 `optionalTrimmed(..., 200)`）。
    public static let sourceClipMaximumLength = 200
    /// `continueAt` 的上界（秒，`generate.ts:147-152`：0–3600，服务端按 0.1 取整）。
    public static let continueAtMaximumSeconds: Double = 3600

    public let mode: StudioCreateMode
    public let operation: StudioCreateOperation
    public let prompt: String
    public let idempotencyKey: IdempotencyKey
    /// 源音乐的**provider clip id**（翻唱/续写/重制必填）。
    ///
    /// ⚠️ 服务端**完全不校验**这一格（§4.7：无存在性/归属/格式检查）⇒ 一个错的 clip id 会
    /// 照常 200 + 新 jobId + **真扣费**，然后异步失败，只在行的 `status=failed` +
    /// `errorMessage` 上显形。所以这一层只能保证两件事：本地拦掉"根本没选源"，
    /// 以及**只把本机从服务端读回来的 `providerClipId` 送进去**（不猜、不拼）。
    public let sourceClipId: String?
    /// 续写起点（秒）。只有 `operation == .extend` 且带 `sourceClipId` 时服务端才消费它；
    /// 缺省时服务端自己取原曲结尾，取不到才回 400「暂时读不到原曲长度，请手动选择续写起点」。
    public let continueAt: Double?

    public init(
        prompt: String,
        mode: StudioCreateMode = .simple,
        operation: StudioCreateOperation = .create,
        sourceClipId: String? = nil,
        continueAt: Double? = nil,
        token: IdempotentRequestToken
    ) throws {
        guard token.operation == .studioCreateGenerate else {
            throw StudioCreateRequestError.operationMismatch
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「prompt 必填」这一条**只在 simple 成立**（`generate.ts:107`）——
        // 把它写成无条件，advanced 那一档的合法提交会被本地挡掉。
        guard !trimmed.isEmpty || mode != .simple else {
            throw StudioCreateRequestError.emptyPrompt
        }
        let count = trimmed.count
        guard count <= Self.promptMaximumLength else {
            throw StudioCreateRequestError.promptTooLong(
                limit: Self.promptMaximumLength, actual: count
            )
        }
        // 空白与"没给"是同一件事：用户在源选择器里没选，与选了一个空格，
        // 该听到的都是那句「需要先选一首源作品」，而不是"标识为空"。
        let trimmedClip = sourceClipId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = (trimmedClip?.isEmpty == false) ? trimmedClip : nil
        if let clip {
            guard clip.count <= Self.sourceClipMaximumLength else {
                throw StudioCreateRequestError.sourceClipIDTooLong(
                    limit: Self.sourceClipMaximumLength, actual: clip.count
                )
            }
        }
        // 非 create 的三种操作**都必须带源**（服务端 400「翻唱 / 续写 / 重制需要先选择源音乐或上传音频」）
        // ⇒ 本地先拦，省一次往返，也省一次"200 之后才发现做不了"的扣费错觉。
        if operation != .create, clip == nil {
            throw StudioCreateRequestError.missingSourceClip
        }
        if let continueAt {
            guard continueAt.isFinite, continueAt >= 0,
                  continueAt <= Self.continueAtMaximumSeconds else {
                throw StudioCreateRequestError.continueAtOutOfRange(
                    limit: Self.continueAtMaximumSeconds
                )
            }
        }
        self.mode = mode
        self.operation = operation
        self.prompt = trimmed
        self.sourceClipId = clip
        // 服务端按 0.1 取整 ⇒ 客户端也按 0.1 落，屏上显示的值与发出去的值才是同一个数。
        self.continueAt = continueAt.map { ($0 * 10).rounded() / 10 }
        self.idempotencyKey = token.key
    }

    enum CodingKeys: String, CodingKey {
        case mode, operation, prompt, idempotencyKey, sourceClipId, continueAt
    }

    /// **没有值的键不许出现**（不是发 `null`）：服务端用 `optionalTrimmed` 读它们，
    /// 缺键与显式 null 今天同义，但把"客户端没这个概念"写成 null 交给对方，
    /// 等于替服务端决定了一次语义（§4.7 的同一口径）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(operation, forKey: .operation)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(sourceClipId, forKey: .sourceClipId)
        try container.encodeIfPresent(continueAt, forKey: .continueAt)
    }
}

/// `POST /api/studio/create/generate` 成功响应：`{ok:true, jobId, charge}`。
///
/// ⚠️ **`charge` 是数字，不是对象**（实测 `generate.ts:526-530` 与
/// `web/src/app/studio/components/create/types.ts:115-119`）—— DEVELOPMENT.md §4.4 写的
/// `{ok:true, jobId, charge}` 没标形态，照「对象」建模会解不出来。
/// 未开 `COVA_SUNO_AGENT_ENABLED` 时恒 0（开发环境），所以 **0 不等于免费**：
/// UI 只在 `charge > 0` 时渲染「本次消耗 N co」（19 §3.D）。
public struct StudioCreateGenerateResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let jobId: String?
    public let charge: Int?

    enum CodingKeys: String, CodingKey {
        case ok, jobId, charge
    }

    /// 拿到任务号才算提交成功。`ok` 单独为真而 jobId 缺失 ⇒ **扣费可能已经发生**
    /// （服务端先落 job 后扣费），此时不许说「没提交成功」——与
    /// `GenerationJobResponseDto.isUnresolvedSubmission` 同一条钱路纪律。
    public var isUnresolvedSubmission: Bool {
        guard let jobId, !jobId.isEmpty else { return true }
        return false
    }
}

/// 非 2xx 的响应体（统一信封 `{error, code?, ...details}`）。
///
/// 逐条实测（`generate/route.ts:21-39`、`generate.ts:63,105,107,145,534`）：
/// · 400 `{error:"请填写音乐描述", code:"invalid_request"}`
/// · 400 `{error:"音乐描述过长（最多 2000 字）", code:"invalid_request"}`
/// · 400 `{error:"缺少幂等键", code:"invalid_request"}`
/// · 402 `{error:"credits_insufficient", balance:<num>, required:<num>}` ——
///   **这一档 `error` 的值就是英文码，且不带 `code` 键**，所以「余额不足」那句话
///   只能由客户端按 `required` 组装（`StudioCreateRejection.userMessage`）；
/// · 502 `{error:"创作任务提交失败，请稍后再试", code:"submit_failed"}`
/// · 409 `{error:"同一 idempotencyKey 不能用于不同播放", code:"IDEMPOTENCY_CONFLICT"}`（播放侧同族）
///
/// `balance` / `required` 建模为 `Int?`：只有 402 那一档给，其余为 nil。
public struct StudioCreateErrorDto: Decodable, Equatable, Sendable {
    public let error: String?
    public let code: String?
    public let balance: Int?
    public let required: Int?

    enum CodingKeys: String, CodingKey {
        case error, code, balance
        case required
    }
}

/// 提交失败 → UI 可说的**一句话**（纯函数裁决面，A4 的判据落点）。
///
/// 为什么必须是一层纯函数而不是在视图里拼：`CovaAPIError.httpStatus(code:apiCode:)`
/// **丢掉了服务端的 `error` 文案**（那是登录防枚举刻意做的取舍，`LoginFailureCopy` 同源），
/// 而 A4 要的恰恰相反 —— 400 要透传服务端中文原文。所以这条腿走
/// `CovaAPIClient.performCoded` 拿到状态码与响应体，由本类型按端点契约分诊。
///
/// 两条不可谈判的口径：
/// · **屏上不出现英文码**（A15）：`credits_insufficient` / `invalid_request` / `submit_failed`
///   都不得直接上屏 —— 它们进分支判断，话术另出；
/// · **不编「未知错误」**：服务端没给文案时说清「服务端未说明原因」，而不是糊一个词。
public enum StudioCreateRejection: Equatable, Sendable {
    /// 400：请求本身不被接受（缺 prompt / 超长 / 缺幂等键）。携服务端中文原文。
    case invalidRequest(serverMessage: String?)
    /// 402：余额不足。`required` = 本次需要的 co 数（服务端给的唯一数字）。
    case creditsInsufficient(balance: Int?, required: Int?)
    /// 409：同一幂等键被用于不同提交。
    case idempotencyConflict
    /// 429：限流（`Retry-After` 秒数由调用方另行持有，本类型只负责话术）。
    case rateLimited(serverMessage: String?)
    /// 502/503：上游提交失败。**generate 永不返回 423** —— 上游 `provider_lease_busy`
    /// 被 catch-all 吞成 `submit_failed`（`generate.ts:531-536`），所以这里没有「排队中」分支；
    /// 423 只存在于 lyrics / style-suggest 通道。
    case submitFailed(serverMessage: String?)
    /// 401/403：交给登录态处理（19 §4 的 17-S6），不在这里编话术。
    case unauthenticated
    /// 其余状态码。
    case server(statusCode: Int, serverMessage: String?)

    /// 上屏文案（19 §8 文案清单）。
    public var userMessage: String {
        switch self {
        case .invalidRequest(let message):
            return Self.human(message) ?? "这次提交没被接受（服务端未说明原因）"
        case .creditsInsufficient(_, let required):
            guard let required, required > 0 else { return "余额不足" }
            return "余额不足，本次需要 \(required) co"
        case .idempotencyConflict:
            return "这次提交和上一次撞了，请重试"
        case .rateLimited(let message):
            return Self.human(message) ?? "请求过于频繁，请稍后再试"
        case .submitFailed(let message):
            return Self.human(message) ?? "创作任务提交失败，请稍后再试"
        case .unauthenticated:
            return "登录状态已过期"
        case .server(let statusCode, let message):
            return Self.human(message) ?? "服务端错误（\(statusCode)）"
        }
    }

    /// 服务端 `error` 值能不能直接上屏（A4「透传」与 A15「屏上无英文码」的交汇点）。
    ///
    /// 实测这一档服务端给的**通常是中文人话**（`请填写音乐描述`、`音乐描述过长（最多 2000 字）`、
    /// `创作任务提交失败，请稍后再试`），但**不总是**：402 的 `error` 值就是英文码
    /// `credits_insufficient`（且那一档不带 `code` 键）。既然同一个字段两种性质都出现过，
    /// 就不能无条件透传。判据取「裸码形状」而不是「非中文」：
    /// 全串只由 `[A-Za-z0-9_]` 构成且不含空白 ⇒ 那是一个标识符，不是一句话 ⇒ 不透传，
    /// 回落到本层自己的中文话术。带空格/标点/中文的一律当人话透传（宁可少拦，不可替服务端改口）。
    static func human(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        let isBareCode = message.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
        return isBareCode ? nil : message
    }

    /// 状态码 + 响应体 → 分诊。**不加 `default` 兜住状态码**：分档是契约事实，
    /// 落进 `.server` 的必须是「契约没为它钉话术」的那一档，不是「我没想到的」那一档。
    public static func classify(
        statusCode: Int, body: Data?
    ) -> StudioCreateRejection {
        let envelope = body.flatMap { try? JSONDecoder().decode(StudioCreateErrorDto.self, from: $0) }
        switch statusCode {
        case 401, 403:
            return .unauthenticated
        case 400:
            return .invalidRequest(serverMessage: envelope?.error)
        case 402:
            return .creditsInsufficient(balance: envelope?.balance, required: envelope?.required)
        case 409:
            return .idempotencyConflict
        case 429:
            return .rateLimited(serverMessage: envelope?.error)
        case 502, 503:
            return .submitFailed(serverMessage: envelope?.error)
        default:
            return .server(statusCode: statusCode, serverMessage: envelope?.error)
        }
    }
}

/// 作品身份：伪 trackId `{jobId}:{candidateId}` 的唯一构造/解析面。
///
/// 服务端判据（`play-history.ts:50`）：非库曲且 `trackId.includes(':')` 或命中
/// `generation_jobs.id` ⇒ 记进 `work_listens`。**裸 jobId 也被接受**，但那种行在
/// GET 历史里可能因取不到候选音频而被整行丢弃（`:149-153`）⇒ 本仓一律带候选后缀。
public enum StudioCreateWorkIdentifier {
    public static let separator = ":"

    /// 组装伪 trackId。两段都必须非空（空段会造出 `:x` / `x:` 这种服务端能收但语义残缺的 id）。
    public static func pseudoTrackId(jobId: String, candidateId: String) -> String? {
        let job = jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = candidateId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !job.isEmpty, !candidate.isEmpty else { return nil }
        guard !job.contains(separator), !candidate.contains(separator) else { return nil }
        return job + separator + candidate
    }

    /// 拆回 `(jobId, candidateId)`；无候选后缀 ⇒ candidateId 为 nil。
    public static func split(_ trackId: String) -> (jobId: String, candidateId: String?)? {
        guard !trackId.isEmpty else { return nil }
        let parts = trackId.split(separator: Character(separator), omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count == 1 { return (String(first), nil) }
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (String(first), String(parts[1]))
    }

    /// 生成中的占位行 id 形态（`works.ts:151-159`）：`<jobId>:pending-1` / `pending-2`。
    /// 这种行**没有音频**，不能被当成可播/可存的作品。
    public static func isPendingPlaceholder(candidateId: String?) -> Bool {
        guard let candidateId else { return false }
        return candidateId.hasPrefix("pending-")
    }
}

/// `GET /api/studio/create/works` 的一行（clip 打平：一行 = 一首）。
///
/// 键集实测 `web/src/app/studio/components/create/types.ts:18-55` +
/// `lib/studio/create/works.ts:123-159`：`id/jobId/title/coverUrl/audioUrl/duration/status/
/// tags/lyrics/modelVersion/instrumental/voiceName/errorMessage/createdAt/source/providerClipId`
/// 恒有键（值可为 null），`playbackUrl/melody/operation/favorited/disliked` **只在有意义时出现**。
///
/// TD-23 口径：`audioUrl` / `playbackUrl` 可能是签名地址 ⇒ 收口 `SecretString?`，
/// 且本类型**仅 `Decodable`**（编译期禁止把签名串重新序列化进持久化索引）。
public struct CreateWorkItemDto: Decodable, Equatable, Sendable {
    /// `{jobId}:{candidateId}`，或生成中的占位 `{jobId}:pending-N`，或裸 jobId。
    public let id: String
    public let jobId: String?
    /// 任务态；字面量与 `GenerationJobStatus` 完全同集（`schema.ts:58`）⇒ 复用同一个枚举，
    /// 中文标签也复用 `GenerationJobStatus.userLabel`（A15 术语唯一源）。
    public let status: GenerationJobStatus?
    public let title: String?
    public let coverUrl: String?
    /// 可播放地址：三种形态（`/audio/*.mp3` 公开静态｜`/api/media/objects/…` 需 Bearer
    /// 且会 302→COS｜`/api/proxy/audio?…` HMAC 签名 TTL 30min）。生成中/失败为 null。
    public let audioUrl: SecretString?
    /// 免 Authorization 的预签名 COS 绝对直链，TTL 900s；**仅 `/api/media/objects/` 形态才签发**，
    /// 经典 worker 路径恒缺 ⇒ 必须按可选处理。
    public let playbackUrl: SecretString?
    public let duration: Double?
    public let instrumental: Bool?
    public let errorMessage: String?
    public let createdAt: String?
    public let providerClipId: String?

    enum CodingKeys: String, CodingKey {
        case id, jobId, status, title, coverUrl, audioUrl, playbackUrl
        case duration, instrumental, errorMessage, createdAt, providerClipId
    }

    public var isPendingPlaceholder: Bool {
        StudioCreateWorkIdentifier.isPendingPlaceholder(
            candidateId: StudioCreateWorkIdentifier.split(id)?.candidateId
        )
    }

    /// 能不能**播**：终态成功、不是占位行、且有 `audioUrl`。
    ///
    /// ⚠️ 判据里**没有** `playbackUrl`（2026-09-26 更正；早先这里写的是
    /// `audioUrl != nil || playbackUrl != nil`，与 `WorksListRowDto` 各持一套 —— 同一个判定
    /// 写两处、其中一处漏改是本仓反复复发的缺陷族）。两条实测把 `playbackUrl` 从"播放"这一格
    /// 摘掉：§7 #37 实测作品行的 `playbackUrl` 6/6 签在 `covalink-uploads-…`（名单外），
    /// 而 §7 #39 之后 `audioUrl` 走同源 `intent=download` 已能 200 出字节 ⇒ 播放这一腿
    /// 没有任何一条需要 `playbackUrl`，留着它只会画出一个点下去必然失败的 ▶。
    ///
    /// 直存是**另一格**（名单内桶的绝对直链在那条腿上是可用的）⇒ 看 `hasStorableSource`。
    public var isPlayable: Bool {
        guard status == .succeeded, !isPendingPlaceholder else { return false }
        return audioUrl != nil
    }

    /// 能不能**直存到本机**：`audioUrl` 之外，落在 D23 名单桶上的 `playbackUrl` 也算
    /// （`WorkDownloadStore` 用 `isSanctionedMediaURL` 裁决，名单外一律拒 ——
    /// 这里只报告"有没有一条本端认的腿"，放行与否仍归出口守卫）。
    public var hasStorableSource: Bool {
        guard status == .succeeded, !isPendingPlaceholder else { return false }
        if audioUrl != nil { return true }
        guard let raw = playbackUrl?.rawValue, let url = URL(string: raw) else { return false }
        return CovaEnvironment.isSanctionedMediaURL(url)
    }

    /// 上屏标题（缺失回落见 19 §3.E 的「未命名作品」，那一句在 UI 层，不在 DTO 里编）。
    public var displayTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }
}

/// `GET /api/studio/create/works` 响应：`{works, nextCursor, total}`（`Cache-Control: no-store`）。
public struct CreateWorksResponseDto: Decodable, Equatable, Sendable {
    public let works: [CreateWorkItemDto]
    public let nextCursor: String?
    public let total: Int?

    enum CodingKeys: String, CodingKey {
        case works, nextCursor, total
    }

    /// 可播的作品行（占位行与未成功的行不进结果区，19 §3.E）。
    public var playableWorks: [CreateWorkItemDto] { works.filter(\.isPlayable) }
}

/// 任务轮询节拍（DEVELOPMENT.md §4.5：**前 6 次 5s、之后 10s、上限约 30min**）。
///
/// 纯值类型、零 timer：调度与执行分离，于是「第 7 次是不是 10s」「什么时候该停」
/// 都能不依赖时钟断言（与本仓 `OneStepStream` 的降级状态机同一套做法）。
public struct StudioCreatePollSchedule: Equatable, Sendable {
    /// 快轮询次数（第 1…6 次）。
    public let fastPollCount: Int
    public let fastInterval: TimeInterval
    public let slowInterval: TimeInterval
    /// 累计等待上限（秒）。到点即停 —— **停不等于失败**：任务可能还在跑，
    /// UI 说「还在做，稍后回来看」（19 §4），不许印「没能完成」。
    public let maximumElapsed: TimeInterval

    public init(
        fastPollCount: Int = 6,
        fastInterval: TimeInterval = 5,
        slowInterval: TimeInterval = 10,
        maximumElapsed: TimeInterval = 30 * 60
    ) {
        self.fastPollCount = max(0, fastPollCount)
        self.fastInterval = max(0, fastInterval)
        self.slowInterval = max(0, slowInterval)
        self.maximumElapsed = max(0, maximumElapsed)
    }

    /// 第 `attempt` 次（**1 基**）轮询前该等多久。
    public func interval(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return fastInterval }
        return attempt <= fastPollCount ? fastInterval : slowInterval
    }

    /// 第 `attempt` 次轮询**发生之前**已经累计等待的秒数。
    public func elapsed(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        var total: TimeInterval = 0
        for index in 1..<attempt { total += interval(forAttempt: index) }
        return total
    }

    /// 还该不该发第 `attempt` 次轮询（累计等待已到上限即停）。
    public func shouldPoll(attempt: Int) -> Bool {
        guard attempt > 0 else { return false }
        return elapsed(beforeAttempt: attempt) < maximumElapsed
    }

    /// 上限内最多能发多少次轮询（用于「上限约 30min」这句话的可断言形态）。
    public var maximumAttemptCount: Int {
        var attempt = 1
        while shouldPoll(attempt: attempt) { attempt += 1 }
        return attempt - 1
    }
}
