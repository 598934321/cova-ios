import CovaCore
import CovaPlayer
import Foundation
import XCTest

@testable import CovaFeature

/// 20 · 作品列表的分页账、写动作回显与媒体出口（§5 P1-1 / 验收 A5·A6·A7）。
///
/// 这一层**不测视图渲染**（TD-48：CovaFeature 只钉纯函数与媒体腿，界面的可信证据是截图 +
/// `CovaAcceptanceTests` 那条设备链）。这里钉的是"屏上那句话从哪来"的三段因果：
/// · **在途合并**：`WorksListState` 是屏上那本账的唯一写入点，代际闸门是它唯一的守卫
///   —— 迟到的响应如果能落账，用户点「制作中」看到的会是「全部」那一页；
/// · **写动作**：乐观态、显式布尔、权威回显不符即回落（`WorkActionToggle` 那三格的端到端形状）；
/// · **播放 / 直存**：伪 trackId 逐字带走 + 同源 `intent=download`（§7 #39 推翻 #37 之后
///   唯一能出声、能落盘的那条腿，与 19 同一条）。
///
/// 为什么异步的 `AppSession` 方法不在这里跑：`worksService` 由 `client` 现场构造，
/// 而 `client` 在 `AppSession.init` 里装配（没有注入点，本轮也不改那个文件）⇒
/// 这一层的可测面就是状态机的每一次变更 + 两个静态映射，
/// **它们正是异步腿里唯一会写屏的两格**（发什么、落成什么）。
@MainActor
final class WorksListFlowTests: XCTestCase {

    // MARK: - 夹具

    private func decodedRow(_ body: String) throws -> WorksListRowDto {
        try JSONDecoder().decode(WorksListRowDto.self, from: Data(body.utf8))
    }

    private func decodedPage(_ body: String) throws -> WorksPageDto {
        try JSONDecoder().decode(WorksPageDto.self, from: Data(body.utf8))
    }

    /// 一行可播的候选（`extra` 是逗号分隔的附加键，形状与生产一致）。
    private func candidate(
        _ id: String, title: String = "夏夜城市", extra: String = ""
    ) -> String {
        let jobID = String(id.split(separator: ":").first.map(String.init) ?? id)
        return """
        {"id":"\(id)","jobId":"\(jobID)","status":"succeeded","title":"\(title)",\
        "source":"studio-create","audioUrl":"/api/media/objects/mo_1?ref=mr_1&intent=play"\
        \(extra.isEmpty ? "" : ",\(extra)")}
        """
    }

    private func oneRowPage(_ id: String, nextCursor: String, total: Int) -> String {
        """
        {"works":[\(candidate(id))],"nextCursor":\(nextCursor == "null" ? "null" : "\"\(nextCursor)\""),\
        "total":\(total)}
        """
    }

    /// 生产实测形态（§4.7：`audioUrl` 是**站内相对**路径 + `intent=play`；
    /// 服务端对它会 302 到名单外的 uploads 桶 ⇒ 客户端必须先换成 `intent=download`）。
    private let playableRowJSON = """
    {"id":"job-a:cand-1","jobId":"job-a","status":"succeeded","title":"夏夜城市",\
    "coverUrl":"/covers/a.jpeg","audioUrl":"/api/media/objects/mo_9f3a?ref=mr_1&intent=play",\
    "duration":158.4,"instrumental":false,"createdAt":"2026-09-26T03:00:00.000Z",\
    "source":"studio-create","lyrics":"第一行\\n第二行"}
    """

    private let placeholderJSON = """
    {"id":"job-b:pending-1","jobId":"job-b","status":"processing","title":null,\
    "coverUrl":null,"audioUrl":null,"duration":null}
    """

    // MARK: - 代际闸门（要求④：迟到的响应不许盖掉更新的选择）

