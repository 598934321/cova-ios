import Foundation

/// 认证会话状态（api-contracts §1）。
///
/// - `signedOut`：无凭证，也未选择匿名浏览；
/// - `guest`：可浏览公开内容（AI 与收藏需登录，由上层按 `isAuthenticated` 判定）；
/// - `authenticated`：持有有效会话（access/refresh token 已写入 `SecureStore`）。
public enum AuthSessionState: Equatable, Sendable {
    case signedOut
    case guest
    case authenticated(AuthUser)

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    public var user: AuthUser? {
        if case .authenticated(let user) = self { return user }
        return nil
    }
}

/// 认证状态机（D5）：登录/刷新/登出 + owner 绑定 + single-flight refresh。
///
/// - 所有网络调用走**注入传输**（生产 = `URLSessionTransport`；测试 = 假传输层，零真实网络）。
/// - token 存 `SecureStore`（生产 = Keychain `ThisDeviceOnly`），按 principalId 绑定（D5）。
/// - 登录/换号/登出对接 G3-b `SessionLifecycle`（推进 generation、清凭证/owner 数据/队列/播放器）。
/// - **single-flight refresh**：并发 `refreshAccessToken()` 只触发一次刷新网络调用，
///   其余等待同一结果；刷新失败 → 清凭证并转 `signedOut`（任务原文）。
///
/// 安全：本类型不打印任何 token / 密码；错误一律经 `CovaAPIError`（无明文描述）。
public actor CovaAuthSession: APICredentialProviding {
    static let loginPath = "/api/auth/login"
    static let refreshPath = "/api/auth/refresh"
    static let logoutPath = "/api/auth/logout"

    private let transport: any HTTPTransport
    private let secureStore: any SecureStore
    private let lifecycle: SessionLifecycle
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var state: AuthSessionState = .signedOut

    /// single-flight 刷新状态：`isRefreshing` 为真时，后来者把 continuation 入队等待同一结果。
    private var isRefreshing = false
    private var refreshWaiters: [CheckedContinuation<SecretString, Error>] = []

    /// 会话代次：登录/登出/刷新失败都会推进，使在途刷新的结果作废（不复活旧会话）。
    private var sessionEpoch: UInt64 = 0

    public init(
        transport: any HTTPTransport,
        secureStore: any SecureStore,
        lifecycle: SessionLifecycle
    ) {
        self.transport = transport
        self.secureStore = secureStore
        self.lifecycle = lifecycle
    }

    // MARK: - 状态查询

    public func currentState() -> AuthSessionState { state }

    public func currentUser() -> AuthUser? { state.user }

    /// 当前 owner（principalId）；未登录/游客为 `nil`。
    public func currentPrincipal() -> PrincipalID? {
        state.user.map { PrincipalID(rawValue: $0.id) }
    }

    // MARK: - 状态迁移

    /// 以游客身份浏览公开内容（仅从 `signedOut` 迁移）。
    public func continueAsGuest() {
        if case .signedOut = state {
            state = .guest
        }
    }

    /// 登录：POST `/api/auth/login` → 写凭证 → 绑定 owner → 转 `authenticated`。
    ///
    /// 契约按目标形态建模；真实 `user` 缺字段由 NEEDS-1 跟踪（见 docs/NEEDS.md）。
    @discardableResult
    public func signIn(email: String, password: SecretString) async throws -> AuthUser {
        let body = try encoder.encode(CovaLoginRequestDto(email: email, password: password))
        let request = try APIRequestBuilder.make(method: .post, path: Self.loginPath, jsonBody: body)
        let response: CovaLoginResponseDto = try await sendRaw(request)
        let principal = PrincipalID(rawValue: response.user.id)

        if let previous = await lifecycle.currentOwner(), previous != principal {
            try? await lifecycle.switchAccount(from: previous, to: principal)
        } else {
            await lifecycle.beginSession(owner: principal)
        }

        try secureStore.set(response.token, for: Self.item(principal, .accessToken))
        try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
        sessionEpoch &+= 1
        state = .authenticated(response.user)
        return response.user
    }

    /// 登出：best-effort 通知服务端 → 清该 owner 本地状态（`SessionLifecycle`）→ 转 `signedOut`。
    ///
    /// - Throws: 仅当本地清理有分量失败时抛 `SessionCleanupFailure`；状态已转 `signedOut`。
    public func signOut() async throws {
        let principal = currentPrincipal()
        if let token = await accessToken() {
            await sendLogoutBestEffort(token: token)
        }
        sessionEpoch &+= 1
        state = .signedOut
        if let principal {
            try await lifecycle.signOut(owner: principal)
        }
    }

    // MARK: - APICredentialProviding

    public func accessToken() async -> SecretString? {
        guard let principal = currentPrincipal() else { return nil }
        return (try? secureStore.secret(for: Self.item(principal, .accessToken))) ?? nil
    }

    /// 401 后取可用 access token（single-flight + 陈旧 token 去重）。
    ///
    /// - 若当前 access token 已不同于 `staleToken`（其它并发请求已完成刷新）→ 直接返回当前 token，
    ///   不触发新的刷新网络调用；
    /// - 否则参与 single-flight：并发调用只触发一次刷新，等待者共享同一 `Result`；
    /// - 刷新失败 → 清凭证并转 `signedOut`（等待者与原调用者得到同一个可判定 `CovaAPIError`）。
    ///
    /// 判定与 `isRefreshing` 检查在同一 actor 临界区内完成，因此「同批 401 只刷一次」是确定性的，
    /// 不依赖网络时序。
    public func refreshAccessToken(replacing staleToken: SecretString?) async throws -> SecretString {
        guard let principal = currentPrincipal() else {
            throw CovaAPIError.unauthorized(apiCode: nil)
        }
        if let staleToken,
           let current = (try? secureStore.secret(for: Self.item(principal, .accessToken))) ?? nil,
           current != staleToken {
            return current
        }
        return try await performSingleFlightRefresh(principal: principal)
    }

    private func performSingleFlightRefresh(principal: PrincipalID) async throws -> SecretString {
        if isRefreshing {
            return try await withCheckedThrowingContinuation { continuation in
                refreshWaiters.append(continuation)
            }
        }
        guard let refreshSecret = (try? secureStore.secret(for: Self.item(principal, .refreshToken))) ?? nil else {
            await invalidateSession(owner: principal)
            throw CovaAPIError.unauthorized(apiCode: nil)
        }

        isRefreshing = true
        let epoch = sessionEpoch
        let result: Result<SecretString, Error>
        do {
            let request = try APIRequestBuilder.make(method: .post, path: Self.refreshPath, bearer: refreshSecret)
            let response: CovaRefreshResponseDto = try await sendRaw(request)
            if epoch == sessionEpoch {
                try secureStore.set(response.token, for: Self.item(principal, .accessToken))
                try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
                result = .success(response.token)
            } else {
                // 会话已在刷新期间被登出/换号：结果作废，不复活旧会话。
                result = .failure(CovaAPIError.cancelled)
            }
        } catch {
            result = .failure(CovaAPIError.normalize(error))
        }
        finishRefresh(result)

        switch result {
        case .success(let token):
            return token
        case .failure(let error):
            if epoch == sessionEpoch {
                await invalidateSession(owner: principal)
            }
            throw error
        }
    }

    // MARK: - 私有

    /// 结束一次刷新：清空队列并把同一结果派发给全部等待者。
    private func finishRefresh(_ result: Result<SecretString, Error>) {
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            switch result {
            case .success(let token): waiter.resume(returning: token)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    /// 刷新失败/凭证缺失：清该 owner 本地状态并转 `signedOut`（清理失败不阻断状态迁移）。
    private func invalidateSession(owner: PrincipalID) async {
        sessionEpoch &+= 1
        state = .signedOut
        try? await lifecycle.signOut(owner: owner)
    }

    /// best-effort 服务端登出：网络失败不影响本地清理。
    private func sendLogoutBestEffort(token: SecretString) async {
        do {
            let request = try APIRequestBuilder.make(method: .post, path: Self.logoutPath, bearer: token)
            _ = try await transport.send(request)
        } catch {
            // 刻意吞掉：本地清理是终态保障。
        }
    }

    /// 发送一个不参与自动刷新的请求（登录/刷新/登出自身）。
    private func sendRaw<Response: Decodable>(_ request: HTTPRequest) async throws -> Response {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw CovaAPIError.normalize(error)
        }
        guard (200...299).contains(response.statusCode) else {
            throw CovaAPIError.classify(httpStatus: response.statusCode, body: response.body) ?? .invalidResponse
        }
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch let error as DecodingError {
            throw CovaAPIError.classify(decoding: error)
        } catch {
            throw CovaAPIError.decoding(field: nil)
        }
    }

    private static func item(_ principalId: PrincipalID, _ kind: CredentialKind) -> SecureStoreItem {
        SecureStoreItem(principalId: principalId, kind: kind)
    }
}
