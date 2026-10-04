import CovaCore
import CovaUI
import SwiftUI

/// 20 · 作品列表（我的作品 · §5 P1-1 / 验收 A7；A5·A6 的设备侧取证就骑这一屏）。
///
/// 规格：`design/screens/20-works-list.md`。这一屏的三处"不许顺手多做"都落在这棵视图之外，
/// 所以这里没有绕过的入口：
/// · **分页与并发**（游标只回传、代际只认当代、一行只允许一个写）在 `WorksListState`；
/// · **媒体出口**（`audioUrl` + `intent=download` + 伪 trackId 的 `PlaybackItem`）在
///   `AppSession.worksRowPlaybackItem` / `worksRowDownloadRequest`，与 19 同一条腿；
/// · **job 级作用域**（重命名/删除/分享）只存在于**组头** ⋯，行 ⋯ 里物理上没有这三项
///   —— 比贴一句警告更可靠（§3.D）。
///
/// 不渲染的东西（§1 的范围声明，不是遗漏）：`cover/extend/remaster` 入口（属 P1-2 的作品详情，
/// 本仓没有那一屏）、`melody` 哼唱、波形与 `bpm`（作品行恒空）、行 ⋯ 的第四项「补充制作」（P2-1 已交付：
/// 它开的是 21 面板的作品路径，走的是同一枚 `sheet` ⇒ 连点两次复用已开的那一层）。
public struct WorksListView: View {
    @Environment(AppSession.self) private var session
    /// §6 Dynamic Type：AX 档下四枚行内钮**整排换到第二行**（不缩热区），
    /// 行标题与徽标各自成行 —— 这三条都靠"换位置"实现，而不是把字压小。
    @Environment(\.covaAXLayout) private var axLayout

    /// 搜索栏草稿（只在展开时存在）。**只有这一格留本地**：它是"用户正在打的字"，
    /// 与会话层那份"已经发出去的 `q`"是两件事（防抖窗口里两者必然不同）。
    @State private var searchDraft = ""
    /// 任务定位锚点，**来自路由载荷**而不是 `worksList.anchoredJobID` 那份状态：
    /// 状态会被这一次 `.task` 的常规加载抹掉，也会把上一次访问的锚点漏到这一次。
    /// 「这一屏看的是哪一组」是目的地的一部分。
    private let anchoredJobID: String?

    public init(jobID: String? = nil) { self.anchoredJobID = jobID }
    @State private var searchOpen = false
    /// ⋯ 菜单：**一个**状态位同时承载组级与行级两条菜单 ⇒ 结构性互斥
    /// （§8「组头 ⋯ 与组内行 ⋯ 不同时开」不靠"记得关掉另一个"，靠开不了第二个）。
    @State private var menu: WorksMenu?
    /// 弹层（排序 / 歌词 / 重命名 / 分享）。
    @State private var sheet: WorksSheet?
    /// 本机文件删除的二次确认（19 §3.E 同一条腿）。
    @State private var pendingLocalDelete: WorksListRowDto?
    /// job 级删除的二次确认（§8 的措辞：这一次生成的**两行**都会消失）。
    @State private var pendingJobDelete: WorksJobDelete?


    private var state: WorksListState { session.worksList }

    public var body: some View {
        ScrollView {
            // **LazyVStack 而不是 VStack**：下一页的触发点挂在尾部那一格上，而 `VStack`
            // 会在首屏就把所有子视图建出来 ⇒ 一进来就把 10 页全拉完（§8 的翻页上限
            // 本来是防 offset 漂移放大，那样实现等于自己把它废掉）。
            LazyVStack(alignment: .leading, spacing: CovaSpace.lg) {
                if state.isRefreshing {
                    // 17-S4 细条位：手里有内容时整表重取失败不长成"整屏错误"。
                    refreshNotice
                }
                // §3.A 任务定位形态：B 摘要行与 C 筛选条**整块不渲染**（数据源换成 `?id=`，
                // 那里没有筛选也没有分页），而不是置灰。
                if !state.isJobAnchored {
                    summaryRow
                    if searchOpen { searchBar }
                    filterChips
                }
                mainContent
                footer
            }
            .padding(.bottom, CovaSpace.xxl)
        }
        .covaPage()
        .navigationTitle(state.isJobAnchored ? WorksListCopy.anchoredTitle : WorksListCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !state.isJobAnchored {
                ToolbarItem(placement: .topBarTrailing) { sortToolbarButton }
            }
        }
        .refreshable { await session.refreshWorksList() }
        .confirmationDialog(
            menuTitle, isPresented: menuBinding, titleVisibility: .visible
        ) { menuActions }
        .confirmationDialog(
            WorksListCopy.deleteLocalConfirm, isPresented: Binding(
                get: { pendingLocalDelete != nil }, set: { if !$0 { pendingLocalDelete = nil } }
            ), titleVisibility: .visible
        ) {
            Button(WorksListCopy.delete, role: .destructive) {
                if let row = pendingLocalDelete {
                    Task { await session.removeSavedWorksRow(id: row.id) }
                }
                pendingLocalDelete = nil
            }
            Button(WorksListCopy.cancel, role: .cancel) { pendingLocalDelete = nil }
        }
        .confirmationDialog(
            WorksListCopy.deleteJobConfirm, isPresented: Binding(
                get: { pendingJobDelete != nil }, set: { if !$0 { pendingJobDelete = nil } }
            ), titleVisibility: .visible
        ) {
            // 后果说在前面：这一组里的**两行**一起消失（§3.D 的三重披露之一）。
            Text(WorksListCopy.deleteJobConsequence)
            Button(WorksListCopy.delete, role: .destructive) {
                if let target = pendingJobDelete {
                    Task {
                        await session.deleteWorksGroup(
                            anchor: target.anchor, probeRowID: target.probeRowID
                        )
                    }
                }
                pendingJobDelete = nil
            }
            Button(WorksListCopy.cancel, role: .cancel) { pendingJobDelete = nil }
        }
        .sheet(item: $sheet) { presented in sheetView(presented) }
        .task { await session.loadWorksList(anchoredTo: anchoredJobID) }
        .onDisappear { session.cancelWorksListRead() }
    }

