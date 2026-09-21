import AVFoundation
import Foundation

// MARK: - 归一化事件（可注入通知名与 userInfo 的纯函数输入）

/// 中断信号（`AVAudioSessionInterruptionNotification` 的脱敏投影）。
public struct AudioInterruptionSignal: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case began
        case ended
    }

    public let kind: Kind
    /// 系统是否建议恢复（`AVAudioSessionInterruptionOptionShouldResume`）。
    public let shouldResumeSuggested: Bool

    public init(kind: Kind, shouldResumeSuggested: Bool = false) {
        self.kind = kind
        self.shouldResumeSuggested = shouldResumeSuggested
    }
}

/// 路由变更信号（拔耳机判定）。
public struct AudioRouteChangeSignal: Equatable, Sendable {
    /// 变更后当前路由是否仍有可用输出（false = 设备已离开，如拔出耳机）。
    public let outputDeviceStillAvailable: Bool
    /// 归一化的系统原因（`AVAudioSession.RouteChangeReason` 的 SDK 常量投影；未知为 nil）。
    public let reasonKind: String?

    public init(outputDeviceStillAvailable: Bool, reasonKind: String? = nil) {
        self.outputDeviceStillAvailable = outputDeviceStillAvailable
        self.reasonKind = reasonKind
    }
}

/// 会话信号（适配器的唯一转发形态）。
public enum AudioSessionSignal: Equatable, Sendable {
    case interruption(AudioInterruptionSignal)
    case routeChange(AudioRouteChangeSignal)
    /// 未识别的通知名（保持可观测，不静默吞掉）。
    case unrecognized(name: String)
}

/// 中断类型的归一化字面量（**内部词汇**；由适配器从 SDK 常量映射而来）。
///
/// **为什么不归一化就会静默失效**：`AVAudioSession.InterruptionType.ended.rawValue` 在
/// iOS 26 SDK 上是 `0`（早期文档里的 1/2 口径不成立，实测见 docs/log/20260921.md 假设 A7），
/// 所以**映射表只以 SDK 常量为键**（见 `AVAudioSessionAdapter.interruptionKind(from:)`），
/// 纯函数层只认下面这几个内部名。任何一处出现字面整型都属于本闸门拦截的缺陷类。
public enum AudioSessionInterruptionKind {
    public static let began = "began"
    public static let ended = "ended"
}

/// 路由变更原因的归一化字面量（同为**内部词汇**）。
///
/// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable` 的整型值同样不可假设
/// （`newDeviceAvailable` 与 `oldDeviceUnavailable` 相邻，早期实现把 3 当成拔耳机，
/// 实际 3 是 `categoryChange`），故映射一律走 SDK 常量。
public enum AudioSessionRouteChangeReasonKind {
    /// 旧输出设备不可用：拔耳机 / 拔线 / 蓝牙断连。
    public static let oldDeviceUnavailable = "oldDeviceUnavailable"
    /// 新输出设备可用：插回耳机 / 连上蓝牙。
    public static let newDeviceAvailable = "newDeviceAvailable"
    /// 会话类目变化（其他 App 或本 App 内部切换）。
    public static let categoryChange = "categoryChange"
    /// 其余系统原因（override / routeConfigurationChange / wakeFromSleep…）：只观测，不据此决策。
    public static let other = "other"
}

/// 通知 userInfo 的**脱敏投影**：只允许抽出字符串/整数/布尔，绝不携带对象引用或地址。
public struct AudioSessionNotificationPayload: Equatable, Sendable {
    /// 归一化后的中断类型（未知/缺失为 nil）。
    public let interruptionKind: String?
    /// 系统是否建议续播（`AVAudioSession.InterruptionOptions.shouldResume`）。
    public let shouldResumeSuggested: Bool
    /// 归一化后的路由变更原因（未知/缺失为 nil）。
    public let routeChangeReasonKind: String?
    /// `AVAudioSessionRouteChangeReasonKey` 原始值（**仅诊断**，不参与决策，也不作为映射键）。
    public let routeChangeReasonRaw: Int?
    /// 当前路由是否仍有输出端口。
    public let routeHasActiveOutput: Bool

