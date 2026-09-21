import CovaCore
import Foundation

/// 播放状态（由 coordinator 归约，不由 UI 猜测）。
public enum PlaybackState: String, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    /// 无队列 / 未选曲。
    case idle
    /// 正在装载当前项（含私有音频本地化中）。
    ///
    /// **不变量（F-7）**：`.loading` ⟺ `inFlightLoad != nil`，即「确有一次装载跨在挂起点」。
    /// 整队替换、清队列、释放都不再打 `.loading`（它们只是「待播」，没有任何装载在途），
    /// 于是「装载态」重新成为一个可采信的归因判据。
    case loading
    case playing
    case paused
    case buffering
    /// 停止：`.off` 播完队列尾，或连续失败达上限，或队列清空。
    case stopped

    /// 是否处于「可继续接受播放请求」的非终态。
    public var allowsPlaybackRequest: Bool { self != .stopped }

    public var description: String { rawValue }
}

/// 播放会话上下文（D8：owner + generation 绑定，防跨账号串号与在途结果误用）。
public struct PlaybackSessionContext: Equatable, Sendable {
    /// `nil` = 未认证（signed-out / guest）：私有音频取不回、上报挂起而非丢弃。
    public let owner: PrincipalID?
    public let generation: SessionGeneration

    public init(owner: PrincipalID?, generation: SessionGeneration = .initial) {
        self.owner = owner
        self.generation = generation
    }

    public static let unauthenticated = PlaybackSessionContext(owner: nil)
}

/// 播放快照（UI 唯一读取面；不含任何可持久化的敏感地址）。
public struct PlaybackSnapshot: Equatable, Sendable {
    public var state: PlaybackState
    public var item: PlaybackItem?
    public var index: Int?
    public var queueCount: Int
    public var loopMode: LoopMode
    public var position: Double
    /// 未知时长为 nil（±15s 的钳制口径依赖它）。
    public var duration: Double?
    public var playbackRate: Double
    public var failureStreak: Int
    /// **回显账**：最近一次失败记录，含 `.cancelled` / `.staleSession` 这类**不计数**形态
    /// （口径见 `hasCountedFailureLedger` 与 `isFailureTerminal`）。它只回答「上一次坏在哪」，
    /// 不参与任何裁决：终态、跳曲、连击全都只看 `failureStreak` 那一本账（MAJ-R6-1）。
    public var lastFailure: PlayerFailure?
    /// 自动推进已停止的终态。两个来源（详见 `docs/log/20260921.md` §5.1 环 4 新规则）：
    /// ① 连续失败达上限；② 失败后队列已无可跳目标，**且引擎里没有装载当前项**（守卫腿 (b)）。
    ///
    /// 两者都以「**计数侧**先有失败」为前提：`failureStreak == 0` 而本字段为 true 就是谎报
    /// （F-A / MAJ-R5-1 / MAJ-R6-1 —— 腿 (b) 的成立条件与「有没有失败」互不蕴含，
    /// 故「从未装载」「装载在途」这类正常形态一律落在 `.held`，见 `hasCountedFailureLedger`）。
    ///
    /// **「先有失败」只有一个来源，就是 `failureStreak`（裁决账）**。本快照里的
    /// `lastFailure` 是**回显账**：「最近一次失败记录」，包含 `.cancelled` / `.staleSession`
    /// 这类 `countsTowardFailureStreak == false` 的形态，只供 UI 提示（design §9「停止并提示」
    /// 的提示面）与诊断，**不具备开终态的资格**（MAJ-R6-1：把回显当账，一次被取消的装载
    /// 就能重新造出「没有失败却进失败终态」）。
    /// 用户的良性动作（暂停中按 ⏭）永远不进终态。
    /// 失效面（登出 / 换号 / `teardown`）会连同失败账一并清除（F-B）。
    public var isFailureTerminal: Bool
    /// 播放器是否已永久释放（`teardown()` 之后恒真且不可复位，缺陷 P3 / F-B）。
    ///
    /// UI 必须靠它区分「空闲待播」（`state == .idle`、还能起播）与
    /// 「播放器已释放」（任何请求都会被拒），否则会把已死的播放器渲染成「失败已停止」。
    public var tornDown: Bool
    public var session: PlaybackSessionContext

    public init(
        state: PlaybackState = .idle,
        item: PlaybackItem? = nil,
        index: Int? = nil,
        queueCount: Int = 0,
        loopMode: LoopMode = .off,
        position: Double = 0,
        duration: Double? = nil,
        playbackRate: Double = 1,
        failureStreak: Int = 0,
        lastFailure: PlayerFailure? = nil,
        isFailureTerminal: Bool = false,
        tornDown: Bool = false,
        session: PlaybackSessionContext = .unauthenticated
    ) {
        self.state = state
        self.item = item
        self.index = index
        self.queueCount = queueCount
        self.loopMode = loopMode
        self.position = position
        self.duration = duration
        self.playbackRate = playbackRate
        self.failureStreak = failureStreak
        self.lastFailure = lastFailure
        self.isFailureTerminal = isFailureTerminal
        self.tornDown = tornDown
        self.session = session
    }

    /// 时长是否已知（有限且为正）。
    public var hasKnownDuration: Bool { duration != nil }
}

/// 推进结果（`next` / `previous` / 播完自动推进 / seek 落到末尾 共用）。
public enum AdvanceOutcome: Equatable, Sendable {
    case advanced(to: Int, item: PlaybackItem, wrapped: Bool)
    /// `.one` 播完：不换曲，回到 0 继续。
    case repeated(at: Int, item: PlaybackItem)
    /// `.off` 末项播完：进入停止态，不 wrap。
    case stopped
    /// 边界保持（`.off`/`.one` 下显式越过首尾，或 F-A：回绕只能落回当前项而用户此刻不想听）。
    /// 共同点：什么都没发生 —— 不换曲、不动位置、不记失败、不进终态。
    case held
    case rejected(AdvanceRejection)
}

public enum AdvanceRejection: String, Equatable, Sendable, CustomStringConvertible {
    case emptyQueue
    case noCurrentItem
    /// 播放器已释放：不得再被「起播 / 续播」复活（与 `SeekRejection.tornDown` 同口径）。
    case tornDown

    public var description: String {
        switch self {
        case .emptyQueue: return "队列为空"
        case .noCurrentItem: return "队列有项但尚未选定当前项"
        case .tornDown: return "播放器已释放"
        }
    }
}

/// ±15s 结果。
public enum SeekClamp: String, Equatable, Sendable {
    case none
    /// 越过 0，已钳到 0。
    case lowerBound
    /// 越过 duration，已钳到 duration。
    case upperBound
    /// 时长未知：只钳下界，允许上界越界（由引擎/后到的 duration 纠正）。
    case durationUnknown
}

public enum SeekRejection: String, Equatable, Sendable, CustomStringConvertible {
    /// 没有可跳转的当前项，**或**当前项尚未进引擎（装载在途 / 引擎里仍是旧条目）。
    ///
    /// 两种情形对锁屏的答复相同（「此刻无从跳转」）：`NowPlayingStatusMapping` 把它映射成
    /// `.noSuchContent`。刻意不复用 `.tornDown`（那是「播放器已释放」的终态，语义更重）。
    /// 想再细分需要一个 `.notLoaded` 分支，但那会打破 `NowPlayingController.swift` 里
    /// 对 `SeekRejection` 的穷尽 switch（不属本组所有权），故按现状收敛（见日志 F-5 段）。
    case noCurrentItem
    case nonFiniteTarget
    case tornDown

    public var description: String {
        switch self {
        case .noCurrentItem: return "无当前播放项，跳转已拒绝"
        case .nonFiniteTarget: return "跳转目标不是有限数值"
        case .tornDown: return "播放器已释放"
        }
    }
}

public enum SeekOutcome: Equatable, Sendable {
    /// `then` 非 nil 表示目标落在 duration 上，已按「播完」规则继续处理（裁决表）。
    case applied(position: Double, clamped: SeekClamp, then: AdvanceOutcome?)
    case rejected(SeekRejection)
}

