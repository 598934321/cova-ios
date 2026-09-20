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
}
