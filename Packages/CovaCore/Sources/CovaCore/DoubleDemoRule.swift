import Foundation

/// 双 Demo 终态硬规则（**D7** / AGENTS 硬边界 6 / `design/screens/09-ai-session-detail.md` §5）
/// 的**唯一**判定处。
///
/// 为什么要在这一层集中：这条规则被**两处**生产代码读 ——
/// ① 09 的终态条、「选一版继续制作」与候选行的可点性（`AISessionDetailView`）；
/// ② 18 本地通知的「两个都 settled 才发、两个都失败也要发」（`StudioNotificationPlanner`）。
/// 两处各写一份 `status == .ready` 的布尔式，漂移只是时间问题，
/// 而它一旦漂移就是「在只有一版就绪时报出终态」这种最难发现的谎。
///
/// 三条口径逐字对齐契约：
/// · **只取前两个**候选（后端给 3+ 时第三个不参与任何判定）；
/// · **就绪 = `audioDownloadStatus == ready` 且有地址**（api-contracts §4 原文「ready+URL」）——
///   只认状态会把"报了 ready 但地址还没跟着来"当成可交付，终态就建在放不出声音的候选上；
///   契约没给状态时回落到唯一还能观察的事实：有没有地址；
/// · **settled = 就绪 或 有失败记录**；两个都 settled 才算终态，不足两个候选永不终态。
public enum DoubleDemoRule {
    /// 本轮看得见的候选：前两个（硬规则，多余的一律不进任何判定与列表）。
    public static func pair(_ candidates: [GenerationCandidateDto]) -> [GenerationCandidateDto] {
        Array(candidates.prefix(2))
    }

    /// 就绪（可试听 / 可被挑去继续制作）。
    public static func isReady(_ candidate: GenerationCandidateDto) -> Bool {
        let hasAudio = candidate.audioUrl?.rawValue.isEmpty == false
        guard let status = candidate.audioDownloadStatus else { return hasAudio }
        return status == .ready && hasAudio
    }

    /// 有失败记录。
    public static func isFailed(_ candidate: GenerationCandidateDto) -> Bool {
        candidate.audioDownloadStatus == .failed
    }

    /// settled = 两条终局之一。
    public static func isSettled(_ candidate: GenerationCandidateDto) -> Bool {
        isReady(candidate) || isFailed(candidate)
    }

    /// 终态 = 前两个候选**都** settled。不足两个 ⇒ 永远不是终态（本轮还没结束，不是"少一个也行"）。
    public static func isTerminal(_ candidates: [GenerationCandidateDto]) -> Bool {
        let pair = pair(candidates)
        return pair.count == 2 && pair.allSatisfy(isSettled)
    }

    public static func readyCount(_ candidates: [GenerationCandidateDto]) -> Int {
        pair(candidates).filter(isReady).count
    }

    public static func failedCount(_ candidates: [GenerationCandidateDto]) -> Int {
        pair(candidates).filter(isFailed).count
    }

    /// 「选一版继续制作」的可用条件（09 §5 行 4 与行 5）：终态 **且** 至少有一版真的可挑。
    /// 两版全失败时没有可交付的音频 ⇒ 不给出一个点了只会失败的钮（那行只要求引导重说一句话）。
    public static func canChooseVersion(_ candidates: [GenerationCandidateDto]) -> Bool {
        isTerminal(candidates) && readyCount(candidates) >= 1
    }
}