    // MARK: - A 导航条右侧「排序」

    /// §3.A：只有两项 —— 服务端 `sort` 是二值枚举 ⇒ 不发明「按播放次数」「按时长」。
    private var sortToolbarButton: some View {
        Button { sheet = .sort } label: {
            HStack(spacing: CovaSpace.xs) {
                Text(WorksListCopy.sort)
                Image(systemName: "chevron.down").font(CovaType.caption)
            }
            .font(CovaType.callout)
            .foregroundStyle(CovaColor.accentText)
            .frame(minWidth: Metrics.touch, minHeight: Metrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("排序，当前 \(state.sort == .newest ? WorksListCopy.sortNewest : WorksListCopy.sortOldest)")
    }

    // MARK: - B 摘要行 + 搜索

    /// 「%d 首」= 服务端 `total` **原值**：不加「共」字、不本地重算（§3.B 待答 1 的口径未文档化）。
    /// `total` 缺失 ⇒ 整行不渲染（不显 `--`，也不拿本页行数冒充全库数）。
    private var summaryRow: some View {
        HStack(alignment: .center, spacing: CovaSpace.md) {
            if let total = state.total {
                Text(WorksListCopy.summary(total))
                    .font(CovaType.subhead)
                    .foregroundStyle(CovaColor.muted)
                    // 数字走 `type.mono`（§3.B），朗读只念人话不念格式。
                    .accessibilityLabel("\(total) 首")
            }
            Spacer(minLength: CovaSpace.sm)
            Button {
                searchOpen.toggle()
                guard !searchOpen else { return }
                // 收起搜索栏 = 撤销那条搜索（留着 `q` 而屏上看不见搜索框，
                // 就是一条"发出去了但没人知道"的隐藏筛选 —— 03 §1 为同一件事设了已选 chips 行）。
                searchDraft = ""
                Task { await session.searchWorksList("") }
            } label: {
                Image(systemName: searchOpen ? "xmark" : "magnifyingglass")
                    .font(CovaType.body)
                    .foregroundStyle(CovaColor.secondary)
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchOpen ? "关闭搜索" : "搜索作品")
            .accessibilityIdentifier("cova.works.search")
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .frame(minHeight: Metrics.touch)
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: CovaSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(CovaColor.muted)
                .accessibilityHidden(true)
            // 占位只说「搜索作品」：`q` 到底检索哪几列未文档化（§3.B 待答 2），
            // 写成「搜歌名/歌词」就是替服务端承诺它没承诺过的检索面。
            TextField(WorksListCopy.searchPlaceholder, text: Binding(
                get: { searchDraft },
                set: { newValue in
                    // §8 极值：本地钳到 200 字，不发一个明知不合理的长串去换服务端脸色。
                    let clamped = String(newValue.prefix(WorkRenameRequestDto.titleMaximumLength))
                    searchDraft = clamped
                    Task { await session.searchWorksList(clamped) }
                }
            ))
            .font(CovaType.callout)
            .foregroundStyle(CovaColor.fg)
            .accessibilityIdentifier("cova.works.searchField")
            if !searchDraft.isEmpty {
                Button {
                    searchDraft = ""
                    Task { await session.searchWorksList("") }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CovaColor.muted)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(CovaSpace.md)
        .background(Capsule().fill(CovaColor.surface))
        .padding(.horizontal, CovaSpace.pageGutter)
    }

    // MARK: - C 筛选 chips（单选 9 值）

    /// 9 枚标签是**本地常量** ⇒ 首载时不骨架（§4 加载态那条明写）。
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CovaSpace.sm) {
                ForEach(WorksListFilter.allCases) { filter in
                    CovaChip(filter.chipTitle, isSelected: state.filter == filter) {
                        guard state.filter != filter else { return }
                        searchDraft = ""
                        Task { await session.selectWorksFilter(filter) }
                    }
                    .frame(minHeight: Metrics.chipHeight)
                    .accessibilityLabel("\(filter.chipTitle)，筛选")
                    .accessibilityAddTraits(state.filter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .frame(minHeight: Metrics.touch)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("筛选，横向滚动，\(WorksListFilter.allCases.count) 项，已选中 \(state.filter.chipTitle)")
    }

    // MARK: - D/E 主体（组头 + 行）

    @ViewBuilder
    private var mainContent: some View {
        switch state.phase {
        case .idle, .loading:
            firstLoadSkeleton
        case .failed(let message):
            failedBlock(message: message)
        case .empty:
            emptyBlock
        case .loaded:
            LazyVStack(alignment: .leading, spacing: CovaSpace.xl) {
                // id 用**下标**而不是锚点：§3.D 明写同一 jobId 被分页切开时要在切断处
                // **重新出现同一组头** ⇒ 锚点会重复，重复 id 的 ForEach 是运行时缺陷。
                ForEach(Array(state.groups.enumerated()), id: \.offset) { _, group in
                    jobGroup(group)
                }
            }
        }
    }

    /// §4 加载（首载）：B 一条骨架 + E 六行骨架；**C chips 不骨架、D 组头不骨架**
    /// （组是聚合出来的形状，骨架会教用户错的结构）。
    private var firstLoadSkeleton: some View {
        VStack(alignment: .leading, spacing: CovaSpace.lg) {
            CovaSkeleton(rows: 1)
            CovaSkeleton(rows: 6)
        }
    }

    /// 一个任务组：组头（job 级动作的唯一落点）+ 组内行。
    private func jobGroup(_ group: WorksJobGroup) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            groupHeader(group)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { offset, row in
                worksRow(row, index: group.firstRowIndex + offset)
                Rectangle().fill(CovaColor.lineSubtle).frame(height: 1)
            }
        }
    }

    /// D 组头：「%s · 一次生成 %d 首」+（可分享时）「已分享」+ ⋯。
    ///
    /// 单行组同样出现组头、数量写「1 首」（§3.D —— 措辞不变成「这首」）：
    /// 这一格说的是**作用域**，不是数量修辞。
    private func groupHeader(_ group: WorksJobGroup) -> some View {
        HStack(spacing: CovaSpace.md) {
            VStack(alignment: .leading, spacing: CovaSpace.xs) {
                Text(WorksListCopy.groupHeader(time: relativeTime(of: group), count: group.rowCount))
                    .font(CovaType.caption)
                    .foregroundStyle(CovaColor.muted)
                if session.worksList.shareBadge(for: group) {
                    badge(WorksListCopy.shared)
                }
            }
            Spacer(minLength: CovaSpace.sm)
            // 整组都是占位行 ⇒ 这一组还在做，job 级动作发早了只会换一次 409（§3.E 同一判据）。
            if !group.isAllPlaceholders,
               let probe = group.rows.first(where: state.actionsAllowed(on:)) {
                Button { openGroupMenu(group, probe: probe) } label: {
                    Image(systemName: "ellipsis")
                        .font(CovaType.body)
                        .foregroundStyle(CovaColor.secondary)
                        .frame(width: Metrics.touch, height: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WorksListCopy.moreActions)
                .accessibilityIdentifier("cova.works.groupMenu.\(group.anchor)")
            }
        }
        .padding(.vertical, CovaSpace.sm)
        .padding(.horizontal, CovaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                .fill(CovaColor.surface)
        )
        .accessibilityIdentifier("cova.works.group.\(group.firstRowIndex)")
    }

    /// 组头的时间位取组内第一行的 `createdAt`；认不出就不渲染那一格（§7 字段可空规则）。
    private func relativeTime(of group: WorksJobGroup) -> String? {
        StudioRelativeTime.text(
            group.rows.first?.createdAt, now: Date(), calendar: Calendar.current
        )
    }

    // MARK: - E 作品行

    /// 行 = `CovaListRow`（19 §3.E 同几何：封面 + 主副标题 + 尾饰），差别只有三处：
    /// · 状态徽标 / 失败原文 / 占位说明都写在**行下方**（`CovaListRow` 没有"标题后插一枚胶囊"的槽位，
    ///   而本仓的 `纯音乐` 徽标从 19 起就是文本位 —— 与 §3.E「主标题后追加」的**位置**有出入，
    ///   值与读法一致，已按"代码赢机理、规格赢呈现"登记在交付说明里）；
    /// · 行内动作收敛为**一枚 ⋯**（2026-10-01 C2 修，§3.E + TG-45），占位行**一枚都不渲染**；
    /// · 行点击 = ▶（§3.E 末条）。
    private func worksRow(_ row: WorksListRowDto, index: Int) -> some View {
        let title = row.displayTitle ?? WorksListCopy.untitled
        let allowsActions = state.actionsAllowed(on: row)
        return VStack(alignment: .leading, spacing: CovaSpace.xs) {
            CovaListRow(
                title: title,
                subtitle: subtitle(for: row),
                artwork: CovaArtwork(
                    resolution: CovaArtworkResolution(serverValue: row.coverUrl), title: title
                )
            ) {
                // 行内只留一枚 ⋯（2026-10-01 C2 修）：四枚 44pt 钮把标题压到约 7 个字，
                // ♡/↓/播放全部收进 ⋯ 菜单，标题才能稳定读到约 12 个字。
                // AX 档下这枚 ⋯ 整排挪到第二行（§6），这一格腾出来。
                if allowsActions, !axLayout { moreButton(row) }
            } action: {
                // 行点击 = ▶。占位行/失败行没有可播的音频 ⇒ 什么都不做
                // （"点了没反应"必须能由屏上那一行「这首还在做」解释，而不是靠一句 Toast）。
                guard row.isPlayable else { return }
                Task { await session.playWorksRow(id: row.id) }
            }
            .frame(minHeight: Metrics.rowHeight)
            .accessibilityIdentifier("cova.works.row.\(index)")

            if allowsActions, axLayout {
                HStack { Spacer(minLength: 0); moreButton(row) }
                    .padding(.horizontal, CovaSpace.pageGutter)
            }
            underRowExtras(row)
        }
    }

    /// 状态徽标：文案**一律**取 `GenerationJobStatus.userLabel`（A15 术语唯一源），
    /// 屏上不得出现 `queued/processing/succeeded` 这类英文态名（17 §10 禁令）。
    /// `succeeded` 且可播 ⇒ **不渲染**（成功是默认预期，给它徽标等于把其他态抬成焦点）。
    private func statusBadge(for row: WorksListRowDto) -> String? {
        guard let status = row.status else { return nil }
        if status == .succeeded, row.isPlayable { return nil }
        return status.userLabel
    }

    /// 副标题 = 时长（`type.mono`）+（纯音乐时）「纯音乐」。
    /// `duration == null` ⇒ 时长位**整段不渲染**，不显 `--`（§7：这里本就没有数值）。
    private func subtitle(for row: WorksListRowDto) -> String? {
        var parts: [String] = []
        if let duration = row.displayDuration { parts.append(PlayerTime.elapsed(duration)) }
        if row.instrumental == true { parts.append(WorksListCopy.instrumental) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 行内唯一按钮（⋯ ≥44pt，TG-03/TG-45；其余动作在行 ⋯ 菜单里）

    private func rowButton(
        symbol: String, tint: Color, label: String, busy: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol)
                    .font(CovaType.title)
                    .foregroundStyle(tint)
                    .opacity(busy ? 0.35 : 1)
                    .accessibilityHidden(true)
                if busy {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: Metrics.touch, height: Metrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 行尾 ⋯ = **clip 级**动作的唯一落点（§3.E）：播放 / 喜欢 / 保存到本机 /
    /// 不喜欢 / 做成笔记 / 歌词 / 补充制作。这里**不存在**重命名/删除/分享 ——
    /// 那三项是 job 级的，靠"物理上放不到一行上"表达作用域。
    private func moreButton(_ row: WorksListRowDto) -> some View {
        rowButton(
            symbol: "ellipsis",
            tint: CovaColor.secondary,
            label: WorksListCopy.moreActions,
            busy: false
        ) {
            menu = .row(rowID: row.id)
        }
        .accessibilityIdentifier("cova.works.rowMenu.\(row.id)")
    }

    /// 行下方那一区：徽标胶囊（可枚）+ 一句说明（最多一条）。
    /// §3.E 的占位行就是这一格在说话：「状态徽标 + 一行『这首还在做』」。
    @ViewBuilder
    private func underRowExtras(_ row: WorksListRowDto) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.xs) {
            if let badgeText = statusBadge(for: row) {
                badge(badgeText).padding(.leading, CovaSpace.pageGutter)
            }
            if let caption = caption(for: row) {
                Text(caption.text)
                    .font(CovaType.caption)
                    .foregroundStyle(caption.isError ? CovaColor.error : CovaColor.muted)
                    // §8：失败原文最多 3 行后**中段**截断（尾部才是"到底还有多少"的信息位）。
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, CovaSpace.pageGutter)
            }
        }
    }

    /// 这一行要不要另说一句：冲突 > 失败原文 > 占位说明（§3.E/§4）。
    private func caption(for row: WorksListRowDto) -> (text: String, isError: Bool)? {
        if state.signalsAreUncertain(row) {
            return (WorksListCopy.signalsUncertain, false)
        }
        if row.status == .failed {
            return (
                WorksListQuery.textIfPresent(row.errorMessage) ?? WorksListCopy.generationFailed,
                true
            )
        }
        if row.isPendingPlaceholder { return (WorksListCopy.stillGenerating, false) }
        return nil
    }

    // MARK: - F 尾部状态行

    /// §3.F：`nextCursor` 为空 ⇒「已显示全部」；在途拉下一页 ⇒「加载中…」。
    /// **但**服务端 `total` 说还有行没到屏上时不许写"已显示全部"（§7：宁可少说，不许装完整）。
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: CovaSpace.md) {
            switch footerState {
            case .loadingMore:
                Text(WorksListCopy.loadingMore)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                    .accessibilityLabel(WorksListCopy.loadingMore)
            case .appendFailed:
                HStack(spacing: CovaSpace.md) {
                    Text(WorksListCopy.pageFailed)
                        .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                    Button(WorksListCopy.retry) { Task { await session.loadMoreWorks() } }
                        .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                        .frame(minWidth: Metrics.touch, minHeight: Metrics.touch)
                }
            case .incomplete(let missing):
                Text(WorksListCopy.incomplete(missing))
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            case .allShown:
                Text(WorksListCopy.allShown)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CovaSpace.xl)
        .accessibilityIdentifier("cova.works.footer")
        // 触底取下一页：键是**已取页数**，所以
        // · 首屏不会自己往下翻（`LazyVStack` 里这一格还没被建出来）；
        // · 失败后不会连环重发（那一格不动 pagesLoaded，屏上改由「重试」钮接手 ——
        //   §4 要的就是"Toast + 行内重试"，不是无限自动重试）。
        .task(id: state.pagesLoaded) {
            guard state.canLoadMorePages else { return }
            await session.loadMoreWorks()
        }
    }

    private enum FooterState: Equatable {
        case hidden, loadingMore, appendFailed, incomplete(Int), allShown
    }

    private var footerState: FooterState {
        guard state.phase == .loaded, state.hasContent else { return .hidden }
        if state.isReading { return .loadingMore }
        if state.appendFailed { return .appendFailed }
        if let missing = state.missingRowCount { return .incomplete(missing) }
        // 任务定位形态无分页（§3.A），不写"已显示全部"那句 —— 它说的是全量列表那本账。
        if state.isJobAnchored { return .hidden }
        return state.reachedEnd ? .allShown : .hidden
    }

    private var refreshNotice: some View {
        HStack(spacing: CovaSpace.md) {
            if let message = state.readMessage {
                Text(message).font(CovaType.caption).foregroundStyle(CovaColor.muted)
                Button(WorksListCopy.retry) { Task { await session.refreshWorksList() } }
                    .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
            } else {
                Text(WorksListCopy.loadingMore)
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CovaSpace.pageGutter)
        .accessibilityIdentifier("cova.works.refreshNotice")
    }

    // MARK: - 空态 / 错误态（§4 的三种空态，措辞各自独立）

    @ViewBuilder
    private var emptyBlock: some View {
        if state.filter == .generating && state.search.isEmpty {
            // 空态 3：`filter=generating` 且确无在制任务是**正常结果**，不配插画、不给 CTA。
            Text(WorksListCopy.nothingGenerating)
                .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CovaSpace.xxl)
        } else if state.hasActiveRefinement {
            // 空态 2：带筛选/搜索无结果 ⇒ 无插画位，只有一个「清除筛选」（不给第二个 CTA）。
            CovaEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: WorksListCopy.filteredEmpty,
                hint: nil,
                actionTitle: WorksListCopy.clearFilter
            ) {
                searchDraft = ""
                searchOpen = false
                Task { await session.clearWorksRefinements() }
            }
        } else {
            // 空态 1：真的一行都没有 ⇒ 主 CTA 去 19（本屏的产物是**作品**，不是会话）。
            CovaEmptyState(
                symbol: "music.note.list",
                title: WorksListCopy.emptyTitle,
                hint: WorksListCopy.emptyHint,
                actionTitle:WorksListCopy.emptyCTA
            ) {
                session.push(.studioCreate)
            }
        }
    }

    /// 首载失败且手里没有内容 ⇒ 整屏那一格（§4 错误 ④「作品列表没取到」+「重试」）。
    private func failedBlock(message: String) -> some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CovaColor.error.opacity(0.8))
            Text(WorksListCopy.listFailed)
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            Text(message)
                .font(CovaType.subhead).foregroundStyle(CovaColor.secondary)
                .multilineTextAlignment(.center)
            CovaButton(WorksListCopy.retry, style: .secondary) {
                Task { await session.loadWorksList(force: true) }
            }
            .frame(maxWidth: 180)
        }
        .padding(CovaSpace.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("cova.works.failed")
    }

