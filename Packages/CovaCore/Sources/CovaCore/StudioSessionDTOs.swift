import Foundation

/// 创作会话（`GET /api/find-my-song/sessions` 与 `…/sessions/:id`）。
///
/// **契约只给了路径与「详情含 `messages[] / generationJobs[]`」这一句，没有条目 schema**
/// （`docs/api-contracts.md` §4）。因此除 `id` 之外**全部按可选建模**：
/// · 缺席不报错、也不编造默认值（宁可少显示一段，也不把猜的值显示成后端给的）；
/// · 缺口登记在 `docs/NEEDS.md`（会话条目字段 schema），补齐前 UI 只渲染**取得到的字段**；
/// · 信封形态按实测两种都容忍（`{sessions:[…]}` 或裸数组），见 `StudioSessionListDto`。
public struct StudioSessionDto: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let titleCn: String?
    public let summary: String?
    /// 08 §3.C 行摘要的**真实来源**。2026-09-26 用 owner 给的测试账号实测
    /// `GET /api/find-my-song/sessions`（HTTP 200 / 5 条），每行给的键是
    /// `lastMessage` 而**不是** `summary` —— 后者只写在契约文档里。
    /// 两个键都建模、不裁决谁更权威（见 `displaySummary`）：列表行今天靠这一个键。
    public let lastMessage: String?
    /// 服务端**提议**的会话名（`listOwnedSessions` 实列，`find_my_song_sessions.proposedTitle`）。
    /// 语义与 `title` 不同：`title` 是已落地的名字（默认「新会话」），`proposedTitle` 是
    /// agent 提议、还没被用户确认的名字（确认后写进 `title` 并清掉本键）——
    /// 所以在 `title` 还是缺省值时它可以拿来当显示名（C6，2026-10-01）。
    public let proposedTitle: String?
    /// 08 §3.C 的 48pt 封面槽来源，**逐行可空**：同一账号 5 条会话（全是 `workflowMode:"one-step"`）
    /// 这里逐条是 `null` ⇒ 「没封面」是正常态而不是故障，占位分支必须留着，
    /// 也**不得**为它补一次详情请求（§数据源行 140 禁 N+1）。
    /// 地址形态与其余美术腿同源（站内相对 + 带查询串都出现过）⇒ 消费侧一律走
    /// `CovaArtworkResolution(serverValue:)`（D23 出口判定面，查询串逐字节带走），不在这里补全或裁剪。
    public let firstCoverUrl: String?
    public let workflowMode: String?
    public let status: String?
    /// `session.workflowState` —— **JSON 字符串**，不是嵌套对象
    /// （2026-09-24 真实账号实测：`{"completedSteps":[…],"activeStep":"demo",
    /// "summaries":{…},"updatedAt":"…"}`）。与 `GenerationJobDto.metadata` 是**同一条形态约定**
    /// ⇒ 同样原样留 `String`，结构化视图走 `decodedWorkflowState()`。
    ///
    /// 这一条是 **E5 的更正**：旧版这里没有建模该键，`DeliveryProgress` 的注释于是把
    /// 「读不到的字段」写成了「不存在的字段」，据称"契约里没有任何进度字段"并把进度条
    /// 设计成永不填满。见 `DeliveryProgress.swift` 与 `docs/NEEDS.md` NEEDS-25。
    public let workflowState: String?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleCn
        case summary
        case lastMessage
        case proposedTitle
        case firstCoverUrl
        case workflowMode
        case status
        case workflowState
        case createdAt
        case updatedAt
    }

    /// 别名键**单独一个容器**去读：`CodingKeys` 必须与属性一一对应，
    /// 往里塞一个没有属性的键会让合成出的 `Encodable` 编译不过。
    private enum SessionIdAliasKey: String, CodingKey {
        case sessionId
    }

    /// 真实响应的**两种键名**都要接（2026-09-24 用真实账号实测）：
    /// 列表行给 `id`，而 `…/sessions/:id` 详情里套的那个 session 对象给的是 `sessionId`、
    /// **没有 `id`**。原先 `id` 是必需键 ⇒ 详情里的 session 解码直接抛错，
    /// 整个 09 屏在真数据上报「读不到」，而不是退化成空会话。
    /// 两个键都取不到时照旧**报错**：会话号是路由与归属的根，不许猜一个。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let direct = try container.decodeIfPresent(String.self, forKey: .id)
        let aliased = try decoder.container(keyedBy: SessionIdAliasKey.self)
            .decodeIfPresent(String.self, forKey: .sessionId)
        guard let resolved = [direct, aliased].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "会话既没有 id 也没有 sessionId（NEEDS-23）"
            )
        }
        id = resolved
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleCn = try container.decodeIfPresent(String.self, forKey: .titleCn)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        lastMessage = (try? container.decodeIfPresent(String.self, forKey: .lastMessage)) ?? nil
        proposedTitle = (try? container.decodeIfPresent(String.self, forKey: .proposedTitle)) ?? nil
        // 「值出现了但不是字符串」与「键不在」同等对待（同下面 `workflowState` 的口径）：
        // 后端哪天把封面换成 `{url:…}` 那种对象时，症状应该是「这一格没封面」，
        // 不是「整个 08 打不开」。
        firstCoverUrl = (try? container.decodeIfPresent(String.self, forKey: .firstCoverUrl)) ?? nil
        workflowMode = try container.decodeIfPresent(String.self, forKey: .workflowMode)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        // 「值出现了但**不是字符串**」（后端哪天改成真对象）与「键不在」在这里同等对待：
        // `decodeIfPresent(String.self)` 遇到对象会抛 typeMismatch，那会把整张详情打成
        // 「这个会话打不开」—— 一个进度展示位读不到，不配让消息流一起消失。故 `try?` 吞掉形态不符，
        // 退化成「没给」= 今天的行为（NEEDS-25 要的正是把这个形态写进契约）。
        workflowState = (try? container.decodeIfPresent(String.self, forKey: .workflowState)) ?? nil
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// design 08：标题取不到 ⇒ 「未命名会话」（这是 spec 指定的兜底文案，不是编造数据）。
    ///
    /// 兜底链（2026-10-01 C6）：
    /// `titleCn` → `title` → `proposedTitle` → `lastMessage` 截断 → 「未命名会话」。
    /// 两处**不原样透传**的修正，都是"服务端写的缺省值不能当成用户起的名"：
    /// · `title == "新会话"` 是服务端建会话时的缺省值（`session.ts` 的 `'新会话'`），
    ///   不是用户命名 ⇒ 当作没给，继续往下找；
    /// · `lastMessage` 是"会话里最后一条非系统消息"（`session.ts:402` 实测口径），
    ///   不是标题 ⇒ 只截取前 20 字当权宜标题，并在末尾补省略号表明被截。
    /// 服务端若有确定性命名（首条用户消息/auto-title），那一栏应该由 `title` 承载 ——
    /// 本端不再替它凑名，缺口登记在 DEVELOPMENT.md §7（会话标题）。
    public var displayTitle: String {
        if let titleCn, !titleCn.isEmpty { return titleCn }
        if let title, !title.isEmpty, title != "新会话" { return title }
        if let proposedTitle {
            let trimmed = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let fallback = Self.messageFallback(lastMessage) { return fallback }
        return "未命名会话"
    }

    /// `lastMessage` → 权宜标题：换行压成空格、首尾裁白、前 20 字 + 「…」。
    /// 为什么 20 字：08 的行标题位设计容纳约一行（约 12–14 个全角字），
    /// 超出一点没关系（行尾截断），但取太短的"前 N 字"会丢掉上下文主干。
    /// 空串/纯空白与缺失同一口径 ⇒ `nil`（不拿一行空白当标题）。
    public static func messageFallback(_ message: String?) -> String? {
        guard let message else { return nil }
        let normalized = message
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.count <= 20 { return normalized }
        return String(normalized.prefix(20)) + "…"
    }

    /// 摘要行取不到 ⇒ **整行不渲染**（spec：省略该行，不放占位符）。
    ///
    /// 两个键都看、**不看优先级谁"更对"**：`summary` 是契约文档写的那个（详情面可能给），
    /// `lastMessage` 是列表行实测给的那个（见两个属性上的实测记录）。
    /// 空串/纯空白与缺失同一口径 —— 都不足以撑起那一行（撑起来会是一行看不见的空白）。
    public var displaySummary: String? {
        for candidate in [summary, lastMessage] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false { return trimmed }
        }
        return nil
    }

    /// `workflowState` 的结构化视图（同 `GenerationJobDto.decodedMetadata()` 的口径：
    /// 字符串里装着 JSON，需要时才解）。**解不出 ⇒ `nil`**，而 `nil` 在这条链路上只有一个含义：
    /// 「这一格没有实测进度」⇒ 界面退回今天的样子（`DeliveryProgressPlanner` 的契约状态映射）。
    /// 它**不等于**「0 步」，也**不等于**「全部完成」—— 那两个都是把"读不到"印成"读到了"。
    public func decodedWorkflowState() -> StudioWorkflowStateDto? {
        StudioWorkflowStateDto.decode(fromJSONString: workflowState)
    }
}

