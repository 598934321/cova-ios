@testable import CovaFeature
import CovaCore
import Foundation
import XCTest

/// 「开始制作」失败分诊（M-1 / M-2 的判据面）。
///
/// 钉的是三件事：① 402 把服务端的 `required` 变成人话、并说清**这次没有扣费**；
/// ② 429 有 `Retry-After` 时说秒数、没有时仍是完整人话；③ 这两个状态码**不许**再落回
/// `CatalogService.classify` 的 `HTTP 402` / `HTTP 429` 兜底（屏上无英文码）。
final class StudioStartFailureTests: XCTestCase {

    private func classify(_ status: Int, _ json: String?, retryAfter: Int? = nil) -> StudioStartFailure {
        StudioStartFailure.classify(
            statusCode: status,
            body: json.map { Data($0.utf8) },
            retryAfterSeconds: retryAfter
        )
    }

    // MARK: 402 余额不足

    func testInsufficientCreditsUsesServerRequiredAmount() {
        let failure = classify(
            402,
            #"{"error":"余额不足，本次需要 55","code":"credits_insufficient","balance":10,"required":55}"#
        )
        XCTAssertEqual(failure.userMessage, "余额不足，本次需要 55 co（这次没有扣费）")
    }

    func testInsufficientCreditsWithoutRequiredStillSaysNoCharge() {
        let failure = classify(402, #"{"balance":0}"#)
        XCTAssertEqual(failure.userMessage, "余额不足（这次没有扣费）")
    }

    func testInsufficientCreditsWithZeroRequiredIsNotRenderedAsZeroCo() {
        let failure = classify(402, #"{"required":0}"#)
        XCTAssertEqual(failure.userMessage, "余额不足（这次没有扣费）")
    }

    func testInsufficientCreditsMessageNeverContainsEnglishCode() {
        let failure = classify(402, #"{"error":"credits_insufficient"}"#)
        XCTAssertFalse(failure.userMessage.contains("credits_insufficient"))
        XCTAssertFalse(failure.userMessage.contains("402"))
    }

    // MARK: 429 限流

    func testRateLimitWithRetryAfterShowsTheSeconds() {
        let failure = classify(429, #"{"error":"请求过于频繁，请稍后再试"}"#, retryAfter: 42)
        XCTAssertEqual(failure.userMessage, "请求过于频繁，请 42 秒后再试")
    }

    func testRateLimitWithoutRetryAfterFallsBackToServerHumanCopy() {
        let failure = classify(429, #"{"error":"请求过于频繁，请稍后再试"}"#)
        XCTAssertEqual(failure.userMessage, "请求过于频繁，请稍后再试")
    }

    func testRateLimitWithZeroSecondsDoesNotPromiseZeroSeconds() {
        let failure = classify(429, nil, retryAfter: 0)
        XCTAssertEqual(failure.userMessage, "请求过于频繁，请稍后再试")
    }

    func testRateLimitNeverShowsHTTP429() {
        let failure = classify(429, nil, retryAfter: 7)
        XCTAssertFalse(failure.userMessage.contains("429"))
        XCTAssertFalse(failure.userMessage.contains("HTTP"))
    }

    // MARK: 其它状态码沿用同一族判据

    func testBadRequestPassesChineseServerCopyThrough() {
        let failure = classify(400, #"{"error":"计划快照不一致"}"#)
        XCTAssertEqual(failure.userMessage, "计划快照不一致")
    }

    func testBadRequestWithBareCodeFallsBackToOwnCopy() {
        let failure = classify(400, #"{"error":"invalid_patch"}"#)
        XCTAssertFalse(failure.userMessage.contains("invalid_patch"))
        XCTAssertEqual(failure.userMessage, "这次提交没被接受（服务端未说明原因）")
    }

    func testServerErrorKeepsStatusCodeForTriage() {
        let failure = classify(503, #"{"error":"歌曲制作任务暂时没有创建成功，请稍后再试"}"#)
        XCTAssertEqual(failure.userMessage, "歌曲制作任务暂时没有创建成功，请稍后再试")
    }

    // MARK: 与 `StudioService.classify` 的接线（屏上用的就是这一条）

    func testClassifyRoutesInsufficientCreditsToServerMessage() {
        let failure = classify(
            402, #"{"code":"credits_insufficient","balance":3,"required":55}"#
        )
        guard case .server(let message) = StudioService.classify(failure) else {
            return XCTFail("402 应落 .server 且带上算好的人话")
        }
        XCTAssertEqual(message, "余额不足，本次需要 55 co（这次没有扣费）")
        XCTAssertFalse(message.contains("402"))
    }

    func testClassifyRoutesRateLimitToServerMessageWithSeconds() {
        let failure = classify(429, nil, retryAfter: 90)
        guard case .server(let message) = StudioService.classify(failure) else {
            return XCTFail("429 应落 .server 且带上秒数")
        }
        XCTAssertEqual(message, "请求过于频繁，请 90 秒后再试")
    }

    /// 401 不许被上面那条 start 专线截成一句本地话术：登录态过期是**跨屏**语义。
    func testClassifyRoutesUnauthenticatedToTheCrossScreenBucket() {
        let failure = classify(401, #"{"error":"请先登录"}"#)
        XCTAssertEqual(StudioService.classify(failure), .unauthenticated)
    }
}
