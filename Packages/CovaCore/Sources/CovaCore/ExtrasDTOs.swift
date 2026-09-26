import Foundation

// MARK: - 六个合法的补充制作键
//
// 契约事实源：DEVELOPMENT.md §4.7「extras（补充制作）」实测卡。三条不能改的事实：
// · 键是**闭集 6 个**（`wav|stems|vocal_stems|accompaniment|lyrics_video|lyrics_timing`），
//   未知键服务端**静默丢弃**（不报错）⇒ 客户端写一个自造的键 = 那一项永远不做而屏上看不出来；
// · `instrumental == true` 的作品服务端**滤掉** `lyrics_video / vocal_stems / accompaniment /
//   lyrics_timing` ⇒ 客户端的选项集必须跟着滤，否则画出来就是点一下回 400 的钮；
// · **作品级那一条腿不扣费**，会话级才按 `MEDIA_EXTRA_PRICES` 扣。

/// 补充制作的一项产物（线格式拼写就是 `rawValue`）。
public enum WorkExtraKey: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// 母带 wav
    case wav
    /// 分轨包
    case stems
    /// 人声分轨
    case vocalStems = "vocal_stems"
    /// 伴奏
    case accompaniment
    /// 歌词视频
    case lyricsVideo = "lyrics_video"
    /// 对齐歌词（LRC）
    case lyricsTiming = "lyrics_timing"

    public var id: String { rawValue }

    /// 认不出的键 ⇒ `nil`（**不**折成某个认识的值：静默折值是替服务端做它没做的决定）。
    public static func recognized(_ raw: String?) -> WorkExtraKey? {
        guard let raw else { return nil }
        return WorkExtraKey(rawValue: raw)
    }

    /// 会话级这一项的扣费额（§4.7 的 `MEDIA_EXTRA_PRICES` 实测表，单位 co）。
    ///
    /// ⚠️ 两个边界都写在名字与文档里，不写在字符串里：
    /// · 这张表**只**适用于 `POST /api/studio/extras`（会话级）那一条腿；
    ///   作品级 `POST …/works/{id}/extras` 服务端**分文不收**（见 `worksPathDeductionCredits`）；
    /// · 本 App 受 D12 合规闸约束（§2 硬边界 9）：**没有**任何充值/购买入口，
    ///   这一格只能作为「这次会消耗多少 co」的**说明**出现在被评审放行的文案里，
    ///   绝不构成一个付款/下单动作 —— 本文件里也没有那样的动作可发。
    public var sessionDeductionCredits: Int {
        switch self {
        case .wav: return 20
        case .accompaniment: return 30
        case .stems: return 50
        case .vocalStems: return 50
        case .lyricsTiming: return 10
        case .lyricsVideo: return 100
        }
    }

    /// 作品级那一条腿恒 0：服务端不扣。
    ///
    /// 这一条不是装饰 —— §4.7 特意写了「文案不许在免费的那条腿上暗示价格」：
    /// 复用会话级那张表给作品级渲染一句「本次消耗 N co」就是说谎。
    public static let worksPathDeductionCredits = 0

    /// 会话级一组键的总消耗（**去重**后算：同一个键写两遍不该扣两遍，服务端也只认一项）。
    public static func sessionDeductionTotal(for keys: [WorkExtraKey]) -> Int {
        Set(keys).reduce(0) { $0 + $1.sessionDeductionCredits }
    }

    /// 纯音乐作品被服务端滤掉的那四项。
    public static let instrumentalExcludedKeys: [WorkExtraKey] = [
        .lyricsVideo, .vocalStems, .accompaniment, .lyricsTiming,
    ]

    /// 全部六项（有序，按契约卡列出的顺序）。
    public static var allKeysInContractOrder: [WorkExtraKey] { allCases }

    /// 这一行**合法**可选项。
    ///
    /// `instrumental` 为 `nil`（服务端没给/读不出）⇒ **不滤**：滤掉是替服务端做一个我们
    /// 不知道成立与否的决定，而不滤最多让 UI 多点一次拿到服务端的 409/400（那一句是权威答复）。
    public static func allowedKeys(instrumental: Bool?) -> [WorkExtraKey] {
        guard instrumental == true else { return allKeysInContractOrder }
        let excluded = Set(instrumentalExcludedKeys)
        return allKeysInContractOrder.filter { !excluded.contains($0) }
    }

    /// 这一项在该行上是否合法（`instrumental == true` 时那四项不合法）。
    public static func isAllowed(_ key: WorkExtraKey, instrumental: Bool?) -> Bool {
        allowedKeys(instrumental: instrumental).contains(key)
    }
}

