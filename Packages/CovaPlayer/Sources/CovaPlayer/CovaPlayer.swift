import CovaCore
import Foundation

/// 播放器层门面（G3-e）。
///
/// 职责：把「可测的决策层」（`PlaybackCoordinator` / `PlayReportCoordinator` /
/// `PlayQueue` / 各 reducer）与「iOS 薄适配器」（`AVPlayerEngine` /
/// `AVAudioSessionAdapter` / `MPNowPlayingController` / `URLSessionPrivateAudioTransport`）
/// 串成一条 M1 可直接调用的链。
///
/// **不含任何 UI**（AGENTS 硬边界 8 / 门禁 3/10 机械化拦截）。
///
/// 安全：
/// - 唯一网络出口是 `https://covalink.cn`（`CovaEnvironment`，D10）；`assetOrigin` 即该出口；
/// - 私有音频（D7）经 `PrivateAudioFetcher` 先落盘校验、再以 `file://` 播放；
///   Bearer / 签名地址以 `AudioURL` 形态存在，不进日志、不进持久化；
/// - `deinit` 同步释放引擎（`stopAndRelease`），不留时间观察者与远端 target。
@MainActor
public final class CovaPlayer {
    /// 资源出口（钉死为生产 origin；既有 `CovaTests` 断言其语义，不得退化）。
    public let assetOrigin: URL

    public let coordinator: PlaybackCoordinator
    public let engine: any PlayerEngine
    public let nowPlaying: MPNowPlayingController
    public let commandRouter: NowPlayingCommandRouter
    public let audioSession: AudioSessionGate
    public let reporter: PlayReportCoordinator
    /// 私有音频本地化器；未注入时为 nil（此时需 Bearer 的条目一律拒绝播放，绝不绕过 D7）。
    public private(set) var fetcher: (any PrivateAudioFetching)?

    private let clock: any CovaClock
    private var activated = false
    /// `teardown()` 之后门面永久下线：重新接线会造出「引擎事件循环已摘除、却在出声」的半死状态。
    private var tornDown = false

    /// 默认出口 = 生产 API origin（D10）。
    public convenience init() {
        self.init(assetOrigin: CovaEnvironment.apiBaseURL)
    }

    /// 依赖注入形态（单测与 M1 装配用）。
    public init(
        assetOrigin: URL = CovaEnvironment.apiBaseURL,
        engine: any PlayerEngine = AVPlayerEngine(),
        clock: any CovaClock = SystemClock(),
        reporter: PlayReportCoordinator? = nil,
        audioSystem: any AudioSessionSystemInterface = AVAudioSessionAdapter(),
        sourcePreparer: (any PlaybackSourcePreparing)? = nil,
        artworkAttacher: (any NowPlayingArtworkAttaching)? = nil
    ) {
        let router = NowPlayingCommandRouter()
        let controller = MPNowPlayingController(router: router, artworkAttacher: artworkAttacher)
        // 未注入上报器时使用 `UnavailablePlayReporter`：NEEDS-2 未解锁期间**显式挂起**，
        // 而不是静默丢包（集次停留在未决态，可经 pendingCount() 观测）。
        let report = reporter ?? PlayReportCoordinator(submitter: UnavailablePlayReporter())
        let playback = PlaybackCoordinator(
            engine: engine,
            clock: clock,
            reporter: report,
            nowPlaying: controller,
            sourcePreparer: sourcePreparer
        )
        self.assetOrigin = assetOrigin
        self.engine = engine
        self.clock = clock
        self.commandRouter = router
        self.nowPlaying = controller
        self.reporter = report
        self.audioSession = AudioSessionGate(
            system: audioSystem,
            handler: AudioSessionCommandHandler(coordinator: playback)
        )
        self.coordinator = playback
        self.fetcher = sourcePreparer as? any PrivateAudioFetching
        // 接线在同步 init 内完成：router 以 weak 持有 coordinator，故不构成循环引用。
        router.bind(playback)
    }

    // MARK: - 装配

    /// 激活：接上引擎事件流、启动音频会话、注册锁屏命令。
    ///
    /// 不在 `init` 里做：门面构建必须廉价（App 冷启动路径与单测都不应触碰系统会话）。
    ///
    /// **teardown 是终态**（M11）：释放后重新接线会造出「远端 target 重挂 + 已 deactivate 的会话
    /// 再激活」的僵尸态（协调器那边已经拒绝一切请求），因此本方法与 `ensureActivated` 一并下线。
    public func activateForPlayback() async throws {
        guard !tornDown else { return }
        guard !activated else { return }
        await coordinator.attach()
        try await audioSession.start()
        await nowPlaying.registerCommands()
        nowPlaying.setCommandsEnabled(true)
        activated = true
    }

    public var isActivated: Bool { activated }

    /// 是否已永久下线（`teardown()` 之后恒真）。
    public var isTornDown: Bool { tornDown }

