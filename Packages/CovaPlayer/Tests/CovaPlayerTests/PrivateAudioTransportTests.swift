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
        /// 环 4（C2）：**落地权威**。URLSession 自动跟随重定向之后，交给调用方的
        /// `HTTPURLResponse.url` 就是重定向终点那一条（可能是另一台主机）。桩没有 socket、
        /// 也不重放跳转链，因此直接把「重定向之后」的响应形态交出来：`url` 用它。
        /// nil = 未发生重定向（响应的权威就是请求的权威）。
        var landedURLString: String?
        /// 环 4（C2）：落地跳要写的字节（nil = 沿用 `chunks`）。
        var landingChunks: [Data]?
        /// 环 4（C2）：非 HTTP 响应（走 `URLResponse`），用于「响应形态不对就 fail-closed」。
        var respondsAsPlainURLResponse = false
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
        let body = current.landingChunks ?? current.chunks
        let target = current.landedURLString.flatMap(URL.init(string:)) ?? request.url!
        let response: URLResponse
        if current.respondsAsPlainURLResponse {
            response = URLResponse(
                url: target,
                mimeType: "audio/mp4",
                expectedContentLength: body.reduce(0) { $0 + $1.count },
                textEncodingName: nil
            )
        } else {
            response = HTTPURLResponse(
                url: target,
                statusCode: current.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in body {
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

    // MARK: - 环 4 · C2：响应权威必须仍是发起那一台主机

    /// C2：URLSession 默认自动跟随**跨主机**重定向，交给调用方的 `HTTPURLResponse.url` 就是
    /// 落地那一条。不在写盘前判，任意主机的字节就会被当作 `file://` 交付播放 ——
    /// 判据必须在 `createFile` 之前，因此被拒时连文件都不该存在（一个字节都不写）。
    ///
    /// 离线口径：桩不重放跳转链（`URLProtocol` 不触发 URLSession 的重定向跟随），而是直接交出
    /// 「落地权威是另一台主机」的响应 —— 那正是传输层唯一能观测到的事实。
    func testCrossHostRedirectIsRejectedBeforeAnyByteIsWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = "https://other-authority.invalid/pawned.m4a"
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [],
            contentLength: nil,
            failure: nil,
            landedURLString: landing,
            landingChunks: [Data(repeating: 0x7f, count: 64)],
            respondsAsPlainURLResponse: false
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: SecretString("stub-token"), to: file, expectedBytes: nil
            )
            XCTFail("落地权威换人必须被拒绝")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .hostRejected, "跨主机重定向必须按权威不符拒绝：\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "被拒时一个字节都不该写盘")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? ["<读不到目录>"]
        XCTAssertTrue(leftovers.isEmpty, "不该留下任何临时文件：\(leftovers)")
        // 前置条件自证：传输层问的是生产权威，而响应报回来的权威是另一台主机（否则什么都没测到）。
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.url?.host, "audio.invalid")
        XCTAssertNotEqual(captured.first?.url?.absoluteString, landing)
    }

    /// C2 的对照（TD-9：合法工程不得误红）：同权威的重定向（换 path / 换 query）必须正常放行。
    func testSameAuthorityRedirectIsAcceptedAndWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [],
            contentLength: nil,
            failure: nil,
            landedURLString: "https://audio.invalid/private/moved.m4a?sig=rotated",
            landingChunks: [Data(repeating: 0x33, count: 24)],
            respondsAsPlainURLResponse: false
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 24, "同一台主机的落地字节必须照常交付")
        XCTAssertEqual(receipt.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file).count, 24)
    }

    /// C2：`http.url` 取不到（nil）时 fail-closed —— 「不知道字节来自谁」就等于不能写盘。
    /// C2：响应根本不是 `HTTPURLResponse`（没有状态码、没有权威）→ 同样按权威不可知拒绝。
    func testNonHTTPResponseIsRejectedAsHostRejected() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x02, count: 8)],
            contentLength: nil,
            failure: nil,
            respondsAsPlainURLResponse: true
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
            )
            XCTFail("非 HTTP 响应不得被当作可用音频")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .hostRejected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// C2 的纯决策面：origin 归一化与判定表（零 URLSession，把「等价」与「不等价」逐条钉住）。
    func testAuthorityMatchDecisionTable() {
        let base = URL(string: "https://audio.invalid/private/one.m4a?sig=a")!
        XCTAssertEqual(AudioAuthorityMatch.origin(of: base), "https://audio.invalid")
        // query / path / fragment 都不属于权威。
        XCTAssertEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid/other/x.m4a?sig=b#f")!),
            AudioAuthorityMatch.origin(of: base)
        )
        XCTAssertTrue(AudioAuthorityMatch.matches(requestURL: base, responseURL: base))
        // 权威不同（主机、端口、方案）一律不匹配。
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "https://other-authority.invalid/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "https://audio.invalid:8443/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "http://audio.invalid/one.m4a")!
        ), "降级到 http 不是同一权威")
        // 缺信息一律 fail-closed。
        XCTAssertFalse(AudioAuthorityMatch.matches(requestURL: base, responseURL: nil))
        XCTAssertNil(AudioAuthorityMatch.origin(of: nil))
        XCTAssertNil(AudioAuthorityMatch.origin(of: URL(string: "file:///tmp/x.m4a")!))
        // 大小写不敏感（权威比对不能因为服务端回了个大写主机名就误判）。
        XCTAssertTrue(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "HTTPS://AUDIO.INVALID/private/one.m4a")!
        ))
        XCTAssertEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid:443/one.m4a")!),
            "https://audio.invalid:443"
        )
    }

    // MARK: - 环 4 · m12：落盘权限收紧

    func testWrittenFileCarriesOwnerOnlyPermissions() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x55, count: 16)], contentLength: 16, failure: nil
        ))
        let file = target(in: directory)
        _ = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int32Value
        XCTAssertEqual(mode & 0o777, 0o600, "私有音频只能是 owner 可读写（实得 \(String(format: "%04o", mode))）")
        // m12 的反面：任何「组可读 / 其它可读」位都不许出现。
        XCTAssertEqual(mode & 0o077, 0)
    }

    func testFileAttributeTemplateCarriesOnlyTheOwnerReadWriteBits() {
        let raw = URLSessionPrivateAudioTransport.fileAttributes()[.posixPermissions] as? NSNumber
        XCTAssertEqual(raw?.int32Value, 0o600)
        XCTAssertEqual(PrivateAudioPath.fileMode, 0o600)
        XCTAssertEqual(
            Set(URLSessionPrivateAudioTransport.fileAttributes().keys.map(\.rawValue)),
            Set([FileAttributeKey.posixPermissions.rawValue])
        )
    }

    // MARK: - 环 4 · m14：写盘失败与短写都必须被判定

    /// `createFile` 返回 false（父目录不存在 → 不可写）时不得靠「句柄为 nil」猜错误码。
    func testUncreatableDestinationMapsToWriteFailedEINVAL() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x11, count: 16)], contentLength: 16, failure: nil
        ))
        let missingParent = directory.url
            .appendingPathComponent("no-such-directory", isDirectory: true)
            .appendingPathComponent("out.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.deletingLastPathComponent().path))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: missingParent, expectedBytes: nil
            )
            XCTFail("建不出文件必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .writeFailed(EINVAL), "建档失败必须报 EINVAL：\(error)")
        }
    }

    /// m14：短写（实际推进量 < 请求量）必须以 `writeFailed` 抛出，绝不把半截文件当成功。
    func testShortWriteIsRejectedInsteadOfSilentlyTruncated() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x22, count: 40)], contentLength: 40, failure: nil
        ))
        for reportedAdvance in [-1, 0] {
            // `-1` = 少写一字节；`0` = 完全没推进（磁盘满 / 句柄失效的可观测形态）。
            let shortWriter: PrivateAudioChunkWrite = { data, handle in
                if reportedAdvance < 0 {
                    return try URLSessionPrivateAudioTransport.defaultChunkWrite(Data(data.dropLast()), handle)
                }
                return 0
            }
            let file = directory.url.appendingPathComponent("short-\(reportedAdvance).part")
            do {
                _ = try await makeScriptedTransport(chunkWrite: shortWriter).writeAudio(
                    from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
                )
                XCTFail("短写必须被拒绝（推进量 \(reportedAdvance)）")
            } catch let error as PlayerError {
                XCTAssertEqual(error, .writeFailed(ENOSPC), "短写必须报 ENOSPC：\(error)")
            }
        }
    }

    /// 判定面与真实原语的分工：原语如实报推进量，判定始终在管道里。
    func testChunkWritePrimitiveAndJudgement() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let file = target(in: directory)
        FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: PrivateAudioPath.fileAttributes)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: file.path))
        defer { try? handle.close() }

        let payload = Data(repeating: 0x77, count: 5)
        XCTAssertEqual(
            try URLSessionPrivateAudioTransport.defaultChunkWrite(payload, handle),
            payload.count,
            "生产原语必须如实报告 offsetInFile 的推进量"
        )
        XCTAssertEqual(try Data(contentsOf: file).count, 5)

        let honest = makeScriptedTransport(chunkWrite: { data, handle in try URLSessionPrivateAudioTransport.defaultChunkWrite(data, handle) })
        XCTAssertEqual(try honest.writeChunk(Data([1, 2, 3]), to: handle), 3)
        let lying = makeScriptedTransport(chunkWrite: { _, _ in 2 })
        XCTAssertThrowsError(try lying.writeChunk(Data([1, 2, 3]), to: handle)) { error in
            XCTAssertEqual(error as? PlayerError, .writeFailed(ENOSPC))
        }
    }

    /// m14 的错误分类面：任何底层错误都只以整数码出去（不带路径 / 句柄描述）。
    func testWriteErrorMappingNeverEchoesPaths() throws {
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.mapWriteError(NSError(domain: NSCocoaErrorDomain, code: 516)),
            .writeFailed(EIO)
        )
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.mapWriteError(PlayerError.cancelled),
            .cancelled,
            "已分类的错误必须原样透出（取消不得被改写成 I/O 失败）"
        )
        let described = String(describing: URLSessionPrivateAudioTransport.mapWriteError(
            NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [NSFilePathErrorKey: "/私密/路径"])
        ))
        XCTAssertFalse(described.contains("私密"))
        XCTAssertFalse(described.contains("/"))
    }

    // MARK: - 环 4 · M8：作废在途而不是打死出口

    func testCancelInFlightTransfersAdvancesGenerationAndKeepsExitUsable() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x3d, count: 11)], contentLength: 11, failure: nil
        ))
        let transport = makeTransport()
        XCTAssertEqual(transport.sessionGeneration, 1, "注入的会话就是第 1 代")
        XCTAssertEqual(transport.cancellationCount, 0)
        _ = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )

        await transport.cancelInFlightTransfers()
        let cancellations = transport.cancellationCount
        XCTAssertEqual(cancellations, 1, "作废次数必须可观测（清理真的发生了）")
        XCTAssertEqual(transport.sessionGeneration, 1, "作废只摘走当前这一代，不预生成新会话")

        // 关键（旧行为）：一次性 `invalidateAndCancel()` 之后出口永久不再接受任务。
        let receipt = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory, name: "after-cancel.part"), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 11, "作废在途之后必须仍能服务下一次请求")
        let generation = transport.sessionGeneration
        XCTAssertEqual(generation, 2, "换代而不是打死")

        // 换代是惰性的：连续请求复用同一代（不得每次掐一次就 +1）。
        _ = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory, name: "same-generation.part"), expectedBytes: nil
        )
        XCTAssertEqual(transport.sessionGeneration, 2)
        await transport.cancelInFlightTransfers()
        XCTAssertEqual(transport.cancellationCount, 2)
        XCTAssertEqual(transport.sessionGeneration, 2)
    }

    /// 两次作废之间没有请求时，第二次作废不得凭空造会话（幂等的下线动作）。
    func testConsecutiveCancellationsWithoutTrafficDoNotLeakSessions() async {
        let transport = makeTransport()
        await transport.cancelInFlightTransfers()
        await transport.cancelInFlightTransfers()
        XCTAssertEqual(transport.cancellationCount, 2)
        XCTAssertEqual(transport.sessionGeneration, 1, "没人请求就不该换代")
    }

    func testShutDownIsTerminalWhileCancellationIsNot() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x08, count: 6)], contentLength: 6, failure: nil
        ))
        let transport = makeTransport()
        transport.shutDown()
        do {
            _ = try await transport.writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
            )
            XCTFail("终态下线之后不得再发起任何请求")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(transport.sessionGeneration, 1, "终态下线不得换代（出口没有再服务过）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(in: directory).path))
        transport.invalidateAndCancel()
        XCTAssertEqual(transport.sessionGeneration, 1)
    }

    /// 环 4 用：可注入分块写原语的会话桩（`makeTransport()` 的扩展形态，不动既有夹具）。
    private func makeScriptedTransport(chunkWrite: PrivateAudioChunkWrite? = nil) -> URLSessionPrivateAudioTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        return URLSessionPrivateAudioTransport(
            session: URLSession(configuration: configuration),
            chunkWrite: chunkWrite
        )
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
