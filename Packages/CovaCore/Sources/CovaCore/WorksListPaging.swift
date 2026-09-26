import Foundation

// MARK: - 20 屏的纯分页账（§5 P1-1「分页是这一屏最容易做错的一条」）
//
// 为什么这一层必须存在，而不是把合并写在 `WorksListState` 里：
// 服务端今天的 `cursor` 是**字符串化的行偏移**（§4.7 明写「不是不透明游标」）⇒
// 两次翻页之间只要有人新增/删除一行，第二页的头几行就会把第一页的尾巴**再发一遍**，
// 或者整页往前挪一行。「把两页数组拼起来」在这种服务端上不是拼接，是**重复行 + 漏行**。
// 本层只做三件事，而且只做一次（同一个判据写两遍是本仓反复复发的缺陷族）：
// · 按行 `id` 去重（折叠掉的条数**记账**，不静默少行）；
// · 游标纪律（`nextCursor == null` 即到底；与刚发出去的那个一模一样 ⇒ 不许再发一次）；
// · `total` 与已取条数的差额（屏上那句「还有 N 行没取到」的唯一来源）。
//
// 刻意**不做**的事：不解析 cursor、不自算 offset、不按 `jobId` 重排整表
// （§3.D 的跨页切断就是要用户在第二页再看到一次同样的组头，重排会把这个事实抹掉）。

/// 一次合并的结果（屏上那三本账的唯一派生点）。
public struct WorksListMerge: Equatable, Sendable {
    /// 合并后的整表（已按行 `id` 去重，顺序 = 服务端给的顺序）。
    public let rows: [WorksListRowDto]
    /// 这一次**新进表**的行数（整表替换时 = 表长；追加时 = 去重后的净增）。
    public let acceptedCount: Int
    /// 这一次被折叠掉的重复行数（`page.works` 里 id 已经在表里的那些）。
    ///
    /// 它必须可断言：offset 漂移的表现形式就是"这一页一半是上一页的尾巴"，
    /// 悄悄丢掉等于把服务端的分页缺陷伪装成客户端的"我数错了"。
    public let duplicateCount: Int
    /// 累计「读不出身份」的元素个数（各页相加；与 `total` 一起才解释得清为什么少行）。
    public let unreadableItemCount: Int
    /// 服务端给的整表条数原值（**最新一页**非 nil 的那个；不本地重算，见 §3.B 待答 1）。
    public let total: Int?
    /// 下一页游标原文；`nil` = 到底了。
    public let nextCursor: String?

    public init(
        rows: [WorksListRowDto], acceptedCount: Int, duplicateCount: Int,
        unreadableItemCount: Int, total: Int?, nextCursor: String?
    ) {
        self.rows = rows
        self.acceptedCount = acceptedCount
        self.duplicateCount = duplicateCount
        self.unreadableItemCount = unreadableItemCount
        self.total = total
        self.nextCursor = nextCursor
    }

    /// 还有多少行**没到屏上**（§7：`works.count + unreadableItemCount < total` 就得说实话）。
    ///
    /// `nil` 有两种意思，都不渲染那一行：服务端没给 `total`（口径待答 1）、
    /// 或者差额 ≤0（offset 漂移让屏上比 `total` 还多时，"多出来"不是新事实，说它是假的）。
    public var missingRowCount: Int? {
        WorksListPaging.shortfall(rows: rows.count, unreadable: unreadableItemCount, total: total)
    }

    /// 服务端**没给**下一页的入口。注意这不等于"只有一页"。
    public var hasMorePages: Bool { nextCursor != nil }
}

/// 一页怎么接到账上：整表替换（新选择 / 首载 / 下拉刷新）还是追加下一页。
public enum WorksListMergeMode: Equatable, Sendable {
    /// 游标归零那一条腿（§7：任何 `filter`/`q`/`sort` 变更 ⇒ cursor 归零、列表整体替换）。
    case replace
    /// 回传上一次 `nextCursor` 的那一条腿（只追加，不重排）。
    case append
}

public enum WorksListPaging {
    /// 差额本体（`WorksListMerge.missingRowCount`、屏上那一行与单测共用这一个算式，
    /// 不两处各写一遍）。
    public static func shortfall(rows: Int, unreadable: Int, total: Int?) -> Int? {
        guard let total, total > 0 else { return nil }
        let accounted = rows + unreadable
        return accounted < total ? total - accounted : nil
    }

