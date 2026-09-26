import Foundation
import XCTest

@testable import CovaCore

/// 20 屏的分页账（`WorksListPaging` / `WorksListGrouping`）。
///
/// 每一条钉的都是"错了会在屏上骗人"的那种映射，而不是"函数返回了个东西"：
/// · offset 型 cursor 会把上一页的尾巴再发一遍 ⇒ 折叠后必须**只剩一条**，且**记着折叠过**；
/// · `nextCursor == null` 就是到底 ⇒ 再发同一个游标只会把同一页拿第二遍；
/// · `total` 是整表条数 ⇒ 屏上没显示全时不许写「已显示全部」；
/// · rename/delete/share 是 **job 级** ⇒ 一次生成两行必须一起变、一起消失。
///
/// 行一律**从 JSON 解出来**（`WorksListRowDto` 刻意没有公开成员构造器：
/// 能凭空造一行的测试，也能凭空造出一行屏幕上不可能存在的数据）。
final class WorksListPagingTests: XCTestCase {

    // MARK: - 夹具

    private func row(_ body: String) throws -> WorksListRowDto {
        try JSONDecoder().decode(WorksListRowDto.self, from: Data(body.utf8))
    }

    private func page(_ body: String) throws -> WorksPageDto {
        try JSONDecoder().decode(WorksPageDto.self, from: Data(body.utf8))
    }

    /// 一行候选作品。`job` 不传就按 id 前段给（§4.7：`{jobId}:{candidateId}` 的前段就是 jobId）。
    private func candidate(_ id: String, title: String = "夏夜城市", job: String? = nil) -> String {
        let jobID = job ?? String(id.split(separator: ":").first.map(String.init) ?? id)
        return """
        {"id":"\(id)","jobId":"\(jobID)","status":"succeeded","title":"\(title)",\
        "audioUrl":"/api/media/objects/mo_1?intent=play","duration":158}
        """
    }

    private func merged(_ rows: [WorksListRowDto]) -> [WorksListRowDto] {
        WorksListPaging.merge(
            page: WorksPageDto(works: rows, nextCursor: nil, total: rows.count, unreadableItemCount: 0),
            onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        ).rows
    }

    // MARK: - 去重与累加（§4.7：cursor 是字符串化的行偏移）

