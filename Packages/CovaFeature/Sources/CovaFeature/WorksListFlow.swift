import CovaCore
import CovaPlayer
import Foundation

// MARK: - 20 · 作品列表的会话层（§5 P1-1 / 验收 A5·A6·A7）
//
// 为什么状态与行为住在 `AppSession` 而不是视图里，与 19 屏同一条理由：
// 这一屏有**三条会跨屏存活的账** —— ① 在途的分页读（用户切筛选时它还在飞），
// ② 行内写动作的乐观态（点了心，网络还没回，屏要先翻面，失败还要回落），
// ③ 「已在本机」（事实源是盘上文件，不是这一次渲染）。
// 把它们放进 `@State` 就等于每次退屏丢掉一次，而 ② 丢掉的那一格会**说谎**：
// 用户以为收藏上了，服务端那边根本没动。

/// 20 屏的全部状态（一个值类型 ⇒ 视图只读它，不散着读十几个属性）。
///
/// 三本账**分开**放，压成一册就会互相覆盖：
/// · **选择态**（`filter`/`sort`/`search`/`anchoredJobID`）：用户此刻要看什么；
/// · **读到的账**（`rows`/`total`/`nextCursor`/`pagesLoaded`）：服务端给了什么；
/// · **本地回显账**（`signalOverrides`/`shareStates`/`materializedNoteRowIDs`/`lyrics`）：
///   刚刚这一屏做过什么 —— 它**不改**服务端给的行，只盖在上面，失败即撤。
public struct WorksListState: Equatable, Sendable {
    /// 整屏阶段（§4 状态变体）。
    public enum Phase: Equatable, Sendable {
        case idle           // 还没发过（进屏前 / 游客：本屏不可达）
        case loading        // 首载在途（B 一条骨架 + E 六行骨架）
        case loaded
        case empty          // 服务端**确实**给了 0 行（这不是失败，是事实）
        case failed(message: String)   // 首载没取到且手里没有内容可留
    }

    /// 一次读的两条腿。
    public enum Read: Equatable, Sendable {
        /// 整表替换：首载 / 切筛选 / 改搜索 / 换排序 / 下拉刷新（cursor 一律归零）。
        case replace
        /// 追加下一页：只回传上一次拿到的 `nextCursor`。
        case append
    }

    /// 一行喜欢/不喜欢的**本地回显**（服务端互斥 ⇒ 只可能是其中一格，不可能同时）。
    ///
    /// 为什么不是 `(favorited: Bool, disliked: Bool)` 两个布尔：那样就能表达出
    /// 「本机把两个都点亮」这个服务端**不存在**的状态，而屏上会照着画。
    /// 单值枚举让"点了心又点了踩"在类型上就是一次换格（后者覆盖前者），
    /// 与 §4.7 的互斥语义同形。
    public enum RowSignal: Equatable, Sendable {
        case favorite
        case dislike
        /// 权威回显说「这一行两个标记都没有」（`{favorite:false}` 落成之后那一格）。
        case cleared
    }

    /// 歌词 sheet 的内容（§7 timing 那一条：`lrc != null` 走静态行文，`null` 回落纯文本）。
    public enum Lyrics: Equatable, Sendable {
        case loading
        /// LRC 原文（**逐行照抄，不做时间轴高亮、不跟着播放进度滚动** —— D15 + §7 的裁决）。
        case aligned(text: String)
        /// 纯文本歌词（`lyrics` 字段那一条腿）。
        case plain(text: String)
        /// 两个来源都没有词（`message` = 「这首还没有歌词」/「还没取到歌词」）。
        case unavailable(message: String)
    }

    // MARK: 选择态

    public internal(set) var filter: WorksListFilter = .all
    public internal(set) var sort: WorksListSort = .newest
    /// **已提交**（发出去）的那一份搜索串。输入框里的草稿留在视图本地 ——
    /// 两处各存一份"用户正在打的字"就会有两张互相打架的账（19 的 prompt 同判据）。
    public internal(set) var search: String = ""
    /// §3.A 任务定位形态（`?job=`）：非 nil ⇒ 数据源换成 `?id=<jobId>`，
    /// 筛选条与搜索**整块不渲染**、无分页。默认 nil = 全量分页形态。
    public internal(set) var anchoredJobID: String?

    // MARK: 读到的账

    public internal(set) var rows: [WorksListRowDto] = []
    public internal(set) var total: Int?
    public internal(set) var unreadableItemCount = 0
    /// 下一页游标原文（`nil` = 到底了）。**永不本地自算**（§7 分页四条）。
    public internal(set) var nextCursor: WorksListCursor?
    /// 上一次**实际发出去**的那个游标 —— 只用来抓"服务端把同一个游标又回给我"这一格。
    public internal(set) var lastSentCursor: WorksListCursor?
    public internal(set) var pagesLoaded = 0
    public internal(set) var phase: Phase = .idle
    /// 在途的那一次读（`nil` = 没有在飞的）。追加下一页只在没有其它读时才允许开始。
    public internal(set) var activeRead: Read?
    /// 在途读的**代号**：每次开始读都 +1，落账时只认自己那一代（同 `studioCreateSubmitID`）。
    public internal(set) var readGeneration = 0
    /// 手里有内容时的整表重取（下拉刷新）—— 不盖骨架，只把旧内容标成"可能不是最新"。
    public internal(set) var isRefreshing = false
    /// 分页那一腿失败（§4：Toast「这一页没取到」+ 行内「重试」文字钮）。
    public internal(set) var appendFailed = false
    /// 整表重取失败但**内容留着**时的那一句（17-S4 细条位）。
    public internal(set) var readMessage: String?

    // MARK: 本地回显账

    /// 行 id → 刚刚这一次写出来的态（乐观 + 权威回显；失败即撤，整表重取即清）。
    public internal(set) var signalOverrides: [String: RowSignal] = [:]
    /// 在途的写（键 = 行 id 或组锚点）。§8「后到者被吞」。
    public internal(set) var pendingWrites: Set<String> = []
    /// 已物化成笔记的行（端点幂等 ⇒ 这一格只用于把菜单项换成「已做成笔记」）。
    public internal(set) var materializedNoteRowIDs: Set<String> = []
    /// 组锚点 → 分享态（**job 级**：组内所有行同时呈现同一状态，§7 ③）。
    public internal(set) var shareStates: [String: WorkShareState] = [:]
    /// 组锚点 → 服务端给的公开分享路径（可显示可复制；硬边界 3 禁的是 `audioUrl`/`playbackUrl` 回显）。
    public internal(set) var sharePaths: [String: String] = [:]
    /// 行 id → 歌词（sheet 打开时才取；取一次留一次，关 sheet 不重取）。
    public internal(set) var lyrics: [String: Lyrics] = [:]

