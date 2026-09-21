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
/// **退出必须摘净自己挂上的 target**：系统不持有 handler target（Apple 明确「targets are not
/// retained」），残留即悬垂 —— 本仓红线。仍持有共享命令面时顺手摘净全部（`removeTarget(nil)`），
/// 已被别人接手时只按自己的 token 摘（Major-1：不碰当前持有者的那条）。
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

    // MARK: - 共享命令面的所有权（min-6）

    /// 进程内「谁最后认领了 `MPRemoteCommandCenter` 这组共享命令」的账。
    ///
    /// 只做事实记录，不做拦截（原因见 TD-43）：系统不给「按所有者查询 target」的能力，
    /// 任何「非所有者就不许动」的实现都会让**已经挂上的** target 留在系统里 —— 那比互踩更糟。
    /// 收敛的那一半是：认领关系变成可查询的票据，于是第二个门面进来时第一个不再蒙在鼓里。
    private final class SharedSurfaceLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var issued: UInt64 = 0
        private var holder: UInt64?

        func claim() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            issued += 1
            holder = issued
            return issued
        }

        /// 认领总次数（进程内单调，永不回收：证明「有没有第二个实例动过共享面」）。
        var claimCount: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return issued
        }

        var currentHolder: UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return holder
        }

        /// 退位：仅当自己仍是当前持有者时清空（别人已经接手则什么都不做）。
        func release(_ ticket: UInt64) {
            lock.lock()
            if holder == ticket { holder = nil }
            lock.unlock()
        }
    }

    private static let sharedSurfaceLedger = SharedSurfaceLedger()

    /// `MPNowPlayingInfoCenter` 那份**读数**的认领账（与命令面分开记，见 `claimInfoSurface`）。
    ///
    /// 为什么必须是两台账：`MPRemoteCommandCenter` 的 `isEnabled`/target 与
    /// `MPNowPlayingInfoCenter` 的字典/`playbackState` 是**两个**进程单例，最后动它们的人
    /// 可以完全不同（B 接手了命令注册，但锁屏上那行字还是 A 最后写的）。合成一台账的话，
    /// 一次 `publish` 就会把命令面的塑形权也顺手抢走 —— 那等于把 Major-1 从 deinit
    /// 挪到 publish 上重演一遍。
    private static let sharedInfoSurfaceLedger = SharedSurfaceLedger()

    /// 本实例最近一次认领共享面的票据（nil = 从未注册过命令、或已随退出释放）。
    private var sharedSurfaceClaim: UInt64?

    /// 本实例最近一次认领**信息面**（Now Playing 字典 / `playbackState`）的票据。
    private var infoSurfaceClaim: UInt64?

    /// 「系统里此刻挂着谁的 handler target」这一件事的账（MAJ-R5-2 的假阴性那一半）。
    ///
    /// 只有 `registerCommands()` 认领它 —— 写 `isEnabled` 不认领：一个 handler 都没挂、
    /// 只碰过命令位的实例，**不是** target 的持有人。旧实现把这两种身份合成一台账
    /// （min-6 的「谁最后塑形谁负责」），于是退出路径会按错的人决定要不要
    /// `removeTarget(nil)` + 关命令位：
    /// - 假阳性：被顶掉者 teardown 把现任的 target 摘光，而现任仍自称持有；
    /// - 假阴性：只写过 `isEnabled` 的实例抢到所有权，它析构时把仍活着的持有者的
    ///   11 条 target 一次摘光。
    /// `ownsSharedCommandSurface` 的语义**不变**（min-6 的塑形事实、既有测试原样保留），
    /// 这里只是把「退出时谁有权塑形整台单例」这条判据换到真正挂着 target 的人身上。
    private static let mountedTargetLedger = SharedSurfaceLedger()

    /// 本实例最近一次认领「挂着 target」的票据（nil = 从未注册过、或已随退出释放）。
    private var mountedTargetClaim: UInt64?

    /// 进程内认领共享命令面的**总次数**（系统侧事实面：> 1 就意味着有第二个实例动过单例）。
    public static var sharedSurfaceClaimCount: UInt64 { sharedSurfaceLedger.claimCount }

    /// 本实例是否仍是共享命令面的当前持有者（min-6 的可查询事实）。
    ///
    /// 这是 `registeredHandlerCount` 的反面：那个数**只说明本层账上记了几条 target**，
    /// 说明不了系统现在听谁的 —— 复审点名的正是这一混淆。
    public var ownsSharedCommandSurface: Bool {
        guard let claim = lockedSharedSurfaceClaim() else { return false }
        return Self.sharedSurfaceLedger.currentHolder == claim
    }

    /// 本实例是否仍是共享**信息面**（锁屏那行字与 `playbackState`）的最后写入者（Major-1）。
    ///
    /// 「最后写的人负责擦」是 `deinit` 敢不敢清 `MPNowPlayingInfoCenter` 的唯一判据：
    /// 别人已经接手了还去清，就是把 Major-1 的「A 析构打死 B」再演一遍。
    public var ownsSharedInfoSurface: Bool {
        guard let claim = lockedInfoSurfaceClaim() else { return false }
        return Self.sharedInfoSurfaceLedger.currentHolder == claim
    }

    /// 系统里此刻挂着的 handler target 是不是本实例的（MAJ-R5-2：退出塑形的唯一依据）。
    ///
    /// 与 `ownsSharedCommandSurface` 刻意分开：后者回答「最后一次 `isEnabled` 是谁写的」，
    /// 这条回答「命令真有人接单吗、接单的是不是我」。**只有挂着 target 的人退出时**才有必要、
    /// 也有资格关掉整台单例的命令位并 `removeTarget(nil)` 摘净。
    public var ownsMountedCommandTargets: Bool {
        guard let claim = lockedMountedTargetClaim() else { return false }
        return Self.mountedTargetLedger.currentHolder == claim
    }

    /// 认领共享面（注册命令、以及任何一次写 `isEnabled` 都算：写的人就是现在的形状负责人）。
    private func claimSharedCommandSurface() {
        let ticket = Self.sharedSurfaceLedger.claim()
        lock.lock()
        sharedSurfaceClaim = ticket
        lock.unlock()
    }

    /// 认领信息面（`publish` 是「我来显示我的内容」：写这份单例的人就是现在的显示负责人。
    /// `clear` **不**认领 —— 它只收走自己显示过的东西，见其注释）。
    private func claimInfoSurface() {
        let ticket = Self.sharedInfoSurfaceLedger.claim()
        lock.lock()
        infoSurfaceClaim = ticket
        lock.unlock()
    }

    /// 释放认领（仅当自己仍是当前持有者）。
    private func releaseSharedCommandSurface() {
        lock.lock()
        let claim = sharedSurfaceClaim
        sharedSurfaceClaim = nil
        lock.unlock()
        if let claim { Self.sharedSurfaceLedger.release(claim) }
    }

    /// 认领「挂着 target」（只有 `registerCommands()` 会做：它先 `removeTarget(nil)` 清场、
    /// 再挂自己那 11 条 ⇒ 从这一刻起系统听的就是它）。
    private func claimMountedTargets() {
        let ticket = Self.mountedTargetLedger.claim()
        lock.lock()
        mountedTargetClaim = ticket
        lock.unlock()
    }

    /// 退掉「挂着 target」的账（仅当自己仍是持有人）。
    private func releaseMountedTargets() {
        lock.lock()
        let claim = mountedTargetClaim
        mountedTargetClaim = nil
        lock.unlock()
        if let claim { Self.mountedTargetLedger.release(claim) }
    }

    private func lockedMountedTargetClaim() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return mountedTargetClaim
    }

    /// 同上，信息面。
    private func releaseInfoSurface() {
        lock.lock()
        let claim = infoSurfaceClaim
        infoSurfaceClaim = nil
        lock.unlock()
        if let claim { Self.sharedInfoSurfaceLedger.release(claim) }
    }

    private func lockedSharedSurfaceClaim() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return sharedSurfaceClaim
    }

    private func lockedInfoSurfaceClaim() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return infoSurfaceClaim
    }

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
    ///
    /// min-6（本批收敛到「可观测」；系统不给的那一半立 TD-43）：
    /// `MPRemoteCommandCenter` 是**进程单例**，因此这里的「先清后加」以及
    /// `setCommandsEnabled` / `teardown` 都作用于全部 11 条命令、与调用者是谁无关 ——
    /// 同进程装配第二个门面会把第一个的 target 抹掉，而 `registeredHandlerCount`
    /// 只是**自我申报**（MediaPlayer 不公开 `targets`，系统侧读数不可得：TD-39）。
    /// 现在每次注册都认领共享面（进程内单调票据）：「我被别人顶掉了」从静默失守
    /// 变成 `ownsSharedCommandSurface` / `sharedSurfaceClaimCount` 两个问得出的事实。
    /// MAJ-R5-2 另补一条：注册同时认领「挂着 target」（`ownsMountedCommandTargets`）——
    /// 退出时谁有权塑形整台单例，只看这一条，不看「最后一次 `isEnabled` 是谁写的」。
    public func registerCommands() async {
        claimSharedCommandSurface()
        claimMountedTargets()
        let center = Self.sharedCenter()
        for name in Self.managedCommandNames {
            guard let command = Self.command(in: center, named: name) else { continue }
            let make = Self.commandMaker(named: name)
            command.removeTarget(nil)
            let token = command.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                guard let translated = make(event) else { return .commandFailed }
                return Self.acceptAndDeliver(router: self.router, command: translated)
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

    /// 远端命令 handler：**受理即返回 + 异步投递**（MAJ-6）。
    ///
    /// 旧实现是 `DispatchSemaphore(value: 0)` + **无超时** `wait()`，把路由链搬回同步形态 ——
    /// 代价是把**系统自己的队列**钉在一条含下载挂起点的 actor 链上
    /// （`resume()` → `loadCurrent` → `prepareSource` → 私有音频取回），
    /// 上界就是 `URLSessionPrivateAudioTransport.resourceTimeout`（**7 天**）；
    /// 复审实测 parked 0.424s（夹具放行之前零推进）。这期间排在系统队列上的其它命令
    /// （暂停、下一首、Control Center 事件）与播放本身一起被拖住。
    ///
    /// 新形态两件事，各自可测：
    /// 1. `acceptanceStatus(for:)` —— **零 hop 的纯函数**受理判定（只有同步可判的那一点参与
    ///    返回码：seek 目标合法性，用的就是 `NowPlayingStatusMapping` 那份判定）；
    /// 2. `deliver(router:command:)` —— 起一条 `Task` 跑完整命令链，**不等它**。
    ///
    /// 命令结果如何回到系统：`MPRemoteCommandHandlerStatus` 只表达「收没收下」，
    /// 真正的播放状态由协调器在每次状态转移时 `publish` 到 `MPNowPlayingInfoCenter`
    /// （`playbackState` + 信息字典）—— 那本来就是异步面（design §7「锁屏只是入口」）。
    ///
    /// 已知取舍（如实标注）：底层失败（如 `.noSuchContent`）不再能从返回码告知系统，
    /// 系统因此不会自动回滚按钮态；口径与上面一致，状态以 Now Playing 回显为准。
    static func acceptAndDeliver(
        router: NowPlayingCommandRouter,
        command: NowPlayingCommand
    ) -> MPRemoteCommandHandlerStatus {
        let status = acceptanceStatus(for: command)
        // 已经同步判死的命令不再投递（`NowPlayingCommandRouter.handle` 里那第二条合法性
        // 检查保留：它是决策面的自守，不是本处的依赖）。
        if status == .success { deliver(router: router, command: command) }
        return status
    }

    /// 受理判定（**纯函数、零 hop、零 await**）：这是 handler 唯一允许用来决定返回码的东西。
    ///
    /// 判据的另一半在 `NowPlayingCommandRouter.handle`（那里会真跑命令链）：本函数**不得**
    /// 出现任何 `await` —— 一旦出现，系统队列就又回到「被播放器钉住」的形态（MAJ-6）。
    static func acceptanceStatus(for command: NowPlayingCommand) -> MPRemoteCommandHandlerStatus {
        if case .seek(let target) = command,
           NowPlayingStatusMapping.isLegalTimeTarget(target) == false {
            return .commandFailed
        }
        return .success
    }

    /// 投递：把命令交给 actor 链跑完，**不等待结果**（MAJ-6 的另一半）。
    ///
    /// `onDelivered` 是**投递完成之后的记账点**，默认什么都不做：
    /// - 生产形态不需要它（返回码早在受理那一刻就定下来了，状态回显走 Now Playing）；
    /// - 它存在的理由是让「异步投递真的跑完了」变成可等待的事实（测试据此做确定性会合，
    ///   不必靠让步或计时器猜 —— D16⑤），也是将来要加「失败回传/上报」时的唯一挂点。
    static func deliver(
        router: NowPlayingCommandRouter,
        command: NowPlayingCommand,
        onDelivered: @escaping @Sendable (NowPlayingStatus) -> Void = { _ in }
    ) {
        Task { onDelivered(await router.handle(command)) }
    }

    /// 系统 command center 单例。
    public static func sharedCenter() -> MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    /// 受管命令实体（`setCommandsEnabled` 与冒烟断言共用）。
    public static func controllableCommands(_ center: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        managedCommandNames.compactMap { command(in: center, named: $0) }
    }

    public func setCommandsEnabled(_ enabled: Bool) {
        // min-6：写共享面即认领共享面 —— 「谁最后塑形，谁负责」，且这件事是查得到的事实。
        claimSharedCommandSurface()
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
        // 写信息面即认领信息面：与 `setCommandsEnabled` 同一条规矩（谁最后塑形，谁负责）。
        claimInfoSurface()
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
        // 过期回写（Major-1 的同一族）：封面是在途任务里取回来的，取回来时**信息面可能已经换人**
        // （第二个门面 publish 过）。这时把「自己那一份字典」整体写回去，就是用一份
        // 已经不属于任何播放器的元数据盖掉当前显示 —— 跳过，连本层账也不改。
        guard ownsSharedInfoSurface else { return }
        lock.lock()
        var info = lastPublishedInfo ?? [:]
        info[Self.artworkAttachedKey] = true
        lastPublishedInfo = info
        lock.unlock()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 封面挂载标记的字典键（自定义键；系统忽略未知键，仅测试可见）。
    public static let artworkAttachedKey = "CovaArtworkAttached"

    /// 擦掉 Now Playing 读数（**只在仍是信息面负责人时**写，见 Major-1）。
    ///
    /// 与 `publish` 相反：`publish` 是「我来显示我的内容」（写即认领），`clear` 是「把我显示的内容收走」。
    /// 已经换人显示之后再由后来者擦一次，就是把 A 的收尾变成对 B 的显示的攻击 —— 与 `deinit`
    /// 那条同一个判据、同一个理由。信息面仍归本实例时它才擦，并且**不认领**：
    /// `teardown()` 因此对非持有者天然无害。
    public func clear() async {
        takeArtworkTask()?.cancel()
        guard ownsSharedInfoSurface else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [:]
        center.playbackState = .stopped
    }

    public func teardown() async {
        await clear()
        // 与 `deinit` 兜底**同一个**实现（MAJ-7 要求两条路径收敛到同一终态；第 9 批起它是字面意义上的
        // 同一个函数，不再是「两条各写一遍、其中一条对」）。
        retireSystemSurfacesSynchronously()
    }

    /// 摘净系统侧 target（同步、幂等）。
    ///
    /// 只有**仍持有共享命令面**的实例才有资格做「一次摘掉全部 target」：它同时是那个
    /// 替别人收尾的人（`registerCommands()` 接手时也是先 `removeTarget(nil)`，见 Major-1 的论证）。
    private func retireAllSharedCommandTargets() {
        for command in Self.controllableCommands(Self.sharedCenter()) {
            command.removeTarget(nil)
        }
    }

    /// 按**自己登记的 token** 逐条摘 target（Major-1：非持有者的退出面）。
    ///
    /// `MPRemoteCommand.removeTarget(_:)` 收的是 `addTarget` 交回来的那个不透明 target 句柄，
    /// 因此这条路**只**摘掉自己挂上去的那 11 条，别人（当前持有者）的 target 一条都不碰。
    /// 账目同时清零：调用后 `handlerTargets` 为空，`registeredHandlerCount` 归零。
    private func retireOwnCommandTargets() {
        let own = lockedTakeHandlerTargets()
        let center = Self.sharedCenter()
        for (name, token) in own {
            Self.command(in: center, named: name)?.removeTarget(token)
        }
    }

    /// 取出并清空本层 token 账（同步临界区；NSLock 不进 async 上下文）。
    private func lockedTakeHandlerTargets() -> [(name: String, token: Any)] {
        lock.lock()
        defer { lock.unlock() }
        let taken = handlerTargets.map { (name: $0.key, token: $0.value) }
        handlerTargets = [:]
        return taken
    }

    /// **同步**退掉系统面（MAJ-7：门面 `deinit` 只能走这条路，deinit 里不能 await）。
    ///
    /// 与 `teardown()` 是**同一个**实现，收敛到的终态按**所有权**分形（Major-1 / MAJ-R5-2）：
    ///
    /// - **系统里挂着的 target 就是自己的**（`ownsMountedCommandTargets`）：整台单例归自己负责 ——
    ///   关掉全部 11 条命令位 + `removeTarget(nil)` 摘净 + 退位。
    /// - **不是**（自己的 target 已被接手者清场，或自己从没注册过）：只清算自己名下那一套 ——
    ///   按自己的 token 摘 target，**不碰** `isEnabled`。旧实现在这里无条件塑形，于是
    ///   「A 注册 → B 接手 → A 析构」把 B 的锁屏控制整体下线（复审实测：
    ///   `center.playCommand.isEnabled` 由 true 变 false）；而按「谁最后写 `isEnabled`」判据的话，
    ///   一个 handler 都没挂的实例也能在析构时把仍活着的持有者摘光（MAJ-R5-2 的假阴性）。
    /// - 信息面（`MPNowPlayingInfoCenter`）同一条判据、各记各的账（`ownsSharedInfoSurface`）：
    ///   最后写它的人才擦它 —— 别人正在显示的曲名不是自己该擦的。
    ///
    /// 原三条不变量都还在：
    /// - `removeTarget` **不许**以任何理由跳过 —— 系统不持有 target，留着就是「命令还在被投给
    ///   一个已经死掉的播放器」。非持有者走 token 形态，同样一条不剩；旧版「非持有者跳过就会悬垂」
    ///   的两难并不成立：`registerCommands()` 接手时已对全部受管命令 `removeTarget(nil)`，
    ///   被顶掉者名下早已没有遗留 target（TD-43 的「做不到」不覆盖这条）。
    /// - 清 Now Playing 字典是同一件事的另一半：不清，锁屏会继续显示已释放门面的曲名与
    ///   「正在播放」—— 而**由谁清**就是本次修的那一半。
    /// - `isEnabled` 一并关闭，否则控制中心仍把按钮画成可点（同上：只在仍是负责人时关）。
    /// - 在途封面任务必须一起取消：否则它会在字典已清空之后再把封面写回去（复活已死门面）。
    ///
    /// 幂等：`teardown()` 之后再释放、或从未 `teardown()` 就释放，结果相同。
    func retireSystemSurfacesSynchronously() {
        // MAJ-R5-2：命令位的塑形与摘净全部 target 的**唯一**依据是「此刻挂着 target 的是不是我」
        // —— 「最后一次写 `isEnabled` 的人」那条账（min-6 的 `ownsSharedCommandSurface`）不授予
        // 这个权力，否则一个 handler 都没挂的实例就能在析构时把仍活着的持有者摘光。
        let ownsTargets = ownsMountedCommandTargets
        let ownsInfo = ownsSharedInfoSurface
        if ownsTargets {
            for command in Self.controllableCommands(Self.sharedCenter()) {
                command.isEnabled = false
            }
            retireAllSharedCommandTargets()
        } else {
            retireOwnCommandTargets()
        }
        // 在途封面任务必须一起取消（自己名下那一条，与所有权无关）。
        takeArtworkTask()?.cancel()
        if ownsInfo {
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        releaseSharedCommandSurface()
        releaseMountedTargets()
        releaseInfoSurface()
        completeTeardown()
    }

    /// 兜底（MAJ-7）：从未 `teardown()` 就被释放时，同样必须退系统面。
    ///
    /// 这里不能 await，所以走上面那条同步路径；`teardown()` 已经执行过时它是空操作。
    deinit {
        retireSystemSurfacesSynchronously()
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
