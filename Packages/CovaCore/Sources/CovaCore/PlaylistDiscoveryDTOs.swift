import Foundation

// §5 P3「每日推荐 / 歌单广场」两条读面的契约面（2026-09-27 对着 `../web` 逐字核过）：
//   GET /api/playlists/daily?date=YYYY-MM-DD → {date, items:[歌单卡 + source + href]}
//     （`src/app/api/playlists/daily/route.ts`：官方 ∪ 已开分享的用户歌单，日期种子确定性轮换；
//      `date` 非 `YYYY-MM-DD` ⇒ **400**，且服务端把任意日期**钳到 [昨日, 今日]**）
//   GET /api/playlists/public → {playlists:[用户分享歌单卡 + source + href]}
//     （`src/app/api/playlists/public/route.ts`：只放 `shareEnabled=1` 且有 shareToken 的，
//      最近更新在前；`href` 是 `/share/playlist/<token>`，**不是** `/playlists/<id>`）
//   GET /api/shared-playlists/[token] → {playlist, tracks, downloadCredits, downloadsEnabled}
//     （免登录可读；404 `歌单不存在或未开启分享`。注意这一支的标题键是 **`name`**，
//      而官方那支是 `title` —— 两个封套不能共用一个解码器）

/// 一张卡在**这一批响应**里是从哪来的。
///
/// 为什么必须有这一格：`source: "shared"` 的那张卡的 `href` 指向分享落地页，
/// 它的 id 是**用户歌单 id**，拿去打 `GET /api/playlists/:id` 只会 404。
/// 少了这一格，"点一张卡"就没有正确的目标屏 —— 而这不是能靠猜的（两条腿的 id 长得一样）。
public enum PlaylistPickSource: Equatable, Sendable {
    case official
    case shared
    /// 服务端给了一个本层不认识的来源 ⇒ 保留原文，**不**折进上面两格。
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "official": self = .official
        case "shared": self = .shared
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }
}

/// 一张歌单卡 + 它属于哪条腿 + 服务端给的目标地址。
public struct PlaylistPickDto: Decodable, Equatable, Sendable {
    public let playlist: PlaylistDto
    public let source: PlaylistPickSource
    public let href: String?

    public init(playlist: PlaylistDto, source: PlaylistPickSource, href: String?) {
        self.playlist = playlist
        self.source = source
        self.href = href
    }

    private enum ExtraKeys: String, CodingKey { case source, href }

    public init(from decoder: any Decoder) throws {
        // 卡本体逐字节按官方那张卡解（字段集一致），只有这两格是本批响应多出来的。
        playlist = try PlaylistDto(from: decoder)
        let extra = try? decoder.container(keyedBy: ExtraKeys.self)
        source = PlaylistPickSource(raw: (try? extra?.decodeIfPresent(String.self, forKey: .source)) ?? nil)
        href = (try? extra?.decodeIfPresent(String.self, forKey: .href)) ?? nil
    }

    /// 分享腿那张卡的 token（从 `href` 的 `/share/playlist/<token>` 里取）。
    ///
    /// 只认这一个形状；不是它就返回 `nil`（**不**去猜 id 能当 token 用）。
    /// token 要进路径 ⇒ 过 `WorksPathEncoding` 那枚"标识能不能安全进路径"的判据，
    /// 与作品伪 id 同一把尺子（同一个判据不许有第二份）。
    public var shareToken: String? {
        guard source == .shared, let href,
              href.hasPrefix(SharedPlaylistResponseDto.pathPrefix) else { return nil }
        let raw = String(href.dropFirst(SharedPlaylistResponseDto.pathPrefix.count))
        guard !raw.isEmpty, !raw.contains("/") else { return nil }
        return WorksPathEncoding.safeIdentifier(raw)
    }
}

/// `GET /api/playlists/daily` 的封套。
public struct DailyPlaylistsResponseDto: Decodable, Equatable, Sendable {
    public let date: String?
    public let items: [PlaylistPickDto]

    private enum CodingKeys: String, CodingKey { case date, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        items = decodePlaylistPicksLoosely(from: decoder, key: "items")
    }

    public static let path = "/api/playlists/daily"

    /// `date` 只接受 `YYYY-MM-DD`（服务端对别的形状回 **400**），且**只在合法时才带上**——
    /// 不合法就当没传这个参数（服务端自己取今日），而不是把一次明知会 400 的请求发出去。
    public static func queryItems(date: String?) -> [URLQueryItem] {
        guard let date, isISODate(date) else { return [] }
        return [URLQueryItem(name: "date", value: date)]
    }

