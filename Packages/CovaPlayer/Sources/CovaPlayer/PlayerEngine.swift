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

        /// 上屏用的中文标签。
        ///
        /// 为什么标签要在这一层，而不是由 UI 自己拼：`PlayerViews` 直接把 `failure.description`
        /// 印到屏上，而 `description` 原先用的是 `kind.rawValue` ⇒ **每一条播放失败都会把英文枚举名
        /// 送上屏**（`invalidSourceURL`、`mediaInvalid`、`localizationRequired`…）。
        /// 本仓已经为同一形状登记过四处（`plan.rawValue`、参数胶囊的 `weirdness`、`status.rawValue`、
        /// 登录错误直出），而「英文态名不得外溢」这条判据原先只钉在状态机那一层 ⇒
        /// **判据留在下一层，UI 层就会反复出现同族**。这里补上，并由用例逐 case 钉死。
        public var userLabel: String {
            switch self {
            case .localizationRequired: return "音频还没准备好"
            case .missingFile: return "本地音频文件缺失"
            case .invalidSourceURL: return "这个音频地址用不了"
            case .network: return "网络有问题"
            case .mediaInvalid: return "音频格式不支持"
            case .engine: return "播放器出错了"
            case .cancelled: return "已取消"
            }
        }
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

    /// 上屏串一律走 `Kind.userLabel`（中文标签的定义为什么在 `Kind` 里、不在这里）。
    public var description: String {
        message.isEmpty ? kind.userLabel : "\(kind.userLabel)：\(message)"
    }
}

/// 引擎事件的**装载代际**闸门（`PlayerEngine` 实现方的义务；纯状态机，可零硬件单测）。
///
/// 为什么闸门在引擎侧而不是协调器侧：只有引擎知道自己**当前装载的是哪一件**，
/// 于是「上一项的迟到 / 重复上报」只能在投递前丢弃。协调器收到的裸 `.ended`
/// 无法区分「当前项真的播完」与「旧项迟到」—— 按协调器状态去丢弃会误杀正常推进
/// （`PlaybackCoordinatorTests.testItemEndUnderOffWalksThenStops` /
/// `testItemEndUnderAllWrapsToFirst` 钉住了这一点），见 `docs/log/20260921.md` §存疑点。
///
/// 规则：
/// 1. 装载项发生变化（换件 / 释放）即推进代际；观测者回调必须捕获**当时**的代际。
/// 2. 代际与当前不符 → 该回调属于已被取代的条目 → 丢弃（缺陷 P4 的「迟到事件」）。
/// 3. 同一代至多投递一条 `.ended`（AVPlayer 的边界观察者与 playToEnd 双发是现实形态）。
public struct EngineEventGate: Sendable {
    /// 当前装载代际（`0` = 从未装载）。
    public private(set) var episode: UInt64
    /// 已投递过 `.ended` 的代际（换件即失效）。
    private var endedDeliveredFor: UInt64?

    public init(episode: UInt64 = 0) {
        self.episode = episode
        self.endedDeliveredFor = nil
    }

    /// 推进代际并返回新值（观测者注册时必须捕获返回值）。
    public mutating func advance() -> UInt64 {
        episode &+= 1
        endedDeliveredFor = nil
        return episode
    }

    /// 候选代际是否仍是当前装载。
    public func isCurrent(_ candidate: UInt64) -> Bool { candidate == episode }

    /// 判定 + 记账：这条观测者回调可否投递。
    public mutating func accepts(_ event: PlayerEvent, from candidate: UInt64) -> Bool {
        guard isCurrent(candidate) else { return false }
        guard case .ended = event else { return true }
        if endedDeliveredFor == candidate { return false }
        endedDeliveredFor = candidate
        return true
    }
}

/// 播放引擎抽象 —— **注入点**。
///
/// 生产实现 = `AVPlayerEngine`（薄适配器）；单测 = 脚本化桩（零 AVFoundation、零音频硬件）。
///
/// 约定：
/// - 事件只经 `events` 流上报，实现方不得直接回调 coordinator；
/// - **观测者/通知回调必须经 `EngineEventGate` 过滤后才 `yield`**（过期代际与重复 `.ended`
///   在进入事件流之前丢弃）；实现方主动产生的事件（如被拒绝的装载）不受此闸门口径约束；
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
