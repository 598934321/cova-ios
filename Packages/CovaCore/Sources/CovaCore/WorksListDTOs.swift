import Foundation

// MARK: - 参数：filter / sort / cursor / limit
//
// 契约事实源：DEVELOPMENT.md §4.7「works 列表」实测卡（2026-09-26 逐条打生产 +
// 逐行读 `../web`），口径高于 §4.4 那段旧写法。一句话版本：
// `GET /api/studio/create/works`（**不带 `id`**）⇒ `{works, nextCursor, total}`，
// 参数**只有** `q` / `filter` / `sort` / `cursor` / `limit` 五个；
// **没有** `status` / `offset` / `page` / `source` ⇒ 本文件不为它们建模，也不发那些键。

/// `filter` 的闭合 9 值（服务端读的就是这几个字面量）。
///
/// 为什么是闭集而不是 `String`：未知值服务端**当成 `all`**（§4.7），也就是说一个拼错的
/// 筛选不会报错、只会**静默变成"全部"**——那是最难查的缺陷（屏上写着「我喜欢」而列表给的是全量）。
/// 闭集把这件事变成编译期问题（与 A2 对 `PlayReportSource` 的判据同族）。
public enum WorksListFilter: String, Equatable, Sendable, CaseIterable, Identifiable {
    case all
    case generating
    case vocal
    case instrumental
    case liked
    case disliked
    case cover
    case extend
    case remaster

    public var id: String { rawValue }

    /// 发给服务端的拼写（就是 `rawValue`，没有任何"客户端别名"）。
    public var queryValue: String { rawValue }

    /// 未知值 → `all` 是**服务端**的行为，不是客户端的兜底：本函数只给「从外部字符串
    /// 恢复选择态」（深链/回显）用，认不出来时如实回 `.all` 并让调用方知道（`isRecognized`）。
    public static func recognized(_ raw: String?) -> WorksListFilter? {
        guard let raw else { return nil }
        return WorksListFilter(rawValue: raw)
    }
}

/// `sort` 的两值（`newest` 是服务端默认）。
public enum WorksListSort: String, Equatable, Sendable, CaseIterable, Identifiable {
    case newest
    case oldest

    public var id: String { rawValue }
    public var queryValue: String { rawValue }

    public static func recognized(_ raw: String?) -> WorksListSort? {
        guard let raw else { return nil }
        return WorksListSort(rawValue: raw)
    }
}

/// `cursor`：服务端 v1 的实现是**字符串化的行偏移**（§4.7 明写「不是不透明游标」）。
///
/// 两件事必须同时成立，所以本类型把"原样带走"和"能读成数字"分开：
/// · `rawValue` 是**上一轮 `nextCursor` 的原文**，回发时一个字都不改 —— 服务端换成真游标
///   时客户端不必跟着改（换了会坏，而坏法是静默少页，不是报错）；
/// · `rowOffset` 只是**今天**能读出来的诊断值，**不许**当分页正确性的判据、也不许用它
///   自己算下一页（那是客户端在服务端的账本上做算术）。
public struct WorksListCursor: Equatable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// 空串不是游标（服务端读的是「有没有这个键」）；纯空白同样拒。
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    /// 今天读得出来的行偏移；不是十进制整数就是 `nil`（**不猜**）。
    public var rowOffset: Int? { Int(rawValue) }

    /// 只回显偏移这一个数字，避免日志里出现"游标"这种词被当成服务端状态。
    public var description: String { "cursor(\(rawValue))" }

    /// 服务端 `nextCursor` → 下一页游标；`null` / 空 ⇒ `nil` = **到底了**。
    public static func next(_ rawValue: String?) -> WorksListCursor? {
        guard let rawValue else { return nil }
        return WorksListCursor(rawValue)
    }
}

// MARK: - 请求构造（纯函数，输出就是发出去的查询串）
//
// 与 `LibraryFilter.swift` 同一套做法的理由一样：编码散在 View 里就没人能断言它。
// E3a 那次「客户端发 `dimension=`/`term=`，服务端一个都不读」是同一类事故，而 works 这一条
// 更阴 —— 参数名错了不报错，只是筛选静默失效（§4.7 那 9 个 filter 值里认不出的当 `all`）。

