import Foundation

/// 引擎上报的播放事件（`PlaybackCoordinator` 的唯一外部事实来源）。
///
/// `position` 与 `duration` 都以秒为单位；`failed` 携带分类原因，
/// 供「连续 3 次失败进入终态」的裁决使用（design/screens/02-player.md §9）。
public enum PlayerEvent: Equatable, Sendable {
    case playing
    case paused
    case buffering
    /// 播放位置推进（周期性观察者上报）。
    case position(seconds: Double)
    /// 引擎实测到真实时长（可能与契约 `duration` 不同）。
    case duration(seconds: Double)
    /// 当前项播完。
    case ended
    case failed(PlayerFailure)
}

/// 引擎失败分类。
///
/// **安全**：`message` 是分类描述文本，**类型层面不存在 URL 字段**，
/// 因此错误经日志/断言描述都不会带出签名地址（AGENTS 硬边界 3）。
public struct PlayerFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// 需要 Bearer 的地址未经本地化就被要求播放（D7 违例）。
        case localizationRequired
        /// 本地文件缺失 / 空文件。
        case missingFile
        /// 地址协议/形态不受支持（无法交给播放器）。
        case invalidSourceURL
        /// 网络类失败（可重试）。
        case network
        /// 解码 / 不支持的媒体。
        case mediaInvalid
        /// 引擎状态异常。
        case engine
        /// 被取消（不计入失败连击）。
        case cancelled
    }

    public let kind: Kind
    /// 诊断文本：**不得**包含地址、query 或凭证。
    public let message: String

    public init(kind: Kind, message: String = "") {
        self.kind = kind
        self.message = message
    }

    /// 是否计入「连续失败」计数（取消不算失败）。
    public var countsTowardFailureStreak: Bool { kind != .cancelled }

    public var description: String {
        message.isEmpty ? kind.rawValue : "\(kind.rawValue): \(message)"
    }
}

/// 播放引擎抽象 —— **注入点**。
///
/// 生产实现 = `AVPlayerEngine`（薄适配器）；单测 = 脚本化桩（零 AVFoundation、零音频硬件）。
///
/// 约定：
/// - 事件只经 `events` 流上报，实现方不得直接回调 coordinator；
/// - `load(_:)` 不抛错：失败一律以 `.failed` 事件表达（避免 coordinator 各处 do/catch）；
/// - `stopAndRelease()` 必须是**同步**的，以便在 `deinit` 中安全释放观察者与播放器。
public protocol PlayerEngine: AnyObject, Sendable {
    /// 事件流（多次访问返回同一贯穿生命周期的流）。
    var events: AsyncStream<PlayerEvent> { get }

    /// 装载条目（内部完成 status 观测准备）。失败经 `.failed` 上报。
    func load(_ item: PlaybackItem) async
    func play() async
    func pause() async
    /// 跳转（秒）。实现方负责在时长未知时按引擎自身边界钳制。
    func seek(to seconds: Double) async
    /// 变速播放（Now Playing 需要上报速率）。
    func setRate(_ rate: Double) async
    func currentRate() async -> Double
    func currentTime() async -> Double
    /// 未知时长返回 nil。
    func currentDuration() async -> Double?
    /// 同步释放：移除时间观察者、暂停并断开 item。
    func stopAndRelease()
}
