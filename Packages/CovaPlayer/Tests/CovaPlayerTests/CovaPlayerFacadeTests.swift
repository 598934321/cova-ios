import XCTest
import CovaCore
import Foundation
@testable import CovaPlayer

/// 门面装配（G3-e 交付面）：把「可测决策层」与「iOS 薄适配器」串成 M1 可直接调用的链。
///
/// 全部注入桩件：引擎 = `ScriptedEngine`（零 AVPlayer 装载）、音频会话 = `StubAudioSessionSystem`
/// （零 `AVAudioSession.sharedInstance()`）、时钟 = `FakeClock`、上报 = 默认
/// `UnavailablePlayReporter`（**零网络**：NEEDS-2 未解锁期间显式挂起而非静默丢包）。
@MainActor
final class CovaPlayerFacadeTests: XCTestCase {
    private static let privateSourcePath = "/api/media/private/priv.m4a?sig=aa"

    private func privateURL() -> AudioURL {
        try! AudioURL(https: URL(string: "https://covalink.cn\(Self.privateSourcePath)")!)
    }

    private func makePlayer(
        engine: ScriptedEngine = ScriptedEngine(),
        sourcePreparer: (any PlaybackSourcePreparing)? = nil
    ) -> CovaPlayer {
        CovaPlayer(
            engine: engine,
            clock: FakeClock(),
            audioSystem: StubAudioSessionSystem(),
            sourcePreparer: sourcePreparer
        )
    }

    private func authenticated() -> PlaybackSessionContext {
        PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"), generation: .initial)
    }

    // MARK: - 出口与激活