    // MARK: - ⋯ 菜单（组级 / 行级共一条呈现，互斥由 `menu` 那一格保证）

    private var menuBinding: Binding<Bool> {
        Binding(get: { menu != nil }, set: { if !$0 { menu = nil } })
    }

    private var menuTitle: String {
        switch menu {
        case .group(_, let count): return WorksListCopy.groupScope(count)
        case .row(let rowID): return state.row(id: rowID)?.displayTitle ?? WorksListCopy.untitled
        case nil: return " "
        }
    }

    @ViewBuilder
    private var menuActions: some View {
        switch menu {
        case .group(let anchor, let count):
            // §3.D：组级三项，每句都带「本次生成的作品」——VoiceOver 不得简写成「重命名」。
            if let target = groupTarget(anchor: anchor) {
                Button(WorksListCopy.renameJob) {
                    sheet = .rename(
                        anchor: target.anchor, jobID: target.jobID, rowID: target.probeRowID,
                        title: target.title
                    )
                }
                if target.canShare {
                    Button(WorksListCopy.shareJob) {
                        sheet = .share(anchor: target.anchor, rowID: target.probeRowID)
                        Task {
                            await session.refreshWorksShareStatus(
                                anchor: target.anchor, probeRowID: target.probeRowID
                            )
                        }
                    }
                }
                Button(WorksListCopy.deleteJob, role: .destructive) {
                    pendingJobDelete = WorksJobDelete(
                        anchor: target.anchor, probeRowID: target.probeRowID, count: count
                    )
                }
            }
        case .row(let rowID):
            if let row = state.row(id: rowID) {
                // 行内收敛为 ⋯ 之后（2026-10-01 C2），「播放 / 保存 / 喜欢」全收进这里；
                // 项集与顺序由 `WorksRowMenuItem.items` 判（可测），这里只做呈现与分发。
                // 「播放」留一项是为了 VoiceOver：整行点击的语义只有菜单里这枚是显式念出来的。
                let items = WorksRowMenuItem.items(
                    for: row,
                    favoriteOn: state.favoriteIsOn(row),
                    dislikeOn: state.dislikeIsOn(row),
                    saved: session.savedWorkIDs.contains(rowID),
                    noteDone: state.materializedNoteRowIDs.contains(rowID)
                )
                ForEach(items, id: \.self) { item in
                    switch item {
                    case .play:
                        Button(WorksListCopy.play) {
                            Task { await session.playWorksRow(id: rowID) }
                        }
                    case .save(let saved):
                        Button(saved ? WorksListCopy.removeSaved : WorksListCopy.save) {
                            if saved {
                                // 连续两个 confirmationDialog 要先让菜单关完再弹确认框，
                                // 同一个 frame 里切换 `menu`/`pendingLocalDelete` 会吃掉其中一个。
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    pendingLocalDelete = row
                                }
                            } else {
                                Task { await session.saveWorksRow(id: rowID) }
                            }
                        }
                    case .favorite(let on):
                        Button(on ? "\(WorksListCopy.favorite)（已选）" : WorksListCopy.favorite) {
                            Task { await session.toggleWorksFavorite(id: rowID) }
                        }
                    case .dislike(let on):
                        Button(on ? "\(WorksListCopy.dislike)（已选）" : WorksListCopy.dislike) {
                            Task { await session.toggleWorksDislike(id: rowID) }
                        }
                    case .note(let done):
                        Button(done ? WorksListCopy.noteDone : WorksListCopy.note) {
                            Task { await session.materializeWorksNote(id: rowID) }
                        }
                    case .lyrics:
                        Button(WorksListCopy.lyrics) {
                            sheet = .lyrics(rowID: rowID)
                            Task { await session.loadWorksLyrics(id: rowID) }
                        }
                    case .extras:
                        // 21 面板（作品路径）。`cova.works.extras` 是验收腿锚点，不许改名。
                        Button("补充制作") { sheet = .extras(rowID: rowID) }
                            .accessibilityIdentifier("cova.works.extras")
                    }
                }
            }
        case nil:
            EmptyView()
        }
        Button(WorksListCopy.cancel, role: .cancel) { menu = nil }
    }

    private func openGroupMenu(_ group: WorksJobGroup, probe: WorksListRowDto) {
        menu = .group(anchor: group.anchor, count: group.rowCount)
    }

    /// 菜单只留锚点，行内容**每次现取**：整表重取可能已经把那一组换掉了，
    /// 拿着旧的 `probeRowID` 发请求会打到一条已经不存在的行上。
    private func groupTarget(anchor: String) -> (anchor: String, jobID: String?, probeRowID: String, title: String, canShare: Bool)? {
        guard let group = state.groups.first(where: { $0.anchor == anchor }),
              let probe = group.rows.first(where: state.actionsAllowed(on:)) else { return nil }
        return (
            group.anchor, group.jobID, probe.id,
            probe.displayTitle ?? WorksListCopy.untitled, group.canShare
        )
    }

    // MARK: - 弹层

    @ViewBuilder
    private func sheetView(_ presented: WorksSheet) -> some View {
        switch presented {
        case .sort:
            sortPanel
        case .lyrics(let rowID):
            lyricsPanel(rowID: rowID)
        case .rename(let anchor, let jobID, let rowID, let title):
            renamePanel(anchor: anchor, jobID: jobID, rowID: rowID, current: title)
        case .share(let anchor, let rowID):
            sharePanel(anchor: anchor, rowID: rowID)
        case .extras(let rowID):
            // `instrumental` 只从那一行取（宿主能给就给，给不出传 nil ⇒ 面板不滤键集，
            // 滤与不滤的裁决权留在服务端那一句权威答复上，不在客户端替它决定）。
            WorkExtrasPanelView(
                host: .work(
                    id: rowID,
                    instrumental: state.row(id: rowID)?.instrumental
                )
            ) { sheet = nil }
        }
    }

    private var sortPanel: some View {
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            ForEach(WorksListSort.allCases) { sort in
                Button {
                    sheet = nil
                    Task { await session.selectWorksSort(sort) }
                } label: {
                    HStack {
                        Text(sort.sheetTitle).font(CovaType.body).foregroundStyle(CovaColor.fg)
                        Spacer()
                        if state.sort == sort {
                            Image(systemName: "checkmark").foregroundStyle(CovaColor.selected)
                        }
                    }
                    .frame(minHeight: Metrics.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(state.sort == sort ? .isSelected : [])
            }
        }
        .padding(CovaSpace.lg)
        .covaPage()
    }

    /// 歌词面板：LRC 取到时**静态行文 + 服务端给的时间戳前缀**，
    /// **不做**与播放进度联动的逐行高亮/自动滚动（§7 与 D15 的裁决：那要播放器同车，另一批活）。
    private func lyricsPanel(rowID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CovaSpace.md) {
                HStack {
                    Text(state.row(id: rowID)?.displayTitle ?? WorksListCopy.untitled)
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    Spacer()
                    Button { sheet = nil } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(CovaColor.secondary)
                            .frame(width: Metrics.touch, height: Metrics.touch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                switch state.lyrics[rowID] ?? .loading {
                case .loading:
                    CovaSkeleton(rows: 3)
                case .aligned(let text), .plain(let text):
                    ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(String(line))
                            .font(CovaType.callout).foregroundStyle(CovaColor.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .unavailable(let message):
                    Text(message).font(CovaType.subhead).foregroundStyle(CovaColor.muted)
                }
            }
            .padding(CovaSpace.lg)
        }
        .covaPage()
    }

    private func renamePanel(
        anchor: String, jobID: String?, rowID: String, current: String
    ) -> some View {
        RenamePanel(
            current: current,
            // §3.D 的复述位：改名是 job 级 ⇒ 一进这一格就把"两行一起变"说出来。
            scopeLine: WorksListCopy.groupScope(state.groups.first { $0.anchor == anchor }?.rowCount ?? 1),
            onCancel: { sheet = nil },
            onSubmit: { title in
                sheet = nil
                Task {
                    await session.renameWorksGroup(
                        anchor: anchor, jobID: jobID, probeRowID: rowID, title: title
                    )
                }
            }
        )
    }

    private func sharePanel(anchor: String, rowID: String) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            Text(WorksListCopy.shareJob)
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            // 公开链接：免登录可听 ⇒ 与签名 URL 不同族，这一条**可以**显示可以复制（§8）。
            if let path = state.sharePaths[anchor], let url = CovaEnvironment.resolveMediaURL(path) {
                Text(url.absoluteString)
                    .font(CovaType.mono).foregroundStyle(CovaColor.secondary)
                    .textSelection(.enabled)
                ShareLink(item: url) {
                    Text(WorksListCopy.shareJob)
                        .font(CovaType.callout).foregroundStyle(CovaColor.accentText)
                        .frame(minHeight: Metrics.touch)
                }
            } else {
                Text(WorksListCopy.shareNotOpened)
                    .font(CovaType.subhead).foregroundStyle(CovaColor.muted)
            }
            HStack(spacing: CovaSpace.md) {
                CovaButton(WorksListCopy.openShare, style: .secondary) {
                    Task { await session.openWorksShare(anchor: anchor, probeRowID: rowID) }
                }
                CovaButton(WorksListCopy.close, style: .secondary) {
                    Task { await session.closeWorksShare(anchor: anchor, probeRowID: rowID) }
                }
            }
            CovaButton(WorksListCopy.cancel, style: .secondary) { sheet = nil }
        }
        .padding(CovaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .covaPage()
    }

    // MARK: - 本地小件

    /// 状态徽标胶囊（§3.E：`type.caption` / `radius.capsule` / 底 `color.surface`）。
    /// 徽标**不**并进行的组合标签：§6 说"值并入行标签首段"针对的是"徽标不独立成元素"，
    /// 而这里它是行下方的一行静态文本，VoiceOver 本来就会念到 —— 藏起来才是漏读。
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(CovaType.caption)
            .foregroundStyle(CovaColor.muted)
            .padding(.horizontal, CovaSpace.sm)
            .padding(.vertical, CovaSpace.xs)
            .background(Capsule().fill(CovaColor.surface))
    }

    /// 本屏**没**做到的两格，写在这里而不是假装做了：
    /// · **离线态**（§4「有缓存 → 列表照常 + 17-S4 细条，全部写动作不渲染」）：本仓没有任何
    ///   "当前通不通"的读面（`CovaEnvironment` 只裁决出口，不报连通性），所以这一格今天判不出来；
    /// · §3.C 的 chips 渐隐与隐藏滚动条（TG-34 档未入库），这里只有 `showsIndicators: false`。
    /// Reduce Motion：骨架呼吸由 `CovaSkeleton` 自己退化成静止块，本屏没有进度类动效（§4 末条）
    /// ⇒ 没有额外的 `reduceMotion` 分支要写。
}