    public init() {}

    // MARK: - 派生事实（视图只读这些，不自己拼判据）

    /// 任务定位形态（无筛选、无搜索、无分页）。
    public var isJobAnchored: Bool { anchoredJobID != nil }

    /// 正在读（首载 / 刷新 / 分页任一在途）。
    public var isReading: Bool { activeRead != nil }

    /// 屏上有没有内容可看（决定失败时是整屏错误还是细条）。
    public var hasContent: Bool { !rows.isEmpty }

    /// 筛选/搜索有没有生效（空态那一屏的措辞判据：带筛选 ⇒ 「这个筛选下没有作品」）。
    public var hasActiveRefinement: Bool { filter != .all || !search.isEmpty }

    /// 还有多少行没到屏上（§7 那句"照原值说实话"的唯一算式；nil = 不说）。
    public var missingRowCount: Int? {
        WorksListPaging.shortfall(rows: rows.count, unreadable: unreadableItemCount, total: total)
    }

    /// 到底了（服务端没给下一页的入口）。
    public var reachedEnd: Bool { nextCursor == nil }

    /// 还能不能再自动取一页（§7 四条纪律 + §8 的 10 页上限，判据都在 CovaCore 那一处）。
    public var canLoadMorePages: Bool {
        guard !isJobAnchored else { return false }   // 该 job 的行恒 ≤2，形态下无分页
        return WorksListPaging.canAdvanceToNextPage(
            nextCursor: nextCursor?.rawValue,
            lastSentCursor: lastSentCursor?.rawValue,
            pagesLoaded: pagesLoaded,
            isReading: isReading
        )
    }

    /// 服务端给了 `total` 而屏上没显示全 ⇒ 尾部必须说实话，不许写「已显示全部」。
    public var mustDeclareIncompleteness: Bool { missingRowCount != nil && reachedEnd }

    /// 分组（连续同锚点切断；跨页切断处会重新出现同一组头，§3.D）。
    public var groups: [WorksJobGroup] { WorksListGrouping.groups(in: rows) }

    /// 行 id → 行（动作回调用它拿"发请求用的那一个 id"，绝不从下标反推：
    /// 下标在整表重取的瞬间会指到别的行）。
    public func row(id: String) -> WorksListRowDto? { rows.first { $0.id == id } }

    /// 这一行的 ♡ 亮不亮（本地回显优先；服务端两个标记同时为真时**不亮**，§3.E）。
    public func favoriteIsOn(_ row: WorksListRowDto) -> Bool {
        switch signalOverrides[row.id] {
        case .favorite: return true
        case .dislike, .cleared: return false
        case nil: return row.favorited && row.signalsAreReadable
        }
    }

    /// 这一行的「不喜欢」选中不选中（同上；`disliked == true` 时 ♡ 必然不亮 —— 服务端互斥）。
    public func dislikeIsOn(_ row: WorksListRowDto) -> Bool {
        switch signalOverrides[row.id] {
        case .dislike: return true
        case .favorite, .cleared: return false
        case nil: return row.disliked && row.signalsAreReadable
        }
    }

    /// 这一行的两个标记**画不准**（服务端自己给了冲突 / 非布尔形状）⇒ 两个都不画，另说一句。
    public func signalsAreUncertain(_ row: WorksListRowDto) -> Bool {
        signalOverrides[row.id] == nil && !row.signalsAreReadable
    }

    /// 点一下 ♡ 要发出去的**目标态**（`WorkActionToggle.requesting(state:)` 的入参）。
    public func favoriteIntent(_ row: WorksListRowDto) -> Bool { !favoriteIsOn(row) }

    /// 点一下「不喜欢」要发出去的目标态。
    public func dislikeIntent(_ row: WorksListRowDto) -> Bool { !dislikeIsOn(row) }

    /// 这一行 / 这一组有没有写在途（视图用它给按钮加"正在保存"的语义，不假装禁用）。
    public func hasWriteInFlight(key: String) -> Bool { pendingWrites.contains(key) }

    /// 这一行能不能出现行内动作（▶ / ↓ / ♡ / ⋯）。
    ///
    /// §3.E 只把**占位行**排除在外：`{jobId}:pending-N` 是真实的一行（用户在等它），
    /// 只是还没有内容 ⇒ 四枚钮一枚都不渲染（不骨架、不闪禁用语义）。
    /// 裸 jobId 行**仍然给**动作：§4.7 明写七个端点都接受它，行内动作不挑形状。
    public func actionsAllowed(on row: WorksListRowDto) -> Bool { !row.isPendingPlaceholder }

    /// 组头 ⋯ 的分享徽标：只在**已知为 on** 时出现（`unknown` 保持上一次已知态，待答 12）。
    public func shareBadge(for group: WorksJobGroup) -> Bool { shareStates[group.anchor] == .on }

    // MARK: - 变更（只有这些方法能改选择态与账）

