import CovaCore
import XCTest

/// `StudioSessionRowFacts.swift` 的纯口径：08 §3.C 进度环、§6 行标签、§8 相对时间、§3.C 封面降级。
/// 钉的全是「错了会骗人」的映射（把没有任务读成 0%、把昨天读成 N 小时前、
/// 把读不到的百分比念出来）；渲染它们的 UI 层代码不在本文件的断言之列。
final class StudioSessionRowFactsTests: XCTestCase {

    // MARK: - 环的取值（§数据源行 140：来源只能是本设备内存里未终态的 job）

    func testNoLiveJobAlwaysMeansIdleEvenIfAPercentageWasHandedIn() {
        // 「没有任务却带着百分比」是矛盾输入；采信它等于凭空造出一格进行中。
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: false, progress: 0.68), .idle)
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: false, progress: nil), .idle)
    }

    func testLiveJobWithoutReadableProgressStaysIndeterminate() {
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: true, progress: nil), .runningWithoutProgress)
    }

    func testLiveJobWithInRangeFractionIsDeterminate() {
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: true, progress: 0.68), .running(fraction: 0.68))
        // 两端点合法：0 = 刚起步、1 = 走到最后一格但**尚未**终态。
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: true, progress: 0), .running(fraction: 0))
        XCTAssertEqual(StudioSessionProgressRing.ring(hasLiveJob: true, progress: 1), .running(fraction: 1))
    }

    /// 越界 / 非有限**不钳位**：钳位等于承认"它至少是 0/至多是 1"，而真意是"这个数不是进度"。
    func testOutOfRangeOrNonFiniteProgressDegradesInsteadOfClamping() {
        for raw in [1.2, -0.1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(
                StudioSessionProgressRing.ring(hasLiveJob: true, progress: raw), .runningWithoutProgress,
                "非法进度值 \(raw) 必须退化成无定值那一档"
            )
        }
    }

    // MARK: - 弧与百分比（§3.C 环内不放百分数 ⇒ 百分比只进 VoiceOver）

    func testArcFractionOnlyExistsForDeterminateRings() {
        XCTAssertNil(StudioSessionProgressRing.arcFraction(of: .idle))
        XCTAssertNil(StudioSessionProgressRing.arcFraction(of: .runningWithoutProgress))
        XCTAssertEqual(StudioSessionProgressRing.arcFraction(of: .running(fraction: 0.42)), 0.42)
    }

    func testPercentRoundsToNearestWholePercent() {
        XCTAssertEqual(StudioSessionProgressRing.percent(of: .running(fraction: 0.682)), 68)
        XCTAssertEqual(StudioSessionProgressRing.percent(of: .running(fraction: 0.679)), 68)
        XCTAssertEqual(StudioSessionProgressRing.percent(of: .running(fraction: 0.5)), 50)
        XCTAssertEqual(StudioSessionProgressRing.percent(of: .running(fraction: 1)), 100)
        XCTAssertEqual(StudioSessionProgressRing.percent(of: .running(fraction: 0.004)), 0)
        XCTAssertNil(StudioSessionProgressRing.percent(of: .runningWithoutProgress))
        XCTAssertNil(StudioSessionProgressRing.percent(of: .idle))
    }

    // MARK: - §6 朗读：数值并进行标签，环本身不是元素

    func testVoiceOverFragmentCarriesTheSpecWording() {
        XCTAssertNil(StudioSessionProgressRing.voiceOverFragment(of: .idle))
        XCTAssertEqual(StudioSessionProgressRing.voiceOverFragment(of: .runningWithoutProgress), "生成中")
        XCTAssertEqual(StudioSessionProgressRing.voiceOverFragment(of: .running(fraction: 0.68)), "生成中，约 68%")
    }

    /// §6 顺序「<标题>，<摘要>，<相对时间>，<生成中，约 68%>」；缺位的段不进标签、不留空逗号。
    func testRowLabelJoinsOnlyTheSegmentsThatExist() {
        XCTAssertEqual(
            StudioSessionRowFactsTestSupport.rowLabel(
                title: "夏夜城市", summary: "帮我做一首…", time: "2 小时前", ring: .running(fraction: 0.68)
            ),
            "夏夜城市，帮我做一首…，2 小时前，生成中，约 68%"
        )
        // 摘要拿不到 ⇒ 那一行不渲染（§数据源行 137）⇒ 标签里也没有它。
        XCTAssertEqual(
            StudioSessionRowFactsTestSupport.rowLabel(title: "未命名会话", summary: nil, time: "昨天", ring: .idle),
            "未命名会话，昨天"
        )
        // 时间拿不到 ⇒ 整条不渲染（§数据源行 138）。
        XCTAssertEqual(
            StudioSessionRowFactsTestSupport.rowLabel(
                title: "未命名会话", summary: "只做了一段纯音乐…", time: nil, ring: .runningWithoutProgress
            ),
            "未命名会话，只做了一段纯音乐…，生成中"
        )
        // 只有标题：行永远可点，`id` 是唯一必需字段 ⇒ 标签至少要说标题，且末尾不留逗号。
        let onlyTitle = StudioSessionRowFactsTestSupport.rowLabel(title: "未命名会话", summary: "", time: "", ring: .idle)
        XCTAssertEqual(onlyTitle, "未命名会话")
        XCTAssertFalse(onlyTitle.hasSuffix("，"))
    }

    // MARK: - §4 Reduce Motion 退化

    func testOnlyTheIndeterminateRingSpinsAndNeverUnderReduceMotion() {
        XCTAssertTrue(StudioSessionProgressRing.spins(of: .runningWithoutProgress, reduceMotion: false))
        XCTAssertFalse(StudioSessionProgressRing.spins(of: .runningWithoutProgress, reduceMotion: true))
        // 有定值时环本身就在说进度，转它反而盖掉读数。
        XCTAssertFalse(StudioSessionProgressRing.spins(of: .running(fraction: 0.3), reduceMotion: false))
        XCTAssertFalse(StudioSessionProgressRing.spins(of: .idle, reduceMotion: false))
    }

    /// §4 行 100：静态环 + **一条**一次性 2pt 高的不确定进度条 —— 只补在不确定那一档。
    func testReduceMotionFallbackBarAppearsOnlyForIndeterminateRing() {
        XCTAssertTrue(StudioSessionProgressRing.showsIndeterminateFallbackBar(of: .runningWithoutProgress, reduceMotion: true))
        XCTAssertFalse(StudioSessionProgressRing.showsIndeterminateFallbackBar(of: .runningWithoutProgress, reduceMotion: false))
        XCTAssertFalse(StudioSessionProgressRing.showsIndeterminateFallbackBar(of: .running(fraction: 0.3), reduceMotion: true))
        XCTAssertFalse(StudioSessionProgressRing.showsIndeterminateFallbackBar(of: .idle, reduceMotion: true))
    }

    /// §5：进行中 2pt 竖条与环同判据（同现同灭），且 `.idle` 两者都不在。
    func testInProgressBarAppearsExactlyWhenTheRingDoes() {
        XCTAssertFalse(StudioSessionProgressRing.showsInProgressBar(of: .idle))
        XCTAssertTrue(StudioSessionProgressRing.showsInProgressBar(of: .runningWithoutProgress))
        XCTAssertTrue(StudioSessionProgressRing.showsInProgressBar(of: .running(fraction: 0.1)))
    }

    // MARK: - §8 相对时间（逐档，不合并）

    func testSubMinuteAndMinuteBands() {
        XCTAssertEqual(text(30), "刚刚")
        XCTAssertEqual(text(59), "刚刚")
        XCTAssertEqual(text(60), "1 分钟前")
        XCTAssertEqual(text(3_599), "59 分钟前")
    }

    func testSameCalendarDayUsesHourBandAndNotDayBand() {
        XCTAssertEqual(text(3_600), "1 小时前")
        XCTAssertEqual(text(2 * 3_600 + 5 * 60), "2 小时前")
    }

    /// 日级判断走**日历天**：深夜那条即使不满 24 小时也算昨天，而不是「N 小时前」。
    func testYesterdayIsThePreviousCalendarDayNotTwentyFourHours() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 10))!
        let lateLastNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22))!
        // 2 小时 10 分前，但跨了日历天 ⇒ 昨天。
        XCTAssertEqual(StudioRelativeTime.text(iso(lateLastNight), now: now, calendar: calendar), "昨天")
        let minutesAgo = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 23, minute: 50))!
        // 20 分钟前（<60min 那一档排在日级判断**之前**，与 §8 的排列顺序一致）。
        XCTAssertEqual(StudioRelativeTime.text(iso(minutesAgo), now: now, calendar: calendar), "20 分钟前")
    }

    func testWeekAndOlderBands() {
        XCTAssertEqual(text(86_400), "昨天")
        XCTAssertEqual(text(3 * 86_400), "3 天前")
        XCTAssertEqual(text(7 * 86_400), "7 天前")
        // 第 8 天出「本周内」⇒「M月D日」。
        XCTAssertEqual(text(8 * 86_400), "9月16日")
    }

    /// 跨年那一档在最后：日级读数优先（3 天前即使是去年底也不改口），过了本周才带年份。
    func testCrossYearKeepsDayBandFirstAndAddsYearAfterwards() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12))!
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)   // 2025-12-30
        XCTAssertEqual(StudioRelativeTime.text(iso(threeDaysAgo), now: now, calendar: calendar), "3 天前")
        let longAgo = calendar.date(from: DateComponents(year: 2025, month: 12, day: 20))!
        XCTAssertEqual(StudioRelativeTime.text(iso(longAgo), now: now, calendar: calendar), "2025年12月20日")
    }

    func testUnusableTimestampsReturnNilInsteadOfNoise() {
        XCTAssertNil(StudioRelativeTime.text(nil, now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(StudioRelativeTime.text("", now: referenceNow, calendar: referenceCalendar))
        XCTAssertNil(StudioRelativeTime.text("not-a-date", now: referenceNow, calendar: referenceCalendar))
        // 未来时间戳 = 不可信（两台机器各走各的钟），不钳成「刚刚」去编造新鲜度。
        XCTAssertNil(text(-600))
    }

    /// 线上四种形态都要认：带 Z、带**小数秒**（2026-09-24 实测 `workflowState.updatedAt` 就是这一种，
    /// 默认 `ISO8601DateFormatter` 解不出）、无时区（按东八区读）、MySQL 的空格分隔。
    /// 参照时刻 = 2026-09-24T04:00:00Z，四个串指的是**同一个** 2 小时前的瞬间。
    func testEveryWireTimestampShapeParses() {
        XCTAssertEqual(StudioRelativeTime.text("2026-09-24T01:59:00.000Z", now: referenceNow, calendar: utcCalendar), "2 小时前")
        XCTAssertEqual(StudioRelativeTime.text("2026-09-24T01:59:00Z", now: referenceNow, calendar: utcCalendar), "2 小时前")
        // 无时区那一支必须按东八区读（`09:59 +08` 与上面两个是同一时刻）；
        // 若被当成 UTC，差 8 小时 ⇒ 这一档会读成未来时间而返回 nil，用例立刻红。
        XCTAssertEqual(StudioRelativeTime.text("2026-09-24T09:59:00", now: referenceNow, calendar: utcCalendar), "2 小时前")
        // MySQL DATETIME 的空格分隔形态，同样按东八区读。
        XCTAssertEqual(StudioRelativeTime.text("2026-09-24 09:59:00", now: referenceNow, calendar: utcCalendar), "2 小时前")
        // 解析不出就是解析不出 ⇒ nil（那一行不渲染），不是「刚刚」。
        XCTAssertNil(StudioRelativeTime.text("24/09/2026 09:59", now: referenceNow, calendar: utcCalendar))
    }

    // MARK: - §3.C 封面降级（逐行判据）

    /// 2026-09-26 实测更正：列表载荷**确实**带 `firstCoverUrl` 这个键，但同一账号 5 条
    /// one-step 会话逐条给 `null` ⇒ 「每行都有封面」仍然不成立（01 §5 那一格继续像素占位，
    /// `HomeCreationGridTests` 钉的是这一条），而 08 §3.C 那一格改成**逐行**分流。
    /// `placeholderSymbol` 这一条判据不变：没给的那一行还是 `sparkles`。
    func testCoverSlotIsPerRowBecauseTheKeyIsNullOnEveryOneStepRow() {
        XCTAssertFalse(StudioSessionCover.hasCoverFieldInListPayload)
        XCTAssertEqual(StudioSessionCover.placeholderSymbol, "sparkles")
        // 「没给」有三形态：键缺席、空串、纯空白 —— 都不足以撑起一张封面。
        XCTAssertNil(StudioSessionCover.usableCover(nil))
        XCTAssertNil(StudioSessionCover.usableCover(""))
        XCTAssertNil(StudioSessionCover.usableCover("  \n"))
        // 给了就**原样**交出，一个字节都不动：站内相对 + 带查询串都在线上出现过，
        // 而 `%2B` 一旦被重编码就是另一张图（判据只判"有没有"）。
        XCTAssertEqual(
            StudioSessionCover.usableCover("  /api/proxy/image?a=1&sig=abc%2Bd  "),
            "  /api/proxy/image?a=1&sig=abc%2Bd  "
        )
        XCTAssertEqual(
            StudioSessionCover.usableCover("https://covalink.cn/c/1.png?sig=a%2Bb"),
            "https://covalink.cn/c/1.png?sig=a%2Bb"
        )
    }

    func testSessionDtoNowModelsTheCoverKeyTheListActuallySends() throws {
        // 建模之后：值原样交出（**不**补全、**不**裁剪查询串 —— `%2B` 那一类的字节保真有过缺陷）。
        let json = """
        [{"id":"s1","title":"夏夜城市","firstCoverUrl":"https://covalink.cn/c/1.png?sig=a%2Bb",
          "lastMessage":"帮我做一首夏日广告配乐"}]
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(StudioSessionListDto.self, from: json)
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.sessions[0].displayTitle, "夏夜城市")
        XCTAssertEqual(list.sessions[0].firstCoverUrl, "https://covalink.cn/c/1.png?sig=a%2Bb")
        XCTAssertEqual(list.sessions[0].displaySummary, "帮我做一首夏日广告配乐")
    }

    /// 两个摘要键都在时看 `summary`（契约文档那个）；`summary` 缺席或空串时用 `lastMessage`；
    /// 两者皆空 ⇒ `nil` ⇒ 那一行不渲染（§数据源行 137：不放占位符）。
    func testRowSummaryFallsThroughBothWireKeys() throws {
        func summary(_ line: String) throws -> String? {
            try JSONDecoder().decode(StudioSessionListDto.self, from: Data(line.utf8)).sessions[0].displaySummary
        }
        XCTAssertEqual(try summary(#"[{"id":"s1","summary":"三段草稿","lastMessage":"最后一句"}]"#), "三段草稿")
        XCTAssertEqual(try summary(#"[{"id":"s1","summary":"","lastMessage":"最后一句"}]"#), "最后一句")
        XCTAssertEqual(try summary(#"[{"id":"s1","lastMessage":"最后一句"}]"#), "最后一句")
        XCTAssertNil(try summary(#"[{"id":"s1","summary":"  ","lastMessage":""}]"#))
        XCTAssertNil(try summary(#"[{"id":"s1"}]"#))
        // 「值不是字符串」不能把整行打成读不到（同 `workflowState` 的容错口径）。
        XCTAssertNil(try summary(#"[{"id":"s1","lastMessage":{"text":"怪形态"},"firstCoverUrl":[1,2]}]"#))
    }

    // MARK: - 内存在途账（`AppSession.liveStudioJobs` 的读写语义）

    /// 「有 job 但没有读数」这一档必须**留得住键**：直接用下标 `ledger[id] = nil` 是删键，
    /// 症状 = 09 刚发起、计划卡还没到的那一段时间里 08 一格环都不出现。
    func testMarkingWithoutProgressKeepsTheKeyAndRingsIndeterminate() {
        var ledger: [String: Double?] = [:]
        ledger.markStudioLive(sessionID: "s1", progress: nil)
        XCTAssertTrue(ledger.studioHasLiveJob("s1"))
        XCTAssertNil(ledger.studioProgress("s1"))
        XCTAssertEqual(ledger.studioRing(for: "s1"), .runningWithoutProgress)
        // 下标读回来是**双层** optional：`.some(.none)`（有键、无读数）与 `nil`（没这个键）
        // 要 `?? nil` 拍平才看得懂，而一拍平两档就塌成一档 ⇒ 必须靠 `studioHasLiveJob` 问键。
        XCTAssertNotNil(ledger["s1"])
        XCTAssertNil(ledger["s2"])
    }

    func testMarkingWithProgressThenSettlingRoundTrips() {
        var ledger: [String: Double?] = [:]
        ledger.markStudioLive(sessionID: "s1", progress: 0.68)
        XCTAssertEqual(ledger.studioProgress("s1"), 0.68)
        XCTAssertEqual(ledger.studioRing(for: "s1"), .running(fraction: 0.68))
        ledger.settleStudioLive(sessionID: "s1")
        XCTAssertFalse(ledger.studioHasLiveJob("s1"))
        XCTAssertEqual(ledger.studioRing(for: "s1"), .idle)
    }

    /// 账按会话号分格：结算一路不能把另一路的读数一起带走（08 是一次列出多条会话）。
    func testSettlingOneSessionLeavesTheOthersAlone() {
        var ledger: [String: Double?] = [:]
        ledger.markStudioLive(sessionID: "s1", progress: 0.2)
        ledger.markStudioLive(sessionID: "s2", progress: nil)
        ledger.settleStudioLive(sessionID: "s1")
        XCTAssertEqual(ledger.studioRing(for: "s1"), .idle)
        XCTAssertEqual(ledger.studioRing(for: "s2"), .runningWithoutProgress)
    }

    /// 没登记过的会话号 ⇒ `.idle`：冷启动那一下整张列表都是这一档，且它**不是**错误态。
    func testUnknownSessionReadsAsIdleWithoutRegisteringItself() {
        var ledger: [String: Double?] = [:]
        XCTAssertEqual(ledger.studioRing(for: "nope"), .idle)
        XCTAssertFalse(ledger.studioHasLiveJob("nope"))
        ledger.markStudioLive(sessionID: "nope", progress: 1)
        XCTAssertEqual(ledger.studioRing(for: "nope"), .running(fraction: 1))
    }

    // MARK: - 测试时钟

    /// 参照时刻：2026-09-24 12:00:00 +08:00（= 04:00 UTC）。
    private var referenceNow: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12, minute: 0))!
    }

    private var referenceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 相对 `referenceNow` 偏移若干秒的时间戳（正数 = 过去）。
    private func text(_ ago: TimeInterval) -> String? {
        StudioRelativeTime.text(iso(referenceNow.addingTimeInterval(-ago)), now: referenceNow, calendar: referenceCalendar)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.string(from: date)
    }
}

/// 行标签的拼接入口（与视图里同一支函数，测试不碰 UI 层）。
private enum StudioSessionRowFactsTestSupport {
    static func rowLabel(title: String, summary: String?, time: String?, ring: StudioSessionRing) -> String {
        StudioSessionProgressRing.rowVoiceOverLabel(title: title, summary: summary, relativeTime: time, ring: ring)
    }
}
