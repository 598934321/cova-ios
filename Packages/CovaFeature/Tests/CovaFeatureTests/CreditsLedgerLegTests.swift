import CovaCore
import Foundation
import XCTest

@testable import CovaFeature

/// 22「co 币明细」在接线层的**纯映射腿**（§5 P2-3 / §6 A9）。
///
/// 与 `StudioCreateLegTests` 同一口径：不测视图渲染（TD-48：界面层的可信证据是截图），
/// 测的是"屏上那一格从哪来"这一段因果：
/// · 请求面只有 `limit` 且被夹进服务端 1..100 的窗口 ⇒ 「只能看最近 100 条」的机械形态；
/// · 尾部那一句在"取满了"与"取到底了"之间**不会同时出现**（§7 硬规则 ②④）；
/// · 「任务」链接只由 `jobId` 决定（手册 §7 #38：该字段生产恒 null ⇒ 屏上恒 0 枚）；
/// · 服务端 `reasonLabel` 逐字上屏、未识别 `reason` 不丢行（§4.7 那张 13/24 的降级表）；
/// · 读不出的行计入 `unreadableItemCount` 并且**必须说一句**（不静默缩表）。
///
/// `@MainActor`：被测的 `AppSession.creditsLedgerQuery()` 是 `@MainActor` 类的静态腿，
/// 隔离面必须一致才编得过（`StudioCreateLegTests` 的先例）。
@MainActor
final class CreditsLedgerLegTests: XCTestCase {

    // MARK: - 夹具
    //
    // 参照时刻写死：用 `Date()` 写的相对时间断言会在午夜前后自己变红
    // （`StudioSessionRowFactsTests` 同一处理）。

    private var referenceCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var referenceNow: Date {
        referenceCalendar.date(
            from: DateComponents(year: 2026, month: 9, day: 26, hour: 12, minute: 0, second: 0)
        )!
    }

