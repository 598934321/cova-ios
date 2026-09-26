@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/play-history` 的混排分型解码（DEVELOPMENT.md A1）。
///
/// 本文件钉的不是「能解出来」，而是**三件会被静默吃掉的事实**：
/// ① 库曲 DTO 直解作品行会抛 ⇒ 整份 items 全丢（不是丢一行）——所以宽松投影是承重墙；
/// ② 作品行的权威标位是 `track.workId`，**不是**「trackId 含 `:`」（裸 jobId 行不含冒号）；
/// ③ 一行坏数据不许连累同批其它行，且少掉的行数必须**可解释**（`unreadableItemCount`）。
final class PlayHistoryDTOTests: XCTestCase {

    // MARK: - ① 混排：库曲行与作品行都不丢

    func testMixedFeedKeepsBothLibraryAndWorkRows() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-mixed")
        XCTAssertEqual(page.authenticated, true)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.items.count, 3, "混排三行一行都不许丢")
        XCTAssertEqual(page.unreadableItemCount, 0)
        XCTAssertEqual(page.workItemCount, 2)
        XCTAssertEqual(page.libraryItemCount, 1)
    }

    /// 承重墙自证：把作品行的 `track` 交给**库曲 DTO** 必须解码失败。
    ///
    /// 撤掉宽松投影（改成 `track: TrackDto?`）⇒ 这条与上面那条一起红：
    /// 前者证明「naive 路径真的坏」，后者证明「坏起来是整份历史全丢」。
    func testLibraryTrackDtoCannotDecodeTheWorkProjection() throws {
        let workTrackJSON = try Self.subJSON("play-history-mixed", path: ["items", "0", "track"])
        XCTAssertThrowsError(
            try JSONDecoder().decode(TrackDto.self, from: workTrackJSON),
            "作品行的 track 投影若能被库曲 DTO 解出来，本层的分型就是装饰"
        )
        // 同一份 fixture 里的库曲行必须能被库曲 DTO 解出来（否则上面那条红的是别的原因）。
        let libraryTrackJSON = try Self.subJSON("play-history-mixed", path: ["items", "1", "track"])
        let library = try JSONDecoder().decode(TrackDto.self, from: libraryTrackJSON)
        XCTAssertEqual(library.id, "library-334cbf73cab881cd48fba970")
    }

    // MARK: - ② 分型判据：workId 是权威，冒号只是兜底

    func testWorkRowIsRecognisedByWorkIdAndSplitsPseudoTrackId() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-mixed")
        let work = try XCTUnwrap(page.items.first)
        XCTAssertEqual(work.rowKind, .work)
        XCTAssertTrue(work.isWorkRow)
        XCTAssertEqual(work.trackId, "job-test-0001:cand-1")
        XCTAssertEqual(work.workJobId, "job-test-0001")
        XCTAssertEqual(work.workCandidateId, "cand-1")
        XCTAssertTrue(work.isPlayable)
        XCTAssertEqual(work.track?.workId, "job-test-0001:cand-1")
    }

    /// 手册 §4.3 把「trackId 含 `:`」当成 work 行的定义 —— **不完整**。
    /// 裸 jobId 也被服务端记进 `work_listens`（`play-history.ts:50` 的 `jobExists` 那一支），
    /// 且当 `result_audio_url` 非空时照样出现在 GET 里。那种行只能靠 `workId` 认出来，
    /// 而它**不能**拿去播（服务端可能因取不到候选音频而丢行）。
    func testBareJobIdRowIsStillWorkButNotPlayable() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-mixed")
        let bare = try XCTUnwrap(page.items.last)
        XCTAssertEqual(bare.trackId, "job-test-0002")
        XCTAssertFalse(bare.trackId.contains(":"), "这条 fixture 的前提就是不含冒号")
        XCTAssertEqual(bare.rowKind, .work, "没有冒号也必须靠 workId 认成作品行")
        XCTAssertEqual(bare.workJobId, "job-test-0002")
        XCTAssertNil(bare.workCandidateId)
        XCTAssertFalse(bare.isPlayable)
    }

    func testLibraryRowIsRecognisedAndResolvesDisplayFields() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-mixed")
        let library = try XCTUnwrap(page.items.dropFirst().first)
        XCTAssertEqual(library.rowKind, .library)
        XCTAssertNil(library.workJobId)
        XCTAssertNil(library.workCandidateId)
        XCTAssertTrue(library.isPlayable)
        // 实测（2026-09-26 生产只读探针，`GET /api/play-history?limit=5`，4/4 行都是这个形状）：
        // 库曲行的 `track` 里 **`workId` 这个键是存在的、值为 null** ⇒ 判别只能是"非空字符串"，
        // 不能是"键在不在"（按存在性判会把每一条库曲行都认成作品行）。
        XCTAssertNil(library.track?.workId)
        XCTAssertEqual(library.track?.displayTitle, "沿海公路", "中文标题优先")
        XCTAssertEqual(library.track?.displayArtist, "极光原野", "扁平中文名优先于艺人对象")
    }

    /// 作品行的 `artist`/`artistName`/`artistNameCn` 恒 null ⇒ 艺人名解不出来就是 nil。
    /// UI 必须自己决定占位，**不许**由 DTO 编一个「未知艺人」（不编造边界）。
    func testWorkRowHasNoArtistAndNoBpmOrWaveform() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-mixed")
        let work = try XCTUnwrap(page.items.first)
        let track = try XCTUnwrap(work.track)
        XCTAssertNil(track.displayArtist)
        XCTAssertNil(track.artist)
        XCTAssertNil(track.artistId)
        XCTAssertEqual(track.displayTitle, "夏日信号")
        XCTAssertEqual(track.duration, 118.4)
        // bpm / waveformPeaks / favoriteCount 在作品行恒空，而本投影**根本不建模**它们
        // ⇒ 「作品行不渲染 bpm/波形」是结构性的，不靠 UI 自觉。
        let keys = try Self.decodedKeys(of: track)
        XCTAssertFalse(keys.contains("bpm"))
        XCTAssertFalse(keys.contains("waveformPeaks"))
        XCTAssertFalse(keys.contains("favoriteCount"))
    }

    /// `track` 投影缺失时，冒号兜底判据仍要认得出作品行（服务端两张表的合流不是恒有 track）。
    func testColonFallbackClassifiesWorkRowWhenTrackProjectionIsMissing() {
        let item = PlayHistoryItemDto(
            id: nil, trackId: "job-x:cand-y", playedAt: nil, source: nil, track: nil
        )
        XCTAssertEqual(item.rowKind, .work)
        XCTAssertEqual(item.workCandidateId, "cand-y")
        let library = PlayHistoryItemDto(
            id: nil, trackId: "library-1", playedAt: nil, source: nil, track: nil
        )
        XCTAssertEqual(library.rowKind, .library)
    }

    // MARK: - ③ 一行坏数据不连累同批，且少掉的行可解释

    func testGarbageRowsAreCountedNotSilentlyDropped() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-garbage-rows")
        XCTAssertEqual(page.items.count, 1, "四个读不出身份的元素之后的那行必须还活着")
        XCTAssertEqual(page.unreadableItemCount, 4)
        XCTAssertEqual(page.items.first?.trackId, "library-survivor")
        // 服务端 `total` 与本地可读行数的落差由 unreadable 解释，不是凭空少了。
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.items.count + page.unreadableItemCount, page.total)
    }

    func testUnauthenticatedShapeHasNoTotalAndNoItems() throws {
        let page = try Fixture.decode(PlayHistoryPageDto.self, "play-history-unauthenticated")
        XCTAssertEqual(page.authenticated, false)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.unreadableItemCount, 0)
        XCTAssertNil(page.total, "401 那一档服务端不回 total（route.ts:16）")
    }

    /// `source` 是服务端回显，刻意松散：别的客户端写进去的值不许让整行解不出来。
    func testUnknownSourceValueDoesNotBreakTheRow() throws {
        let data = Data(#"{"items":[{"trackId":"library-1","source":"some-future-client"}]}"#.utf8)
        let page = try JSONDecoder().decode(PlayHistoryPageDto.self, from: data)
        XCTAssertEqual(page.items.first?.source, "some-future-client")
        XCTAssertEqual(page.items.first?.rowKind, .library)
    }

    // MARK: - 夹具助手（只读 fixture 的子路径，不打印任何值）

    private static func subJSON(_ fixture: String, path: [String]) throws -> Data {
        var node = try Fixture.value(fixture)
        for component in path {
            if let index = Int(component), let array = node as? [Any] {
                node = try XCTUnwrap(array.indices.contains(index) ? array[index] : nil, "路径越界：\(path)")
            } else if let object = node as? [String: Any] {
                node = try XCTUnwrap(object[component], "缺键：\(component)")
            } else {
                XCTFail("路径不可走：\(path)")
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "fixture 路径不可走")
                )
            }
        }
        return try JSONSerialization.data(withJSONObject: node)
    }

    /// 用反射读出**已建模**的键名（不是 JSON 里的键）——用于钉「本投影刻意不建模某些字段」。
    private static func decodedKeys(of track: PlayHistoryTrackDto) throws -> Set<String> {
        Set(Mirror(reflecting: track).children.compactMap(\.label))
    }
}
