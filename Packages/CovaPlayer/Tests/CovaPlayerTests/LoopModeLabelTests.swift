import XCTest
@testable import CovaPlayer

/// 「英文态名不得外溢」判据在 `LoopMode` 上的落点（与
/// `testEveryFailureKindSurfacesChineseLabelAndNeverTheEnumName` 同族同形）：
/// `PlayerViews` 把 `description` 直接上屏，原判据只钉了 `PlayerFailure.Kind` 一处，
/// 循环模式这一处就把 `off`/`all`/`one` 印到了 02 屏顶部。逐 case 钉，而不是只钉当下那条。
final class LoopModeLabelTests: XCTestCase {
    func testEveryCaseSurfacesChineseLabelAndNeverTheRawValue() {
        for mode in LoopMode.allCases {
            XCTAssertEqual(mode.description, mode.userLabel)
            XCTAssertNotEqual(mode.description, mode.rawValue, "\(mode.rawValue) 仍在上屏串里")
            XCTAssertFalse(
                mode.description.contains(mode.rawValue),
                "\(mode) 的上屏串露出了 wire 值：\(mode.description)"
            )
            XCTAssertFalse(
                mode.description.rangeOfCharacter(
                    from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
                ) != nil,
                "\(mode) 的上屏串里不该有拉丁字母：\(mode.description)"
            )
        }
        XCTAssertEqual(LoopMode.off.userLabel, "不循环")
        XCTAssertEqual(LoopMode.all.userLabel, "列表循环")
        XCTAssertEqual(LoopMode.one.userLabel, "单曲循环")
    }

    /// `rawValue` 是持久化/上报的 wire 值：中文标签只换显示面，wire 一个字节都不能动。
    func testCodableWireValueUnchangedByChineseLabels() throws {
        for mode in LoopMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(mode.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(LoopMode.self, from: data), mode)
        }
        XCTAssertEqual(Set(LoopMode.allCases.map(\.rawValue)), ["off", "all", "one"])
        // 旧持久化数据（wire 形态）必须继续解得开。
        for raw in ["off", "all", "one"] {
            let data = Data("\"\(raw)\"".utf8)
            XCTAssertNotNil(try JSONDecoder().decode(LoopMode.self, from: data))
        }
    }
}