// MARK: - 重命名面板（本地校验用 §8 的两句：「名称不能为空」/「名称太长了」）
//
// 为什么不把校验塞进 `AppSession`：那是**输入端**的事（§8「超出即输入端截断，
// 不发出去换 400」），而会话层的 `WorkRenameRequestDto` 已经是这条规则的唯一事实源
// —— 这里只是把它的两种拒绝翻成人话，不再自己数一遍长度。
private struct RenamePanel: View {
    @State private var draft: String
    private let current: String
    private let scopeLine: String
    private let onCancel: () -> Void
    private let onSubmit: (String) -> Void

    init(
        current: String, scopeLine: String,
        onCancel: @escaping () -> Void, onSubmit: @escaping (String) -> Void
    ) {
        self.current = current
        self.scopeLine = scopeLine
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _draft = State(initialValue: current)
    }

    /// 服务端规则的本地回声（`WorkRenameRequestDto` 是唯一判据；两遍各写一次就是 min-2 那一族）。
    private var problem: String? {
        do {
            _ = try WorkRenameRequestDto(title: draft)
            return nil
        } catch WorkActionRequestError.emptyTitle {
            return WorksListCopy.nameEmpty
        } catch WorkActionRequestError.titleTooLong {
            return WorksListCopy.nameTooLong
        } catch {
            return WorksListCopy.nameEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            Text(WorksListCopy.rename)
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
            Text(scopeLine)
                .font(CovaType.caption).foregroundStyle(CovaColor.muted)
            TextField(WorksListCopy.rename, text: $draft)
                .font(CovaType.body)
                .foregroundStyle(CovaColor.fg)
                // 不换行（§8 截断规则）；提交后的截断由行的标题规则负责。
                .lineLimit(1)
                .accessibilityLabel(WorksListCopy.rename)
                .accessibilityIdentifier("cova.works.renameField")
                .onChange(of: draft) { _, value in
                    if value.count > WorkRenameRequestDto.titleMaximumLength {
                        draft = String(value.prefix(WorkRenameRequestDto.titleMaximumLength))
                    }
                }
            if let problem {
                Text(problem).font(CovaType.caption).foregroundStyle(CovaColor.error)
            }
            HStack(spacing: CovaSpace.md) {
                CovaButton(WorksListCopy.saveTitle, style: .primary) {
                    guard problem == nil else { return }
                    onSubmit(draft)
                }
                .disabled(problem != nil)
                CovaButton(WorksListCopy.cancel, style: .secondary, action: onCancel)
            }
        }
        .padding(CovaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .covaPage()
    }
}

// MARK: - 菜单与弹层的值类型

/// 两条 ⋯ 菜单共用一个状态位 ⇒ 开一个就关不了另一个（§8 互斥通则）。
private enum WorksMenu: Equatable {
    case group(anchor: String, count: Int)
    case row(rowID: String)
}

// MARK: - 行 ⋯ 菜单项判据（2026-10-01 C2：行内只留 ⋯，其余动作收进菜单）

/// 行 ⋯ 菜单的**有序项集**。判据收成一个纯函数而不是散在 `menuActions` 的 `if` 里：
/// 这里的规则（不可播没有播放/保存、占位行整个没有菜单、纯音乐没词不给歌词项）
/// 每一条都要能在单测里钉死 —— CovaFeature 没有 UI 测试目标（TD-48），
/// 「菜单里有什么」是这一屏唯一能被机械执行的行级契约。
enum WorksRowMenuItem: Equatable, Hashable {
    case play
    case favorite(Bool)
    case save(Bool)
    case dislike(Bool)
    case note(Bool)
    case lyrics
    case extras

