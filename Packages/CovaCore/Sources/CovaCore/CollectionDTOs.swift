import Foundation

// MARK: - 收藏（api-contracts 2：`GET/POST/DELETE /api/favorites` + `POST/DELETE /api/notes/:id/favorite`，均需登录）

/// `GET /api/favorites` 响应：**两类收藏混在同一个 `{tracks[]}` 里的合并 feed**（E3b）。
///
/// 服务端把「库曲收藏」与「生成笔记（`music_notes`）收藏」按收藏时间倒序混排下发
/// （`web` 仓 `src/app/api/favorites/route.ts` 里就是这条合并规则，注里写着
/// 「note 条目带 `source:'note'`/`noteId`，前端据此走 note 收藏端点」）。两类字段集不同：
/// 笔记条目 `artist` 恒为 `null`、**没有** `favoriteCount` / `energy` / `tags` /
/// `previewStart` / `previewEnd`，`id` 形如 `note:<uuid>`。
///
/// 旧实现把整份数组建模成 `[TrackDto]` ⇒ **一条笔记条目就让整个 收藏 屏报解码失败**。
/// 现在逐条定类型；定完类型仍然解不出的条目**照常抛错，不静默丢行** ——
/// 丢行是把用户自己的收藏藏起来，比报错更坏（12a 的「静默跳过」旧注释就是这个谎）。
///
/// 刻意只 `Decodable`（TD-23 同一条理由）：条目里的 `audioUrl` 是带签名的本站地址，
/// 编译期就不给「把它再序列化进持久化索引」留通路。
public struct FavoritesListDto: Decodable, Equatable, Sendable {
    /// 合并 feed 的原样顺序（服务端按收藏时间倒序；客户端**不重排**）。
    public let items: [FavoriteItemDto]

    /// 库曲条目子集：`AppSession.favoriteIDs` 那本账只认库曲 id
    /// （笔记收藏的账在 `/api/notes/:id/favorite` 那一侧，两本账不混）。
    public var tracks: [TrackDto] {
        items.compactMap { if case .library(let track) = $0 { track } else { nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([FavoriteItemDto].self, forKey: .tracks)
    }
}

/// 一条收藏的**种类**（决定它走哪个收藏端点）。
public enum FavoriteItemDto: Equatable, Sendable {
    case library(TrackDto)
    case note(NoteFavoriteDto)

    /// 判别只看服务端给的两件事实：`source == "note"`，以及 `id` 的 `note:` 前缀。
    /// 两者都没有 ⇒ 按库曲条目解（库曲投影**不带** `source` 键，2026-09-24 只读实测：
    /// `/api/tracks` 的条目里没有 `source`）。解不出来就抛，不猜成笔记、也不丢行。
    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKey.self)
        let identifier = try probe.decodeIfPresent(String.self, forKey: .id)
        let source = try probe.decodeIfPresent(String.self, forKey: .source)
        if source == NoteFavoriteDto.noteSource || FavoriteMutationRoute.isNoteID(identifier) {
            self = .note(try NoteFavoriteDto(from: decoder))
        } else {
            self = .library(try TrackDto(from: decoder))
        }
    }

    /// 判别用的**只读探针**容器：`CodingKeys` 必须与属性一一对应，故单独一个键集
    /// （同 `StudioSessionDTOs` 的 `SessionIdAliasKey` 手法）。
    private enum ProbeKey: String, CodingKey {
        case id
        case source
    }

    public var id: String {
        switch self {
        case .library(let track): return track.id
        case .note(let note): return note.id
        }
    }

    /// 本条收藏的取消/收藏动作落点；`nil` = **不许发任何端点**（宁可失败也不误伤）。
    public var route: FavoriteMutationRoute? {
        switch self {
        case .library(let track):
            return .libraryTrack(trackID: track.id)
        case .note(let note):
            return note.noteIdentifier.map { .generatedNote(noteID: $0) }
        }
    }
}

/// 生成笔记形态的收藏条目（`source: "note"`）。
///
/// **必填集合只有 `id`**：行身份与收藏端点都靠它，缺了就无处可发（照 `StudioSessionDto`
/// 的口径：身份取不到 ⇒ 报错，不猜一个）。其余一律可选 —— 缺席的字段在模型里就是缺席，
/// 不填 `0` / `""` 冒充真值：笔记的 `favoriteCount` / `energy` / `tags` 服务端**根本不发**，
/// 所以本类型也**没有**这些属性（渲染面拿不到，就不会把"未知"画成"0 人收藏"）。
/// 唯一例外是 `duration`：服务端确实发，但值是 `0`（= 未知），视图据此**不渲染时长**。
public struct NoteFavoriteDto: Decodable, Equatable, Sendable {
    /// 服务端标记这类条目的 `source` 值。
    static let noteSource = "note"
    /// `id` 的前缀标记（`id = "note:" + noteId`）。
    public static let idPrefix = "note:"

