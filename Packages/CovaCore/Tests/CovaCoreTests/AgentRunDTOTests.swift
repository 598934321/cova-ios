@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/studio/agent-runs/{id}` 的契约面（DEVELOPMENT.md §4.7 那条就地更正）。
///
/// 这一条腿最容易被写错的地方，是把它当成"SSE 恢复"：
/// `/api/studio/agent` 的流**每帧只有 `event:`/`data:`，没有 `id:` 行**，服务端**没有
/// Last-Event-ID 处理、没有环形缓冲** ⇒ 断线期间的事件被静默丢弃，按事件 id 续流这件事
/// 在这台服务端上不存在。能做的只有**轮询对账**（`status` / `currentStep` / `timeline[].sequence`）。
/// 本文件因此重点测 `AgentRunReconciler` 的判据顺序，尤其是那条**没有词表就不许报终态**。
final class AgentRunDTOTests: XCTestCase {

    // MARK: - 快照解码

    func testRunSnapshotDecodesEveryContractKey() throws {
        let response = try Fixture.decode(AgentRunResponseDto.self, "agent-run-snapshot")
        XCTAssertTrue(response.hasRun)
        XCTAssertFalse(response.isUnreadableEnvelope)
        let run = try XCTUnwrap(response.run)
        XCTAssertEqual(run.id, "run-3f9a1c")
        XCTAssertEqual(run.sessionId, "sess-test-0001")
        XCTAssertEqual(run.turnId, "turn-7")
        XCTAssertEqual(run.goal, "做一首夏日城市流行")
        XCTAssertEqual(run.status, "working")
        XCTAssertEqual(run.stepLabel, "写词")
        XCTAssertEqual(run.retryCount, 0)
        XCTAssertNil(run.stopReason, "还在跑就没有停止原因；服务端给了 null 就是 null")
        XCTAssertEqual(run.createdAt, "2026-09-26T07:00:00.000Z")
        XCTAssertEqual(run.updatedAt, "2026-09-26T07:03:12.000Z")
        XCTAssertTrue(run.hasTimelineKey)
    }

    /// `sequence` 是服务端**追加时**按 `timeline.length + 1` 赋的号 ⇒ 重建过就可能跳号。
    /// 本层只把它当"读到过多大"的单调信号，不当持久游标，也不按下标补一个。
    func testSequenceIsReadAsGivenIncludingGapsAndMissingValues() throws {
        let run = try XCTUnwrap(Fixture.decode(AgentRunResponseDto.self, "agent-run-snapshot").run)
        XCTAssertEqual(run.timeline.count, 3)
        XCTAssertEqual(run.timeline.compactMap(\.sequence), [1, 2, 4], "跳号原样留着，不重新编号")
        XCTAssertEqual(run.latestSequence, 4)
        XCTAssertNil(run.timeline[1].fields["sequence"]?.text, "号是数字，不是字符串")

        // 缺 sequence / 带小数 / 字符串形态都不许被"补"成一个号。
        let sloppy = try JSONDecoder().decode(
            AgentRunResponseDto.self,
            from: Data(#"{"run":{"id":"r","timeline":[{"kind":"a"},{"sequence":2.5},{"sequence":"3"}]}}"#.utf8)
        ).run
        XCTAssertEqual(sloppy?.timeline.count, 3)
        XCTAssertEqual(sloppy?.timeline[0].sequence, nil)
        XCTAssertEqual(sloppy?.timeline[1].sequence, nil, "2.5 不是 2 也不是 3")
        XCTAssertEqual(sloppy?.timeline[2].sequence, nil, "字符串号不猜")
        XCTAssertNil(sloppy?.latestSequence)
        XCTAssertEqual(sloppy?.timelineCount, 3, "而条数仍然可用（兜底判据）")
    }

    /// 条目里除 `sequence` 之外的键名**未实测** ⇒ 原样保留、按已知键名读，不发明属性。
    func testTimelineEntriesKeepTheirKeysInsteadOfInventingAStepProperty() throws {
        let run = try XCTUnwrap(Fixture.decode(AgentRunResponseDto.self, "agent-run-snapshot").run)
        let entry = try XCTUnwrap(run.timeline.first)
        XCTAssertEqual(entry.presentKeys, ["sequence", "kind", "label"])
        XCTAssertEqual(entry.text(for: "kind"), "step_started")
        XCTAssertEqual(entry.text(for: "label"), "开始写词")
        XCTAssertNil(entry.text(for: "message"), "没这个键就是没有，不回落成空串")
        // 本层没有 `.event`/`.kindName`/`.step` 这类**猜出来的键名**：属性只有两个。
        let labels = Set(Mirror(reflecting: entry).children.compactMap(\.label))
        XCTAssertEqual(labels, ["sequence", "fields"])
    }

    /// 词表分家的事实（§4.7）：timeline 的词汇与 SSE 事件名是**两套东西** ⇒
    /// `run_failed` 这类流事件名不该被认成本层任何枚举的一等分支。
    func testSSEEventNamesAreNotRunStatusesOrTimelineKindsHere() {
        // 本层根本没有状态/词汇枚举可撞 —— 状态是松散 String，词汇在 fields 里。
        XCTAssertEqual(CovaSSEEventType(rawName: "run_failed"), .runLifecycle("run_failed"))
        XCTAssertNil(
            try JSONDecoder().decode(AgentRunResponseDto.self, from: Data(#"{"run":{}}"#.utf8)).run?.status
        )
    }

    /// `plan` / `checkpoint` 的形状未实测 ⇒ 原样留着可寻址，不摊平成一堆可选字段。
    func testPlanAndCheckpointArePreservedAsRawValues() throws {
        let run = try XCTUnwrap(Fixture.decode(AgentRunResponseDto.self, "agent-run-snapshot").run)
        let steps = run.plan?.objectValue?["steps"]?.arrayValue
        XCTAssertEqual(steps?.count, 2)
        XCTAssertEqual(steps?.first?.objectValue?["label"]?.text, "写词")
        XCTAssertEqual(run.checkpoint?.objectValue?["attempt"]?.integer, 1)
        XCTAssertNil(run.checkpoint?.objectValue?["attempt"]?.text)
        XCTAssertNil(run.checkpoint?.arrayValue, "对象不是数组：拿不到就不是拿不到")
    }

    /// 脱敏：goal 与载荷都不许出现在描述/反射里（硬边界 3；默认反射会把 agent 内部载荷整包印进日志）。
    func testDescriptionIsRedactedToIdentityStatusAndCounts() throws {
        let run = try XCTUnwrap(Fixture.decode(AgentRunResponseDto.self, "agent-run-snapshot").run)
        let rendered = [String(describing: run), String(reflecting: run)]
        for text in rendered {
            XCTAssertFalse(text.contains("做一首夏日城市流行"), "goal 上日志了：\(text)")
            // `currentStep` **是**摘要的一部分（它就是三条对账信号之一）；
            // 不许出去的是 goal 原文与 plan / checkpoint / timeline 的载荷。
            XCTAssertFalse(text.contains("出曲"), "plan 载荷上日志了：\(text)")
            XCTAssertFalse(text.contains("lyrics"), "checkpoint 载荷上日志了：\(text)")
            XCTAssertFalse(text.contains("step_started"), "timeline 词汇上日志了：\(text)")
        }
        XCTAssertTrue(rendered[0].contains("run-3f9a1c"))
        XCTAssertTrue(rendered[0].contains("working"))
        XCTAssertTrue(rendered[0].contains("currentStep: 写词"))
        XCTAssertTrue(rendered[0].contains("latestSequence: 4"))
    }

    // MARK: - 信封

    func testEnvelopeDistinguishesNoRunFromAnUnreadableRun() throws {
        let empty = try JSONDecoder().decode(
            AgentRunResponseDto.self, from: Data("{}".utf8)
        )
        XCTAssertNil(empty.run)
        XCTAssertTrue(empty.isUnreadableEnvelope)
        XCTAssertFalse(empty.runKeyPresentButUnreadable, "缺键不是「给了读不出的 run」")

        let nullRun = try JSONDecoder().decode(
            AgentRunResponseDto.self, from: Data(#"{"run":null}"#.utf8)
        )
        XCTAssertFalse(nullRun.runKeyPresentButUnreadable)

        for wrongShape in [#"{"run":"working"}"#, #"{"run":[1,2]}"#, #"{"run":3}"#] {
            let shaped = try JSONDecoder().decode(
                AgentRunResponseDto.self, from: Data(wrongShape.utf8)
            )
            XCTAssertNil(shaped.run, "\(wrongShape) 不许变成一个字段全空的幻影 run")
            XCTAssertTrue(shaped.runKeyPresentButUnreadable, "给了 run 却读不出 ⇒ 契约漂移，必须可见")
        }
    }

    func testPathGateRejectsUnsafeRunIdentifiers() {
        XCTAssertEqual(AgentRunResponseDto.path(runID: "run-3f9a1c"), "/api/studio/agent-runs/run-3f9a1c")
        XCTAssertNil(AgentRunResponseDto.path(runID: ""))
        XCTAssertNil(AgentRunResponseDto.path(runID: "run 1"), "空白不许进路径")
        XCTAssertNil(AgentRunResponseDto.path(runID: "run/../../x"))
        XCTAssertNil(AgentRunResponseDto.path(runID: "a:b:c"), "至多一个冒号（伪 id 的规则同源）")
    }

    func testFailureBucketsKeepTheServerSentenceAndNeverClaimAFailedRun() {
        XCTAssertEqual(
            AgentRunRejection.classify(
                statusCode: 404, body: Data(#"{"error":"运行记录不存在"}"#.utf8)
            ),
            .runMissing(serverMessage: "运行记录不存在")
        )
        XCTAssertEqual(
            AgentRunRejection.classify(statusCode: 404, body: nil).userMessage, "找不到这条运行记录"
        )
        XCTAssertEqual(AgentRunRejection.classify(statusCode: 401, body: nil), .unauthenticated)
        // 英文码形状不上屏（A15）。
        XCTAssertFalse(
            AgentRunRejection.classify(
                statusCode: 404, body: Data(#"{"error":"RUN_NOT_FOUND"}"#.utf8)
            ).userMessage.contains("RUN_NOT_FOUND")
        )
        XCTAssertEqual(
            AgentRunRejection.classify(statusCode: 500, body: nil).userMessage, "服务端错误（500）"
        )
    }

    // MARK: - 轮询对账（本条腿的正题）

    /// 没有词表就没有终态判断 —— 这条是本文件最重的一条：
    /// 词表未实测时**猜**一个终态，要么让 UI 提前收尾（把还在跑的运行说成结束了），
    /// 要么让轮询永不停。宁可继续问，也不猜。
    func testTerminalityIsNeverInventedWithoutADeclaredVocabulary() throws {
        let fresh = try decodeRun(#"{"id":"r","status":"failed","stopReason":"上游超时"}"#)
        for previous in [nil, fresh] {
            XCTAssertEqual(
                AgentRunReconciler.reconcile(previous: previous, fresh: fresh),
                previous == nil ? .progressed : .unchanged,
                "词表没注入时，这条 failed 也只能被读成没变化，不许被读成终态"
            )
        }
        XCTAssertFalse(AgentRunTerminalVocabulary.notDeclared.isDeclared)
    }

    func testDeclaredVocabularyReportsTerminalStatesAndFailureWinsTies() throws {
        let vocabulary = AgentRunTerminalVocabulary(
            successStatuses: ["completed", "succeeded"],
            failureStatuses: ["failed", "cancelled"]
        )
        XCTAssertTrue(vocabulary.isDeclared)
        XCTAssertEqual(vocabulary.terminality(of: "completed"), .success)
        XCTAssertEqual(vocabulary.terminality(of: "failed"), .failure)
        XCTAssertEqual(vocabulary.terminality(of: "working"), .running)
        XCTAssertEqual(vocabulary.terminality(of: nil), .unknown)
        XCTAssertEqual(vocabulary.terminality(of: ""), .unknown)

        let failed = try decodeRun(#"{"id":"r","status":"failed","stopReason":"上游制作失败"}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(fresh: failed, terminal: vocabulary),
            .terminalFailed(stopReason: "上游制作失败")
        )
        let succeeded = try decodeRun(#"{"id":"r","status":"completed"}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(fresh: succeeded, terminal: vocabulary), .terminalSuccess
        )
        // 同一个状态同时进两个集合 ⇒ 失败优先（"停下并报失败"比"停下并报成功"少骗人）。
        let contradictory = AgentRunTerminalVocabulary(
            successStatuses: ["done"], failureStatuses: ["done"]
        )
        XCTAssertEqual(contradictory.terminality(of: "done"), .failure)
    }

    /// 已经在终态上再读到同一次终态 ⇒ **仍报终态**（"停轮询"这个信号不能因为两次读数相同就消失）。
    func testRepeatedTerminalSnapshotStaysTerminalNotUnchanged() throws {
        let vocabulary = AgentRunTerminalVocabulary(successStatuses: ["completed"], failureStatuses: [])
        let first = try decodeRun(#"{"id":"r","status":"completed","stopReason":null}"#)
        let again = try decodeRun(#"{"id":"r","status":"completed","stopReason":null}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: first, fresh: again, terminal: vocabulary),
            .terminalSuccess
        )
    }

    func testProgressIsDetectedOnTheThreeNamedSignals() throws {
        let vocabulary = AgentRunTerminalVocabulary(successStatuses: ["completed"], failureStatuses: [])
        let before = try decodeRun(
            #"{"id":"r","status":"working","currentStep":"写词","timeline":[{"sequence":1}],"retryCount":0}"#
        )
        // ① currentStep 变
        let stepMoved = try decodeRun(
            #"{"id":"r","status":"working","currentStep":"出曲","timeline":[{"sequence":1}],"retryCount":0}"#
        )
        // ② status 变
        let statusMoved = try decodeRun(
            #"{"id":"r","status":"running","currentStep":"写词","timeline":[{"sequence":1}],"retryCount":0}"#
        )
        // ③ timeline 的 sequence 变大
        let sequenceMoved = try decodeRun(
            #"{"id":"r","status":"working","currentStep":"写词","timeline":[{"sequence":1},{"sequence":2}],"retryCount":0}"#
        )
        // ④ retryCount 变（同一条可见变化的另一种）
        let retried = try decodeRun(
            #"{"id":"r","status":"working","currentStep":"写词","timeline":[{"sequence":1}],"retryCount":1}"#
        )
        for fresh in [stepMoved, statusMoved, sequenceMoved, retried] {
            XCTAssertEqual(
                AgentRunReconciler.reconcile(previous: before, fresh: fresh, terminal: vocabulary),
                .progressed, "\(fresh)"
            )
        }
        let identical = try decodeRun(
            #"{"id":"r","status":"working","currentStep":"写词","timeline":[{"sequence":1}],"retryCount":0}"#
        )
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: before, fresh: identical, terminal: vocabulary),
            .unchanged
        )
        // sequence 全都读不出时，条目数才是唯一看得见的进展。
        let noNumbers = try decodeRun(#"{"id":"r","status":"working","currentStep":"写词","timeline":[{},{}]}"#)
        let sameNoNumbers = try decodeRun(#"{"id":"r","status":"working","currentStep":"写词","timeline":[{}]}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: sameNoNumbers, fresh: noNumbers, terminal: vocabulary),
            .progressed
        )
    }

    /// 拿错快照（id 不同）不许被读成"没进展"。
    func testIdentityMismatchIsItsOwnOutcome() throws {
        let previous = try decodeRun(#"{"id":"run-a","status":"working"}"#)
        let other = try decodeRun(#"{"id":"run-b","status":"working"}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: previous, fresh: other),
            .identityMismatch(expectedRunID: "run-a", observedRunID: "run-b")
        )
        // 任一边没有 id ⇒ 无从判身份，退回正常的进展/不变判断（不编一个 mismatch）。
        let anonymous = try decodeRun(#"{"status":"working"}"#)
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: previous, fresh: anonymous), .unchanged
        )
        XCTAssertEqual(
            AgentRunReconciler.reconcile(previous: anonymous, fresh: anonymous), .unchanged
        )
    }

    /// 首帧：屏幕上刚刚多出一份可显示的东西 ⇒ 报"有进展"，不是"没变化"。
    func testFirstSnapshotIsProgressedNotUnchanged() throws {
        let fresh = try decodeRun(#"{"id":"run-a","status":"working","timeline":[{"sequence":1}]}"#)
        XCTAssertEqual(AgentRunReconciler.reconcile(fresh: fresh), .progressed)
        XCTAssertNil(fresh.timeline.first?.text(for: "kind"), "没有的键就是没有")
    }

    /// 直接构造一份 run（信封那条腿另有它的用例）。
    private func decodeRun(_ json: String) throws -> AgentRunDto {
        try XCTUnwrap(
            JSONDecoder().decode(AgentRunResponseDto.self, from: Data(#"{"run":\#(json)}"#.utf8)).run,
            "run 读不出来：\(json)"
        )
    }
}