/// `GET /api/studio/create/works` 的**分页读**请求（不带 `id` 那一支）。
///
/// ⚠️ 本类型**不建模 `id`**：`?id=<jobId 或 jobId:candidateId>` 是"详情轮询"的另一条腿，
/// 已落在 `StudioCreateService.works(id:)`（本仓现有事实源），这里再写一份就是两条口径。
public struct WorksListQuery: Equatable, Sendable {
    /// 端点路径（同源相对，交给 `CovaEnvironment.makeAPIURL` 钉 host）。
    public static let path = "/api/studio/create/works"

    /// `limit` 的三件套（§4.7：夹在 1..100，默认 30）。
    public static let defaultLimit = 30
    public static let minimumLimit = 1
    public static let maximumLimit = 100

    public var filter: WorksListFilter
    /// `q`：服务端做的是 **title / lyrics / tags 的子串匹配**（不是分词、不是相关性）。
    public var search: String?
    public var sort: WorksListSort
    public var cursor: WorksListCursor?
    /// 构造期就夹进服务端窗口（§4.7），于是 `queryItems` 永远发一个服务端认的值。
    public var limit: Int

    public init(
        filter: WorksListFilter = .all,
        search: String? = nil,
        sort: WorksListSort = .newest,
        cursor: WorksListCursor? = nil,
        limit: Int = WorksListQuery.defaultLimit
    ) {
        self.filter = filter
        self.search = search
        self.sort = sort
        self.cursor = cursor
        self.limit = Self.clamped(limit)
    }

    static func clamped(_ value: Int) -> Int {
        min(max(value, minimumLimit), maximumLimit)
    }

    /// 去空白后为空 ⇒ `nil`（**不发 `q=` 这种空值键**：空串在服务端是"匹配一切"还是"匹配空"
    /// 不由客户端决定，而"同一选择 = 同一地址"这条不变量也不该被一个空键劈成两半）。
    ///
    /// 本批次（P1/P2 那六个 DTO 文件）里所有"服务端可空的文本"都走这一条函数——
    /// 空白文本一律读成"没给"、**不**回落成空串也**不**编占位文案。同一个判据写第二遍
    /// 是本仓反复复发的缺陷族（min-2），所以 extras / producers / ledger / agent-run
    /// 那几处直接复用它，而不是各写一份 trim。
    public static func textIfPresent(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 编码后的选择态（`search` 已归一，比较与断言都读这一个值而不是读原始入参）。
    public var normalizedSearch: String? { Self.textIfPresent(search) }

    /// 查询项，顺序固定为契约卡列出的 `q / filter / sort / cursor / limit`。
    ///
    /// `filter` / `sort` / `limit` **恒发**（三者各自有一个服务端认识的合法值，写出来就自描述，
    /// 也让「同一选择 = 同一地址」在 URL 层面可断言）；`q` / `cursor` **缺位不发键**。
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let search = normalizedSearch {
            items.append(URLQueryItem(name: "q", value: search))
        }
        items.append(URLQueryItem(name: "filter", value: filter.queryValue))
        items.append(URLQueryItem(name: "sort", value: sort.queryValue))
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor.rawValue))
        }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        return items
    }

    /// 下一页请求（同一选择 + 服务端给的 `nextCursor`）。
    /// `nextCursor` 为 `null` ⇒ 返回 `nil`：**到底了，不许用同一个 cursor 再发一次**
    /// （服务端是行偏移，重复发同一偏移只会把同一页再拿一遍）。
    public func advanced(toNextCursor rawValue: String?) -> WorksListQuery? {
        guard let cursor = WorksListCursor.next(rawValue) else { return nil }
        var next = self
        next.cursor = cursor
        return next
    }
}

// MARK: - 行 id 的四种形状

