@testable import CovaCore
import Foundation
import XCTest

/// 登录**提交临界区**与**凭证落盘次序**（第 15 轮 R15-1 / R15-4 / R15-5）。
///
/// 与 `SignInTwoStepTests` 分开：那一份钉的是「两步都要走、身份只取自 `/me`」，
/// 本份钉的是「**什么时候允许把 `state` 写成已登录**」—— 登录是在途操作，
/// 期间用户的显式动作与另一个账号的登录都可能改变会话，此时无脑提交就是把真实结果推翻。
///
/// 全部零网络：注入 `FakeHTTPTransport` + 内存凭证存储；探针都是确定性的
/// （用 `setBeforeSessionActivation` 把 `signIn` 卡在最后一道 await 之后；
/// 用假传输层的 `/login` 把它卡在**换号之前**），不靠时序运气。
final class SignInCommitDisciplineTests: XCTestCase {

    // MARK: - R15-1 探针 P1：显式登出不得被在途登录推翻

    /// 用户在这次登录的 `/me` 回来之后、写状态之前点了「登出」。
    /// 不复核就提交 ⇒ 状态复活成 `authenticated`、凭证留在库里，而那次登出因为此刻内存里没有
    /// principal，既没发 `/api/auth/logout` 也没做生命周期清理 —— 两边都以为自己没登录成功过。
    func testExplicitSignOutInsideTheCommitWindowIsNotOverturned() async throws {
        let stack = makeTestStack()
        let transport = makeAuthTransport()
        let session = makeAuthSession(transport: transport, stack: stack)

        await session.setBeforeSessionActivation { [session] in
            try? await session.signOut()
        }

        do {
            _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
            XCTFail("已被显式登出取代的登录必须失败")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .sessionChanged, "被取代的登录要报「会话已变」，不是假装登录成功")
        }

