import Foundation

// MARK: - 曲目收藏（api-contracts 2：`GET/POST/DELETE /api/favorites`，需登录）

/// `GET /api/favorites` 响应。
///
/// **契约目标形态 + 已知偏差**：真实实现会额外混入「生成音乐收藏」条目
/// （带 `source: "note"` / `noteId`，字段集与 `TrackDto` 不同）；该变体未能只读实测，
/// 已登记 `docs/NEEDS.md`（`FAVORITES-NOTE-ITEMS`），此处只建模库曲条目。
public struct FavoritesListDto: Codable, Equatable, Sendable {
    public let tracks: [TrackDto]

    enum CodingKeys: String, CodingKey {
        case tracks
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
