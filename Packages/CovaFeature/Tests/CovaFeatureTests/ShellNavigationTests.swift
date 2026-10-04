@testable import CovaFeature
import XCTest

/// 04 §1/§2/§3/§6 外壳导航的判据（TabView 四页签 + 每页签独立栈）。
///
/// 这一层只钉**纯导航事实**：归属表、push/navigate 的栈归属、点当前页签回根、
/// 「切换不清另一页签的栈」误触保护、通知深链落创作栈、登出回落。视图装配
/// （`Tab`/`NavigationStack` 怎么挂）不在覆盖内 —— 能骗人而又钉得住的都在这里。
@MainActor
final class ShellNavigationTests: XCTestCase {

    // MARK: 04 §3 归属表（这张表的唯一来源是 `Route.owningTab`）

    func testOwningTabMatchesTheSpecTable() {
        // 首页栈
        XCTAssertEqual(AppSession.Route.playlist("p").owningTab, .home)
        XCTAssertEqual(AppSession.Route.sharedPlaylist("t").owningTab, .home)
        XCTAssertEqual(AppSession.Route.plaza.owningTab, .home)
        // 我的栈
        for route: AppSession.Route in [
            .favorites, .myPlaylists, .myCreations, .creditsLedger,
            .membership, .enterprise, .settings,
        ] {
            XCTAssertEqual(route.owningTab, .mine, "\(route) 应归「我的」栈")
        }
        // 创作栈
        for route: AppSession.Route in [.aiSessions, .aiSession("s"), .studioCreate, .worksList(jobID: nil)] {
            XCTAssertEqual(route.owningTab, .studio, "\(route) 应归「创作」栈")
        }
        // 唯一留当前栈的：艺人页与 03 复用件（01↔03↔25 各有入口，页签不切换）
        XCTAssertNil(AppSession.Route.artist("a").owningTab)
        // 04 §3 修订（2026-10-02）：`.library` 同属「当前栈 push」那一族
        // （25 分类卡 / 01 搜索档目标=曲库都从发起栈内 push，不切页签）。
        XCTAssertNil(AppSession.Route.library(nil).owningTab)
        XCTAssertNil(AppSession.Route.library(.init(search: "钢琴")).owningTab)
        // 01 搜索档目标=歌单：`plazaSearch` 归属与 `.plaza` 同栈（首页栈内 push 05）。
        XCTAssertEqual(AppSession.Route.plazaSearch("咖啡馆").owningTab, .home)
        // 根屏标记：今天只有 08 会话列表是页签根屏本身
        XCTAssertTrue(AppSession.Route.aiSessions.isTabRoot)
        XCTAssertFalse(AppSession.Route.aiSession("s").isTabRoot)
    }

    // MARK: push = 同栈直推

    func testPushAppendsToCurrentTabStackOnly() {
        let session = AppSession()
        session.push(.playlist("p1"))
        XCTAssertEqual(session.paths[.home] ?? [], [.playlist("p1")])
        XCTAssertEqual(session.selection, .home, "同栈 push 不切页签")
        XCTAssertTrue(session.paths[.mine] == nil || session.paths[.mine]!.isEmpty)
    }

    func testPushOfRouteOwnedByAnotherTabRedirectsToNavigate() {
        // 「写错归属」不是可能项：push 一个别栈路由 ⇒ 自动改走 navigate
        // （04 §3：一条路由的归属只有一个答案）。
        let session = AppSession()
        session.push(.aiSession("s9"))
        XCTAssertEqual(session.selection, .studio)
        XCTAssertEqual(session.paths[.studio] ?? [], [.aiSession("s9")])
        XCTAssertEqual(session.paths[.home] ?? [], [])
    }

    // MARK: navigate = 跨页签（目的栈先回根 → 切 selection → push）
    // 注意两条边界都是实现钉死的：跨页签才清目的栈；**同页签** navigate = 普通入栈
    // （唯一例外是 `isTabRoot` 路由，见 testNavigateToTabRootScreenPopsInsteadOfStacking）。

