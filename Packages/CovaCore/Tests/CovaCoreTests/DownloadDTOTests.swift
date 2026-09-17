import CovaCore
import XCTest

final class DownloadDTOTests: XCTestCase {
    func testDecodesCheckoutInfoRealAnonymousPayload() throws {
        let info = try Fixture.decode(DownloadCheckoutInfoDto.self, "checkout-info")
        XCTAssertEqual(info.downloadCredits, 10)
        XCTAssertEqual(info.enabled, true)
        XCTAssertEqual(info.format, "mp3")
        // 匿名访问时后端返回 balance: null
        XCTAssertNil(info.balance)
    }

    func testCheckoutInfoDecodesSignedInBalance() throws {
        let json = Data(#"{"downloadCredits":10,"enabled":true,"balance":120,"format":"mp3"}"#.utf8)
        let info = try JSONDecoder().decode(DownloadCheckoutInfoDto.self, from: json)
        XCTAssertEqual(info.balance, 120)
    }

    func testDecodesCheckoutResponseWithDownloadsAndItems() throws {
        let response = try Fixture.decode(DownloadCheckoutResponseDto.self, "checkout-response")
        XCTAssertEqual(response.batchId, "batch-test-0001")
        XCTAssertEqual(response.chargedCredits, 10)
        XCTAssertEqual(response.skippedOwned, ["library-test-0002"])
        XCTAssertEqual(response.balance, 110)

        let downloads = try XCTUnwrap(response.downloads)
        XCTAssertEqual(downloads.count, 2)
        XCTAssertEqual(downloads[0].trackId, "library-test-0001")
        XCTAssertEqual(downloads[0].downloadId, "dl-test-0001")
        XCTAssertEqual(downloads[0].url?.rawValue, "/api/downloads/dl-test-0001/file")
        XCTAssertEqual(downloads[0].filename, "Golden-Beacon.mp3")
        XCTAssertEqual(downloads[0].owned, false)
        XCTAssertEqual(downloads[1].owned, true)

        XCTAssertEqual(response.items?.count, 1)
        XCTAssertEqual(response.resolvedItems.count, 2)
    }

    func testResolvedItemsFallsBackToItems() throws {
        let json = Data(
            #"{"balance":1,"items":[{"trackId":"t1","downloadId":"d1","url":"/api/downloads/d1/file","filename":"a.mp3","owned":true}]}"#.utf8
        )
        let response = try JSONDecoder().decode(DownloadCheckoutResponseDto.self, from: json)
        XCTAssertNil(response.downloads)
        XCTAssertEqual(response.resolvedItems.count, 1)
        XCTAssertEqual(response.resolvedItems[0].downloadId, "d1")
    }

    func testResolvedItemsIsEmptyWhenNeitherKeyPresent() throws {
        let response = try JSONDecoder().decode(DownloadCheckoutResponseDto.self, from: Data("{}".utf8))
        XCTAssertEqual(response.resolvedItems.count, 0)
        XCTAssertNil(response.batchId)
    }

    func testMissingDownloadIdentityFailsDecoding() {
        let json = Data(#"{"downloads":[{"url":"/x","filename":"a.mp3"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadCheckoutResponseDto.self, from: json))
    }
}