/// 跳转钳制（纯函数，`PlaybackCoordinator` 的唯一算术入口）。
///
/// 规则（详见 `docs/log/20260921.md` 裁决表）：
/// 1. 下界恒为 0（已在 0 再退 → 停在 0，绝不外溢为负）；
/// 2. `duration` 已知（有限且 > 0）→ 上界钳到 duration；
/// 3. `duration` 未知 → 只钳下界，允许越界，后到的 duration / 引擎自纠正；
/// 4. 非有限目标 → 拒绝（不产生 NaN 污染状态）。
public enum SeekArithmetic {
    public static func clamp(target raw: Double, duration: Double?) -> ClampedPosition? {
        guard raw.isFinite else { return nil }
        guard let duration, duration.isFinite, duration > 0 else {
            // 时长未知：只钳下界，允许上界越界（由引擎 / 后到的 duration 纠正）。
            if raw < 0 { return ClampedPosition(position: 0, clamp: .lowerBound) }
            return ClampedPosition(position: raw, clamp: .durationUnknown)
        }
        if raw < 0 { return ClampedPosition(position: 0, clamp: .lowerBound) }
        if raw > duration { return ClampedPosition(position: duration, clamp: .upperBound) }
        return ClampedPosition(position: raw, clamp: .none)
    }
}

/// 钳制结果（可等值断言的值类型）。
public struct ClampedPosition: Equatable, Sendable {
    public let position: Double
    public let clamp: SeekClamp

    public init(position: Double, clamp: SeekClamp) {
        self.position = position
        self.clamp = clamp
    }
}

