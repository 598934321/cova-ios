@testable import CovaCore
import Foundation
import XCTest

final class AuthSessionTests: XCTestCase {
    private let loginUser = PrincipalID(rawValue: "user-0001")

    private func makeSession(
        transport: any HTTPTransport,
        stack: TestStack
    ) -> CovaAuthSession {
        CovaAuthSession(transport: transport, secureStore: stack.secureStore, lifecycle: stack.lifecycle)
    }

    private func loginTransport() -> FakeHTTPTransport {
        FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            if request.url.path == CovaAuthSession.refreshPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            }
            if request.url.path == CovaAuthSession.logoutPath {
                return HTTPResponse(statusCode: 200, body: Data(#"{"message":"ok"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
    }

    func testInitialStateIsSignedOut() async {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        let state = await session.currentState()
        let user = await session.currentUser()
        let principal = await session.currentPrincipal()
        let token = await session.accessToken()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(user)
        XCTAssertNil(principal)
        XCTAssertNil(token)
    }

    func testContinueAsGuestOnlyFromSignedOut() async {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        await session.continueAsGuest()
        let guestState = await session.currentState()
        XCTAssertEqual(guestState, .guest)
        await session.continueAsGuest()
        let againState = await session.currentState()
        let token = await session.accessToken()
        XCTAssertEqual(againState, .guest)
        XCTAssertNil(token)
    }

    func testSignInStoresTokensBindsOwnerAndAdvancesGeneration() async throws {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        let before = await stack.lifecycle.currentGeneration()

        let user = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        let state = await session.currentState()
        let principal = await session.currentPrincipal()
        let owner = await stack.lifecycle.currentOwner()
        let after = await stack.lifecycle.currentGeneration()
        let token = await session.accessToken()
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
        let secondLogin = Data(
            #"{"user":{"id":"user-0002","name":"乙","role":"user","email":"b@example.invalid","covaId":null,"phone":null,"isArtist":false,"isPartner":false},"token":"SECOND_ACCESS","refreshToken":"SECOND_REFRESH","expiresIn":7200}"#.utf8
        )
        final class Script: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let script = Script()
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                return HTTPResponse(statusCode: 200, body: script.next() == 1 ? TestTransportData.login : secondLogin)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
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
    }

    func testRefreshRotatesTokensAndIsSingleFlight() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func increment() { lock.lock(); calls += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let counter = Counter()
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.refreshPath {
                counter.increment()
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            }
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let staleValue = await session.accessToken()
        let stale = try XCTUnwrap(staleValue)

        let tokens = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<10 {
                group.addTask { try? await session.refreshAccessToken(replacing: stale).rawValue }
            }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(counter.value, 1, "并发刷新只允许一次网络调用")
        XCTAssertEqual(tokens.compactMap { $0 }.count, 10)
        XCTAssertTrue(tokens.allSatisfy { $0 == "ACCESS_TOKEN_PLACEHOLDER_2" })
        let access = await session.accessToken()
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
        let transport = FakeHTTPTransport { request in
            if request.url.path == CovaAuthSession.refreshPath {
                counter.increment()
                return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            }
            if request.url.path == CovaAuthSession.loginPath {
                return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            }
            return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let staleValue = await session.accessToken()
        let stale = try XCTUnwrap(staleValue)

        let first = try await session.refreshAccessToken(replacing: stale)
        let second = try await session.refreshAccessToken(replacing: stale)

        XCTAssertEqual(first, second)
        XCTAssertEqual(counter.value, 1, "陈旧 token 不得触发第二次刷新")
    }

    func testRefreshFailureSignsOutAndClearsCredentials() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        do {
            _ = try await session.refreshAccessToken(replacing: nil)
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
        try stack.secureStore.removeSecret(for: SecureStoreItem(principalId: loginUser, kind: .refreshToken))

        do {
            _ = try await session.refreshAccessToken(replacing: nil)
            XCTFail("缺 refresh token 应失败")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
        }
        let state = await session.currentState()
        let refreshRequests = (await transport.recordedRequests()).filter { $0.url.path == CovaAuthSession.refreshPath }
        XCTAssertEqual(state, .signedOut)
        XCTAssertTrue(refreshRequests.isEmpty)
    }

    func testRefreshWhenSignedOutThrowsUnauthorized() async {
        let stack = makeTestStack()
        let session = makeSession(transport: loginTransport(), stack: stack)
        do {
            _ = try await session.refreshAccessToken(replacing: nil)
            XCTFail("未登录不应可刷新")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil))
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
}
