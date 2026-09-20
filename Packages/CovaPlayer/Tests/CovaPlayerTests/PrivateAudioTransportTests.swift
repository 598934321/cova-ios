import XCTest
import CovaCore
import Foundation
@testable import CovaPlayer

/// 私有音频**落盘式**传输（`URLSessionPrivateAudioTransport`）的离线测试。
///
/// 零网络：自定义 `URLProtocol` 在建立 socket 之前就接管请求；且主机刻意用保留的
/// 不可解析 TLD `.invalid` —— 万一桩没接管，结果是「测试变红」而不是真的出网。
/// （对照 `SSETransportConfigurationTests` 的同类做法。）
private final class StubAudioURLProtocol: URLProtocol {
    struct Script {
        var statusCode = 200
        var chunks: [Data] = []
        var contentLength: Int?
        var failure: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script = Script()
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

    static func configure(_ update: Script) {
        lock.lock()
        defer { lock.unlock() }
        script = update
        capturedRequests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    /// 锁内「记录请求 + 取脚本快照」，避免 `startLoading`（URLSession 后台线程）裸读静态可变状态。
    private static func snapshot(for request: URLRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        return script
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.snapshot(for: request)
        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var headers: [String: String] = ["Content-Type": "audio/mp4"]
        if let length = current.contentLength {
            headers["Content-Length"] = String(length)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: current.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in current.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PrivateAudioTransportTests: XCTestCase {
    private static let host = "https://audio.invalid"

    private func makeTransport() -> URLSessionPrivateAudioTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        return URLSessionPrivateAudioTransport(session: URLSession(configuration: configuration))
    }

    private func sourceURL(_ path: String = "/private/one.m4a") -> URL {
        URL(string: "\(Self.host)\(path)")!
    }

    private func target(in directory: TemporaryDirectory, name: String = "out.part") -> URL {
        directory.url.appendingPathComponent(name)
    }

    // MARK: - 正常路径

    func testStreamedBodyIsWrittenToDiskAndReceiptReportsBytes() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let body = Data(repeating: 0x7f, count: 140)
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [body], contentLength: 140, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: SecretString("stub-token-should-never-be-logged"),
            to: target(in: directory),
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 140)
        XCTAssertEqual(receipt.expectedBytes, 140)
        XCTAssertEqual(receipt.statusCode, 200)
        XCTAssertTrue(receipt.isComplete)
        let file = target(in: directory)
        let written = try Data(contentsOf: file)
        XCTAssertEqual(written.count, 140)
    }

    func testPayloadCrossingChunkBoundaryIsFullyWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let total = URLSessionPrivateAudioTransport.writeChunkBytes + 7
        let first = Data(repeating: 0x11, count: URLSessionPrivateAudioTransport.writeChunkBytes)
        let second = Data(repeating: 0x22, count: 7)
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [first, second], contentLength: total, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: nil,
            to: target(in: directory),
            expectedBytes: total
        )
        XCTAssertEqual(receipt.bytesWritten, total, "整块 + 残块都必须落盘")
        XCTAssertEqual(try Data(contentsOf: target(in: directory)).count, total)
    }

    func testBearerHeaderIsAttachedAndNeverEchoedThroughReceiptOrError() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let token = "super-secret-token-value"
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([1, 2, 3])], contentLength: 3, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: SecretString(token),
            to: target(in: directory),
            expectedBytes: nil
        )
        let described = String(describing: receipt)
        XCTAssertFalse(described.contains(token), "回执描述不得带出凭证")
        XCTAssertFalse(described.lowercased().contains("authorization"))
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.count, 1)
        let header = captured.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header?.hasPrefix("Bearer "), true, "Bearer 必须由凭证提供器注入")
        XCTAssertEqual(header?.count, "Bearer ".count + token.count)
    }

    func testAbsentAuthorizationSendsNoHeader() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([0])], contentLength: nil, failure: nil))
        _ = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: nil,
            to: target(in: directory),
            expectedBytes: nil
        )
        let header = StubAudioURLProtocol.captured().first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(header)
    }

    // MARK: - 状态与错误分类

    func testNon2xxStatusBecomesBadStatusWithCodeOnly() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 503, chunks: [], contentLength: nil, failure: nil))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(),
                authorization: nil,
                to: target(in: directory),
                expectedBytes: nil
            )
            XCTFail("非 2xx 必须抛错")
        } catch let error as PlayerError {
            guard case .badStatus(let code) = error else { return XCTFail("应为 badStatus：\(error)") }
            XCTAssertEqual(code, 503)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(in: directory).path), "错误响应不得留下文件")
    }

    func testTransportFailuresAreClassifiedAsCancellationOrBadStatus() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [], contentLength: nil, failure: URLError(.cancelled)))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
            )
            XCTFail("取消必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .cancelled)
        }

        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [], contentLength: nil, failure: URLError(.networkConnectionLost)
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory, name: "lost.part"), expectedBytes: nil
            )
            XCTFail("传输失败必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .badStatus(0))
        }
    }

    func testTruncatedAgainstDeclaredLengthIsReportedNotHidden() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x33, count: 10)],
            contentLength: 999,
            failure: nil
        ))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 10)
        XCTAssertEqual(receipt.expectedBytes, 999, "服务端声明的长度必须透传给上层判定")
        XCTAssertFalse(receipt.isComplete)
    }

    func testCallerExpectationIsUsedWhenServerDeclaresNothing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x44, count: 12)], contentLength: nil, failure: nil
        ))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: 12
        )
        XCTAssertEqual(receipt.expectedBytes, 12, "无 Content-Length 时退回调用方期望值")
        XCTAssertTrue(receipt.isComplete)
    }

    func testEmptyBodyYieldsZeroByteReceipt() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 204, chunks: [], contentLength: 0, failure: nil))
        // 204 属 2xx：回执必须如实报 0 字节，由上层按「空文件」拒绝（D7「校验非空」）。
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 0)
        XCTAssertFalse(receipt.isComplete)
        XCTAssertEqual(receipt.statusCode, 204)
    }

    // MARK: - 生产默认与会话生命周期

    func testDefaultTransportPinsAudioShapedTimeouts() {
        let transport = URLSessionPrivateAudioTransport()
        XCTAssertEqual(URLSessionPrivateAudioTransport.requestTimeout, 15, "建连/首字节超时（大文件读）")
        XCTAssertEqual(URLSessionPrivateAudioTransport.resourceTimeout, 7 * 24 * 60 * 60)
        XCTAssertGreaterThan(URLSessionPrivateAudioTransport.resourceTimeout, 60 * 60)
        XCTAssertGreaterThan(URLSessionPrivateAudioTransport.writeChunkBytes, 0)
        transport.invalidateAndCancel()
    }

    func testGETIsTheOnlyMethodIssued() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([9])], contentLength: 1, failure: nil))
        _ = try await makeTransport().writeAudio(
            from: sourceURL("/private/two.m4a"), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.first?.httpMethod, "GET")
        XCTAssertEqual(captured.first?.url?.host, "audio.invalid")
    }
}