    /// 从**行**与**会话侧的已解析标记**算这份菜单。
    /// `favoriteOn/dislikeOn/saved/noteDone` 必须由调用方给解析后的布尔
    /// （`state.favoriteIsOn` / `session.savedWorkIDs.contains` 之类），
    /// 这里不再去读 row 上的 `favorited`——服务端缺键即 false 的口径和
    /// 行内 override 的口径都已经在状态层合流了。
    static func items(
        for row: WorksListRowDto,
        favoriteOn: Bool, dislikeOn: Bool, saved: Bool, noteDone: Bool
    ) -> [WorksRowMenuItem] {
        var result: [WorksRowMenuItem] = []
        // 不可播 ⇒ 播放/保存都不给（给一枚点了没反应的钮不如没有）。
        if row.isPlayable {
            result.append(.play)
            result.append(.save(saved))
        }
        result.append(.favorite(favoriteOn))
        result.append(.dislike(dislikeOn))
        result.append(.note(noteDone))
        // 纯音乐且没有词 ⇒ 「歌词」项不渲染（07 §3.H 同判据，与原行 ⋯ 一致）。
        if !(row.instrumental == true && WorksListQuery.textIfPresent(row.lyrics) == nil) {
            result.append(.lyrics)
        }
        // 21 面板（作品路径）只认伪 id：裸 jobId 服务端 404（§4.7），占位行更没有音频。
        if row.isRealCandidateRow, row.status == .succeeded {
            result.append(.extras)
        }
        return result
    }
}

private enum WorksSheet: Identifiable, Equatable {
    case sort
    case lyrics(rowID: String)
    case rename(anchor: String, jobID: String?, rowID: String, title: String)
    case share(anchor: String, rowID: String)
    /// 21 面板（作品路径）。走的是同一枚 `sheet`，所以 §8 那句"连点两次复用已开的那一层、
    /// 不叠第二层"由机制保证，而不是靠调用方记得判空。
    case extras(rowID: String)

