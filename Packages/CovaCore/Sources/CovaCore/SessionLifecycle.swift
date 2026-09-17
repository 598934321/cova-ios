import Foundation

/// 登出/换号时需要清理的**本地会话状态**原语（D8 / api-contracts §5）。
///
/// CovaCore 只定义原语；具体实现在 CovaPlayer（播放队列）与缓存层（私有音频/封面）。
public protocol LocalSessionStateClearing: Sendable {
    /// 清空播放队列。
    func clearPlayQueue() async
    /// 清空指定 owner 的私有音频/封面缓存（以缓存键/目录为单位）。
    func clearPrivateMediaCache(owner: PrincipalID) async
}

/// 会话生命周期编排（D8）：把「失效在途结果」与「清理本地状态」收敛为两个入口。
///
/// 顺序固定：**先推进 generation**（在途结果立即失效）→ 清凭证 → 清 owner 数据 → 清队列/缓存。
/// 这样即使后续清理抛错，旧 generation 的结果也不会再被写回。
public actor SessionLifecycle {
    private let secureStore: any SecureStore
    private let ownerStore: any OwnerScopedStoring
    private let cleaners: [any LocalSessionStateClearing]
    private let generations: SessionGenerationTracker
    private var activeOwner: PrincipalID?

    public init(
        secureStore: any SecureStore,
        ownerStore: any OwnerScopedStoring,
        cleaners: [any LocalSessionStateClearing] = []
    ) {
        self.secureStore = secureStore
        self.ownerStore = ownerStore
        self.cleaners = cleaners
        self.generations = SessionGenerationTracker()
    }

    /// 当前 generation。
    public func currentGeneration() async -> SessionGeneration {
        await generations.snapshot()
    }

    /// 当前 active owner（未登录为 nil）。
    public func currentOwner() -> PrincipalID? {
        activeOwner
    }

    /// 在途结果是否仍属于当前会话。
    public func isCurrent(_ generation: SessionGeneration) async -> Bool {
        await generations.isCurrent(generation)
    }

    /// 校验在途结果；过期即抛 `StaleSessionError`。
    public func validate(_ generation: SessionGeneration) async throws {
        try await generations.validate(generation)
    }

    /// 开始新 owner 的会话：推进 generation（旧在途结果失效）并记录 active owner。
    ///
    /// - Returns: 新会话的 generation（调用方应在异步请求上携带它）。
    @discardableResult
    public func beginSession(owner: PrincipalID) async -> SessionGeneration {
        activeOwner = owner
        return await generations.advance()
    }

    /// 登出：失效在途结果 → 清该 owner 的凭证与 owner 数据 → 清队列与该 owner 的私有缓存。
    public func signOut(owner: PrincipalID) async throws {
        await generations.advance()
        try secureStore.removeAllSecrets(for: owner)
        try ownerStore.removeAll(owner: owner)
        await clearLocalState(for: owner)
        if activeOwner == owner {
            activeOwner = nil
        }
    }

    /// 换号：清理上一 owner 的全部本地状态并切换 active owner（新 owner 由调用方写入凭证）。
    public func switchAccount(from previousOwner: PrincipalID, to newOwner: PrincipalID) async throws {
        await generations.advance()
        try secureStore.removeAllSecrets(for: previousOwner)
        try ownerStore.removeAll(owner: previousOwner)
        await clearLocalState(for: previousOwner)
        activeOwner = newOwner
    }

    private func clearLocalState(for owner: PrincipalID) async {
        for cleaner in cleaners {
            await cleaner.clearPlayQueue()
            await cleaner.clearPrivateMediaCache(owner: owner)
        }
    }
}
