import MediaPlayer
import Foundation

// MARK: - 远端命令适配（薄适配器）

/// `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` 适配层。
///
/// 决策全部在 `NowPlayingCommandRouter` + `PlaybackCoordinator`（可桩、可断言）；
/// 本类型只负责四件事：
/// 1. 注册命令 handler；2. 把 `MPRemoteCommandEvent` 翻译成 `NowPlayingCommand`；
/// 3. 把 `NowPlayingStatus` 翻译成 `MPRemoteCommandHandlerStatus`；4. 写 Now Playing 信息字典。
///
/// **teardown 必须移除全部 target**：系统不持有 handler target（Apple 明确「targets are not
/// retained」），残留即悬垂 —— 本仓红线。
public final class MPNowPlayingController: NowPlayingControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let router: NowPlayingCommandRouter
    private var artworkAttacher: (any NowPlayingArtworkAttaching)?
    private var artworkTask: Task<Void, Never>?
    /// `addTarget(handler:)` 返回的不透明 target 句柄：**必须由本对象强持有**。
    private var handlerTargets: [String: Any] = [:]
    private var teardownCount = 0
    /// 最近一次发布的信息字典（纯映射结果，测试可断言）。
    internal private(set) var lastPublishedInfo: [String: Any]?

    /// ±15s 的 skip 节拍（design/screens/02-player.md §4）。
    public static let skipInterval: Double = 15

    public init(router: NowPlayingCommandRouter, artworkAttacher: (any NowPlayingArtworkAttaching)? = nil) {
        self.router = router
        self.artworkAttacher = artworkAttacher
    }

    /// 封面挂载器注入点（生产实现在 UI 层，见冲突说明 C4）。
    public func setArtworkAttacher(_ attacher: (any NowPlayingArtworkAttaching)?) {
        lock.lock()
        artworkAttacher = attacher
        lock.unlock()
    }

    // MARK: - 命令注册

    /// 纯映射：命令名 + 事件携带的量 → `NowPlayingCommand`（不可识别即 nil）。
    ///
    /// 事件类（`MPChangePlaybackPositionCommandEvent` 等）无公开 init，故把「取值后的决策」
    /// 收敛到这里，可以零构造地穷举断言；适配器只负责向下转型取字段。
    public static func remoteCommand(
        named name: String,
        positionTime: Double? = nil,
        playbackRate: Double? = nil
    ) -> NowPlayingCommand? {
        switch name {
        case "play": return .play
        case "pause": return .pause
        case "togglePlayPause": return .togglePlayPause
        case "nextTrack": return .nextTrack
        case "previousTrack": return .previousTrack
        case "seekForward", "skipForward": return .skipForward(seconds: skipInterval)
        case "seekBackward", "skipBackward": return .skipBackward(seconds: skipInterval)
        case "changePlaybackPosition": return positionTime.map { .seek(to: $0) }
        case "changePlaybackRate": return playbackRate.map { .changeRate(to: $0) }
        default: return nil
        }
    }

    /// 命令名 → 事件翻译（向下转型取字段后交给纯映射）。
    public static func commandMaker(named name: String) -> (MPRemoteCommandEvent) -> NowPlayingCommand? {
        { event in
            switch name {
            case "changePlaybackPosition":
                guard let position = event as? MPChangePlaybackPositionCommandEvent else { return nil }
                return remoteCommand(named: name, positionTime: position.positionTime)
            case "changePlaybackRate":
                guard let rate = event as? MPChangePlaybackRateCommandEvent else { return nil }
                return remoteCommand(named: name, playbackRate: Double(rate.playbackRate))
            default:
                return remoteCommand(named: name)
            }
        }
    }

    /// 注册的命令名（`seekForward/Backward` 与 `skipForward/Backward` 都接：前者是系统耳机口径，
    /// 后者带 `preferredIntervals`，二者语义都是 ±15s）。
    public static let managedCommandNames: [String] = [
        "play", "pause", "togglePlayPause", "nextTrack", "previousTrack",
        "seekForward", "seekBackward", "skipForward", "skipBackward",
        "changePlaybackPosition", "changePlaybackRate",
    ]

    /// 按名取命令实体。
    public static func command(in center: MPRemoteCommandCenter, named name: String) -> MPRemoteCommand? {
        switch name {
        case "play": return center.playCommand
        case "pause": return center.pauseCommand
        case "togglePlayPause": return center.togglePlayPauseCommand
        case "nextTrack": return center.nextTrackCommand
        case "previousTrack": return center.previousTrackCommand
        case "seekForward": return center.seekForwardCommand
        case "seekBackward": return center.seekBackwardCommand
        case "skipForward": return center.skipForwardCommand
        case "skipBackward": return center.skipBackwardCommand
        case "changePlaybackPosition": return center.changePlaybackPositionCommand
        case "changePlaybackRate": return center.changePlaybackRateCommand
        default: return nil
        }
    }

    /// 注册全部锁屏 / 耳机远端命令（幂等：先清后加，不叠加 target）。
    public func registerCommands() async {
        let center = Self.sharedCenter()
        for name in Self.managedCommandNames {
            guard let command = Self.command(in: center, named: name) else { continue }
            let make = Self.commandMaker(named: name)
            command.removeTarget(nil)
            let token = command.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                guard let translated = make(event) else { return .commandFailed }
                return Self.handleSynchronously(router: self.router, command: translated)
            }
            recordTarget(token, for: name)
        }
        let intervals = [Self.skipNumber]
        center.skipForwardCommand.preferredIntervals = intervals
        center.skipBackwardCommand.preferredIntervals = intervals
        center.changePlaybackRateCommand.supportedPlaybackRates = [Self.defaultRateNumber]
    }

    /// 登记 handler target（系统不持有 target，必须由本对象强持有）。
    ///
    /// `NSLock` 不得进 async 上下文，故登记动作单独成同步方法。
    private func recordTarget(_ token: Any, for name: String) {
        lock.lock()
        handlerTargets[name] = token
        lock.unlock()
    }

    public static var skipNumber: NSNumber { NSNumber(value: skipInterval) }
    public static var defaultRateNumber: NSNumber { NSNumber(value: 1) }

    /// 远端命令 handler 必须**同步**返回状态码，故在此桥接 actor 调用。
    ///
    /// 系统在自己的队列上调用 handler（非主线程），且路由链不触碰主 actor → 无自死锁；
    /// 单测不打到这里（改测 `NowPlayingCommandRouter` 的纯决策）。
    static func handleSynchronously(
        router: NowPlayingCommandRouter,
        command: NowPlayingCommand
    ) -> MPRemoteCommandHandlerStatus {
        // 局部 var 被 @Sendable 闭包捕获会触发 region isolation 诊断，故经显式盒子传递
        // （读写两侧由信号量串行化，盒子自身不再假设线程安全）。
        let box = StatusBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.status = await router.handle(command)
            semaphore.signal()
        }
        semaphore.wait()
        return handlerStatus(for: box.status)
    }

    /// `handleSynchronously` 的结果载体。
    final class StatusBox: @unchecked Sendable {
        var status: NowPlayingStatus = .failure
    }

    /// 状态码映射（纯函数）。
    public static func handlerStatus(for status: NowPlayingStatus) -> MPRemoteCommandHandlerStatus {
        switch status {
        case .success: return .success
        case .noSuchContent: return .noSuchContent
        case .notReadyToPlay: return .noActionableNowPlayingItem
        case .failure: return .commandFailed
        }
    }

    /// 系统 command center 单例。
    public static func sharedCenter() -> MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    /// 受管命令实体（`setCommandsEnabled` 与冒烟断言共用）。
    public static func controllableCommands(_ center: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        managedCommandNames.compactMap { command(in: center, named: $0) }
    }

    public func setCommandsEnabled(_ enabled: Bool) {
        for command in Self.controllableCommands(Self.sharedCenter()) {
            command.isEnabled = enabled
        }
    }

    // MARK: - Now Playing 信息

    /// 元数据 → `MPNowPlayingInfoCenter` 字典（纯函数，可断言）。
    public static func infoDictionary(for metadata: NowPlayingMetadata) -> [String: Any] {
        // 速率必须是 Double：字典值为 Any 时三元里的 `0` 会被推成 Int，系统侧读数不一致。
        let publishedRate: Double = metadata.isPlaying ? metadata.playbackRate : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: metadata.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: metadata.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: publishedRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: metadata.playbackRate,
        ]
        if let album = metadata.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = metadata.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        return info
    }

    public func publish(_ metadata: NowPlayingMetadata) async {
        let info = Self.infoDictionary(for: metadata)
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = metadata.isPlaying ? .playing : .paused
        center.nowPlayingInfo = info
        // NSLock 不得进 async 上下文：加锁段落收敛在下面的同步辅助方法里。
        let attacher = recordPublished(info)
        guard let attacher, metadata.artworkURL != nil else { return }
        // 封面异步挂载：不在当前 actor 上等，也不阻塞主线程（design §7）。
        let task = Task { [weak self] in
            let attached = await attacher.attachArtwork(for: metadata)
            guard attached, Task.isCancelled == false else { return }
            self?.mergeArtworkAttached()
        }
        assignArtworkTask(task)
    }

    /// 记录已发布信息并返回当前封面挂载器（同时取消上一次的挂载任务）。
    private func recordPublished(_ info: [String: Any]) -> (any NowPlayingArtworkAttaching)? {
        lock.lock()
        defer { lock.unlock() }
        lastPublishedInfo = info
        artworkTask?.cancel()
        artworkTask = nil
        return artworkAttacher
    }

    private func assignArtworkTask(_ task: Task<Void, Never>) {
        lock.lock()
        artworkTask = task
        lock.unlock()
    }

    private func takeArtworkTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let task = artworkTask
        artworkTask = nil
        lastPublishedInfo = nil
        return task
    }

    private func completeTeardown() {
        lock.lock()
        defer { lock.unlock() }
        handlerTargets = [:]
        teardownCount += 1
    }

    /// 等待封面任务落地（测试用信号式等待，不做时间猜测）。
    public func waitForArtworkTask() async {
        let task = peekArtworkTask()
        _ = await task?.value
    }

    private func peekArtworkTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return artworkTask
    }

    private func mergeArtworkAttached() {
        lock.lock()
        var info = lastPublishedInfo ?? [:]
        info[Self.artworkAttachedKey] = true
        lastPublishedInfo = info
        lock.unlock()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 封面挂载标记的字典键（自定义键；系统忽略未知键，仅测试可见）。
    public static let artworkAttachedKey = "CovaArtworkAttached"

    public func clear() async {
        takeArtworkTask()?.cancel()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [:]
        center.playbackState = .stopped
    }

    public func teardown() async {
        await clear()
        for command in Self.controllableCommands(Self.sharedCenter()) {
            command.removeTarget(nil)
        }
        completeTeardown()
    }

    /// 已持有的 handler target 数（注册后 = 命令数；teardown 后必须 = 0）。
    public var registeredHandlerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlerTargets.count
    }

    public var registeredHandlerNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return handlerTargets.keys.sorted()
    }

    public var observedTeardownCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return teardownCount
    }
}
