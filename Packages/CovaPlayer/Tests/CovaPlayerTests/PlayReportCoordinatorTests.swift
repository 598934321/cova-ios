import CovaCore
import XCTest
@testable import CovaPlayer

/// 播放上报去重（D8 / api-contracts §5 / TD-19）。
///
/// 全部经桩提交器，**零真实网络**。
///
/// 本文件的来源断言按 **E2** 更正后的契约重写：旧用例钉的是 `source == "app-ios"`，
/// 而线上 `POST /api/tracks/play` 的 source allowlist 是闭合的、该值被 400 拒绝
/// （`播放来源无效`）—— 那条期望钉住的是一个真实缺陷（本客户端的播放历史从未落库），
/// 所以改写期望是正当的，不是删断言。幂等键那批断言（一次播放一个键、重试复用同键）
/// 一条未动。
final class PlayReportCoordinatorTests: XCTestCase {
    /// 服务端 source allowlist 在本文件里的**独立副本**（不从 `PlayReportSource` 推导，
    /// 否则「字节都在 allowlist 内」就退化成自证）。依据：2026-09-24 线上 400/200 实测。
    private static let acceptedSources: Set<String> = [
        "discover", "playlist", "project", "track_detail", "player",
    ]

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

    private func start(
        _ id: String, kind: PlaybackItem.Kind = .libraryTrack, source: PlayReportSource = .player
    ) async -> PlayReportOutcome {
        await subject.playbackStarted(itemID: id, kind: kind, session: authenticated, source: source)
    }

    /// 把桩收到的请求**编码成真实出站字节**后读 `source`：
    /// 断言的是线上看得见的字符串，不是内存里的枚举值。
    private func wireSources(_ requests: [PlayReportRequestDto]) throws -> [String] {
        try requests.map { request in
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
            return try XCTUnwrap((object as? [String: Any])?["source"] as? String)
        }
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
        XCTAssertEqual(sources, [.player], "语境未知时按唯一播放面归因（服务端 allowlist 内的值）")
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

    // MARK: - 环 4 · 第 5 批 F-C：提交在途与回前台补发重叠

    /// 缺陷 F-C（Minor，第 4 轮隔离复审实测）：`retryPending` 只看 `!submitted`、`deliver`
    /// 没有「在途」概念 —— 于是**第一次提交还挂在 `submit` 上**时经历「后台 → 前台」，
    /// 同一次实际播放会被写两次（同键）。键层面没破（服务端 `idempotentReplay` 兜得住），
    /// 破的是 api-contracts §5「一次实际播放 = 一个写请求」的写放大口径。
    ///
    /// 确定性口径：闸门只挡**第一次**提交（后续调用直通），因此「实现走偏」时用例是
    /// 变红而不是挂死；全程不需要让步/睡眠/竞态断言（D16⑤）。
    /// 与既有 `testForegroundBackgroundTransitionNeverReportsTwice` 的分工：那条只覆盖
    /// 「上一次提交已完成」的形态（名字过强），本条钉的是**重叠窗口**。
    func testRetryWhileSubmissionIsInFlightNeverSubmitsTwice() async {
        let gated = GatedPlayReportSubmitter()
        let subject = PlayReportCoordinator(submitter: gated)
        let session = authenticated
        _ = await subject.bindSession(session)
        let startTask = Task {
            await subject.playbackStarted(itemID: "track-1", kind: .libraryTrack, session: session)
        }
        let opened = await Signals.wait(target: 1, counter: gated.enteredSignal)
        XCTAssertTrue(opened, "前置：首次提交未进入在途，本用例无从验证重叠补发")

        let backgrounded = await subject.lifecyclePhaseChanged(.background)
        XCTAssertTrue(backgrounded.isEmpty, "转后台不产生新提交")
        let resumed = await subject.lifecyclePhaseChanged(.active)
        XCTAssertEqual(
            resumed,
            [.suppressed(itemID: "track-1", reason: .submissionInFlight)],
            "F-C：补发必须看见「同一集次已有一路在途」并让路"
        )

        await gated.release()
        let first = await startTask.value
        guard case .sent(_, let key) = first else { return XCTFail("在途那一路自己要把这一集次发掉：\(first)") }
        var calls = await gated.callCount
        XCTAssertEqual(calls, 1, "F-C：一次实际播放只有一个写请求")
        let concurrent = await gated.maxConcurrentInFlight
        XCTAssertEqual(concurrent, 1, "F-C：同一集次从未有两路并写在途")
        var keys = await gated.keys
        XCTAssertEqual(Set(keys).count, 1, "F-C：两次尝试即便发生也只带同一个键（键层面从未破）")
        XCTAssertEqual(keys, [key])
        var pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
        let reported = await subject.reportedCount()
        XCTAssertEqual(reported, 1)

        // 正向对照（TD-9）：在途标记只挡重叠，不得把后续集次也一起挡死。
        await subject.playbackEnded(itemID: "track-1")
        let second = await subject.playbackStarted(
            itemID: "track-1", kind: .libraryTrack, session: authenticated
        )
        guard case .sent(_, let newKey) = second else { return XCTFail("集次结束后再播是新集次：\(second)") }
        XCTAssertNotEqual(newKey, key)
        calls = await gated.callCount
        XCTAssertEqual(calls, 2, "F-C：下一集次照常提交")
        pending = await subject.pendingCount()
        XCTAssertEqual(pending, 0)
        keys = await gated.keys
        XCTAssertEqual(Set(keys).count, 2, "两集次两键，去重口径不退化")
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

    // MARK: - DTO 契约面（来源：服务端 allowlist 是闭合集，E2）

    /// 旧用例 `testRequestCarriesNoOverridePathForSource` 钉的是「source 恒为 app-ios 且
    /// 本层不给覆写入口」—— 那正好把 E2 写进了测试：`app-ios` 不在服务端 allowlist 内，
    /// 每次上报都被 400 拒掉。按更正后的契约改写：默认值必须是 allowlist 内的 `player`，
    /// 并且**语境要能从调用点传进来**（覆写入口是本次修复的一部分，不再是缺陷）。
    func testDefaultSourceEncodesOntoTheServerAllowlist() throws {
        let token = IdempotentRequestToken(operation: .playReport)
        let request = try PlayReportRequestDto(trackId: "t1", token: token)
        XCTAssertEqual(request.source, .player)
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"source\":\"player\""), json)
        XCTAssertTrue(json.contains(token.key.rawValue), json)
        XCTAssertFalse(json.contains("app-ios"), "旧常量不得再出现在任何请求体里：\(json)")
    }