// MARK: - 产物文件

/// `files[].type` 的取值（闭集 8 值 + 容忍新值）。
///
/// 为什么带 `.unknown(String)` 而不是 `String?` 严解（同 `CovaSSEEventType` 的手法）：
/// 新类型上线时**这一行必须还活着**（用户已经付过 co 的产物不能因为客户端词表旧了就看不见），
/// 但 `.unknown` 保留原拼写 ⇒ 上层不会把认不出的东西画成 `其他`（那才是把服务端的话改掉）。
public enum WorkExtraFileKind: Equatable, Sendable {
    case audioWav
    case instrumentalWav
    case instrumentalMp3
    case stems
    case video
    case doc
    case cover
    case other
    /// 词表外的新值（原拼写在括号里）。
    case unknown(String)

    static let knownRawTypes: [String: WorkExtraFileKind] = [
        "audio-wav": .audioWav,
        "instrumental-wav": .instrumentalWav,
        "instrumental-mp3": .instrumentalMp3,
        "stems": .stems,
        "video": .video,
        "doc": .doc,
        "cover": .cover,
        "other": .other,
    ]

    public init(rawType: String) {
        self = WorkExtraFileKind.knownRawTypes[rawType] ?? .unknown(rawType)
    }

    /// 线格式原拼写（`.unknown` 回吐服务端给的那个词，一个字都不改）。
    public var rawType: String {
        switch self {
        case .audioWav: return "audio-wav"
        case .instrumentalWav: return "instrumental-wav"
        case .instrumentalMp3: return "instrumental-mp3"
        case .stems: return "stems"
        case .video: return "video"
        case .doc: return "doc"
        case .cover: return "cover"
        case .other: return "other"
        case .unknown(let raw): return raw
        }
    }
}

/// 一个交付产物的**状态**：由「有没有 `url`」与「`version` 写的是什么」两件事推出来。
///
/// 为什么不直接读 `version` 字符串（§4.7 明写「建模成枚举不是字符串」）：
/// 待做时服务端**不发 `url` 键**，而把状态文本塞进 `version`（`补充制作准备中` /
/// `失败：<msg>` / `已取消`）。一个 `String` 字段同时承担"版本号"与"状态文本"两种语义，
/// 于是 `file.version == "3"` 与 `file.version == "已取消"` 在字符串层面完全同型 ——
/// 拿它当版本号渲染就是那句「v 已取消」。
public enum WorkExtraDeliveryState: Equatable, Sendable {

    /// 可下载：`url` 在场。
    ///
    /// `url` 在场优先于 `version` 里的文本 —— 可下载性是文件本身的属性，状态文本只解释
    /// "还不能下载"的那几种情况。
    case ready
    /// 服务端已接单、还在做（`补充制作准备中`）。
    case preparing
    /// 制作失败，携服务端给的**原因原文**（`失败：<msg>` 的那半截）。
    case failed(message: String?)
    /// 已取消（`已取消`）。
    case cancelled
    /// 没有 `url`，而 `version` 不是那三个已知状态文本之一 ⇒ **不猜**。
    ///
    /// 这一格存在的意义是"UI 不许把它画成准备中"：新状态文本上线时它是看得见的未知，
    /// 而不是被 `default: .preparing` 悄悄吞掉的一个假进度。
    case unrecognised(version: String?)

    /// 待做状态的三个线格式文本（逐字来自 §4.7，不是本层的措辞）。
    public static let preparingText = "补充制作准备中"
    public static let failurePrefix = "失败："
    public static let cancelledText = "已取消"

