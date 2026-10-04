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

    /// TD-24：写请求 DTO 的幂等键只能经 `IdempotentRequestToken` 注入（见 `IdempotencyTests`）。
    private func token(_ operation: IdempotentOperation, hex: String = String(repeating: "0", count: 32)) throws -> IdempotentRequestToken {
        try IdempotentRequestToken(operation: operation, key: IdempotencyKey(validating: operation.keyPrefix + hex))
    }

    /// 模块外（本文件 `import CovaCore`，非 `@testable`）构造播放上报请求，并钉住默认归因。
    ///
    /// 旧用例钉的是 `appIOSSource == "app-ios"`，该值不在服务端 source allowlist 内
    /// （E2：线上 400 `播放来源无效`），故按更正后的契约改写为 `PlayReportSource` 的默认值。
    func testPlayReportRequestIsConstructibleAndDefaultsToPlayerSource() throws {
        let request = try PlayReportRequestDto(
            trackId: "library-1",
            token: token(.playReport)
        )
        XCTAssertEqual(PlayReportSource.player.rawValue, "player")
        XCTAssertEqual(request.source, .player)
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/play-report-request"
        )
    }

    /// 模块外也必须能显式指定语境来源（`track_detail` 的线格式拼写是这条的价值所在）。
    func testPlayReportRequestAcceptsAnExplicitContextSource() throws {
        let request = try PlayReportRequestDto(
            trackId: "library-1",
            source: .trackDetail,
            token: token(.playReport)
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let source = try XCTUnwrap((object as? [String: Any])?["source"] as? String)
        XCTAssertEqual(source, "track_detail")
    }

    func testDownloadCheckoutRequestIsConstructibleAndDefaultsToMp3() throws {
        let request = try DownloadCheckoutRequestDto(
            trackIds: ["library-1", "library-2"],
            token: token(.downloadCheckout)
        )
        XCTAssertEqual(DownloadCheckoutRequestDto.mp3Format, "mp3")
        XCTAssertEqual(request.format, "mp3")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/checkout-request"
        )
    }

    func testOneStepPlanStartRequestIsConstructibleAndCarriesIdempotencyKey() throws {
        let request = try OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "snapshot-1",
            token: token(.planStart)
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/one-step-plan-start-request"
        )
    }

    /// studio/create 的提交请求（DEVELOPMENT.md §4.4 / A3）：模块外可构造、
    /// 幂等键只能经 token 注入，且编码出的键集与服务端读取清单一致
    /// （`mode` / `operation` / `prompt` / `idempotencyKey` —— 不多不少，不发明字段）。
    func testStudioCreateGenerateRequestIsConstructibleAndEncodesContractKeys() throws {
        let request = try StudioCreateGenerateRequestDto(
            prompt: "夏夜城市里的合成器流行，女声，中速",
            token: token(.studioCreateGenerate)
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/studio-create-generate-request"
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

    /// §7 #55：`title` 携带时编码出该键（服务端 `renameSession` 成真名）；
    /// `nil` 时键**不出现**（合成 Codable 自动略 nil ⇒ 不传比传空串干净）。
    func testCreateSessionRequestEncodesTitleOnlyWhenPresent() throws {
        let titled = CovaCreateSessionRequestDto(title: "给新店的开业歌单")
        let titledJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(titled)) as? [String: Any])
        XCTAssertEqual(titledJson["title"] as? String, "给新店的开业歌单")

        let untitled = CovaCreateSessionRequestDto()
        let untitledJson = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(untitled)) as? [String: Any])
        XCTAssertNil(untitledJson["title"], "不带标题时这个键不该出现在线上")
    }

    // MARK: - `normalizedTitle`（prompt → 会话真名，§7 #55）

    func testNormalizedTitleTakesFirstLineAndTrims() {
        XCTAssertEqual(
            CovaCreateSessionRequestDto.normalizedTitle("  给新店的开业歌单，轻快一点\n再要一版慢的  "),
            "给新店的开业歌单，轻快一点")
        XCTAssertEqual(
            CovaCreateSessionRequestDto.normalizedTitle(" 海边黄昏的 Lo-Fi "),
            "海边黄昏的 Lo-Fi")
    }

    func testNormalizedTitleReturnsNilForBlankInput() {
        XCTAssertNil(CovaCreateSessionRequestDto.normalizedTitle(""))
        XCTAssertNil(CovaCreateSessionRequestDto.normalizedTitle("   \n  "))
        XCTAssertNil(CovaCreateSessionRequestDto.normalizedTitle("\n首行是空的但第二行有字"))
    }

    func testNormalizedTitleCapsAtThirtyCharacters() {
        let long = String(repeating: "歌", count: 31)
        XCTAssertEqual(CovaCreateSessionRequestDto.normalizedTitle(long)?.count, 30)
        let exact = String(repeating: "词", count: 30)
        XCTAssertEqual(CovaCreateSessionRequestDto.normalizedTitle(exact), exact)
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
        let request = CovaLoginRequestDto(email: "tester@example.invalid", password: SecretString("placeholder"))
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
