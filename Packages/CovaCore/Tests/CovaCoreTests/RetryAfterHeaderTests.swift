@testable import CovaCore
import Foundation
import XCTest

/// `Retry-After` 的解析判据（M-2 的地基）。
///
/// 只认 RFC 7231 的 **delta-seconds** 形态：服务端在 `plans/start` 超限时回的是
/// `Retry-After: <秒>`（`web/src/lib/security.ts:116`）。HTTP-date 形态一律 `nil` ——
/// 我们不做日历/时区换算，宁可上屏「请稍后再试」也不给一个可能差 8 小时的秒数。
final class RetryAfterHeaderTests: XCTestCase {

    func testPlainDigitsBecomeSeconds() {
        XCTAssertEqual(URLSessionTransport.retryAfterSeconds("120"), 120)
        XCTAssertEqual(URLSessionTransport.retryAfterSeconds("0"), 0)
        XCTAssertEqual(URLSessionTransport.retryAfterSeconds("3600"), 3600)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(URLSessionTransport.retryAfterSeconds(" 45 "), 45)
        XCTAssertEqual(URLSessionTransport.retryAfterSeconds("\t45\n"), 45)
    }

    func testNonNumericFormsAreRefused() {
        // 缺头 / 空串 / 词 / 小数 / 负数 / 两个数 / 带单位
        XCTAssertNil(URLSessionTransport.retryAfterSeconds(nil))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds(""))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("   "))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("abc"))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("120.5"))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("-5"))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("1 20"))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("120s"))
    }

    /// HTTP-date 形态**刻意不解析**：这条用例钉的是「宁可没有秒数」这个取舍本身，
    /// 不是「我们还不会解析」。改成支持 date 时，这条必须一起改（并补时区用例）。
    func testHTTPDateFormIsRefusedOnPurpose() {
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT"))
        XCTAssertNil(URLSessionTransport.retryAfterSeconds("120, 21 Oct 2015 07:28:00 GMT"))
    }

    // MARK: 结果类型上的接线（不能把整份 header 搬出去）

    func testOutcomeCarriesOnlyTheParsedSecond() {
        let outcome = CovaHTTPOutcome(statusCode: 429, body: Data(), retryAfterSeconds: 42)
        XCTAssertEqual(outcome.retryAfterSeconds, 42)
        XCTAssertEqual(outcome.description, "CovaHTTPOutcome(status: 429, bytes: 0)")
    }

    func testOutcomeDefaultsToNilSecond() {
        XCTAssertNil(CovaHTTPOutcome(statusCode: 200, body: Data()).retryAfterSeconds)
    }

    /// 硬边界 3：描述与反射面只有状态码与字节数 —— 响应头（含 `Set-Cookie`）不在这个类型里，
    /// 也就不可能被这句 `description` 带出去。
    func testOutcomeDescribesNothingButStatusAndByteCount() throws {
        let outcome = CovaHTTPOutcome(
            statusCode: 429,
            body: Data("{\"error\":\"请求过于频繁\"}".utf8),
            retryAfterSeconds: 42
        )
        XCTAssertFalse(outcome.debugDescription.contains("请求过于频繁"))
        let children = outcome.customMirror.children.compactMap(\.label)
        XCTAssertEqual(children, ["statusCode", "bytes"])
    }
}