/// `session.workflowState` 那个 JSON 字符串的**容忍**解码视图
/// （`GET /api/find-my-song/sessions/:id`，2026-09-24 真实账号实测键名逐字取自线上）：
///
/// ```json
/// {"completedSteps":["collect","lyrics","style","musician","brief","breakdown"],
///  "activeStep":"demo",
///  "summaries":{"demo":"一步计划已锁定，正在制作两个 Demo。"},
///  "updatedAt":"2026-09-24T13:09:14.778Z"}
/// ```
///
/// ### 容忍规则（逐条都是「不猜」，不是「多接一点」）
/// 1. **逐字段**容错，不整包连坐：`completedSteps` 里混进非字符串元素、`summaries` 的值不是
///    字符串、`activeStep` 是数字 —— 都只让**那一个字段**变成 `nil`，其余字段照常可用。
///    （整包 `try?` 会让后端加一个异形字段就把用户的进度条整个吃掉。）
/// 2. **不认识的位置一律不猜**：本类型只是**记录**后端给的字符串键，**不给任何键赋予位置**。
///    位置只有一处来源 —— `DeliveryProgress.swift` 里那份与 web 同源的 14 步规范序；
///    不在其中的键（未来新增的 `quantum`、`timemachine`…）因此**无法**声称走过某一格。
/// 3. `activeStep: null`（会话收口）是**合法值**，不是错误：`decodeIfPresent` 给 `nil`。
/// 4. **空串/纯空白/非法 JSON/顶层不是对象** ⇒ `decode` 返回 `nil`（见该方法）。
///    注意"顶层是对象但一个字段都没有"（`"{}"`）**能**解出实例 —— 它没有可用信号，
///    由 `DeliveryProgressPlanner` 那一层判「不足以画梯子」，本类型不越权裁决。
/// 5. 字段里**没有任何凭证/签名地址**（`summaries` 是后端写给人看的中文句子，
///    `completedSteps`/`activeStep` 是环节名）⇒ 不进 `SecretString` 收口；
///    但同 09 §8 的口径，它同样**不写日志**（界面上只印中文，不印键名与原文 JSON）。
public struct StudioWorkflowStateDto: Codable, Equatable, Sendable {
    /// 后端自报**已完成**的环节键（未去重、未排序、可能含未知键 —— 见类型注释 2）。
    public let completedSteps: [String]?
    /// 当前进行中的环节键；收口时后端给 `null`。
    public let activeStep: String?
    /// 后端自己标注"跳过"的环节。**进度计算不使用它**：跳过 ≠ 做过
    /// （web 的 5 组投影 `tutorialStepsFromWorkflow` 同样不看这个字段）。建模它是为了读全这份载荷。
    public let skippedSteps: [String]?
    /// 环节号 → 后端写的那句话（09 屏左列优先用它，见 `DeliveryProgress`）。
    public let summaries: [String: String]?
    /// ISO-8601 串；**原样保留**，本屏不参与计算（格式由后端定，客户端不裁决）。
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case completedSteps
        case activeStep
        case skippedSteps
        case summaries
        case updatedAt
    }

    public init(
        completedSteps: [String]?,
        activeStep: String?,
        skippedSteps: [String]? = nil,
        summaries: [String: String]?,
        updatedAt: String?
    ) {
        self.completedSteps = completedSteps
        self.activeStep = activeStep
        self.skippedSteps = skippedSteps
        self.summaries = summaries
        self.updatedAt = updatedAt
    }

    /// 每个字段**单独**容错（规则 1）：某字段形态不对 ⇒ 只丢那一个字段，其余照常。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedSteps = (try? container.decodeIfPresent([String].self, forKey: .completedSteps)) ?? nil
        activeStep = (try? container.decodeIfPresent(String.self, forKey: .activeStep)) ?? nil
        skippedSteps = (try? container.decodeIfPresent([String].self, forKey: .skippedSteps)) ?? nil
        summaries = (try? container.decodeIfPresent([String: String].self, forKey: .summaries)) ?? nil
        updatedAt = (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
    }

    /// **唯一的**字符串→结构入口（缺失 / 空 / 空白 / 非法 JSON / 顶层不是对象 ⇒ `nil`）。
    ///
    /// 「顶层不是对象」这一条必须显式挡：`"null"`、`"123"`、`"\"abc\""` 都是**合法 JSON**，
    /// 但没有键容器 ⇒ 交给 `init(from:)` 会在 `container(keyedBy:)` 抛错。
    /// 这里靠 `try?` 同样能得到 `nil`，可那条路径是"靠异常做控制流"，
    /// 而真实响应里 `"null"` 就是"没有工作流"（`StudioSessionDto` 实测见过 `proposedTitle: null`）
    /// ⇒ 提前判掉，让「空」与「坏」在两处含义上都不必走到抛错。
    public static func decode(fromJSONString raw: String?) -> StudioWorkflowStateDto? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有以 `{` 开头的载荷才可能是那个对象；`null` / `""` / `"[]"` 一律按「没给」处理。
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudioWorkflowStateDto.self, from: data)
    }
}

