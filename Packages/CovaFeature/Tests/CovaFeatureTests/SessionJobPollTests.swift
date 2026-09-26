import CovaCore
import Foundation
import XCTest

/// §5 P1-5「轮询断链补腿」在**接线层**的那半本账。
///
/// `CovaCore/SessionJobPollReconcileTests`（14 条）钉的是判据本身；这里钉的是
/// 「屏上那条腿真正拿到的东西」—— 也就是 `GET …/generation-jobs?id=` 的**响应信封**
/// 经过容忍解码之后，喂进判决的还是不是同一件事。
///
/// 为什么这一层值得单独有用例：本仓反复被烧的那一类缺陷是**绿 build、红屏幕**，
/// 而它最常见的入口恰恰是信封 —— 判决写得再对，只要解码把 `job` 读成 `nil`，
/// 屏上那条腿就会一路"什么都没读到"地投到 30 分钟上限，用户看见的是一个不动的进度条，
/// 而单元测试（只喂手写枚举）全是绿的。所以这批用例一律**从 JSON 出发**。
///
/// 不测视图渲染（TD-48：CovaFeature 只钉纯函数与媒体腿）。
final class SessionJobPollTests: XCTestCase {

    // MARK: - 夹具：逐字取自线上形态（2026-09-27 只读双向 GET 实测过键集合）

    /// 真实 succeeded 那一行的**骨架**：`metadata` 在线上是 JSON 字符串，
    /// 候选就在里面（这一条决定了"整行换上屏"是安全的）。签名地址一律换成站内相对路径，
    /// 用例不需要也不该带任何可用凭证。
    private let succeededEnvelope = """
    {"job":{"id":"job-77","sessionId":"s-1","status":"succeeded","costCredits":12,\
    "errorMessage":null,"createdAt":"2026-09-26T12:00:00.000Z",\
    "metadata":"{\\"candidates\\":[{\\"id\\":\\"c1\\",\\"title\\":\\"夏夜 A\\",\
    \\"audioUrl\\":\\"/api/proxy/audio?url=a1\\",\\"audioDownloadStatus\\":\\"ready\\",\
    \\"mediaReferenceId\\":\\"mr_1\\",\\"favorite\\":true},\
    {\\"id\\":\\"c2\\",\\"title\\":\\"夏夜 B\\",\
    \\"audioUrl\\":\\"/api/proxy/audio?url=a2\\",\\"audioDownloadStatus\\":\\"ready\\",\
    \\"mediaReferenceId\\":\\"mr_2\\"}],\\"outputCount\\":2,\\"source\\":\\"one_step\\"}"}}
    """

    /// 初始 INSERT 那一行：`status='submitted'`，而 `metadata` 里**没有** `candidates` 键
    /// （`web/src/lib/one-step/generation.ts:1122-1151`）。
    private let submittedEnvelope = """
    {"job":{"id":"job-77","sessionId":"s-1","status":"submitted",\
    "metadata":"{\\"source\\":\\"one_step\\",\\"outputCount\\":2,\\"billingState\\":\\"charged\\"}"}}
    """

    /// 重试那一行：`submitted` + **显式空数组**（同文件 `:2461-2472`）。
    /// 它和上一条是两种不同的"没有候选"，判决必须给出同一个答案。
    private let retriedEnvelope = """
    {"job":{"id":"job-77","sessionId":"s-1","status":"submitted",\
    "metadata":"{\\"candidates\\":[],\\"candidateCount\\":0,\\"attempt\\":2}"}}
    """

    private func decode(_ json: String) throws -> GenerationJobResponseDto {
        try JSONDecoder().decode(GenerationJobResponseDto.self, from: Data(json.utf8))
    }

    // MARK: - 信封 → 观测

    func testSucceededEnvelopeFeedsTheJudgeARealRow() throws {
        let response = try decode(succeededEnvelope)
        let job = try XCTUnwrap(response.job)
        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(job.candidates().count, 2, "候选就在 metadata 那串 JSON 里，读不到就等于看不见")

        let decision = SessionJobPollReconcile.decide(
            previous: .processing,
            observation: SessionJobPollReconcile.Observation(job: job),
            streamMidRound: false,
            attempt: 3
        )
        XCTAssertEqual(decision.reason, .terminalObserved)
        XCTAssertTrue(decision.settles, "08 那一格的环与 18 的真终态通知都挂在既有收口腿上")
        XCTAssertTrue(decision.writesCandidates, "带着两张已就绪的卡 ⇒ 屏上就该亮起来，不必离开再进来")
        XCTAssertFalse(decision.claimsFailure)
    }

