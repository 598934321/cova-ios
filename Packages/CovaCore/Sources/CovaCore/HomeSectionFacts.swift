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