/// 会话列表信封。容忍 `{sessions:[…]}` 与裸数组两种形态；
/// 两者都不是 ⇒ 解码失败（**不静默当空列表**，那会把契约漂移伪装成「你还没有创作」）。
public struct StudioSessionListDto: Decodable, Equatable, Sendable {
    public let sessions: [StudioSessionDto]

    private enum ObjectKeys: String, CodingKey {
        case sessions
        case items
        case data
    }

    public init(from decoder: Decoder) throws {
        if let array = try? [StudioSessionDto](from: decoder) {
            sessions = array
            return
        }
        let container = try decoder.container(keyedBy: ObjectKeys.self)
        for key in [ObjectKeys.sessions, .items, .data] {
            if let value = try? container.decode([StudioSessionDto].self, forKey: key) {
                sessions = value
                return
            }
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "会话列表既不是数组也没有 sessions/items/data 键（NEEDS-23）"
        ))
    }
}

/// 会话详情里的消息条目。
///
/// `id` **不是**必需的（真实响应的消息就没有这个键，缺了按确定性视图标识合成，见 `init(from:)`）；
/// 正文可能落在 `text` 或 `content`（契约没写），
/// 两者都取不到 ⇒ `displayText == nil`，UI **跳过这条**而不是显示空白气泡。
public struct StudioMessageDto: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String?
    public let text: String?
    public let content: String?
    public let createdAt: String?

    /// 这个 `id` 是**客户端合成的视图标识**还是**后端给的消息号**。合成键才允许在本次响应里
    /// 被补序号（见 `withResponseUniqueIds`）；后端给的那一个是身份，客户端不许改写。
    /// 不进 `CodingKeys` ⇒ 合成的 `encode(to:)` 不会把它当业务字段吐出去。
    let idIsSynthesized: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case content
        case createdAt
    }

    /// 去重时「换身份、不换内容」的内部构造器：不给外部一个能凭空造消息号的入口。
    init(
        id: String,
        role: String?,
        text: String?,
        content: String?,
        createdAt: String?,
        idIsSynthesized: Bool
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.content = content
        self.createdAt = createdAt
        self.idIsSynthesized = idIsSynthesized
    }

    /// 真实响应的消息**没有 `id` 键**，时间戳叫 `timestamp` 而不是 `createdAt`
    /// （2026-09-24 真实账号实测：`{role, content, timestamp, attachments}`）。
    private enum MessageAliasKey: String, CodingKey {
        case timestamp
    }

    /// 缺 `id` 时拼一个**确定性视图标识**：`view:` + 角色 + 时间戳 + **整段正文**的指纹。
    /// 同一条消息每次解码都得到同一个键；它只用于列表身份，**不冒充后端给过消息号**。
    ///
    /// 三条口径（R15-6：旧实现取正文**前 12 个字符**，评审用探针实测会撞车也会换身份）：
    /// · **不截断** —— 指纹吃的是 `role / createdAt / text / content` 四个字段的全量
    ///   （见 `stableFingerprint`），所以「同角色同时间戳、正文前 12 个字也相同、之后才分岔」
    ///   的两条不同消息不再共用一个键。一份响应里出现重复键不是"难看"，是列表会**丢行/串内容**。
    /// · **跨进程启动稳定** —— 指纹是自己实现的 FNV-1a/64，**不是** `hashValue`：后者每进程
    ///   换种子，等于每次冷启动整屏气泡重排一次；也不含任何**下标**，所以翻页时后端把更早的
    ///   消息 prepend 进来，已有条目的键**不变**。
    /// · **正文一变键就变**（残余弱点，不藏）—— 内容寻址的身份没法在正文增长（流式追加、
    ///   后端改写）时保持不变，而这条消息没有号可依据。要真正消除只有等响应带消息 `id`
    ///   （**NEEDS-28**）；在此之前本键的稳定性口径是「同一份内容 ⇒ 同一个键」，
    ///   不是「同一个气泡永远同一个键」。
    ///
    /// 逐字节相同的两条（角色、时间戳、正文全等）必然解出同一个键 —— 那一份响应内的重复
    /// 由 `withResponseUniqueIds` 在**看得见整张清单**的地方补掉。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alias = try decoder.container(keyedBy: MessageAliasKey.self)
        let decodedRole = try container.decodeIfPresent(String.self, forKey: .role)
        let decodedText = try container.decodeIfPresent(String.self, forKey: .text)
        let decodedContent = try container.decodeIfPresent(String.self, forKey: .content)
        let ownCreated = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let aliasStamp = try alias.decodeIfPresent(String.self, forKey: .timestamp)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id)
        // 先算完局部值再一次性赋给 self：在 init 里让闭包读 self.xxx 会撞上
        // 「所有存储属性初始化完成之前不得使用 self」。
        let stamp = ownCreated ?? aliasStamp
        let viewId = "view:\(decodedRole ?? "-"):\(stamp ?? "-"):" + Self.stableFingerprint(
            role: decodedRole,
            createdAt: stamp,
            text: decodedText,
            content: decodedContent
        )
        // 「有 `id` 键」与「有一个能用的号」是两件事：空串当身份用 ⇒ 整屏撞在一起，
        // 与 `StudioSessionDto` 对 `id`/`sessionId` 的同一口径。
        let realId = decodedId.flatMap { $0.isEmpty ? nil : $0 }
        role = decodedRole
        text = decodedText
        content = decodedContent
        createdAt = stamp
        id = realId ?? viewId
        idIsSynthesized = realId == nil
    }

    /// FNV-1a/64 —— 确定性、零依赖（依赖白名单为空 ⇒ 不能引 `CryptoKit` 之类）。
    /// 每个字段按「存在位 + UTF-8 字节数 + 内容」喂进哈希，所以
    /// `role="ab", createdAt="c"` 与 `role="a", createdAt="bc"` 不会拼成同一串字节，
    /// 「键缺席」与「键是空串」也不同（`text` 没有 ≠ `text` 是 ""）。
    /// 64 位指纹对不同输入仍可能理论撞车（约 2⁻⁶⁴），但不再是旧口径那种**按构造必撞**。
    private static func stableFingerprint(
        role: String?,
        createdAt: String?,
        text: String?,
        content: String?
    ) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        func mix(_ byte: UInt8) {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        for field in [role, createdAt, text, content] {
            if let field {
                mix(0x1f)
                for byte in String(field.utf8.count).utf8 { mix(byte) }
                mix(0x1c)
                for byte in field.utf8 { mix(byte) }
                mix(0x1d)
            } else {
                mix(0x1e)
            }
        }
        return String(format: "%016llx", hash)
    }

    /// 把**同一份响应内**重复的合成键按出现顺序补成 `base`、`base#2`、`base#3`…
    /// （第一条保持原键，后来的重复条目才移位）。
    ///
    /// 只有看得见整张清单的地方做得到这件事，而今天那个地方就是 `StudioSessionDetailDto`：
    /// 单条 `init(from:)` 没有"前面已经出现过几次"的视野。**直接解 `[StudioMessageDto]`
    /// 的调用点拿不到这层保证**（本仓暂无这种调用点，见该 DTO 的注释）。
    ///
    /// 残余弱点如实写明：`#n` 是**这一份有序清单内**的位置序号，所以后端在更早处 prepend
    /// 一条一模一样的消息时，原来 `#2` 那条会变成 `#3` —— 逐字节相同的重复条目本来就无法
    /// 用内容区分，这是"没有消息号"的直接后果（NEEDS-28）。后端给过 `id` 的条目**原样透传**，
    /// 只占用键位以防合成键与它重合；真 id 自己在一批里重复属后端 bug，同样记 NEEDS-28。
    static func withResponseUniqueIds(_ messages: [StudioMessageDto]) -> [StudioMessageDto] {
        var used: Set<String> = []
        used.reserveCapacity(messages.count)
        return messages.map { message in
            guard message.idIsSynthesized else {
                used.insert(message.id)
                return message
            }
            var candidate = message.id
            var occurrence = 2
            while used.contains(candidate) {
                candidate = "\(message.id)#\(occurrence)"
                occurrence += 1
            }
            used.insert(candidate)
            guard candidate != message.id else { return message }
            return StudioMessageDto(
                id: candidate,
                role: message.role,
                text: message.text,
                content: message.content,
                createdAt: message.createdAt,
                idIsSynthesized: true
            )
        }
    }

    public var displayText: String? {
        if let text, !text.isEmpty { return text }
        if let content, !content.isEmpty { return content }
        return nil
    }

    /// 用户气泡 vs agent 气泡。role 缺失时按 agent 渲染（保守：不把未知说成用户说的）。
    public var isFromUser: Bool { role == "user" }
}

