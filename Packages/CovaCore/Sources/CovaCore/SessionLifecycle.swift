import Foundation

/// 登出/换号时需要清理的**本地会话状态**原语（D8 / api-contracts §5）。
///
/// CovaCore 只定义原语；具体实现在 CovaPlayer（播放队列 / 播放器）与缓存层（私有音频/封面）。
/// 方法均为 `async throws`：清理失败必须**可观测**（由 `SessionLifecycle` 聚合上报），
/// 不得静默吞掉。
public protocol LocalSessionStateClearing: Sendable {
    /// 清空播放队列。
    func clearPlayQueue() async throws
    /// 清空指定 owner 的私有音频/封面缓存（以缓存键/目录为单位）。
    func clearPrivateMediaCache(owner: PrincipalID) async throws
    /// 停止并销毁播放器（D8「销毁播放器」），释放音频会话/锁屏控制等资源。
    func tearDownPlayback(owner: PrincipalID) async throws
}

/// 登出/换号清理未全部完成时的聚合错误。
///
/// `SessionLifecycle` 采用 **best-effort**：任一步失败**不短路**其余步骤，
/// 全部尝试后把失败的分量一次性上报。
public struct SessionCleanupFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Component: String, Hashable, Sendable, CaseIterable {
        case credentials
        case ownerData
        case playQueue
        case privateMediaCache
        case playbackTeardown
    }

    public let failedComponents: [Component]

    public init(failedComponents: [Component]) {
        self.failedComponents = failedComponents
    }

    public var description: String {
        "登出/换号清理未全部完成：" + failedComponents.map(\.rawValue).joined(separator: ",")
    }
}

/// 会话生命周期编排（D8）：把「失效在途结果」与「清理本地状态」收敛为两个入口。
///
/// 顺序固定：**先推进 generation**（在途结果立即失效）→ 清凭证 → 清 owner 数据 →
/// 清队列/私有缓存/销毁播放器。清理阶段为 best-effort：任一步失败不阻断其余步骤，
/// 最后以 `SessionCleanupFailure` 聚合上报。
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

    /// 登出：失效在途结果 → best-effort 清该 owner 的凭证、owner 数据、队列、私有缓存、播放器。
    ///
    /// - Throws: 仅当清理有任一分量失败时抛 `SessionCleanupFailure`（其余步骤仍已执行）。
    public func signOut(owner: PrincipalID) async throws {
        await generations.advance()
        let failures = await cleanUp(for: owner)
        if activeOwner == owner {
            activeOwner = nil
        }
        try Self.throwIfCleanupIncomplete(failures)
    }

    /// 换号：清理上一 owner 的全部本地状态并切换 active owner（新 owner 由调用方写入凭证）。
    public func switchAccount(from previousOwner: PrincipalID, to newOwner: PrincipalID) async throws {
        await generations.advance()
        let failures = await cleanUp(for: previousOwner)
        activeOwner = newOwner
        try Self.throwIfCleanupIncomplete(failures)
    }

    /// best-effort 全量清理：每一步独立尝试，失败只记录不短路。
    private func cleanUp(for owner: PrincipalID) async -> [SessionCleanupFailure.Component] {
        var failures: [SessionCleanupFailure.Component] = []
        func record(_ component: SessionCleanupFailure.Component) {
            if !failures.contains(component) {
                failures.append(component)
            }
        }
        do {
            try secureStore.removeAllSecrets(for: owner)
        } catch {
            record(.credentials)
        }
        do {
            try ownerStore.removeAll(owner: owner)
        } catch {
            record(.ownerData)
        }
        for cleaner in cleaners {
            do {
                try await cleaner.clearPlayQueue()
            } catch {
                record(.playQueue)
            }
            do {
                try await cleaner.clearPrivateMediaCache(owner: owner)
            } catch {
                record(.privateMediaCache)
            }
            do {
                try await cleaner.tearDownPlayback(owner: owner)
            } catch {
                record(.playbackTeardown)
            }
        }
        return failures
    }

    private static func throwIfCleanupIncomplete(_ failures: [SessionCleanupFailure.Component]) throws {
        guard failures.isEmpty else {
            throw SessionCleanupFailure(failedComponents: failures)
        }
    }
}