    func testLandingAFirstPageSetsTheWholeLedger() throws {
        var state = WorksListState()
        let generation = state.beginReplacementRead()
        XCTAssertEqual(state.phase, .loading, "手里没内容时首载是整屏骨架，不是空态")
        XCTAssertTrue(state.isReading)
        let page = try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "1", total: 8))
        XCTAssertTrue(state.apply(page, for: .replace, generation: generation))
        XCTAssertEqual(state.phase, .loaded)
        XCTAssertEqual(state.rows.map(\.id), ["job-a:cand-1"])
        XCTAssertEqual(state.total, 8)
        XCTAssertEqual(state.nextCursor?.rawValue, "1")
        XCTAssertEqual(state.pagesLoaded, 1)
        XCTAssertFalse(state.isReading)
    }

    func testSupersededResponseCannotOverwriteTheNewerSelection() throws {
        var state = WorksListState()
        // ①「全部」那一发先出发（还没回）。
        let firstGeneration = state.beginReplacementRead()
        // ② 用户随即点「制作中」：推进代际 + 游标归零。
        let secondGeneration = state.beginReplacementRead(filter: .generating)
        XCTAssertNotEqual(firstGeneration, secondGeneration, "每一次选择变更都要有自己的代号")
        XCTAssertEqual(state.filter, .generating)

        // ③ 迟到的「全部」那一页回来了 —— 必须**一个字都不落**。
        let late = try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "1", total: 8))
        XCTAssertFalse(
            state.apply(late, for: .replace, generation: firstGeneration),
            "代际不匹配的响应整包丢弃：屏上写着「制作中」而列表是「全部」那一页，就是这一格在骗人"
        )
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertNil(state.total)
        XCTAssertNil(state.nextCursor)
        XCTAssertEqual(state.pagesLoaded, 0)
        XCTAssertEqual(state.filter, .generating, "落账失败也不该顺手动选择态")

        // ④ 当代那一发仍然可以正常落账。
        let mine = try decodedPage(#"{"works":[],"nextCursor":null,"total":0}"#)
        XCTAssertTrue(state.apply(mine, for: .replace, generation: secondGeneration))
        XCTAssertEqual(state.phase, .empty, "服务端确实给了 0 行 = 事实，不是失败")
    }

    func testSupersededFailureCannotClobberTheNewerReadEither() throws {
        var state = WorksListState()
        let stale = state.beginReplacementRead()
        let current = state.beginReplacementRead(sort: .oldest)
        XCTAssertFalse(state.fail(message: "网络没通", for: .replace, generation: stale))
        XCTAssertEqual(state.phase, .loading, "旧一代的失败不能把屏判成错误")
        XCTAssertTrue(state.fail(message: "网络没通", for: .replace, generation: current))
        XCTAssertEqual(state.phase, .failed(message: "网络没通"))
    }

    func testASecondWriteOnTheSameRowIsSwallowed() {
        // §8 并发通则：同一行的 ♡ 与 ⋯「不喜欢」在途只允许一个写，后到者**被吞**。
        var state = WorksListState()
        XCTAssertTrue(state.beginWrite(key: "job-a:cand-1"))
        XCTAssertFalse(state.beginWrite(key: "job-a:cand-1"))
        XCTAssertTrue(state.hasWriteInFlight(key: "job-a:cand-1"))
        state.endWrite(key: "job-a:cand-1")
        XCTAssertTrue(state.beginWrite(key: "job-a:cand-1"), "撤了账才能再写")
        state.endWrite(key: "job-a:cand-1")
        XCTAssertFalse(state.hasWriteInFlight(key: "job-a:cand-1"))
    }

    // MARK: - 分页合并（要求③：append + 按 id 去重；nextCursor == null 即到底）

    func testAppendDeduplicatesAndStopsExactlyAtNullCursor() throws {
        var state = WorksListState()
        let generation = state.beginReplacementRead()
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "1", total: 3)),
                for: .replace, generation: generation
            )
        )
        XCTAssertTrue(state.canLoadMorePages)

        let appendGeneration = state.beginAppendRead()
        XCTAssertEqual(state.activeRead, .append)
        // 第二页的头一行就是上一页的尾巴（服务端在两次翻页之间被插入了一行 ⇒ 偏移漂移）。
        let second = try decodedPage("""
        {"works":[\(candidate("job-a:cand-1")),\(candidate("job-a:cand-2", title: "副歌"))],\
        "nextCursor":null,"total":3}
        """)
        XCTAssertTrue(state.apply(second, for: .append, generation: appendGeneration))
        XCTAssertEqual(
            state.rows.map(\.id), ["job-a:cand-1", "job-a:cand-2"],
            "offset 漂移送回来的重复行折叠成一条"
        )
        XCTAssertNil(state.nextCursor)
        XCTAssertFalse(state.canLoadMorePages, "到底了：绝不再发一次同一个游标")
        XCTAssertTrue(state.reachedEnd)
        XCTAssertEqual(state.pagesLoaded, 2)
    }

    func testAppendCannotStartWhileAReadIsAlreadyInFlight() {
        var state = WorksListState()
        state.beginReplacementRead()
        let before = state.readGeneration
        let returned = state.beginAppendRead()
        XCTAssertEqual(returned, before, "判据不过就不该领新的代际")
        XCTAssertNotEqual(state.activeRead, .append, "也不能把账翻成「有一页在途」")
        XCTAssertFalse(state.canLoadMorePages)
    }

    func testTheAppendRequestCarriesExactlyTheServersCursorAndTheCurrentSelection() throws {
        var state = WorksListState()
        var generation = state.beginReplacementRead(filter: .liked, sort: .oldest)
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "30", total: 60)),
                for: .replace, generation: generation
            )
        )

        generation = state.beginAppendRead()
        let items = state.query(for: .append).queryItems
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "30", "只回传服务端给的那一个")
        XCTAssertEqual(items.first { $0.name == "filter" }?.value, "liked", "换页不换选择")
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "oldest")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "30", "§7：本屏钉 30，不写 100")
        XCTAssertNil(items.first { $0.name == "q" }, "空搜索不发空值键")
        XCTAssertEqual(
            items.map(\.name), ["filter", "sort", "cursor", "limit"],
            "键序与键集都在契约卡列出的五个里，不发明第六个"
        )
    }

    func testEverySelectionChangeLandsARequestWithoutAnyCursor() throws {
        var state = WorksListState()
        let generation = state.beginReplacementRead()
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "1", total: 3)),
                for: .replace, generation: generation
            )
        )
        XCTAssertNotNil(state.nextCursor, "上一发确实拿到了下一页游标")
        XCTAssertEqual(state.pagesLoaded, 1)

        let mutations: [(String, (inout WorksListState) -> Void)] = [
            ("切筛选", { $0.filter = .vocal }),
            ("换排序", { $0.sort = .oldest }),
            ("改搜索", { $0.search = "夏夜" }),
            ("下拉刷新", { _ in }),
        ]
        for (label, mutate) in mutations {
            var probe = state
            mutate(&probe)
            probe.beginReplacementRead()
            XCTAssertFalse(
                probe.query(for: .replace).queryItems.contains { $0.name == "cursor" },
                "\(label)之后的第一个请求不能带 cursor"
            )
            XCTAssertEqual(probe.pagesLoaded, 0, "\(label)之后分页账整本重开")
            XCTAssertNil(probe.lastSentCursor, "\(label)也不留着上一次发过的游标")
        }
    }

    func testTenConsecutivePagesStopTheAutoLoaderButRefreshRestartsIt() throws {
        var state = WorksListState()
        var generation = state.beginReplacementRead()
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "30", total: 900)),
                for: .replace, generation: generation
            )
        )
        var offset = 30
        for _ in 0..<(WorksListPaging.maximumConsecutivePages - 1) {
            XCTAssertTrue(state.canLoadMorePages, "取满 10 页之前都该还能自动取")
            generation = state.beginAppendRead()
            offset += 30
            XCTAssertTrue(
                state.apply(
                    try decodedPage(
                        oneRowPage("job-\(offset):cand-1", nextCursor: "\(offset)", total: 900)
                    ),
                    for: .append, generation: generation
                )
            )
        }
        XCTAssertEqual(state.pagesLoaded, WorksListPaging.maximumConsecutivePages)
        XCTAssertFalse(
            state.canLoadMorePages,
            "§8 极值：连翻 10 页后停止**自动**加载（offset 漂移随深度放大）"
        )
        let before = state.readGeneration
        generation = state.beginReplacementRead()
        XCTAssertGreaterThan(state.readGeneration, before)
        XCTAssertEqual(state.pagesLoaded, 0, "下拉刷新 = 从第一页重取，账本整本重开")
        XCTAssertFalse(state.canLoadMorePages, "刷新在途时也不许并发第二发")
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "30", total: 900)),
                for: .replace, generation: generation
            )
        )
        XCTAssertTrue(state.canLoadMorePages, "上限只砍**自动连翻**，不砍这一次刷新之后的正常翻页")
    }

    func testTotalShortfallIsDeclaredInsteadOfPretendingCompleteness() throws {
        var state = WorksListState()
        let generation = state.beginReplacementRead()
        // 服务端说整表 8 条，只给回 1 条且没下一页入口 ⇒ 屏上不许写「已显示全部」。
        XCTAssertTrue(
            state.apply(
                try decodedPage(oneRowPage("job-a:cand-1", nextCursor: "null", total: 8)),
                for: .replace, generation: generation
            )
        )
        XCTAssertEqual(state.missingRowCount, 7)
        XCTAssertTrue(state.mustDeclareIncompleteness)
        XCTAssertEqual(state.total, 8, "不本地重算成 rows.count")
        XCTAssertTrue(state.reachedEnd, "到底与没显示全**同时成立**，这正是必须说实话的那一格")
    }

    func testUnreadableRowsCountTowardTheExplanationNotTowardSilence() throws {
        var state = WorksListState()
        let generation = state.beginReplacementRead()
        // 一行没有 id ⇒ 整页不解体，只把这一行记成「读不出」（CovaCore 的逐行容错腿）。
        let page = try decodedPage("""
        {"works":[{"id":"","status":"succeeded"},{"id":"job-a:cand-1","status":"succeeded"}],\
        "nextCursor":null,"total":2}
        """)
        XCTAssertTrue(state.apply(page, for: .replace, generation: generation))
        XCTAssertEqual(state.rows.count, 1)
        XCTAssertEqual(state.unreadableItemCount, 1)
        XCTAssertNil(state.missingRowCount, "1 行 + 1 读不出 = 2 条 ⇒ 没有没解释的行")
    }

    // MARK: - ♡ / 不喜欢（要求⑤：显式布尔 + 权威回显 + 回落）

    func testUnFavoritingSendsAnExplicitFalseKeyNotAnOmittedOne() throws {
        // §4.7 三条坑的第①条：服务端读 `body.favorite` 并**缺省为 true** ⇒
        // 取消收藏只有"发出去一个货真价实的 false"这一条路。这一条断的是**字节形状**。
        let off = try JSONEncoder().encode(WorkFavoriteRequestDto(.requesting(state: false)))
        XCTAssertTrue(
            String(decoding: off, as: UTF8.self).contains(#""favorite":false"#),
            "取消必须落一个显式 false"
        )
        XCTAssertFalse(WorkFavoriteRequestDto(.requesting(state: false)).serverEffectiveState)

        let on = try JSONEncoder().encode(WorkFavoriteRequestDto(.requesting(state: true)))
        XCTAssertTrue(String(decoding: on, as: UTF8.self).contains(#""favorite":true"#))

        // 缺键的那一格读回来仍然是「缺键」，而它的**服务端语义是 true**（最坑人的一格：
        // 本屏的任何一条路径都不许走到它，包括"忘了赋值"）。
        let omitted = try JSONDecoder().decode(
            WorkFavoriteRequestDto.self, from: Data("{}".utf8)
        )
        XCTAssertEqual(omitted.favorite, .omitted)
        XCTAssertTrue(omitted.serverEffectiveState, "缺键不是「没决定」，是「点亮收藏」")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(omitted)) as? [String: Any]
        )
        XCTAssertFalse(object.keys.contains("favorite"), ".omitted 是**真的不写键**")

        let dislike = try JSONEncoder().encode(WorkDislikeRequestDto(.requesting(state: false)))
        XCTAssertTrue(String(decoding: dislike, as: UTF8.self).contains(#""dislike":false"#))
    }

    func testFavoriteIntentFollowsTheDisplayedStateAndTheAuthoritativeEcho() throws {
        let item = try decodedRow(candidate("job-a:cand-1", extra: #""favorited":true"#))
        var state = WorksListState(seedRows: [item])
        XCTAssertTrue(state.favoriteIsOn(item))
        XCTAssertFalse(state.favoriteIntent(item), "已点亮的那一枚再点 = 取消")

        state.optimisticallySet(.cleared, for: item.id)
        XCTAssertFalse(state.favoriteIsOn(item), "乐观更新先翻面（屏上不能等一个往返）")
        XCTAssertTrue(state.favoriteIntent(item), "再点就是又要点亮")

        // 取消那一单：发出去的是显式 false，回显也必须是 false 才算落定。
        let intent = WorkActionToggle.requesting(state: state.favoriteIntent(item))
        XCTAssertEqual(intent, .on)
        let echo = try JSONDecoder().decode(
            WorkFavoriteResponseDto.self, from: Data(#"{"ok":true,"favorited":true}"#.utf8)
        )
        XCTAssertTrue(echo.agrees(with: intent))
        state.confirm(.favorite, for: item.id)
        XCTAssertTrue(state.favoriteIsOn(item))

        let contradicting = try JSONDecoder().decode(
            WorkFavoriteResponseDto.self, from: Data(#"{"ok":true,"favorited":false}"#.utf8)
        )
        XCTAssertFalse(
            contradicting.agrees(with: intent),
            "回显与这一单要做的事不符 ⇒ 必须回落，不能当成成功"
        )
        let silent = try JSONDecoder().decode(
            WorkFavoriteResponseDto.self, from: Data("{}".utf8)
        )
        XCTAssertFalse(silent.isAcknowledged, "200 但没回执 ≠ 做成了")
        XCTAssertFalse(silent.agrees(with: intent))
    }

    func testRejectedActionRollsBackTheOptimisticFlagAndNamesTheFailure() throws {
        let item = try decodedRow(candidate("job-a:cand-1"))
        var state = WorksListState(seedRows: [item])
        state.optimisticallySet(.favorite, for: item.id)
        XCTAssertTrue(state.favoriteIsOn(item))

        // 失败回落（`sendWorksSignal` 的 catch 分支走的就是这一格）。
        state.rollback(rowID: item.id)
        XCTAssertFalse(state.favoriteIsOn(item), "服务端没做成 ⇒ 屏上回到它给的那一行")
        XCTAssertFalse(state.signalOverrides.keys.contains(item.id))

        // 上屏的是那一句能看懂的话，不是英文码（A15）。
        XCTAssertEqual(
            WorksActionError.rejected(.rateLimited(serverMessage: nil)).userMessage,
            "操作太频繁了，稍后再试"
        )
        XCTAssertTrue(
            WorksActionError.rejected(.notMaterialisedYet(serverMessage: nil)).userMessage
                .contains("还在制作中"),
            "409 是「这一单发早了」，不是「用户做错了」"
        )
        XCTAssertTrue(
            WorksActionError.unreadableResponse.userMessage.contains("客户端待核"),
            "解码器读不懂是我们自己的账，不许记到后端头上"
        )
        XCTAssertTrue(
            WorksActionError.transport(.network).userMessage.contains("网络"),
            "传输层失败与业务拒绝也不许并成一锅「操作失败」"
        )
        // 404 = 这行已经不在了（他端删了）：整行撤掉，本地账跟着撤（§8 静默移除）。
        state.optimisticallySet(.favorite, for: item.id)
        state.dropRow(id: item.id)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertFalse(state.signalOverrides.keys.contains(item.id))
    }

    func testDislikeAndFavoriteNeverBothLightUpFromOneLocalWrite() throws {
        let item = try decodedRow(candidate("job-a:cand-1", extra: #""favorited":true"#))
        var state = WorksListState(seedRows: [item])
        state.optimisticallySet(.dislike, for: item.id)   // 点踩（服务端会撤收藏）
        XCTAssertTrue(state.dislikeIsOn(item))
        XCTAssertFalse(state.favoriteIsOn(item), "本地那一格是单值的：画不出两个都点亮")
    }

    func testConflictingServerSignalsDrawNeitherBadgeAndSaySo() throws {
        // 要求⑥：`favorited && disliked` 的行**两个都不画**（§4.7 服务端互斥 ⇒ 同时为真
        // 只可能是账没对上，挑一个显示就是替服务端决定它没决定的事）。
        let conflicted = try decodedRow("""
        {"id":"job-c:c1","jobId":"job-c","status":"succeeded","favorited":true,"disliked":true}
        """)
        let state = WorksListState(seedRows: [conflicted])
        XCTAssertFalse(state.favoriteIsOn(conflicted))
        XCTAssertFalse(state.dislikeIsOn(conflicted))
        XCTAssertTrue(state.signalsAreUncertain(conflicted))

        let disliked = try decodedRow("""
        {"id":"job-c:c2","jobId":"job-c","status":"succeeded","disliked":true}
        """)
        XCTAssertFalse(state.favoriteIsOn(disliked), "点踩会撤收藏 ⇒ ♡ 不画填充态")
        XCTAssertTrue(state.dislikeIsOn(disliked))
        XCTAssertFalse(state.signalsAreUncertain(disliked))

        // 非布尔形状（`"yes"`）回落成 false，但那不是「用户没点过心」⇒ 同样不画。
        let drifted = try decodedRow("""
        {"id":"job-c:c3","jobId":"job-c","status":"succeeded","favorited":"yes"}
        """)
        XCTAssertTrue(state.signalsAreUncertain(drifted))
        XCTAssertFalse(state.favoriteIsOn(drifted))
    }

    func testARefreshedPageWinsOverTheLocalEchoUnlessAWriteIsStillFlying() throws {
        let item = try decodedRow(candidate("job-m:cand-1"))
        var state = WorksListState(seedRows: [item])
        state.optimisticallySet(.favorite, for: item.id)
        XCTAssertTrue(state.favoriteIsOn(item))

        // ① 整表重取覆盖到这一行 ⇒ 本机那一格撤掉，服务端那一份是事实（§7 就地回显的边界）。
        let generation = state.beginReplacementRead()
        let page = try decodedPage(oneRowPage("job-m:cand-1", nextCursor: "null", total: 1))
        XCTAssertTrue(state.apply(page, for: .replace, generation: generation))
        XCTAssertFalse(state.favoriteIsOn(item))

        // ② 同一行有写在途时不撤（不然按钮会在响应回来之前闪回旧态）。
        state.optimisticallySet(.favorite, for: item.id)
        XCTAssertTrue(state.beginWrite(key: item.id))
        let second = state.beginReplacementRead()
        XCTAssertTrue(state.apply(page, for: .replace, generation: second))
        XCTAssertTrue(state.favoriteIsOn(item), "在途那一格留着，等它自己的回执")
    }

    // MARK: - 占位行（要求⑤后半：`{jobId}:pending-N` 一枚动作钮都没有）

    func testPlaceholderRowsExposeNoActionsAndCannotBePlayedOrSaved() throws {
        let placeholder = try decodedRow(placeholderJSON)
        var state = WorksListState(seedRows: [placeholder])
        XCTAssertTrue(placeholder.isPendingPlaceholder)
        XCTAssertFalse(state.actionsAllowed(on: placeholder))
        XCTAssertFalse(placeholder.isPlayable)
        XCTAssertFalse(placeholder.isRealCandidateRow)
        XCTAssertEqual(placeholder.status?.userLabel, "制作中", "徽标只能来自中文词表（A15）")

        let playable = try decodedRow(playableRowJSON)
        XCTAssertTrue(state.actionsAllowed(on: playable))

        // 占位行拿去播/存：两条腿都必须给 nil（而不是拿一个 null 地址去出站）。
        XCTAssertNil(AppSession.worksRowPlaybackItem(from: placeholder))
        XCTAssertNil(
            AppSession.worksRowDownloadRequest(
                from: placeholder,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
            )
        )
    }

    func testBareJobIdRowStillGetsItsActionsButIsNotAPseudoTrackId() throws {
        // §4.7：七个端点都接受裸 jobId ⇒ 它**不是**占位行，动作照给。
        let bare = try decodedRow("""
        {"id":"job-q","jobId":"job-q","status":"succeeded",\
        "audioUrl":"/api/media/objects/mo_1?ref=mr_1&intent=play"}
        """)
        let state = WorksListState(seedRows: [bare])
        XCTAssertTrue(state.actionsAllowed(on: bare))
        XCTAssertFalse(bare.isRealCandidateRow, "它不是作品正身，上报与分组都不认它当候选行")
    }

    // MARK: - job 级三条的本地账（要求⑤后半）

    func testDeletingAJobDropsEveryRowOfThatJobIncludingTheSecondPageOnes() throws {
        let rows = try [
            candidate("job-d:cand-1"), candidate("job-d:cand-2", title: "副歌"),
            candidate("job-e:cand-1"),
        ].map { try decodedRow($0) }
        var state = WorksListState(seedRows: rows)
        state.shareStates["job-d"] = .on
        state.sharePaths["job-d"] = "/share/work/tk_1"
        state.dropJob(anchor: "job-d")
        XCTAssertEqual(state.rows.map(\.id), ["job-e:cand-1"], "一次 DELETE = 整组消失")
        XCTAssertNil(state.shareStates["job-d"], "跟着这组走的组级账不能留在屏外")
        XCTAssertEqual(state.phase, .loaded)
    }

    func testDeletingTheLastGroupLandsTheEmptyStateInsteadOfABlankScreen() throws {
        var state = WorksListState(seedRows: [try decodedRow(candidate("job-x:cand-1"))])
        state.dropJob(anchor: "job-x")
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.phase, .empty, "删空了是「还没有你的作品」那一屏，不是一张白屏")
    }

    func testRenameBackfillRewritesBothRowsOfTheJob() throws {
        let rows = try [
            candidate("job-f:cand-1", title: "旧名"), candidate("job-f:cand-2", title: "旧名"),
        ].map { try decodedRow($0) }
        var state = WorksListState(seedRows: rows)
        let refreshed = try [
            candidate("job-f:cand-2", title: "新名"), candidate("job-f:cand-1", title: "新名"),
        ].map { try decodedRow($0) }
        state.applyRefreshedJobRows(refreshed, anchor: "job-f")
        XCTAssertEqual(state.rows.compactMap(\.displayTitle), ["新名", "新名"])
        XCTAssertEqual(state.rows.map(\.id), ["job-f:cand-1", "job-f:cand-2"], "不重排")
    }

    func testGroupScopeLineTellsTheRealRowCountAndShareFollowsSource() throws {
        let studioCreate = try [
            candidate("job-g:cand-1"), candidate("job-g:cand-2", title: "副歌"),
        ].map { try decodedRow($0) }
        let state = WorksListState(seedRows: studioCreate)
        let group = try XCTUnwrap(state.groups.first)
        XCTAssertEqual(group.rowCount, 2)
        XCTAssertEqual(
            WorksListCopy.groupScope(group.rowCount),
            "这一组里有 2 首，这三项操作对它们一起生效"
        )
        XCTAssertTrue(group.canShare, "source == studio-create ⇒ 有分享目标")
        XCTAssertEqual(
            WorksListCopy.groupHeader(time: "2 小时前", count: 2), "2 小时前 · 一次生成 2 首"
        )
        XCTAssertEqual(
            WorksListCopy.groupHeader(time: nil, count: 1), "一次生成 1 首",
            "createdAt 认不出就只写数量（§7：不显占位）"
        )

        let oneStep = try decodedRow(
            #"{"id":"job-h:cand-1","jobId":"job-h","status":"succeeded","source":"one-step"}"#
        )
        XCTAssertFalse(
            WorksListState(seedRows: [oneStep]).groups[0].canShare,
            "one-step 没有分享目标 ⇒ 该项**不渲染**（不是置灰）"
        )
    }

    func testJobAnchoredFormHasNoPagingAndKeepsItsAnchorAcrossRefresh() {
        var state = WorksListState()
        state.setJobAnchor("job-h")
        XCTAssertTrue(state.isJobAnchored)
        XCTAssertFalse(state.canLoadMorePages, "该 job 的行恒 ≤2 ⇒ 形态下没有分页这一说")
        state.beginReplacementRead()
        XCTAssertTrue(state.isJobAnchored, "整表重取不该把形态洗掉（它是选择态的一部分）")
        state.setJobAnchor(nil)
        XCTAssertFalse(state.isJobAnchored)
    }

    // MARK: - 播放 / 直存（要求①：与 19 同一条媒体出口；A5 的 id 逐字）

    func testPlayUsesTheVerbatimPseudoTrackIdAndTheSameOriginDownloadIntent() throws {
        let item = try decodedRow(playableRowJSON)
        let playback = try XCTUnwrap(AppSession.worksRowPlaybackItem(from: item))
        // A5：上报的 trackId 就是服务端给的那一串，**一个字都不改**。
        XCTAssertEqual(playback.id, "job-a:cand-1")
        XCTAssertEqual(playback.kind, .work)
        XCTAssertTrue(
            playback.requiresLocalization,
            "作品试听走 D7（Bearer 下载 → 校验非空 → file://），不许把签名地址交给播放器"
        )
        guard case .bearerRequired(let audio) = playback.audioSource else {
            return XCTFail("作品的音频只能是 bearerRequired")
        }
        let url = audio.value.absoluteString
        XCTAssertTrue(url.hasPrefix("https://covalink.cn/api/media/objects/mo_9f3a?"), url)
        XCTAssertTrue(url.contains("intent=download"), "§7 #39：同源 download 那一腿才 200 出字节")
        XCTAssertFalse(url.contains("intent=play"), "play 那一腿会被 302 到名单外的桶")
        XCTAssertTrue(url.contains("ref=mr_1"), "其余查询项逐字节带走（R17-6）")
        XCTAssertEqual(playback.duration, 158.4)
        XCTAssertEqual(playback.title, "夏夜城市")
        XCTAssertEqual(playback.coverURL?.value.absoluteString, "https://covalink.cn/covers/a.jpeg")
    }

    func testSaveUsesTheSameDirectFetchLegAndRefusesWithoutAnOwner() throws {
        let item = try decodedRow(playableRowJSON)
        let request = try XCTUnwrap(
            AppSession.worksRowDownloadRequest(
                from: item, session: PlaybackSessionContext(owner: PrincipalID(rawValue: "p-1"))
            )
        )
        XCTAssertEqual(request.workId, "job-a:cand-1", "本机身份与上报用的是同一个号")
        XCTAssertTrue(request.source.value.absoluteString.contains("intent=download"))
        XCTAssertFalse(request.source.value.absoluteString.contains("intent=play"))
        XCTAssertNil(
            AppSession.worksRowDownloadRequest(from: item, session: nil),
            "没有归属就不存，而不是先落进一个无主目录"
        )
        XCTAssertNil(
            AppSession.worksRowDownloadRequest(from: item, session: .unauthenticated),
            "D8：owner 为 nil 的快照不能存东西"
        )
    }

    func testThePlayAndSaveLegsNeverReadPlaybackUrl() throws {
        // §7 #37：`playbackUrl` 签在名单外的 uploads 桶 ⇒ 这两条腿**一次都不读**它。
        let onlyPlayback = try decodedRow("""
        {"id":"job-k:c1","jobId":"job-k","status":"succeeded","audioUrl":null,\
        "playbackUrl":"https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/a.mp3?sign=x"}
        """)
        XCTAssertNil(AppSession.worksRowPlaybackItem(from: onlyPlayback))
        XCTAssertNil(
            AppSession.worksRowDownloadRequest(
                from: onlyPlayback,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "p-1"))
            )
        )
    }

    func testAUrlShapeTheClientCannotResolveIsNotPlayable() throws {
        // 服务端哪天给出认不出的地址形态（协议相对）⇒ 不猜 host、不播（R16-1 那一条腿）。
        let hostile = try decodedRow(
            #"{"id":"job-r:c1","jobId":"job-r","status":"succeeded","audioUrl":"//evil.test/a.mp3"}"#
        )
        XCTAssertNil(hostile.resolvedAudioURL)
        XCTAssertNil(AppSession.worksRowPlaybackItem(from: hostile))
    }

    // MARK: - 歌词（A7 的 timing 那一腿：lrc null 是**正常路径**）

    func testTimingWithNoAlignedLyricsFallsBackToPlainLinesNotToAnError() throws {
        let rowWithLyrics = try decodedRow(
            #"{"id":"job-l:c1","jobId":"job-l","status":"succeeded","lyrics":"第一行"}"#
        )
        let nullLrc = try JSONDecoder().decode(
            WorkTimingResponseDto.self, from: Data(#"{"ok":true,"lrc":null}"#.utf8)
        )
        XCTAssertTrue(nullLrc.shouldFallBackToPlainLyrics)
        XCTAssertEqual(
            WorksListState.lyricsContent(timing: nullLrc, row: rowWithLyrics),
            .plain(text: "第一行")
        )

        let aligned = try JSONDecoder().decode(
            WorkTimingResponseDto.self, from: Data(#"{"ok":true,"lrc":"[00:12.30]第一行"}"#.utf8)
        )
        XCTAssertTrue(aligned.hasAlignedLyrics)
        XCTAssertEqual(
            WorksListState.lyricsContent(timing: aligned, row: rowWithLyrics),
            .aligned(text: "[00:12.30]第一行"),
            "静态行文 + 服务端给的时间戳前缀：**不做**逐行高亮（D15 / §7 的裁决）"
        )

        let rowWithoutLyrics = try decodedRow(#"{"id":"job-l:c2","status":"succeeded"}"#)
        XCTAssertEqual(
            WorksListState.lyricsContent(timing: nullLrc, row: rowWithoutLyrics),
            .unavailable(message: "这首还没有歌词")
        )
        XCTAssertEqual(
            WorksListState.lyricsContent(
                timing: nil, row: rowWithoutLyrics, failureMessage: "还没取到歌词"
            ),
            .unavailable(message: "还没取到歌词"),
            "取失败与真没词是两句话，不许合并"
        )
        XCTAssertEqual(
            WorksListState.lyricsContent(
                timing: nil, row: rowWithLyrics, failureMessage: "网络没通"
            ),
            .plain(text: "第一行"),
            "timing 挂了也不许把已经有的纯文本词藏起来"
        )
    }

    func testShareStatusWithoutAnAnswerKeepsTheKnownState() throws {
        // 待答 12 的现规格口径：取不到态 ⇒ **保持上一次已知态**，不回落成「没开」——
        // 那一格会画出「分享本次生成的作品」，而它可能已经开着。
        let unknown = try JSONDecoder().decode(
            WorkShareStatusResponseDto.self, from: Data("{}".utf8)
        )
        XCTAssertEqual(unknown.state, .unknown)
        var state = WorksListState()
        state.shareStates["job-a"] = .on
        if unknown.state != .unknown { state.shareStates["job-a"] = unknown.state }
        XCTAssertEqual(state.shareStates["job-a"], .on)

        let off = try JSONDecoder().decode(
            WorkShareStatusResponseDto.self, from: Data(#"{"enabled":false}"#.utf8)
        )
        state.shareStates["job-a"] = off.state
        XCTAssertEqual(state.shareStates["job-a"], .off, "服务端明确说了没开，才改口")
    }

    // MARK: - 输入钳位与账本清理

    func testSearchTextIsTrimmedAndClampedLocally() {
        XCTAssertEqual(WorksListState.normalized("  夏夜  "), "夏夜")
        XCTAssertEqual(
            WorksListState.normalized(String(repeating: "啊", count: 500)).count,
            WorkRenameRequestDto.titleMaximumLength
        )
        var state = WorksListState()
        state.beginReplacementRead(search: "   ")
        XCTAssertTrue(state.search.isEmpty)
        XCTAssertNil(state.query(for: .replace).normalizedSearch, "纯空白 = 不发 q 键")
        XCTAssertEqual(state.query(for: .replace).filter, .all)
        XCTAssertEqual(state.query(for: .replace).sort, .newest)
    }

    func testUnauthenticatedResetsTheWholeLedger() throws {
        let item = try decodedRow(candidate("job-n:cand-1"))
        var state = WorksListState(seedRows: [item])
        state.optimisticallySet(.favorite, for: item.id)
        state.noteUnauthenticated()
        XCTAssertTrue(state.rows.isEmpty, "D8：不给下一个人看上一个人的作品")
        XCTAssertEqual(state.filter, .all)
        XCTAssertEqual(state.search, "")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.signalOverrides.isEmpty)
    }

    func testLeavingTheScreenKeepsTheLedgerButDropsTheInFlightMark() throws {
        let item = try decodedRow(candidate("job-o:cand-1"))
        var state = WorksListState(seedRows: [item])
        state.beginReplacementRead()
        XCTAssertTrue(state.isReading)
        state.noteLeftRead()
        XCTAssertFalse(state.isReading)
        XCTAssertTrue(state.hasContent, "退屏再回来，屏上那几行还在（同 19 的取消口径）")
    }

    func testRenameTitleValidationIsTheDTORuleNotASecondCopyOfIt() {
        // §8：本地先拦两句「名称不能为空」/「名称太长了」，判据**只有** `WorkRenameRequestDto` 那一处。
        XCTAssertThrowsError(try WorkRenameRequestDto(title: "   ")) { error in
            XCTAssertEqual(error as? WorkActionRequestError, .emptyTitle)
        }
        XCTAssertThrowsError(
            try WorkRenameRequestDto(title: String(repeating: "名", count: 201))
        ) { error in
            guard case .titleTooLong(let limit, let actual) = error as? WorkActionRequestError
            else { return XCTFail("超长那一格要落 titleTooLong") }
            XCTAssertEqual(limit, 200)
            XCTAssertEqual(actual, 201)
        }
        XCTAssertNotNil(try WorkRenameRequestDto(title: "  夏夜城市  "))
    }
}

// MARK: - 夹具用：带行的初始状态
//
/// `WorksListState.rows` 是 `internal(set)` ⇒ 测试也只能通过"服务端给回一页"这条路把行放进
/// 账里。这个构造器就是那一页的**记账形式**（走 `apply(_:for:generation:)` 同一条落账腿），
/// 不是绕过判据的后门：绕开它就没有「一行凭空出现在屏上」的测试形状。
extension WorksListState {
    init(seedRows: [WorksListRowDto]) {
        self.init()
        let generation = beginReplacementRead()
        apply(
            WorksPageDto(
                works: seedRows, nextCursor: nil, total: seedRows.count, unreadableItemCount: 0
            ),
            for: .replace, generation: generation
        )
    }
}
