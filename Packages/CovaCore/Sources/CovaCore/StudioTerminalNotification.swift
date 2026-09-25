import Foundation

// 18 本地通知**真终态**那条腿的判据层（纯函数 + 幂等账；系统侧薄壳在
// `CovaFeature/StudioNotifications.swift`）。
//
// 这一层为什么必须存在：`StudioNotificationPlanner` 早就把判定、文案与 userInfo 都算好了，
// 但它**没有任何调用点** ⇒ 用户实际收到的只有 `plans/start` 之后预约的那条 30 分钟兜底串
// 「两个版本应该好了，去 Cova 听」。缺的不是判据，是**把判据交给系统的那一步**。
// 本文件把那一步的"该不该交"收成一处，逐条对齐 `design/screens/18-local-notification.md`：
// · §7 触发判定 = 前两个候选都 settled（D7）⇒ 仍然只读 `StudioNotificationPlanner`，这里不重写；
// · §7 幂等 = 同一 `jobId` 只调度一次 ⇒ `StudioNotificationClaimLedger`（owner 绑定，换号不共账）；
// · §4 兜底第 3 行 = 回前台对账时**不发迟到的通知** ⇒ 用「本机是否还持有这一路的在途账」
//   （08 §数据源那本 `liveStudioJobs`）当"新鲜"的证据，而不是去解析 `completedAt`：
//   那个字段的**日期格式契约里没写**（`GenerationJobDto.completedAt` 是 `String?`），
//   拿一个未文档化的串去判"迟到没有"，错的是判据本身，不是后端；
// · §4 兜底第 1 行 = 授权 denied ⇒ **没排上就说没排上**，不记已发账、不假装投递成功
//   （系统授权态的唯一回显面是 15 设置 E 行，本层不再长第二张中文状态表）。

/// 系统通知授权态在**本判据里**的形状。
///
/// 只分三档，因为判据只关心"现在能不能投"：`provisional`/`ephemeral` 与 `authorized`
/// 一样可投（与 15 设置「已开启」同一口径），`notDetermined` 单独一档 —— 它意味着
/// **不该在这里弹权限框**（spec：只在 09「开始制作」成功后索权）。
public enum StudioNotificationAuthorization: Equatable, Sendable, CaseIterable {
    case allowed
    case denied
    case undecided
}

/// 一次终态观察的处理结果。**上屏一律走 `userLabel`**，`rawValue`/枚举名一个都不许露。
public enum StudioTerminalNotificationOutcome: String, CaseIterable, Equatable, Sendable {
    /// 真终态文案已交给系统（同标识会顶掉那条兜底预约）。
    case scheduled
    /// 这一轮的账已经记过 ⇒ 不再排第二条（重复轮询/多次进屏就是这一档）。
    case alreadyScheduled
    /// 前两个候选还没都 settled ⇒ 不发（D7 取证项）。
    case notTerminal
    /// 用户关了系统通知 ⇒ 没排上，完成消息由 08 指示点 + 09 终态条承担。
    case authorizationDenied
    /// 系统还没被问过 ⇒ 不在这里索权，也不排。
    case authorizationUndecided
    /// 本机没有这一路的在途账（App 被杀后重启、别人发起的会话）⇒ 不补发迟到的通知。
    case lateObservation
    /// 载荷里没有可用的任务号 ⇒ 既没有幂等键也没有可投的东西。
    case payloadUnusable
    /// 系统没接受这一次登记（真投递失败，账已回退，下一次观察还可以再试）。
    case systemRefused