    /// §8 极值：`q` 本地钳到 200 字（与服务端 `title` 同一条口径；待答 9 说长度未文档化，
    /// 于是钳位只用于"不发一个明知不合理的长串"，不声称服务端也这么算）。
    public static func normalized(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WorkRenameRequestDto.titleMaximumLength))
    }

    /// 开始一次整表替换的读：游标归零、代际推进、旧响应全部作废（§7 分页第④条）。
    ///
    /// 为什么"改选择"必须先走这里而不是直接改字段：只要 `filter` 变了而 cursor 留着，
    /// 拿到的就是**另一个筛选条件下的第 N 页**（游标是 offset，不携带筛选身份）——
    /// 屏上写着「喜欢」而列表给的是别的行，正是 §4.7 那三条坑里最难查的一种。
    @discardableResult
    public mutating func beginReplacementRead(
        filter: WorksListFilter? = nil, sort: WorksListSort? = nil, search: String? = nil
    ) -> Int {
        if let filter { self.filter = filter }
        if let sort { self.sort = sort }
        if let search { self.search = Self.normalized(search) }
        readGeneration += 1
        nextCursor = nil
        lastSentCursor = nil
        pagesLoaded = 0
        appendFailed = false
        readMessage = nil
        isRefreshing = !rows.isEmpty
        activeRead = .replace
        if rows.isEmpty { phase = .loading }
        pruneLocalLedger()
        return readGeneration
    }

    /// 切到 / 切出 §3.A 的任务定位形态（**必须在 `beginReplacementRead` 之前**调，
    /// 因为那一格决定发出去的是 `?id=` 还是分页串）。
    public mutating func setJobAnchor(_ jobID: String?) { anchoredJobID = jobID }

    /// 开始一次追加下一页的读（代际同样推进：任何更早的响应都不该再落账）。
    /// 判据不过 ⇒ 返回当代代号且**不**标记在途（调用方用 `activeRead == .append` 认这个拒绝）。
    @discardableResult
    public mutating func beginAppendRead() -> Int {
        guard canLoadMorePages else { return readGeneration }
        readGeneration += 1
        lastSentCursor = nextCursor
        appendFailed = false
        activeRead = .append
        return readGeneration
    }

    /// 落账。**代际不匹配的响应整包丢弃**（返回 false），一个字都不写。
    ///
    /// 这一格是本屏并发正确性的唯一闸门：切筛选 / 改搜索 / 换排序都会推进代际，
    /// 而**先发的**那一发完全可能**后到**（传输层不保证顺序）。少了这道闸，
    /// 用户点「制作中」看到的会是迟到的「全部」那一页 —— 屏上没有任何东西会说谎，
    /// 除了事实本身。
    @discardableResult
    public mutating func apply(
        _ page: WorksPageDto, for read: Read, generation: Int
    ) -> Bool {
        guard generation == readGeneration, activeRead == read else { return false }
        let merged = WorksListPaging.merge(
            page: page,
            onto: read == .replace ? [] : rows,
            unreadableSoFar: unreadableItemCount,
            totalSoFar: total,
            mode: read == .replace ? .replace : .append
        )
        rows = merged.rows
        total = merged.total
        unreadableItemCount = merged.unreadableItemCount
        nextCursor = WorksListCursor.next(merged.nextCursor)
        pagesLoaded += 1
        activeRead = nil
        isRefreshing = false
        appendFailed = false
        if read == .replace {
            phase = rows.isEmpty ? .empty : .loaded
            readMessage = nil
            // 整表重取之后**服务端那一份才是事实**：本页覆盖到的行，本机那格回显一律撤掉
            // （§7「动作成功后就地回显」说的是一次写的当场，不是"从此不认服务端"）。
            // 唯一例外是仍在这张表上、但这一页没覆盖到的行（它跟着整表消失了，账由
            // `pruneLocalLedger` 撤），以及**仍在途**的那一格 —— 它的响应还没落，
            // 现在撤就会让按钮在回执回来之前闪回旧态（§4 的回落是失败才做的事）。
            let covered = Set(page.works.map(\.id))
            signalOverrides = signalOverrides.filter {
                pendingWrites.contains($0.key) || !covered.contains($0.key)
            }
            materializedNoteRowIDs = materializedNoteRowIDs.filter {
                pendingWrites.contains($0) || !covered.contains($0)
            }
        } else if !rows.isEmpty {
            phase = .loaded
        }
        pruneLocalLedger()
        return true
    }

    /// 一次读失败。**手里有内容就不改阶段**（§4「有缓存 → 保留内容 + 细条」）。
    @discardableResult
    public mutating func fail(message: String, for read: Read, generation: Int) -> Bool {
        guard generation == readGeneration, activeRead == read else { return false }
        activeRead = nil
        isRefreshing = false
        switch read {
        case .replace:
            if rows.isEmpty {
                phase = .failed(message: message)
            } else {
                readMessage = message
            }
        case .append:
            appendFailed = true
        }
        return true
    }

    /// 退屏：撤掉在途标记，**留着屏上的账**（回来还在，同 19 的取消口径）。
    public mutating func noteLeftRead() {
        activeRead = nil
        isRefreshing = false
    }

    /// 游客 / 登录态掉了：本屏不可达（§1 登录门槛）⇒ 整本账清干净，不给下一个人看上一个人的行。
    public mutating func noteUnauthenticated() { self = WorksListState() }

    // MARK: 写的在途与回显

    /// 开始一次写：这一行 / 这一组已有写在途 ⇒ 返回 false（§8「后到者被吞」）。
    ///
    /// 为什么在会话层吞而不是在视图里 disable：♡ 与 ⋯「不喜欢」是两条不同的腿，
    /// 判据必须只有一处；而 disable 只挡点击，挡不住"两条腿各自以为自己拿到了许可"。
    @discardableResult
    public mutating func beginWrite(key: String) -> Bool {
        guard !pendingWrites.contains(key) else { return false }
        pendingWrites.insert(key)
        return true
    }

    public mutating func endWrite(key: String) { pendingWrites.remove(key) }

    /// 乐观更新：先把这一格按下去要变成的态画出来。
    public mutating func optimisticallySet(_ signal: RowSignal, for rowID: String) {
        signalOverrides[rowID] = signal
    }

    /// 权威回显落地（`agrees(with:)` 通过之后才调；值来自服务端，不是本机猜的）。
    public mutating func confirm(_ signal: RowSignal, for rowID: String) {
        signalOverrides[rowID] = signal
    }

    /// **回落**：撤掉本机那一格，让屏回到服务端给的那一行（§4「行内或组头回落原态」）。
    public mutating func rollback(rowID: String) { signalOverrides.removeValue(forKey: rowID) }

    /// 他端已删（写动作拿到 404）：静默移除这一行（§8「行内回落 + 静默移除」）。
    public mutating func dropRow(id: String) {
        rows.removeAll { $0.id == id }
        removeLocalLedger(forRowID: id)
        phase = rows.isEmpty ? .empty : .loaded
    }

    /// 删除成功后：该 job 的全部行本地移除（含跨页已取到的，§7 ③），并撤掉它的组级账。
    public mutating func dropJob(anchor: String) {
        rows = WorksListPaging.removing(rows: rows, anchor: anchor)
        phase = rows.isEmpty ? .empty : .loaded
        pruneLocalLedger()
    }

    /// 一行彻底离开屏上时，它挂在本地账里的那几格一起走（不留"看不见的回显"）。
    private mutating func removeLocalLedger(forRowID id: String) {
        signalOverrides.removeValue(forKey: id)
        materializedNoteRowIDs.remove(id)
        lyrics.removeValue(forKey: id)
    }

    /// 改名回读后回填（就地替换该 job 的行 ⇒ 两行同时改，§7 ④）。
    public mutating func applyRefreshedJobRows(_ refreshed: [WorksListRowDto], anchor: String) {
        rows = WorksListPaging.applying(refreshed: refreshed, to: rows, anchor: anchor)
    }

    /// 服务端只给回**单数** `work` 时的最低回填：把那一行自己换掉（别的行原样留着）。
    public mutating func applyPatchedRow(_ row: WorksListRowDto) {
        rows = rows.map { $0.id == row.id ? row : $0 }
    }

    /// 歌词这一格的三路裁决（纯函数，`loadWorksLyrics` 与单测共用同一个判据）：
    /// · `lrc` 有值 ⇒ 静态行文（**不做逐行高亮**，D15）；
    /// · `lrc == null` ⇒ 回落行上的 `lyrics`（契约把这条设计成**正常路径**，不是降级告警）；
    /// · 两个都没有 ⇒ 一句实话（取失败时带失败原因，从没词时是「这首还没有歌词」）。
    static func lyricsContent(
        timing: WorkTimingResponseDto?, row: WorksListRowDto, failureMessage: String? = nil
    ) -> Lyrics {
        if let timing, timing.hasAlignedLyrics, let lrc = WorksListQuery.textIfPresent(timing.lrc) {
            return .aligned(text: lrc)
        }
        if let plain = WorksListQuery.textIfPresent(row.lyrics) { return .plain(text: plain) }
        return .unavailable(
            message: failureMessage ?? WorksListCopy.noLyrics
        )
    }

    /// 整表重取后清掉**已经不在表上**的本地账（在途那一格留着 —— 它的响应还要落回来）。
    private mutating func pruneLocalLedger() {
        let alive = Set(rows.map(\.id))
        let anchors = Set(rows.map(WorksListPaging.anchor(of:)))
        signalOverrides = signalOverrides.filter {
            alive.contains($0.key) || pendingWrites.contains($0.key)
        }
        materializedNoteRowIDs = materializedNoteRowIDs.filter {
            alive.contains($0) || pendingWrites.contains($0)
        }
        lyrics = lyrics.filter { alive.contains($0.key) }
        shareStates = shareStates.filter { anchors.contains($0.key) }
        sharePaths = sharePaths.filter { anchors.contains($0.key) }
    }

    // MARK: 请求构造

    /// 分页形态下这一次要发的请求（**cursor 由这一处决定**，视图不参与拼）。
    ///
    /// `filter`/`sort`/`limit` 恒发、`q` 空则不发键，都是 `WorksListQuery` 的既有口径
    /// （同一选择 = 同一地址）；追加腿只回传服务端给的 `nextCursor`，永不本地自算。
    public func query(for read: Read) -> WorksListQuery {
        let base = WorksListQuery(
            filter: filter, search: search, sort: sort, cursor: nil,
            limit: WorksListQuery.defaultLimit
        )
        switch read {
        case .replace: return base
        case .append: return base.advanced(toNextCursor: nextCursor?.rawValue) ?? base
        }
    }
}

