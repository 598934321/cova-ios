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
    /// 注入别的 origin **不会**放宽任何判定 —— `isAllowedEgress` 的第一重永远是
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
            setItem(avItem)
            attachObservers(to: avItem, episode: episode)
            player.replaceCurrentItem(with: avItem)
            continuation.yield(.buffering)
        }
    }

    public func play() async {
        setWantsPlayback(true)
        player.play()
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

    public func setRate(_ rate: Double) async {
        guard rate.isFinite, rate > 0 else { return }
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
        setWantsPlayback(false)
        player.pause()
        // 释放同样推进代际：在途回调（含通知线程上已排队的 ended）从此不再进入事件流。
        _ = detachObservers()
        player.replaceCurrentItem(with: nil)
        lock.lock()
        releasedCount += 1
        lock.unlock()
    }

    // MARK: - 纯映射（可零硬件单测）

    /// 条目 → 可播地址。需 Bearer 的一律拒绝（D7 的第二道闸）；
    /// 公开直链还必须落在唯一生产出口（MAJ-8，AGENTS 硬边界 2 / D10）。
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
            guard Self.isAllowedEgress(url.value, origin: egressOrigin) else {
                return .failure(PlayerFailure(
                    kind: .invalidSourceURL,
                    message: "公开直链不在唯一生产出口（D10）"
                ))
            }
            return .success(url.value)
        }
    }

    /// 公开直链的出口判定（MAJ-8）：两重都必须成立。
    /// ① `CovaEnvironment.isProductionOrigin` —— 与私有音频准备器**同一判据、同一实现**（D10）；
    /// ② 权威仍是门面声明的那个出口（scheme + host + 规范端口折叠同源，见 `AudioAuthorityMatch`）。
    /// ②让 `assetOrigin` 真的说了算，①保证注入任何别的 origin 都不可能把出口放宽到别处。
    public static func isAllowedEgress(_ url: URL, origin: URL) -> Bool {
        guard CovaEnvironment.isProductionOrigin(url) else { return false }
        return AudioAuthorityMatch.origin(of: url) == AudioAuthorityMatch.origin(of: origin)
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

    /// 播放意图记账（`NSLock` 只在同步上下文，故独立成方法）。
    private func setWantsPlayback(_ value: Bool) {
        lock.lock()
        wantsPlayback = value
        lock.unlock()
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
        lock.lock()
        let current = item
        let episode = gate.episode
        let playing = wantsPlayback
        lock.unlock()
        // KVO token 已随换件移除，但仍可能有一条在途回调进来：只认「仍是当前装载的那一件」。
        guard let current, (object as? AVPlayerItem) === current else { return }
        for event in Self.observedEvents(
            forKeyPath: keyPath,
            status: current.status,
            duration: current.duration,
            playing: playing
        ) {
            deliverObserved(event, from: episode)
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