    /// 中文标签（本仓「屏上不许出现英文态名」判据，与 `LoopMode.userLabel`、
    /// `PlayerFailure.Kind.userLabel`、`OneStepLyricsPanelPhase.userLabel` 同族同形：
    /// 标签挂在**它所属的那一层**，并由用例逐 case 钉死，判据只留在下一层就会反复长新漏点）。
    public var userLabel: String {
        switch self {
        case .scheduled: return "已按真实终态排好通知"
        case .alreadyScheduled: return "这一轮已经通知过了"
        case .notTerminal: return "两个版本还没都完成，不发"
        case .authorizationDenied: return "系统通知没开启，改由会话页承担"
        case .authorizationUndecided: return "还没问过系统通知权限，不发"
        case .lateObservation: return "这一轮不是本机在等的，不补发迟到的通知"
        case .payloadUnusable: return "没拿到可用的任务编号，无法通知"
        case .systemRefused: return "系统没接受这条通知登记"
        }
    }
}

/// 「同一 `(会话, 任务)` 只调度一次」的账（18 §7 幂等 + §8「登出清已发记录」）。
///
/// 形状取自本仓已有的 `PlanStartTokenLedger`：按业务三元组记账、纯值类型、`mutating` 入口。
/// 与它的两处差别是有意的：
/// · **按 owner 分桶**而不是全局一本 —— D5/D8/D22 那条"换号不得留上一个身份的账"，
///   分桶让"隔离"是结构性的，而不是靠前缀字符串猜；
/// · **记的是事实**（已经排过）而不是可重放的凭据 —— 通知排出去就收不回来，没有"换个键再来一次"。
public struct StudioNotificationClaimLedger: Equatable, Sendable {
    /// 无身份（游客/恢复中）那一桶的桶名。真身份一律带 `p:` 前缀 ⇒ 两者不可能撞上。
    public static let anonymousBucket = "-"
    /// 真身份桶名前缀。
    public static let ownerBucketPrefix = "p:"

    private var buckets: [String: Set<String>] = [:]

    public init() {}

    /// 从持久化形态恢复（键 = 桶名，值 = 该桶内的 `(会话,任务)` 条目）。
    public init(_ records: [String: [String]]) {
        for (bucket, entries) in records where entries.isEmpty == false {
            buckets[bucket] = Set(entries)
        }
    }

    /// 落盘用的稳定形态（桶内排序，便于"写回去的是同一本账"这类断言可判等）。
    public var records: [String: [String]] { buckets.mapValues { $0.sorted() } }

    /// 可投的条目数（用例钉"重复观察十次也只有一条账"）。
    public var count: Int { buckets.values.reduce(0) { $0 + $1.count } }

    public static func bucket(for owner: String?) -> String {
        guard let owner = normalized(owner) else { return anonymousBucket }
        return ownerBucketPrefix + owner
    }

    /// `(会话, 任务)` 条目；任务号为空 ⇒ `nil`（没有任何东西可以作为幂等键）。
    /// 会话号可以为空：spec §7 的兜底是「点进去回落首页」，通知本身照样可以排，
    /// 但**必须仍然只排一次**，所以它落进同一条目而不是被拒绝记账。
    public static func entry(sessionID: String?, jobID: String) -> String? {
        guard let job = normalized(jobID) else { return nil }
        return "\(normalized(sessionID) ?? "")|\(job)"
    }

    public func isClaimed(owner: String?, sessionID: String?, jobID: String) -> Bool {
        guard let entry = Self.entry(sessionID: sessionID, jobID: jobID) else { return false }
        return buckets[Self.bucket(for: owner)]?.contains(entry) ?? false
    }

    /// 记账：`true` = 首次（可以调度）；`false` = 已经记过（不得再排第二条）。
    public mutating func claim(owner: String?, sessionID: String?, jobID: String) -> Bool {
        guard let entry = Self.entry(sessionID: sessionID, jobID: jobID) else { return false }
        let bucket = Self.bucket(for: owner)
        var entries = buckets[bucket] ?? []
        guard entries.insert(entry).inserted else { return false }
        buckets[bucket] = entries
        return true
    }

    /// 回退一次记账：只有"真投递失败"才用它 —— 没投出去的东西不得占着幂等账，
    /// 否则这一轮永远不会再有一次机会。
    public mutating func release(owner: String?, sessionID: String?, jobID: String) {
        guard let entry = Self.entry(sessionID: sessionID, jobID: jobID) else { return }
        let bucket = Self.bucket(for: owner)
        buckets[bucket]?.remove(entry)
        if buckets[bucket]?.isEmpty == true { buckets[bucket] = nil }
    }

