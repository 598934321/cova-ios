import Foundation

// MARK: - 08 §3.C 会话行的「进行中进度环」取值面
//
// design 08 §数据源行 140 把这一格的来源钉成一句话：**本设备内存中未终态的 job**
// （由 09 的发起者持有），并且**明令**不得为列表逐行发详情请求（N+1）、不得造字段。
// 所以这里只回答「内存里那个值该画成什么」，不回答「那个值从哪来」——
// 来源接线在 `AppSession`（本仓当前**没有**按会话号存的在途 job 账，见本批报告）。
//
// 三个容易做错、于是专门钉死的地方：
// 1. **没有 job ≠ 进度 0%**：`.idle` 时环、2pt 竖条、「生成中」三者都不出现（§3.C/§5）。
//    冷启动后必然是这一档，且**不报错**（§9 判据第 3 条）。
// 2. **有 job 但没有可读进度 ⇒ 只说「生成中」**，不印也不念百分数（§3.C 环内不放百分数 +
//    §6 行 117）。把「读不到」念成「约 0%」是把未知说成已知。
// 3. **越界/非有限的进度值不钳位**：钳位等于承认"我们知道它至少是 0/至多是 1"，
//    而真实含义是"这个数不是进度"。退化成无定值那一档更诚实。
public enum StudioSessionRing: Equatable, Sendable {
    /// 本设备内存里没有这个会话的未终态 job。
    case idle
    /// 有 job 在跑，但内存里没有可得的进度值（或给了一个不可信的值）。
    case runningWithoutProgress
    /// 有 job 在跑，且内存里有 `0...1` 的实测进度。
    case running(fraction: Double)
}

public enum StudioSessionProgressRing {
    /// 「生成中」——§8 文案清单逐字，且是 §6 行标签里那一格的固定前缀。
    public static let runningLabel = "生成中"

    /// 输入 = 内存账本对该会话的两件事：有没有未终态 job、有没有可读进度。
    ///
    /// `hasLiveJob == false` 时**一律** `.idle`，即使 `progress` 给了个数 ——
    /// 「没有任务却有百分比」是矛盾输入，采信它等于凭空造出一格进行中（§数据源行 140）。
    public static func ring(hasLiveJob: Bool, progress raw: Double?) -> StudioSessionRing {
        guard hasLiveJob else { return .idle }
        guard let raw, raw.isFinite, raw >= 0, raw <= 1 else { return .runningWithoutProgress }
        return .running(fraction: raw)
    }

    /// 弧线填充比例。`nil` = 没有定值（视图取 §3.C 的静态/旋转那一段，不自行补一个数）。
    public static func arcFraction(of ring: StudioSessionRing) -> Double? {
        guard case .running(let fraction) = ring else { return nil }
        return fraction
    }

    /// §6：百分比**只**进 VoiceOver 标签（环内空间不足，§3.C）。无定值 ⇒ `nil`，界面上一个百分数都不出现。
    public static func percent(of ring: StudioSessionRing) -> Int? {
        guard case .running(let fraction) = ring else { return nil }
        return Int((fraction * 100).rounded())
    }

    /// §4：旋转只发生在「无定值」那一档（有定值时环本身就在说进度，转它反而盖掉读数）。
    /// Reduce Motion 下**一律**不转（§4 行 100）。
    public static func spins(of ring: StudioSessionRing, reduceMotion: Bool) -> Bool {
        !reduceMotion && ring == .runningWithoutProgress
    }

    /// §4 行 100 的静态替代：Reduce Motion + 无定值 ⇒ 静态环**再**配一条一次性 2pt 高的不确定进度条。
    /// 有定值那一档本来就是静止的弧，不需要那条额外的不确定条。
    public static func showsIndeterminateFallbackBar(of ring: StudioSessionRing, reduceMotion: Bool) -> Bool {
        reduceMotion && ring == .runningWithoutProgress
    }