    /// 严格到"逐字符"：四位-两位-两位，且月/日在合法区间、数字全 ASCII。
    /// 不做历法级校验（那是服务端钳位的事），但也不会把 `2026-13-45` 放过去。
    static func isISODate(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count == 10,
              chars[4] == "-", chars[7] == "-" else { return false }
        let digits = chars.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.count == 8, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let month = digits[4...5].reduce(into: "") { $0.append($1) }
        let day = digits[6...7].reduce(into: "") { $0.append($1) }
        guard let m = Int(month), let d = Int(day) else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }
}

/// `GET /api/playlists/public` 的封套（键名是 `playlists`，与 daily 的 `items` **不同**）。
public struct PublicPlaylistsResponseDto: Decodable, Equatable, Sendable {
    public let playlists: [PlaylistPickDto]

    private enum CodingKeys: String, CodingKey { case playlists }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlists = decodePlaylistPicksLoosely(from: decoder, key: "playlists")
    }

    public static let path = "/api/playlists/public"
}

/// 逐条解一组卡：解不动的那一条丢掉，其余留下。
///
/// 为什么要这一层：`[PlaylistPickDto]` 的默认解码是"一颗坏卡 ⇒ 整块推荐位读不出"，
/// 而推荐位是一张张**独立**的卡 —— 服务端多给一个没见过的形状，代价不该是整屏空掉。
/// （反过来 `tracks` 不做逐条：见 `SharedPlaylistResponseDto.init` 那一段的理由。）
func decodePlaylistPicksLoosely(from decoder: any Decoder, key: String) -> [PlaylistPickDto] {
    struct Lossy: Decodable {
        let pick: PlaylistPickDto?
        init(from inner: any Decoder) throws { pick = try? PlaylistPickDto(from: inner) }
    }
    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    guard let c = try? decoder.container(keyedBy: AnyKey.self), let k = AnyKey(stringValue: key) else {
        return []
    }
    return ((try? c.decodeIfPresent([Lossy].self, forKey: k)) ?? []).compactMap(\.pick)
}

/// 分享歌单的头部（`shared-playlists/[token]` 的 `playlist` 那一层）。
///
/// ⚠️ 标题键是 **`name`**（用户自己起的歌单名），不是官方那套的 `title`；
/// 两个封套因此各解各的，不做"统一成一个 DTO"的合并（合并就得猜键，猜错就是空标题）。
public struct SharedPlaylistDto: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let description: String?
    public let coverUrl: String?
    public let coverMedia: PlaylistCoverMediaDto?
    public let creatorName: String?
    public let trackCount: Int?
    public let createdAt: String?
    public let updatedAt: String?
    public let sharePath: String?
    public let isOwner: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description, coverUrl, coverMedia, creatorName, trackCount
        case createdAt, updatedAt, sharePath, isOwner
    }
}

/// `GET /api/shared-playlists/[token]` 的封套（免登录可读；404 走调用方的分档）。
public struct SharedPlaylistResponseDto: Decodable, Equatable, Sendable {
    public let playlist: SharedPlaylistDto?
    public let tracks: [TrackDto]?
    public let downloadCredits: Int?
    public let downloadsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case playlist, tracks, downloadCredits, downloadsEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlist = try c.decodeIfPresent(SharedPlaylistDto.self, forKey: .playlist)
        // 曲目那一层**不做逐条容错**：`TrackDto` 的必填面很宽（标题/时长/音频/艺人/波形…），
        // 少一个键的"半首"画在屏上比不画更坏（会给出一个点不动的行）。
        // ⇒ 整层读不出就按"没给曲目"处理，屏上是一句"曲目没取到"，不是少一行。
        tracks = (try? c.decodeIfPresent([TrackDto].self, forKey: .tracks)) ?? nil
        downloadCredits = try c.decodeIfPresent(Int.self, forKey: .downloadCredits)
        downloadsEnabled = try c.decodeIfPresent(Bool.self, forKey: .downloadsEnabled)
    }

    public static let pathPrefix = "/share/playlist/"
    public static let apiPrefix = "/api/shared-playlists/"

    /// token 不能安全进路径段 ⇒ `nil`（**不发**）。
    public static func path(token: String) -> String? {
        guard let safe = WorksPathEncoding.safeIdentifier(token) else { return nil }
        return "\(apiPrefix)\(safe)"
    }

    /// 这一屏是**别人的**分享歌单：`isOwner` 缺省按"不是主人"处理是安全的，
    /// 但反过来把缺键读成"是主人"就会给出一整排本不该出现的编辑动作 ⇒ 这一格只问服务端明确说了什么。
    public var viewerIsOwner: Bool { playlist?.isOwner == true }
}
