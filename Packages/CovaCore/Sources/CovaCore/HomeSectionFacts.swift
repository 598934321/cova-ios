import Foundation

// MARK: - 01 §3 今日推荐歌单大卡
//
// design/screens/01-home.md §3（+ `design/components.md` §2「PlaylistCard · 大卡」）的取值面。
// 视图只负责摆，这一层回答三件会骗人的事：**取哪一张卡**、**那句话说成什么样**、
// **遮罩要多深**。§数据源那句「`GET /api/playlists` 第一条精选」是**唯一**的选卡依据 ——
// 本仓没有"精选位"字段（2026-09-25 只读核对线上 593 行：条目键集里既无 `featured`
// 也无 `isFeatured`/`pinned`，歌单表压根不给），所以"第一条"就是服务端顺序的第一条
// （`/api/playlists` 按 `createdAt desc`），客户端**不**重排、**不**另挑一张。
public enum HomeFeaturedCard {
    /// §3 卡高 200pt（`components.md` §2 同值）。
    public static let heroHeight: Double = 200
    /// §3「右上：玻璃圆形播放钮 44pt」——44 同时是 TG-03 的最小触控档。
    public static let playButtonSide: Double = 44
    /// §3「底部 45% 深色渐变遮罩」——**45% 是那条带子的高度占比**，不是不透明度。
    public static let scrimHeightRatio: Double = 0.45
    /// 遮罩深色端的不透明度。
    ///
    /// 遮罩强度档是**登记在案的缺口 TG-12**（`01` 未列、`06` §51 / `16` §86 都点名
    /// "强度需 light/dark 双值"，而 `design/tokens.json` 至今没有这一档）⇒ 这里取一个
    /// 单值并把"它是降级"写明白，而不是假称已有 token：§3 要的是「白字压在封面上
    /// 对比度达标」，0.72 那一端在深浅两套主题下都由这条深色带自身保证。
    public static let scrimMaxAlpha: Double = 0.72

    /// §数据源：第一条（没有 ⇒ `nil`，整块不渲染而不是摆一张空卡）。
    ///
    /// 只判 `nil`，不判"标题为空的行"：标题为空是脏数据，那一行仍然占着"第一条"这个位置；
    /// 把它悄悄跳过等于把顺序改成客户端挑的了（同上那条不重排的口径）。
    public static func hero(of playlists: [PlaylistDto]) -> PlaylistDto? {
        playlists.first
    }

    /// §3 元信息行「曲数 · 总时长」。**两件各说各的**：拿不到那一件就整段不出现，
    /// 不补 `0 首`、也不补 `约 0 分`（那都是把"后端没给"印成"后端给的是零"）。
    /// 读法与 06 的 `meta()` 同一口径（同一个 `totalDuration` 字段不该在两屏长成两种话）。
    public static func metaLine(trackCount: Int?, totalDuration: Double?) -> String? {
        var parts: [String] = []
        if let trackCount { parts.append("\(trackCount) 首") }
        if let text = durationText(totalDuration) { parts.append(text) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// 秒 → 「约 N 分」/「约 N 小时 M 分」。未知（nil / 非有限 / ≤0）⇒ `nil`。
    /// 整张歌单短于 1 分钟那一档同样按「没有可读时长」处理，而不是说「约 0 分」：
    /// `totalDuration` 为 0 就是后端给的"还没有曲目"形态，印成 0 分是把空说成一个读数。
    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let minutes = Int(seconds) / 60
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "约 \(minutes / 60) 小时 \(minutes % 60) 分" : "约 \(minutes) 分"
    }
}

// MARK: - 01 §4 场景精选横滑卡
//
// §数据来源写的是「playlists 按 scene 分组」。这一条**先核过线上再施工**
// （2026-09-25 只读 GET /api/playlists）：593 条里 **101 条带非空 `scene`**，
// 共 23 个不同取值（最多的「短视频/Vlog」17 条、「活动」13 条），
// `PlaylistDto.scene` 也早就在 DTO 里（`LibraryDTOs.swift`）⇒ 分组是有数据支撑的，
// 于是这里**只**用 `scene` 这一个真字段分组，`scene` 为空的 492 条一律不进这一区。
public enum HomeSceneRail {
    /// §4 卡片 140×140pt。
    public static let cardSide: Double = 140
    /// 一屏之内的上限：23 个场景全铺会把首页拖成长页，且"精选"本身就是要挑。
    /// 这两个数是 **UI 取舍**（spec 没给档），所以钉在这里、可测、不藏在视图体里。
    public static let groupLimit = 4
    public static let cardsPerGroup = 4

    /// 一个场景分组：组名就是后端给的 `scene` 原文（不翻译、不合并、不造"全部场景"）。
    public struct Group: Equatable, Sendable {
        public let scene: String
        public let playlists: [PlaylistDto]

        public init(scene: String, playlists: [PlaylistDto]) {
            self.scene = scene
            self.playlists = playlists
        }
    }

    /// 分组裁决（三条都是"不猜"）：
    /// 1. 只收 `scene` **非空非空白**的行 —— 没有场景的歌单不进这一区，也不给它们补一个
    ///    「其他」桶：那等于客户端发明一个后端没有的场景。
    /// 2. 组的先后按**该场景有多少条歌单**（多的在前），同数按服务端顺序里首次出现的位置 ——
    ///    23 个组装不下 ⇒ 总要挑，挑的依据用服务端自己给的事实，不用"我觉得哪个场景火"。
    /// 3. 组内保持服务端给的原顺序（`createdAt desc`），客户端不重排。
    public static func groups(
        of playlists: [PlaylistDto],
        groupLimit: Int = HomeSceneRail.groupLimit,
        cardsPerGroup: Int = HomeSceneRail.cardsPerGroup
    ) -> [Group] {
        guard groupLimit > 0, cardsPerGroup > 0 else { return [] }
        var order: [String] = []            // 首次出现顺序（同数时的 tie-break）
        var bucket: [String: [PlaylistDto]] = [:]
        for playlist in playlists {
            guard let scene = normalized(playlist.scene) else { continue }
            if bucket[scene] == nil { order.append(scene) }
            bucket[scene, default: []].append(playlist)
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return order
            .sorted { lhs, rhs in
                let lhCount = bucket[lhs]?.count ?? 0
                let rhCount = bucket[rhs]?.count ?? 0
                if lhCount != rhCount { return lhCount > rhCount }
                return (rank[lhs] ?? .max) < (rank[rhs] ?? .max)
            }
            .prefix(groupLimit)
            .map { scene in
                Group(scene: scene, playlists: Array((bucket[scene] ?? []).prefix(cardsPerGroup)))
            }
    }

    /// 去首尾空白后判空：`"  "` 这种脏值不进分组（否则界面上会出现一个看不见的场景名）。
    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
