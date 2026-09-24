import CovaCore
import XCTest

final class CollectionDTOTests: XCTestCase {
    // MARK: - 曲目收藏（契约目标形态）

    func testDecodesFavoritesList() throws {
        let list = try Fixture.decode(FavoritesListDto.self, "favorites-list")
        XCTAssertEqual(list.tracks.count, 1)
        XCTAssertEqual(list.tracks[0].id, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(list.tracks[0].featured, false)
        XCTAssertEqual(list.items.count, 1, "纯库曲 feed 也逐条成型")
        guard case .library = list.items[0] else { return XCTFail("库曲投影的条目必须解成 .library") }
    }

    // MARK: - 合并 feed：`{tracks}` 里混着「库曲收藏」与「生成笔记收藏」（E3b）
    //
    // 依据 2026-09-24 真实抓取（登录态 `GET /api/favorites`，本文件只留键名与占位值）：
    // 笔记条目 `artist` 恒 `null`、`bpm` 恒 `null`、`duration` 恒 `0`，
    // 且**根本没有** `favoriteCount` / `energy` / `tags` / `previewStart` / `previewEnd` 这些键。
    // 旧模型是 `[TrackDto]`（那些键必填）⇒ 一条笔记条目让整个收藏屏报解码失败。

    /// 抓取到的 note 条目形状（键名/值类型照抄，地址一律换成占位路径，不含真实签名）。
    private static let noteItemJSON = """
    {
      "addedAt": "2026-09-24T10:12:30.000Z",
      "artist": null,
      "artistId": null,
      "artistName": "",
      "artistNameCn": "占位作者",
      "audioUrl": "/api/proxy/audio?url=https%3A%2F%2Fcdn.invalid%2Fsample.mp3&exp=1790000000000&sig=SIG_PLACEHOLDER",
      "bpm": null,
      "concreteTrackId": null,
      "cover": "/audio/cover-sample.jpg",
      "createdAt": "2026-09-24T09:00:00.000Z",
      "displayLabels": [],
      "duration": 0,
      "favorited": true,
      "groupCandidateKey": null,
      "groupDisplay": false,
      "groupKey": null,
      "groupSize": 1,
      "highlightEnd": 0,
      "highlightStart": 0,
      "id": "note:1f0e9a6c-77e0-4d4c-a1a2-3b4c5d6e7f80",
      "lyrics": null,
      "moods": [],
      "noteId": "1f0e9a6c-77e0-4d4c-a1a2-3b4c5d6e7f80",
      "playlistItemId": null,
      "scenes": [],
      "sortOrder": 0,
      "source": "note",
      "title": "雨夜地铁的哼唱",
      "titleCn": "雨夜地铁的哼唱",
      "variantCount": 1,
      "variantGroupId": null,
      "variantRole": null,
      "vocalType": "vocal",
      "waveformPeaks": []
    }
    """

    private static let noteID = "1f0e9a6c-77e0-4d4c-a1a2-3b4c5d6e7f80"

    private func noteItemValue() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.noteItemJSON.utf8)) as? [String: Any]
        )
    }

    /// 真实库曲条目（fixture 回灌）+ 抓取的笔记条目，按服务端顺序混排。
    private func mixedFavoritesData() throws -> Data {
        let root = try Fixture.value("favorites-list") as? [String: Any]
        let library = try XCTUnwrap(root?["tracks"] as? [[String: Any]])
        let merged = library + [try noteItemValue()]
        return try XCTUnwrap(JSONSerialization.data(withJSONObject: ["tracks": merged]))
    }

    /// (i) 一条笔记 + 一条库曲 ⇒ 整份数组解得开，两类各归各型。
    func testMergedFavoritesFeedDecodesBothItemKinds() throws {
        let list = try JSONDecoder().decode(FavoritesListDto.self, from: try mixedFavoritesData())
        XCTAssertEqual(list.items.count, 2, "合并 feed 的两条都要活下来（丢行=藏起用户的收藏）")
        guard case .library(let track) = list.items[0] else {
            return XCTFail("第 1 条应是库曲条目，实际 \(list.items[0])")
        }
        guard case .note(let note) = list.items[1] else {
            return XCTFail("第 2 条应是笔记条目，实际 \(list.items[1])")
        }
        XCTAssertEqual(track.id, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(note.id, "note:\(Self.noteID)")
        XCTAssertEqual(list.tracks.map(\.id), [track.id], "库曲账本只认库曲条目")

        // 认得出的行：标题 / 封面 / 时长面（12a §C）。
        XCTAssertEqual(note.displayTitle, "雨夜地铁的哼唱")
        XCTAssertEqual(note.cover, "/audio/cover-sample.jpg")
        XCTAssertNil(note.displayDuration, "服务端发 duration=0（未分析）⇒ 当未知，不渲染 0s")
        XCTAssertEqual(note.favorited, true)
        XCTAssertEqual(note.noteIdentifier, Self.noteID)
    }

    /// 真实投影守卫：抓到的形状不许被后来人"顺手改整齐"。
    func testNoteItemFixtureKeepsCapturedShape() throws {
        let note = try noteItemValue()
        XCTAssertNil(note["favoriteCount"], "笔记条目不带 favoriteCount")
        XCTAssertNil(note["energy"], "笔记条目不带 energy")
        XCTAssertNil(note["tags"], "笔记条目不带 tags")
        XCTAssertNil(note["previewStart"])
        XCTAssertNil(note["previewEnd"])
        XCTAssertTrue(note["artist"] is NSNull, "artist 恒为 null（不是缺键）")
        XCTAssertTrue(note["bpm"] is NSNull)
        XCTAssertEqual(note["source"] as? String, "note")
        XCTAssertEqual((note["id"] as? String)?.hasPrefix("note:"), true)
        // 同数组里的库曲条目恰恰相反：这些键都在，且 artist 非 null。
        let root = try Fixture.value("favorites-list") as? [String: Any]
        let library = try XCTUnwrap((root?["tracks"] as? [[String: Any]])?.first)
        XCTAssertNotNil(library["favoriteCount"])
        XCTAssertNotNil(library["energy"])
        XCTAssertNotNil(library["tags"])
        XCTAssertFalse(library["artist"] is NSNull)
    }

    /// (ii) 服务端**没给**的字段保持缺席 —— 模型里连属性都不许有（有了就会被渲染成 0/空 的假值），
    /// 服务端给了 `null` 的字段解成 `nil`（不是 0、不是 ""）。
    func testAbsentFieldsStayAbsentRatherThanFabricated() throws {
        let list = try JSONDecoder().decode(FavoritesListDto.self, from: try mixedFavoritesData())
        guard case .note(let note) = list.items.last else { return XCTFail("应为笔记条目") }
        let modeled = Set(Mirror(reflecting: note).children.compactMap(\.label))
        for absent in ["favoriteCount", "energy", "tags", "previewStart", "previewEnd", "artist"] {
            XCTAssertFalse(modeled.contains(absent), "服务端不发 \(absent) ⇒ 模型里不得有它")
        }
        XCTAssertNil(note.bpm, "bpm 给了 null ⇒ nil，不是 0")
        XCTAssertNil(note.lyrics)
    }

    /// 判别腿本身：`source` 与 `note:` 前缀**任一**成立即算笔记条目（服务端两件都给）。
    func testNoteItemDetectedBySourceEvenWithoutIDPrefix() throws {
        var note = try noteItemValue()
        note["id"] = Self.noteID          // 没有 note: 前缀
        note["noteId"] = Self.noteID
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: ["tracks": [note]]))
        let list = try JSONDecoder().decode(FavoritesListDto.self, from: data)
        guard case .note = list.items.first else { return XCTFail("source=note 就足以判成笔记条目") }
        XCTAssertEqual(list.items.first?.route, .generatedNote(noteID: Self.noteID))
        XCTAssertEqual(list.tracks.count, 0, "绝不能被当进库曲账本")
    }

    /// `id` 缺席、`noteId` 在 ⇒ 按服务端自己的构造式（`id = "note:" + noteId`）补出同值。
    func testNoteItemDerivesIDFromNoteIDWhenIDLacks() throws {
        var note = try noteItemValue()
        note.removeValue(forKey: "id")
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: ["tracks": [note]]))
        let list = try JSONDecoder().decode(FavoritesListDto.self, from: data)
        guard case .note(let decoded) = list.items.first else { return XCTFail("应为笔记条目") }
        XCTAssertEqual(decoded.id, "note:\(Self.noteID)")
        XCTAssertEqual(list.items.first?.route, .generatedNote(noteID: Self.noteID))
    }

    /// 身份取不到 ⇒ 整屏报错，**不**猜一个 id、也不丢行。
    func testNoteItemWithoutAnyIdentifierFailsDecoding() throws {
        var note = try noteItemValue()
        note.removeValue(forKey: "id")
        note.removeValue(forKey: "noteId")
        let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: ["tracks": [note]]))
        XCTAssertThrowsError(try JSONDecoder().decode(FavoritesListDto.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "应为 DecodingError，实际 \(error)")
        }
    }

    // MARK: (iii) 收藏动作按种类路由

    func testNoteFavoriteTargetsNoteEndpointAndNeverLibraryPath() throws {
        let route = FavoriteMutationRoute.route(favoriteID: "note:\(Self.noteID)")
        XCTAssertEqual(route, .generatedNote(noteID: Self.noteID))
        XCTAssertEqual(route?.path, "/api/notes/\(Self.noteID)/favorite")
        XCTAssertNotEqual(route?.path, FavoriteMutationRoute.libraryPath)
        // 条目面同一口径（视图拿条目、服务拿 id，两条腿不能给出两个落点）。
        let list = try JSONDecoder().decode(FavoritesListDto.self, from: try mixedFavoritesData())
        XCTAssertEqual(list.items[1].route, .generatedNote(noteID: Self.noteID))
        XCTAssertEqual(list.items[0].route, .libraryTrack(trackID: list.tracks[0].id))
        // 落点必须真的能出站（不是只拼出个字符串）。
        let url = try XCTUnwrap(CovaEnvironment.makeAPIURL(path: try XCTUnwrap(route).path))
        XCTAssertEqual(url.path, "/api/notes/\(Self.noteID)/favorite")
        XCTAssertEqual(url.host, "covalink.cn")
    }

    func testLibraryFavoriteStillTargetsLibraryEndpoint() throws {
        XCTAssertEqual(
            FavoriteMutationRoute.route(favoriteID: "library-9749cdc210a624de9d0da02e"),
            .libraryTrack(trackID: "library-9749cdc210a624de9d0da02e")
        )
        XCTAssertEqual(
            FavoriteMutationRoute.route(favoriteID: "library-1")?.path,
            "/api/favorites"
        )
    }

    /// `note:` 前缀 + 不安全载荷 ⇒ **无处可去**：既不能进路径，也绝不回落到 `/api/favorites`
    /// （回落就是拿笔记 id 去打库曲端点 —— 实测 404，还会记错账）。
    func testUnsafeNotePayloadRoutesNowhere() throws {
        for payload in ["../../api/favorites", "a/b", "a?x=1", "a#b", "", " ", "a%2Fb", String(repeating: "n", count: 121)] {
            XCTAssertNil(
                FavoriteMutationRoute.route(favoriteID: "note:\(payload)"),
                "载荷「\(payload)」不得被拼进路径"
            )
        }
    }

    // MARK: - 笔记收藏端点的响应形态（与库曲端点不同：`{favorited[, cocreate]}`）

    func testNoteFavoriteMutationResponseDecodes() throws {
        let added = try JSONDecoder().decode(
            NoteFavoriteMutationDto.self,
            from: Data(#"{"favorited":true,"cocreate":{"status":"consent_required"}}"#.utf8)
        )
        XCTAssertEqual(added.favorited, true)
        let removed = try JSONDecoder().decode(
            NoteFavoriteMutationDto.self, from: Data(#"{"favorited":false}"#.utf8)
        )
        XCTAssertEqual(removed.favorited, false)
        let result = FavoriteMutationResultDto.note(removed)
        XCTAssertEqual(result.favorited, false)
        // 库曲那一型不回显收藏态（端点给的是 message/favoriteCount）⇒ 不假装有。
        let library = FavoriteMutationResultDto.library(
            FavoriteMutationResponseDto(message: "已取消收藏", favoriteCount: 3)
        )
        XCTAssertNil(library.favorited)
    }

    func testFavoriteMutationRequestUsesTrackIdKey() throws {
        let request = FavoriteMutationRequestDto(trackId: "library-1")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/favorite-mutation-request"
        )
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
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/saved-playlist-mutation-request"
        )
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
