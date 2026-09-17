import Foundation

/// 曲目标签（真实响应为对象数组：`{trackId, dimension, value}`）。
public struct TrackTagDto: Codable, Equatable, Sendable {
    public let trackId: String?
    public let dimension: String
    public let value: String

    enum CodingKeys: String, CodingKey {
        case trackId
        case dimension
        case value
    }
}

/// 曲目内嵌的音乐人信息。
///
/// 注意：`coreInstruments` / `colorPalette` / `sceneResponsibility` 在真实响应里是
/// **JSON 字符串**（如 `"[\"钢琴\",\"弦乐\"]"`），不是数组，故按原样 `String` 建模。
public struct ArtistDto: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let nameCn: String?
    public let country: String?
    public let countryFlag: String?
    public let style: String?
    public let styleCn: String?
    public let personality: String?
    public let coreInstruments: String?
    public let colorPalette: String?
    public let avatar: String?
    public let sceneResponsibility: String?
    public let stylePrompt: String?
    public let lyricsPrompt: String?
    public let userId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameCn
        case country
        case countryFlag
        case style
        case styleCn
        case personality
        case coreInstruments
        case colorPalette
        case avatar
        case sceneResponsibility
        case stylePrompt
        case lyricsPrompt
        case userId
    }
}

/// A/B 变体（api-contracts 2：`variants[]`）。列表接口有、详情接口缺失 → 可选。
public struct TrackVariantDto: Codable, Equatable, Sendable {
    public let id: String?
    public let title: String?
    public let variantRole: String?
    public let audioUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case variantRole
        case audioUrl
    }
}

/// 曲目（api-contracts 2）。
///
/// 必填集合 = 契约点名 **且** 真实列表/详情两种形态都存在的字段；
/// 其余一律可选（真实响应中 `lyrics` 恒为 `null`、详情接口缺 variant 字段族）。
public struct TrackDto: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let cover: String
    public let duration: Double
    public let bpm: Int
    public let audioUrl: String
    public let artist: ArtistDto
    public let scenes: [String]
    public let moods: [String]
    public let tags: [TrackTagDto]
    public let displayLabels: [String]
    public let waveformPeaks: [Double]
    public let previewStart: Double
    public let previewEnd: Double
    public let highlightStart: Double
    public let highlightEnd: Double
    public let favoriteCount: Int
    public let vocalType: String
    public let energy: String

    public let titleCn: String?
    public let category: String?
    public let artistId: String?
    public let key: String?
    public let style: String?
    public let styleCn: String?
    public let description: String?
    public let descriptionCn: String?
    public let copyright: String?
    public let featured: Bool?
    public let playCount: Int?
    public let createdAt: String?
    public let audioDuration: Double?
    public let status: String?
    public let segmentColors: String?
    public let lyrics: String?
    public let artistName: String?
    public let artistNameCn: String?
    public let lyricistName: String?
    public let lyricistNameCn: String?
    public let cocreate: Bool?
    public let downloadCount: Int?
    public let variantGroupId: String?
    public let variantRole: String?
    public let variantCount: Int?
    public let variants: [TrackVariantDto]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleCn
        case category
        case artistId
        case cover
        case duration
        case bpm
        case key
        case style
        case styleCn
        case description
        case descriptionCn
        case copyright
        case featured
        case playCount
        case favoriteCount
        case createdAt
        case audioUrl
        case audioDuration
        case previewStart
        case previewEnd
        case status
        case segmentColors
        case waveformPeaks
        case lyrics
        case vocalType
        case energy
        case artist
        case artistName
        case artistNameCn
        case lyricistName
        case lyricistNameCn
        case scenes
        case moods
        case displayLabels
        case highlightStart
        case highlightEnd
        case cocreate
        case downloadCount
        case tags
        case variantGroupId
        case variantRole
        case variantCount
        case variants
    }
}

/// `GET /api/tracks` 分页封套（真实响应：`{tracks, total, page, pageSize, totalPages}`）。
public struct TrackPageDto: Codable, Equatable, Sendable {
    public let tracks: [TrackDto]
    public let total: Int?
    public let page: Int?
    public let pageSize: Int?
    public let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case tracks
        case total
        case page
        case pageSize
        case totalPages
    }
}

/// `GET /api/tracks/:id` 响应：详情 + 相似曲目。
public struct TrackDetailDto: Codable, Equatable, Sendable {
    public let track: TrackDto
    public let similar: [TrackDto]?

    enum CodingKeys: String, CodingKey {
        case track
        case similar
    }
}

