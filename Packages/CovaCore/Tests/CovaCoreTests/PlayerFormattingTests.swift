import CovaCore
import XCTest

/// `PlayerFormatting.swift` 的纯口径：02 §1/§3 的上屏数字与波形柱高。
/// 这些是「错了会骗人」的映射（剩余时间算错、把 NaN 画进柱条），所以在这里钉死；
/// 渲染它们的 SwiftUI 代码不在被测断言之列。
final class PlayerFormattingTests: XCTestCase {
    // MARK: - 时间读法（§1：00:42 / -02:18）

    func testElapsedZeroPadsMinutesAndFloorsSeconds() {
        XCTAssertEqual(PlayerTime.elapsed(42.9), "00:42")
        XCTAssertEqual(PlayerTime.elapsed(0), "00:00")
        XCTAssertEqual(PlayerTime.elapsed(138), "02:18")
        XCTAssertEqual(PlayerTime.elapsed(599.99), "09:59")
        XCTAssertEqual(PlayerTime.elapsed(3600), "1:00:00")
        XCTAssertEqual(PlayerTime.elapsed(3725), "1:02:05")
    }

    func testElapsedRefusesNaNAndNegatives() {
        XCTAssertEqual(PlayerTime.elapsed(.nan), "00:00")
        XCTAssertEqual(PlayerTime.elapsed(.infinity), "00:00")
        XCTAssertEqual(PlayerTime.elapsed(-30), "00:00")
    }

    func testRemainingCountsDownAndNeverGoesNegativeOnScreen() {
        XCTAssertEqual(PlayerTime.remaining(position: 42, duration: 180), "-02:18")
        // 已越过末尾：显示 -00:00，而不是把负秒数印上屏。
        XCTAssertEqual(PlayerTime.remaining(position: 200, duration: 180), "-00:00")
        XCTAssertEqual(PlayerTime.remaining(position: .nan, duration: 180), "-00:00")
        XCTAssertEqual(PlayerTime.remaining(position: 42, duration: .nan), "-00:00")
    }

    // MARK: - 波形柱高归一（§3）

    func testEmptySinglePeakAndAllZeroDegradeToNoBars() {
        XCTAssertEqual(WaveformBars.heights(peaks: []), [])
        XCTAssertEqual(WaveformBars.heights(peaks: [0.5]), [])
        XCTAssertEqual(WaveformBars.heights(peaks: [0, 0, 0, 0]), [])
        XCTAssertEqual(WaveformBars.heights(peaks: [.nan, .infinity, -.infinity]), [])
        XCTAssertEqual(WaveformBars.heights(peaks: [0.1, 0.2], barCount: 0), [])
        XCTAssertEqual(WaveformBars.heights(peaks: [0.1, 0.2], barCount: -3), [])
    }

    func testNaNAndNegativeAndOvershootAreClampedNotDropped() {
        // 剔除 NaN 会让后续桶错位 ⇒ 按 0 计并保留槽位；负值钳 0、>1 钳 1。
        let bars = WaveformBars.heights(peaks: [.nan, -0.4, 2.0, 0.5], barCount: 4)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars, [0, 0, 1, 0.5])
        XCTAssertTrue(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testResampleTo48KeepsBarCountAndPeakEnvelope() {
        // 128 点（线上实测长度）→ 48 根：桶内取最大 ⇒ 孤峰被保留、且不复制到相邻桶。
        var peaks = [Double](repeating: 0.1, count: 128)
        peaks[64] = 1.0
        let bars = WaveformBars.heights(peaks: peaks, barCount: 48)
        XCTAssertEqual(bars.count, 48)
        XCTAssertEqual(bars.filter { $0 == 1.0 }.count, 1)
        XCTAssertTrue(bars.allSatisfy { $0 >= 0.1 && $0 <= 1 })
    }

    func testDownsamplingKeepsBurstPeaks() {
        // 稀疏峰值（1 根高、其余 0）在 48 桶下必须至少出现在一根柱里。
        var peaks = [Double](repeating: 0, count: 600)
        peaks[300] = 1
        let bars = WaveformBars.heights(peaks: peaks, barCount: 48)
        XCTAssertEqual(bars.count, 48)
        XCTAssertEqual(bars.max(), 1)
    }

    func testUndersamplingPointPicksWithoutEmptyBars() {
        let bars = WaveformBars.heights(peaks: [0.2, 0.8], barCount: 6)
        XCTAssertEqual(bars.count, 6)
        XCTAssertTrue(bars.contains(0.2))
        XCTAssertTrue(bars.contains(0.8))
    }

    // MARK: - 进度与高亮区间（§3 刻度带）

    func testProgressFractionClampsToUnit() {
        XCTAssertEqual(WaveformBars.progress(position: 90, duration: 180), 0.5)
        XCTAssertEqual(WaveformBars.progress(position: -5, duration: 180), 0)
        XCTAssertEqual(WaveformBars.progress(position: 400, duration: 180), 1)
        XCTAssertEqual(WaveformBars.progress(position: 42, duration: 0), 0)
        XCTAssertEqual(WaveformBars.progress(position: 42, duration: .nan), 0)
    }

    func testHighlightRangeRejectsMalformedIntervals() {
        guard let band = WaveformBars.highlightFraction(start: 135, end: 155, duration: 180) else {
            return XCTFail("合法区间必须解出，而不是静默丢弃")
        }
        XCTAssertEqual(band.lowerBound, 0.75)
        XCTAssertEqual(band.upperBound, 155.0 / 180.0, accuracy: 1e-9)
        // 出界腿钳到 1，不画到轨外。
        XCTAssertEqual(WaveformBars.highlightFraction(start: 135, end: 900, duration: 180), 0.75...1)
        XCTAssertNil(WaveformBars.highlightFraction(start: 155, end: 135, duration: 180))
        XCTAssertNil(WaveformBars.highlightFraction(start: 10, end: 20, duration: 0))
        XCTAssertNil(WaveformBars.highlightFraction(start: .nan, end: 20, duration: 180))
        XCTAssertNil(WaveformBars.highlightFraction(start: 90, end: 90, duration: 180))
    }
}
