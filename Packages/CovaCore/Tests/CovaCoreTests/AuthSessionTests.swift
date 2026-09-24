@testable import CovaCore
import Foundation
import XCTest

final class AuthSessionTests: XCTestCase {
    private let loginUser = PrincipalID(rawValue: "user-0001")

    private func makeSession(
        transport: any HTTPTransport,
        stack: TestStack
    ) -> CovaAuthSession {
        makeAuthSession(transport: transport, stack: stack)
    }

    /// 构造绑定当前 owner + generation 的会话快照（测试用）。
    private func snapshot(
        stack: TestStack,
        token: SecretString,
        principal: PrincipalID? = nil
    ) async -> AuthSessionSnapshot {
        let generation = await stack.lifecycle.currentGeneration()
        return AuthSessionSnapshot(
            principal: principal ?? loginUser,
            generation: generation,
            accessToken: token
        )
    }

    /// 登录两步流（`/login` + 同 id 的 `/me`）+ 刷新 200 + 登出 200。
    private func loginTransport() -> FakeHTTPTransport {
        makeAuthTransport { request in
            switch request.url.path {
            case CovaAuthSession.refreshPath:
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            case CovaAuthSession.logoutPath:
                return HTTPResponse(statusCode: 200, body: Data(#"{"message":"ok"}"#.utf8))
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
    }

    func testInitialStateIsSignedOut() async throws {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        let state = await session.currentState()
        let user = await session.currentUser()
        let principal = await session.currentPrincipal()
        let token = try await session.accessToken()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(user)
        XCTAssertNil(principal)
        XCTAssertNil(token)
    }

    func testContinueAsGuestOnlyFromSignedOut() async throws {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        await session.continueAsGuest()
        let guestState = await session.currentState()
        XCTAssertEqual(guestState, .guest)
        await session.continueAsGuest()
        let againState = await session.currentState()
        let token = try await session.accessToken()
        XCTAssertEqual(againState, .guest)
        XCTAssertNil(token)
    }

    func testSignInStoresTokensBindsOwnerAndAdvancesGeneration() async throws {
        let stack = makeTestStack()
        let transport = loginTransport()
        let session = makeSession(transport: transport, stack: stack)
        let before = await stack.lifecycle.currentGeneration()

        let user = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        let state = await session.currentState()
        let principal = await session.currentPrincipal()
        let owner = await stack.lifecycle.currentOwner()
        let after = await stack.lifecycle.currentGeneration()
        let token = try await session.accessToken()
        XCTAssertEqual(user.id, "user-0001")
        XCTAssertEqual(state, .authenticated(user))
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(principal, loginUser)
        XCTAssertEqual(owner, loginUser)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(token?.rawValue, "ACCESS_TOKEN_PLACEHOLDER")
        XCTAssertEqual(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .refreshToken))?.rawValue,
            "REFRESH_TOKEN_PLACEHOLDER"
        )
        // 登录是两步：`/login` 建立凭证后必须由 `/me` 取回权威身份，且恰一次。
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(meCount, 1, "登录后必须由 GET /api/auth/me 取回身份")
    }

    func testSignInFailureKeepsSignedOutAndStoresNothing() async {
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)

        do {
            _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
            XCTFail("登录应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }
        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(owner)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
    }

    func testSignInRequestCarriesNoAuthorizationHeaderAndRedactedPassword() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        let password = "LEAK-LOGIN-PASSWORD"
        try await session.signIn(email: "tester@example.invalid", password: SecretString(password))

        let loginRequests = (await transport.recordedRequests()).filter { $0.url.path == CovaAuthSession.loginPath }
        let request = try XCTUnwrap(loginRequests.first)
        XCTAssertNil(request.bearerToken, "登录请求不得携带旧 token")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("email"), "请求体应含契约字段")
        let rendered = renderAllSurfaces(request)
        XCTAssertFalse(rendered.contains(password), "密码不得进入描述面：\(rendered)")
    }

    func testSignOutClearsCredentialsAndCallsServerLogout() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        try await session.signOut()

        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(owner)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .refreshToken)))
        XCTAssertEqual(logoutCount, 1)
    }

    func testGuestSignOutIsNoOpWithoutServerCall() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        await session.continueAsGuest()

        try await session.signOut()

        let state = await session.currentState()
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(logoutCount, 0)
    }

    func testSwitchAccountClearsPreviousOwnerCredentials() async throws {
        // 两次登录分别是账号 A、B；每次登录的 `/me` 都回**同 id** 的身份（两步流硬要求）。
        let transport = makeAuthTransport(script: AuthFlowScript(accounts: [.a, .b]))
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)

        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))
        try await session.signIn(email: "b@example.invalid", password: SecretString("pw"))

        let newOwner = PrincipalID(rawValue: "user-0002")
        let principal = await session.currentPrincipal()
        let owner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(principal, newOwner)
        XCTAssertEqual(owner, newOwner)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
        XCTAssertEqual(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: newOwner, kind: .accessToken))?.rawValue,
            "SECOND_ACCESS"
        )
        // A、B 各自完成两步：两次登录 + 两次取身份。
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(loginCount, 2)
        XCTAssertEqual(meCount, 2, "每次登录都必须各取一次 `/me`")
    }

    func testRefreshRotatesTokensAndIsSingleFlight() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func increment() { lock.lock(); calls += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let counter = Counter()
        let transport = makeAuthTransport { request in
            if request.url.path == CovaAuthSession.refreshPath {
                counter.increment()
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let staleValue = try await session.accessToken()
        let stale = try XCTUnwrap(staleValue)
        let boundSnapshot = await snapshot(stack: stack, token: stale)

        let tokens = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<10 {
                group.addTask { try? await session.refreshAccessToken(for: boundSnapshot).rawValue }
            }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(counter.value, 1, "并发刷新只允许一次网络调用")
        XCTAssertEqual(tokens.compactMap { $0 }.count, 10)
        XCTAssertTrue(tokens.allSatisfy { $0 == "ACCESS_TOKEN_PLACEHOLDER_2" })
        let access = try await session.accessToken()
        XCTAssertEqual(access?.rawValue, "ACCESS_TOKEN_PLACEHOLDER_2")
        XCTAssertEqual(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .refreshToken))?.rawValue,
            "REFRESH_TOKEN_PLACEHOLDER_2"
        )
    }

    /// 陈旧 token 去重：token 已被刷新后，携旧 token 的 401 处理不得再触发刷新网络调用。
    func testStaleTokenRefreshReturnsCurrentWithoutNewNetworkCall() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func increment() { lock.lock(); calls += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let counter = Counter()
        let transport = makeAuthTransport { request in
            if request.url.path == CovaAuthSession.refreshPath {
                counter.increment()
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let staleValue = try await session.accessToken()
        let stale = try XCTUnwrap(staleValue)
        let boundSnapshot = await snapshot(stack: stack, token: stale)

        let first = try await session.refreshAccessToken(for: boundSnapshot)
        let second = try await session.refreshAccessToken(for: boundSnapshot)

        XCTAssertEqual(first, second)
        XCTAssertEqual(counter.value, 1, "陈旧 token 不得触发第二次刷新")
    }

    func testRefreshFailureSignsOutAndClearsCredentials() async throws {
        let transport = makeAuthTransport { request in
            switch request.url.path {
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let oldValue = try await session.accessToken()
        let old = try XCTUnwrap(oldValue)
        let boundSnapshot = await snapshot(stack: stack, token: old)

        do {
            _ = try await session.refreshAccessToken(for: boundSnapshot)
            XCTFail("刷新应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }
        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(owner)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
    }

    func testRefreshWithoutRefreshTokenInvalidatesSession() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let oldValue = try await session.accessToken()
        let old = try XCTUnwrap(oldValue)
        let boundSnapshot = await snapshot(stack: stack, token: old)
        try stack.secureStore.removeSecret(for: SecureStoreItem(principalId: loginUser, kind: .refreshToken))

        do {
            _ = try await session.refreshAccessToken(for: boundSnapshot)
            XCTFail("缺 refresh token 应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }
        let state = await session.currentState()
        let refreshRequests = (await transport.recordedRequests()).filter { $0.url.path == CovaAuthSession.refreshPath }
        XCTAssertEqual(state, .signedOut)
        XCTAssertTrue(refreshRequests.isEmpty)
    }

    func testRefreshWhenSignedOutThrowsSessionChanged() async {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        let orphan = AuthSessionSnapshot(
            principal: loginUser,
            generation: .initial,
            accessToken: SecretString("orphan")
        )
        do {
            _ = try await session.refreshAccessToken(for: orphan)
            XCTFail("未登录不应可刷新")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .sessionChanged)
        }
    }

    func testSignOutSurfacesCleanupFailureButStillSignsOut() async throws {
        struct FailingCleaner: LocalSessionStateClearing {
            func clearPlayQueue() async throws { throw SessionCleanupFailure(failedComponents: [.playQueue]) }
            func clearPrivateMediaCache(owner: PrincipalID) async throws {}
            func tearDownPlayback(owner: PrincipalID) async throws {}
        }
        let transport = loginTransport()
        let stack = makeTestStack(cleaners: [FailingCleaner()])
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        do {
            try await session.signOut()
            XCTFail("清理失败应上报")
        } catch {
            XCTAssertEqual(error as? SessionCleanupFailure, SessionCleanupFailure(failedComponents: [.playQueue]))
        }
        let state = await session.currentState()
        XCTAssertEqual(state, .signedOut)
    }

    // MARK: - m-1：换号清理失败必须上报（与 signOut 一致）

    func testSwitchAccountCleanupFailureIsSurfacedButSessionStillSwitches() async throws {
        struct FailingCleaner: LocalSessionStateClearing {
            func clearPlayQueue() async throws { throw SessionCleanupFailure(failedComponents: [.playQueue]) }
            func clearPrivateMediaCache(owner: PrincipalID) async throws {}
            func tearDownPlayback(owner: PrincipalID) async throws {}
        }
        let script = AuthFlowScript(accounts: [.a, .b])
        let transport = makeAuthTransport(script: script)
        let stack = makeTestStack(cleaners: [FailingCleaner()])
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))

        do {
            _ = try await session.signIn(email: "b@example.invalid", password: SecretString("pw"))
            XCTFail("换号清理失败应上报")
        } catch {
            XCTAssertEqual(error as? SessionCleanupFailure, SessionCleanupFailure(failedComponents: [.playQueue]))
        }

        let newOwner = PrincipalID(rawValue: "user-0002")
        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.user?.id, "user-0002")
        XCTAssertEqual(owner, newOwner)
        XCTAssertEqual(pointer, newOwner)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
        XCTAssertEqual(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: newOwner, kind: .accessToken))?.rawValue,
            "SECOND_ACCESS"
        )
    }

    // MARK: - m-2：凭证读取失败 vs 本无凭证

    func testCredentialReadFailureIsObservableAndDistinctFromAbsence() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let failing = ReadFailingSecureStore(inner: stack.secureStore, failingReads: false)
        let session = CovaAuthSession(
            transport: transport,
            secureStore: failing,
            lifecycle: stack.lifecycle,
            activeOwnerStore: stack.activeOwnerStore
        )
        // 登录两步流的 `/me` 也要读 access token，故先让读可用、建立一次**真实登录**，
        // 再翻转成「keychain 读不出」——m-2 要区分的正是登录之后的读失败与本无凭证。
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        failing.setFailingReads(true)

        do {
            _ = try await session.accessToken()
            XCTFail("读失败应抛出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .credentialReadFailed)
        }
        do {
            _ = try await session.currentSession()
            XCTFail("读失败应抛出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .credentialReadFailed)
        }
        do {
            _ = try await session.restoreSession()
            XCTFail("读失败应抛出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .credentialReadFailed)
        }

        let client = CovaAPIClient(transport: transport, credentials: session)
        do {
            let _: EmptyDTO = try await client.get("/api/probe")
            XCTFail("读失败时请求不得发出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .credentialReadFailed)
        }
        let probeCount = await transport.requestCount(path: "/api/probe")
        XCTAssertEqual(probeCount, 0, "凭证读取失败时不得发出请求")
    }

    func testMissingAccessTokenYieldsNoAuthorizationHeaderNotAnError() async throws {
        let transport = loginTransport()
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        try stack.secureStore.removeSecret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken))

        let bound = try await session.currentSession()
        XCTAssertNil(bound, "本无 token 应返回 nil，而非抛错")

        let client = CovaAPIClient(transport: transport, credentials: session)
        let _: EmptyDTO = try await client.get("/api/probe")
        let probe = (await transport.recordedRequests()).first { $0.url.path == "/api/probe" }
        XCTAssertNil(probe?.bearerToken)
    }

    // MARK: - m-4：确定性认证失败 vs 传输类失败

    func testRefresh403ClearsCredentialsAndSignsOut() async throws {
        let transport = makeAuthTransport { request in
            switch request.url.path {
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let oldValue = try await session.accessToken()
        let old = try XCTUnwrap(oldValue)
        let boundSnapshot = await snapshot(stack: stack, token: old)

        do {
            _ = try await session.refreshAccessToken(for: boundSnapshot)
            XCTFail("403 应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .httpStatus(code: 403, apiCode: nil))
        }
        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(owner)
        XCTAssertNil(pointer)
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: loginUser, kind: .accessToken)))
    }

    func testRefreshTransportFailureKeepsSessionAndCredentials() async throws {
        let transport = makeAuthTransport { request in
            switch request.url.path {
            case CovaAuthSession.refreshPath: throw URLError(.timedOut)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let oldValue = try await session.accessToken()
        let old = try XCTUnwrap(oldValue)
        let boundSnapshot = await snapshot(stack: stack, token: old)

        do {
            _ = try await session.refreshAccessToken(for: boundSnapshot)
            XCTFail("超时应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .timeout)
        }
        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        XCTAssertTrue(state.isAuthenticated, "传输类失败不得登出")
        XCTAssertEqual(owner, loginUser)
        XCTAssertEqual(pointer, loginUser)
        let retained = try await session.accessToken()
        XCTAssertEqual(retained?.rawValue, "ACCESS_TOKEN_PLACEHOLDER", "凭证必须保留")
    }
}
