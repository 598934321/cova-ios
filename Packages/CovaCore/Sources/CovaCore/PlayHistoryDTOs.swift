import Foundation

/// `GET /api/play-history` 的一行**是哪一种东西**（DEVELOPMENT.md §4.3）。
///
/// 服务端把两张表合并成一条时间序：`track_listens`（库曲）与 `work_listens`（作品）。
/// 两者的 `track` 子对象是**不同投影**，用库曲 DTO 直解会在作品行上抛错 ——
/// 而 `items` 是一个数组，一处抛错 ⇒ **整份历史全丢**（不是丢一行）。
public enum PlayHistoryRowKind: String, Equatable, Sendable, CaseIterable {
    /// 库曲行（`track_listens`）。
    case library
    /// 作品行（`work_listens`）：`trackId` 是伪 id `{jobId}:{candidateId}`（也可为裸 jobId）。
    case work
}

/// 历史行里 `track` 子对象的**展示投影**（库曲与作品共用一个宽松形态）。
///
/// 两条刻意的取舍，都写在类型上而不是留给调用方猜：
/// · **不含音频地址**。`audioUrl` 在作品行上是 30 分钟 TTL 的签名代理串，在库曲行上是
///   预览/整曲共用端点 —— 存下来的地址到点开必然过期或形态不明。硬边界 3 也禁止签名串
///   进持久化索引。所以这一栏只存展示字段，**点开时回读权威端点**（库曲
///   `GET /api/tracks/:id`、作品 `GET /api/studio/create/works?id=<trackId>`），
///   与本仓 `RecentTrack` 的既有口径同源。
/// · **不含 `bpm` / `waveformPeaks` / `favoriteCount`**。作品行里它们恒为
///   `null` / `[]` / `null`（实测 `web/src/lib/play-history.ts:157-182`），而历史行
///   本来就只渲染标题/艺人/封面/时长 —— 建模一个两种行都读不出的字段，等于给 UI
///   一个「以为有」的借口（A1 的「作品行无 bpm/波形」由这里结构性保证）。
///
/// 解码口径：**永不抛**。所有字段 `try?`，容器取不到就全 nil —— 一行的形状不对
/// 不许连累同批其它行（那是 `items` 数组解码的默认行为，也正是本类型存在的理由）。
public struct PlayHistoryTrackDto: Decodable, Equatable, Sendable {
    public let id: String?
    public let title: String?
    public let titleCn: String?
    /// 库曲行的完整艺人对象；**作品行恒 null**（`play-history.ts:170-176`）。
    public let artist: ArtistDto?
    /// 扁平艺人名。库曲行与作品行都可能给，也可能都是 null。
    public let artistName: String?
    public let artistNameCn: String?
    public let artistId: String?
    public let cover: String?
    public let duration: Double?
    /// **作品行的权威标位**：只有 work 投影会带这个键（`play-history.ts:181`，
    /// 服务端注释明写「标位供前端区分」）。库曲行没有它。
    public let workId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, titleCn, artist, artistName, artistNameCn, artistId
        case cover, duration, workId
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        id = try? c?.decodeIfPresent(String.self, forKey: .id) ?? nil
        title = try? c?.decodeIfPresent(String.self, forKey: .title) ?? nil
        titleCn = try? c?.decodeIfPresent(String.self, forKey: .titleCn) ?? nil
        artist = try? c?.decodeIfPresent(ArtistDto.self, forKey: .artist) ?? nil
        artistName = try? c?.decodeIfPresent(String.self, forKey: .artistName) ?? nil
        artistNameCn = try? c?.decodeIfPresent(String.self, forKey: .artistNameCn) ?? nil
        artistId = try? c?.decodeIfPresent(String.self, forKey: .artistId) ?? nil
        cover = try? c?.decodeIfPresent(String.self, forKey: .cover) ?? nil
        duration = try? c?.decodeIfPresent(Double.self, forKey: .duration) ?? nil
        workId = try? c?.decodeIfPresent(String.self, forKey: .workId) ?? nil
    }

    /// 上屏标题：中文优先（与本仓 `TrackDto.titleCn ?? title` 同口径）。
    public var displayTitle: String? { titleCn ?? title }

    /// 上屏艺人名：扁平中文名 → 扁平名 → 艺人对象中文名 → 艺人对象名。
    ///
    /// 作品行的 `artist` 恒 null，只能吃扁平键；库曲行两者都可能给。
    /// 四条都取不到 ⇒ 返回 nil，由 UI 决定占位（**不发明**「未知艺人」这类假值）。
    public var displayArtist: String? {
        artistNameCn ?? artistName ?? artist?.nameCn ?? artist?.name
    }
}

/// `GET /api/play-history` 的一行。
///
/// 身份只有一个硬要求：`trackId`（没有它这行既不能播也不能归类）。
/// 其余字段缺失一律容忍 —— 服务端在 `playedAt`/`source` 上给的是两张表各自的列，
/// 形状不由客户端钉死。
public struct PlayHistoryItemDto: Equatable, Sendable {
    public let id: String?
    public let trackId: String
    public let playedAt: String?
    /// 服务端回显，**刻意是松散 `String?`**：它可能是别的客户端写进去的取值，
    /// 用 `PlayReportSource` 严解会把「服务端已经记上了」误判成读不出来
    /// （与 `PlayReportRecordDto.source` 同一条理由）。
    public let source: String?
    public let track: PlayHistoryTrackDto?

    public init(
        id: String?, trackId: String, playedAt: String?, source: String?,
        track: PlayHistoryTrackDto?
    ) {
        self.id = id
        self.trackId = trackId
        self.playedAt = playedAt
        self.source = source
        self.track = track
    }

