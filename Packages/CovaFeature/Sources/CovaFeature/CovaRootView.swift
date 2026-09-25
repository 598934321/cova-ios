import CovaCore
import CovaUI
import SwiftUI

/// 根视图（design 04 抽屉 + 三 Tab + MiniPlayer 浮层 + 全屏播放器 sheet）。
/// 登录态门控：未登录且未选游客 → 登录页；其余进主壳。
public struct CovaRootView: View {
    @State private var session = AppSession(previewTab: previewTab())
    @Environment(\.covaAXLayout) private var axLayout
    /// 04 §6「焦点在进入抽屉时移到第一项」：SwiftUI 公开 API 里唯一能把 **VoiceOver 焦点**
    /// 放到某个元素上的是 `AccessibilityFocusState`（iOS 17+）。走查时 VoiceOver 关着 ⇒
    /// 它是无害的空操作；开着 ⇒ 进抽屉的第一下读到的就是「首页，标签页」。
    ///
    /// §6 后半句「关闭时归还给触发它的 logo 按钮」的另一半在 `DrawerTrigger`（01/03 顶栏各一枚）：
    /// 那两枚按钮自己持有 `@AccessibilityFocusState`，观察 `session.drawerOpen` 回落为假、
    /// 且 `session.drawerOpener` 正是自己时把焦点接回去。本文件只负责**释放**抽屉侧的绑定
    /// （`onDisappear`，见 `drawerPanel`），不让它停在一个已经消失的元素上。
    /// 两处归还不到，也不在这里假装做到了：① 走查键 `COVA_PREVIEW_DRAWER` 打开的抽屉没有触发者
    /// （`drawerOpener` 恒 nil）；② 关闭时若底层已被 06/07/09 这类 push 屏盖住，触发钮不在朗读树里，
    /// 焦点请求无处落地。这两种情形下 VoiceOver 留在原地，不假装"回到了 logo"。
    @AccessibilityFocusState private var drawerEntryFocused: Bool
    private let themeMode: CovaThemeMode

    public init(themeMode: CovaThemeMode = .system) {
        self.themeMode = themeMode
    }

