@testable import CovaCore
import Foundation
import XCTest

/// 可控闸门：让 A 的刷新在途，测试在此期间完成切号 / 发起 B 的请求。
private actor RefreshGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func signalStarted() {
        started = true
        let waiters = startedWaiters
        startedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}

/// 到达栅栏：等 N 个受保护请求都拿到 401 后再一起放行，制造真正的并发 401 风暴。
private actor ArrivalBarrier {
    private let expected: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= expected {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class SessionRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CovaAuthSession?
    var session: CovaAuthSession? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// M-1 / m-1：在途旧账号刷新 + 切号 + 新账号请求的交互。
final class CrossAccountRefreshTests: XCTestCase {
    private static let aRefresh = "REFRESH_TOKEN_PLACEHOLDER"
    private static let bRefresh = "SECOND_REFRESH"
    private static let protectedPath = "/api/tracks/1"
    private static let bRefreshResponse = Data(
        #"{"token":"SECOND_ACCESS_2","refreshToken":"SECOND_REFRESH_2","expiresIn":7200}"#.utf8
    )

    /// `aRefreshResult` 决定 A 的刷新最终返回 401 还是 200（用于分别覆盖失败/成功分支）。
    private func makeTransport(
        gate: RefreshGate,
        aRefreshResult: @escaping @Sendable () -> HTTPResponse
    ) -> FakeHTTPTransport {
        // 两次登录分别是 A、B（`/me` 按出示的 token 回同 id 身份）。
        let script = AuthFlowScript(accounts: [.a, .b])
        return makeAuthTransport(script: script) { request in
            switch request.url.path {
            case CovaAuthSession.refreshPath:
                switch request.bearerToken {
                case Self.aRefresh:
                    await gate.signalStarted()
                    await gate.waitForRelease()
                    return aRefreshResult()
                case Self.bRefresh:
                    return HTTPResponse(statusCode: 200, body: Self.bRefreshResponse)
                default:
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
            case Self.protectedPath:
                // 旧 token 一律 401，用来触发各自的刷新；刷新后的 token 返回 200。
                if request.bearerToken == "ACCESS_TOKEN_PLACEHOLDER" || request.bearerToken == "SECOND_ACCESS" {
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
    }

    private func startARequestThenSwitchToB(
        transport: FakeHTTPTransport,
        gate: RefreshGate,
        session: CovaAuthSession,
        client: CovaAPIClient
    ) async -> Task<CovaAPIError?, Never> {
        let aTask = Task { () -> CovaAPIError? in
            do {
                let _: EmptyDTO = try await client.get(Self.protectedPath)
                return nil
            } catch {
                return error as? CovaAPIError
            }
        }
        await gate.waitUntilStarted()
        try? await session.signIn(email: "b@example.invalid", password: SecretString("pw"))
        return aTask
    }

    // M-1：旧账号刷新失败（401）不得清理已切换的新账号；原调用者收到 sessionChanged。
    func testOldAccountRefreshFailureDoesNotCleanUpSwitchedAccount() async throws {
        let gate = RefreshGate()
        let transport = makeTransport(gate: gate) { HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized) }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        let aTask = await startARequestThenSwitchToB(transport: transport, gate: gate, session: session, client: client)

        // B（当前账号）的请求必须成功，并触发 B 自己的刷新。
        let bResponse: EmptyDTO = try await client.get(Self.protectedPath)
        _ = bResponse

        await gate.release()
        let aError = await aTask.value

        XCTAssertEqual(aError, .sessionChanged, "切号后原调用者必须收到 sessionChanged，而非 unauthorized")

        let state = await session.currentState()
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        XCTAssertTrue(state.isAuthenticated, "新账号不得被旧账号刷新失败登出")
        XCTAssertEqual(state.user?.id, "user-0002")
        XCTAssertEqual(pointer, PrincipalID(rawValue: "user-0002"))
        let bToken = try stack.secureStore.secret(for: SecureStoreItem(principalId: PrincipalID(rawValue: "user-0002"), kind: .accessToken))
        XCTAssertEqual(bToken?.rawValue, "SECOND_ACCESS_2", "B 自己的刷新结果必须保留")
        XCTAssertNil(try stack.secureStore.secret(for: SecureStoreItem(principalId: PrincipalID(rawValue: "user-0001"), kind: .accessToken)))
        let bRefreshCount = await transport.requestCount(path: CovaAuthSession.refreshPath)
        XCTAssertGreaterThanOrEqual(bRefreshCount, 2, "A、B 各触发一次刷新（分桶，不共享）")
    }

    // 覆盖盲点①：旧账号在途刷新**成功**返回也不得复活旧会话（杀死「删除成功分支 generation 校验」的变异）。
    func testOldAccountRefreshSuccessAfterSwitchIsDiscarded() async throws {
        let gate = RefreshGate()
        let transport = makeTransport(gate: gate) { HTTPResponse(statusCode: 200, body: TestTransportData.refresh) }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        let aTask = await startARequestThenSwitchToB(transport: transport, gate: gate, session: session, client: client)
        await gate.release()
        let aError = await aTask.value

        XCTAssertEqual(aError, .sessionChanged, "A 的成功刷新结果必须作废")
        let state = await session.currentState()
        XCTAssertEqual(state.user?.id, "user-0002")
        XCTAssertNil(
            try stack.secureStore.secret(for: SecureStoreItem(principalId: PrincipalID(rawValue: "user-0001"), kind: .accessToken)),
            "旧账号 token 不得被写回（复活）"
        )
        let bToken = try stack.secureStore.secret(for: SecureStoreItem(principalId: PrincipalID(rawValue: "user-0002"), kind: .accessToken))
        XCTAssertEqual(bToken?.rawValue, "SECOND_ACCESS", "B 的凭证不受影响")
    }

    // F1：并发 401 风暴 + 切号，**每个**等待者必须收到 sessionChanged（而非 leader 的 unauthorized）。
    func testConcurrentWaitersReceiveSessionChangedAfterSwitch() async throws {
        let concurrency = 8
        let gate = RefreshGate()
        let barrier = ArrivalBarrier(expected: concurrency)
        let script = AuthFlowScript(accounts: [.a, .b])
        let transport = makeAuthTransport(script: script) { request in
            switch request.url.path {
            case Self.protectedPath:
                if request.bearerToken == "ACCESS_TOKEN_PLACEHOLDER" {
                    await barrier.arriveAndWait()
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            case CovaAuthSession.refreshPath:
                if request.bearerToken == Self.aRefresh {
                    await gate.signalStarted()
                    await gate.waitForRelease()
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
                if request.bearerToken == Self.bRefresh {
                    return HTTPResponse(statusCode: 200, body: Self.bRefreshResponse)
                }
                return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
            default:
                return HTTPResponse(statusCode: 200, body: TestTransportData.ok)
            }
        }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        let tasks: [Task<CovaAPIError?, Never>] = (0..<concurrency).map { _ in
            Task {
                do {
                    let _: EmptyDTO = try await client.get(Self.protectedPath)
                    return nil
                } catch {
                    return error as? CovaAPIError
                }
            }
        }

        await gate.waitUntilStarted()
        try await session.signIn(email: "b@example.invalid", password: SecretString("pw"))
        await gate.release()

        var errors: [CovaAPIError?] = []
        for task in tasks { errors.append(await task.value) }
        XCTAssertEqual(errors.count, concurrency)
        for (index, error) in errors.enumerated() {
            XCTAssertEqual(
                error,
                .sessionChanged,
                "等待者[\(index)] 必须收到 sessionChanged，而非 leader 的 unauthorized"
            )
        }
        let state = await session.currentState()
        XCTAssertEqual(state.user?.id, "user-0002", "新会话不得被清理/登出")
        let pointer = try stack.activeOwnerStore.loadActiveOwner()
        XCTAssertEqual(pointer, PrincipalID(rawValue: "user-0002"))
    }

    // m-1：B 已登录时，A 的在途刷新不得让 B 的合法请求被误判失败。
    func testNewAccountRefreshIsNotAffectedByOldAccountInFlightRefresh() async throws {
        let gate = RefreshGate()
        let transport = makeTransport(gate: gate) { HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized) }
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(email: "a@example.invalid", password: SecretString("pw"))
        let client = CovaAPIClient(transport: transport, credentials: session)

        _ = await startARequestThenSwitchToB(transport: transport, gate: gate, session: session, client: client)

        var bError: CovaAPIError?
        do {
            let _: EmptyDTO = try await client.get(Self.protectedPath)
        } catch {
            bError = error as? CovaAPIError
        }
        XCTAssertNil(bError, "B 的请求不得被 A 的在途刷新影响")
        await gate.release()
    }
}
