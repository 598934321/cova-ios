import Foundation

/// 09 §10「零余额」行内话术的**判定层**（retryable_failure + 余额类 errorMessage 才命中）。
///
/// 词表的两条边界都有意收窄：
/// · **不收「不足」裸词** —— 「参数不足」「时长不足」这类失败不该长成余额话术；
/// · 不收 `co` 裸词 —— 「co」是常见英文子串（`core`/`record`），会误伤。
/// 命中的都必须是"余额/额度/点数/积分 + 不足/不够"或后端英文族（insufficient…/topup）
/// 的**完整**说法，宁漏勿冤：漏了仍是普通的「未完成，可重试」卡，冤了就是把一次
/// 制作失败说成扣费问题。
public enum OneStepPlanFailureCopy {

    /// 命中余额/额度类拒绝（输入大小写不敏感，内部一律 lowercase 后查子串）。
    public static func isBalanceRefusal(_ message: String?) -> Bool {
        guard let message else { return false }
        let text = message.lowercased()
        return refusalMarkers.contains { text.contains($0) }
    }

    /// 09 §10 零余额段的固定行内文案（费用行整行转 error 色）。
    public static let balanceRefusalNotice = "这次没有扣费，余额不足以开始制作"

    /// 词表（已小写；新增词必须能说清「它为什么会出现在 job.errorMessage 里」）。
    static let refusalMarkers: [String] = [
        "余额不足", "余额不够",
        "额度不足", "额度不够",
        "点数不足", "点数不够",
        "积分不足", "积分不够",
        "insufficient balance", "insufficient_balance",
        "insufficient credit", "insufficient_credit",
        "insufficient funds", "insufficient_funds",
        "topup_required", "topup required",
        "low balance", "low_balance",
    ]
}
