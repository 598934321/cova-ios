import CovaCore
import CovaPlayer
import CovaUI
import SwiftUI
import XCTest

final class LayerWiringTests: XCTestCase {
    @MainActor
    func testPlayerDefaultsToProductionAssetOrigin() {
        XCTAssertEqual(CovaPlayer().assetOrigin, CovaEnvironment.apiBaseURL)
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(CovaPlayer().assetOrigin))
    }

    func testThemeModeMapsToExpectedColorScheme() {
        XCTAssertNil(CovaThemeMode.system.colorScheme)
        XCTAssertEqual(CovaThemeMode.light.colorScheme, .light)
        XCTAssertEqual(CovaThemeMode.dark.colorScheme, .dark)
        XCTAssertEqual(CovaThemeMode.allCases.count, 3)
    }
}
