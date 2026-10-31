import Foundation

/// 生成状态轮询退避（COVA-20261024-003 R2）。
///
/// 契约原话：「轮询退避 **1/2/4/5s**、页面不可见暂停、恢复可见立即拉取。
/// 当前**无 generation SSE 端点**，契约只承诺轮询。」
///
/// 三件事分得很开，因为它们各有各的判据：
/// 1. **节拍**（本类型）：第 1/2/3 次分别等 1/2/4s，第 4 次起一律 5s（封顶）；
/// 2. **可见性**（`isAppropriate` 家族）：不可见时不发，恢复可见立刻补一拍；
/// 3. **上限**：到点停，但**停不等于失败**（与 `StudioCreatePollSchedule` 同一条纪律）。
///
/// 为什么另起一个类型而不改 `StudioCreatePollSchedule`：后者是 studio/create 的
/// 「前 6 次 5s、之后 10s、上限 30min」，已被 `StudioCreateDTOTests` 逐值钉住，
/// 且它服务的是**提交后的一次性任务跟踪**。R2 说的是**生成状态轮询**的退避，
/// 两者上限与节奏都不同，合成一个类型会让两组判据互相污染。
public struct GenerationPollBackoff: Equatable, Sendable {

    /// 契约写死的退避序列（秒）：1 / 2 / 4，之后封顶 5。
    public static let contractPattern: [TimeInterval] = [1, 2, 4, 5]

    /// 退避序列。最后一项是所有后续尝试的封顶值。
    public let pattern: [TimeInterval]
    /// 累计等待上限（秒）。到点即停 —— **停不等于失败**。
    public let maximumElapsed: TimeInterval

    public init(
        pattern: [TimeInterval] = GenerationPollBackoff.contractPattern,
        maximumElapsed: TimeInterval = 30 * 60
    ) {
        // 钳制：空序列会让「第一次等多久」无值可读 ⇒ 退回契约序列。
        // 负值/0 会让轮询变成忙等 ⇒ 同样不接受。
        let clean = pattern.filter { $0 > 0 }
        self.pattern = clean.isEmpty ? GenerationPollBackoff.contractPattern : clean
        self.maximumElapsed = max(0, maximumElapsed)
    }

    /// 第 `attempt` 次（**1 基**）轮询前该等多久：序列内取对应值，超出走最后一项。
    public func interval(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return pattern.first ?? 5 }
        let index = min(attempt - 1, pattern.count - 1)
        return pattern[index]
    }

    /// 第 `attempt` 次轮询**发生之前**已累计等待的秒数。
    public func elapsed(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        var total: TimeInterval = 0
        for index in 1..<attempt { total += interval(forAttempt: index) }
        return total
    }

    /// 还该不该发第 `attempt` 次（累计等待已到上限即停）。
    public func shouldPoll(attempt: Int) -> Bool {
        guard attempt > 0 else { return false }
        return elapsed(beforeAttempt: attempt) < maximumElapsed
    }

    /// 上限内最多能发多少次。
    public var maximumAttemptCount: Int {
        var attempt = 1
        while shouldPoll(attempt: attempt) { attempt += 1 }
        return attempt - 1
    }

    /// R2 的「页面不可见暂停、恢复可见立即拉取」判决。
    ///
    /// 四种情形，每一条都对应屏上一种真实差别：
    /// · 不可见 ⇒ **不发**，且不计入尝试号（否则用户切回来时已经白白烧掉几次配额）；
    /// · 恢复可见 ⇒ **立刻发一次**（`shouldFireImmediately`），不等节拍；
    /// · 可见且正常在途 ⇒ 按节拍等；
    /// · 到上限 ⇒ 停（无论可不可见）。
    public enum VisibilityDecision: Equatable, Sendable {
        /// 现在就该发（恢复可见后的补拍，或首拍）。
        case fireNow
        /// 还不到点，等 `delay` 秒再发。
        case wait(TimeInterval)
        /// 页面不可见，暂停；恢复可见时再决定。
        case paused
        /// 到上限，停。**不是失败**。
        case stoppedAtCap
    }

    public func decide(
        attempt: Int,
        isVisible: Bool,
        justBecameVisible: Bool = false
    ) -> VisibilityDecision {
        if !shouldPoll(attempt: attempt) { return .stoppedAtCap }
        guard isVisible else { return .paused }
        // 恢复可见的第一拍不吃退避：用户已经在看，让他等 5 秒没有任何道理。
        if justBecameVisible { return .fireNow }
        return .wait(interval(forAttempt: attempt))
    }
}

/// R2 可见性状态机（纯值类型，零 timer、零通知依赖）。
///
/// 为什么单独抽出来：可见性这件事的三条规则（不可见暂停 / 恢复可见立刻补一拍 /
/// 补拍不吃退避）都是**可断言的纯逻辑**，但它们住在 `AppSession` 里就只能在
/// 模拟器上肉眼验（`@MainActor` 类 + 真实网络腿）。抽成值类型之后，
/// 这三条在单测里逐条钉住，会话层只负责把 `scenePhase` 喂进来。
public struct GenerationPollVisibility: Equatable, Sendable {
    /// 当前是否可见。
    public private(set) var isVisible: Bool
    /// 恢复可见后**待消费**的那一拍补拍标记。
    public private(set) var resumePending: Bool

    public init(isVisible: Bool = true) {
        self.isVisible = isVisible
        // 冷启即前台：**不**置补拍标记（第一拍本来就该按退避走，没有"刚恢复"这回事）。
        self.resumePending = false
    }

    /// 喂一次可见性。返回 true 表示「刚从不可见转可见」⇒ 调用方应立刻补一拍。
    ///
    /// 重复喂同一个值**不**重复触发补拍（不然每次 `scenePhase` 抖动都会多打一次网络）。
    public mutating func update(isVisible visible: Bool) -> Bool {
        let wasVisible = isVisible
        isVisible = visible
        guard visible, !wasVisible else { return false }
        resumePending = true
        return true
    }

    /// 消费补拍标记（轮询腿在发完那一拍之后调）。
    /// 返回 true 表示**这一拍不吃退避**。
    public mutating func consumeResume() -> Bool {
        guard resumePending else { return false }
        resumePending = false
        return true
    }

    /// 补拍那一拍**不消耗尝试号**：它不改变退避序列（1/2/4/5 的进度不因切前台而重置）。
    public static func advancesAttempt(resumeConsumed: Bool) -> Bool { !resumeConsumed }
}
