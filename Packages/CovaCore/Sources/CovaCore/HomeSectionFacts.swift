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

// MARK: - 01 §5 你的创作（生成候选小卡）
//
// §5 的三格：封面（**这里恒为像素占位**，见下）、标题（subhead）、状态徽标
// （生成中 `warning` / 完成 `success` / 失败 `error`）。
public enum HomeCreationGrid {
    /// 双列（§5 第一行）。列数与卡宽的算法是同一件事：两列 + `md` 列距 + 左右 `pageGutter`
    /// ⇒ 卡宽自然等于 §5 写的 (屏宽 − 2×gutter − md)/2，视图侧不再自己算一遍除法。
    public static let columnCount = 2
    /// §5 是首页的一格，不是 08 的整屏：线上 `GET /api/find-my-song/sessions` 服务端自己
    /// 封顶 50 条（`listOwnedSessions` 的 `.limit(50)`），首页只取最近 6 条（= 3 行双列）。
    /// 这个 6 是 **UI 取舍**（spec 没给这一区的条数），钉在这里可测。
    public static let cardLimit = 6

    /// 徽标的三个档（§5 逐字只有这三档）。
    public enum Badge: String, Equatable, Sendable {
        case generating
        case done
        case failed
    }

    /// 「生成中」这个词**复用** 08 那一批发在 `StudioSessionProgressRing.runningLabel` 的常量，
    /// 不在这里再打一遍字：同一句话在两屏长得不一样，是文案漂移的开始。
    public static let generatingLabel = StudioSessionProgressRing.runningLabel
    public static let doneLabel = "完成"
    public static let failedLabel = "失败"

    public static func label(of badge: Badge) -> String {
        switch badge {
        case .generating: return generatingLabel
        case .done: return doneLabel
        case .failed: return failedLabel
        }
    }

    /// 状态取值。**只认后端自己的那套任务态词表**（`GenerationJobStatus`，
    /// 注释逐字写着「对齐后端 generationJobStatus」）—— 不去猜一份新的会话态词表。
    ///
    /// 三条降级都是"不说没根据的话"：
    /// · `nil` / 空 / 认不出的值 ⇒ **不出徽标**（§5 的三档装不下一个未知态，硬贴一个色就是把
    ///   未知画成已知；也不把英文态名印上屏 —— 本仓早有「英文态名不得外溢」的判据）；
    /// · `cancelled` ⇒ 也不出徽标：它既不是「生成中」也不是「失败」，§5 没有第三态可给它；
    /// · 线上这一格今天**恒不出现** —— 见 `statusFieldInListPayload`。
    public static func badge(forStatus raw: String?) -> Badge? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = GenerationJobStatus(rawValue: trimmed) else { return nil }
        switch status {
        case .queued, .submitted, .processing: return .generating
        case .succeeded: return .done
        case .failed: return .failed
        case .cancelled: return nil
        }
    }

    /// **实测事实（2026-09-25 对着后端的部署面读源码核对）**：
    /// `GET /api/find-my-song/sessions` 的行来自 `listOwnedSessions`，它 select 出来的键是
    /// `id / title / titleLocked / proposedTitle / pinned / archived / lastMessage /
    /// createdAt / updatedAt / projectId / workflowMode` + `generatedTrackCount / firstCoverUrl`，
    /// **没有 `status`**（`find_my_song_sessions` 表里也没有 status 列）⇒
    /// `StudioSessionDto.status` 在真实数据上永远是 `nil`。
    ///
    /// 于是 §5 的状态徽标今天**不可能**出现：映射、颜色、无障碍标签都照 spec 施工好了，
    /// 字段一上线就点亮，不需要再改这里。缺口登记需求点在本批报告里
    /// （`docs/NEEDS.md` 的 `SESSION-LIST-FIELDS` 候选，同一处已经为 `firstCoverUrl` 立过案）。
    public static var statusFieldInListPayload: Bool { false }
}

// MARK: - 像素占位的取值（01 §5 / 02 §2 / components §5 共用）
//
// 数字放在 CovaCore 的唯一理由：**CovaUI 没有测试目标**（`Packages/CovaUI/Package.swift`
// 里只有 `.target`，没有 `.testTarget`），写在视图里的档永远不会红。
public enum PixelCoverFacts {
    /// 网格边长格数。spec 只写「像素网格」，没给档（tokens 与 Token 缺口表里都没有这一项）
    /// ⇒ 4×4：16 格在 140pt 见方的槽里每格 ≈ 35pt，"像素"读得出来又不至于变成噪点。
    public static let cellsPerSide = 4
    /// 呼吸周期：与 `CovaStates.swift` 的 `CovaSkeleton`（骨架屏「整块呼吸」）同一档 0.9s。
    /// §S1「不做的事」明令不做高光扫过 ⇒ 本 App 所有"占位在呼吸"共用一个节奏，
    /// 而不是每屏各挑一个数。
    public static let breatheDuration = 0.9
    /// 棋盘互换的亮/暗两档，与 Reduce Motion 那一档的静态值。
    public static let cellAlphaHigh = 0.28
    public static let cellAlphaLow = 0.12
    public static let cellAlphaStatic = 0.2

    /// 棋盘互换：亮的那批与暗的那批每半个周期**对调**，读起来是整格在呼吸；
    /// 如果只让同一批格子变亮，那是一道方向性的光 —— 也就是 §S1 禁掉的那种扫过。
    public static func cellAlpha(row: Int, column: Int, lit: Bool, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return cellAlphaStatic }
        let darkCell = (row + column) % 2 == 0
        if darkCell { return lit ? cellAlphaHigh : cellAlphaLow }
        return lit ? cellAlphaLow : cellAlphaHigh
    }
}
