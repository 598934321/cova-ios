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
    func testReadyEventCannotClaimPlayingWhileNothingIsLoadedInTheEngine() async {
        _ = await subject.replaceQueue(TestItems.makeMany(["a", "b"]))
        var after = await snapshot()
        XCTAssertEqual(after.state, .loading, "前置：整队替换后处于装载态")
        await subject.receive(.playing)
        after = await snapshot()
        XCTAssertNotEqual(after.state, .playing, "R1：引擎未装载当前项时就绪事件不得伪造播放")
        XCTAssertEqual(after.state, .loading)
    }
}