// MARK: - 读：一条腿（首载 / 刷新 / 分页 / 任务定位形态）

extension AppSession {

    /// 进屏取数（幂等：已经有内容且不是 `force` 就不重发 —— §7「进入本屏不自动重取 ≤5min」，
    /// 本仓没有时限配置档 ⇒ 退化成「同一次会话内不重发，除显式刷新」，与 `loadMe` 同一取舍）。
    ///
    /// `jobID` 非 nil = §3.A 任务定位形态（数据源 `?id=<jobId>`、不发 `filter/q/sort/cursor`、
    /// 标题换「本次生成的作品」）。⚠️ **本构建里没有任何入口带 job 进来**：`Route.worksList`
    /// 不带载荷，而 19 结果区的「全部作品」钮要由 19 的持有者回写（20 §1 已登记交叉引用）、
    /// 22 的「任务」钮属 §5 P2-3 那一批。这一格留在会话层是规格要求，不是提前施工：
    /// 入口一到位就能用，不必再改这一屏。
    public func loadWorksList(anchoredTo jobID: String? = nil, force: Bool = false) async {
        guard case .signedIn = authPhase else {
            worksList.noteUnauthenticated()
            loginPresented = true   // 17-S6：游客到这一屏不是"空列表"，是登录引导
            return
        }
        if !force, worksList.phase != .idle, worksList.hasContent, !worksList.isReading,
           worksList.anchoredJobID == jobID { return }
        worksList.setJobAnchor(jobID)
        await startWorksReplacementRead()
    }

    /// 下拉刷新：从第一页重取并**整表替换**（§7「刷新 = 整表替换」，不保留上一页尾巴）。
    public func refreshWorksList() async {
        guard case .signedIn = authPhase else { return }
        await startWorksReplacementRead()
    }

