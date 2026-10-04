import CovaCore
import Foundation
import XCTest

@testable import CovaFeature

/// 20 屏行 ⋯ 菜单的项集判据（2026-10-01 C2：行内收敛为 ⋯ 一枚钮之后，
/// 「菜单里有什么、什么顺序、什么条件下不出现」成了这一屏唯一的行级契约 ⇒ 钉成纯函数用例）。
///
/// 钉的是**判据层**（TD-48：CovaFeature 没有 UI 测试目标，「点开 ⋯ 之后看到什么」
/// 的另一面由 `CovaAcceptanceTests` 的设备腿负责）。
final class WorksRowMenuItemTests: XCTestCase {

    private func row(_ body: String) throws -> WorksListRowDto {
        try JSONDecoder().decode(WorksListRowDto.self, from: Data(body.utf8))
    }

    /// 一行可播的正身候选（生产实测形态：站内相对 `audioUrl` + `intent=play`）。
    private let playableJSON = """
    {"id":"job-a:cand-1","jobId":"job-a","status":"succeeded","title":"夏夜城市",\
    "audioUrl":"/api/media/objects/mo_1?ref=mr_1&intent=play","instrumental":false,\
    "lyrics":"第一行","source":"studio-create"}
    """

    /// 全量行：播放 + 保存 + 喜欢 + 不喜欢 + 笔记 + 歌词 + 补充制作，顺序钉死。
    func testPlayableRowGetsTheFullClipMenuInOrder() throws {
        let items = WorksRowMenuItem.items(
            for: try row(playableJSON),
            favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
        )
        XCTAssertEqual(items, [
            .play, .save(false), .favorite(false), .dislike(false), .note(false), .lyrics, .extras
        ])
    }

    /// 「已选/已存/已做成笔记」只是**标签翻面**，项集不变（菜单里没有"换一个动作"那回事）。
    func testSelectedStatesFlipLabelsNotMembership() throws {
        let items = WorksRowMenuItem.items(
            for: try row(playableJSON),
            favoriteOn: true, dislikeOn: true, saved: true, noteDone: true
        )
        XCTAssertEqual(items, [
            .play, .save(true), .favorite(true), .dislike(true), .note(true), .lyrics, .extras
        ])
    }

    /// 不可播的行：没有「播放」也没有「保存到本机」——给一枚点了没反应的钮不如没有。
    /// （占位行/failed 行在视图层连 ⋯ 都不出，这里钉的是"假设给了"的判据面。）
    func testUnplayableRowDropsPlayAndSaveButKeepsSignals() throws {
        let pending = try row("""
            {"id":"job-b:pending-1","jobId":"job-b","status":"processing","title":null,\
            "audioUrl":null,"instrumental":false,"lyrics":"词"}
            """)
        let items = WorksRowMenuItem.items(
            for: pending,
            favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
        )
        XCTAssertEqual(items, [.favorite(false), .dislike(false), .note(false), .lyrics])
        XCTAssertFalse(items.contains(.play))
        XCTAssertFalse(items.contains(.save(true)) || items.contains(.save(false)))
    }

    /// 纯音乐且没有词 ⇒ 「歌词」项不出（07 §3.H 同判据）；纯音乐**有**词 ⇒ 照常给。
    func testInstrumentalWithoutLyricsDropsTheLyricsItem() throws {
        let instrumentalMute = try row("""
            {"id":"job-c:cand-1","jobId":"job-c","status":"succeeded","title":"纯音乐",\
            "audioUrl":"/api/media/objects/mo_2?ref=mr_2&intent=play","instrumental":true,\
            "source":"studio-create"}
            """)
        let items = WorksRowMenuItem.items(
            for: instrumentalMute,
            favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
        )
        XCTAssertFalse(items.contains(.lyrics))

        let instrumentalWithWords = try row("""
            {"id":"job-d:cand-1","jobId":"job-d","status":"succeeded","title":"纯音乐",\
            "audioUrl":"/api/media/objects/mo_3?ref=mr_3&intent=play","instrumental":true,\
            "lyrics":"（有唱段）","source":"studio-create"}
            """)
        XCTAssertTrue(
            WorksRowMenuItem.items(
                for: instrumentalWithWords,
                favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
            ).contains(.lyrics)
        )
    }

    /// 「补充制作」只给**正身候选行**：裸 jobId 在服务端 404（§4.7），
    /// `one-step`/`song-match` 来源的行也不在 extras 的射程内由 `isRealCandidateRow` 判掉。
    func testExtrasItemOnlyForRealCandidateRows() throws {
        let bareJob = try row("""
            {"id":"job-e","jobId":"job-e","status":"succeeded","title":"裸 job 行",\
            "audioUrl":"/api/media/objects/mo_4?ref=mr_4&intent=play",\
            "instrumental":false,"lyrics":"词","source":"studio-create"}
            """)
        let items = WorksRowMenuItem.items(
            for: bareJob,
            favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
        )
        XCTAssertFalse(items.contains(.extras), "裸 jobId 行给「补充制作」必然 404")

        let failedRow = try row("""
            {"id":"job-f:cand-1","jobId":"job-f","status":"failed","title":"失败行",\
            "audioUrl":null,"errorMessage":"生成失败"}
            """)
        XCTAssertFalse(
            WorksRowMenuItem.items(
                for: failedRow,
                favoriteOn: false, dislikeOn: false, saved: false, noteDone: false
            ).contains(.extras),
            "失败行没有音频，extras 无从谈起"
        )
    }
}