    var id: String {
        switch self {
        case .sort: return "sort"
        case .lyrics(let rowID): return "lyrics:\(rowID)"
        case .rename(let anchor, _, _, _): return "rename:\(anchor)"
        case .share(let anchor, _): return "share:\(anchor)"
        case .extras(let rowID): return "extras:\(rowID)"
        }
    }
}

/// job 级删除的确认载荷（`count` 只为把"这一组有几首"说进 VoiceOver 序列）。
private struct WorksJobDelete: Equatable {
    let anchor: String
    let probeRowID: String
    let count: Int
}

// MARK: - 本屏的 chip / sheet 标签（§3.C 定稿词表，与 A15 不冲突）
//
// `fileprivate` 是刻意的：这九个词是**这一屏**的裁决（§3.C「标签是本屏定稿」），
// 给 CovaCore 的枚举加一个跨屏共享的 `userLabel` 就是把一次设计裁决写成了全局事实。
fileprivate extension WorksListFilter {
    var chipTitle: String {
        switch self {
        case .all: return "全部"
        case .generating: return "制作中"
        case .vocal: return "有人声"
        case .instrumental: return "纯音乐"
        case .liked: return "喜欢"
        case .disliked: return "不喜欢"
        case .cover: return "翻唱"
        case .extend: return "续写"
        case .remaster: return "重制"
        }
    }
}

fileprivate extension WorksListSort {
    var sheetTitle: String {
        switch self {
        case .newest: return WorksListCopy.sortNewest
        case .oldest: return WorksListCopy.sortOldest
        }
    }
}

/// 本屏还没有 token 档的几何值（20 §「Token 缺口」TG-44/45/46 + 继承的 TG-03/07）。
/// 集中成命名常量而不是散落字面量：裁决落 token 时只改这一处。
private enum Metrics {
    /// TG-03：最小触控目标 44。
    static let touch: CGFloat = 44
    /// §3.C：chip 高 36（TG-07 档未入库）。
    static let chipHeight: CGFloat = 36
    /// 19 §3.E：行最小高 64。
    static let rowHeight: CGFloat = 64
}
