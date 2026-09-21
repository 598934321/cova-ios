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
/// - 唯一网络出口是 `https://covalink.cn`（`CovaEnvironment`，D10）；`assetOrigin` 就是这条出口
///   的**注入点**：默认装配把它交给 `AVPlayerEngine` 作为公开直链的判定基准（MAJ-8），
///   不再只是「被断言一次然后没人用」的字段；
/// - 私有音频（D7）经 `PrivateAudioFetcher` 先落盘校验、再以 `file://` 播放；
///   Bearer / 签名地址以 `AudioURL` 形态存在，不进日志、不进持久化；
/// - `deinit` 同步释放引擎（`stopAndRelease`）并**退掉系统面**（远端命令 / Now Playing），
///   音频会话观测者由 `AVAudioSessionAdapter.deinit` 兜底摘除（MAJ-7）；
/// - 音频会话激活失败**不被吞掉**（MAJ-5）：门面无 `try?`，失败留在
///   `audioSessionActivationFailure`，且 `isActivated` 只在激活真的成功时为真；
///   系统面（观测者 / 远端命令）的注册与「激活是否成功」脱钩。
@MainActor
public final class CovaPlayer {
    /// 资源出口（钉死为生产 origin；既有 `CovaTests` 断言其语义，不得退化）。
    ///
    /// MAJ-8：这个值**被消费**——未注入引擎时，门面用 `assetOrigin` 装配默认
    /// `AVPlayerEngine`，而该引擎拿它当公开直链的出口判定基准。改出口必须动这里，
    /// 只改断言不会生效。
    public let assetOrigin: URL

    public let coordinator: PlaybackCoordinator
    public let engine: any PlayerEngine
    public let nowPlaying: MPNowPlayingController
    public let commandRouter: NowPlayingCommandRouter
    public let audioSession: AudioSessionGate
    public let reporter: PlayReportCoordinator
    /// 私有音频本地化器；未注入时为 nil（此时需 Bearer 的条目一律拒绝播放，绝不绕过 D7）。
    public private(set) var fetcher: (any PrivateAudioFetching)?
    /// 注入的源准备器本体（D8 的清理面 `discardPrivateAudio(owner:)` 挂在它上面，F-13）。
    private var sourcePreparer: (any PlaybackSourcePreparing)?
    /// 最近一次绑定的会话视图：只有知道「上一个身份是谁」，才可能把它留下的字节清干净。
    private var boundSession = PlaybackSessionContext.unauthenticated

    private let clock: any CovaClock
    private var activated = false
    /// `teardown()` 之后门面永久下线：重新接线会造出「引擎事件循环已摘除、却在出声」的半死状态。
    private var tornDown = false
    /// 最近一次**音频会话激活失败**（MAJ-5）。
    ///
    /// 旧实现是 `try? await audioSession.start()`：错误被吞掉后，门面对外仍然自称
    /// `isActivated == true`，于是真机上「他人占用会话 / 通话中」这种常见形态会表现成
    /// 「播放莫名其妙没声音、UI 却说一切正常」。现在错误**必须**留在这里并可被上层读到，
    /// 同时 `activated` 只在真的激活成功时才置位（状态面不许说谎）。
    ///
    /// 类型是 `Error?` 而不是 `PlayerError?`：`configureForPlayback()` 之外没有别的换算可做，
    /// 把未知错误硬编成一个 `PlayerError` case 等于再制造一次信息损失。
    public private(set) var audioSessionActivationFailure: Error?
    /// 远端命令面是否已挂上系统（MAJ-5：这与「会话激活成功」是两件事，分开记账）。
    public private(set) var isRemoteCommandSurfaceRegistered = false

    /// 默认出口 = 生产 API origin（D10）。
    public convenience init() {
        self.init(assetOrigin: CovaEnvironment.apiBaseURL)
    }

