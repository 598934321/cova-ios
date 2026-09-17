@testable import CovaCore
import XCTest

final class LibraryDTOTests: XCTestCase {
    func testDecodesTrackPage() throws {
        let page = try Fixture.decode(TrackPageDto.self, "track-page")
        XCTAssertEqual(page.tracks.count, 2)
        XCTAssertEqual(page.total, 19562)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.pageSize, 20)
        XCTAssertEqual(page.totalPages, 979)

        let full = page.tracks[0]
        XCTAssertEqual(full.id, "library-test-0001")
        XCTAssertEqual(full.titleCn, "金色灯塔")
        XCTAssertEqual(full.bpm, 76)
        XCTAssertEqual(full.duration, 209.592)
        XCTAssertEqual(full.favoriteCount, 3)
        XCTAssertEqual(full.scenes, ["悬疑惊悚"])
        XCTAssertEqual(full.moods, ["氛围"])
        XCTAssertEqual(full.displayLabels.count, 4)
        XCTAssertEqual(full.waveformPeaks, [0.17, 0.368, 0.5])
        XCTAssertEqual(full.previewStart, 167.02)
        XCTAssertEqual(full.previewEnd, 186.67)
        XCTAssertEqual(full.highlightStart, 167.02)
        XCTAssertEqual(full.highlightEnd, 186.67)
        XCTAssertEqual(full.vocalType, "instrumental")
        XCTAssertEqual(full.energy, "中")
        XCTAssertNil(full.lyrics)
        XCTAssertNil(full.description)
        XCTAssertNil(full.audioDuration)
        XCTAssertNil(full.lyricistName)
        XCTAssertEqual(full.variantCount, 0)
        XCTAssertEqual(full.variants?.count, 0)
        XCTAssertEqual(full.tags.count, 2)
        XCTAssertEqual(full.tags[0].dimension, "instrument")
        XCTAssertEqual(full.tags[0].value, "合成器")
        XCTAssertEqual(full.tags[0].trackId, "library-test-0001")
    }

    func testDecodesArtistSubObjectWithJsonEncodedFields() throws {
        let page = try Fixture.decode(TrackPageDto.self, "track-page")
        let artist = page.tracks[0].artist
        XCTAssertEqual(artist.id, "A07")
        XCTAssertEqual(artist.name, "Elise Moreau")
        XCTAssertEqual(artist.nameCn, "艾丽丝·莫罗")
        XCTAssertEqual(artist.country, "France")
        XCTAssertEqual(artist.userId, "user-artist-07")
        XCTAssertEqual(artist.coreInstruments, "[\"钢琴\",\"大提琴\"]")
    }

    func testToleratesMissingOptionalFieldsAndVariantFamily() throws {
        let page = try Fixture.decode(TrackPageDto.self, "track-page")
        let sparse = page.tracks[1]
        XCTAssertNil(sparse.titleCn)
        XCTAssertNil(sparse.key)
        XCTAssertNil(sparse.style)
        XCTAssertNil(sparse.lyrics)
        XCTAssertNil(sparse.description)
        XCTAssertEqual(sparse.vocalType, "vocal")
        XCTAssertEqual(sparse.variantGroupId, "group-01")
        XCTAssertEqual(sparse.variantRole, "A")
        XCTAssertEqual(sparse.variantCount, 2)
        XCTAssertEqual(sparse.variants?.count, 2)
        XCTAssertEqual(sparse.variants?[1].variantRole, "B")
        XCTAssertEqual(sparse.variants?[1].audioUrl, "https://cdn.invalid/audio/0002b.mp3")
    }

    func testTrackDetailOmitsVariantFamilyAndStillDecodes() throws {
        let detail = try Fixture.decode(TrackDetailDto.self, "track-detail")
        XCTAssertEqual(detail.track.id, "library-test-0001")
        XCTAssertNil(detail.track.variantGroupId)
        XCTAssertNil(detail.track.variantCount)
        XCTAssertNil(detail.track.variants)
        XCTAssertEqual(detail.similar?.count, 1)
        XCTAssertEqual(detail.similar?[0].id, "library-test-0004")
    }

    func testMissingRequiredTrackFieldFailsDecoding() {
        let json = Data(#"{"tracks":[{"title":"no id"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPageDto.self, from: json)) { error in
            guard let decoding = error as? DecodingError else { return XCTFail("应为 DecodingError") }
            XCTAssertEqual(CovaAPIError.classify(decoding: decoding), .decoding(field: "id"))
        }
    }

    func testDecodesPlaylistListWithSaveState() throws {
        let list = try Fixture.decode(PlaylistListDto.self, "playlists")
        XCTAssertEqual(list.playlists.count, 1)
        let playlist = list.playlists[0]
        XCTAssertEqual(playlist.id, "PL-test-01")
        XCTAssertEqual(playlist.titleCn, "明亮氛围感歌单")
        XCTAssertEqual(playlist.trackCount, 10)
        XCTAssertEqual(playlist.totalDuration, 1480.56)
        XCTAssertEqual(playlist.isSaved, false)
        XCTAssertEqual(playlist.writable, false)
        XCTAssertEqual(playlist.disabledReason, "官方歌单使用收藏")
        XCTAssertEqual(playlist.saveAction?.kind, "bookmark")
        XCTAssertEqual(playlist.saveAction?.endpoint, "/api/saved-playlists")
        XCTAssertEqual(playlist.saveAction?.addMethod, "POST")
        XCTAssertEqual(playlist.saveAction?.removeMethod, "DELETE")
        XCTAssertEqual(playlist.saveAction?.saved, false)
        XCTAssertEqual(playlist.coverMedia?.imageUrl, "https://cdn.invalid/covers/pl01.jpeg")
        XCTAssertEqual(playlist.coverMedia?.fit, "cover")
        XCTAssertEqual(playlist.coverMedia?.focalX, 50)
        XCTAssertEqual(playlist.coverMedia?.mode, "fallback")
        XCTAssertNil(playlist.coverMedia?.updatedAt)
        XCTAssertNil(playlist.coverDefault)
        XCTAssertNil(playlist.coverAlt)
        XCTAssertNil(playlist.coverUpdatedAt)
        XCTAssertNil(playlist.scene)
    }

    func testPlaylistDetailOmitsSaveStateAndStillDecodes() throws {
        let detail = try Fixture.decode(PlaylistDetailDto.self, "playlist-detail")
        XCTAssertEqual(detail.playlist.id, "PL-test-01")
        XCTAssertNil(detail.playlist.isSaved)
        XCTAssertNil(detail.playlist.writable)
        XCTAssertNil(detail.playlist.disabledReason)
        XCTAssertNil(detail.playlist.saveAction)
        XCTAssertEqual(detail.tracks?.count, 1)
        XCTAssertEqual(detail.tracks?[0].id, "library-test-0001")
    }

    func testDecodesTaxonomyTwelveDimensions() throws {
        let taxonomy = try Fixture.decode(TaxonomyDto.self, "taxonomy")
        let dims = taxonomy.taxonomy
        XCTAssertEqual(dims.scene?.count, 1)
        XCTAssertEqual(dims.mood?.count, 1)
        XCTAssertEqual(dims.genre?.count, 1)
        XCTAssertEqual(dims.subgenre?.count, 1)
        XCTAssertEqual(dims.style?.count, 1)
        XCTAssertEqual(dims.instrument?.count, 1)
        XCTAssertEqual(dims.attribute?.count, 1)
        XCTAssertEqual(dims.energy?.count, 1)
        XCTAssertEqual(dims.tag?.count, 1)
        XCTAssertEqual(dims.vocalType?.count, 1)
        XCTAssertEqual(dims.type?.count, 1)
        XCTAssertEqual(dims.musicalKey?.count, 1)

        let term = try XCTUnwrap(dims.subgenre?.first)
        XCTAssertEqual(term.id, "Neo Soul")
        XCTAssertEqual(term.label, "Neo Soul")
        XCTAssertEqual(term.aliases, ["parent:R&B"])
        XCTAssertEqual(term.active, true)
        XCTAssertEqual(term.source, "genre-vocab-v3")
        XCTAssertEqual(term.sortOrder, 0)
        XCTAssertEqual(term.version, 1)
    }

    func testTaxonomyToleratesMissingDimensionsAndTerms() throws {
        let json = Data(#"{"taxonomy":{"scene":[{"id":"x"}]}}"#.utf8)
        let taxonomy = try JSONDecoder().decode(TaxonomyDto.self, from: json)
        XCTAssertEqual(taxonomy.taxonomy.scene?.count, 1)
        XCTAssertEqual(taxonomy.taxonomy.scene?[0].id, "x")
        XCTAssertNil(taxonomy.taxonomy.scene?[0].label)
        XCTAssertNil(taxonomy.taxonomy.genre)
        XCTAssertNil(taxonomy.taxonomy.musicalKey)
    }

    func testMissingTaxonomyEnvelopeFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(TaxonomyDto.self, from: Data("{}".utf8)))
    }
}
