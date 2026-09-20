import CovaCore
import Foundation

/// 播放状态（由 coordinator 归约，不由 UI 猜测）。
public enum PlaybackState: String, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    /// 无队列 / 未选曲。
    case idle
    /// 正在装载当前项（含私有音频本地化中）。
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
    public var lastFailure: PlayerFailure?
    /// 连续失败达上限进入的终态（自动推进已停止）。
    public var isFailureTerminal: Bool
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
    /// 边界保持（`.off`/`.one` 下显式越过首尾）。
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
            session: session
        )
    }

    /// 绑定/切换会话（D8）：generation 推进时丢弃未决上报、清私有音频、停播放。
    public func bindSession(_ context: PlaybackSessionContext) async {
        guard context != session else { return }
        let previous = session
        session = context
        // 失效面（D8）：登出 / 换号（两个已认证身份之间）/ generation 推进 —— 不含「登录」。
        let switchedAccounts = context.owner != nil && previous.owner != nil && context.owner != previous.owner
        if previous.generation != context.generation || switchedAccounts || context.owner == nil {
            await discardPendingReports()
            engine.stopAndRelease()
            await clearQueueAndStop()
        }
        // 上报器共用同一会话视图：未认证 → 挂起；登出/换号 → 丢弃未决。
        await reporter?.bindSession(context)
    }

    public func sessionGeneration() -> SessionGeneration { session.generation }

    // MARK: - 队列

    /// 整队替换（进入加载态，不自动播放；播放由 `start` / `resume` 决定）。
    @discardableResult
    public func replaceQueue(_ items: [PlaybackItem], startingAt start: Int = 0) async -> PlayQueue.Change {
        await closeEpisodeIfNeeded()
        let change = queue.replace(items, startingAt: start)
        resetItemTimingState()
        state = queue.current == nil ? .idle : .loading
        await publishNowPlaying(force: true)
        return change
    }

    @discardableResult
    public func appendToQueue(_ item: PlaybackItem) async -> PlayQueue.Change {
        let change = queue.append(item)
        await publishNowPlaying(force: false)
        return change
    }

    @discardableResult
    public func insertNext(_ item: PlaybackItem) async -> PlayQueue.Change {
        let change = queue.insertNext(item)
        await publishNowPlaying(force: false)
        return change
    }

    /// 拖拽排序（当前曲目身份保持不变）。
    @discardableResult
    public func reorder(from: Int, to destination: Int) async -> PlayQueue.Change {
        queue.move(from: from, to: destination)
    }

    /// 移除队列项；移除的是当前项时按裁决表处理（保持播放意图，换到同位置的新项）。
    @discardableResult
    public func removeItem(at index: Int) async -> PlayQueue.Change {
        let wasCurrent = queue.currentIndex == index
        let wasPlaying = state == .playing || state == .buffering || state == .loading
        let change = queue.remove(at: index)
        guard wasCurrent, case .applied(let effect) = change else { return change }
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
                await publishNowPlaying(force: true)
            }
        default:
            break
        }
        return change
    }

    @discardableResult
    public func removeItem(itemID: String) async -> PlayQueue.Change {
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
        guard let item = queue.current, let index = queue.currentIndex else {
            state = .idle
            return .rejected(.emptyQueue)
        }
        isFailureTerminal = false
        failureStreak = 0
        lastFailure = nil
        await loadCurrent(autoplay: true)
        return .advanced(to: index, item: item, wrapped: false)
    }

    public func pause() async {
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
        if state == .stopped || isFailureTerminal {
            isFailureTerminal = false
            failureStreak = 0
            lastFailure = nil
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
    @discardableResult
    public func setLoopMode(_ mode: LoopMode) async -> LoopMode {
        loopMode = mode
        await publishNowPlaying(force: false)
        return mode
    }

    /// UI 循环按钮：off → all → one → off。
    @discardableResult
    public func cycleLoopMode() async -> LoopMode {
        await setLoopMode(loopMode.advanced())
    }

    public func currentLoopMode() -> LoopMode { loopMode }

    @discardableResult
    public func setPlaybackRate(_ rate: Double) async -> Double {
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
        guard queue.current != nil else { return .rejected(.noCurrentItem) }
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
    public func receive(_ event: PlayerEvent) async {
        guard !tornDown else { return }
        switch event {
        case .playing:
            state = .playing
            failureStreak = 0
            isFailureTerminal = false
            await reportEpisodeIfNeeded()
            await publishNowPlaying(force: true)
        case .paused:
            if state == .playing { state = .paused }
            await publishNowPlaying(force: true)
        case .buffering:
            if state == .playing || state == .loading { state = .buffering }
            await publishNowPlaying(force: false)
        case .position(let seconds):
            applyEnginePosition(seconds)
            await publishNowPlaying(force: false)
        case .duration(let seconds):
            await applyEngineDuration(seconds)
            await publishNowPlaying(force: true)
        case .ended:
            _ = await handleItemEnded()
        case .failed(let failure):
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
    public func teardown() async {
        guard !tornDown else { return }
        tornDown = true
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
        let step = queue.step(direction: direction, trigger: trigger, under: loopMode)
        return await apply(step)
    }

    private func apply(_ step: PlayQueue.Step) async -> AdvanceOutcome {
        queue.apply(step)
        switch step {
        case .moved(let index, let wrapped):
            await closeEpisodeIfNeeded()
            await loadCurrent(autoplay: true)
            guard let item = queue.current else { return .rejected(.emptyQueue) }
            return .advanced(to: index, item: item, wrapped: wrapped)
        case .repeated(let index):
            guard let item = queue.current else { return .rejected(.emptyQueue) }
            position = 0
            await engine.seek(to: 0)
            await engine.play()
            state = .playing
            await publishNowPlaying(force: true)
            return .repeated(at: index, item: item)
        case .held:
            return .held
        case .stopped:
            await closeEpisodeIfNeeded()
            state = .stopped
            await engine.pause()
            await publishNowPlaying(force: true)
            return .stopped
        case .rejected(let failure):
            switch failure {
            case .emptyQueue: return .rejected(.emptyQueue)
            case .noCurrentIndex: return .rejected(.noCurrentItem)
            case .indexOutOfRange, .unknownItem, .invalidDestination: return .rejected(.emptyQueue)
            }
        }
    }

    private func handleItemEnded() async -> AdvanceOutcome {
        // 仅「正在播」状态下接受 ended；装载中/已停止/暂停时到达的一律视为重复上报
        // （AVPlayer 的 boundary observer 与 playToEnd 可能双发），忽略。
        guard state == .playing || state == .buffering else { return .held }
        let step = queue.step(direction: .forward, trigger: .itemEnded, under: loopMode)
        return await apply(step)
    }

    private func handleFailure(_ failure: PlayerFailure) async {
        lastFailure = failure
        guard failure.countsTowardFailureStreak else { return }
        if failureStreak < configuration.consecutiveFailureLimit { failureStreak += 1 }
        guard failureStreak < configuration.consecutiveFailureLimit else {
            // 第 3 次：进入终态，停止自动推进（design §9「连续 3 次失败停止并提示」）。
            isFailureTerminal = true
            state = .stopped
            await closeEpisodeIfNeeded()
            await engine.pause()
            await publishNowPlaying(force: true)
            return
        }
        // 未达上限：自动跳下一首（失败永不「重复当前项」，见裁决表）。
        await closeEpisodeIfNeeded()
        let step = queue.step(direction: .forward, trigger: .itemFailed, under: loopMode)
        _ = await apply(step)
    }

    /// 装载当前项（含私有音频本地化前置，D7）。
    private func loadCurrent(autoplay: Bool) async {
        guard let item = queue.current else {
            state = .idle
            return
        }
        state = .loading
        position = 0
        duration = item.duration
        await publishNowPlaying(force: true)
        let prepared: PlaybackItem
        if let preparer = sourcePreparer {
            switch await preparer.prepareSource(for: item, session: session) {
            case .success(let ready):
                prepared = ready
            case .failure(let error):
                await handleFailure(PlayerFailure(kind: Self.kind(for: error), message: error.description))
                return
            }
        } else if item.requiresLocalization {
            // 未注入本地化器时，绝不把 Bearer 地址交给播放器（D7 硬规则）。
            await handleFailure(PlayerFailure(kind: .localizationRequired, message: "缺少私有音频本地化器"))
            return
        } else {
            prepared = item
        }
        await engine.load(prepared)
        if autoplay {
            state = .playing
            await engine.play()
            await engine.setRate(playbackRate)
            await reportEpisodeIfNeeded()
        } else {
            state = .paused
        }
        await publishNowPlaying(force: true)
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
    @discardableResult
    public func retryPendingReports() async -> [PlayReportOutcome] {
        guard let reporter else { return [] }
        return await reporter.retryPending()
    }

    private func clearQueueAndStop() async {
        reportedEpisodeItemID = nil
        _ = queue.removeAll()
        lastTimeSyncStamp = nil
        position = 0
        duration = nil
        state = .stopped
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