    /// 协调器发出的**每一条**上报，其字节里的 source 都必须落在服务端闭合集内。
    func testEverySubmittedRequestCarriesAnAllowedSource() async throws {
        await bind(authenticated)
        _ = await start("track-1")
        _ = await start("track-2", source: .discover)
        _ = await start("track-3", source: .trackDetail)
        _ = await start("track-4", source: .playlist)
        _ = await start("track-5", source: .project)
        let requests = await submitter.requests
        XCTAssertEqual(requests.count, 5)
        let sources = try wireSources(requests)
        XCTAssertEqual(sources, ["player", "discover", "track_detail", "playlist", "project"])
        for source in sources {
            XCTAssertTrue(
                Self.acceptedSources.contains(source),
                "服务端只认这五个值，\(source) 会换回 400 播放来源无效"
            )
        }
    }

    /// 语境在调用点已知时就地归因（09 试听一条已入库的候选 ⇒ `project`）。
    func testCallSiteContextReachesTheWire() async throws {
        await bind(authenticated)
        _ = await start("track-1", source: .project)
        let requests = await submitter.requests
        XCTAssertEqual(try wireSources(requests), ["project"])
    }

    /// 集次的归因与幂等键**同生命周期**：失败后补发既复用同键也必须复用同来源。
    ///
    /// 服务端对同一 `idempotencyKey` 额外比对 `(trackId, source)`，补发时换来源会撞
    /// 409 `IDEMPOTENCY_CONFLICT`，等于把一次真实播放报成冲突。
    func testResubmissionReusesBothTheKeyAndTheEpisodeSource() async throws {
        await bind(authenticated)
        await submitter.script(StubPlayReportSubmitter.Script(failures: [0: .transport]))
        let first = await start("track-1", source: .discover)
        guard case .failed(_, let key, let reason) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(reason, .transport)

        let outcomes = await subject.retryPending()
        guard case .sent(_, let resentKey)? = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(resentKey, key, "补发复用同一幂等键（D8）")

        let requests = await submitter.requests
        XCTAssertEqual(requests.count, 2, "一次失败 + 一次补发")
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)), [key])
        XCTAssertEqual(try wireSources(requests), ["discover", "discover"], "补发不得改变这一集次的归因")
        XCTAssertEqual(Set(requests.map(\.trackId)), ["track-1"])
    }

    /// 同一集次误重入时带上了**不同**来源：首次取值生效，不得改写这一集次的归因。
    func testReentryWithADifferentSourceDoesNotOverwriteTheEpisode() async throws {
        await bind(authenticated)
        await submitter.script(StubPlayReportSubmitter.Script(failures: [0: .transport]))
        _ = await start("track-1", source: .discover)
        _ = await subject.playbackStarted(
            itemID: "track-1", kind: .libraryTrack, session: authenticated, source: .playlist
        )
        let requests = await submitter.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.idempotencyKey)).count, 1, "两次尝试仍是同一个键")
        XCTAssertEqual(try wireSources(requests), ["discover", "discover"])
    }

    /// 后台挂起 → 回前台补发：来源跟着集次走，不会退回默认值。
    func testBackgroundResendKeepsTheEpisodeSource() async throws {
        await bind(authenticated)
        _ = await subject.lifecyclePhaseChanged(.background)
        let queued = await start("track-1", source: .trackDetail)
        if case .queued = queued {} else { return XCTFail("后台应挂起：\(queued)") }
        let sent = await subject.lifecyclePhaseChanged(.active)
        XCTAssertEqual(sent.count, 1)
        let requests = await submitter.requests
        XCTAssertEqual(try wireSources(requests), ["track_detail"])
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
        // 出站字节里的 source 必须是服务端 allowlist 内的值（E2：`app-ios` 换回 400）。
        XCTAssertTrue(body.contains("\"source\":\"player\""), body)
        XCTAssertFalse(body.contains("app-ios"), body)
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