    /// 这一条是整批用例里最值钱的一条：**判决正确、解码把候选读成空 ⇒ 屏上每 5 秒洗一次卡**。
    /// 所以两种"没有候选"（没有键 / 显式空数组）都必须落到"清单原样留着"。
    func testInFlightEnvelopesNeverOfferToClearTheCandidateList() throws {
        for json in [submittedEnvelope, retriedEnvelope] {
            let job = try XCTUnwrap(try decode(json).job)
            let observation = SessionJobPollReconcile.Observation(job: job)
            XCTAssertEqual(observation.status, .submitted)
            XCTAssertFalse(
                observation.carriesCandidates,
                "服务端这一行确实没带着候选；读成带着 ⇒ 屏上两张卡被空数组换掉"
            )
            let advancing = SessionJobPollReconcile.decide(
                previous: .queued, observation: observation, streamMidRound: false, attempt: 1
            )
            XCTAssertFalse(advancing.writesCandidates)
            XCTAssertFalse(advancing.settles)

            // 同一行若是终态（取消那一行通常就是没候选），清单同样不许被动。
            let cancelled = SessionJobPollReconcile.Observation(
                status: .cancelled, carriesCandidates: observation.carriesCandidates
            )
            let settled = SessionJobPollReconcile.decide(
                previous: .submitted, observation: cancelled, streamMidRound: false, attempt: 4
            )
            XCTAssertTrue(settled.settles)
            XCTAssertFalse(settled.writesCandidates, "取消时清单里没有东西 ⇒ 留着屏上那两张，别换成空")
        }
    }

    /// `{result:{jobId}}` 是 `plans/start` 的真实响应形态（见 `GenerationJobResponseDto` 注释）。
    /// 本屏不拿它当轮询结果，但它**会**流进同一个封套类型 ⇒ 必须落成"这一趟没读到"，
    /// 而不是把任务号读成状态、或让整条腿当场判定失败。
    func testSubmissionEnvelopeIsObservedAsNothingRead() throws {
        let response = try decode(
            #"{"result":{"jobId":"job-77","summary":"已扣 12 co"}}"#
        )
        XCTAssertNil(response.job)
        XCTAssertEqual(response.resolvedJobId, "job-77", "任务号还是要拿到：那是幂等账与通知的键")
        let decision = SessionJobPollReconcile.decide(
            previous: .processing,
            observation: SessionJobPollReconcile.Observation(job: response.job),
            streamMidRound: false,
            attempt: 2
        )
        XCTAssertEqual(decision.reason, .noObservation)
        XCTAssertFalse(decision.stops, "一次读不到不终止整条腿（网络抖动 ≠ 任务失败）")
        XCTAssertFalse(decision.claimsFailure)
        XCTAssertFalse(decision.writesJob)
    }

    // MARK: - 节拍只有一本账

    /// 本屏**不许**有第二张节拍表：复用 19 屏那一份（前 6 次 5s、之后 10s、上限约 30min），
    /// 于是"什么时候停"在两个屏上是同一个答案。
    func testScreenReusesTheSharedPollSchedule() {
        let shared = StudioCreatePollSchedule()
        XCTAssertEqual(shared.maximumAttemptCount, 183)
        XCTAssertEqual(shared.interval(forAttempt: 6), 5)
        XCTAssertEqual(shared.interval(forAttempt: 7), 10)
        XCTAssertTrue(shared.shouldPoll(attempt: 183))
        XCTAssertFalse(shared.shouldPoll(attempt: 184))
        // 判决的默认 schedule 就是它：第 184 趟落 `.capReached`（停，而**不**说失败）。
        let cap = SessionJobPollReconcile.decide(
            previous: .processing,
            observation: SessionJobPollReconcile.Observation(status: .processing, carriesCandidates: false),
            streamMidRound: false,
            attempt: 184
        )
        XCTAssertEqual(cap.reason, .capReached)
        XCTAssertFalse(cap.claimsFailure)
        XCTAssertFalse(cap.settles, "到上限不是'结束'：环该继续亮着，等下一次载荷说真话")
    }
}
