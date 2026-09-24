import CovaCore
import XCTest

/// 09 候选卡 ♡ 的账（纯逻辑）。夹具走 `JSONSerialization` 造真实响应形态
/// （不用 DTO 的内部 memberwise 构造器，与 `StudioNotificationPlanTests` 同一口径）。
final class CandidateFavoriteLedgerTests: XCTestCase {
    private func candidate(
        id: String, reference: String? = "ref-1", favorite: Bool? = nil
    ) -> GenerationCandidateDto {
        var dict: [String: Any] = ["id": id]
        if let reference { dict["mediaReferenceId"] = reference }
        if let favorite { dict["favorite"] = favorite }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(GenerationCandidateDto.self, from: data)
    }

    /// 09 §8：没有 `mediaReferenceId` 的候选**整钮不渲染**（不是禁用），因此根本不该入账。
    func testCandidateWithoutMediaReferenceIdIsNotFavoritable() {
        let subject = candidate(id: "c1", reference: nil, favorite: true)
        XCTAssertFalse(CandidateFavoriteLedger.canFavorite(subject))

        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [subject])
        XCTAssertTrue(ledger.serverTruth.isEmpty, "无 reference 的候选不得进入任何一本账")
        XCTAssertTrue(ledger.displayed.isEmpty)
        XCTAssertNil(ledger.beginToggle(subject), "点它无处可调 ⇒ 吞掉，不发请求")
        XCTAssertFalse(CandidateFavoriteLedger.isFavorite(subject, in: ledger))
    }

    /// 空串 reference 同「没有」：拼出来的是 `…/references//retention`，注定失败的写请求。
    func testBlankMediaReferenceIdIsTreatedAsAbsent() {
        let subject = candidate(id: "c1", reference: "   ")
        XCTAssertFalse(CandidateFavoriteLedger.canFavorite(subject))
    }

    /// 播种读服务端的 `favorite`；缺席按未收藏（后端没说 = 不声称已收藏）。
    func testReseedReadsServerFavoriteField() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [
            candidate(id: "a", reference: "ref-a", favorite: true),
            candidate(id: "b", reference: "ref-b", favorite: false),
            candidate(id: "c", reference: "ref-c"),
        ])
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(candidate(id: "a", reference: "ref-a", favorite: true), in: ledger))
        XCTAssertFalse(CandidateFavoriteLedger.isFavorite(candidate(id: "b", reference: "ref-b", favorite: false), in: ledger))
        XCTAssertFalse(CandidateFavoriteLedger.isFavorite(candidate(id: "c", reference: "ref-c"), in: ledger))
        XCTAssertEqual(ledger.displayed, ["ref-a": true, "ref-b": false, "ref-c": false])
    }

    /// 乐观翻转发生在请求之前，但**服务端事实那本不动** —— 失败时才有的回落落点。
    func testOptimisticFlipTouchesOnlyDisplayLedger() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        let subject = candidate(id: "a", reference: "ref-a", favorite: false)

        XCTAssertEqual(ledger.beginToggle(subject)?.target, true)
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(subject, in: ledger))
        XCTAssertEqual(ledger.serverTruth["ref-a"], false, "未确认前不得把乐观值写进服务端事实")
        XCTAssertEqual(ledger.inFlight, ["ref-a"])
    }

    /// 成功：有回显以回显为准（后端可能把 `false` 改成 `false`，也可能带权威态回来）。
    func testConfirmPrefersServerEchoOverSentValue() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        _ = ledger.beginToggle(candidate(id: "a", reference: "ref-a", favorite: false))
        ledger.confirm(referenceID: "ref-a", sent: true, echoed: false)
        XCTAssertEqual(ledger.displayed["ref-a"], false)
        XCTAssertEqual(ledger.serverTruth["ref-a"], false)
        XCTAssertTrue(ledger.inFlight.isEmpty)
    }

    /// 契约没写响应字段（`MediaRetentionResponseDto` 全可选）⇒ 无回显时采信已发送值，
    /// 而不是把状态退回播种值。
    func testConfirmWithoutEchoAdoptsSentValue() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        _ = ledger.beginToggle(candidate(id: "a", reference: "ref-a", favorite: false))
        ledger.confirm(referenceID: "ref-a", sent: true, echoed: nil)
        XCTAssertEqual(ledger.displayed["ref-a"], true)
        XCTAssertEqual(ledger.serverTruth["ref-a"], true)
    }

    /// 失败：回落到**服务端值**，并给出回落后的值让调用方把失败说给用户。
    func testFailureRollsBackToServerValue() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: true)])
        let subject = candidate(id: "a", reference: "ref-a", favorite: true)
        XCTAssertEqual(ledger.beginToggle(subject)?.target, false)
        XCTAssertFalse(CandidateFavoriteLedger.isFavorite(subject, in: ledger))

        let restored = ledger.reject(referenceID: "ref-a")
        XCTAssertTrue(restored)
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(subject, in: ledger))
        XCTAssertTrue(ledger.inFlight.isEmpty)
    }

    /// 09 §10：同一候选连点吞后发（不排队、不发第二次 PATCH）。
    func testSecondTapWhileInFlightIsSwallowed() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        let subject = candidate(id: "a", reference: "ref-a", favorite: false)
        // 意图里带 referenceID ⇒ 调用方不必自己再解一次可选字段（解错就是发给空 reference）。
        let intent = ledger.beginToggle(subject)
        XCTAssertEqual(intent?.referenceID, "ref-a")
        XCTAssertEqual(intent?.target, true)
        XCTAssertNil(ledger.beginToggle(subject), "在途时后发的点击必须被吞")
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(subject, in: ledger))
    }

    /// 不同候选互不阻塞：A 在途不影响 B。
    func testOtherCandidateIsNotBlocked() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [
            candidate(id: "a", reference: "ref-a"),
            candidate(id: "b", reference: "ref-b"),
        ])
        XCTAssertNotNil(ledger.beginToggle(candidate(id: "a", reference: "ref-a")))
        XCTAssertNotNil(ledger.beginToggle(candidate(id: "b", reference: "ref-b")))
    }

    /// **不留本地的谎**：中途刷新（下拉 / 重新进屏）必须用服务端值整本覆盖未确认的乐观翻转。
    func testRefreshReseedsAndDropsUnconfirmedLocalFlip() {
        var ledger = CandidateFavoriteLedger()
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        _ = ledger.beginToggle(candidate(id: "a", reference: "ref-a", favorite: false))
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(candidate(id: "a", reference: "ref-a"), in: ledger))

        // 服务端在 PATCH 落地前把这条读成了未收藏 ⇒ 以它为准。
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: false)])
        XCTAssertFalse(CandidateFavoriteLedger.isFavorite(candidate(id: "a", reference: "ref-a"), in: ledger))
        XCTAssertTrue(ledger.inFlight.isEmpty, "重新播种后不得留下悬空的在途账")

        // 反过来也一样：后端已经改成已收藏，本地乐观值必须让路。
        ledger.reseed(from: [candidate(id: "a", reference: "ref-a", favorite: true)])
        XCTAssertTrue(CandidateFavoriteLedger.isFavorite(candidate(id: "a", reference: "ref-a"), in: ledger))
    }
}
