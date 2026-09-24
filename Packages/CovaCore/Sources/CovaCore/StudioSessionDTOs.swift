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
    public let workflowMode: String?
    public let status: String?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleCn
        case summary
        case workflowMode
        case status
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
        workflowMode = try container.decodeIfPresent(String.self, forKey: .workflowMode)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// design 08：标题取不到 ⇒ 「未命名会话」（这是 spec 指定的兜底文案，不是编造数据）。
    public var displayTitle: String {
        if let titleCn, !titleCn.isEmpty { return titleCn }
        if let title, !title.isEmpty { return title }
        return "未命名会话"
    }

    /// 摘要行取不到 ⇒ **整行不渲染**（spec：省略该行，不放占位符）。
    public var displaySummary: String? {
        guard let summary, !summary.isEmpty else { return nil }
        return summary
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
