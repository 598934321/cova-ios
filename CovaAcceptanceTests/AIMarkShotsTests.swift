import XCTest

/// COVA-142 · 成对截图的**取图腿**（改前 / 改后各跑一次，同一入口、同一视口、同一账号状态）。
///
/// 为什么必须是 XCUITest 而不是 `simctl`：
/// 1. `simctl` 不提供点击与滑动 ⇒ 首页「新歌上架」卡带在首屏之下，够不到；
/// 2. 首页首屏那排小卡是**歌单卡**（`PlaylistCard`），不是曲目卡 —— 拿它当「网格卡」的证据
///    等于拍错了对象（这是本轮第一次拍图时踩到的：图里根本没有标识，因为那不是曲目卡）。
///
/// 零扣费、零登录：只用 `COVA_PREVIEW_*` 预览键 + 游客态，不触碰任何生成/支付链。
/// 它**不进 `Cova` scheme**（门禁不跑它），只在 `CovaAcceptance` 里按需执行。
@MainActor
final class AIMarkShotsTests: XCTestCase {
    private var app: XCUIApplication!

    /// 输出目录：运行器容器的 tmp（事后 `simctl get_app_container <udid> <runner-id> data` 取回）。
    private var outDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private func launch(_ env: [String: String]) {
        app?.terminate()
        app = XCUIApplication()
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launch()
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = outDir.appendingPathComponent("142-\(name).png")
        try? data.write(to: url)
        NSLog("COVA_142_SHOT %@ %d", url.path, data.count)
        let item = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }

    /// 等一屏「真的画出来了」：不 sleep 猜时间，而是等某个该出现的元素。
    private func waitFor(_ element: XCUIElement, _ seconds: TimeInterval = 20) -> Bool {
        element.waitForExistence(timeout: seconds)
    }

    // MARK: - 五个形态（按渲染方式取，不逐界面拍）

    /// 1. 列表卡：曲库（`CovaListRow`，7 处列表界面的共同承载点）
    func test01_ListCard() {
        launch(["COVA_PREVIEW_ROUTE": "library"])
        let title = app.staticTexts["曲库"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "曲库页没起来")
        // 等「真实曲目行」而不是固定 sleep：冷启动时 6s 只拍到骨架屏（深色轮实拍踩过，
        // 骨架屏里没有标识可量，等于白拍）。曲目行副标题固定含「BPM」。
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "BPM")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "曲库行 30s 未加载（仍是骨架屏）")
        sleep(2)
        shot("list")
    }

    /// 2. 网格/卡带卡：首页「新歌上架」（`HomeTrackCard`，140pt 封面角标形态）。
    ///    必须滑到那一区 —— 首屏那排是歌单卡，不是曲目卡。
    func test02_GridCard() {
        launch(["COVA_PREVIEW_TAB": "home"])
        sleep(8)
        let newest = app.staticTexts["新歌上架"]
        for _ in 0 ..< 6 where !newest.exists {
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(newest.exists, "首页没有「新歌上架」区块 ⇒ 无法取网格卡形态")
        app.swipeUp()                  // 让卡带整体进入视口
        sleep(2)
        shot("grid")
    }

    /// 3. 歌单详情：曲目行 + 头部
    func test03_PlaylistDetail() {
        launch(["COVA_PREVIEW_ROUTE": "playlist:PL-20261016-09"])
        XCTAssertTrue(waitFor(app.buttons["播放全部"], 30) || waitFor(app.staticTexts["播放全部"], 10))
        sleep(3)
        app.swipeUp()                  // 头部封面占满首屏，往下滚一行才看得到曲目行
        sleep(2)
        shot("playlist")
    }

    /// 4. 播放器（L2 整句）
    func test04_Player() {
        launch(["COVA_PREVIEW_PLAY": "library-b6e21e004d106540d0e116e1"])
        let pause = app.buttons["暂停"]
        let play = app.buttons["播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30) || play.waitForExistence(timeout: 5),
                      "播放器没起来（既无暂停钮也无播放钮）")
        sleep(4)
        shot("player")
    }

    /// 5. 详情 sheet（L2 整句）
    func test05_TrackDetailSheet() {
        launch(["COVA_PREVIEW_ROUTE": "track:library-b6e21e004d106540d0e116e1"])
        sleep(8)
        shot("detail")
    }

    /// 6. 歌词面板（L2 整句）—— 作品侧唯一能零扣费到达的 L2 面。
    func test06_LyricsPanel() {
        launch(["COVA_PREVIEW_ROUTE": "worksList"])
        sleep(8)
        shot("works")
    }
}
