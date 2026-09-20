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
}