    /// 相对参照时刻 `ago` 秒的 ISO 串（-7200 ⇒ 「2 小时前」）。
    private func iso(ago: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: referenceNow.addingTimeInterval(-ago))
    }

    /// 「服务端这一格没给」的取值。为什么不直接传 `nil`：`entry` 的默认值就是 `nil`，
    /// 传 `nil` 会被默认成"两小时前"，那条用例于是变成断言一个它没在测的东西（假绿）。
    private let noTimestamp = "__absent__"

    private func entry(
        id: String? = "led-1",
        type: String? = "debit",
        amount: Int? = -20,
        balanceAfter: Int? = 108,
        reason: String? = "studio_create_generation",
        reasonLabel: String? = "AI 音乐生成",
        jobId: String? = nil,
        unlinked: Bool? = nil,
        createdAt: String? = nil
    ) -> CreditLedgerEntryDto {
        // `nil` 在这里是"用默认时间戳"，缺席由 `noTimestamp` 那个哨兵表达（见上）。
        let stamp: String?
        if createdAt == noTimestamp {
            stamp = nil
        } else {
            stamp = createdAt ?? iso(ago: 7_200)
        }
        return CreditLedgerEntryDto(
            id: id, type: type, amount: amount, balanceAfter: balanceAfter, reason: reason,
            reasonLabel: reasonLabel, jobId: jobId,
            // 服务端给的 `unlinked` 就是 `jobId == nil` 的等价式（§4.7）⇒ 夹具默认自洽，
            // 免得每条用例都要去核一个与断言无关的漂移位（要造漂移时显式传值）。
            unlinked: unlinked ?? (jobId == nil),
            createdAt: stamp
        )
    }

    private func page(_ entries: [CreditLedgerEntryDto], unreadable: Int = 0) -> CreditLedgerPageDto {
        CreditLedgerPageDto(entries: entries, unreadableItemCount: unreadable)
    }

    private func decodePage(_ json: String) throws -> CreditLedgerPageDto {
        try JSONDecoder().decode(CreditLedgerPageDto.self, from: Data(json.utf8))
    }

    private func row(_ entry: CreditLedgerEntryDto) -> CreditsLedgerRow? {
        CreditsLedgerRow(entry: entry, now: referenceNow, calendar: referenceCalendar)
    }

    // MARK: - 请求面：只有 `limit`，且永远在服务端窗口内（§7 硬规则 ①）

    func testLimitIsClampedIntoTheServerWindow() {
        XCTAssertEqual(CreditLedgerQuery(limit: 0).limit, CreditLedgerQuery.minimumLimit)
        XCTAssertEqual(CreditLedgerQuery(limit: -500).limit, CreditLedgerQuery.minimumLimit)
        XCTAssertEqual(CreditLedgerQuery(limit: 100).limit, 100)
        // 上限之外一律夹住而不是报错：屏上"取满了"这件事由 `maximumVisibleEntries` 判。
        XCTAssertEqual(CreditLedgerQuery(limit: 101).limit, CreditLedgerQuery.maximumLimit)
        XCTAssertEqual(CreditLedgerQuery(limit: 999_999).limit, CreditLedgerQuery.maximumLimit)
        // 默认值是服务端那个"没写就等于 50"的口径，不是客户端随手挑的数。
        XCTAssertEqual(CreditLedgerQuery().limit, CreditLedgerQuery.defaultLimit)
        XCTAssertEqual(CreditLedgerQuery.defaultLimit, 50)
    }

    func testQueryCarriesNoPaginationParameterAtAll() {
        // 「不假装分页」在类型面上成立：这个 struct 没有 offset / cursor / page / before / since。
        let items = AppSession.creditsLedgerQuery().queryItems
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "limit")
        let query = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        for forbidden in ["offset", "cursor", "page", "before", "after", "since", "total"] {
            XCTAssertFalse(query.contains(forbidden), "请求里出现了翻页参数 \(forbidden)")
        }
    }

    func testScreenReadsTheWholeWindowInOneRequest() {
        // §7 ①：本屏恒发 `limit=100`（取满就是全部可读的东西，没有"下一页"可依赖）。
        XCTAssertEqual(
            AppSession.creditsLedgerQuery().limit, CreditLedgerQuery.maximumVisibleEntries
        )
        XCTAssertEqual(CreditLedgerQuery.maximumVisibleEntries, 100)
    }

    // MARK: - E 尾部行：边界 vs 穷尽（§7 硬规则 ②④，本屏最重要的一句措辞）

    func testFullWindowSaysTheServerBoundaryAndNotExhaustion() {
        let state = readyState(with: Array(stride(from: 0, to: 100, by: 1).map {
            entry(id: "led-\($0)")
        }))
        XCTAssertTrue(state.tailIsBoundary)
        XCTAssertEqual(state.tailText, "这里只有最近 100 条变动")
        XCTAssertNotEqual(state.tailText, "已显示全部")   // 伪装成穷尽就是替服务端撒谎
    }

    func testPartialWindowSaysExhausted() {
        let state = readyState(with: [entry(id: "led-1"), entry(id: "led-2")])
        XCTAssertFalse(state.tailIsBoundary)
        XCTAssertEqual(state.tailText, "已显示全部")
    }

    func testEmptyListHasNoTailLineAtAll() {
        let state = readyState(with: [])
        XCTAssertNil(state.tailText)
        XCTAssertNil(state.summaryText)      // §3.B：空 ⇒ 摘要行整行不渲染
        XCTAssertTrue(state.showsEmptyState)
    }

    func testBoundaryWordingTracksTheServerWindowConstant() {
        // 那句话里的数字必须跟着窗口常量走：写死"100"就是第二套口径（窗口一变它就成谎话）。
        XCTAssertTrue(
            CreditsLedgerCopy.tailBoundary.contains(
                "\(CreditLedgerQuery.maximumVisibleEntries)"
            )
        )
    }

    // MARK: - 「任务」链接：`jobId` 为 null 是今天的常态（手册 §7 #38）

    func testRowWithoutJobIDExposesNoLink() {
        let null = row(entry(jobId: nil))
        XCTAssertNotNil(null)
        XCTAssertFalse(null?.showsJobLink ?? true)
        XCTAssertNil(null?.linkedJobID)
        // §3.D：不留空位、不留「—」、不留「不可用」说明 ⇒ 朗读序列里也不许有"任务"那一停。
        XCTAssertFalse(null?.spokenLabel.contains(CreditsLedgerCopy.jobLink) ?? true)
    }

    func testEmptyAndBlankJobIDMeanTheSameAsNull() throws {
        // 空串 / 纯空白是服务端"解不出 metadata.jobId"的另一种写法，与 null 同义 ⇒ 不给链接。
        for raw in ["", "   ", "\n\t"] {
            let facts = row(entry(jobId: raw))
            XCTAssertNil(facts?.linkedJobID, "空白 jobId（\(raw.debugDescription)）不该给出链接")
            XCTAssertFalse(facts?.showsJobLink ?? true)
        }
        // 线格式那一支同样落进"没给"（`CreditLedgerEntryDto.linkedJobId` 走 `textIfPresent`）。
        let decoded = try decodePage(
            """
            {"entries":[{"id":"led-1","reason":"media_extra","reasonLabel":"其他变动","jobId":""}]}
            """
        )
        XCTAssertEqual(decoded.linkableEntries.count, 0)
        XCTAssertTrue(decoded.entries[0].isUnlinked)
    }

    func testRowWithJobIDExposesExactlyOneLinkCarryingThatID() {
        let withJob = entry(id: "led-1", jobId: "job-9f3a")
        let without = entry(id: "led-2")
        let state = readyState(with: [withJob, without])
        let rows = state.rows(now: referenceNow, calendar: referenceCalendar)
        XCTAssertEqual(rows.count, 2)
        let linked = rows.filter(\.showsJobLink)
        XCTAssertEqual(linked.count, 1, "屏上「任务」钮的数量必须恰好等于 jobId 非空的行数")
        XCTAssertEqual(linked.first?.linkedJobID, "job-9f3a")
        XCTAssertEqual(state.linkableJobIDs, ["job-9f3a"])
        XCTAssertTrue(linked.first?.spokenLabel.hasSuffix("，任务") ?? false)
    }

    func testStudioCreateRowsCarryNoLinkBecauseTheServerSendsNull() {
        // 生产实测（§7 #38）：今天 16:10 那次 `studio_create_generation` 仍回 `jobId=null`，
        // 而更早的 `cova_one_step_generation` 带着号 ⇒ 客户端不许"修"这个 null。
        let studio = decodePageOrCrash(
            """
            {"entries":[{"id":"a","type":"debit","amount":-100,"balanceAfter":19415,
            "reason":"studio_create_generation","reasonLabel":"AI 音乐生成","jobId":null,
            "unlinked":true,"createdAt":"\(iso(ago: 600))}"}]}
            """
        )
        XCTAssertEqual(studio.entries.count, 1)
        XCTAssertTrue(studio.entries[0].isUnlinked)
        XCTAssertFalse(studio.entries[0].canLinkToJob)
        XCTAssertEqual(studio.linkableEntries.count, 0)
    }

    func testOlderOneStepRowsKeepTheirLink() {
        let older = decodePageOrCrash(
            """
            {"entries":[{"id":"b","type":"debit","amount":-20,"balanceAfter":128,
            "reason":"cova_one_step_generation","reasonLabel":"其他变动","jobId":"job-old-1",
            "unlinked":false,"createdAt":"\(iso(ago: 86_400))}"}]}
            """
        )
        XCTAssertEqual(older.linkableEntries.map(\.linkedJobId), ["job-old-1"])
        let facts = row(older.entries[0])
        // 服务端标签"其他变动"逐字上屏 —— 客户端**不**按 reason 把它改回「AI 音乐生成」。
        XCTAssertEqual(facts?.reasonText, "其他变动")
        XCTAssertEqual(facts?.linkedJobID, "job-old-1")
    }

    // MARK: - reason / reasonLabel（§4.7：服务端那张表与真实 reason 不同步）

    func testServerLabelWinsVerbatimEvenWhenTheClientKnowsTheReason() {
        let given = row(
            entry(
                reason: "studio_create_generation", reasonLabel: "服务端给的一句原话", jobId: "job-x"
            )
        )
        XCTAssertEqual(given?.reasonText, "服务端给的一句原话")
    }

    func testServerDegradedLabelIsDisplayedAsGiven() {
        // 24 个在写的 reason 里 13 个在服务端就落到「其他变动」（含 `media_extra`）⇒
        // 那一句是**服务端的映射结果**，本屏照上，不再映射第二遍。
        let degraded = row(entry(reason: "media_extra", reasonLabel: "其他变动"))
        XCTAssertEqual(degraded?.reasonText, "其他变动")
    }

    func testUnknownReasonStillRendersTheRowWithTheFallbackWord() throws {
        // 后端新增的 reason 不许让一行消失（`.unknown(rawValue)` 保住原拼写）。
        let decoded = try decodePage(
            """
            {"entries":[{"id":"new-1","type":"debit","amount":-30,"balanceAfter":70,
            "reason":"inspiration_shop_item_bought","reasonLabel":"买了一个灵感","unlinked":true,
            "createdAt":"\(iso(ago: 300))}"}]}
            """
        )
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].reasonKind, .unknown("inspiration_shop_item_bought"))
        let facts = row(decoded.entries[0])
        XCTAssertEqual(facts?.reasonText, "买了一个灵感")   // 服务端给了 ⇒ 逐字
        XCTAssertNil(facts?.linkedJobID)
    }

    func testUnknownReasonWithoutLabelFallsBackInsteadOfShowingTheRawCode() {
        let subject = entry(reason: "some_future_reason", reasonLabel: nil)
        // `.unknown(rawValue)` 保住原拼写 ⇒ 行不丢（后端新增 reason 不该让一条账消失）。
        XCTAssertEqual(subject.reasonKind, .unknown("some_future_reason"))
        let facts = row(subject)
        XCTAssertNotNil(facts)
        XCTAssertEqual(facts?.reasonText, CreditsLedgerCopy.otherChange)
        // 17 §10 禁技术词 + A15：英文码一次都不许出现在屏上。
        XCTAssertFalse(facts?.reasonText.contains("some_future_reason") ?? true)
    }

    func testFallbackTableOnlySpeaksWhenTheServerSaidNothing() {
        XCTAssertEqual(
            row(entry(reason: "studio_create_generation", reasonLabel: nil))?.reasonText,
            "AI 音乐生成"
        )
        XCTAssertEqual(
            row(entry(reason: "daily_checkin", reasonLabel: nil))?.reasonText, "每日签到"
        )
        // §4.7 就地更正：`generation_refund` 不是真实 reason，退款标签挂在两个真实值上。
        XCTAssertEqual(
            row(entry(reason: "cova_one_step_generation_refund", reasonLabel: nil))?.reasonText,
            "生成失败退款"
        )
        // 契约从没给过中文的那一支 ⇒ 「其他变动」，这是**已知降级**（§7 待答（3）），不是缺陷。
        XCTAssertEqual(
            row(entry(reason: "library_download_checkout", reasonLabel: nil))?.reasonText,
            CreditsLedgerCopy.otherChange
        )
        // 两个字段同时缺失 ⇒ 回落「其他变动」，不留空行（§7 ④）。
        XCTAssertEqual(row(entry(reason: nil, reasonLabel: nil))?.reasonText, CreditsLedgerCopy.otherChange)
        XCTAssertEqual(row(entry(reason: "   ", reasonLabel: "  "))?.reasonText, CreditsLedgerCopy.otherChange)
    }

    // MARK: - 金额与余额（§7「±」三条 + 异常值可空规则）

    func testDebitRendersMinusSignAndSpokenDirectionWord() {
        let facts = row(entry(amount: -20))
        XCTAssertEqual(facts?.amount?.displayText, "\u{2212}20")   // U+2212，不是半角连字符
        XCTAssertEqual(facts?.amount?.direction, .debit)
        XCTAssertEqual(facts?.amount?.spokenText, "扣 20 co")       // 念方向词，不念「减号」
    }

    func testCreditRendersPlusSignAndSpokenDirectionWord() {
        let facts = row(entry(amount: 20))
        XCTAssertEqual(facts?.amount?.displayText, "+20")
        XCTAssertEqual(facts?.amount?.direction, .credit)
        XCTAssertEqual(facts?.amount?.spokenText, "加 20 co")
    }

    func testZeroAmountHasNoSignSlotButIsStillDisplayed() {
        // 0 既不是入账也不是扣费 ⇒ 方向判不出（§7 第 ③ 档）：符号位**不渲染**，
        // 而数字本身是服务端给的，照显（不是"没给"）。
        let facts = row(entry(amount: 0))
        XCTAssertEqual(facts?.amount?.direction, .undirected)
        XCTAssertEqual(facts?.amount?.displayText, "0")
        XCTAssertEqual(facts?.amount?.spokenText, "0 co")
    }

    func testMissingAmountDropsOnlyTheAmountSlotAndKeepsTheRow() {
        let facts = row(entry(amount: nil))
        XCTAssertNotNil(facts)
        XCTAssertNil(facts?.amount)
        XCTAssertFalse(facts?.spokenLabel.contains(" co") ?? true)
        // 行不能因为少一个字段就消失（§7：明细行不能因缺字段消失）。
        XCTAssertEqual(facts?.reasonText, "AI 音乐生成")
    }

    func testSuspiciousBalanceShowsThePlaceholderInsteadOfTheNumber() {
        XCTAssertEqual(CreditsLedgerCopy.balanceValueText(-1), CreditsLedgerCopy.unknownValue)
        XCTAssertEqual(CreditsLedgerCopy.balanceValueText(nil), CreditsLedgerCopy.unknownValue)
        XCTAssertEqual(CreditsLedgerCopy.spokenBalance(-1), "余额未同步")
        // 「异常大」没有阈值档 ⇒ 与 `MineCopy.balance` 同一口径：**不自造阈值**。
        XCTAssertEqual(CreditsLedgerCopy.balanceValueText(9_999_999_999), "9999999999")
    }

    func testRealZeroBalanceIsDisplayedAsZeroNotAsPlaceholder() {
        // §8：0 不是错误态 ⇒ 「余额 0」照常显示、不用告警色、不加催促文案。
        XCTAssertEqual(CreditsLedgerCopy.balanceValueText(0), "0")
        XCTAssertEqual(CreditsLedgerCopy.spokenBalance(0), "余额 0")
        XCTAssertTrue(CreditsLedgerCopy.believableBalance(0) == 0)
    }

    // MARK: - §6 朗读：顺序即心智，缺位不留占位

    func testRowSpokenLabelOrder() {
        let facts = row(entry(amount: -20, balanceAfter: 108, jobId: nil))
        XCTAssertEqual(facts?.spokenLabel, "AI 音乐生成，扣 20 co，余额 108，2 小时前")
    }

    func testRowSpokenLabelEndsWithTheLinkOnlyWhenItExists() {
        let linked = row(entry(jobId: "job-1"))
        XCTAssertTrue(linked?.spokenLabel.hasSuffix("，任务") ?? false)
        let unlinked = row(entry(jobId: nil))
        XCTAssertFalse(unlinked?.spokenLabel.hasSuffix("，任务") ?? true)
    }

    func testMissingTimestampIsAbsentFromTheSpokenLabel() {
        // 时间缺失 ⇒ 那一格不渲染（不显示「—」噪声）⇒ 标签里也不许有一串空逗号。
        let facts = row(entry(createdAt: noTimestamp))
        XCTAssertNil(facts?.timeText)
        XCTAssertEqual(facts?.spokenLabel, "AI 音乐生成，扣 20 co，余额 108")
    }

    func testEmptyTimestampStringIsTreatedTheSameAsAbsent() {
        // 空串 / 纯空白也是"没给"，而不是"一个解析不出的时间戳"——表现必须一致：不渲染。
        for raw in ["", "   "] {
            let facts = row(entry(createdAt: raw))
            XCTAssertNil(facts?.timeText, "空白 createdAt（\(raw.debugDescription)）不该渲染")
            XCTAssertEqual(facts?.spokenLabel, "AI 音乐生成，扣 20 co，余额 108")
        }
    }

    func testFutureTimestampIsTreatedAsUntrusted() {
        // 两台机器各走各的钟 ⇒ 超前几秒的 `createdAt` 不钳成「刚刚」去编造新鲜度。
        let facts = row(entry(createdAt: iso(ago: -600)))
        XCTAssertNil(facts?.timeText)
    }

    // MARK: - 行身份与顺序（§7：`id` 缺失不渲染、客户端不重排）

    func testRowWithoutStableIDIsNotRendered() {
        XCTAssertNil(row(entry(id: nil)))
        XCTAssertNil(row(entry(id: "")))
        XCTAssertNil(row(entry(id: "  \n")))
    }

    func testServerOrderIsNeverResortedByTheClient() {
        // 故意给一份"时间正序"的响应：客户端若按 `createdAt` 重排，这一条就会红。
        let older = entry(id: "old", createdAt: iso(ago: 90_000))
        let newer = entry(id: "new", createdAt: iso(ago: 120))
        let state = readyState(with: [older, newer])
        XCTAssertEqual(
            state.rows(now: referenceNow, calendar: referenceCalendar).map(\.id), ["old", "new"]
        )
    }

    // MARK: - 读不出的行：要说一句，不许静默缩表（§7 + `CreditLedgerPageDto` 的可见面）

    func testUnreadableRowsAreCountedAndDisclosed() throws {
        let decoded = try decodePage(
            """
            {"entries":[
              {"id":"ok-1","amount":-20,"balanceAfter":108,"reason":"media_extra",
               "reasonLabel":"其他变动","createdAt":"\(iso(ago: 600))}"},
              {"amount":-5,"balanceAfter":103,"reason":"media_extra","reasonLabel":"其他变动"},
              null
            ]}
            """
        )
        XCTAssertEqual(decoded.entries.count, 1, "读不出 id 的行不能混进可渲染行")
        XCTAssertEqual(decoded.unreadableItemCount, 2)
        let state = readyState(with: decoded.entries, unreadable: decoded.unreadableItemCount)
        XCTAssertEqual(state.unreadableText, "2 条变动没读出来")
        // 差值看得见：屏上 1 行 + 一句"2 条没读出来"，而不是"1 行 + 沉默"。
        XCTAssertEqual(state.rows(now: referenceNow, calendar: referenceCalendar).count, 1)
        XCTAssertFalse(state.showsEmptyState)
    }

    func testNothingIsDisclosedWhenEverythingDecodedCleanly() {
        let state = readyState(with: [entry()], unreadable: 0)
        XCTAssertNil(state.unreadableText)
    }

    func testAnEntirelyUnreadablePayloadIsNotDrawnAsEmptyState() {
        // 「一条都没读出来」≠「这个账号没有变动记录」：前者不许说成后者。
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page([], unreadable: 3))
        XCTAssertFalse(state.showsEmptyState)
        XCTAssertEqual(state.unreadableText, "3 条变动没读出来")
        XCTAssertNil(state.tailText)
        XCTAssertEqual(state.phase, .ready)
    }

    func testDefinitivelyEmptyPayloadIsTheEmptyState() {
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page([]))
        XCTAssertTrue(state.showsEmptyState)
        XCTAssertNil(state.unreadableText)
    }

    // MARK: - 刷新失败的两格（§4：整屏 ④ vs ①Toast + 保留旧行）

    func testRefreshFailureKeepsOldRowsAndMarksThemStale() {
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page([entry(), entry(id: "led-2")]))
        let toasts = state.applyFailure(.network)
        XCTAssertTrue(toasts, "刷新失败要说一次「明细没取到」（①形态）")
        XCTAssertEqual(state.entries.count, 2, "失败不清行：屏上那一份仍是上一次读到的")
        XCTAssertTrue(state.outOfSync)
        XCTAssertTrue(state.showsUnsyncedMark)
        XCTAssertTrue(state.showsOfflineBanner)          // 网络类失败 ⇒ 17-S4 横幅
        XCTAssertFalse(state.showsWholeScreenFailure)
        XCTAssertEqual(state.phase, .ready)
    }

    func testNonNetworkRefreshFailureMarksStaleWithoutTheOfflineBanner() {
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page([entry()]))
        XCTAssertTrue(state.applyFailure(.server("HTTP 503")))
        XCTAssertTrue(state.showsUnsyncedMark)
        XCTAssertFalse(state.showsOfflineBanner, "服务端故障不是「离线」，两句话不能混")
    }

    func testFirstLoadFailureWithoutRowsIsAWholeScreenError() {
        var state = CreditsLedgerState(ownerID: "u-1")
        XCTAssertFalse(state.applyFailure(.server("HTTP 503")), "整屏那一格不再叠一条 Toast")
        XCTAssertTrue(state.showsWholeScreenFailure)
        XCTAssertFalse(state.showsSkeleton)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertFalse(state.showsOfflineBanner)   // 手里没有旧行 ⇒ 没有"上次内容"可展示
    }

    func testOfflineWithoutAnyCachedRowsIsTheOfflineLineNotASkeleton() {
        var state = CreditsLedgerState(ownerID: "u-1")
        _ = state.applyFailure(.network)
        XCTAssertTrue(state.showsWholeScreenFailure)
        XCTAssertEqual(state.failure?.userText, "离线：明细需要联网")
    }

    func testUnauthenticatedSaysSessionExpiredNotAServiceFault() {
        // 401/403 由会话层统一处理（§4：各屏不各自弹登录框），本屏只把这一句说实话。
        XCTAssertEqual(
            CreditsLedgerFailure.unauthenticated.userText, "登录状态已过期"
        )
        XCTAssertFalse(CreditsLedgerFailure.unauthenticated.isNetworkLike)
    }

    func testSuccessfulReadClearsTheStaleMark() {
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page([entry()]))
        _ = state.applyFailure(.network)
        XCTAssertTrue(state.outOfSync)
        state.apply(page([entry(), entry(id: "led-2")]))
        XCTAssertFalse(state.outOfSync)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.summaryText, "2 条变动")
    }

    func testSkeletonOnlyBelongsToAStateWithNothingToShow() {
        XCTAssertTrue(CreditsLedgerState().showsSkeleton)        // 还没发过
        var loading = CreditsLedgerState(ownerID: "u-1")
        loading.phase = .loading
        XCTAssertTrue(loading.showsSkeleton)
        loading.apply(page([entry()]))
        loading.phase = .loading                                  // 刷新在途：旧行还在
        XCTAssertFalse(loading.showsSkeleton, "刷新时保留旧行，不整屏重画骨架")
    }

    // MARK: - 摘要行（B）

    func testSummaryCountsLocallyRenderedEntriesOnly() {
        // 响应没有 `total` ⇒ 这一句只能是"本地已渲染条目数"，不能写成"共 N 条"。
        let state = readyState(with: [entry(id: "a"), entry(id: "b"), entry(id: "c")])
        XCTAssertEqual(state.summaryText, "3 条变动")
        XCTAssertFalse(state.summaryText?.contains("共") ?? true)
    }

    // MARK: - 私有小工具

    private func readyState(
        with entries: [CreditLedgerEntryDto], unreadable: Int = 0
    ) -> CreditsLedgerState {
        var state = CreditsLedgerState(ownerID: "u-1")
        state.apply(page(entries, unreadable: unreadable))
        return state
    }

    private func decodePageOrCrash(_ json: String) -> CreditLedgerPageDto {
        do {
            return try decodePage(json)
        } catch {
            XCTFail("这份响应必须解得开：\(error)")
            return CreditLedgerPageDto(entries: [], unreadableItemCount: 0)
        }
    }
}