/// 作品行 `id` 的形状（§4.7：四种形状都必须**原样保留**）。
///
/// 拆分只用于**读**（判占位行、按 job 归组、拼行内动作的落点），
/// 本仓从不拿它反向拼 `id` 上屏 —— `WorksListRowDto.id` 才是服务端给的那个字符串。
public enum WorksRowIdentity: Equatable, Sendable {
    /// `{jobId}:{candidateId}` —— 一行的正身（可上报、可行内动作）。
    case candidate(jobID: String, candidateID: String)
    /// `{jobId}:pending-N` —— **生成中的占位行**，没有音频，不能当作品播/存。
    case pendingPlaceholder(jobID: String, ordinal: String)
    /// 裸 `{jobId}` —— 服务端接受（`play-history.ts:50` 的 `jobExists` 那一支），
    /// 但那种行可能因取不到候选音频而在别处被整行丢弃 ⇒ 能显示、**不能播**。
    case bareJobID(jobID: String)
    /// 以上都不是（三段、空段、未来新形状）。**不丢、不改写**：原 id 仍然在行上，
    /// 只是本层拒绝给一个它认不出的形状编语义（认出来是 `.irregular` 比猜成 candidate 好）。
    case irregular(rawID: String)

    /// 用本仓既有的伪 trackId 面拆（`StudioCreateWorkIdentifier` —— 同一个规则不许有第二份）。
    public init(rawID: String) {
        guard let split = StudioCreateWorkIdentifier.split(rawID) else {
            self = .irregular(rawID: rawID)
            return
        }
        guard let candidateID = split.candidateId else {
            self = .bareJobID(jobID: split.jobId)
            return
        }
        guard StudioCreateWorkIdentifier.isPendingPlaceholder(candidateId: candidateID),
              let ordinal = Self.pendingOrdinal(candidateID) else {
            self = .candidate(jobID: split.jobId, candidateID: candidateID)
            return
        }
        self = .pendingPlaceholder(jobID: split.jobId, ordinal: ordinal)
    }

    /// `pending-` 后面的序号（`pending` 本身 / `pending-` 空序号 ⇒ `nil` ⇒ 落 `.candidate`，
    /// 因为那种值不是契约里的占位形态，本层不给它编一个"第几个"）。
    static func pendingOrdinal(_ candidateID: String) -> String? {
        let prefix = "pending-"
        guard candidateID.hasPrefix(prefix) else { return nil }
        let tail = candidateID.dropFirst(prefix.count)
        return tail.isEmpty ? nil : String(tail)
    }

    public var jobID: String? {
        switch self {
        case .candidate(let job, _), .pendingPlaceholder(let job, _), .bareJobID(let job): return job
        case .irregular: return nil
        }
    }

    public var candidateID: String? {
        switch self {
        case .candidate(_, let candidate), .pendingPlaceholder(_, let candidate): return candidate
        case .bareJobID, .irregular: return nil
        }
    }

    /// 只有正身候选行才能当一首作品用（播、存、上报、行内动作）。
    public var isRealCandidateRow: Bool {
        if case .candidate = self { return true }
        return false
    }
}

// MARK: - 行

