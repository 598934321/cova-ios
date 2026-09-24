import Foundation

/// 09 候选卡 ♡ 收藏的**账**（`design/screens/09-ai-session-detail.md` §3-H / §8「候选收藏」）。
///
/// 为什么把这本账放进 CovaCore 而不是留在 View 里：它守的是这个仓反复踩过的那一类缺陷 ——
/// 「服务方法声明了却没有调用点」与「本地乐观值被当成事实」。两条都在这里可被测住：
/// · **不渲染即无账**：没有 `mediaReferenceId` 的候选**不进账**（spec 钉「整钮不渲染」，
///   不是禁用），于是 UI 拿不到可点状态；
/// · **刷新必须重新播种**：详情载荷到达 = 用服务端值整本覆盖，未确认的乐观翻转一律作废
///   （留住它就是把「本地的谎」继续显示成「后端的谎」）；
/// · **失败回落服务端事实**：PATCH 失败时回到上一次的服务端值，而不是回到"点之前的本地值"，
///   两者在「连点 + 中途刷新」下并不等价；
/// · **同一候选连点吞后发**（09 §10 并发），靠在途集合而不是靠按钮禁用。
///
/// 写路径本身（`PATCH /api/media/references/:id/retention`，体 = `{favorite}`）**不带幂等键**：
/// 该端点按值幂等（api-contracts §4 只给了 `{favorite}` 一个字段），
/// 发明 `idempotencyKey` 属改契约 ⇒ 需要时走 `docs/NEEDS.md`，不在客户端加字段。
public struct CandidateFavoriteLedger: Equatable, Sendable {
    /// 上一次**从服务端拿到**的值（详情载荷播种 / PATCH 成功回显）。乐观值不进这本。
    public private(set) var serverTruth: [String: Bool] = [:]
    /// 界面读的那本：正常情况下等于 `serverTruth`，PATCH 在途时短暂背离（乐观翻转）。
    public private(set) var displayed: [String: Bool] = [:]
    /// 在途的 `mediaReferenceId`。
    public private(set) var inFlight: Set<String> = []

    public init() {}

    /// 详情载荷到达 ⇒ **整本重新播种**。
    ///
    /// 没有 `mediaReferenceId` 的候选直接跳过（不是"按未收藏入账"，是**根本不入账**）；
    /// `favorite` 缺席按 `false` 记（保守：后端没说 = 不声称已收藏），与"不渲染"是两回事。
    public mutating func reseed(from candidates: [GenerationCandidateDto]) {
        var truth: [String: Bool] = [:]
        for candidate in candidates {
            guard let referenceID = Self.referenceID(of: candidate) else { continue }
            truth[referenceID] = candidate.favorite ?? false
        }
        serverTruth = truth
        displayed = truth
        inFlight = []
    }

    /// ♡ 是否渲染（09 §8：`mediaReferenceId` 缺失时**整钮不渲染**）。
    public static func canFavorite(_ candidate: GenerationCandidateDto) -> Bool {
        referenceID(of: candidate) != nil
    }

    /// 当前该显示成收藏还是未收藏。无账（不该被点的候选）按未收藏渲染。
    public static func isFavorite(_ candidate: GenerationCandidateDto, in ledger: Self) -> Bool {
        guard let referenceID = referenceID(of: candidate) else { return false }
        return ledger.displayed[referenceID] ?? false
    }

    /// 点一下 ♡：返回 `nil` 表示**这次点击不该产生请求**（不可收藏 = 无 `mediaReferenceId`，
    /// 或该候选已有 PATCH 在途 ⇒ 09 §10「同一候选连点 ♡ 吞后发」）。
    /// 返回值里带 `referenceID`，调用方因此**不需要**再去解一次可选字段（解错一次就是往
    /// `/api/media/references//retention` 发请求）。
    public mutating func beginToggle(
        _ candidate: GenerationCandidateDto
    ) -> (referenceID: String, target: Bool)? {
        guard let referenceID = Self.referenceID(of: candidate) else { return nil }
        guard !inFlight.contains(referenceID) else { return nil }
        let target = !(displayed[referenceID] ?? false)
        inFlight.insert(referenceID)
        displayed[referenceID] = target
        return (referenceID, target)
    }

    /// PATCH 成功。有回显以回显为准；无回显采信已发送值（端点按值幂等 ⇒ 2xx 就是服务端认了这个值）。
    public mutating func confirm(referenceID: String, sent: Bool, echoed: Bool?) {
        let settled = echoed ?? sent
        serverTruth[referenceID] = settled
        displayed[referenceID] = settled
        inFlight.remove(referenceID)
    }

    /// PATCH 失败 ⇒ 回落到**服务端事实**，返回回落后的值（调用方据此把失败说给用户，不许静默）。
    @discardableResult
    public mutating func reject(referenceID: String) -> Bool {
        let restored = serverTruth[referenceID] ?? false
        displayed[referenceID] = restored
        inFlight.remove(referenceID)
        return restored
    }

    /// `mediaReferenceId` 为空串也按「没有」处理：拿空串去拼 `PATCH /api/media/references//retention`
    /// 是一条注定失败的写请求，不配拥有一个按钮。
    static func referenceID(of candidate: GenerationCandidateDto) -> String? {
        guard let id = candidate.mediaReferenceId else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : id
    }
}