/// `GET /api/find-my-song/sessions/:id` 详情信封（`{messages[], generationJobs[]}`，
/// 也容忍外面再套一层 `{session:…}`）。
/// 这里是**唯一看得见整份消息清单**的解码点 ⇒ 「一份响应内消息身份不重复」那条保证
/// 只在这一层成立（`StudioMessageDto.withResponseUniqueIds`）。
public struct StudioSessionDetailDto: Decodable, Equatable, Sendable {
    public let session: StudioSessionDto?
    public let messages: [StudioMessageDto]
    public let generationJobs: [GenerationJobDto]

    private enum ObjectKeys: String, CodingKey {
        case session
        case messages
        case generationJobs
    }

    private enum NestedKeys: String, CodingKey {
        case messages
        case generationJobs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ObjectKeys.self)
        session = try container.decodeIfPresent(StudioSessionDto.self, forKey: .session)
        var decodedMessages = try container.decodeIfPresent([StudioMessageDto].self, forKey: .messages) ?? []
        var decodedJobs = try container.decodeIfPresent([GenerationJobDto].self, forKey: .generationJobs) ?? []
        // 真实响应把内容**套在 `session` 里面**（2026-09-24 真实账号实测：
        // `{session:{messages[2], generationJobs[], …}}`）。只读顶层不会报错 ——
        // 它会把「有 2 条消息」悄悄解码成「0 条消息」，屏幕上就是一片空白。
        // 那不是失败，是撒谎，所以两处都看一遍。
        if decodedMessages.isEmpty || decodedJobs.isEmpty,
           let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .session) {
            decodedMessages = try nested.decodeIfPresent([StudioMessageDto].self, forKey: .messages)
                ?? decodedMessages
            decodedJobs = try nested.decodeIfPresent([GenerationJobDto].self, forKey: .generationJobs)
                ?? decodedJobs
        }
        // 合成键是**内容**的函数，所以"这一批里有几条"必须在这里补一次：
        // 单条 `init(from:)` 看不到整张清单，逐字节相同的两条会解出同一个键
        // （重复键在列表里是丢行/串内容，不是难看）。两条解码路径都过这一手。
        messages = StudioMessageDto.withResponseUniqueIds(decodedMessages)
        generationJobs = decodedJobs
    }
}

