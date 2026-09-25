import Foundation

/// `GenerationJobStatus`（后端任务 6 态）的**唯一**中文词表。
///
/// 为什么补在这一层：本仓已经为同一个形状登记过六处（`plan.rawValue`、参数胶囊的 `weirdness`、
/// `status.rawValue`、登录错误直出、`LoopMode.description`、抽屉的第 6 张套餐表），
/// 原判据一直只钉在状态机那一层 ⇒ **判据留在下一层，UI 层就会反复长新的**。
/// （历史：09 的 `reconcileStartedJob` 曾在 `AISessionDetailView.swift:474` 直接印
/// `newest.status.rawValue` ⇒ 本词表当时是"有表没接"。那一行已改走 `userLabel`。）
/// 会把 `succeeded` / `processing` 这类 wire 值直接印上屏。标签挂在它所属的那一层、
/// 并由用例逐 case 钉死（`testEveryGenerationJobStatusSurfacesChineseLabel`），
/// 那处才有一个不需要在本屏现编的词可指。
///
/// 词表来源逐条对齐既有话术，不新造词：
/// · `submitted` = 本屏启动成功那句「已提交，正在排产」（`AISessionDetailView.swift:830`）；
/// · `cancelled` = 09 §3-I 固定的「本轮已停止」（`DeliveryProgressPlanner.stoppedLabel`）；
/// · `succeeded` = 「已完成」（`StudioWorkflowLadder.terminalLabel`）；
/// · `failed` 与 §5 的「两个版本都没能完成」同族说法（单任务口径去掉量词）。
extension GenerationJobStatus {
    /// 上屏用的中文标签。`rawValue` 是线格式与后端词表，只有显示面走这里。
    public var userLabel: String {
        switch self {
        case .queued: return "排队中"
        case .submitted: return "已提交，正在排产"
        case .processing: return "制作中"
        case .succeeded: return StudioWorkflowLadder.terminalLabel
        case .failed: return "没能完成"
        case .cancelled: return DeliveryProgressPlanner.stoppedLabel
        }
    }
}