    func testAppendedPageCollapsesRowsRepeatedAcrossTheOffsetBoundary() throws {
        let first = try page("""
        {"works":[\(candidate("job-1:cand-1"))],"nextCursor":"1","total":3}
        """)
        let ledger = WorksListPaging.merge(
            page: first, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        XCTAssertEqual(ledger.rows.map(\.id), ["job-1:cand-1"])
        XCTAssertEqual(ledger.acceptedCount, 1)
        XCTAssertEqual(ledger.duplicateCount, 0)

        // 第二页的头一行就是上一页的尾巴（服务端在两次翻页之间被插入了一行 ⇒ 偏移漂移）。
        let second = try page("""
        {"works":[\(candidate("job-1:cand-1")),\(candidate("job-1:cand-2", title: "副歌"))],\
        "nextCursor":null,"total":3}
        """)
        let merged = WorksListPaging.merge(
            page: second, onto: ledger.rows, unreadableSoFar: ledger.unreadableItemCount,
            totalSoFar: ledger.total, mode: .append
        )
        XCTAssertEqual(
            merged.rows.map(\.id), ["job-1:cand-1", "job-1:cand-2"],
            "整串同 id 的行只留第一次出现的那一条，位置也不动"
        )
        XCTAssertEqual(merged.acceptedCount, 1, "净进表一条")
        XCTAssertEqual(merged.duplicateCount, 1, "折叠掉的那一条必须记账，不能静默少行")
        XCTAssertFalse(merged.hasMorePages)
        XCTAssertEqual(merged.rows.first?.displayTitle, "夏夜城市", "留的是**先**到的那一行")
    }

    func testDeduplicationAlsoHoldsInsideASinglePage() throws {
        // `WorksPageDto` **刻意不去重**（它原样保留顺序与条数）；去重是分页这一层的账。
        let page = try page("""
        {"works":[\(candidate("job-9:cand-1")),\(candidate("job-9:cand-1")),\
        \(candidate("job-9:cand-2"))],"nextCursor":null,"total":3}
        """)
        XCTAssertEqual(page.works.count, 3, "DTO 层原样保留")
        let merged = WorksListPaging.merge(
            page: page, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        XCTAssertEqual(merged.rows.map(\.id), ["job-9:cand-1", "job-9:cand-2"])
        XCTAssertEqual(merged.duplicateCount, 1)
    }

    func testBareJobIdRowAndItsCandidateRowStayTwoSeparateRows() throws {
        // §4.7 四种形状：裸 jobId 行与 `{jobId}:{candidateId}` 行**不是**同一条，
        // 按"前缀相同"去重会把它们并成一行（那是把两种不同的可播性判据压成一个）。
        let page = try page("""
        {"works":[\(candidate("job-4")),\(candidate("job-4:cand-1"))],"nextCursor":null,"total":2}
        """)
        let merged = WorksListPaging.merge(
            page: page, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        XCTAssertEqual(merged.rows.map(\.id), ["job-4", "job-4:cand-1"])
        XCTAssertEqual(merged.duplicateCount, 0)
    }

    // MARK: - 游标纪律（§7 分页四条）

    func testCursorAdvanceStopsExactlyWhenServerStopsGivingOne() throws {
        let withMore = try page(#"{"works":[],"nextCursor":"6","total":8}"#)
        let done = try page(#"{"works":[],"nextCursor":null,"total":8}"#)
        XCTAssertTrue(withMore.hasMorePages)
        XCTAssertFalse(done.hasMorePages, "没有 nextCursor = 服务端没给下一页的入口")

        let query = WorksListQuery(filter: .liked, sort: .oldest)
        let advanced = try XCTUnwrap(query.advanced(toNextCursor: "6"))
        XCTAssertEqual(advanced.cursor?.rawValue, "6", "游标**原样**带走，不加前后缀")
        XCTAssertEqual(advanced.filter, .liked, "换页不许把选择态换掉")
        XCTAssertNil(query.advanced(toNextCursor: nil), "null = 到底，不许再发一次")
        XCTAssertNil(query.advanced(toNextCursor: "   "), "空白不是游标")
        XCTAssertNil(WorksListCursor.next(done.nextCursor))
    }

    func testQuerySendsNoCursorOnAFirstPageAndTheServersCursorOnAnAppend() {
        let first = WorksListQuery(filter: .disliked, search: "夏夜", sort: .newest)
        let items = first.queryItems
        XCTAssertFalse(items.contains { $0.name == "cursor" })
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "夏夜")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "30", "§7：本屏钉 30")
        XCTAssertEqual(
            items.map(\.name), ["q", "filter", "sort", "limit"],
            "任何时刻查询里最多一个 filter，也不发明别的键"
        )
        let next = try? XCTUnwrap(first.advanced(toNextCursor: "30"))
        let appended = try? XCTUnwrap(next?.queryItems)
        XCTAssertEqual(appended?.first { $0.name == "cursor" }?.value, "30")
    }

    func testRefusingToResendTheCursorTheServerJustGaveBack() {
        // 服务端把同一个偏移又回给我 ⇒ 再发一次只是把同一页拿第二遍（屏上一半是重复行）。
        XCTAssertFalse(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: "6", lastSentCursor: "6", pagesLoaded: 1, isReading: false
            )
        )
        XCTAssertTrue(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: "12", lastSentCursor: "6", pagesLoaded: 1, isReading: false
            )
        )
        XCTAssertFalse(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: "12", lastSentCursor: "6", pagesLoaded: 1, isReading: true
            ), "并发只留一条腿"
        )
        XCTAssertFalse(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: nil, lastSentCursor: "6", pagesLoaded: 1, isReading: false
            ), "没给入口就不是还有下一页 —— 也不许自己算一个偏移补上"
        )
    }

    func testAutoPagingStopsAtTheTenPageCeiling() {
        XCTAssertEqual(WorksListPaging.maximumConsecutivePages, 10)
        XCTAssertTrue(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: "270", lastSentCursor: "240",
                pagesLoaded: WorksListPaging.maximumConsecutivePages - 1, isReading: false
            )
        )
        XCTAssertFalse(
            WorksListPaging.canAdvanceToNextPage(
                nextCursor: "300", lastSentCursor: "270",
                pagesLoaded: WorksListPaging.maximumConsecutivePages, isReading: false
            ),
            "§8 极值：连续翻页 10 页后停止自动加载（offset 漂移随深度放大）"
        )
    }

    // MARK: - total 的账（§3.B 待答 1：口径未文档化 ⇒ 照原值说，不本地重算）

    func testShortfallKeepsTheServerNumberInsteadOfPretendingCompleteness() throws {
        let page = try page("""
        {"works":[\(candidate("job-1:cand-1"))],"nextCursor":null,"total":8}
        """)
        let merged = WorksListPaging.merge(
            page: page, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        XCTAssertEqual(merged.total, 8, "total 原值带走，不改成 rows.count")
        XCTAssertEqual(merged.missingRowCount, 7)

        // 读不出的行**计入已解释**，但整表仍没显示全 ⇒ 差额跟着减。
        XCTAssertEqual(WorksListPaging.shortfall(rows: 5, unreadable: 2, total: 8), 1)
        XCTAssertNil(WorksListPaging.shortfall(rows: 8, unreadable: 0, total: 8), "显示全了就不说这句")
        XCTAssertNil(WorksListPaging.shortfall(rows: 9, unreadable: 0, total: 8), "多出来的不是新事实")
        XCTAssertNil(WorksListPaging.shortfall(rows: 1, unreadable: 0, total: nil), "服务端没给 = 不说")
    }

    func testUnreadableItemsAccumulateAcrossPages() throws {
        let page = try page("""
        {"works":[\(candidate("job-2:cand-1"))],"nextCursor":"1","total":4}
        """)
        let first = WorksListPaging.merge(
            page: page, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        XCTAssertEqual(first.unreadableItemCount, 0)
        let second = WorksListPaging.merge(
            page: WorksPageDto(works: [], nextCursor: nil, total: 4, unreadableItemCount: 2),
            onto: first.rows, unreadableSoFar: first.unreadableItemCount,
            totalSoFar: first.total, mode: .append
        )
        XCTAssertEqual(second.unreadableItemCount, 2, "两页各数各的，不覆盖")
        XCTAssertEqual(second.missingRowCount, 1, "4 - (1 行 + 2 读不出)")
    }

    func testTotalSurvivesAnAppendThatDoesNotRepeatIt() throws {
        let first = try page("""
        {"works":[\(candidate("job-1:cand-1"))],"nextCursor":"1","total":8}
        """)
        let base = WorksListPaging.merge(
            page: first, onto: [], unreadableSoFar: 0, totalSoFar: nil, mode: .replace
        )
        let second = try page(#"{"works":[],"nextCursor":null}"#)   // 服务端这一发没带 total
        let merged = WorksListPaging.merge(
            page: second, onto: base.rows, unreadableSoFar: base.unreadableItemCount,
            totalSoFar: base.total, mode: .append
        )
        XCTAssertEqual(merged.total, 8, "缺 total 不等于 total 没了")
    }

    // MARK: - job 级作用域的本地账（§7 ③④）

    func testDeletingAJobRemovesEveryRowOfThatJobAcrossPages() throws {
        let rows = try [
            candidate("job-7:cand-1"), candidate("job-7:cand-2", title: "副歌"),
            candidate("job-8:cand-1"), candidate("job-7:cand-1", title: "漂移重复"),
        ].map { try row($0) }
        let onScreen = merged(rows)          // 先按分页规则折叠重复行
        XCTAssertEqual(onScreen.count, 3)
        let afterDelete = WorksListPaging.removing(rows: onScreen, anchor: "job-7")
        XCTAssertEqual(
            afterDelete.map(\.id), ["job-8:cand-1"],
            "一次 DELETE 作用在整个 job ⇒ 该 jobId 的全部行一起消失，不许只撤点到的那一行"
        )
    }

    func testRenameReadBackUpdatesBothRowsOfTheJobInPlace() throws {
        // 回读 `?id=job-2` 给的是该 job 的**全部**行（契约明写），顺序可能与屏上不同。
        let refreshed = try [
            candidate("job-2:cand-2", title: "新名", job: "job-2"),
            candidate("job-2:cand-1", title: "新名", job: "job-2"),
        ].map { try row($0) }
        let rows = try [
            candidate("job-1:cand-1"),
            candidate("job-2:cand-1", title: "旧名", job: "job-2"),
            candidate("job-3:cand-1"),
            candidate("job-2:cand-2", title: "旧名", job: "job-2"),
        ].map { try row($0) }
        let patched = WorksListPaging.applying(refreshed: refreshed, to: rows, anchor: "job-2")
        XCTAssertEqual(patched.count, 4, "回填不新增行（新增是分页那条腿的事）")
        XCTAssertEqual(patched.map(\.id), rows.map(\.id), "也不重排：整表顺序是服务端给的")
        XCTAssertEqual(patched[1].displayTitle, "新名")
        XCTAssertEqual(patched[3].displayTitle, "新名", "PATCH 响应是单数 work ⇒ 只补一行就是少补一行")
        XCTAssertEqual(patched[0].displayTitle, "夏夜城市", "别的组一个字都不动")
    }

    func testRenameReadBackLeavesRowsItCannotMatchAlone() throws {
        // 跨页时只取到了这一组的一行 ⇒ 回读给回两行，屏上那条换掉，另一条**不新增**。
        let refreshed = try [
            candidate("job-5:cand-1", title: "新名", job: "job-5"),
            candidate("job-5:cand-2", title: "新名", job: "job-5"),
        ].map { try row($0) }
        let rows = try [candidate("job-5:cand-1", title: "旧名", job: "job-5")].map { try row($0) }
        let patched = WorksListPaging.applying(refreshed: refreshed, to: rows, anchor: "job-5")
        XCTAssertEqual(patched.count, 1)
        XCTAssertEqual(patched[0].displayTitle, "新名")
    }

    // MARK: - 组头（§3.D）

    func testGroupingKeepsConsecutiveRowsTogetherAndRepeatsTheHeaderOnASplit() throws {
        let rows = try [
            candidate("job-a:cand-1"), candidate("job-a:cand-2"),
            candidate("job-b:cand-1"),
            candidate("job-a:cand-3"),   // offset 漂移把同一个 job 又送回一次 ⇒ 重新起一组
        ].map { try row($0) }
        let groups = WorksListGrouping.groups(in: rows)
        XCTAssertEqual(groups.map(\.anchor), ["job-a", "job-b", "job-a"])
        XCTAssertEqual(groups.map(\.rowCount), [2, 1, 1])
        XCTAssertEqual(groups.map(\.firstRowIndex), [0, 2, 3])
        XCTAssertEqual(groups.map(\.jobID), ["job-a", "job-b", "job-a"])
    }

    func testSingleRowGroupStillReadsAsAGroupOfOne() throws {
        let rows = try [candidate("job-only:cand-1")].map { try row($0) }
        let groups = WorksListGrouping.groups(in: rows)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rowCount, 1, "措辞不变成「这首」：这一格说的是作用域")
    }

    func testShareItemRendersOnlyForStudioCreateRows() throws {
        let cases: [(String, Bool)] = [
            ("studio-create", true), ("one-step", false), ("song-match", false),
        ]
        for (source, allowed) in cases {
            let item = try row(
                #"{"id":"job-s:c-1","jobId":"job-s","status":"succeeded","source":"\#(source)"}"#
            )
            let groups = WorksListGrouping.groups(in: [item])
            XCTAssertEqual(groups[0].canShare, allowed, source)
        }
        let missing = try row(#"{"id":"job-n:c-1","jobId":"job-n","status":"succeeded"}"#)
        XCTAssertFalse(
            WorksListGrouping.groups(in: [missing])[0].canShare,
            "认不出来源 = 没有分享目标 ⇒ 不渲染（不是置灰、不是点了再报错）"
        )
    }

    func testIrregularIdBecomesItsOwnGroupWithoutAJobHandle() throws {
        // 三段 id 不是契约里的任何一种形状 ⇒ 不猜 jobID，但仍是一行、仍要出现（不丢）。
        let odd = try row(#"{"id":"a:b:c","status":"succeeded"}"#)
        let groups = WorksListGrouping.groups(in: [odd])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].anchor, "a:b:c")
        XCTAssertNil(groups[0].jobID, "认不出 job 就不给一个猜的号（回读那条腿因此不发）")
    }

    func testPlaceholderGroupHasNothingForJobActionsToActOn() throws {
        let rows = try [
            #"{"id":"job-p:pending-1","jobId":"job-p","status":"processing","title":null}"#,
            #"{"id":"job-p:pending-2","jobId":"job-p","status":"queued","title":null}"#,
        ].map { try row($0) }
        let groups = WorksListGrouping.groups(in: rows)
        XCTAssertTrue(groups[0].isAllPlaceholders)
        XCTAssertEqual(groups[0].playableRowCount, 0)
        for item in rows {
            XCTAssertTrue(item.isPendingPlaceholder)
            XCTAssertFalse(item.isRealCandidateRow, "占位行不是作品正身 ⇒ 不给行内动作")
            XCTAssertFalse(item.isPlayable)
        }
    }

    // MARK: - 两个标记的可读性（§3.E / §4.7 互斥）

    func testConflictingAndDriftedSignalsAreBothUnrenderable() throws {
        let normal = try row(#"{"id":"j:c1","status":"succeeded","favorited":true}"#)
        XCTAssertTrue(normal.signalsAreReadable)
        XCTAssertTrue(normal.signalConflict == false)

        let conflicted = try row(
            #"{"id":"j:c2","status":"succeeded","favorited":true,"disliked":true}"#
        )
        XCTAssertTrue(conflicted.signalConflict)
        XCTAssertFalse(conflicted.signalsAreReadable, "服务端互斥被破坏 ⇒ 两个都不画")

        let drifted = try row(#"{"id":"j:c3","status":"succeeded","favorited":"yes"}"#)
        XCTAssertFalse(drifted.signalsAreReadable, "非布尔形状读不出 = 不是「用户没点过心」")
        XCTAssertFalse(drifted.favorited, "回落值本身仍是 false（那是服务端行为，不是本机填的）")

        let absent = try row(#"{"id":"j:c4","status":"succeeded"}"#)
        XCTAssertTrue(absent.signalsAreReadable, "两个键都不发 = 两个都是 false（§4.7）")
    }
}