    public init(
        interruptionKind: String? = nil,
        shouldResumeSuggested: Bool = false,
        routeChangeReasonKind: String? = nil,
        routeChangeReasonRaw: Int? = nil,
        routeHasActiveOutput: Bool = true
    ) {
        self.interruptionKind = interruptionKind
        self.shouldResumeSuggested = shouldResumeSuggested
        self.routeChangeReasonKind = routeChangeReasonKind
        self.routeChangeReasonRaw = routeChangeReasonRaw
        self.routeHasActiveOutput = routeHasActiveOutput
    }
}

/// 通知名（**由 AVFoundation SDK 常量派生**，不写字面串）。
///
/// 拼错的字符串常量没有任何编译期信号，只会让真实中断永远不进决策（静默失效）；
/// 这里以 `AVAudioSession.interruptionNotification.rawValue` 为唯一事实源，
/// 使「观测的通知」与「映射表比对的键」在定义上就是同一个常量。
public enum AudioSessionNotificationName {
    public static let interruption = AVAudioSession.interruptionNotification.rawValue
    public static let routeChange = AVAudioSession.routeChangeNotification.rawValue
}

/// 纯函数：通知名 + 脱敏投影 → 归一化信号。
///
/// 全部用 `==` 比较（不用 `case 常量` 模式：标识符模式会退化成绑定，导致静默错判）。
public enum AudioSessionNormalizer {
    public static func signal(name: String, payload: AudioSessionNotificationPayload) -> AudioSessionSignal {
        if name == AudioSessionNotificationName.interruption {
            if payload.interruptionKind == AudioSessionInterruptionKind.began {
                return .interruption(AudioInterruptionSignal(kind: .began))
            }
            if payload.interruptionKind == AudioSessionInterruptionKind.ended {
                return .interruption(AudioInterruptionSignal(
                    kind: .ended,
                    shouldResumeSuggested: payload.shouldResumeSuggested
                ))
            }
            return .unrecognized(name: name)
        }
        if name == AudioSessionNotificationName.routeChange {
            return .routeChange(AudioRouteChangeSignal(
                outputDeviceStillAvailable: payload.routeHasActiveOutput,
                reasonKind: payload.routeChangeReasonKind
            ))
        }
        return .unrecognized(name: name)
    }
}

// MARK: - 决策（纯状态机）

/// 会话决策出的播放动作。
public enum AudioSessionCommand: Equatable, Sendable {
    case pause
    case resume
    /// 不做任何播放动作。
    case none
}

/// 会话决策（动作 + 状态账）。
public struct AudioSessionDecision: Equatable, Sendable {
    public let command: AudioSessionCommand
    /// 是否记录了「中断结束后续播」意图（来电后自动续播的依据）。
    public let recordsShouldResume: Bool
    /// 是否清除已记录的续播意图。
    public let clearsShouldResume: Bool

    public init(command: AudioSessionCommand, recordsShouldResume: Bool = false, clearsShouldResume: Bool = false) {
        self.command = command
        self.recordsShouldResume = recordsShouldResume
        self.clearsShouldResume = clearsShouldResume
    }
}

/// 会话状态（可注入、可断言的纯值）。
public struct AudioSessionState: Equatable, Sendable {
    /// 已记录「稍后应恢复播放」。
    public var shouldResume = false
    /// 当前处于系统中断中。
    public var isInterrupted = false
    /// 最后一次决策（诊断用）。
    public var lastCommand: AudioSessionCommand?

    public init() {}
}

/// 中断/路由处理策略（design/screens/02-player.md §7：来电后自动续播，拔耳机暂停）。
public enum AudioSessionReducer {
    /// 纯函数决策 + 状态更新（`inout state` 使每条规则都可单独断言）。
    public static func decide(_ signal: AudioSessionSignal, state: inout AudioSessionState) -> AudioSessionDecision {
        let decision = evaluate(signal, state: &state)
        state.lastCommand = decision.command
        return decision
    }

