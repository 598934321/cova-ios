import CovaCore
import XCTest

final class CovaEnvironmentTests: XCTestCase {
    func testAPIBaseURLIsPinnedToProductionHTTPSOrigin() {
        let url = CovaEnvironment.apiBaseURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "covalink.cn")
        XCTAssertEqual(url.absoluteString, "https://covalink.cn")
    }

    func testAPIBaseURLRejectsLocalhostAndProviderGateway() {
        let url = CovaEnvironment.apiBaseURL
        XCTAssertNotEqual(url.host, "localhost")
        XCTAssertNotEqual(url.host, "127.0.0.1")
        XCTAssertNotEqual(url.port, 3110)
    }

    func testIsProductionOriginAcceptsOnlyProductionHTTPS() {
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(CovaEnvironment.apiBaseURL))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "http://covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://localhost")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://127.0.0.1:3110")!))
    }

    func testIsProductionOriginRejectsHTTPSWithoutHost() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https:")!))
    }
}
