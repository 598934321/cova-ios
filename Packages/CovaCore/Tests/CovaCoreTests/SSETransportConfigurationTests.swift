@testable import CovaCore
import Foundation
import XCTest

/// 拦截 `URLSession` 请求并记下 URLRequest（不产生任何真实网络）。
///
/// 可配置为：正常响应（指定状态码/响应体）、传输失败（指定错误）。
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var delaysResponse = false
    nonisolated(unsafe) static var stopLoadingTotal = 0
    private static let lock = NSLock()

    static func configure(
        statusCode: Int = 200,
        body: Data = Data(),
        failure: Error? = nil,
        delaysResponse: Bool = false
    ) {
        lock.lock()
        capturedRequests = []
        self.statusCode = statusCode
        self.responseBody = body
        self.failure = failure
        self.delaysResponse = delaysResponse
        stopLoadingTotal = 0
        lock.unlock()
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func stopLoadingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopLoadingTotal
    }

    private static func record(_ request: URLRequest) {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
    }

    private static func recordStop() {
        lock.lock()
        stopLoadingTotal += 1
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // delaysResponse：保持连接不结束，供取消测试观察 stopLoading。
        guard !Self.delaysResponse else { return }
        if !Self.responseBody.isEmpty {
            client?.urlProtocol(self, didLoad: Self.responseBody)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.recordStop()
    }
}

/// M3/F2/Minor-1：SSE 生产传输的超时语义、请求构造与关键生产分支。
/// **不发任何真实网络**（自定义 `URLProtocol` 拦截）。
final class SSETransportConfigurationTests: XCTestCase {
    private func makeStubTransport() -> URLSessionSSETransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionSSETransport(session: URLSession(configuration: configuration))
    }

    private func agentRequest() throws -> HTTPRequest {
        try CovaSSERequests.agent(jsonBody: Data("{}".utf8))
    }

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
        let request = try agentRequest()
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
        StubURLProtocol.configure(body: Data("event: done\ndata: {}\n\n".utf8))
        let transport = makeStubTransport()

        let stream = try await transport.stream(try agentRequest())
        for try await _ in stream {}

        let captured = StubURLProtocol.captured()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.timeoutInterval, URLSessionSSETransport.idleTimeout)
        XCTAssertNotEqual(captured.first?.timeoutInterval, URLSessionTransport.timeout)
    }

    /// Minor-1：已取消的任务调用 `stream()` 必须抛出（`.cancelled`）且**不发起网络**。
    func testStreamThrowsCancellationWhenTaskCancelledWithoutNetwork() async throws {
        StubURLProtocol.configure(body: Data("event: done\ndata: {}\n\n".utf8))
        let transport = makeStubTransport()
        let request = try agentRequest()

        let task = Task { () -> CovaAPIError in
            do {
                _ = try await transport.stream(request)
                return .invalidResponse // 哨兵：不应发生
            } catch {
                return CovaAPIError.normalize(error)
            }
        }
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertTrue(StubURLProtocol.captured().isEmpty, "取消后不得发起网络")
    }

    /// Minor-1：非 2xx → `.invalidResponse`。
    func testStreamMapsNonSuccessStatusToInvalidResponse() async throws {
        StubURLProtocol.configure(statusCode: 500, body: Data())
        let transport = makeStubTransport()

        let stream = try await transport.stream(try agentRequest())
        do {
            for try await _ in stream {}
            XCTFail("非 2xx 应抛错")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    /// Minor-1：响应体按 `chunkByteLimit` 分块产出，且字节不丢。
    func testStreamSplitsBodyIntoChunkLimitSizedPieces() async throws {
        let total = 10_000
        StubURLProtocol.configure(body: Data(repeating: 0x41, count: total))
        let transport = makeStubTransport()

        let stream = try await transport.stream(try agentRequest())
        var chunks: [Data] = []
        for try await chunk in stream { chunks.append(chunk) }

        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, total)
        XCTAssertEqual(chunks.count, 3, "10000 字节应切成 4096 + 4096 + 1808")
        // 安全解包：即便分块数回归，也只是断言失败而非下标越界崩溃（Minor-2）。
        XCTAssertEqual(chunks.first?.count, URLSessionSSETransport.chunkByteLimit)
        XCTAssertEqual(chunks.dropFirst().first?.count, URLSessionSSETransport.chunkByteLimit)
        XCTAssertEqual(chunks.last?.count, total - 2 * URLSessionSSETransport.chunkByteLimit)
    }

    /// M-1/D16②：取消消费任务必须立即取消底层 URLSession 任务（`stopLoading` 被调用）。
    func testStreamCancellationStopsUnderlyingURLSessionTask() async throws {
        StubURLProtocol.configure(body: Data(), delaysResponse: true)
        let transport = makeStubTransport()
        let request = try agentRequest()

        let task = Task {
            do {
                let stream = try await transport.stream(request)
                for try await _ in stream {}
            } catch {
                // 取消以错误结束，属预期。
            }
        }
        // 请求已发起并停在未完成状态。
        let started = await waitUntil { !StubURLProtocol.captured().isEmpty }
        XCTAssertTrue(started)

        task.cancel()
        _ = await task.value
        let stopped = await waitUntil { StubURLProtocol.stopLoadingCount() > 0 }
        XCTAssertTrue(stopped, "取消后必须停止底层 URLSession 任务")
    }

    /// D16②（轮询入口）：在途轮询请求取消后必须停止底层 URLSession 任务，且结果以取消结束。
    func testPollInFlightRequestCancelledAtURLSession() async throws {
        StubURLProtocol.configure(body: Data("{}".utf8), delaysResponse: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let httpTransport = URLSessionTransport(session: URLSession(configuration: configuration))
        let poller = HTTPOneStepPlanPoller(transport: httpTransport)

        let task = Task { () -> CovaAPIError? in
            do {
                _ = try await poller.pollPlans(sessionId: "s-1")
                return nil
            } catch {
                return CovaAPIError.normalize(error)
            }
        }
        // 请求已发起并停在未完成状态（确定性：等到 captured 再取消）。
        let started = await waitUntil { !StubURLProtocol.captured().isEmpty }
        XCTAssertTrue(started, "轮询请求应已发起并在途")

        task.cancel()
        let error = await task.value
        XCTAssertEqual(error, .cancelled, "在途轮询取消后应以取消结束")
        let stopped = await waitUntil { StubURLProtocol.stopLoadingCount() > 0 }
        XCTAssertTrue(stopped, "取消后必须停止底层 URLSession 任务")
    }

    /// Minor-1：底层传输错误归一化为 `CovaAPIError`。
    func testStreamNormalizesTransportFailure() async throws {
        StubURLProtocol.configure(failure: URLError(.timedOut))
        let transport = makeStubTransport()

        let stream = try await transport.stream(try agentRequest())
        do {
            for try await _ in stream {}
            XCTFail("传输失败应抛错")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testSSETransportRejectsNonProductionOriginWithoutNetwork() async {
        StubURLProtocol.configure(body: Data("event: done\ndata: {}\n\n".utf8))
        let transport = makeStubTransport()
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
        XCTAssertTrue(StubURLProtocol.captured().isEmpty)
    }
}