    private static func evaluate(_ signal: AudioSessionSignal, state: inout AudioSessionState) -> AudioSessionDecision {
        switch signal {
        case .interruption(let interruption):
            switch interruption.kind {
            case .began:
                // 中断开始：暂停并记录续播意图（用户按了暂停还是被中断，恢复后行为不同）。
                state.isInterrupted = true
                state.shouldResume = true
                return AudioSessionDecision(command: .pause, recordsShouldResume: true)
            case .ended:
                state.isInterrupted = false
                let shouldResume = state.shouldResume || interruption.shouldResumeSuggested
                state.shouldResume = false
                guard shouldResume else {
                    return AudioSessionDecision(command: .none, clearsShouldResume: true)
                }
                return AudioSessionDecision(command: .resume, clearsShouldResume: true)
            }
        case .routeChange(let route):
            // 裁决表（§7）：旧设备不可用（拔耳机/拔线/蓝牙断连）**无条件暂停** —— 系统路由探针
            // 在蓝牙断开瞬间仍可能报有输出，故原因优先；原因未知时退回探针兜底。
            // `newDeviceAvailable`（插回）与 `categoryChange` 在有输出时不动作，且清不掉续播意图。
            let oldDeviceGone = route.reasonKind == AudioSessionRouteChangeReasonKind.oldDeviceUnavailable
            guard oldDeviceGone || route.outputDeviceStillAvailable == false else {
                return AudioSessionDecision(command: .none)
            }
            // 设备离开：暂停，并清除续播意图（重新插回不自动续播，避免口袋误触出声）。
            state.shouldResume = false
            return AudioSessionDecision(command: .pause, clearsShouldResume: true)
        case .unrecognized:
            return AudioSessionDecision(command: .none)
        }
    }
}

// MARK: - 系统接口抽象

/// `AVAudioSession` 的可注入面（生产 = `AVAudioSessionAdapter`；单测 = 桩）。
public protocol AudioSessionSystemInterface: Sendable {
    /// 设置 `.playback` 类目并激活（D4：后台音频）。
    func configureForPlayback() throws
    func deactivate() throws
    /// 当前路由是否仍有输出端口（拔耳机判据）。
    func hasActiveOutputPorts() -> Bool
}

/// 播放意图下发面。
public protocol AudioSessionCommandHandling: Sendable {
    func apply(_ command: AudioSessionCommand) async
}

/// 自身就是「系统音频会话通知源」的会话接口（缺陷 M3 的接线判据）。
///
/// 为什么要有这个协议：门只观测 `AVAudioSession` 的两条通知，而**注册动作发生在 `start()` 里**。
/// 旧实现只在调用者显式传 `adapter:` 时才注册，而生产门面恰恰没传 —— 于是 design §7
/// （来电续播、拔耳机暂停）整条链在真机上静默失效，单测却因为手工接线而全绿。
/// 现在：只要注入的 `system` 自己能观测通知（`AVAudioSessionAdapter` 属之），门就必须接上它，
/// 「谁来观测」不再依赖调用方记得多传一个参数。
public protocol AudioSessionNotificationObserving: Sendable {
    /// 注册系统通知观测者，并把归一化后的信号投进 `gate`；路由探针取 `routeProbe`。
    func attachNotifications(to gate: AudioSessionGate, routeProbe: any AudioSessionSystemInterface) async
    /// 摘掉**全部**观测者（通知残留是本仓红线）。
    func detachNotifications() async
    /// 观测中的通知数量（可观测面：证明接线真的发生了）。
    var observedNotificationCount: Int { get }
}

/// 会话控制器（facade 持有的门面）。
public protocol AudioSessionControlling: Sendable {
    func start() async throws
    func stop() async
    func receive(_ signal: AudioSessionSignal) async
    func currentAudioSessionState() async -> AudioSessionState
}