    /// 由 `(url == nil, version)` 派生。`urlPresent` 是"这一项到底有没有拿到可下载地址"。
    public static func derive(urlPresent: Bool, version: String?) -> WorkExtraDeliveryState {
        if urlPresent { return .ready }
        guard let version, !version.isEmpty else { return .unrecognised(version: version) }
        if version == Self.preparingText { return .preparing }
        if version == Self.cancelledText { return .cancelled }
        if version.hasPrefix(Self.failurePrefix) {
            let message = String(version.dropFirst(Self.failurePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message: message.isEmpty ? nil : message)
        }
        return .unrecognised(version: version)
    }

    public var isReady: Bool { self == .ready }
}

/// `files[]` 的一项（交付产物）。
///
/// 键集实测：`id / name / type / url? / version / sourceGenerationJobId? / sourceCandidateId? / createdAt`。
///
/// ⚠️ **`files[].url` 里的 jobId 是 worker job，不是生成 job**（§4.7）。后果写在类型上：
/// · 本类型**只**交出 `url` 原文（`SecretString`，仅 Decodable、没有编码通路 ⇒ 编译期就拼不出
///   第二条地址），**没有**任何 `artifactURL(jobId:artifactId:)` 之类的构造器；
/// · 产物下载端点 `GET /api/studio/extras/artifacts/:jobId/:artifactId` 在本文件里**不建模**：
///   那个 `jobId` 只能从 `files[].url` 里读出来，而"从地址里拆参数再拼回去"正是本条禁令
///   要挡的动作（拆错了不报错，只是 404 或打到别人的产物上）；
/// · `id` 的拼写是 `extra-<workerJobId>-<artifactId>` —— 两段都可能含 `-`，
///   所以**字符串切分还原不出** worker jobId，本层不提供那个切分（不提供 = 不能用错）。
///
/// 两条已实测的下载形态（写在这里是因为它们决定"能不能直接交给播放器"）：
/// 产物下载是**同源 200 流**（`Content-Disposition: attachment`），`accompaniment` 是
/// **同源 302 到 `intent=download`** —— 都在生产出口上，与 §7 #37/#39 那条名单外桶的腿无关。
public struct WorkExtraDeliveryFileDto: Decodable, Equatable, Sendable {
    /// 产物身份（`extra-<workerJobId>-<artifactId>`），原样保留。
    public let id: String?
    public let name: String?
    /// 松散保存的原始 `type` 拼写（`kind` 是它的分类视图，两者都不丢信息）。
    public let rawType: String?
    public let url: SecretString?
    /// **双语义字段**：就绪时是版本号，待做时是状态文本（见 `WorkExtraDeliveryState`）。
    public let version: String?
    /// 生成 job（不是 url 里那个 worker job）。
    public let sourceGenerationJobId: String?
    public let sourceCandidateId: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, url, version, sourceGenerationJobId, sourceCandidateId, createdAt
    }

    /// 显式成员初始化（合成 memberwise 因下面有 `init(from:)` 而不存在；给出来也让测试
    /// 能从模块外构造一行 —— 本类型仍是**仅 Decodable**，构造它不等于能把签名地址编码出去）。
    public init(
        id: String?, name: String?, rawType: String?, url: SecretString?, version: String?,
        sourceGenerationJobId: String?, sourceCandidateId: String?, createdAt: String?
    ) {
        self.id = id
        self.name = name
        self.rawType = rawType
        self.url = url
        self.version = version
        self.sourceGenerationJobId = sourceGenerationJobId
        self.sourceCandidateId = sourceCandidateId
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        name = (try? container?.decodeIfPresent(String.self, forKey: .name)) ?? nil
        rawType = (try? container?.decodeIfPresent(String.self, forKey: .type)) ?? nil
        url = (try? container?.decodeIfPresent(SecretString.self, forKey: .url)) ?? nil
        version = (try? container?.decodeIfPresent(String.self, forKey: .version)) ?? nil
        sourceGenerationJobId =
            (try? container?.decodeIfPresent(String.self, forKey: .sourceGenerationJobId)) ?? nil
        sourceCandidateId =
            (try? container?.decodeIfPresent(String.self, forKey: .sourceCandidateId)) ?? nil
        createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
    }