/// 歌单封面焦点信息（api-contracts 2：`coverMedia`）。
public struct PlaylistCoverMediaDto: Codable, Equatable, Sendable {
    public let imageUrl: String?
    public let fallbackUrl: String?
    public let alt: String?
    public let fit: String?
    public let focalX: Double?
    public let focalY: Double?
    public let mode: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case imageUrl
        case fallbackUrl
        case alt
        case fit
        case focalX
        case focalY
        case mode
        case updatedAt
    }
}

/// 歌单收藏动作描述（真实响应字段）。
public struct PlaylistSaveActionDto: Codable, Equatable, Sendable {
    public let kind: String?
    public let icon: String?
    public let saved: Bool?
    public let endpoint: String?
    public let addMethod: String?
    public let removeMethod: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case icon
        case saved
        case endpoint
        case addMethod
        case removeMethod
    }
}

/// 歌单（api-contracts 2）。`isSaved` / `saveAction` 等用户态字段仅在列表响应出现 → 可选。
public struct PlaylistDto: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let titleCn: String?
    public let description: String?
    public let descriptionCn: String?
    public let cover: String?
    public let coverUrl: String?
    public let coverDefault: String?
    public let coverMode: String?
    public let coverAlt: String?
    public let coverFit: String?
    public let coverFocalX: Double?
    public let coverFocalY: Double?
    public let coverUpdatedAt: String?
    public let coverMedia: PlaylistCoverMediaDto?
    public let scene: String?
    public let curator: String?
    public let createdAt: String?
    public let trackCount: Int?
    public let totalDuration: Double?
    public let isSaved: Bool?
    public let writable: Bool?
    public let disabledReason: String?
    public let saveAction: PlaylistSaveActionDto?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleCn
        case description
        case descriptionCn
        case cover
        case coverUrl
        case coverDefault
        case coverMode
        case coverAlt
        case coverFit
        case coverFocalX
        case coverFocalY
        case coverUpdatedAt
        case coverMedia
        case scene
        case curator
        case createdAt
        case trackCount
        case totalDuration
        case isSaved
        case writable
        case disabledReason
        case saveAction
    }
}

/// `GET /api/playlists` 响应封套（真实响应：`{playlists}`，无分页字段）。
public struct PlaylistListDto: Codable, Equatable, Sendable {
    public let playlists: [PlaylistDto]

    enum CodingKeys: String, CodingKey {
        case playlists
    }
}

/// `GET /api/playlists/:id` 响应：歌单 + 曲目。
public struct PlaylistDetailDto: Codable, Equatable, Sendable {
    public let playlist: PlaylistDto
    public let tracks: [TrackDto]?

    enum CodingKeys: String, CodingKey {
        case playlist
        case tracks
    }
}

/// 词表条目（真实响应：`{id,label,aliases,active,source,sortOrder,version}`，无 null）。
public struct TaxonomyTermDto: Codable, Equatable, Sendable {
    public let id: String
    public let label: String?
    public let aliases: [String]?
    public let active: Bool?
    public let source: String?
    public let sortOrder: Int?
    public let version: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case aliases
        case active
        case source
        case sortOrder
        case version
    }
}

/// 词表 12 维度。维度全部可选，容忍后端增删维度（真实响应 12 维齐全）。
public struct TaxonomyDimensionsDto: Codable, Equatable, Sendable {
    public let scene: [TaxonomyTermDto]?
    public let mood: [TaxonomyTermDto]?
    public let genre: [TaxonomyTermDto]?
    public let subgenre: [TaxonomyTermDto]?
    public let style: [TaxonomyTermDto]?
    public let instrument: [TaxonomyTermDto]?
    public let attribute: [TaxonomyTermDto]?
    public let energy: [TaxonomyTermDto]?
    public let tag: [TaxonomyTermDto]?
    public let vocalType: [TaxonomyTermDto]?
    public let type: [TaxonomyTermDto]?
    public let musicalKey: [TaxonomyTermDto]?

    enum CodingKeys: String, CodingKey {
        case scene
        case mood
        case genre
        case subgenre
        case style
        case instrument
        case attribute
        case energy
        case tag
        case vocalType
        case type
        case musicalKey
    }
}

/// `GET /api/library/taxonomy` 响应封套（真实响应：`{taxonomy:{…}}`）。
public struct TaxonomyDto: Codable, Equatable, Sendable {
    public let taxonomy: TaxonomyDimensionsDto

    enum CodingKeys: String, CodingKey {
        case taxonomy
    }
}
