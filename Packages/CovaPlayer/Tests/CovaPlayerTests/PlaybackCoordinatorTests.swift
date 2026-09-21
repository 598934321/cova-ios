import CovaCore
import XCTest
@testable import CovaPlayer

/// `PlaybackCoordinator`：±15s / 循环三态 / 失败连击 / 事件归约 / 生命周期。
///
/// 全部用例：注入引擎桩 + 虚拟时钟 + 记录型 Now Playing，零 AVFoundation、零网络、零真实等待。
/// 异步断言一律「先 await 取值，再断言」（XCTest 断言的 autoclosure 不支持 await）。
final class PlaybackCoordinatorTests: XCTestCase {
    private var engine: ScriptedEngine!
    private var clock: FakeClock!
    private var nowPlaying: RecordingNowPlaying!
    private var submitter: StubPlayReportSubmitter!
    private var reporter: PlayReportCoordinator!
    private var subject: PlaybackCoordinator!

    override func setUp() {
        super.setUp()
        engine = ScriptedEngine()
        clock = FakeClock()
        nowPlaying = RecordingNowPlaying()
        submitter = StubPlayReportSubmitter()
        reporter = PlayReportCoordinator(submitter: submitter)
        subject = PlaybackCoordinator(
            engine: engine,
            clock: clock,
            reporter: reporter,
            nowPlaying: nowPlaying
        )
    }

    override func tearDown() {
        engine = nil
        clock = nil
        nowPlaying = nil
        submitter = nil
        reporter = nil
        subject = nil
        super.tearDown()
    }

    private func snapshot() async -> PlaybackSnapshot {
        await subject.currentSnapshot()
    }

    // MARK: - 纯钳制算术

    func testSeekClampWithKnownDuration() {
        XCTAssertEqual(SeekArithmetic.clamp(target: 105, duration: 100), ClampedPosition(position: 100, clamp: .upperBound))
        XCTAssertEqual(SeekArithmetic.clamp(target: 40, duration: 100), ClampedPosition(position: 40, clamp: .none))
        XCTAssertEqual(SeekArithmetic.clamp(target: 0, duration: 100), ClampedPosition(position: 0, clamp: .none))
        XCTAssertEqual(SeekArithmetic.clamp(target: 100, duration: 100), ClampedPosition(position: 100, clamp: .none))
    }

    func testSeekClampNeverGoesNegative() {
        XCTAssertEqual(SeekArithmetic.clamp(target: -0.001, duration: 100), ClampedPosition(position: 0, clamp: .lowerBound))
        XCTAssertEqual(SeekArithmetic.clamp(target: -999, duration: 100), ClampedPosition(position: 0, clamp: .lowerBound))
        XCTAssertEqual(SeekArithmetic.clamp(target: -5, duration: nil), ClampedPosition(position: 0, clamp: .lowerBound))
    }

    func testSeekClampWithDurationUnknownAllowsOvershoot() {
        XCTAssertEqual(SeekArithmetic.clamp(target: 300, duration: nil), ClampedPosition(position: 300, clamp: .durationUnknown))
        XCTAssertEqual(
            SeekArithmetic.clamp(target: 1_000_000, duration: nil),
            ClampedPosition(position: 1_000_000, clamp: .durationUnknown)
        )
    }

    func testSeekClampRejectsNonFinite() {
        XCTAssertNil(SeekArithmetic.clamp(target: Double.nan, duration: 100))
        XCTAssertNil(SeekArithmetic.clamp(target: Double.infinity, duration: 100))
    }

    func testDegenerateDurationsCountAsUnknown() {
        for bogus in [0.0, -3, Double.nan] {
            let clamped = SeekArithmetic.clamp(target: 300, duration: bogus)
            XCTAssertEqual(clamped?.clamp, .durationUnknown, "\(bogus) 应视为时长未知")
        }
    }

    // MARK: - ±15s 行为

    func testSeekForwardAndBackwardByFifteen() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        await subject.receive(.position(seconds: 42))

