@testable import CovaFeature
import XCTest

/// t74 原生 iPad 的纯布局判据（对齐 web 768×1024：卡片网格 3 列、输入卡居中限宽）。
final class AdaptiveLayoutTests: XCTestCase {
    func testCardColumnCountPerSizeClassAndAX() {
        XCTAssertEqual(CovaAdaptiveLayout.cardColumnCount(isRegularWidth: false, axLayout: false), 2, "iPhone 维持 2 列")
        XCTAssertEqual(CovaAdaptiveLayout.cardColumnCount(isRegularWidth: false, axLayout: true), 1, "AX 档降 1 列（05 既有口径）")
        XCTAssertEqual(CovaAdaptiveLayout.cardColumnCount(isRegularWidth: true, axLayout: false), 3, "iPad regular 3 列（web 768 宽）")
        XCTAssertEqual(CovaAdaptiveLayout.cardColumnCount(isRegularWidth: true, axLayout: true), 2)
    }

    func testCardColumnsBuildsMatchingGridItems() {
        XCTAssertEqual(CovaAdaptiveLayout.cardColumns(isRegularWidth: true, axLayout: false, spacing: 12).count, 3)
        XCTAssertEqual(CovaAdaptiveLayout.cardColumns(isRegularWidth: false, axLayout: true, spacing: 12).count, 1)
    }

    func testReadableWidthOnlyCapsRegular() {
        XCTAssertEqual(CovaAdaptiveLayout.contentMaxWidth(isRegularWidth: true), CovaAdaptiveLayout.readableMaxWidth)
        XCTAssertEqual(CovaAdaptiveLayout.contentMaxWidth(isRegularWidth: false), .infinity, "compact 不限宽，iPhone 观感不变")
    }
}