/// `GET /api/studio/create/works` 的一行（clip 打平：一行 = 一首），契约全键集。
///
/// 键集实测 §4.4 + §4.7 + `web/src/app/studio/components/create/types.ts`：
/// `id/jobId/title/coverUrl/audioUrl/duration/status/tags/lyrics/modelVersion/instrumental/
/// voiceName/errorMessage/createdAt/source/providerClipId` 恒有键（值可为 `null`），
/// `playbackUrl/melody/operation/favorited/disliked` **只在有意义时出现**。
///
/// 与既有 `CreateWorkItemDto`（`StudioCreateDTOs.swift`，P0 最小读回那一支）的关系要说清：
/// 本类型是**分页列表**的完整契约行（多了 `tags/lyrics/modelVersion/voiceName/source/melody/
/// operation/favorited/disliked` 这八个 P0 没建的键）。两者并存是**分端点、分投影**，
/// 不是同一件事写两遍；等 P1 的 19 屏改造把两条腿并成一个调用点时该收敛成一个，
/// 但那要改既有文件（本轮的文件域只允许新建）。
///
/// TD-23 口径：`audioUrl` / `playbackUrl` / `melody` 收口 `SecretString`，且本类型
/// **仅 `Decodable`** —— 编译期不给"把签名串序列化进持久化索引"留通路（硬边界 3）。
public struct WorksListRowDto: Decodable, Equatable, Sendable {
    /// 服务端原样给的那串 id（四种形状之一，见 `WorksRowIdentity`）。**永不改写。**
    public let id: String
    public let jobId: String?
    public let title: String?
    /// 封面：**公开读桶的直链**（§CovaEnvironment 名单里的 covers 桶），不是签名串 ⇒ 不套 `SecretString`。
    public let coverUrl: String?
    /// 站内**相对**同源路径（生产实测形态 `/api/media/objects/mo_…?ref=mr_…&intent=play`，
    /// 2026-09-26 `GET /api/studio/create/works?limit=6` 6/6 行同形）。
    /// 本端播放只吃这一条：Bearer 下载 → 校验非空 → `file://`（硬边界 6/D7），
    /// 直存走 `CovaEnvironment.workAudioDirectFetchURL` 的 `intent=download` 那一腿。
    public let audioUrl: SecretString?
    /// 免 Authorization 的**预签名 COS 绝对直链**（桶 `covalink-uploads-…`，TTL 900s）。
    ///
    /// ⚠️ **在 iOS 上不可用**（§7 #37）：D23 的存储名单只有 `covers` 与 `audio` 两个桶，
    /// uploads 是用户私产桶、**刻意不在名单里** ⇒ 出口守卫按主机名点名拒掉
    /// （`CovaEnvironment.mediaHopEgress` → `.refused`，`WorkDownloadStoreTests` 钉的就是这条）。
    /// 于是它既不能播（§4.4 那句「App 后台播控必须用它」在本端不成立）也不能直存，
    /// 只在"名单一放宽就自动可用"的意义上保留 —— 因此**只建模、不提供任何 URL 出口**，
    /// 也不许把它拼进 `URL` 交给播放器。客户端不许自己放宽名单（D23②）。
    public let playbackUrl: SecretString?
    public let duration: Double?
    /// 与 `GenerationJobStatus` 完全同集（`schema.ts:58`）⇒ 复用同一个枚举（A15 术语唯一源）；
    /// 认不出的状态值解成 `nil`，**不**把它读成 `failed`。
    public let status: GenerationJobStatus?
    /// 服务端**恒给键**、值可为 `null` ⇒ `nil`（没标签）与 `[]`（标签为空）是两件事，不合并。
    public let tags: [String]?
    public let lyrics: String?
    public let modelVersion: String?
    public let instrumental: Bool?
    public let voiceName: String?
    public let errorMessage: String?
    public let createdAt: String?
    /// 来源（`studio-create` / `one-step` / `song-match`）。**刻意是松散 `String?`**
    /// （与 `PlayHistoryItemDto.source` 同一条理由）：新增来源值不许把整行判成读不出来。
    public let source: String?
    /// 哼唱素材：**本端不消费**（melody 模式是 P1 的表单，§4.7 明写 `melody` 不是 generate 入参、
    /// 由服务端按 `mode` 写进 metadata）。形态（站内 id 还是地址）未在生产逐行实测钉死，
    /// 而它**有可能是签名地址** ⇒ 收口 `SecretString` 走保守方向：宁可名字叫 secret，
    /// 也不让一个未定形态的串在日志/反射里裸奔。
    public let melody: SecretString?
    public let operation: StudioCreateOperation?
    public let providerClipId: String?
    /// ⚠️ **缺键即 `false` 是服务端行为**，不是客户端填的默认值（§4.7 原话：
    /// 「`favorited`/`disliked` 为 false 时服务端整个键都不发」）。
    /// 于是"这个键在不在"根本不能用来区分 false 与"未知"——服务端已经把这两件事编码成同一件事了。
    /// 显式 `true` 才是唯一带信息量的形态；非布尔的值（漂移信号）同样落 `false`，
    /// 但由下面的 `signalShapeDrift` 把"读不出布尔"这件事留一个可见面。
    public let favorited: Bool
    public let disliked: Bool
    /// `favorited`/`disliked` 两个键**出现过非布尔值**的行内标记（形状漂移，不是用户信号）。
    public let signalShapeDrift: Bool

    enum CodingKeys: String, CodingKey {
        case id, jobId, title, coverUrl, audioUrl, playbackUrl, duration, status, tags, lyrics
        case modelVersion, instrumental, voiceName, errorMessage, createdAt, source, melody
        case operation, providerClipId, favorited, disliked
    }

