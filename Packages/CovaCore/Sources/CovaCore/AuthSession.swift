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

/// 发起请求时捕获的会话快照：**owner + generation + 所用 access token**。
///
/// M-1：在途请求必须绑定该快照；401 重放前校验「仍是同一 principal 且 generation 未推进」，
/// 否则以 `.sessionChanged` 失败，绝不用新账号凭证重放（D8）。
public struct AuthSessionSnapshot: Equatable, Sendable {
    public let principal: PrincipalID
    public let generation: SessionGeneration
    public let accessToken: SecretString

    public init(principal: PrincipalID, generation: SessionGeneration, accessToken: SecretString) {
        self.principal = principal
        self.generation = generation
        self.accessToken = accessToken
    }
}

/// 刷新单飞分桶键：同一 `(principal, generation)` 的并发刷新才共享一次网络调用。
private struct RefreshKey: Hashable {
    let principal: PrincipalID
    let generation: SessionGeneration
}

/// 在途刷新的等待者集合（键存在即表示在途）。
private struct RefreshBucket {
    var waiters: [CheckedContinuation<SecretString, Error>] = []
}

/// API client 视角的凭证来源（由认证状态机 `CovaAuthSession` 实现）。
public protocol APICredentialProviding: Sendable {
    /// 当前会话快照；无凭证返回 `nil`（请求不带授权头）。
    /// 读取凭证失败抛 `.credentialReadFailed`（与「本无凭证」区分，m-2）。
    func currentSession() async throws -> AuthSessionSnapshot?
    /// 401 后取可用 token：校验快照仍是当前会话（owner + generation），
    /// 已在同会话内被刷新则直接复用当前 token，否则触发 single-flight 刷新。
    func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString
}

