import CovaCore
import XCTest
@testable import CovaPlayer

/// 播放上报去重（D8 / api-contracts §5 / TD-19）。
///
/// 全部经桩提交器，**零真实网络**。
final class PlayReportCoordinatorTests: XCTestCase {
    private var submitter: StubPlayReportSubmitter!
    private var subject: PlayReportCoordinator!
    private let authenticated = PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"))

    override func setUp() {
        super.setUp()
        submitter = StubPlayReportSubmitter()
        subject = PlayReportCoordinator(submitter: submitter)
    }

    override func tearDown() {
        submitter = nil
        subject = nil
        super.tearDown()
    }

    private func bind(_ context: PlaybackSessionContext) async {
        _ = await subject.bindSession(context)
    }

    private func start(_ id: String, kind: PlaybackItem.Kind = .libraryTrack) async -> PlayReportOutcome {
        await subject.playbackStarted(itemID: id, kind: kind, session: authenticated)
    }

    // MARK: - 一次实际播放 = 一个键

    func testFirstActualPlaybackSendsExactlyOneRequest() async {
        await bind(authenticated)
        let outcome = await start("track-1")
        guard case .sent(let itemID, let key) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(itemID, "track-1")
        XCTAssertTrue(key.isCanonical(for: .playReport), "\(key)")
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        let sources = await submitter.sources
        XCTAssertEqual(sources, ["app-ios"], "source 恒为 app-ios（D10）")
        let tracks = await submitter.trackIDs
        XCTAssertEqual(tracks, ["track-1"])
        let reported = await subject.reportedCount()
        XCTAssertEqual(reported, 1)
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
    }

