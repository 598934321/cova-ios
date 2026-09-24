import CovaCore
import XCTest

/// 18 本地通知的判定与载荷（纯规划器）。用例逐条对 spec 的硬规则，
/// 尤其两条容易写错的：**两个都失败也要发**、**没 settled 就不发**。
///
/// 夹具走 `JSONSerialization` 造真实响应形态 —— 不用 DTO 的内部 memberwise 构造器，
/// 那样会把「测试能跑」绑在实现细节上。
final class StudioNotificationPlanTests: XCTestCase {
    private func candidate(id: String, title: String, status: String? = nil, url: String? = nil)
        -> [String: Any] {
        var dict: [String: Any] = ["id": id, "title": title]
        if let status { dict["audioDownloadStatus"] = status }
        if let url { dict["audioUrl"] = url }
        return dict
    }

    private func job(status: GenerationJobStatus, candidates: [[String: Any]]) -> GenerationJobDto {
        let metadata = try! JSONSerialization.data(withJSONObject: ["candidates": candidates])
        let payload: [String: Any] = [
            "id": "job-1",
            "status": status.rawValue,
            "sessionId": "s-1",
            "costCredits": 30,
            "metadata": String(data: metadata, encoding: .utf8)!,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(GenerationJobDto.self, from: data)
    }

    func testBothReadyFiresWithBothTitles() {
        let subject = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "夏日广告曲", status: "ready", url: "https://cdn.example/a.m4a"),
            candidate(id: "c2", title: "夏日广告曲 慢版", status: "ready", url: "https://cdn.example/b.m4a"),
        ])
        let plan = StudioNotificationPlanner.plan(job: subject, sessionID: "s-1")
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.title, "你的歌做好了")
        XCTAssertEqual(plan?.body, "「夏日广告曲」「夏日广告曲 慢版」两个版本都完成了")
        XCTAssertEqual(plan?.sessionID, "s-1")
        XCTAssertEqual(plan?.jobID, "job-1")
    }

    /// 双失败**照发**（spec 明令），且不带任何情绪符号。
    func testBothFailedStillFires() {
        let subject = job(status: .failed, candidates: [
            candidate(id: "c1", title: "A", status: "failed"),
            candidate(id: "c2", title: "B", status: "failed"),
        ])
        let plan = StudioNotificationPlanner.plan(job: subject, sessionID: "s-1")
        XCTAssertEqual(plan?.body, "这次两个版本都没做成")
        XCTAssertFalse(plan?.body.contains("❌") ?? true)
        XCTAssertFalse(plan?.body.contains("！") ?? true)
    }

    func testOneReadyOneFailedIsReportedAsOneReady() {
        let subject = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://cdn.example/a.m4a"),
            candidate(id: "c2", title: "B", status: "failed"),
        ])
        XCTAssertEqual(
            StudioNotificationPlanner.plan(job: subject, sessionID: "s-1")?.body,
            "「A」做好了，另一版没完成"
        )
    }

    /// `succeeded` 但前两个候选还没都 settled ⇒ **不发**（双 Demo 硬规则）。
    func testSucceededButNotBothSettledDoesNotFire() {
        let pending = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://cdn.example/a.m4a"),
            candidate(id: "c2", title: "B", status: "pending"),
        ])
        XCTAssertNil(StudioNotificationPlanner.plan(job: pending, sessionID: "s-1"))

        let single = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://cdn.example/a.m4a"),
        ])
        XCTAssertNil(StudioNotificationPlanner.plan(job: single, sessionID: "s-1"))
    }

    /// 只看**前两个**：第三个就绪与否不得改变判定。
    func testOnlyFirstTwoCandidatesMatter() {
        let extra = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://x/a"),
            candidate(id: "c2", title: "B", status: "pending"),
            candidate(id: "c3", title: "C", status: "ready", url: "https://x/c"),
        ])
        XCTAssertNil(StudioNotificationPlanner.plan(job: extra, sessionID: "s-1"))
    }

    /// 载荷卫生：URL、签名地址、token、余额/价格/`co 币`、`costCredits` 的数字
    /// 都不得出现在标题 / 正文 / userInfo 里。
    func testPayloadCarriesNoUrlsOrMoney() {
        let subject = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://cdn.example/a.m4a?sig=SECRET"),
            candidate(id: "c2", title: "B", status: "ready", url: "https://cdn.example/b.m4a?sig=SECRET"),
        ])
        guard let plan = StudioNotificationPlanner.plan(
            job: subject, sessionID: "s-1", planCardID: "p-1", candidateID: "c1"
        ) else { return XCTFail("应有计划") }
        let blob = ([plan.title, plan.body] + plan.userInfo.values).joined(separator: "|")
        for forbidden in ["http", "SECRET", "co 币", "余额", "价格", "30", "点击查看", "领取"] {
            XCTAssertFalse(blob.contains(forbidden), "载荷里不得出现 \(forbidden)：\(blob)")
        }
        XCTAssertEqual(plan.userInfo["source"], "local-notification")
        XCTAssertEqual(plan.identifier, "cova-generation-job-1")
    }

    /// 路由契约：`sessionId` 缺失/空白 ⇒ 不给可路由的会话号（UI 回落首页，不猜路由）。
    func testMissingSessionIDNeverYieldsARoute() {
        let subject = job(status: .succeeded, candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "x"),
            candidate(id: "c2", title: "B", status: "ready", url: "y"),
        ])
        XCTAssertNil(StudioNotificationPlanner.plan(job: subject, sessionID: "   ")?.sessionID)
        XCTAssertNil(StudioNotificationPlanner.route(from: ["source": "local-notification"]))
        XCTAssertEqual(
            StudioNotificationPlanner.route(from: ["sessionId": "s-9"]), "s-9",
            "带合法 sessionId 时才能路由到 09"
        )
    }
}
