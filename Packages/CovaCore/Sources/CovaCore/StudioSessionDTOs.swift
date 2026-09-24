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
/// 只有 `id` 是必需的；正文可能落在 `text` 或 `content`（契约没写），
/// 两者都取不到 ⇒ `displayText == nil`，UI **跳过这条**而不是显示空白气泡。
public struct StudioMessageDto: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String?
    public let text: String?
    public let content: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case content
        case createdAt
    }

    /// 真实响应的消息**没有 `id` 键**，时间戳叫 `timestamp` 而不是 `createdAt`
    /// （2026-09-24 真实账号实测：`{role, content, timestamp, attachments}`）。
    private enum MessageAliasKey: String, CodingKey {
        case timestamp
    }

    /// 缺 `id` 时拼一个**确定性视图标识**（角色 + 时间戳 + 正文前缀）：同一条消息每次解码
    /// 都得到同一个键，列表视图因此不会重排气泡；它只用于列表身份，**不冒充后端给过消息号**。
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
        let body = decodedText ?? decodedContent ?? ""
        let viewId = "view:\(decodedRole ?? "-"):\(ownCreated ?? aliasStamp ?? "-"):\(body.prefix(12))"
        role = decodedRole
        text = decodedText
        content = decodedContent
        createdAt = ownCreated ?? aliasStamp
        id = decodedId ?? viewId
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
        messages = decodedMessages
        generationJobs = decodedJobs
    }
}

/// `POST /api/find-my-song/sessions` 响应。契约没写信封 ⇒ 两种都接：
/// `{session:{id}}` 或 `{id}`。取不到 id 就是**失败**（不能凭空造一个会话号去开流）。
public struct StudioCreateSessionResponseDto: Decodable, Equatable, Sendable {
    public let sessionId: String

    private enum ObjectKeys: String, CodingKey {
        case session
        case id
        case sessionId
    }
    private enum SessionKeys: String, CodingKey {
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ObjectKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session),
           let id = try? nested.decode(String.self, forKey: .id) {
            sessionId = id
            return
        }
        for key in [ObjectKeys.id, ObjectKeys.sessionId] {
            if let id = try? container.decode(String.self, forKey: key) {
                sessionId = id
                return
            }
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "建会话响应里没有可用的 sessionId（NEEDS-23）"
        ))
    }
}