    /// 分类视图：`type` 缺席 ⇒ `nil`（没有"未知类型"这个假值；读不到就是没给）。
    public var kind: WorkExtraFileKind? {
        rawType.map(WorkExtraFileKind.init(rawType:))
    }

    /// 有没有可下载的地址（只看键在不在，不看 `version` 写了什么）。
    public var hasDownloadURL: Bool { url != nil }

    public var deliveryState: WorkExtraDeliveryState {
        WorkExtraDeliveryState.derive(urlPresent: url != nil, version: version)
    }

    /// 只有真拿到地址才算可下载（`version` 里写着「准备中」而 `url` 在场时仍然可下 —— 那是
    /// 服务端自己的口径，本层不替它推翻）。
    public var isDownloadable: Bool { url != nil }

    /// 展示名：服务端给的 `name` 原文；空串按"没给名字"处理（**不**拿 `type` 编一个文件名）。
    public var displayName: String? { WorksListQuery.textIfPresent(name) }
}

// MARK: - 响应封套（两条腿形状不同，不共用一个类型）

/// `POST|GET /api/studio/create/works/{id}/extras` 的响应 `{ok:true, files:[…]}`。
///
/// ⚠️ **这一条腿不回 `deliveryRevision`**（§4.7）：那个计数器只在会话级响应里。
/// 本类型因此**没有**那个属性 —— 不是漏了建模，是"服务端不发就不建模"（硬边界 7）。
/// 同理也**不扣费**：作品级那一条腿分文不收。
///
/// 这一条腿**只认伪 id**：裸 jobId 会 404（§4.7）⇒ 传 id 之前先看 `WorksRowIdentity`，
/// 别拿 `jobId` 去点这条腿（见 `WorkExtrasRequest`）。
public struct WorkExtrasResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let files: [WorkExtraDeliveryFileDto]
    /// `files` 里读不出身份（无 `id`/空 `id`）的元素个数。
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey { case ok, files }

    public init(
        ok: Bool?, files: [WorkExtraDeliveryFileDto], unreadableItemCount: Int
    ) {
        self.ok = ok
        self.files = files
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? root.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        // `[WireFile?]`：元素 `null` 在非 Optional 数组解码里会让**整份快照**抛错，
        // 而"抛"在 UI 上就是"没有产物"——那比丢一项坏得多。
        let wire = try root.decode([WireFile?].self, forKey: .files)
        var rows: [WorkExtraDeliveryFileDto] = []
        var unreadable = 0
        rows.reserveCapacity(wire.count)
        for element in wire {
            if let element, let id = element.id, !id.isEmpty {
                rows.append(element.materialize())
            } else {
                unreadable += 1
            }
        }
        files = rows
        unreadableItemCount = unreadable
    }

    /// 已经能拿走的产物。
    public var downloadableFiles: [WorkExtraDeliveryFileDto] { files.filter(\.isDownloadable) }

    /// 还在做 / 失败 / 取消的条目（渲染进度与原因用，**不是**空列表的同义词）。
    public var pendingOrFailedFiles: [WorkExtraDeliveryFileDto] {
        files.filter { !$0.isDownloadable }
    }

    /// 线格式：永不抛（一行坏形状不许把整份交付快照判成解不出来 ⇒ 那会读成"没有产物"）。
    struct WireFile: Decodable {
        let id: String?
        let name: String?
        let rawType: String?
        let url: SecretString?
        let version: String?
        let sourceGenerationJobId: String?
        let sourceCandidateId: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, type, url, version, sourceGenerationJobId, sourceCandidateId, createdAt
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
            name = (try? container?.decodeIfPresent(String.self, forKey: .name)) ?? nil
            rawType = (try? container?.decodeIfPresent(String.self, forKey: .type)) ?? nil
            url = (try? container?.decodeIfPresent(SecretString.self, forKey: .url)) ?? nil
            version = (try? container?.decodeIfPresent(String.self, forKey: .version)) ?? nil
            sourceGenerationJobId =
                (try? container?.decodeIfPresent(String.self, forKey: .sourceGenerationJobId)) ?? nil
            sourceCandidateId =
                (try? container?.decodeIfPresent(String.self, forKey: .sourceCandidateId)) ?? nil
            createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        }

        func materialize() -> WorkExtraDeliveryFileDto {
            WorkExtraDeliveryFileDto(
                id: id, name: name, rawType: rawType, url: url, version: version,
                sourceGenerationJobId: sourceGenerationJobId,
                sourceCandidateId: sourceCandidateId, createdAt: createdAt
            )
        }
    }
}