        let forward = await subject.seekBySeconds(15)
        XCTAssertEqual(forward, .applied(position: 57, clamped: .none, then: nil))
        let backward = await subject.seekBySeconds(-15)
        XCTAssertEqual(backward, .applied(position: 42, clamped: .none, then: nil))
        let after = await snapshot()
        XCTAssertEqual(after.position, 42)
    }

    func testSeekBackwardAtZeroStopsAtZeroAndNeverGoesNegative() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        let first = await subject.seekBySeconds(-15)
        XCTAssertEqual(first, .applied(position: 0, clamped: .lowerBound, then: nil))
        let second = await subject.seekBySeconds(-15)
        XCTAssertEqual(second, .applied(position: 0, clamped: .lowerBound, then: nil))
        let after = await snapshot()
        XCTAssertEqual(after.position, 0)
        XCTAssertEqual(engine.seeks, [0, 0], "绝不把负值交给引擎")
    }

    func testSeekNearTailClampsToDurationAndTriggersEndedSemantics() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        await subject.receive(.position(seconds: 90))
        let outcome = await subject.seekBySeconds(15)
        guard case .applied(let position, let clamp, let then) = outcome else {
            return XCTFail("应落在 duration：\(outcome)")
        }
        XCTAssertEqual(position, 100)
        XCTAssertEqual(clamp, .upperBound)
        XCTAssertEqual(then, .advanced(to: 1, item: TestItems.make("b"), wrapped: false))
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
    }

    func testSeekBeyondDurationUnderOneRepeatsFromZero() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        await subject.receive(.position(seconds: 99))
        let outcome = await subject.seekBySeconds(15)
        XCTAssertEqual(
            outcome,
            .applied(position: 100, clamped: .upperBound, then: .repeated(at: 0, item: TestItems.make("a")))
        )
        let after = await snapshot()
        XCTAssertEqual(after.position, 0, ".one 回到 0 继续播")
        XCTAssertEqual(after.state, .playing)
    }

    func testSeekBeyondDurationUnderOffAtTailStops() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        await subject.receive(.position(seconds: 95))
        let outcome = await subject.seekBySeconds(15)
        guard case .applied(_, _, let then) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(then, .stopped)
        let after = await snapshot()
        XCTAssertEqual(after.state, .stopped)
    }

    func testSeekWithUnknownDurationAllowsOvershootThenEngineCorrects() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"], duration: nil))
        _ = await subject.start()
        await subject.receive(.position(seconds: 10))
        let overshot = await subject.seekBySeconds(200)
        XCTAssertEqual(overshot, .applied(position: 210, clamped: .durationUnknown, then: nil))

        // 引擎后到 duration → 越界位置落回边界并按「播完」推进。
        await subject.receive(.duration(seconds: 100))
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "b", "duration 迟到把越界位置纠正到末尾后按播完处理")
    }

    func testSeekAbsolutePositionIsClampedToo() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 60))
        // 单元素 + `.off`：末项落到时长末端即进入停止态（不 wrap）。
        let outcome = await subject.seek(to: 1_000)
        XCTAssertEqual(outcome, .applied(position: 60, clamped: .upperBound, then: .stopped))
    }

    func testSeekToDurationUnderOneRepeatsCurrentItem() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"], duration: nil))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        await subject.receive(.duration(seconds: 60))
        let looping = await subject.seek(to: 1_000)
        XCTAssertEqual(
            looping,
            .applied(position: 60, clamped: .upperBound, then: .repeated(at: 0, item: TestItems.make("a", duration: nil)))
        )
    }

    func testSeekWithoutCurrentItemIsRejected() async {
        let forward = await subject.seekBySeconds(15)
        XCTAssertEqual(forward, .rejected(.noCurrentItem))
        let absolute = await subject.seek(to: 3)
        XCTAssertEqual(absolute, .rejected(.noCurrentItem))
        XCTAssertEqual(engine.count(of: "seek"), 0)
    }

    func testNonFiniteSeekTargetIsRejected() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        let nan = await subject.seek(to: Double.nan)
        XCTAssertEqual(nan, .rejected(.nonFiniteTarget))
        let infinite = await subject.seekBySeconds(.infinity)
        XCTAssertEqual(infinite, .rejected(.nonFiniteTarget))
    }

    // MARK: - 循环三态（itemEnd）

    func testItemEndUnderOffWalksThenStops() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        await subject.receive(.ended)
        var after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        await subject.receive(.ended)
        after = await snapshot()
        XCTAssertEqual(after.state, .stopped)
        XCTAssertEqual(after.item?.id, "b", ".off 不 wrap：停在末项")
    }

    func testItemEndUnderAllWrapsToFirst() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        await subject.setLoopMode(.all)
        _ = await subject.start()
        await subject.receive(.ended)
        var after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        await subject.receive(.ended)
        after = await snapshot()
        XCTAssertEqual(after.item?.id, "a", "末项播完回到首项")
        XCTAssertEqual(after.state, .playing)
    }

    func testItemEndUnderOneReplaysSameTrackFromZero() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        await subject.receive(.duration(seconds: 100))
        await subject.receive(.position(seconds: 100))
        await subject.receive(.ended)
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "a", ".one 不换曲")
        XCTAssertEqual(after.position, 0)
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(engine.count(of: "load"), 1, ".one 不重新装载")
        XCTAssertEqual(engine.seeks, [0], "只 seek 回 0")
    }

    func testEndedWhileLoadingOrStoppedIsIgnoredNoDoubleAdvance() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        await subject.receive(.ended)
        var after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        await subject.pause()
        // 暂停中到达的 ended（引擎重复上报）不得再推进。
        await subject.receive(.ended)
        await subject.receive(.ended)
        after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        await subject.resume()
        after = await snapshot()
        XCTAssertEqual(after.state, .playing)
    }

    func testStoppedThenUserNextDoesNotRevivePlayback() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.ended)
        var after = await snapshot()
        XCTAssertEqual(after.state, .stopped)
        let outcome = await subject.next()
        XCTAssertEqual(outcome, .held)
        after = await snapshot()
        XCTAssertEqual(after.state, .stopped)
        // 恢复条件：显式 resume 从 0 重新播当前项。
        await subject.resume()
        after = await snapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(after.position, 0)
    }

    func testCycleLoopModeFollowsDesignOrder() async {
        let first = await subject.cycleLoopMode()
        let second = await subject.cycleLoopMode()
        let third = await subject.cycleLoopMode()
        let current = await subject.currentLoopMode()
        XCTAssertEqual(first, .all)
        XCTAssertEqual(second, .one)
        XCTAssertEqual(third, .off)
        XCTAssertEqual(current, .off)
    }

    // MARK: - next / previous

    func testNextAndPreviousMoveAndPlay() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start(at: 1)
        let forward = await subject.next()
        XCTAssertEqual(forward, .advanced(to: 2, item: TestItems.make("c"), wrapped: false))
        let back = await subject.previous()
        XCTAssertEqual(back, .advanced(to: 1, item: TestItems.make("b"), wrapped: false))
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
    }

    func testPreviousAtFirstUnderOffIsHeld() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        let outcome = await subject.previous()
        XCTAssertEqual(outcome, .held)
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "a")
    }

    func testPreviousAtFirstUnderAllWrapsToLast() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        await subject.setLoopMode(.all)
        _ = await subject.start()
        let outcome = await subject.previous()
        XCTAssertEqual(outcome, .advanced(to: 2, item: TestItems.make("c"), wrapped: true))
    }

    func testNavigationOnEmptyQueueIsRejected() async {
        let next = await subject.next()
        let previous = await subject.previous()
        let start = await subject.start()
        let startEmpty = await subject.start(items: [])
        let startIndexEmpty = await subject.start(at: 3)
        XCTAssertEqual(next, .rejected(.emptyQueue))
        XCTAssertEqual(previous, .rejected(.emptyQueue))
        XCTAssertEqual(start, .rejected(.emptyQueue))
        XCTAssertEqual(startEmpty, .rejected(.emptyQueue))
        XCTAssertEqual(startIndexEmpty, .rejected(.emptyQueue))
    }

    func testStartSelectsRequestedIndexAndPlays() async {
        let outcome = await subject.start(items: TestItems.makeMany(["a", "b", "c"]), at: 2)
        XCTAssertEqual(outcome, .advanced(to: 2, item: TestItems.make("c"), wrapped: false))
        let after = await snapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(after.index, 2)
        XCTAssertEqual(engine.loads.last?.id, "c")
    }

    func testStartAtIndexOutOfRangeIsClamped() async {
        let outcome = await subject.start(items: TestItems.makeMany(["a", "b", "c"]), at: 99)
        XCTAssertEqual(outcome, .advanced(to: 2, item: TestItems.make("c"), wrapped: false))
        let ids = await subject.queueItems()
        XCTAssertEqual(ids.count, 3, "越界索引钳到末项，不改变队列")
    }

    // MARK: - 暂停 / 恢复 / 切换

    func testPauseResumeToggleTransitions() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        XCTAssertEqual(engine.count(of: "play"), 1, "start 装载后立即起播")
        let paused = await subject.toggle()
        XCTAssertEqual(paused, .paused)
        XCTAssertEqual(engine.count(of: "pause"), 1)
        let playing = await subject.toggle()
        XCTAssertEqual(playing, .playing)
        XCTAssertEqual(engine.count(of: "play"), 2)
        await subject.pause()
        var after = await snapshot()
        XCTAssertEqual(after.state, .paused)
        await subject.resume()
        after = await snapshot()
        XCTAssertEqual(after.state, .playing)
    }

    func testPauseWithoutItemStillForwardsToEngine() async {
        await subject.pause()
        await subject.resume()
        let after = await snapshot()
        XCTAssertEqual(after.state, .idle)
        XCTAssertEqual(engine.count(of: "play"), 0, "无当前项时不得假装播放")
    }

    func testEngineEventsRefineState() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.buffering)
        var after = await snapshot()
        XCTAssertEqual(after.state, .buffering)
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertEqual(after.state, .playing)
        await subject.receive(.paused)
        after = await snapshot()
        XCTAssertEqual(after.state, .paused)
    }

    func testPositionEventsClampAndIgnoreGarbage() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.duration(seconds: 50))
        await subject.receive(.position(seconds: 40))
        var after = await snapshot()
        XCTAssertEqual(after.position, 40)
        await subject.receive(.position(seconds: 999))
        after = await snapshot()
        XCTAssertEqual(after.position, 50, "越界位置由 duration 钳住")
        await subject.receive(.position(seconds: -8))
        after = await snapshot()
        XCTAssertEqual(after.position, 0)
        await subject.receive(.position(seconds: Double.nan))
        after = await snapshot()
        XCTAssertEqual(after.position, 0, "非有限位置不污染状态")
        await subject.receive(.duration(seconds: 0))
        after = await snapshot()
        XCTAssertEqual(after.duration, 50, "非正 duration 不上账")
    }

    // MARK: - 失败连击（design §9「连续 3 次失败停止并提示」）

    func testThreeConsecutiveFailuresEnterTerminalState() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        var after = await snapshot()
        XCTAssertEqual(after.failureStreak, 1)
        XCTAssertEqual(after.item?.id, "b", "失败自动跳下一首")

        await subject.receive(.failed(PlayerFailure(kind: .mediaInvalid)))
        after = await snapshot()
        XCTAssertEqual(after.failureStreak, 2)
        XCTAssertEqual(after.item?.id, "c")

        await subject.receive(.failed(PlayerFailure(kind: .mediaInvalid)))
        after = await snapshot()
        XCTAssertEqual(after.failureStreak, 3)
        XCTAssertEqual(after.state, .stopped)
        XCTAssertTrue(after.isFailureTerminal)
        XCTAssertEqual(after.item?.id, "c", "第 3 次不推进：停在坏项上等待用户处置")
        XCTAssertEqual(after.lastFailure?.kind, .mediaInvalid)
        XCTAssertEqual(engine.count(of: "load"), 3)
        // 终态下再来失败也不越界计数。
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        after = await snapshot()
        XCTAssertEqual(after.failureStreak, 3)
    }

    func testTerminalStateStopsAutoAdvanceButAllowsUserNavigation() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        for _ in 0..<3 { await subject.receive(.failed(PlayerFailure(kind: .network))) }
        var after = await snapshot()
        XCTAssertTrue(after.isFailureTerminal)
        // 终态下不再自动推进（再来 ended 也不动）。
        await subject.receive(.ended)
        after = await snapshot()
        XCTAssertEqual(after.item?.id, "c")
        // 用户显式跳过仍然有效，并在成功播放后清零连击。
        _ = await subject.next()
        after = await snapshot()
        XCTAssertEqual(after.item?.id, "d")
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertFalse(after.isFailureTerminal)
    }

    func testSuccessResetsFailureStreak() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        await subject.receive(.playing)
        var after = await snapshot()
        XCTAssertEqual(after.failureStreak, 0)
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        after = await snapshot()
        XCTAssertEqual(after.failureStreak, 1)
        XCTAssertFalse(after.isFailureTerminal)
    }

    func testCancellationFailureDoesNotCountTowardStreak() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        for _ in 0..<5 { await subject.receive(.failed(PlayerFailure(kind: .cancelled))) }
        let after = await snapshot()
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(after.lastFailure?.kind, .cancelled, "仍保留最后失败供 UI 提示")
        XCTAssertEqual(engine.count(of: "load"), 1, "取消不触发跳曲")
    }

    func testFailureUnderOneStillLeavesCurrentItem() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        await subject.receive(.failed(PlayerFailure(kind: .missingFile)))
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "b", "坏项不得被 .one 无限重试")
    }

    func testPreparerFailureIsClassifiedAndNeverReachesEngine() async {
        let preparer = StubSourcePreparer()
        await preparer.configure(.failWith(.hostRejected))
        let subject = PlaybackCoordinator(engine: engine, clock: clock, sourcePreparer: preparer)
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.lastFailure?.kind, .network)
        XCTAssertEqual(engine.count(of: "load"), 0, "本地化失败绝不能把 Bearer 地址交给引擎")
    }

    // MARK: - D7：未本地化绝不播

    func testBearerItemWithoutPreparerFailsWithLocalizationRequired() async {
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await snapshot()
        XCTAssertEqual(after.lastFailure?.kind, .localizationRequired)
        XCTAssertEqual(engine.count(of: "load"), 0)
    }

    func testLocalizedItemReachesEngine() async {
        let preparer = StubSourcePreparer()
        let subject = PlaybackCoordinator(engine: engine, clock: clock, sourcePreparer: preparer)
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(engine.loads.first?.isReadyToStream, true)
        let calls = await preparer.callCount
        XCTAssertEqual(calls, 1)
    }

    // MARK: - 队列变更

    func testRemoveCurrentKeepsPlayingNextAtSamePosition() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start(at: 1)
        let change = await subject.removeItem(at: 1)
        XCTAssertEqual(change, .applied(.removed(at: 1, remaining: 2, current: 1)))
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "c")
        XCTAssertEqual(after.state, .playing)
    }

    func testRemoveLastItemStopsPlayback() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        _ = await subject.removeItem(at: 0)
        let after = await snapshot()
        XCTAssertEqual(after.state, .stopped)
        XCTAssertNil(after.item)
        XCTAssertEqual(engine.count(of: "release"), 1)
        let clears = await nowPlaying.clearCount
        XCTAssertEqual(clears, 1)
    }

    func testRemoveWhilePausedDoesNotStartPlaying() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start(at: 1)
        await subject.pause()
        _ = await subject.removeItem(at: 1)
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "c")
        XCTAssertEqual(after.state, .paused)
    }

    func testReorderKeepsCurrentTrackPlaying() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        _ = await subject.reorder(from: 0, to: 2)
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "a", "拖拽排序不得换曲")
        XCTAssertEqual(after.index, 2)
        let ids = await subject.queueItems()
        XCTAssertEqual(ids.map(\.id), ["b", "c", "a"])
    }

    func testAppendAndInsertNextReportChanges() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        _ = await subject.appendToQueue(TestItems.make("b"))
        _ = await subject.insertNext(TestItems.make("x"))
        let ids = await subject.queueItems()
        XCTAssertEqual(ids.map(\.id), ["a", "x", "b"])
        let contains = await subject.containsItem(itemID: "x")
        let missing = await subject.containsItem(itemID: "z")
        XCTAssertTrue(contains)
        XCTAssertFalse(missing)
    }

    func testRemoveUnknownItemIsRejectedWithoutSideEffects() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        let change = await subject.removeItem(itemID: "z")
        XCTAssertEqual(change, .rejected(.unknownItem))
        let after = await snapshot()
        XCTAssertEqual(after.queueCount, 2)
    }

    func testReplaceQueueDropsToIdleWhenEmpty() async {
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        _ = await subject.replaceQueue([])
        let after = await snapshot()
        XCTAssertEqual(after.state, .idle)
        XCTAssertNil(after.item)
        XCTAssertEqual(after.queueCount, 0)
    }

    // MARK: - Now Playing 同步与节流（虚拟时钟）

    func testNowPlayingMetadataCarriesTitleArtistDurationElapsedRate() async {
        _ = await subject.replaceQueue([TestItems.make("a", album: "专辑", duration: 120)])
        _ = await subject.start()
        await clock.advance(2)
        await subject.receive(.position(seconds: 33))
        let metadata = await nowPlaying.lastPublished
        XCTAssertEqual(metadata?.title, "曲目-a")
        XCTAssertEqual(metadata?.artist, "艺人")
        XCTAssertEqual(metadata?.album, "专辑")
        XCTAssertEqual(metadata?.duration, 120)
        XCTAssertEqual(metadata?.elapsed, 33)
        XCTAssertEqual(metadata?.playbackRate, 1)
        XCTAssertEqual(metadata?.isPlaying, true)
        XCTAssertNotNil(metadata?.artworkURL)
    }

    func testElapsedTimeSyncIsThrottledButItemChangesAreNot() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = await subject.start()
        let baseline = await nowPlaying.publishCount
        await clock.advance(0.2)
        await subject.receive(.position(seconds: 5))
        await subject.receive(.position(seconds: 6))
        var count = await nowPlaying.publishCount
        XCTAssertEqual(count, baseline, "1s 内纯时间推进被节流")
        await clock.advance(1.1)
        await subject.receive(.position(seconds: 7))
        count = await nowPlaying.publishCount
        XCTAssertEqual(count, baseline + 1, "跨过节流窗口后放行一次")
        await subject.receive(.position(seconds: 8))
        count = await nowPlaying.publishCount
        XCTAssertEqual(count, baseline + 1, "同窗口内再次节流")
        // 换曲 / 状态变更是强制同步，不受节流影响。
        _ = await subject.next()
        let afterChange = await nowPlaying.publishCount
        XCTAssertGreaterThan(afterChange, count, "换曲必须立即刷新锁屏元数据")
    }

    func testPausedStateIsPublished() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.pause()
        let metadata = await nowPlaying.lastPublished
        XCTAssertEqual(metadata?.isPlaying, false)
        XCTAssertEqual(metadata?.playbackRate, 1)
    }

    func testRateClampsToSupportedRange() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        let low = await subject.setPlaybackRate(0.1)
        let high = await subject.setPlaybackRate(9)
        let bogus = await subject.setPlaybackRate(Double.nan)
        XCTAssertEqual(low, 0.5)
        XCTAssertEqual(high, 2)
        XCTAssertEqual(bogus, 2, "非有限速率保持原值")
        let after = await snapshot()
        XCTAssertEqual(after.playbackRate, 2)
        XCTAssertEqual(engine.rates, [1, 0.5, 2], "速率变更同步交给引擎")
    }

    func testClearQueuePublishesClearWhenNoItem() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        _ = await subject.replaceQueue([])
        let clears = await nowPlaying.clearCount
        XCTAssertGreaterThan(clears, 0)
    }

    // MARK: - 会话绑定与释放

    func testGenerationAdvanceDropsPendingReportsAndStopsPlayback() async {
        let authenticated = PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"), generation: .initial)
        await subject.bindSession(authenticated)
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]))
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        await subject.bindSession(
            PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"), generation: authenticated.generation.advanced())
        )
        let after = await snapshot()
        XCTAssertEqual(after.state, .stopped, "换号后不得继续旧账号的播放")
        XCTAssertNil(after.item)
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1, "旧播放不得被误报")
        let pending = await reporter.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(after.session.generation, authenticated.generation.advanced())
    }

    func testBindSessionIsIdempotentForIdenticalContext() async {
        let context = PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"))
        await subject.bindSession(context)
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        await subject.bindSession(context)
        let after = await snapshot()
        XCTAssertEqual(after.state, .playing, "同一会话重复绑定不得打断播放")
    }

    func testTeardownStopsEngineClearsNowPlayingAndRejectsFurtherWork() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.teardown()
        var after = await snapshot()
        XCTAssertEqual(after.state, .idle)
        XCTAssertNil(after.item)
        XCTAssertEqual(engine.releaseCount, 1)
        let teardowns = await nowPlaying.teardownCount
        XCTAssertEqual(teardowns, 1)
        let tornDown = await subject.isTornDown
        XCTAssertTrue(tornDown)
        // 幂等：第二次 teardown 不重复释放。
        await subject.teardown()
        XCTAssertEqual(engine.releaseCount, 1)
        let seek = await subject.seekBySeconds(15)
        XCTAssertEqual(seek, .rejected(.tornDown))
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertEqual(after.state, .idle, "teardown 后引擎事件不得复活播放")
    }

    func testTeardownCancelsPendingReportsWithoutSubmittingThem() async {
        _ = await subject.bindSession(.unauthenticated)
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        var pending = await reporter.pendingCount()
        XCTAssertEqual(pending, 1, "未认证：键已分配并挂起，不静默丢包")
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
        await subject.teardown()
        pending = await reporter.pendingCount()
        XCTAssertEqual(pending, 0, "teardown 丢弃未决上报")
        calls = await submitter.callCount
        XCTAssertEqual(calls, 0, "teardown 不得把未决上报补发出去")
    }

    func testEngineStreamDeliversEventsAfterAttach() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        let baseline = nowPlaying.publishSignal.value
        await subject.attach()
        await subject.attach()
        engine.emit(.duration(seconds: 77))
        let delivered = await Signals.wait(target: baseline + 1, counter: nowPlaying.publishSignal)
        XCTAssertTrue(delivered, "引擎事件必须经流投递到归约入口")
        let after = await snapshot()
        XCTAssertEqual(after.duration, 77)
        XCTAssertEqual(after.state, .playing, "投递不得把播放态打断")
        await subject.detachFromEngine()
        engine.finishStream()
    }

    func testLoginWhilePlayingDoesNotInterruptPendingReportAndKeepsKey() async {
        // 游客态播了一首公开曲库曲目：键已分配并挂起。
        _ = await subject.bindSession(.unauthenticated)
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        let queuedKey = await reporter.activeEpisodeKey()
        XCTAssertNotNil(queuedKey, "未认证不静默丢包：键已分配")
        var calls = await submitter.callCount
        XCTAssertEqual(calls, 0)
        // 登录：不得打断播放，也不得换键；以同一键补发。
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        var after = await snapshot()
        XCTAssertEqual(after.state, .playing, "登录不是登出，不得销毁播放")
        _ = await subject.retryPendingReports()
        calls = await submitter.callCount
        XCTAssertEqual(calls, 1)
        let sent = await submitter.keys
        XCTAssertEqual(sent.first, queuedKey, "补发必须复用同一幂等键")
        after = await snapshot()
        XCTAssertEqual(after.session.owner, PrincipalID(rawValue: "p1"))
    }

    func testSessionGenerationAccessorReflectsBinding() async {
        let context = PlaybackSessionContext(owner: nil, generation: SessionGeneration(value: 7))
        await subject.bindSession(context)
        let generation = await subject.sessionGeneration()
        XCTAssertEqual(generation, SessionGeneration(value: 7))
    }

    func testQueueProjectionExposesIdentityOrder() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        let items = await subject.queueItems()
        XCTAssertEqual(items.map(\.id), ["a", "b"])
        let hasCurrent = await subject.hasCurrentItem()
        XCTAssertTrue(hasCurrent)
    }

    // MARK: - 环 4 修复 R1：状态必须与实际装载一致（缺陷 P1 / P1b / P1c）

    /// 缺陷 P1（评审探针 `ZZReviewProbeTests.swift:51`）：单元素队列在 `.off` 下当前项
    /// `itemFailed` 后，队列数学回绕得到 `.repeated`（无处可跳），而引擎里**从未装载过任何东西**
    /// —— 旧实现据此把状态写成 `.playing`，属于状态谎报。
    func testSingleItemLoadFailureUnderOffNeverClaimsPlaying() async {
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await snapshot()
        XCTAssertEqual(after.lastFailure?.kind, .localizationRequired)
        XCTAssertEqual(engine.count(of: "load"), 0, "需本地化的条目绝不能进引擎（D7）")
        XCTAssertNotEqual(after.state, .playing, "P1：引擎无装载时不得声称正在播")
        XCTAssertEqual(after.state, .stopped, "P1：失败且无可跳目标 → 停止")
        XCTAssertTrue(after.isFailureTerminal, "P1：无处可跳即自动推进停止，等待用户处置（design §9）")
        XCTAssertEqual(engine.count(of: "play"), 0, "P1：绝不得命令引擎出声")
        XCTAssertEqual(engine.count(of: "seek"), 0, "P1：引擎里没有可重播的条目")
        XCTAssertEqual(after.item?.id, "a", "终态仍停在坏项上，供 UI 提示与用户重试")

        _ = await subject.start()
        let retried = await snapshot()
        XCTAssertEqual(retried.state, .stopped, "P1：用户重试再次失败 → 依旧不得谎报播放")
        XCTAssertTrue(retried.isFailureTerminal)
    }

    /// 缺陷 P1b（评审探针 `:60`）：同一谎报在 `.all` 下同样成立（回绕到唯一的那一项）。
    func testSingleItemLoadFailureUnderAllNeverClaimsPlaying() async {
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await snapshot()
        XCTAssertEqual(engine.count(of: "load"), 0)
        XCTAssertNotEqual(after.state, .playing, "P1b：.all 单元素同上，回绕目标就是那个坏项")
        XCTAssertEqual(after.state, .stopped)
        XCTAssertTrue(after.isFailureTerminal)
        XCTAssertEqual(engine.count(of: "play"), 0)
    }

    /// 缺陷 P1b 的同族（`.one`）：`itemFailed` 在 `.one` 下也不得「原地重播」一个从未装载的项。
    func testSingleItemLoadFailureUnderOneNeverClaimsPlaying() async {
        await subject.setLoopMode(.one)
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        _ = await subject.start()
        let after = await snapshot()
        XCTAssertEqual(engine.count(of: "load"), 0)
        XCTAssertEqual(after.state, .stopped, "P1：`.one` 的「重播当前项」只对引擎里真有的项成立")
        XCTAssertTrue(after.isFailureTerminal)
    }

    /// 缺陷 P1c（评审探针 `:71`/`:75`）：两元素队列每一项都装载失败。
    ///
    /// 探针的字面期望「停在 b」与既有锁定裁决冲突（`.off` 末项 `itemFailed` **回绕首项**，
    /// 见 `docs/log/20260921.md` §5.1 与 `PlayQueueTests` 的回绕断言），因此这里钉的是不变量：
    /// 每次失败都离开当前项、连击达上限进入终态、全程不得出现 `.playing`，
    /// 且引擎从未收到 `load` / `play`。（详见日志 §存疑点。）
    func testAllItemsFailingConvergesToTerminalWithoutFakePlaying() async {
        let bad = [
            TestItems.make("a", source: .bearerRequired(TestItems.audioURL())),
            TestItems.make("b", source: .bearerRequired(TestItems.audioURL())),
        ]
        _ = await subject.replaceQueue(bad)
        _ = await subject.start()
        var after = await snapshot()
        XCTAssertEqual(after.failureStreak, 3, "P1c：一次起播内三次失败即达上限（design §9）")
        XCTAssertTrue(after.isFailureTerminal)
        XCTAssertEqual(after.state, .stopped, "P1c：连续失败后不得停留在 .playing")
        XCTAssertNotEqual(after.state, .playing)
        XCTAssertEqual(after.item?.id, "a", "P1c：末项失败回绕首项（既有裁决；与「.off 末项播完即停」不同）")
        XCTAssertEqual(engine.count(of: "load"), 0, "P1c：三次装载全部失败，引擎一次都不该收到")
        XCTAssertEqual(engine.count(of: "play"), 0)

        _ = await subject.start()
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        after = await snapshot()
        XCTAssertTrue(
            after.state == .stopped || after.isFailureTerminal,
            "P1c：终态之后的失败必须停在终态（实际 state=\(after.state) streak=\(after.failureStreak)）"
        )
        XCTAssertEqual(after.failureStreak, 3, "P1c：终态后来失败也不越界计数")
        XCTAssertEqual(engine.count(of: "play"), 0)
    }

    /// 新不变量 R1（把 P1 家族收敛成一条可普遍断言的规则）：
    /// **状态声称 `.playing` ⟹ 引擎里实际装载着当前项**。正向路径逐条对照，不得误红。
    func testPlayingStateIsAlwaysBackedByTheItemLoadedInTheEngine() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        await assertPlayingIsBackedByEngine("起播")
        _ = await subject.next()
        await assertPlayingIsBackedByEngine("显式下一首")
        await subject.receive(.ended)
        await assertPlayingIsBackedByEngine("播完自动推进")
        await subject.pause()
        await subject.resume()
        await assertPlayingIsBackedByEngine("暂停后续播")
        await subject.setLoopMode(.one)
        await subject.receive(.ended)
        await assertPlayingIsBackedByEngine(".one 重播当前项")
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        await assertPlayingIsBackedByEngine("播放中失败 → 跳下一首")
        _ = await subject.previous()
        await assertPlayingIsBackedByEngine("显式上一首")
    }

    /// R1 的断言原语：只有 `.playing` 参与判定（其余状态本就未声称在播）。
    private func assertPlayingIsBackedByEngine(_ scene: String) async {
        let snap = await snapshot()
        guard snap.state == .playing else { return }
        XCTAssertEqual(
            engine.loads.last?.id, snap.item?.id,
            "R1：\(scene) 后状态为 .playing，但引擎装载的不是当前项（loads=\(engine.loads.map(\.id))）"
        )
    }

    // MARK: - 环 4 修复 R2：装载代际（缺陷 P2）

    /// 缺陷 P2（评审探针 `:103`）：A 的装载在途时用户 skip 到 B，迟到的 A 装载回写
    /// 把引擎与状态又覆盖回 A（`loads == ["b","a"]`）。修复 = 装载代际守卫。
    func testStaleLoadInFlightCannotOverwriteEngineAfterUserSkips() async {
        let preparer = GatedSourcePreparer(gating: ["a"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：A 的本地化未进入在途，用例无从验证过期回写")

        let skip = await subject.next()
        guard case .advanced(to: let index, item: let item, _) = skip else {
            return XCTFail("next 应前进到 b，实际 \(skip)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(item.id, "b")
        XCTAssertEqual(engine.loads.map(\.id), ["b"], "B 的装载应在 A 仍挂起时完成")

        let returnedBefore = await preparer.returnedCount()
        await preparer.release("a")
        let returned = await Signals.wait(target: returnedBefore + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置：A 的在途装载未返回")
        // 确定性屏障：向同一 actor 再投一条消息。过期续体在 `release()` 时已排在它之前
        // （actor 的作业按入队顺序串行执行），故本调用返回即代表过期回写已被处理完 —— 不做时间猜测（D16⑤）。
        await subject.pause()

        let loads = engine.loads.map(\.id)
        let after = await subject.currentSnapshot()
        XCTAssertEqual(loads, ["b"], "P2：过期的 A 装载绝不得回写引擎")
        XCTAssertEqual(after.item?.id, "b")
        XCTAssertEqual(after.state, .paused, "P2：迟到回写也不得把状态改回 .playing/.loading")
        let outcome = await startTask.value
        XCTAssertEqual(
            outcome, .advanced(to: 1, item: TestItems.make("b"), wrapped: false),
            "P2：被取代的 start() 结果必须反映真实落点，而不是在途前捕获的 A"
        )
    }

    /// 缺陷 P2 的同族：迟到的 A **失败**也不得计入新集次（否则用户换曲白扣一次连击）。
    func testStaleLoadFailureAfterSkipIsDiscardedEntirely() async {
        let preparer = GatedSourcePreparer(gating: ["a"], failing: ["a": .hostRejected])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        _ = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：A 的本地化未进入在途")
        _ = await subject.next()
        var after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(after.failureStreak, 0)

        let returnedBefore = await preparer.returnedCount()
        await preparer.release("a")
        let returned = await Signals.wait(target: returnedBefore + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置：A 的在途装载未返回")
        await subject.pause()

        after = await subject.currentSnapshot()
        XCTAssertEqual(after.failureStreak, 0, "P2：过期装载的失败不得计入新集次的连击")
        XCTAssertNil(after.lastFailure, "P2：过期失败不得污染 lastFailure")
        XCTAssertEqual(after.item?.id, "b")
        XCTAssertEqual(engine.loads.map(\.id), ["b"])
    }

    /// R2 的正向对照（TD-9）：没有换曲时，装载照常回写（闸门不得把正常路径也关掉）。
    func testUninterruptedLoadStillWritesBackNormally() async {
        let preparer = GatedSourcePreparer(gating: ["a"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：A 的本地化未进入在途")
        await preparer.release("a")
        let outcome = await startTask.value
        XCTAssertEqual(outcome, .advanced(to: 0, item: TestItems.make("a"), wrapped: false))
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .playing, "R2：未被取代的装载必须照常进入播放态")
        XCTAssertEqual(engine.loads.map(\.id), ["a"])
        XCTAssertEqual(engine.count(of: "play"), 1)
    }

    // MARK: - 环 4 修复 R3：teardown 是终态（缺陷 P3）

    /// 缺陷 P3（评审探针 `:114`/`:115`/`:117`）：teardown 之后的队列变更把播放器「复活」
    /// —— 状态变 `.loading`、队列非空、仍存在当前项。
    func testQueueReplacementAfterTeardownIsRejectedAndKeepsPlayerDead() async {
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        await subject.teardown()

        let change = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        XCTAssertEqual(change, .rejected(.tornDown), "P3：teardown 后队列变更必须被拒绝")
        let after = await snapshot()
        XCTAssertEqual(after.state, .idle, "P3：teardown 后队列变更不得把状态打成 loading")
        XCTAssertEqual(after.queueCount, 0, "P3：teardown 后队列必须保持为空")
        let hasCurrent = await subject.hasCurrentItem()
        XCTAssertFalse(hasCurrent, "P3：teardown 后不得存在当前项")
        let items = await subject.queueItems()
        XCTAssertTrue(items.isEmpty)
        let publishes = await nowPlaying.publishCount
        XCTAssertEqual(publishes, 0, "P3：teardown 后不得再发布锁屏元数据")
    }

    /// 缺陷 P3（同族，覆盖面更宽）：**所有**队列与偏好变更入口在 teardown 之后一律拒绝且不改状态。
    func testEveryMutationEntryAfterTeardownIsRejected() async {
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]))
        await subject.teardown()
        let callsBefore = engine.callCount

        let append = await subject.appendToQueue(TestItems.make("c"))
        let insert = await subject.insertNext(TestItems.make("d"))
        let reorder = await subject.reorder(from: 0, to: 1)
        let remove = await subject.removeItem(at: 0)
        let removeByID = await subject.removeItem(itemID: "a")
        let mode = await subject.setLoopMode(.all)
        let cycled = await subject.cycleLoopMode()
        let rate = await subject.setPlaybackRate(2)
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p9")))
        let retried = await subject.retryPendingReports()

        XCTAssertEqual(append, .rejected(.tornDown))
        XCTAssertEqual(insert, .rejected(.tornDown))
        XCTAssertEqual(reorder, .rejected(.tornDown))
        XCTAssertEqual(remove, .rejected(.tornDown))
        XCTAssertEqual(removeByID, .rejected(.tornDown))
        XCTAssertEqual(mode, .off, "P3：teardown 后偏好设置也不得再改动状态")
        XCTAssertEqual(cycled, .off)
        XCTAssertEqual(rate, 1)
        XCTAssertTrue(retried.isEmpty, "P3：teardown 后不得再补发上报")

        let after = await snapshot()
        XCTAssertEqual(after.state, .idle)
        XCTAssertEqual(after.queueCount, 0)
        XCTAssertEqual(after.loopMode, .off)
        XCTAssertEqual(after.playbackRate, 1)
        XCTAssertNil(after.session.owner, "P3：teardown 后绑定会话不得改写状态账")
        XCTAssertEqual(engine.callCount, callsBefore, "P3：teardown 后引擎不得再收到任何调用")
        let publishes = await nowPlaying.publishCount
        XCTAssertEqual(publishes, 0)
    }

    /// 缺陷 P3（同族）：teardown 后的传输 / 导航 / 事件入口同样不得复活播放器。
    func testTransportAndEventEntriesAfterTeardownDoNotRevivePlayer() async {
        _ = await subject.start(items: TestItems.makeMany(["a", "b", "c"]))
        await subject.teardown()
        let callsBefore = engine.callCount

        let start = await subject.start()
        let startIndex = await subject.start(at: 1)
        let startItems = await subject.start(items: TestItems.makeMany(["x", "y"]))
        let next = await subject.next()
        let previous = await subject.previous()
        let toggle = await subject.toggle()
        await subject.resume()
        await subject.pause()
        await subject.receive(.playing)
        await subject.receive(.ended)
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        await subject.attach()

        XCTAssertEqual(start, .rejected(.tornDown))
        XCTAssertEqual(startIndex, .rejected(.tornDown))
        XCTAssertEqual(startItems, .rejected(.tornDown))
        XCTAssertEqual(next, .rejected(.tornDown), "P3：teardown 后导航必须显式拒绝，而不是伪装成空队列")
        XCTAssertEqual(previous, .rejected(.tornDown))
        XCTAssertEqual(toggle, .idle)

        let after = await snapshot()
        XCTAssertEqual(after.state, .idle, "P3：teardown 是终态")
        XCTAssertEqual(after.queueCount, 0)
        let hasCurrent = await subject.hasCurrentItem()
        XCTAssertFalse(hasCurrent)
        XCTAssertEqual(engine.callCount, callsBefore, "P3：teardown 后引擎不得再收到任何调用")
        let publishes = await nowPlaying.publishCount
        XCTAssertEqual(publishes, 0)
    }

    /// R3 的正向对照（TD-9）：未 teardown 时同样的入口都照常工作（闸门不得把活路径打死）。
    func testMutationEntriesWorkNormallyBeforeTeardown() async {
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]))
        let append = await subject.appendToQueue(TestItems.make("c"))
        let insert = await subject.insertNext(TestItems.make("d"))
        var after = await snapshot()
        XCTAssertEqual(append, .applied(.appended(at: 2)))
        XCTAssertEqual(insert, .applied(.insertedNext(at: 1)))
        XCTAssertEqual(after.queueCount, 4)
        _ = await subject.next()
        _ = await subject.setLoopMode(.all)
        after = await snapshot()
        XCTAssertEqual(after.loopMode, .all)
        XCTAssertEqual(after.item?.id, "d")
        XCTAssertEqual(engine.loads.map(\.id), ["a", "d"])
        XCTAssertFalse(after.isFailureTerminal)
    }

    /// R1 的另一条腿：`replaceQueue` 之后 `resume()` 必须**真装载**，而不是直接命令引擎出声。
    /// （缺陷 P1 的同族：换队未播时按锁屏 ⏯，旧实现把状态写成 `.playing` 而引擎里是空手。）
    func testResumeAfterQueueReplacementLoadsInsteadOfClaimingPlaying() async {
        _ = await subject.replaceQueue([TestItems.make("a", source: .bearerRequired(TestItems.audioURL()))])
        await subject.resume()
        var after = await snapshot()
        XCTAssertEqual(after.state, .stopped, "R1：没有本地化器时 resume 不得假装播放")
        XCTAssertEqual(engine.count(of: "play"), 0)
        XCTAssertEqual(engine.count(of: "load"), 0)

        let preparer = StubSourcePreparer()
        let live = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await live.replaceQueue([TestItems.make("b", source: .bearerRequired(TestItems.audioURL()))])
        await live.resume()
        after = await live.currentSnapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(engine.loads.map(\.id), ["b"], "R1：进入 .playing 的前提是引擎真的装载了它")
    }

    // MARK: - 环 4 修复 R4：按装载代际丢弃迟到事件（缺陷 P4）

    /// 缺陷 P4（评审探针 `:132`）：下一首已经开播之后才到达的**上一首的 ended** 又推进了一次，
    /// 队列白跳一首。
    ///
    /// 口径说明（详见 `docs/log/20260921.md` §存疑点）：探针用裸 `receive(.ended)` 连投两条，
    /// 那条口径与既有永久测试 `testItemEndUnderOffWalksThenStops` /
    /// `testItemEndUnderAllWrapsToFirst` 直接冲突 —— 协调器收到的裸 ended 不带归因，
    /// 无法区分「当前项真的播完」与「旧项迟到」，按状态丢弃会误杀正常推进。
    /// 归因事实只存在于引擎侧，所以守卫落在 `EngineEventGate`：过期代际的事件
    /// **根本进不了事件流**。本用例跑的是真实接线（`attach` + `AsyncStream` + 同一闸门）。
    func testLateEndedFromPreviousLoadEpisodeDoesNotSkipExtraTrack() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        await subject.attach()
        _ = await subject.start()
        let episodeOfA = engine.currentEpisode
        let baseline = await nowPlaying.publishCount

        XCTAssertTrue(engine.emitObserved(.ended, from: episodeOfA), "当前代的 ended 必须投递")
        let advanced = await Signals.wait(target: baseline + 1, counter: nowPlaying.publishSignal)
        XCTAssertTrue(advanced, "前置：第一条 ended 未被消费")
        // 排干前置（**本轮加固**，见日志）：「多了一次发布」只证明装载**开始**了 ——
        // `loadCurrent` 每次装载恰好强制同步两次（`.loading` 一次、落地一次），等满两次才代表
        // 它真的返回、引擎才真的被交给 B（`currentEpisode` 也随之推进）。HEAD 上这条用例
        // 在 400 迭代里于两处不同断言上各红过，同一个歧义屏障是根因（非本轮引入）。
        let loadLanded = await Signals.wait(target: baseline + 2, counter: nowPlaying.publishSignal)
        let landedCount = await nowPlaying.publishCount
        XCTAssertTrue(loadLanded, "前置：B 的装载未落地（发布 \(landedCount) < \(baseline + 2)）")
        var after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        let episodeOfB = engine.currentEpisode
        XCTAssertNotEqual(episodeOfB, episodeOfA, "换件必须推进装载代际")

        // A 的迟到 ended（通知已在别的线程排队，removeObserver 拦不住那一条）
        XCTAssertFalse(
            engine.emitObserved(.ended, from: episodeOfA),
            "P4：已被取代的条目不得再投递 ended"
        )
        // 正向屏障：随后一条当代事件必然排在被丢弃者之后被消费（AsyncStream 严格 FIFO），
        // 它被处理完即证明「迟到 ended 已经错过它的机会」—— 不做任何时间猜测（D16⑤）。
        // 此刻装载已排干，`publishCount + 1` 只可能来自这条屏障事件。
        let barrier = await nowPlaying.publishCount
        XCTAssertTrue(engine.emitObserved(.duration(seconds: 77), from: episodeOfB))
        let settled = await Signals.wait(target: barrier + 1, counter: nowPlaying.publishSignal)
        XCTAssertTrue(settled, "前置：屏障事件未被消费")

        after = await snapshot()
        XCTAssertEqual(after.item?.id, "b", "P4：迟到的 ended 不得让队列多跳一首")
        XCTAssertNotEqual(after.item?.id, "c")
        XCTAssertEqual(after.duration, 77, "屏障事件确实已被归约")
        XCTAssertEqual(after.state, .playing, "P4：留在 B 上继续播，而不是被伪造成推进")
        await subject.detachFromEngine()
        engine.finishStream()
    }

    /// 缺陷 P4 的第二形态：同一装载代际内的重复 ended（边界观察者 + playToEnd 双发）。
    func testDuplicateEndedWithinSameLoadEpisodeIsDeliveredOnce() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        let episode = engine.currentEpisode
        XCTAssertTrue(engine.emitObserved(.ended, from: episode))
        XCTAssertFalse(
            engine.emitObserved(.ended, from: episode),
            "P4：同一代至多一条 ended —— 第二次是重复上报"
        )
        XCTAssertFalse(engine.emitObserved(.ended, from: episode))
        // 换件即重新起算（下一首的播完是另一件事）。
        _ = await subject.next()
        XCTAssertTrue(
            engine.emitObserved(.ended, from: engine.currentEpisode),
            "P4：新代的 ended 必须照常放行（闸门不得把正常推进也关掉）"
        )
    }

    /// 迟到的**位置**上报同样不得污染新集次（同一闸门覆盖全部观测者事件）。
    func testLatePositionFromReplacedEpisodeCannotMovePlayhead() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        await subject.attach()
        _ = await subject.start()
        let episodeOfA = engine.currentEpisode
        _ = await subject.next()
        let episodeOfB = engine.currentEpisode
        XCTAssertFalse(engine.emitObserved(.position(seconds: 98), from: episodeOfA))
        let barrier = await nowPlaying.publishCount
        XCTAssertTrue(engine.emitObserved(.duration(seconds: 40), from: episodeOfB))
        let settled = await Signals.wait(target: barrier + 1, counter: nowPlaying.publishSignal)
        XCTAssertTrue(settled, "前置：屏障事件未被消费")
        let after = await snapshot()
        XCTAssertEqual(after.item?.id, "b")
        XCTAssertEqual(after.position, 0, "P4：旧项迟到的位置上报不得把新项的进度条挪走")
        await subject.detachFromEngine()
        engine.finishStream()
    }

    // MARK: - 环 4 修复 R6：teardown 时本地化在途（缺陷 C1）

    /// 缺陷 C1（Critical）：teardown 时私有音频本地化仍在途 —— 旧实现在 `prepareSource` 返回后
    /// **不复核生命周期**，于是「释放之后」真的装载 + 起播，快照谎报 `playing`。
    /// 既有测试只钉了事件侧（`testTeardownStopsEngineClearsNowPlayingAndRejectsFurtherWork`），
    /// 本用例钉的是「在途装载回写侧」：引擎一次调用都不许多收到。
    func testInFlightLocalizationCompletingAfterTeardownNeitherLoadsNorStarts() async {
        let preparer = GatedSourcePreparer(gating: ["priv"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        )
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：本地化未进入在途，本用例无从验证释放后的迟到回写")

        await subject.teardown()
        let returnedBefore = await preparer.returnedCount()
        await preparer.release("priv")
        let returned = await Signals.wait(target: returnedBefore + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置：在途装载未返回")
        _ = await startTask.value

        let loads = engine.loads
        let calls = engine.calls
        XCTAssertTrue(loads.isEmpty, "C1：释放后迟到的本地化结果绝不得装载引擎（calls=\(calls)）")
        XCTAssertEqual(engine.count(of: "play"), 0, "C1：绝不得命令引擎出声")
        XCTAssertEqual(engine.count(of: "setRate"), 0, "C1：速率设置也属于复活链路的一部分")
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .idle, "C1：快照不得谎报 playing")
        XCTAssertNil(after.item, "C1：释放后不应存在当前项")
        XCTAssertEqual(engine.count(of: "release"), 1, "C1：teardown 的释放恰好一次")
    }

    /// C1 的同族：teardown 之后迟到的**失败**也不得留下任何账（连击 / lastFailure / 状态）。
    func testLateLocalizationFailureAfterTeardownLeavesNoTrace() async {
        let preparer = GatedSourcePreparer(gating: ["priv"], failing: ["priv": .hostRejected])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        )
        _ = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：本地化未进入在途")
        await subject.teardown()
        let returnedBefore = await preparer.returnedCount()
        await preparer.release("priv")
        let returned = await Signals.wait(target: returnedBefore + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置：在途装载未返回")

        let after = await subject.currentSnapshot()
        XCTAssertNil(after.lastFailure, "C1：释放后的迟到失败不得污染账本")
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertEqual(after.state, .idle)
    }

    // MARK: - 环 4 修复 R7：单曲循环的每一次播放都要上报（缺陷 P5）

    /// 缺陷 P5：`.one` 下 N 次完整播放旧实现只上报 1 次（`apply(.repeated)` 不关闭集次）
    /// → 与 api-contracts §5「一次实际播放一个幂等键」的**少报**偏差。
    func testLoopOneReplayReportsEveryPlayWithFreshKey() async {
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        var keys = await submitter.keys
        XCTAssertEqual(keys.count, 1, "首次起播上报一次")
        guard let firstKey = keys.first else { return XCTFail("首次起播必须已产生幂等键") }

        for round in 2...3 {
            await subject.receive(.ended)
            let after = await snapshot()
            XCTAssertEqual(after.state, .playing, ".one 重播后仍在播")
            XCTAssertEqual(engine.count(of: "load"), 1, ".one 不重新装载（既有裁决）")
            keys = await submitter.keys
            XCTAssertEqual(keys.count, round, "P5：第 \(round) 次完整播放必须各上报一次")
            XCTAssertEqual(Set(keys).count, round, "P5：每次播放一个**新**幂等键")
            XCTAssertNotEqual(keys.last, firstKey)
        }
        let trackIDs = await submitter.trackIDs
        XCTAssertEqual(trackIDs, ["a", "a", "a"], "同一曲目的重复播放都算实际播放")
    }

    /// R7 的边界（不得过度上报）：暂停/续播是同一集次，不产生第二次上报。
    func testPauseResumeUnderLoopOneStillReportsOncePerEpisode() async {
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        await subject.setLoopMode(.one)
        _ = await subject.start()
        await subject.pause()
        await subject.resume()
        await subject.pause()
        await subject.resume()
        let keys = await submitter.keys
        XCTAssertEqual(keys.count, 1, "pause/resume 复用同一集次（既有裁决不得退化）")
    }

    // MARK: - 环 4 修复 R8：引擎就绪不得翻回播放（缺陷 M10 协调器侧）

    /// 缺陷 M10：用户显式暂停后，引擎的「就绪 / 缓冲恢复」事件把状态翻回 `.playing`
    /// 并向锁屏发布 `isPlaying = true`。修复 = 采信条件（状态 + 引擎装载，两者都要）。
    func testExplicitPauseIsNotOverturnedByEngineReadyEvents() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.pause()
        var after = await snapshot()
        XCTAssertEqual(after.state, .paused)

        await subject.receive(.playing)
        await subject.receive(.buffering)
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertEqual(after.state, .paused, "M10：暂停必须在连续就绪事件后仍然成立")
        let published = await nowPlaying.lastPublished
        XCTAssertEqual(published?.isPlaying, false, "M10：锁屏不得收到 isPlaying=true")

        // 正向对照（TD-9）：用户 resume 之后就绪事件照常采信。
        await subject.resume()
        await subject.receive(.buffering)
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertEqual(after.state, .playing, "M10：闸门不得把活路径也关掉")
    }

    /// R1 的另一半：`.loading` 状态下引擎里还没有装载当前项时，就绪事件也不得声称在播。
    ///
    /// F-7 改了一处**前置**期望：整队替换后没有任何装载在途，因此状态是「已选曲、待播」
    /// （`.paused`）而不是 `.loading`（枚举定义 = 正在装载当前项）。本用例的**断言强度不变**：
    /// 引擎没持有当前项时，就绪事件依旧不得伪造播放。
    func testReadyEventCannotClaimPlayingWhileNothingIsLoadedInTheEngine() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        var after = await snapshot()
        XCTAssertEqual(after.state, .paused, "F-7 前置：整队替换后无装载在途 → 不再是 .loading")
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertNotEqual(after.state, .playing, "R1：引擎未装载当前项时就绪事件不得伪造播放")
        XCTAssertEqual(after.state, .paused)
    }

    // MARK: - 环 4 · 状态机组 R9：续体守卫（缺陷 F-1 … F-8）

    /// F-1（Major，评审探针 `testA01`/`testA02`；反向对照 `testA03` 绿 ⇒ 窗口缺陷）：
    /// 用户显式 `pause()` 落在装载在途的窗口里时，装载续体把暂停翻回 `.playing`
    /// 并向锁屏发布 `isPlaying = true`。上一轮只封了事件路径（M10），装载续体这条路径仍开放。
    ///
    /// 修复口径：装载续体必须过 `continuationIsCurrent`（代际 + 引擎归属 + **用户意图**）。
    /// 暂停**不作废**装载本身 —— 条目照常进引擎，只是不命令出声、不上报这一集次。
    func testPauseDuringInFlightLoadIsNotOverturnedByTheLoadContinuation() async {
        let preparer = GatedSourcePreparer(gating: ["priv"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, reporter: reporter, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        // 认证会话：让「上报」真的会提交（未认证时是挂起，0 次提交就不构成证据）。
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        )
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：本地化未进入在途，本用例无从验证续体翻状态")
        var mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.state, .loading, "前置：此刻确实有装载在途")

        await subject.pause()
        mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.state, .paused)

        // 放行 → 装载续体回来。`start()` 返回即是屏障：它只能在续体跑完之后返回（同一 actor）。
        let returnedBefore = await preparer.returnedCount()
        await preparer.release("priv")
        let returned = await Signals.wait(target: returnedBefore + 1, counter: preparer.returnedSignal)
        XCTAssertTrue(returned, "前置：在途装载未返回")
        _ = await startTask.value

        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .paused, "F-1：在途装载不得把用户的暂停翻回播放")
        XCTAssertEqual(after.item?.id, "priv")
        XCTAssertEqual(engine.count(of: "play"), 0, "F-1：暂停中的装载绝不命令引擎出声")
        let submitted = await submitter.callCount
        XCTAssertEqual(submitted, 0, "F-1：没有播放就不许上报这一集次")
        let published = await nowPlaying.lastPublished
        XCTAssertEqual(published?.isPlaying, false, "F-1：锁屏不得收到 isPlaying=true")
        XCTAssertEqual(engine.loads.map(\.id), ["priv"], "F-1：装载本身照常完成（暂停 ≠ 作废装载）")

        // 正向对照（TD-9）：闸门不得把活路径也关掉 —— 续播直接出声，且不必重新装载。
        await subject.resume()
        let resumed = await subject.currentSnapshot()
        XCTAssertEqual(resumed.state, .playing, "F-1：用户恢复后照常播放")
        XCTAssertEqual(engine.count(of: "load"), 1, "F-1：暂停保留已完成的装载")
        XCTAssertEqual(engine.count(of: "play"), 1)
    }

    /// F-2（Major，评审探针 `testB01`/`testB02`：一次 skip 实测跳了两首、失败扣在新曲头上）：
    /// 迟到的 `.failed` **完全无归因** —— `EngineEventGate` 的代际只在 `engine.load` 真正发生时
    /// 推进，`prepareSource` 挂起期间旧项事件照样过闸，协调器侧又什么都不比对。
    ///
    /// 修复口径：守卫 (a)(b) —— 引擎还没被交给当代条目时，它上报的失败必然属于
    /// 已被取代的那一件 → 整条丢弃（不计数、不污染 lastFailure、不跳曲）。
    func testLateFailureWhileNextLoadIsPreparingNeitherSkipsTwiceNorChargesNewEpisode() async {
        let preparer = GatedSourcePreparer(gating: ["b"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start()
        var before = await subject.currentSnapshot()
        XCTAssertEqual(before.item?.id, "a", "前置：a 已装载并在播")

        let nextTask = Task { await subject.next() }
        let opened = await Signals.wait(target: 2, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：b 的装载未进入在途（引擎里装的还是 a）")

        // a 的迟到失败：此刻引擎从未见过 b（`prepareSource` 仍挂起）。
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        await preparer.release("b")
        let outcome = await nextTask.value

        XCTAssertEqual(
            outcome, .advanced(to: 1, item: TestItems.make("b"), wrapped: false),
            "F-2：一次 skip 只能跳一首"
        )
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.item?.id, "b", "F-2：迟到的失败不得把队列再推一格")
        XCTAssertEqual(after.index, 1)
        XCTAssertNotEqual(after.item?.id, "c")
        XCTAssertEqual(after.failureStreak, 0, "F-2：旧项的迟到失败不得扣到新曲头上")
        XCTAssertNil(after.lastFailure, "F-2：不得污染 lastFailure（UI 提示会张冠李戴）")
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(engine.loads.map(\.id), ["a", "b"], "F-2：不得为伪失败去装载 c")
        before = await subject.currentSnapshot()
        XCTAssertEqual(before.queueCount, 3, "F-2：队列本身不被触碰")
    }

    /// F-3（Major，评审探针 `testC02`/`testC03`）：`apply(.moved)` 用 step 捕获的旧 `index`
    /// 却重新读 `queue.current` → 返回 `.advanced(to: 1, item: c)` 而 c 实际在 index 2。
    /// P2 修好了 `beginCurrentIndex`，`.moved` 漏改；锁屏收到「成功 + 错误落点」（UI 高亮错行）。
    ///
    /// 修复口径：落点一律按**当下队列**投影（`advanceOutcome`），且 `to:` 与 `item:` 同刻读取。
    func testAdvancedOutcomeAgreesWithLiveSnapshotWhenQueueMovesUnderTheLoad() async {
        let preparer = GatedSourcePreparer(gating: ["b"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.start(items: TestItems.makeMany(["a", "b", "c", "d"]))
        let nextTask = Task { await subject.next() }
        let opened = await Signals.wait(target: 2, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：b 的装载未进入在途")

        // 重入：装载在途期间用户直接落到 d（B 的装载就此作废）。
        let moved = await subject.start(at: 3)
        XCTAssertEqual(moved, .advanced(to: 3, item: TestItems.make("d"), wrapped: false))
        await preparer.release("b")
        let outcome = await nextTask.value

        let snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.index, 3, "前置：真实落点是 d")
        XCTAssertEqual(snap.item?.id, "d")
        guard case .advanced(to: let index, item: let item, let wrapped) = outcome else {
            return XCTFail("落点确实前进到了 d，应回 `.advanced`：\(outcome)")
        }
        XCTAssertEqual(index, snap.index, "F-3：`to:` 必须等于同一时刻快照的 index")
        XCTAssertEqual(item.id, snap.item?.id, "F-3：`item:` 必须等于同一时刻快照的 item")
        XCTAssertFalse(wrapped)
        XCTAssertEqual(outcome, .advanced(to: 3, item: TestItems.make("d"), wrapped: false))
    }

    /// F-3 + F-4 的合流（评审探针 `testC03`）：装载链上的**嵌套失败**会让外层 `.moved`
    /// 拿着 step 的旧索引回吐 `.advanced`，而链的终点其实是「停止 + 终态」。
    func testNestedLoadFailuresSurfaceAsStoppedNotAsAMismatchedLandingPoint() async {
        let bad = ["a", "b", "c", "d"].map {
            TestItems.make($0, source: .bearerRequired(TestItems.audioURL()))
        }
        _ = await subject.replaceQueue(bad)
        let outcome = await subject.next()

        let snap = await snapshot()
        XCTAssertEqual(snap.index, 3)
        XCTAssertEqual(snap.item?.id, "d", "三次装载失败 → 连击达上限，停在最后一项等待处置")
        XCTAssertEqual(snap.failureStreak, 3)
        XCTAssertEqual(snap.state, .stopped)
        XCTAssertTrue(snap.isFailureTerminal)
        XCTAssertEqual(engine.count(of: "load"), 0, "需本地化而无本地化器：一次都不许进引擎")
        XCTAssertEqual(
            outcome, .stopped,
            "F-3/F-4：链上失败收敛为终态时不得回吐 `.advanced(to: 1, item: d)` 这种错行落点"
        )
    }

    /// F-4（Major，评审探针 `testC01`）：已收敛为 `.stopped` + 失败终态时 `start()` 仍返回
    /// `.advanced(to: 0, item: a)`。P1 堵住了「状态谎报」，「**结果值谎报**」在上一层。
    func testStartOnFailureTerminalQueueReportsStoppedInsteadOfAdvanced() async {
        let bad = [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        _ = await subject.replaceQueue(bad)

        let first = await subject.start()
        var snap = await snapshot()
        XCTAssertEqual(snap.state, .stopped, "前置：单元素队列无处可跳 → 停止")
        XCTAssertTrue(snap.isFailureTerminal)
        XCTAssertEqual(first, .stopped, "F-4：装载链收敛为终态时 start() 不得回吐 .advanced")

        // 用户重试（design §9 的处置路径）：再次失败 → 依旧是 `.stopped`，不是 `.advanced(to: 0)`。
        let retry = await subject.start()
        XCTAssertEqual(retry, .stopped, "F-4：重试仍失败必须如实回 .stopped")
        snap = await snapshot()
        XCTAssertEqual(snap.state, .stopped)
        XCTAssertTrue(snap.isFailureTerminal)
        XCTAssertEqual(snap.item?.id, "priv", "终态仍停在坏项上供 UI 提示（既有裁决不得退化）")

        // 正向对照（TD-9）：装得上的时候必须照旧回 `.advanced`，且与快照同刻自洽。
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        let ok = await subject.start()
        snap = await snapshot()
        XCTAssertEqual(ok, .advanced(to: 0, item: TestItems.make("a"), wrapped: false))
        XCTAssertEqual(snap.state, .playing)
        if case .advanced(to: let index, item: let item, _) = ok {
            XCTAssertEqual(index, snap.index, "F-3：成功路径的落点同样与快照自洽")
            XCTAssertEqual(item.id, snap.item?.id)
        } else {
            XCTFail("成功起播应回 `.advanced`：\(ok)")
        }
    }

    /// F-5（Major，评审探针 `testD01`）：装载在途时 `seek(toTarget:)` 没有代际 / 引擎账本判据
    /// → 把跳转写进仍装着旧条目的引擎，且快照 position 谎报（装载完成后引擎从 0 起播，
    /// position 却停在 42）。
    func testSeekDuringInFlightLoadIsRejectedAndNeverWritesIntoStaleEngine() async {
        let preparer = GatedSourcePreparer(gating: ["priv"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL())), TestItems.make("b")]
        )
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：装载未进入在途")

        let rejected = await subject.seek(to: 42)
        XCTAssertEqual(rejected, .rejected(.noCurrentItem), "F-5：当前项尚未进引擎 → 此刻无从跳转")
        XCTAssertTrue(engine.seeks.isEmpty, "F-5：绝不把 seek 写进仍装着旧条目的引擎")
        var mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.position, 0, "F-5：快照不得谎报进度")

        await preparer.release("priv")
        _ = await startTask.value
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.item?.id, "priv")
        XCTAssertEqual(after.state, .playing)
        XCTAssertEqual(after.position, 0, "F-5：装载完成后引擎从 0 起播，进度必须如实")
        XCTAssertTrue(engine.seeks.isEmpty)

        // 正向对照（TD-9）：装载落地后同样的跳转照常生效（闸门不得把活路径关掉）。
        let ok = await subject.seek(to: 42)
        XCTAssertEqual(ok, .applied(position: 42, clamped: .none, then: nil))
        XCTAssertEqual(engine.seeks, [42])
        mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.position, 42)
    }

    /// F-6（Minor）：成功装载**不得**归零 `failureStreak` —— design §9 的「连续」数的是
    /// 连续失败的曲目，装载成功 ≠ 播放成功（归零会让 `testThreeConsecutiveFailures…`
    /// 那种「三项各自装载成功、播放全部失败」的既定裁决永远到不了上限，属**非缺陷**，
    /// 详见日志 F-6 段）。真正错的是终态**标记**：恢复装载已经成功，决策层还在谎报终态。
    func testSuccessfulRecoveryLoadClearsTerminalFlagWithoutBreakingFailureRun() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        for _ in 0..<3 { await subject.receive(.failed(PlayerFailure(kind: .network))) }
        var snap = await snapshot()
        XCTAssertTrue(snap.isFailureTerminal, "前置：连续 3 次失败进入终态")
        XCTAssertEqual(snap.state, .stopped)

        // 用户显式跳下一首：装载成功（引擎真的装着 d）→ 终态标记必须随之解除。
        let outcome = await subject.next()
        snap = await snapshot()
        XCTAssertEqual(snap.item?.id, "d")
        XCTAssertEqual(snap.state, .playing)
        XCTAssertEqual(outcome, .advanced(to: 3, item: TestItems.make("d"), wrapped: false))
        XCTAssertFalse(
            snap.isFailureTerminal,
            "F-6：恢复装载已成功，决策层不得继续声称自动推进已停止"
        )
        XCTAssertEqual(
            snap.failureStreak, 3,
            "F-6：连击的「连续」只在引擎确认播放时断开 —— 装载成功不算播成功"
        )
        await subject.receive(.playing)
        snap = await snapshot()
        XCTAssertEqual(snap.failureStreak, 0, "引擎确认播放 → 连击归零（既有裁决不得退化）")
    }

    /// F-7（Minor）：`replaceQueue` 置 `.loading` 却无任何装载在途，与枚举定义相悖，
    /// 并与 F-2 复合（迟到事件被当成当前集次）。
    ///
    /// 新不变量：**`.loading` ⟺ 真有装载在途**（整队替换 / 清队 / 释放都只是「待播」）。
    func testLoadingStateAlwaysMeansALoadIsActuallyInFlight() async {
        let preparer = GatedSourcePreparer(gating: ["priv"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL())), TestItems.make("b")]
        )
        var snap = await subject.currentSnapshot()
        XCTAssertEqual(
            snap.state, .paused,
            "F-7：整队替换后没有任何装载在途 → `.loading`（=正在装载当前项）是谎报"
        )
        XCTAssertEqual(snap.item?.id, "priv", "已选曲这一事实不变")

        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：装载未进入在途")
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .loading, "F-7：真正在途的装载才配 `.loading`")

        // 与 F-2 的复合面：此刻引擎从未见过当前项，迟到的失败必须整条丢弃。
        await subject.receive(.failed(PlayerFailure(kind: .network)))
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.item?.id, "priv", "F-2/F-7：伪失败不得把队列推走")
        XCTAssertNil(snap.lastFailure)
        XCTAssertEqual(snap.failureStreak, 0)

        await preparer.release("priv")
        _ = await startTask.value
        snap = await subject.currentSnapshot()
        XCTAssertNotEqual(snap.state, .loading, "F-7：装载返回后不得残留 `.loading`")
        XCTAssertEqual(snap.state, .playing)

        // 空队列仍落 `.idle`（既有裁决不得退化）。
        _ = await subject.replaceQueue([])
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .idle)
    }

    /// F-7 的**另一半**（第 11 批存疑点 1 → 11B，MAJ-R6-1 的第二半）：装载**以取消收场**时
    /// 也必须把 `.loading` 交还给事实。
    ///
    /// 上面那条用例只钉了「装载成功返回 → 不留 `.loading`」。取消那一腿的形状不同：
    /// `handleFailure` 对不计数的取消是「记完回显账就返回」，既不推进也不改状态 ⇒ 台账已被
    /// `defer { finishLoad }` 收掉，而入口那句 `state = .loading` 还挂着 —— F-7 的自述
    /// （`.loading` ⟺ 真有装载在途）失守。同一份输入还有第二层后果：`advanceOutcome` 照
    /// `.loading` 回 `.advanced`，于是 `start()` 向调用方声称「已经落到这一项」，而引擎里
    /// 从来没有过这一项（`NowPlayingStatusMapping` 把 `.advanced` 一律映射成 `.success`，
    /// UI 与锁屏于是同时收到「成功」）。
    func testCancelledLoadConvergesOutOfLoadingAndItsStartNeverClaimsAdvanced() async {
        for error in [PlayerError.cancelled, .staleSession] {
            let engine = ScriptedEngine()
            let nowPlaying = RecordingNowPlaying()
            let preparer = AttemptScriptedPreparer(gating: [0], outcomes: [0: error])
            let subject = PlaybackCoordinator(
                engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
            )
            let scene = "error=\(error)"

            let started = Task { await subject.start(items: TestItems.makeMany(["a"])) }
            await assertSignalReached(
                target: 1, counter: preparer.requestSignal, what: "\(scene) 的装载进入在途"
            )
            let mid = await subject.currentSnapshot()
            XCTAssertEqual(mid.state, .loading, "F-7 前置：\(scene) 此刻真有装载在途，`.loading` 是真话")

            await preparer.releasePendingAttempt()
            await assertSignalReached(
                target: 1, counter: preparer.returnedSignal, what: "\(scene) 的装载返回"
            )
            let outcome = await started.value
            XCTAssertEqual(
                outcome, .stopped,
                "11B：\(scene) 取消的装载不得向调用方回 `.advanced`（旧实现照 `.loading` 声称已落到这一项）"
            )
            // 如实钉住**已知不足**而不是愿望：`.stopped` 在命令回显面与「末项播完」同码
            // （`NowPlayingStatusMapping`），锁屏因此分不出「取消收场的停止」与「播完的停止」。
            // 协调器这一侧的债已经还了（不再回 `.advanced`），剩下的结果粒度归 TD-39（M1 接
            // UI 时一并复核）—— UI 真正的区分来源是快照的 `state` + `lastFailure` 回显账。
            XCTAssertEqual(
                NowPlayingStatusMapping.status(for: outcome), .success,
                "TD-39（已知不足，如实钉住）：`.stopped` 与「末项播完」共用一个回显码，"
                    + "锁屏分不出「取消收场的停止」。本批不偷偷改掉它 —— UI 的区分来源是快照的 "
                    + "`state` + `lastFailure` 回显账，结果粒度在 M1 复核"
            )

            let after = await subject.currentSnapshot()
            XCTAssertNotEqual(after.state, .loading, "F-7：\(scene) 装载已结束却无在途装载 → `.loading` 是谎报")
            XCTAssertEqual(after.state, .stopped, "11B：\(scene) 交还给事实 = 停止")
            XCTAssertFalse(after.isFailureTerminal, "11B：\(scene) 取消不是故障，终态闸门不得打开")
            assertNoFakeTerminal(after, scene)
            XCTAssertEqual(after.failureStreak, 0, "11B：\(scene) 计数侧仍然无账")
            XCTAssertEqual(
                after.lastFailure, PlayerFailure(kind: .cancelled, message: error.description),
                "11B：\(scene) 回显账照旧留着（UI 要提示上一次坏在哪）"
            )
            XCTAssertTrue(engine.loads.isEmpty, "D7：\(scene) 取消的条目绝不能交给引擎")
            XCTAssertEqual(
                engine.count(of: "pause"), 1,
                "11B：\(scene) 装载入口不预先摁引擎（换件本应由 `engine.load` 顶替），取消意味着那次顶替永远不会发生 —— 此刻响着的可能是上一件"
            )
            let published = await nowPlaying.lastPublished
            XCTAssertEqual(published?.isPlaying, false, "11B：\(scene) 锁屏不得收到 isPlaying=true")

            // 11B 的新读数（也是本修法删掉的一个**不可能状态**）：取消收场已是 `.stopped`，
            // 显式暂停在停止态上是无操作 —— 旧实现靠「`.loading` 被 `pause()` 折成 `.paused`」
            // 才造得出「暂停 × 引擎无装载 × 取消账」那一格，而它本身就是谎报的产物。
            await subject.pause()
            let pausedAttempt = await subject.currentSnapshot()
            XCTAssertEqual(
                pausedAttempt.state, .stopped,
                "11B：\(scene) 停止态不得被一次暂停改写成「有东西可续播」的 .paused"
            )
            XCTAssertEqual(pausedAttempt.lastFailure, after.lastFailure, "11B：暂停不改写回显账")

            // 收敛 ≠ 卡死：用户随后 `start()` 必须真装一次并播起来（R1 的既有裁决不得退化）。
            let retry = await subject.start()
            XCTAssertEqual(
                retry, .advanced(to: 0, item: TestItems.make("a"), wrapped: false),
                "11B：\(scene) 停止态下重新起播是**真**装载，不是补写状态"
            )
            let resumed = await subject.currentSnapshot()
            XCTAssertEqual(resumed.state, .playing, "11B：\(scene)")
            XCTAssertEqual(engine.loads.last?.id, "a", "R1：\(scene)")
            XCTAssertNil(resumed.lastFailure, "起播时失败账归零（既有口径，本批不动）")
            assertNoFakeTerminal(resumed, "11B \(scene) 重试之后")
            let attempts = await preparer.requestedIDs
            XCTAssertEqual(attempts, ["a", "a"], "11B：\(scene) 两趟都真的走过准备器")
        }
    }

    // MARK: - 环 4 · 第 12 批：第 7 轮复审三条探针转成的永久测试

    /// 缺陷 R7B（Major，第 7 轮隔离复审；**11B 自己留下的「修一半」**）：
    /// 装载在途时用户按暂停，`pause()` 把 `.loading` 折成 `.paused`，而 11B 的收敛腿守卫
    /// 只看 `state == .loading` ⇒ 这条交错下整条腿跳过，状态留在 `.paused` 而引擎从未拿到
    /// 这一项，`advanceOutcome` 照 `.paused` 回 `.advanced`。同一个谎换了状态外衣就躲过了
    /// 自己的守卫。修法：守卫改按**事实**判 —— 「这一代装载结束了，而引擎没拿到当前项」。
    func testCancelledLoadEndingUnderPauseStillConvergesAndNeverClaimsAdvanced() async {
        for error in [PlayerError.cancelled, PlayerError.staleSession] {
            let engine = ScriptedEngine()
            let nowPlaying = RecordingNowPlaying()
            let preparer = AttemptScriptedPreparer(gating: [0], outcomes: [0: error])
            let subject = PlaybackCoordinator(
                engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
            )
            let scene = "error=\(error)"
            let started = Task { await subject.start(items: TestItems.makeMany(["a"])) }
            await assertSignalReached(
                target: 1, counter: preparer.requestSignal, what: "\(scene) 装载进入在途"
            )
            // 关键交错：**先暂停**，再让这一趟以取消收场。
            await subject.pause()
            let mid = await subject.currentSnapshot()
            XCTAssertEqual(mid.state, .paused, "前置：\(scene) 暂停落在装载在途之上")
            await preparer.releasePendingAttempt()
            await assertSignalReached(
                target: 1, counter: preparer.returnedSignal, what: "\(scene) 装载返回"
            )
            let outcome = await started.value
            let snap = await subject.currentSnapshot()

            XCTAssertFalse(
                snap.state == .paused && engine.loads.isEmpty,
                "R7B：\(scene) 取消收场不得留下「暂停 + 引擎无装载」这一格"
            )
            XCTAssertNotEqual(
                snap.state, .paused, "R7B：\(scene) 「暂停」承诺有位置可续，而引擎里什么都没有"
            )
            XCTAssertEqual(snap.state, .stopped, "R7B：\(scene) 交还给事实 = 停止")
            if case .advanced(let to, let item, _) = outcome {
                XCTFail(
                    "R7B：\(scene) 引擎从未装载 \(item.id)，start() 却回 .advanced(to: \(to))；"
                        + "同一形状在 `.loading` 腿上已被 11B 判为谎报"
                )
            }
            XCTAssertEqual(outcome, .stopped, "R7B：\(scene)")
            XCTAssertFalse(snap.isFailureTerminal, "R7B：\(scene) 取消仍不是故障")
            assertNoFakeTerminal(snap, "R7B \(scene)")
            XCTAssertEqual(snap.failureStreak, 0, "R7B：\(scene) 计数侧无账")
            XCTAssertEqual(snap.lastFailure?.kind, .cancelled, "R7B：\(scene) 回显账留着")
            XCTAssertTrue(engine.loads.isEmpty, "D7：\(scene) 取消的条目绝不交给引擎")
            // 停止 ≠ 卡死：随后一次起播必须真装一次。
            let retry = await subject.start()
            XCTAssertEqual(retry, .advanced(to: 0, item: TestItems.make("a"), wrapped: false))
            let resumed = await subject.currentSnapshot()
            XCTAssertEqual(resumed.state, .playing, "R7B：\(scene) 用户随后要听 → 真装一次")
            XCTAssertEqual(engine.loads.last?.id, "a", "R1：\(scene)")
        }
    }

    /// 缺陷 R7C（Major，第 7 轮隔离复审）：`Configuration.consecutiveFailureLimit` 没有下界
    /// 校验，取 0（或负数）时 `handleFailure` 里「不自增」与「已达上限」两条**同时成立** ⇒
    /// 一次计数失败就在 `failureStreak == 0` 上打开终态 —— 正面违反 D18「终态只能长在计数账上」
    /// 与本套件每条场景都跑的 `assertNoFakeTerminal`。这条不变量过去只靠「默认值是 3」侥幸成立，
    /// 而全部既有测试没有一个注入过自定义 `Configuration`（本轮实测：`configuration:` 在测试里
    /// 零调用点）—— 这就是它能活到第 7 轮的原因。
    func testIllegalConfigurationCannotOpenTerminalWithoutCountedLedger() async {
        for limit in [0, -5] {
            let engine = ScriptedEngine()
            let subject = PlaybackCoordinator(
                engine: engine, clock: clock,
                configuration: PlaybackCoordinator.Configuration(
                    seekStep: 15, consecutiveFailureLimit: limit, nowPlayingTimeSyncInterval: 1
                ),
                nowPlaying: nowPlaying
            )
            _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
            _ = await subject.start()
            await subject.receive(.failed(PlayerFailure(kind: .network)))
            let snap = await subject.currentSnapshot()
            XCTAssertGreaterThan(
                snap.failureStreak, 0,
                "R7C：limit=\(limit) 时终态若成立，计数账必须非空（clamp 到 1，而不是 0 次就终态）"
            )
            assertNoFakeTerminal(snap, "R7C limit=\(limit)")
            XCTAssertTrue(snap.isFailureTerminal, "R7C：clamp 后第一次计数失败即达上限")
            // 另外两个旋钮的合法性口径一并钉住（别只修被点名的那一半）。
            let fallbacks = PlaybackCoordinator.Configuration(
                seekStep: 0, consecutiveFailureLimit: 3, nowPlayingTimeSyncInterval: -1
            )
            XCTAssertEqual(fallbacks.seekStep, PlaybackCoordinator.Configuration.fallbackSeekStep, "R7C：非正 seekStep 回落")
            XCTAssertEqual(
                fallbacks.nowPlayingTimeSyncInterval, PlaybackCoordinator.Configuration.fallbackTimeSyncInterval,
                "R7C：负节流间隔回落"
            )
            let nan = PlaybackCoordinator.Configuration(
                seekStep: .nan, consecutiveFailureLimit: 3, nowPlayingTimeSyncInterval: .infinity
            )
            XCTAssertEqual(nan.seekStep, PlaybackCoordinator.Configuration.fallbackSeekStep, "R7C：NaN 不得进引擎 seek")
            XCTAssertTrue(
                nan.nowPlayingTimeSyncInterval.isFinite, "R7C：无限节流会把时间同步整条关掉"
            )
            XCTAssertEqual(
                PlaybackCoordinator.Configuration(seekStep: 7, consecutiveFailureLimit: 99, nowPlayingTimeSyncInterval: 2)
                    .consecutiveFailureLimit,
                99, "R7C：合法值必须原样通过（clamp 不是把配置写死）"
            )
        }
    }

    /// 缺陷 R7D（第 7 轮隔离复审）：`toggle()` 只把 `.playing`/`.buffering` 当「正在响」，
    /// 于是**装载在途**（用户已经看到进度）时按一次 ⏯ 走的是 `resume()` → 起新一轮装载并
    /// 声称 `.playing`；用户想停必须按第二次，而锁屏与耳机按键只给一次。
    func testToggleDuringInFlightLoadPausesInsteadOfStartingNewPlayback() async {
        let engine = ScriptedEngine()
        let preparer = GatedSourcePreparer(gating: ["priv"])
        // `reporter:` 必须注入 —— 不注入时 `reportEpisodeIfNeeded` 直接 no-op，
        // 下面那条「没播起来就不许多报一次」会**恒真**（假绿比假红更难发现）。
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, reporter: reporter, nowPlaying: nowPlaying,
            sourcePreparer: preparer
        )
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        )
        let started = Task { await subject.start() }
        await assertSignalReached(target: 1, counter: preparer.requestSignal, what: "装载进入在途")
        let mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.state, .loading, "前置：真有装载在途")

        let toggled = await subject.toggle()
        var snap = await subject.currentSnapshot()
        XCTAssertNotEqual(toggled, .playing, "R7D：在途时按 ⏯ 不得变成「起播」")
        XCTAssertEqual(snap.state, .paused, "R7D：`.loading` 归「正要响」一侧 → 这一按是暂停")

        await preparer.release("priv")
        _ = await started.value
        snap = await subject.currentSnapshot()
        // F-1 的既有裁决不得退化：条目照常进引擎，但绝不命令出声、不声称 `.playing`。
        XCTAssertEqual(snap.state, .paused, "R7D/F-1：装载照常落地，但不许越过用户的暂停")
        XCTAssertEqual(engine.loads.last?.id, "priv")
        XCTAssertFalse(
            engine.calls.contains("play"),
            "R7D：暂停意图成立时不得命令引擎出声"
        )
        let submitted = await submitter.callCount
        XCTAssertEqual(submitted, 0, "R7D：没播起来就不许提交播放上报")
    }

    /// 缺陷 R8B-1（**Major**，第 8 轮 b 复审；第 13 批修）：「引擎装着当前项 + 正在响 +
    /// 在途台账未收」是一段**真实窗口** —— `loadCurrent` 写完 `engineEpisodeItemID` 后还要
    /// await 播放/上报/回显（上报是真网络 await）才收台账。旧 (a) 腿把「台账开着」读成
    /// 「引擎没装这一项」，于是窗口内：⏭ 停掉正在响的音乐并写 `.paused`（用户从未暂停）、
    /// `seek` 被拒（用户拖不动进度条）、`.playing`/`.paused` 事件被丢 —— **语义由网络时序决定**。
    /// 窗口构造不用睡眠：`GatedPlayReportSubmitter` 让上报挂在真 await 上，引擎账本与
    /// `.playing` 在它之前就已落定（`enteredSignal` 就是窗口打开的可读事实）。
    func testReportInFlightWindowKeepsReplaySeekAndEventsHonest() async {
        let engine = ScriptedEngine()
        let gated = GatedPlayReportSubmitter()
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock,
            reporter: PlayReportCoordinator(submitter: gated), nowPlaying: nowPlaying
        )
        await subject.setLoopMode(.all)
        // 上报需要会话（无会话时 playbackStarted 直接返回，闸门永远不会开）。
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-r8b1")))
        let started = Task { await subject.start(items: TestItems.makeMany(["a"])) }
        await assertSignalReached(
            target: 1, counter: gated.enteredSignal, what: "播放上报进入在途（R8B-1 窗口打开）"
        )
        var snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .playing, "前置：引擎装着当前项且正在响")
        XCTAssertEqual(engine.count(of: "load"), 1, "前置：只装过一趟")

        // ① ⏭ 在单元素 `.all` 上 = 重播当前项：不得停引擎、不得改状态、不得回 `.held`。
        let pausesBefore = engine.count(of: "pause")
        let outcome = await subject.next()
        XCTAssertEqual(
            outcome, .repeated(at: 0, item: TestItems.make("a")),
            "R8B-1：窗口内 ⏭ 是重播当前项，不是「保持」；旧实现回 .held 并摁停引擎"
        )
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .playing, "R8B-1：不得把正在响写成 .paused")
        XCTAssertEqual(engine.count(of: "pause"), pausesBefore, "R8B-1：不得摁停正在响的引擎")
        XCTAssertFalse(snap.isFailureTerminal, "R8B-1")

        // ② 窗口内 `seek` 不得被拒（引擎正装着当前项在响，用户拖进度条是合法手势）。
        let seeked = await subject.seek(to: 30)
        guard case .applied = seeked else {
            return XCTFail("R8B-1/R8B-2：窗口内 seek 被拒：\(seeked)")
        }
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.position, 30, "R8B-2：seek 必须真的落位置")

        // ③ 窗口内引擎事件仍须被采信（缓冲恢复一类）。
        await subject.receive(.playing)
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .playing, "R8B-2：窗口内 .playing 事件不得被丢")

        await gated.release()
        _ = await started.value
    }

    /// F-8（Minor，评审探针 `testG01`）：`PlayerEngine` 契约的「load 失败经 `.failed` 表达」
    /// 在 `loadCurrent` 里不被消费 —— 引擎说装载失败，续体照样 `state = .playing` 并**提交一次
    /// 播放上报**（少报/多报同族的口径偏差）。
    ///
    /// 如实说明：当前生产不可达（`AudioURL` 只允许 https/file，`.bearerRequired` 被前置拦截），
    /// 属**纵深防御缺口**，因此仍按 Major 的同一把守卫修掉。
    func testEngineReportedLoadFailureIsConsumedByItsOwnLoadAndNeverClaimsPlaying() async {
        let gated = GatedLoadEngine()
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        let subject = PlaybackCoordinator(
            engine: gated, clock: clock, reporter: reporter, nowPlaying: nowPlaying
        )
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        let startTask = Task { await subject.start() }
        let entered = await Signals.wait(target: 1, counter: gated.enteredLoad)
        XCTAssertTrue(entered, "前置：engine.load 未进入在途，本用例无从验证契约上报")
        var mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.state, .loading, "前置：装载在途（引擎账本尚未记账）")

        // 契约路径：`load(_:)` 不抛错，失败经 `.failed` 表达 —— 它必须被这次装载消费。
        await subject.receive(.failed(PlayerFailure(kind: .mediaInvalid)))
        gated.releaseLoad()
        let returned = await Signals.wait(target: 1, counter: gated.returnedLoad)
        XCTAssertTrue(returned, "前置：装载未返回")
        let outcome = await startTask.value

        mid = await subject.currentSnapshot()
        XCTAssertNotEqual(mid.state, .playing, "F-8：引擎说装载失败，就不许声称正在播")
        XCTAssertEqual(mid.state, .stopped)
        XCTAssertTrue(mid.isFailureTerminal, "F-8：单元素队列无处可跳 → 收敛为终态")
        XCTAssertEqual(mid.failureStreak, 1, "F-8：这条失败确实属于当代，必须计数")
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(gated.count(of: "play"), 0, "F-8：失败的装载上不得命令引擎出声")
        XCTAssertEqual(gated.count(of: "setRate"), 0)
        XCTAssertEqual(gated.loads.map(\.id), ["a"], "前置：装载确实发生过（不是没走到引擎）")
        let submitted = await submitter.callCount
        XCTAssertEqual(submitted, 0, "F-8：没播起来就不许提交播放上报（多报形态）")
        let key = await reporter.activeEpisodeKey()
        XCTAssertNil(key, "F-8：未成功的装载不得占用集次幂等键")
    }

    // MARK: - 环 4 · 第 5 批 F-A：`.repeated` 的两条腿必须分离（伪失败终态）

    /// 「终态 ⟹ 先有失败」的统一探针（F-A 的判据本身）。
    ///
    /// design §9 的终态定义是「连续 3 次失败」，`PlaybackSnapshot.isFailureTerminal` 的自述 likewise
    /// 要求先有失败。任何**良性动作**（用户按 ⏭/⏮）都不许把它翻成 true —— 否则 UI 会提示
    /// 「已停止（失败）」而实际上一次都没失败过。
    private func assertNoFakeTerminal(_ snap: PlaybackSnapshot, _ scene: String, line: UInt = #line) {
        guard snap.isFailureTerminal else { return }
        XCTAssertGreaterThan(
            snap.failureStreak, 0,
            "F-A：\(scene) 出现无失败的终态（streak=\(snap.failureStreak)）", line: line
        )
        XCTAssertNotNil(snap.lastFailure, "F-A：\(scene) 终态却没有失败记录", line: line)
    }

    /// 缺陷 F-A（Major，第 4 轮隔离复审实测）：单曲队列 + `.all` + **用户暂停中**按 ⏭ ——
    /// 队列数学只能给 `.repeated`，而 `.repeated` 的守卫把「用户此刻没有播放意图」（腿 (c)）
    /// 与「引擎里根本没有装载」（腿 (b)）收敛成同一个结果 → 良性动作落进
    /// `haltBecauseNothingIsLoaded()`：快照 `state = .stopped` + `isFailureTerminal = true`，
    /// 而 `failureStreak = 0`、`lastFailure = nil`、引擎**确实装着**这一项；
    /// 顺带抹平暂停位置、清空引擎账本（下一次 `resume()` 因此多余重新装载）。
    func testPausedUserNextOnSingleItemQueueUnderAllHoldsInsteadOfFakeTerminal() async {
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.pause()
        await subject.receive(.position(seconds: 40))
        let before = await snapshot()
        XCTAssertEqual(before.state, .paused, "前置：用户已暂停")
        assertNoFakeTerminal(before, "前置")
        let loadsBefore = engine.count(of: "load")
        let playsBefore = engine.count(of: "play")
        let pausesBefore = engine.count(of: "pause")
        let seeksBefore = engine.count(of: "seek")

        let outcome = await subject.next()
        XCTAssertEqual(
            outcome, .held,
            "F-A：无处可去 + 用户没有播放意图 = 边界保持，不是「停止 + 失败终态」"
        )
        var after = await snapshot()
        XCTAssertEqual(after.state, .paused, "F-A：暂停不得被一次 ⏭ 打成 .stopped")
        XCTAssertFalse(after.isFailureTerminal, "F-A：终态的定义是连续 3 次失败（design §9）")
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertNil(after.lastFailure)
        assertNoFakeTerminal(after, "next 之后")
        XCTAssertEqual(after.item?.id, "a", "F-A：曲目身份不变")
        XCTAssertEqual(after.position, 40, "F-A：暂停位置不得被抹平为 0")
        XCTAssertEqual(engine.count(of: "seek"), seeksBefore, "F-A：没重播就不许把 seek(0) 写进引擎")
        XCTAssertEqual(engine.count(of: "play"), playsBefore, "F-A：用户没要听，绝不命令引擎出声")
        XCTAssertEqual(engine.count(of: "pause"), pausesBefore, "F-A：本来就已经暂停，不必再摁一次")
        let published = await nowPlaying.lastPublished
        XCTAssertEqual(published?.isPlaying, false, "F-A：锁屏不得收到 isPlaying=true")

        // 引擎账本必须保住：旧实现把 `engineEpisodeItemID` 清了，于是随后的续播要重新装载一次。
        await subject.resume()
        after = await snapshot()
        XCTAssertEqual(after.state, .playing, "F-A：用户随后要听 → 直接续播")
        XCTAssertEqual(after.position, 40, "F-A：保持位置是这条裁决的一部分")
        XCTAssertEqual(engine.count(of: "load"), loadsBefore, "F-A：引擎一直装着这一项 → 不该重新装载")
        XCTAssertEqual(engine.count(of: "play"), playsBefore + 1)
        assertNoFakeTerminal(after, "resume 之后")
    }

    /// F-A 的 ⏮ 同族（单曲 + `.all` 在首项后退同样只能回绕到当前项）。
    func testPausedUserPreviousOnSingleItemQueueUnderAllKeepsPositionAndLedger() async {
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.pause()
        await subject.receive(.position(seconds: 25))
        let loadsBefore = engine.count(of: "load")

        let outcome = await subject.previous()
        XCTAssertEqual(outcome, .held, "F-A：⏮ 与 ⏭ 同一条腿")
        let after = await snapshot()
        XCTAssertEqual(after.state, .paused)
        XCTAssertFalse(after.isFailureTerminal, "F-A：无失败的终态就是伪终态")
        XCTAssertEqual(after.position, 25)
        await subject.resume()
        let resumed = await snapshot()
        XCTAssertEqual(resumed.state, .playing)
        XCTAssertEqual(engine.count(of: "load"), loadsBefore, "F-A：引擎账本未被清空")
    }

    /// F-A 的 `.stopped` 同族：单元素队列在 `.off` 下播完进入**合法**停止态后切到 `.all`
    /// 再按 ⏭ —— 同样只能回绕到当前项，位置必须保住、终态必须不出现。
    /// （既有裁决 `testStoppedThenUserNextDoesNotRevivePlayback` 钉的是「stopped 下良性导航
    /// 不得复活播放」；本用例钉的是同一条路径不得伪造失败终态 —— 两者必须同时成立。）
    func testStoppedSingleItemQueueNextUnderAllHoldsPositionWithoutFakeTerminal() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        _ = await subject.start()
        await subject.receive(.position(seconds: 60))
        await subject.receive(.ended)
        var after = await snapshot()
        XCTAssertEqual(after.state, .stopped, "前置：`.off` 末项播完 → 停止（不 wrap）")
        XCTAssertFalse(after.isFailureTerminal, "前置：播完不是失败")
        await subject.setLoopMode(.all)

        let outcome = await subject.next()
        XCTAssertEqual(outcome, .held, "F-A：stopped 下的越界导航同样是良性动作")
        after = await snapshot()
        XCTAssertEqual(after.state, .stopped, "F-A：状态保持（既不复活播放，也不改口成失败）")
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertNil(after.lastFailure)
        XCTAssertEqual(after.position, 60, "F-A：位置不得被抹平")
        XCTAssertEqual(after.item?.id, "a")
    }

    /// F-A 的**对照组**（复审指认：三曲队列的同一动作是 `.advanced` + `.playing`、不进终态）：
    /// 说明旧判据是「过宽」而不是「必要代价」。
    func testPausedUserNextOnThreeItemQueueUnderAllAdvancesAndPlays() async {
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c"]))
        _ = await subject.start(at: 2)
        await subject.pause()
        let outcome = await subject.next()
        XCTAssertEqual(outcome, .advanced(to: 0, item: TestItems.make("a"), wrapped: true))
        let after = await snapshot()
        XCTAssertEqual(after.state, .playing, "对照组：三曲队列的同一动作正常推进")
        XCTAssertFalse(after.isFailureTerminal, "对照组：不进终态")
        XCTAssertEqual(after.item?.id, "a")
        XCTAssertEqual(after.position, 0, "对照组：推进到新曲目 → 从头开始（与「保持」相对）")
        await assertPlayingIsBackedByEngine("F-A 对照组")
    }

    /// 缺陷 MAJ-R5-1 · **复现路径 ①**（第 5 轮隔离复审实测）：门面那段公开 API 序列
    /// `start → pause → 移除当前曲 → `.all` → next` 里，`removeItem` 已经把在途台账与
    /// **引擎账本**一并作废（引擎里装着的是被删掉的那一件），于是新当前项从未进过引擎；
    /// 此时一次 ⏭ 只能回绕到当前项 → 守卫腿 (b) 不成立 → 第 5 批的实现**无条件**进
    /// `haltBecauseNothingIsLoaded()` → `isFailureTerminal = true` 而 `failureStreak == 0`、
    /// `lastFailure == nil`，正是 `PlaybackSnapshot.isFailureTerminal` 自述里禁止的「谎报」。
    ///
    /// 门面形态说明：`CovaPlayer.start/pause/remove(itemID:)/setLoopMode/next` 都是对
    /// `coordinator` 同名方法的一层透传（`CovaPlayer.swift` 的方法体即 `await coordinator.…`），
    /// 故本用例就是那条序列本身；门面本身不归本批改（第 9 批在修），记日志存疑点。
    func testRemovingCurrentItemThenNavigatingUnderAllNeverCreatesFakeTerminal() async {
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]))
        await subject.pause()
        await subject.receive(.position(seconds: 20))
        _ = await subject.removeItem(itemID: "a")
        await subject.setLoopMode(.all)
        let before = await snapshot()
        XCTAssertEqual(before.state, .paused, "前置：移除当前曲不得把暂停中的播放器打成播放")
        XCTAssertEqual(before.item?.id, "b", "前置：当前项已换到同位置的新曲")
        XCTAssertEqual(engine.loads.map(\.id), ["a"], "前置：新当前项从未进过引擎（引擎里是已删掉的 a）")
        assertNoFakeTerminal(before, "移除当前曲之后")
        let pausesBefore = engine.count(of: "pause")
        let releasesBefore = engine.releaseCount

        let outcome = await subject.next()
        XCTAssertEqual(
            outcome, .held,
            "MAJ-R5-1：腿 (b) 不成立 + 没有任何失败账 = 良性保持，不是「停止 + 失败终态」"
        )
        var after = await snapshot()
        XCTAssertFalse(after.isFailureTerminal, "MAJ-R5-1：终态的唯一合法来源是失败账（design §9）")
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertNil(after.lastFailure)
        assertNoFakeTerminal(after, "移除当前曲后 next")
        XCTAssertEqual(after.state, .paused, "MAJ-R5-1：状态保持，既不进 .stopped 也不复活播放")
        XCTAssertEqual(after.item?.id, "b")
        XCTAssertEqual(engine.count(of: "pause"), pausesBefore, "MAJ-R5-1：没播起来也没摁它，不该动引擎")
        XCTAssertEqual(engine.releaseCount, releasesBefore)
        XCTAssertEqual(
            NowPlayingStatusMapping.status(for: outcome), .noSuchContent,
            "MAJ-R5-1：`.stopped` 会被锁屏映射成 `.success`（虚报「已生效」）"
        )

        // 保持 ≠ 卡死：用户随后要听 → 「恢复」必须是真装载（R1 的既有裁决不得退化）。
        await subject.resume()
        after = await snapshot()
        XCTAssertEqual(after.state, .playing)
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(engine.loads.last?.id, "b", "R1：引擎此前没有 b → resume 得真的装一次")
        assertNoFakeTerminal(after, "resume 之后")
    }

    /// 缺陷 MAJ-R5-1 · **复现路径 ②**：单曲队列 + `.all`，整队替换后**从未装载**时按 ⏭。
    ///
    /// `replaceQueue` 按既有裁决不自动播放、也不打 `.loading`（F-7），所以这一刻
    /// 「引擎没装当前项」是**正常态**而不是故障；旧实现照样写出失败终态。
    func testReplacedQueueNeverLoadedThenNavigatingUnderAllNeverCreatesFakeTerminal() async {
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue(TestItems.makeMany(["a"]))
        let before = await snapshot()
        XCTAssertEqual(engine.count(of: "load"), 0, "前置：整队替换不自动播放（既有裁决）")
        XCTAssertEqual(before.state, .paused, "前置：F-7 口径 —— 没有装载在途就不是 .loading")
        XCTAssertEqual(before.failureStreak, 0, "前置：从未发生失败")
        XCTAssertNil(before.lastFailure)
        let loadsBefore = engine.count(of: "load")

        let outcome = await subject.next()
        XCTAssertEqual(outcome, .held, "MAJ-R5-1：从未装载 + 从未失败 = 保持，不是终态")
        let after = await snapshot()
        XCTAssertFalse(after.isFailureTerminal, "MAJ-R5-1：无失败的失败终态（isFailureTerminal 谎报）")
        XCTAssertEqual(after.state, .paused)
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertNil(after.lastFailure)
        assertNoFakeTerminal(after, "未装载时 next")
        XCTAssertEqual(after.item?.id, "a")
        XCTAssertEqual(engine.count(of: "load"), loadsBefore, "MAJ-R5-1：⏭ 不是装载请求，不该顺手装一次")
        let published = await nowPlaying.lastPublished
        XCTAssertEqual(published?.isPlaying, false, "MAJ-R5-1：锁屏不得收到 isPlaying=true")

        await subject.resume()
        let resumed = await snapshot()
        XCTAssertEqual(resumed.state, .playing, "用户要听 → 这一次才真装载")
        XCTAssertEqual(engine.loads.map(\.id), ["a"])
        assertNoFakeTerminal(resumed, "resume 之后")
    }

    /// 缺陷 MAJ-R5-1 · **复现路径 ③**（M1 的真实形态）：单曲队列 + `.all`、
    /// **私有音频装载在途**时按 ⏭。
    ///
    /// 这条最坏的地方是**两段**谎报：① 导航当场写出无失败的失败终态并向调用方回 `.stopped`
    /// （`NowPlayingStatusMapping` 把 `.stopped` 映射成 `.success` ⇒ 锁屏收到「已生效」）；
    /// ② 晚到的装载续体又把那个终态**悄悄抹掉**（`loadCurrent` 见引擎真的装上了当前项即
    /// `isFailureTerminal = false`）—— 于是「终态」 existed 只在调用方的返回值里，快照上查无此事。
    func testNextDuringInFlightPrivateAudioLoadNeverCreatesFakeTerminal() async {
        let preparer = GatedSourcePreparer(gating: ["priv"])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        await subject.setLoopMode(.all)
        _ = await subject.replaceQueue(
            [TestItems.make("priv", source: .bearerRequired(TestItems.audioURL()))]
        )
        let startTask = Task { await subject.start() }
        let opened = await Signals.wait(target: 1, counter: preparer.requestSignal)
        XCTAssertTrue(opened, "前置：私有音频装载未进入在途，本用例无从验证")
        var mid = await subject.currentSnapshot()
        XCTAssertEqual(mid.state, .loading, "前置：装载在途（F-7 口径）")
        XCTAssertEqual(mid.failureStreak, 0, "前置：从未发生失败")
        XCTAssertNil(mid.lastFailure)
        assertNoFakeTerminal(mid, "装载在途")

        let outcome = await subject.next()
        XCTAssertEqual(
            outcome, .held,
            "MAJ-R5-1：装载在途时的一次 ⏭ 既没失败也没落地 → 只能回「保持」"
        )
        XCTAssertEqual(
            NowPlayingStatusMapping.status(for: outcome), .noSuchContent,
            "MAJ-R5-1：旧实现回 `.stopped`，而锁屏侧把 `.stopped` 映射成 `.success`"
        )
        mid = await subject.currentSnapshot()
        XCTAssertFalse(mid.isFailureTerminal, "MAJ-R5-1：无失败的失败终态（第 5 批只修了腿 (c)）")
        XCTAssertEqual(mid.state, .loading, "MAJ-R5-1：装载在途这个事实不得被 ⏭ 改写成 .stopped")
        XCTAssertEqual(mid.failureStreak, 0)
        XCTAssertNil(mid.lastFailure)
        assertNoFakeTerminal(mid, "装载在途时 next 之后")
        XCTAssertEqual(mid.item?.id, "priv", "MAJ-R5-1：单曲回绕本就还是这一项，不该换也不该清")

        // 晚到的装载照常落地：此刻的状态就是它真实写出的那一个，中间不存在「曾进过终态」。
        await preparer.release("priv")
        let landed = await Signals.wait(target: 1, counter: preparer.returnedSignal)
        XCTAssertTrue(landed, "前置：在途装载未返回")
        let started = await startTask.value
        if case .advanced(to: let index, item: let item, let wrapped) = started {
            XCTAssertEqual(index, 0)
            XCTAssertEqual(item.id, "priv")
            XCTAssertFalse(wrapped)
        } else {
            return XCTFail("未被取代的装载必须照常回 `.advanced`：\(started)")
        }
        let after = await subject.currentSnapshot()
        XCTAssertEqual(after.state, .playing, "MAJ-R5-1：终态不该由一次良性 ⏭ 造出来，也就不存在被抹掉")
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(engine.loads.map(\.id), ["priv"])
        assertNoFakeTerminal(after, "装载落地后")
    }

    /// 普遍化（F-A 的判据面，替代逐条枚举）：**计数侧从来没有账**时，
    /// 任何一次用户显式导航（`循环模式 × 队列长度 × 前/后 × 基态`）都不得产生失败终态。
    /// 复审指出既有 90 条协调器用例无一条覆盖「paused/stopped × 单曲 × `.all`」，本组矩阵把该
    /// 组合连同其邻域一起钉住。
    ///
    /// **基态列从 2 格补到 4 格（MAJ-R5-1，第 5 轮复审指认）**：旧矩阵每一格都先
    /// `start(items:)` 把装载走完，于是「引擎从未装过当前项」这一整族形态（整队替换后未起播、
    /// 私有音频装载在途）从未被这一格覆盖，`assertNoFakeTerminal` 在那里形同漏空 ——
    /// 第 5 批的 F-A 因此只修了一半（腿 (c)）就落了证。
    ///
    /// **基态列再从 4 格补到 8 格（MAJ-R6-1，第 11 批）、第 13 批删回 7 格**：前四列全程「一次失败都没有」，
    /// 而 MAJ-R6-1 恰恰只在「**有一次不计数失败**（取消 / 过期会话）」时才成立 ——
    /// 那一格此前同样形同漏空（第 6 轮复审的探针 `testProbeStaleSessionThenNavigate` 就是从这里
    /// 打出来的）。新增四列把「取消账 × 未装载 / 暂停 / 装载在途」三种此前只测过「零失败」的
    /// 形状全部重走一遍，另加一列 `.staleSession` 分类腿（`kind(for:)` 归一到同一个不计数形态）。
    func testUserNavigationNeverCreatesFailureTerminalWithoutAnyFailure() async {
        for mode in LoopMode.allCases {
            for ids in [["a"], ["a", "b", "c"]] {
                for base in NavigationBase.allCases {
                    for goForward in [true, false] {
                        await assertNavigationFrom(mode: mode, ids: ids, base: base, forward: goForward)
                    }
                }
            }
        }
    }

    /// 矩阵的基态列。前四列是第 5 / 10 批已有的形态（**计数侧与回显侧都无账**），
    /// 后三列由 MAJ-R6-1 补齐（**回显侧有一次不计数的取消，计数侧仍无账**）。
    /// **第 13 批删掉的那一列（MIN-R7-3）**：原 `cancelledWithLoadInFlight` 的
    /// `echoBeforeNavigation` 恒为 `nil`，列名与所测相反、行为上退化为 `loadInFlight` 的重复列。
    /// 它想钉的「取消回显 × 新一轮装载在途」形状由
    /// `testNavigatingDuringInFlightLoadAfterCancellationHoldsAndLeavesNoTerminal` 以可达构造
    /// （`previous()` 的 `.moved` 腿起第二趟）单独守着 —— 删列不留空名，判据不丢。
    private enum NavigationBase: CaseIterable, Equatable {
        /// 走完装载后用户显式暂停（旧矩阵 `basePaused == true`）。
        case loadedPaused
        /// 走完装载后 `.off` 末项播完 → **合法**停止态（旧矩阵 `basePaused == false`）。
        case loadedStopped
        /// 整队替换后**从未装载**（`replaceQueue` 不自动播放，引擎一次 `load` 都没收到）。
        case neverLoaded
        /// **私有音频装载在途**（M1 的真实形态：`prepareSource` 正跨在挂起点上）。
        case loadInFlight
        /// 第一趟装载以 `.cancelled` **收场后**导航：不计数、引擎从未装着当前项、
        /// 账上只留一次回显 —— MAJ-R6-1 的正身。
        ///
        /// 11B 之后「收场」有了真正的落点：`state = .stopped`（旧实现留 `.loading`，
        /// 于是这一格的「良性导航不得改写状态」比的是那句谎报的 `.loading`）。
        case cancelledSettled
        /// 同上，但用户随后显式按暂停。11B 的新读数：取消收场已是 `.stopped`，暂停在停止态
        /// 上是**无操作** —— 这一格因此从「暂停 × 无装载 × 取消账」变成「停止 × 无装载 ×
        /// 取消账」，而前者本来就是靠谎报才存在的（真正可达的「暂停 × 取消回显」见
        /// `testPausedUserWithCancellationEchoHoldsInsteadOfOpeningFailureTerminal`）。
        case cancelledThenPaused
        /// 同 `cancelledSettled`，但收场的是 `.staleSession`（登出/换代产生的过期会话；
        /// `kind(for:)` 把它归一到 `.cancelled` ⇒ 与上一列走的是同一把闸门）。
        case staleSessionSettled

        var label: String {
            switch self {
            case .loadedPaused: return "loadedPaused"
            case .loadedStopped: return "loadedStopped"
            case .neverLoaded: return "neverLoaded"
            case .loadInFlight: return "loadInFlight"
            case .cancelledSettled: return "cancelledSettled"
            case .cancelledThenPaused: return "cancelledThenPaused"
            case .staleSessionSettled: return "staleSessionSettled"
            }
        }

        /// 本格第一趟装载用来收场的错误（`nil` = 装载正常走完 / 只在途不返回）。
        var firstAttemptError: PlayerError? {
            switch self {
            case .cancelledSettled, .cancelledThenPaused: return .cancelled
            case .staleSessionSettled: return .staleSession
            case .loadedPaused, .loadedStopped, .neverLoaded, .loadInFlight: return nil
            }
        }

        /// 本格**导航之前**账上应留的那次回显（口径：`lastFailure` = 回显账，含不计数形态）。
        var echoBeforeNavigation: PlayerFailure? {
            guard let error = firstAttemptError else { return nil }
            return PlayerFailure(kind: .cancelled, message: error.description)
        }
    }

    /// 一格里装载夹具的**统一会合面**（基态扩到取消形态后，两种夹具各有分工）。
    private enum NavigationRig {
        /// 共享夹具：闸门按曲目 id **粘性**放行 —— 只需「一次在途」的前四列。
        case gated(GatedSourcePreparer)
        /// 本批夹具：闸门与结果都按**尝试序号**给 —— 取消形态的后四列（见其注释）。
        case scripted(AttemptScriptedPreparer)

        var sourcePreparer: any PlaybackSourcePreparing {
            switch self {
            case .gated(let preparer): return preparer
            case .scripted(let preparer): return preparer
            }
        }

        var requestSignal: SignalCounter {
            switch self {
            case .gated(let preparer): return preparer.requestSignal
            case .scripted(let preparer): return preparer.requestSignal
            }
        }

        var returnedSignal: SignalCounter {
            switch self {
            case .gated(let preparer): return preparer.returnedSignal
            case .scripted(let preparer): return preparer.returnedSignal
            }
        }

        /// 放行当前在途的那一趟（`gated` 认 id，`scripted` 认序号，id 对它无意义）。
        func release(_ id: String) async {
            switch self {
            case .gated(let preparer): await preparer.release(id)
            case .scripted(let preparer): await preparer.releasePendingAttempt()
            }
        }
    }

    private func assertNavigationFrom(
        mode: LoopMode, ids: [String], base: NavigationBase, forward: Bool, line: UInt = #line
    ) async {
        let engine = ScriptedEngine()
        let nowPlaying = RecordingNowPlaying()
        let scene = "mode=\(mode) items=\(ids) base=\(base.label) nav=\(forward ? "next" : "previous")"
        let gatedID = ids[ids.count - 1]
        // 前四列：闸门只挡「导航那一刻在途的那一件」，其余格放行同一件装具（pass-through
        // 准备器），于是四种基态走的是同一条装载链，差异只在「装载走到哪一步被打断」。
        // 后四列：按尝试序号说话 —— 第一趟以取消收场，需要时再挂起第二趟。
        let rig: NavigationRig
        switch base {
        case .loadedPaused, .loadedStopped, .neverLoaded, .loadInFlight:
            rig = .gated(GatedSourcePreparer(gating: base == .loadInFlight ? [gatedID] : []))
        case .cancelledSettled, .cancelledThenPaused, .staleSessionSettled:
            let error = base.firstAttemptError!   // 取消列必非 nil（见 `firstAttemptError`）
            rig = .scripted(AttemptScriptedPreparer(gating: [0], outcomes: [0: error]))
        }
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: rig.sourcePreparer
        )
        var startTask: Task<AdvanceOutcome, Never>?
        var secondTask: Task<Void, Never>?
        _ = await subject.setLoopMode(.off)
        let items = ids.map { TestItems.make($0) }
        switch base {
        case .neverLoaded:
            _ = await subject.replaceQueue(items, startingAt: ids.count - 1)
        case .loadInFlight:
            startTask = Task { await subject.start(items: items, at: ids.count - 1) }
            let opened = await Signals.wait(target: 1, counter: rig.requestSignal)
            XCTAssertTrue(opened, "前置：\(scene) 的装载未进入在途，本格无从验证", line: line)
        case .loadedPaused, .loadedStopped:
            _ = await subject.start(items: items, at: ids.count - 1)
        case .cancelledSettled, .cancelledThenPaused, .staleSessionSettled:
            // 第一趟装载**真的走完**并以取消收场（不是「模拟一个已完成的失败账」：
            // 走的是 `loadCurrent → handleFailure` 那条真实写入路径）。
            let first = Task { await subject.start(items: items, at: ids.count - 1) }
            let opened = await Signals.wait(target: 1, counter: rig.requestSignal)
            XCTAssertTrue(opened, "前置：\(scene) 的第一趟装载未进入在途", line: line)
            await rig.release(gatedID)
            let settled = await Signals.wait(target: 1, counter: rig.returnedSignal)
            XCTAssertTrue(settled, "前置：\(scene) 的第一趟装载未返回", line: line)
            _ = await first.value
            if base == .cancelledThenPaused {
                await subject.pause()
            }
        }
        switch base {
        case .loadedPaused, .loadedStopped:
            await subject.receive(.position(seconds: 40))
            if base == .loadedPaused {
                await subject.pause()
            } else {
                await subject.receive(.ended)   // `.off` 末项播完 → 合法停止态
            }
        case .neverLoaded, .loadInFlight:
            break   // 这两种基态下没有任何一次装载走完：位置/状态都由装载链自己写着
        case .cancelledSettled, .cancelledThenPaused, .staleSessionSettled:
            break   // 取消收场：位置与状态同样由装载链自己写着
        }
        var snap = await subject.currentSnapshot()
        XCTAssertEqual(
            snap.failureStreak, 0,
            "前置：\(scene) 计数侧从未有账（取消不计数，MAJ-4 的归一）", line: line
        )
        if let echo = base.echoBeforeNavigation {
            XCTAssertEqual(snap.lastFailure, echo, "前置：\(scene) 取消形态留下一次回显", line: line)
            XCTAssertEqual(
                snap.lastFailure?.countsTowardFailureStreak, false,
                "前置：\(scene) 回显不得是计数形态", line: line
            )
        } else {
            XCTAssertNil(snap.lastFailure, "前置：\(scene) 从未发生失败", line: line)
        }
        _ = await subject.setLoopMode(mode)
        let baseState = snap.state
        let baseItemID = snap.item?.id
        let echoAtNavigation = snap.lastFailure

        let outcome = forward ? await subject.next() : await subject.previous()
        snap = await subject.currentSnapshot()
        assertNoFakeTerminal(snap, scene, line: line)
        XCTAssertFalse(
            snap.isFailureTerminal,
            "MAJ-R6-1：计数侧无账时终态闸门**一律**不得打开（\(scene)）", line: line
        )
        XCTAssertEqual(
            snap.lastFailure, echoAtNavigation,
            "F-A / MAJ-R6-1：良性导航不得改写失败账（回显也不许多记一次）", line: line
        )
        XCTAssertEqual(snap.failureStreak, 0, "F-A：\(scene)", line: line)
        if outcome == .held {
            XCTAssertEqual(snap.state, baseState, "F-A：\(scene) 边界保持不得改写状态", line: line)
            XCTAssertEqual(snap.item?.id, baseItemID, "F-A：\(scene) 边界保持不得换曲", line: line)
        }
        if snap.state == .playing {
            XCTAssertEqual(engine.loads.last?.id, snap.item?.id, "R1：\(scene) \(line)", line: line)
        }
        // 收尾：在途那一件必须真的跑完（挂起的续体不得留到本格之外 —— 它会在下一格里
        // 变成一个不受控的回写点，D16⑤）。
        if let secondTask {
            await rig.release(gatedID)
            let landed = await Signals.wait(target: 2, counter: rig.returnedSignal)
            XCTAssertTrue(landed, "前置：\(scene) 的第二趟在途装载未返回", line: line)
            _ = await secondTask.value
        }
        if let startTask {
            await rig.release(gatedID)
            let landed = await Signals.wait(target: 1, counter: rig.returnedSignal)
            XCTAssertTrue(landed, "前置：\(scene) 的在途装载未返回", line: line)
            _ = await startTask.value
        }
    }

    /// 会合点必须成立，否则本格/本用例的**前提**就消失了。上界沿用 `Signals.wait` 的 10s
    /// （本仓唯一的时间上界），到期即红 —— 不允许「等不到就当没事发生」（D16⑤）。
    private func assertSignalReached(
        target: Int, counter: SignalCounter, what: String, line: UInt = #line
    ) async {
        let reached = await Signals.wait(target: target, counter: counter)
        XCTAssertTrue(reached, "前置：\(what) 未会合（信号未达第 \(target) 次，上界到期）", line: line)
    }

    // MARK: - 环 4 · 第 11 批 MAJ-R6-1：不计数的取消形态不得重开失败终态

    /// 缺陷 MAJ-R6-1（Major，第 6 轮复审 + 协调者坐实）：`handleFailure` **无条件**先写
    /// `lastFailure`，只有 `failureStreak` 被 `countsTowardFailureStreak` 门控；而第 10 批的
    /// 终态分流判据取的是 `failureStreak > 0 || lastFailure != nil` ⇒ 一次**被取消的装载**
    /// （用户取消 / 断网 / 登出换代产生的 `.staleSession`）就能点亮终态闸门，把
    /// 「引擎没装当前项 + 无处可跳」收敛成失败终态：`isFailureTerminal = true` 而
    /// `failureStreak == 0` —— 正是 design §9 与 `PlaybackSnapshot.isFailureTerminal` 自述
    /// 禁止的「没有失败却进失败终态」（F-A 那一类），也是第 6 批 MAJ-4
    /// 「取消一律归一为 `.cancelled` → 不计连击」的**后半刀没落下**。
    ///
    /// 本批定口径（同时写进 `hasCountedFailureLedger` 与字段自述）：
    ///   · `failureStreak` = **裁决账**，「失败终态」的唯一合法来源；
    ///   · `lastFailure` = **回显账**（最近一次失败记录，含 `.cancelled` / `.staleSession`
    ///     这类不计数形态），只供 UI 提示与诊断，**不参与任何裁决**。
    /// ⇒ 取消仍留一次回显（既有裁决 `testCancellationFailureDoesNotCountTowardStreak` 一字未动），
    /// 但它永远开不了终态闸门。
    ///
    /// 正向对照见 `testCountedFailuresStillOpenFailureTerminalWithCancellationEchoInBetween`；
    /// 全形状穷举见矩阵 `testUserNavigationNeverCreatesFailureTerminalWithoutAnyFailure`。
    func testCancelledOrStaleLoadCannotOpenFailureTerminalOnSingleItemQueueUnderAll() async {
        for error in [PlayerError.cancelled, .staleSession] {
            for forward in [true, false] {
                let engine = ScriptedEngine()
                let nowPlaying = RecordingNowPlaying()
                let preparer = AttemptScriptedPreparer(gating: [0], outcomes: [0: error])
                let subject = PlaybackCoordinator(
                    engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
                )
                let scene = "error=\(error) nav=\(forward ? "next" : "previous")"
                await subject.setLoopMode(.all)
                let first = Task { await subject.start(items: TestItems.makeMany(["a"])) }
                await assertSignalReached(
                    target: 1, counter: preparer.requestSignal, what: "\(scene) 的第一趟装载进入在途"
                )
                await preparer.releasePendingAttempt()
                await assertSignalReached(
                    target: 1, counter: preparer.returnedSignal, what: "\(scene) 的第一趟装载返回"
                )
                _ = await first.value

                let before = await subject.currentSnapshot()
                XCTAssertEqual(
                    before.lastFailure, PlayerFailure(kind: .cancelled, message: error.description),
                    "前置：\(scene) 取消形态留下一次回显（口径：回显账）"
                )
                XCTAssertEqual(before.failureStreak, 0, "前置：\(scene) 计数侧无账")
                XCTAssertFalse(before.isFailureTerminal, "前置：\(scene)")
                XCTAssertTrue(engine.loads.isEmpty, "前置：\(scene) 取消的装载绝不能把条目交给引擎")

                let pausesBefore = engine.count(of: "pause")
                let outcome = forward ? await subject.next() : await subject.previous()
                XCTAssertEqual(
                    outcome, .held,
                    "MAJ-R6-1：被取消的装载不构成失败账，无处可跳时只能保持（\(scene)）"
                )
                let after = await subject.currentSnapshot()
                XCTAssertFalse(
                    after.isFailureTerminal,
                    "MAJ-R6-1：不计数形态不得具备开终态闸门的资格（\(scene)）"
                )
                assertNoFakeTerminal(after, scene)
                XCTAssertEqual(after.failureStreak, 0, "MAJ-R6-1：\(scene)")
                XCTAssertEqual(
                    after.lastFailure, before.lastFailure,
                    "MAJ-R6-1：良性导航不得改写回显账（\(scene)）"
                )
                XCTAssertEqual(after.state, before.state, "MAJ-R6-1：\(scene) 状态保持")
                XCTAssertEqual(after.item?.id, "a", "MAJ-R6-1：\(scene) 曲目身份保持")
                XCTAssertEqual(
                    NowPlayingStatusMapping.status(for: outcome), .noSuchContent,
                    "MAJ-R6-1：\(scene) 旧实现回 `.stopped`，锁屏侧把 `.stopped` 映射成 `.success`"
                )
                XCTAssertEqual(
                    engine.count(of: "pause"), pausesBefore,
                    "MAJ-R6-1：\(scene) 保持不是停止，不许命令引擎"
                )
                let published = await nowPlaying.lastPublished
                XCTAssertEqual(
                    published?.isPlaying, false,
                    "MAJ-R6-1：\(scene) 锁屏不得收到 isPlaying=true"
                )

                // 保持 ≠ 卡死：用户随后要听 → 这一次真的重新装一次（R1 的既有裁决不得退化）。
                await subject.resume()
                let resumed = await subject.currentSnapshot()
                XCTAssertEqual(resumed.state, .playing, "MAJ-R6-1：\(scene) 取消之后仍可正常起播")
                XCTAssertFalse(resumed.isFailureTerminal, "MAJ-R6-1：\(scene)")
                XCTAssertEqual(engine.loads.last?.id, "a", "R1：\(scene) resume 得真装一次")
                let attempts = await preparer.requestedIDs
                XCTAssertEqual(
                    attempts, ["a", "a"],
                    "MAJ-R6-1：\(scene) 保持不是卡死 —— 两趟都真的走过准备器（取消一趟 + resume 一趟）"
                )
                assertNoFakeTerminal(resumed, "resume 之后")
            }
        }
    }

    /// MAJ-R6-1 的「暂停 × 取消账」形状（design §4/§6：暂停中按 ⏭ 是最典型的良性动作，
    /// 而此刻账上有一次**不计数**的取消 —— 第 5 批与第 10 批都只测了「零失败」那一半）。
    ///
    /// **这一格的来源换了（11B）**：旧实现里它靠「装载以取消收场 ⇒ `.loading` ⇒ `pause()`
    /// 折成 `.paused`」得到，而那条链每一环都是谎报（`.loading` 背后没有在途装载、
    /// `.paused` 背后引擎里没装当前项）。11B 把取消收场收敛成 `.stopped` 之后，
    /// 「暂停 × 取消回显 × 引擎装着当前项」只能由**事件面**的取消构造；装载面收场那一半
    /// 由 `testCancelledLoadConvergesOutOfLoadingAndItsStartNeverClaimsAdvanced` 钉住
    /// （连同「停止态下暂停造不出 `.paused`」这条新的不可能状态）。
    func testPausedUserWithCancellationEchoHoldsInsteadOfOpeningFailureTerminal() async {
        let engine = ScriptedEngine()
        let subject = PlaybackCoordinator(engine: engine, clock: clock, nowPlaying: nowPlaying)
        await subject.setLoopMode(.all)
        _ = await subject.start(items: TestItems.makeMany(["a"]))
        await subject.receive(.position(seconds: 30))
        await subject.pause()
        await subject.receive(.failed(PlayerFailure(kind: .cancelled)))
        var snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .paused, "前置：用户已暂停")
        XCTAssertEqual(snap.failureStreak, 0, "前置：计数侧无账（MAJ-4 的归一）")
        XCTAssertEqual(snap.lastFailure?.kind, .cancelled, "前置：回显账在")
        XCTAssertEqual(engine.count(of: "load"), 1, "前置：引擎确实装着当前项")

        let pausesBefore = engine.count(of: "pause")
        let outcome = await subject.next()
        XCTAssertEqual(outcome, .held, "MAJ-R6-1：暂停 + 取消账 + 无处可跳 = 保持")
        snap = await subject.currentSnapshot()
        XCTAssertFalse(snap.isFailureTerminal, "MAJ-R6-1：不计数形态开不了终态闸门")
        assertNoFakeTerminal(snap, "暂停中取消账在时 next")
        XCTAssertEqual(snap.state, .paused, "MAJ-R6-1：状态保持")
        XCTAssertEqual(snap.position, 30, "MAJ-R6-1：保持不是停止，位置不得被抹平")
        XCTAssertEqual(snap.failureStreak, 0)
        XCTAssertEqual(snap.lastFailure?.kind, .cancelled, "MAJ-R6-1：回显账不得被良性导航改写")
        XCTAssertEqual(engine.count(of: "pause"), pausesBefore, "MAJ-R6-1：本来就已经暂停，不必再摁一次")

        await subject.resume()
        let resumed = await subject.currentSnapshot()
        XCTAssertEqual(resumed.state, .playing, "保持 ≠ 卡死")
        XCTAssertFalse(resumed.isFailureTerminal)
        XCTAssertEqual(engine.count(of: "load"), 1, "R1：引擎一直装着这一项 → 续播不必重新装载")
    }

    /// MAJ-R6-1 的「装载在途 × 取消账」形状，连同第 5 轮点名的**第二段谎**：旧实现在导航当场
    /// 写出终态并回 `.stopped`，而晚到的装载续体又把那个终态悄悄抹掉（`loadCurrent` 见引擎
    /// 真的装上了当前项即 `isFailureTerminal = false`）⇒ 「终态」只存在于调用方的返回值里。
    ///
    /// **形状的来源（11B）**：装载面收场的取消现在落在 `.stopped`，而 `.stopped` 上的任何重试
    /// 入口（`start` / `resume`）都按既有口径把两本账一起归零 ⇒ 「取消回显 + 由重试起的在途装载」
    /// 这一格在公开 API 上不可达（那条不可达本身由 11B 用例的暂停腿钉住）。可达的构造是：
    /// 回显由**事件面**的取消落下（引擎确实装着当前项），在途那一趟由 `previous()` 的 `.moved`
    /// 腿起（用户导航不清失败账），回绕到「只能重播当前项」则用装载在途期间切到的 `.one`。
    func testNavigatingDuringInFlightLoadAfterCancellationHoldsAndLeavesNoTerminal() async {
        let engine = ScriptedEngine()
        let preparer = AttemptScriptedPreparer(gating: [1], outcomes: [:])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        await subject.setLoopMode(.all)
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]), at: 0)
        await subject.receive(.failed(PlayerFailure(kind: .cancelled)))
        var snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.lastFailure?.kind, .cancelled, "前置：回显账在（事件面落下）")
        XCTAssertEqual(snap.failureStreak, 0, "前置：计数侧无账")
        XCTAssertEqual(snap.state, .playing)

        let second = Task { await subject.previous() }
        await assertSignalReached(
            target: 2, counter: preparer.requestSignal,
            what: "第二趟装载进入在途（`.all` 下 ⏮ 回绕到 b —— 用户导航不清失败账，回显才留得住）"
        )
        await subject.setLoopMode(.one)   // 在途期间切 `.one`：此刻 ⏭ 只能回绕到当前项
        snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .loading, "F-7 前置：这一趟是真的在途")
        XCTAssertEqual(snap.lastFailure?.kind, .cancelled, "前置：回显账挺过了正常推进")

        let outcome = await subject.next()
        XCTAssertEqual(outcome, .held, "MAJ-R6-1：取消账 + 装载在途 = 保持，不是「停止 + 终态」")
        XCTAssertEqual(
            NowPlayingStatusMapping.status(for: outcome), .noSuchContent,
            "MAJ-R6-1：`.stopped` 会被锁屏映射成 `.success`（虚报「已生效」）"
        )
        snap = await subject.currentSnapshot()
        XCTAssertFalse(snap.isFailureTerminal, "MAJ-R6-1：无计数账即无终态")
        assertNoFakeTerminal(snap, "取消账 + 装载在途时 next")
        XCTAssertEqual(snap.item?.id, "b")

        await preparer.releasePendingAttempt()
        await assertSignalReached(target: 2, counter: preparer.returnedSignal, what: "第二趟在途装载返回")
        _ = await second.value
        let after = await subject.currentSnapshot()
        XCTAssertEqual(
            after.state, .playing,
            "MAJ-R6-1：晚到的装载照常落地；中间不存在「曾进过终态」（否则这段就是悄悄抹账）"
        )
        XCTAssertFalse(after.isFailureTerminal)
        XCTAssertEqual(after.failureStreak, 0)
        assertNoFakeTerminal(after, "装载落地后")
        XCTAssertEqual(engine.loads.last?.id, "b")
    }

    /// **正向腿**（防修法过窄把 F-A 的合法终态也关掉）：真实失败（计数形态）无论中间夹了多少次
    /// 取消，都必须照常累计并打开终态 —— 两条来源各自钉住：
    ///   ① 「失败后无处可跳」（单曲 + `.all`，计数失败 1 次即收敛为终态，第 5/10 批的既有裁决）；
    ///   ② 「连续失败达上限」（design §9 的 3 次，夹着 5 次取消也不许推迟也不许提前）。
    func testCountedFailuresStillOpenFailureTerminalWithCancellationEchoInBetween() async {
        // ① 计数失败 + 无处可跳 → 终态（`hasCountedFailureLedger` 为真那一腿）。
        //    `.hostRejected` 经 `PlaybackCoordinator.kind(for:)` 归一为 `.network` —— 计数形态。
        let engine = ScriptedEngine()
        let preparer = AttemptScriptedPreparer(gating: [0], outcomes: [0: .hostRejected])
        let subject = PlaybackCoordinator(
            engine: engine, clock: clock, nowPlaying: nowPlaying, sourcePreparer: preparer
        )
        await subject.setLoopMode(.all)
        let first = Task { await subject.start(items: TestItems.makeMany(["a"])) }
        await assertSignalReached(target: 1, counter: preparer.requestSignal, what: "装载进入在途")
        await preparer.releasePendingAttempt()
        await assertSignalReached(target: 1, counter: preparer.returnedSignal, what: "装载返回")
        _ = await first.value
        let snap = await subject.currentSnapshot()
        XCTAssertEqual(snap.state, .stopped, "正向①：计数失败 + 无处可跳 = 停止")
        XCTAssertTrue(snap.isFailureTerminal, "正向①：MAJ-R6-1 的修法不得关掉这条合法终态")
        XCTAssertEqual(snap.failureStreak, 1, "正向①：计数形态入裁决账")
        XCTAssertEqual(snap.lastFailure?.kind, .network)

        // ② 夹着取消的 3 次计数失败照样达到上限进终态（取消既不抬高也不吞掉连击）。
        await subject.resume()   // 用户处置 → 终态复位，回到可播状态
        let mixed = await subject.currentSnapshot()
        XCTAssertFalse(mixed.isFailureTerminal, "前置：resume 是既有的终态复位路径")
        XCTAssertEqual(mixed.failureStreak, 0)
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        for _ in 0..<5 { await subject.receive(.failed(PlayerFailure(kind: .cancelled))) }
        var counted = await subject.currentSnapshot()
        XCTAssertEqual(counted.failureStreak, 0, "正向②：取消不抬高连击（MAJ-4 既有口径）")
        XCTAssertFalse(counted.isFailureTerminal, "正向②：取消永远不构成终态")
        for _ in 0..<2 { await subject.receive(.failed(PlayerFailure(kind: .network))) }
        counted = await subject.currentSnapshot()
        XCTAssertEqual(counted.failureStreak, 2, "正向②：计数形态照常累计")
        XCTAssertFalse(counted.isFailureTerminal, "正向②：未达上限不得提前终态")
        await subject.receive(.failed(PlayerFailure(kind: .cancelled)))
        let interleaved = await subject.currentSnapshot()
        XCTAssertEqual(
            interleaved.failureStreak, 2,
            "正向②：上限前一次夹入的取消也不得把计数推到 3"
        )
        await subject.receive(.failed(PlayerFailure(kind: .mediaInvalid)))
        counted = await subject.currentSnapshot()
        XCTAssertEqual(counted.failureStreak, 3, "正向②：第 3 次计数失败即终态（design §9）")
        XCTAssertTrue(counted.isFailureTerminal, "正向②：合法终态必须仍然可达 —— 修法没过窄")
        XCTAssertEqual(counted.state, .stopped)
        XCTAssertEqual(
            counted.lastFailure?.kind, .mediaInvalid,
            "正向②：回显账记的是最近一次失败（含不计数形态）"
        )
    }

    // MARK: - 环 4 · 第 5 批 F-B：teardown 的失效面收敛 + 快照暴露「已释放」

    /// 缺陷 F-B（Minor，第 4 轮隔离复审实测）：3 连失败进终态后 `teardown()` ——
    /// 旧实现的失效面（`teardown` + `clearQueueAndStop`）只清队列/时间/状态，**不碰失败账**，
    /// 于是快照 `state = .idle` 却仍 `isFailureTerminal = true` / `lastFailure = network` /
    /// `streak = 3`；而 `PlaybackSnapshot` 没有 `tornDown` 字段，UI 无从区分
    /// 「空闲待播」与「播放器已永久释放」，会把已死的播放器渲染成「失败已停止」。
    func testTeardownAfterFailuresClearsFailureLedgerAndMarksSnapshotReleased() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        for _ in 0..<3 { await subject.receive(.failed(PlayerFailure(kind: .network))) }
        let before = await snapshot()
        XCTAssertTrue(before.isFailureTerminal, "前置：连续 3 次失败进入终态")
        XCTAssertEqual(before.failureStreak, 3)
        XCTAssertFalse(before.tornDown, "F-B：未释放时该字段必须为 false（否则它是个常量）")
        XCTAssertEqual(before.state, .stopped)

        await subject.teardown()
        let after = await snapshot()
        XCTAssertEqual(after.state, .idle)
        XCTAssertFalse(after.isFailureTerminal, "F-B：已释放的播放器不得继续携带失败终态")
        XCTAssertEqual(after.failureStreak, 0, "F-B：失败账随集次一起失效")
        XCTAssertNil(after.lastFailure)
        XCTAssertTrue(after.tornDown, "F-B：快照必须能表达「播放器已永久释放」")
        XCTAssertEqual(after.queueCount, 0)
        XCTAssertNil(after.item)

        // 幂等：第二次 teardown 不得把任何事实改回去。
        await subject.teardown()
        let again = await snapshot()
        XCTAssertTrue(again.tornDown)
        XCTAssertFalse(again.isFailureTerminal)
        XCTAssertEqual(engine.releaseCount, 1, "既有裁决：teardown 幂等")
    }

    /// F-B 的另一半：**登出/换号**与 teardown 走同一个失效收敛点（不得一个清、一个不清）。
    /// 对照面同样钉住：登录（首次绑定已认证身份）不是失效面，不得把账清掉、也不得假报已释放。
    func testLogoutInvalidationClearsFailureLedgerJustLikeTeardown() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b", "c", "d"]))
        _ = await subject.start()
        for _ in 0..<3 { await subject.receive(.failed(PlayerFailure(kind: .network))) }
        let stale = await snapshot()
        XCTAssertTrue(stale.isFailureTerminal, "前置：终态已成立")
        XCTAssertFalse(stale.tornDown)

        let next = PlaybackSessionContext(
            owner: PrincipalID(rawValue: "p2"), generation: SessionGeneration(value: 9)
        )
        await subject.bindSession(next)
        let after = await snapshot()
        XCTAssertEqual(after.state, .stopped, "登出停止播放（既有裁决）")
        XCTAssertFalse(after.isFailureTerminal, "F-B：失效面必须与 teardown 同口径收敛")
        XCTAssertEqual(after.failureStreak, 0)
        XCTAssertNil(after.lastFailure)
        XCTAssertFalse(after.tornDown, "F-B：已释放是 teardown 专属事实")
        XCTAssertEqual(after.session.generation, SessionGeneration(value: 9))

        // 正向对照（TD-9）：登录不是失效面 —— 已经播起来的东西不得被打断、账也不清。
        let live = PlaybackCoordinator(engine: engine, clock: clock, nowPlaying: nowPlaying)
        _ = await live.start(items: TestItems.makeMany(["a"]))
        await live.receive(.failed(PlayerFailure(kind: .network)))
        await live.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        let loggedIn = await live.currentSnapshot()
        XCTAssertEqual(loggedIn.state, .playing, "登录不是登出（既有裁决）")
        XCTAssertEqual(loggedIn.failureStreak, 1, "非失效面不得顺手清失败账")
        XCTAssertFalse(loggedIn.tornDown)
    }

    // MARK: - 环 4 · 第 10 批 MIN-R5-4：失效面必须一起清掉系统回显面

    /// 缺陷 MIN-R5-4（Minor，第 5 轮隔离复审实测）：`teardown()` 会 `await nowPlaying?.teardown()`，
    /// 而 `bindSession` 的失效分支只做「丢未决上报 + 停引擎 + `clearQueueAndStop()`」，
    /// 后者**一次发布/清理都不做** ⇒ 登出后锁屏继续显示**上一身份**的曲名与艺人
    /// （探针 `last=Optional("private-song")`）。F-B 立的「失效面必须一致收敛」只做到了快照那一半。
    /// 违反 D8（防跨账号串号）、AGENTS 硬边界 3、design §7/§8（「生成候选 · 仅本人可见」的内容
    /// 不应留在锁屏上）。
    func testLogoutAndAccountSwitchClearTheNowPlayingEchoSurface() async {
        let echo = EchoSurfaceProbe()
        let subject = PlaybackCoordinator(engine: engine, clock: clock, nowPlaying: echo)
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        _ = await subject.start(items: [TestItems.make("private-song")])
        var shown = await echo.current
        XCTAssertEqual(
            shown, .showing(itemID: "private-song", title: "曲目-private-song", artist: "艺人"),
            "前置：锁屏正显示该身份的曲目"
        )
        var clears = await echo.clearCount
        var teardowns = await echo.teardownCount
        XCTAssertEqual(clears, 0, "前置：正常播放路径上没有清理")

        // 失效面 ①：登出（已认证 → 未认证）。
        await subject.bindSession(.unauthenticated)
        shown = await echo.current
        XCTAssertEqual(shown, .empty, "MIN-R5-4：登出后锁屏不得继续显示上一身份的曲名")
        clears = await echo.clearCount
        XCTAssertEqual(clears, 1, "MIN-R5-4：失效面恰好清一次回显面（不多不少）")
        teardowns = await echo.teardownCount
        XCTAssertEqual(teardowns, 0, "MIN-R5-4：登出**不是** teardown —— 播放器还要继续服务")

        // 登出后这条链仍然可用（游客态起播 → 回显面重新写起来）。
        _ = await subject.start(items: [TestItems.make("guest-song")])
        shown = await echo.current
        XCTAssertTrue(shown.isShowing, "MIN-R5-4：清理只擦读数，不得把播放器写成不可用")
        XCTAssertEqual(shown.itemID, "guest-song")

        // 对照：游客 → 已认证是**登录**，不是失效面（既有裁决「登录不是登出」）。
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p1")))
        shown = await echo.current
        XCTAssertEqual(shown.itemID, "guest-song", "MIN-R5-4 对照：登录不得顺手擦掉读数")

        // 失效面 ②：换号（两个已认证身份之间 —— D8 的防串号正身）。
        _ = await subject.start(items: [TestItems.make("p1-song")])
        await subject.bindSession(PlaybackSessionContext(owner: PrincipalID(rawValue: "p2")))
        shown = await echo.current
        XCTAssertEqual(shown, .empty, "MIN-R5-4：换号后上一身份的曲名不得留在锁屏上")
        clears = await echo.clearCount
        XCTAssertEqual(clears, 2)

        // 失效面 ③：同一身份但 generation 推进（D8 的会话换代）。
        _ = await subject.start(items: [TestItems.make("p2-song")])
        await subject.bindSession(
            PlaybackSessionContext(owner: PrincipalID(rawValue: "p2"), generation: SessionGeneration(value: 4))
        )
        shown = await echo.current
        XCTAssertEqual(shown, .empty, "MIN-R5-4：换代与换号同属失效面")
        clears = await echo.clearCount
        XCTAssertEqual(clears, 3)

        // 与 teardown **同口径**（F-B 的原则）：teardown 同样把回显面清干净。
        _ = await subject.start(items: [TestItems.make("last-song")])
        await subject.teardown()
        shown = await echo.current
        XCTAssertEqual(shown, .empty, "F-B：teardown 的清回显面既有行为，不得因本批改动退化")
        teardowns = await echo.teardownCount
        XCTAssertEqual(teardowns, 1)
    }

    /// MIN-R5-4 的**正向对照**（TD-9）：回显面只有失效面才清 —— 登录、同会话重复绑定、
    /// 普通换队/追加/换曲/暂停续播都不许擦掉正在显示的内容，也不许一次导航就清一次。
    ///
    /// 没有这条对照，「把 `clear()` 塞进每一个发布点」也能让上一条测试变绿。
    func testLoginAndOrdinaryQueueMaintenanceNeverClearsTheEchoSurface() async {
        let echo = EchoSurfaceProbe()
        let subject = PlaybackCoordinator(engine: engine, clock: clock, nowPlaying: echo)
        _ = await subject.start(items: TestItems.makeMany(["a", "b"]))
        let startClears = await echo.clearCount
        XCTAssertEqual(startClears, 0, "前置：起播链上没有清理")
        var shown = await echo.current
        XCTAssertEqual(shown.itemID, "a", "前置：锁屏显示 a")

        // ① 登录（未认证 → 已认证）：既有裁决「登录不是登出」。
        let authenticated = PlaybackSessionContext(owner: PrincipalID(rawValue: "p1"))
        await subject.bindSession(authenticated)
        shown = await echo.current
        XCTAssertEqual(shown.itemID, "a", "MIN-R5-4 对照：登录不得擦掉正在显示的内容")

        // ② 同一会话视图重复绑定（幂等路径）。
        await subject.bindSession(authenticated)
        shown = await echo.current
        XCTAssertEqual(shown.itemID, "a", "MIN-R5-4 对照：重复绑定同一会话同样不清")

        // ③ 普通队列维护 + 导航 + 暂停/续播：每一项都只**改写**读数，从不清空。
        _ = await subject.replaceQueue(TestItems.makeMany(["c", "d", "e"]), startingAt: 1)
        _ = await subject.appendToQueue(TestItems.make("f"))
        _ = await subject.insertNext(TestItems.make("g"))
        _ = await subject.next()
        await subject.pause()
        await subject.resume()
        _ = await subject.removeItem(itemID: "g")
        shown = await echo.current
        XCTAssertTrue(shown.isShowing, "MIN-R5-4 对照：全程没有一次「清空回显面」")
        let clears = await echo.clearCount
        XCTAssertEqual(clears, 0, "MIN-R5-4 对照：非失效面一次都不许清")
        let teardowns = await echo.teardownCount
        XCTAssertEqual(teardowns, 0, "MIN-R5-4 对照：普通操作更不是 teardown")
    }
}