/// 播放协调器：队列 + 循环三态 + ±15s + 失败连击 + 事件归约 + 生命周期。
///
/// **不 import AVFoundation**（D3 分层 + 门禁 3/10）：引擎经 `PlayerEngine` 注入，
/// 时间经 `CovaClock` 注入，于是全部决策路径可在无音频硬件、零网络下确定性测试。
public actor PlaybackCoordinator {
    public struct Configuration: Equatable, Sendable {
        /// ±15s 的步长（design/screens/02-player.md §4）。
        public var seekStep: Double
        /// 连续失败上限（design §9「连续 3 次失败停止并提示」）。
        public var consecutiveFailureLimit: Int
        /// Now Playing 时间信息的节流间隔（元数据变更不受节流影响）。
        public var nowPlayingTimeSyncInterval: TimeInterval
        public static let `default` = Configuration(seekStep: 15, consecutiveFailureLimit: 3, nowPlayingTimeSyncInterval: 1)

        public init(seekStep: Double, consecutiveFailureLimit: Int, nowPlayingTimeSyncInterval: TimeInterval) {
            self.seekStep = seekStep
            self.consecutiveFailureLimit = consecutiveFailureLimit
            self.nowPlayingTimeSyncInterval = nowPlayingTimeSyncInterval
        }
    }

    // MARK: - 依赖

    private let engine: any PlayerEngine
    private let clock: any CovaClock
    private let configuration: Configuration
    private var reporter: PlayReportCoordinator?
    private var nowPlaying: (any NowPlayingControlling)?
    private var sourcePreparer: (any PlaybackSourcePreparing)?

    // MARK: - 状态

    private var queue = PlayQueue()
    private var state: PlaybackState = .idle
    private var loopMode: LoopMode = .off
    private var position: Double = 0
    private var duration: Double?
    private var playbackRate: Double = 1
    private var failureStreak: Int = 0
    private var lastFailure: PlayerFailure?
    private var isFailureTerminal: Bool = false
    private var session: PlaybackSessionContext = .unauthenticated
    private var eventTask: Task<Void, Never>?
    private var lastTimeSyncStamp: TimeInterval?
    /// 当前播放集次（episode）已尝试上报的曲目 id；换曲/播完时清空。
    private var reportedEpisodeItemID: String?
    private var tornDown = false
    /// **装载代际**：每次 `loadCurrent` 递增（`teardown` 也递增，用于作废在途装载）。
    ///
    /// 装载要跨 `prepareSource` / `engine.load` 两个挂起点，期间 actor 是可重入的
    /// （用户此刻完全可能 skip / 释放）。回写前比对代际，过期一律整条丢弃 ——
    /// 否则迟到的装载会把引擎与状态覆盖回旧条目（缺陷 P2）。
    private var loadGeneration: UInt64 = 0
    /// 引擎里**实际**装载着哪一项（`engine.load` 真正返回、且当代未被取代时才记账）。
    ///
    /// 这是「状态 = `.playing`」的必要条件（缺陷 P1/P1b：装载失败后队列回绕到同一坏项，
    /// 旧实现据此声称正在播，而引擎里根本没有条目）。
    private var engineEpisodeItemID: String?
    /// **用户意图**（守卫条件 (c)）：`true` = 用户此刻要听当前项。
    ///
    /// 只有 `pause()` / 进入失败终态 / 释放 / 整队换代才置 `false`，`start` / `resume` /
    /// 推进装载置 `true`。装载续体据此决定「声称 `.playing`」还是「落在 `.paused`」——
    /// 引擎的就绪上报不得翻回播放（缺陷 M10 的装载侧，F-1）。
    private var userWantsPlayback = false
    /// **在途装载台账**（守卫条件 (a)(b) 的载体）。
    ///
    /// `nil` = 此刻没有任何装载在途（于是 `state == .loading` 只会出现在真正装载在途时，
    /// F-7 的口径）；非 nil 时 `handedToEngine` 区分「还在准备源」与「已交给引擎」：
    /// 引擎从未见过当前条目时，它上报的一切（含 `.failed`）都属于**已被取代的那一件**（F-2）。
    private struct InFlightLoad {
        let generation: UInt64
        /// 已调用 `engine.load`（引擎此刻装着的就是当代条目 → 它的上报可归因到当代）。
        var handedToEngine = false
        /// 装载在途期间引擎上报的失败：契约「load 失败经 `.failed` 表达」的落点，
        /// 由当代装载续体消费，绝不让它把状态写成 `.playing`（F-8）。
        var failure: PlayerFailure?
    }
    private var inFlightLoad: InFlightLoad?

    public init(
        engine: any PlayerEngine,
        clock: any CovaClock = SystemClock(),
        configuration: Configuration = .default,
        reporter: PlayReportCoordinator? = nil,
        nowPlaying: (any NowPlayingControlling)? = nil,
        sourcePreparer: (any PlaybackSourcePreparing)? = nil
    ) {
        self.engine = engine
        self.clock = clock
        self.configuration = configuration
        self.reporter = reporter
        self.nowPlaying = nowPlaying
        self.sourcePreparer = sourcePreparer
    }

    /// 运行期接回协作者（facade 需要先把 coordinator 建出来才能注入自己）。
    public func injectCollaborators(
        reporter: PlayReportCoordinator?,
        nowPlaying: (any NowPlayingControlling)?,
        sourcePreparer: (any PlaybackSourcePreparing)?
    ) {
        if let reporter { self.reporter = reporter }
        if let nowPlaying { self.nowPlaying = nowPlaying }
        if let sourcePreparer { self.sourcePreparer = sourcePreparer }
    }

    // MARK: - 快照与绑定

    public func currentSnapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            state: state,
            item: queue.current,
            index: queue.currentIndex,
            queueCount: queue.count,
            loopMode: loopMode,
            position: position,
            duration: duration,
            playbackRate: playbackRate,
            failureStreak: failureStreak,
            lastFailure: lastFailure,
            isFailureTerminal: isFailureTerminal,
            tornDown: tornDown,
            session: session
        )
    }

    /// 绑定/切换会话（D8）：generation 推进时丢弃未决上报、清私有音频、停播放。
    /// teardown 后拒绝（R3）：已释放的播放器不再接受任何状态变更。
    public func bindSession(_ context: PlaybackSessionContext) async {
        guard !tornDown else { return }
        guard context != session else { return }
        let previous = session
        session = context
        // 失效面（D8）：登出 / 换号（两个已认证身份之间）/ generation 推进 —— 不含「登录」。
        let switchedAccounts = context.owner != nil && previous.owner != nil && context.owner != previous.owner
        if previous.generation != context.generation || switchedAccounts || context.owner == nil {
            await discardPendingReports()
            engine.stopAndRelease()
            // `clearQueueAndStop` 内已作废在途装载台账（守卫 (a)）。
            await clearQueueAndStop()
        }
        // 上报器共用同一会话视图：未认证 → 挂起；登出/换号 → 丢弃未决。
        await reporter?.bindSession(context)
    }

    public func sessionGeneration() -> SessionGeneration { session.generation }

    // MARK: - 队列
    //
    // **teardown 是终态**（缺陷 P3）：本区块每个变更入口都以 `guard !tornDown` 开头，
    // 拒绝时不改队列、不改状态、不驱动引擎、不发布锁屏元数据，并返回 `.rejected(.tornDown)`。

    /// 整队替换（进入加载态，不自动播放；播放由 `start` / `resume` 决定）。
    @discardableResult
    public func replaceQueue(_ items: [PlaybackItem], startingAt start: Int = 0) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        await closeEpisodeIfNeeded()
        let change = queue.replace(items, startingAt: start)
        // 队列整队换了 → 在途装载全部作废，且新当前项尚未进引擎（R1 / R2 账本）。
        invalidateInFlightLoad()
        resetItemTimingState()
        // **`replaceQueue` 不自动播放**（既有裁决）：意图落在「暂停」侧，否则任何一次
        // 整队替换都会在 `loadCurrent` 里被当成「用户要听」而擅自起播。
        userWantsPlayback = false
        // F-7 的诚实口径：整队替换后**没有任何装载在途**，因此 `.loading`（= 正在装载当前项）
        // 是谎报；引擎里也没有可播的东西，状态只能是「已选曲、待播」。
        state = queue.current == nil ? .idle : .paused
        await publishNowPlaying(force: true)
        return change
    }

    @discardableResult
    public func appendToQueue(_ item: PlaybackItem) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        let change = queue.append(item)
        await publishNowPlaying(force: false)
        return change
    }

    @discardableResult
    public func insertNext(_ item: PlaybackItem) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        let change = queue.insertNext(item)
        await publishNowPlaying(force: false)
        return change
    }

    /// 拖拽排序（当前曲目身份保持不变）。
    @discardableResult
    public func reorder(from: Int, to destination: Int) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        return queue.move(from: from, to: destination)
    }

    /// 移除队列项；移除的是当前项时按裁决表处理（保持播放意图，换到同位置的新项）。
    @discardableResult
    public func removeItem(at index: Int) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        let wasCurrent = queue.currentIndex == index
        let wasPlaying = state == .playing || state == .buffering || state == .loading
        let change = queue.remove(at: index)
        guard wasCurrent, case .applied(let effect) = change else { return change }
        // 被移除的正是「装载在途的那一件」→ 整条在途装载作废：它回来时既不得回写引擎、
        // 也不得把已被删掉的曲目声称成正在播（守卫 (a) 的另一半：换代必须推进台账）。
        invalidateInFlightLoad()
        await closeEpisodeIfNeeded()
        switch effect {
        case .removed(_, _, let current):
            guard current != nil else {
                state = .stopped
                duration = nil
                position = 0
                engine.stopAndRelease()
                await publishNowPlaying(force: true)
                return change
            }
            if wasPlaying {
                await loadCurrent(autoplay: true)
            } else {
                resetItemTimingState()
                // 引擎里装着的是**被删掉的那一项**：从现在起没有当前项被装载（R1 账本）。
                await publishNowPlaying(force: true)
            }
        default:
            break
        }
        return change
    }

    @discardableResult
    public func removeItem(itemID: String) async -> PlayQueue.Change {
        guard !tornDown else { return .rejected(.tornDown) }
        guard let index = queue.index(ofItemID: itemID) else {
            return .rejected(.unknownItem)
        }
        return await removeItem(at: index)
    }

    public func containsItem(itemID: String) -> Bool {
        queue.contains(itemID: itemID)
    }

    /// 是否存在当前项（远端命令的 `noSuchContent` 判据）。
    public func hasCurrentItem() -> Bool {
        queue.current != nil
    }

    public func queueItems() -> [PlaybackItem] {
        queue.items
    }

    // MARK: - 传输控制

    /// 从指定索引开始播放整队（M1 的入口：点一行 / 点播放）。
    public func start(items: [PlaybackItem], at index: Int = 0) async -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        await replaceQueue(items, startingAt: index)
        guard queue.current != nil else { return .rejected(.emptyQueue) }
        return await beginCurrentIndex()
    }

    /// 在既有队列上从指定索引开始播（锁屏 ⏯ 与列表点击共用）。
    public func start(at index: Int) async -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        _ = await replaceQueue(queue.items, startingAt: index)
        guard queue.current != nil else { return .rejected(.emptyQueue) }
        return await beginCurrentIndex()
    }

    /// 播放当前项（idle/paused 下请求播放；stopped 下重新从头播当前项）。
    public func start() async -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        guard queue.current != nil else { return .rejected(.emptyQueue) }
        return await beginCurrentIndex()
    }

    private func beginCurrentIndex() async -> AdvanceOutcome {
        guard queue.current != nil, queue.currentIndex != nil else {
            state = .idle
            return .rejected(.emptyQueue)
        }
        isFailureTerminal = false
        failureStreak = 0
        lastFailure = nil
        // 用户显式起播 = 意图成立（守卫条件 (c) 的置位点）。
        userWantsPlayback = true
        await loadCurrent(autoplay: true)
        // 装载可能已被取代（用户中途换曲 / 暂停 / 已释放）→ 结果按**当下真实落点**报告，
        // 不回吐在途前捕获的那一项（缺陷 P2 的「结果谎报」面 + F-4 的「终态谎报」）。
        return advanceOutcome(wrapped: false)
    }

    /// 推进结果的**自洽投影**（F-3 / F-4）：`to:` 与 `item:` 取自**同一时刻**的队列快照，
    /// 且状态已收敛为停止 / 终态时绝不回吐 `.advanced`。
    ///
    /// `loadCurrent` 跨多个挂起点，返回时队列可能已被用户换掉、也可能整条链已失败收敛；
    /// 在途期间捕获的索引只是历史事实，不能当作「此刻落在哪」的答案交给 UI 与锁屏
    /// （`NowPlayingStatusMapping` 把 `.advanced` 一律映射成 `.success`，落点错了就是高亮错行）。
    private func advanceOutcome(wrapped: Bool) -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        // `index` 与 `item` 必须来自**同一时刻**的队列投影：本函数非 async，两次读取之间
        // 没有挂起点，actor 不可能被重入 —— 于是 `item` 必然就躺在 `index` 上。
        // （F-3 的病根正是「step 捕获的旧索引」+「await 之后重读的当前项」拼成一个不存在的落点。）
        guard let index = queue.currentIndex, let item = queue.current else {
            return .rejected(.emptyQueue)
        }
        switch state {
        case .stopped:
            // 装载链已收敛为停止（失败终态 / 末项播完）：如实回 `.stopped`。
            return .stopped
        case .idle:
            return .rejected(.emptyQueue)
        case .playing, .paused, .buffering, .loading:
            return .advanced(to: index, item: item, wrapped: wrapped)
        }
    }

    public func pause() async {
        guard !tornDown else { return }
        // F-1：显式暂停**先**落意图，再动状态机 —— 在途装载的续体据此选择 `.paused`，
        // 而不是无条件声称 `.playing`。
        userWantsPlayback = false
        guard state == .playing || state == .buffering || state == .loading else {
            await engine.pause()
            return
        }
        state = .paused
        await engine.pause()
        await publishNowPlaying(force: true)
    }

    /// 恢复播放。stopped 态下 = 从 0 重新播当前项（恢复条件，见裁决表）。
    public func resume() async {
        guard !tornDown else { return }
        guard queue.current != nil else { return }
        // 用户显式续播 = 意图成立（守卫条件 (c) 的置位点）。
        userWantsPlayback = true
        if state == .stopped || isFailureTerminal {
            isFailureTerminal = false
            failureStreak = 0
            lastFailure = nil
            await loadCurrent(autoplay: true)
            return
        }
        guard engineEpisodeItemID == queue.current?.id else {
            // 引擎里没有当前项（刚换过队列 / 上一轮装载失败 / 移除过当前曲）→
            // 「恢复」必须是真装载，而不是命令引擎出声（R1，缺陷 P1 的同族）。
            await loadCurrent(autoplay: true)
            return
        }
        state = .playing
        await engine.play()
        await engine.setRate(playbackRate)
        await reportEpisodeIfNeeded()
        await publishNowPlaying(force: true)
    }

    /// 播放/暂停切换（锁屏 togglePlayPause 与 UI 中央钮共用）。
    public func toggle() async -> PlaybackState {
        if state == .playing || state == .buffering {
            await pause()
        } else {
            await resume()
        }
        return state
    }

    public func next() async -> AdvanceOutcome {
        await advance(direction: .forward, trigger: .userInitiated)
    }

    public func previous() async -> AdvanceOutcome {
        await advance(direction: .backward, trigger: .userInitiated)
    }

    /// 循环三态设置（`Codable`，可持久化 —— 模式不是敏感信息）。
    /// teardown 后拒绝：释放的播放器不接受任何状态变更（缺陷 P3）。
    @discardableResult
    public func setLoopMode(_ mode: LoopMode) async -> LoopMode {
        guard !tornDown else { return loopMode }
        loopMode = mode
        await publishNowPlaying(force: false)
        return mode
    }

    /// UI 循环按钮：off → all → one → off。
    @discardableResult
    public func cycleLoopMode() async -> LoopMode {
        guard !tornDown else { return loopMode }
        return await setLoopMode(loopMode.advanced())
    }

    public func currentLoopMode() -> LoopMode { loopMode }

    @discardableResult
    public func setPlaybackRate(_ rate: Double) async -> Double {
        guard !tornDown else { return playbackRate }
        guard rate.isFinite, rate > 0 else { return playbackRate }
        playbackRate = min(max(rate, 0.5), 2)
        await engine.setRate(playbackRate)
        await publishNowPlaying(force: true)
        return playbackRate
    }

    // MARK: - ±15s 与 seek

    public func seekBySeconds(_ delta: Double) async -> SeekOutcome {
        await seek(toTarget: position + delta)
    }

    public func seek(to target: Double) async -> SeekOutcome {
        await seek(toTarget: target)
    }

    private func seek(toTarget raw: Double) async -> SeekOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        guard let claimed = queue.current?.id else { return .rejected(.noCurrentItem) }
        // F-5：seek 与「声称播放」共用同一条续体守卫 —— 装载在途时引擎里装的还是**旧条目**，
        // 把跳转写进去既打错对象又让快照谎报进度（`position = 42` 而引擎从 0 起播）。
        // 此处不要求播放意图：暂停中拖进度条是正常操作。
        guard continuationIsCurrent(
            generation: nil, claimingEngineItem: claimed, requiresPlaybackIntent: false
        ) else { return .rejected(.noCurrentItem) }
        guard let result = SeekArithmetic.clamp(target: raw, duration: effectiveDuration) else {
            return .rejected(.nonFiniteTarget)
        }
        position = result.position
        await engine.seek(to: result.position)
        await publishNowPlaying(force: true)
        guard result.clamp == .upperBound, let total = effectiveDuration else {
            return .applied(position: result.position, clamped: result.clamp, then: nil)
        }
        // 落在 duration 上：等同「播完」，按循环三态继续（design §3 拖到尾部）。
        let advance = await handleItemEnded()
        return .applied(position: total, clamped: .upperBound, then: advance)
    }

    // MARK: - 事件归约（引擎 → 状态）

    /// 归约一条引擎事件。公开以便**零竞态**单测：测试直接投递事件序列并断言状态。
    ///
    /// **每个分支都先过 `continuationIsCurrent`**（环 4 R9）：引擎事件不带曲目身份，
    /// 迟到的上报只能靠「代际 + 引擎账本 + 用户意图」三条判据归因，不得凭「事件来了」
    /// 就改状态（F-2：一次 skip 被迟到的失败跳成两首，且连击扣到新曲头上）。
    public func receive(_ event: PlayerEvent) async {
        guard !tornDown else { return }
        switch event {
        case .playing:
            // M10：`.playing` 是引擎的「就绪 / 缓冲恢复」类上报，不是用户意图。
            // 采信条件（F-1 起改为「装载侧同一把守卫」）：
            //   ① 没有装载在途 —— 在途期间引擎里是旧条目，它说什么都不能翻成播放；
            //   ② 引擎里确实装载着当前项（R1：状态不得超出实际装载）；
            //   ③ 用户此刻要听（显式暂停、失败终态之后不得被引擎悄悄翻回播放，
            //      否则锁屏会发布 isPlaying=true）；
            //   ④ 当前本就处于「在播 / 缓冲 / 装载」三态之一。
            guard state == .playing || state == .buffering || state == .loading else { return }
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: queue.current?.id, requiresPlaybackIntent: true
            ) else { return }
            state = .playing
            failureStreak = 0
            lastFailure = nil
            isFailureTerminal = false
            await reportEpisodeIfNeeded()
            await publishNowPlaying(force: true)
        case .paused:
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: queue.current?.id, requiresPlaybackIntent: false
            ) else { return }
            if state == .playing { state = .paused }
            await publishNowPlaying(force: true)
        case .buffering:
            guard state == .playing else { return }
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: queue.current?.id, requiresPlaybackIntent: true
            ) else { return }
            state = .buffering
            await publishNowPlaying(force: false)
        case .position(let seconds):
            // 迟到的位置上报不得挪动新集次的进度条（引擎侧 `EngineEventGate` 是第一道，
            // 这里是决策层的第二道：引擎从未被交给当前项时一律丢弃）。
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: queue.current?.id,
                kind: .observation, requiresPlaybackIntent: false
            ) else { return }
            applyEnginePosition(seconds)
            await publishNowPlaying(force: false)
        case .duration(let seconds):
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: queue.current?.id,
                kind: .observation, requiresPlaybackIntent: false
            ) else { return }
            await applyEngineDuration(seconds)
            await publishNowPlaying(force: true)
        case .ended:
            _ = await handleItemEnded()
        case .failed(let failure):
            // F-2 / F-8：先归因，再记账。归因到「当代装载在途且已交给引擎」的失败由
            // 装载续体消费（它才知道该条目到底有没有真的进引擎）。
            guard failureIsAttributableToCurrentEpisode(failure) else { return }
            if var inFlight = inFlightLoad, inFlight.generation == loadGeneration,
               inFlight.handedToEngine, engineEpisodeItemID == nil {
                inFlight.failure = failure
                self.inFlightLoad = inFlight
                return
            }
            await handleFailure(failure)
        }
    }

    /// 启动引擎事件消费循环（幂等）。
    public func attach() {
        guard eventTask == nil, !tornDown else { return }
        let engine = self.engine
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
    }

    public func detachFromEngine() {
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - 生命周期

    /// 释放：停引擎、清 Now Playing、取消未决上报与下载、清队列。
    ///
    /// **终态**：`tornDown` 一旦置位就不复位，之后所有变更入口一律拒绝（缺陷 P3 的裁决）；
    /// 同时推进装载代际，让在途装载回来时自行丢弃。
    /// 失效面（F-B）与登出走同一个收敛点 `clearQueueAndStop()` —— 队列、时间账、**失败账**
    /// 一起作废，快照只剩 `state == .idle` + `tornDown == true` 可表达「播放器已释放」。
    public func teardown() async {
        guard !tornDown else { return }
        tornDown = true
        invalidateInFlightLoad()
        detachFromEngine()
        await closeEpisodeIfNeeded()
        await discardPendingReports()
        engine.stopAndRelease()
        await nowPlaying?.teardown()
        await clearQueueAndStop()
        state = .idle
        position = 0
        duration = nil
    }

    public var isTornDown: Bool { tornDown }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - 内部：推进与失败

    private func advance(direction: PlayQueue.Direction, trigger: PlayQueue.Trigger) async -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        let step = queue.step(direction: direction, trigger: trigger, under: loopMode)
        return await apply(step)
    }

    private func apply(_ step: PlayQueue.Step) async -> AdvanceOutcome {
        queue.apply(step)
        switch step {
        case .moved(_, let wrapped):
            await closeEpisodeIfNeeded()
            await loadCurrent(autoplay: true)
            // `.moved` 携带的索引只是 step 计算那一刻的事实：装载期间用户可能又换了曲，
            // 失败链也可能已经走得更远（F-3）。落点一律按**当下队列**投影。
            return advanceOutcome(wrapped: wrapped)
        case .repeated:
            // 引擎账本 + 用户意图都要过守卫（R1 / F-6），但**每条腿的收敛结果必须分离**
            // （F-A 修了腿 (c)，MAJ-R5-1 补上腿 (b)，MAJ-R6-1 把「有没有失败」定在计数侧）：
            //   · (b) 引擎归属不成立**且计数侧有账** → 「重播当前项」是无中生有，且确实
            //     发生过故障 → 收敛为「停止 + 失败终态」，等用户处置；
            //   · (b) 不成立而计数侧无账（含「只有一次不计数的取消」）/ (c) 意图不成立
            //     → 什么都没坏 → 边界保持（位置、引擎账本、状态、失败账一律不动）。
            // 旧实现把两者并进同一个 `haltBecauseNothingIsLoaded()`，于是「单曲 + `.all` +
            // 暂停中按 ⏭」这类良性动作进入**伪失败终态**（`isFailureTerminal = true` 而
            // `failureStreak = 0`、`lastFailure = nil`），并抹平位置、清空引擎账本。
            // `claimed` 只读一次：它就是这次「重播当前项」宣称要落到的那一件，两个复核点
            // 必须比对同一件（F-1 的口径），不能让 await 之后的重读替换掉它。
            let claimed = queue.current?.id
            switch repeatGuardVerdict(claiming: claimed) {
            case .nothingLoaded:
                // MAJ-R5-1（F-A 的后一半）+ MAJ-R6-1（它的**下一半**）：守卫不成立这件事
                // 本身**说不出有没有失败**。腿 (b) 的成立条件是「引擎此刻装着当前项」，而它可以
                // 在一次失败都没有时不成立 —— 整队替换后从未起播、私有音频装载还在
                // `prepareSource` 上、刚把当前曲从队列里删掉，都是这种正常形态。第 10 批为此
                // 加了分流，但把「账上有没有失败」读成了 `failureStreak > 0 || lastFailure != nil`；
                // `lastFailure` 是**回显账**，一次被取消的装载（用户取消 / 断网 / 登出换代产生的
                // `.staleSession`）就会把它点亮 ⇒ 终态闸门被重新打开，F-A 那一类「没有失败却进
                // 失败终态」原地复活。
                // 分流口径：**终态只能长在计数侧的失败账上**（`countsTowardFailureStreak`）；
                // 计数侧没有账时，它与腿 (c) 是同一个结果 —— 良性保持（状态、位置、队列身份、
                // 失败账一律不动，用户随后 `resume()` 会真装一次）。
                guard hasCountedFailureLedger else { return await holdCurrentItemWithoutPlaying() }
                return await haltBecauseNothingIsLoaded()
            case .holdWithoutPlaying:
                return await holdCurrentItemWithoutPlaying()
            case .mayReplay:
                break
            }
            position = 0
            await engine.seek(to: 0)
            await engine.play()
            // 两个 await 之后再复核一次（F-1 的同一把守卫）：期间用户完全可能已经暂停或
            // 换曲，此时状态必须交还给事实，而不是把 `.playing` 补写在用户的暂停之后。
            // 此处两条腿仍然合并：走到这里说明重播**已经**发起，落点一律按当下事实投影，
            // 不需要（也不允许）再判一次「该不该停止」。
            guard continuationIsCurrent(
                generation: nil, claimingEngineItem: claimed, requiresPlaybackIntent: true
            ) else {
                await engine.pause()
                return advanceOutcome(wrapped: false)
            }
            state = .playing
            // F-6：`.playing` 不得跑在「失败终态」账本前面 —— 引擎既然重新播起了这一项，
            // 自动推进的失败链就已由用户的处置打断。`failureStreak` 的「连续」口径不动
            // （装载/重播成功 ≠ 播放成功，断点在引擎确认播放的那一刻）。
            isFailureTerminal = false
            // P5（api-contracts §5「一次实际播放一个幂等键」）：单曲循环下的每一次完整播放
            // 都是一次实际播放 → 先关闭上一集次（产生新幂等键），再上报。少报同样是口径偏差。
            await closeEpisodeIfNeeded()
            await reportEpisodeIfNeeded()
            await publishNowPlaying(force: true)
            // F-3：`at:` / `item:` 与快照同刻（`index` 是 step 捕获的，可能已过期）。
            return repeatedOutcome()
        case .held:
            return .held
        case .stopped:
            await closeEpisodeIfNeeded()
            // `.off` 末项播完：用户「继续听」的意图随队列尾结束（守卫条件 (c) 的复位点）。
            userWantsPlayback = false
            state = .stopped
            await engine.pause()
            await publishNowPlaying(force: true)
            return .stopped
        case .rejected(let failure):
            switch failure {
            case .emptyQueue: return .rejected(.emptyQueue)
            case .noCurrentIndex: return .rejected(.noCurrentItem)
            case .tornDown: return .rejected(.tornDown)
            case .indexOutOfRange, .unknownItem, .invalidDestination: return .rejected(.emptyQueue)
            }
        }
    }

    /// `.one` 重播的自洽投影（F-3）：`at:` 与 `item:` 取**同一时刻**的队列快照，
    /// 状态已收敛为停止时不得再回吐 `.repeated`。
    private func repeatedOutcome() -> AdvanceOutcome {
        guard !tornDown else { return .rejected(.tornDown) }
        guard let index = queue.currentIndex, let item = queue.current else {
            return .rejected(.emptyQueue)
        }
        switch state {
        case .stopped: return .stopped
        case .idle: return .rejected(.emptyQueue)
        case .playing, .paused, .buffering, .loading:
            return .repeated(at: index, item: item)
        }
    }

    /// 一致性收敛（状态必须与实际装载一致）：「回绕 / 重播当前项」落到一个引擎里
    /// 根本不存在的项目上时，绝不进入 `.playing`，而是停止自动推进并进入终态，
    /// 等用户处置（design §9「停止并提示」；由 `resume()` / `start()` 显式重试恢复）。
    ///
    /// **只用于「装载事实不成立」且「计数侧确实有失败账」那一腿**（F-A + MAJ-R5-1 + MAJ-R6-1）：
    /// 本函数会写 `isFailureTerminal = true`，而终态的定义是先有**计数**失败（design §9）。
    /// 计数侧没有账时 —— 哪怕回显账上有一次不计数的取消 ——
    /// 「引擎里没装当前项」不是故障而是正常形态（未起播 / 装载在途 / 刚删掉当前曲 / 装载被取消），
    /// 那种情形走 `holdCurrentItemWithoutPlaying()`，绝不允许进到这里。
    private func haltBecauseNothingIsLoaded() async -> AdvanceOutcome {
        isFailureTerminal = true
        userWantsPlayback = false
        state = .stopped
        position = 0
        engineEpisodeItemID = nil
        await closeEpisodeIfNeeded()
        await engine.pause()
        await publishNowPlaying(force: true)
        return .stopped
    }

    /// `.repeated` 守卫的**分离结果**（F-A）。
    private enum RepeatGuardVerdict: Equatable {
        /// 三条腿全成立：可以重播当前项并声称 `.playing`。
        case mayReplay
        /// 装载事实成立、仅用户意图不成立：良性保持，不写任何账。
        case holdWithoutPlaying
        /// 装载事实不成立（无当前项 / 换代在途 / 引擎没持有这一项 / 已释放）。
        ///
        /// **这个裁决本身不足以定终态**（MAJ-R5-1）：调用处还要问 `hasCountedFailureLedger`，
        /// 而它只看裁决账 —— 一次不计数的取消不算数（MAJ-R6-1）。
        case nothingLoaded
    }

    /// 把 `.repeated` 的两条腿**分别**折算成各自的收敛结果 —— 这是 F-A 的全部修法。
    ///
    /// 之所以不直接调 `continuationIsCurrent(requiresPlaybackIntent:)` 再一分为二：
    /// 那个函数返回单个布尔，「(b) 不成立」与「(c) 不成立」在它手里是同一个事实，
    /// 于是必然重演 F-A（把良性动作收敛成失败终态）。装载事实腿仍然只由
    /// `continuationIsCurrent` 定义，意图腿只由 `hasPlaybackIntent` 定义（一处一份，无就地重写）。
    /// 本函数不公开：三条腿的**组合结果**只服务 `.repeated` 一个调用点，
    /// 让外面能查「两腿合一的裁决」只会诱导就地重写条件（F-1/F-2 的老病根）。
    ///
    /// 注意 `.nothingLoaded` 的**收敛结果**不由本函数决定：装载事实腿的成立条件里
    /// 不含「有没有失败」，所以终态与否留给调用处按 `hasCountedFailureLedger` 分流
    /// （MAJ-R5-1；第 11 批 MAJ-R6-1 把那条分流钉死在**计数侧**：不计数的取消不开终态）。
    private func repeatGuardVerdict(claiming claimed: String?) -> RepeatGuardVerdict {
        guard let claimed,
              continuationIsCurrent(
                generation: nil, claimingEngineItem: claimed, requiresPlaybackIntent: false
              ) else { return .nothingLoaded }
        guard hasPlaybackIntent else { return .holdWithoutPlaying }
        return .mayReplay
    }

    /// 良性保持（F-A / MAJ-R5-1 / MAJ-R6-1）：`.repeated` 的守卫不成立，而**裁决账上没有失败**。
    ///
    /// 触发它的有两种形态，结果必须相同 —— 因为它们都不是故障：
    ///   · 腿 (c)：队列数学只能「重播当前项」，而用户此刻没有播放意图（暂停中按 ⏭）；
    ///   · 腿 (b)/(a) 不成立而计数侧无账：引擎没装当前项（整队替换后未起播、
    ///     私有音频装载在途、刚移除当前曲、**上一次装载被取消 / 会话过期**）。
    ///     最后一例的回显账可能非 nil（`lastFailure == .cancelled`），那也只是「上次为什么没播成」，
    ///     不构成终态资格（MAJ-R6-1）。
    ///
    /// 与 `haltBecauseNothingIsLoaded()` 相反，这里**什么都不改写**：位置、`loopMode`、
    /// 引擎账本（`engineEpisodeItemID`）、失败账（`failureStreak` / `lastFailure` /
    /// `isFailureTerminal`）、集次（不关闭 → 续播复用同一幂等键）全部保持，
    /// 只把「还在响的引擎」按意图摁住，并如实回 `.held`（design §4/§6「越界保持」）。
    /// 引擎账本没保住的那种后果由 `resume()` 自己处理：它见引擎里没有当前项就真装一次（R1）。
    private func holdCurrentItemWithoutPlaying() async -> AdvanceOutcome {
        if state == .playing || state == .buffering {
            state = .paused
            await engine.pause()
        }
        await publishNowPlaying(force: true)
        return .held
    }

    private func handleItemEnded() async -> AdvanceOutcome {
        // 仅「正在播」状态下接受 ended；装载中/已停止/暂停时到达的一律视为重复上报，忽略。
        // 「上一项的迟到 ended」与「同项的重复 ended」**不在这里判**：裸 `.ended` 不带归因，
        // 在此丢弃会误杀正常推进（`testItemEndUnderOffWalksThenStops` 钉住）。归因事实只在
        // 引擎侧存在，故由 `EngineEventGate` 在事件进流之前丢弃（见 `PlayerEngine.swift`）。
        // 决策层这里补的是**另一半**归因：装载在途 / 引擎未持有当前项时不得推进（F-2 同族），
        // 那类 `ended` 只可能来自已被取代的条目，且引擎闸门管不到「装载续体自己正在 await」的窗口。
        guard state == .playing || state == .buffering else { return .held }
        guard continuationIsCurrent(
            generation: nil, claimingEngineItem: queue.current?.id, requiresPlaybackIntent: true
        ) else { return .held }
        let step = queue.step(direction: .forward, trigger: .itemEnded, under: loopMode)
        return await apply(step)
    }

    private func handleFailure(_ failure: PlayerFailure) async {
        // F-2 的终态腿：已经收敛为终态时，迟到的失败不得再计数、不得再跳曲。
        guard !isFailureTerminal else { return }
        // 两本账分开记（MAJ-R6-1 的口径，见 `hasCountedFailureLedger`）：
        //   · `lastFailure` = **回显账**，任何形态（含不计数的取消）都写，供 UI 提示；
        //   · `failureStreak` = **裁决账**，只有 `countsTowardFailureStreak` 的形态进得来，
        //     而它是「失败终态」的唯一合法来源。
        // 因此下面这条 `guard` 不只是「少计一次连击」，它同时决定了这一次失败**能不能
        // 打开终态闸门**（`apply(.repeated)` 的腿 (b) 分流）—— 这正是第 6 批 MAJ-4
        // 「取消一律归一为 `.cancelled` → 不计连击」的应有之义。
        lastFailure = failure
        guard failure.countsTowardFailureStreak else { return }
        if failureStreak < configuration.consecutiveFailureLimit { failureStreak += 1 }
        guard failureStreak < configuration.consecutiveFailureLimit else {
            // 第 3 次：进入终态，停止自动推进（design §9「连续 3 次失败停止并提示」）。
            isFailureTerminal = true
            userWantsPlayback = false
            state = .stopped
            await closeEpisodeIfNeeded()
            await engine.pause()
            await publishNowPlaying(force: true)
            return
        }
        // 未达上限：自动跳下一首（失败永不「重复当前项」，见裁决表）。
        // 若队列数学只能回绕到**同一个坏项**（单元素队列 / `.one` 全坏），`apply(.repeated)`
        // 的一致性闸门会把它收敛成 `.stopped` + 终态 —— 引擎里没有可播的东西，绝不声称在播。
        await closeEpisodeIfNeeded()
        let step = queue.step(direction: .forward, trigger: .itemFailed, under: loopMode)
        _ = await apply(step)
    }

    /// 装载当前项（含私有音频本地化前置，D7）。
    ///
    /// **每个回写点都走 `continuationIsCurrent`**（守卫 a+b+c，见该函数注释）：本函数跨
    /// `prepareSource` / `engine.load` / `engine.play` 多个挂起点，期间用户完全可以
    /// skip、暂停、释放播放器。过期或违背意图就整条丢弃（不回写引擎、不改状态、
    /// 不记失败、不发上报、不发布元数据）。
    private func loadCurrent(autoplay: Bool) async {
        guard !tornDown else { return }
        guard let item = queue.current else {
            // 无当前项也要作废在途装载，否则它回来时会把状态复活。
            invalidateInFlightLoad()
            state = .idle
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        inFlightLoad = InFlightLoad(generation: generation)
        // 台账的生命周期用 defer 钉死：本函数有 7 个提前返回，漏掉任何一个都会让
        // 「装载在途」永久成立，从而把所有后续 seek / 事件归约误杀（守卫 (a) 的另一半）。
        defer { finishLoad(generation) }
        // 换件的瞬间，引擎里就没有可播的东西了 —— 直到当代装载真正返回。
        engineEpisodeItemID = nil
        userWantsPlayback = autoplay
        state = .loading
        position = 0
        duration = item.duration
        await publishNowPlaying(force: true)
        guard continuationIsCurrent(
            generation: generation, claimingEngineItem: nil, requiresPlaybackIntent: false
        ) else { return }

        let prepared: PlaybackItem
        if let preparer = sourcePreparer {
            switch await preparer.prepareSource(for: item, session: session) {
            case .success(let ready):
                guard continuationIsCurrent(
                    generation: generation, claimingEngineItem: nil, requiresPlaybackIntent: false
                ) else { return }
                prepared = ready
            case .failure(let error):
                // 过期装载的失败同样不得污染新集次（连击计数 / lastFailure）。
                guard continuationIsCurrent(
                    generation: generation, claimingEngineItem: nil, requiresPlaybackIntent: false
                ) else { return }
                await handleFailure(PlayerFailure(kind: Self.kind(for: error), message: error.description))
                await convergeStalledLoad(generation: generation)
                return
            }
        } else if item.requiresLocalization {
            // 未注入本地化器时，绝不把 Bearer 地址交给播放器（D7 硬规则）。
            guard continuationIsCurrent(
                generation: generation, claimingEngineItem: nil, requiresPlaybackIntent: false
            ) else { return }
            await handleFailure(PlayerFailure(kind: .localizationRequired, message: "缺少私有音频本地化器"))
            await convergeStalledLoad(generation: generation)
            return
        } else {
            prepared = item
        }
        // 交给引擎：从这一刻起，引擎上报的失败属于当代（F-2 的归因分界）。
        if inFlightLoad?.generation == generation {
            inFlightLoad?.handedToEngine = true
        }
        await engine.load(prepared)
        guard continuationIsCurrent(
            generation: generation, claimingEngineItem: nil, requiresPlaybackIntent: false
        ) else { return }
        if let failure = inFlightLoad?.failure, inFlightLoad?.generation == generation {
            // F-8：契约「load 失败经 `.failed` 表达」在这里被真正消费 ——
            // 引擎账本尚未记账，所以「无处可跳」会由 `apply(.repeated)` 的闸门收敛成终态。
            inFlightLoad?.failure = nil
            await handleFailure(failure)
            await convergeStalledLoad(generation: generation)
            return
        }
        // 引擎账本先落，再谈播放状态（R1）。
        engineEpisodeItemID = prepared.id
        // 引擎确实装着当前项 = 「自动推进的失败连击」已被用户的处置打断（F-6）。
        isFailureTerminal = false
        if autoplay && userWantsPlayback {
            state = .playing
            await engine.play()
            await engine.setRate(playbackRate)
            guard continuationIsCurrent(
                generation: generation, claimingEngineItem: prepared.id, requiresPlaybackIntent: true
            ) else { return }
            await reportEpisodeIfNeeded()
        } else {
            // F-1：装载期间用户显式暂停 —— 条目照常进引擎，但绝不命令出声、
            // 不声称 `.playing`、不上报这一集次。
            state = .paused
        }
        await publishNowPlaying(force: true)
    }

    /// 当代装载是否仍未被取代（取代 = 新一轮 `loadCurrent` / 无当前项 / teardown）。
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == loadGeneration && !tornDown
    }

    /// 取消导致的装载结束：把 `.loading` **交还给事实**（MAJ-R6-1 的第二半，第 11 批存疑点 1）。
    ///
    /// 为什么需要一条独立的腿：`handleFailure` 对不计数的取消就是「记完回显账立刻返回」，
    /// 于是这一次装载既不播、也不推进、也不改状态 —— 而它入口那句 `state = .loading` 还在，
    /// `defer { finishLoad }` 又已经把台账收掉 ⇒ **`.loading` 从此没有对应的在途装载**，
    /// F-7 的自述（`.loading` ⟹ 真有装载在途）当场失守。同一份输入还有第二层后果：
    /// `advanceOutcome` 照 `.loading` 回 `.advanced`，`start()` 于是向调用方声称
    /// 「已经落到这一项」，而引擎里什么都没有。
    ///
    /// 与 `haltBecauseNothingIsLoaded()` 的差别只有**一行**：这里不写 `isFailureTerminal`。
    /// 取消不是故障（MAJ-4 / MAJ-R6-1 的口径 —— 计数账才是终态的唯一来源），它只让
    /// 「装载中」这个读数作废；位置、时长、队列身份都留着，用户 `resume()` 会真装一次
    /// （引擎账本已归零，R1 要求的就是这个）。
    ///
    /// 自我守卫的两个条件缺一不可：计数失败的腿会经 `apply` 去装**下一件**（状态已被那条腿
    /// 改写，或已换成更新一代的在途装载），那时本函数必须是无操作 —— 否则就会把用户刚刚
    /// 起播的新一轮装载打成 `.stopped`。
    private func convergeStalledLoad(generation: UInt64) async {
        guard state == .loading, inFlightLoad?.generation == generation else { return }
        userWantsPlayback = false
        state = .stopped
        position = 0
        engineEpisodeItemID = nil
        await closeEpisodeIfNeeded()
        // 装载入口没有先摁住引擎（换件由 `engine.load` 顶替旧项）：取消意味着永远不会有那次
        // 顶替，此刻响着的可能是**上一件**。不暂停就是「读数说停止了，耳朵里却还在播」。
        await engine.pause()
        await publishNowPlaying(force: true)
    }

    // MARK: - 内部：续体守卫（环 4 R9：F-1 / F-2 / F-5 / F-7 / F-8 的同一条不变量）

    /// 守卫 (a) 的两种严格度。
    private enum ContinuationKind {
        /// **宣称类**续体（装载回写 / 声称播放 / 写引擎 / 推进 / seek）：装载在途期间
        /// 引擎里可能还是旧条目 → 除本代际的装载本身外一律不采信。
        case claim
        /// **观测类**续体（`position` / `duration`）：`engine.load` 已在途时，引擎里装的
        /// 就是当代条目，它上报的事实属于当代 —— 只排除 `prepareSource` 阶段（F-2 的分界）。
        case observation
    }

    /// **唯一的续体采信判据**：任何跨挂起点回来的「装载 / 播放 / 事件归约」续体，
    /// 在回写状态、命令引擎、记失败账、动进度账或发布锁屏之前，必须同时满足三条：
    ///
    /// - (a) **装载代际**：`generation` 仍是当代且未释放；传 `nil` 表示本续体不源自
    ///   `loadCurrent`，于是按 `kind` 决定对在途装载的严格度；
    /// - (b) **引擎归属**：引擎里实际装着被宣称的那一项（见 `engineOwns(_:kind:)`），
    ///   且当代没有收到过引擎上报的失败；
    /// - (c) **用户意图**：未被显式暂停、未进入失败终态（仅在宣称播放时要求）。
    ///
    /// 收敛成一个命名守卫的原因：这三条曾在五个续体点各写一份、各漏一处
    /// （M10 只封了事件路径 → F-1 的装载路径仍开放；P2 只封了代际 → F-2/F-5/F-8 仍开放）。
    /// 新增续体点时只允许调用本函数，不允许就地重写条件。
    private func continuationIsCurrent(
        generation: UInt64?,
        claimingEngineItem claimed: String?,
        kind: ContinuationKind = .claim,
        requiresPlaybackIntent: Bool
    ) -> Bool {
        // (a) 装载代际 / 生命周期
        if let generation {
            guard inFlightLoad?.generation == generation, isCurrent(generation) else { return false }
        } else {
            guard !tornDown else { return false }
            if kind == .claim {
                guard inFlightLoad == nil else { return false }
            }
        }
        // (b) 引擎归属（含「本代际的 load 已失败」）
        if let claimed {
            guard inFlightLoad?.failure == nil, engineOwns(claimed, kind: kind) else { return false }
        }
        // (c) 用户意图
        if requiresPlaybackIntent {
            guard hasPlaybackIntent else { return false }
        }
        return true
    }

    /// 守卫 (c)：**用户此刻是否要听当前项**（F-A 起单独成一条判据，好让它的失效结果
    /// 与守卫 (b)「引擎里到底有没有这一项」分开收敛）。
    ///
    /// 置位/复位点：`start` / `resume` / 推进装载 → `true`；`pause` / 失败终态 / 释放 /
    /// 整队换代 / `.off` 队列尾播完 → `false`。「意图不成立」是**正常状态**（暂停里按 ⏭
    /// 就是它），不是故障，因此它的收敛结果只能是「保持」，不能是失败终态。
    private var hasPlaybackIntent: Bool { userWantsPlayback && !isFailureTerminal }

    /// 守卫 (b) 的另一半（MAJ-R5-1 / MAJ-R6-1）：**此刻裁决账上到底有没有失败**。
    ///
    /// 「失败」在本协调器里是**两本账**，混用就是 MAJ-R6-1 的根：
    ///   · `failureStreak` = **裁决账** —— 只由 `PlayerFailure.countsTowardFailureStreak == true`
    ///     的形态累加（`handleFailure`），是「失败终态」的**唯一**合法来源（design §9
    ///     「连续 3 次失败停止并提示」，以及第二个来源「失败后队列已无可跳目标」）；
    ///   · `lastFailure` = **回显账** —— 最近一次失败记录，含 `.cancelled`（用户取消、断网、
    ///     登出/换代产生的 `.staleSession` 都经 `kind(for:)` 归一到这一类）这种**不计数**形态。
    ///     它回答的是「上一次坏在哪」，供 UI 提示与诊断，**不回答「现在还算不算失败」**。
    ///
    /// 所以判据只看计数侧：`failureStreak > 0`。第 10 批写成
    /// `failureStreak > 0 || lastFailure != nil`，等于让回显账获得裁决权 —— 一次被取消的
    /// 装载即可点亮终态闸门，把 F-A 那一类「没有失败却进失败终态」原地重新打开
    /// （`failureStreak == 0` 而 `isFailureTerminal == true`，违反本文件与 `PlaybackSnapshot`
    /// 的自述不变量，也违反 MAJ-4 立下的「取消不是失败」）。
    ///
    /// 与「引擎里有没有装当前项」「用户想不想听」两件事**互不蕴含**：`failureStreak == 0`
    /// 而该字段为 true 才是谎报（F-A 原文），而 `failureStreak > 0` 时它必然也非 nil
    /// （计数形态先写回显再进裁决账），故「终态 ⟹ 两本账都有」这条测试判据仍然成立。
    private var hasCountedFailureLedger: Bool { failureStreak > 0 }

    /// 守卫 (b)：引擎此刻装着的是不是这一项。
    ///
    /// `observation` 口径放宽到「正在被交给它」：`engine.load` 已在途时引擎里装的就是它，
    /// 观测者上报的是当代条目；`claim` 口径要求装载已经真正返回并记账（R1）。
    private func engineOwns(_ itemID: String, kind: ContinuationKind) -> Bool {
        if engineEpisodeItemID == itemID { return true }
        guard kind == .observation else { return false }
        guard let inFlight = inFlightLoad,
              inFlight.handedToEngine,
              inFlight.generation == loadGeneration else { return false }
        return queue.current?.id == itemID
    }

    /// 引擎上报的失败能否归因到**当前集次**（F-2）。
    ///
    /// 迟到失败的现实形态：用户已 skip，新一轮装载还挂在 `prepareSource` 上，引擎里装的
    /// 仍是上一件 —— 上一件的失败此时到达。裸 `.failed` 不带身份，协调器唯一能用的判据
    /// 就是「引擎有没有被交给当代条目」+「引擎账本装着谁」。
    private func failureIsAttributableToCurrentEpisode(_ failure: PlayerFailure) -> Bool {
        guard !tornDown else { return false }
        guard queue.current != nil else { return false }
        if let inFlight = inFlightLoad {
            // 装载在途：只有「已交给引擎」的阶段上报才属于当代，交由装载续体消费（F-8）。
            return inFlight.generation == loadGeneration && inFlight.handedToEngine
        }
        // 无装载在途：引擎里必须确实装着当前项。
        return engineEpisodeItemID != nil && engineEpisodeItemID == queue.current?.id
    }

    /// 队列换代 / 释放：在途台账与用户意图一并作废（F-7：`loading`  ⟹ 真有装载在途）。
    private func invalidateInFlightLoad() {
        loadGeneration &+= 1
        inFlightLoad = nil
        engineEpisodeItemID = nil
        userWantsPlayback = false
    }

    /// 结束本代际的在途台账（被取代的装载不得清掉新一轮的台账）。
    private func finishLoad(_ generation: UInt64) {
        if inFlightLoad?.generation == generation { inFlightLoad = nil }
    }

    static func kind(for error: PlayerError) -> PlayerFailure.Kind {
        switch error {
        case .hostRejected, .badStatus, .truncated, .credentialUnavailable: return .network
        case .emptyDownload, .writeFailed: return .missingFile
        case .notLocalized: return .localizationRequired
        case .cancelled, .staleSession: return .cancelled
        case .pathEscape, .noCurrentItem, .indexOutOfRange, .unknownItem, .engineNotReady, .tornDown:
            return .engine
        }
    }

    // MARK: - 内部：时间与上报

    private var effectiveDuration: Double? {
        if let duration, duration.isFinite, duration > 0 { return duration }
        if let item = queue.current, let duration = item.duration { return duration }
        return nil
    }

    private func applyEnginePosition(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if let total = effectiveDuration, seconds > total {
            position = total
            return
        }
        position = max(0, seconds)
    }

    /// 引擎上报真实时长。
    ///
    /// 若先前因「时长未知」而允许位置越界（±15s 口径 3），此处按引擎时长纠正；
    /// 纠正后恰落在时长末端 → 按「播完」规则继续（同一次 `receive` 内完成，不派新任务，保持确定性）。
    private func applyEngineDuration(_ seconds: Double) async {
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        guard position > seconds else { return }
        position = seconds
        guard state == .playing || state == .buffering else { return }
        _ = await handleItemEnded()
    }

    private func resetItemTimingState() {
        position = 0
        duration = queue.current?.duration
        failureStreak = 0
        lastFailure = nil
        isFailureTerminal = false
    }

    private func reportEpisodeIfNeeded() async {
        guard let reporter, let item = queue.current, state == .playing else { return }
        guard reportedEpisodeItemID != item.id else { return }
        reportedEpisodeItemID = item.id
        await reporter.playbackStarted(
            itemID: item.id,
            kind: item.kind,
            session: session
        )
    }

    /// 关闭当前集次：使「同一曲目稍后再次播放」产生**新**幂等键。
    private func closeEpisodeIfNeeded() async {
        guard let id = reportedEpisodeItemID else { return }
        reportedEpisodeItemID = nil
        if let reporter { await reporter.playbackEnded(itemID: id) }
    }

    private func discardPendingReports() async {
        reportedEpisodeItemID = nil
        if let reporter { await reporter.invalidateSessions() }
    }

    /// 未决上报重试入口（网络恢复 / 凭证就绪）：**复用同一幂等键**。
    /// teardown 后拒绝（R3）：未决集次已在释放时丢弃，不得再补发。
    @discardableResult
    public func retryPendingReports() async -> [PlayReportOutcome] {
        guard !tornDown else { return [] }
        guard let reporter else { return [] }
        return await reporter.retryPending()
    }

    /// 失效收敛点（F-B）：登出 / 换号 / generation 推进 与 `teardown` 共用这一条。
    ///
    /// 除了队列与时间账，**失败账也一并作废**：`failureStreak` / `lastFailure` / `isFailureTerminal`
    /// 数的是「当前这一串连续失败的曲目」，队列已经没了、引擎已经停了，继续携带只会让 UI
    /// 把「已释放 / 空闲」渲染成「失败已停止」（且 `isFailureTerminal` 的自述要求先有失败）。
    /// 与 `resetItemTimingState()` 同一口径，两者都不是「用户重试」——重试的清零在 `resume`。
    ///
    /// **系统回显面也在这个收敛点上清掉**（MIN-R5-4）：失效面过去只做到了快照那一半，
    /// 于是登出后锁屏继续显示**上一身份**的曲名与艺人（design §8「生成候选 · 仅本人可见」
    /// 的内容尤其不该留在锁屏上），违反 D8 的防串号与 AGENTS 硬边界 3。放在这里而不是
    /// `bindSession` 的分支里，是为了让「登出」与 `teardown` 共用同一份失效口径 ——
    /// 少一个可以被忘记写的地方。
    private func clearQueueAndStop() async {
        reportedEpisodeItemID = nil
        _ = queue.removeAll()
        // 队列清空 = 在途装载全部作废，引擎账本同步归零（R1 / R2 / F-7）。
        invalidateInFlightLoad()
        lastTimeSyncStamp = nil
        position = 0
        duration = nil
        failureStreak = 0
        lastFailure = nil
        isFailureTerminal = false
        state = .stopped
        // 只擦读数（`MPNowPlayingInfoCenter` 的字典与播放态），**不退命令面**：
        // 登出后本播放器还要继续服务游客态与新账号（`clear()` 与 `teardown()` 的语义差别）。
        // `teardown()` 路径上这句是幂等的重复 —— 那里已经先做过一次完整的 `nowPlaying.teardown()`。
        await nowPlaying?.clear()
    }

    // MARK: - 内部：Now Playing

    /// `force == false` 用于纯时间推进：受 `nowPlayingTimeSyncInterval` 节流（虚拟时钟可测）。
    private func publishNowPlaying(force: Bool) async {
        guard let nowPlaying else { return }
        let now = await clock.now()
        if !force, let stamp = lastTimeSyncStamp, now - stamp < configuration.nowPlayingTimeSyncInterval {
            return
        }
        lastTimeSyncStamp = now
        guard let item = queue.current else {
            await nowPlaying.clear()
            return
        }
        await nowPlaying.publish(NowPlayingMetadata(
            itemID: item.id,
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: effectiveDuration,
            elapsed: position,
            playbackRate: playbackRate,
            isPlaying: state == .playing,
            artworkURL: item.coverURL
        ))
    }
}
