import CovaCore
import CovaUI
import XCTest

@testable import CovaFeature

/// 08 §3.C 会话行的几何档与 §3.C 封面降级（对应 `StudioViews.swift` 的 `SessionRowMetrics`）。
/// 只钉判据层：§9 的最后一条判据就是「全部值来自 token（抽查进度环线宽、行内边距、胶囊高度）」，
/// 抽查要能在源码里落到一个有名字的数上。`body` 有没有把它们摆对，本目标没有 UI 快照框架，不在此声称。
final class SessionRowGeometryTests: XCTestCase {

    func testSessionRowGeometryMatchesSpecNumbers() {
        XCTAssertEqual(SessionRowMetrics.coverSide, 48)            // §3.C：封面 48 方
        XCTAssertEqual(SessionRowMetrics.minRowHeight, 64)         // §3.C / TG-19：行最小高
        XCTAssertEqual(SessionRowMetrics.ringDiameter, 20)         // §3.C / TG-18：进度环直径 20
        XCTAssertEqual(SessionRowMetrics.ringLineWidth, 2)         // §3.C / TG-04：环与描边宽度档
        XCTAssertEqual(SessionRowMetrics.inProgressStripWidth, 2)  // §3.C / §5：进行中 2pt 竖条
        XCTAssertEqual(SessionRowMetrics.separatorHeight, 1)       // §3.C：行间分隔 1pt（首行不加）
        XCTAssertEqual(SessionRowMetrics.fallbackBarHeight, 2)     // §4：Reduce Motion 那条 2pt 高
    }

    /// 不确定环那段弧**不是**进度读数：0 会看不见，1 会被读成"走完了"——两个都是假话。
    func testIndeterminateSweepIsNeitherEmptyNorFull() {
        XCTAssertGreaterThan(SessionRowMetrics.indeterminateSweep, 0)
        XCTAssertLessThan(SessionRowMetrics.indeterminateSweep, 1)
    }

    /// tokens 里没有「无限旋转周期」与「一次性进度条时长」两档 ⇒ 取已有的 `motion.duration.hero`（700ms），
    /// 而不是新造一个数。这一条把那个决定钉住，将来补 TG 时要在这里改口径。
    func testSweepDurationReusesAnExistingMotionTokenValue() {
        XCTAssertEqual(SessionRowMetrics.sweepDuration, 0.7)
    }

    /// §3.C + §数据源行 139：封面拿不到 ⇒ `sparkles` 符号占位（不是曲目行那枚 `music.note`）。
    func testCoverSlotFallsBackToSparkles() {
        XCTAssertEqual(StudioSessionCover.placeholderSymbol, "sparkles")
    }
}
