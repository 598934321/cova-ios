import Foundation

// MARK: - 路径段（伪 id 进 URL 路径的唯一编码面）
//
// §4.7：七个端点**都接受伪 id** `{jobId}:{candidateId}`（`pending-N` 与裸 jobId 也在同一形状域里）。
// 伪 id 的分隔符就是 `:`，所以路径段的白名单**必须**含冒号 —— 用 `NoteFavoriteDto.safeSegment`
// 那种"只允许 [A-Za-z0-9_-]"的规则会把每一条合法伪 id 都拒掉（同一条规则的第二个坑）。

/// 作品/运行标识进 URL 路径段之前的**唯一**白名单校验。
///
/// 拦的是注入面：路径段直接拼进 `CovaEnvironment.makeAPIURL(path:)`，而那条腿只查
/// `?`/`#`/`\`/`.`/`..`/`%2e` —— 我们在**拼之前**就把这些挡掉，而不是依赖下游兜住。
/// 合法字符集：`[A-Za-z0-9._:-]`（含冒号，见文件头）、非空、UTF-8 字节 ≤ 200。
/// 认不出来 ⇒ `nil` = **不许发这个请求**（宁可不发，也不发出一条打到别的资源上的路径）。
public enum WorksPathEncoding {
    public static let maximumIdentifierBytes = 200

    public static func safeIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= maximumIdentifierBytes else { return nil }
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isLetter = (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            let isDigit = value >= 0x30 && value <= 0x39
            let allowed = isLetter || isDigit || value == 0x2D || value == 0x5F || value == 0x2E || value == 0x3A
            guard allowed else { return nil }
        }
        // 斜杠与百分号都不在白名单里 ⇒ 路径段逃逸与穿越在字符集那一循环就死了。
        // 剩下的是两个"整段就是一个点"的形状：它们不是 id，是相对路径语法。
        guard raw != ".", raw != ".." else { return nil }
        // 冒号是伪 id 的分隔符，而契约只有**一种**拼接式（`{jobId}:{candidateId}`）⇒ 至多一个。
        // 三段 id（`a:b:c`）服务端不会认，让它进路径就是拿一个服务端认不出的形状去赌 404。
        guard raw.split(separator: ":", omittingEmptySubsequences: false).count <= 2 else { return nil }
        return raw
    }
}

// MARK: - 三态开关（缺键 ≠ false）

/// `POST …/favorite` 的 `favorite` 与 `POST …/dislike` 的 `dislike`：一个**三态**开关。
///
/// 为什么不能用 `Bool` 或 `Bool?`（§4.7 三个坑的第①条）：
/// 服务端读的是 `body.favorite` 然后**缺省为 true** ⇒
/// · 传 `Bool`：表达不出"我要取消"和"我没决定"以外的第三种情况，且 `false` 是唯一能取消的值；
/// · 传 `Bool?` 并让 `nil` 表示"省略"：**任何一次忘了赋值都会点亮收藏**（`nil` 是可选类型的
///   零值，`XCTAssertEqual(dto.favorite, nil)` 之类的构造路径太容易悄悄走到）。
/// 本枚举把那一格写成一个**必须点名**的 case（`.omitted`），于是"整条代码路径里没有决定"
/// 这件事在源码里是可 grep 的一个词，而不是一个隐式的 nil。
public enum WorkActionToggle: Equatable, Sendable, CustomStringConvertible {
    /// 显式 `true`。
    case on
    /// 显式 `false` —— **取消收藏只能走这一格**。
    case off
    /// **不发这个键**（或发 JSON `null`）⇒ 服务端按 `true` 处理。
    ///
    /// ⚠️ 这一格的语义是"点亮"，不是"没做决定"。命名成 `omitted` 是为了让它在 diff 里显眼，
    /// 但调用方必须清楚：`WorkActionToggle.omitted.serverEffectiveState == true`。
    case omitted

    /// 服务端最终会落成的状态（`.omitted` 读作 `true` —— 这是契约事实，不是客户端的猜测）。
    public var serverEffectiveState: Bool {
        switch self {
        case .on, .omitted: return true
        case .off: return false
        }
    }

