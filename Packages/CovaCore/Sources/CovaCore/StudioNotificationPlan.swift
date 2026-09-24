import Foundation

/// 18 本地通知的**纯规划器**（`design/screens/18-local-notification.md`）。
///
/// 18 不是屏幕，交付物是「通知样式 + 路由契约 + 授权/兜底态」。这里只放**不需要系统框架**
/// 的那一半（判定 + 文案 + userInfo 组装），所以它能被 CovaCore 的确定性测试钉住；
/// 真正向系统登记通知的薄壳在 `CovaFeature/StudioNotifications.swift`。
///
/// 三条硬规则（逐条都有对应用例）：
/// · **双 Demo 硬规则（D7）**：只看前两个候选，两个都 settled（就绪或有失败记录）才算终态；
///   `succeeded` 但两个还没都 settled ⇒ **不发**；两个都失败 ⇒ **照发**（失败也要通知，
///   但文案里不放红色/感叹号那类情绪符号）；
/// · **载荷里不许有**：任何 URL（含 `covalink.cn` 文本）、音频/签名地址、token、
///   `co 币`、余额、价格、`job.costCredits`、「点击查看/领取」类诱导词；
/// · **路由契约**：`sessionId` 缺失或不合法 ⇒ 回落首页，**不**尝试拼一条会话路由。
public enum StudioNotificationOutcome: Equatable, Sendable {
    /// 两个版本都完成了。
    case bothReady(firstTitle: String?, secondTitle: String?)
    /// 一版完成、另一版没完成。
    case oneReady(title: String?)
    /// 两个版本都没做成。
    case bothFailed
    /// 尚未 settled ⇒ 不发。
    case notSettled
}

public struct StudioNotificationPlan: Equatable, Sendable {
    /// spec 固定标题（含两版都失败的场合 —— 见 `docs/log` 里对这条的存疑记录）。
    public static let fixedTitle = "你的歌做好了"

    public let identifier: String
    public let title: String
    public let body: String
    public let userInfo: [String: String]

    /// 路由所需的 `sessionId`；`nil` = 这条不可路由（UI 侧回落首页）。
    public var sessionID: String? { userInfo[StudioNotificationPlan.sessionKey] }
    public var jobID: String? { userInfo[StudioNotificationPlan.jobKey] }

    public static let sessionKey = "sessionId"
    public static let jobKey = "jobId"
    public static let planCardKey = "planCardId"
    public static let candidateKey = "candidateId"
    public static let sourceKey = "source"
    public static let sourceValue = "local-notification"
}

public enum StudioNotificationPlanner {
    /// 「一个 job 只登记一次」的标识（spec：按 `jobId` 去重；同轮多个 job 合并成一条）。
    public static func identifier(jobID: String) -> String { "cova-generation-\(jobID)" }

    /// 由前两个候选算出该发什么。判定不在这里重写一份 —— 它与 09 的终态条、
    /// 与「选一版继续制作」读同一本账，唯一来源是 `DoubleDemoRule`（D7）。
    ///
    /// **没有 `jobStatus` 形参**是有意的：旧签名带着它，而三条分支没有一条读它
    /// （`switch (readyCount, status)` 的两个 case 都用 `_` 吞掉）—— 留一个不进任何判断的
    /// 参数，等于给后来人"发不发要看 job 态"的假线索。发与不发**只由候选清单决定**。
    public static func outcome(
        candidates: [GenerationCandidateDto]
    ) -> StudioNotificationOutcome {
        let pair = DoubleDemoRule.pair(candidates)
        guard DoubleDemoRule.isTerminal(candidates) else { return .notSettled }
        switch DoubleDemoRule.readyCount(candidates) {
        case 2:
            return .bothReady(
                firstTitle: pair[0].title?.isEmpty == false ? pair[0].title : nil,
                secondTitle: pair[1].title?.isEmpty == false ? pair[1].title : nil
            )
        case 1:
            let winner = pair.first(where: DoubleDemoRule.isReady)
            return .oneReady(title: winner?.title?.isEmpty == false ? winner?.title : nil)
        default:
            // 两个都失败：照发（spec 明令），且不带任何情绪符号。
            return .bothFailed
        }
    }

    /// 终态文案。`notSettled` ⇒ `nil`（不发）。
    public static func body(for outcome: StudioNotificationOutcome) -> String? {
        switch outcome {
        case .bothReady(let first, let second):
            // 标题缺失时用「版本 1/2」而不是留 %@ 空位（那是把没取到的东西显示成占位符）。
            return "「\(first ?? "版本 1")」「\(second ?? "版本 2")」两个版本都完成了"
        case .oneReady(let title):
            return "「\(title ?? "版本 1")」做好了，另一版没完成"
        case .bothFailed:
            return "这次两个版本都没做成"
        case .notSettled:
            return nil
        }
    }

    /// 组装计划。**不**把 `costCredits`、音频地址、任何 URL 放进 userInfo。
    public static func plan(
        job: GenerationJobDto,
        sessionID: String?,
        planCardID: String? = nil,
        candidateID: String? = nil
    ) -> StudioNotificationPlan? {
        guard let jobID = nonEmpty(job.id) else { return nil }
        // 路由契约：sessionId 缺失/不合法 ⇒ 不可路由。仍然发通知（spec 的兜底是
        // 「点进去回落首页」），但绝不拿一个猜出来的 id 去拼路由。
        guard let body = body(for: outcome(candidates: job.candidates())) else {
            return nil
        }
        var userInfo: [String: String] = [
            StudioNotificationPlan.jobKey: jobID,
            StudioNotificationPlan.sourceKey: StudioNotificationPlan.sourceValue,
        ]
        if let sessionID = nonEmpty(sessionID) {
            userInfo[StudioNotificationPlan.sessionKey] = sessionID
        }
        if let planCardID = nonEmpty(planCardID) {
            userInfo[StudioNotificationPlan.planCardKey] = planCardID
        }
        if let candidateID = nonEmpty(candidateID) {
            userInfo[StudioNotificationPlan.candidateKey] = candidateID
        }
        return StudioNotificationPlan(
            identifier: identifier(jobID: jobID),
            title: StudioNotificationPlan.fixedTitle,
            body: body,
            userInfo: userInfo
        )
    }

    /// 点通知后的路由决定：`sessionId` 不合法就回落首页，不拼路由。
    public static func route(from userInfo: [AnyHashable: Any]) -> String? {
        guard let raw = userInfo[StudioNotificationPlan.sessionKey] as? String else { return nil }
        return nonEmpty(raw)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }
}
