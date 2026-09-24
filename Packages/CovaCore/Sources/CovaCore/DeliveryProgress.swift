import Foundation

/// 09 §3-I「补充制作进度条」的**纯映射**（`design/screens/09-ai-session-detail.md` §3-I / §8 / §9）。
///
/// ### 为什么这里没有百分比
/// 契约里**不存在任何进度字段**：`OneStepPlanCardDto`（api-contracts §4 的 12 态卡）没有
/// `progress` / `percent` / `deliveryProgress`；`GenerationJob` 只有 6 态 + `costCredits` +
/// `metadata`；§3-I 收尾条件写的 `fullMediaReady` 也不在候选投影里。
/// ⇒ **不印猜出来的数字**（09 §8「字段可空规则」同一口径：取不到就不渲染，不占位）。
/// 这里改成「里程碑」：分母 = 契约里真实存在的推进序列 + 那一格我们观察不到的完成态，
/// 分子 = 当前状态在序列里的位置。右列因此显示 `7/9` 这类**阶段计数**而不是 `78%`，
/// 并且本条**永远不会填满** —— 填满等于声称「完整音频已交付」，而那正是没有依据的一件事。
/// 百分比位真正的来源已登记 **NEEDS-25**。
///
/// ### 英文态名不得出现在界面上（09 §8）
/// 界面上只有下面三个中文标签与阶段计数，任何 `delivery_preparing` / `queued` 之类的
/// 契约原文都不许外溢（用例逐条钉住「产出的文案里没有 ASCII 字母」）。
public struct DeliveryProgress: Equatable, Sendable {
    /// 左列文案（09 §3-I 固定串 / §9 行 9 / §9 末注的「本轮已停止」）。
    public let label: String
    /// 1...totalMilestones —— 由契约状态映射出的固定里程碑，**不是**实测进度。
    public let milestone: Int
    public let totalMilestones: Int

    /// 轨道填充比例（`color.accent` 那一段）。
    public var fraction: Double { Double(milestone) / Double(totalMilestones) }
    /// 右列：阶段计数（顶替百分比位，见类型注释）。
    public var stepText: String { "\(milestone)/\(totalMilestones)" }
    /// VoiceOver（09 §7「补充制作中，<百分比>」）：值变化**不**逐帧播报，只在元素被聚焦时读当前值。
    public var voiceOverLabel: String { "\(label)，第 \(milestone) 步，共 \(totalMilestones) 步" }

    public init(label: String, milestone: Int, totalMilestones: Int) {
        self.label = label
        self.milestone = milestone
        self.totalMilestones = totalMilestones
    }
}

public enum DeliveryProgressPlanner {
    /// 左列三个固定文案（逐字取自 spec，禁改）。
    public static let preparingLabel = "补充制作中"
    public static let rehydratingLabel = "正在恢复完整音频"
    public static let stoppedLabel = "本轮已停止"

    /// 契约里真实存在的**前进序列**（`OneStepPlanStatus` 的正常推进路径）。
    ///
    /// 少掉的四态（`patching` 修改中 / `manual_recovery` 需人工处理 /
    /// `retryable_failure` 未完成可重试 / `archived` 已归档）不是"走到哪一步"，
    /// 是"这一轮不在这条路上" ⇒ 没有位置，返回 `nil`。
    public static let forwardPath: [OneStepPlanStatus] = [
        .analyzing, .ready, .starting, .generating,
        .mediaStaging, .demosReady, .deliveryPreparing, .rehydrating,
    ]

    /// 分母 = 前进序列 + **一格完成态**（§3-I 的 `fullMediaReady`，契约未给）。
    /// 这一格永远不会被指到，所以进度条在窗口内至多走到 `8/9`。
    public static var totalMilestones: Int { forwardPath.count + 1 }

    /// 状态 → 里程碑（1 起算）；不在前进序列上 ⇒ `nil`。
    public static func milestone(for status: OneStepPlanStatus) -> Int? {
        guard let index = forwardPath.firstIndex(of: status) else { return nil }
        return index + 1
    }

    /// §3-I 的出现条件：**仅** `delivery_preparing` 或 `rehydrating`。
    /// 其余状态（包括两格之间的 `demos_ready` 与之后的 `archived`）一律不出现该条 ——
    /// §9 表把这一条钉在行 8/行 9 的「卡体附加表现」列，多画就是发明。
    public static func isInDeliveryWindow(_ status: OneStepPlanStatus) -> Bool {
        status == .deliveryPreparing || status == .rehydrating
    }

    /// 算出该画什么。`jobStatus` 只影响**一件事**：本轮被取消 ⇒ 文案改「本轮已停止」
    /// （§9 末注把「已取消」这条表现层语义指定给 I 条），里程碑停在原地不后退也不前进。
    public static func progress(
        planStatus: OneStepPlanStatus,
        jobStatus: GenerationJobStatus?
    ) -> DeliveryProgress? {
        guard isInDeliveryWindow(planStatus), let milestone = milestone(for: planStatus) else {
            return nil
        }
        if jobStatus == .cancelled {
            return DeliveryProgress(
                label: stoppedLabel, milestone: milestone, totalMilestones: totalMilestones
            )
        }
        return DeliveryProgress(
            label: planStatus == .rehydrating ? rehydratingLabel : preparingLabel,
            milestone: milestone,
            totalMilestones: totalMilestones
        )
    }
}