    /// §8 极值：连续翻页 ≤10 页后停止自动加载（并要求用户下拉）。
    ///
    /// 为什么钉一个上限而不是"翻到 null 为止"：cursor 是 offset，翻页次数越多、
    /// 中途插删行造成的漂移越明显（重复行与漏行都随深度增长）。上限只砍**自动**加载，
    /// 不砍下拉刷新 —— 下拉是 `replace`，账本整本重开。
    public static let maximumConsecutivePages = 10

    /// 合并一页。纯函数：不碰时钟、不改服务端给的顺序。
    public static func merge(
        page: WorksPageDto,
        onto existing: [WorksListRowDto],
        unreadableSoFar: Int,
        totalSoFar: Int?,
        mode: WorksListMergeMode
    ) -> WorksListMerge {
        let replacing = mode == .replace
        var rows: [WorksListRowDto] = []
        rows.reserveCapacity(replacing ? page.works.count : existing.count + page.works.count)
        var seen = Set<String>()
        // 整表替换时 `existing` 被丢掉，但**同一页内部**也可能有整串重复的 id
        // （§4.7：裸 jobId 行与它的候选行并存 ⇒ `WorksPageDto` 刻意不去重，去重是本层的账）。
        let incoming = replacing ? page.works : existing + page.works
        for row in incoming {
            if seen.insert(row.id).inserted {
                rows.append(row)
            }
        }
        let base = replacing ? 0 : existing.count
        let accepted = max(0, rows.count - base)
        return WorksListMerge(
            rows: rows,
            acceptedCount: accepted,
            duplicateCount: max(0, page.works.count - accepted),
            unreadableItemCount: replacing ? page.unreadableItemCount : unreadableSoFar + page.unreadableItemCount,
            total: replacing ? page.total : (page.total ?? totalSoFar),
            nextCursor: page.nextCursor
        )
    }

    /// 还要不要发下一页：**四条**都成立才发。
    ///
    /// ① 没有正在进行的读（并发只留一条腿，后到的落账会覆盖先到的）；
    /// ② 服务端给了下一页入口（`nextCursor != nil`）—— **绝不自算 offset 补一个**；
    /// ③ 那个游标与上一次发出去的不相同（§4.7 的死循环形状：服务端把同一个 offset 又回给你，
    ///    再发一次只是把同一页拿第二遍，屏上就是一半重复行）；
    /// ④ 没到连续翻页上限。
    public static func canAdvanceToNextPage(
        nextCursor: String?, lastSentCursor: String?, pagesLoaded: Int, isReading: Bool
    ) -> Bool {
        guard !isReading else { return false }
        guard let nextCursor else { return false }
        guard nextCursor != lastSentCursor else { return false }
        return pagesLoaded < maximumConsecutivePages
    }

    // MARK: - 行的锚点（一次生成两行 = 同一个 job）

    /// 组头锚点 = 这一行属于哪一次生成。
    ///
    /// 优先级说清楚，免得两条腿各挑一个：
    /// · `jobId` 字段是**服务端自己给的**，最权威（重命名后回读 `?id=<jobId>` 用的就是它）；
    /// · 缺字段时退回从 `id` 前段解出来的（§4.7 四种形状里 `{jobId}:…` 的前段就是 jobId）；
    /// · 两个都拿不到 ⇒ 以原 id 自成一锚（§7 字段可空规则：那种行**不可作为组头锚点**，
    ///   单行成组，但它在屏上仍然是一行，不能被丢掉）。
    public static func anchor(of row: WorksListRowDto) -> String {
        if let jobId = WorksListQuery.textIfPresent(row.jobId) { return jobId }
        if let jobID = row.identity.jobID { return jobID }
        return row.id
    }

    /// 这一行有没有一个**可指认**的 job 身份（`.irregular` 的 id 没有）⇒ 决定组头能不能回读。
    public static func jobID(of row: WorksListRowDto) -> String? {
        if let jobId = WorksListQuery.textIfPresent(row.jobId) { return jobId }
        return row.identity.jobID
    }

    /// 删除成功后本地移除该 job 的**全部**行（含跨页已取到的，§7 ③）。
    public static func removing(rows: [WorksListRowDto], anchor: String) -> [WorksListRowDto] {
        rows.filter { Self.anchor(of: $0) != anchor }
    }

    /// 按 job 回读后回填：**就地替换**（不重排、不新增）。
    ///
    /// 为什么不重排：`?id=` 回读的是这个 job 的全部行，而屏上那张表是**服务端排序**的整表；
    /// 把这两行抽出来插到别处就是客户端在服务端的账本上重画顺序（§3.D 的切断形态也会跟着消失）。
    /// 回读里没有的 id ⇒ 原行留着（那一行的其他字段仍是上一次读到的事实，不是"没了"）。
    public static func applying(
        refreshed: [WorksListRowDto], to rows: [WorksListRowDto], anchor: String
    ) -> [WorksListRowDto] {
        var replacement: [String: WorksListRowDto] = [:]
        for row in refreshed where Self.anchor(of: row) == anchor {
            replacement[row.id] = row
        }
        guard !replacement.isEmpty else { return rows }
        return rows.map { row in
            Self.anchor(of: row) == anchor ? (replacement[row.id] ?? row) : row
        }
    }
}

