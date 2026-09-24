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

    /// 取不到会话号 = 失败。**不凭空造一个号**去开流（那会让整条会话链挂在一个假 id 上）。
    func testCreateSessionWithoutIdFails() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(StudioCreateSessionResponseDto.self, from: Data(#"{"ok":true}"#.utf8))
        )
    }
}