    /// 预览/走查钩子（**仅**模拟器走查用，文档登记于 §14）：
    /// `COVA_PREVIEW_TAB=home|library|mine` 决定首屏 Tab，便于逐屏截图；生产不设置即默认 home。
    private static func previewTab() -> AppSession.Tab {
        let raw = ProcessInfo.processInfo.environment["COVA_PREVIEW_TAB"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_TAB")
        switch raw {
        case "library": return .library
        case "mine": return .mine
        default: return .home
        }
    }

    /// 预览/走查钩子 2（同一性质）：`COVA_PREVIEW_SHEET=login|player` 在 bootstrap 之后直接展开
    /// 对应 sheet —— 登录页与全屏播放器没有 Tab 入口，不这样就没法逐屏截图。
    private static func previewSheet() -> String? {
        ProcessInfo.processInfo.environment["COVA_PREVIEW_SHEET"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_SHEET")
    }

    /// 走查钩子 3：`COVA_PREVIEW_ROUTE=favorites|myPlaylists|playlist:<id>|track:<id>`。
    /// 详情/列表页都在 Tab 之下且需要点击才能到达，逐屏走查需要一个「直接落到这一屏」的入口。
    private static func previewRoute() -> AppSession.Route? {
        let raw = ProcessInfo.processInfo.environment["COVA_PREVIEW_ROUTE"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_ROUTE")
        guard let raw else { return nil }
        switch raw {
        case "favorites": return .favorites
        case "myPlaylists": return .myPlaylists
        case "plaza": return .plaza
        case "settings": return .settings
        case "aiSessions": return .aiSessions
        case "membership": return .membership
        case "enterprise": return .enterprise
        default:
            if raw.hasPrefix("playlist:") { return .playlist(String(raw.dropFirst("playlist:".count))) }
            if raw.hasPrefix("artist:") { return .artist(String(raw.dropFirst("artist:".count))) }
            if raw.hasPrefix("aiSession:") { return .aiSession(String(raw.dropFirst("aiSession:".count))) }
            return nil
        }
    }

    /// 走查钩子 4（同一性质）：`COVA_PREVIEW_DRAWER=1` 启动即展开抽屉。
    /// 04 §1 入口①（顶栏字标钮）现在**真的存在**了，但这个键仍然保留、且不许用"只能点到达"的
    /// 代码路径替换它：`simctl` 不提供点击（引入 idb/appium 会破零依赖）⇒ 没有这个键，
    /// 04 就进不了逐屏走查的截图集合。它打开的抽屉没有触发者 ⇒ 关闭时不做焦点归还（见 `DrawerTrigger`）。
    private static func previewDrawer() -> Bool {
        (ProcessInfo.processInfo.environment["COVA_PREVIEW_DRAWER"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_DRAWER")) == "1"
    }

    /// 与钩子 3 同批：`COVA_PREVIEW_ROUTE=track:<id>` 走的是 sheet 而不是路由栈。
    private static func previewTrackID() -> String? {
        guard let raw = previewSheetValue() else { return nil }
        return raw.hasPrefix("track:") ? String(raw.dropFirst("track:".count)) : nil
    }

    private static func previewSheetValue() -> String? {
        ProcessInfo.processInfo.environment["COVA_PREVIEW_ROUTE"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_ROUTE")
    }

    /// 走查钩子 5（**只为模拟器逐屏截图存在**）：`COVA_PREVIEW_LOGIN_EMAIL` +
    /// `COVA_PREVIEW_LOGIN_PASSWORD` 走**真实的两步登录**（`/login` 建凭证 → `/me` 取身份），
    /// 不是往状态里塞一个假 token。
    ///
    /// 与 `COVA_PREVIEW_TAB/SHEET/ROUTE/DRAWER` 的关键差别：**只读进程环境，刻意不接
    /// `UserDefaults`** —— 口令与凭证不许落进任何持久化索引（AGENTS 硬边界 3），
    /// `simctl launch --setenv` 的值只活在这一次进程里。任一键缺失 ⇒ 这条路径完全不存在。
    private static func previewLogin() -> (email: String, password: String)? {
        guard let email = ProcessInfo.processInfo.environment["COVA_PREVIEW_LOGIN_EMAIL"],
              let password = ProcessInfo.processInfo.environment["COVA_PREVIEW_LOGIN_PASSWORD"],
              !email.isEmpty, !password.isEmpty
        else { return nil }
        return (email, password)
    }

    public var body: some View {
        Group {
            switch session.authPhase {
            case .restoring:
                ProgressView().controlSize(.large)
            case .guest, .signedIn, .failed:
                mainShell
            }
        }
        .environment(session)
        .preferredColorScheme(session.themeMode.colorScheme)
        .task {
            await session.bootstrap()
            // 登录要先于路由：登录后才有 `favorites`/`aiSessions` 这些屏可走查。
            if let login = Self.previewLogin() {
                await session.signIn(email: login.email, password: login.password)
            }
            switch Self.previewSheet() {
            case "login": session.loginPresented = true
            case "player": session.playerSheetOpen = true
            default: break
            }
            if let route = Self.previewRoute() { session.path.append(route) }
            // 这里是**直接置 `drawerOpen`** 而不是走 `openDrawer(from:)`：走查键没有触发者，
            // 于是关闭时不做焦点归还（04 §6 后半句只对真触发钮成立）。
            if Self.previewDrawer() { session.drawerOpen = true }
            if let trackID = Self.previewTrackID() { session.detailTrackID = trackID }
            // 走查钩子 7：`COVA_PREVIEW_PLAY=<trackId>` 走**真实取数 + 真实播放腿**（详情 → 队列 →
            // 出声），不是往状态里塞一个假快照。为什么必须有它：02 的波形进度条、♡、次级操作行
            // 只在"有内容在播"时才存在，而 `simctl` 不提供点击 ⇒ 没有这条键，02 的截图永远停在
            // 游客空态（昨天就是这样），D23①′ 那条「已购整曲 302 → 名单桶 ⇒ 剥凭证匿名 GET」的腿
            // 也没有任何一屏能被看到。登录在上面已完成，所以这一条走的就是带凭证的那一支。
            if let playID = ProcessInfo.processInfo.environment["COVA_PREVIEW_PLAY"], !playID.isEmpty,
               let detail = try? await session.catalog.trackDetail(playID) {
                await session.play(tracks: [detail.track], at: 0)
                // ️ 第一版在这里直接 `toggle()`，结果**永远停在 00:00**：`player.start` 之后状态是
                // `.loading`，而 `toggle()` 按 R7D 的裁决把 `.loading` 归到「正要响」那一侧 ⇒
                // 在途按 ⏯ 的语义是「别播这首」，于是这条钩子自己把刚起的装载暂停了。
                // 正确做法是等装载收敛（有界轮询，不无限等），只在真的停在静默态时补一次 ⏯。
                for _ in 0..<40 {
                    if let state = session.snapshot?.state, state != .loading, state != .buffering { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let state = session.snapshot?.state, state != .playing {
                    await session.toggle()
                }
                session.playerSheetOpen = true
                // 截图要拍到**进度真的在走**：`.playing` 是在引擎可出声之前乐观写的
                // （`PlaybackCoordinator.swift:616`），而 02 的第一根柱要到 `position ≥ 时长/48`
                // 才填色、`PlayerTime.elapsed` 又把不足 1 秒抹成 00:00 ⇒ 立刻拍必然是一张
                // "在播但 00:00"的图（第 20 轮 R20-3 纠正了我上一条读图结论：进度腿是通的）。
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
        .overlay(alignment: .top) { toastOverlay }
        .onReceive(NotificationCenter.default.publisher(for: StudioNotifier.didTap)) { tap in
            session.handleNotificationTap(userInfo: tap.userInfo ?? [:])
        }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            tabContent
            MiniPlayerView()
            tabBar
        }
        .covaPage()
        .sheet(isPresented: Binding(
            get: { session.playerSheetOpen },
            set: { session.playerSheetOpen = $0 }
        )) {
            PlayerView().environment(session)
        }
        .sheet(isPresented: Binding(
            get: { session.loginPresented },
            set: { session.loginPresented = $0 }
        )) {
            LoginView().environment(session)
        }
        // 07 曲目详情：sheet 只带 trackID，页面自己取数（与路由同一把口径）。
        .sheet(item: Binding(
            get: { session.detailTrackID.map(TrackSheetID.init) },
            set: { session.detailTrackID = $0?.id }
        )) { wrapped in
            TrackDetailSheet(trackID: wrapped.id).environment(session)
        }
        .overlay(alignment: .leading) { drawer }
    }

    @ViewBuilder
    private var tabContent: some View {
        let catalog = CatalogService(client: session.client)
        NavigationStack(path: $session.path) {
            Group {
                switch session.tab {
                case .home:
                    if case .guest = session.authPhase { LoginGate(catalog: catalog) }
                    else { HomeView(catalog: catalog) }
                case .library: LibraryView(catalog: catalog)
                case .mine: MineView()
                }
            }
            .navigationDestination(for: AppSession.Route.self) { route in
                switch route {
                case .playlist(let id): PlaylistDetailView(playlistID: id)
                case .favorites: FavoritesView()
                case .myPlaylists: MyPlaylistsView()
                case .plaza: PlaylistsPlazaView()
                case .settings: SettingsView()
                case .aiSessions: AISessionsView()
                case .aiSession(let id): AISessionDetailView(sessionID: id)
                case .membership: MembershipView()
                case .enterprise: EnterpriseView()
                case .artist(let id): ArtistHomeView(artistID: id)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack {
            ForEach(AppSession.Tab.allCases) { tab in
                Button { session.tab = tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: session.tab == tab ? .semibold : .regular))
                        Text(tab.title).font(CovaType.caption)
                    }
                    .foregroundStyle(session.tab == tab ? CovaColor.accent : CovaColor.muted)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(session.tab == tab ? .isSelected : [])
            }
        }
        .padding(.top, CovaSpace.sm)
        .padding(.bottom, CovaSpace.xs)
        .background(CovaColor.canvas.opacity(0.95))
        .overlay(alignment: .top) { Rectangle().fill(CovaColor.line).frame(height: 0.5) }
    }

    // MARK: 04 抽屉（全局导航 + 我的卡片）

    /// 抽屉宽 = 屏宽 × 78%（04 §2 与 inventory 钉死；TG-01「分栏比例」档未入 tokens
    /// ⇒ 按 78% 施工，393pt 屏 ⇒ 306pt）。**不随字号变**（§6：AX 档下抽屉宽度保持比例值，
    /// 溢出由换行消化）。用 `GeometryReader` 而不是 `containerRelativeFrame` ——
    /// 后者的参照是"最近的容器祖先"，在 `.overlay` 里拿到的不是屏宽。
    private static let drawerWidthRatio: CGFloat = 0.78

    @ViewBuilder
    private var drawer: some View {
        if session.drawerOpen {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // 遮罩（04 §2「遮罩宽 = 屏宽 − 抽屉宽」+ §9「右侧遮罩可点关闭」）。
                    // TG-08（scrim 强度档）未入库 ⇒ 取系统遮罩的默认形态（黑 30%），
                    // 不自造品牌色；裁决后换成 token。
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()   // 遮罩盖满整屏（含状态条带），面板自己仍留在安全区内
                        .contentShape(Rectangle())
                        .onTapGesture { session.drawerOpen = false }
                        // §1/§9：遮罩上左滑关闭。阈值复用 `spacing.xxl`，不另造数字。
                        .gesture(DragGesture().onEnded { value in
                            if value.translation.width < -CovaSpace.xxl { session.drawerOpen = false }
                        })
                        // 遮罩是**手势**目标，不是朗读目标：关闭语义由 ✕ 承担（§6 顺序里
                        // 只有「关闭按钮」一停，遮罩再占一停就成了多出来的噪声）。
                        .accessibilityHidden(true)

                    drawerPanel(width: proxy.size.width * Self.drawerWidthRatio)
                        .transition(.move(edge: .leading))
                }
            }
        }
    }

    private func drawerPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            drawerTopBar
            // §6：AX5 档**横向不许溢出** ⇒ 组区纵向可滚动（放大后 11 项 + 卡片装不进 852pt）。
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CovaSpace.xl) {   // §2 组间距 spacing.xl
                    drawerSection(title: "主导航", items: DrawerItem.main, entryGroup: true)
                    drawerDivider                                       // C 分隔线
                    drawerSection(title: "我的资产", items: DrawerItem.assets, entryGroup: false)
                    drawerDivider                                       // E 分隔线
                    drawerSection(title: "商业", items: DrawerItem.commerce, entryGroup: false)
                }
                .padding(.horizontal, CovaSpace.pageGutter)             // §2 内容左右内边距
                .padding(.vertical, CovaSpace.lg)
            }
            DrawerAccountCard(session: session)
                .padding(.horizontal, CovaSpace.pageGutter)
                .padding(.bottom, CovaSpace.lg)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(CovaColor.elevated)
        // §6 朗读顺序第 1 项：「Cova 导航抽屉，标题」。
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cova 导航抽屉")
        // 遮罩已让底层不可点 ⇒ 同时告诉 VoiceOver 底层**不该被朗读到**
        // （§9「放行前『已下载』在 VoiceOver 元素序列中不存在」的取证也依赖容器边界干净）。
        .accessibilityAddTraits(.isModal)
        .onAppear {
            drawerEntryFocused = true
            // 04 §7：打开抽屉时刷新 G 区数据。`loadMe` 自己按身份去重（同身份已取过就不重发），
            // 游客走的是"不发 me"那条腿 ⇒ 这里对游客是空操作，不是偷偷打一次接口。
            Task { await session.loadMe() }
        }
        .onDisappear { drawerEntryFocused = false }
    }

    /// A 顶栏（品牌 + 关闭）+ 底边分隔线。
    private var drawerTopBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: CovaSpace.md) {
                // 字标：`type.headline` / `color.fg`（§3.A）。
                // **不画 logo 图**：`design/assets/CovaAssets.xcassets` 里只有 `AppIcon`，
                // 没有 01 顶栏那枚品牌 logo 的 image set ⇒ 不拿 SF Symbol 冒充官方资产
                // （design/README 红线：logo 禁反色/重着色）。缺料已上报，不是这里能补的。
                Text("Cova").font(CovaType.headline).foregroundStyle(CovaColor.fg)
                Spacer()
                // §3.A：图标 17pt 不配当热区，触控区 ≥44pt（TG-03 档未入库）。
                Button { session.drawerOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(CovaType.headline)
                        .foregroundStyle(CovaColor.secondary)
                        .frame(width: DrawerMetrics.touchMin, height: DrawerMetrics.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭抽屉")
            }
            .padding(.horizontal, CovaSpace.pageGutter)
            .padding(.vertical, CovaSpace.lg)             // §3.A 品牌行上下内边距 lg
            .overlay(alignment: .bottom) { drawerDivider }  // §3.A 底边 1pt lineSubtle
        }
    }

    private var drawerDivider: some View {
        // C/E：`color.lineSubtle` 1pt（TG-04 描边宽度档未入库，按 spec 的 1pt 施工），
        // 上下留白由组间距 `spacing.xl` 提供。
        Rectangle().fill(CovaColor.lineSubtle).frame(height: DrawerMetrics.hairline)
    }

    /// 一个分组（B/D/F）。
    ///
    /// §6/§9 的「AX 档组标题隐藏」在这里落地，而且**不是把文字藏起来就完事**：
    /// 1. AX 档（≥ AX1）下这行标题**根本不被构造**（不是 `opacity(0)`、不是
    ///    `.accessibilityHidden`、不是 `hidden()`）—— 放大档下它挤占的正是项文字要用的
    ///    那点横向空间，留着它才是溢出的来源；
    /// 2. 分组语义改由**无障碍结构**承担：`.accessibilityElement(children: .contain)`
    ///    让这一组成为一个可进入的容器，`.accessibilityLabel(组名)` 让 VoiceOver 进组时
    ///    仍然念得出「主导航 / 我的资产 / 商业」。
    ///    ⇒ §6 的朗读顺序（组标题 → 组内各项）与 §9「AX5 无横向溢出且组标题隐藏」同时成立，
    ///    而不是"看得见的标题没了、语义也跟着没了"。
    /// 3. 非 AX 档标题虽然可见，但 `accessibilityHidden(true)`：容器标签已经念过一次组名，
    ///    再让标题单独占一停就是重复朗读。
    @ViewBuilder
    private func drawerSection(
        title: String, items: [DrawerItem], entryGroup: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            if !axLayout {
                Text(title)
                    .font(CovaType.caption).foregroundStyle(CovaColor.muted)
                    .accessibilityHidden(true)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                drawerRow(item, entryFocus: entryGroup && index == 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func drawerRow(_ item: DrawerItem, entryFocus: Bool = false) -> some View {
        let row = DrawerRow(
            item: item,
            selected: selectedDrawerLabel == item.label,
            action: { select(item) }
        )
        if entryFocus {
            row.accessibilityFocused($drawerEntryFocused)
        } else {
            row
        }
    }

    /// §3.B 状态语义：当前屏对应的项常驻选中；子屏保持**父项**高亮（06 → 歌单）。
    private var selectedDrawerLabel: String? {
        if let route = session.path.last {
            switch route {
            case .plaza, .playlist: return "歌单"
            case .favorites: return "收藏"
            case .myPlaylists: return "我的歌单"
            // B 组「创作」与 D 组「我的创作」是同一目的地（08）⇒ 高亮资产组那条：
            // 08 列的是"我的"会话，选中态标在它身上才是实话。
            case .aiSessions, .aiSession: return "我的创作"
            case .membership: return "会员"
            case .enterprise: return "企业服务"
            case .settings, .artist: return nil
            }
        }
        switch session.tab {
        case .home: return "首页"
        case .library: return "曲库"
        case .mine: return nil   // 11「我的」不是抽屉的导航项（G 区卡片才是它的入口）
        }
    }

    private func select(_ item: DrawerItem) {
        session.drawerOpen = false        // §1：选中任一导航项自动关闭
        switch item.destination {
        case .tab(let tab):
            session.tab = tab
        case .route(let route):
            session.path.append(route)
        case .gated(let route):
            // 游客点需要登录的入口 → 弹登录（17-S6），不是静默禁用。
            if session.requireLoginForCollections() { session.path.append(route) }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = session.toast {
            CovaToast(message: toast.message, isError: toast.isError)
                .padding(.top, CovaSpace.lg)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 游客态首页门控：匿名可浏览曲库/首页，但「我的」与播放上报需要登录；
/// 这里给一条明确的登录入口而不是静默禁用（design 10）。
public struct LoginGate: View {
    @Environment(AppSession.self) private var session
    private let catalog: CatalogService
    public init(catalog: CatalogService) { self.catalog = catalog }

    public var body: some View {
        ZStack(alignment: .bottom) {
            HomeView(catalog: catalog)
            VStack(spacing: CovaSpace.md) {
                Text("登录后可播放完整曲目与收藏").font(CovaType.callout).foregroundStyle(CovaColor.fg)
                CovaButton("邮箱登录") { session.loginPresented = true }
            }
            .padding(CovaSpace.lg)
            .covaGlass(elevated: true)
            .padding(CovaSpace.pageGutter)
        }
    }
}

// MARK: - 04 抽屉的施工件（顶栏触发钮 / 分组项 / 行 / G 区卡片）

/// 抽屉里反复出现、但 `design/tokens.json` **还没有档位**的几何值。
/// 集中成命名常量而不是在十几处散落字面量：缺口裁决落 token 时只改这一处。
/// （04「Token 缺口」TG-03 最小触控 / TG-04 描边与指示条 / TG-05 头像尺寸，均未入库。）
private enum DrawerMetrics {
    /// 最小触控目标 44（§6「逐一确认 ≥44pt」）。
    static let touchMin: CGFloat = 44
    /// 头像显示尺寸 44（§3.G）。
    static let avatarSize: CGFloat = 44
    /// 选中竖条宽 2（§3.B，与 components §7 词条行同规格）。
    static let indicatorWidth: CGFloat = 2
    /// 分隔线/描边 1pt（§3.A/C/E/F）。
    static let hairline: CGFloat = 1
    /// 主按钮高 50（§4「登录」主钮；TG-07 按钮高度档未入库）。
    static let primaryControlHeight: CGFloat = 50
}

/// 04 §1 入口①：顶层屏顶栏左上的**字标钮**（01 `HomeView` / 03 `LibraryView` 各一枚，
/// `placement: .topBarLeading`）。抽屉在根视图的 overlay 里、触发钮在各屏的 toolbar 里，
/// 两者不在同一棵视图树上，所以"是谁开的"记在 `AppSession.drawerOpener`（见该处注释）。
///
/// **为什么不画 logo 图**：`design/assets/CovaAssets.xcassets` 里只有 `AppIcon`，没有 01 §1
/// 顶栏那枚 28pt 品牌 logo 的 image set（TG-02 也未裁决）⇒ 拿 SF Symbol 冒充官方资产是
/// design/README 的红线（04 §3.A 抽屉顶栏同一处已经按这条不画）。所以这一枚与抽屉顶栏用
/// **同一个字标**：`CovaType.headline` / `CovaColor.fg`（04 §3.A 字标规格），logo 资产到位后
/// 只换 `label` 里这一段，热区与归还逻辑不动。
///
/// 04 §6 后半句的归还：只有 `session.drawerOpener == opener` 的那一枚在抽屉关闭时把
/// VoiceOver 焦点接回自己 —— 走查键打开的抽屉（`drawerOpener` 恒 nil）不归还，
/// 因为那一回确实没有触发者，假装归还就是对着验收谎报做了做不到的事。
struct DrawerTrigger: View {
    @Environment(AppSession.self) private var session
    @AccessibilityFocusState private var focused: Bool
    private let opener: AppSession.DrawerOpener

    init(opener: AppSession.DrawerOpener) { self.opener = opener }

    var body: some View {
        Button { session.openDrawer(from: opener) } label: {
            Text("Cova")
                .font(CovaType.headline)
                .foregroundStyle(CovaColor.fg)
                // 04 §3.A / TG-03：字标的显示宽度不当事务热区 ⇒ 触控区 ≥44×44。
                .frame(
                    minWidth: DrawerMetrics.touchMin, minHeight: DrawerMetrics.touchMin
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开导航抽屉")
        .accessibilityFocused($focused)
        .onChange(of: session.drawerOpen) { _, open in
            guard !open, session.drawerOpener == opener else { return }
            focused = true
        }
    }
}

/// 抽屉的一条导航项。文案取自 04 §8 的固定清单（禁改），分组与目的地取自 §1/§2。
private struct DrawerItem: Identifiable {
    enum Group { case main, assets, commerce }
    enum Destination {
        case tab(AppSession.Tab)
        case route(AppSession.Route)
        /// 需要登录的入口：游客点 → 弹登录（17-S6），不是静默禁用、也不是只弹 Toast。
        case gated(AppSession.Route)
    }

    let label: String
    let symbol: String
    let group: Group
    let destination: Destination
    /// 会员/企业的语义色**由这一格说了算**，不再比 `label == 「会员」`那种显示文案：
    /// 那四处（图标/文字/底/描边）会把一次纯文案修改（「会员」→「会员中心」）静默变成企业蓝，
    /// 而加第三个商业入口会默认吃蓝（第 20 轮 R20-7，`DrawerItem` 当时零覆盖）。
    var isMembership = false

    var id: String { label }
    /// §3.B：AI 渐变**只**给「创作」这一项文字，其余任何导航项不得出现渐变。
    var isAIGradient: Bool { group == .main && label == "创作" }
    /// §3.F：商业组两项统一在右侧显 `arrow.up.right.square`（外链语义）。
    var showsExternalArrow: Bool { group == .commerce }

    /// 用 `static var`（每次取一份）而不是 `static let`：`Destination` 带着 public 的
    /// `AppSession.Route`，整张表在 Swift 6 严格并发下不是 `Sendable` 的全局量。
    static var main: [DrawerItem] {
        [
            .init(label: "首页", symbol: "house", group: .main, destination: .tab(.home)),
            .init(label: "曲库", symbol: "music.note", group: .main, destination: .tab(.library)),
            .init(label: "歌单", symbol: "list.bullet", group: .main, destination: .route(.plaza)),
            // 「创作」→ 08 会话列表：PRD 4.1 的游客可浏览清单（01/03/05/06/07/16）**不含 08**
            // ⇒ 与 D 组「我的创作」同口径，游客点了弹登录。
            .init(label: "创作", symbol: "sparkles", group: .main, destination: .gated(.aiSessions)),
        ]
    }

    /// D 我的资产组（§3.D）。
    ///
    /// **「已下载」这一项在 D12 合规放行前整项不渲染** —— 不是置灰、不是 disabled、
    /// 也不是 hidden，而是**这条数据本身不存在**：它既不在视图树里，也不在 VoiceOver 的
    /// 元素序列里（§6 末条 + §9 判据要用辅助功能检查器取证，只有"不构造"能同时满足两处）。
    /// 此前抽屉里有它、15 设置里没有 ⇒ 两处口径打架（HANDOVER D′#10），已按 §3.D 收敛。
    static var assets: [DrawerItem] {
        [
            .init(label: "收藏", symbol: "heart", group: .assets, destination: .gated(.favorites)),
            .init(label: "我的歌单", symbol: "list.bullet", group: .assets, destination: .gated(.myPlaylists)),
            .init(label: "我的创作", symbol: "sparkles", group: .assets, destination: .gated(.aiSessions)),
        ]
    }

    static var commerce: [DrawerItem] {
        [
            .init(label: "会员", symbol: "star.fill", group: .commerce, destination: .route(.membership),
                  isMembership: true),
            .init(label: "企业服务", symbol: "building.2", group: .commerce, destination: .route(.enterprise)),
        ]
    }
}

/// 抽屉的一行（§3.B 项规格 + §6 可访问性）。
private struct DrawerRow: View {
    @Environment(\.covaAXLayout) private var axLayout
    private let item: DrawerItem
    private let selected: Bool
    private let action: () -> Void

    init(item: DrawerItem, selected: Bool, action: @escaping () -> Void) {
        self.item = item
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CovaSpace.md) {
                Image(systemName: item.symbol)
                    // 图标字号走文本档：固定 `.system(size:)` **不跟随 Dynamic Type**，
                    // 放大档下会出现"文字涨了、图标没涨"的错位。
                    .font(CovaType.body)
                    .foregroundStyle(iconTint)
                    // §6 组合标签：整行一个元素，图标不单独占一停。
                    .accessibilityHidden(true)
                label
                    .font(CovaType.body)
                    // §6：AX 档下 B/D/F 组项文字允许换 2 行；
                    // `fixedSize` 只钉**纵向** ⇒ 放大的文字由换行消化，而不是把抽屉撑出
                    // 横向溢出（§9 判据「AX5 档无横向溢出」）。
                    .lineLimit(axLayout ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CovaSpace.sm)
                if item.showsExternalArrow {
                    Image(systemName: "arrow.up.right.square")
                        .font(CovaType.body)
                        .foregroundStyle(CovaColor.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, CovaSpace.md)      // §3.B 水平内边距 md
            .padding(.vertical, CovaSpace.md)        // §3.B 行高 = 内容 + 上下 md
            .frame(
                maxWidth: .infinity, minHeight: DrawerMetrics.touchMin,
                alignment: .leading
            )
            .background(rowFill)
            .clipShape(RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous))
            .overlay {
                if let rowBorder {
                    RoundedRectangle(cornerRadius: CovaRadius.control, style: .continuous)
                        .strokeBorder(rowBorder, lineWidth: DrawerMetrics.hairline)
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    // §3.B：选中项左 2pt accent 竖条（components §7 词条行同规格）。
                    Capsule().fill(CovaColor.accent)
                        .frame(width: DrawerMetrics.indicatorWidth)
                        .padding(.vertical, CovaSpace.sm)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 「创作」= `gradient.ai` 文字；其余项按 §3.B/§3.F 的纯色。
    @ViewBuilder
    private var label: some View {
        if item.isAIGradient {
            Text(item.label).foregroundStyle(CovaGradient.ai)
        } else {
            Text(item.label).foregroundStyle(textTint)
        }
    }

    private var iconTint: Color {
        switch item.group {
        case .commerce: return item.isMembership ? CovaColor.memberGold : CovaColor.enterpriseBlue
        case .main, .assets: return selected ? CovaColor.accentText : CovaColor.secondary
        }
    }

    private var textTint: Color {
        switch item.group {
        case .commerce: return item.isMembership ? CovaColor.memberGold : CovaColor.enterpriseBlue
        // §3.B：选中项文字 `color.accentText`，其余 `color.fg`。
        case .main, .assets: return selected ? CovaColor.accentText : CovaColor.fg
        }
    }

    private var rowFill: Color {
        switch item.group {
        case .commerce:
            // §3.F：会员行底 memberGoldSoft、企业行底 enterpriseBlueSoft（双主题由 token 给）。
            return item.isMembership ? CovaColor.memberGoldSoft : CovaColor.enterpriseBlueSoft
        case .main, .assets:
            return selected ? CovaColor.accentSoft : .clear
        }
    }

    private var rowBorder: Color? {
        guard item.group == .commerce else { return nil }   // §3.F：两项各 1pt 同系描边
        return item.isMembership ? CovaColor.memberGoldBorder : CovaColor.enterpriseBlueBorder
    }

    /// §6 的标签形状：`首页，标签页` / `创作，AI 创作，当前选中`。
    private var accessibilityText: String {
        var parts = [item.label]
        if case .tab = item.destination { parts.append("标签页") }
        if item.isAIGradient { parts.append("AI 创作") }
        // 商业组**不**加「前往网页」这类副标签：本 App 里这两项走的是应用内 13/14
        // （04 §1 互链表），说「前往网页」就是对着用户撒谎。外链语义由 §3.F 的箭头图标表达。
        if selected { parts.append("当前选中") }
        return parts.joined(separator: "，")
    }
}

/// 04 §3.G 底部「我的」卡片。数据**只**来自 `AppSession` 里那一份 `/me`（与 11「我的」同源）。
///
/// §7 的可空字段规则全是「不渲染」，一条都不许编：
/// · `creditsBalance` 还没回来 → 数值位显 §4 钉的未知占位 `--`，**绝不显 0**
///   （0 与「无数据」在扣费语境下是两件事，显 0 就是误导）；
/// · `plan` 还没回来 → 套餐徽标整枚不渲染；
/// · `covaId` 缺 → 次行整行不渲染（不留 `--` 占位），而且**不拿 `user.id` 冒充 covaId**；
/// · 契约无 `avatar` 字段 → 头像恒为首字母占位，不猜字段。
///
/// §6：AX 档下整卡改**纵向堆叠**（设置钮右上角绝对定位）、名字允许 2 行。
private struct DrawerAccountCard: View {
    @Environment(\.covaAXLayout) private var axLayout
    private let session: AppSession

    init(session: AppSession) { self.session = session }

    var body: some View {
        Group {
            if let user = session.meUser {
                signedIn(user)
            } else {
                guest
            }
        }
        .padding(CovaSpace.lg)                     // §3.G 内边距 spacing.lg
        .frame(maxWidth: .infinity, alignment: .leading)
        // §3.G `material.glass`（与会话卡/MiniPlayer 同语汇）。阴影档
        // `elevation.glassButtonShadow*` 在 CovaUI 里还没有对应物 ⇒ 没加，不自造投影参数。
        .covaGlass(elevated: true)
        // §6 朗读顺序第 10 项：「我的卡片」是这一块的容器名。
        .accessibilityElement(children: .contain)
        .accessibilityLabel("我的卡片")
    }

    // MARK: authenticated

    @ViewBuilder
    private func signedIn(_ user: AuthUser) -> some View {
        let name = displayName(user)
        VStack(alignment: .leading, spacing: CovaSpace.sm) {
            HStack(alignment: .center, spacing: CovaSpace.md) {
                avatar(initial: String(name.prefix(1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                        // §8 单行截断；§6 AX 档允许 2 行。
                        .lineLimit(axLayout ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if let identity = identityLine(user) {
                        Text(identity.value)
                            // §3.G：covaId 走 `type.mono`（tabular-nums），邮箱走 `type.subhead`。
                            .font(identity.isCovaID ? CovaType.mono : CovaType.subhead)
                            .foregroundStyle(CovaColor.secondary)
                            .lineLimit(axLayout ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            // §6：covaId 读作「Cova 身份编号，X」，不把符号逐字符念出来。
                            .accessibilityLabel(identity.isCovaID ? "Cova 身份编号，\(identity.value)" : identity.value)
                    }
                }
                // AX 档给设置钮让出右侧 44pt：让出的是**文字行宽**，不是整行高度。
                .padding(.trailing, axLayout ? DrawerMetrics.touchMin : 0)
                if !axLayout {
                    Spacer(minLength: CovaSpace.sm)
                    settingsButton
                }
            }
            if axLayout {
                // §6：余额胶囊与徽标**换行**堆叠。
                balanceBlock
                planBadge
            } else {
                HStack(spacing: CovaSpace.sm) {
                    balanceBlock
                    planBadge
                    Spacer(minLength: 0)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if axLayout { settingsButton }   // §6：设置钮右上角绝对定位
        }
    }

    /// 余额胶囊 + 「未同步」降级腿。§4：`me` 失败 → **行内**降级，
    /// 不弹 Toast、不整屏错误（抽屉是导航容器，错误不得阻塞导航）。
    @ViewBuilder
    private var balanceBlock: some View {
        HStack(spacing: CovaSpace.xs) {
            balancePill
            if session.meState == .outOfSync {
                Text("未同步").font(CovaType.caption).foregroundStyle(CovaColor.muted)
                retryButton
            }
        }
    }

    private var balancePill: some View {
        // §3.G：`radius.capsule` + `color.surface` 底 + `type.caption`/`accentText` 字，
        // 数值走 `type.mono`。**只读展示**（D12）：无点击态、无「充值」副文案。
        let balance = session.me.map { String($0.entitlements.creditsBalance) } ?? Self.unknownValue
        return HStack(spacing: CovaSpace.xs) {
            Text("co").font(CovaType.caption)
            Text(balance).font(CovaType.mono).monospacedDigit()
        }
        .foregroundStyle(CovaColor.accentText)
        .padding(.horizontal, CovaSpace.md)
        .padding(.vertical, CovaSpace.xs)
        .background(Capsule().fill(CovaColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            balance == Self.unknownValue ? "余额未同步，仅展示" : "余额 \(balance) co，仅展示"
        )
    }

    @ViewBuilder
    private var planBadge: some View {
        // §7：`plan` 缺 → 整枚不渲染（`/me` 没回来时就属此列）。
        if let plan = session.me?.entitlements.plan {
            let name = plan.userLabel
            Text(name)
                .font(CovaType.caption)
                .foregroundStyle(foreground(for: plan))
                .padding(.horizontal, CovaSpace.sm)
                .padding(.vertical, CovaSpace.xs)
                .background(Capsule().fill(background(for: plan)))
                .overlay(
                    Capsule().strokeBorder(border(for: plan), lineWidth: DrawerMetrics.hairline)
                )
                .accessibilityLabel("当前套餐 \(name)")
        }
    }

    private func foreground(for plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlue
        case .free: return CovaColor.muted
        case .creator, .pro: return CovaColor.memberGold
        }
    }

    private func background(for plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlueSoft
        case .free: return .clear
        case .creator, .pro: return CovaColor.memberGoldSoft
        }
    }

    private func border(for plan: CovaPlan) -> Color {
        switch plan {
        case .enterprise: return CovaColor.enterpriseBlueBorder
        case .free: return CovaColor.muted          // components §9：free = 描边 muted
        case .creator, .pro: return CovaColor.memberGoldBorder
        }
    }

    // MARK: guest（§4 未登录换态）

    private var guest: some View {
        VStack(alignment: .leading, spacing: CovaSpace.md) {
            HStack(spacing: CovaSpace.md) {
                avatar(initial: "")      // §4：头像位 = `color.surface` 占位
                Text("登录解锁创作与收藏")   // §8 固定文案
                    .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    .lineLimit(axLayout ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CovaSpace.sm)
            }
            // §4：未登录 → 余额胶囊与套餐徽标**不渲染**（上面那两枚在这里根本不被构造）。
            // 「登录」主钮按 §3.G/§4 的原文用 `gradient.brandButton` + 白字 + 50pt 高，
            // 而不是全站那颗 `CovaButton`（accent 实心 / 44 高）：04 给这一屏钉的就是渐变主钮，
            // 而反过来私改公共按钮组件会连带动到 12 屏的既有观感。50pt 属 TG-07（按钮高度档
            // 未入库）⇒ 收进 `DrawerMetrics`，不散落裸字面量。
            loginButton
            Button("先逛逛") { session.drawerOpen = false }
                .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: DrawerMetrics.touchMin)
            // 「先逛逛」= §4 的关闭抽屉；「登录」那条不关（见 `loginButton`）。
        }
    }

    // MARK: 零件

    private func avatar(initial: String) -> some View {
        // §3.G + §7：契约无 `avatar` 字段 ⇒ v1.0 恒为首字母占位（surface 底 + accentText 字）。
        ZStack {
            Circle().fill(CovaColor.surface)
            if !initial.isEmpty {
                Text(initial).font(CovaType.headline).foregroundStyle(CovaColor.accentText)
            }
        }
        .frame(width: DrawerMetrics.avatarSize, height: DrawerMetrics.avatarSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("用户头像")   // §6 朗读顺序第 10 项的第一个子元素
        // 游客态那枚是**纯占位**（§4），§6 的朗读顺序里也没有它 ⇒ 不进元素序列。
        .accessibilityHidden(initial.isEmpty)
    }

    /// 「登录」主钮 → 10（§4：`gradient.brandButton` + 白字，高 50）。
    /// 点它**不关抽屉**：§4 authenticated 要求从 10 回跳时抽屉保持打开，便于继续点资产项。
    private var loginButton: some View {
        Button { session.loginPresented = true } label: {
            Text("登录")
                .font(CovaType.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: DrawerMetrics.primaryControlHeight)
                .background(CovaGradient.brandButton, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button {
            session.drawerOpen = false
            session.path.append(.settings)
        } label: {
            Image(systemName: "gearshape")
                .font(CovaType.body)
                .foregroundStyle(CovaColor.secondary)
                .frame(width: DrawerMetrics.touchMin, height: DrawerMetrics.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设置")
    }

    private var retryButton: some View {
        Button { Task { await session.loadMe(force: true) } } label: {
            Image(systemName: "arrow.clockwise")
                .font(CovaType.body)
                .foregroundStyle(CovaColor.accentText)
                .frame(width: DrawerMetrics.touchMin, height: DrawerMetrics.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("重试")
    }

    /// §7：`name` 空 → 回落 `email`；两者都空 → 「Cova 用户」。
    private func displayName(_ user: AuthUser) -> String {
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? "Cova 用户" : email
    }

    /// §7：次行 covaId 优先，其次邮箱；**两个都没有就整行不渲染**（不留 `--`，
    /// 免得用户以为账号异常）。`user.id` 不是 covaId，不参与回落。
    private func identityLine(_ user: AuthUser) -> (value: String, isCovaID: Bool)? {
        let covaId = user.covaId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !covaId.isEmpty { return (covaId, true) }
        let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? nil : (email, false)
    }

    /// 「/me 还没回答」的数值占位（04 §4 钉的 `--`；TG-29「数值占位符」档未入库）。
    private static let unknownValue = "--"

}