    /// §5：进行中行的 2pt `color.accent` 竖条与环同判据（同一档事实 ⇒ 同现同灭）。
    public static func showsInProgressBar(of ring: StudioSessionRing) -> Bool {
        ring != .idle
    }

    /// §6 行标签里的那一格：「生成中」/「生成中，约 68%」。
    public static func voiceOverFragment(of ring: StudioSessionRing) -> String? {
        switch ring {
        case .idle: return nil
        case .runningWithoutProgress: return runningLabel
        case .running:
            // 拿不到百分比就退回只说「生成中」——「约 0%」是把没有读数说成一个读数。
            guard let percent = percent(of: ring) else { return runningLabel }
            return "\(runningLabel)，约 \(percent)%"
        }
    }

    /// §6：**整行一个可聚焦元素**，复合标签顺序「<标题>，<摘要>，<相对时间>，<生成中，约 68%>」。
    /// 缺位的段（摘要拿不到、时间拿不到、没有任务）**不进标签**，也不留空逗号 ——
    /// §数据源行 137/138 要的就是「那一行不渲染」，标签跟着不渲染才是同一件事。
    public static func rowVoiceOverLabel(
        title: String,
        summary: String?,
        relativeTime: String?,
        ring: StudioSessionRing
    ) -> String {
        [title, summary, relativeTime, voiceOverFragment(of: ring)]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "，")
    }
}

// MARK: - 08 §8 相对时间
//
// §8 那张表逐档实现，**一条都不合并**：合并会把「今天内」读成「N 天前」，
// 而 §数据源行 138 的降级口径是「拿不到就整条不渲染（不显示『—』噪声）」⇒ 返回 `nil`。
// 跨年那一档在最后：日级读数（昨天/N 天前）优先于年历读数，与 §8 的排列顺序一致。
public enum StudioRelativeTime {