    func testAssetOriginStaysOnProductionExit() {
        let player = makePlayer()
        XCTAssertEqual(player.assetOrigin, CovaEnvironment.apiBaseURL)
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(player.assetOrigin))
        XCTAssertFalse(player.isActivated)
    }

    func testActivateIsIdempotentAndTeardownRemovesEveryRemoteTarget() async throws {
        let system = StubAudioSessionSystem()
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: system)
        try await player.activateForPlayback()
        try await player.activateForPlayback()
        let configurations = system.configurationCount
        XCTAssertEqual(configurations, 1, "重复激活不得重复设置系统会话")
        XCTAssertTrue(player.isActivated)
        let handlers = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlers, MPNowPlayingController.managedCommandNames.count)
        await player.teardown()
        let remaining = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(remaining, 0, "teardown 必须移除全部远端 target（系统不持有 target）")
        let deactivations = system.deactivationCount
        XCTAssertEqual(deactivations, 1)
        await player.teardown()
        let secondDeactivation = system.deactivationCount
        XCTAssertEqual(secondDeactivation, 1, "重复 teardown 不得反配置第二次")
    }

    func testStartSelfWiresWithoutExplicitActivation() async {
        let player = makePlayer()
        let outcome = await player.start(items: TestItems.makeMany(["a"]))
        guard case .advanced(let index, let item, _) = outcome else { return XCTFail("应进入播放：\(outcome)") }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(item.id, "a")
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertTrue(player.isActivated)
    }

    // MARK: - 传输与队列表面的委托（M1 调用面）

    func testTransportSurfaceDelegatesToCoordinator() async {
        let engine = ScriptedEngine()
        let player = CovaPlayer(engine: engine, clock: FakeClock(), audioSystem: StubAudioSessionSystem())
        _ = await player.start(items: TestItems.makeMany(["a", "b", "c"]))

        await player.pause()
        var snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
        await player.resume()
        snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing)
        let toggled = await player.toggle()
        XCTAssertEqual(toggled, .paused)
        let resumed = await player.toggle()
        XCTAssertEqual(resumed, .playing)

        let next = await player.next()
        guard case .advanced(let nextIndex, let nextItem, _) = next else { return XCTFail("next 必须前进：\(next)") }
        XCTAssertEqual(nextIndex, 1)
        XCTAssertEqual(nextItem.id, "b")
        let previous = await player.previous()
        guard case .advanced(let previousIndex, _, _) = previous else { return XCTFail("previous 必须后退：\(previous)") }
        XCTAssertEqual(previousIndex, 0)

        let seeked = await player.seekTo(30)
        guard case .applied(let position, let clamp, let then) = seeked else { return XCTFail("seekTo 必须生效：\(seeked)") }
        XCTAssertEqual(position, 30)
        XCTAssertEqual(clamp, .none)
        XCTAssertNil(then)
        let stepped = await player.seekBySeconds(-100)
        guard case .applied(let clamped, let lowerClamp, _) = stepped else { return XCTFail("±15s 必须钳制：\(stepped)") }
        XCTAssertEqual(clamped, 0)
        XCTAssertEqual(lowerClamp, .lowerBound)
        let forward = await player.seekBySeconds(15)
        guard case .applied(let moved, let none, _) = forward else { return XCTFail("快进必须生效：\(forward)") }
        XCTAssertEqual(moved, 15)
        XCTAssertEqual(none, .none)

        let looped = await player.setLoopMode(.one)
        XCTAssertEqual(looped, .one)
        let cycled = await player.cycleLoopMode()
        XCTAssertEqual(cycled, .off)
        let snapshotLoop = await player.currentSnapshot()
        XCTAssertEqual(snapshotLoop.loopMode, .off)
    }

    func testQueueSurfaceDelegatesToCoordinator() async {
        let player = makePlayer()
        _ = await player.start(items: TestItems.makeMany(["a", "b", "c"]))

        let appended = await player.appendToQueue(TestItems.make("d"))
        guard case .applied(.appended(let at)) = appended else { return XCTFail("追加必须成功：\(appended)") }
        XCTAssertEqual(at, 3)

        let inserted = await player.insertNext(TestItems.make("e"))
        guard case .applied(.insertedNext(let insertedAt)) = inserted else { return XCTFail("插队必须成功：\(inserted)") }
        XCTAssertEqual(insertedAt, 1)

        let moved = await player.reorder(from: 0, to: 2)
        guard case .applied(.moved(from: let from, to: let to, current: let current)) = moved else {
            return XCTFail("拖拽排序必须成功：\(moved)")
        }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(to, 2)
        XCTAssertEqual(current, 2, "当前曲目必须跟随自身移动")

        let removedByID = await player.remove(itemID: "e")
        guard case .applied = removedByID else { return XCTFail("按 id 移除应成功：\(removedByID)") }
        let removedByIndex = await player.remove(at: 0)
        guard case .applied = removedByIndex else { return XCTFail("按索引移除应成功：\(removedByIndex)") }
        let unknown = await player.remove(itemID: "zzz")
        XCTAssertEqual(unknown, .rejected(.unknownItem))
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.queueCount, 3)
        XCTAssertEqual(snapshot.state, .playing, "移除当前项后必须继续播同位置的新项")
    }

    func testRemoteCommandEntrypointRoutesThroughRouter() async {
        let player = makePlayer()
        let emptyPause = await player.handleRemoteCommand(.pause)
        XCTAssertEqual(emptyPause, .noSuchContent, "无当前项时锁屏命令必须报无内容")
        _ = await player.start(items: TestItems.makeMany(["a"]))
        let paused = await player.handleRemoteCommand(.pause)
        XCTAssertEqual(paused, .success)
        let played = await player.handleRemoteCommand(.play)
        XCTAssertEqual(played, .success)
        let skipped = await player.handleRemoteCommand(.skipForward(seconds: 15))
        XCTAssertEqual(skipped, .success)
        let backwards = await player.handleRemoteCommand(.skipBackward(seconds: 15))
        XCTAssertEqual(backwards, .success)
        let located = await player.handleRemoteCommand(.seek(to: 5))
        XCTAssertEqual(located, .success)
        let positioned = await player.currentSnapshot()
        XCTAssertEqual(positioned.position, 5)
        let nextOnSingleItem = await player.handleRemoteCommand(.nextTrack)
        XCTAssertEqual(nextOnSingleItem, .noSuchContent, ".off 模式末项无邻居 → 不得假成功")
        let badSeek = await player.handleRemoteCommand(.seek(to: .nan))
        XCTAssertEqual(badSeek, .failure)
        let rate = await player.handleRemoteCommand(.changeRate(to: 1))
        XCTAssertEqual(rate, .success)
        let availability = await player.commandRouter.isAvailable(.togglePlayPause)
        XCTAssertTrue(availability)
    }

    // MARK: - D7：私有音频必须先本地化（门面无绕过入口）

    func testBearerItemWithoutPreparerNeverReachesEngine() async {
        let engine = ScriptedEngine()
        let player = makePlayer(engine: engine)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("priv", source: .bearerRequired(privateURL()))])
        let loads = engine.loads
        XCTAssertTrue(loads.isEmpty, "未注入本地化器时，绝不把 Bearer 地址交给播放器")
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.lastFailure?.kind, .localizationRequired)
    }

    func testInjectedPreparerLocalizesBearerBeforeEngineLoad() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = ScriptedEngine()
        let fetcher = try! PrivateAudioFetcher(
            transport: StubPrivateAudioTransport(),
            credentials: StubCredentialProvider(),
            baseDirectory: directory.url
        )
        let player = makePlayer(engine: engine, sourcePreparer: fetcher)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("priv", source: .bearerRequired(privateURL()))])

        let loads = engine.loads
        XCTAssertEqual(loads.count, 1)
        guard case .localized(let url)? = loads.first?.audioSource else {
            return XCTFail("交给引擎的必须是本地化后的 file 地址")
        }
        XCTAssertEqual(url.scheme, .file)
        XCTAssertNil(url.value.query)
        let described = String(describing: loads.first)
        // 签名串住在 query/路径里：`AudioURL` 的反射面必须把它擦掉（host 按设计可见，不是秘密）。
        XCTAssertFalse(described.contains("sig=aa"), "签名查询串不得随条目回显")
        XCTAssertFalse(described.contains(Self.privateSourcePath), "私有音频的带签名地址整体不得回显")
        let cached = await fetcher.cachedFileCount()
        XCTAssertEqual(cached, 1)

        await player.teardown()
        let afterTeardown = await fetcher.cachedFileCount()
        XCTAssertEqual(afterTeardown, 0, "teardown 必须清空私有音频缓存（D8）")
    }

    func testLatePreparerInjectionIsTrackedForPurge() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let fetcher = try! PrivateAudioFetcher(
            transport: StubPrivateAudioTransport(),
            credentials: StubCredentialProvider(),
            baseDirectory: directory.url
        )
        let player = makePlayer()
        let before = player.fetcher == nil
        XCTAssertTrue(before, "未注入时门面不得虚构本地化能力")
        await player.setSourcePreparer(fetcher)
        let exposed = player.fetcher != nil
        XCTAssertTrue(exposed, "注入的本地化器必须被门面追踪，否则 teardown 无法清理")
    }

    // MARK: - 上报与会话（D8 / D10 / TD-19）

    func testUnavailableReporterKeepsEpisodePendingInsteadOfSilentlyDropping() async {
        let player = makePlayer()
        await player.bindSession(authenticated())
        _ = await player.start(items: TestItems.makeMany(["a"]))
        let pending = await player.reporter.pendingCount()
        XCTAssertEqual(pending, 1, "NEEDS-2 未解锁：显式挂起，不静默丢包")
        let reported = await player.reporter.reportedCount()
        XCTAssertEqual(reported, 0)
        let backgrounded = await player.handleLifecycle(.background)
        XCTAssertTrue(backgrounded.isEmpty, "后台不发起新提交")
        let resumed = await player.handleLifecycle(.active)
        XCTAssertEqual(resumed.count, 1)
        guard case .failed(_, let key, let reason)? = resumed.first else {
            return XCTFail("补发必须返回失败结果：\(resumed)")
        }
        XCTAssertEqual(reason, .transport)
        let stillSameKey = await player.reporter.activeEpisodeKey()
        XCTAssertEqual(stillSameKey, key, "补发复用同一幂等键（TD-19）")
    }

    func testPrivateCandidatesAreNeverReportedThroughFacade() async {
        let player = makePlayer()
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("cand", kind: .privateCandidate)])
        let pending = await player.reporter.pendingCount()
        XCTAssertEqual(pending, 0, "生成候选音频不上报（design §8）")
        let state = await player.currentSnapshot()
        XCTAssertEqual(state.state, .playing, "不上报不影响试听")
    }

    func testBindSessionDrivesCoordinatorInvalidation() async {
        let player = makePlayer()
        await player.bindSession(authenticated())
        _ = await player.start(items: TestItems.makeMany(["a"]))
        let generation = await player.coordinator.sessionGeneration()
        XCTAssertEqual(generation, .initial)
        await player.bindSession(
            PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-2"), generation: SessionGeneration(value: 1))
        )
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.queueCount, 0, "换号必须清播放队列")
        XCTAssertTrue(snapshot.state == .stopped || snapshot.state == .idle)
        let pending = await player.reporter.pendingCount()
        XCTAssertEqual(pending, 0, "换号必须丢弃未决上报")
    }

    // MARK: - 释放

    func testTeardownRejectsFurtherPlaybackRequests() async {
        let engine = ScriptedEngine()
        let player = makePlayer(engine: engine)
        _ = await player.start(items: TestItems.makeMany(["a"]))
        await player.teardown()
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        let outcome = await player.start(items: TestItems.makeMany(["b"]))
        guard case .rejected(let rejection) = outcome else { return XCTFail("已释放后不得再装载：\(outcome)") }
        XCTAssertEqual(rejection, .tornDown)
        // 锁屏/控制中心侧必须读到「未就绪」，而不是假成功或无内容。
        let status = NowPlayingStatusMapping.status(for: outcome)
        XCTAssertEqual(status, .notReadyToPlay)
        await player.resume()
        let revived = await player.currentSnapshot()
        XCTAssertEqual(revived.state, .idle, "teardown 后 resume 不得复活播放")
        let releases = engine.releaseCount
        XCTAssertGreaterThan(releases, 0)
    }
}
