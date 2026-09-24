import CovaCore
import XCTest

/// D7 / 09 §5 双 Demo 终态硬规则（唯一判定处）。夹具仍走 `JSONSerialization` 造真实响应形态。
///
/// 这四条最容易被写歪的地方各钉一条：只取前二、ready 必须带地址、不足两个不终态、
/// 以及「终态但两版全失败」不给可挑。
final class DoubleDemoRuleTests: XCTestCase {
    private func candidate(
        id: String, status: String? = nil, url: String? = nil
    ) -> GenerationCandidateDto {
        var dict: [String: Any] = ["id": id]
        if let status { dict["audioDownloadStatus"] = status }
        if let url { dict["audioUrl"] = url }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(GenerationCandidateDto.self, from: data)
    }

    private func decode(_ raws: [[String: Any]]) -> [GenerationCandidateDto] {
        let data = try! JSONSerialization.data(withJSONObject: raws)
        return try! JSONDecoder().decode([GenerationCandidateDto].self, from: data)
    }

    func testOnlyTheFirstTwoCandidatesEverCount() {
        let three = decode([
            ["id": "a", "audioDownloadStatus": "ready", "audioUrl": "https://x/a"],
            ["id": "b", "audioDownloadStatus": "pending"],
            ["id": "c", "audioDownloadStatus": "ready", "audioUrl": "https://x/c"],
        ])
        XCTAssertEqual(DoubleDemoRule.pair(three).map(\.id), ["a", "b"], "多余候选不进任何判定")
        XCTAssertFalse(DoubleDemoRule.isTerminal(three))

        let settledPair = decode([
            ["id": "a", "audioDownloadStatus": "ready", "audioUrl": "https://x/a"],
            ["id": "b", "audioDownloadStatus": "failed"],
            ["id": "c", "audioDownloadStatus": "pending"],
        ])
        XCTAssertTrue(DoubleDemoRule.isTerminal(settledPair), "前两个都 settled 即终态，第三个不得拖住")
    }

    /// 「ready 且有 URL」是两个条件：报了就绪但地址没跟着来 ⇒ 不算就绪（否则终态建在放不出声音的卡上）。
    func testReadyRequiresBothStatusAndAddress() {
        XCTAssertTrue(DoubleDemoRule.isReady(candidate(id: "a", status: "ready", url: "https://x/a")))
        XCTAssertFalse(
            DoubleDemoRule.isReady(candidate(id: "a", status: "ready")),
            "状态说就绪、地址缺席 ⇒ 不认作就绪"
        )
        XCTAssertFalse(DoubleDemoRule.isReady(candidate(id: "a", status: "ready", url: "")))
        XCTAssertFalse(DoubleDemoRule.isReady(candidate(id: "a", status: "pending", url: "https://x/a")))
        // 契约没给状态时，回落到「有没有地址」这一件可观察事实。
        XCTAssertTrue(DoubleDemoRule.isReady(candidate(id: "a", url: "https://x/a")))
        XCTAssertFalse(DoubleDemoRule.isReady(candidate(id: "a")))
    }

    /// 不足两个候选**永不**终态 —— 这是「本轮还没结束」，不是"少一个也行"。
    func testFewerThanTwoCandidatesIsNeverTerminal() {
        let single = candidate(id: "a", status: "ready", url: "https://x/a")
        XCTAssertFalse(DoubleDemoRule.isTerminal([]))
        XCTAssertFalse(DoubleDemoRule.isTerminal([single]))
        XCTAssertTrue(DoubleDemoRule.canChooseVersion([single]) == false, "一版都不算终态，也就没得挑")

        let bothFailed = decode([
            ["id": "a", "audioDownloadStatus": "failed"],
            ["id": "b", "audioDownloadStatus": "failed"],
        ])
        XCTAssertTrue(DoubleDemoRule.isTerminal(bothFailed))
    }

    /// 终态 ≠ 可选：两版全失败时终态条要说话，但主钮不出现（§5 行 6 只要求引导重说一句话）。
    func testTerminalButNothingToPick() {
        let bothFailed = decode([
            ["id": "a", "audioDownloadStatus": "failed"],
            ["id": "b", "audioDownloadStatus": "failed"],
        ])
        XCTAssertFalse(DoubleDemoRule.canChooseVersion(bothFailed))
        XCTAssertEqual(DoubleDemoRule.readyCount(bothFailed), 0)
        XCTAssertEqual(DoubleDemoRule.failedCount(bothFailed), 2)

        let readyPending = decode([
            ["id": "a", "audioDownloadStatus": "ready", "audioUrl": "https://x/a"],
            ["id": "b", "audioDownloadStatus": "pending"],
        ])
        XCTAssertFalse(DoubleDemoRule.canChooseVersion(readyPending))

        let readyFailed = decode([
            ["id": "a", "audioDownloadStatus": "ready", "audioUrl": "https://x/a"],
            ["id": "b", "audioDownloadStatus": "failed"],
        ])
        XCTAssertTrue(DoubleDemoRule.canChooseVersion(readyFailed), "§5 行 5：唯一可选项也要能用")

        let bothReady = decode([
            ["id": "a", "audioDownloadStatus": "ready", "audioUrl": "https://x/a"],
            ["id": "b", "audioDownloadStatus": "ready", "audioUrl": "https://x/b"],
        ])
        XCTAssertTrue(DoubleDemoRule.canChooseVersion(bothReady))
    }
}