    /// ISO8601 串 → 中文相对时间。`nil` = 没有可信时间（缺失 / 空 / 解析不出 / **在未来**）。
    ///
    /// 未来时间戳按「不可信」处理而不是钳成「刚刚」：服务器与本机各走各的钟时，
    /// 一个超前几秒的 `updatedAt` 说「刚刚」是在**编造**新鲜度（这一档 §8 根本没有）。
    public static func text(_ raw: String?, now: Date, calendar: Calendar) -> String? {
        guard let date = date(fromISO8601: raw) else { return nil }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return nil }
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60)) 分钟前" }

        // 日级判断一律用**日历天**（昨天 = 昨日整日，不是"24 小时前"），
        // 否则深夜 23:50 的那条在 00:10 会被读成「昨天」以外的东西。
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        if days == 0 { return "\(Int(elapsed / 3_600)) 小时前" }   // 今天内
        if days == 1 { return "昨天" }
        if days <= 7 { return "\(days) 天前" }                      // 本周内

        let format = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "M月d日"          // 更早（同一年）
            : "yyyy年M月d日"    // 跨年
        return dayString(date, format: format, calendar: calendar)
    }

    /// 线上三种形态都认：带 `Z`/偏移、带**小数秒**（2026-09-24 实测 `workflowState.updatedAt` =
    /// `…T13:09:14.778Z`，默认 `ISO8601DateFormatter` **解不出**这一种）、无时区（按东八区读，
    /// 与 `CollectionsViews.date(_:)` 同一口径）。解不出 ⇒ `nil` ⇒ 那一行整条不渲染（§数据源行 138）。
    ///
    /// 小数秒靠**截掉那一段**再解析，而不是换 formatter 选项：本工具链的 `ISO8601DateFormatter`
    /// 没有 `options` 成员（写上去编译期就红），而截断只丢亚秒精度
    /// —— 相对时间最细的一档是「刚刚 / N 分钟前」，亚秒不参与任何判断。
    static func date(fromISO8601 raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let internet = ISO8601DateFormatter()
        let withoutFraction = strippingFractionalSeconds(from: raw)
        if let date = internet.date(from: raw) { return date }
        if let withoutFraction, let date = internet.date(from: withoutFraction) { return date }
        return zonelessDate(raw, alreadyStripped: withoutFraction)
    }

    /// 无时区那一支只能交给 `DateFormatter`：`ISO8601DateFormatter` 在这条链路上要求时区标识存在，
    /// 换 `timeZone` 也不改变"必须有 `Z`/偏移"这件事（实测两支都返回 `nil`）。
    private static func zonelessDate(_ raw: String, alreadyStripped stripped: String?) -> Date? {
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var candidates = [raw]
        if let stripped { candidates.append(stripped) }
        // `T` 分隔与 MySQL DATETIME 的空格分隔都认。
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            out.dateFormat = format
            for value in candidates where !value.isEmpty {
                if let date = out.date(from: value) { return date }
            }
        }
        return nil
    }

    /// `2026-09-24T13:09:14.778Z` → `2026-09-24T13:09:14Z`；小数点不在时间部分里 ⇒ `nil`（不动原串）。
    private static func strippingFractionalSeconds(from raw: String) -> String? {
        guard let timeMark = raw.firstIndex(of: "T"),
              let dot = raw.firstIndex(of: "."), dot > timeMark else { return nil }
        var end = raw.index(after: dot)
        while end < raw.endIndex, raw[end].isNumber { end = raw.index(after: end) }
        guard end > raw.index(after: dot) else { return nil }   // 点后一位数字都没有 ⇒ 不是秒的小数段
        return String(raw[..<dot]) + String(raw[end...])
    }

    private static func dayString(_ date: Date, format: String, calendar: Calendar) -> String {
        let out = DateFormatter()
        // 中文月日年份的写法由 §8 钉死，不跟随系统 locale（否则英文系统上会念成 09/24）。
        out.locale = Locale(identifier: "zh_CN")
        out.calendar = calendar
        out.dateFormat = format
        return out.string(from: date)
    }
}

// MARK: - 08 §3.C 首个候选封面
//
// 这一格只回答「列表里那一份载荷能不能撑起封面」，让「拿不到 ⇒ `sparkles` 占位」这条
// 降级成为**可测**判据，而不是注释里的一句愿望。
public enum StudioSessionCover {
    /// 「**每一行**都带着一张可显示的封面」——**不成立**：2026-09-26 用 owner 给的测试账号实测
    /// `GET /api/find-my-song/sessions`，键 `firstCoverUrl` **在**（`StudioSessionDto` 已建模），
    /// 但那 5 条（全 `workflowMode:"one-step"`）逐条给 `null`。
    /// 所以本常量回答的是"能不能不写占位分支"，而不是"载荷里有没有这个键"（有）——
    /// 两件事混成一个布尔，就会在下一个 `null` 行上长成一张空白封面。
    ///
    /// 消费方：`HomeView` 的 01 §5 小卡整格继续走像素占位（`HomeCreationGridTests` 钉的就是这一条）；
    /// 08 §3.C 那一格自本批起按 `usableCover(_:)` **逐行**分流。
    public static var hasCoverFieldInListPayload: Bool { false }

    /// 逐行判据：这一行到底给了没有一张可用的封面地址。**纯空白算没给**
    /// （撑起来会是一张取不到图的空白 + 一枚出口拒绝警示，那是把"没给"演成"给了坏地址"）。
    ///
    /// 有值时**原样交出、连空白都不 strip**：`%2B` 这类查询串是按字节保真的地址的一部分，
    /// 判据只负责"有没有"，绝不负责"改写"—— 改写属于 `CovaEnvironment.resolveMediaURL` 那一道。
    public static func usableCover(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    /// 无封面时的符号（§3.C 行 62）。
    public static let placeholderSymbol = "sparkles"
}