    /// 伪 trackId 的分隔符（`{jobId}:{candidateId}`）。
    public static let workTrackIDSeparator = ":"

    /// 这一行是库曲还是作品。
    ///
    /// 判据顺序是**契约事实**，不是猜的：
    /// ① `track.workId` 非空 ⇒ 作品（服务端自己就用这个键区分，`play-history.ts:181`）；
    /// ② 否则 `trackId` 含 `:` ⇒ 作品（`track` 投影缺失时的兜底；服务端 POST 侧的判据
    ///    就是 `trackId.includes(':') || jobExists(trackId)`，`:50`）；
    /// ③ 其余 ⇒ 库曲。
    ///
    /// ⚠️ 手册 §4.3 把「trackId 含 `:`」写成 work 行的定义，那是不完整的：
    /// **裸 jobId**（无候选后缀）也会被服务端记进 `work_listens`，且当 `result_audio_url`
    /// 非空时照样出现在 GET 的 items 里 —— 那种行不含 `:`，只能靠 `workId` 认出来。
    public var rowKind: PlayHistoryRowKind {
        if let workId = track?.workId, !workId.isEmpty { return .work }
        if trackId.contains(Self.workTrackIDSeparator) { return .work }
        return .library
    }

    public var isWorkRow: Bool { rowKind == .work }

    /// 作品行的 jobId（`:` 前段；裸 jobId 行 = 整个 trackId）。库曲行为 nil。
    public var workJobId: String? {
        guard isWorkRow else { return nil }
        return trackId.split(separator: Character(Self.workTrackIDSeparator)).first.map(String.init)
    }

    /// 作品行的 candidateId（`:` 后段）。裸 jobId 行为 nil —— 那种行**不能**拿去播
    /// （服务端在 GET 时会因取不到候选音频而可能整行丢弃，`:149-153`）。
    public var workCandidateId: String? {
        guard isWorkRow else { return nil }
        let parts = trackId.split(separator: Character(Self.workTrackIDSeparator))
        guard parts.count > 1 else { return nil }
        return String(parts[1])
    }

    /// 这一行能不能点开播放（作品行必须有候选后缀，理由见 `workCandidateId`）。
    public var isPlayable: Bool {
        switch rowKind {
        case .library: return true
        case .work: return workCandidateId != nil
        }
    }
}

/// `GET /api/play-history` 响应：`{authenticated, items, total}`。
///
/// 未登录是 `401 {"error":"请先登录","code":"AUTH_REQUIRED","authenticated":false,"items":[]}`
/// （**没有 `total`**，实测 `web/src/app/api/play-history/route.ts:16`）—— 由
/// `CovaAPIClient` 归一成 `.unauthorized`，所以本类型只需要吃 200 那一档，
/// 但 `authenticated` 仍建模（服务端在 200 里也回它，游客语义要靠它说话）。
///
/// **逐行容错**：`items` 里读不出身份的行不计入 `items`，而是计入
/// `unreadableItemCount` —— 既不让一行坏数据毁掉整份历史，也不把「少了几行」
/// 藏成一个看不见的差值（服务端 `total` 与本地 `items.count` 的落差由此可解释）。
public struct PlayHistoryPageDto: Decodable, Equatable, Sendable {
    public let authenticated: Bool?
    public let total: Int?
    public let items: [PlayHistoryItemDto]
    /// `items` 数组里读不出 `trackId` 的元素个数（不是对象、或对象里没有 trackId）。
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey {
        case authenticated, total, items
    }

    /// 线格式行：**永不抛**（容器取不到就全 nil），于是数组解码也不会因单个元素而整体失败。
    private struct WireItem: Decodable {
        let id: String?
        let trackId: String?
        let playedAt: String?
        let source: String?
        let track: PlayHistoryTrackDto?

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: WireItem.CodingKeys.self)
            id = (try? c?.decodeIfPresent(String.self, forKey: .id)) ?? nil
            trackId = (try? c?.decodeIfPresent(String.self, forKey: .trackId)) ?? nil
            playedAt = (try? c?.decodeIfPresent(String.self, forKey: .playedAt)) ?? nil
            source = (try? c?.decodeIfPresent(String.self, forKey: .source)) ?? nil
            track = (try? c?.decodeIfPresent(PlayHistoryTrackDto.self, forKey: .track)) ?? nil
        }

        enum CodingKeys: String, CodingKey {
            case id, trackId, playedAt, source, track
        }
    }

    public init(
        authenticated: Bool?, total: Int?, items: [PlayHistoryItemDto], unreadableItemCount: Int
    ) {
        self.authenticated = authenticated
        self.total = total
        self.items = items
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        authenticated = (try? root.decodeIfPresent(Bool.self, forKey: .authenticated)) ?? nil
        total = (try? root.decodeIfPresent(Int.self, forKey: .total)) ?? nil
        let wire = (try? root.decode([WireItem].self, forKey: .items)) ?? []
        var rows: [PlayHistoryItemDto] = []
        var unreadable = 0
        rows.reserveCapacity(wire.count)
        for element in wire {
            guard let trackId = element.trackId, !trackId.isEmpty else {
                unreadable += 1
                continue
            }
            rows.append(PlayHistoryItemDto(
                id: element.id, trackId: trackId, playedAt: element.playedAt,
                source: element.source, track: element.track
            ))
        }
        items = rows
        unreadableItemCount = unreadable
    }

    /// 作品行数（A1 的「work 行不丢」用它取证：与 `curl` 数出的含 `:`/`workId` 行数对齐）。
    public var workItemCount: Int { items.filter(\.isWorkRow).count }

    public var libraryItemCount: Int { items.count - workItemCount }
}
