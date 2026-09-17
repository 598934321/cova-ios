@testable import CovaCore
import Foundation
import XCTest

/// M3：SSE 生产传输必须使用「无限流」超时语义（空闲 > 30s 静默窗口、资源总时限足够大），
/// 与普通请求的 15s/15s 明确区分。**不发任何网络请求**（仅读会话配置 / 断言守卫）。
final class SSETransportConfigurationTests: XCTestCase {
    func testSSESessionUsesLongIdleAndNearInfiniteResourceTimeout() {
        let session = URLSessionSSETransport.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, URLSessionSSETransport.idleTimeout)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, URLSessionSSETransport.resourceTimeout)
        XCTAssertGreaterThan(
            session.configuration.timeoutIntervalForRequest,
            OneStepDegradationPolicy().silenceTimeout,
            "空闲超时必须大于 30s 静默窗口，否则长连接会在静默判定前被 URLSession 掐断"
        )
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 7 * 24 * 60 * 60)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testPlainRequestSessionKeepsContract15sTimeouts() {
        let session = URLSessionTransport.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 15)
    }

    func testSSERequestUsesIdleTimeoutNotContract15s() throws {
        let request = try CovaSSERequests.agent(jsonBody: Data("{}".utf8))
        let urlRequest = URLSessionTransport.makeURLRequest(
            request,
            timeoutInterval: URLSessionSSETransport.idleTimeout
        )
        XCTAssertEqual(urlRequest.timeoutInterval, URLSessionSSETransport.idleTimeout)
        // 普通请求仍为契约 15s。
        XCTAssertEqual(URLSessionTransport.makeURLRequest(request).timeoutInterval, 15)
    }

    func testSSETransportRejectsNonProductionOriginWithoutNetwork() async {
        let transport = URLSessionSSETransport()
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://evil.example/api/studio/agent")!
        )
        do {
            _ = try await transport.stream(request)
            XCTFail("非生产 origin 必须被拒绝")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .invalidRequestURL)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }
}