// MARK: - 环 4 · 第 10 批 MIN-R5-4：系统回显面的**当前内容**夹具

/// 锁屏回显面（`MPNowPlayingInfoCenter.nowPlayingInfo`）的等价模型。
///
/// 为什么不用共享夹具 `RecordingNowPlaying`：它记的是「发布过什么」的**流水账**，
/// 回显面被清掉之后 `lastPublished` 依然是上一身份的那一首 —— 于是 MIN-R5-4 的实测形态
/// （登出后锁屏还挂着上一身份曲名）在它上面根本读不出来。本夹具把「系统此刻显示的是什么」
/// 单独做成一份可读取的事实，`clear()` 真的把它翻回 `.empty`。
///
/// 刻意不在 `CovaPlayerTestSupport.swift` 里加（第 9 批正在改那份共享夹具，本批不碰）。
actor EchoSurfaceProbe: NowPlayingControlling {
    /// 回显面的当前内容。
    enum Content: Equatable {
        /// 锁屏上没有曲目（字典为空 / `.stopped`）。
        case empty
        case showing(itemID: String, title: String, artist: String)
    }

    private(set) var current: Content = .empty
    private(set) var clearCount = 0
    private(set) var teardownCount = 0

    func publish(_ metadata: NowPlayingMetadata) {
        current = .showing(itemID: metadata.itemID, title: metadata.title, artist: metadata.artist)
    }

    func clear() {
        current = .empty
        clearCount += 1
    }

    func teardown() {
        current = .empty
        clearCount += 1
        teardownCount += 1
    }
}