    /// 线格式：`.omitted` **不写键**（由外层 DTO 的 `encode(to:)` 实现）。
    public var booleanValue: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .omitted: return nil
        }
    }

    public var description: String {
        switch self {
        case .on: return "显式置为真"
        case .off: return "显式置为假"
        case .omitted: return "缺键（服务端按真处理）"
        }
    }

    /// 「想要某个状态」→ 该发哪一种：**只有显式要 false 才发 false**。
    /// 这一条函数的存在理由：调用方最容易写的是 `send(state)`，而 `state == true` 时
    /// 发 `.on` 与发 `.omitted` 结果相同 ⇒ 两种写法都该收敛到 `.on`（可断言、可读）。
    public static func requesting(state: Bool) -> WorkActionToggle { state ? .on : .off }
}

/// 收藏动作的请求体 `{favorite?}`。
///
/// `Codable` 双向：`encode` 证明"缺键是真的缺键"，`decode` 证明"缺键/null 都回到 `.omitted`"
/// —— 那个不对称是整条链最容易骗人的地方，两头都要能断言。
public struct WorkFavoriteRequestDto: Codable, Equatable, Sendable {
    public var favorite: WorkActionToggle

    public init(_ toggle: WorkActionToggle) {
        self.favorite = toggle
    }

    /// 服务端这一单最终落成的收藏态（**不是**"我发了什么"，是"它会做成什么"）。
    public var serverEffectiveState: Bool { favorite.serverEffectiveState }

    enum CodingKeys: String, CodingKey { case favorite }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `.omitted` ⇒ 一个键都不写（不是写 null：null 与服务端缺省等价，但形状不同、
        // 日志里也不同；契约上"不发键"才是被测过的那一条）。
        if let value = favorite.booleanValue {
            try container.encode(value, forKey: .favorite)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let value = (try? container?.decodeIfPresent(Bool.self, forKey: .favorite)) ?? nil
        favorite = value.map { $0 ? .on : .off } ?? .omitted
    }
}

/// 点踩动作的请求体 `{dislike?}`（同一个缺省陷阱：缺省为 true，且点踩会撤收藏）。
public struct WorkDislikeRequestDto: Codable, Equatable, Sendable {
    public var dislike: WorkActionToggle

    public init(_ toggle: WorkActionToggle) {
        self.dislike = toggle
    }

    public var serverEffectiveState: Bool { dislike.serverEffectiveState }

    enum CodingKeys: String, CodingKey { case dislike }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let value = dislike.booleanValue {
            try container.encode(value, forKey: .dislike)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let value = (try? container?.decodeIfPresent(Bool.self, forKey: .dislike)) ?? nil
        dislike = value.map { $0 ? .on : .off } ?? .omitted
    }
}

// MARK: - 响应

/// favorite 回执 `{ok:true, favorited:Bool}`。
public struct WorkFavoriteResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    /// 服务端回显的**权威**收藏态（本地乐观态要拿它校正）。
    public let favorited: Bool?

    enum CodingKeys: String, CodingKey { case ok, favorited }

    /// `{}` / `{ok:null}` 都**不算确认**（200 但没回执 ≠ 做成了）。
    public var isAcknowledged: Bool { ok == true }

    /// 回执是否与"这一单本来要做成什么"一致（把缺键≠false 那条陷阱变成可断言的端到端判据）。
    public func agrees(with intent: WorkActionToggle) -> Bool {
        guard let favorited else { return false }
        return favorited == intent.serverEffectiveState
    }
}

/// dislike 回执 `{ok:true, disliked:Bool}`。
public struct WorkDislikeResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let disliked: Bool?

    enum CodingKeys: String, CodingKey { case ok, disliked }

    public var isAcknowledged: Bool { ok == true }

    public func agrees(with intent: WorkActionToggle) -> Bool {
        guard let disliked else { return false }
        return disliked == intent.serverEffectiveState
    }

    /// ⚠️ 服务端 favorite 与 dislike **互斥**（点踩会撤收藏，§4.7）：
    /// 本类型**不给** `favorited` 字段，因为那一腿的权威账在列表行上（`WorksListRowDto.favorited`），
    /// 在这里补一个猜的 `false` 就是替服务端写它没写的字段（硬边界 7）。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container?.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        disliked = (try? container?.decodeIfPresent(Bool.self, forKey: .disliked)) ?? nil
    }
}

