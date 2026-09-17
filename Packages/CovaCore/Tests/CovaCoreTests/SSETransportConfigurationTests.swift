@testable import CovaCore
import Foundation
import XCTest

/// 拦截 `URLSession` 请求并记下 URLRequest（不产生任何真实网络）。
private final class CapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var captured: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
    }

    static func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event: done\ndata: {}\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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

    /// F2：钉死 `stream()` 实际发出的 URLRequest 超时 = idleTimeout（删掉 `timeoutInterval:` 实参即红）。
    func testStreamBuildsURLRequestWithIdleTimeout() async throws {
        CapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let transport = URLSessionSSETransport(session: URLSession(configuration: configuration))

        let request = try CovaSSERequests.agent(jsonBody: Data("{}".utf8))
        let stream = try await transport.stream(request)
        for try await _ in stream {}

        let captured = CapturingURLProtocol.snapshot()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.timeoutInterval, URLSessionSSETransport.idleTimeout)
        XCTAssertNotEqual(captured.first?.timeoutInterval, URLSessionTransport.timeout)
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