/// `POST|GET /api/studio/extras`（会话级）的响应 `{ok:true, files, deliveryRevision:Int}`。
///
/// `deliveryRevision` 是**工作流计数器**（§4.7），是这一条腿驱动 UI 版本比对的唯一依据；
/// 作品级响应里没有它 ⇒ 两条腿不许共用一个类型（共用了就只能给一个 `Int?`，
/// 而那个 nil 在作品级是"这个端点没这个概念"、在会话级是"契约漂了"，两件事）。
public struct SessionExtrasResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let files: [WorkExtraDeliveryFileDto]
    public let deliveryRevision: Int?
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey { case ok, files, deliveryRevision }

    public init(
        ok: Bool?, files: [WorkExtraDeliveryFileDto], deliveryRevision: Int?,
        unreadableItemCount: Int
    ) {
        self.ok = ok
        self.files = files
        self.deliveryRevision = deliveryRevision
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? root.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        // 计数器读不出来（键缺失或不是整数）⇒ nil，**不填 0**：0 会被 UI 读成"第一版"，
        // 于是一次漂移就变成"版本没变"（这一格的可断言用例见 SessionExtras 那组测试）。
        deliveryRevision = (try? root.decodeIfPresent(Int.self, forKey: .deliveryRevision)) ?? nil
        let wire = try root.decode([WorkExtrasResponseDto.WireFile?].self, forKey: .files)
        var rows: [WorkExtraDeliveryFileDto] = []
        var unreadable = 0
        rows.reserveCapacity(wire.count)
        for element in wire {
            if let element, let id = element.id, !id.isEmpty {
                rows.append(element.materialize())
            } else {
                unreadable += 1
            }
        }
        files = rows
        unreadableItemCount = unreadable
    }

    public var isAcknowledged: Bool { ok == true }
    public var downloadableFiles: [WorkExtraDeliveryFileDto] { files.filter(\.isDownloadable) }
}

// MARK: - 请求

/// 补充制作请求的本地校验失败（**不发请求**就拦下，省一次 400/404 往返）。
public enum WorkExtrasRequestError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 空选择。服务端那一档的原文是「请选择可用的补充制作文件。」（400）
    case noKeysSelected
    /// 会话级缺 `sessionId`。
    case missingSessionID
    /// 伪 id 不安全 ⇒ 不许发出（见 `WorksPathEncoding`）。
    case unsafeWorkIdentifier
    /// 裸 jobId：`works/{id}/extras` **只认伪 id**，裸 jobId 服务端直接 404（§4.7）。
    /// 这一条在本地就拦，是因为 404 与"作品不存在"在屏上根本分不开。
    case bareJobIDRejected

    public var description: String {
        switch self {
        case .noKeysSelected: return "没有选中的补充制作文件"
        case .missingSessionID: return "缺少会话标识"
        case .unsafeWorkIdentifier: return "作品标识不能安全进 URL 路径"
        case .bareJobIDRejected: return "作品级补充制作只接受伪 id（jobId:candidateId）"
        }
    }
}

/// `POST /api/studio/create/works/{id}/extras` 的请求体 `{keys}`。
///
/// 键集是闭集枚举 ⇒ **写不出**服务端不认识的键（那一个坑是静默丢弃，不是报错）。
/// 选择集必须先用 `WorkExtraKey.allowedKeys(instrumental:)` 过一遍：纯音乐那四项不合法。
public struct WorkExtrasRequestDto: Codable, Equatable, Sendable {
    public let keys: [WorkExtraKey]

