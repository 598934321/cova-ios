import MediaPlayer
import XCTest
@testable import CovaPlayer

/// 锁屏 / 耳机远端命令：决策路径（协议桩）+ 真实 `MPRemoteCommandCenter` 注册注销冒烟。
final class NowPlayingCommandTests: XCTestCase {
    private var engine: ScriptedEngine!
    private var clock: FakeClock!
    private var coordinator: PlaybackCoordinator!
    private var router: NowPlayingCommandRouter!

    override func setUp() {
        super.setUp()
        engine = ScriptedEngine()
        clock = FakeClock()
        coordinator = PlaybackCoordinator(engine: engine, clock: clock)
        router = NowPlayingCommandRouter(coordinator: coordinator)
    }

    override func tearDown() {
        engine = nil
        clock = nil
        coordinator = nil
        router = nil
        super.tearDown()
    }

    private func handle(_ command: NowPlayingCommand) async -> NowPlayingStatus {
        await router.handle(command)
    }

    // MARK: - 状态码映射（纯函数）

    func testStatusMappingForAdvanceOutcomes() {
        let item = TestItems.make("a")
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.advanced(to: 1, item: item, wrapped: false)), .success)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.repeated(at: 0, item: item)), .success)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.stopped), .success, "请求被受理，状态转 stopped")
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.held), .noSuchContent, "边界无邻居不得假成功")
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.rejected(.emptyQueue)), .noSuchContent)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: AdvanceOutcome.rejected(.noCurrentItem)), .notReadyToPlay)
    }

    func testStatusMappingForSeekOutcomes() {
        XCTAssertEqual(NowPlayingStatusMapping.status(for: SeekOutcome.applied(position: 3, clamped: .none, then: nil)), .success)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: SeekOutcome.rejected(.noCurrentItem)), .noSuchContent)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: SeekOutcome.rejected(.nonFiniteTarget)), .failure)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: SeekOutcome.rejected(.tornDown)), .notReadyToPlay)
    }

    func testStatusMappingForStateAndItemPresence() {
        let item = TestItems.make("a")
        XCTAssertEqual(NowPlayingStatusMapping.status(for: .playing, hasCurrentItem: true), .success)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: .idle, hasCurrentItem: true), .notReadyToPlay)
        XCTAssertEqual(NowPlayingStatusMapping.status(for: .playing, hasCurrentItem: false), .noSuchContent)
        XCTAssertNotNil(item)
    }

    func testLegalTimeTargetRules() {
        XCTAssertTrue(NowPlayingStatusMapping.isLegalTimeTarget(nil))
        XCTAssertTrue(NowPlayingStatusMapping.isLegalTimeTarget(0))
        XCTAssertTrue(NowPlayingStatusMapping.isLegalTimeTarget(12.5))
        XCTAssertFalse(NowPlayingStatusMapping.isLegalTimeTarget(-1))
        XCTAssertFalse(NowPlayingStatusMapping.isLegalTimeTarget(Double.nan))
        XCTAssertFalse(NowPlayingStatusMapping.isLegalTimeTarget(Double.infinity))
    }

    func testCommandTimeTargetExposure() {
        XCTAssertEqual(NowPlayingCommand.seek(to: 12).timeTarget, 12)
        XCTAssertNil(NowPlayingCommand.play.timeTarget)
        XCTAssertNil(NowPlayingCommand.skipForward(seconds: 15).timeTarget)
    }

    // MARK: - 命令路由（空队列 / 有曲目 / 边界）

    func testAllCommandsReportNoSuchContentOnEmptyQueue() async {
        let commands: [NowPlayingCommand] = [
            .play, .pause, .togglePlayPause, .nextTrack, .previousTrack,
            .seek(to: 10), .skipForward(seconds: 15), .skipBackward(seconds: 15), .changeRate(to: 1.5),
        ]
        for command in commands {
            let status = await handle(command)
            XCTAssertEqual(status, .noSuchContent, "\(command)")
        }
        XCTAssertEqual(engine.callCount, 0, "无内容时不得触碰引擎")
    }

    func testUnboundRouterReportsNotReadyToPlay() async {
        let detached = NowPlayingCommandRouter(coordinator: nil)
        let status = await detached.handle(.play)
        XCTAssertEqual(status, .notReadyToPlay)
        let available = await detached.isAvailable(.play)
        XCTAssertFalse(available)
    }

    func testPlayPauseAndToggleReachCoordinator() async {
        _ = await coordinator.start(items: TestItems.makeMany(["a", "b", "c"]))
        let paused = await handle(.pause)
        XCTAssertEqual(paused, .success)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)

        let played = await handle(.play)
        XCTAssertEqual(played, .success)
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing)

        let toggled = await handle(.togglePlayPause)
        XCTAssertEqual(toggled, .success)
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
    }

    func testNextAndPreviousReachCoordinator() async {
        _ = await coordinator.start(items: TestItems.makeMany(["a", "b", "c"]))
        let forward = await handle(.nextTrack)
        XCTAssertEqual(forward, .success)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.item?.id, "b")
        let back = await handle(.previousTrack)
        XCTAssertEqual(back, .success)
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.item?.id, "a")
    }

    func testSkipForwardAndBackwardAreFifteenSeconds() async {
        _ = await coordinator.start(items: [TestItems.make("a", duration: 100)])
        _ = await coordinator.seek(to: 50)
        let forward = await handle(.skipForward(seconds: 15))
        XCTAssertEqual(forward, .success)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.position, 65)
        let backward = await handle(.skipBackward(seconds: 15))
        XCTAssertEqual(backward, .success)
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.position, 50)
    }

    func testSkipAtHeadClampsToZeroAndPreviousIsNoSuchContent() async {
        _ = await coordinator.start(items: [TestItems.make("a", duration: 5)])
        let status = await handle(.skipBackward(seconds: 15))
        XCTAssertEqual(status, .success, "已在 0 再退：合法地停在 0")
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.position, 0)
        let previous = await handle(.previousTrack)
        XCTAssertEqual(previous, .noSuchContent, ".off 下首项无邻居")
    }

    func testAbsoluteSeekBeyondDurationIsClampedAndSucceeds() async {
        _ = await coordinator.start(items: [TestItems.make("a", duration: 30)])
        let status = await handle(.seek(to: 500))
        XCTAssertEqual(status, .success)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.position, 30)
    }

    func testIllegalSeekTargetsFail() async {
        _ = await coordinator.start(items: [TestItems.make("a")])
        let negative = await handle(.seek(to: -5))
        XCTAssertEqual(negative, .failure)
        let nan = await handle(.seek(to: Double.nan))
        XCTAssertEqual(nan, .failure)
    }

    func testChangeRateWithinAndOutsideSupportedWindow() async {
        _ = await coordinator.start(items: [TestItems.make("a")])
        let outOfRange = await handle(.changeRate(to: 9))
        XCTAssertEqual(outOfRange, .failure, "越界速率被钳制 → 命令视为失败")
        let okRate = await handle(.changeRate(to: 1.5))
        XCTAssertEqual(okRate, .success)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.playbackRate, 1.5)
    }

    func testAvailabilityReflectsQueueState() async {
        let before = await router.isAvailable(.play)
        XCTAssertFalse(before)
        _ = await coordinator.start(items: TestItems.makeMany(["a"]))
        let after = await router.isAvailable(.play)
        XCTAssertTrue(after)
        let next = await router.isAvailable(.nextTrack)
        XCTAssertTrue(next)
    }

    func testRouterHoldsCoordinatorWeakly() {
        // weak 打断 `coordinator → controller → router → coordinator` 循环。
        XCTAssertNotNil(router.boundCoordinator)
        router.bind(nil)
        XCTAssertNil(router.boundCoordinator)
    }

    // MARK: - 元数据字典（纯映射）

    func testInfoDictionaryCarriesRequiredNowPlayingKeys() {
        let metadata = NowPlayingMetadata(
            itemID: "a", title: "标题", artist: "艺人", album: "专辑",
            duration: 120, elapsed: 42, playbackRate: 1, isPlaying: true,
            artworkURL: TestItems.audioURL()
        )
        let info = MPNowPlayingController.infoDictionary(for: metadata)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "标题")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "艺人")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "专辑")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 120)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    func testInfoDictionaryOmitsUnknownOptionalFields() {
        let metadata = NowPlayingMetadata(itemID: "a", title: "标题", artist: "艺人")
        let info = MPNowPlayingController.infoDictionary(for: metadata)
        XCTAssertNil(info[MPMediaItemPropertyAlbumTitle])
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0, "未播放 → 速率 0")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
    }

    func testPausedPlaybackRateIsPublishedAsZero() {
        let metadata = NowPlayingMetadata(
            itemID: "a", title: "t", artist: "s", duration: 10, elapsed: 4,
            playbackRate: 1.5, isPlaying: false
        )
        let info = MPNowPlayingController.infoDictionary(for: metadata)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
    }

    func testMetadataNeverEchoesCoverQuery() {
        let signed = try! AudioURL(https: URL(string: "https://cdn.covalink.example/cover.jpg?sig=SECRETVALUE")!)
        let metadata = NowPlayingMetadata(itemID: "a", title: "t", artist: "s", artworkURL: signed)
        let described = String(reflecting: metadata)
        XCTAssertFalse(described.contains("SECRETVALUE"), described)
    }

    func testNegativeElapsedIsNormalizedToZero() {
        let metadata = NowPlayingMetadata(itemID: "a", title: "t", artist: "s", elapsed: -5)
        XCTAssertEqual(metadata.elapsed, 0)
    }

    // MARK: - 状态码 → MPRemoteCommandHandlerStatus

    func testHandlerStatusMappingCoversAllCases() {
        XCTAssertEqual(MPNowPlayingController.handlerStatus(for: .success), .success)
        XCTAssertEqual(MPNowPlayingController.handlerStatus(for: .noSuchContent), .noSuchContent)
        XCTAssertEqual(MPNowPlayingController.handlerStatus(for: .notReadyToPlay), .noActionableNowPlayingItem)
        XCTAssertEqual(MPNowPlayingController.handlerStatus(for: .failure), .commandFailed)
        XCTAssertEqual(NowPlayingStatus.allCases.count, 4)
    }

    func testSkipIntervalConstantIsFifteen() {
        XCTAssertEqual(MPNowPlayingController.skipInterval, 15)
        XCTAssertEqual(MPNowPlayingController.skipNumber.doubleValue, 15)
        XCTAssertEqual(MPNowPlayingController.defaultRateNumber.doubleValue, 1)
    }

    /// 纯映射穷举（事件类无公开 init，故「取值后的决策」在此断言）。
    func testPureRemoteCommandMappingCoversEveryName() {
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "play"), .play)
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "pause"), .pause)
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "togglePlayPause"), .togglePlayPause)
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "nextTrack"), .nextTrack)
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "previousTrack"), .previousTrack)
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "seekForward"), .skipForward(seconds: 15))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "skipForward"), .skipForward(seconds: 15))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "seekBackward"), .skipBackward(seconds: 15))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "skipBackward"), .skipBackward(seconds: 15))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "changePlaybackPosition", positionTime: 33), .seek(to: 33))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "changePlaybackRate", playbackRate: 1.5), .changeRate(to: 1.5))
        // 事件字段缺失 = 事件类型不匹配 → nil（handler 回 .commandFailed，绝不假装成功）。
        XCTAssertNil(MPNowPlayingController.remoteCommand(named: "changePlaybackPosition"))
        XCTAssertNil(MPNowPlayingController.remoteCommand(named: "changePlaybackRate"))
        XCTAssertNil(MPNowPlayingController.remoteCommand(named: "nonsense", positionTime: 1))
    }

    /// `MPRemoteCommandEvent` 及其子类都无公开 init（系统侧构造），
    /// 因此事件翻译的可断言面在 `remoteCommand(named:positionTime:playbackRate:)`。
    /// 此处只守「事件类型不匹配 → nil」这条不猜测的规矩（用系统真实事件类型的父类判空）。
    func testTypedCommandMakersRequireTheirEventKind() {
        // 缺字段（等价于事件类型不匹配）→ nil，绝不回落到 .seek(to: 0)。
        XCTAssertNil(MPNowPlayingController.remoteCommand(named: "changePlaybackPosition"))
        XCTAssertNil(MPNowPlayingController.remoteCommand(named: "changePlaybackRate"))
        // 显式给字段才产出命令。
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "changePlaybackPosition", positionTime: 0), .seek(to: 0))
        XCTAssertEqual(MPNowPlayingController.remoteCommand(named: "changePlaybackRate", playbackRate: 0), .changeRate(to: 0))
    }

    // MARK: - 真实 MPRemoteCommandCenter 冒烟（注册 / 注销，零悬垂）

    /// 真实 `MPRemoteCommandCenter` 上的注册 / 注销冒烟。
    ///
    /// 说明（TD-39）：MediaPlayer 未公开 `MPRemoteCommand.targets`，系统侧 target 数不可观测，
    /// 故冒烟面断言「本层持有的 handler token 账」——它同时是防悬垂的关键（系统不持有 target，
    /// token 必须由本对象强持有；注销后账目必须清零）。
    func testRealCommandCenterRegistrationAndRemoval() async {
        let controller = MPNowPlayingController(router: router)
        let center = MPNowPlayingController.sharedCenter()
        await controller.teardown()
        XCTAssertEqual(controller.registeredHandlerCount, 0)
        await controller.registerCommands()
        let registered = controller.registeredHandlerCount
        XCTAssertEqual(registered, MPNowPlayingController.managedCommandNames.count)
        XCTAssertEqual(
            Set(controller.registeredHandlerNames),
            Set(MPNowPlayingController.managedCommandNames),
            "全部受管命令都必须接上 handler"
        )
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals.map { $0.doubleValue }, [15])
        XCTAssertEqual(center.skipBackwardCommand.preferredIntervals.map { $0.doubleValue }, [15])

        await controller.teardown()
        XCTAssertEqual(controller.registeredHandlerCount, 0, "teardown 后不得残留 target 账（本仓红线）")
        XCTAssertEqual(controller.observedTeardownCount, 2, "本用例先 teardown 清零了一次")
        XCTAssertNil(controller.lastPublishedInfo)
    }

    func testRegisterCommandsIsIdempotentOnRealCenter() async {
        let controller = MPNowPlayingController(router: router)
        await controller.registerCommands()
        await controller.registerCommands()
        let registered = controller.registeredHandlerCount
        XCTAssertEqual(registered, MPNowPlayingController.managedCommandNames.count, "重复注册不得叠加 token 账")
        await controller.teardown()
    }

    func testCommandsCanBeEnabledAndDisabled() {
        let controller = MPNowPlayingController(router: router)
        controller.setCommandsEnabled(false)
        let disabled = MPNowPlayingController.controllableCommands(MPNowPlayingController.sharedCenter())
            .allSatisfy { $0.isEnabled == false }
        XCTAssertTrue(disabled)
        controller.setCommandsEnabled(true)
        let enabled = MPNowPlayingController.controllableCommands(MPNowPlayingController.sharedCenter())
            .allSatisfy(\.isEnabled)
        XCTAssertTrue(enabled)
    }

    func testNowPlayingInfoIsPublishedAndCleared() async {
        let controller = MPNowPlayingController(router: router)
        await controller.publish(NowPlayingMetadata(
            itemID: "a", title: "标题", artist: "艺人", album: "专辑", duration: 10, elapsed: 1, isPlaying: true
        ))
        XCTAssertEqual(controller.lastPublishedInfo?[MPMediaItemPropertyTitle] as? String, "标题")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String, "艺人")
        await controller.clear()
        XCTAssertNil(controller.lastPublishedInfo)
        XCTAssertTrue(MPNowPlayingInfoCenter.default().nowPlayingInfo?.isEmpty ?? true)
        await controller.teardown()
    }

    func testArtworkIsAttachedAsynchronouslyWithoutBlockingPublish() async {
        let attacher = StubArtworkAttacher()
        let controller = MPNowPlayingController(router: router, artworkAttacher: attacher)
        let metadata = NowPlayingMetadata(itemID: "a", title: "t", artist: "s", artworkURL: TestItems.audioURL())
        await controller.publish(metadata)
        // publish 已返回（未被封面取回阻塞），随后信号式等待挂载完成。
        await controller.waitForArtworkTask()
        let calls = await attacher.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.lastPublishedInfo?[MPNowPlayingController.artworkAttachedKey] as? Bool, true)
        await controller.teardown()
    }

    func testArtworkFailureLeavesMetadataIntact() async {
        let attacher = StubArtworkAttacher()
        await attacher.configure(result: false)
        let controller = MPNowPlayingController(router: router, artworkAttacher: attacher)
        await controller.publish(NowPlayingMetadata(
            itemID: "a", title: "t", artist: "s", artworkURL: TestItems.audioURL()
        ))
        await controller.waitForArtworkTask()
        XCTAssertNil(controller.lastPublishedInfo?[MPNowPlayingController.artworkAttachedKey])
        XCTAssertEqual(controller.lastPublishedInfo?[MPMediaItemPropertyTitle] as? String, "t")
        await controller.teardown()
    }

    func testPublishWithoutArtworkURLSkipsAttacher() async {
        let attacher = StubArtworkAttacher()
        let controller = MPNowPlayingController(router: router, artworkAttacher: attacher)
        await controller.publish(NowPlayingMetadata(itemID: "a", title: "t", artist: "s"))
        await controller.waitForArtworkTask()
        let calls = await attacher.callCount
        XCTAssertEqual(calls, 0)
        await controller.teardown()
    }

    func testAttacherCanBeInjectedAfterConstruction() async {
        let controller = MPNowPlayingController(router: router)
        let attacher = StubArtworkAttacher()
        controller.setArtworkAttacher(attacher)
        await controller.publish(NowPlayingMetadata(
            itemID: "a", title: "t", artist: "s", artworkURL: TestItems.audioURL()
        ))
        await controller.waitForArtworkTask()
        let calls = await attacher.callCount
        XCTAssertEqual(calls, 1)
        controller.setArtworkAttacher(nil)
        await controller.teardown()
    }

    func testCommandTableCoversDesignSurface() {
        // design/screens/02-player.md §7：播放/暂停/上下首/seek/±15s。
        let required: Set<String> = [
            "play", "pause", "togglePlayPause", "nextTrack", "previousTrack",
            "seekForward", "seekBackward", "skipForward", "skipBackward",
            "changePlaybackPosition", "changePlaybackRate",
        ]
        XCTAssertEqual(Set(MPNowPlayingController.managedCommandNames), required)
        let center = MPNowPlayingController.sharedCenter()
        for name in required {
            XCTAssertNotNil(MPNowPlayingController.command(in: center, named: name), name)
        }
        XCTAssertNil(MPNowPlayingController.command(in: center, named: "nope"))
        XCTAssertEqual(MPNowPlayingController.controllableCommands(center).count, required.count)
    }

    // MARK: - 环 4 · 第 7 批 MAJ-6：锁屏命令桥禁止无超时 `wait()`

    /// MAJ-6（受理判定腿，纯函数零 hop）：返回码**只能**来自同步可判的那一点。
    ///
    /// 这条同时是「旧形态」的确定性杀手：旧实现 `semaphore.wait()` 等的是
    /// `router.handle(...)` 的真实结果 —— 协调器未绑定时那是 `.notReadyToPlay`
    /// → `.noActionableNowPlayingItem`。所以拿一个**没绑协调器**的 router 打这里，
    /// 阻塞式桥接必然变红（不需要挂死、也不需要竞态断言）。
    func testRemoteCommandAcceptanceIsDecidedWithoutAskingThePlayer() {
        let unbound = NowPlayingCommandRouter()
        for command in [
            NowPlayingCommand.play, .pause, .togglePlayPause, .nextTrack, .previousTrack,
            .skipForward(seconds: 15), .skipBackward(seconds: 15), .changeRate(to: 1),
            .seek(to: 0), .seek(to: 42),
        ] {
            XCTAssertEqual(
                MPNowPlayingController.acceptanceStatus(for: command),
                .success,
                "已受理的命令不得因为「结果还没跑完」被拒：\(command)"
            )
            XCTAssertEqual(
                MPNowPlayingController.acceptAndDeliver(router: unbound, command: command),
                .success,
                "MAJ-6：零 hop 的受理判定；等 actor 链的旧桥接在这里会回 .noActionableNowPlayingItem"
            )
        }
        for illegal in [NowPlayingCommand.seek(to: -1), .seek(to: .nan), .seek(to: .infinity)] {
            XCTAssertEqual(
                MPNowPlayingController.acceptanceStatus(for: illegal),
                .commandFailed,
                "非法时间目标是**同步可判**的，必须当场拒：\(illegal)"
            )
            XCTAssertEqual(
                MPNowPlayingController.acceptAndDeliver(router: unbound, command: illegal),
                .commandFailed
            )
        }
    }

    /// MAJ-6（投递腿）：命令链**在途挂起**时 handler 照样返回，且返回之后命令真的被投递了。
    ///
    /// 复审实测旧桥接把系统队列 parked 0.424s（夹具放行之前零推进），上界 = `resourceTimeout`
    /// 7 天。这里把 `prepareSource` 关在闸门后（`GatedSourcePreparer`，确定性会合点）：
    /// - `acceptAndDeliver` 必须先返回（旧形态在这条链上永远不会返回）；
    /// - 返回之后投递**确实发生了**（`requestSignal` 到 2 次）；
    /// - 而闸门未放行时协调器**必然**还没走完（放行权在测试手里，所以「没走完」是事实、
    ///   不是时序猜测 —— D16⑤）；
    /// - 放行后那一路真的走到第二首。
    ///
    /// 「结果回显到 `MPNowPlayingInfoCenter`」那条腿**刻意不塞在这里**：放行闸门之后 `next()`
    /// 还有后续续体（装载 → `.playing` → `publish`）要跑，而它没有会合点，在它上面做读数
    /// 断言就是竞态断言（第 7 批 `-test-iterations 500` 实测挂过 5 次）。回显由
    /// `testDeliveredRemoteCommandStillEchoesIntoNowPlaying` 在一条**没有在途装载**的链上验。
    func testRemoteCommandDeliveryDoesNotWaitForInFlightLoad() async throws {
        let preparer = GatedSourcePreparer(gating: ["b"])
        let controller = MPNowPlayingController(router: router)
        let bound = PlaybackCoordinator(
            engine: ScriptedEngine(),
            clock: FakeClock(),
            nowPlaying: controller,
            sourcePreparer: preparer
        )
        let liveRouter = try XCTUnwrap(router)
        liveRouter.bind(bound)
        await controller.teardown()
        await controller.registerCommands()
        addTeardownBlock {
            // 兜底放行：handler 若回归成阻塞式桥接，闸门不得把测试挂死在 teardown 之后。
            await preparer.release("b")
        }

        _ = await bound.start(items: TestItems.makeMany(["a", "b"]))
        let firstPrepared = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(firstPrepared, "前置条件：a 的装载未进入在途")
        let afterFirstLoad = await preparer.returnedCount()
        XCTAssertEqual(afterFirstLoad, 1, "前置条件：a 那一趟装载已经走完")

        // handler 要在「b 的装载在途」时照样返回。放进 Task 里跑：一旦回归成
        // 无超时 `semaphore.wait()`，这里是**变红**（`Signals` 的真实上界）而不是挂死。
        final class StatusBox: @unchecked Sendable { var status: MPRemoteCommandHandlerStatus? }
        let box = StatusBox()
        let handlerReturned = SignalCounter()
        Task {
            box.status = MPNowPlayingController.acceptAndDeliver(
                router: liveRouter, command: .nextTrack
            )
            handlerReturned.bump()
        }
        let cameBack = await Signals.wait(target: 1, counter: handlerReturned)
        XCTAssertTrue(
            cameBack,
            "MAJ-6：命令桥又被在途装载钉住了 —— handler 在闸门放行前不得返回"
        )
        XCTAssertEqual(box.status, .success, "受理码来自零 hop 的受理判定，与装载结果无关")

        // 返回之后投递真的发生了：b 的 `prepareSource` 已进入在途。
        let delivered = await Signals.wait(target: 2, counter: preparer.requestSignal)
        XCTAssertTrue(delivered, "MAJ-6：handler 返回了，但那道命令没人跑（投递是空操作）")
        let returnedWhileParked = await preparer.returnedCount()
        XCTAssertEqual(
            returnedWhileParked,
            afterFirstLoad,
            "前置条件：b 仍关在闸门里 —— 放行权在测试手里，故「那一路没走完」是可核对的事实"
        )

        await preparer.release("b")
        let returned = await Signals.wait(target: returnedWhileParked + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置条件：闸门已放行")
        let after = await bound.currentSnapshot()
        XCTAssertEqual(after.item?.id, "b", "放行的那一路必须真的走到第二首")
        await bound.teardown()
        await controller.teardown()
    }

    /// MAJ-6（回传腿，**独立且确定性**）：异步投递的命令，其结果仍然写回 Now Playing。
    ///
    /// 为什么不塞在上那条在途测试里：`prepareSource` 放行之后，`next()` 那一支还有
    /// 后续续体（装载 → `.playing`）要跑，而它**没有会合点** —— 在它上面做任何读数断言
    /// 都是竞态断言（第 7 批 `-test-iterations 500` 实测挂过 5 次：读数停在装载那一次发布上）。
    /// 所以这里刻意用一支**没有在途装载**的链：`start` 已经完全 await 结束，
    /// 之后投递的 `.pause` 是最后一个动手的人，读数才有确定性。
    func testDeliveredRemoteCommandStillEchoesIntoNowPlaying() async throws {
        let controller = MPNowPlayingController(router: router)
        let liveRouter = try XCTUnwrap(router)
        let bound = PlaybackCoordinator(
            engine: ScriptedEngine(),
            clock: FakeClock(),
            nowPlaying: controller,
            sourcePreparer: nil
        )
        liveRouter.bind(bound)
        await controller.teardown()
        await controller.registerCommands()
        _ = await bound.start(items: TestItems.makeMany(["echo"]))
        let playing = await bound.currentSnapshot()
        XCTAssertEqual(playing.state, .playing, "前置条件：正在播")

        // 局部 var 不能进 `@Sendable` 闭包（region isolation），故用显式盒子；
        // 读写两侧由 `statuses` 的信号串行化。
        final class Sink: @unchecked Sendable { var status: NowPlayingStatus? }
        let sink = Sink()
        let statuses = SignalCounter()
        MPNowPlayingController.deliver(router: liveRouter, command: .pause) { status in
            sink.status = status
            statuses.bump()
        }
        let done = await Signals.wait(target: 1, counter: statuses)
        XCTAssertTrue(done, "MAJ-6：投递未跑完（`onDelivered` 记账点没被触发）")
        XCTAssertEqual(sink.status, .success, "命令要真的被播放器受理并生效")

        let paused = await bound.currentSnapshot()
        XCTAssertEqual(paused.state, .paused, "投递的命令必须真的改变状态")
        let published = MPNowPlayingInfoCenter.default()
        XCTAssertEqual(
            published.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,
            "曲目-echo",
            "MAJ-6：结果回传系统 = Now Playing 信息字典（受理即返回不等于不回传）"
        )
        XCTAssertEqual(
            published.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            0,
            "MAJ-6：已生效的暂停必须回显成速率 0"
        )
        XCTAssertEqual(
            controller.lastPublishedInfo?[MPMediaItemPropertyTitle] as? String,
            "曲目-echo",
            "回显确实是这条投递链写的"
        )
        await bound.teardown()
        await controller.teardown()
    }

    // MARK: - 环 4 · 第 7 批 min-6：共享命令面（进程单例）的所有权必须看得见

    /// min-6：第二个实例注册命令时，第一个实例必须**查询得到**自己已被顶掉。
    ///
    /// 旧实现里这件事完全静默：`registerCommands()` 每次 `removeTarget(nil)` 清掉别人的 target，
    /// 而 `registeredHandlerCount` 只申报「本层账上有几条」，说不出系统现在听谁的。
    /// 本用例同时把那条**局限**钉在明面上（末尾三行）：被顶掉的那位仍然自报 11 条 ——
    /// 这就是 TD-43 里「系统不给按所有者查询 target 的能力」那一部分，不是本层能修的。
    func testSecondRegistrationTakesOverSharedCommandSurface() async {
        let first = MPNowPlayingController(router: router)
        let second = MPNowPlayingController(router: router)
        await first.teardown()
        await second.teardown()
        let claimsBefore = MPNowPlayingController.sharedSurfaceClaimCount

        await first.registerCommands()
        XCTAssertTrue(first.ownsSharedCommandSurface, "注册即认领共享面")
        XCTAssertFalse(second.ownsSharedCommandSurface)

        await second.registerCommands()
        XCTAssertFalse(first.ownsSharedCommandSurface, "min-6：第二个实例接手时，第一个必须看得见")
        XCTAssertTrue(second.ownsSharedCommandSurface)
        let claimsAfter = MPNowPlayingController.sharedSurfaceClaimCount
        XCTAssertEqual(claimsAfter, claimsBefore + 2, "认领次数是进程内事实，不是自我申报")
        XCTAssertEqual(
            first.registeredHandlerCount,
            MPNowPlayingController.managedCommandNames.count,
            "被顶掉者仍自报满额 target（min-6 点名的自我申报，TD-43 记着这条边界）"
        )

        await second.teardown()
        XCTAssertFalse(second.ownsSharedCommandSurface, "持有者退出后共享面回到无人认领")
        await first.teardown()
    }

    /// min-6（边界本体，写下来而不是藏起来）：任何一次 `setCommandsEnabled` 都作用于
    /// **全部 11 条**命令、与所有者无关，并把所有权带走。这是「进程单例 + 无 owner 命名空间」
    /// 的直接后果，本层只能把它变成可查询的事实（TD-43）。
    func testSharedSurfaceWriteFromNonOwnerStompsEveryCommandAndTakesOver() async {
        let ownerController = MPNowPlayingController(router: router)
        let jumper = MPNowPlayingController(router: router)
        await ownerController.teardown()
        await jumper.teardown()
        await ownerController.registerCommands()
        ownerController.setCommandsEnabled(true)
        XCTAssertTrue(ownerController.ownsSharedCommandSurface, "前置条件：ownerController 是持有者")

        jumper.setCommandsEnabled(false)
        let commands = MPNowPlayingController.controllableCommands(MPNowPlayingController.sharedCenter())
        XCTAssertEqual(commands.count, MPNowPlayingController.managedCommandNames.count)
        XCTAssertTrue(
            commands.allSatisfy { $0.isEnabled == false },
            "min-6：非持有者一次写入就把全部命令位关掉（与所有者无关 —— 已登记 TD-43）"
        )
        XCTAssertFalse(ownerController.ownsSharedCommandSurface, "写共享面即接手共享面：形状负责人随之转移")
        XCTAssertTrue(jumper.ownsSharedCommandSurface)
        jumper.setCommandsEnabled(true)
        await ownerController.teardown()
        await jumper.teardown()
    }
}
