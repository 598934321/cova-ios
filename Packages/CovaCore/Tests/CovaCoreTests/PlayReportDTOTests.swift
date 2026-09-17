import CovaCore
import XCTest

final class PlayReportDTOTests: XCTestCase {
    func testRequestDefaultsToAppIOSSourceAndUsesContractKeys() throws {
        XCTAssertEqual(PlayReportRequestDto.appIOSSource, "app-ios")

        let request = PlayReportRequestDto(trackId: "library-1", idempotencyKey: "play-0001")
        XCTAssertEqual(request.source, "app-ios")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/play-report-request"
        )
    }

    func testDecodesPlayReportResponse() throws {
        let response = try Fixture.decode(PlayReportResponseDto.self, "play-report-response")
        XCTAssertEqual(response.message, "ok")
        XCTAssertEqual(response.recorded, true)
        XCTAssertEqual(response.idempotentReplay, false)
        XCTAssertEqual(response.authenticated, true)
        XCTAssertEqual(response.play?.trackId, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(response.play?.source, "app-ios")
        XCTAssertEqual(response.play?.playedAt?.isEmpty, false)
    }

    func testDecodesIdempotentReplayResponse() throws {
        let json = Data(
            #"{"message":"ok","recorded":false,"idempotentReplay":true,"authenticated":true,"play":{"trackId":"t1","source":"app-ios","playedAt":"2026-09-17T03:10:00.000Z"}}"#.utf8
        )
        let response = try JSONDecoder().decode(PlayReportResponseDto.self, from: json)
        XCTAssertEqual(response.recorded, false)
        XCTAssertEqual(response.idempotentReplay, true)
    }
}
