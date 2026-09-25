import Foundation

/// 02 播放器屏的**纯**格式化面（design/screens/02-player.md §1/§3）。
///
/// 放这一层的理由：时间读法与波形柱高度都是「错了会骗人」的口径
/// （`-02:18` 算错=谎报剩余；柱高归一错=把 NaN/负值画进 UI），必须可被 XCTest 钉住，
/// 而不是埋在 SwiftUI 的 preview/geometry 里（那部分永远不声称被测）。
public enum PlayerTime {
    /// 已播时间：`mm:ss`（分钟补零，§1 的 `00:42`）；超过一小时转 `h:mm:ss`。
    /// 非有限值（NaN/inf）与负值一律按 0 读 —— 不显示 `nan`，也不显示负秒数。
    public static func elapsed(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, Int(floor(seconds))) : 0
        if safe >= 3600 {
            return String(format: "%d:%02d:%02d", safe / 3600, (safe % 3600) / 60, safe % 60)
        }
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }

    /// 剩余时间：`-mm:ss`（§1 右侧的 `-02:18`）。时长未知或已越界一律显示 `-00:00`，
    /// 不编造一个看起来像真数据的数字。
    public static func remaining(position: Double, duration: Double) -> String {
        guard position.isFinite, duration.isFinite else { return "-\(elapsed(0))" }
        return "-\(elapsed(duration - position))"
    }
}

/// 波形进度条的柱高度归一（02 §3：数据源 `TrackDto.waveformPeaks`，线上实测 128 点、0…1 域）。
public enum WaveformBars {
    /// 柱数与 web 端紧凑播放器同口径（48 根，避免整屏铺柱的布局成本）。
    public static let defaultBarCount = 48

    /// 把任意长度的 peaks 重采样成恰好 `barCount` 根 0…1 柱高（桶内取最大，保留峰值轮廓）。
    ///
    /// 退化裁决（调用方据此走 §3 的「无波形数据 ⇒ 3pt 细线进度条」）：
    /// - 空数组 / 只有 1 个点 / `barCount ≤ 0` → `[]`（一根柱不构成波形）；
    /// - 全零（或只有 NaN）→ `[]`（没有可用信号，画平线是骗人的进度条）；
    /// - NaN/inf 按 0 计（不剔除，剔除会让桶错位）；负值钳到 0，超过 1 钳到 1。
    public static func heights(peaks: [Double], barCount: Int = defaultBarCount) -> [Double] {
        guard barCount > 0, peaks.count >= 2 else { return [] }
        let clamped: [Double] = peaks.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        guard (clamped.max() ?? 0) > 0 else { return [] }
        let count = clamped.count
        return (0..<barCount).map { bar in
            let start = bar * count / barCount
            let end = max(start + 1, (bar + 1) * count / barCount)
            return clamped[start..<min(end, count)].max() ?? 0
        }
    }

    /// 播放进度占比（0…1 钳制）。时长未知/非有限 → 0（细线与柱条着色都只认这一个口径）。
    public static func progress(position: Double, duration: Double) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// 高亮区间（`highlightStart/End`，§3 的 2pt 刻度带）折算成时间轴占比区间。
    /// 非法区间（反向/非有限/时长未知）→ nil：UI 不放刻度带，而不是画一条假的。
    public static func highlightFraction(start: Double, end: Double, duration: Double) -> ClosedRange<Double>? {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0, end > start else { return nil }
        let from = min(max(start / duration, 0), 1)
        let to = min(max(end / duration, 0), 1)
        guard to > from else { return nil }
        return from...to
    }
}
