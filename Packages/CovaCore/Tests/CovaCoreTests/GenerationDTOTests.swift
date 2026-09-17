import CovaCore
import XCTest

final class GenerationDTOTests: XCTestCase {
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
        let job = response.job
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
