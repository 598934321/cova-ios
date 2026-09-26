@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/me/credits/ledger` 的契约面（DEVELOPMENT.md §4.6/§4.7 + A9 + §7 #38）。
///
/// 三条承重判据：
/// ① 请求侧只有 `limit`，响应侧只有 `entries` ⇒ 「共 N 条」「下一页」「当前余额」在本层
///    **拿不到数据**，类型上也就没有那三个字段（有字段就会有人去渲染它）；
/// ② `reasonLabel` 是服务端映射表给的字符串（24 个在写的 reason 里 13 个落到「其他变动」）⇒
///    客户端**原样显示，绝不重映射**；本层的 reason 枚举只用于分支，一个中文字都不带；
/// ③ `jobId` 可为 null（§7 #38 记的生产实测：`studio_create_generation` 那一支今天恒 null）⇒
///    不渲染「任务」链接、不猜一个号。
final class LedgerDTOTests: XCTestCase {

    // MARK: - ① 只有 entries

    func testPageDecodesEveryEntryAndKeepsTheServerOrder() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-entries")
        XCTAssertEqual(page.entries.count, 7)
        XCTAssertEqual(page.unreadableItemCount, 0)
        // 排序固定 `createdAt DESC, id DESC` 是服务端的账 ⇒ 本层**不重排**。
        // 这条断言的意义在反向：谁加了一次 sort，最后一行（日期最旧）就会跑到最前面。
        XCTAssertEqual(page.entries.map { $0.resolvedId }, [
            "cl_0001", "cl_0002", "cl_0003", "cl_0004", "cl_0005", "cl_0006", "cl_0007",
        ])
        XCTAssertEqual(page.entries.first?.createdAt, "2026-09-26T08:10:00.000Z")
        XCTAssertEqual(page.entries.last?.createdAt, "2026-09-19T09:00:00.000Z")
    }

    /// 服务端**没有** total / nextCursor / balance ⇒ 本类型没有那三个属性（不建模不发的键）。
    /// 就算响应里偷偷多出这三个键，也读不出、更渲染不了。
    func testNoTotalNoCursorNoBalanceAreModelled() throws {
        let page = try JSONDecoder().decode(
            CreditLedgerPageDto.self,
            from: Data(#"{"entries":[],"total":1234,"nextCursor":"abc","balance":99,"limit":50}"#.utf8)
        )
        let labels = Set(Mirror(reflecting: page).children.compactMap(\.label))
        XCTAssertEqual(labels, ["entries", "unreadableItemCount"])
        XCTAssertTrue(page.entries.isEmpty)
    }

    /// 空流水与读不懂是两件事（同 producers 那条判据）。
    func testMissingEntriesKeyThrowsInsteadOfReadingAsNoEntries() {
        for body in ["{}", #"{"entries":null}"#, #"{"entries":"none"}"#, #"{"history":[]}"#, "[]"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(CreditLedgerPageDto.self, from: Data(body.utf8)),
                "\(body) 不许被读成「这个账号还没有账目」"
            )
        }
        XCTAssertNoThrow(
            try JSONDecoder().decode(CreditLedgerPageDto.self, from: Data(#"{"entries":[]}"#.utf8))
        )
    }

    func testGarbageRowsAreCountedNotSilentlyDropped() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-garbage-rows")
        XCTAssertEqual(page.entries.count, 1, "四个读不出的元素之后那一条必须还活着")
        XCTAssertEqual(page.unreadableItemCount, 4)
        XCTAssertEqual(page.entries.first?.resolvedId, "cl_survivor")
        XCTAssertEqual(page.entries.first?.linkedJobId, "job-x")
    }

    /// 读不出身份的四种形状：非对象、`null` 元素、缺 `id`、`id` 为空串或纯空白。
    func testIdentityIsTheOnlyHardRequirement() throws {
        let page = try JSONDecoder().decode(
            CreditLedgerPageDto.self,
            from: Data(#"{"entries":["x",null,{"amount":-1},{"id":"   "},{"id":"ok","amount":-1}]}"#.utf8)
        )
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.unreadableItemCount, 4)
        XCTAssertNil(page.entries.first?.reason, "活下来的那条只有 id 与金额 —— 其余一律 nil")
    }

    // MARK: - ② reasonLabel 逐字，枚举不带文案

    func testDisplayReasonIsTheServerStringVerbatimIncludingTheFallbackBucket() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-entries")
        let mediaExtra = try XCTUnwrap(page.entries.first { $0.reason == "media_extra" })
        // 这一条就是"13/24 落到其他变动"的形状：枚举认得这个 reason，但文案仍然吃服务端那句。
        XCTAssertEqual(mediaExtra.reasonKind, .mediaExtra)
        XCTAssertEqual(mediaExtra.displayReason, "其他变动", "本层不许映射成「补充制作」")
        let shop = try XCTUnwrap(page.entries.first { $0.reasonKind?.rawReason == "inspiration_shop_purchase" })
        XCTAssertEqual(shop.reasonKind, .unknown("inspiration_shop_purchase"), "词表外的值不丢行")
        XCTAssertEqual(shop.displayReason, "其他变动")
    }

    /// 没给 `reasonLabel` ⇒ nil。**不**在这里回落成「其他变动」——那一句是**服务端**的映射结果，
    /// 客户端兜一次就有两套口径（而且兜出来的那句和真兜出来的那句在屏幕上分不开）。
    func testMissingReasonLabelStaysNilAndIsNotReplacedByTheFallbackWord() throws {
        let entry = try JSONDecoder().decode(
            CreditLedgerPageDto.self,
            from: Data(#"{"entries":[{"id":"cl_x","reason":"daily_checkin"}]}"#.utf8)
        ).entries.first
        XCTAssertNil(try XCTUnwrap(entry).displayReason)
        XCTAssertEqual(entry?.reasonKind, .dailyCheckin, "分支判断仍然可用")
    }

    /// 词表与真实 reason 的同步关系由这条钉住：`generation_refund` **不是真实值**
    /// （§4.6 的旧措辞已被 §4.7 就地推翻）。它必须落 `.unknown`，而不是被我"顺手"补成已知档。
    func testTheRetiredRefundSpellingIsNotAKnownReason() {
        XCTAssertEqual(
            CreditLedgerReason(rawReason: "generation_refund"),
            .unknown("generation_refund")
        )
        XCTAssertEqual(CreditLedgerReason(rawReason: "cova_one_step_generation_refund"),
                       .covaOneStepGenerationRefund)
        XCTAssertEqual(CreditLedgerReason(rawReason: "cova_ai_agent_generation_refund").rawReason,
                       "cova_ai_agent_generation_refund")
        XCTAssertTrue(CreditLedgerReason.covaAiAgentGenerationRefund.isRefund)
        XCTAssertTrue(CreditLedgerReason.covaOneStepGenerationRefund.isRefund)
        XCTAssertFalse(CreditLedgerReason.studioCreateGeneration.isRefund)
    }

    /// 已知词表 = §4.7 逐条实测确认过的那些（灵感商店一族与 admin 三件未实测 ⇒ 不进词表）。
    func testKnownReasonTableIsExactlyTheMeasuredVocabulary() {
        XCTAssertEqual(
            Set(CreditLedgerReason.knownRawReasons.keys),
            [
                "studio_create_generation", "cova_one_step_generation", "cova_ai_agent_generation",
                "cova_one_step_generation_refund", "cova_ai_agent_generation_refund",
                "media_extra", "library_download_checkout", "daily_checkin",
                "iap_credits_purchase",
            ] as Set<String>
        )
        // 只有生成/补充制作这一族有"任务"可跳；库曲订单与签到没有。
        XCTAssertTrue(CreditLedgerReason.studioCreateGeneration.isGenerationBearing)
        XCTAssertTrue(CreditLedgerReason.mediaExtra.isGenerationBearing)
        XCTAssertFalse(CreditLedgerReason.libraryDownloadCheckout.isGenerationBearing)
        XCTAssertFalse(CreditLedgerReason.dailyCheckin.isGenerationBearing)
        XCTAssertFalse(CreditLedgerReason(rawReason: "anything_new").isGenerationBearing)
    }

    // MARK: - ③ jobId / unlinked：能不能跳去任务

    func testNullJobIDLinksNothingAndIsReportedUnlinked() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-entries")
        let studio = try XCTUnwrap(page.entries.first { $0.reason == "studio_create_generation" })
        XCTAssertNil(studio.linkedJobId, "§7 #38：这一支今天在生产上恒 null")
        XCTAssertFalse(studio.canLinkToJob, "A9 的「点击任务跳转」在这一行没有落点")
        XCTAssertTrue(studio.isUnlinked)
        XCTAssertFalse(studio.linkageDrift, "服务端两个字段今天说的是同一件事")
        XCTAssertEqual(
            page.linkableEntries.compactMap(\.resolvedId), ["cl_0002", "cl_0003"],
            "空串 jobId 的 cl_0005 与 null jobId 的都不算挂了任务"
        )
    }

    /// **空串 jobId** 与 null 同义：那是"解不出 metadata.jobId"的另一种写法，不是可跳转的号。
    func testEmptyStringJobIDIsNotALink() throws {
        let entry = try JSONDecoder().decode(
            CreditLedgerPageDto.self, from: Data(#"{"entries":[{"id":"e","jobId":""}]}"#.utf8)
        ).entries.first
        XCTAssertNil(try XCTUnwrap(entry).linkedJobId)
        XCTAssertFalse(try XCTUnwrap(entry).canLinkToJob)
        XCTAssertTrue(try XCTUnwrap(entry).isUnlinked)
    }

    /// `unlinked` 缺键 ⇒ 按服务端的定义式（`unlinked == (jobId == nil)`）派生；
    /// 两个字段打架 ⇒ 不判谁对，只把漂移数出来（`linkageDrift`）。
    func testUnlinkedIsDerivedWhenAbsentAndContradictionsAreReportedNotResolved() throws {
        let page = try JSONDecoder().decode(
            CreditLedgerPageDto.self,
            from: Data(#"{"entries":[{"id":"a","jobId":"job-1"},{"id":"b"},{"id":"c","jobId":"job-2","unlinked":true},{"id":"d","jobId":null,"unlinked":false}]}"#.utf8)
        )
        let entries = Dictionary(
            uniqueKeysWithValues: page.entries.compactMap { entry in
                entry.resolvedId.map { ($0, entry) }
            }
        )
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries["a"]?.isUnlinked, false, "缺 unlinked：jobId 在 ⇒ 挂着")
        XCTAssertEqual(entries["b"]?.isUnlinked, true, "缺 unlinked：jobId 不在 ⇒ 没挂")
        XCTAssertFalse(entries["b"]!.linkageDrift, "两个都缺不是漂移")
        // c：服务端自己打架。本层以"能不能跳"为准（jobId 是那个载荷），但把冲突留下记录。
        XCTAssertEqual(entries["c"]?.canLinkToJob, true)
        XCTAssertEqual(entries["c"]?.linkageDrift, true)
        XCTAssertEqual(page.driftingEntries.map { $0.resolvedId }, ["c", "d"])
        XCTAssertEqual(entries["d"]?.isUnlinked, true, "false 而无 jobId 也是打架")
    }

    // MARK: - 金额与类型：不猜方向、不填零

    /// `amount` 建模为整数（co 币在服务端是整数）。读不出 ⇒ nil，**不填 0**：
    /// 0 会被渲染成「+0 co」，那是把一次契约漂移说成一笔零元账。
    func testAmountAndBalanceAfterNeverBecomeZeroOnFailure() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-entries")
        let drifted = try XCTUnwrap(page.entries.first { $0.resolvedId == "cl_0007" })
        XCTAssertNil(drifted.amount, "金额是个字符串而不是数字：读不出就是读不出")
        XCTAssertNil(drifted.balanceAfter, "null 余额不许读成 0")
        XCTAssertNil(drifted.creditedAmount)
        XCTAssertNil(drifted.debitedAmount)
        XCTAssertNil(drifted.reasonKind, "reason 是 null，不编一个空串的 unknown")
        XCTAssertNil(drifted.displayReason)

        let debit = try XCTUnwrap(page.entries.first { $0.resolvedId == "cl_0001" })
        XCTAssertEqual(debit.amount, -100)
        XCTAssertEqual(debit.debitedAmount, -100)
        XCTAssertNil(debit.creditedAmount, "方向只看 amount 的正负，不看 type")
        let credit = try XCTUnwrap(page.entries.first { $0.resolvedId == "cl_0003" })
        XCTAssertEqual(credit.creditedAmount, 20)
        XCTAssertNil(credit.debitedAmount)
        XCTAssertEqual(credit.balanceAfter, 19435)
    }

    /// 零元账（服务端真给 0）与读不出（nil）必须分得开。
    func testZeroAmountIsAFactNotAMissingValue() throws {
        let entry = try JSONDecoder().decode(
            CreditLedgerPageDto.self, from: Data(#"{"entries":[{"id":"e","amount":0}]}"#.utf8)
        ).entries.first
        XCTAssertEqual(try XCTUnwrap(entry).amount, 0)
        XCTAssertNil(try XCTUnwrap(entry).creditedAmount, "0 既不是入账也不是出账")
        XCTAssertNil(try XCTUnwrap(entry).debitedAmount)
    }

    /// `type` 的取值集没在生产里钉死 ⇒ 松散字符串原样留着（本层不据它判方向）。
    func testEntryTypeIsKeptLooseBecauseItsVocabularyWasNeverMeasured() throws {
        let page = try Fixture.decode(CreditLedgerPageDto.self, "ledger-entries")
        XCTAssertEqual(Set(page.entries.compactMap(\.type)), ["debit", "credit"])
        let future = try JSONDecoder().decode(
            CreditLedgerPageDto.self,
            from: Data(#"{"entries":[{"id":"e","type":"refund_like","amount":1}]}"#.utf8)
        )
        XCTAssertEqual(future.entries.first?.type, "refund_like", "新值不许让这一行消失")
        XCTAssertEqual(future.unreadableItemCount, 0)
    }

    // MARK: - ④ 请求构造：只有 limit

    func testLimitIsClampedIntoTheServerWindow() {
        XCTAssertEqual(CreditLedgerQuery.defaultLimit, 50, "服务端默认 50")
        XCTAssertEqual(CreditLedgerQuery.minimumLimit, 1)
        XCTAssertEqual(CreditLedgerQuery.maximumLimit, 100)
        XCTAssertEqual(CreditLedgerQuery().limit, 50)
        XCTAssertEqual(CreditLedgerQuery(limit: 0).limit, 1)
        XCTAssertEqual(CreditLedgerQuery(limit: -5).limit, 1)
        XCTAssertEqual(CreditLedgerQuery(limit: 101).limit, 100)
        XCTAssertEqual(CreditLedgerQuery(limit: 1_000_000).limit, 100)
        XCTAssertEqual(CreditLedgerQuery.maximumVisibleEntries, 100, "「只能看最近 100 条」")
    }

    /// 只有 `limit` 这一个键；`offset` / `cursor` / `page` / `type` 服务端都不读 ⇒ 一个都不发。
    func testQueryEmitsExactlyOneKeyAndNeverTheOnesThatDoNotExist() {
        for limit in [1, 50, 100, 500] {
            let items = CreditLedgerQuery(limit: limit).queryItems
            XCTAssertEqual(items.count, 1, "多一个键就是多发一个服务端不读的参数")
            XCTAssertEqual(items[0].name, "limit")
            XCTAssertEqual(items[0].value, String(min(max(limit, 1), 100)))
        }
        let names = CreditLedgerQuery(limit: 10).queryItems.map(\.name)
        for forbidden in ["offset", "cursor", "page", "pageSize", "type", "reason", "since", "until"] {
            XCTAssertFalse(names.contains(forbidden), "发了服务端不存在的 \(forbidden)")
        }
    }

    /// 类型面上也拿不到那些参数（留了参数就等于以为自己真在翻页）。
    func testQueryHasNoPagingSurfaceAtAll() throws {
        let labels = Set(Mirror(reflecting: CreditLedgerQuery(limit: 50)).children.compactMap(\.label))
        XCTAssertEqual(labels, ["limit"])
        XCTAssertEqual(CreditLedgerQuery.path, "/api/me/credits/ledger")
        let url = try XCTUnwrap(
            CovaEnvironment.makeAPIURL(
                path: CreditLedgerQuery.path, queryItems: CreditLedgerQuery(limit: 10).queryItems
            )
        )
        XCTAssertEqual(url.absoluteString, "https://covalink.cn/api/me/credits/ledger?limit=10")
    }
}