/// 可测的会话门：持有 `AudioSessionState`，把决策转成播放动作。
///
/// 真实通知由 `AVAudioSessionAdapter` 归一化后投递进来；单测直接 `receive(_:)` 合成信号，
/// 于是「中断/路由」的全部分支都在零 AVAudioSession 实例、零音频硬件输出下可断言。
public actor AudioSessionGate: AudioSessionControlling {
    private let system: any AudioSessionSystemInterface
    private let handler: AudioSessionCommandHandling
    /// 通知观测者（M3）：显式 `adapter:` 优先，否则由「自身可观测的 system」接管。
    private let notifier: (any AudioSessionNotificationObserving)?
    private var state = AudioSessionState()
    private var started = false
    /// 观测者是否已挂上（MAJ-5）：这与「会话激活成功」是**两件事**，必须分开记账 ——
    /// 混成一个 flag 的话，激活失败要么让注册一起丢（design §7 静默失效），
    /// 要么让 `stop()` 漏摘已挂上的观测者（通知残留，本仓红线）。
    private var observingAttached = false

    public init(
        system: any AudioSessionSystemInterface,
        handler: AudioSessionCommandHandling,
        adapter: AVAudioSessionAdapter? = nil
    ) {
        self.system = system
        self.handler = handler
        self.notifier = adapter ?? (system as? any AudioSessionNotificationObserving)
    }

    public func start() async throws {
        guard !started else { return }
        // MAJ-5：观测者注册排在 `configureForPlayback()` **之前**。
        //
        // 旧顺序把「注册」挂在「激活成功」上：真机上 `setActive(true)` 会因为他人占用音频、
        // 通话中等而失败，一失败就整段跳过注册 —— design §7（来电后自动续播、拔耳机暂停）
        // 再次静默失效（M3 修的是「没接上」，这一次是「接上了但被跳过」）。
        // 而且中断/路由通知恰恰在「本 App 拿不到会话」时最可能出现，所以它们必须已经被观测。
        // 注册是幂等的（适配器按通知名去重），激活失败时留着它也没有任何残留风险 ——
        // `stop()` 会按 `observingAttached` 摘掉，与 `started` 无关。
        if observingAttached == false, let notifier {
            await notifier.attachNotifications(to: self, routeProbe: system)
            observingAttached = true
        }
        try system.configureForPlayback()
        started = true
    }

    public func stop() async {
        // 两个 flag 任一成立都要走收尾：只认 `started` 会把「注册成功、激活失败」的那一半漏掉。
        guard started || observingAttached else { return }
        started = false
        observingAttached = false
        await notifier?.detachNotifications()
        try? system.deactivate()
        state = AudioSessionState()
    }

    /// 正在观测系统通知的数量（M3 的可观测面：`start()` 之后必须 > 0，`stop()` 之后必须归零）。
    public var observedNotificationCount: Int { notifier?.observedNotificationCount ?? 0 }

    /// 是否已接上系统通知源（生产默认接线判据）。
    public var observesSystemNotifications: Bool { notifier != nil }

    /// 观测者**当前确实挂着**（MAJ-5 的判据面：激活失败时它也必须为真）。
    public var isObservingSystemNotifications: Bool { observingAttached }

    public func receive(_ signal: AudioSessionSignal) async {
        let decision = AudioSessionReducer.decide(signal, state: &state)
        guard decision.command != .none else { return }
        await handler.apply(decision.command)
    }

    public func currentAudioSessionState() -> AudioSessionState { state }

    public func isStarted() -> Bool { started }

    /// 归一化入口：通知名 + 脱敏投影 → 信号（routeChange 的「设备是否仍在」由调用方现取）。
    public static func normalizedSignal(
        name: String,
        payload: AudioSessionNotificationPayload
    ) -> AudioSessionSignal {
        AudioSessionNormalizer.signal(name: name, payload: payload)
    }
}

/// 播放意图处理：把会话决策转成 coordinator 调用（单测记录命令序列）。
public actor AudioSessionCommandHandler: AudioSessionCommandHandling {
    private weak var coordinator: PlaybackCoordinator?
    public private(set) var appliedCommands: [AudioSessionCommand] = []

    public init(coordinator: PlaybackCoordinator?) {
        self.coordinator = coordinator
    }

    public func apply(_ command: AudioSessionCommand) async {
        appliedCommands.append(command)
        switch command {
        case .none:
            return
        case .pause:
            await coordinator?.pause()
        case .resume:
            await coordinator?.resume()
        }
    }
}

// MARK: - AVAudioSession 实现（薄适配器）