    func testNavigateSwitchesTabAndClearsDestinationStack() {
        let session = AppSession()
        session.selectTab(.studio)
        session.push(.aiSession("old"))               // 创作栈上有旧内容
        session.selectTab(.mine)
        session.navigate(to: .aiSession("s1"))
        XCTAssertEqual(session.selection, .studio)
        XCTAssertEqual(
            session.paths[.studio] ?? [], [.aiSession("s1")],
            "目的栈先回根：旧屏不留在路由下面"
        )
    }

    func testNavigateWithinSameTabAppendsLikePush() {
        // 同页签的 navigate 不清栈（08 会话 → 09 详情这条腿靠它才能「返回」回列表）。
        let session = AppSession()
        session.selectTab(.studio)
        session.navigate(to: .aiSession("s1"))
        session.navigate(to: .aiSession("s2"))
        XCTAssertEqual(session.paths[.studio] ?? [], [.aiSession("s1"), .aiSession("s2")])
        XCTAssertEqual(session.selection, .studio)
    }

    func testNavigateKeepsOtherStacksUntouched() {
        // §8 误触保护：切换**不清**另一页签的栈 —— 深链去创作栈时，「我的」栈原样留住。
        let session = AppSession()
        session.selectTab(.mine)
        session.push(.settings)
        session.selectTab(.home)
        session.navigate(to: .aiSession("s1"))
        XCTAssertEqual(session.paths[.mine] ?? [], [.settings])
        XCTAssertEqual(session.paths[.home] ?? [], [])
    }

    func testNavigateToTabRootScreenPopsInsteadOfStacking() {
        // `.aiSessions` 是创作页签的根屏（isTabRoot）：navigate 到它 = 回根，
        // 同栈也要弹空 —— 不许在 08 上再叠一层 08。
        let session = AppSession()
        session.selectTab(.studio)
        session.push(.aiSession("s1"))
        session.navigate(to: .aiSessions)
        XCTAssertEqual(session.paths[.studio] ?? [], [])
        XCTAssertEqual(session.selection, .studio)
    }

    // MARK: pop / goToTabRoot / selectTab

    func testPopRemovesOnlyTheTopRoute() {
        let session = AppSession()
        session.push(.playlist("p1"))
        session.push(.playlist("p2"))
        session.pop()
        XCTAssertEqual(session.paths[.home] ?? [], [.playlist("p1")])
    }

    func testSelectTabRetapPopsCurrentStackOnly() {
        let session = AppSession()
        session.selectTab(.studio)
        session.push(.aiSession("s1"))
        session.selectTab(.mine)                      // 切走：创作栈不动
        XCTAssertEqual(session.paths[.studio] ?? [], [.aiSession("s1")])
        session.selectTab(.studio)                    // 切回
        session.selectTab(.studio)                    // 再点当前页签 ⇒ 该栈回根（04 §2 末）
        XCTAssertEqual(session.paths[.studio] ?? [], [])
        XCTAssertEqual(session.selection, .studio)
    }

    func testSearchTabRetapPopsItsOwnStackOnly() {
        // 25 页签同一条规则（04 §2 末没有给系统搜索位豁免）：栈内 push 的 03 复用件
        // 在再点搜索页签时回根；别的栈不动。
        let session = AppSession()
        session.selectTab(.search)
        session.push(.library(.init(dimensions: ["scene": ["咖啡馆"]], title: "咖啡馆")))
        XCTAssertEqual(session.paths[.search]?.count, 1)
        session.selectTab(.home)
        XCTAssertEqual(session.paths[.search]?.count, 1, "切走不清搜索栈")
        session.selectTab(.search)
        session.selectTab(.search)
        XCTAssertEqual(session.paths[.search] ?? [], [], "再点搜索页签回根")
    }