/// `POST /api/find-my-song/sessions` 响应。契约没写信封 ⇒ 已知形态都接，
/// 但**一个可用的会话号都取不到就是失败**（不能凭空造一个会话号去开流）。
///
/// **真实响应**（2026-09-24 真实账号实测）：顶层**只有 `session` 一个键**，
/// 而那个对象给的会话号叫 **`sessionId`、没有 `id`** ——
/// 与 `StudioSessionDto` 遇到的同一处漂移（列表行 `id` / 详情与这里的 `sessionId`）。
/// 旧实现的嵌套容器只声明 `id` ⇒ 三条分支全落空 ⇒ 直接抛错，
/// 「新建创作」在真机上永远建不出会话（从 08 点已有会话进 09 走的是 GET 详情、
/// 不发这个 POST ⇒ 一直没暴露）。首页那条"发一句话"的入口同样是 POST，同样挂着。
public struct StudioCreateSessionResponseDto: Decodable, Equatable, Sendable {
    public let sessionId: String

    private enum ObjectKeys: String, CodingKey {
        case session
        case id
        case sessionId
    }
    /// `session` 那一层的号**两个键名都读**（同 `StudioSessionDto.SessionIdAliasKey` 的口径）：
    /// 实测给 `sessionId`，契约文档写 `id`。
    private enum SessionKeys: String, CodingKey {
        case id
        case sessionId
    }

