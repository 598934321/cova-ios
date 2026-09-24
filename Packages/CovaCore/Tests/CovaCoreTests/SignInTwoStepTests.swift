@testable import CovaCore
import Foundation
import XCTest

/// 登录**两步流**的新增行为面（`POST /api/auth/login` 建凭证 → `GET /api/auth/me` 取身份）。
///
/// 对照在产的 web 客户端：`LoginForm` 登录成功后不使用登录响应的 `user`，而是立刻走 `/me`
/// —— `covaId / phone / isArtist / isPartner` 与 `entitlements` 只在 `/me` 上给。
/// 因此身份以 `/me` 为准；`/me` 失败或两步身份不一致都判「登录没完成」，凭证收回。
///
/// 与 `AuthSessionTests`（登录/刷新/登出的既有面）分开，是因为这三条各钉死一步的一个失败模式，
/// 每条都必须在对应生产分支被删掉时变红。
final class SignInTwoStepTests: XCTestCase {
    // MARK: - 1. 身份只来自 `/me`

    /// 真实 `/login` 的 `user` 只有 `{id, email, name, role}`（NEEDS-1）。
    /// 若 `signIn` 把 `/login` 的 user 当身份，「刚登录的那一次会话」就一直缺身份，
    /// 直到冷启动走 `/me` 恢复才补齐 —— 两处口径不一致。
    /// 这里刻意让两步回**不同形状**的 user，使「身份取自哪一步」可判定。
    func testSignInTakesIdentityFromMeNotFromLoginResponse() async throws {
        let account = TestAccount.a
        let loginBody = Data(
            #"{"user":{"id":"user-0001","email":"tester@example.invalid","name":"测试用户","role":"user"},"token":"ACCESS_TOKEN_PLACEHOLDER","refreshToken":"REFRESH_TOKEN_PLACEHOLDER","expiresIn":7200}"#.utf8
        )
        let meBody = Data(
            #"{"user":{"id":"user-0001","covaId":"COVA-0001","email":"tester@example.invalid","phone":"+8613900000000","name":"测试用户","role":"user","isArtist":true,"isPartner":true},"entitlements":{"plan":"creator","subscriptionId":null,"activeUntil":null,"creditsBalance":880,"monthlyCredits":500,"canDownload":true,"canUseCovaAI":true,"canRequestProjects":true}}"#.utf8
        )
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return HTTPResponse(statusCode: 200, body: loginBody)
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 200, body: meBody)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)

        let user = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        let loginUserDto = try JSONDecoder().decode(CovaLoginResponseDto.self, from: loginBody).user
        let meUser = try JSONDecoder().decode(CovaMeResponse.self, from: meBody).user
        // 前置：两步响应本身不同 —— 否则本测试无法区分身份来自哪一步（防「永真断言」）。
        XCTAssertNil(loginUserDto.covaId)
        XCTAssertFalse(loginUserDto.isArtist)
        XCTAssertFalse(loginUserDto.isPartner)
        XCTAssertEqual(meUser.covaId, "COVA-0001")
        XCTAssertTrue(meUser.isArtist)

        XCTAssertEqual(user, meUser, "signIn 必须返回 `/me` 的权威身份")
        XCTAssertNotEqual(user, loginUserDto, "身份不得取自 `/login` 响应")
        XCTAssertEqual(user.id, "user-0001")
        XCTAssertEqual(user.covaId, "COVA-0001")
        XCTAssertEqual(user.phone, "+8613900000000")
        XCTAssertTrue(user.isArtist)
        XCTAssertTrue(user.isPartner)

        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUser), "状态里的 user 也必须是 `/me` 的那一份")

        // 两步各恰一次（不得靠重试蒙过去），且 `/me` 用刚建立的凭证。
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(meCount, 1, "登录后必须且只一次 GET /api/auth/me")
        let meRequests = (await transport.recordedRequests()).filter { $0.url.path == CovaAuthSession.mePath }
        XCTAssertEqual(meRequests.first?.method, .get)
        XCTAssertEqual(meRequests.first?.bearerToken, account.accessToken, "`/me` 必须用刚建立的凭证")
    }

    // MARK: - 2. `/me` 失败要把登录整个收回

    /// `/me` 失败 = 登录**没有完成**：留着凭证就得到「状态说已登录、身份与权益却一无所知」的半态。
    /// 所以第一步写入的凭证与本地归属必须一并收回，错误原样抛给调用方。
    func testSignInRollsBackCompletelyWhenMeRequestFails() async throws {
        let account = TestAccount.a
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return account.loginResponse
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)

        do {
            _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
            XCTFail("`/me` 失败时登录必须抛出")
        } catch {
            XCTAssertEqual(error as? CovaAPIError, .unauthorized(apiCode: nil), "`/me` 的错误须原样抛出")
        }

        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        let access = try stack.secureStore.secret(for: account.item(.accessToken))
        let refresh = try stack.secureStore.secret(for: account.item(.refreshToken))
        XCTAssertEqual(state, .signedOut, "不得留下「状态说已登录、身份一无所知」的半态")
        XCTAssertNil(access, "第一步写入的 access token 必须收回")
        XCTAssertNil(refresh, "第一步写入的 refresh token 必须收回")
        XCTAssertNil(pointer, "owner 指针必须收回")
        XCTAssertNil(owner, "lifecycle 归属必须收回")
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(meCount, 1, "`/me` 失败不得被重试掩盖")
    }

    // MARK: - 3. 两步身份不一致 fail-closed

    /// 两步回来的不是同一个人 → 不猜谁是对的：`/me` 覆盖会把会话记到错误的人身上
    /// （权益、缓存归属、播放上报的 owner 全跟着错），退回 `/login` 又回到「缺身份」的老问题。
    func testSignInFailsClosedWhenMeIdentityDiffersFromLogin() async throws {
        let account = TestAccount.a
        let mismatchedMeBody = Data(
            #"{"user":{"id":"user-8888","covaId":"COVA-8888","email":"other@example.invalid","phone":null,"name":"另一个人","role":"user","isArtist":false,"isPartner":false},"entitlements":{"plan":"free","subscriptionId":null,"activeUntil":null,"creditsBalance":0,"monthlyCredits":0,"canDownload":false,"canUseCovaAI":false,"canRequestProjects":false}}"#.utf8
        )
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return account.loginResponse
            case CovaAuthSession.mePath: return HTTPResponse(statusCode: 200, body: mismatchedMeBody)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)

        do {
            _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
            XCTFail("两步身份不一致时登录必须失败")
        } catch let error as CovaAPIError {
            // 匹配关联值而非「抛了个错」：错误必须指明是两步身份不一致。
            guard case .decoding(let field) = error else {
                XCTFail("应为 .decoding(field:)，实得 \(error)")
                return
            }
            // 字面量而非生产常量：键名本身也是被钉死的契约面。
            XCTAssertEqual(field, "auth-me-user-id")
        }

        let state = await session.currentState()
        let owner = await stack.lifecycle.currentOwner()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        let access = try stack.secureStore.secret(for: account.item(.accessToken))
        let refresh = try stack.secureStore.secret(for: account.item(.refreshToken))
        XCTAssertEqual(state, .signedOut, "身份不一致不得留下任何一方的会话")
        XCTAssertNil(access, "凭证必须收回")
        XCTAssertNil(refresh, "凭证必须收回")
        XCTAssertNil(pointer, "owner 指针必须收回")
        XCTAssertNil(owner, "lifecycle 归属必须收回")
        let stranger = PrincipalID(rawValue: "user-8888")
        XCTAssertNil(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: stranger, kind: .accessToken)),
            "不得把会话记到 `/me` 返回的另一个人身上"
        )
        let meCount = await transport.requestCount(path: CovaAuthSession.mePath)
        XCTAssertEqual(meCount, 1)
    }
}