/// `POST …/note` 回执 `{ok:true, noteId:String}` —— **物化成音乐笔记**（进歌单用的那张表）。
public struct WorkNoteMaterializationDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    /// 物化出来的笔记 id（`/api/notes/:id/favorite` 与歌单入口用它）。
    public let noteId: String?

    enum CodingKeys: String, CodingKey { case ok, noteId }

    public var isAcknowledged: Bool { ok == true }
    public var resolvedNoteId: String? {
        guard let noteId, !noteId.isEmpty else { return nil }
        return noteId
    }

    /// 端点是**幂等物化**（重复点拿同一个 noteId）⇒ 本类型不接幂等键，
    /// 也不许把"拿到 noteId"当成"新建了一条"。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container?.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        noteId = (try? container?.decodeIfPresent(String.self, forKey: .noteId)) ?? nil
    }
}

/// `GET …/timing` 回执 `{ok:true, lrc:String|null}`。
///
/// ⚠️ **`lrc: null` 不是错误**（§4.4：任何失败 / 纯音乐 / 无 clip 都回 `{ok:true,lrc:null}`）
/// ⇒ 客户端回退纯文本歌词，**不许**弹一次"歌词加载失败"。
/// 载荷是歌词文本、不是凭证，所以不需要 `SecretString`（也不落日志的理由是内容不是形态）。
public struct WorkTimingResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let lrc: String?

    enum CodingKeys: String, CodingKey { case ok, lrc }

    /// 拿到可用的对齐歌词：非 nil、非空串、且不是只有空白。
    public var hasAlignedLyrics: Bool { WorksListQuery.textIfPresent(lrc) != nil }

    /// 该回退纯文本歌词（这是**正常路径**，不是降级告警）。
    public var shouldFallBackToPlainLyrics: Bool { !hasAlignedLyrics }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container?.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        lrc = (try? container?.decodeIfPresent(String.self, forKey: .lrc)) ?? nil
    }
}

/// `POST …/share` 回执 `{ok:true, sharePath}`（开或复用同一条链接）。
public struct WorkShareEnableResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    /// 站内分享路径（`/share/work/<token>`，**设计上免登录可听**）。
    ///
    /// 本层只交出原文：把它拼成绝对地址、开系统分享面板都是 UI 层的事，
    /// 而在 CovaCore 里拼一条**不是 API 出口**的 URL 就是给 D10 添第二条口径。
    /// 它是公开链接，但带令牌 ⇒ 仍按硬边界 3 不进日志。
    public let sharePath: String?

    enum CodingKeys: String, CodingKey { case ok, sharePath }

    public var isAcknowledged: Bool { ok == true }
    public var resolvedSharePath: String? { WorksListQuery.textIfPresent(sharePath) }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container?.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        sharePath = (try? container?.decodeIfPresent(String.self, forKey: .sharePath)) ?? nil
    }
}

/// `GET …/share` 回执 `{enabled, sharePath}` —— **没有 `ok` 这一键**，
/// 所以不复用 `WorkShareEnableResponseDto`（复用就是让两个端点的形状混成一个，字段永远对不上）。
public struct WorkShareStatusResponseDto: Decodable, Equatable, Sendable {
    public let enabled: Bool?
    public let sharePath: String?

    enum CodingKeys: String, CodingKey { case enabled, sharePath }

    /// 分享态。`enabled` 缺席/读不出 ⇒ `.unknown` —— **不许**默认成"没开"：
    /// 那一格会画出"开启分享"的钮，而它其实可能已经开着。
    public var state: WorkShareState {
        guard let enabled else { return .unknown }
        return enabled ? .on : .off
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container?.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        sharePath = (try? container?.decodeIfPresent(String.self, forKey: .sharePath)) ?? nil
    }
}

public enum WorkShareState: Equatable, Sendable {
    case on
    case off
    /// 服务端没给可判的形状（契约漂移，或该作品从来没开过分享）。
    case unknown
}

/// `DELETE …/share` 与 `DELETE …/works/{id}` 的共用回执 `{ok:true}`。
///
/// 两个端点都是**幂等收尾**：关分享**保留令牌**（可重开），删作品是软删
/// （`metadata.deletedAt`，§4.4）⇒ 本类型不建模"永久删除"，也不许把 DELETE 成功读成"再也找不回"。
public struct WorkActionAcknowledgementDto: Decodable, Equatable, Sendable {
    public let ok: Bool?

    enum CodingKeys: String, CodingKey { case ok }

    public var isAcknowledged: Bool { ok == true }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container?.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
    }
}

// MARK: - 改名

