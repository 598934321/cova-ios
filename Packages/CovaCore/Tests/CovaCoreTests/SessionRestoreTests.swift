@testable import CovaCore
import Foundation
import XCTest

private final class RestoreSessionRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CovaAuthSession?

    var session: CovaAuthSession? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

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

    /// 先建立一次真实登录（两步：`/login` 建凭证 + `/me` 取身份，都成功）写入凭证 + owner 指针，
    /// 模拟「上次会话已持久化」。
    ///
    /// 刻意用一个**独立的**登录传输层：登录后半程那次 `/me` 属于「上一次运行」的历史，
    /// 不该占用本测试为**恢复路径**脚本化的 `/me` 行为 —— 否则 401/超时/身份失配的脚本会在
    /// seed 阶段就把登录打断，`/me` 计数也会凭空多出一跳。
    private func seedSignedInSession(stack: TestStack) async throws {
        let session = makeAuthSession(transport: makeAuthTransport(), stack: stack)
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
        try await seedSignedInSession(stack: stack)

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
        try await seedSignedInSession(stack: stack)

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
        try await seedSignedInSession(stack: stack)

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
        try await seedSignedInSession(stack: stack)

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

    /// 额外：恢复在途时用户显式选择 guest，恢复结果必须被丢弃（不得覆盖用户选择）。
    func testRestoreDiscardedWhenUserExplicitlyChoosesGuest() async throws {
        let box = RestoreSessionRef()
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath:
                await box.session?.continueAsGuest()
                return HTTPResponse(statusCode: 200, body: TestTransportData.me)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        box.session = cold
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .guest, "用户显式选择 guest 后不得被恢复为 authenticated")
        let finalState = await cold.currentState()
        XCTAssertEqual(finalState, .guest)
        XCTAssertFalse(state.isAuthenticated)
    }

    /// F2：refresh 2xx 但二次 `me` 仍确定性 401 —— 必须清理凭证 + 指针 + lifecycle。
    func testRestoreRefreshSucceedsButMeStillRevokedCleansUp() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem), "access token 必须被清理")
        XCTAssertNil(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: ownerA, kind: .refreshToken)),
            "refresh token 必须被清理"
        )
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner(), "owner 指针必须被清理")
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertNil(lifecycleOwner, "lifecycle 登出清理必须执行")
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(meCount, 2, "原始 me + 刷新后重放各一次")
    }

    /// F2 变体：二次 `me` 返回 403 同样必须清理。
    func testRestoreRefreshSucceedsButMeForbiddenCleansUp() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
    }

    /// F3：提交临界区（`beginSession` await 期间）用户显式改变会话 → 回滚，不写回 authenticated。
    func testRestoreRollsBackWhenSessionChangesDuringCommit() async throws {
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: TestTransportData.login)
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 200, body: TestTransportData.me)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        try await seedSignedInSession(stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        await cold.setBeforeSessionActivation { [cold] in
            await cold.continueAsGuest()
        }
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .guest, "提交临界区内的显式 guest 必须胜出")
        let finalState = await cold.currentState()
        XCTAssertEqual(finalState, .guest)
    }

    func testRestoreWithMismatchedUserInvalidatesSession() async throws {
        let mismatch = Data(
            #"{"user":{"id":"user-9999","name":"陌生","role":"user","email":null,"covaId":null,"phone":null,"isArtist":false,"isPartner":false},"entitlements":{"plan":"free","creditsBalance":0,"monthlyCredits":0,"canDownload":false,"canUseCovaAI":false,"canRequestProjects":false}}"#.utf8
        )
        let transport = loginAndMeTransport { _ in HTTPResponse(statusCode: 200, body: mismatch) }
        let stack = makeTestStack()
        try await seedSignedInSession(stack: stack)

        let cold = makeAuthSession(transport: transport, stack: stack)
        let state = try await cold.restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try stack.secureStore.secret(for: accessItem))
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner())
    }
}