        let state = await session.currentState()
        XCTAssertEqual(state, .signedOut, "在途登录不得把用户刚做的显式登出推翻成已登录")
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.accessToken)),
            "本次登录写的 access 必须定点收回"
        )
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.refreshToken)),
            "本次登录写的 refresh 必须定点收回"
        )
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner(), "owner 指针不得留下指向本次登录的值")
        // 三条归属面必须**一致地**不指向甲：状态 / 持久化 owner 指针 / lifecycle 的 activeOwner。
        // 甲在绑定那一步已经把 lifecycle 指到自己身上，而显式登出当时取不到 principal ⇒ 没人清它。
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertNil(lifecycleOwner, "lifecycle 归属仍指着本次登录 ⇒ 三个归属面分家（R15-1 的同一形状）")
        // 登出本身拿不到 principal（内存里还没登录上）⇒ 那次 `/api/auth/logout` 只能由回滚补发：
        // 本地删 token ≠ 服务端会话结束，不补发就是留了一条「客户端以为作废、实际仍可用」的凭证。
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(logoutCount, 1, "定点回滚要 best-effort 通知服务端作废刚建立的那条会话")
    }

    // MARK: - R15-1 探针 P2：并发登录两个账号，只允许一个提交

    /// 甲停在提交临界区里、乙在同一个临界区内完整跑完并提交 ⇒ 甲必须**放弃**，
    /// 而且**只能**收回自己的东西。
    ///
    /// 这条同时钉死两种错法：
    /// · 不复核就提交 ⇒ 状态写甲、owner 指针是乙（此后每个请求都不带 Authorization）；
    /// · 复核不过就走「完整失效」（`invalidateSession`）⇒ 把乙的会话连带抹掉。
    /// ⇒ 只有「定点回滚自己」这一种实现能同时满足下面的全部断言。
    ///
    /// 探针形态刻意用**钩子内重入**而不是"park 住等测试放行"：被测实现一旦没走到那道复核，
    /// park 型探针会挂死成"永远跑不完"而不是"红"—— 红必须能被门禁看见。
    func testConcurrentLoginsCommitExactlyOneAccountAndKeepTheWinner() async throws {
        let stack = makeTestStack()
        let transport = makeAuthTransport(script: AuthFlowScript(accounts: [.a, .b]))
        let session = makeAuthSession(transport: transport, stack: stack)
        let winnerBox = UserResultBox()

        await session.setBeforeSessionActivation { [session, winnerBox] in
            guard await winnerBox.claimWindow() else { return }  // 只有甲那一次进入会带动乙
            do {
                let user = try await session.signIn(
                    email: "b@example.invalid", password: SecretString("placeholder")
                )
                await winnerBox.saveWinner(user)
            } catch {
                await winnerBox.saveFailure(String(describing: error))
            }
        }

        do {
            _ = try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
            XCTFail("被后来者取代的登录必须失败")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .sessionChanged)
        }

        let meUser = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.b.meBody).user
        let detail = await winnerBox.describeFailure() ?? "钩子根本没被调用（复核未落地）"
        guard let winnerUser = await winnerBox.saved() else {
            XCTFail("乙这次登录应当成功，实得：\(detail)")
            return
        }
        XCTAssertEqual(winnerUser, meUser)

        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUser), "状态必须停在**先提交的那个**（乙），不能被甲盖写")
        XCTAssertEqual(
            try stack.activeOwnerStore.loadActiveOwner(), TestAccount.b.principal,
            "owner 指针必须与状态同一个人"
        )
        XCTAssertNotNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.accessToken)),
            "失败的一方不得顺手清掉赢家的凭证（那正是 `invalidateSession` 的错法）"
        )
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.accessToken)),
            "甲的凭证不得留下（本例里乙的换号清理已经抹掉一份，这条只作完备性）"
        )
        // 症状本身：状态与凭证必须能一起给请求供出 Authorization。
        let snapshot = try await session.currentSession()
        XCTAssertEqual(snapshot?.principal, TestAccount.b.principal, "并发登录后不得出现「状态说已登录、凭证却一无所知」")
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        XCTAssertEqual(loginCount, 2, "两次登录各发一次 `/login`（探针不得靠重放凑数）")
    }

    // MARK: - R16-2 探针 P3：赢家**先**提交 ⇒ 输家的破坏性换号必须整体跳过

    /// 现场：甲停在 `/login` 的在途网络窗口里，乙在这期间完整跑完**并提交**；甲随后才醒来去做换号。
    ///
    /// 与 P2 的差别只有顺序：P2 里甲的换号排在乙开始之前，所以它只能证明"状态不被盖写"，
    /// 证明不了"输家不去动别人的账户状态"。而换号（`switchAccount(from: 乙, to: 甲)`）的清理
    /// 删的是 `previous` 的凭证 —— 排在乙提交之后就是在删**乙**的东西，甲自己在后面才被提交闸拦下：
    /// 拦下的是甲，毁掉的却是乙。终态三处齐红（第 16 轮实测）：状态 `authenticated(乙)` 但
    /// `accessToken()` 是 nil、owner 指针 nil、lifecycle 归属 nil ⇒ 此后每个请求都不带
    /// Authorization，且只能等冷启动自愈。
    ///
    /// 探针形态：把"卡住"放进假传输层的 `/login`，并在同一次调用里把乙跑到完成再返回甲的响应。
    /// 刻意不用"park 住等测试放行"——实现一旦没走到复核就是挂死而不是红（见文件头）。
    func testLoserSkipsTheDestructiveRebindWhenAnotherAccountAlreadyCommitted() async throws {
        let stack = makeTestStack()
        let script = AuthFlowScript(accounts: [.a, .b])
        let box = InFlightLoginBox()
        let transport = FakeHTTPTransport { [script, box] request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                let response = script.nextLoginResponse()  // 第 1 次是甲，第 2 次是乙
                // 只有甲那一次 `/login` 带动乙；乙自己那次拿到 nil，不再重入。
                if let session = await box.claimWinnerRun() {
                    do {
                        let user = try await session.signIn(
                            email: "b@example.invalid", password: SecretString("placeholder")
                        )
                        await box.saveWinner(user)
                    } catch {
                        await box.saveFailure(String(describing: error))
                    }
                }
                return response
            case CovaAuthSession.mePath:
                return script.meResponse(for: request)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = makeAuthSession(transport: transport, stack: stack)
        await box.install(session)

        do {
            _ = try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
            XCTFail("已被乙的提交取代的登录必须失败")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .sessionChanged, "输家要报「会话已变」，不能假装登录成功")
        }

        let meUser = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.b.meBody).user
        let detail = await box.describeFailure() ?? "甲根本没走到 `/login`（探针未成立）"
        guard let winnerUser = await box.saved() else {
            XCTFail("乙这次登录应当成功，实得：\(detail)")
            return
        }
        XCTAssertEqual(winnerUser, meUser)

        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUser), "状态必须停在**先提交的那个**（乙）")
        // 症状本身：赢家的会话必须仍能供出 Authorization。
        let winnerToken = try await session.accessToken()
        XCTAssertEqual(
            winnerToken?.rawValue, TestAccount.b.accessToken,
            "输家的换号不得抹掉赢家的 access —— 状态说已登录、凭证却一无所知就是「每个请求都不带 Authorization」"
        )
        let snapshot = try await session.currentSession()
        XCTAssertEqual(snapshot?.principal, TestAccount.b.principal, "凭证与状态必须是同一个人")
        XCTAssertEqual(snapshot?.accessToken.rawValue, TestAccount.b.accessToken)
        XCTAssertNotNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.refreshToken)),
            "单次旋转的 refresh 同样不能被输家抹掉（抹掉后乙一过期就再也刷不动）"
        )
        // 三个归属面都必须仍然指向乙：输家既不该盖指针，也不该碰 lifecycle。
        XCTAssertEqual(
            try stack.activeOwnerStore.loadActiveOwner(), TestAccount.b.principal,
            "owner 指针被输家清成 nil ⇒ 冷启动会以为没人登录"
        )
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(lifecycleOwner, TestAccount.b.principal, "输家根本不该为另一个 owner 调用 lifecycle")
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.accessToken)),
            "甲的凭证不得留下（复核成立时它压根没被写过）"
        )
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        XCTAssertEqual(loginCount, 2, "两次登录各发一次 `/login`（探针不得靠重放凑数）")
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(
            logoutCount, 1,
            "甲要作废**自己**这次 `/login` 在服务端建立的会话族（本地没落凭证也得撤），且只撤一次"
        )
    }

    // MARK: - R16-2 的副作用边界：同账号重新登录不得被换号前的复核误判

    /// 当前 owner 就是甲时，甲再点一次登录：换号分支本来就不触发（`previous == principal`），
    /// 换号前的复核也不能把它判废 —— 否则"换号前先看 epoch"就成了把正常重登也一起拦掉的新 bug。
    func testReSignInForTheCurrentOwnerStillCommits() async throws {
        let stack = makeTestStack()
        let transport = makeAuthTransport()
        let session = makeAuthSession(transport: transport, stack: stack)
        let account = TestAccount.a
        let meUser = try JSONDecoder().decode(CovaMeResponse.self, from: account.meBody).user

        _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))

        let user = try await session.signIn(
            email: "tester@example.invalid", password: SecretString("placeholder")
        )
        XCTAssertEqual(user, meUser, "同账号重登是合法的成功路径，不得被判「会话已变」")
        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUser))
        let currentToken = try await session.accessToken()
        XCTAssertEqual(
            currentToken?.rawValue, account.accessToken,
            "重登后自己的凭证必须可读"
        )
        XCTAssertEqual(try stack.activeOwnerStore.loadActiveOwner(), account.principal)
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(lifecycleOwner, account.principal)
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(logoutCount, 0, "成功路径不得发出任何登出（包括换号前复核的那条作废分支）")
    }

    // MARK: - 提交判据的取舍：generation 不得当判据（反向用例）

    /// 临界区里推进了 **generation 而没推进 epoch** —— 这正是"迟到的冷启动恢复"的现场
    /// （`restoreSession` 提交前会 `beginSession`，但它不算用户动作，故不推进 epoch）。
    ///
    /// 这条是**反向**断言：登录必须照样提交。它钉的是判据取舍，不是"再补一道闸"——
    /// 把 generation 并进来，一次被动恢复就能把用户主动点的这次登录判废（错的方向正好相反）。
    func testGenerationAdvanceWithoutEpochStillCommitsTheExplicitLogin() async throws {
        let stack = makeTestStack()
        let transport = makeAuthTransport()
        let session = makeAuthSession(transport: transport, stack: stack)
        let account = TestAccount.a

        await session.setBeforeSessionActivation { [stack] in
            await stack.lifecycle.beginSession(owner: TestAccount.b.principal)
        }

        let user = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        let meUser = try JSONDecoder().decode(CovaMeResponse.self, from: account.meBody).user
        XCTAssertEqual(user, meUser)
        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUser), "epoch 未动 ⇒ 这次显式登录是终态，不得被 generation 判废")
        XCTAssertNotNil(try stack.secureStore.secret(for: account.item(.accessToken)))
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(logoutCount, 0, "提交成功的路径不得顺手发出登出请求")
    }

    // MARK: - R15-4：回滚的清理失败必须冒到调用方，不被 `try?` 吞掉

    /// `/me` 失败 ⇒ 登录收回；但 Keychain 删除本身也失败时，用户看到的必须是「清理没做完」，
    /// 而不是一个看起来很正常的「密码错了」—— 库里那条 refresh token 还是活的。
    func testRollbackCleanupFailureIsReportedInsteadOfTheLoginError() async throws {
        let secureStore = RemovalFailingSecureStore()
        let stackOwnerStore = InMemoryOwnerStore()
        let lifecycle = SessionLifecycle(
            secureStore: secureStore, ownerStore: stackOwnerStore, cleaners: []
        )
        let activeOwnerStore = InMemoryActiveOwnerStore()
        // `/me` 一被调用就让删除开始失败：随后 `signIn` 的收回正好踩上它。
        let meFailing = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return TestAccount.a.loginResponse
            case CovaAuthSession.mePath:
                secureStore.setFailingRemovals(true)
                return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = CovaAuthSession(
            transport: meFailing,
            secureStore: secureStore,
            lifecycle: lifecycle,
            activeOwnerStore: activeOwnerStore
        )

        do {
            _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
            XCTFail("`/me` 失败时登录必须抛出")
            return
        } catch let failure as SessionCleanupFailure {
            XCTAssertEqual(
                failure.failedComponents, [.credentials],
                "凭证没删掉这件事必须自己冒出来，不能躲在 `.unauthorized` 后面"
            )
        } catch let error {
            XCTFail("应为 `SessionCleanupFailure`，实得 \(error)")
            return
        }
        // 抛清理失败**不阻断**状态迁移（否则会出现「清理报错但用户实际已登录」的反向半态）。
        let state = await session.currentState()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try activeOwnerStore.loadActiveOwner(), "owner 指针那条清理成功了，只有凭证分量失败")
    }

    // MARK: - R15-5：旋转凭证的落盘次序（先 refresh 后 access）

    /// 两步登录建立凭证时的写序。refresh 是单次消费的：半态只能落在**可恢复**的那一侧。
    func testSignInPersistsRefreshTokenBeforeAccessToken() async throws {
        let secureStore = WriteOrderRecordingSecureStore()
        let lifecycle = SessionLifecycle(
            secureStore: secureStore, ownerStore: InMemoryOwnerStore(), cleaners: []
        )
        let session = CovaAuthSession(
            transport: makeAuthTransport(),
            secureStore: secureStore,
            lifecycle: lifecycle,
            activeOwnerStore: InMemoryActiveOwnerStore()
        )

        _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        XCTAssertEqual(
            secureStore.writtenKinds(), [.refreshToken, .accessToken],
            "先 refresh 后 access：反过来写半态会留下「新 access + 已被服务端消费的旧 refresh」⇒ 永久刷不动"
        )
    }

    /// 刷新拿到新的一对之后同样按这个次序落盘。
    func testRefreshPersistsRefreshTokenBeforeAccessToken() async throws {
        let secureStore = WriteOrderRecordingSecureStore()
        let lifecycle = SessionLifecycle(
            secureStore: secureStore, ownerStore: InMemoryOwnerStore(), cleaners: []
        )
        let refreshBody = Data(
            #"{"token":"ROTATED_ACCESS","refreshToken":"ROTATED_REFRESH","expiresIn":7200}"#.utf8
        )
        let transport = FakeHTTPTransport { request in
            switch request.url.path {
            case CovaAuthSession.loginPath: return TestAccount.a.loginResponse
            case CovaAuthSession.mePath: return TestAccount.a.meResponse
            case CovaAuthSession.refreshPath: return HTTPResponse(statusCode: 200, body: refreshBody)
            default: return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = CovaAuthSession(
            transport: transport,
            secureStore: secureStore,
            lifecycle: lifecycle,
            activeOwnerStore: InMemoryActiveOwnerStore()
        )
        _ = try await session.signIn(email: "tester@example.invalid", password: SecretString("placeholder"))
        guard let snapshot = try await session.currentSession() else {
            XCTFail("登录后必须能取到会话快照")
            return
        }
        secureStore.resetWrittenKinds()

        _ = try await session.refreshAccessToken(for: snapshot)
        XCTAssertEqual(
            secureStore.writtenKinds(), [.refreshToken, .accessToken],
            "刷新路径与登录路径必须是同一个写序 —— 它消费的正是那条单次 refresh"
        )
    }
}

// MARK: - 本文件专用夹具（刻意 private：不与其他测试文件的同名助手互相覆盖）

/// 甲停在 `/login` 里时的记账：把状态机自身交给假传输层，让它在那一次调用里驱动乙登录。
///
/// 存 `CovaAuthSession`（actor 引用，天然 Sendable）而不是 `any Error`：actor 的存储属性
/// 要满足 Sendable，错误只能存成描述文本。
private actor InFlightLoginBox {
    private var session: CovaAuthSession?
    private var claimed = false
    private var winner: AuthUser?
    private var failure: String?

    func install(_ session: CovaAuthSession) { self.session = session }

    /// 第一次调用返回状态机（甲那次 `/login` 带动乙），之后一律 `nil`（乙自己那次不再重入）。
    func claimWinnerRun() -> CovaAuthSession? {
        if claimed { return nil }
        claimed = true
        return session
    }

    func saveWinner(_ user: AuthUser) { winner = user }
    func saveFailure(_ description: String) { failure = description }
    func saved() -> AuthUser? { winner }
    func describeFailure() -> String? { failure }
}

/// 提交临界区里"谁赢了"的记账，兼当**只触发一次**的闸门（`claimWindow`）。
///
/// 只存 `AuthUser` 与错误描述文本：actor 的存储属性要 Sendable，`any Error` 不能直接存。
private actor UserResultBox {
    private var claimed = false
    private var winner: AuthUser?
    private var failure: String?

    /// 第一次调用返回 true（甲的那次进入），之后一律 false（乙自己的进入不再触发重入登录）。
    func claimWindow() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }

    func saveWinner(_ user: AuthUser) { winner = user }
    func saveFailure(_ description: String) { failure = description }
    func saved() -> AuthUser? { winner }
    func describeFailure() -> String? { failure }
}

