import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 15 设置屏里**唯一两格会骗人**的读法：缓存占用右值、以及"什么时候不该弹确认框"。
/// 屏的其余部分（系统 List 行、Dialog、外链）是装配而非判据，本文件不声称覆盖了它们；
/// `body` 有没有真的调用这两个 helper 同样不在覆盖之内（本目标没有 UI 快照框架）。
final class SettingsCacheReadoutTests: XCTestCase {

    /// §4：唯一异步值（占用）计算期右位显 `--`，**不显 0** —— "还没算出来"不是"没东西可清"。
    func testUnmeasuredCacheReadsAsPlaceholderNotZero() {
        XCTAssertEqual(SettingsView.cacheDisplay(nil), "--")
        XCTAssertEqual(SettingsView.cacheDisplay(nil), MineCopy.unknownValue)
    }

    /// §8：真 0 的读法是「0 MB」（逐字），不是 ByteCountFormatter 的 "0 bytes"。
    func testZeroCacheReadsAsZeroMegabytes() {
        XCTAssertEqual(SettingsView.cacheDisplay(0), "0 MB")
    }

    /// §8 极值：>1 GB → 一位小数「1.2 GB」。`ByteCountFormatter` 的有效位随量级漂，
    /// 所以这一档自己算，用例把"恰好一位小数"钉住（交给它就无法承诺）。
    func testGigabyteScaleKeepsExactlyOneDecimal() {
        XCTAssertEqual(SettingsView.cacheDisplay(1_200_000_000), "1.2 GB")
        XCTAssertEqual(SettingsView.cacheDisplay(1_000_000_000), "1.0 GB")
        XCTAssertEqual(SettingsView.cacheDisplay(1_234_567_890), "1.2 GB")
        XCTAssertEqual(SettingsView.cacheDisplay(12_345_678_900), "12.3 GB")
    }

    /// MB 档沿用既有 `ByteCountFormatter` 读法。**这条同时钉住一处修掉的缺陷**：
    /// 旧 `human` 对已经带空格的 "128 MB" 再插一个空格 ⇒ 屏上是「128␣␣MB」。
    func testMegabyteScaleHasExactlyOneSpaceBeforeTheUnit() {
        XCTAssertEqual(SettingsView.cacheDisplay(128_000_000), "128 MB")
        XCTAssertEqual(SettingsView.cacheDisplay(128_000), "128 KB")
        // 字节档的单位词**随系统语言变**（中文环境给的是「500 字节」，不是 "500 B"），
        // 所以这里只承诺本屏真正的口径：数字与单位之间恰好一个空格、没有叠出来的空。
        XCTAssertFalse(SettingsView.cacheDisplay(500).contains("  "))
    }

    /// §8：0 不是错误态 —— 点它不该弹一个"要清除吗"的确认框；但**还在测量**不等于 0，
    /// 那一支必须照常可清（否则首帧点清除会永久没反应）。
    func testClearDialogIsSkippedOnlyForARealZero() {
        XCTAssertFalse(SettingsView.asksBeforeClearing(0))
        XCTAssertTrue(SettingsView.asksBeforeClearing(nil))
        XCTAssertTrue(SettingsView.asksBeforeClearing(1))
        XCTAssertTrue(SettingsView.asksBeforeClearing(1_200_000_000))
    }
}