    func testKeyIsGeneratedOnceAndReusedAcrossRetries() async {
        await bind(authenticated)
        await submitter.script(StubPlayReportSubmitter.Script(failures: [0: .transport]))
        let first = await start("track-1")
        guard case .failed(_, let key, let reason) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(reason, .transport)
        XCTAssertTrue(key.isCanonical(for: .playReport))

        let retried = await subject.retryPending()
        XCTAssertEqual(retried.count, 1)
        guard case .sent(_, let secondKey)? = retried.first else { return XCTFail("\(retried)") }
        XCTAssertEqual(secondKey, key, "重试同一播放必须复用同一幂等键（TD-19）")
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 2)
        var keys = await submitter.keys
        keys = Array(Set(keys))
        XCTAssertEqual(keys.count, 1, "两次提交只携带一个键")
    }

    func testRepeatedStartOfSameEpisodeDoesNotDoubleReport() async {
        await bind(authenticated)
        let first = await start("track-1")
        if case .sent = first {} else { return XCTFail("\(first)") }
        let second = await start("track-1")
        XCTAssertEqual(second, .suppressed(itemID: "track-1", reason: .alreadyReported))
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 1, "pause/resume 误重入不得产生第二次上报")
    }

    func testSameTrackPlayedAgainLaterGetsNewKey() async {
        await bind(authenticated)
        let first = await start("track-1")
        guard case .sent(_, let oldKey) = first else { return XCTFail("\(first)") }
        await subject.playbackEnded(itemID: "track-1")
        let second = await start("track-1")
        guard case .sent(_, let newKey) = second else { return XCTFail("\(second)") }
        XCTAssertNotEqual(oldKey, newKey, "集次结束后同一曲目再次播放是新键")
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 2)
    }

    func testDifferentTracksGetDifferentKeys() async {
        await bind(authenticated)
        let first = await start("track-1")
        guard case .sent(_, let keyA) = first else { return XCTFail("\(first)") }
        let second = await start("track-2")
        guard case .sent(_, let keyB) = second else { return XCTFail("\(second)") }
        XCTAssertNotEqual(keyA, keyB)
    }

    // MARK: - 私有候选不上报

    func testPrivateCandidateIsNeverReported() async {
        await bind(authenticated)
        let outcome = await start("candidate-1", kind: .privateCandidate)
        XCTAssertEqual(outcome, .suppressed(itemID: "candidate-1", reason: .privateCandidate))
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
        let pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0, "候选音频不得留下未决集次")
        let key = await subject.activeEpisodeKey()
        XCTAssertNil(key)
    }

    // MARK: - 未认证：挂起而非丢包

    func testUnauthenticatedQueuesWithAllocatedKeyAndResendsWithSameKey() async {
        await bind(.unauthenticated)
        let queued = await start("track-1")
        guard case .queued(_, let key, let reason) = queued else { return XCTFail("\(queued)") }
        XCTAssertEqual(reason, .unauthenticated)
        XCTAssertTrue(key.isCanonical(for: .playReport), "挂起前键已分配：不静默丢包")
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
        var pending = await subject.pendingCount()
        XCTAssertEqual(pending, 1)

        // 凭证就绪后以同一键补发。
        await bind(authenticated)
        let outcomes = await subject.retryPending()
        guard case .sent(_, let resentKey)? = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(resentKey, key)
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - 前后台转场共用去重态

    func testForegroundBackgroundTransitionNeverReportsTwice() async {
        await bind(authenticated)
        _ = await start("track-1")
        let backgrounded = await subject.lifecyclePhaseChanged(.background)
        XCTAssertTrue(backgrounded.isEmpty, "转后台不产生新提交")
        let inactive = await subject.lifecyclePhaseChanged(.inactive)
        XCTAssertTrue(inactive.isEmpty)
        let resumed = await subject.lifecyclePhaseChanged(.active)
        XCTAssertTrue(resumed.isEmpty, "已成功的集次不再补发")
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 1, "前后台转场共用同一去重态")

        // 后台期间的新一轮播放：挂起，回前台以同键补发一次。
        _ = await subject.playbackEnded(itemID: "track-1")
        _ = await subject.lifecyclePhaseChanged(.background)
        let queued = await start("track-2")
        if case .queued = queued {} else { return XCTFail("后台应挂起：\(queued)") }
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        let outcomes = await subject.lifecyclePhaseChanged(.active)
        XCTAssertEqual(outcomes.count, 1)
        calls = await submitter.callCount
        XCTAssertEqual(calls, 2)
    }

    // MARK: - 会话推进（登出 / 换号）

    func testGenerationAdvanceDropsPendingWithoutSubmitting() async {
        await bind(.unauthenticated)
        _ = await start("track-1")
        var pending = await subject.pendingCount()
        XCTAssertEqual(pending, 1)
        let nextGeneration = SessionGeneration(value: 5)
        let dropped = await subject.bindSession(
            PlaybackSessionContext(owner: PrincipalID(rawValue: "p2"), generation: nextGeneration)
        )
        XCTAssertEqual(dropped, 1)
        pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 0, "登出/换号后不得把旧播放误报出去")

        // 旧 generation 的在途调用被拒绝。
        let stale = await subject.playbackStarted(
            itemID: "track-1", kind: .libraryTrack,
            session: PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"), generation: .initial)
        )
        XCTAssertEqual(stale, .dropped(itemID: "track-1", reason: .staleGeneration))
        calls = await submitter.callCount
        XCTAssertEqual(calls, 0)

        // 新会话的正常播放仍可上报。
        let fresh = await subject.playbackStarted(
            itemID: "track-9", kind: .libraryTrack,
            session: PlaybackSessionContext(owner: PrincipalID(rawValue: "p2"), generation: nextGeneration)
        )
        if case .sent = fresh {} else { return XCTFail("\(fresh)") }
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
    }

    func testInvalidateSessionsKeepsSentLedger() async {
        await bind(authenticated)
        let first = await start("track-1")
        guard case .sent(_, let key) = first else { return XCTFail("\(first)") }
        let dropped = await subject.invalidateSessions()
        XCTAssertEqual(dropped, 0)
        var reported = await subject.hasReported(key: key)
        XCTAssertTrue(reported, "已成功的去重账本必须保留")
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        _ = await subject.invalidateSessions(includingSent: true)
        reported = await subject.hasReported(key: key)
        XCTAssertFalse(reported)
    }

    // MARK: - 服务端幂等重放

    func testIdempotentReplayIsRecordedAsSuppressionButConsumesEpisode() async {
        await bind(authenticated)
        await submitter.script(StubPlayReportSubmitter.Script(replays: [0]))
        let outcome = await start("track-1")
        XCTAssertEqual(outcome, .suppressed(itemID: "track-1", reason: .idempotentReplay))
        let pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0, "服务端已记录 → 集次不再重投")
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
    }

    func testFailureClassificationCoversAPIErrorFamilies() {
        let cases: [(CovaAPIError, PlayReportFailure)] = [
            (.offline, .transport),
            (.timeout, .transport),
            (.transport(code: -1005), .transport),
            (.invalidResponse, .transport),
            (.cancelled, .transport),
            (.sessionChanged, .transport),
            (.credentialReadFailed, .transport),
            (.invalidRequestURL, .transport),
            (.unauthorized(apiCode: nil), .unauthorized),
            (.httpStatus(code: 503, apiCode: nil), .rejected),
            (.decoding(field: "recorded"), .decoding),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(PlayReportFailure.classify(error), expected, "\(error)")
        }
        XCTAssertEqual(PlayReportFailure.classify(CancellationError()), .transport)
        XCTAssertEqual(PlayReportFailure.classify(NSError(domain: "x", code: 1)), .unknown)
    }

    // MARK: - teardown

    func testTeardownDropsPendingAndRejectsLaterCalls() async {
        await bind(.unauthenticated)
        _ = await start("track-1")
        await subject.teardown()
        var pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
        let outcome = await start("track-2")
        XCTAssertEqual(outcome, .dropped(itemID: "track-2", reason: .tornDown))
        let retries = await subject.retryPending()
        XCTAssertTrue(retries.isEmpty)
        pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - 未决集次的有界性

    func testPendingEpisodesAreBounded() async {
        await bind(.unauthenticated)
        for index in 0..<(PlayReportCoordinator.maximumPendingEpisodes + 6) {
            _ = await start("track-\(index)")
        }
        let pending = await subject.pendingCount()
        XCTAssertLessThanOrEqual(pending, PlayReportCoordinator.maximumPendingEpisodes, "未决集次必须有上界")
        let calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - DTO 契约面

    func testRequestCarriesNoOverridePathForSource() throws {
        // `PlayReportRequestDto` 的 source 只有默认值 + 显式覆写；本层不提供覆写入口。
        let token = IdempotentRequestToken(operation: .playReport)
        let request = try PlayReportRequestDto(trackId: "t1", token: token)
        XCTAssertEqual(request.source, PlayReportRequestDto.appIOSSource)
        XCTAssertEqual(request.source, "app-ios")
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"source\":\"app-ios\""), json)
        XCTAssertTrue(json.contains(token.key.rawValue), json)
    }

    func testWrongOperationTokenIsRejected() {
        let wrong = IdempotentRequestToken(operation: .downloadCheckout)
        XCTAssertThrowsError(try PlayReportRequestDto(trackId: "t1", token: wrong))
    }

    func testOutcomeExposesItemIDForAllBranches() {
        let outcomes: [PlayReportOutcome] = [
            .sent(itemID: "a", key: try! IdempotencyKey(validating: "cova-play-report-00000000000000000000000000000000")),
            .queued(itemID: "b", key: try! IdempotencyKey(validating: "cova-play-report-00000000000000000000000000000000"), reason: .backgrounded),
            .suppressed(itemID: "c", reason: .privateCandidate),
            .dropped(itemID: "d", reason: .tornDown),
            .failed(itemID: "e", key: try! IdempotencyKey(validating: "cova-play-report-00000000000000000000000000000000"), reason: .unknown),
        ]
        XCTAssertEqual(outcomes.map(\.itemID), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(PlayReportHoldReason.backgrounded.description, "后台态，上报已挂起")
        XCTAssertEqual(PlayReportDropReason.staleGeneration.description, "会话已变更，该调用作废")
    }
}