    init?(from wire: WorksListRowWireDto) {
        guard let id = wire.id, !id.isEmpty else { return nil }
        self.id = id
        self.jobId = wire.jobId
        self.title = wire.title
        self.coverUrl = wire.coverUrl
        self.audioUrl = wire.audioUrl
        self.playbackUrl = wire.playbackUrl
        self.duration = wire.duration
        self.status = wire.status
        self.tags = wire.tags
        self.lyrics = wire.lyrics
        self.modelVersion = wire.modelVersion
        self.instrumental = wire.instrumental
        self.voiceName = wire.voiceName
        self.errorMessage = wire.errorMessage
        self.createdAt = wire.createdAt
        self.source = wire.source
        self.melody = wire.melody
        self.operation = wire.operation
        self.providerClipId = wire.providerClipId
        self.favorited = wire.favorited ?? false
        self.disliked = wire.disliked ?? false
        self.signalShapeDrift = wire.favoritedShapeDrift || wire.dislikedShapeDrift
    }

    /// 单行端点用的严格腿：读不出 `id` ⇒ **抛**（`PATCH …/works/{id}` 的 200 里带着一行
    /// 却认不出身份，那是契约破坏，不该被读成"改好了但没数据"）。
    /// 分页数组走 `WorksPageDto` 的逐行容错腿，两者共用同一个不可抛的 wire 类型。
    public init(from decoder: Decoder) throws {
        let wire = try WorksListRowWireDto(from: decoder)
        guard let row = WorksListRowDto(from: wire) else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "作品行没有可用的 id（宁可报错，不画一行没有身份的作品）"
            )
        }
        self = row
    }

    // MARK: 派生事实

    public var identity: WorksRowIdentity { WorksRowIdentity(rawID: id) }

    /// `{jobId}:pending-N` 占位行（没有音频，不能播/存/上报）。
    public var isPendingPlaceholder: Bool {
        if case .pendingPlaceholder = identity { return true }
        return false
    }

    /// 能不能播：**终态成功 + 不是占位行 + 有 `audioUrl`**。
    ///
    /// 判据里**没有** `playbackUrl` —— 不是漏了，是它在 D23 下今天就走不通（见属性文档）。
    /// 放行与否最终仍由出口守卫裁决；本属性只报告"有没有一条本端认的腿"。
    public var isPlayable: Bool {
        guard status == .succeeded, !isPendingPlaceholder else { return false }
        return audioUrl != nil
    }

    /// 只有正身候选行才能拿去上报 / 行走内动作。
    public var isRealCandidateRow: Bool { identity.isRealCandidateRow }

    /// `audioUrl` → 可出站绝对地址（同源相对路径由 `CovaEnvironment.resolveMediaURL`
    /// 钉死生产 host）。读不出合法同源形态 ⇒ `nil`（**不猜 host**）。
    public var resolvedAudioURL: URL? {
        audioUrl.flatMap { CovaEnvironment.resolveMediaURL($0.rawValue) }
    }

    /// 上屏标题：空串与纯空白都当"没标题"（不是"标题是一个空格"）。
    /// 占位文案（「未命名作品」）在 UI 层，不在 DTO 里编（19 §3.E）。
    public var displayTitle: String? {
        guard let title = WorksListQuery.textIfPresent(title) else { return nil }
        return title
    }

    /// 时长：只有**正的有限值**才算有时长（`0` 在服务端是"还没分析"，不是"零秒"；
    /// 与 `NoteFavoriteDto.displayDuration` 同口径）。
    public var displayDuration: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// favorite 与 dislike **服务端互斥**（点踩会撤收藏，§4.7）。
    /// 两个同时为真只能是形状漂移 ⇒ 本行**不猜**该显示哪一个，交给上层如实报错而不是画一个。
    public var signalConflict: Bool { favorited && disliked }
}

