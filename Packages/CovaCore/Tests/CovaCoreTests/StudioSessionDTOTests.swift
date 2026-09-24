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
