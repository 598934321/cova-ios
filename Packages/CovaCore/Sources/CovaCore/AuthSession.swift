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

/// 刷新单飞分桶键：同一 `(principal, generation, epoch)` 的并发刷新才共享一次网络调用。
///
/// 把 `epoch` 并入键，保证同桶等待者与 leader 共享同一会话代次，
/// 从而「派发前复核归属」的结论对整桶一致（F1）。
private struct RefreshKey: Hashable {
    let principal: PrincipalID
    let generation: SessionGeneration
    let epoch: UInt64
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

    /// 登录两步之间身份不一致时的错误描述键（`CovaAPIError.decoding(field:)` 的 `field`）。
    static let identityMismatchDescription = "auth-me-user-id"

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

    /// 测试注入点：会话激活（提交 `authenticated`）前的钩子；生产恒为 `nil`。
    private var beforeSessionActivation: (@Sendable () async -> Void)?

    /// 两个提交临界区共用它（`restoreSession` 与 `signIn`），因为要钉的是同一件事：
    /// 最后一道 await 之后到写 `state` 之间，用户的显式会话变化不得被在途结果推翻。
    func setBeforeSessionActivation(_ hook: (@Sendable () async -> Void)?) {
        beforeSessionActivation = hook
    }

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
        // 测试注入点（生产恒为 nil）：在两次 await 之间模拟用户显式 guest/切号，验证提交临界区（F3）。
        if let hook = beforeSessionActivation {
            await hook()
        }
        // 最终复核（同步，无 await）：`beginSession` 是 await 点，期间本 actor 可被重入；
        // epoch/state 的变更都在本 actor 内同步发生，故此处复核即为权威判定。
        guard sessionEpoch == epoch, case .signedOut = state else {
            return state
        }
        try? activeOwnerStore.saveActiveOwner(principal)
        state = .authenticated(me.user)
        return state
    }

    /// 登录（两步，与 web 同一入口）：`POST /api/auth/login` 建立凭证 → `GET /api/auth/me`
    /// 取回权威身份与权益 → 绑定 owner → 转 `authenticated(me.user)`。
    ///
    /// - Throws: 第一步的传输/认证错误；或第二步失败 —— 那时**已写入的凭证会被收回**，
    ///   不留「状态说已登录、身份与权益一无所知」的半态；以及换号清理的 `SessionCleanupFailure`
    ///   （后者不阻断登录，见 m-1）。
    ///
    /// 换号清理失败与 `signOut` 一致上报 `SessionCleanupFailure`：状态仍完成迁移为
    /// `authenticated(newOwner)`，以免出现「清理报错但用户实际已登录」的半态（m-1）。
    ///
    /// **提交纪律**（R15-1）：`/me` 是在途窗口，所以写 `state` 之前按 `restoreSession` 的口径
    /// 同步复核 `sessionEpoch`；复核不过就定点收回本次登录自己写的凭证并抛 `.sessionChanged`。
    /// 不复核会有两类真后果：显式登出被在途登录推翻（状态复活成已登录、凭证留在库里，而那次
    /// 登出因为取到 nil principal 既没通知服务端也没做本地清理），以及并发登录两个账号时
    /// 「状态写甲、owner 指针是乙」—— 此后每个请求都不带 Authorization。
    @discardableResult
    public func signIn(email: String, password: SecretString) async throws -> AuthUser {
        // 基准在**入口**取：本次登录期间任何用户可感知的会话变化都会推进它。
        let epoch = sessionEpoch
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

        do {
            // **先写 refresh、再写 access**（R15-5）。refresh token 是单次消费的旋转凭证：
            // 反过来的写序一旦只落一半，库里留下的是「新 access + 已被服务端消费掉的旧 refresh」
            // ⇒ 刷新永久坏掉，只能重新登录。按现在的顺序失败，留下的是「旧 access + 新 refresh」
            // ⇒ 旧 access 过期后仍能用新 refresh 续上。两条写不可能原子（`SecureStore` 只有单条写），
            // 所以让**可恢复的那一侧**去承受半态。
            try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
            try secureStore.set(response.token, for: Self.item(principal, .accessToken))
        } catch {
            // 凭证没落全 = 登录没建立：把本次写进去的东西定点收回，别留孤儿凭证。
            if let discardFailure = await discardOwnSessionArtifacts(principal: principal) {
                throw discardFailure  // 收回本身失败 ⇒ 抛它：「库里可能还有可用凭证」更要紧
            }
            throw error
        }
        try? activeOwnerStore.saveActiveOwner(principal)
        // **身份以 `GET /api/auth/me` 为准**（对照 web 客户端：`LoginForm` 登录成功后并不使用
        // 登录响应里的 `user`，而是立刻 `refresh(true)` 走 `/me`；`covaId / phone / avatar /
        // isArtist / isPartner` 与 `entitlements` 只在 `/me` 上给）。所以登录是两步：
        // 建立凭证 → 取回身份。把 `response.user` 当身份会让「刚登录的那一次会话」
        // 一直缺身份与权益，直到冷启动走 `/me` 恢复路径才补齐 —— 两处口径不一致。
        let me: CovaMeResponse
        do {
            me = try await fetchMe(principal: principal)
        } catch {
            // `/me` 失败 = 登录**没有完成**：留着凭证就得到一个「状态声称已登录、
            // 身份与权益却一无所知」的半态。凭证与本地态一并收回，让调用方看到真实结果。
            try await concludeFailedSignIn(owner: principal, epoch: epoch, primary: error)
        }
        // **两次响应必须是同一个人**。`/me` 是权威身份源，若它回的是另一个 `id`，
        // 拿它覆盖刚登录的 principal 会把会话记到错误的人身上（权益、缓存归属、
        // 播放上报的 owner 全跟着错）；拿 `response.user` 继续又回到"缺身份"的老问题。
        // 所以这里 fail-closed：收回凭证并报错，不猜哪一个是对的。
        guard me.user.id == response.user.id else {
            try await concludeFailedSignIn(
                owner: principal,
                epoch: epoch,
                primary: CovaAPIError.decoding(field: Self.identityMismatchDescription)
            )
        }
        // 测试注入点（生产恒为 nil）：在最后一道 await 之后模拟显式登出/切游客/切号。
        if let hook = beforeSessionActivation {
            await hook()
        }
        // **提交前复核**（R15-1）：`fetchMe` 与上面那道钩子都是 await 点，期间用户的显式动作
        // （登出 / 选游客）或另一个账号的登录都可能改变会话。不复核就写 `state`，等于把用户
        // 最后那一下真实操作推翻 —— 这正是 P1/P2 两个探针的形状。
        //
        // 判据只取 `sessionEpoch`，**刻意不并 generation**：本 actor 里每一条"用户可感知的会话
        // 变化"都在同步上下文里推进 epoch，所以同步读它就是终态判定；而 generation 只做
        // 「作废在途结果」用，`restoreSession` 会推进它却不推进 epoch（被动冷启动恢复不算
        // 用户动作）。拿它当提交判据的后果是反的：一次迟到的冷启动恢复会把用户**主动**点的
        // 这次登录判废。`SignInCommitDisciplineTests` 里那条反向用例钉的就是这个取舍。
        guard sessionEpoch == epoch else {
            try await concludeFailedSignIn(
                owner: principal, epoch: epoch, primary: CovaAPIError.sessionChanged
            )
        }
        state = .authenticated(me.user)
        sessionEpoch &+= 1
        if let cleanupFailure { throw cleanupFailure }
        return me.user
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
            // 两个来源都可能落到这里：刷新本身确定性失败（刷新路径已清理），
            // 或「刷新 2xx 但二次 me 仍 401/403」。后者此前不清理（F2）——统一按需清理。
            if await isSessionUnchanged(principal: principal, generation: generation, epoch: epoch) {
                await invalidateSession(owner: principal)
            }
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
        let key = RefreshKey(principal: principal, generation: expectedGeneration, epoch: expectedEpoch)
        if var bucket = refreshBuckets[key] {
            // 只加入同账号 + 同 generation + 同 epoch 的在途刷新（m-1：新账号不得被旧账号刷新影响）。
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
                // 与 `signIn` 同一写序（R15-5）：**先落新 refresh，再落新 access**。服务端已经消费掉
                // 旧 refresh，所以半态只能落在可恢复的那一侧 —— 反过来写会留下
                // 「新 access + 已作废的旧 refresh」，access 一过期就再也刷不动，只能重新登录。
                try secureStore.set(response.refreshToken, for: Self.item(principal, .refreshToken))
                try secureStore.set(response.token, for: Self.item(principal, .accessToken))
                result = .success(response.token)
            } else {
                result = .failure(CovaAPIError.sessionChanged)
            }
        } catch {
            result = .failure(CovaAPIError.normalize(error))
        }
        // 派发前复核归属：会话已变则整桶（含 leader）交付 `.sessionChanged`，
        // 绝不把 leader 的原始认证失败交给等待者（F1）。
        let delivered = await finishRefresh(key: key, result: result)

        switch delivered {
        case .success(let token):
            return token
        case .failure(let error):
            if Self.isAuthenticationFailure(error) {
                // 能走到这里说明派发时会话未变；仍再同步复核一次，避免清理期间被切号。
                if await isSessionUnchanged(principal: principal, generation: expectedGeneration, epoch: expectedEpoch) {
                    await invalidateSession(owner: principal)
                } else {
                    throw CovaAPIError.sessionChanged
                }
            }
            throw error
        }
    }

    /// 结束一次刷新（指定分桶）：移除分桶，**先复核归属**再向等待者派发结果。
    ///
    /// - 会话未变 → 派发 leader 原始结果；
    /// - 会话已变 → 向整桶派发 `.sessionChanged`。
    ///
    /// - Returns: 实际派发给等待者的结果（leader 据此决定自身行为，保证与等待者一致）。
    private func finishRefresh(
        key: RefreshKey,
        result: Result<SecretString, Error>
    ) async -> Result<SecretString, Error> {
        let bucket = refreshBuckets.removeValue(forKey: key)
        let waiters = bucket?.waiters ?? []
        let unchanged = await isSessionUnchanged(
            principal: key.principal,
            generation: key.generation,
            epoch: key.epoch
        )
        let delivered: Result<SecretString, Error> = unchanged
            ? result
            : .failure(CovaAPIError.sessionChanged)
        for waiter in waiters {
            switch delivered {
            case .success(let token): waiter.resume(returning: token)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
        return delivered
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

    /// 收尾一次**没完成**的登录（`/me` 失败、两步身份不一致、提交前复核不过）。
    ///
    /// 分两种现场，用错一种就是事故：
    /// - 会话仍归本次登录（`epoch` 没动）→ 走完整失效：状态转 `signedOut` + 生命周期清理。
    ///   此时不留「状态说已登录、身份一无所知」的半态。
    /// - 已被别的会话变化接管（用户的显式登出/切游客，或另一个账号先提交）→ **只**定点收回
    ///   本次自己写进去的凭证与 owner 指针。这里若去动全局状态，就会把接管者（往往是用户
    ///   最后那一下真实操作）的会话抹掉 —— 那正是 R15-1 反过来要犯的错。
    ///
    /// - Throws: 永远抛（`-> Never`）。默认抛 `primary`（登录为什么没成）；但本地收尾本身失败时
    ///   改抛该清理失败 —— 「库里可能还留着一条可用凭证」比"没登上的原因"更需要调用方知道，
    ///   这也是 `SessionLifecycle` 自己写的「清理失败必须可观测」（R15-4，不再用 `try?` 吞掉）。
    private func concludeFailedSignIn(owner: PrincipalID, epoch: UInt64, primary: Error) async throws -> Never {
        let failure: SessionCleanupFailure?
        if sessionEpoch == epoch {
            failure = await invalidateSession(owner: owner)
        } else {
            failure = await discardOwnSessionArtifacts(principal: owner)
        }
        if let failure { throw failure }
        throw primary
    }

    /// 定点回滚：只清「这一次登录自己写进去的东西」，不碰 `state`、不推进 epoch。
    ///
    /// 删凭证前先 best-effort 打一次 `/api/auth/logout`：本地删掉 token 不等于服务端会话结束，
    /// 留着它就是一条「客户端以为已经作废、实际仍可用人」的活凭证。
    /// owner 指针只在仍指向本次登录时清 —— 指向别人就说明接管已经发生，那不是我们的东西。
    ///
    /// - Returns: 清理失败的分量（顺序与 `SessionLifecycle.cleanUp` 一致）；`nil` = 干净。
    private func discardOwnSessionArtifacts(principal: PrincipalID) async -> SessionCleanupFailure? {
        if let token = try? readSecret(principal, .accessToken) {
            await sendLogoutBestEffort(token: token)
        }
        var failed: [SessionCleanupFailure.Component] = []
        do {
            try secureStore.removeAllSecrets(for: principal)
        } catch {
            failed.append(.credentials)
        }
        if let current = try? activeOwnerStore.loadActiveOwner(), current == principal {
            do {
                try activeOwnerStore.saveActiveOwner(nil)
            } catch {
                if !failed.contains(.ownerData) { failed.append(.ownerData) }
            }
        }
        // 第三个归属面：`lifecycle` 的 activeOwner。绑定那一步（`beginSession`/`switchAccount`）
        // 已经把它指到本次登录身上，而"显式登出发生在在途登录里"这一路取不到 principal ⇒ 没人清它。
        // 不清就是三个面各说一套（状态 `signedOut`、指针 nil、lifecycle 还指着甲）。
        // 同样只清确认仍归本次登录的那一份：指着别人说明接管已发生。
        if await lifecycle.currentOwner() == principal {
            do {
                try await lifecycle.signOut(owner: principal)
            } catch let error as SessionCleanupFailure {
                for component in error.failedComponents where !failed.contains(component) {
                    failed.append(component)
                }
            } catch {
                if !failed.contains(.ownerData) { failed.append(.ownerData) }
            }
        }
        return failed.isEmpty ? nil : SessionCleanupFailure(failedComponents: failed)
    }

    /// 凭证被吊销/不可恢复：清该 owner 本地状态与 owner 指针并转 `signedOut`（清理失败不阻断迁移）。
    ///
    /// 清理失败**返回**给调用方而不被吞掉（R15-4）：状态已经转 `signedOut`，若库里的凭证没删掉，
    /// 用户看不到任何异常，但下一次冷启动可能又"活了回来"。
    @discardableResult
    private func invalidateSession(owner: PrincipalID) async -> SessionCleanupFailure? {
        state = .signedOut
        sessionEpoch &+= 1
        var failed: [SessionCleanupFailure.Component] = []
        do {
            try activeOwnerStore.saveActiveOwner(nil)
        } catch {
            failed.append(.ownerData)
        }
        do {
            try await lifecycle.signOut(owner: owner)
        } catch let error as SessionCleanupFailure {
            for component in error.failedComponents where !failed.contains(component) {
                failed.append(component)
            }
        } catch {
            if !failed.contains(.credentials) { failed.append(.credentials) }
        }
        return failed.isEmpty ? nil : SessionCleanupFailure(failedComponents: failed)
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
