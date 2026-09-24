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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ObjectKeys.self)
        session = try container.decodeIfPresent(StudioSessionDto.self, forKey: .session)
        messages = try container.decodeIfPresent([StudioMessageDto].self, forKey: .messages) ?? []
        generationJobs = try container.decodeIfPresent([GenerationJobDto].self, forKey: .generationJobs) ?? []
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