    /// 某个身份整桶作废（登出/换号）。
    public mutating func reset(owner: String?) {
        buckets[Self.bucket(for: owner)] = nil
    }

    /// 整本作废（`revokeAll` 的那一半：撤销待发 + 清已发记录）。
    public mutating func removeAll() {
        buckets = [:]
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// 终态观察 ⇒ 该不该把真文案交给系统。纯函数：同一个载荷不会投两次（账本决定），
/// 没投的场合不得改账（`release` 只在真投递失败时由调用方走）。
public enum StudioTerminalNotification {
    public struct Decision: Equatable, Sendable {
        public let outcome: StudioTerminalNotificationOutcome
        /// 真终态的文案与载荷（未到终态 / 载荷不可用 ⇒ `nil`）。
        public let plan: StudioNotificationPlan?

        /// 非 `nil` 就意味着「这一轮在 18 的口径里已经结束了」⇒ 那条**未定名的兜底预约**必须撤掉，
        /// 否则用户会在几小时后收到一句「两个版本应该好了」而歌其实早就做好了（也可能早就失败了）。
        /// 走了 `.scheduled` 那条不在此列：同标识的 `add` 本身就是替换。
        public var shouldRevokeFallback: Bool { plan != nil && outcome != .scheduled }
    }

    /// 判据顺序**逐条都有理由**，测试按这条顺序钉：
    /// 1. 先问「有没有终态」—— 没终态时后面全部不谈（D7 是这条腿的第一道门）；
    /// 2. 再问「有没有可幂等的任务号」；
    /// 3. **已经记过账**优先于一切系统事实：重复轮询要报"已经通知过了"，
    ///    而不是报"没授权"这种只在第一次才成立的理由；
    /// 4. 迟到（本机没在等这一路）优先于授权：这是"不该发"，与系统权限无关；
    /// 5. 授权两档（关掉了 / 还没问过）都算"没排上"，也不记账；
    /// 6. 只有走到第 6 步才**记账并交出去**。
    public static func decide(
        job: GenerationJobDto?,
        sessionID: String?,
        planCardID: String?,
        owner: String?,
        authorization: StudioNotificationAuthorization,
        watchedInFlight: Bool,
        ledger: inout StudioNotificationClaimLedger
    ) -> Decision {
        guard let job, job.candidates().isEmpty == false else {
            return Decision(outcome: .notTerminal, plan: nil)
        }
        guard StudioNotificationPlanner.outcome(candidates: job.candidates()) != .notSettled else {
            return Decision(outcome: .notTerminal, plan: nil)
        }
        guard let plan = StudioNotificationPlanner.plan(
            job: job, sessionID: sessionID, planCardID: planCardID
        ) else {
            return Decision(outcome: .payloadUnusable, plan: nil)
        }
        // 幂等键的主体：`plan` 非 nil 就已经要求过任务号非空，这里只是把"没有号"这一档
        // 明确留在 payloadUnusable，而不是让它滑进账本里变成一个看不见条目的"已通知"。
        guard let jobID = plan.jobID else {
            return Decision(outcome: .payloadUnusable, plan: nil)
        }
        if ledger.isClaimed(owner: owner, sessionID: sessionID, jobID: jobID) {
            return Decision(outcome: .alreadyScheduled, plan: plan)
        }
        guard watchedInFlight else {
            return Decision(outcome: .lateObservation, plan: plan)
        }
        switch authorization {
        case .denied: return Decision(outcome: .authorizationDenied, plan: plan)
        case .undecided: return Decision(outcome: .authorizationUndecided, plan: plan)
        case .allowed: break
        }
        guard ledger.claim(owner: owner, sessionID: sessionID, jobID: jobID) else {
            return Decision(outcome: .alreadyScheduled, plan: plan)
        }
        return Decision(outcome: .scheduled, plan: plan)
    }
}
