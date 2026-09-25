import CovaCore
import CovaUI
import XCTest

@testable import CovaFeature

/// 06 §3.E 操作行的判据面（`PlaylistActionRowFacts`）：符号、文案、禁用位、AX 形态、连点吞击。
/// 只钉判据层 —— §9 的三条判据（书签不混爱心、空歌单保留操作行、AX5 档堆叠）里能静态化的部分。
/// `body` 有没有把它们摆对，本目标没有 UI 快照框架，不在此声称。
final class PlaylistActionRowFactsTests: XCTestCase {

    // MARK: - §3.E 符号裁决（§9 判据：全站不混用）

    func testPlaylistSaveButtonIsABookmarkNeverAHeart() {
        XCTAssertEqual(PlaylistActionRowFacts.bookmarkSymbol(saved: true), "bookmark.fill")
        XCTAssertEqual(PlaylistActionRowFacts.bookmarkSymbol(saved: false), "bookmark")
        // 这一条防的是"顺手改成爱心"：爱心在 03/07 是**曲目**收藏，两处同形用户分不开。
        XCTAssertFalse(PlaylistActionRowFacts.bookmarkSymbol(saved: true).contains("heart"))
        XCTAssertFalse(PlaylistActionRowFacts.bookmarkSymbol(saved: false).contains("heart"))
    }

    func testSaveButtonCopyComesFromTheSpecList() {
        // §8 文案清单只有 `收藏` / `已收藏`；§6 朗读要「收藏歌单，按钮，已选中/未选中」。
        XCTAssertEqual(PlaylistActionRowFacts.saveTitle(saved: true), "已收藏")
        XCTAssertEqual(PlaylistActionRowFacts.saveTitle(saved: false), "收藏")
        XCTAssertEqual(PlaylistActionRowFacts.saveValue(saved: true), "已选中")
        XCTAssertEqual(PlaylistActionRowFacts.saveValue(saved: false), "未选中")
    }

    // MARK: - §6 Dynamic Type（§9 判据：AX5 档下操作行堆叠）

    func testOnlyAXSizeStacksTheTwoButtons() {
        XCTAssertTrue(PlaylistActionRowFacts.stacksVertically(axLayout: true))
        XCTAssertFalse(PlaylistActionRowFacts.stacksVertically(axLayout: false))
    }

    // MARK: - §4 空态与 §8 并发

    /// §4：0 首时只有「播放全部」禁用；收藏钮**照常可点**（空歌单也可以收藏这个歌单）。
    func testEmptyPlaylistDisablesPlayAllButNotSaving() {
        XCTAssertFalse(PlaylistActionRowFacts.playAllEnabled(hasTracks: false))
        XCTAssertTrue(PlaylistActionRowFacts.playAllEnabled(hasTracks: true))
        XCTAssertTrue(PlaylistActionRowFacts.acceptsSaveTap(inFlight: false))
    }

    /// §8：连点收藏时第二次点击被吞（按钮已在 loading 里）。
    func testSecondSaveTapWhileInFlightIsSwallowed() {
        XCTAssertFalse(PlaylistActionRowFacts.acceptsSaveTap(inFlight: true))
    }

    /// §3.E「同高 50」+ TG-07 按钮高度档：两枚都要是 50，不是 `CovaButton` 那一档 44。
    func testBothActionButtonsCarryTheTG07Height() {
        XCTAssertEqual(PlaylistPrimaryCapsuleButton.height, 50)
        XCTAssertEqual(PlaylistSecondaryCapsuleButton.height, 50)
    }
}
