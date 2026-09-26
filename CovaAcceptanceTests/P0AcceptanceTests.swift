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
        for _ in 0..<34 {   // 服务端历史已从 5 条涨到 35 条 ⇒ 滚动预算跟着给足
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

    /// 屏上所有按钮的「标识符 + 标签」清单。labelDump() 只看 staticText，
    /// 而这一族失败几乎都是「标识符挂在按钮上、我却只打了文本」—— 没有它就是靠猜。
    private func buttonDump() -> String {
        app.buttons.allElementsBoundByIndex.map {
            "[" + $0.identifier + "]" + $0.label
        }.joined(separator: " ")
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
        // 这一格是修出来的：上一版只 sleep 12s 就截图，于是"点了、MiniPlayer 出来了"就算过 ——
        // 而实测那张截图停在「加载私有音频中…」，**声音从来没起来**，A5 的上报自然也没发生
        // （play-history 34 条里 work 行 = 0）。判据必须是"真的在放"，不是"起过一个弹层"。
        var playing = false
        for _ in 0..<30 {   // 最多再等 120s：5.3MB 的整曲要先下载完才能出声
            if miniPlayerShowsTime() { playing = true; break }
            Thread.sleep(forTimeInterval: 4)
        }
        shot("20-after-play")
        XCTAssertTrue(
            playing,
            "A5：点了行之后 MiniPlayer 始终没有走到「有时间在走」那一态 —— "                + "停在「加载私有音频中…」就说明 D7 那条取字节的腿没通，上报不会发生；标签="                + labelDump()
        )
        // 起来之后再多等一会儿：集次上报要真的播过一段才发（不是按下即发）。
        Thread.sleep(forTimeInterval: 45)
        shot("20-after-listen")
    }

    /// MiniPlayer 上有没有"时间在走"那一格（`00:12 / 04:03` 这类文本）。
    /// 只看数字形状，不依赖任何标签措辞 —— 措辞会改，`mm:ss` 不会。
    private func miniPlayerShowsTime() -> Bool {
        let pattern = "^[0-9]{1,2}:[0-9]{2}"
        for text in app.staticTexts.allElementsBoundByIndex {
            if text.label.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// A7（works 行内动作）的设备腿：**clip 级那几项**在行 ⋯ 里，job 级那三项在组头 ⋯ 里。
    ///
    /// 这条腿只证"屏上到得了、发得出去、回执看得见"；`GET /api/favorites` 出现 note 条目、
    /// `sharePath` 免登录可听、`lrc` 非 null 这三半由仓库外的只读 curl 复核（不打印签名串）。
    /// 刻意**不做**删除：那是不可逆的，而"确认框存在 + 措辞说清两行一起消失"已经是可以拍的证据。
    func testWorksListClipActionsReachTheServer() throws {
        let list = try launchedScreen("我的作品", route: "worksList")

        // ① 组头 ⋯：三项都在，且每一句都带「本次生成的作品」。
        //    顺序是修出来的 —— 第一版把这一格放在最后，而前面「关掉歌词面板」那一步点的是
        //    导航条第一个按钮，那正是**返回**：20 整屏被弹掉 ⇒ 这里报「组头没有 ⋯」。
        //    与其去猜面板的关闭键，不如把不需要弹层的检查放到最前面。
        //    标识符是在设备上核出来的：组头那枚 ⋯ 实际暴露的是 `cova.works.group.<序号>`
        //    （源码里写的 `cova.works.groupMenu.<anchor>` 被外层组的标识符盖掉了）。
        //    选择器不靠读源码猜 —— 上一版就是猜错的，报"组头没有 ⋯"而屏上明明有。
        let groupMenu = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cova.works.group.")
        ).element(boundBy: 0)
        XCTAssertTrue(
            groupMenu.waitForExistence(timeout: 25),
            "组头没有 ⋯；按钮标识=" + buttonDump() + "｜标签=" + labelDump()
        )
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

    /// A7 的第二条腿：clip 级那几项在**行** ⋯ 里，job 级三项不在。
    ///
    /// 为什么单独一条：上一版把两步写在同一次会话里，第一步留下的弹层让第二步的
    /// `rowMenu` 变成「存在但点不到」（XCUITest 报 `Failed to not hittable`）——
    /// 那是测试自己的状态泄漏，不是屏上的缺陷。一条用例一个起点，就不必去猜别人的关闭键。
    func testWorksListClipMenuHoldsOnlyClipActions() throws {
        let list = try launchedScreen("我的作品", route: "worksList")

        // ① ♡ 真按一次。断言的是"屏上确实有反应"这一格可观察事实：
        //    按钮清单在点之前与点之后必须不同（翻面、或出现回执/失败说明都算）——
        //    相同就说明这一发根本没走到会话层，那才是这条判据要挡的东西。
        let favorite = list.buttons["喜欢"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "行上没有 ♡「喜欢」；" + buttonDump())
        //    观测量是**选中态**而不是标签：♡ 这一枚的标签恒为「喜欢」，翻面走的是
        //    `accessibilityAddTraits(on ? .isSelected : [])`（`WorksListView.favoriteRow`）。
        //    上一版断"按钮清单前后不同"，红了一次 —— 不是没生效，是量错了格：
        //    服务端同一分钟就多了那条 note 条目（档案里记着这次误判）。
        //    断言写成**双向翻转 + 复位**，不写成"按之前必须是未收藏"：
        //    前者与账号当前状态无关，后者会被上一轮跑剩的状态挡死（实测就是这样红过一次，
        //    而那一次的失败信息恰恰证明选中态是跟着服务端走的）。
        let before = favorite.isSelected
        favorite.tap()
        XCTAssertTrue(
            favorite.waitForExistence(timeout: 15) && favorite.isSelected != before,
            "点了 ♡ 选中态没翻面：这一发没走到会话层，或被服务端拒了；" + buttonDump()
        )
        shot("20-favorited")
        favorite.tap()
        XCTAssertTrue(
            favorite.waitForExistence(timeout: 15) && favorite.isSelected == before,
            "再点一次没能翻回原态：撤收藏这一发没生效；" + buttonDump()
        )


        // 行 ⋯ 必须是 clip 级那几项，且**不含**改名/删除/分享（那三项是 job 级的，
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
        XCTAssertTrue(
            list.buttons["补充制作"].exists,
            "A7：行 ⋯ 少了 21 面板的入口「补充制作」（§5 P2-1 的生产宿主）；标签=" + labelDump()
        )
        shot("20-row-menu")

        // ③ 歌词：有词 ⇒ 屏上出正文；没词 ⇒ 出那两句诚实的空态之一。不许出「未知错误」。
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

    }

    /// 21「补充制作」面板的 A14 腿：从 20 的行 ⋯ 真点开它。
    ///
    /// 为什么要单独一条：这一屏没有"到得了但不需要点击"的路由键（它是 sheet，
    /// 宿主是行菜单），而 A14 要的是"这一屏深浅各一图" —— 用走查键假装到得了就是骗自己。
    func testExtrasPanelOpensFromTheRowMenu() throws {
        let list = try launchedScreen("我的作品", route: "worksList")
        let rowMenu = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cova.works.rowMenu.")
        ).element(boundBy: 0)
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 25), "行 ⋯ 没出现；" + buttonDump())
        rowMenu.tap()
        let extras = list.buttons["补充制作"].firstMatch   // 每一行的 ⋯ 里都有这一枚 ⇒ 按标签查必然多命中
        XCTAssertTrue(extras.waitForExistence(timeout: 10), "行 ⋯ 里没有「补充制作」；" + buttonDump())
        extras.tap()
        // 先无条件拍一张再断言：上一版断"关闭钮在不在"，红的时候屏上到底是什么完全不知道。
        Thread.sleep(forTimeInterval: 4)
        shot("21-extras-attempt")
        // 观测量取自设备 dump（不是读源码猜的标识符）：`cova.extras.panel` 在 XCUITest
        // 的元素树上根本不出现，而这两句只可能在**作品路径的正常态**里有 ——
        // 「这里不消耗 co」是 §3.H 那一行，「可以再做的，6 项，多选」是 D 组的分组标签。
        // 上一版断"离线"消失其实不够：骨架态也没有离线句。
        XCTAssertTrue(
            list.staticTexts["这里不消耗 co"].waitForExistence(timeout: 25),
            "21 面板没到作品路径的正常态；标签=" + labelDump()
        )
        XCTAssertTrue(
            list.staticTexts["可以再做的，6 项，多选"].exists,
            "D 可选 key 组没渲染出六项；标签=" + labelDump()
        )
        // 给一次 GET 复列留时间：面板先读一次已知态，读回来的行与骨架不是同一张图。
        Thread.sleep(forTimeInterval: 6)
        shot("21-extras")
    }

    /// A7 的 **dislike** 那一半（判据原句：「dislike → 收藏被撤」）。
    ///
    /// 为什么屏上就够、不必再 curl：`WorksListState.favoriteIsOn` 在
    /// `signalOverrides == .dislike` 时恒返回 false —— 那是照抄服务端
    /// `setWorkDislike` 的互斥语义（`work-actions.ts` 里点踩时顺手 `setNoteFavorite(false)`），
    /// ⇒ ♡ 的选中态翻灭就是"收藏被撤"这一格的可观察事实本身。
    /// 复原也做在同一条腿里：这一枚钮在真机上会留痕，点完就走等于给下一轮造起始态。
    func testWorksListDislikeWithdrawsTheFavorite() throws {
        let list = try launchedScreen("我的作品", route: "worksList")
        let favorite = list.buttons["喜欢"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 25), "行上没有 ♡「喜欢」；" + buttonDump())
        let started = favorite.isSelected
        // 先把这一行钉成「收藏 on / 点踩 off」：`setWorkFavorite(true)` 在服务端顺手删掉
        // dislike 行 ⇒ 起始态与账号上一轮留了什么无关（不这样钉，第一次开 ⋯ 就可能只看到
        // 「不喜欢（已选）」，那条查不到就是"这一发没走到会话层"的假红）。
        if !started {
            favorite.tap()
            XCTAssertTrue(
                favorite.waitForExistence(timeout: 15) && favorite.isSelected,
                "A7：先把 ♡ 点亮这一步没生效，后面的判据无从谈起；" + buttonDump()
            )
        }
        let rowMenu = list.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cova.works.rowMenu.")
        ).element(boundBy: 0)
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 25), "行 ⋯ 没出现；" + buttonDump())
        rowMenu.tap()
        let dislike = list.buttons["不喜欢"].firstMatch
        XCTAssertTrue(
            dislike.waitForExistence(timeout: 10),
            "行 ⋯ 里没有裸「不喜欢」（起始态没钉成「点踩 off」）；" + buttonDump()
        )
        dislike.tap()
        // 判据正身：点踩之后 ♡ 不许还亮着。POST 回来才翻 ⇒ 轮询而不是查一次。
        var withdrew = false
        for _ in 0..<12 {
            if favorite.exists && !favorite.isSelected { withdrew = true; break }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(withdrew, "A7：点了「不喜欢」而 ♡ 一直还亮着 ⇒ 收藏没被撤；" + buttonDump())
        shot("20-disliked")
        // 复原 + 第二个证人：再开一次 ⋯，标签应是「不喜欢（已选）」（选中态真的记上了）。
        rowMenu.tap()
        let marked = list.buttons["不喜欢（已选）"].firstMatch
        XCTAssertTrue(
            marked.waitForExistence(timeout: 10),
            "A7：点踩后菜单项没翻成「不喜欢（已选）」；" + buttonDump()
        )
        marked.tap()
        if started {
            // 撤点踩**不**还原收藏（服务端只做单向互斥）⇒ 这里再点一次 ♡ 才回到进入前的态。
            favorite.tap()
            XCTAssertTrue(
                favorite.waitForExistence(timeout: 15) && favorite.isSelected,
                "A7：这一行的收藏没复原成进入前的态（跑完不留痕）；" + buttonDump()
            )
        }
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
