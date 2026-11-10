@testable import CovaFeature
import XCTest

/// COVA-20261111-111：卡片网格按容器宽度反推列数（用户实测 iPad 分屏后「单纯拉伸」）。
///
/// 纯函数测试，不引 UI。判据全部来自 `AdaptiveLayout.swift` 的
/// `cardColumnCount(containerWidth:minCardWidth:spacing:maxColumns:)` 与
/// `resolvedCardColumnCount(...)`。
final class CardColumnByWidthTests: XCTestCase {

    private let spacing: CGFloat = 12   // CovaSpace.md

    // MARK: - ① 纯反推函数（四象限 + 边界）

    func testWidthDrivenCount_795ptReturns2() {
        // 真机 iPad 分屏实测宽度 795pt，扣页边距 40 ⇒ 容器 755pt
        let n = CovaAdaptiveLayout.cardColumnCount(
            containerWidth: 755, minCardWidth: 280, spacing: spacing, maxColumns: 3)
        XCTAssertEqual(n, 2, "755pt 容器排不下 3 列（3×280+2×12=864），应降为 2 列")
    }

    func testWidthDrivenCount_1600ptReturns3() {
        // 真机全屏 1600pt，扣页边距 40 ⇒ 容器 1560pt
        let n = CovaAdaptiveLayout.cardColumnCount(
            containerWidth: 1560, minCardWidth: 280, spacing: spacing, maxColumns: 3)
        XCTAssertEqual(n, 3, "1560pt 够放 3 列")
    }

    func testWidthDrivenCount_375ptReturns1WhenNoRoom() {
        // 375pt（iPhone SE 级）扣页边距 40 ⇒ 335pt。3×280 不可能，2×280+12=572 也不够
        let n = CovaAdaptiveLayout.cardColumnCount(
            containerWidth: 335, minCardWidth: 280, spacing: spacing, maxColumns: 3)
        XCTAssertEqual(n, 1, "335pt 只够 1 列")
    }

    func testWidthDrivenCount_AXCapRespected() {
        // AX 档上限 2：即使容器极宽也不能超
        let n = CovaAdaptiveLayout.cardColumnCount(
            containerWidth: 3000, minCardWidth: 280, spacing: spacing, maxColumns: 2)
        XCTAssertEqual(n, 2, "maxColumns=2 时不得返回 3")
    }

    func testWidthDrivenCount_NeverBelowOne() {
        for w in [0.0, 1.0, 100.0, -50.0, .nan, .infinity] {
            let n = CovaAdaptiveLayout.cardColumnCount(
                containerWidth: w, minCardWidth: 280, spacing: spacing, maxColumns: 3)
            XCTAssertGreaterThanOrEqual(n, 1, "containerWidth=\(w) 时至少 1 列")
        }
    }

    // MARK: - ② resolvedCardColumnCount（上限 + 宽度取小）

    func testResolved_iPadSplit795_RegularNonAX_Returns2() {
        let n = CovaAdaptiveLayout.resolvedCardColumnCount(
            isRegularWidth: true, axLayout: false, containerWidth: 755, spacing: spacing)
        XCTAssertEqual(n, 2, "这是本单的核心判据：795pt 分屏栏 3 列 → 2 列")
    }

    func testResolved_iPadFull1600_RegularNonAX_Returns3() {
        let n = CovaAdaptiveLayout.resolvedCardColumnCount(
            isRegularWidth: true, axLayout: false, containerWidth: 1560, spacing: spacing)
        XCTAssertEqual(n, 3, "全屏仍是 3 列")
    }

    func testResolved_iPhone_Compact_KeepsOriginalColumns() {
        // compact 不参与反推：835pt 宽也不会变成 3 列
        XCTAssertEqual(
            CovaAdaptiveLayout.resolvedCardColumnCount(
                isRegularWidth: false, axLayout: false, containerWidth: 362, spacing: spacing),
            2, "iPhone 非 AX 保持 2 列（原口径）")
        XCTAssertEqual(
            CovaAdaptiveLayout.resolvedCardColumnCount(
                isRegularWidth: false, axLayout: true, containerWidth: 362, spacing: spacing),
            1, "iPhone AX 保持 1 列（原口径）")
    }

    func testResolved_AXOnWideContainer_NotMoreThanAXLimit() {
        let n = CovaAdaptiveLayout.resolvedCardColumnCount(
            isRegularWidth: true, axLayout: true, containerWidth: 1560, spacing: spacing)
        XCTAssertEqual(n, 2, "AX 档上限 2，容器再宽也不得 3 列")
    }

    func testResolved_iPadPortrait834_RegularNonAX_Returns2() {
        // 834pt 竖屏扣页边距 40 ⇒ 794pt；3 列需 864 ⇒ 降 2 列
        let n = CovaAdaptiveLayout.resolvedCardColumnCount(
            isRegularWidth: true, axLayout: false, containerWidth: 794, spacing: spacing)
        XCTAssertEqual(n, 2, "iPad 竖屏 834pt 也挤，实测每卡仅 256.5pt，应降 2 列")
    }
}
