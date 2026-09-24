import CovaCore
import CovaUI
import SwiftUI

/// 根视图（design 04 抽屉 + 三 Tab + MiniPlayer 浮层 + 全屏播放器 sheet）。
/// 登录态门控：未登录且未选游客 → 登录页；其余进主壳。
public struct CovaRootView: View {
    @State private var session = AppSession(previewTab: previewTab())
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

    /// 与钩子 3 同批：`COVA_PREVIEW_ROUTE=track:<id>` 走的是 sheet 而不是路由栈。
    private static func previewTrackID() -> String? {
        guard let raw = previewSheetValue() else { return nil }
        return raw.hasPrefix("track:") ? String(raw.dropFirst("track:".count)) : nil
    }

    private static func previewSheetValue() -> String? {
        ProcessInfo.processInfo.environment["COVA_PREVIEW_ROUTE"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_ROUTE")
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
            switch Self.previewSheet() {
            case "login": session.loginPresented = true
            case "player": session.playerSheetOpen = true
            default: break
            }
            if let route = Self.previewRoute() { session.path.append(route) }
            if let trackID = Self.previewTrackID() { session.detailTrackID = trackID }
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
            }
        }
        .padding(.top, CovaSpace.sm)
        .padding(.bottom, CovaSpace.xs)
        .background(CovaColor.canvas.opacity(0.95))
        .overlay(alignment: .top) { Rectangle().fill(CovaColor.line).frame(height: 0.5) }
    }

    @ViewBuilder
    private var drawer: some View {
        if session.drawerOpen {
            VStack(alignment: .leading, spacing: CovaSpace.lg) {
                Text("Cova").font(CovaType.title).foregroundStyle(CovaColor.accent)
                ForEach(["收藏", "我的歌单", "我的创作", "下载管理", "会员", "设置"], id: \.self) { item in
                    Button {
                        session.drawerOpen = false
                        switch item {
                        case "收藏":
                            if session.requireLoginForCollections() { session.path.append(.favorites) }
                        case "我的歌单":
                            if session.requireLoginForCollections() { session.path.append(.myPlaylists) }
                        case "我的创作":
                            if session.requireLoginForCollections() { session.path.append(.aiSessions) }
                        case "会员":
                            session.path.append(.membership)
                        case "设置":
                            session.path.append(.settings)
                        default:
                            session.showToast("\(item)：入口已登记，该页在 M2/M3 接入")
                        }
                    } label: {
                        Text(item).font(CovaType.headline).foregroundStyle(CovaColor.fg)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(CovaSpace.xl)
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(CovaColor.elevated)
            .transition(.move(edge: .leading))
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