    /// 依赖注入形态（单测与 M1 装配用）。
    ///
    /// - Parameter engine: 播放引擎；`nil` = 生产默认 `AVPlayerEngine(egressOrigin: assetOrigin)`。
    ///   刻意把「默认引擎」的构造放进 `init` 体内而不是参数默认值里 —— 只有这样才能让
    ///   `assetOrigin` 真的决定引擎承认的那台出口（MAJ-8）。注入别的引擎（单测桩）时
    ///   出口判定由该实现自己负责，门面不做二次猜测。
    public init(
        assetOrigin: URL = CovaEnvironment.apiBaseURL,
        engine: (any PlayerEngine)? = nil,
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
        let playbackEngine = engine ?? AVPlayerEngine(egressOrigin: assetOrigin)
        let playback = PlaybackCoordinator(
            engine: playbackEngine,
            clock: clock,
            reporter: report,
            nowPlaying: controller,
            sourcePreparer: sourcePreparer
        )
        self.assetOrigin = assetOrigin
        self.engine = playbackEngine
        self.clock = clock
        self.commandRouter = router
        self.nowPlaying = controller
        self.reporter = report
        self.audioSession = AudioSessionGate(
            system: audioSystem,
            handler: AudioSessionCommandHandler(coordinator: playback)
        )
        self.coordinator = playback
        self.sourcePreparer = sourcePreparer
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
    ///
    /// MAJ-5：会话激活失败**不掩掉系统面注册**。观测者注册在 `AudioSessionGate.start()` 内部
    /// 已排在 `configureForPlayback()` 之前，远端命令注册在这里也不得排在「激活成功」之后才发生 ——
    /// 否则 design §7（锁屏 / 中断后续播）在会话被他人占用时又静默失效一次。
    /// 失败仍然照实抛出（本方法是 throwing 面），并由 `audioSessionActivationFailure` 留痕。
    public func activateForPlayback() async throws {
        guard !tornDown else { return }
        guard !activated else { return }
        await coordinator.attach()
        let activationFailure = await startAudioSession()
        await nowPlaying.registerCommands()
        nowPlaying.setCommandsEnabled(true)
        isRemoteCommandSurfaceRegistered = true
        activated = activationFailure == nil
        if let activationFailure { throw activationFailure }
    }

    /// 启动音频会话并把失败**记账后交回调用方**（MAJ-5：门面侧禁止 `try?` 吞错）。
    ///
    /// 返回 nil = 激活成功；返回错误 = 已留痕在 `audioSessionActivationFailure`。
    /// 成功时清掉旧失败记录，避免「上一次失败」被误读成当前状态。
    private func startAudioSession() async -> Error? {
        do {
            try await audioSession.start()
            audioSessionActivationFailure = nil
            return nil
        } catch {
            audioSessionActivationFailure = error
            return error
        }
    }

    public var isActivated: Bool { activated }

    /// 是否已永久下线（`teardown()` 之后恒真）。
    public var isTornDown: Bool { tornDown }

    /// 本门面的控制器是否仍是**共享命令面**（`MPRemoteCommandCenter` 是进程单例）的当前持有者
    /// （min-6）。同进程装配第二个门面并注册命令后，这里必须变成 `false` ——
    /// 旧实现里这件事完全静默：`registeredHandlerCount` 只申报自己账上有几条 target，
    /// 说不出「系统现在听谁的」。
    public var ownsSharedCommandSurface: Bool { nowPlaying.ownsSharedCommandSurface }

    /// 绑定会话（D8：登出/换号 → 推进 generation → 丢未决上报 + 清私有音频 + 停播放）。
    ///
    /// 缺陷 F-13：这一支以前只丢上报、停引擎、清队列 —— **盘上的私有音频一个字节都没动过**，
    /// 于是「仅本人可见」的音频在登出/换号后继续躺在缓存里等着被下一次装载复用。
    /// 清理走 `PlaybackSourcePreparing.discardPrivateAudio(owner:)`（协议面），
    /// 因此装配里不存在「忘了 purge」的形态。
    public func bindSession(_ session: PlaybackSessionContext) async {
        let previous = boundSession
        boundSession = session
        await coordinator.bindSession(session)
        await reporter.bindSession(session)
        await discardPrivateAudio(of: previous, supersededBy: session)
    }

    /// 失效判定与 `PlaybackCoordinator.bindSession` 同一口径：登出 / 换号 / generation 推进
    /// （不含「首次登录」）。`PlaybackSessionContext` 只有 owner 与 generation 两个字段，
    /// 因此「两者都没变」= 同一个会话视图 = 未失效。
    private func discardPrivateAudio(
        of previous: PlaybackSessionContext,
        supersededBy next: PlaybackSessionContext
    ) async {
        guard previous != next, let outgoing = previous.owner else { return }
        if next.owner == outgoing, let fetcher {
            // 同一账号只是代次推进：旧代次文件（文件名带 `@g<generation>`）已成孤儿、
            // 永远取不到，但当前代次的缓存仍然属于本人且可用 → 精确回收，不牵连有效缓存。
            _ = await fetcher.purgeStale(before: next.generation)
            return
        }
        // 换号 / 登出：上一个身份的私有音频一个字节都不能留在沙盒里。
        await sourcePreparer?.discardPrivateAudio(owner: outgoing)
    }

    /// 注入私有音频本地化器（M1 拿到真实凭证提供器后调用）。teardown 后拒绝（M11）。
    public func setSourcePreparer(_ preparer: any PlaybackSourcePreparing) async {
        guard !tornDown else { return }
        sourcePreparer = preparer
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
        // MAJ-5：这里曾是 `try? await audioSession.start()` —— 吞掉错误之后仍然置位
        // `activated = true`，于是「会话没起来」在门面外部完全不可观测（状态面说谎）。
        let activationFailure = await startAudioSession()
        await nowPlaying.registerCommands()
        isRemoteCommandSurfaceRegistered = true
        activated = activationFailure == nil
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
    ///
    /// F-C：回前台的补发与**仍在途**的那一路提交撞上同一集次时让路
    /// （`.submissionInFlight`），于是一次实际播放始终只有一个写请求。
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
        isRemoteCommandSurfaceRegistered = false
        nowPlaying.setCommandsEnabled(false)
        await coordinator.teardown()
        await reporter.teardown()
        await audioSession.stop()
        // D8：私有音频一个字节都不留。两道面都走：协议清理面（覆盖「任何会落盘的准备器」，
        // MAJ-2 之后它是必须实现的成员）与取回清理面（覆盖 `PrivateAudioFetching` 那一侧）
        // —— 二者都是幂等全清。
        await sourcePreparer?.discardPrivateAudio(owner: nil)
        if let fetcher {
            _ = await fetcher.purgeAll()
        }
    }

    deinit {
        // 同步释放：取消事件循环并摘掉时间观察者 / KVO / 通知 token。
        engine.stopAndRelease()
        // MAJ-7：析构**必须**退系统面。旧实现只做了引擎那一件事，于是走「没 teardown 就释放」
        // 这条真实路径（App 里门面是随作用域生死的一次性装配）之后：`playCommand.isEnabled`
        // 仍为 true、锁屏还显示着已死门面的曲名、`playbackState` 仍是 playing ——
        // 系统把命令投给一个已经不存在的播放器。
        // 这里只能是同步路径（deinit 不能 await）：`retireSystemSurfacesSynchronously()` 与
        // `teardown()` 走的是同一批退出动作（摘 target / 关命令位 / 清 Now Playing 字典）。
        // 音频会话那一侧的观测者 token 由 `AVAudioSessionAdapter.deinit` 兜底摘除
        // （门释放 → 适配器释放 → 兜底生效；`AudioSessionGate.stop()` 是常规路径，deinit 是漏路径的兜底）。
        nowPlaying.retireSystemSurfacesSynchronously()
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