    public let id: String
    public let noteId: String?
    public let source: String?
    public let title: String?
    public let titleCn: String?
    public let artistName: String?
    public let artistNameCn: String?
    public let cover: String?
    /// 本站地址（Suno 资产被改写成 `/api/proxy/audio?…&sig=…`，或历史件 `/audio/….mp3`），
    /// 也可能是绝对 https；**不保证可直接播**，由 UI 侧按 D7 先本地化。
    public let audioUrl: String?
    public let duration: Double?
    /// 真实响应恒为 `null`（笔记不入库、没有 BPM 分析）。
    public let bpm: Int?
    public let lyrics: String?
    public let vocalType: String?
    public let favorited: Bool?
    public let addedAt: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case noteId
        case source
        case title
        case titleCn
        case artistName
        case artistNameCn
        case cover
        case audioUrl
        case duration
        case bpm
        case lyrics
        case vocalType
        case favorited
        case addedAt
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleCn = try container.decodeIfPresent(String.self, forKey: .titleCn)
        artistName = try container.decodeIfPresent(String.self, forKey: .artistName)
        artistNameCn = try container.decodeIfPresent(String.self, forKey: .artistNameCn)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        audioUrl = try container.decodeIfPresent(String.self, forKey: .audioUrl)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
        vocalType = try container.decodeIfPresent(String.self, forKey: .vocalType)
        favorited = try container.decodeIfPresent(Bool.self, forKey: .favorited)
        addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)

        let direct = try container.decodeIfPresent(String.self, forKey: .id)
        if let direct, !direct.isEmpty {
            id = direct
        } else if let noteId = Self.safeSegment(noteId) {
            // 别名腿（`SessionIdAliasKey` 同一手法）：序列化器本身就是 `id = "note:" + noteId`，
            // 所以 `id` 缺席而 `noteId` 在 ⇒ 按服务端的构造式补出**同一个值**，不是编造。
            id = Self.idPrefix + noteId
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "收藏条目既没有 id 也没有可用的 noteId（宁可整屏报错，不丢用户的收藏）"
            )
        }
    }

    /// 路由用的笔记号：优先服务端自己的 `noteId`，其次剥 `note:` 前缀。
    /// 两者都拿不到安全载荷 ⇒ `nil`（**不**回落到库曲端点）。
    public var noteIdentifier: String? {
        if let safe = Self.safeSegment(noteId) { return safe }
        return FavoriteMutationRoute.noteID(in: id)
    }

    /// 展示标题：`titleCn` 优先（服务端两个键都给同一个值）。
    /// 兜底文案不是数据：序列化器在标题为空时自己就发 `'未命名音乐笔记'`，这里同口径。
    public var displayTitle: String {
        if let titleCn, !titleCn.isEmpty { return titleCn }
        if let title, !title.isEmpty { return title }
        return "未命名音乐笔记"
    }

    /// 时长：`0` 是服务端的「未分析」形态，不是「零秒」；按未知处理（渲染与播放条都不显）。
    public var displayDuration: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// 能安全进 URL 路径段的笔记号：`[A-Za-z0-9_-]`、非空、≤120 字节
    /// （与 `PlaybackItem.validateIdentifier` 同一口径；`note:` 载荷是 uuid）。
    static func safeSegment(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 120 else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x30 && v <= 0x39)
                || v == 0x2D || v == 0x5F
            if !ok { return nil }
        }
        return raw
    }
}

/// 收藏动作的**落点**（E3b 的第二半：一条 `note:` 条目发给库曲端点会 404，
/// 2026-09-24 只读实测 `DELETE /api/favorites` + 笔记 id ⇒ 404 `{error}`）。
public enum FavoriteMutationRoute: Equatable, Sendable {
    /// 库曲收藏：`POST` / `DELETE /api/favorites`，body `{trackId}`。
    case libraryTrack(trackID: String)
    /// 生成笔记收藏：`POST` / `DELETE /api/notes/:noteId/favorite`，**无请求体**；
    /// 响应 `{favorited}`（POST 另带 `cocreate`）。
    case generatedNote(noteID: String)

    public static let libraryPath = "/api/favorites"

