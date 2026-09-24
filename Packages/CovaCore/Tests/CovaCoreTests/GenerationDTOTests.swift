import CovaCore
import XCTest

final class GenerationDTOTests: XCTestCase {
    /// **真实 start 响应**（2026-09-24 真实账号实测）：顶层是 `{result, summary}`，
    /// 任务号在 `result.jobId` —— 与契约文档写的 `{job:…}` 不是一回事（web 同样读
    /// `payload.result.jobId`，`useAgentV2Session.ts:127-128`）。这条用例守的是**钱**：
    /// 旧实现解不出 `{job}` 就抛错 ⇒ UI 说「这次没提交成功」⇒ 用户再点 ⇒ 换幂等键
    /// ⇒ **第二次扣费**。
    func testStartResponseAcceptsTheRealResultJobIdShape() throws {
        let json = Data(#"{"result":{"jobId":"job-77","status":"submitted"},"summary":"已排产"}"#.utf8)
        let response = try JSONDecoder().decode(GenerationJobResponseDto.self, from: json)
        XCTAssertEqual(response.resolvedJobId, "job-77")
        XCTAssertFalse(response.isUnresolvedSubmission)
    }

    /// 契约文档形态仍然要接（`generation-jobs?id=` 的真实响应就是 `{job}`）。
    func testStartResponseStillAcceptsTheContractJobShape() throws {
        let json = Data(#"{"job":{"id":"job-88","status":"submitted","costCredits":100}}"#.utf8)
        let response = try JSONDecoder().decode(GenerationJobResponseDto.self, from: json)
        XCTAssertEqual(response.job?.id, "job-88")
        XCTAssertEqual(response.resolvedJobId, "job-88")
        XCTAssertFalse(response.isUnresolvedSubmission)
    }

    /// 2xx 却**没有任何任务号** ⇒ 解码不许抛错，而是给出可区分的状态：
    /// 提交可能已经发生，调用方必须去核对权威任务列表，而不是断言"没提交"。
    func testStartResponseWithoutAnyJobIdIsFlaggedNotThrown() throws {
        let json = Data(#"{"result":{"note":"queued"},"summary":"ok"}"#.utf8)
        let response = try JSONDecoder().decode(GenerationJobResponseDto.self, from: json)
        XCTAssertNil(response.resolvedJobId)
        XCTAssertTrue(response.isUnresolvedSubmission)
    }

    /// D8「一次逻辑操作 = 一个幂等键」：同一 `(会话, 计划卡, revision)` 的重试复用同一个键，
    /// 换计划卡 / 抬 revision 才是新操作；显式作废后才允许再发新键。
    func testPlanStartTokenIsReusedForTheSameLogicalOperation() throws {
        var ledger = PlanStartTokenLedger()
        let first = ledger.token(sessionID: "s-1", planCardID: "c-1", revision: 1)
        let retry = ledger.token(sessionID: "s-1", planCardID: "c-1", revision: 1)
        XCTAssertEqual(first, retry, "同一次点击的重试必须带同一个键，否则等于允许第二次扣费")
        XCTAssertNotEqual(
            ledger.token(sessionID: "s-1", planCardID: "c-2", revision: 1), first, "不同计划卡是不同操作"
        )
        let bumped = ledger.token(sessionID: "s-1", planCardID: "c-1", revision: 2)
        XCTAssertNotEqual(bumped, first, "revision 变了 = 用户改了要求 = 新一次操作")
        ledger.invalidate(sessionID: "s-1", planCardID: "c-1", revision: 2)
        XCTAssertNotEqual(
            ledger.token(sessionID: "s-1", planCardID: "c-1", revision: 2), bumped,
            "作废后重新发起才允许换新键"
        )
    }

    func testJobStatusCoversExactlySixContractStates() {
        XCTAssertEqual(GenerationJobStatus.allCases.count, 6)
        XCTAssertEqual(
            Set(GenerationJobStatus.allCases.map(\.rawValue)),
            ["queued", "submitted", "processing", "succeeded", "failed", "cancelled"]
        )
    }

    func testJobStatusDecodesEveryContractValue() throws {
        for status in GenerationJobStatus.allCases {
            let decoded = try JSONDecoder().decode(
                GenerationJobStatus.self,
                from: Data("\"\(status.rawValue)\"".utf8)
            )
            XCTAssertEqual(decoded, status)
        }
    }

    func testUnknownJobStatusFailsDecoding() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(GenerationJobStatus.self, from: Data("\"paused\"".utf8))
        )
    }

    func testDecodesGenerationJobAndMetadataCandidates() throws {
        let response = try Fixture.decode(GenerationJobResponseDto.self, "generation-job")
        // `job` 现在是可选的（真实的 start 响应 `{result:{jobId}}` 里根本没有 job 对象），
        // 所以这条既有用例改为**显式断言该 fixture 里 job 必须在**——比原来更严，不是放宽。
        let job = try XCTUnwrap(response.job)
        XCTAssertEqual(job.id, "job-test-0001")
        XCTAssertEqual(job.sessionId, "session-test-0001")
        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(job.costCredits, 315)
        XCTAssertEqual(job.idempotencyKey, "idem-test-0001")
        XCTAssertNil(job.errorMessage)
        XCTAssertEqual(job.completedAt, "2026-09-17T02:12:00.000Z")

        let metadata = try XCTUnwrap(job.decodedMetadata())
        XCTAssertEqual(metadata.candidates?.count, 2)
        let candidates = job.candidates()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].id, "cand-1")
        XCTAssertEqual(candidates[0].title, "Summer Signal")
        XCTAssertEqual(candidates[0].audioUrl?.rawValue, "https://cdn.invalid/audio/c1.mp3")
        XCTAssertEqual(candidates[0].audioDownloadStatus, .ready)
        XCTAssertEqual(candidates[0].audioDownloadUrl?.rawValue, "https://cdn.invalid/audio/c1-download.mp3")
        XCTAssertEqual(candidates[0].mediaReferenceId, "ref-1")
        XCTAssertEqual(candidates[0].favorite, false)
        XCTAssertEqual(candidates[0].duration, 118.4)
        XCTAssertEqual(candidates[1].audioDownloadStatus, .pending)
        XCTAssertNil(candidates[1].audioDownloadUrl)
    }

    func testCandidateSettledStatusesMatchContract() throws {
        for raw in ["pending", "ready", "failed"] {
            let decoded = try JSONDecoder().decode(
                GenerationCandidateDownloadStatus.self,
                from: Data("\"\(raw)\"".utf8)
            )
            XCTAssertEqual(decoded.rawValue, raw)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                GenerationCandidateDownloadStatus.self,
                from: Data("\"unknown\"".utf8)
            )
        )
    }

    func testJobListToleratesMissingMetadataAndSession() throws {
        let response = try Fixture.decode(GenerationJobsResponseDto.self, "generation-jobs")
        XCTAssertEqual(response.jobs.count, 2)

        let processing = response.jobs[0]
        XCTAssertEqual(processing.status, .processing)
        XCTAssertEqual(processing.candidates().count, 0)

        let failed = response.jobs[1]
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(failed.sessionId)
        XCTAssertNil(failed.metadata)
        XCTAssertNil(failed.idempotencyKey)
        XCTAssertNil(failed.decodedMetadata())
        XCTAssertEqual(failed.candidates().count, 0)
        XCTAssertEqual(failed.errorMessage, "生成服务繁忙，请重试")
    }

    func testMetadataToleratesMalformedJSON() throws {
        let json = Data(#"{"jobs":[{"id":"j1","status":"queued","metadata":"{not json"}]}"#.utf8)
        let response = try JSONDecoder().decode(GenerationJobsResponseDto.self, from: json)
        XCTAssertNil(response.jobs[0].decodedMetadata())
        XCTAssertEqual(response.jobs[0].candidates().count, 0)
    }

    func testMissingJobStatusFailsDecoding() {
        let json = Data(#"{"job":{"id":"j1"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GenerationJobResponseDto.self, from: json))
    }
}