    /// 追加下一页。**四条判据都在 `canLoadMorePages` 里**
    /// （在途 / 到底 / 游标没前进 / 连续翻页上限），这里不重复判。
    public func loadMoreWorks() async {
        guard case .signedIn = authPhase, worksList.canLoadMorePages else { return }
        worksListTask?.cancel()
        let generation = worksList.beginAppendRead()
        guard worksList.activeRead == .append else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performWorksRead(.append, generation: generation)
        }
        worksListTask = task
        await task.value
    }

    /// 切筛选（**单选**，§3.C：服务端 `filter` 是单值枚举 ⇒ 不提供多选、不发明 `filter=a,b`）。
    public func selectWorksFilter(_ filter: WorksListFilter) async {
        guard case .signedIn = authPhase, !worksList.isJobAnchored else { return }
        worksListTask?.cancel()
        let generation = worksList.beginReplacementRead(filter: filter)
        await runWorksReplacementRead(generation: generation)
    }

    /// 换排序（§3.A：服务端 `sort` 是二值枚举 ⇒ sheet 只有这两项）。
    public func selectWorksSort(_ sort: WorksListSort) async {
        guard case .signedIn = authPhase, !worksList.isJobAnchored else { return }
        worksListTask?.cancel()
        let generation = worksList.beginReplacementRead(sort: sort)
        await runWorksReplacementRead(generation: generation)
    }

    /// 搜索（输入即搜 + 300ms 防抖，03 §3 同规格）。
    ///
    /// 防抖只是**推迟发请求**，不推迟作废：代际在调用这一刻就推进了，
    /// 所以用户在 300ms 里连打五个字，前面几发的响应一个字都落不到屏上。
    public func searchWorksList(_ raw: String) async {
        guard case .signedIn = authPhase, !worksList.isJobAnchored else { return }
        worksListTask?.cancel()
        let generation = worksList.beginReplacementRead(search: raw)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performWorksRead(.replace, generation: generation)
        }
        worksListTask = task
        await task.value
    }

    /// 「清除筛选」（带筛选空态那一屏的唯一 CTA，§4 空态 2 —— 不给第二个 CTA）。
    public func clearWorksRefinements() async {
        guard case .signedIn = authPhase, !worksList.isJobAnchored else { return }
        worksListTask?.cancel()
        let generation = worksList.beginReplacementRead(filter: .all, search: "")
        await runWorksReplacementRead(generation: generation)
    }

    /// 退屏 / 登出：撤掉在途读并把代际推进（迟到的那发认不出这一代 ⇒ 不落账），
    /// 但**留着屏上的账**（回来还在，同 `cancelStudioCreate` 的口径）。
    public func cancelWorksListRead() {
        worksListTask?.cancel()
        worksListTask = nil
        worksList.readGeneration += 1
        worksList.noteLeftRead()
    }

    private func startWorksReplacementRead() async {
        worksListTask?.cancel()
        worksListTask = nil
        let generation = worksList.beginReplacementRead()
        await runWorksReplacementRead(generation: generation)
    }

    private func runWorksReplacementRead(generation: Int) async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performWorksRead(.replace, generation: generation)
        }
        worksListTask = task
        await task.value
    }

    private func performWorksRead(_ read: WorksListState.Read, generation: Int) async {
        do {
            let page: WorksPageDto
            if let jobID = worksList.anchoredJobID {
                page = try await worksPage(jobID: jobID)
            } else {
                // 请求**这一刻**才构造：拿的是当代的选择态（早一步取好的话，
                // 防抖窗口里的最后一次输入就没机会进这一发了）。
                page = try await worksService.page(worksList.query(for: read))
            }
            // 「已在本机」的事实源是盘上文件，不是内存猜测 ⇒ 每次读完对一次账（同 19）。
            await refreshSavedWorks()
            worksList.apply(page, for: read, generation: generation)
        } catch {
            let message = CatalogService.classify(error).userText
            worksList.fail(message: message, for: read, generation: generation)
            // 分页那一腿失败要说"这一页没取到"，而不是把整屏判成错误（手里还有内容）。
            if read == .append { showToast(WorksListCopy.pageFailed, isError: true) }
        }
    }

    /// 任务定位形态 / 改名回填共用的那一条 `?id=` 腿（契约明写：纯 jobId 返回该 job 全部行）。
    ///
    /// 为什么不改 `WorksListQuery` 去带 `id`（CovaCore 明写它**不建模** `id`），也不换用
    /// `StudioCreateService.works(id:)`：那一支回的是 `CreateWorkItemDto`（P0 的最小投影，
    /// 没有 `favorited/disliked/lyrics/source`），拿它覆盖屏上的行会把这些字段擦成"没有"。
    /// 同一个端点、两种投影，本屏只有 `WorksPageDto` 这一种能落地 ⇒ 出腿写在会话层，
    /// 路径复用 `WorksListQuery.path`（那一条常量的唯一来源）。
    private func worksPage(jobID: String) async throws -> WorksPageDto {
        try await client.get(
            WorksListQuery.path, queryItems: [URLQueryItem(name: "id", value: jobID)]
        )
    }

    // MARK: - 播放 / 直存（A5 / A6：与 19 完全同一条媒体出口）

    /// `WorksListRowDto` → `PlaybackItem`。
    ///
    /// 与 19 的 `workPlaybackItem(from:)` 同三条硬规矩，只因为行类型不同而各写一份
    /// （`CreateWorkItemDto` 与 `WorksListRowDto` 收敛成一条是 19 那一批的事，本轮不许改既有文件）：
    /// · **只吃 `audioUrl`**，`playbackUrl` 一次都不碰（它签在 D23 名单外的 uploads 桶，§7 #37）；
    /// · 原文带的 `intent=play` 会被服务端 302 到那个名单外桶 ⇒ 先经
    ///   `CovaEnvironment.workAudioDirectFetchURL` 换成同源的 `intent=download`（§7 #39 的更正）；
    /// · id **逐字**用服务端的行 id = 伪 trackId `{jobId}:{candidateId}` ⇒
    ///   播放层的集次上报把它原样发给 `POST /api/tracks/play`（A5 的判据就是这一格）；
    /// · `.bearerRequired` + `kind: .work` ⇒ D7 的顺序（下载 → 校验非空 → `file://`）
    ///   在类型层面绕不过去。
    public static func worksRowPlaybackItem(from row: WorksListRowDto) -> PlaybackItem? {
        guard row.isPlayable, let raw = row.audioUrl?.rawValue,
              let resolved = CovaEnvironment.resolveMediaURL(raw),
              let audio = try? AudioURL(https: CovaEnvironment.workAudioDirectFetchURL(resolved))
        else { return nil }
        let cover = CovaEnvironment.resolveMediaURL(row.coverUrl).flatMap { try? AudioURL(https: $0) }
        return try? PlaybackItem(
            id: row.id,
            title: row.displayTitle ?? WorksListCopy.untitled,
            artist: "Cova AI",
            duration: row.displayDuration,
            coverURL: cover,
            audioSource: .bearerRequired(audio),
            kind: .work
        )
    }

    /// 直存请求（A6）：**不 checkout、不扣费**，走 `WorkDownloadStore`（Documents + 清单）。
    /// 同源直取改写与播放腿同一处，两条腿不许各挑一个 intent。
    public static func worksRowDownloadRequest(
        from row: WorksListRowDto, session: PlaybackSessionContext?
    ) -> WorkDownloadRequest? {
        // owner 先成立才谈得上「存到谁的名下」：没有归属就不存（D8）。
        guard let session, session.owner != nil, row.isPlayable,
              let raw = row.audioUrl?.rawValue,
              let url = CovaEnvironment.resolveMediaURL(raw),
              let source = try? AudioURL(https: CovaEnvironment.workAudioDirectFetchURL(url))
        else { return nil }
        return WorkDownloadRequest(
            workId: row.id,
            title: row.displayTitle ?? WorksListCopy.untitled,
            artist: nil,
            duration: row.displayDuration,
            source: source,
            session: session
        )
    }

    /// 播这一行（行点击与 ▶ 同一动作，§3.E「行点击 = ▶」）。
    public func playWorksRow(id: String) async {
        guard let row = worksList.row(id: id) else { return }
        guard let item = Self.worksRowPlaybackItem(from: row) else {
            showToast(WorksListCopy.audioUnavailable, isError: true)
            return
        }
        await play(items: [item], at: 0)
    }

    /// 把这一行直存到本机（↓）。已存过的再点一次走「删除本机文件」那一格（视图侧二次确认）。
    public func saveWorksRow(id: String) async {
        guard let row = worksList.row(id: id),
              let session = await worksPlaybackSession(),
              let request = Self.worksRowDownloadRequest(from: row, session: session) else {
            showToast(WorksListCopy.downloadUnavailable, isError: true)
            return
        }
        switch await workDownloads.save(request) {
        case .success(let entry):
            savedWorkIDs.insert(entry.workId)
            showToast(WorksListCopy.savedHere)
        case .failure(let error):
            showToast(error.description, isError: true)
        }
    }

    /// 删除本机文件（不碰服务端：软删是组头那一条腿，这一条只清沙盒）。
    public func removeSavedWorksRow(id: String) async {
        guard let session = await worksPlaybackSession(), let owner = session.owner else { return }
        if await workDownloads.remove(workId: id, owner: owner) {
            savedWorkIDs.remove(id)
            showToast(WorksListCopy.removedLocalFile)
        } else {
            showToast(WorksListCopy.localFileNotRemoved, isError: true)
        }
    }

    /// 凭证快照（owner 分桶与 generation 作废都靠它）。读不出来 = nil ⇒ **不做**，不猜身份。
    ///
    /// 19 的同名辅助是 `private`（`StudioCreateFlow.swift:211`），跨文件够不到；
    /// 动它的可见性就是改别人正在编辑的文件 ⇒ 这里各写一份，两处的判据逐字一致。
    private func worksPlaybackSession() async -> PlaybackSessionContext? {
        guard let snapshot = try? await auth.currentSession() else { return nil }
        return PlaybackSessionContext(owner: snapshot.principal, generation: snapshot.generation)
    }

    // MARK: - ♡ / 不喜欢（§4.7 三条坑的第①条：缺键 ≠ false）

    /// 点 ♡：**显式布尔**，永不省略键（`WorkActionToggle.requesting(state:)`）。
    ///
    /// 为什么不用 `Bool?`：服务端读 `body.favorite` 并**缺省为 true** ⇒
    /// 「这一单没决定」与「要取消」在 `Bool?` 上长得一样，而任何一次忘了赋值都会点亮收藏。
    public func toggleWorksFavorite(id: String) async {
        await sendWorksSignal(id: id, leg: .favorite)
    }

    /// 点 ⋯ 里的「不喜欢」（同一本在途账、同一个乐观/回落形状，只差端点与键名）。
    public func toggleWorksDislike(id: String) async {
        await sendWorksSignal(id: id, leg: .dislike)
    }

    /// ♡ 与「不喜欢」共用的一条腿。两件事钉在这里：
    /// · **一行只允许一个在途写**（§8 并发通则：后到者被吞，不排队、不并发发两枪）；
    /// · **200 不等于办成**：`ok:true` 且回执与这一单要做的事**一致**才算落定，
    ///   否则撤乐观态 + 说一次话（`agrees(with:)` 是唯一能端到端证明"我发的那个 false
    ///   真的落成了 false"的判据 —— 缺键那条坑如果哪天被服务端改掉，红的第一现场就是这里）。
    private enum SignalLeg { case favorite, dislike }

    private func sendWorksSignal(id: String, leg: SignalLeg) async {
        guard let row = worksList.row(id: id), worksList.actionsAllowed(on: row) else { return }
        guard worksList.beginWrite(key: id) else { return }
        defer { worksList.endWrite(key: id) }
        let isFavoriteLeg = leg == .favorite
        let wanted = isFavoriteLeg ? worksList.favoriteIntent(row) : worksList.dislikeIntent(row)
        let toggle = WorkActionToggle.requesting(state: wanted)
        let echo: WorksListState.RowSignal = wanted ? (isFavoriteLeg ? .favorite : .dislike) : .cleared
        worksList.optimisticallySet(echo, for: id)
        do {
            if isFavoriteLeg {
                let response = try await worksService.setFavorite(workID: id, toggle)
                try Self.ensureAcknowledged(
                    response.isAcknowledged && response.agrees(with: toggle)
                )
            } else {
                let response = try await worksService.setDislike(workID: id, toggle)
                try Self.ensureAcknowledged(
                    response.isAcknowledged && response.agrees(with: toggle)
                )
            }
            worksList.confirm(echo, for: id)
        } catch let failure as WorksActionError {
            worksList.rollback(rowID: id)
            handleWorksWriteFailure(failure, rowID: id)
        } catch {
            worksList.rollback(rowID: id)
            showToast(WorksListCopy.notSaved, isError: true)
        }
    }

    /// 回执不认（`ok != true`，或回显的那个布尔与这一单要做的不是一回事）⇒ 按失败处理。
    private static func ensureAcknowledged(_ acknowledged: Bool) throws {
        guard acknowledged else { throw WorksActionError.unreadableResponse }
    }

    /// 「做成笔记」= **物化**（work→`music_note`，回 `noteId`），不是写备注（§7 的语义边界）。
    /// 成功后 Toast 只说事实「已做成笔记」，**不承诺**"去收藏/歌单里能看见它"（§7 那条 #11 未解锁）。
    public func materializeWorksNote(id: String) async {
        guard let row = worksList.row(id: id), worksList.actionsAllowed(on: row) else { return }
        guard worksList.beginWrite(key: id) else { return }
        defer { worksList.endWrite(key: id) }
        do {
            let response = try await worksService.materializeNote(workID: id)
            try Self.ensureAcknowledged(response.isAcknowledged)
            worksList.materializedNoteRowIDs.insert(id)
            showToast(WorksListCopy.noteDone)
        } catch let failure as WorksActionError {
            handleWorksWriteFailure(failure, rowID: id)
        } catch {
            showToast(WorksListCopy.notSaved, isError: true)
        }
    }

    // MARK: - 歌词（timing）

    /// 取这一行的歌词：`lrc != null` ⇒ 静态行文（**不做逐行高亮**，D15 / §7 的裁决）；
    /// `lrc == null` ⇒ 回落 `lyrics` 纯文本 —— 这一支是**正常路径**，不弹"歌词加载失败"。
    public func loadWorksLyrics(id: String) async {
        guard let row = worksList.row(id: id) else { return }
        worksList.lyrics[id] = .loading
        do {
            let response = try await worksService.timing(workID: id)
            worksList.lyrics[id] = WorksListState.lyricsContent(timing: response, row: row)
        } catch let failure as WorksActionError {
            // 任何失败都回落到纯文本（契约把 timing 设计成"取不到就 null"，客户端同一形状）。
            worksList.lyrics[id] = WorksListState.lyricsContent(
                timing: nil, row: row, failureMessage: failure.userMessage
            )
        } catch {
            worksList.lyrics[id] = WorksListState.lyricsContent(
                timing: nil, row: row, failureMessage: WorksListCopy.lyricsUnavailable
            )
        }
    }

    // MARK: - job 级三条（重命名 / 分享 / 删除）
    //
    // 三条都在**组头** ⋯ 上，行 ⋯ 里永不出现（§3.D：作用域靠"物理上放不到一行上"来表达）。
    // 请求侧一律用**该行自己的 id**（§7 ①：作用域由服务端从 id 里解出 jobId 决定，
    // 不是客户端"换个更合适的 id"能控制的）；本地账则按**组锚点**记，一次覆盖整组。

    /// 组头 ⋯ 打开时查一次分享态（**不在列表加载时按组 N+1 地打**）。
    ///
    /// 取不到态 ⇒ 保持上一次已知态（§7 待答 12 的现规格口径），不回落成"没开"：
    /// 那一格会画出「分享本次生成的作品」，而它可能已经开着。
    public func refreshWorksShareStatus(anchor: String, probeRowID: String) async {
        await runGroupAction(anchor: anchor, probeRowID: probeRowID) { rowID in
            let response = try await self.worksService.shareStatus(workID: rowID)
            if response.state != .unknown { self.worksList.shareStates[anchor] = response.state }
            // 状态那一条腿**没有** `ok`，路径也就是那一个键；空串按"没给"处理（不填默认值）。
            if let path = WorksListQuery.textIfPresent(response.sharePath) {
                self.worksList.sharePaths[anchor] = path
            }
        }
    }

    /// 开（或复用）这一组的公开分享链接。交给用户的是 `sharePath`，**不是** `audioUrl`（§8）。
    /// 成功后组内**所有行同时**呈现「已分享」（§7 ③：态由组头承载）。
    public func openWorksShare(anchor: String, probeRowID: String) async {
        await runGroupAction(anchor: anchor, probeRowID: probeRowID) { rowID in
            let response = try await self.worksService.openShare(workID: rowID)
            try Self.ensureAcknowledged(response.isAcknowledged)
            self.worksList.shareStates[anchor] = .on
            if let path = response.resolvedSharePath { self.worksList.sharePaths[anchor] = path }
        }
    }

    /// 关分享（**令牌保留、可重开** ⇒ 不许把它说成"永久撤销"，§7 那条共用回执的文档）。
    public func closeWorksShare(anchor: String, probeRowID: String) async {
        await runGroupAction(anchor: anchor, probeRowID: probeRowID) { rowID in
            let response = try await self.worksService.closeShare(workID: rowID)
            try Self.ensureAcknowledged(response.isAcknowledged)
            self.worksList.shareStates[anchor] = .off
        }
    }

    /// 重命名这一组（**job 级**：一次生成两行 ⇒ 两行同时改）。
    ///
    /// `PATCH` 响应是**单数** `work` ⇒ 只补一行就是替服务端少写一行。落账两条腿：
    /// ① 先把服务端给回的那一行就地换掉；② 按 `?id=<jobId>` 回读该 job 全部行覆盖本地
    /// （契约明写这一形态，不发明 `?ids=`）。回读失败时 ① 仍然成立 —— 服务端说了 ok。
    /// **不弹成功 Toast**：两行标题同时变了就是唯一可见且不说谎的回执，
    /// §8 的文案清单里也没有"改好了"那一句，不现编。
    public func renameWorksGroup(
        anchor: String, jobID: String?, probeRowID: String, title: String
    ) async {
        await runGroupAction(anchor: anchor, probeRowID: probeRowID) { rowID in
            let response = try await self.worksService.rename(workID: rowID, title: title)
            try Self.ensureAcknowledged(response.isAcknowledged)
            if let patched = response.work { self.worksList.applyPatchedRow(patched) }
            // 认不出 job 身份的那一组（id 三段以上 / 空段之类）没有可回读的锚点：
            // 就地换掉服务端给回的那一行已经是**全部**能确证的事，不拿原 id 去打 `?id=`。
            if let jobID, !jobID.isEmpty {
                await self.reconcileRenamedJob(anchor: anchor, jobID: jobID)
            }
        }
    }

    /// 改名后的权威回读。失败**不喊**：标题已经是服务端给回的那一个，只是这一组另一行的
    /// 别的字段可能还是旧的 —— 下一次整表重取自动对上（在屏上为这一格弹一次错误会夸大事态）。
    private func reconcileRenamedJob(anchor: String, jobID: String) async {
        guard let page = try? await worksPage(jobID: jobID) else { return }
        worksList.applyRefreshedJobRows(page.works, anchor: anchor)
    }

    /// 删除这一组（**job 级软删**，§7 ③：该 jobId 的全部行一起消失，含跨页已取到的）。
    /// 同样**不弹成功 Toast** —— 屏上少掉一整组就是回执。
    public func deleteWorksGroup(anchor: String, probeRowID: String) async {
        await runGroupAction(anchor: anchor, probeRowID: probeRowID) { rowID in
            let response = try await self.worksService.delete(workID: rowID)
            try Self.ensureAcknowledged(response.isAcknowledged)
            self.worksList.dropJob(anchor: anchor)
        }
    }

    /// 组级动作共用的在途账 + 失败处置（`key` = 组锚点 ⇒ 同组同时只允许一个写：
    /// 重命名与删除撞在一起只会让第二枪打到第一枪改过的东西上）。
    private func runGroupAction(
        anchor: String, probeRowID: String, _ body: @MainActor (String) async throws -> Void
    ) async {
        guard let row = worksList.row(id: probeRowID), worksList.actionsAllowed(on: row) else { return }
        guard worksList.beginWrite(key: anchor) else { return }
        defer { worksList.endWrite(key: anchor) }
        do {
            try await body(probeRowID)
        } catch let failure as WorksActionError {
            // 组级动作的 404 = 他端把这一整组删了 ⇒ 整组静默消失（§8 同一格口径）。
            if case .rejected(let rejection) = failure, case .workNotFound = rejection {
                worksList.dropJob(anchor: anchor)
            }
            showToast(failure.userMessage, isError: true)
        } catch {
            showToast(WorksListCopy.notSaved, isError: true)
        }
    }

    /// 写动作失败的统一处置：`userMessage` 上屏（屏上无英文码），404 顺手把这一行撤掉。
    private func handleWorksWriteFailure(_ failure: WorksActionError, rowID: String) {
        if case .rejected(let rejection) = failure, case .workNotFound = rejection {
            worksList.dropRow(id: rowID)
        }
        showToast(failure.userMessage, isError: true)
    }
}

