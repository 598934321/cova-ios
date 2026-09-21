import AVFoundation
import MediaPlayer
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

    /// 缺陷 M11：门面声明的「teardown 后永久下线」旧实现**未落地**（`tornDown` 从不赋值、从不读取），
    /// teardown 后一次 `resume()` 就把全部远端 target 重挂回系统单例、并重新激活已 deactivate 的会话。
    func testTeardownPermanentlyRetiresFacadeWiring() async {
        let engine = ScriptedEngine()
        let system = StubAudioSessionSystem()
        let player = CovaPlayer(engine: engine, clock: FakeClock(), audioSystem: system)
        _ = await player.start(items: TestItems.makeMany(["a"]))
        XCTAssertTrue(player.isActivated)
        let configuredBefore = system.configurationCount
        let handlersBefore = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlersBefore, MPNowPlayingController.managedCommandNames.count, "前置：远端 target 已挂上")

        await player.teardown()
        let loadsBeforeTeardown = engine.loads.count
        let handlersAfterTeardown = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlersAfterTeardown, 0)
        XCTAssertTrue(player.isTornDown, "M11：下线标志必须是可观测的事实")

        // 逐个尝试复活（评审探针形态：resume + toggle + next + start + 显式激活）。
        await player.resume()
        _ = await player.toggle()
        _ = await player.next()
        _ = await player.start()
        _ = await player.start(items: TestItems.makeMany(["b"]))
        try? await player.activateForPlayback()
        await player.setSourcePreparer(StubSourcePreparer())

        let handlers = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlers, 0, "M11：teardown 后不得再把远端 target 挂回系统单例")
        let configured = system.configurationCount
        XCTAssertEqual(configured, configuredBefore, "M11：teardown 后不得重新激活已反激活的音频会话")
        XCTAssertFalse(player.isActivated)
        let preparerInjected = player.fetcher != nil
        XCTAssertFalse(preparerInjected, "M11：下线后注入本地化器不得改变任何装配")
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.queueCount, 0)
        let loads = engine.loads
        XCTAssertEqual(loads.count, loadsBeforeTeardown, "M11：下线后引擎不得再收到装载")
    }

    /// M11 的正向对照（TD-9）：未 teardown 时同一批入口都照常工作。
    func testFacadeWiringStaysLiveWithoutTeardown() async throws {
        let system = StubAudioSessionSystem()
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: system)
        _ = await player.start(items: TestItems.makeMany(["a"]))
        await player.resume()
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertFalse(player.isTornDown)
        let handlers = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlers, MPNowPlayingController.managedCommandNames.count)
        let configured = system.configurationCount
        XCTAssertEqual(configured, 1)
        await player.teardown()
    }

    // MARK: - 环 4 · 第 5 批 F-C / F-B：门面链上的事实

    /// F-C 的门面腿：`handleLifecycle(.active)` → `retryPending` 与起播时那一路**在途的**
    /// 提交重叠 → 旧实现写两次（同键）。这里跑的是真实接线（门面 → 协调器 → 上报器），
    /// 免得「协调器层修好了、门面那条链没接上」蒙过去。
    func testForegroundRetryDuringInFlightSubmissionNeverDoubleSubmits() async {
        let gated = GatedPlayReportSubmitter()
        let player = CovaPlayer(
            engine: ScriptedEngine(),
            clock: FakeClock(),
            reporter: PlayReportCoordinator(submitter: gated),
            audioSystem: StubAudioSessionSystem()
        )
        await player.bindSession(authenticated())
        let startTask = Task { await player.start(items: TestItems.makeMany(["a"])) }
        let opened = await Signals.wait(target: 1, counter: gated.enteredSignal)
        XCTAssertTrue(opened, "前置：起播的提交未进入在途")

        let backgrounded = await player.handleLifecycle(.background)
        XCTAssertTrue(backgrounded.isEmpty, "转后台不产生新提交")
        let resumed = await player.handleLifecycle(.active)
        XCTAssertEqual(
            resumed,
            [.suppressed(itemID: "a", reason: .submissionInFlight)],
            "F-C：回前台补发要让路给在途的那一路"
        )

        await gated.release()
        let outcome = await startTask.value
        guard case .advanced = outcome else { return XCTFail("起播本身要成功：\(outcome)") }
        let calls = await gated.callCount
        XCTAssertEqual(calls, 1, "F-C：一次实际播放 = 一个写请求")
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing, "让路不得打断播放本身")
        await player.teardown()
    }

    /// F-B 的门面腿：UI 唯一读取面必须能区分「空闲待播」与「播放器已永久释放」，
    /// 且释放后不再携带失败账（否则已死的播放器会被渲染成「失败已停止」）。
    func testSnapshotDistinguishesIdleFromReleased() async {
        let player = makePlayer()
        _ = await player.start(items: TestItems.makeMany(["a"]))
        var snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertFalse(snapshot.tornDown, "F-B：活着的播放器不得自称已释放")

        await player.teardown()
        snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertTrue(snapshot.tornDown, "F-B：teardown 之后快照必须自称已释放")
        XCTAssertFalse(snapshot.isFailureTerminal)
        XCTAssertEqual(snapshot.failureStreak, 0)
    }

    // MARK: - 环 4 · M4 / F-13：登出换号必须真的清私有音频

    private func makeFetchers(_ directory: TemporaryDirectory) -> PrivateAudioFetcher {
        try! PrivateAudioFetcher(
            transport: StubPrivateAudioTransport(),
            credentials: StubCredentialProvider(),
            baseDirectory: directory.url
        )
    }

    /// 失效之后磁盘上不得有残留（旧实现只丢上报 + 停引擎 + 清队列，盘上一个字节都没动）。
    func testLogoutLeavesNoPrivateAudioOnDisk() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let fetcher = makeFetchers(directory)
        let engine = ScriptedEngine()
        let player = makePlayer(engine: engine, sourcePreparer: fetcher)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("priv", source: .bearerRequired(privateURL()))])
        let ownerDirectory = PrivateAudioPath.ownerDirectory(
            base: directory.url,
            owner: PrincipalID(rawValue: "principal-1")
        )
        let cachedBefore = await fetcher.cachedFileCount()
        XCTAssertEqual(cachedBefore, 1, "前置条件：私有音频已落盘")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerDirectory.path))

        await player.bindSession(.unauthenticated)

        let cachedAfter = await fetcher.cachedFileCount()
        XCTAssertEqual(cachedAfter, 0, "登出之后磁盘上不得有残留")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ownerDirectory.path),
            "owner 目录本身也必须消失（不是只剩空目录）"
        )
        let loads = engine.loads
        XCTAssertEqual(loads.count, 1, "清理不得牵连已完成的装载")
    }

    /// 换号：上一个身份的私有音频必须整体消失，而新身份自己的缓存一个都不许被牵连。
    func testAccountSwitchDiscardsPreviousOwnerOnly() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let alice = makeFetchers(directory)
        let bob = try! PrivateAudioFetcher(
            transport: StubPrivateAudioTransport(),
            credentials: StubCredentialProvider(principal: "principal-2"),
            baseDirectory: directory.url
        )
        let player = makePlayer(sourcePreparer: alice)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("alice", source: .bearerRequired(privateURL()))])
        // Bob 先有一份自己的缓存（换号后必须原封不动）
        _ = await bob.localizedURL(for: PrivateAudioRequest(
            itemID: "bob",
            source: privateURL(),
            session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-2"), generation: .initial)
        ))
        let bobDirectory = PrivateAudioPath.ownerDirectory(
            base: directory.url,
            owner: PrincipalID(rawValue: "principal-2")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bobDirectory.path), "前置条件：Bob 的缓存已落盘")

        await player.bindSession(
            PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-2"), generation: SessionGeneration(value: 1))
        )

        let aliceFiles = await alice.cachedFileCount()
        XCTAssertEqual(aliceFiles, 1, "只剩 Bob 自己那一份")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: PrivateAudioPath.ownerDirectory(base: directory.url, owner: PrincipalID(rawValue: "principal-1")).path
            ),
            "换号后 Alice 的目录必须不存在"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bobDirectory.path), "换号不得波及新账号")
    }

    /// 同账号 generation 推进：回收**旧代次**孤儿，当前代次的缓存仍然属于本人 → 必须留下，
    /// 且 owner 目录本身不能被抹掉（那不是登出）。
    func testGenerationAdvancePurgesStaleAndKeepsCurrentGeneration() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let owner = PrincipalID(rawValue: "principal-1")
        let generations: [SessionGeneration] = [.initial, SessionGeneration(value: 1), SessionGeneration(value: 2)]
        var files: [URL] = []
        var fetchers: [PrivateAudioFetcher] = []
        for (index, generation) in generations.enumerated() {
            let fetcher = try! PrivateAudioFetcher(
                transport: StubPrivateAudioTransport(),
                credentials: StubCredentialProvider(generation: generation),
                baseDirectory: directory.url
            )
            _ = await fetcher.localizedURL(for: PrivateAudioRequest(
                itemID: "take\(index)",
                source: privateURL(),
                session: PlaybackSessionContext(owner: owner, generation: generation)
            ))
            files.append(try! PrivateAudioPath.fileURL(
                base: directory.url,
                owner: owner,
                itemID: "take\(index)",
                generation: generation
            ))
            fetchers.append(fetcher)
        }
        let player = makePlayer(sourcePreparer: fetchers[1])
        await player.bindSession(PlaybackSessionContext(owner: owner, generation: generations[1]))
        let cachedBefore = await fetchers[1].cachedFileCount()
        XCTAssertEqual(cachedBefore, 3, "前置条件：g0 / g1 / g2 各一份")

        // g1 → g2：只有 g0 与 g1 是旧代次；g2 那一份必须活着。
        await player.bindSession(PlaybackSessionContext(owner: owner, generation: generations[2]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path), "g0 是旧代次孤儿")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path), "g1 已成旧代次")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path), "当代（g2）缓存不得被牵连")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: PrivateAudioPath.ownerDirectory(base: directory.url, owner: owner).path
            ),
            "同账号推进不是登出：目录本身保留"
        )
        let cachedAfter = await fetchers[2].cachedFileCount()
        XCTAssertEqual(cachedAfter, 1)
    }

    /// TD-9 正向对照：同一身份重复绑定不得清掉可用缓存。
    func testRepeatedIdenticalBindDoesNotDiscardPrivateAudio() async {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let fetcher = makeFetchers(directory)
        let player = makePlayer(sourcePreparer: fetcher)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("priv", source: .bearerRequired(privateURL()))])
        await player.bindSession(authenticated())
        await player.bindSession(authenticated())
        let cached = await fetcher.cachedFileCount()
        XCTAssertEqual(cached, 1, "身份与代次都没变 → 不得清盘")
    }

    /// 清理必须走**协议面**（而不是「门面记得去够实现方的 purge」）：
    /// 这个准备器不是 `PrivateAudioFetching`，`player.fetcher == nil`，观测到的调用只能来自协议要求。
    func testSessionInvalidationCallsProtocolDiscardSurface() async {
        let preparer = RecordingPrivateAudioPreparer()
        let player = makePlayer(sourcePreparer: preparer)
        let noFetcher = player.fetcher == nil
        XCTAssertTrue(noFetcher, "前置条件：门面手里没有可用的 purge 面")
        let first = authenticated()
        let second = PlaybackSessionContext(
            owner: PrincipalID(rawValue: "principal-2"),
            generation: SessionGeneration(value: 1)
        )
        await player.bindSession(first)
        await player.bindSession(second)
        let discarded = await Signals.wait(target: 1, counter: preparer.discardedSignal)
        XCTAssertTrue(discarded, "会话失效必须调用 discardPrivateAudio(owner:)")
        let owners = await preparer.discardedOwners
        XCTAssertEqual(owners, [PrincipalID(rawValue: "principal-1")], "清理的对象必须是**上一个**身份")
    }

    /// teardown 走同一协议面，且以「身份不可知」= 全量清除的口径调用。
    func testTeardownCallsProtocolDiscardSurfaceWithUnknownOwner() async {
        let preparer = RecordingPrivateAudioPreparer()
        let player = makePlayer(sourcePreparer: preparer)
        await player.bindSession(authenticated())
        await player.teardown()
        let owners = await preparer.discardedOwners
        // 首次登录（unauthenticated → 已认证）不属于失效面：不得清盘。
        XCTAssertEqual(owners.count, 1, "只有 teardown 这一次清理")
        XCTAssertNil(owners[0] as PrincipalID?, "teardown 必须以 owner == nil 的口径全清")
    }

    // MARK: - 环 4 · M3：生产默认必须真的注册音频会话通知

    func testFacadeWiresAudioSessionNotificationsThroughProductionShape() async throws {
        let system = ObservingStubAudioSessionSystem()
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: system)
        // 生产形态：只传 system，不传 adapter —— 旧实现在这里根本不注册观测者。
        let wiredBefore = await player.audioSession.observesSystemNotifications
        XCTAssertTrue(wiredBefore, "M3：注入的 system 自己能观测通知时，门必须接上它")
        let registeredBefore = system.observedNotificationCount
        XCTAssertEqual(registeredBefore, 0, "未激活前不得注册（构造必须廉价）")

        _ = await player.start(items: TestItems.makeMany(["a"]))
        let registered = system.observedNotificationCount
        XCTAssertEqual(registered, AVAudioSessionAdapter.observedNotificationNames.count, "生产默认接线必须真的挂上通知")
        let observed = await player.audioSession.observedNotificationCount
        XCTAssertEqual(observed, registered)

        // 通知确实进到观测者（并会转发给门）。
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
        let forwarded = await Signals.wait(target: 1, counter: system.forwardedSignal)
        XCTAssertTrue(forwarded, "系统会话通知未到达门")

        await player.teardown()
        let remaining = system.observedNotificationCount
        XCTAssertEqual(remaining, 0, "teardown 之后不得残留观测者（本仓红线）")
        XCTAssertFalse(system.holdsGate)
    }

    // MARK: - 环 4 · 第 6 批 MAJ-2 / MAJ-8：第二个会写文件的准备器 + 出口真的被消费

    /// MAJ-2：`discardPrivateAudio(owner:)` 的**协议默认空实现已删除**（漏覆盖 = 编译不过）。
    /// 本用例守的是另一半：一个不是 `PrivateAudioFetching` 的、**真的往磁盘写字节**的准备器，
    /// 覆盖了自己的清理面之后，登出必须把文件真的清掉 —— 门面只调协议那一句，
    /// 没有任何「顺手去够实现方的 purge」可依赖。
    func testSecondFileWritingPreparerIsDiscardedThroughProtocolSurfaceOnLogout() async throws {
        let sandbox = TemporaryDirectory(subdirectory: "preparer-discard")
        defer { sandbox.remove() }
        let preparer = FileWritingPrivateAudioPreparer(
            directory: sandbox.url.appendingPathComponent("private-audio", isDirectory: true)
        )
        let player = makePlayer(sourcePreparer: preparer)
        await player.bindSession(authenticated())
        _ = await player.start(items: [TestItems.make("priv", source: .bearerRequired(privateURL()))])
        let prepared = await Signals.wait(target: 1, counter: preparer.preparedSignal)
        XCTAssertTrue(prepared, "前置条件：准备器真的写过文件")
        let written = await preparer.survivingFiles
        XCTAssertEqual(written.count, 1, "前置条件：登出前文件确实在沙盒里")

        await player.bindSession(.unauthenticated)

        let called = await Signals.wait(target: 1, counter: preparer.discardedSignal)
        XCTAssertTrue(called, "MAJ-2：登出必须经协议面调用清理（而不是靠 fetcher 支路）")
        let survivors = await preparer.survivingFiles
        XCTAssertTrue(survivors.isEmpty, "MAJ-2：登出之后磁盘上不得有残留：\(survivors.map(\.lastPathComponent))")
        let owners = await preparer.discardedOwners
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners.first ?? nil, PrincipalID(rawValue: "principal-1"), "必须带着**上一个身份**去清")
        await player.teardown()
    }

    /// MAJ-8：`assetOrigin` 不再是死字段 —— 未注入引擎时它就是引擎的出口判定基准。
    func testAssetOriginIsConsumedByTheDefaultEngine() {
        let production = CovaPlayer()
        let origin = production.assetOrigin
        let engine = production.engine as? AVPlayerEngine
        let wired = engine?.currentEgressOrigin
        XCTAssertEqual(origin, CovaEnvironment.apiBaseURL)
        XCTAssertEqual(wired, origin, "MAJ-8：默认装配必须把出口交给引擎")

        // 注入别的 origin：引擎判定基准跟着走（字段被消费的正面证据）。
        let custom = CovaPlayer(assetOrigin: URL(string: "https://cdn.covalink.example")!)
        let customOrigin = custom.assetOrigin
        let customEngine = custom.engine as? AVPlayerEngine
        XCTAssertEqual(customEngine?.currentEgressOrigin, customOrigin)
        // 而判定本身仍是 fail-closed：非生产出口一律拒绝（见 `AVPlayerEngineTests` 的判定表）。
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(customOrigin), "前置：这条出口不合法")

        // 显式注入引擎时门面不做二次猜测（桩引擎没有出口可言）。
        let scripted = CovaPlayer(assetOrigin: CovaEnvironment.apiBaseURL, engine: ScriptedEngine())
        let scriptedEngine = scripted.engine as? AVPlayerEngine
        XCTAssertNil(scriptedEngine, "注入的引擎不得被换掉")
    }

    /// min-6：同进程装配第二个门面时，第一个门面必须**问得出**自己已经不是共享命令面的持有者。
    ///
    /// 复审的形态：`registerCommands()` 每次 `removeTarget(nil)`、`setCommandsEnabled` 与
    /// `teardown` 都作用于全部 11 条命令，与所有者无关，而 `registeredHandlerCount`
    /// 是自我申报。本层能收敛的是「让失守可见」（票据），收敛不了的是「按所有者隔离写入」
    /// （MediaPlayer 不给这个能力）⇒ TD-43 记边界与影响面。当前生产装配只有一个门面。
    func testSecondFacadeRegistrationTakesOverSharedCommandSurface() async throws {
        let first = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: StubAudioSessionSystem())
        let second = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: StubAudioSessionSystem())
        XCTAssertFalse(first.ownsSharedCommandSurface, "未注册不得自称持有共享面")

        try await first.activateForPlayback()
        XCTAssertTrue(first.ownsSharedCommandSurface)
        XCTAssertFalse(second.ownsSharedCommandSurface)

        try await second.activateForPlayback()
        XCTAssertFalse(first.ownsSharedCommandSurface, "min-6：第二个门面接手必须可见（旧实现里这是静默的）")
        XCTAssertTrue(second.ownsSharedCommandSurface)
        // 自我申报的局限一并钉在明面上：被顶掉者仍然自报满额 target（TD-43 的那一半）。
        let selfReport = first.nowPlaying.registeredHandlerCount
        XCTAssertEqual(selfReport, MPNowPlayingController.managedCommandNames.count)
        await second.teardown()
        await first.teardown()
    }

    /// 生产默认的 `audioSystem` 类型（`AVAudioSessionAdapter`）本身就是通知源 —— 上条用例的
    /// 「生产形态」与真实类型必须是同一判据，否则「桩过了、真的没接」仍然可能。
    func testProductionDefaultAudioSystemIsItsOwnNotificationCenterSource() {
        let adapter = AVAudioSessionAdapter()
        let asSystem: any AudioSessionSystemInterface = adapter
        let observes = (asSystem as? any AudioSessionNotificationObserving) != nil
        XCTAssertTrue(observes, "M3：生产默认注入的系统接口必须自带通知观测能力")
        let unregistered = adapter.observedNotificationCount
        XCTAssertEqual(unregistered, 0)
        let stub: any AudioSessionSystemInterface = StubAudioSessionSystem()
        let stubObserves = (stub as? any AudioSessionNotificationObserving) != nil
        XCTAssertFalse(stubObserves, "不具备观测能力的桩不得被误判为已接线")
    }

    // MARK: - 环 4 · 第 7 批 MAJ-5 / MAJ-7：系统面生命周期

    /// MAJ-5（门面腿）：`ensureActivated()` 旧实现是 `try? await audioSession.start()` ——
    /// 吞掉错误之后仍然 `activated = true`，于是「会话根本没起来」在门面外部完全不可观测。
    /// 现在：失败留痕、状态面不谎报、而系统面注册（远端命令）仍然完成。
    func testFacadeDoesNotSwallowAudioSessionActivationFailure() async {
        let system = StubAudioSessionSystem(failsConfigure: true)
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: system)
        _ = await player.start(items: TestItems.makeMany(["a"]))

        let activated = player.isActivated
        XCTAssertFalse(activated, "MAJ-5：激活失败的门面不得自称已激活")
        let failure = player.audioSessionActivationFailure as? PlayerError
        XCTAssertEqual(failure, .writeFailed(-10868), "错误必须原样留痕（不吞、不改写、不丢码）")
        let registered = player.isRemoteCommandSurfaceRegistered
        XCTAssertTrue(registered, "MAJ-5：会话起不来也不该掩掉系统面注册")
        let handlers = player.nowPlaying.registeredHandlerCount
        XCTAssertEqual(handlers, MPNowPlayingController.managedCommandNames.count, "前置条件：target 确实挂上了")
        // 播放意图本身仍然服务（用户按了播放就该播；失败以状态面如实呈现，而不是静默改判）。
        let snapshot = await player.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing, "会话激活失败不得被伪装成播放失败")
        // 重试语义：每次传输动作都会再试一次激活（`started` 没置位 → 门会重跑 configure）。
        let configuredBefore = system.configurationCount
        await player.resume()
        let configuredAfter = system.configurationCount
        XCTAssertEqual(configuredAfter, configuredBefore + 1, "失败后下一次用户意图必须重试激活")
        await player.teardown()
        let still = player.audioSessionActivationFailure as? PlayerError
        XCTAssertEqual(still, .writeFailed(-10868), "teardown 不得抹掉失败留痕（那是事实，不是待清标志位）")
    }

    /// MAJ-5：显式激活面（throwing 路径）同样不得因为「激活失败」而丢掉系统面注册。
    func testExplicitActivationThrowsButStillRegistersSystemSurface() async {
        let system = StubAudioSessionSystem(failsConfigure: true)
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: system)
        do {
            try await player.activateForPlayback()
            XCTFail("前置条件：桩系统被配成激活必然失败")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .writeFailed(-10868), "门面必须把错误如实抛出，而不是吞掉")
        } catch {
            XCTFail("错误类型不得被门面改写：\(type(of: error))")
        }
        let registered = player.isRemoteCommandSurfaceRegistered
        XCTAssertTrue(registered)
        let activated = player.isActivated
        XCTAssertFalse(activated)
        await player.teardown()
    }

    /// 建门面 → 激活 → 起播 → （可选 `teardown()`）→ **在同一个作用域末尾把它放掉**。
    ///
    /// 为什么必须有这个 helper：`let live` 这类局部常量会把对象生命周期续到**所在作用域末尾**，
    /// 所以在测试方法体里写 `player = nil` 压根不会触发析构（那是 MAJ-7 判据最容易写空的地方）。
    /// 返回值是「放掉之前」读到的系统面事实，用作前置条件自证 —— 少了它，下面的断言就可能是空断言。
    private func runFacadeUntilDeallocation(
        itemID: String,
        explicitTeardown: Bool = false
    ) async throws -> (
        commandsEnabled: Bool,
        title: String?,
        playbackState: MPNowPlayingPlaybackState,
        heldTargets: Int
    ) {
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: StubAudioSessionSystem())
        try await player.activateForPlayback()
        _ = await player.start(items: TestItems.makeMany([itemID]))
        if explicitTeardown {
            await player.teardown()
        }
        return (
            MPNowPlayingController.sharedCenter().playCommand.isEnabled,
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
            MPNowPlayingInfoCenter.default().playbackState,
            player.nowPlaying.registeredHandlerCount
        )
        // 此处作用域结束：`player` 与隐式持有的引用全部释放 → deinit 必须退系统面。
    }

    /// MAJ-7：**没有 teardown 就释放**（App 里门面的真实终态之一）之后，系统面必须退干净：
    /// 远端命令 `isEnabled` 归位、target 摘净、`MPNowPlayingInfoCenter` 不再显示死门面的曲目。
    ///
    /// 旧 `deinit` 只做 `engine.stopAndRelease()`，复审实测析构后 `playCommand.isEnabled == true`、
    /// Now Playing 仍是死门面的曲名、`playbackState == playing`。
    func testDeinitWithoutTeardownRetiresRemoteCommandsAndNowPlaying() async throws {
        let center = MPNowPlayingController.sharedCenter()
        let infoCenter = MPNowPlayingInfoCenter.default()
        let before = try await runFacadeUntilDeallocation(itemID: "dying-facade")

        // 前置条件：系统面确实被这个（已死的）门面占着。
        XCTAssertTrue(before.commandsEnabled, "前置条件：命令已启用")
        XCTAssertEqual(before.title, "曲目-dying-facade", "前置条件：锁屏显示的是本门面的曲目")
        XCTAssertEqual(before.playbackState, .playing, "前置条件：系统读数仍是「正在播放」")
        XCTAssertEqual(
            before.heldTargets,
            MPNowPlayingController.managedCommandNames.count,
            "前置条件：target 确实挂上了"
        )

        XCTAssertFalse(center.playCommand.isEnabled, "MAJ-7：析构后不得继续接远端命令")
        XCTAssertFalse(center.pauseCommand.isEnabled)
        XCTAssertFalse(center.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(infoCenter.nowPlayingInfo?.isEmpty ?? true, "MAJ-7：析构后锁屏不得继续显示死门面的曲目")
        XCTAssertEqual(infoCenter.playbackState, .stopped, "MAJ-7：析构后不得继续自称在播放")
    }

    /// MAJ-7 的对照腿（TD-9）：常规 `teardown()` 路径同样收敛到「命令位关闭 + target 摘净」，
    /// 之后的析构兜底是幂等的（不得把已关闭的命令位再打开、也不得重复扣账）。
    func testTeardownThenDeinitIsIdempotentOnSharedSurfaces() async throws {
        let center = MPNowPlayingController.sharedCenter()
        let before = try await runFacadeUntilDeallocation(itemID: "tidy-facade", explicitTeardown: true)
        XCTAssertFalse(before.commandsEnabled, "前置条件：teardown 已关闭命令位")
        XCTAssertEqual(before.heldTargets, 0, "前置条件：teardown 已摘净 target 账")

        XCTAssertFalse(center.playCommand.isEnabled, "析构兜底不得把已关闭的命令位再打开")
        XCTAssertTrue(MPNowPlayingInfoCenter.default().nowPlayingInfo?.isEmpty ?? true)
    }

    /// 用**生产默认**音频会话（真实 `AVAudioSessionAdapter`）跑一次起播，然后在本作用域末尾释放门面。
    ///
    /// 「活着时的净额」必须在**作用域内**读：helper 一返回，门面就已经析构了（那是本条的判据本体）。
    private func runFacadeWithProductionAudioSession(itemID: String) async -> (attached: Bool, netWhileAlive: Int) {
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock())
        _ = await player.start(items: TestItems.makeMany([itemID]))
        let attached = await player.audioSession.isObservingSystemNotifications
        return (attached, AVAudioSessionAdapter.netLiveObserverTokens)
    }

    /// MAJ-7 的分层腿：控制器**比门面活得久**时（真实装配里协调器就强持着它），
    /// 退系统面只能由门面的 `deinit` 那一句完成 —— 控制器自己的 deinit 兜底此时根本没跑。
    ///
    /// 为什么需要单独一条：只测「析构后系统面干净」时，两层兜底互为替身，删掉门面那一句
    /// 仍然全绿（变异自证 G3-M7a 的第一版就逃过了）。把控制器留在测试手里，
    /// 替身就消失了。
    func testDeinitRetiresSharedSurfacesEvenWhenControllerOutlivesFacade() async throws {
        let center = MPNowPlayingController.sharedCenter()
        let infoCenter = MPNowPlayingInfoCenter.default()
        let survivor = try await runFacadeAndKeepControllerAlive(itemID: "orphaned-controller")

        XCTAssertFalse(center.playCommand.isEnabled, "MAJ-7：门面析构即须关闭命令位（控制器活着不算理由）")
        XCTAssertTrue(infoCenter.nowPlayingInfo?.isEmpty ?? true, "MAJ-7：死门面的曲名不得留在锁屏上")
        XCTAssertEqual(infoCenter.playbackState, .stopped)
        XCTAssertEqual(
            survivor.observedTeardownCount,
            1,
            "退出动作确实发生在这个仍活着的控制器身上（不是它自己稍后的 deinit）"
        )
        XCTAssertEqual(survivor.registeredHandlerCount, 0, "MAJ-7：target 账必须随退出清零")
    }

    /// 建门面 → 激活 → 起播 → 返回**控制器本体**（于是控制器比门面活得久）。
    private func runFacadeAndKeepControllerAlive(itemID: String) async throws -> MPNowPlayingController {
        let player = CovaPlayer(engine: ScriptedEngine(), clock: FakeClock(), audioSystem: StubAudioSessionSystem())
        try await player.activateForPlayback()
        _ = await player.start(items: TestItems.makeMany([itemID]))
        XCTAssertTrue(
            MPNowPlayingController.sharedCenter().playCommand.isEnabled,
            "前置条件：活着的门面确实占着共享命令面"
        )
        return player.nowPlaying
    }

    /// MAJ-7：门面释放后，观测者账必须回到原水位 —— 走的是 `AVAudioSessionAdapter.deinit`
    /// 兜底（门是 actor，`deinit` 里不能 `await audioSession.stop()`）。
    /// 这条同时证明「自引用强环已断」：环没断时适配器永不释放，净额会永久停在 +2。
    func testFacadeDeallocationLeavesNoLiveSessionObservers() async throws {
        let baseline = AVAudioSessionAdapter.netLiveObserverTokens
        let run = await runFacadeWithProductionAudioSession(itemID: "observer-leak")
        XCTAssertTrue(run.attached, "前置条件：门已挂上观测者（MAJ-5 —— 会话激活成不成都与此无关）")
        XCTAssertEqual(
            run.netWhileAlive,
            baseline + AVAudioSessionAdapter.observedNotificationNames.count,
            "前置条件：净额随注册上升（门面还活着，此时 +2 是事实而不是泄漏）"
        )

        let net = AVAudioSessionAdapter.netLiveObserverTokens
        XCTAssertEqual(net, baseline, "MAJ-7：门面释放之后进程内不得残留观测者 token")
    }
}