    /// 判定规则（四处号键一次看完，再按集合裁决）：
    /// · **只有一个值** ⇒ 用它。`session.sessionId`（实测）、`session.id`（契约文档）、
    ///   顶层 `sessionId`、顶层 `id` 四个位置谁给都行，**不看优先级** —— 只给一个时它没有对手。
    /// · **一个都没有** ⇒ 抛错。空串与缺失同一口径（`StudioSessionDto` 对 `id` 的同一判据）：
    ///   旧实现里 `{"session":{"id":""}}` 会**静默**解出空号，那比抛错坏得多 ——
    ///   用户下一句 prompt 会打进一个不存在的会话（`sessionId 缺失不得猜路由`）。
    /// · **两个及以上互不相同的值** ⇒ **也抛错**，而不是「嵌套优先」。这是刻意取的最严答案：
    ///   服务端自己给出两个号时客户端没有裁决依据，挑一个 = 把会话开在**另一个真实存在的**
    ///   会话上，症状是「消息发进了别的创作」，比「建不出来」更难被发现；抛错至少是可解释的失败。
    ///   两处键给的是**同一个值**时只算一个值 ⇒ 那种接（`testCreateSessionAcceptsConsistentIds…`
    ///   钉着），实测未见过两个不同值的响应，真遇到就是 NEEDS-23 要回答的问题。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ObjectKeys.self)
        // 「键在但值不是字符串」与「键不在」同等对待（都不入候选池）：值不合法时不猜。
        var candidates: [String?] = []
        if let nested = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session) {
            candidates.append((try? nested.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil)
            candidates.append((try? nested.decodeIfPresent(String.self, forKey: .id)) ?? nil)
        }
        candidates.append((try? container.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil)
        candidates.append((try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil)
        let usable = Set(candidates.compactMap { $0 }.filter { !$0.isEmpty })
        guard usable.count == 1, let resolved = usable.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: usable.isEmpty
                    ? "建会话响应里没有可用的 sessionId（NEEDS-23）"
                    : "建会话响应给了两个互不相同的会话号，客户端不猜（NEEDS-23）"
            ))
        }
        sessionId = resolved
    }
}
