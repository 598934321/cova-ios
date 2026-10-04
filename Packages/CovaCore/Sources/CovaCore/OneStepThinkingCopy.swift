import Foundation

/// 09 §3.E thinking 折叠块的**公开短语裁决层**（待裁决 5 的同源依据）。
///
/// 依据：`design/screens/09-ai-session-detail.md` §3.E 要求「若 `thinking.text` 命中未公开化
/// 字样，展示层按白名单短语回退」，短语集「与 web 一步模式公开进度文案同构」。
/// 这里直接移植 web `src/lib/one-step/progress-status.ts` 的整张表（五阶段 × working/refining
/// 两档 + REFINEMENT_MARKERS），逐字对齐 —— web 那边 verifier / schema repair /
/// constraint retry 这类实现词**永远**先经这张表落成对外短语，本端同一本账。
///
/// 为什么是「映射」而不是「白名单通过」：web 的实现是全量映射（任何 label 都先落成公开
/// 短语再上屏），只对「白名单命中才保留原文」的口径会在第一次遇到表外措辞时把内部词
/// 漏出去。映射到最近邻阶段，与 web 的行为逐条一致；判不出来的就落 plan 档
/// 「正在整理计划细节」——正是 09 §3.E 点名的那句兜底。
public enum OneStepThinkingCopy {

    /// SSE `thinking` 帧的 `{text}` → 可上屏的公开短语。
    /// 空/缺失输入也落 plan 档兜底句（折叠行要的是"有一句可说"，不是空行）。
    public static func publicPhrase(_ raw: String?) -> String {
        let label = (raw ?? "").lowercased()
        let stage = resolveStage(label)
        let refining = OneStepStage.refinementMarkers.contains(where: { label.contains($0) })
        return phrases(for: stage, refining: refining)
    }

    /// 内部阶段（与 web `OneStepPublicProgressStage` 逐字对应）。
    enum OneStepStage: String, Equatable, Sendable {
        case requirements, titles, style, lyrics, plan

        /// 与 web `ONE_STEP_REFINEMENT_MARKERS` 同一张表（已小写）。
        static let refinementMarkers: [String] = [
            "重新", "重写", "改写", "批注", "同步", "补齐", "完善", "核对", "约束", "来源",
            "repair", "retry", "verify", "constraint",
        ]
    }

    /// web `resolveProgressStage` 的逐字移植：命中顺序固定（歌词 → 曲风 → 曲名 → 需求 → plan 兜底）。
    static func resolveStage(_ label: String) -> OneStepStage {
        if containsAny(label, ["歌词", "段落", "lyric"]) { return .lyrics }
        if containsAny(label, ["曲风", "风格", "style", "prompt"]) { return .style }
        if containsAny(label, ["曲名", "标题", "候选", "title"]) { return .titles }
        if containsAny(label, ["需求", "分析", "requirement"]) { return .requirements }
        return .plan
    }

    /// web `ONE_STEP_PUBLIC_PROGRESS` 的 working/refining 两档，逐字。
    static func phrases(for stage: OneStepStage, refining: Bool) -> String {
        switch (stage, refining) {
        case (.requirements, false): return "正在理解你的创作需求"
        case (.requirements, true): return "正在完善创作方向"
        case (.titles, false): return "正在构思候选曲名"
        case (.titles, true): return "正在完善候选曲名"
        case (.style, false): return "正在设计曲风"
        case (.style, true): return "正在完善曲风方向"
        case (.lyrics, false): return "正在创作歌词"
        case (.lyrics, true): return "正在完善歌词结构"
        case (.plan, _): return "正在整理计划细节"
        }
    }

    private static func containsAny(_ label: String, _ markers: [String]) -> Bool {
        markers.contains { label.contains($0) }
    }
}