// MARK: - 本屏文案（20 §8 清单，逐串按 `Scripts/d12-copy-check.sh` 的禁词表核过）
//
// 为什么单独一册而不是散在视图里：D12 的扫描面是**字符串字面量**，同一句话出现在
// 可见文本与 VoiceOver 标签两处就要各写一遍；收成一册才能保证念的与看的是同一个词。
enum WorksListCopy {
    static let title = "我的作品"
    static let anchoredTitle = "本次生成的作品"
    static let sort = "排序"
    static let sortNewest = "最新在前"
    static let sortOldest = "最早在前"
    static let searchPlaceholder = "搜索作品"
    static let play = "播放"
    static let save = "保存到本机"
    static let removeSaved = "删除本机文件"
    static let deleteLocalConfirm = "删除本机文件？"
    static let delete = "删除"
    static let cancel = "取消"
    static let retry = "重试"
    static let allShown = "已显示全部"
    static let loadingMore = "加载中…"
    static let pageFailed = "这一页没取到"
    static let listFailed = "作品列表没取到"
    static let stillGenerating = "这首还在做"
    static let noLyrics = "这首还没有歌词"
    static let lyricsUnavailable = "还没取到歌词"
    static let shareNotOpened = "分享没打开"
    static let notSaved = "没保存上，再试一次"
    static let shared = "已分享"
    static let noteDone = "已做成笔记"
    static let note = "做成笔记"
    static let lyrics = "歌词"
    static let dislike = "不喜欢"
    static let favorite = "喜欢"
    static let rename = "重命名"
    static let saveTitle = "保存"
    static let renameJob = "重命名本次生成的作品"
    static let shareJob = "分享本次生成的作品"
    static let deleteJob = "删除本次生成的作品"
    static let deleteJobConfirm = "删除本次生成的作品？"
    static let deleteJobConsequence = "删除后这次生成的作品都会从列表里消失。"
    static let emptyTitle = "还没有你的作品"
    static let emptyHint = "一句话就能做一首：说场景、说情绪、说人声"
    static let emptyCTA = "做一首歌"
    static let filteredEmpty = "这个筛选下没有作品"
    static let clearFilter = "清除筛选"
    static let nothingGenerating = "没有在做的了"
    static let untitled = "未命名作品"
    static let instrumental = "纯音乐"
    static let generationFailed = "这次没做成，可以再试一次"
    static let nameEmpty = "名称不能为空"
    static let nameTooLong = "名称太长了"
    static let audioUnavailable = "这首的音频地址不可用，暂时播不了"
    static let downloadUnavailable = "这首的音频地址不可用，存不了"
    static let savedHere = "已在本机"
    static let removedLocalFile = "已删除本机文件"
    static let localFileNotRemoved = "本机文件没删掉"
    static let moreActions = "更多操作"
    static let close = "关闭分享"
    static let openShare = "开启分享"

