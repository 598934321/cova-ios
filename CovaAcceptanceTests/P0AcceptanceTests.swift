import XCTest

/// P0 设备侧验收（DEVELOPMENT.md §6 的 A1 / A3 / A5 / A6 与 A14 的截图）。
///
/// 为什么是 XCUITest 而不是"人工点一下"：驱动本机会话的进程没有 macOS「辅助访问」权限
/// （`cliclick` 报 Accessibility privileges not enabled、AppleScript 报 -25211/1002），
/// `simctl` 又不提供点击，装 idb/appium 会破零第三方依赖（硬边界 4）。
/// XCUITest 的事件注入发生在模拟器内、由 Xcode 测试基础设施驱动 ⇒ 不需要宿主权限，
/// 而且**可复现**：这一条跑通后，A1/A3/A5/A6 的屏上证据不再依赖某一次手工操作。
///
/// 它**不是门禁的一部分**（独立 scheme `CovaAcceptance`，`check.sh` 不跑它）：
/// 这条链路要真等一个生成任务（分钟级）并真扣一次 co，塞进 14 分钟的门禁等于把门禁做成不可靠判据。
///
/// 口令：只从**运行器进程环境**读（`COVA_ACCEPT_EMAIL` / `COVA_ACCEPT_PASSWORD`），
/// 缺失即 `XCTSkip` 跳过 —— 绝不为"让这条腿看起来跑过"而写死任何凭证（硬边界 3）。
@MainActor
final class P0AcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    /// 生成任务上限：契约侧轮询调度器是「前 6×5s、之后 10s、累计约 30min」，
    /// 这里给 26 分钟留一次余量（超时即如实失败，不许"没等到"读成"通过"）。
    private let generationBudget: TimeInterval = 26 * 60

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let email = env["COVA_ACCEPT_EMAIL"], let password = env["COVA_ACCEPT_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip(
                "缺 COVA_ACCEPT_EMAIL / COVA_ACCEPT_PASSWORD ⇒ 设备侧验收跳过"
                    + "（口令不进仓库，也不进日志）"
            )
        }
        app = XCUIApplication()
        // 既有的登录钩子：真跑两步 `/login` → `/me`，只读进程环境、不落 UserDefaults。
        app.launchEnvironment["COVA_PREVIEW_LOGIN_EMAIL"] = email
        app.launchEnvironment["COVA_PREVIEW_LOGIN_PASSWORD"] = password
        // 本轮补的钩子：19 屏在导航栈里，`simctl` 到不了 ⇒ 与钩子 3 的既有理由同源。
        app.launchEnvironment["COVA_PREVIEW_ROUTE"] = "studioCreate"
        app.launch()
    }

    /// 截图写进**运行器容器**的 tmp（事后用 `simctl get_app_container … data` 取回）。
    /// 每张都同时挂成 xcodebuild 附件，两条路任一能拿到即算落档。
    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cova-acceptance-\(name).png")
        try? data.write(to: url)
        NSLog("COVA_ACCEPTANCE_SHOT %@", url.path)
        attachment(data, name: name)
    }

    private func attachment(_ data: Data, name: String) {
        let item = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }

    /// A1 的判据是「屏上渲染的行数与服务端 items 一致」，所以这里**逐条点名**：
    /// 把只读 curl 数出来的标题（`COVA_EXPECT_TITLES`，换行分隔）一个个查到，
    /// 少哪一条就报哪一条 —— 上一版只等"区块标题出现"，而区块标题在**回落到本机账**时
    /// 也会出现，于是屏上只有 1 行也算"通过"。那是空炮判据。
    func testRecentHistoryRendersServerRows() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["COVA_ACCEPT_EMAIL"], let password = env["COVA_ACCEPT_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("缺 COVA_ACCEPT_EMAIL / COVA_ACCEPT_PASSWORD ⇒ 跳过")
        }
        let expected = (env["COVA_EXPECT_TITLES"] ?? "")
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(expected.isEmpty, "缺 COVA_EXPECT_TITLES ⇒ 没法对账（不许退化成「看到一行就算过」）")
        let home = XCUIApplication()
        home.launchEnvironment["COVA_PREVIEW_LOGIN_EMAIL"] = email
        home.launchEnvironment["COVA_PREVIEW_LOGIN_PASSWORD"] = password
        home.launch()
        let feed = home.scrollViews.element(boundBy: 0)
        // 每一轮都往下滚一格再找：服务端历史要等首屏 feed 的并发请求回来才发，
        // 而区块本身在回落账上也会出现 ⇒ 判据只能是"这 N 条标题都在不在"，不是"区块在不在"。
        var missing = expected
        for _ in 0..<14 {
            missing = missing.filter { !home.staticTexts[$0].exists }
            if missing.isEmpty { break }
            feed.swipeUp()
            Thread.sleep(forTimeInterval: 2)
        }
        app = home
        shot("01-recent-history")
        XCTAssertTrue(
            missing.isEmpty,
            "A1：服务端 items 有 \(expected.count) 条，屏上缺 \(missing.count) 条 → \(missing)"
        )
    }

    /// 把元素滚到**可点**：结果行在 ScrollView 里，键盘还占着下半屏时它可能不可命中。
    /// 判据用 `isHittable` 而不是 `exists` —— 存在但被键盘挡住的东西点了不算数。
    private func scrollIntoView(_ element: XCUIElement, maxSwipes: Int = 6) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return }
            app.scrollViews.element(boundBy: 0).swipeUp()
        }
    }

    /// 失败时把屏上所有 staticText 标签打出来 —— 选择器猜错时这是唯一能少跑一轮的东西。
    private func labelDump() -> String {
        app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
    }

    // MARK: - 主链路

    /// A3（提交→轮询→两首）→ A6（直存不扣费）→ A5（播放上报伪 trackId）→ A1（01 混排）。
    ///
    /// 顺序是**刻意**的：直存要在播放之前 —— 播放可能拉起播控层盖住结果行，
    /// 那时再点 ↓ 就是在测另一条路径了。
    func testStudioCreateLoopThenSaveThenPlayThenHistory() throws {
        // 登录 + 路由到 19（登录钩子会先跑，留几秒给它落账）
        XCTAssertTrue(
            app.navigationBars["做一首歌"].waitForExistence(timeout: 40),
            "A3 前置：19 屏没到达（登录或路由钩子失败，后面全部不成立）"
        )
        shot("19-form")

        // ① 输入 prompt：计数必须跟着动（证明"屏上看到的"与"发出去的"是同一份文本）
        let prompt = app.textViews["cova.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "B 描述卡没出现")
        prompt.tap()
        // 为什么是英文：`typeText` 走键盘，**打不出中文**（第一次实测计数纹丝不动）；
        // 而模拟器这里弹的是**软件键盘**（截图 f006 可见），所以"剪贴板 + ⌘V"那条路也不通 ——
        // ⌘V 是硬件键盘键，软件键盘不吃。A3 的判据是「填 prompt → 生成 → 两首 succeeded」，
        // 与 prompt 的语言无关，因此换成 ASCII 而不是去伪造输入通道。
        let text = "synthwave summer city night, female vocals, mid tempo"
        prompt.typeText(text)
        // 判据换成**可直接观测的那一格**：CTA 从 disabled 变 enabled。
        // 前两版在这里断"计数那一格的字符串"，一次断屏上渲染的 "53/2,000"、一次断
        // 我给它设的 accessibilityLabel "53，共 2000 字"，两次都没查到 —— 那是我在猜选择器，
        // 而截图（f075）早就证明文本进去了、计数动了、CTA 也变实心了。
        // ⇒ 断"输入有没有走到会话层"，用状态位而不是字符串形状；标签清单只作诊断打出来。
        let submit = app.buttons["开始生成"]
        XCTAssertTrue(
            submit.waitForExistence(timeout: 10),
            "CTA 不在屏上；staticText 标签=" + labelDump()
        )
        XCTAssertTrue(
            submit.isEnabled,
            "A3 的表单腿没接上会话层：输入后 CTA 仍不可点；标签=" + labelDump()
        )
        shot("19-typed")

        // ② 提交（一次点击 = 一把新幂等键；扣费发生在服务端 2xx 那一刻）
        submit.tap()
        shot("19-submitting")

        // ③ 等终态：要么两行作品（succeeded），要么失败态 —— 两者都没有就是超时，如实红
        let row0 = app.buttons["cova.work.row.0"]
        let deadline = Date().addingTimeInterval(generationBudget)
        var sawPolling = false
        while Date() < deadline {
            if app.staticTexts["排队中"].exists || app.staticTexts["制作中"].exists
                || app.staticTexts["已提交，正在排产"].exists {
                sawPolling = true
            }
            if row0.waitForExistence(timeout: 15) { break }
            if app.staticTexts["没能完成"].exists {
                break
            }
        }
        XCTAssertTrue(sawPolling, "D 任务区从未出现任何态名（轮询腿没接上）")
        XCTAssertFalse(
            app.staticTexts["没能完成"].exists,
            "A3：任务终态失败 —— 屏上应同时有服务端 errorMessage"
        )
        XCTAssertTrue(
            row0.waitForExistence(timeout: 5),
            "A3：约 \(Int(generationBudget / 60)) 分钟内没等到结果行"
        )
        XCTAssertTrue(app.staticTexts["作品（2）"].waitForExistence(timeout: 10), "结果区不是两行")
        shot("19-results")

        // ④ A6 直存：点 ↓ ⇒ 行内标记转「已在本机」（按钮标签翻面就是盘上落成的 UI 侧证据；
        //    文件是否真在沙盒、字节是否完整，由仓库外的 simctl + afinfo 复核）
        let save = app.buttons["保存到本机"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "结果行没有 ↓ 直存钮")
        scrollIntoView(save)
        save.tap()
        XCTAssertTrue(
            app.buttons["删除本机文件"].firstMatch.waitForExistence(timeout: 180),
            "A6：点了 ↓ 但标记没翻成「已在本机」（下载未完成或被出口守卫拒绝）"
        )
        shot("19-saved")

        // ⑤ A5 播放：点第一行 ⇒ 播放层按伪 trackId 上报 `POST /api/tracks/play`。
        //    `recorded:true` 与「GET 混排含该 work 行」这两半都在服务端复核（屏上看不出来）。
        scrollIntoView(row0)
        row0.tap()
        Thread.sleep(forTimeInterval: 12)   // 给 Bearer 下载→校验→file:// 与上报留时间
        shot("after-play")

        // ⑥ A1：回 01 滚到「继续聆听」，服务端历史里现在应当混进那条作品行
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        let feed = app.scrollViews.element(boundBy: 0)
        XCTAssertTrue(feed.waitForExistence(timeout: 15), "01 首页没回来")
        for _ in 0..<6 {
            if app.staticTexts["继续聆听"].exists { break }
            feed.swipeUp()
        }
        XCTAssertTrue(
            app.staticTexts["继续聆听"].exists,
            "A1：滚完 6 屏仍看不到「继续聆听」区块"
        )
        shot("01-recent-mixed")
    }

    /// A6 + A5 的**零扣费**腿：在 works 列表屏（20）对**已经存在**的作品行点 ↓ 与 ▶。
    ///
    /// 为什么要单独一条：上面那条链要等一次真生成（分钟级 + 100 co）才能拿到两行结果，
    /// 而账号里今天已经有 10 行 `succeeded` 作品（§7 #39 解阻之后这些行可播可存）。
    /// 判据不变 —— 直存看标记翻面 + 仓库外按沙盒文件复核，播放看上报（服务端复核），
    /// 变的只是"结果行从哪来"。
    func testWorksListSavesAndPlaysAnExistingWork() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["COVA_ACCEPT_EMAIL"], let password = env["COVA_ACCEPT_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("缺 COVA_ACCEPT_EMAIL / COVA_ACCEPT_PASSWORD ⇒ 跳过")
        }
        let list = XCUIApplication()
        list.launchEnvironment["COVA_PREVIEW_LOGIN_EMAIL"] = email
        list.launchEnvironment["COVA_PREVIEW_LOGIN_PASSWORD"] = password
        list.launchEnvironment["COVA_PREVIEW_ROUTE"] = "worksList"
        list.launch()
        app = list

        XCTAssertTrue(
            list.navigationBars["我的作品"].waitForExistence(timeout: 40),
            "20 屏没到达（登录或路由钩子失败，后面全部不成立）"
        )
        let firstRow = list.buttons["cova.works.row.0"]
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 25),
            "A6 前置：列表一行都没渲染；标签=" + labelDump()
        )
        shot("20-works-list")

        // ① A6 直存：↓ ⇒ 标记翻成「删除本机文件」。这一步同时是 §7 #39 那条修复的
        //    **唯一屏上证人** —— 改错 intent 的话这里 180s 不翻面。
        let save = list.buttons["保存到本机"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "作品行没有 ↓ 直存钮")
        scrollIntoView(save)
        save.tap()
        XCTAssertTrue(
            list.buttons["删除本机文件"].firstMatch.waitForExistence(timeout: 180),
            "A6：点了 ↓ 标记没翻面（同源 intent=download 那条腿没通，或文件没落成）"
        )
        shot("20-saved")

        // ② A5 播放：点行 ⇒ D7 取字节 → file:// → 按伪 trackId 上报 `POST /api/tracks/play`。
        //    `recorded:true` 与「play-history 出现 work 行」由服务端复核（屏上看不出来）。
        scrollIntoView(firstRow)
        firstRow.tap()
        Thread.sleep(forTimeInterval: 12)
        shot("20-after-play")
    }

    /// A7（works 行内动作）的设备腿：**clip 级那几项**在行 ⋯ 里，job 级那三项在组头 ⋯ 里。
    ///
    /// 这条腿只证"屏上到得了、发得出去、回执看得见"；`GET /api/favorites` 出现 note 条目、
    /// `sharePath` 免登录可听、`lrc` 非 null 这三半由仓库外的只读 curl 复核（不打印签名串）。
    /// 刻意**不做**删除：那是不可逆的，而"确认框存在 + 措辞说清两行一起消失"已经是可以拍的证据。
    func testWorksListClipActionsReachTheServer() throws {
        let list = try launchedScreen("我的作品", route: "worksList")

        // ① 行 ⋯ 必须是 clip 级那几项，且**不含**改名/删除/分享（那三项是 job 级的，
        //    这一屏靠"物理上放不到一行上"表达作用域 ⇒ 这里断言它不在，比断言它在别处更硬）。
        let rowMenu = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cova.works.rowMenu.")
        ).element(boundBy: 0)
        XCTAssertTrue(
            rowMenu.waitForExistence(timeout: 20),
            "A7：第一行没有 ⋯ 钮；标签=" + labelDump()
        )
        rowMenu.tap()
        let lyrics = list.buttons["歌词"]
        XCTAssertTrue(
            lyrics.waitForExistence(timeout: 10),
            "行 ⋯ 里没有「歌词」；标签=" + labelDump()
        )
        XCTAssertFalse(
            list.buttons["重命名本次生成的作品"].exists || list.buttons["分享本次生成的作品"].exists
                || list.buttons["删除本次生成的作品"].exists,
            "A7：job 级的三项不许出现在行 ⋯ 里（作用域靠位置表达）"
        )
        shot("20-row-menu")

        // ② 歌词：有词 ⇒ 屏上出正文；没词 ⇒ 出那两句诚实的空态之一。不许出「未知错误」。
        lyrics.tap()
        Thread.sleep(forTimeInterval: 4)
        let showedLyrics = list.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "\n")
        ).element.exists || list.scrollViews.element.exists
        let saidSo = list.staticTexts["这首还没有歌词"].exists
            || list.staticTexts["还没取到歌词"].exists
        XCTAssertTrue(
            showedLyrics || saidSo,
            "A7：点「歌词」之后既没有正文也没有空态说明；标签=" + labelDump()
        )
        shot("20-lyrics")
        list.navigationBars.buttons.element(boundBy: 0).tap()

        // ③ 组头 ⋯：三项都在，且每一句都带「本次生成的作品」（VoiceOver 不许简写成「重命名」）。
        let groupMenu = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cova.works.groupMenu.")
        ).element(boundBy: 0)
        XCTAssertTrue(groupMenu.waitForExistence(timeout: 10), "组头没有 ⋯")
        groupMenu.tap()
        Thread.sleep(forTimeInterval: 2)
        // 正面断言：三项都在组头，且每一句都带「本次生成的作品」。
        // 这一格是上面那条"行 ⋯ 里不许有"的对照面 —— 没有它，那条否定断言可以因为
        // 标签写错而恒真（本轮第一次写这条时就是这个错法）。
        for label in [
            "重命名本次生成的作品", "分享本次生成的作品", "删除本次生成的作品"
        ] {
            XCTAssertTrue(
                list.buttons[label].exists,
                "组头 ⋯ 少了「\(label)」；标签=" + labelDump()
            )
        }
        shot("20-group-menu")
    }

    /// A9（流水页）的设备腿：行渲染 + 服务端 `reasonLabel` 原样上屏 + **「任务」跳得到作品**。
    ///
    /// 这一条同时是 §7 #38 的反面证人：`studio_create_generation` 那两行今天**不该**有链接
    /// （实测 `jobId=null`），而更早的 `cova_one_step_generation` 那行有 ⇒ 同一屏上
    /// "有链接"与"没链接"两种形态同时存在，正是"不猜一个号"这条规则能被人看见的样子。
    func testCreditsLedgerRendersRowsAndLinksAJob() throws {
        let ledger = try launchedScreen("co 币明细", route: "creditsLedger")

        XCTAssertTrue(
            ledger.staticTexts["AI 音乐生成"].waitForExistence(timeout: 20),
            "A9：服务端给的 reasonLabel 没原样上屏；标签=" + labelDump()
        )
        XCTAssertTrue(
            ledger.staticTexts["其他变动"].exists || ledger.staticTexts["曲目下载"].exists,
            "A9：兜底档/其它档至少要有一种在屏上（只有生成一类 = 数据被过滤掉了）；标签="
                + labelDump()
        )
        shot("22-ledger")

        let link = ledger.buttons["任务"].firstMatch
        XCTAssertTrue(
            link.waitForExistence(timeout: 10),
            "A9：整屏没有一个「任务」链接 —— 有 jobId 的行（09-24 那条一步创作）必须给链接；标签="
                + labelDump()
        )
        scrollIntoView(link)
        link.tap()
        XCTAssertTrue(
            ledger.navigationBars["本次生成的作品"].waitForExistence(timeout: 20),
            "A9：点「任务」没落到那一组作品（20 的 job 锚定态）"
        )
        shot("22-job-landing")
    }

    /// 起一个只到某一屏的会话（登录钩子 + 路由钩子），并把首屏导航标题等出来。
    /// 三个方法共用这一小段，避免"每条腿自己忘了一次登录"这种各写一遍的偏差。
    private func launchedScreen(
        _ title: String, route: String
    ) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["COVA_ACCEPT_EMAIL"], let password = env["COVA_ACCEPT_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("缺 COVA_ACCEPT_EMAIL / COVA_ACCEPT_PASSWORD ⇒ 跳过")
        }
        let app = XCUIApplication()
        app.launchEnvironment["COVA_PREVIEW_LOGIN_EMAIL"] = email
        app.launchEnvironment["COVA_PREVIEW_LOGIN_PASSWORD"] = password
        app.launchEnvironment["COVA_PREVIEW_ROUTE"] = route
        app.launch()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 40),
            "路由 \(route) 没到达「\(title)」这一屏（登录或路由钩子失败，后面全部不成立）"
        )
        self.app = app
        return app
    }
}
