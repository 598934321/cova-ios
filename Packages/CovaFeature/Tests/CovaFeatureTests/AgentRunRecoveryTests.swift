import CovaCore
import CovaFeature
import XCTest

/// 断流恢复腿的判据（§5 P1-5 后半 / §7 #52）。
///
/// 这一层只钉"纯判据"：runId 从哪一帧来、`run.status` 能换成哪句已有的话、
/// 什么时候该继续问。调度（令牌、节拍）在视图那一侧，形状与本屏任务轮询同源，
/// 不在这里重钉一遍。
final class AgentRunRecoveryTests: XCTestCase {

    private func frame(_ event: String, _ json: String) -> CovaSSEFrame {
        CovaSSEFrame(rawEventName: event, payload: Data(json.utf8))
    }

    // MARK: runId 的来源

    func testRunIDIsTakenOnlyFromTheRunStartedFrame() {
        let id = AgentRunRecovery.runID(
            from: frame("run_started", #"{"runId":"run-3f9a","turnId":"t-1","autonomous":true}"#)
        )
        XCTAssertEqual(id, "run-3f9a", "run_started 的 runId 是这条腿唯一的号源")
    }

    func testRunIDIgnoresOtherRunLifecycleFramesEvenWhenTheyCarryThatKey() {
        // 服务端今天只在 run_started 里放 runId；别的帧就算哪天放了，也不许顺手改这个号
        // （改了就是把两条运行混成一条）。
        XCTAssertNil(
            AgentRunRecovery.runID(from: frame("run_completed", #"{"runId":"run-9"}"#)),
            "非 run_started 的 run_* 帧不许改 runId"
        )
        XCTAssertNil(
            AgentRunRecovery.runID(from: frame("text", #"{"runId":"run-9"}"#)),
            "普通事件帧更不是号源"
        )
    }

    func testRunIDIsNilWhenThePayloadDoesNotCarryThatKey() {
        XCTAssertNil(
            AgentRunRecovery.runID(from: frame("run_started", #"{"turnId":"t-1"}"#)),
            "没给 runId 就是没给 ⇒ nil，不猜同载荷里的别的键当号"
        )
        XCTAssertNil(
            AgentRunRecovery.runID(from: frame("run_started", "not json")),
            "坏载荷不许产出一个号（那会凭一次解码失败发起一整条轮询）"
        )
    }

    // MARK: status → 屏上短语

    func testStatusLabelsAreTheFourPhrasesAlreadyInTheScreenSpec() {
        let cases: [(String, String)] = [
            ("waiting_user", "等待你的决定"),
            ("waiting_worker", "歌曲制作中"),
            ("completed", "处理完成"),
            ("failed", "处理失败"),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(
                AgentRunRecovery.label(forStatus: status), expected,
                "09 §3.F 表里已有的那四条，恢复腿只能复用，不许改字"
            )
        }
    }

    func testInFlightStatusesProduceNoNewLabel() {
        // planning/executing/verifying/repairing 都不在 §3.F 表里 ⇒ 那一格写的是
        // "不显示、保持上一条不回落"。这里钉的是**这一层不给字符串**，
        // 回落与否由视图决定 —— 一旦这里冒出"正在规划"之类，就是替服务端发明了文案。
        for status in ["planning", "executing", "verifying", "repairing", "未知态", "", nil] {
            XCTAssertNil(
                AgentRunRecovery.label(forStatus: status),
                "表外的状态不许带出任何新短语：\(String(describing: status))"
            )
        }
    }

    // MARK: 终态词表（接线层注入的那一份）

    func testTerminalVocabularyIsExactlyTheTwoMeasuredStatuses() {
        let vocabulary = AgentRunRecovery.terminalVocabulary
        XCTAssertTrue(vocabulary.isDeclared, "词表没注入 ⇒ 本层永不报终态，轮询会问到天荒地老")
        XCTAssertEqual(vocabulary.terminality(of: "completed"), .success)
        XCTAssertEqual(vocabulary.terminality(of: "failed"), .failure)
        XCTAssertEqual(vocabulary.terminality(of: "executing"), .running)
        XCTAssertEqual(vocabulary.terminality(of: nil), .unknown)
        XCTAssertEqual(
            vocabulary.successStatuses, ["completed"],
            "词表出处是 web/src/lib/agent/run.ts:7；多一个少一个都要先回服务端核"
        )
        XCTAssertEqual(vocabulary.failureStatuses, ["failed"])
    }

    // MARK: 该不该发这一趟

    func testPollIsNotArmedWithoutARunID() {
        XCTAssertFalse(
            AgentRunRecovery.shouldPoll(runID: nil, streamOwnsRound: false, lastTerminality: .unknown),
            "没有 runId 就没东西可问（也不许裸访问端点前缀）"
        )
    }

    func testPollIsNotArmedWhileTheStreamOwnsThisRound() {
        XCTAssertFalse(
            AgentRunRecovery.shouldPoll(runID: "run-1", streamOwnsRound: true, lastTerminality: .running),
            "流还活着这一轮 ⇒ 主人是流，轮询回来也只能丢，不如不发"
        )
    }

    func testPollStopsOnTerminalButNotOnUnknown() {
        XCTAssertFalse(
            AgentRunRecovery.shouldPoll(runID: "run-1", streamOwnsRound: false, lastTerminality: .success),
            "服务端已经说完成，继续问只是白要"
        )
        XCTAssertFalse(
            AgentRunRecovery.shouldPoll(runID: "run-1", streamOwnsRound: false, lastTerminality: .failure)
        )
        XCTAssertTrue(
            AgentRunRecovery.shouldPoll(runID: "run-1", streamOwnsRound: false, lastTerminality: .running)
        )
        XCTAssertTrue(
            AgentRunRecovery.shouldPoll(runID: "run-1", streamOwnsRound: false, lastTerminality: .unknown),
            "「还没拿到事实」不等于「没事可做」⇒ 这一格要继续问"
        )
    }
}
