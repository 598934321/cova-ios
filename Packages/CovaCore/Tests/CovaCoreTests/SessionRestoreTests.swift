@testable import CovaCore
import Foundation
import XCTest

/// M-2：冷启动恢复（`restoreSession()`）。
///
/// 契约目标形态：`GET /api/auth/me` → `{user, entitlements}`。真实字段不全由 NEEDS-3 跟踪，
/// 测试使用仓库内脱敏 fixture（`auth-me.json`），不连线上、不伪造线上行为。
final class SessionRestoreTests: XCTestCase {
    private let ownerA = PrincipalID(rawValue: "user-0001")
    private var accessItem: SecureStoreItem {
        SecureStoreItem(principalId: ownerA, kind: .accessToken)
    }

    private var expectedUser: AuthUser {
        get throws { try Fixture.decode(CovaMeResponse.self, "auth-me").user }
    }

    /// 先建立一次真实登录（写入 Keychain 凭证 + owner 指针），模拟「上次会话已持久化」。
    private func seedSignedInSession(transport: FakeHTTPTransport, stack: TestStack) async throws {
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
    }

    private func loginAndMeTransport(
        me: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) -> FakeHTTPTransport {
        FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: return me(request)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
    }

    func testRestoreWithoutCredentialsEntersGuest() async throws {
        let stack = makeTestStack()
        let session = makeAuthSession(transport: loginAndMeTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.me) }, stack: stack)

        let state = try await session.restoreSession()

        XCTAssertEqual(state, .guest)
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
    }

    func testRestoreWithPointerButNoCredentialsClearsPointerAndEntersGuest() async throws {
        let stack = makeTestStack()
        try stack.activeOwnerStore.saveActiveOwner(ownerA)
        let session = makeAuthSession(transport: loginAndMeTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.me) }, stack: stack)

        let state = try await session.restoreSession()

        XCTAssertEqual(state, .guest)
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
    }

    func testRestoreWithValidCredentialsEntersAuthenticated() async throws {
        let transport = loginAndMeTransport { _ in HTTPResponse(statusCode: 200, body: TestTransportData.me) }
        let stack = makeTestStack()
        try await seedSignedInSession(transport: transport, stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        let user = try expectedUser
        XCTAssertEqual(state, .authenticated(user))
        let principal = await cold.currentPrincipal()
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(principal, ownerA)
        XCTAssertEqual(lifecycleOwner, ownerA)
        let token = try await cold.accessToken()
        XCTAssertEqual(token?.rawValue, "ACCESS_TOKEN_PLACEHOLDER")
    }

    func testRestoreRefreshesExpiredTokenThenSucceeds() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath:
                if request.bearerToken == "ACCESS_TOKEN_PLACEHOLDER" {
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
                return HTTPResponse(statusCode: 200, body: TestTransportData.me)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(transport: transport, stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        let user = try expectedUser
        XCTAssertEqual(state, .authenticated(user))
        let token = try await cold.accessToken()
        XCTAssertEqual(token?.rawValue, "ACCESS_TOKEN_PLACEHOLDER_2", "过期 token 应经单飞刷新后重放 me")
        let refreshCount = await transport.requestCount(path: CovaAuthSession.refreshPath)
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(meCount, 2, "me 原始 + 重放各一次")
    }

    func testRestoreWithRevokedCredentialsSignsOutAndCleansUp() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(transport: transport, stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertNil(lifecycleOwner)
    }

    func testRestoreWithTransportFailureKeepsCredentialsAndThrows() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: throw URLError(.timedOut)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(transport: transport, stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        do {
            _ = try await cold.restoreSession()
            XCTFail("传输失败应抛出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .timeout)
        }
        XCTAssertNotNil(try stack.secureStore.secret(for: accessItem), "传输失败不得清凭证")
        XCTAssertEqual(try stack.activeOwnerStore.loadActiveOwner(), ownerA)
        let state = await cold.currentState()
        XCTAssertEqual(state, .signedOut)
    }

    func testRestoreWithMismatchedUserInvalidatesSession() async throws {
        let mismatch = Data(
            #"{"user":{"id":"user-9999","name":"陌生","role":"user","email":null,"covaId":null,"phone":null,"isArtist":false,"isPartner":false},"entitlements":{"plan":"free","creditsBalance":0,"monthlyCredits":0,"canDownload":false,"canUseCovaAI":false,"canRequestProjects":false}}"#.utf8
        )
        let transport = loginAndMeTransport { _ in HTTPResponse(statusCode: 200, body: mismatch) }
        let stack = makeTestStack()
        try await seedSignedInSession(transport: transport, stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
    }
}
