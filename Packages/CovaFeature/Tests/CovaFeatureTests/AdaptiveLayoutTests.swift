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

    /// t84：iPhone 底栏连搜索格最多 5 格 ⇒ compact 不显示顶层搜索格（否则系统折出「更多」把「我的」藏起来）。
    func testSearchTabOnlyInRegularWidth() {
        XCTAssertTrue(CovaAdaptiveLayout.showsSearchTab(isRegularWidth: true, isPad: true))
        XCTAssertFalse(CovaAdaptiveLayout.showsSearchTab(isRegularWidth: false, isPad: true), "iPad 分屏窄栏")
        XCTAssertFalse(CovaAdaptiveLayout.showsSearchTab(isRegularWidth: false, isPad: false))
        XCTAssertFalse(CovaAdaptiveLayout.showsSearchTab(isRegularWidth: true, isPad: false), "iPhone Pro Max 横屏 regular 宽仍是底栏")
        let visibleCompact = AppSession.Tab.allCases.filter {
            $0 != .search || CovaAdaptiveLayout.showsSearchTab(isRegularWidth: true, isPad: false)
        }
        XCTAssertLessThanOrEqual(visibleCompact.count, 5, "iPhone 底栏超过 5 格会出现系统「更多」页签")
    }

    /// t84：栈内搜索屏不切页签（曲库/歌单哪里打开就在哪棵栈里）。
    func testSearchRouteStaysInCurrentStack() {
        XCTAssertNil(AppSession.Route.search.owningTab)
        XCTAssertFalse(AppSession.Route.search.isTabRoot)
    }

    /// t84：iPad 上曲目详情 sheet 走单一 .large 档（60% 档只露封面）；iPhone 非 AX 档保持两档吸附。
    func testTrackDetailDetentsOnPad() {
        XCTAssertTrue(TrackDetailSheet.usesSingleLargeDetent(axLayout: false, isPad: true))
        XCTAssertTrue(TrackDetailSheet.usesSingleLargeDetent(axLayout: true, isPad: false))
        XCTAssertFalse(TrackDetailSheet.usesSingleLargeDetent(axLayout: false, isPad: false))
        XCTAssertEqual(CovaAdaptiveLayout.heroArtworkMaxWidth(isRegularWidth: true), 360)
        XCTAssertEqual(CovaAdaptiveLayout.heroArtworkMaxWidth(isRegularWidth: false), .infinity)
    }
}
