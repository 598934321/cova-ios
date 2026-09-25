import AVFoundation
import CovaCore
import Foundation

/// `AVPlayer` 薄适配器（D4）。
///
/// 刻意做薄：只做「地址 → AVPlayerItem → 事件」的搬运，
/// 一切队列 / 循环 / ±15s / 失败连击决策都在 `PlaybackCoordinator`（可确定性测试）。
///
/// 边界守卫（**两道**）：`load(_:)` 只接受**可直接播**的条目 ——
/// 1. 需 Bearer 的条目在这里被拒绝（`.localizationRequired`），D7 的第二道闸；
/// 2. `.publicDirect` 的 https 地址必须落在**唯一生产出口**（MAJ-8：AGENTS 硬边界 2 / D10）。
///    这道判定只能在这里做：`AVPlayer` 自己发起网络请求，而公开直链**从不经过**私有音频准备器
///    （准备器只管 Bearer 那一路），所以出口守卫在引擎以下没有任何执行点。
///    判定只有 `CovaEnvironment.isPublicDirectEgressAllowed` 那一份（本层经 `PlayerEgress`
///    转授）；D23② 的存储桶名单在这一条上**不适用**，理由写在那个函数的注释里。
///
/// 不使用 Combine KVO（Swift 6 下 `Observable` 已弃用会报警告），改用传统字符串 KVO +
/// 通知中心；所有观测者与 token 都在 `stopAndRelease()` 中移除（通知残留是本仓红线）。
public final class AVPlayerEngine: NSObject, PlayerEngine, @unchecked Sendable {
    /// 周期时间观察者的节拍（秒）。
    public static let periodicTimeInterval: Double = 0.5

    private let lock = NSLock()
    private let player: AVPlayer
    /// 本引擎承认的唯一媒体出口（MAJ-8）。门面的 `assetOrigin` 就是从这里进生产路径的
    /// —— 它不再是「只被断言一次、没人消费的死字段」。
    private let egressOrigin: URL
    private var item: AVPlayerItem?
    private var timeObserverToken: Any?
    private var endNotificationToken: NSObjectProtocol?
    private var observedKeyPaths: [String] = []
    private let stream: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var lastReportedSecond: Double?
    /// 观测者回调的装载代际闸门（迟到/重复事件在 `yield` 之前丢弃）。
    private var gate = EngineEventGate()
    /// **播放意图**（`play()` 置真、`pause()`/释放置假）。
    ///
    /// 「就绪 / 缓冲恢复」是引擎状态，不是用户意图：用户显式暂停后 AVPlayer 仍可能上报
    /// `readyToPlay` 或 `playbackLikelyToKeepUp`，若一律翻成 `.playing` 就会把暂停悄悄改回播放
    /// 并向锁屏发布 `isPlaying = true`（缺陷 M10）。观测者只在意图为「在播」时才上报播放。
    private var wantsPlayback = false
    /// 暂停期间收到的目标速率；`play()` 落地时应用（生命周期见 `setRate` 的契约注释）。
    private var pendingRate: Double?