/// 真实 `AVAudioSession` 接口 + 通知观测。
///
/// 职责边界：**只取值与转发，不做决策**。因此每一行都可冒烟测试，且不需要真机音频输出。
///
/// 循环引用：`gate` 以 **weak** 持有（门强持观测者本体，见 `AudioSessionGate.notifier`）；
/// `stopObserving()` 必须清空全部观测 token（通知残留是本仓红线）。
public final class AVAudioSessionAdapter: AudioSessionSystemInterface, AudioSessionNotificationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var observerTokens: [Notification.Name: NSObjectProtocol] = [:]
    private weak var gate: AudioSessionGate?
    /// 路由探针（**weak**）：MAJ-7 附带发现 —— 门把 `system` 同时当作 `notifier` 与 `routeProbe`
    /// 传回来，生产默认形态下这就是**自引用强环**（adapter → adapter），适配器永不释放，
    /// 于是 `deinit` 兜底形同不存在、观测者 token 永久残留。协议不要求 `AnyObject`，
    /// 故这里以 `AnyObject` 存弱引用、用时向下转回协议存在值。
    private weak var routeProbe: AnyObject?
    /// 进程内「已注册但未摘除」的 token 净数（MAJ-7 的可观测面）。
    ///
    /// 为什么需要一个静态账而不是实例计数：实例释放后没人能再问它「你还挂着几个观测者」，
    /// 而那正是本条 finding 的形态 —— 只有跨对象的全局净额能证明 `deinit` 真的兜住了。
    ///
    /// 为什么是一盒子而不是 `static var`：Swift 6 严格并发下非隔离的全局可变量直接编译失败
    /// （`#MutableGlobalVariable`），而临界区本来就在这只盒子里用 `NSLock` 守住。
    private final class ObserverLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var net = 0

        func bump(_ by: Int) {
            lock.lock()
            net += by
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return net
        }
    }

    private static let observerLedger = ObserverLedger()

    /// 当前进程内未摘除的观测者 token 净数（注册 +1、摘除 -1；泄漏判据）。
    public static var netLiveObserverTokens: Int { observerLedger.value }

    private static func ledgerBumped(_ by: Int) {
        observerLedger.bump(by)
    }

    public init() {}

    /// 兜底摘除（MAJ-7）：忘记 `stopObserving()` 时由 `deinit` 收尾 —— 通知残留是本仓红线。
    deinit {
        stopObservingSynchronously()
    }

    /// gate 与路由探针在 `AudioSessionGate.start()` 时回填。
    func attach(gate: AudioSessionGate, routeProbe: any AudioSessionSystemInterface) {
        lock.lock()
        defer { lock.unlock() }
        self.gate = gate
        // 结构上只有类实例能当探针（要弱引用它）；值类型的 `AudioSessionSystemInterface`
        // 实现在本仓不存在（生产适配器与全部测试桩都是 class）。
        self.routeProbe = routeProbe as AnyObject
    }

    /// 取回路由探针（未回填 / 已释放 → nil，`forward` 端按「输出不可知」fail-closed 处理）。
    private func lockedRouteProbe() -> (any AudioSessionSystemInterface)? {
        lock.lock()
        defer { lock.unlock() }
        return routeProbe as? any AudioSessionSystemInterface
    }

    public func configureForPlayback() throws {
        do {
            // D4：`.playback` 类目才能在锁屏/后台持续出声（不受静音键影响）。
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            throw PlayerError.writeFailed(Self.status(of: error))
        }
    }

    public func deactivate() throws {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            throw PlayerError.writeFailed(Self.status(of: error))
        }
    }

    public func hasActiveOutputPorts() -> Bool {
        !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
    }

    /// 从系统错误里只取整数码：绝不携带地址、描述或凭证文本。
    public static func status(of error: Error) -> Int32 {
        Int32(truncatingIfNeeded: (error as NSError).code)
    }

    /// 观测中的通知名（冒烟测试断言其与 AVFoundation 常量一致）。
    public static let observedNotificationNames: [Notification.Name] = [
        AVAudioSession.interruptionNotification,
        AVAudioSession.routeChangeNotification,
    ]

    /// 从 `Notification` 抽取脱敏投影（纯映射：单测可直接构造 Notification 喂进来）。
    public static func payload(
        from notification: Notification,
        routeHasActiveOutput: Bool
    ) -> AudioSessionNotificationPayload {
        let userInfo = notification.userInfo
        let reason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber
        return AudioSessionNotificationPayload(
            interruptionKind: interruptionKind(from: userInfo?[AVAudioSessionInterruptionTypeKey]),
            shouldResumeSuggested: shouldResumeSuggested(from: userInfo?[AVAudioSessionInterruptionOptionKey]),
            routeChangeReasonKind: routeChangeReasonKind(from: reason),
            routeChangeReasonRaw: reason?.intValue,
            routeHasActiveOutput: routeHasActiveOutput
        )
    }

    /// 中断类型 → 归一化字面量（**以 SDK 常量为键**，绝不写死整数）。
    public static func interruptionKind(from raw: Any?) -> String? {
        guard let value = (raw as? NSNumber)?.uintValue else { return nil }
        let type = AVAudioSession.InterruptionType(rawValue: value)
        if type == AVAudioSession.InterruptionType.began { return AudioSessionInterruptionKind.began }
        if type == AVAudioSession.InterruptionType.ended { return AudioSessionInterruptionKind.ended }
        return nil
    }

    /// 路由变更原因 → 归一化字面量（**以 SDK 常量为键**）。
    ///
    /// `RouteChangeReason` 是 OptionSet：`==` 比的是整位集，故单位置常量之间不会互相误命中；
    /// 取值缺失/类型不符返回 nil（决策面按「原因未知」处理）。
    public static func routeChangeReasonKind(from raw: Any?) -> String? {
        guard let value = (raw as? NSNumber)?.uintValue else { return nil }
        let reason = AVAudioSession.RouteChangeReason(rawValue: value)
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable {
            return AudioSessionRouteChangeReasonKind.oldDeviceUnavailable
        }
        if reason == AVAudioSession.RouteChangeReason.newDeviceAvailable {
            return AudioSessionRouteChangeReasonKind.newDeviceAvailable
        }
        if reason == AVAudioSession.RouteChangeReason.categoryChange {
            return AudioSessionRouteChangeReasonKind.categoryChange
        }
        return AudioSessionRouteChangeReasonKind.other
    }

    public static func shouldResumeSuggested(from raw: Any?) -> Bool {
        let value = (raw as? NSNumber)?.uintValue ?? 0
        return AVAudioSession.InterruptionOptions(rawValue: value).contains(.shouldResume)
    }

    public func startObserving() async {
        startObservingSynchronously()
    }

    /// `NSLock` 不得进 async 上下文：注册/注销收敛到同步方法。
    private func startObservingSynchronously() {
        lock.lock()
        var added = 0
        for name in Self.observedNotificationNames where observerTokens[name] == nil {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.forward(notification)
            }
            observerTokens[name] = token
            added += 1
        }
        lock.unlock()
        // 账目在锁外推进：观测者账的锁与适配器自己的 `lock` 不得嵌套（两把锁的持有顺序
        // 一旦在别处反过来就是死锁面）。
        Self.ledgerBumped(added)
    }

    public func stopObserving() async {
        stopObservingSynchronously()
    }

    private func stopObservingSynchronously() {
        lock.lock()
        let tokens = Array(observerTokens.values)
        observerTokens = [:]
        gate = nil
        routeProbe = nil
        lock.unlock()
        Self.ledgerBumped(-tokens.count)
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 观测者数量（teardown 后必须归零）。
    public var observedNotificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observerTokens.count
    }

    /// 是否仍持有 gate（`stopObserving` 后必须为 false）。
    public var holdsGate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate != nil
    }

    private func forward(_ notification: Notification) {
        lock.lock()
        let target = gate
        lock.unlock()
        guard let target else { return }
        let signal = Self.normalizedSignal(
            name: notification.name.rawValue,
            payload: Self.payload(
                from: notification,
                // min-2 同源做法：探针的读取单独走同步临界区（`routeProbe` 现在是弱引用，
                // 取用与判空必须原子，否则可能在两次读取之间被释放）。
                routeHasActiveOutput: lockedRouteProbe()?.hasActiveOutputPorts() ?? false
            )
        )
        Task { await target.receive(signal) }
    }

    /// 转发用的归一化（暴露为静态以便单测直接断言映射结果）。
    static func normalizedSignal(name: String, payload: AudioSessionNotificationPayload) -> AudioSessionSignal {
        AudioSessionNormalizer.signal(name: name, payload: payload)
    }
}

// MARK: - 通知观测接线（M3）

/// `AVAudioSessionAdapter` 既是系统接口、又是通知源：它自己就能把系统会话通知归一化投进门。
///
/// 于是「生产默认」不再需要调用方额外传 `adapter:` —— 门在 `start()` 里必然接上它。
public extension AVAudioSessionAdapter {
    func attachNotifications(to gate: AudioSessionGate, routeProbe: any AudioSessionSystemInterface) async {
        attach(gate: gate, routeProbe: routeProbe)
        await startObserving()
    }

    func detachNotifications() async {
        await stopObserving()
    }
}
