import Foundation

/// Now Playing 元数据（锁屏 / 控制中心展示面）。
///
/// `artworkURL` 是脱敏载体：本类型**不含位图**，位图由 UI 层实现的外挂器取回
/// （`MPMediaItemArtwork` 的构造需要 UIKit 类型，而播放器层被门禁禁止引入 UI 框架 ——
/// 见 `docs/log/20260921.md` 冲突处理 C4）。
public struct NowPlayingMetadata: Equatable, Sendable {
    public let itemID: String
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: Double?
    public let elapsed: Double
    public let playbackRate: Double
    public let isPlaying: Bool
    public let artworkURL: AudioURL?

    public init(
        itemID: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil,
        elapsed: Double = 0,
        playbackRate: Double = 1,
        isPlaying: Bool = false,
        artworkURL: AudioURL? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = max(0, elapsed)
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.artworkURL = artworkURL
    }
}

/// 元数据发布面（生产 = `MPNowPlayingController`；单测 = 记录桩）。
public protocol NowPlayingControlling: Sendable {
    func publish(_ metadata: NowPlayingMetadata) async
    func clear() async
    /// 释放：**必须**清空所有 target（通知残留 / 悬垂是本仓红线）。
    func teardown() async
}

/// 封面外挂器：由 UI 层（CovaUI/CovaFeature）实现，播放器层只负责异步调度。
public protocol NowPlayingArtworkAttaching: Sendable {
    /// 取回并挂载封面；返回是否已挂载。**不得**在主 actor 上同步等待。
    func attachArtwork(for metadata: NowPlayingMetadata) async -> Bool
}

/// 锁屏/耳机远端命令（`MPRemoteCommandCenter` 命令集的 UI 无关表示）。
public enum NowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    /// 绝对跳转（`seekToHandler` / `changePlaybackPositionHandler`）。
    case seek(to: Double)
    /// ±15s（`skipForwardHandler` / `skipBackwardHandler`，preferredIntervals）。
    case skipForward(seconds: Double)
    case skipBackward(seconds: Double)
    /// 变速（`changePlaybackRateHandler`）。
    case changeRate(to: Double)

    /// 命令携带的时间目标（用于 `invalidTimeTarget` 判定）。
    public var timeTarget: Double? {
        switch self {
        case .seek(let target): return target
        default: return nil
        }
    }
}

/// 远端命令处理结果（与 `MPRemoteCommandHandlerStatus` 一一对应，但 UI 无关 → 可断言）。
public enum NowPlayingStatus: String, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    /// 命令已受理并生效。
    case success
    /// 无可播内容（空队列 / 无当前项 / 边界无邻居）。
    case noSuchContent
    /// 尚未就绪（已释放 / 引擎未接）。
    case notReadyToPlay
    /// 命令参数非法或底层失败。
    case failure

    public var description: String { rawValue }
}

/// 命令 → 结果的映射（纯函数，`PlaybackCoordinator` 的返回码在此收敛）。
public enum NowPlayingStatusMapping {
    /// 时间目标合法性：必须是有限非负数（越界由 ±15s 钳制规则处理，不算非法）。
    public static func isLegalTimeTarget(_ raw: Double?) -> Bool {
        guard let raw else { return true }
        return raw.isFinite && raw >= 0
    }

    public static func status(for advance: AdvanceOutcome) -> NowPlayingStatus {
        switch advance {
        case .advanced, .repeated, .stopped:
            return .success
        case .held:
            // 边界无邻居（.off/.one 下越界）：锁屏侧应报「无此内容」而非假成功。
            return .noSuchContent
        case .rejected(let rejection):
            switch rejection {
            case .emptyQueue: return .noSuchContent
            case .noCurrentItem: return .notReadyToPlay
            case .tornDown: return .notReadyToPlay
            }
        }
    }

    public static func status(for seek: SeekOutcome) -> NowPlayingStatus {
        switch seek {
        case .applied:
            return .success
        case .rejected(let rejection):
            switch rejection {
            case .noCurrentItem: return .noSuchContent
            case .nonFiniteTarget: return .failure
            case .tornDown: return .notReadyToPlay
            }
        }
    }

    public static func status(for state: PlaybackState, hasCurrentItem: Bool) -> NowPlayingStatus {
        guard hasCurrentItem else { return .noSuchContent }
        return state == .idle ? .notReadyToPlay : .success
    }
}

/// 远端命令路由：把 `NowPlayingCommand` 变成 coordinator 调用 + 状态码。
///
/// **weak 持有 coordinator** 以打断 `coordinator → controller → router → coordinator` 的
/// 循环引用（门禁要求「teardown 后对象已释放」可断言）。
///
/// 刻意不是 actor：唯一的可变状态是「一次性回填的 weak 引用」，用锁保护即可，
/// 于是门面可以在**同步 init** 里完成接线（不需要 fire-and-forget 任务，保持确定性）。
public final class NowPlayingCommandRouter: @unchecked Sendable {
    private let lock = NSLock()
    private weak var weakCoordinator: PlaybackCoordinator?

    public init(coordinator: PlaybackCoordinator? = nil) {
        weakCoordinator = coordinator
    }

    /// 回填 coordinator（`init` 里对象自身尚未就绪，故需两步接线）。
    public func bind(_ coordinator: PlaybackCoordinator?) {
        lock.lock()
        defer { lock.unlock() }
        weakCoordinator = coordinator
    }

    /// 当前绑定的协调器（teardown 断言 `nil` 用）。
    public var boundCoordinator: PlaybackCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        return weakCoordinator
    }

    private func coordinatorRef() -> PlaybackCoordinator? { boundCoordinator }

    /// 命令是否可用（用于 `command.isEnabled`）。
    public func isAvailable(_ command: NowPlayingCommand) async -> Bool {
        guard let coordinator = coordinatorRef() else { return false }
        let snapshot = await coordinator.currentSnapshot()
        switch command {
        case .play, .pause, .togglePlayPause, .seek, .skipForward, .skipBackward, .changeRate:
            return snapshot.item != nil
        case .nextTrack, .previousTrack:
            return snapshot.queueCount > 0
        }
    }

    public func handle(_ command: NowPlayingCommand) async -> NowPlayingStatus {
        guard let coordinator = coordinatorRef() else { return .notReadyToPlay }
        if case .seek(let target) = command,
           NowPlayingStatusMapping.isLegalTimeTarget(target) == false {
            return .failure
        }
        switch command {
        case .play:
            guard await coordinator.hasCurrentItem() else { return .noSuchContent }
            await coordinator.resume()
            return .success
        case .pause:
            guard await coordinator.hasCurrentItem() else { return .noSuchContent }
            await coordinator.pause()
            return .success
        case .togglePlayPause:
            guard await coordinator.hasCurrentItem() else { return .noSuchContent }
            _ = await coordinator.toggle()
            return .success
        case .nextTrack:
            return NowPlayingStatusMapping.status(for: await coordinator.next())
        case .previousTrack:
            return NowPlayingStatusMapping.status(for: await coordinator.previous())
        case .seek(let target):
            return NowPlayingStatusMapping.status(for: await coordinator.seek(to: target))
        case .skipForward(let seconds):
            return NowPlayingStatusMapping.status(for: await coordinator.seekBySeconds(abs(seconds)))
        case .skipBackward(let seconds):
            return NowPlayingStatusMapping.status(for: await coordinator.seekBySeconds(-abs(seconds)))
        case .changeRate(let rate):
            guard await coordinator.hasCurrentItem() else { return .noSuchContent }
            let applied = await coordinator.setPlaybackRate(rate)
            return applied == rate ? .success : .failure
        }
    }
}