    /// §3.D 的复述位：job 级作用的**行数**必须在确认之前就说出来（不是贴一句警告，是念数字）。
    static func groupScope(_ count: Int) -> String {
        "这一组里有 \(count) 首，这三项操作对它们一起生效"
    }

    /// 组头那一行（`createdAt` 读不出来时**只写数量**，§7 字段可空规则：不显占位）。
    static func groupHeader(time: String?, count: Int) -> String {
        let quantity = "一次生成 \(count) 首"
        guard let time else { return quantity }
        return "\(time) · \(quantity)"
    }

    /// B 摘要行：照服务端原值显示、**不加「共」字**（§3.B —— `total` 的口径未文档化）。
    static func summary(_ total: Int) -> String { "\(total) 首" }

    /// 屏上没显示全那一句（不本地重算 `total`，也不装成"已显示全部"）。
    static func incomplete(_ missing: Int) -> String { "还有 \(missing) 首没取到" }

    /// 两个标记同时存在（只可能来自服务端账没对上）⇒ 两个都不画，如实说一句。
    /// ⚠️ §8 的清单里**没有**这一句（规格把它写成"§8 有措辞规则"，实际没有）⇒
    /// 本屏按 §7「不猜该显示哪一个」的裁决补一句能说的实话，不替服务端挑一个。
    static let signalsUncertain = "喜欢与不喜欢同时出现，这一行的状态没读准"
}