    /// `id` 带 `note:` 前缀 ⇒ 这是笔记条目（哪怕载荷不安全，也**绝不**按库曲处理）。
    static func isNoteID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(NoteFavoriteDto.idPrefix)
    }

    /// 剥前缀 + 载荷校验（不合法 ⇒ `nil`）。
    public static func noteID(in favoriteID: String) -> String? {
        guard favoriteID.hasPrefix(NoteFavoriteDto.idPrefix) else { return nil }
        return NoteFavoriteDto.safeSegment(String(favoriteID.dropFirst(NoteFavoriteDto.idPrefix.count)))
    }

    /// 只有 id 的入口（`AppSession` 那本账只存 id）。
    /// `nil` = 认出来是笔记但载荷不安全 ⇒ 调用方**不许**回落到 `/api/favorites`。
    public static func route(favoriteID: String) -> FavoriteMutationRoute? {
        if let noteID = noteID(in: favoriteID) { return .generatedNote(noteID: noteID) }
        guard !isNoteID(favoriteID) else { return nil }
        return .libraryTrack(trackID: favoriteID)
    }

    public var path: String {
        switch self {
        case .libraryTrack: return Self.libraryPath
        case .generatedNote(let noteID): return "/api/notes/\(noteID)/favorite"
        }
    }
}

/// `POST` / `DELETE /api/favorites` 请求体。
public struct FavoriteMutationRequestDto: Codable, Equatable, Sendable {
    public let trackId: String

    public init(trackId: String) {
        self.trackId = trackId
    }

    enum CodingKeys: String, CodingKey {
        case trackId
    }
}

/// `POST` / `DELETE /api/favorites` 响应（真实实现：`{message, favoriteCount}`）。
public struct FavoriteMutationResponseDto: Codable, Equatable, Sendable {
    public let message: String?
    public let favoriteCount: Int?

    enum CodingKeys: String, CodingKey {
        case message
        case favoriteCount
    }
}

/// `POST` / `DELETE /api/notes/:noteId/favorite` 响应。
///
/// 真实实现（`web` 仓 `src/app/api/notes/[id]/favorite/route.ts`）：POST 回
/// `{favorited, cocreate}`，DELETE 只回 `{favorited}` —— **没有** `message` /
/// `favoriteCount`，所以不复用 `FavoriteMutationResponseDto`（复用就是把两个端点的
/// 响应形态混成一个，字段永远对不上）。`cocreate` 的共创条款弹窗不在 v1 面上，
/// 故只建 `favorited`；`cocreate` 以未知键忽略（NEEDS 见交付报告）。
public struct NoteFavoriteMutationDto: Decodable, Equatable, Sendable {
    public let favorited: Bool?

    enum CodingKeys: String, CodingKey {
        case favorited
    }
}

/// 收藏开关的回执：两类条目走两个端点，响应形态不同 ⇒ 结果分两型，不压成一个。
public enum FavoriteMutationResultDto: Equatable, Sendable {
    case library(FavoriteMutationResponseDto)
    case note(NoteFavoriteMutationDto)

    /// 服务端回执的收藏态；两端点给的字段不同，取**各自那一型**的值。
    public var favorited: Bool? {
        switch self {
        case .note(let note): return note.favorited
        case .library: return nil   // 库曲端点不回显收藏态（只回 message/favoriteCount）
        }
    }
}

// MARK: - 歌单收藏（api-contracts 2：`GET/POST/DELETE /api/saved-playlists`，需登录）

/// `GET /api/saved-playlists` 响应（真实实现：`{playlists}`，元素为 `PlaylistDto` + `savedAt`）。
public struct SavedPlaylistsListDto: Codable, Equatable, Sendable {
    public let playlists: [PlaylistDto]

    enum CodingKeys: String, CodingKey {
        case playlists
    }
}

/// `POST` / `DELETE /api/saved-playlists` 请求体。
public struct SavedPlaylistMutationRequestDto: Codable, Equatable, Sendable {
    public let playlistId: String

    public init(playlistId: String) {
        self.playlistId = playlistId
    }

    enum CodingKeys: String, CodingKey {
        case playlistId
    }
}

/// `POST` / `DELETE /api/saved-playlists` 响应（真实实现：`{saved, playlistId, action}`）。
public struct SavedPlaylistMutationResponseDto: Codable, Equatable, Sendable {
    public let saved: Bool?
    /// 真实实现返回 `"bookmark"`（收藏动作 kind）。
    public let action: String?
    public let playlistId: String?

    enum CodingKeys: String, CodingKey {
        case saved
        case action
        case playlistId
    }
}