/// 删除分量可翻转失败的凭证存储（其余分量委托内存实现）。
private final class RemovalFailingSecureStore: SecureStore, @unchecked Sendable {
    private let inner = InMemorySecureStore()
    private let lock = NSLock()
    private var failing = false

    func setFailingRemovals(_ value: Bool) {
        lock.lock()
        failing = value
        lock.unlock()
    }

    func set(_ secret: SecretString, for item: SecureStoreItem) throws {
        try inner.set(secret, for: item)
    }

    func secret(for item: SecureStoreItem) throws -> SecretString? {
        try inner.secret(for: item)
    }

    func removeSecret(for item: SecureStoreItem) throws {
        try Self.check(failing: failing)
        try inner.removeSecret(for: item)
    }

    func removeAllSecrets(for principalId: PrincipalID) throws {
        try Self.check(failing: failing)
        try inner.removeAllSecrets(for: principalId)
    }

    private static func check(failing: Bool) throws {
        if failing { throw SecureStoreError.status(-25300) }
    }
}

/// 记录 `set` 调用次序的凭证存储（R15-5 的观测面）。
private final class WriteOrderRecordingSecureStore: SecureStore, @unchecked Sendable {
    private let inner = InMemorySecureStore()
    private let lock = NSLock()
    private var kinds: [CredentialKind] = []

    func writtenKinds() -> [CredentialKind] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }

    func resetWrittenKinds() {
        lock.lock()
        kinds = []
        lock.unlock()
    }

    func set(_ secret: SecretString, for item: SecureStoreItem) throws {
        lock.lock()
        kinds.append(item.kind)
        lock.unlock()
        try inner.set(secret, for: item)
    }

    func secret(for item: SecureStoreItem) throws -> SecretString? {
        try inner.secret(for: item)
    }

    func removeSecret(for item: SecureStoreItem) throws {
        try inner.removeSecret(for: item)
    }

    func removeAllSecrets(for principalId: PrincipalID) throws {
        try inner.removeAllSecrets(for: principalId)
    }
}
