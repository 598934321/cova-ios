import CovaCore
import Foundation

/// 上报挂起原因（未发出，但**幂等键已分配并保留**，可后续以同键补发）。
public enum PlayReportHoldReason: String, Equatable, Sendable, CustomStringConvertible {
    /// 未认证（signed-out / guest）：不静默丢包，挂起待凭证就绪后以同键补发。
    case unauthenticated
    /// 后台转场期间不发起新提交（回前台补发）。
    case backgrounded

    public var description: String {
        switch self {
        case .unauthenticated: return "未认证，上报已挂起"
        case .backgrounded: return "后台态，上报已挂起"
        }
    }
}

/// 抑制原因（本次调用**不应**产生新上报）。
public enum PlayReportSuppression: String, Equatable, Sendable, CustomStringConvertible {
    /// 生成候选私有音频：非曲库曲目，不上报（design/screens/02-player.md §8）。
    case privateCandidate
    /// 同一播放集次已成功上报（pause/resume 复用同一集次，不得二次上报）。
    case alreadyReported
    /// 服务端去重命中（响应 `idempotentReplay == true`）。
    case idempotentReplay
    /// 同一集次已有一路提交在途（补发与在途重叠）：让路，不重复发起写请求。
    case submissionInFlight

    public var description: String {
        switch self {
        case .privateCandidate: return "私有候选音频不上报"
        case .alreadyReported: return "本次播放已上报"
        case .idempotentReplay: return "服务端判定为幂等重放"
        case .submissionInFlight: return "同一集次的提交仍在途，本次补发让路"
        }
    }
}

/// 丢弃原因。
public enum PlayReportDropReason: String, Equatable, Sendable, CustomStringConvertible {
    /// 会话代次已推进（登出/换号）：属于旧会话的在途调用作废。
    case staleGeneration
    case tornDown

    public var description: String {
        switch self {
        case .staleGeneration: return "会话已变更，该调用作废"
        case .tornDown: return "播放器已释放，该调用作废"
        }
    }
}

/// 失败分类（**刻意不携带响应体 / URL / 凭证文本**：分类而非透传，结构上不可能泄漏敏感串）。
public enum PlayReportFailure: String, Equatable, Sendable, CustomStringConvertible {
    case transport
    case unauthorized
    case rejected
    case decoding
    case unknown

    public var description: String { rawValue }

    /// 把任意错误归类为固定枚举。
    public static func classify(_ error: Error) -> PlayReportFailure {
        if let apiError = error as? CovaAPIError {
            switch apiError {
            case .offline, .timeout, .transport, .invalidResponse,
                 .cancelled, .sessionChanged, .credentialReadFailed, .invalidRequestURL:
                return .transport
            case .unauthorized:
                return .unauthorized
            case .httpStatus:
                return .rejected
            case .decoding:
                return .decoding
            }
        }
        if error is CancellationError { return .transport }
        return .unknown
    }
}

/// 上报结果（幂等键随结果回传，便于测试断言「同键复用 / 新键」而不必窥探内部状态）。
public enum PlayReportOutcome: Equatable, Sendable {
    case sent(itemID: String, key: IdempotencyKey)
    case queued(itemID: String, key: IdempotencyKey, reason: PlayReportHoldReason)
    case suppressed(itemID: String, reason: PlayReportSuppression)
    case dropped(itemID: String, reason: PlayReportDropReason)
    case failed(itemID: String, key: IdempotencyKey, reason: PlayReportFailure)

    public var itemID: String {
        switch self {
        case .sent(let id, _), .queued(let id, _, _), .suppressed(let id, _),
             .dropped(let id, _), .failed(let id, _, _):
            return id
        }
    }
}

/// App 生命周期相位（前后台转场共用同一去重态）。
///
/// 刻意不引用 `UIApplication.ScenePhase`：那会拖入 UIKit，违反门禁 3/10 的无 UI 不变量。
public enum PlaybackLifecyclePhase: String, Equatable, Sendable, CaseIterable {
    case active
    case inactive
    case background

    /// 是否允许发起新的网络提交。
    public var allowsSubmission: Bool { self != .background }
}

/// 播放上报的提交面（生产 = `CovaAPIClientPlayReporter`；单测 = 桩，零真实请求）。
public protocol PlayReportSubmitting: Sendable {
    func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto
}