    /// 观测者计数（**仅供测试断言 teardown 归零**；生产不使用）。
    internal private(set) var liveTimeObserverCount = 0
    internal private(set) var liveNotificationObserverCount = 0
    internal private(set) var liveKeyValueObserverCount = 0
    internal private(set) var releasedCount = 0
    /// 当前装载代际（观测者块捕获的就是它）。
    internal var currentEpisode: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return gate.episode
    }

    public convenience override init() {
        self.init(egressOrigin: CovaEnvironment.apiBaseURL)
    }

    /// 指定出口形态（MAJ-8）：`CovaPlayer` 用它的 `assetOrigin` 装配生产默认引擎。
    /// 注入别的 origin **不会**放宽任何判定 —— `PlayerEgress.isPlayable` 的第一重永远是
    /// `CovaEnvironment.isProductionOrigin`，因此非法出口只会「一律拒绝」（fail-closed）。
    public init(egressOrigin: URL) {
        // 有界缓冲会把 .ended/.failed 挤掉，故用 unbounded（消费者是常驻循环，不会积压）
        let pairing = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .unbounded)
        self.stream = pairing.0
        self.continuation = pairing.1
        self.egressOrigin = egressOrigin
        self.player = AVPlayer()
        super.init()
        self.player.actionAtItemEnd = .pause
    }

    /// 当前生效的唯一媒体出口（诊断与冒烟断言用）。
    public var currentEgressOrigin: URL { egressOrigin }

    public var events: AsyncStream<PlayerEvent> { stream }

    deinit {
        releaseInternally()
    }

    // MARK: - PlayerEngine

    public func load(_ item: PlaybackItem) async {
        switch Self.playableURL(for: item, egressOrigin: egressOrigin) {
        case .failure(let failure):
            // 被拒绝的装载**不推进代际**：此时引擎里仍是上一件在播（既没换件也没摘观测者），
            // 上一件的事件依然是事实，不得丢弃。失败本身由协调器侧的装载代际账本收敛。
            continuation.yield(.failed(failure))
            return
        case .success(let url):
            let episode = detachObservers()
            let avItem = AVPlayerItem(url: url)
            // 换件的瞬间，针对**上一件**提的待用速率作废（R14-2 的 `load` 一侧；
            // 被拒绝的装载走上面的 failure 分支，不清 —— 那时引擎里仍是上一件在播）。
            discardPendingRateForNewItem()
            setItem(avItem)
            attachObservers(to: avItem, episode: episode)
            player.replaceCurrentItem(with: avItem)
            continuation.yield(.buffering)
        }
    }

    public func play() async {
        // 状态转移一次做完（置意图 + 取待用速率），`player.*` 留在锁外（R14-3）。
        let pending = startPlaybackTakingPendingRate()
        player.play()
        if let pending {
            // 暂停期间收到的改速请求在这里生效 —— 那时 `setRate` 只记不下发（见下方契约）。
            player.rate = Float(pending)
        }
        continuation.yield(.playing)
    }

    public func pause() async {
        setWantsPlayback(false)
        player.pause()
        continuation.yield(.paused)
    }

    public func seek(to seconds: Double) async {
        guard seconds.isFinite else { return }
        await player.seek(to: Self.time(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// **改速不等于起播**（第 13 轮 R13-1 的根因）：AVPlayer 的 `rate = x` 赋值会顺手起播，
    /// 于是暂停期间一次纯改速会把刚摁停的引擎重新放响。引擎契约因此是：不在「要播」状态时
    /// 只记待用速率，等 `play()` 落地再生效。
    ///
    /// **待用槽的生命周期**（第 14 轮 R14-2：每一次清空都为了「上一个持有者的命令不得由
    /// 下一个持有者执行」；第 21 轮 R15-2 查出不等价的两条边**零测试**，本段随之给每条边
    /// 点名它的钉死用例 —— 五条边现在各自都有「改动此处 ⇒ 该条变红」的可测后果
    /// （两条变异的实测红色计数记在本批 commit message；评审出处
    /// `docs/review-g3e-round4.md` 第 15 轮 R15-2）：
    ///   · `play()` —— **取走并清空**（与置真意图同一段锁内完成）。
    ///     钉它的是 `testTakenPendingRateDoesNotOverrideANewerRateOnTheNextStart`：
    ///     中间插一次「播放中当场改速」，再走第二次 `play()` —— 漏掉清空就是把已消费的
    ///     陈旧速率重新写回 `player.rate`，盖掉更新过的那一个；
    ///   · `pause()` —— **保留**：暂停期里改的速就是等下一次起播生效的那一个。
    ///     钉它的是 `testPauseKeepsThePendingRateAcrossARepeatedPause`：形状必须是
    ///     「**先记待用、后摁暂停**」（「对已经暂停的引擎再摁一次 pause」是真形状：
    ///     协调器公开的 `pause()` 对不可暂停状态照样摁、装载入口为摁住旧声摁一次
    ///     （`loadCurrent`）、`pauseEngineIfStillOwned` 五处收敛腿各摁一次），
    ///     在 pause 的状态转移里插一句清空就是把用户挑的速率悄悄退回默认；
    ///   · `stopAndRelease()` —— **清空**：引擎已不属于任何持有者，留着它下一次 `play()`
    ///     就会以上一个持有者的速率起播（评审在真机引擎上实测到的泄漏）。
    ///     钉它的是 `testPendingRateDoesNotOutliveRelease`；
    ///   · `load(_:)` 接受新条目 —— **清空**：待用速率是针对**被换掉那一条**提的请求，
    ///     新条目没有继承它的道理。协调器每次起播后都会自己下 `setRate`
    ///     （`PlaybackCoordinator.loadCurrent`），所以这里清空不丢功能，
    ///     只关掉跨持有者泄漏的另一个入口。钉它的是 `testPendingRateDoesNotCrossANewLoadedItem`；
    ///   · 被**拒绝**的装载（D7 / MAJ-8）不清空：引擎里仍是上一件在播，那一件才是这条速率
    ///     的主人。钉它的是 `testRejectedLoadKeepsPendingRateForTheItemStillInEngine`。
    public func setRate(_ rate: Double) async {
        guard rate.isFinite, rate > 0 else { return }
        // 「判意图」与「记待用」是一份状态的两半，必须落在同一段锁里（R14-3）。
        guard rateCommandsPlayerNow(rate) else { return }
        player.rate = Float(rate)
    }

    public func currentRate() async -> Double {
        Double(player.rate)
    }

    public func currentTime() async -> Double {
        Self.seconds(player.currentTime()) ?? 0
    }

    public func currentDuration() async -> Double? {
        guard let current = lockedCurrentItem() else { return nil }
        return Self.seconds(current.duration)
    }

    public func stopAndRelease() {
        // 意图 / 待用速率 / 释放计数在同一段锁内一并落定（R14-2 + R14-3）。
        markReleased()
        player.pause()
        // 释放同样推进代际：在途回调（含通知线程上已排队的 ended）从此不再进入事件流。
        _ = detachObservers()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 纯映射（可零硬件单测）

    /// 条目 → 可播地址。需 Bearer 的一律拒绝（D7 的第二道闸）；
    /// 公开直链还必须落在唯一生产出口（MAJ-8，AGENTS 硬边界 2 / D10），
    /// 被拒时失败必须**点名落地 host**（D23③：只有 host，path/query 一概不带）。
    ///
    /// - Parameter egressOrigin: 本引擎承认的那一台主机。默认就是生产 origin，
    ///   因此「忘了传」只会走向最严的一侧。
    public static func playableURL(
        for item: PlaybackItem,
        egressOrigin: URL = CovaEnvironment.apiBaseURL
    ) -> Result<URL, PlayerFailure> {
        switch item.audioSource {
        case .bearerRequired:
            return .failure(PlayerFailure(
                kind: .localizationRequired,
                message: "私有音频必须先本地化再播放"
            ))
        case .localized(let url):
            guard url.isLocalized else {
                return .failure(PlayerFailure(kind: .invalidSourceURL, message: "本地地址形态异常"))
            }
            return .success(url.value)
        case .publicDirect(let url):
            guard url.scheme == .https else {
                return .failure(PlayerFailure(kind: .invalidSourceURL, message: "地址协议不受支持"))
            }
            // 判在**交给 AVPlayerItem 之前**：一旦交出去，网络请求就是 `AVPlayer` 自己发的，
            // 本层再也拦不住（`.publicDirect` 不经过私有音频准备器，那里那道出口守卫管不到它）。
            // 判定本身在 `CovaEnvironment.isPublicDirectEgressAllowed`（唯一一份，D23③）：
            // 本层只转授，被拒时按 `egressHostLabel` 口径**点名落地 host**（只有 host）。
            return PlayerEgress.decide(direct: url.value, origin: egressOrigin)
        }
    }

    /// `CMTime` → 秒（未定/无效一律 nil，避免 NaN 污染状态）。
    /// `invalid` / `indefinite` / NaN 都会让 `CMTimeGetSeconds` 返回非有限值，故一次判定即可。
    public static func seconds(_ time: CMTime) -> Double? {
        let raw = CMTimeGetSeconds(time)
        guard raw.isFinite, raw >= 0 else { return nil }
        return raw
    }

    public static func time(_ seconds: Double) -> CMTime {
        guard seconds.isFinite, seconds >= 0 else { return .zero }
        return CMTime(seconds: seconds, preferredTimescale: 1000)
    }

    /// 状态 → 事件（nil = 无需上报）。
    public static func event(for status: AVPlayerItem.Status) -> PlayerEvent? {
        switch status {
        case .readyToPlay:
            return .playing
        case .failed:
            return .failed(PlayerFailure(kind: .mediaInvalid, message: "媒体项状态异常"))
        case .unknown:
            return .buffering
        @unknown default:
            return .buffering
        }
    }

    /// 状态 → 事件（**带播放意图**，缺陷 M10）。
    ///
    /// `.readyToPlay` 只说明「可以出声」，不说明「用户要在听」：意图为假时上报 `.paused`
    /// （协调器侧 `.paused` 只在「本就在播」时才改状态，双向都不会把暂停翻回播放）。
    public static func event(for status: AVPlayerItem.Status, playing: Bool) -> PlayerEvent? {
        guard let event = event(for: status) else { return nil }
        if case .playing = event { return readinessEvent(playing: playing) }
        return event
    }

    /// 「就绪 / 缓冲恢复」类事件 → 上报值（纯函数）。
    public static func readinessEvent(playing: Bool) -> PlayerEvent {
        playing ? .playing : .paused
    }

    /// KVO 路径表（teardown 断言用）。
    public static let observedKeyPathList: [String] = ["status", "playbackBufferEmpty", "playbackLikelyToKeepUp"]

    // MARK: - 观测者管理

    /// `NSLock` 只能在**同步**上下文使用（Swift 6 禁止在 async 函数里 lock/unlock）：
    /// 所有加锁段落都收敛在这些非 async 的辅助方法里。
    ///
    /// 共享状态的收敛点（第 14 轮 R14-3 之后，这句要能一行一行对上）：
    /// `item` / `gate` / 观测者记账 / `releasedCount` 走本文件的 `lock`，
    /// 而**播放意图与待用速率这一对**（`wantsPlayback` + `pendingRate`）只允许出现在
    /// 下面 `MARK: - 锁内状态转移：意图与速率` 那一区里 —— 它们是一份状态的两半
    /// （「现在能不能直接下发」与「不能下发时记谁的值」），分两处判必然分叉。
    /// `play()` / `setRate()` / `pause()` / `stopAndRelease()` 这些 async 或半 async 入口
    /// 只经**一次**辅助调用完成转移，`player.*` 一律留在锁外（与观测者回调同一口径）。
    /// 自查方式（第 21 批 R15-7 拆掉同义死重复 `discardPendingRate()` 之后重跑，本批实测
    /// 全文 18 处命中 = 声明 2 处 + 注释 5 处 + 代码 11 处，代码那 11 处**全部**在下一区
    /// 「锁内状态转移：意图与速率」之内，区外零读写）：
    /// `grep -n "wantsPlayback\b\|pendingRate\b" AVPlayerEngine.swift`。
    private func setItem(_ avItem: AVPlayerItem?) {
        lock.lock()
        item = avItem
        lock.unlock()
    }

    private func lockedCurrentItem() -> AVPlayerItem? {
        lock.lock()
        defer { lock.unlock() }
        return item
    }


    private func attachObservers(to avItem: AVPlayerItem, episode: UInt64) {
        let interval = CMTime(seconds: Self.periodicTimeInterval, preferredTimescale: 1000)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            guard let seconds = Self.seconds(time) else { return }
            self.lock.lock()
            let alreadyReported = self.lastReportedSecond.map { abs($0 - seconds) < 0.05 } ?? false
            self.lastReportedSecond = seconds
            self.lock.unlock()
            guard !alreadyReported else { return }
            self.deliverObserved(.position(seconds: seconds), from: episode)
        }
        lock.lock()
        timeObserverToken = token
        liveTimeObserverCount += 1
        lock.unlock()

        let endToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: avItem,
            queue: nil
        ) { [weak self] _ in
            // 通知可能已在别的线程投递途中，`removeObserver` 拦不住那一条 ——
            // 捕获的装载代际才是唯一的判据（迟到 ended 多跳一首的根因）。
            self?.deliverObserved(.ended, from: episode)
        }
        lock.lock()
        endNotificationToken = endToken
        liveNotificationObserverCount += 1
        lock.unlock()

        for path in Self.observedKeyPathList {
            avItem.addObserver(self, forKeyPath: path, options: [.new], context: nil)
        }
        lock.lock()
        observedKeyPaths = Self.observedKeyPathList
        liveKeyValueObserverCount += Self.observedKeyPathList.count
        lock.unlock()
    }

    /// 观测者 / 通知回调的**唯一**投递入口（同一条代码路径也被单测直接驱动）。
    ///
    /// 返回值表示是否真的进了事件流；被丢弃的都是「已被取代的条目」或「同一代重复的 ended」。
    @discardableResult
    internal func deliverObserved(_ event: PlayerEvent, from episode: UInt64) -> Bool {
        lock.lock()
        let allowed = gate.accepts(event, from: episode)
        lock.unlock()
        guard allowed else { return false }
        continuation.yield(event)
        return true
    }

    // MARK: - 锁内状态转移：意图与速率（R14-3）
    //
    // 本区之外**不得**出现 `wantsPlayback` / `pendingRate` 的读写（声明与本区除外）。
    // 每条辅助都是「判定 + 写入」一次做完的非 async 函数；调用方拿到返回值后再决定要不要
    // 命令 `player`，命令本身一律在锁外发（`NSLock` 不可跨 await，也不可包住可能回调的 API）。

    /// 播放意图置真，并**一次取走**待用速率（`play()` 的唯一状态转移，R14-2/R14-3）。
    private func startPlaybackTakingPendingRate() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        wantsPlayback = true
        let pending = pendingRate
        pendingRate = nil
        return pending
    }

    /// 「改速」的状态转移：在要播状态 → 返回真（调用方负责下发 `player.rate`）；
    /// 不在要播状态 → 把值写进待用槽并返回假（改速 ≠ 起播）。
    private func rateCommandsPlayerNow(_ rate: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard wantsPlayback else {
            pendingRate = rate
            return false
        }
        return true
    }

    /// 显式暂停 / 起播之外的意图翻转（`pause()` 用；释放走 `markReleased`）。
    ///
    /// 刻意**不**清待用速率：暂停期里收到的改速就是要等下一次 `play()` 生效的那一个
    /// （R15-2：第 21 批之前这句只是嘴上说的 —— 在本区插一句 `pendingRate = nil`
    /// 全量 415 条 0 失败；现在钉它的是
    /// `AVPlayerEngineTests.testPauseKeepsThePendingRateAcrossARepeatedPause`）。
    private func setWantsPlayback(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        wantsPlayback = value
    }

    /// 释放：意图 + 待用速率 + 释放计数一段落定（R14-2 的泄漏点就在这里补的）。
    private func markReleased() {
        lock.lock()
        defer { lock.unlock() }
        wantsPlayback = false
        pendingRate = nil
        releasedCount += 1
    }

    /// 接受新条目时清空待用速率（锁内；契约见 `setRate` 的生命周期注释）。
    ///
    /// 本区**只**留这一条「清空待用速率」的辅助（R15-7：原先并存一条同义的
    /// `discardPendingRate()`，零调用点 —— 两条同义写法正是「改了一条、漏了另一条」的入口）。
    /// `markReleased()` 的清的是「连同意图一起」的释放语义，与此处不同轴，故不合并。
    private func discardPendingRateForNewItem() {
        lock.lock()
        defer { lock.unlock() }
        pendingRate = nil
    }

    /// KVO 回调的**一次性快照**：「引擎装着谁 / 当代代际 / 用户意图」三者同段取。
    /// 有了它，`observeValue` 就不必自己碰字段（本区之外不得出现 `wantsPlayback` 的直接读）。
    private func observerSnapshot() -> (current: AVPlayerItem?, episode: UInt64, playing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (item, gate.episode, wantsPlayback)
    }

    /// 当前播放意图（单测断言 `play()`/`pause()`/释放后的意图翻转）。
    internal var currentPlaybackIntent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsPlayback
    }

    /// 摘掉上一件的观测者并**推进装载代际**（返回新代际，供新观测者捕获）。
    private func detachObservers() -> UInt64 {
        lock.lock()
        let token = timeObserverToken
        let endToken = endNotificationToken
        let paths = observedKeyPaths
        let target = item
        timeObserverToken = nil
        endNotificationToken = nil
        observedKeyPaths = []
        lastReportedSecond = nil
        if token != nil { liveTimeObserverCount = max(0, liveTimeObserverCount - 1) }
        if endToken != nil { liveNotificationObserverCount = max(0, liveNotificationObserverCount - 1) }
        liveKeyValueObserverCount = max(0, liveKeyValueObserverCount - paths.count)
        let episode = gate.advance()
        lock.unlock()
        if let token { player.removeTimeObserver(token) }
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        if let target {
            for path in paths {
                target.removeObserver(self, forKeyPath: path, context: nil)
            }
        }
        return episode
    }

    private func releaseInternally() {
        _ = detachObservers()
        continuation.finish()
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath else { return }
        let snapshot = observerSnapshot()
        // KVO token 已随换件移除，但仍可能有一条在途回调进来：只认「仍是当前装载的那一件」。
        guard let current = snapshot.current, (object as? AVPlayerItem) === current else { return }
        for event in Self.observedEvents(
            forKeyPath: keyPath,
            status: current.status,
            duration: current.duration,
            playing: snapshot.playing
        ) {
            deliverObserved(event, from: snapshot.episode)
        }
    }

    /// KVO 路径 → 应上报的事件序列（**纯判定**，零硬件、可穷举断言）。
    ///
    /// `observeValue` 只负责「取当下快照 + 投递」，映射规则全部收敛在这里 —— 包括 M10 的
    /// 播放意图口径：`readyToPlay` / `likelyToKeepUp` 只有在意图为「在播」时才上报 `.playing`。
    static func observedEvents(
        forKeyPath keyPath: String,
        status: AVPlayerItem.Status,
        duration: CMTime,
        playing: Bool
    ) -> [PlayerEvent] {
        switch keyPath {
        case "status":
            var events: [PlayerEvent] = []
            if let event = event(for: status, playing: playing) { events.append(event) }
            if status == .readyToPlay, let seconds = seconds(duration) {
                events.append(.duration(seconds: seconds))
            }
            return events
        case "playbackBufferEmpty":
            return [.buffering]
        case "playbackLikelyToKeepUp":
            return [readinessEvent(playing: playing)]
        default:
            return []
        }
    }
}
