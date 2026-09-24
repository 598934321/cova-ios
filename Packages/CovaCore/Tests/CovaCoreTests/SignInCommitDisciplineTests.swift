@testable import CovaCore
import Foundation
import XCTest

/// 登录**提交临界区**与**凭证落盘次序**（第 15 轮 R15-1 / R15-4 / R15-5，第 16 轮 R16-2 / R16-3）。
///
/// 与 `SignInTwoStepTests` 分开：那一份钉的是「两步都要走、身份只取自 `/me`」，
/// 本份钉的是「**什么时候允许把 `state` 写成已登录**」—— 登录是在途操作，
/// 期间用户的显式动作与另一个账号的登录都可能改变会话，此时无脑提交就是把真实结果推翻。
///
/// 两层机制、两组用例，不要混成一组：
/// · **串行槽**（R16-3）：同一个实例上两次登录不得交错穿过「重绑 → 写凭证 → 提交」，
///   见 `testConcurrentLoginsForDifferentAccountsNeverShareTheRebindRegion`；
/// · **`sessionEpoch` 复核**（R15-1 / R16-2）：不取槽的显式登出 / 选游客落在同一个窗口里时，
///   输家必须**什么都不写**、只作废自己那条服务端会话，见 P1 与两条 P3。
///
/// 全部零网络：注入 `FakeHTTPTransport` + 内存凭证存储；探针都是确定性的
/// （用 `setBeforeSessionActivation` 把 `signIn` 卡在最后一道 await 之后；
/// 用假传输层的 `/login`、`/me` 与换号清理的闸门把它卡在**换号之前 / 之中**），
/// 不靠时序运气。所有闸门都有拉开的超时判定与"测试结束一律拉开"的兜底，
/// 所以探针只会**红**，不会挂死。
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

    // MARK: - R16-3 探针 P2：两次并发登录不得交错穿过「重绑 → 写凭证 → 提交」

    /// 现场（原 P2 的同一形状，改由两个并发 `Task` 驱动）：甲、乙两个账号同时点登录。
    ///
    /// 为什么不能再像原来那样"在钩子里重入另一次登录"：串行槽之后那正是**死锁**
    /// （外层持有槽并等内层，内层等外层释放），而内层永远等不到。交错必须由测试从外面驱动。
    ///
    /// 未修复前这条必然红，而且红在两个地方：① 乙确实挤进了甲的窗口（甲还停在 `/me` 里时
    /// `enteredAccountSwitch` 就被拉开）；② 按"先放行甲 → 等甲提交完 → 才放行乙"走完之后，
    /// 终态停在**状态 = 甲**、而甲的凭证已经被乙那步换号清理删掉 —— owner 指针与 lifecycle 归属
    /// 一起变 nil，`accessToken()` / `currentSession()` 一律 nil：UI 显示已登录、每个请求都不带
    /// Authorization。修复后：两次登录各自跑完，后一次以**正常的换号**接管（不是抢），
    /// 四个归属面必须一起指着最后完成的那次登录。
    func testConcurrentLoginsForDifferentAccountsNeverShareTheRebindRegion() async throws {
        let kit = ProbeKit()
        // 换号清理的观测点：乙一旦进入 `switchAccount`，这里就是"它进了甲还没出来的区域"。
        let stack = makeTestStack(cleaners: [GateCleaner(kit: kit)])
        let script = AuthFlowScript(accounts: [.a, .b])
        let transport = FakeHTTPTransport { [kit, script] request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                // 只有乙那一次被卡在 `/login` 里，直到甲已经**写完自己的凭证**停在 `/me`。
                // 修复后乙根本发不出这次请求（还在排队），闸门早已拉开 ⇒ 立即通过。
                if await kit.isLoginFor(request, emailPrefix: "b@") {
                    _ = await kit.wait(.parkedInsideMeHop)
                }
                return await kit.loginResponse(for: request)
            case CovaAuthSession.mePath:
                if request.bearerToken == TestAccount.a.accessToken {
                    // 甲已写完凭证与 owner 指针 —— 这正是"别人顺手抹掉它"的窗口。
                    await kit.raise(.parkedInsideMeHop)
                    _ = await kit.wait(.releaseParkedMeHop)
                }
                return script.meResponse(for: request)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = makeAuthSession(transport: transport, stack: stack)

        let first = UserResultBox()
        let second = UserResultBox()
        defer { Task { await kit.raiseAll() } }

        let firstTask = Task { () -> AuthUser? in
            await first.run {
                try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
            }
        }
        // 甲确实进到窗口里了，才让乙开始 —— 顺序确定，不靠调度运气。
        let firstInside = await kit.raisedWithin(.parkedInsideMeHop, seconds: 20)
        XCTAssertTrue(firstInside, "甲没进到 `/me` 窗口里 ⇒ 探针未成立")
        let secondTask = Task { () -> AuthUser? in
            await second.run {
                try await session.signIn(email: "b@example.invalid", password: SecretString("placeholder"))
            }
        }
        // 关键判定：甲还没走出临界区时，乙**不许**进入破坏性换号。2 秒不是竞态窗口，
        // 而是"这件事根本不该发生"的证据；两种实现下本用例的断言结论都是确定的。
        let interleaved = await kit.raisedWithin(.enteredAccountSwitch, seconds: 2)
        XCTAssertFalse(
            interleaved,
            "并发登录在甲的「写凭证 → 提交」窗口里进了换号 ⇒ 串行槽没生效（R16-3 的洞）"
        )
        // 刻意按"放行甲 → 等甲提交完 → 才放行乙的换号"的顺序走：这样两种实现下的终态都不靠调度运气。
        // 未修复的字节会停在甲**已经提交**、而它的凭证已经被乙那步换号清理删掉的现场 ——
        // 也就是"状态说已登录、每个请求却都不带 Authorization"那个症状本身。
        await kit.raise(.releaseParkedMeHop)
        let firstOutcome = await firstTask.value
        await kit.raise(.releaseAccountSwitch)
        let secondOutcome = await secondTask.value
        let firstFailure = await first.describeFailure() ?? "无"
        let secondFailure = await second.describeFailure() ?? "无"
        XCTAssertNotNil(firstOutcome, "甲这次登录应当成功（它先拿到槽），实得失败：\(firstFailure)")
        XCTAssertNotNil(secondOutcome, "乙排队之后应当**照常执行**（用户最后一次点击仍然落地）：\(secondFailure)")

        let meUserA = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.a.meBody).user
        let meUserB = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.b.meBody).user
        let state = await session.currentState()
        XCTAssertEqual(
            state, .authenticated(meUserB),
            "状态必须停在**最后完成**的那次登录（用户最后一次点击仍然落地）"
        )
        // 四个归属面必须一起指向同一个人；刻意不做 `XCTUnwrap`，让未修复的实现把**四个面**
        // 都红出来，而不是在第一处就中止。
        let statePrincipal = state.user.map { PrincipalID(rawValue: $0.id) }
        XCTAssertEqual(statePrincipal, TestAccount.b.principal, "归属面①：状态")
        XCTAssertEqual(
            try stack.activeOwnerStore.loadActiveOwner(), TestAccount.b.principal,
            "归属面②：owner 指针必须与状态同一个人"
        )
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(lifecycleOwner, TestAccount.b.principal, "归属面③：lifecycle 归属必须与状态同一个人")
        let token = try await session.accessToken()
        XCTAssertEqual(
            token?.rawValue, TestAccount.b.accessToken,
            "归属面④：状态说已登录，凭证就必须读得出来 —— 否则每个请求都不带 Authorization"
        )
        let snapshot = try await session.currentSession()
        XCTAssertEqual(snapshot?.principal, TestAccount.b.principal, "凭证与状态必须是同一个人")
        XCTAssertEqual(snapshot?.accessToken.rawValue, TestAccount.b.accessToken)
        XCTAssertNotNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.refreshToken)),
            "单次旋转的 refresh 也必须在"
        )
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.accessToken)),
            "被换号清理掉的甲不得留下凭证"
        )
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        XCTAssertEqual(loginCount, 2, "两次登录各发一次 `/login`（探针不得靠重放凑数）")
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(logoutCount, 0, "两条登录都成功 ⇒ 谁都不该作废会话")
        XCTAssertEqual(firstOutcome, meUserA)
        XCTAssertEqual(secondOutcome, meUserB, "两次登录各自返回自己的身份")
    }

    // MARK: - R16-2 探针 P3：换号**之前**就被接管 ⇒ 破坏性重绑整体跳过

    /// 原 P3 的形状（甲停在 `/login` 里、乙在这期间完整跑完并提交）在 R16-3 之后**构造不出来了**：
    /// 乙现在只能排在甲后面，进不到这个窗口里（`testConcurrentLoginsForDifferentAccountsNeverShareTheRebindRegion`
    /// 钉的就是这件事）。所以原 P3 的"两个登录互相抢"这一半被串行槽接管，剩下这一半照旧要有人钉：
    /// **换号前的复核确实会触发，而且触发时一个字节都不写别人的东西**。
    /// 触发者换成不取槽的那两条路径 —— 下面两条用例分别对应它们，原 P3 的断言面
    /// （凭证 / owner 指针 / lifecycle 归属 / 甲不留凭证 / 只作废自己那条服务端会话）全部保留。
    ///
    /// 现场：本地归属已经指着乙（凭证、owner 指针、lifecycle 三处都在），甲在 `/login` 的在途窗口里
    /// 时用户点了「以游客身份浏览」。`switchAccount(from: 乙, to: 甲)` 删的是**乙**的东西，
    /// 所以这道判据必须排在它前面。
    ///
    /// 探针形态：把"卡住"放进假传输层的 `/login`，并在同一次调用里把用户的显式选择落下去；
    /// 刻意不用"park 住等测试放行"—— 实现一旦没走到复核就是挂死而不是红（见文件头）。
    func testLoserSkipsTheDestructiveRebindWhenTheUserPickedGuestMidLogin() async throws {
        let stack = makeTestStack()
        let script = AuthFlowScript(accounts: [.a, .b])
        let box = InFlightLoginBox()
        let transport = FakeHTTPTransport { [script, box] request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                // 只有甲那一次 `/login` 带动"用户改选游客"，甲自己那次拿到 false 不再重入。
                if await box.claimGuestPick() {
                    await box.continueAsGuestForA()
                }
                return script.nextLoginResponse()  // 第 1 次是甲
            case CovaAuthSession.mePath:
                return script.meResponse(for: request)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = makeAuthSession(transport: transport, stack: stack)
        await box.install(session)
        // 本地归属先指着乙：这就是甲下面那次换号会删掉的东西。
        let boundLogin = try JSONDecoder().decode(CovaLoginResponseDto.self, from: TestAccount.b.loginBody)
        try stack.secureStore.set(boundLogin.token, for: TestAccount.b.item(.accessToken))
        try stack.secureStore.set(boundLogin.refreshToken, for: TestAccount.b.item(.refreshToken))
        try stack.activeOwnerStore.saveActiveOwner(TestAccount.b.principal)
        await stack.lifecycle.beginSession(owner: TestAccount.b.principal)

        do {
            _ = try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
            XCTFail("已被用户「以游客身份浏览」取代的登录必须失败")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .sessionChanged, "输家要报「会话已变」，不能假装登录成功")
        }
        let detail = await box.describeFailure() ?? "甲根本没走到 `/login`（探针未成立）"
        let picked = await box.pickedGuest()
        XCTAssertTrue(picked, "用户的显式选择没落下去 ⇒ 探针未成立（\(detail)）")

        let state = await session.currentState()
        XCTAssertEqual(state, .guest, "状态必须停在用户选的那一侧，不能被在途登录盖成已登录")
        // 症状本身：乙的会话必须仍能供出 Authorization（换号一旦跑起来就把这些一起删了）。
        XCTAssertEqual(
            try stack.secureStore.secret(for: TestAccount.b.item(.accessToken))?.rawValue,
            TestAccount.b.accessToken,
            "输家的换号不得抹掉已绑定 owner 的 access —— 那正是「状态说已登录、凭证却一无所知」"
        )
        XCTAssertNotNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.refreshToken)),
            "单次旋转的 refresh 同样不能被输家抹掉（抹掉后乙一过期就再也刷不动）"
        )
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
        XCTAssertEqual(loginCount, 1, "只有一次登录发出 `/login`（探针不得靠重放凑数）")
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(
            logoutCount, 1,
            "甲要作废**自己**这次 `/login` 在服务端建立的会话族（本地没落凭证也得撤），且只撤一次"
        )
    }

    /// 同一个跳过判据的**完全真实**版本：当前会话就是乙（真的登录上的，不是手工摆出来的），
    /// 甲在 `/login` 的窗口里时用户点了「登出」。
    ///
    /// 这条钉两件事：① 输家一个字节都不写（甲的凭证/归属都不存在，因此也没得回滚）；
    /// ② 用户那次登出是终态 —— 它取 principal 时内存里还没登录上，所以既没发出 logout 也没做
    /// 生命周期清理，不能被在途登录复活成"已登录 + 有凭证"。
    func testLoserWritesNothingWhenTheUserSignedOutBeforeTheRebind() async throws {
        let stack = makeTestStack()
        let kit = ProbeKit()
        let script = AuthFlowScript(accounts: [.a, .b])
        let transport = FakeHTTPTransport { [kit, script] request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                if await kit.isLoginFor(request, emailPrefix: "a@") {
                    // 甲停在 `/login` 里 —— 用户就是在这个窗口里点的登出。
                    await kit.raise(.parkedInsideLoginHop)
                    _ = await kit.wait(.releaseParkedLoginHop)
                }
                return await kit.loginResponse(for: request)
            case CovaAuthSession.mePath:
                return script.meResponse(for: request)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = makeAuthSession(transport: transport, stack: stack)
        defer { Task { await kit.raiseAll() } }

        let winnerUser = try await session.signIn(
            email: "b@example.invalid", password: SecretString("placeholder")
        )
        let meUserB = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.b.meBody).user
        XCTAssertEqual(winnerUser, meUserB)

        let loser = Task { () -> String in
            do {
                _ = try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
                return "committed"
            } catch let error as CovaAPIError where error == .sessionChanged {
                return "sessionChanged"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "otherError"
            }
        }
        let parkedInLoginHop = await kit.raisedWithin(.parkedInsideLoginHop, seconds: 20)
        XCTAssertTrue(parkedInLoginHop, "甲没进到 `/login` 窗口里 ⇒ 探针未成立")
        // 不取槽的那条路径：用户的显式登出可以正好落在甲的在途窗口里。
        try await session.signOut()
        await kit.raise(.releaseParkedLoginHop)
        let outcome = await loser.value
        XCTAssertEqual(outcome, "sessionChanged", "被登出取代的登录必须报「会话已变」")

        let state = await session.currentState()
        XCTAssertEqual(state, .signedOut, "在途登录不得把用户刚做的显式登出推翻成已登录")
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.a.item(.accessToken)),
            "复核排在换号之前 ⇒ 甲的凭证根本没被写过"
        )
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.accessToken)),
            "赢家的会话也不能留下来 —— 那是用户自己登出的，不是被输家抹的"
        )
        XCTAssertNil(try stack.activeOwnerStore.loadActiveOwner(), "owner 指针必须是登出后的 nil")
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertNil(lifecycleOwner, "lifecycle 归属必须是登出后的 nil")
        let snapshot = try await session.currentSession()
        XCTAssertNil(snapshot, "登出后不得再供出 Authorization")
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        XCTAssertEqual(loginCount, 2, "两次登录各发一次 `/login`")
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(
            logoutCount, 2,
            "两条各自一条：用户登出时乙确实登录着（1），甲要作废**自己**那次 `/login` 建立的会话族（1）；"
                + "甲不得为乙重放登出，也不得留下第二条"
        )
    }

    // MARK: - R16-3 的陷阱边界：排队中的登录被取消，既不能挂死也不能污染在跑的那次

    /// 串行槽把第二次点击变成"排队"，于是多出一条必须钉死的路径：**排队中被取消**。
    ///
    /// 错法有两种，都很难看：① 取消时不把自己从队列里摘掉 ⇒ 下一条登录唤醒的是这个已经死了的
    /// 等待者，真正的等待者永远拿不到槽（探针挂死而不是红）；② 摘掉自己时顺手把槽放开 ⇒
    /// 在跑的那次登录还没结束就有第三个人冲进来，回到 R16-3 要消掉的交错。
    ///
    /// 现场：甲写完凭证停在 `/me` 里（持槽），乙开始排队，随后乙的 `Task` 被取消。
    /// 断言全部有 deadline（`ProbeGate.wait(seconds:)` / 记账闸门），任何一步走不通都是红而不是挂。
    func testSignInCancelledWhileQueuedReturnsAndKeepsTheRunningLoginIntact() async throws {
        let kit = ProbeKit()
        let stack = makeTestStack(cleaners: [GateCleaner(kit: kit)])
        let script = AuthFlowScript(accounts: [.a, .b])
        let transport = FakeHTTPTransport { [kit, script] request in
            switch request.url.path {
            case CovaAuthSession.loginPath:
                // 乙的 `/login` 只允许在"甲已经离开临界区"之后发生；本例里甲始终 inside，
                // 所以修复后这条请求根本不该发出去（下面的 `/login` 计数会证明）。
                if await kit.isLoginFor(request, emailPrefix: "b@") {
                    _ = await kit.wait(.parkedInsideMeHop)
                }
                return await kit.loginResponse(for: request)
            case CovaAuthSession.mePath:
                if request.bearerToken == TestAccount.a.accessToken {
                    await kit.raise(.parkedInsideMeHop)
                    _ = await kit.wait(.releaseParkedMeHop)
                }
                return script.meResponse(for: request)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let session = makeAuthSession(transport: transport, stack: stack)
        // 兜底：无论测试走到哪一步失败，都不把任何任务永久 park 住。
        defer { Task { await kit.raiseAll() } }

        let first = UserResultBox()
        let firstTask = Task { () -> AuthUser? in
            await first.run {
                try await session.signIn(email: "a@example.invalid", password: SecretString("placeholder"))
            }
        }
        let firstInside = await kit.raisedWithin(.parkedInsideMeHop, seconds: 20)
        XCTAssertTrue(firstInside, "甲没进到 `/me` 窗口里 ⇒ 探针未成立")

        let second = UserResultBox()
        let secondTask = Task { () -> AuthUser? in
            await second.run {
                try await session.signIn(email: "b@example.invalid", password: SecretString("placeholder"))
            }
        }
        // 甲仍持着槽 ⇒ 乙只能在队列里；此刻取消它。
        secondTask.cancel()
        let cameBack = await second.waitFinished(seconds: 20)
        XCTAssertTrue(
            cameBack,
            "取消后排队的登录没有返回 ⇒ 槽被 strand（后续所有登录都会一起挂死）"
        )
        let cancelled = await second.describeFailure()
        XCTAssertEqual(
            cancelled, "cancelled",
            "取消要如实报「已取消」：既不能假装登录成功，也不能报成会话已变"
        )
        let earlyUser = await second.saved()
        XCTAssertNil(earlyUser, "被取消的登录不得留下成功结局")
        // 摘掉自己不能把在跑的人的槽放掉：甲必须照常提交。
        await kit.raise(.releaseParkedMeHop)
        let firstOutcome = await firstTask.value
        let detail = await second.describeFailure() ?? "无"
        XCTAssertNotNil(firstOutcome, "甲的登录被乙的取消波及了：\(detail)")
        let firstUser = try XCTUnwrap(firstOutcome)

        let meUserA = try JSONDecoder().decode(CovaMeResponse.self, from: TestAccount.a.meBody).user
        XCTAssertEqual(firstUser, meUserA)
        let state = await session.currentState()
        XCTAssertEqual(state, .authenticated(meUserA), "甲的会话必须是终态")
        let owner = PrincipalID(rawValue: meUserA.id)
        XCTAssertEqual(try stack.activeOwnerStore.loadActiveOwner(), owner, "owner 指针必须是甲")
        let lifecycleOwner = await stack.lifecycle.currentOwner()
        XCTAssertEqual(lifecycleOwner, owner, "lifecycle 归属必须是甲")
        let token = try await session.accessToken()
        XCTAssertEqual(
            token?.rawValue, TestAccount.a.accessToken,
            "状态说已登录 ⇒ 甲的凭证必须读得出来（被取消的乙不得抹掉它）"
        )
        let snapshot = try await session.currentSession()
        XCTAssertEqual(snapshot?.principal, owner, "凭证与状态必须是同一个人")
        XCTAssertNil(
            try stack.secureStore.secret(for: TestAccount.b.item(.accessToken)),
            "乙被取消在队列里 ⇒ 一个字节都不该写过"
        )
        let loginCount = await transport.requestCount(path: CovaAuthSession.loginPath)
        XCTAssertEqual(loginCount, 1, "乙排在槽上 ⇒ 它那次 `/login` 根本不该发出")
        let logoutCount = await transport.requestCount(path: CovaAuthSession.logoutPath)
        XCTAssertEqual(logoutCount, 0, "取消掉一次还没起步的登录不需要作废任何会话")
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

/// 一次性闸门：`wait()` 挂到 `raise()` 为止；先 raise 后 wait 同样立即通过。
///
/// `raise` 幂等 + 等待者按凭据定点摘除 ⇒ 一条闸门可以被很多个探针共用（修复前后的实现里
/// "谁先跑到某个点"并不固定），且**不会**出现"没人来唤醒"的悬挂：所有 `wait` 要么被 `raise`
/// 叫醒，要么被自己那次 `waitWithin` 的定时器叫醒，要么被测试收尾的 `raiseAll` 叫醒。
private actor ProbeGate {
    private var raised = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var ids: UInt64 = 0

    func raise() {
        guard !raised else { return }
        raised = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(returning: true) }
    }

    /// 等到闸门拉开；`false` = 超时（给了 `seconds` 才有这个可能）。
    ///
    /// 超时判定由**非结构化** `Task.detached` 送达：它不继承调用方的取消，所以即使调用方被取消，
    /// 这条等待也一定会被唤醒 —— 本仓已经被"探针挂死而不是红"烧过一次，这里不留那种形状。
    func wait(seconds: Double = .infinity) async -> Bool {
        if raised { return true }
        ids &+= 1
        let id = ids
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if raised {
                continuation.resume(returning: true)
                return
            }
            waiters.append((id, continuation))
            guard seconds.isFinite else { return }
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
                await self.timeout(id)
            }
        }
    }

    private func timeout(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

/// 一组命名闸门：探针要卡的位置与测试要看的证据各占一键，测试体里不出现裸的续作。
private actor ProbeKit {
    enum Key: CaseIterable {
        /// 停在 `/login` 网络窗口里的那次登录已拉开 = 它真的进去了（探针成立）。
        case parkedInsideLoginHop
        /// 放行那次停在 `/login` 里的登录。
        case releaseParkedLoginHop
        /// 已经**写完自己的凭证与 owner 指针**、停在 `/me` 里的那次登录。
        case parkedInsideMeHop
        /// 放行那次停在 `/me` 里的登录。
        case releaseParkedMeHop
        /// 有人开始跑破坏性换号（`SessionLifecycle.switchAccount` 的清理）。
        case enteredAccountSwitch
        /// 放行那次换号清理。
        case releaseAccountSwitch
    }

    private var gates: [Key: ProbeGate] = [:]

    func gate(_ key: Key) -> ProbeGate {
        if let existing = gates[key] { return existing }
        let created = ProbeGate()
        gates[key] = created
        return created
    }

    func raise(_ key: Key) async { await gate(key).raise() }

    func wait(_ key: Key, seconds: Double = .infinity) async -> Bool {
        await gate(key).wait(seconds: seconds)
    }

    /// 在 `seconds` 内看这件事**有没有**发生（`false` = 到此刻为止没有，且不挂死）。
    func raisedWithin(_ key: Key, seconds: Double) async -> Bool {
        await gate(key).wait(seconds: seconds)
    }

    /// 一律放行：测试中途 XCTFail 提前 return 时也不把任何任务永久 park 住。
    func raiseAll() async {
        for key in Key.allCases { await gate(key).raise() }
    }

    /// 按请求体里的 email 回对应账号的 `/login` 响应。
    ///
    /// 刻意**不看调用次序**：两种实现下"谁先发出 `/login`"并不固定，按身份回才确定。
    /// 只读 `email`，不碰密码字段。
    func loginResponse(for request: HTTPRequest) -> HTTPResponse {
        isLoginFor(request, emailPrefix: "b@") ? TestAccount.b.loginResponse : TestAccount.a.loginResponse
    }

    func isLoginFor(_ request: HTTPRequest, emailPrefix: String) -> Bool {
        guard let body = request.body,
              let dto = try? JSONDecoder().decode(CovaLoginRequestDto.self, from: body) else { return false }
        return dto.email.hasPrefix(emailPrefix)
    }
}

/// 换号清理的观测点：`SessionLifecycle.switchAccount` 跑到清理阶段时拉开 `enteredAccountSwitch`
/// 并等放行 —— 于是"谁进了破坏性重绑、什么时候进的"变成一个可断言的事实。
private final class GateCleaner: LocalSessionStateClearing, @unchecked Sendable {
    private let kit: ProbeKit

    init(kit: ProbeKit) {
        self.kit = kit
    }

    func clearPlayQueue() async throws {
        await kit.raise(.enteredAccountSwitch)
        _ = await kit.wait(.releaseAccountSwitch)
    }

    func clearPrivateMediaCache(owner: PrincipalID) async throws {}

    func tearDownPlayback(owner: PrincipalID) async throws {}
}

/// 甲停在 `/login` 里时的记账：让假传输层在那一次调用里把**用户的显式选择**落下去。
///
/// 存 `CovaAuthSession`（actor 引用，天然 Sendable）而不是 `any Error`：actor 的存储属性
/// 要满足 Sendable，错误只能存成描述文本。
private actor InFlightLoginBox {
    private var session: CovaAuthSession?
    private var claimed = false
    private var guestWasPicked = false
    private var failure: String?

    func install(_ session: CovaAuthSession) { self.session = session }

    /// 第一次调用返回 true（甲那次 `/login` 带动用户的显式选择），之后一律 false。
    func claimGuestPick() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }

    /// 在甲的 `/login` 窗口里落下「以游客身份浏览」；失败只记账，不把登录流程改成挂死。
    func continueAsGuestForA() async {
        guard let session else {
            failure = "状态机还没注入"
            return
        }
        await session.continueAsGuest()
        guestWasPicked = true
    }

    func pickedGuest() -> Bool { guestWasPicked }
    func describeFailure() -> String? { failure }
}

/// 一次登录的结局记账：成功的人 / 失败的描述，外加"已经回来了"的闸门。
///
/// 只存 `AuthUser` 与描述文本：actor 的存储属性要 Sendable，`any Error` 不能直接存。
/// 闸门是给**有上限**的等待用的 —— 取消掉一次排队的登录之后，它有没有真的回来，
/// 必须能在 deadline 内红出来，而不是让整条门禁一起挂住。
private actor UserResultBox {
    private let finished = ProbeGate()
    private var winner: AuthUser?
    private var failure: String?

    /// 跑一次登录并记账；**任何**结局都会拉开闸门。
    func run(_ login: @escaping @Sendable () async throws -> AuthUser) async -> AuthUser? {
        do {
            let user = try await login()
            winner = user
            await finished.raise()
            return user
        } catch CovaAPIError.cancelled {
            failure = "cancelled"
        } catch is CancellationError {
            failure = "cancelled"
        } catch CovaAPIError.sessionChanged {
            failure = "sessionChanged"
        } catch let error as CovaAPIError {
            failure = error.redactedDescription
        } catch {
            failure = "otherError"
        }
        await finished.raise()
        return nil
    }

    func waitFinished(seconds: Double) async -> Bool {
        await finished.wait(seconds: seconds)
    }

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