/// `PATCH …/works/{id}` 的请求体 `{title}`（服务端要求 1–200 字）。
///
/// ⚠️ **`PATCH`/`DELETE`/`share` 是 job 级不是行级**（§4.7 第②条）：一次生成两行共用同一个
/// jobId ⇒ 改一行的标题等于改两行。本类型无法在 DTO 层阻止这件事（端点就这样），
/// 所以把事实写在名字上：见 `WorkActionRoute.isJobScoped`。
public struct WorkRenameRequestDto: Codable, Equatable, Sendable {
    /// 服务端上限（§4.4 `title≤200`）。
    public static let titleMaximumLength = 200
    public static let titleMinimumLength = 1

    public let title: String

    /// 本地先拦（不发请求就挡下一次 400，与 `StudioCreateGenerateRequestDto` 同一做法）。
    public init(title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkActionRequestError.emptyTitle }
        guard trimmed.count <= Self.titleMaximumLength else {
            throw WorkActionRequestError.titleTooLong(limit: Self.titleMaximumLength, actual: trimmed.count)
        }
        self.title = trimmed
    }

    enum CodingKeys: String, CodingKey { case title }
}

/// 改名请求的本地校验失败（**没发出去**就拦下）。
public enum WorkActionRequestError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyTitle
    case titleTooLong(limit: Int, actual: Int)
    /// 伪 id 形状不认识（空/非法字符/超长）⇒ 请求**不该发出**。
    case unsafeWorkIdentifier

    public var description: String {
        switch self {
        case .emptyTitle: return "标题为空"
        case .titleTooLong(let limit, let actual): return "标题过长（\(actual) > \(limit)）"
        case .unsafeWorkIdentifier: return "作品标识不能安全进 URL 路径"
        }
    }
}

/// `PATCH …/works/{id}` 回执 `{ok:true, work:<行>}`（权威回读那一行）。
public struct WorkRenameResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let work: WorksListRowDto?
    /// `work` 键**在**却读不出身份 ⇒ true。这一格必须可见：
    /// 「服务端说改好了，而它给回的那行我们认不出是哪一首」不能被读成"改好了但没数据"。
    public let workPresentButUnreadable: Bool

    enum CodingKeys: String, CodingKey { case ok, work }

    public var isAcknowledged: Bool { ok == true }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? root.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        let row = (try? root.decodeIfPresent(WorksListRowDto.self, forKey: .work)) ?? nil
        work = row
        // 「键在 + 不是 null + 解不出来」才是不可读；显式 `work: null` 是"没给行"，不是"给了读不出的行"。
        let keyPresent = root.contains(CodingKeys.work)
        let isNull = keyPresent ? ((try? root.decodeNil(forKey: .work)) ?? true) : true
        workPresentButUnreadable = row == nil && keyPresent && !isNull
    }
}

// MARK: - 端点表

/// 作品行内动作的**七个端点**（§4.7：都接受伪 id `{jobId}:{candidateId}`）。
///
/// 把"路径怎么拼"收成一处有两个理由：① 伪 id 里带冒号，任何一处手拼都会顺手写出
/// "把冒号当分隔符再切一遍"的第三种解释；② `CovaFeature` 侧的服务类不该各写一份路径模板
/// （本仓反复复发的缺陷族就是同一个判定写两遍、其中一遍漏改，见 min-2）。
public enum WorkActionRoute: String, Equatable, Sendable, CaseIterable {
    case favorite
    case dislike
    case note
    case timing
    case shareOpen
    case shareStatus
    case shareClose
    case rename
    case delete

    public static let worksPath = "/api/studio/create/works"

    /// 该动作发的方法。
    public var method: HTTPMethod {
        switch self {
        case .favorite, .dislike, .note, .shareOpen: return .post
        case .timing, .shareStatus: return .get
        case .shareClose, .delete: return .delete
        case .rename: return .patch
        }
    }

    /// 这一支是 **job 级**（改一行等于改两行）还是**行级**。§4.7 第②条的落点。
    ///
    /// UI 必须按这一条交代后果：对 job 级动作说"已重命名这一首"就是在说谎，
    /// 同一次生成的另一行标题也跟着变了。
    public var isJobScoped: Bool {
        switch self {
        case .rename, .delete, .shareOpen, .shareStatus, .shareClose: return true
        case .favorite, .dislike, .note, .timing: return false
        }
    }