/// 认证状态机（D5）：登录/恢复/刷新/登出 + owner 绑定 + single-flight refresh。
///
/// - 所有网络调用走**注入传输**（生产 = `URLSessionTransport`；测试 = 假传输层，零真实网络）。
/// - token 存 `SecureStore`（生产 = Keychain `ThisDeviceOnly`），按 principalId 绑定（D5）。
/// - 登录/换号/登出对接 G3-b `SessionLifecycle`（推进 generation、清凭证/owner 数据/队列/播放器）。
/// - **single-flight refresh**：并发刷新只触发一次网络调用，其余等待同一结果。
/// - M-4：仅**确定性认证失败**（401/403、缺 refresh token）才清理凭证转 `signedOut`；
///   传输类失败（超时/断连/取消）保留会话并抛出可重试错误。
///
/// 安全：本类型不打印任何 token / 密码；错误一律经 `CovaAPIError`（无明文描述）。
public actor CovaAuthSession: APICredentialProviding {
    static let loginPath = "/api/auth/login"
    static let refreshPath = "/api/auth/refresh"
    static let logoutPath = "/api/auth/logout"
    static let mePath = "/api/auth/me"

    private let transport: any HTTPTransport
    private let secureStore: any SecureStore
    private let lifecycle: SessionLifecycle
    private let activeOwnerStore: any ActiveOwnerStoring
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var state: AuthSessionState = .signedOut

    /// 刷新单飞状态：按 `(principal, generation)` 分桶，**跨账号互不干扰**（m-1）。
    /// 某键存在即表示该键有一次刷新在途；等待者只加入同键。
    private var refreshBuckets: [RefreshKey: RefreshBucket] = [:]

    /// 会话代次：任何用户可感知的会话变化（登录/登出/游客/凭证吊销）都会推进。
    /// generation 管 owner 绑定，epoch 额外覆盖「显式选择 guest」这类不推进 generation 的变化。
    private var sessionEpoch: UInt64 = 0

    public init(
        transport: any HTTPTransport,
        secureStore: any SecureStore,
        lifecycle: SessionLifecycle,
        activeOwnerStore: any ActiveOwnerStoring
    ) {
        self.transport = transport
        self.secureStore = secureStore
        self.lifecycle = lifecycle
        self.activeOwnerStore = activeOwnerStore
    }

    // MARK: - 状态查询

    public func currentState() -> AuthSessionState { state }

    public func currentUser() -> AuthUser? { state.user }

    /// 当前 owner（principalId）；未登录/游客为 `nil`。
    public func currentPrincipal() -> PrincipalID? {
        state.user.map { PrincipalID(rawValue: $0.id) }
    }

    /// 当前 access token；未登录为 `nil`；读取失败抛 `.credentialReadFailed`。
    public func accessToken() async throws -> SecretString? {
        guard let principal = currentPrincipal() else { return nil }
        return try readSecret(principal, .accessToken)
    }

    // MARK: - 状态迁移

    /// 以游客身份浏览公开内容（仅从 `signedOut` 迁移）。
    ///
    /// 推进 `sessionEpoch`：若此时有恢复（restore）在途，恢复结果会被丢弃，
    /// 不得覆盖用户的显式选择。
    public func continueAsGuest() {
        if case .signedOut = state {
            state = .guest
            sessionEpoch &+= 1
        }
    }

    /// 冷启动恢复（M-2）：读取持久化 owner 指针 + 凭证 → `GET /api/auth/me` 校验。
    ///
    /// - 有效凭证 → `authenticated`；
    /// - token 过期（401）→ single-flight refresh 后**重放一次** `me`；
    /// - 凭证被吊销（刷新/校验确定性 401/403）→ 清理并转 `signedOut`；
    /// - 无凭证 → 清指针并转 `guest`；
    /// - 传输类失败 → 保留凭证并抛出（可重试），不误登出。
    ///
    /// 契约目标形态：`GET /api/auth/me` 期望 `{user, entitlements}`；真实字段不全由 NEEDS-3 跟踪，
    /// 测试使用仓库内脱敏 fixture，不连线上。
    @discardableResult
    public func restoreSession() async throws -> AuthSessionState {
        let epoch = sessionEpoch
        guard let principal = try activeOwnerStore.loadActiveOwner() else {
            enterGuest()
            return state
        }
        let generation = await lifecycle.currentGeneration()
        let access = try readSecret(principal, .accessToken)
        let refresh = try readSecret(principal, .refreshToken)
        guard access != nil || refresh != nil else {
            try? activeOwnerStore.saveActiveOwner(nil)
            enterGuest()
            return state
        }

        let me: CovaMeResponse
        do {
            me = try await fetchMe(principal: principal)
        } catch let error as CovaAPIError where Self.isAuthenticationFailure(error) {
            let recovered: CovaMeResponse?
            do {
                recovered = try await recoverMeAfterExpiry(principal: principal, generation: generation, epoch: epoch)
            } catch CovaAPIError.sessionChanged {
                // 恢复期间会话被显式改变（切号/游客/登出）：丢弃恢复结果，不覆盖用户选择。
                return state
            }
            guard let recovered else { return state } // 已 invalidate → signedOut
            me = recovered
        }

        guard me.user.id == principal.rawValue else {
            // 服务端返回的 user 与持久化 owner 不一致：不可信。仅当会话未变时才清理。
            if await isSessionUnchanged(principal: principal, generation: generation, epoch: epoch) {
                await invalidateSession(owner: principal)
            }
            return state
        }
        guard sessionEpoch == epoch,
              case .signedOut = state,
              await lifecycle.currentGeneration() == generation else {
            // 恢复完成前用户显式改变了会话状态 → 丢弃恢复结果。
            return state
        }
        await lifecycle.beginSession(owner: principal)
        try? activeOwnerStore.saveActiveOwner(principal)
        state = .authenticated(me.user)
        return state
    }

    /// 登录：POST `/api/auth/login` → 写凭证 → 绑定 owner → 转 `authenticated`。
    ///
    /// 换号清理失败与 `signOut` 一致上报 `SessionCleanupFailure`：状态仍完成迁移为
    /// `authenticated(newOwner)`，以免出现「清理报错但用户实际已登录」的半态（m-1）。
    @discardableResult
    public func signIn(email: String, password: SecretString) async throws -> AuthUser {
        let body = try encoder.encode(CovaLoginRequestDto(email: email, password: password))
        let request = try APIRequestBuilder.make(method: .post, path: Self.loginPath, jsonBody: body)
        let response: CovaLoginResponseDto = try await sendRaw(request)
        let principal = PrincipalID(rawValue: response.user.id)

        var cleanupFailure: SessionCleanupFailure?
        if let previous = await lifecycle.currentOwner(), previous != principal {
            do {
                try await lifecycle.switchAccount(from: previous, to: principal)
            } catch let error as SessionCleanupFailure {
                cleanupFailure = error
            }
        } else {
            await lifecycle.beginSession(owner: principal)
        }

        try secureStore.set(response.token, for: Self.item(principal, .accessToken))
        try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
        try? activeOwnerStore.saveActiveOwner(principal)
        state = .authenticated(response.user)
        sessionEpoch &+= 1
        if let cleanupFailure { throw cleanupFailure }
        return response.user
    }

    /// 登出：best-effort 通知服务端 → 清该 owner 本地状态（`SessionLifecycle`）→ 转 `signedOut`。
    ///
    /// - Throws: 仅当本地清理有分量失败时抛 `SessionCleanupFailure`；状态已转 `signedOut`。
    public func signOut() async throws {
        let principal = currentPrincipal()
        if let principal, let token = try? readSecret(principal, .accessToken) {
            await sendLogoutBestEffort(token: token)
        }
        state = .signedOut
        sessionEpoch &+= 1
        try? activeOwnerStore.saveActiveOwner(nil)
        if let principal {
            try await lifecycle.signOut(owner: principal)
        }
    }

    // MARK: - APICredentialProviding

    public func currentSession() async throws -> AuthSessionSnapshot? {
        guard let principal = currentPrincipal() else { return nil }
        guard let token = try readSecret(principal, .accessToken) else { return nil }
        let generation = await lifecycle.currentGeneration()
        return AuthSessionSnapshot(principal: principal, generation: generation, accessToken: token)
    }

    /// 401 后取可用 access token（M-1 归属校验 + 同会话去重 + single-flight）。
    public func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
        guard currentPrincipal() == snapshot.principal else {
            throw CovaAPIError.sessionChanged
        }
        guard await lifecycle.currentGeneration() == snapshot.generation else {
            throw CovaAPIError.sessionChanged
        }
        if let current = try readSecret(snapshot.principal, .accessToken), current != snapshot.accessToken {
            // 同会话内已被其它并发请求刷新：直接复用，不再触发网络刷新。
            return current
        }
        return try await performSingleFlightRefresh(
            principal: snapshot.principal,
            expectedGeneration: snapshot.generation,
            expectedEpoch: sessionEpoch
        )
    }

    // MARK: - 私有

    /// 刷新失败后的 `me` 恢复；确定性认证失败 → 刷新路径已清理并返回 `nil`。
    ///
    /// `.sessionChanged`（会话在刷新期间被切号/游客/登出）不在此吞掉，向上传播由调用方丢弃结果。
    private func recoverMeAfterExpiry(
        principal: PrincipalID,
        generation: SessionGeneration,
        epoch: UInt64
    ) async throws -> CovaMeResponse? {
        do {
            _ = try await performSingleFlightRefresh(
                principal: principal,
                expectedGeneration: generation,
                expectedEpoch: epoch
            )
            return try await fetchMe(principal: principal)
        } catch let error as CovaAPIError where Self.isAuthenticationFailure(error) {
            return nil
        }
    }

    private func fetchMe(principal: PrincipalID) async throws -> CovaMeResponse {
        guard let token = try readSecret(principal, .accessToken) else {
            throw CovaAPIError.unauthorized(apiCode: nil)
        }
        let request = try APIRequestBuilder.make(method: .get, path: Self.mePath, bearer: token)
        return try await sendRaw(request)
    }

    /// single-flight 刷新（按 `(principal, generation)` 分桶）。
    ///
    /// 失败分类（M-1 + m-4）：
    /// - **会话已变**（epoch/generation/principal 任一改变）→ 不做任何全局清理，抛 `.sessionChanged`；
    /// - 会话未变且为**确定性认证失败** → 清该 owner 凭证并转 `signedOut`；
    /// - 会话未变且为**传输类失败** → 保留会话并抛可重试错误。
    private func performSingleFlightRefresh(
        principal: PrincipalID,
        expectedGeneration: SessionGeneration,
        expectedEpoch: UInt64
    ) async throws -> SecretString {
        let key = RefreshKey(principal: principal, generation: expectedGeneration)
        if var bucket = refreshBuckets[key] {
            // 只加入同账号 + 同 generation 的在途刷新（m-1：新账号不得被旧账号刷新影响）。
            return try await withCheckedThrowingContinuation { continuation in
                bucket.waiters.append(continuation)
                refreshBuckets[key] = bucket
            }
        }

        guard let refreshSecret = try readSecret(principal, .refreshToken) else {
            if await isSessionUnchanged(principal: principal, generation: expectedGeneration, epoch: expectedEpoch) {
                await invalidateSession(owner: principal)
                throw CovaAPIError.unauthorized(apiCode: nil)
            }
            throw CovaAPIError.sessionChanged
        }

        refreshBuckets[key] = RefreshBucket()
        let result: Result<SecretString, Error>
        do {
            let request = try APIRequestBuilder.make(method: .post, path: Self.refreshPath, bearer: refreshSecret)
            let response: CovaRefreshResponseDto = try await sendRaw(request)
            if await isSessionUnchanged(principal: principal, generation: expectedGeneration, epoch: expectedEpoch) {
                try secureStore.set(response.token, for: Self.item(principal, .accessToken))
                try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
                result = .success(response.token)
            } else {
                result = .failure(CovaAPIError.sessionChanged)
            }
        } catch {
            result = .failure(CovaAPIError.normalize(error))
        }
        finishRefresh(key: key, result: result)

        switch result {
        case .success(let token):
            return token
        case .failure(let error):
            // 关键：失败分支同样先复核归属；会话已变则绝不清理新账号，改抛 stale 错误。
            guard await isSessionUnchanged(principal: principal, generation: expectedGeneration, epoch: expectedEpoch) else {
                throw CovaAPIError.sessionChanged
            }
            if Self.isAuthenticationFailure(error) {
                await invalidateSession(owner: principal)
            }
            throw error
        }
    }

    /// 结束一次刷新（指定分桶）：移除分桶并把同一结果派发给该桶的全部等待者。
    private func finishRefresh(key: RefreshKey, result: Result<SecretString, Error>) {
        let bucket = refreshBuckets.removeValue(forKey: key)
        for waiter in bucket?.waiters ?? [] {
            switch result {
            case .success(let token): waiter.resume(returning: token)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    /// 会话是否仍是发起刷新时的那一个：epoch 未推进 + generation 未推进 + principal 未被换成别人。
    private func isSessionUnchanged(
        principal: PrincipalID,
        generation: SessionGeneration,
        epoch: UInt64
    ) async -> Bool {
        guard sessionEpoch == epoch else { return false }
        guard await lifecycle.currentGeneration() == generation else { return false }
        if let current = currentPrincipal() { return current == principal }
        return true
    }

    /// 进入游客态（推进 epoch，使在途恢复/刷新失效）。
    private func enterGuest() {
        state = .guest
        sessionEpoch &+= 1
    }

    /// 凭证被吊销/不可恢复：清该 owner 本地状态与 owner 指针并转 `signedOut`（清理失败不阻断）。
    private func invalidateSession(owner: PrincipalID) async {
        state = .signedOut
        sessionEpoch &+= 1
        try? activeOwnerStore.saveActiveOwner(nil)
        try? await lifecycle.signOut(owner: owner)
    }

    /// best-effort 服务端登出：网络/读取失败不影响本地清理。
    private func sendLogoutBestEffort(token: SecretString) async {
        do {
            let request = try APIRequestBuilder.make(method: .post, path: Self.logoutPath, bearer: token)
            _ = try await transport.send(request)
        } catch {
            // 刻意吞掉：本地清理是终态保障。
        }
    }

    /// 读取凭证：存储层异常 → `.credentialReadFailed`（与「本无凭证」区分，m-2）。
    private func readSecret(_ principal: PrincipalID, _ kind: CredentialKind) throws -> SecretString? {
        do {
            return try secureStore.secret(for: Self.item(principal, kind))
        } catch {
            throw CovaAPIError.credentialReadFailed
        }
    }

    /// 发送一个不参与自动刷新的请求（登录/刷新/登出/me 自身）。
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

    /// 确定性认证失败：只有这类失败才允许清理凭证并转 `signedOut`（m-4）。
    /// 传输类错误（timeout/offline/cancelled/transport）不在此列。
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? CovaAPIError else { return false }
        switch apiError {
        case .unauthorized:
            return true
        case .httpStatus(let code, _):
            return code == 401 || code == 403
        default:
            return false
        }
    }
}
