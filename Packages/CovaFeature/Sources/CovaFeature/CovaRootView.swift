import CovaCore
import CovaUI
import SwiftUI

/// 根视图（04 §1：**原生 `TabView` 外壳** · 四页签 · 每页签一棵 `NavigationStack`
/// · `tabViewBottomAccessory` 迷你播放条 · 全屏播放器/登录/曲目详情 = 外壳级 sheet）。
/// 抽屉与自绘底栏已按 04 §5 对照表移除；各屏顶栏不再有品牌字标钮。
/// 登录态门控：游客照常进壳（首页/曲库可浏览），创作/我的页签根走 17-S6 引导形态。
public struct CovaRootView: View {
    @State private var session = AppSession(previewTab: previewTab())
    private let themeMode: CovaThemeMode

    public init(themeMode: CovaThemeMode = .system) {
        self.themeMode = themeMode
    }

    /// 预览/走查钩子（**仅**模拟器走查用，文档登记于 §14）：
    /// `COVA_PREVIEW_TAB=home|library|studio|mine|search` 决定首屏页签，便于逐屏截图；生产不设置即默认 home。
    static func previewTab() -> AppSession.Tab {
        let raw = ProcessInfo.processInfo.environment["COVA_PREVIEW_TAB"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_TAB")
        switch raw {
        case "library": return .library
        case "studio": return .studio
        case "mine": return .mine
        case "search": return .search
        default: return .home
        }
    }

    /// 预览/走查钩子 2（同一性质）：`COVA_PREVIEW_SHEET=login|player` 在 bootstrap 之后直接展开
    /// 对应 sheet —— 登录页与全屏播放器没有页签入口，不这样就没法逐屏截图。
    /// `player` 受 04 §4「无播放任务 ⇒ 02 不可打开」约束：快照无任务时**不** present。
    private static func previewSheet() -> String? {
        ProcessInfo.processInfo.environment["COVA_PREVIEW_SHEET"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_SHEET")
    }

    /// 走查钩子 3：`COVA_PREVIEW_ROUTE=…` 直接落到某一屏（详情/列表页都在页签根屏之下，
    /// 需要点击才能到达，逐屏走查要一个「直达」入口）。落点一律走 `navigate(to:)`：
    /// 归属表（04 §3）决定它进哪棵栈、是否切页签，不走查 `push` 的那条同栈捷径。
    static func previewRoute() -> AppSession.Route? {
        let raw = ProcessInfo.processInfo.environment["COVA_PREVIEW_ROUTE"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_ROUTE")
        guard let raw else { return nil }
        switch raw {
        case "favorites": return .favorites
        case "myPlaylists": return .myPlaylists
        case "myCreations": return .myCreations
        case "plaza": return .plaza
        // 03 复用件的走查腿：不带条件的库列表（预填各支走 `COVA_PREVIEW_FILTER` / `plazaSearch:`）。
        case "library": return .library(nil)
        case "settings": return .settings
        case "aiSessions": return .aiSessions
        // 19 创作台：`simctl` 不提供点击 ⇒ 没有这一格，19 进不了
        // 逐屏走查的截图集合，A3/A14 的「屏上真条目」就没法取证。
        case "studioCreate": return .studioCreate
        // 20 我的作品：同一条理由（`simctl` 不给点击），A5/A6 的零扣费验收腿要靠它
        // 到达已存在的作品行。
        case "worksList": return .worksList(jobID: nil)
        // 22 积分流水：同一条理由（`simctl` 不给点击），A9 的屏上证据要靠它。
        case "creditsLedger": return .creditsLedger
        case "membership": return .membership
        case "enterprise": return .enterprise
        default:
            if raw.hasPrefix("playlist:") { return .playlist(String(raw.dropFirst("playlist:".count))) }
            if raw.hasPrefix("plazaSearch:") {
                return .plazaSearch(String(raw.dropFirst("plazaSearch:".count)))
            }
            if raw.hasPrefix("artist:") { return .artist(String(raw.dropFirst("artist:".count))) }
            if raw.hasPrefix("aiSession:") { return .aiSession(String(raw.dropFirst("aiSession:".count))) }
            // 分享歌单详情（§5 P3）：A14 要这一屏的深浅两张，而它没有页签入口。
            if raw.hasPrefix("sharedPlaylist:") {
                return .sharedPlaylist(String(raw.dropFirst("sharedPlaylist:".count)))
            }
            return nil
        }
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

    /// 走查钩子 4（**只为模拟器逐屏截图存在**）：`COVA_PREVIEW_LOGIN_EMAIL` +
    /// `COVA_PREVIEW_LOGIN_PASSWORD` 走**真实的两步登录**（`/login` 建凭证 → `/me` 取身份），
    /// 不是往状态里塞一个假 token。
    ///
    /// 与其他 `COVA_PREVIEW_*` 键的关键差别：**只读进程环境，刻意不接
    /// `UserDefaults`** —— 口令与凭证不许落进任何持久化索引（AGENTS 硬边界 3），
    /// `simctl launch --setenv` 的值只活在这一次进程里。任一键缺失 ⇒ 这条路径完全不存在。
    private static func previewLogin() -> (email: String, password: String)? {
        guard let email = ProcessInfo.processInfo.environment["COVA_PREVIEW_LOGIN_EMAIL"],
              let password = ProcessInfo.processInfo.environment["COVA_PREVIEW_LOGIN_PASSWORD"],
              !email.isEmpty, !password.isEmpty
        else { return nil }
        return (email, password)
    }

    /// 04 §4「无播放任务 ⇒ 02 不可打开」的唯一判据（sheet 绑定与走查钩子共用一条）：
    /// `wantsOpen` 且快照里**确实有**播放任务才 present；`hasPlaybackItem` 单独无播放态。
    static func playerSheetPresentable(wantsOpen: Bool, hasPlaybackItem: Bool) -> Bool {
        wantsOpen && hasPlaybackItem
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
            case "player":
                if Self.playerSheetPresentable(
                    wantsOpen: true, hasPlaybackItem: session.snapshot?.item != nil
                ) {
                    session.playerSheetOpen = true
                }
            default: break
            }
            if let route = Self.previewRoute() { session.navigate(to: route) }
            if let trackID = Self.previewTrackID() { session.detailTrackID = trackID }
            // 走查钩子 5：`COVA_PREVIEW_PLAY=<trackId>` 走**真实取数 + 真实播放腿**（详情 → 队列 →
            // 出声），不是往状态里塞一个假快照。为什么必须有它：02 的波形进度条、♡、次级操作行
            // 只在"有内容在播"时才存在，而 `simctl` 不提供点击 ⇒ 没有这条键，02 的截图永远停在
            // 游客空态，D23①′ 那条「已购整曲 302 → 名单桶 ⇒ 剥凭证匿名 GET」的腿
            // 也没有任何一屏能被看到。登录在上面已完成，所以这一条走的就是带凭证的那一支。
            if let playID = ProcessInfo.processInfo.environment["COVA_PREVIEW_PLAY"], !playID.isEmpty,
               let detail = try? await session.catalog.trackDetail(playID) {
                await session.play(tracks: [detail.track], at: 0)
                // ⚠️ 第一版在这里直接 `toggle()`，结果**永远停在 00:00**：`player.start` 之后状态是
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
                // "在播但 00:00"的图。
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: StudioNotifier.didTap)) { tap in
            session.handleNotificationTap(userInfo: tap.userInfo ?? [:])
        }
    }

    /// 04 §1：原生 `TabView` + 五个 `Tab`（搜索位是 `role:.search` 系统格，栏右端分隔位）；
    /// selection 走 `selectTab`（再点当前页签回根那一条在 setter 里，04 §2 末——
    /// 搜索页签同规则，栈非空时照样回根）。底栏滚动收起交给 `.onScrollDown`；
    /// MiniPlayer 落在系统的 `tabViewBottomAccessory`，无播放任务时整格不存在。
    private var mainShell: some View {
        let catalog = session.catalog
        let tabs = TabView(selection: Binding(
            get: { session.selection },
            set: { session.selectTab($0) }
        )) {
            shellTab(.home) { HomeView(catalog: catalog) }
            shellTab(.library) { LibraryView(catalog: catalog) }
            shellTab(.studio) {
                // 04 §6：创作/我的页签的游客态 = 17-S6 引导形态（页签内容区，不遮标签栏）。
                if case .signedIn = session.authPhase { AISessionsView() }
                else { GuestGuideView(tab: .studio) }
            }
            shellTab(.mine) {
                if case .signedIn = session.authPhase { MineView() }
                else { GuestGuideView(tab: .mine) }
            }
            // 04 §1/§2：`Tab(role:.search)` 由系统钉在栏右端分隔位，标题/图标系统自给
            // （04 §1 明写"传 nil 让系统给，不自造文案"）——不经过 `shellTab` 的自绘标题通道，
            // 但栈结构一致：25 屏也有自己那棵 NavigationStack（分类卡/历史/结果行在栈内 push）。
            Tab(value: AppSession.Tab.search, role: .search) {
                NavigationStack(path: session.pathBinding(for: .search)) {
                    SearchTabView(catalog: catalog)
                        .navigationDestination(for: AppSession.Route.self) { route in
                            routeView(route)
                        }
                }
                .safeAreaInset(edge: .bottom) { toastOverlay }
            }
        }
        .tint(CovaColor.accent)
        .tabBarMinimizeBehavior(.onScrollDown)

        // 空 accessory 的隐藏分两个运行时代码档（2026-10-01 截图实测钉死）：
        // · 26.0 系统对「内容为空」的 accessory 自动收壳（不画胶囊）——只挂内容闭包即可；
        // · 26.1 起规则改了：空内容仍画出一条空胶囊壳（26.5 模拟器全屏实测），必须走
        //   `isEnabled:` 显式隐藏。它是 26.1 API 而部署目标钉在 26.0 ⇒ 用 `#available`
        //   静态分流；可用性在进程内不会换边，两条分支的 TabView 身份稳定。
        // 判据仍是 04 §4 那条：无播放任务 ⇒ accessory 不出现，02 也不可打开。
        return Group {
            if #available(iOS 26.1, *) {
                tabs.tabViewBottomAccessory(isEnabled: session.snapshot?.item != nil) {
                    MiniPlayerView()
                }
            } else {
                tabs.tabViewBottomAccessory {
                    if session.snapshot?.item != nil { MiniPlayerView() }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { Self.playerSheetPresentable(
                wantsOpen: session.playerSheetOpen,
                hasPlaybackItem: session.snapshot?.item != nil) },
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
    }

    /// 一个页签 = `Tab` + 自己那棵 `NavigationStack`（`pathBinding(for:)` 各栈一份，
    /// `navigationDestination` 四栈同一张表，落哪棵栈由 `Route.owningTab` 决定）。
    /// 返回值是 `some TabContent`（`Tab` 只 conform `TabContent`，不是 `View`）；
    /// 因此提示条的 `safeAreaInset` 挂在栈内容**之内**而不是 `Tab` 上 ——
    /// C5（2026-10-01）续订：它随原生标签栏的 inset 走 ⇒ 落在 MiniPlayer accessory 与
    /// 标签栏**之上**、任意导航屏之内（栈内 push 屏共享同一 inset 区）；盖在 accessory
    /// 之上是 04 §4 层序条款的落点。
    private func shellTab<Content: View>(
        _ tab: AppSession.Tab, @ViewBuilder root: () -> Content
    ) -> some TabContent<AppSession.Tab> {
        Tab(tab.title, systemImage: tab.symbol, value: tab) {
            NavigationStack(path: session.pathBinding(for: tab)) {
                root().navigationDestination(for: AppSession.Route.self) { route in
                    routeView(route)
                }
            }
            .safeAreaInset(edge: .bottom) { toastOverlay }
        }
    }

    /// 四棵栈共用的一张目的地表（04 §3 归属表决定**进哪棵栈**，这里只管路由 → 屏）。
    @ViewBuilder
    private func routeView(_ route: AppSession.Route) -> some View {
        switch route {
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .sharedPlaylist(let token): SharedPlaylistView(token: token)
        case .favorites: FavoritesView()
        case .myPlaylists: MyPlaylistsView()
        case .myCreations: MyCreationsView()
        case .plaza: PlaylistsPlazaView()
        case .plazaSearch(let query): PlaylistsPlazaView(searchQuery: query)
        /// 03 §7：路由载荷直传（一层一份）；`pendingLibraryPreset` 那条旧腿由屏内 `consume` 接着。
        case .library(let preset): LibraryView(catalog: session.catalog, preset: preset)
        case .settings: SettingsView()
        case .aiSessions: AISessionsView()
        case .aiSession(let id): AISessionDetailView(sessionID: id)
        case .studioCreate: StudioCreateView()
        case .worksList(let jobID): WorksListView(jobID: jobID)
        case .creditsLedger: CreditsLedgerView()
        case .membership: MembershipView()
        case .enterprise: EnterpriseView()
        case .artist(let id): ArtistHomeView(artistID: id)
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = session.toast {
            CovaToast(message: toast.message, isError: toast.isError)
                .padding(.bottom, CovaSpace.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 外壳里反复出现、但 `design/tokens.json` **还没有档位**的几何值。
/// 集中成命名常量而不是散落字面量：缺口裁决落 token 时只改这一处。
/// （TG-03 最小触控 / TG-07 按钮高度，均未入库。）
enum ShellMetrics {
    /// 最小触控目标 44（原 04 §6「逐一确认 ≥44pt」，现归各屏引导件）。
    static let touchMin: CGFloat = 44
    /// 主按钮高 50（原 04 §4「登录」主钮；TG-07 按钮高度档未入库）。
    static let primaryControlHeight: CGFloat = 50
}

/// 创作/我的页签的游客态根（04 §6：17-S6 引导形态出现在**页签内容区**，不遮标签栏；
/// 登录成功后停留在当前页签，不跳走）。文案三件套沿用 04 §8：「登录解锁创作与收藏」/
/// 主钮「登录」/ 次钮「先逛逛」。图标用该页签自己的 SF Symbol（图标列 04 §2）。
struct GuestGuideView: View {
    @Environment(AppSession.self) private var session
    let tab: AppSession.Tab

    var body: some View {
        VStack(spacing: CovaSpace.md) {
            Image(systemName: tab.symbol)
                .font(.largeTitle)
                .foregroundStyle(CovaColor.accentText)
                .accessibilityHidden(true)
            Text("登录解锁创作与收藏")
                .font(CovaType.headline).foregroundStyle(CovaColor.fg)
                .multilineTextAlignment(.center)
            // 「登录」按原 §4 的原文用 `gradient.brandButton` + 白字 + 50pt 高，
            // 而不是 `CovaButton`（accent 实心 / 44 高）：引导主钮的观感钉在渐变上。
            Button { session.loginPresented = true } label: {
                Text("登录")
                    .font(CovaType.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: ShellMetrics.primaryControlHeight)
                    .background(CovaGradient.brandButton, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // 「先逛逛」= 回落到游客可浏览的首页页签（创作/我的栈留在引导态）。
            Button("先逛逛") { session.selectTab(.home) }
                .font(CovaType.subhead).foregroundStyle(CovaColor.accentText)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: ShellMetrics.touchMin)
        }
        .padding(CovaSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tab.title)
        .toolbarTitleDisplayMode(.inline)
    }
}