/// 不可抛的**线格式行**（数组解码的承重墙）。
///
/// 一个元素抛错 ⇒ Swift 的数组解码把**整页**判失败 ⇒ 用户看到的是"作品列表空"，
/// 而真相当次是第 3 行的 `duration` 是个字符串。这正是 `PlayHistoryTrackDto` 已经踩过的坑
/// （`PlayHistoryDTOTests.testLibraryTrackDtoCannotDecodeTheWorkProjection` 自证的那堵墙）。
/// 所以每个字段各自 `try?`：一行的形状不对只让**这一行**降级，不连累同批其它行。
public struct WorksListRowWireDto: Decodable, Equatable, Sendable {
    public let id: String?
    public let jobId: String?
    public let title: String?
    public let coverUrl: String?
    public let audioUrl: SecretString?
    public let playbackUrl: SecretString?
    public let duration: Double?
    public let status: GenerationJobStatus?
    public let tags: [String]?
    public let lyrics: String?
    public let modelVersion: String?
    public let instrumental: Bool?
    public let voiceName: String?
    public let errorMessage: String?
    public let createdAt: String?
    public let source: String?
    public let melody: SecretString?
    public let operation: StudioCreateOperation?
    public let providerClipId: String?
    /// `nil` 有三种来路（键缺席 / 显式 `null` / 值不是布尔）—— 前两种在服务端都是 `false`，
    /// 第三种由下面的 `*ShapeDrift` 标记区分出来，落到 `WorksListRowDto.signalShapeDrift`。
    public let favorited: Bool?
    public let disliked: Bool?
    /// **键在、值不是 null、却读不出布尔** ⇒ true（契约形状漂移；把它读成 `false` 是静默说谎）。
    public let favoritedShapeDrift: Bool
    public let dislikedShapeDrift: Bool

    enum CodingKeys: String, CodingKey {
        case id, jobId, title, coverUrl, audioUrl, playbackUrl, duration, status, tags, lyrics
        case modelVersion, instrumental, voiceName, errorMessage, createdAt, source, melody
        case operation, providerClipId, favorited, disliked
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        jobId = (try? container?.decodeIfPresent(String.self, forKey: .jobId)) ?? nil
        title = (try? container?.decodeIfPresent(String.self, forKey: .title)) ?? nil
        coverUrl = (try? container?.decodeIfPresent(String.self, forKey: .coverUrl)) ?? nil
        audioUrl = (try? container?.decodeIfPresent(SecretString.self, forKey: .audioUrl)) ?? nil
        playbackUrl = (try? container?.decodeIfPresent(SecretString.self, forKey: .playbackUrl)) ?? nil
        duration = (try? container?.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
        status = (try? container?.decodeIfPresent(GenerationJobStatus.self, forKey: .status)) ?? nil
        tags = (try? container?.decodeIfPresent([String].self, forKey: .tags)) ?? nil
        lyrics = (try? container?.decodeIfPresent(String.self, forKey: .lyrics)) ?? nil
        modelVersion = (try? container?.decodeIfPresent(String.self, forKey: .modelVersion)) ?? nil
        instrumental = (try? container?.decodeIfPresent(Bool.self, forKey: .instrumental)) ?? nil
        voiceName = (try? container?.decodeIfPresent(String.self, forKey: .voiceName)) ?? nil
        errorMessage = (try? container?.decodeIfPresent(String.self, forKey: .errorMessage)) ?? nil
        createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        source = (try? container?.decodeIfPresent(String.self, forKey: .source)) ?? nil
        melody = (try? container?.decodeIfPresent(SecretString.self, forKey: .melody)) ?? nil
        operation = (try? container?.decodeIfPresent(StudioCreateOperation.self, forKey: .operation)) ?? nil
        providerClipId = (try? container?.decodeIfPresent(String.self, forKey: .providerClipId)) ?? nil
        favorited = (try? container?.decodeIfPresent(Bool.self, forKey: .favorited)) ?? nil
        disliked = (try? container?.decodeIfPresent(Bool.self, forKey: .disliked)) ?? nil
        favoritedShapeDrift = Self.shapeDrift(container: container, key: .favorited, value: favorited)
        dislikedShapeDrift = Self.shapeDrift(container: container, key: .disliked, value: disliked)
    }

