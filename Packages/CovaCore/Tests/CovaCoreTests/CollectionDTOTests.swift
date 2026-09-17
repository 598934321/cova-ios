@testable import CovaCore
import XCTest

final class CollectionDTOTests: XCTestCase {
    // MARK: - 曲目收藏（契约目标形态）

    func testDecodesFavoritesList() throws {
        let list = try Fixture.decode(FavoritesListDto.self, "favorites-list")
        XCTAssertEqual(list.tracks.count, 1)
        XCTAssertEqual(list.tracks[0].id, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(list.tracks[0].featured, false)
    }

    func testFavoriteMutationRequestUsesTrackIdKey() throws {
        let request = FavoriteMutationRequestDto(trackId: "library-1")
        let data = try JSONEncoder().encode(request)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(text, #"{"trackId":"library-1"}"#)
    }

    func testDecodesFavoriteMutationResponse() throws {
        let response = try Fixture.decode(FavoriteMutationResponseDto.self, "favorite-mutation-response")
        XCTAssertEqual(response.message, "收藏成功")
        XCTAssertEqual(response.favoriteCount, 1)

        let partial = try JSONDecoder().decode(FavoriteMutationResponseDto.self, from: Data("{}".utf8))
        XCTAssertNil(partial.message)
        XCTAssertNil(partial.favoriteCount)
    }

    // MARK: - 歌单收藏（契约目标形态）

    func testDecodesSavedPlaylistsWithSavedAt() throws {
        let list = try Fixture.decode(SavedPlaylistsListDto.self, "saved-playlists")
        XCTAssertEqual(list.playlists.count, 1)
        let playlist = list.playlists[0]
        XCTAssertEqual(playlist.id, "PL-20260917-09")
        XCTAssertEqual(playlist.savedAt, "2026-09-17T03:00:00.000Z")
        XCTAssertEqual(playlist.writable, false)
        XCTAssertEqual(playlist.saveAction?.saved, true)
        XCTAssertEqual(playlist.disabledReason, "收藏的官方歌单不可直接修改，请创建个人歌单后再加入")
        XCTAssertEqual(playlist.savedAt?.isEmpty, false)
    }

    func testSavedPlaylistMutationUsesPlaylistIdKey() throws {
        let request = SavedPlaylistMutationRequestDto(playlistId: "PL-1")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"playlistId":"PL-1"}"#)
    }

    func testDecodesSavedPlaylistMutationResponse() throws {
        let response = try Fixture.decode(
            SavedPlaylistMutationResponseDto.self,
            "saved-playlist-mutation-response"
        )
        XCTAssertEqual(response.saved, true)
        XCTAssertEqual(response.action, "bookmark")
        XCTAssertEqual(response.playlistId, "PL-20260917-09")

        let removed = try JSONDecoder().decode(
            SavedPlaylistMutationResponseDto.self,
            from: Data(#"{"saved":false,"playlistId":"PL-1","action":"bookmark"}"#.utf8)
        )
        XCTAssertEqual(removed.saved, false)
    }
}
