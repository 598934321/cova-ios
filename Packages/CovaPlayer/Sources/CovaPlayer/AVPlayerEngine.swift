import AVFoundation
import Foundation

/// `AVPlayer` 薄适配器（D4）。
///
/// 刻意做薄：只做「地址 → AVPlayerItem → 事件」的搬运，
/// 一切队列 / 循环 / ±15s / 失败连击决策都在 `PlaybackCoordinator`（可确定性测试）。
///
/// 边界守卫：`load(_:)` 只接受**可直接播**的条目（公开直链或已本地化 `file://`）；
/// 需 Bearer 的条目在这里被拒绝（`.localizationRequired`），于是 D7 有第二道闸。
///
/// 不使用 Combine KVO（Swift 6 下 `Observable` 已弃用会报警告），改用传统字符串 KVO +
/// 通知中心；所有观测者与 token 都在 `stopAndRelease()` 中移除（通知残留是本仓红线）。
public final class AVPlayerEngine: NSObject, PlayerEngine, @unchecked Sendable {
    /// 周期时间观察者的节拍（秒）。
    public static let periodicTimeInterval: Double = 0.5

    private let lock = NSLock()
    private let player: AVPlayer
    private var item: AVPlayerItem?
    private var timeObserverToken: Any?
    private var endNotificationToken: NSObjectProtocol?
    private var observedKeyPaths: [String] = []
    private let stream: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var lastReportedSecond: Double?

    /// 观测者计数（**仅供测试断言 teardown 归零**；生产不使用）。
    internal private(set) var liveTimeObserverCount = 0
    internal private(set) var liveNotificationObserverCount = 0
    internal private(set) var liveKeyValueObserverCount = 0
    internal private(set) var releasedCount = 0

    public override init() {
        // 有界缓冲会把 .ended/.failed 挤掉，故用 unbounded（消费者是常驻循环，不会积压）
        let pairing = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .unbounded)
        self.stream = pairing.0
        self.continuation = pairing.1
        self.player = AVPlayer()
        super.init()
        self.player.actionAtItemEnd = .pause
    }

    public var events: AsyncStream<PlayerEvent> { stream }

    deinit {
        releaseInternally()
    }

    // MARK: - PlayerEngine

    public func load(_ item: PlaybackItem) async {
        switch Self.playableURL(for: item) {
        case .failure(let failure):
            continuation.yield(.failed(failure))
            return
        case .success(let url):
            detachObservers()
            let avItem = AVPlayerItem(url: url)
            setItem(avItem)
            attachObservers(to: avItem)
            player.replaceCurrentItem(with: avItem)
            continuation.yield(.buffering)
        }
    }

    public func play() async {
        player.play()
        continuation.yield(.playing)
    }

    public func pause() async {
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
        player.pause()
        detachObservers()
        player.replaceCurrentItem(with: nil)
        lock.lock()
        releasedCount += 1
        lock.unlock()
    }

    // MARK: - 纯映射（可零硬件单测）

    /// 条目 → 可播地址。需 Bearer 的一律拒绝（D7 的第二道闸）。
    public static func playableURL(for item: PlaybackItem) -> Result<URL, PlayerFailure> {
        switch item.audioSource {
        case .bearerRequired:
            return .failure(PlayerFailure(
                kind: .localizationRequired,
                message: "私有音频必须先本地化再播放"
            ))
        case .publicDirect(let url), .localized(let url):
            guard url.isLocalized || url.scheme == .https else {
                return .failure(PlayerFailure(kind: .invalidSourceURL, message: "地址协议不受支持"))
            }
            return .success(url.value)
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


    private func attachObservers(to avItem: AVPlayerItem) {
        let interval = CMTime(seconds: Self.periodicTimeInterval, preferredTimescale: 1000)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            guard let seconds = Self.seconds(time) else { return }
            self.lock.lock()
            let alreadyReported = self.lastReportedSecond.map { abs($0 - seconds) < 0.05 } ?? false
            self.lastReportedSecond = seconds
            self.lock.unlock()
            guard !alreadyReported else { return }
            self.continuation.yield(.position(seconds: seconds))
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
            self?.continuation.yield(.ended)
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

    private func detachObservers() {
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
        lock.unlock()
        if let token { player.removeTimeObserver(token) }
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        if let target {
            for path in paths {
                target.removeObserver(self, forKeyPath: path, context: nil)
            }
        }
    }

    private func releaseInternally() {
        detachObservers()
        continuation.finish()
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath else { return }
        switch keyPath {
        case "status":
            lock.lock()
            let current = item
            lock.unlock()
            guard let current, let event = Self.event(for: current.status) else { return }
            continuation.yield(event)
            if current.status == .readyToPlay, let seconds = Self.seconds(current.duration) {
                continuation.yield(.duration(seconds: seconds))
            }
        case "playbackBufferEmpty":
            continuation.yield(.buffering)
        case "playbackLikelyToKeepUp":
            continuation.yield(.playing)
        default:
            break
        }
    }
}