    /// 空选择本地就拒（服务端那一档是 400「请选择可用的补充制作文件。」）。
    /// 顺序保留调用方给的顺序（去重但**不排序** —— 排序会改掉 UI 里"先点先做"的顺序语义）。
    public init(keys: [WorkExtraKey]) throws {
        let deduped = WorkExtrasRequestDto.deduplicate(keys)
        guard !deduped.isEmpty else { throw WorkExtrasRequestError.noKeysSelected }
        self.keys = deduped
    }

    static func deduplicate(_ keys: [WorkExtraKey]) -> [WorkExtraKey] {
        var seen = Set<WorkExtraKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// 作品级这一条腿的扣费额：0（服务端不扣 ⇒ UI 不许在这一条上写消耗）。
    public var worksPathDeductionCredits: Int { WorkExtraKey.worksPathDeductionCredits }

    enum CodingKeys: String, CodingKey { case keys }

    /// 行级 id 校验：这一条腿**只认伪 id**（裸 jobId 服务端直接 404，§4.7）。
    /// `pending-N` 占位行是**合法伪 id**、允许拼出路径 —— 它拿到的是 409「作品尚未完成」，
    /// 那是服务端的权威答复，本层不替它预判（预判就要猜"什么时候算完成"）。
    public func path(workID: String) throws -> String {
        try WorkExtrasEndpoint.workPath(workID: workID)
    }
}

/// `POST /api/studio/extras` 的请求体 `{sessionId, keys}`。
public struct SessionExtrasRequestDto: Codable, Equatable, Sendable {
    public let sessionId: String
    public let keys: [WorkExtraKey]

    public init(sessionId: String, keys: [WorkExtraKey]) throws {
        let session = WorksListQuery.textIfPresent(sessionId)
        guard let session else { throw WorkExtrasRequestError.missingSessionID }
        let deduped = WorkExtrasRequestDto.deduplicate(keys)
        guard !deduped.isEmpty else { throw WorkExtrasRequestError.noKeysSelected }
        self.sessionId = session
        self.keys = deduped
    }

    /// 这一条腿**才**扣费（会话级）。合计是**给用户的说明**，不是下单动作（D12）。
    public var sessionDeductionTotalCredits: Int { WorkExtraKey.sessionDeductionTotal(for: keys) }

    enum CodingKeys: String, CodingKey { case sessionId, keys }
}

/// extras 两条腿的路径常量。
public enum WorkExtrasEndpoint {
    /// 会话级（`POST` 带体 / `GET ?sessionId=`）。
    public static let sessionPath = "/api/studio/extras"
    /// 作品级前缀（完整路径由 `WorkExtrasRequestDto.path(workID:)` 拼，含伪 id 校验）。
    public static let worksPathPrefix = "/api/studio/create/works"

    /// 会话级的查询读：`GET /api/studio/extras?sessionId=<id>`。
    ///
    /// 空白 / 非法字符 / 超长 ⇒ `nil`（**不发**一条形状不对的查询：那是在拿别人的快照或
    /// 一条服务端根本不读的键赌运气）。字符集闸门复用 `WorksPathEncoding`——同一个
    /// "标识符能不能出门"的判据不许有第二份（路径段与查询值在这里同一条规则）。
    public static func sessionQueryItems(sessionId: String?) -> [URLQueryItem]? {
        guard let session = WorksListQuery.textIfPresent(sessionId) else { return nil }
        guard WorksPathEncoding.safeIdentifier(session) != nil else { return nil }
        return [URLQueryItem(name: "sessionId", value: session)]
    }

