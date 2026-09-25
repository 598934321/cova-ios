import Foundation
import XCTest

@testable import CovaCore

/// 01 §5「你的创作」的取值面（对应 `HomeSectionFacts.swift` 的 `HomeCreationGrid`
/// 与 `PixelCoverFacts`）。
///
/// 这一组测试里最要紧的一条其实是**否定式**的：状态徽标与封面在今天的真实数据上都出不来，
/// 因为后端那份列表压根不给这两个字段。测试钉的是"拿不到就不画"，
/// 不是"画得出来"——后者要靠假数据才做得到，而那正是本仓明令不许的事。
final class HomeCreationGridTests: XCTestCase {

    /// §5 三档的取值域 = 后端自己的任务态词表（`GenerationJobStatus`，逐字对齐后端）。
    func testBadgeCoversTheThreeSpecBuckets() {
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: "queued"), .generating)
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: "submitted"), .generating)
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: "processing"), .generating)
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: "succeeded"), .done)
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: "failed"), .failed)
    }

    /// 「取消」既不是生成中也不是失败 ⇒ 三档装不下它，就不出徽标（硬贴一个色是把未知画成已知）。
    /// 认不出的值、空、纯空白同样不出；**英文态名一次都不会上屏**。
    func testUnknownOrUnmappableStatusProducesNoBadge() {
        XCTAssertNil(HomeCreationGrid.badge(forStatus: "cancelled"))
        XCTAssertNil(HomeCreationGrid.badge(forStatus: nil))
        XCTAssertNil(HomeCreationGrid.badge(forStatus: ""))
        XCTAssertNil(HomeCreationGrid.badge(forStatus: "   "))
        XCTAssertNil(HomeCreationGrid.badge(forStatus: "someBrandNewState"))
        XCTAssertNil(HomeCreationGrid.badge(forStatus: "PROCESSING"))   // 不猜大小写等价
    }

    func testBadgeLabelsAreTheSpecThreeWords() {
        XCTAssertEqual(HomeCreationGrid.label(of: .generating), "生成中")
        XCTAssertEqual(HomeCreationGrid.label(of: .done), "完成")
        XCTAssertEqual(HomeCreationGrid.label(of: .failed), "失败")
    }

    /// 「生成中」与 08 §3.C 那一批发在 `StudioSessionProgressRing.runningLabel` 的常量
    /// 是**同一个字符串**：同一句话在两屏长得不一样，就是文案漂移的开始。
    func testGeneratingLabelReusesSessionRowFactsConstant() {
        XCTAssertEqual(HomeCreationGrid.generatingLabel, StudioSessionProgressRing.runningLabel)
    }

    /// 两条"字段不存在"的实测事实钉成断言：DTO 补上 status / 封面那天，
    /// 这两条会红，逼着改动的人回来看 §5 的降级口径（而不是让徽标悄悄长成一个猜出来的色）。
    func testSessionListPayloadHasNeitherStatusNorCover() {
        XCTAssertFalse(HomeCreationGrid.statusFieldInListPayload)
        XCTAssertFalse(StudioSessionCover.hasCoverFieldInListPayload)
    }

    /// §5 第一行：双列 + 取最近若干条（条数是 UI 取舍，钉住它而不是让它长在视图体里）。
    func testGridShape() {
        XCTAssertEqual(HomeCreationGrid.columnCount, 2)
        XCTAssertEqual(HomeCreationGrid.cardLimit, 6)
    }

    // MARK: 像素占位

    /// Reduce Motion ⇒ 静态（§8「封面呼吸/渐变动画关闭，直接静态呈现」），
    /// 且静态值必须落在亮暗两档**之间**：呼吸停了，格子不能整片消失也不能整片涂死。
    func testPixelCoverStopsBreathingUnderReduceMotion() {
        for lit in [false, true] {
            for row in 0..<PixelCoverFacts.cellsPerSide {
                for column in 0..<PixelCoverFacts.cellsPerSide {
                    XCTAssertEqual(
                        PixelCoverFacts.cellAlpha(
                            row: row, column: column, lit: lit, reduceMotion: true
                        ),
                        PixelCoverFacts.cellAlphaStatic
                    )
                }
            }
        }
        XCTAssertGreaterThan(PixelCoverFacts.cellAlphaStatic, PixelCoverFacts.cellAlphaLow)
        XCTAssertLessThan(PixelCoverFacts.cellAlphaStatic, PixelCoverFacts.cellAlphaHigh)
    }

    /// 棋盘**互换**（§S1 不做扫过的具体形态）：半个周期后亮格与暗格对调，
    /// 相邻两格永远一明一暗 —— 没有方向性，也就读不出一道走过去的光。
    func testCheckerboardSwapsInsteadOfSweeping() {
        let darkEven = PixelCoverFacts.cellAlpha(row: 0, column: 0, lit: false, reduceMotion: false)
        let oddAfterSwap = PixelCoverFacts.cellAlpha(row: 0, column: 1, lit: true, reduceMotion: false)
        XCTAssertEqual(darkEven, oddAfterSwap)
        for column in 0..<PixelCoverFacts.cellsPerSide {
            let a = PixelCoverFacts.cellAlpha(row: 0, column: column, lit: false, reduceMotion: false)
            let b = PixelCoverFacts.cellAlpha(row: 0, column: column, lit: true, reduceMotion: false)
            XCTAssertNotEqual(a, b)
        }
    }

    /// 呼吸节奏与骨架屏同档（0.9s）：本 App 里"占位在呼吸"只有一种节奏。
    func testBreatheDurationMatchesSkeletonFamily() {
        XCTAssertEqual(PixelCoverFacts.breatheDuration, 0.9)
    }
}