/// 生产上报器：经**桩传输**验证出站形态（绝不访问线上）。
final class CovaAPIClientPlayReporterTests: XCTestCase {
    /// 记录型传输（零网络）。
    final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [HTTPRequest] = []
        var response = HTTPResponse(statusCode: 200, body: Data(#"{"recorded":true}"#.utf8))

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }

        var lastRequest: HTTPRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }

        func configure(_ value: HTTPResponse) {
            lock.lock()
            response = value
            lock.unlock()
        }

        private func record(_ request: HTTPRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            record(request)
            return snapshot()
        }

        private func snapshot() -> HTTPResponse {
            lock.lock()
            defer { lock.unlock() }
            return response
        }
    }

    func testSubmitterPostsToContractPathWithBearerAndIdempotencyKey() async throws {
        let transport = RecordingTransport()
        let credentials = StubCredentialProvider(principal: "p1")
        let client = CovaAPIClient(transport: transport, credentials: credentials)
        let reporter = CovaAPIClientPlayReporter(client: client)
        let token = IdempotentRequestToken(operation: .playReport)
        let request = try PlayReportRequestDto(trackId: "track-1", token: token)
        let response = try await reporter.submit(request)
        XCTAssertEqual(response.recorded, true)
        XCTAssertEqual(transport.count, 1)
        let sent = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(sent.method, .post)
        XCTAssertEqual(sent.url.path, "/api/tracks/play")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(sent.url), "唯一出口（D10）")
        let body = String(data: try XCTUnwrap(sent.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"source\":\"app-ios\""), body)
        XCTAssertTrue(body.contains(token.key.rawValue), body)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer stub-access-token-value")
    }

    func testRequestBodyDescriptionNeverEchoesBearer() async throws {
        let token = IdempotentRequestToken(operation: .playReport)
        let request = PlayRequestProbe.make(token: token)
        let described = String(reflecting: request)
        XCTAssertFalse(described.contains("stub-access-token-value"), described)
    }
}

/// 用于反射面断值的包装（模拟真实请求对象携带 Bearer 头的情形）。
enum PlayRequestProbe {
    static func make(token: IdempotentRequestToken) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: CovaEnvironment.apiBaseURL.appendingPathComponent("api/tracks/play"),
            headers: ["Authorization": "Bearer stub-access-token-value"],
            body: try? JSONEncoder().encode(["idempotencyKey": token.key.rawValue])
        )
    }
}