    /// 作品级那一腿的完整路径（`POST` 与 `GET` **共用**：判据只有一份）。
    ///
    /// 为什么在 endpoint 上而不是只在请求体类型上：`GET …/works/{id}/extras` 复列产物时
    /// **没有键集**，如果路径校验只长在 `WorkExtrasRequestDto` 里，GET 那条就只能
    /// "编一个假键集借道校验"——那正是"同一个判定写两份、其中一份漏改"的形状。
    public static func workPath(workID: String) throws -> String {
        let identity = WorksRowIdentity(rawID: workID)
        guard identity.candidateID != nil else {
            if case .bareJobID = identity { throw WorkExtrasRequestError.bareJobIDRejected }
            throw WorkExtrasRequestError.unsafeWorkIdentifier
        }
        guard let identifier = WorksPathEncoding.safeIdentifier(workID) else {
            throw WorkExtrasRequestError.unsafeWorkIdentifier
        }
        return "\(worksPathPrefix)/\(identifier)/extras"
    }
}

// MARK: - 错误

/// extras 的失败分诊。四条实测原文（§4.7 + A8）逐条一档，**不合并**：
/// · 404 `作品不存在`
/// · 409 `作品尚未完成，完成后才可补充制作`
/// · 409 `作品素材不完整，暂不能补充制作`
/// · 400 `请选择可用的补充制作文件。`
///
/// 409 那一档有**两句**不同的话，所以分支不能只看状态码 —— 两句的处置方式不同：
/// "尚未完成"= 等（不是失败），"素材不完整"= 这一行根本做不了（要回作品行看错误）。
/// 把它们压成一个 409 分支就是把这两种用户都指错方向。
public enum ExtrasRejection: Equatable, Sendable {
    case unauthenticated
    /// 404：作品不存在（**也包括拿裸 jobId 打作品级那一条腿**的情况 —— 服务端只会给这一句，
    /// 分不出"没这个作品"与"有作品但 id 形状不对"，所以客户端在本地就先拦，见
    /// `WorkExtrasRequestError.bareJobIDRejected`）。
    case workMissing(serverMessage: String?)
    /// 409：还没生成完（等待，不是失败）。
    case notCompleted(serverMessage: String?)
    /// 409：素材不完整（这一行做不了）。
    case sourceIncomplete(serverMessage: String?)
    /// 400：没选中任何可用项。
    case noUsableKeys(serverMessage: String?)
    /// 429：限流。
    case rateLimited(serverMessage: String?)
    case server(statusCode: Int, serverMessage: String?)

    /// 上屏文案：透传服务端原文（这四档服务端给的都是中文人话），
    /// 读不到原文时说清"未说明原因"，不编「未知错误」（A4/A15）。
    public var userMessage: String {
        switch self {
        case .unauthenticated:
            return "登录状态已过期"
        case .workMissing(let message):
            return WorkActionRejection.human(message) ?? "这首作品不存在（或已被删除）"
        case .notCompleted(let message):
            return WorkActionRejection.human(message) ?? "还在制作中，做完才能补充制作"
        case .sourceIncomplete(let message):
            return WorkActionRejection.human(message) ?? "这一首的素材不完整，没法补充制作"
        case .noUsableKeys(let message):
            return WorkActionRejection.human(message) ?? "请至少选一项补充制作文件"
        case .rateLimited(let message):
            return WorkActionRejection.human(message) ?? "操作太频繁了，稍后再试"
        case .server(let statusCode, let message):
            return WorkActionRejection.human(message) ?? "服务端错误（\(statusCode)）"
        }
    }

    /// 该不该继续等（"尚未完成"是唯一一档"等着就行"的失败）。
    public var shouldKeepWaiting: Bool {
        if case .notCompleted = self { return true }
        return false
    }

    public static func classify(statusCode: Int, body: Data?) -> ExtrasRejection {
        let message = body.flatMap {
            try? JSONDecoder().decode(WorkActionErrorDto.self, from: $0)
        }?.error
        switch statusCode {
        case 401, 403:
            return .unauthenticated
        case 400:
            return .noUsableKeys(serverMessage: message)
        case 404:
            return .workMissing(serverMessage: message)
        case 409:
            // 分支只认**服务端原文里的那两个短语**；认不出来就如实落 `.server`，
            // 不给一个我没见过的 409 编一句我自己的话。
            if let message, message.contains("素材不完整") { return .sourceIncomplete(serverMessage: message) }
            if let message, message.contains("尚未完成") { return .notCompleted(serverMessage: message) }
            return .server(statusCode: 409, serverMessage: message)
        case 429:
            return .rateLimited(serverMessage: message)
        default:
            return .server(statusCode: statusCode, serverMessage: message)
        }
    }
}