private extension EchoSurfaceProbe.Content {
    /// 「此刻确有一首显示着」的投影（只关心显示/不显示，不关心是哪一首时用）。
    var isShowing: Bool {
        if case .showing = self { return true }
        return false
    }

    var itemID: String? {
        if case .showing(let id, _, _) = self { return id }
        return nil
    }
}

// MARK: - 环 4 · 第 11 批 MAJ-R6-1：按「尝试序号」设闸与设错的装载夹具

/// 装载夹具：**第几趟**装载过闸门、**第几趟**以哪个 `PlayerError` 收场，都由脚本说话。
///
/// 为什么不复用共享夹具 `GatedSourcePreparer`（它的闸门与错误都按**曲目 id** 生效、闸门粘性）：
/// 本批的形态全都要求「同一曲目上，第二趟与第一趟不一样」——
///   ① 取消账已落下，而**新一轮装载真的在途**（粘性闸门第二次直接直通，造不出在途）；
///   ② 取消一趟之后用户真的能播起来（「保持 ≠ 卡死」的对照腿，粘性 `failing` 会永远失败）；
///   ③ 取消账在 + 随后一次**计数**失败仍须把终态打开（正向腿，防修法过窄把 F-A 的合法终态也关掉）。
/// 因此这里按尝试序号（0 起）给闸门与结果：`gating` 决定哪几趟挂起，`outcomes` 决定哪几趟
/// 以哪个错误收场（缺席 = 成功）。
///
/// 会合面与既有夹具同形：`requestSignal` = 已进入 `prepareSource`（在途已开始），
/// `returnedSignal` = 闸门放行后即将返回给协调器。等待一律走 `Signals.wait(SignalCounter)`
/// （10s 上界，到期即 `XCTAssertTrue` 变红），**不使用**第 5 轮坐实有边沿丢失缺陷的
/// `TransferWaiter.settle()`，也没有 `Task.yield()` / 睡眠 / 让步（D16⑤）。
actor AttemptScriptedPreparer: PlaybackSourcePreparing {
    let requestSignal = SignalCounter()
    let returnedSignal = SignalCounter()
    private let gating: Set<Int>
    private let outcomes: [Int: PlayerError]
    private var attempts = 0
    private var parked: Int?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released: Set<Int> = []
    private(set) var requestedIDs: [String] = []

    init(gating: [Int], outcomes: [Int: PlayerError] = [:]) {
        self.gating = Set(gating)
        self.outcomes = outcomes
    }

    func prepareSource(
        for item: PlaybackItem,
        session: PlaybackSessionContext
    ) async -> Result<PlaybackItem, PlayerError> {
        let attempt = attempts
        attempts += 1
        requestedIDs.append(item.id)
        requestSignal.bump()
        if gating.contains(attempt) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released.contains(attempt) {
                    continuation.resume()
                } else {
                    parked = attempt
                    waiter = continuation
                }
            }
        }
        returnedSignal.bump()
        if let error = outcomes[attempt] { return .failure(error) }
        return .success(item)
    }

    /// 放行**当前停着的那一趟**。测试总是先等到 `requestSignal` 再调用本方法，
    /// 而 `bump` 与挂起登记在同一段 actor 同步区内完成 ⇒ 这里必然看得见那一个。
    func releasePendingAttempt() {
        guard let parked else { return }
        released.insert(parked)
        self.parked = nil
        waiter?.resume()
        waiter = nil
    }

    /// MAJ-2 口径：本桩不在磁盘上留任何私有音频字节，显式空操作 = 免责申明。
    func discardPrivateAudio(owner: PrincipalID?) async {}
}