    /// 「键在、值非 null、却读不出布尔」的判定（缺键与显式 `null` 都不算漂移：
    /// §4.7 明写 false 时服务端整个键都不发，那两种缺席在语义上都是 `false`）。
    static func shapeDrift(
        container: KeyedDecodingContainer<CodingKeys>?,
        key: CodingKeys,
        value: Bool?
    ) -> Bool {
        guard let container, container.contains(key) else { return false }
        let isNull = (try? container.decodeNil(forKey: key)) ?? true
        return !isNull && value == nil
    }
}

// MARK: - 分页响应

/// `GET /api/studio/create/works`（不带 `id`）的响应：`{works, nextCursor, total}`。
///
/// 实测（2026-09-26，`limit=6`）：`WORKS 6 nextCursor "6" total 8`
/// ⇒ `nextCursor` 是**字符串**不是数字；`total` 是**整表条数**不是本页行数。
/// `Cache-Control: no-store` ⇒ 列表不能靠 HTTP 缓存"自己一致"，一致性只有轮询对账那一条腿。
///
/// **逐行容错**：读不出身份的行不计入 `works`，而是计入 `unreadableItemCount`
/// —— 既不让一行坏数据毁掉整页，也不把"少了几行"藏成一个看不见的差值
/// （与 `PlayHistoryPageDto` 同一套账，`total` 与 `works.count + unreadableItemCount`
/// 的关系因此可解释；注意服务端 `total` 计的是**整表**，两者本来就不该相等）。
///
/// **不去重**：§4.7 明写"同一 job 两行共用 id 前缀"，而行 `id` 也可能整串重复
/// （裸 jobId 行与它的候选行并存）⇒ 本层**原样保留顺序与条数**，不拿 `id` 当唯一键。
public struct WorksPageDto: Decodable, Equatable, Sendable {
    public let works: [WorksListRowDto]
    /// 下一页游标原文；`null` = 到底了。
    public let nextCursor: String?
    /// 整表条数（**不是**本页行数）。
    public let total: Int?
    /// `works` 数组里读不出身份的元素个数（非对象、无 `id`、`id` 为空串）。
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey {
        case works, nextCursor, total
    }

    public init(
        works: [WorksListRowDto], nextCursor: String?, total: Int?, unreadableItemCount: Int
    ) {
        self.works = works
        self.nextCursor = nextCursor
        self.total = total
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        nextCursor = (try? root.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        total = (try? root.decodeIfPresent(Int.self, forKey: .total)) ?? nil
        // 整个 `works` 键读不出来（不是数组，比如服务端 500 时回了一个字符串）⇒ 抛，
        // 不静默当空列表：空列表在 19 屏是"你还没有作品"，那是另一个意思（§4.7 + StudioSession
        // 那条"容忍与撒谎的分界"同源）。
        // 元素类型给成 Optional：Swift 的数组解码遇到元素 `null` 会在调用元素 init **之前**
        // 就抛 ⇒ 非 Optional 的话，中台回一个 null 元素就能把整页作品判死（读成"你还没有作品"）。
        let wire = try root.decode([WorksListRowWireDto?].self, forKey: .works)
        var rows: [WorksListRowDto] = []
        var unreadable = 0
        rows.reserveCapacity(wire.count)
        for element in wire {
            if let element, let row = WorksListRowDto(from: element) {
                rows.append(row)
            } else {
                unreadable += 1
            }
        }
        works = rows
        unreadableItemCount = unreadable
    }

    /// 可播的正身作品行（占位行与未成功的行不进结果区，19 §3.E）。
    public var playableWorks: [WorksListRowDto] { works.filter(\.isPlayable) }

    /// 生成中的占位行（渲染"制作中"骨架，不能播）。
    public var placeholderWorks: [WorksListRowDto] { works.filter(\.isPendingPlaceholder) }

    /// 到底了（服务端没给下一页游标）。**没有** nextCursor 不等于"只有一页"，
    /// 只等于"服务端没给下一页的入口"。
    public var hasMorePages: Bool { nextCursor != nil }

    /// 同一个 job 下的全部行（一次生成两行 ⇒ 按 job 归组的唯一正确口径是**用 `jobId` 或
    /// id 前段**，而不是把 `id` 当唯一键）。
    public func rows(jobID: String) -> [WorksListRowDto] {
        works.filter { $0.identity.jobID == jobID }
    }

    /// favorite/dislike 互斥被破坏的行（只可能来自形状漂移；UI 不许自己挑一个显示）。
    public var conflictingSignalRows: [WorksListRowDto] { works.filter(\.signalConflict) }
}