    /// 绑定会话（D8：登出/换号 → 推进 generation → 丢未决上报 + 清私有音频 + 停播放）。
    public func bindSession(_ session: PlaybackSessionContext) async {
        await coordinator.bindSession(session)
        await reporter.bindSession(session)
    }

    /// 注入私有音频本地化器（M1 拿到真实凭证提供器后调用）。teardown 后拒绝（M11）。
    public func setSourcePreparer(_ preparer: any PlaybackSourcePreparing) async {
        guard !tornDown else { return }
        fetcher = preparer as? any PrivateAudioFetching
        await coordinator.injectCollaborators(reporter: nil, nowPlaying: nil, sourcePreparer: preparer)
    }

    // MARK: - 传输控制（M1 调用面）

    public func start(items: [PlaybackItem], at index: Int = 0) async -> AdvanceOutcome {
        await ensureActivated()
        return await coordinator.start(items: items, at: index)
    }

    public func start() async -> AdvanceOutcome {
        await ensureActivated()
        return await coordinator.start()
    }

    private func ensureActivated() async {
        guard !tornDown, !activated else { return }
        await coordinator.attach()
        try? await audioSession.start()
        await nowPlaying.registerCommands()
        activated = true
    }

    public func pause() async {
        await coordinator.pause()
    }

    public func resume() async {
        await ensureActivated()
        await coordinator.resume()
    }

    public func toggle() async -> PlaybackState {
        await ensureActivated()
        return await coordinator.toggle()
    }

    public func next() async -> AdvanceOutcome {
        await coordinator.next()
    }

    public func previous() async -> AdvanceOutcome {
        await coordinator.previous()
    }

    public func seekTo(_ seconds: Double) async -> SeekOutcome {
        await coordinator.seek(to: seconds)
    }

    /// ±15s 快进/快退（design §4）。
    public func seekBySeconds(_ delta: Double) async -> SeekOutcome {
        await coordinator.seekBySeconds(delta)
    }

    public func setLoopMode(_ mode: LoopMode) async -> LoopMode {
        await coordinator.setLoopMode(mode)
    }

    public func cycleLoopMode() async -> LoopMode {
        await coordinator.cycleLoopMode()
    }

    public func reorder(from: Int, to destination: Int) async -> PlayQueue.Change {
        await coordinator.reorder(from: from, to: destination)
    }

    public func remove(at index: Int) async -> PlayQueue.Change {
        await coordinator.removeItem(at: index)
    }

    public func remove(itemID: String) async -> PlayQueue.Change {
        await coordinator.removeItem(itemID: itemID)
    }

    public func appendToQueue(_ item: PlaybackItem) async -> PlayQueue.Change {
        await coordinator.appendToQueue(item)
    }

    public func insertNext(_ item: PlaybackItem) async -> PlayQueue.Change {
        await coordinator.insertNext(item)
    }

    public func currentSnapshot() async -> PlaybackSnapshot {
        await coordinator.currentSnapshot()
    }

    /// 前后台转场（共用同一去重态；不产生第二次上报）。
    public func handleLifecycle(_ phase: PlaybackLifecyclePhase) async -> [PlayReportOutcome] {
        await reporter.lifecyclePhaseChanged(phase)
    }

    /// 远端命令入口（`MPNowPlayingController` 的 handler 与单测共用）。
    public func handleRemoteCommand(_ command: NowPlayingCommand) async -> NowPlayingStatus {
        await commandRouter.handle(command)
    }

    /// 释放全部系统资源（幂等）。
    ///
    /// 置位 `tornDown` 后门面**永久下线**（M11）：任何再次激活的路径（`resume` / `start` /
    /// `activateForPlayback`）都不会重挂远端 target、不会再激活已反激活的音频会话。
    public func teardown() async {
        guard !tornDown else { return }
        tornDown = true
        activated = false
        nowPlaying.setCommandsEnabled(false)
        await coordinator.teardown()
        await reporter.teardown()
        await audioSession.stop()
        if let fetcher {
            _ = await fetcher.purgeAll()
        }
    }

    deinit {
        // 同步释放：取消事件循环并摘掉时间观察者 / KVO / 通知 token。
        engine.stopAndRelease()
    }
}

/// 默认上报面：NEEDS-2 未解锁（后端 allowlist 尚无 `app-ios`）时使用的**显式不可用**实现。
///
/// 关键取舍：绝不静默丢包 —— 抛 `.offline` 使集次停留在未决态（`pendingCount()` 可观测），
/// 一旦 M1 注入真实 `CovaAPIClient` 即以同一幂等键补发。
public struct UnavailablePlayReporter: PlayReportSubmitting {
    public init() {}

    public func submit(_ request: PlayReportRequestDto) async throws -> PlayReportResponseDto {
        throw CovaAPIError.offline
    }
}
