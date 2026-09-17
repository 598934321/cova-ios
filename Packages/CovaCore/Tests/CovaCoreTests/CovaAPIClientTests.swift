@testable import CovaCore
import Foundation
import XCTest

private struct ProbeBody: Encodable { let value: String }
private struct CountDTO: Decodable { let count: Int }

/// 单飞并发测试专用：拦住全部「旧 token」请求，等 N 个到齐后一起回 401。
/// 这样可证明「N 个并发 401 只触发 1 次 refresh」而非靠时序侥幸。
private actor GatedTransport: HTTPTransport {
    static let protectedPath = "/api/tracks/1"
    static let oldAccess = "ACCESS_TOKEN_PLACEHOLDER"
    static let newAccess = "ACCESS_TOKEN_PLACEHOLDER_2"

    private let expectedOldArrivals: Int
    private var oldArrivals = 0
    private var barrier: [CheckedContinuation<Void, Never>] = []
    private var recorded: [HTTPRequest] = []

    init(expectedOldArrivals: Int) {
        self.expectedOldArrivals = expectedOldArrivals
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        switch request.url.path {
        case CovaAuthSession.loginPath:
            return HTTPResponse(statusCode: 200, body: TestTransportData.login)
        case CovaAuthSession.refreshPath:
            return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
        case Self.protectedPath:
            if request.bearerToken == Self.oldAccess {
                await waitForBarrier()
                return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        default:
            return HTTPResponse(statusCode: 404, body: Data())
        }
    }

    func requestCount(path: String) -> Int { recorded.filter { $0.url.path == path }.count }

    private func waitForBarrier() async {
        oldArrivals += 1
        if oldArrivals >= expectedOldArrivals {
            let waiters = barrier
            barrier = []
            for waiter in waiters { waiter.resume() }
            return
        }
        await withCheckedContinuation { barrier.append($0) }
    }
}

final class CovaAPIClientTests: XCTestCase {
    // MARK: - 单飞 refresh

    func testConcurrent401TriggersSingleRefreshAndReplaysAll() async throws {
        let concurrency = 12
        let transport = GatedTransport(expectedOldArrivals: concurrency)
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    do {
                        let _: EmptyDTO = try await client.get(GatedTransport.protectedPath)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var ok = 0
            for await result in group where result { ok += 1 }
            return ok
        }

        XCTAssertEqual(successes, concurrency, "全部并发请求应重放成功")
        let refreshCount = await transport.requestCount(path: CovaAuthSession.refreshPath)
        XCTAssertEqual(refreshCount, 1, "并发 401 只允许触发一次 refresh")
        let protectedCount = await transport.requestCount(path: GatedTransport.protectedPath)
        XCTAssertEqual(protectedCount, concurrency * 2, "每个请求恰重放一次")

        let expectedUser = try Fixture.decode(CovaLoginResponseDto.self, "auth-login").user
        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(expectedUser))
    }

    func testRefreshFailureClearsCredentialsAndSignsOut() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            }
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        do {
            let _: EmptyDTO = try await client.get("/api/tracks/1")
            XCTFail("刷新失败时原请求应抛出错误")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }

        let state = await session.currentState()
        let token = await session.accessToken()
        let principal = await session.currentPrincipal()
        let owner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(token)
        XCTAssertNil(principal)
        XCTAssertNil(owner)
        let accessItem = SecureStoreItem(principalId: PrincipalID(rawValue: "user-0001"), kind: .accessToken)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
        let refreshCount = await transport.requestCount(path: CovaAuthSession.refreshPath)
        XCTAssertEqual(refreshCount, 1)
    }

    func testReplayHappensOnlyOnceEvenWhenStillUnauthorized() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            default: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            }
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        do {
            let _: EmptyDTO = try await client.get("/api/tracks/1")
            XCTFail("重放仍 401 应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }
        let protectedCount = await transport.requestCount(path: "/api/tracks/1")
        let refreshCount = await transport.requestCount(path: CovaAuthSession.refreshPath)
        XCTAssertEqual(protectedCount, 2, "原始 + 重放各一次")
        XCTAssertEqual(refreshCount, 1, "重放仍 401 不得二次刷新")
        let authenticated = await session.currentState().isAuthenticated
        XCTAssertTrue(authenticated, "重放 401 不属于刷新失败，不应登出")
    }

    // MARK: - 错误映射

    func testTimeoutErrorIsDecidableWithoutRealWaiting() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            throw CovaAPIError.timeout
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)

        do {
            let _: EmptyDTO = try await client.get("/api/tracks/1")
            XCTFail("应超时")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .timeout)
        }
    }

    func testURLSessionURLErrorIsNormalized() async throws {
        let transport = FakeHTTPTransport { _ in throw URLError(.timedOut) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        do {
            let _: EmptyDTO = try await client.get("/api/tracks/1")
            XCTFail("应超时")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .timeout)
        }
    }

    func testDecodingFailureIsDecidableAndKeepsFieldPath() async throws {
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"count":"not-a-number"}"#.utf8))
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        do {
            let _: CountDTO = try await client.get("/api/probe")
            XCTFail("应解码失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .decoding(field: "count"))
        }
    }

    func testHTTPFailureMapsToStatusAndBusinessCode() async throws {
        let body = Data(#"{"error":"积分不足","code":"INSUFFICIENT_CREDITS"}"#.utf8)
        let transport = FakeHTTPTransport { _ in HTTPResponse(statusCode: 402, body: body) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        do {
            let _: EmptyDTO = try await client.get("/api/downloads/checkout")
            XCTFail("应返回 402")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS"))
        }
    }

    func testUnknownTransportErrorMapsToTransportCode() async throws {
        let transport = FakeHTTPTransport { _ in throw NSError(domain: "probe.domain", code: 4321) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        do {
            let _: EmptyDTO = try await client.get("/api/probe")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .transport(code: 4321))
        }
    }

    // MARK: - 出口守卫

    func testIllegalOutboundPathsAreRejectedWithoutAnyTransportCall() async throws {
        let transport = FakeHTTPTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.ok) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)

        let illegal = [
            "https://evil.invalid/api/tracks",
            "//evil.invalid/api/tracks",
            "/api/tracks\\..\\..",
            "/api/tracks?injected=1",
            "/api/tracks#fragment",
            "api/tracks"
        ]
        for path in illegal {
            do {
                let _: EmptyDTO = try await client.get(path)
                XCTFail("非法路径应被拒绝：\(path)")
            } catch {
                XCTAssertEqual(error as? CovaAPIError, .invalidRequestURL, "path=\(path)")
            }
        }
        let recorded = await transport.recordedRequests()
        XCTAssertTrue(recorded.isEmpty, "非法 URL 不得产生任何传输调用")
    }

    // MARK: - 授权头与登出

    func testNoAuthorizationHeaderWhenSignedOut() async throws {
        let transport = FakeHTTPTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.ok) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        let _: EmptyDTO = try await client.get("/api/tracks")

        let recorded = await transport.recordedRequests()
        let state = await session.currentState()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertNil(recorded[0].bearerToken)
        XCTAssertEqual(state, .signedOut)
    }

    func testGuestKeepsBrowsingWithoutAuthorizationHeader() async throws {
        let transport = FakeHTTPTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.ok) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        await session.continueAsGuest()
        let client = CovaAPIClient(transport: transport, credentials: session)
        let _: EmptyDTO = try await client.get("/api/tracks")

        let recorded = await transport.recordedRequests()
        let state = await session.currentState()
        XCTAssertEqual(state, .guest)
        XCTAssertNil(recorded.first?.bearerToken)
    }

    func testAfterSignOutRequestsCarryNoOldToken() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            if request.url.path == CovaAuthSession.logoutPath {
                return HTTPResponse(statusCode: 200, body: Data(#"{"message":"ok"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        try await session.signOut()
        let _: EmptyDTO = try await client.get("/api/tracks")

        let recorded = await transport.recordedRequests()
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        let token = await session.accessToken()
        XCTAssertEqual(recorded.last?.bearerToken, nil, "登出后请求不得携带旧 token")
        XCTAssertEqual(logoutCount, 1)
        XCTAssertNil(token)
        let accessItem = SecureStoreItem(principalId: PrincipalID(rawValue: "user-0001"), kind: .accessToken)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
    }

    // MARK: - 便捷方法 / 查询参数 / 脱敏

    func testPostPatchDeleteWrappersSendBodies() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)

        let _: EmptyDTO = try await client.post("/api/probe", body: ProbeBody(value: "a"))
        let _: EmptyDTO = try await client.patch("/api/probe", body: ProbeBody(value: "b"))
        let _: EmptyDTO = try await client.delete("/api/probe", body: ProbeBody(value: "c"))

        let probe = (await transport.recordedRequests()).filter { $0.url.path == "/api/probe" }
        XCTAssertEqual(probe.map(\.method), [.post, .patch, .delete])
        for request in probe {
            XCTAssertEqual(request.headers["Content-Type"], "application/json")
            XCTAssertNotNil(request.body)
        }
    }

    func testQueryItemsAreForwarded() async throws {
        let transport = FakeHTTPTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.ok) }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        let client = CovaAPIClient(transport: transport, credentials: session)
        let _: EmptyDTO = try await client.get("/api/tracks", queryItems: [URLQueryItem(name: "similarTo", value: "abc")])

        let request = (await transport.recordedRequests()).first
        XCTAssertEqual(request?.url.query, "similarTo=abc")
    }

    func testRecordedRequestNeverRendersBearerToken() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let client = CovaAPIClient(transport: transport, credentials: session)
        let _: EmptyDTO = try await client.get("/api/tracks")

        let allRequests = await transport.recordedRequests()
        let signed = try XCTUnwrap(allRequests.last(where: { $0.url.path == "/api/tracks" }))
        XCTAssertEqual(signed.bearerToken, "ACCESS_TOKEN_PLACEHOLDER")
        let rendered = renderAllSurfaces(signed)
        XCTAssertFalse(rendered.contains("ACCESS_TOKEN_PLACEHOLDER"), "authorization header 不得进入描述面：\(rendered)")
    }
}
