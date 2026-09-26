import CovaCore
import Foundation

/// 断流之后的恢复腿（§5 P1-5 后半 / §7 #52）。
///
/// 09 的 agent 流按 §4.7 既不发 `id:` 也无 `Last-Event-ID`/缓冲 ⇒ 断了**不能续播**。
/// 能做的只有：把 `run_started` 那一帧里的 runId 记下来，在流不活着的那段时间按
/// `run.status / currentStep / timeline[].sequence` 回读对账。
/// 判据全在这一层（纯函数），调度沿用本屏任务轮询那套令牌形状。
public enum AgentRunRecovery {

    /// 终态词表由**接线层**注入（`AgentRunTerminalVocabulary` 的文件头要求的就是这个：
    /// 核心层不写死一份自己没核过的词表）。
    /// 出处 `web/src/lib/agent/run.ts:7`：`RunStatus` 八态里只有
    /// `completed`（成功）与 `failed`（失败）是终态，其余六态都还在跑。
    public static let terminalVocabulary = AgentRunTerminalVocabulary(
        successStatuses: ["completed"], failureStatuses: ["failed"]
    )

    /// `run_started` 的载荷（`web/src/lib/studio/agent-route.ts:778` 放的是
    /// `{runId, turnId, goal, autonomous}`）。只建模这一格要用的那一个键。
    private struct RunStartedPayload: Decodable {
        let runId: String?
    }

    /// 从一帧里取 runId。不是 `run_started`、或载荷没给这个键 ⇒ `nil`（不猜别的键名）。
    public static func runID(from frame: CovaSSEFrame) -> String? {
        guard case .runLifecycle(let name) = frame.event, name == "run_started" else { return nil }
        return frame.decodePayload(RunStartedPayload.self)?.runId
    }

    /// `run.status` → 09 §3.F 表里**已有**的那四条短语。
    ///
    /// in-flight 四态（`planning`/`executing`/`verifying`/`repairing`）一律 `nil`：
    /// §3.F 对没进表的写法是"不显示、保持上一条不回落" ⇒ 不替它发明一句新文案。
    public static func label(forStatus status: String?) -> String? {
        switch status {
        case "waiting_user": return "等待你的决定"
        case "waiting_worker": return "歌曲制作中"
        case "completed": return "处理完成"
        case "failed": return "处理失败"
        default: return nil
        }
    }

    /// 该不该发这一趟。三格都不许少：
    /// · 没有 runId ⇒ 没东西可问；
    /// · 流正读这一轮 ⇒ 主人是流，轮询回来也只能丢（与任务轮询同一裁决）；
    /// · 上一次读数已是终态 ⇒ 服务端已经把这轮说完了，继续问只是白要。
    /// `.unknown`（没读到 / 读不懂）**算该继续**：那正是"还没拿到事实"，不是"没事可做"。
    public static func shouldPoll(
        runID: String?, streamOwnsRound: Bool, lastTerminality: AgentRunTerminality
    ) -> Bool {
        guard runID != nil, !streamOwnsRound else { return false }
        return lastTerminality != .success && lastTerminality != .failure
    }
}

/// `GET /api/studio/agent-runs/{id}` 的读腿（登录态；401 未认证、404 `运行记录不存在`）。
public struct AgentRunService: Sendable {

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// `AgentRunResponseDto.path(runID:)` 判定这枚 id 不能安全进路径段 ⇒ **不发**（`nil`），
    /// 不退化成"猜一个号"，也不自己拼字符串绕过那枚校验。
    public func snapshot(runID: String) async throws -> AgentRunResponseDto? {
        guard let path = AgentRunResponseDto.path(runID: runID) else { return nil }
        return try await client.get(path)
    }
}
