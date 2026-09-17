// 注意：本文件**刻意使用普通 `import CovaCore`（非 @testable）**。
// 目的：让编译器强制校验对外公共 API 的可见性 —— 请求体 DTO 必须能从模块外构造并编码。
// 若某个请求 DTO 只有合成的 internal memberwise init，这里会编译失败（上一轮的假阳性根因）。
import CovaCore
import Foundation
import XCTest

final class PublicAPIRequestEncodingTests: XCTestCase {
    // MARK: - 请求体：模块外构造 → 编码 → 与契约 fixture 结构比对

    func testFavoriteMutationRequestIsConstructibleAndEncodesContractKeys() throws {
        let request = FavoriteMutationRequestDto(trackId: "library-1")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/favorite-mutation-request"
        )
    }

    func testSavedPlaylistMutationRequestIsConstructibleAndEncodesContractKeys() throws {
        let request = SavedPlaylistMutationRequestDto(playlistId: "PL-1")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/saved-playlist-mutation-request"
        )
    }

    func testPlayReportRequestIsConstructibleAndDefaultsToAppIOSSource() throws {
        let request = PlayReportRequestDto(
            trackId: "library-1",
            idempotencyKey: try IdempotencyKey(validating: "play-0001")
        )
        XCTAssertEqual(PlayReportRequestDto.appIOSSource, "app-ios")
        XCTAssertEqual(request.source, "app-ios")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/play-report-request"
        )
    }

    func testDownloadCheckoutRequestIsConstructibleAndDefaultsToMp3() throws {
        let request = DownloadCheckoutRequestDto(
            trackIds: ["library-1", "library-2"],
            idempotencyKey: try IdempotencyKey(validating: "checkout-0001")
        )
        XCTAssertEqual(DownloadCheckoutRequestDto.mp3Format, "mp3")
        XCTAssertEqual(request.format, "mp3")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/checkout-request"
        )
    }

    func testOneStepPlanStartRequestIsConstructibleAndCarriesIdempotencyKey() throws {
        let request = OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "snapshot-1",
            idempotencyKey: try IdempotencyKey(validating: "start-0001")
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/one-step-plan-start-request"
        )
    }

    func testCreateSessionRequestIsConstructibleAndDefaultsToOneStep() throws {
        let request = CovaCreateSessionRequestDto()
        XCTAssertEqual(CovaCreateSessionRequestDto.oneStepWorkflowMode, "one-step")
        XCTAssertEqual(request.workflowMode, "one-step")
        XCTAssertEqual(request.skipWelcome, true)
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/create-session-request"
        )
    }

    func testMediaRetentionRequestIsConstructibleAndEncodesFavorite() throws {
        let request = MediaRetentionRequestDto(favorite: true)
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/media-retention-request"
        )
        let removed = MediaRetentionRequestDto(favorite: false)
        let text = String(decoding: try JSONEncoder().encode(removed), as: UTF8.self)
        XCTAssertEqual(text, #"{"favorite":false}"#)
    }

    func testLoginRequestIsConstructibleFromOutsideModule() throws {
        let request = CovaLoginRequestDto(email: "tester@example.invalid", password: "placeholder")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/login-request"
        )
    }

    // MARK: - 其余对外可构造的公共类型

    func testErrorEnvelopeIsConstructibleFromOutsideModule() throws {
        let envelope = CovaAPIErrorEnvelope(error: "积分不足", code: "INSUFFICIENT_CREDITS")
        XCTAssertEqual(envelope.error, "积分不足")
        XCTAssertEqual(envelope.code, "INSUFFICIENT_CREDITS")
        let text = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertTrue(text.contains("INSUFFICIENT_CREDITS"))
    }

    func testSSEFrameIsConstructibleFromOutsideModule() throws {
        let frame = CovaSSEFrame(rawEventName: "text", payload: Data(#"{"text":"hi"}"#.utf8))
        XCTAssertEqual(frame.event, .text)
        XCTAssertEqual(frame.decodePayload(CovaSSETextEventDto.self)?.text, "hi")

        let typed = CovaSSEFrame(event: CovaSSEEventType(rawName: "done"), payload: Data("{}".utf8))
        XCTAssertEqual(typed.event.rawName, "done")
    }

    func testErrorCasesAreConstructibleFromOutsideModule() {
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: nil).httpStatusCode, 401)
        XCTAssertEqual(CovaAPIError.httpStatus(code: 500, apiCode: "X").httpStatusCode, 500)
    }

    func testEnvironmentConstantsAreVisibleFromOutsideModule() {
        XCTAssertEqual(CovaEnvironment.apiPort, 443)
        XCTAssertEqual(CovaEnvironment.isProductionOrigin(CovaEnvironment.apiBaseURL), true)
    }
}
