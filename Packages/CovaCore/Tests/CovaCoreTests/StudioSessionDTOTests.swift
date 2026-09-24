import CovaCore
import XCTest

/// 会话面 DTO 的解码容忍（M2）。
///
/// 这一组用例守的不是「能解出来」，而是**容忍与撒谎的分界**：
/// · 信封形态未文档化 ⇒ 已知的几种都接（NEEDS-23）；
/// · 但「一个都接不上」必须**报错**，绝不能静默当空列表 ——
///   那会把契约漂移伪装成「你还没有创作」，用户看到的是一个不存在的空状态。
final class StudioSessionDTOTests: XCTestCase {
    func testSessionListAcceptsWrappedEnvelope() throws {
        let json = Data(
            #"{"sessions":[{"id":"s-1","title":"深夜写作","titleCn":"深夜写作集","summary":"三段草稿"}]}"#.utf8
        )
        let page = try JSONDecoder().decode(StudioSessionListDto.self, from: json)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, "s-1")
        XCTAssertEqual(page.sessions[0].displayTitle, "深夜写作集")
        XCTAssertEqual(page.sessions[0].displaySummary, "三段草稿")
    }

    func testSessionListAcceptsBareArray() throws {
        let json = Data(#"[{"id":"s-2"}]"#.utf8)
        let page = try JSONDecoder().decode(StudioSessionListDto.self, from: json)
        XCTAssertEqual(page.sessions.map(\.id), ["s-2"])
    }

    /// 两种已知形态都接不上 ⇒ 必须抛，而不是给一个空数组。
    func testSessionListRejectsUnknownShapeInsteadOfFakingEmpty() {
        let json = Data(#"{"things":[{"id":"s-3"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StudioSessionListDto.self, from: json))
    }

    func testTitleAndSummaryFallbacksFollowTheSpec() throws {
        // 标题全缺 ⇒ spec 指定的「未命名会话」；摘要缺 ⇒ 整行不渲染（nil，不是空串）。
        let json = Data(#"{"sessions":[{"id":"s-4"}]}"#.utf8)
        let page = try JSONDecoder().decode(StudioSessionListDto.self, from: json)
        XCTAssertEqual(page.sessions[0].displayTitle, "未命名会话")
        XCTAssertNil(page.sessions[0].displaySummary)

        // 只有英文 title ⇒ 用它，不编中文。
        let onlyEN = Data(#"{"sessions":[{"id":"s-5","title":"Nightly Focus","titleCn":""}]}"#.utf8)
        let decoded = try JSONDecoder().decode(StudioSessionListDto.self, from: onlyEN)
        XCTAssertEqual(decoded.sessions[0].displayTitle, "Nightly Focus")
    }

    /// **真实账号实测形态**（2026-09-24）：`{session:{sessionId, messages:[{role, content,
    /// timestamp, attachments}], generationJobs:[]}}` —— 内容套在 `session` 里，会话号叫
    /// `sessionId` 而不是 `id`，消息正文叫 `content` 而不是 `text`，且消息**没有 id 键**。
    /// 这条用例守的是：这三处任何一处被读成"没有内容"，09 屏都会显示成一片空白而不是报错。
    func testDetailAcceptsTheRealNestedShape() throws {
        let json = Data(
            #"""
            {"session":{"sessionId":"6029c66b-0000-4ba8-841c-3aa4cd2efc0b","title":"新会话",
            "workflowMode":"one-step","createdAt":"2026-09-24T12:30:47.313Z",
            "updatedAt":"2026-09-24T12:30:51.684Z",
            "messages":[{"role":"user","content":"帮我做一首适合咖啡馆下午的轻爵士纯音乐",
            "timestamp":"2026-09-24T12:30:48.000Z","attachments":[]},
            {"role":"assistant","content":"已按咖啡馆下午的场景规划。",
            "timestamp":"2026-09-24T12:30:51.000Z","attachments":[]}],
            "generationJobs":[]}}
            """#.utf8
        )
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertEqual(detail.session?.id, "6029c66b-0000-4ba8-841c-3aa4cd2efc0b",
                       "详情里的会话号是 sessionId，必须别名到 id")
        XCTAssertEqual(detail.messages.count, 2, "内容套在 session 里时不得解码成 0 条")
        XCTAssertTrue(detail.messages[0].isFromUser)
        XCTAssertEqual(detail.messages[0].displayText, "帮我做一首适合咖啡馆下午的轻爵士纯音乐",
                       "正文在真实响应里叫 content")
        XCTAssertFalse(detail.messages[1].isFromUser, "role=assistant 是 agent 说的")
        XCTAssertTrue(detail.generationJobs.isEmpty)
    }

    /// 顶层扁平形态仍然要接（旧口径没写错，只是后端两种都给）。
    func testDetailStillAcceptsFlatShape() throws {
        let json = Data(#"{"messages":[{"id":"m-9","role":"user","text":"来点雨声"}]}"#.utf8)
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertEqual(detail.messages.count, 1)
        XCTAssertEqual(detail.messages[0].displayText, "来点雨声")
    }

    /// 会话两个键名都没有 ⇒ **报错**，不许凭空造一个会话号去开 SSE。
    func testSessionWithoutAnyIdKeyFails() {
        let json = Data(#"{"title":"没有号的会话"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StudioSessionDto.self, from: json))
    }

    func testDetailToleratesMissingSections() throws {
        let json = Data(#"{"messages":[{"id":"m-1","role":"user","text":"做一首夏日广告配乐"}]}"#.utf8)
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertNil(detail.session)
        XCTAssertEqual(detail.messages.count, 1)
        XCTAssertTrue(detail.messages[0].isFromUser)
        XCTAssertEqual(detail.messages[0].displayText, "做一首夏日广告配乐")
        XCTAssertTrue(detail.generationJobs.isEmpty)
    }

    /// 空详情**不是**解码失败（会话刚建出来就是空的），但解不出的条目要能被跳过。
    func testEmptyDetailDecodesAndUndisplayableMessageYieldsNil() throws {
        let empty = try JSONDecoder().decode(StudioSessionDetailDto.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.messages.isEmpty)

        let noText = Data(#"{"messages":[{"id":"m-2","role":"assistant"}]}"#.utf8)
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: noText)
        XCTAssertNil(detail.messages[0].displayText, "没有正文 ⇒ UI 跳过这条，不显示空气泡")
        XCTAssertFalse(detail.messages[0].isFromUser, "role 缺失按 agent 渲染（不把未知说成用户说的）")
    }

    /// **R15-6 撞车探针（评审实测的那条）**：两条**确实不同**的消息 —— 角色相同、时间戳相同、
    /// 正文前 12 个字符也相同，只在第 13 个字之后分岔。旧口径取的是**截断前缀**，
    /// 于是这两条解出**同一个 id**；一份响应里出现重复 id 不是"难看"，是列表会
    /// **丢行或串内容**。修好后两条必须各自成键。
    func testMessagesDifferingOnlyAfterTheTwelfthCharacterGetDistinctIds() throws {
        let json = Data(
            #"""
            {"messages":[
              {"role":"user","content":"帮我做一首适合咖啡馆下午的轻爵士纯音乐，第二段甲",
               "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]},
              {"role":"user","content":"帮我做一首适合咖啡馆下午的轻爵士纯音乐，第二段乙",
               "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]}]}
            """#.utf8
        )
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertEqual(detail.messages.map(\.id), [
            "view:user:2026-09-24T12:00:00.000Z:1d0cb71331d4de04",
            "view:user:2026-09-24T12:00:00.000Z:49d412205f072b77",
        ], "正文只在第 13 个字之后不同也是两条不同的消息，不得共用一个列表身份")
    }

    /// **逐字节相同的重复条目**：后端真给两条一模一样的消息时，合成键天然相同。
    /// 这一条守的是「同一份响应内 id 不得重复」——按出现顺序给第二、三条起加序号。
    func testByteIdenticalDuplicateMessagesGetUniqueIdsWithinOneResponse() throws {
        let json = Data(
            #"""
            {"messages":[
              {"role":"assistant","content":"已按你的描述生成。",
               "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]},
              {"role":"assistant","content":"已按你的描述生成。",
               "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]},
              {"role":"assistant","content":"已按你的描述生成。",
               "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]}]}
            """#.utf8
        )
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        let ids = detail.messages.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "同一份响应里三条重复正文也要各自有身份")
        XCTAssertEqual(ids, [
            "view:assistant:2026-09-24T12:00:00.000Z:e6cba14abc8bf582",
            "view:assistant:2026-09-24T12:00:00.000Z:e6cba14abc8bf582#2",
            "view:assistant:2026-09-24T12:00:00.000Z:e6cba14abc8bf582#3",
        ], "第一条保持原键、其后按出现顺序加序号：去重必须是确定的，不依赖集合的迭代顺序")

        // **真实响应那两条解码路径都要过这一手**：内容套在 `session` 里（2026-09-24 实测形态）
        // 时同样不许留下重复键 —— 去重发生在清单合并之后，两处都覆盖。
        let nested = Data(
            #"""
            {"session":{"sessionId":"6029c66b-0000-4ba8-841c-3aa4cd2efc0b",
            "messages":[{"role":"assistant","content":"已按你的描述生成。",
            "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]},
            {"role":"assistant","content":"已按你的描述生成。",
            "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]}],
            "generationJobs":[]}}
            """#.utf8
        )
        let nestedIds = try JSONDecoder().decode(StudioSessionDetailDto.self, from: nested).messages.map(\.id)
        XCTAssertEqual(Set(nestedIds).count, 2, "套在 session 里的那份清单同样不得留重复键")
    }

    /// 合成键里那个指纹是**自己实现的确定性哈希**（FNV-1a/64），不是 `hashValue` ——
    /// 后者每进程换种子 ⇒ 每次冷启动整屏气泡重排。这里把**字面期望值**钉死：
    /// 换成 `hashValue` 实现、或换成每次启动重算的任意方案，这条都会红。
    func testSynthesizedMessageIdIsDeterministicAcrossDecodes() throws {
        let json = Data(
            #"""
            {"messages":[{"role":"user","content":"再来一段雨声",
            "timestamp":"2026-09-24T12:00:00.000Z","attachments":[]}]}
            """#.utf8
        )
        let first = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        let second = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertEqual(first.messages.map(\.id), second.messages.map(\.id), "同一份 JSON 解两次必须同键")
        XCTAssertEqual(
            first.messages[0].id, "view:user:2026-09-24T12:00:00.000Z:cf92cf7ff92dc3dc",
            "跨进程可复现的期望值（钉字面量，否则'确定性'只是自称）"
        )
    }

    /// 后端**给了 `id` 就必须原样用它**（`SessionIdAliasKey` 同一口径）：
    /// 真消息号是身份，客户端不许改它，也不许给同一份响应里的另一条合成键去撞它。
    func testRealMessageIdIsPreferredAndNeverRewritten() throws {
        let json = Data(
            #"""
            {"messages":[
              {"id":"m-7","role":"assistant","content":"已按你的描述生成。",
               "timestamp":"2026-09-24T12:00:00.000Z"},
              {"role":"assistant","content":"已按你的描述生成。",
               "timestamp":"2026-09-24T12:00:00.000Z"}]}
            """#.utf8
        )
        let detail = try JSONDecoder().decode(StudioSessionDetailDto.self, from: json)
        XCTAssertEqual(detail.messages[0].id, "m-7", "后端给过 id ⇒ 原样透传，不套视图键、也不被去重改写")
        XCTAssertNotEqual(detail.messages[1].id, "m-7")
        XCTAssertEqual(
            detail.messages[1].id,
            "view:assistant:2026-09-24T12:00:00.000Z:e6cba14abc8bf582",
            "没有 id 的那条仍按合成键，且不因为前一条真 id 的存在而移位"
        )
    }

    func testCreateSessionAcceptsBothKnownShapes() throws {
        let nested = Data(#"{"session":{"id":"s-9","workflowMode":"one-step"}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: nested).sessionId, "s-9"
        )
        let flat = Data(#"{"id":"s-10"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: flat).sessionId, "s-10"
        )
    }

    /// **真实账号实测形态**（2026-09-24）：`POST /api/find-my-song/sessions` 返 200，
    /// 顶层**只有 `session` 一个键**，而那个对象里的会话号叫 `sessionId`、**没有 `id`**
    /// （键名逐个取自实测响应；值是造的 —— 真实号与 userId 不入 fixture）。
    /// 旧实现的嵌套容器只声明了 `id` ⇒ 三条分支全落空 ⇒ 抛错 ⇒
    /// 「新建创作」在真机上**永远**建不出会话（08 列表点旧会话不发消息，所以一直掩盖着）。
    func testCreateSessionAcceptsTheRealCapturedShape() throws {
        let json = Data(
            #"""
            {"session":{"archived":false,"briefApproved":false,
            "createdAt":"2026-09-24T12:30:47.313Z","inProductionMode":false,
            "lastRecommendationIds":[],"messages":[],"pinned":false,
            "proposedTitle":null,"round":0,
            "sessionId":"3f2a5c88-1d47-4f62-9a0b-7c5e8d1b2a44",
            "title":null,"titleLocked":false,
            "updatedAt":"2026-09-24T12:30:47.313Z",
            "userId":"91b7d2e4-aaaa-4c1a-8f3a-2e5b7c9d1f02",
            "workflowMode":"one-step"}}
            """#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: json).sessionId,
            "3f2a5c88-1d47-4f62-9a0b-7c5e8d1b2a44",
            "真实响应的会话号是 session.sessionId，读不到就是整条建会话链路挂掉"
        )
    }

    /// 契约文档写的是 `{session:{id}}` ⇒ 旧口径不能因为支持 `sessionId` 而退化掉。
    func testCreateSessionStillAcceptsNestedIdOnlyShape() throws {
        let json = Data(#"{"session":{"id":"s-11","workflowMode":"one-step"}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: json).sessionId, "s-11"
        )
    }

    /// 两处号**一致** ⇒ 用那个号（同一件事的两种写法，不该因此报错）。
    func testCreateSessionAcceptsConsistentIdsAcrossBothKeyNames() throws {
        let json = Data(#"{"session":{"sessionId":"s-12","id":"s-12"},"sessionId":"s-12"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: json).sessionId, "s-12"
        )
    }

    /// 一个号都取不到 ⇒ **报错**：空串号会让用户下一句 prompt 打进一个不存在的会话
    /// （`sessionId 缺失不得猜路由`）。空串尤其要拦 —— 它是"看起来成功"的那种失败。
    func testCreateSessionWithoutAnyUsableIdFails() {
        let noKey = Data(#"{"session":{"title":"没有号的会话","workflowMode":"one-step"}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: noKey),
            "套在 session 里而两处号键都缺 ⇒ 不能退化成空号"
        )
        let emptyIds = Data(#"{"session":{"sessionId":"","id":""}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: emptyIds),
            "空串不是会话号，与「没有号」同一口径"
        )
    }

    /// 两处号**不一致** ⇒ 抛错（比"嵌套优先"更严）。理由：客户端没有裁决权 ——
    /// 猜哪一个都会把用户这句话发进另一个真实存在的会话，那比建不出会话更难发现。
    func testCreateSessionWithConflictingIdsFailsInsteadOfGuessing() {
        let sameLevel = Data(#"{"session":{"sessionId":"s-13","id":"s-14"}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: sameLevel),
            "session.id 与 session.sessionId 打架 ⇒ 不挑一个用"
        )
        let acrossLevels = Data(#"{"session":{"sessionId":"s-13"},"id":"s-14"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: acrossLevels),
            "嵌套与顶层各给一个号 ⇒ 同上"
        )
    }

    /// 取不到会话号 = 失败。**不凭空造一个号**去开流（那会让整条会话链挂在一个假 id 上）。
    func testCreateSessionWithoutIdFails() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: Data(#"{"ok":true}"#.utf8))
        )
    }
}