    func testGoToTabRootResetsTargetStackAndSwitches() {
        let session = AppSession()
        session.selectTab(.library)
        session.push(.artist("a"))
        session.goToTabRoot(.library)                 // 已在该页签：清栈，selection 不变
        XCTAssertEqual(session.paths[.library] ?? [], [])
        XCTAssertEqual(session.selection, .library)
        session.push(.artist("a"))
        session.goToTabRoot(.home)                    // 清的是**目的**栈（落在首页根）；
        XCTAssertEqual(session.selection, .home)      // 离开的那棵不动 —— §8 误触保护，
        XCTAssertEqual(                               // 切回曲库时艺人页还在
            session.paths[.library] ?? [], [.artist("a")],
            "离开的那棵栈不清：goToTabRoot 只重置目的栈"
        )
    }

    // MARK: 通知深链（04 §3 归属表最后一行）

    func testNotificationTapWithSessionIDFallsIntoStudioStack() {
        let session = AppSession()
        session.handleNotificationTap(userInfo: ["sessionId": "s-9"])
        XCTAssertEqual(session.selection, .studio)
        XCTAssertEqual(session.paths[.studio] ?? [], [.aiSession("s-9")])
    }

    func testNotificationTapWithoutSessionIDFallsBackToHome() {
        let session = AppSession()
        session.selectTab(.mine)
        session.push(.settings)
        session.handleNotificationTap(userInfo: [:])
        XCTAssertEqual(session.selection, .home)
        XCTAssertEqual(session.paths[.home] ?? [], [])
    }

    // MARK: 登出回落（04 §6：四栈回根 + selection 回首页）

    func testResetShellNavigationClearsEveryStackAndReturnsHome() {
        let session = AppSession()
        session.selectTab(.studio)
        session.push(.aiSession("s1"))
        session.selectTab(.mine)
        session.push(.settings)
        session.resetShellNavigation()
        XCTAssertEqual(session.selection, .home)
        for tab in AppSession.Tab.allCases {
            XCTAssertEqual(session.paths[tab] ?? [], [], "\(tab) 栈应已回根")
        }
    }

    // MARK: 走查钩子（`CovaRootView.previewRoute` / `playerSheetPresentable`）

    func testPreviewRouteParsesAllRegisteredKeys() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: "COVA_PREVIEW_ROUTE") }
        let cases: [(String, AppSession.Route)] = [
            ("favorites", .favorites),
            ("myCreations", .myCreations),
            ("aiSessions", .aiSessions),
            ("worksList", .worksList(jobID: nil)),
            ("playlist:p7", .playlist("p7")),
            ("aiSession:s7", .aiSession("s7")),
            ("sharedPlaylist:tk", .sharedPlaylist("tk")),
            ("artist:a7", .artist("a7")),
            ("library", .library(nil)),
            ("plazaSearch:轻音乐", .plazaSearch("轻音乐")),
        ]
        for (raw, expected) in cases {
            defaults.set(raw, forKey: "COVA_PREVIEW_ROUTE")
            XCTAssertEqual(CovaRootView.previewRoute(), expected, "键 \(raw) 应解析为 \(expected)")
        }
        defaults.set("bogus", forKey: "COVA_PREVIEW_ROUTE")
        XCTAssertNil(CovaRootView.previewRoute(), "不认识的键不许猜一条路由")
    }

    func testPlayerSheetRequiresAnActualPlaybackItem() {
        // 04 §4：无播放任务 ⇒ 02 不可打开（sheet 绑定与 `COVA_PREVIEW_SHEET=player`
        // 共用这一条判据）。
        XCTAssertFalse(
            CovaRootView.playerSheetPresentable(wantsOpen: true, hasPlaybackItem: false))
        XCTAssertFalse(
            CovaRootView.playerSheetPresentable(wantsOpen: false, hasPlaybackItem: true))
        XCTAssertTrue(
            CovaRootView.playerSheetPresentable(wantsOpen: true, hasPlaybackItem: true))
    }
}
