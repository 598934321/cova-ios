@testable import CovaCore
import XCTest

final class CovaAPIErrorTests: XCTestCase {
    func testClassifyHTTPStatusSuccessReturnsNil() {
        XCTAssertNil(CovaAPIError.classify(httpStatus: 200, apiCode: nil))
        XCTAssertNil(CovaAPIError.classify(httpStatus: 204, apiCode: "IGNORED"))
        XCTAssertNil(CovaAPIError.classify(httpStatus: 299, apiCode: nil))
    }

    func testClassifyHTTPStatusMapsUnauthorizedSeparately() {
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 401, apiCode: nil), .unauthorized(apiCode: nil))
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 401, apiCode: "TOKEN_EXPIRED"),
            .unauthorized(apiCode: "TOKEN_EXPIRED")
        )
    }

    func testClassifyHTTPStatusMapsOtherFailures() {
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 400, apiCode: "INVALID"),
            .httpStatus(code: 400, apiCode: "INVALID")
        )
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 402, apiCode: "INSUFFICIENT_CREDITS"),
            .httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS")
        )
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 302, apiCode: nil), .httpStatus(code: 302, apiCode: nil))
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 500, apiCode: nil), .httpStatus(code: 500, apiCode: nil))
    }

    func testClassifyBodyExtractsBusinessCode() throws {
        let body = try Fixture.data("error-envelope")
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 402, body: body),
            .httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS")
        )
        XCTAssertNil(CovaAPIError.classify(httpStatus: 200, body: body))
    }

    func testClassifyBodyToleratesNonEnvelopePayloads() {
        let malformed = Data("not json at all".utf8)
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 503, body: malformed),
            .httpStatus(code: 503, apiCode: nil)
        )
        let empty = Data()
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 401, body: empty),
            .unauthorized(apiCode: nil)
        )
    }

    func testClassifyTransportErrorCodes() {
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorNotConnectedToInternet), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorNetworkConnectionLost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorDataNotAllowed), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCannotConnectToHost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCannotFindHost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorDNSLookupFailed), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorTimedOut), .timeout)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCancelled), .cancelled)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: -1234), .transport(code: -1234))
    }

    func testClassifyDecodingErrorsKeepsFieldPathOnly() throws {
        struct Probe: Decodable {
            let name: String
            enum CodingKeys: String, CodingKey { case name }
        }
        struct Outer: Decodable {
            let values: [Probe]
        }

        let missingKey = Data(#"{"other":1}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: missingKey)
            XCTFail("应因缺少 name 解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: "name"))
        }

        let typeMismatch = Data(#"{"name":123}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: typeMismatch)
            XCTFail("应因类型不符解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: "name"))
        }

        let corrupted = Data("{".utf8)
        do {
            _ = try JSONDecoder().decode(Outer.self, from: corrupted)
            XCTFail("应因 JSON 结构损坏解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: nil))
        }
    }

    func testHTTPStatusCodeProjection() {
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: nil).httpStatusCode, 401)
        XCTAssertEqual(CovaAPIError.httpStatus(code: 503, apiCode: nil).httpStatusCode, 503)
        XCTAssertNil(CovaAPIError.offline.httpStatusCode)
        XCTAssertNil(CovaAPIError.decoding(field: "x").httpStatusCode)
    }

    func testIsRetryable() {
        XCTAssertTrue(CovaAPIError.offline.isRetryable)
        XCTAssertTrue(CovaAPIError.timeout.isRetryable)
        XCTAssertTrue(CovaAPIError.transport(code: -1).isRetryable)
        XCTAssertTrue(CovaAPIError.httpStatus(code: 500, apiCode: nil).isRetryable)
        XCTAssertTrue(CovaAPIError.httpStatus(code: 429, apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.httpStatus(code: 400, apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.unauthorized(apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.cancelled.isRetryable)
        XCTAssertFalse(CovaAPIError.invalidResponse.isRetryable)
        XCTAssertFalse(CovaAPIError.decoding(field: nil).isRetryable)
    }

    func testRedactedDescriptionsCarryNoSensitiveData() {
        XCTAssertEqual(CovaAPIError.offline.redactedDescription, "网络不可用")
        XCTAssertEqual(CovaAPIError.timeout.redactedDescription, "请求超时")
        XCTAssertEqual(CovaAPIError.cancelled.redactedDescription, "请求已取消")
        XCTAssertEqual(CovaAPIError.transport(code: -50).redactedDescription, "传输错误(-50)")
        XCTAssertEqual(CovaAPIError.invalidResponse.redactedDescription, "响应格式无效")
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: nil).redactedDescription, "未授权(no_code)")
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: "TOKEN_EXPIRED").redactedDescription, "未授权(TOKEN_EXPIRED)")
        XCTAssertEqual(
            CovaAPIError.httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS").redactedDescription,
            "服务端错误(402/INSUFFICIENT_CREDITS)"
        )
        XCTAssertEqual(CovaAPIError.httpStatus(code: 500, apiCode: nil).redactedDescription, "服务端错误(500/no_code)")
        XCTAssertEqual(CovaAPIError.decoding(field: "title").redactedDescription, "响应解码失败(title)")
        XCTAssertEqual(CovaAPIError.decoding(field: nil).redactedDescription, "响应解码失败(unknown)")

        let signedURL = "https://cdn.invalid/audio/x.mp3?signature=SECRET"
        let descriptions = [
            CovaAPIError.transport(code: -1).redactedDescription,
            CovaAPIError.httpStatus(code: 403, apiCode: "FORBIDDEN").redactedDescription,
            CovaAPIError.decoding(field: "url").redactedDescription
        ]
        for text in descriptions {
            XCTAssertFalse(text.contains("SECRET"))
            XCTAssertFalse(text.contains(signedURL))
            XCTAssertFalse(text.contains("http"))
        }
    }

    func testErrorEnvelopeDecoding() throws {
        let envelope = try Fixture.decode(CovaAPIErrorEnvelope.self, "error-envelope")
        XCTAssertEqual(envelope.code, "INSUFFICIENT_CREDITS")
        XCTAssertEqual(envelope.error, "积分不足")

        let minimal = try JSONDecoder().decode(CovaAPIErrorEnvelope.self, from: Data("{}".utf8))
        XCTAssertNil(minimal.error)
        XCTAssertNil(minimal.code)
    }
}