/// 生产实现：`POST /api/tracks/play`。
///
/// 请求体的 `source` 由 `PlayReportSource` 保证落在服务端闭合集内（E2 的修复面），
/// 本类型只负责把它发出去，不决定来源。
public struct CovaAPIClientPlayReporter: PlayReportSubmitting {
    public static let path = "/api/tracks/play"

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) {
        self.client = client
    }

    public func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto {
        try await client.post(Self.path, body: request)
    }
}

/// 播放上报协调器（D8 / api-contracts §5 / TD-19）。
///
/// 语义（完整裁决表见 `docs/log/20260921.md`）：
/// - **一次实际播放 = 一个集次（episode）= 一个幂等键**（键仅在集次创建时生成一次）；
/// - pause/resume 复用同一集次 → `alreadyReported`，不二次上报；
/// - 同一集次的重试（含补发）**复用同一键**（TD-19 由 `IdempotentRequestToken` 类型契约保证）；
/// - 集次结束（播完 / 换曲 / teardown）后同一曲目再次播放 → 新集次 → **新键**；
/// - 私有候选音频一律不上报（design §8）；
/// - 前后台转场共用同一去重态：后台不发起新提交，回前台只补发未决集次（同键）；
/// - 同一集次的提交**已在途**时，补发/重投一律让路（`.submissionInFlight`）：
///   「未决」不等于「可以发」，一次实际播放只允许一个写请求在写（F-C）；
/// - 未认证：分配并保留键 → `.queued(.unauthenticated)`，**不静默丢包**；
/// - generation 推进（登出/换号）：未决集次作废，且不产生任何提交；
/// - **来源标识按集次固定**（E2）：`source` 在集次创建那一刻定下，重试与回前台补发
///   复用同一个值 —— 服务端对同一幂等键还校验 `(trackId, source)` 完全一致，
///   补发时换来源会撞 409 `IDEMPOTENCY_CONFLICT`，等于把一次真实播放记成冲突。
public actor PlayReportCoordinator {
    /// 未决集次的保留上限（超出即丢弃最旧者，防止病态循环撑大内存）。
    public static let maximumPendingEpisodes = 16

    private struct Episode: Equatable {
        let id: UInt64
        let itemID: String
        let token: IdempotentRequestToken
        /// 本次实际播放的归因来源（`PlayReportSource` 保证是服务端认的取值之一）。
        ///
        /// 与 `token` 同级：**集次创建时定、之后不改**，重试与补发都带着它，
        /// 这样「同一幂等键 = 同一次播放」在服务端那句 `(trackId, source)` 比对下也成立。
        let source: PlayReportSource
        var submitted = false
        var attempts = 0
        /// **提交在途标记**（F-C）：此刻是否已有一路 `submit` 挂在这个集次上。
        ///
        /// `submitted` 只在提交**成功返回后**才成立，因此「在途」是第三种事实：
        /// 只看 `!submitted` 的补发（回前台 / 网络恢复 / 同一集次重投）会在重叠窗口里
        /// 把同一次实际播放写成两个请求。标记是**每集次**的，所以不同集次仍可并行提交。
        var inFlight = false
    }

    private let submitter: any PlayReportSubmitting
    private var episodes: [UInt64: Episode] = [:]
    private var activeID: UInt64?
    private var nextEpisodeID: UInt64 = 1
    private(set) var sentKeys: Set<IdempotencyKey> = []
    private var session: PlaybackSessionContext = .unauthenticated
    /// 与 `sentKeys` 同生命周期的账本归属（诊断用）。
    private var boundGenerationOwner: PrincipalID?
    private var phase: PlaybackLifecyclePhase = .active
    private var tornDown = false

    public init(submitter: any PlayReportSubmitting) {
        self.submitter = submitter
    }

    // MARK: - 查询面

    public func pendingCount() -> Int {
        episodes.values.filter { !$0.submitted }.count
    }

    public func activeEpisodeKey() -> IdempotencyKey? {
        guard let activeID, let episode = episodes[activeID] else { return nil }
        return episode.token.key
    }

    public func hasReported(key: IdempotencyKey) -> Bool {
        sentKeys.contains(key)
    }

    public func reportedCount() -> Int { sentKeys.count }

    public func currentPhase() -> PlaybackLifecyclePhase { phase }

    public func currentSession() -> PlaybackSessionContext { session }

    // MARK: - 会话绑定

    /// 绑定会话：仅在**登出 / 换号 / generation 推进**时作废未决上报（D8）。
    ///
    /// 刻意不把 `nil → owner`（登录）当作失效事件：登录前那次「实际播放」确实发生了，
    /// 保留其键才能在凭证就绪后以同一幂等键补发（去重语义不因登录而失真）。
    @discardableResult
    public func bindSession(_ next: PlaybackSessionContext) -> Int {
        guard next != session else { return 0 }
        let isSwitchBetweenAccounts = next.owner != nil && session.owner != nil && next.owner != session.owner
        guard next.generation != session.generation || isSwitchBetweenAccounts || next.owner == nil else {
            session = next
            return 0
        }
        let dropped = invalidateSessions()
        session = next
        return dropped
    }

    /// 会话推进（登出 / 换号）：丢弃全部未决集次，不产生任何提交。
    ///
    /// - Parameter includingSent: 是否连「已成功」的去重账本一并清除。
    ///   默认 `false` —— 保留账本可防止同一集次在竞态下被重投。
    @discardableResult
    public func invalidateSessions(includingSent: Bool = false) -> Int {
        activeID = nil
        boundGenerationOwner = nil
        let dropped = episodes.values.filter { !$0.submitted }.count
        episodes = episodes.filter { $0.value.submitted }
        if includingSent {
            episodes = [:]
            sentKeys = []
        }
        return dropped
    }

    // MARK: - 集次生命周期

    /// 一次**实际播放**开始（引擎进入 playing 时由 `PlaybackCoordinator` 调用；pause/resume 不调用）。
    ///
    /// `source` 默认 `.player`：本层只有唯一播放面，起播语境（广场 / 歌单 / 作品页 / 生成结果）
    /// 只有视图层知道，`PlaybackItem` 与队列刻意不携带来源字段，所以未显式指明时按播放面归因。
    /// 同一集次重入时**首次的取值生效**（一次播放一次归因，换值会撞服务端的键冲突判定）。
    @discardableResult
    public func playbackStarted(
        itemID: String,
        kind: PlaybackItem.Kind,
        session: PlaybackSessionContext,
        source: PlayReportSource = .player
    ) async -> PlayReportOutcome {
        guard !tornDown else { return .dropped(itemID: itemID, reason: .tornDown) }
        guard kind != .privateCandidate else {
            return .suppressed(itemID: itemID, reason: .privateCandidate)
        }
        guard self.session.generation == session.generation else {
            return .dropped(itemID: itemID, reason: .staleGeneration)
        }
        if let activeID, let existing = episodes[activeID], existing.itemID == itemID {
            // 同一集次：复用键（重试 / 误重入）。
            return await deliver(existing)
        }
        if let owner = session.owner { boundGenerationOwner = owner }
        let episode = Episode(
            id: nextEpisodeID, itemID: itemID,
            token: IdempotentRequestToken(operation: .playReport), source: source
        )
        nextEpisodeID &+= 1
        // 换曲隐含「上一集次已结束」：已成功的旧集次只留去重账本，实体释放。
        if let previousID = activeID, episodes[previousID]?.submitted == true {
            episodes[previousID] = nil
        }
        episodes[episode.id] = episode
        activeID = episode.id
        retireOldestIfOverflow()
        return await deliver(episode)
    }

    /// 集次结束（播完 / 换曲 / teardown）：使同一曲目稍后再次播放产生**新键**。
    public func playbackEnded(itemID: String) {
        guard let activeID, let episode = episodes[activeID], episode.itemID == itemID else { return }
        self.activeID = nil
        if episode.submitted { episodes[activeID] = nil }
    }

    /// 前后台转场：共用同一去重态。后台不发起新提交；回前台仅补发未决集次（同键）。
    public func lifecyclePhaseChanged(_ newPhase: PlaybackLifecyclePhase) async -> [PlayReportOutcome] {
        let previous = phase
        phase = newPhase
        guard newPhase.allowsSubmission, previous == .background else { return [] }
        return await retryPending()
    }

    /// 补发全部未决集次（各自**复用原键**）。
    ///
    /// 刻意不在这里过滤「已在途」的集次：判定只住在 `deliver` 一处（唯一咽喉），
    /// 新增补发入口时不可能忘记它 —— 与 F-A/F-1 同一个教训：一条事实分两处判必然分叉。
    @discardableResult
    public func retryPending() async -> [PlayReportOutcome] {
        guard !tornDown, phase.allowsSubmission else { return [] }
        var outcomes: [PlayReportOutcome] = []
        for id in episodes.keys.sorted() {
            guard let episode = episodes[id], !episode.submitted else { continue }
            outcomes.append(await deliver(episode))
        }
        return outcomes
    }

    /// 释放：作废未决集次，拒绝后续任何调用。
    public func teardown() {
        guard !tornDown else { return }
        tornDown = true
        invalidateSessions()
    }

    // MARK: - 内部

    private func retireOldestIfOverflow() {
        let unresolved = episodes.values.filter { !$0.submitted }.sorted { $0.id < $1.id }
        guard unresolved.count > Self.maximumPendingEpisodes else { return }
        for stale in unresolved.prefix(unresolved.count - Self.maximumPendingEpisodes) where stale.id != activeID {
            episodes[stale.id] = nil
        }
    }

    /// 提交一个集次：成功即记账并转入去重账本；失败则保留供**同键**重试。
    ///
    /// **全部提交入口的唯一咽喉**（`playbackStarted` 的复用腿 / `retryPending` / 回前台补发），
    /// 所以「一次实际播放只写一个请求」的在途闸门只写在这里（F-C）：调用方一律不许自己
    /// 判断「是否该发」，否则又多一处各写一份、各漏一处的账（同 F-1/F-2 的病根）。
    private func deliver(_ episode: Episode) async -> PlayReportOutcome {
        var current = episode
        // F-C：同一集次此刻已有一路 `submit` 挂在半路 → 让路，不重复发起写请求。
        // 早退前不动任何账（`attempts` / 集次实体都不改）：在途那一路自己会收尾。
        // 键层面本来就不会破（两路携带同一个键，服务端 `idempotentReplay` 兜得住），
        // 这里保的是 api-contracts §5「一次实际播放 = 一个写请求」的**写放大**口径。
        guard !current.inFlight else {
            return .suppressed(itemID: current.itemID, reason: .submissionInFlight)
        }
        current.attempts += 1
        episodes[current.id] = current
        let key = current.token.key

        guard session.owner != nil else {
            return .queued(itemID: current.itemID, key: key, reason: .unauthenticated)
        }
        guard phase.allowsSubmission else {
            return .queued(itemID: current.itemID, key: key, reason: .backgrounded)
        }
        guard !sentKeys.contains(key) else {
            return .suppressed(itemID: current.itemID, reason: .alreadyReported)
        }
        let request: PlayReportRequestDto
        do {
            // 来源与键同源：都取自**这个集次**，所以补发/重试不会改变一次播放的归因。
            request = try PlayReportRequestDto(
                trackId: current.itemID, source: current.source, token: current.token
            )
        } catch {
            // 键由本类型按 .playReport 生成，理论上不可达；保留 fail-closed 分支。
            return .failed(itemID: current.itemID, key: key, reason: .unknown)
        }
        // 下面唯一的挂起点之前立牌；`defer` 覆盖成功 / 抛错 / `idempotentReplay` 三条返回路径，
        // 漏摘一次就会把这个集次的后续补发永久挡死（比 F-C 更严重）。
        beginSubmission(current)
        defer { endSubmission(id: current.id) }
        do {
            let response = try await submitter.submit(request)
            markSent(current)
            if response.idempotentReplay == true {
                return .suppressed(itemID: current.itemID, reason: .idempotentReplay)
            }
            return .sent(itemID: current.itemID, key: key)
        } catch {
            return .failed(itemID: current.itemID, key: key, reason: PlayReportFailure.classify(error))
        }
    }

    /// 立「在途」牌（F-C）：只标当前集次，不影响其它集次并行提交。
    private func beginSubmission(_ episode: Episode) {
        var flagged = episode
        flagged.inFlight = true
        episodes[flagged.id] = flagged
    }

    /// 摘「在途」牌：集次已被失效面丢弃时无事可做（不得把它写回来）。
    private func endSubmission(id: UInt64) {
        guard var stored = episodes[id], stored.inFlight else { return }
        stored.inFlight = false
        episodes[stored.id] = stored
    }

    private func markSent(_ episode: Episode) {
        var stored = episode
        stored.submitted = true
        sentKeys.insert(stored.token.key)
        episodes[stored.id] = stored
    }
}
