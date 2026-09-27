import XCTest
@testable import CovaCore

/// §5 P3「每日推荐 / 歌单广场 / 分享歌单详情」三条读面的契约面。
///
/// 真实形状取自 `../web`（就是线上那套）：
///   `src/app/api/playlists/daily/route.ts`、`.../public/route.ts`、`.../shared-playlists/[token]/route.ts`。
final class PlaylistDiscoveryDTOsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: daily

    func testDailyEnvelopeTakesDateAndItems() throws {
        let dto = try decode(
            DailyPlaylistsResponseDto.self,
            """
            {"date":"2026-09-27","items":[
              {"id":"pl-1","title":"Boundary Song","titleCn":"边界之歌","trackCount":12,
               "isSaved":false,"href":"/playlists/pl-1","source":"official"},
              {"id":"up-9","title":"My list","trackCount":3,
               "href":"/share/playlist/tk-abc","source":"shared"}]}
            """
        )
        XCTAssertEqual(dto.date, "2026-09-27")
        XCTAssertEqual(dto.items.count, 2)
        XCTAssertEqual(dto.items[0].playlist.id, "pl-1")
        XCTAssertEqual(dto.items[0].playlist.titleCn, "边界之歌")
        XCTAssertEqual(dto.items[0].source, .official)
        XCTAssertEqual(dto.items[1].source, .shared)
    }

    func testDailyEmptyItemsIsAnEmptyListNotAMissingEnvelope() throws {
        // 服务端在"今天没有推荐"时明确回 {date, items: []} ⇒ 屏上是空态，不是读失败。
        let dto = try decode(DailyPlaylistsResponseDto.self, #"{"date":"2026-09-27","items":[]}"#)
        XCTAssertTrue(dto.items.isEmpty)
    }

    func testOneBadPickDoesNotKillTheWholeDailyBoard() throws {
        let dto = try decode(
            DailyPlaylistsResponseDto.self,
            """
            {"date":"2026-09-27","items":[{"id":"a","title":"A"}, "字符串不是卡", {"id":"b","title":"B"}]}
            """
        )
        XCTAssertEqual(dto.items.map(\.playlist.id), ["a", "b"], "一条坏条目只丢它自己")
    }

    func testMissingItemsKeyDecodesToEmptyNotAnError() throws {
        let dto = try decode(DailyPlaylistsResponseDto.self, #"{"date":"2026-09-27"}"#)
        XCTAssertTrue(dto.items.isEmpty)
    }

    // MARK: source 与目标屏

    func testSourceKeepsUnrecognisedValuesInsteadOfFoldingThem() throws {
        XCTAssertEqual(PlaylistPickSource(raw: "official"), .official)
        XCTAssertEqual(PlaylistPickSource(raw: "shared"), .shared)
        XCTAssertEqual(PlaylistPickSource(raw: "partner"), .unknown("partner"))
        XCTAssertEqual(PlaylistPickSource(raw: nil), .unknown(""))
    }

    func testShareTokenComesOnlyFromASharedCardWithTheLandingShape() throws {
        let shared = try decode(
            PlaylistPickDto.self,
            #"{"id":"up-9","title":"T","href":"/share/playlist/tk-abc","source":"shared"}"#
        )
        XCTAssertEqual(shared.shareToken, "tk-abc")

        // 官方那张的 href 就是 /playlists/<id>：它不该有 token，也不该被拿去打分享端点。
        let official = try decode(
            PlaylistPickDto.self,
            #"{"id":"pl-1","title":"T","href":"/playlists/pl-1","source":"official"}"#
        )
        XCTAssertNil(official.shareToken, "official 卡不许产出一个 token")
    }

    func testShareTokenIgnoresAHrefThatOnlyLooksLikeTheLandingPage() throws {
        let weird = try decode(
            PlaylistPickDto.self,
            #"{"id":"up-9","title":"T","href":"/share/playlist/tk-abc/extra","source":"shared"}"#
        )
        XCTAssertNil(weird.shareToken, "尾巴上还有一段 ⇒ 不是我们认的那个形状，宁可不给")
    }

    func testUnsafeTokenNeverBecomesAPath() throws {
        // 与作品伪 id 同一把尺子：不能安全进路径段 ⇒ nil（不发），不自己编码绕过去。
        XCTAssertNil(SharedPlaylistResponseDto.path(token: "a/b"))
        XCTAssertNil(SharedPlaylistResponseDto.path(token: ""))
        XCTAssertNil(SharedPlaylistResponseDto.path(token: ".."))
        XCTAssertEqual(SharedPlaylistResponseDto.path(token: "tk-abc_1"), "/api/shared-playlists/tk-abc_1")
    }

    // MARK: date 参数

    func testDateIsSentOnlyWhenItIsTheOneShapeTheServerAccepts() {
        let sent = DailyPlaylistsResponseDto.queryItems(date: "2026-09-27")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.name, "date")
        XCTAssertEqual(sent.first?.value, "2026-09-27")
        // 服务端对别的形状回 400 ⇒ 客户端不发一次明知会 400 的请求，而是干脆不带这个参数。
        for bad in [nil, "", "2026-9-7", "2026/09/27", "2026-13-01", "2026-00-10", "2026-09-32",
                    "20260927", "2026-09-27T00:00", "２０２６-０９-２７"] {
            XCTAssertTrue(
                DailyPlaylistsResponseDto.queryItems(date: bad).isEmpty,
                "这个形状会被服务端 400：\(String(describing: bad))"
            )
        }
    }

    // MARK: public

    func testPublicEnvelopeUsesPlaylistsNotItems() throws {
        let dto = try decode(
            PublicPlaylistsResponseDto.self,
            """
            {"playlists":[{"id":"up-1","title":"Shared one","trackCount":4,
              "href":"/share/playlist/tk-1","source":"shared"}]}
            """
        )
        XCTAssertEqual(dto.playlists.count, 1)
        XCTAssertEqual(dto.playlists[0].shareToken, "tk-1")
    }

    func testPublicEnvelopeWithoutTheKeyIsEmptyNotFailure() throws {
        XCTAssertTrue(try decode(PublicPlaylistsResponseDto.self, "{}").playlists.isEmpty)
    }

    // MARK: 分享详情（另一支封套：标题键是 name）

    func testSharedDetailReadsNameAndNotTitle() throws {
        let dto = try decode(
            SharedPlaylistResponseDto.self,
            """
            {"playlist":{"id":"up-1","name":"我的深夜歌单","description":"d",
              "creatorName":"爱丽丝","trackCount":2,"sharePath":"/share/playlist/tk-1","isOwner":false},
             "downloadCredits":20,"downloadsEnabled":true}
            """
        )
        XCTAssertEqual(dto.playlist?.name, "我的深夜歌单")
        XCTAssertEqual(dto.playlist?.creatorName, "爱丽丝")
        XCTAssertEqual(dto.downloadCredits, 20)
        XCTAssertEqual(dto.downloadsEnabled, true)
    }

    func testViewerIsOwnerIsTrueOnlyWhenTheServerSaidSo() throws {
        // 缺 isOwner / 缺整层 ⇒ 一律"不是主人"。反过来会把一整排编辑动作交给游客。
        let missing = try decode(SharedPlaylistResponseDto.self, #"{"playlist":{"id":"up-1"}}"#)
        XCTAssertFalse(missing.viewerIsOwner)
        let noPlaylist = try decode(SharedPlaylistResponseDto.self, #"{"tracks":[]}"#)
        XCTAssertFalse(noPlaylist.viewerIsOwner)
        let owner = try decode(
            SharedPlaylistResponseDto.self, #"{"playlist":{"id":"up-1","isOwner":true}}"#
        )
        XCTAssertTrue(owner.viewerIsOwner)
    }

    func testHalfATrackIsNoListAtAllRatherThanASilentRow() throws {
        // TrackDto 的必填面很宽（标题/时长/音频/艺人/波形…）。半首"能解出 id"的曲目
        // 画在屏上是一个点不动的行 ⇒ 整层读不出就按"没给曲目"处理，屏上那句是"曲目没取到"。
        let dto = try decode(
            SharedPlaylistResponseDto.self,
            #"{"playlist":{"id":"up-1","name":"N"},"tracks":[{"id":"t1"}]}"#
        )
        XCTAssertNil(dto.tracks, "读不完整的曲目层不许变成一个短了的列表")
        XCTAssertEqual(dto.playlist?.name, "N", "而头部该留着")
    }
}