// MARK: - 分组（§3.D 任务组头：本屏的合规焦点）

/// 连续同锚点的一批行 = 一个任务组。
///
/// 为什么是"连续"而不是"按 job 聚合"：cursor 是 offset ⇒ 同一 job 的两行会被分页切开，
/// 规格对这一条的裁决是**重新出现同一组头**（§3.D），而不是把第二页的头一行搬回上一组。
/// 聚合会把这件事藏起来，切分会把它如实画出来。
public struct WorksJobGroup: Equatable, Sendable {
    /// 组头锚点（`jobId`，或认不出 job 的行的原 id）。
    public let anchor: String
    /// 可指认的 job 身份；`nil` = 这一行认不出自己属于哪次生成 ⇒ 组头的回读腿不发。
    public let jobID: String?
    /// 组内行（顺序照服务端）。
    public let rows: [WorksListRowDto]
    /// 组头在整表里的第一个行下标（XCUITest 的 `cova.works.row.N` 要按整表编号）。
    public let firstRowIndex: Int
    /// 组内**第一行的来源**（§4.7 分享钮可见性判据只看这一个字段，见 `canShare`）。
    public let source: String?

    public var rowCount: Int { rows.count }

    /// 「分享本次生成的作品」这一项**在不在**（不是禁不禁用）。
    ///
    /// §7 的判据：`works/:id/share` 只解 create 作品，而 `CreateWorkItem` **没有** `shareable`
    /// 布尔位 ⇒ 本屏只有 `source` 这一个判别式。`one-step`/`song-match` 来源**不渲染**该项
    /// （手册 §7 #24「无目标 ⇒ 不渲染分享钮」），来源缺失同样不渲染 —— 认不出来源就是没有目标。
    public var canShare: Bool { source == "studio-create" }

    /// 组内可播的行数（一次生成恒 ≤2 行，占位行不算）。
    public var playableRowCount: Int { rows.filter(\.isPlayable).count }

    /// 整组都是占位行 ⇒ 这一组还在做，组头 ⋯ 的 job 级动作发早了只会换一次 409。
    public var isAllPlaceholders: Bool {
        !rows.isEmpty && rows.allSatisfy(\.isPendingPlaceholder)
    }
}

public enum WorksListGrouping {
    /// 连续同锚点切组。**不排序、不丢弃、不去重**（那些是 `merge` 的账）。
    public static func groups(in rows: [WorksListRowDto]) -> [WorksJobGroup] {
        var groups: [WorksJobGroup] = []
        var current: [WorksListRowDto] = []
        var anchor = ""
        for (index, row) in rows.enumerated() {
            let rowAnchor = WorksListPaging.anchor(of: row)
            if !current.isEmpty, rowAnchor != anchor {
                groups.append(group(current: current, anchor: anchor, firstIndex: index - current.count))
                current = []
            }
            if current.isEmpty { anchor = rowAnchor }
            current.append(row)
        }
        if !current.isEmpty {
            groups.append(group(current: current, anchor: anchor, firstIndex: rows.count - current.count))
        }
        return groups
    }

    private static func group(
        current: [WorksListRowDto], anchor: String, firstIndex: Int
    ) -> WorksJobGroup {
        WorksJobGroup(
            anchor: anchor,
            jobID: current.first.flatMap(WorksListPaging.jobID(of:)),
            rows: current,
            firstRowIndex: firstIndex,
            source: current.first?.source
        )
    }
}

// MARK: - 两个标记的可读性（§3.E / `signalConflict`）

extension WorksListRowDto {
    /// 服务端这一行的 favorite/dislike **能不能被诚实地画出来**。
    ///
    /// 两种"画不准"，都不画：
    /// · `favorited && disliked`（§4.7：服务端两者互斥 ⇒ 同时为真只可能是账没对上）——
    ///   挑一个显示就是替服务端决定它没决定的事；
    /// · `signalShapeDrift`（那两个键里出现过**非布尔**值）—— 读出来的 `false` 是
    ///   「读不出」的回落值，把它画成"用户没点过心"就是说谎。
    public var signalsAreReadable: Bool { !signalConflict && !signalShapeDrift }
}