    /// 子路径（`rename`/`delete` 打在作品本身上，没有子段）。
    public var subpath: String? {
        switch self {
        case .favorite: return "favorite"
        case .dislike: return "dislike"
        case .note: return "note"
        case .timing: return "timing"
        case .shareOpen, .shareStatus, .shareClose: return "share"
        case .rename, .delete: return nil
        }
    }

    /// 完整路径；伪 id 不安全 ⇒ `nil`（**不发**，见 `WorksPathEncoding`）。
    public func path(workID: String) -> String? {
        guard let identifier = WorksPathEncoding.safeIdentifier(workID) else { return nil }
        let base = Self.worksPath + "/" + identifier
        guard let subpath else { return base }
        return base + "/" + subpath
    }

    /// 带身份校验的路径（失败给出**原因**而不是 `nil`，让调用方能如实报错）。
    public func validatedPath(workID: String) throws -> String {
        guard let path = path(workID: workID) else { throw WorkActionRequestError.unsafeWorkIdentifier }
        return path
    }
}

// MARK: - 错误

/// 非 2xx 的响应体 `{error: String}`（favorite / dislike / note / timing 四条腿都是这一形状，
/// 服务端把 thrown 的 status 直接给到客户端，**没有** `code` 键）。
public struct WorkActionErrorDto: Decodable, Equatable, Sendable {
    public let error: String?

    enum CodingKeys: String, CodingKey { case error }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        error = (try? container?.decodeIfPresent(String.self, forKey: .error)) ?? nil
    }
}

/// 行内动作的失败分诊（与 `StudioCreateRejection` 同一族判据：**屏上无英文码**、
/// **不编"未知错误"**、400/409 透传服务端中文原文）。
public enum WorkActionRejection: Equatable, Sendable {
    /// 401/403：交给登录态处理，不在这里编话术。
    case unauthenticated
    /// 404：作品不存在（或已软删；extras 那条腿的原文是「作品不存在」）。
    case workNotFound(serverMessage: String?)
    /// 409：`作品尚未生成完成，暂不能执行此操作` —— 音频还没物化（§4.7）。
    ///
    /// 这一档**不是**用户做错了什么：行还在生成中，动作发早了。UI 该说"还在做"，不该说"失败"。
    case notMaterialisedYet(serverMessage: String?)
    /// 400：请求本身不被接受（如 `title` 空/超长）。
    case invalidRequest(serverMessage: String?)
    /// 429：限流（favorite/dislike 120/分、note/timing 60/分）。
    case rateLimited(serverMessage: String?)
    /// 其余状态码。
    case server(statusCode: Int, serverMessage: String?)

    /// 上屏文案。
    public var userMessage: String {
        switch self {
        case .unauthenticated:
            return "登录状态已过期"
        case .workNotFound(let message):
            return Self.human(message) ?? "这首作品已经不在了"
        case .notMaterialisedYet(let message):
            return Self.human(message) ?? "还在制作中，做完才能做这一步"
        case .invalidRequest(let message):
            return Self.human(message) ?? "这一步没被接受（服务端未说明原因）"
        case .rateLimited(let message):
            return Self.human(message) ?? "操作太频繁了，稍后再试"
        case .server(let statusCode, let message):
            return Self.human(message) ?? "服务端错误（\(statusCode)）"
        }
    }

    /// 「裸码形状不透传」这一条闸**复用** `StudioCreateRejection.human`（同一个判据写两份
    /// 是本仓反复复发的缺陷族，min-2 就是这么来的）。
    static func human(_ message: String?) -> String? { StudioCreateRejection.human(message) }

    /// 状态码 + 响应体 → 分诊。`ok:false` 那类 200 由调用方按各自 DTO 的 `isAcknowledged` 判，
    /// 不在这里混成一锅（200 与 4xx 的处置方式不同：一个要回读权威态，一个要说人话）。
    public static func classify(statusCode: Int, body: Data?) -> WorkActionRejection {
        let envelope = body.flatMap {
            try? JSONDecoder().decode(WorkActionErrorDto.self, from: $0)
        }
        switch statusCode {
        case 401, 403:
            return .unauthenticated
        case 400:
            return .invalidRequest(serverMessage: envelope?.error)
        case 404:
            return .workNotFound(serverMessage: envelope?.error)
        case 409:
            return .notMaterialisedYet(serverMessage: envelope?.error)
        case 429:
            return .rateLimited(serverMessage: envelope?.error)
        default:
            return .server(statusCode: statusCode, serverMessage: envelope?.error)
        }
    }
}
