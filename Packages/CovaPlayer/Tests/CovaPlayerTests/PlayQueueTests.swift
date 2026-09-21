import XCTest
@testable import CovaPlayer

/// 队列纯索引数学（无 async、无副作用）。
final class PlayQueueTests: XCTestCase {
    private func queue(_ ids: [String], at index: Int? = nil) -> PlayQueue {
        PlayQueue(items: TestItems.makeMany(ids), currentIndex: index)
    }

    // MARK: - 构造与投影

    func testInitClampsInvalidCurrentIndex() {
        XCTAssertEqual(queue(["a", "b"], at: 9).currentIndex, 1)
        XCTAssertEqual(queue(["a", "b"], at: -5).currentIndex, 0)
        XCTAssertNil(queue([], at: 0).currentIndex)
        XCTAssertNil(queue(["a", "b"]).currentIndex, "缺省不选曲：选曲只经 replace / 导航")
    }

    func testCurrentAndLookup() {
        let subject = queue(["a", "b", "c"], at: 1)
        XCTAssertEqual(subject.current?.id, "b")
        XCTAssertTrue(subject.contains(itemID: "c"))
        XCTAssertFalse(subject.contains(itemID: "z"))
        XCTAssertEqual(subject.index(ofItemID: "c"), 2)
        XCTAssertNil(subject.index(ofItemID: "z"))
        XCTAssertNil(queue([]).current)
    }

    // MARK: - replace / removeAll

    func testReplaceSelectsClampedIndex() {
        var subject = PlayQueue()
        XCTAssertEqual(
            subject.replace(TestItems.makeMany(["a", "b", "c"])),
            .applied(.replaced(count: 3, current: 0))
        )
        XCTAssertEqual(subject.currentIndex, 0)
        XCTAssertEqual(
            subject.replace(TestItems.makeMany(["a", "b"]), startingAt: 9),
            .applied(.replaced(count: 2, current: 1))
        )
        XCTAssertEqual(subject.currentIndex, 1)
        XCTAssertEqual(subject.count, 2)
    }

    func testReplaceWithEmptyClearsCurrentIndex() {
        var subject = queue(["a", "b"], at: 1)
        XCTAssertEqual(subject.replace([]), .applied(.replaced(count: 0, current: nil)))
        XCTAssertNil(subject.currentIndex)
        XCTAssertTrue(subject.isEmpty)
    }

    func testRemoveAllIsAppliedNotRejected() {
        var subject = queue(["a"])
        XCTAssertEqual(subject.removeAll(), .applied(.cleared))
        XCTAssertTrue(subject.isEmpty)
        XCTAssertNil(subject.current)
    }

    // MARK: - append / insertNext（裁决：变更类操作一律不选曲）

    func testAppendIntoEmptyDoesNotAutoSelect() {
        var subject = PlayQueue()
        XCTAssertEqual(subject.append(TestItems.make("a")), .applied(.appended(at: 0)))
        XCTAssertNil(subject.currentIndex, "追加不选曲：选曲只经 replace 或导航")
        XCTAssertEqual(subject.count, 1)
    }

    func testAppendAtTailKeepsCurrentIndex() {
        var subject = queue(["a", "b"], at: 0)
        XCTAssertEqual(subject.append(TestItems.make("c")), .applied(.appended(at: 2)))
        XCTAssertEqual(subject.currentIndex, 0)
        XCTAssertEqual(subject.items.map(\.id), ["a", "b", "c"])
    }

    func testInsertNextGoesRightAfterCurrent() {
        var subject = queue(["a", "b", "c"], at: 0)
        XCTAssertEqual(subject.insertNext(TestItems.make("x")), .applied(.insertedNext(at: 1)))
        XCTAssertEqual(subject.items.map(\.id), ["a", "x", "b", "c"])
        XCTAssertEqual(subject.currentIndex, 0, "插队不改变当前项")
    }

    func testInsertNextWithoutCurrentIndexDegradesToAppend() {
        var subject = PlayQueue()
        XCTAssertEqual(subject.insertNext(TestItems.make("x")), .applied(.insertedNext(at: 0)))
        XCTAssertNil(subject.currentIndex)
        subject = queue(["a", "b"])
        subject = PlayQueue(items: TestItems.makeMany(["a", "b"]), currentIndex: nil)
        XCTAssertEqual(subject.insertNext(TestItems.make("x")), .applied(.insertedNext(at: 2)))
        XCTAssertNil(subject.currentIndex)
    }

    func testInsertNextAfterCurrentOfTailQueue() {
        var subject = queue(["a"], at: 0)
        XCTAssertEqual(subject.insertNext(TestItems.make("x")), .applied(.insertedNext(at: 1)))
        XCTAssertEqual(subject.items.map(\.id), ["a", "x"])
    }

    // MARK: - remove（裁决：移除当前项 → 指向同位置的新项）

    func testRemoveRejectsEmptyAndOutOfRange() {
        var subject = PlayQueue()
        XCTAssertEqual(subject.remove(at: 0), .rejected(.emptyQueue))
        subject = queue(["a", "b"])
        XCTAssertEqual(subject.remove(at: 5), .rejected(.indexOutOfRange))
        XCTAssertEqual(subject.remove(at: -1), .rejected(.indexOutOfRange))
        XCTAssertEqual(subject.count, 2, "被拒绝的变更不得产生副作用")
    }

    func testRemoveCurrentMovesToSamePosition() {
        var subject = queue(["a", "b", "c"], at: 1)
        XCTAssertEqual(subject.remove(at: 1), .applied(.removed(at: 1, remaining: 2, current: 1)))
        XCTAssertEqual(subject.current?.id, "c", "移除当前项后指向同位置的新项")
    }

    func testRemoveCurrentAtTailBacksOff() {
        var subject = queue(["a", "b"], at: 1)
        XCTAssertEqual(subject.remove(at: 1), .applied(.removed(at: 1, remaining: 1, current: 0)))
        XCTAssertEqual(subject.current?.id, "a")
    }

    func testRemoveBeforeCurrentShiftsIndexLeft() {
        var subject = queue(["a", "b", "c"], at: 2)
        XCTAssertEqual(subject.remove(at: 0), .applied(.removed(at: 0, remaining: 2, current: 1)))
        XCTAssertEqual(subject.current?.id, "c")
    }

    func testRemoveAfterCurrentKeepsIndex() {
        var subject = queue(["a", "b", "c"], at: 0)
        XCTAssertEqual(subject.remove(at: 2), .applied(.removed(at: 2, remaining: 2, current: 0)))
        XCTAssertEqual(subject.current?.id, "a")
    }

    func testRemoveLastItemEmptiesQueue() {
        var subject = queue(["a"], at: 0)
        XCTAssertEqual(subject.remove(at: 0), .applied(.removed(at: 0, remaining: 0, current: nil)))
        XCTAssertNil(subject.currentIndex)
        XCTAssertTrue(subject.isEmpty)
    }

    func testRemoveByUnknownIDIsRejected() {
        var subject = queue(["a"])
        XCTAssertEqual(subject.remove(itemID: "z"), .rejected(.unknownItem))
        XCTAssertEqual(subject.remove(itemID: "z"), .rejected(.unknownItem))
    }

    func testRemoveByIDDropsFirstMatchOnly() {
        var subject = queue(["a", "b"], at: 0)
        _ = subject.append(TestItems.make("a"))
        XCTAssertEqual(subject.remove(itemID: "a"), .applied(.removed(at: 0, remaining: 2, current: 0)))
        XCTAssertEqual(subject.items.map(\.id), ["b", "a"])
        XCTAssertEqual(subject.current?.id, "b")
    }

    // MARK: - move（裁决：当前曲目身份保持不变）

    func testMoveRejectsOutOfRange() {
        var subject = queue(["a", "b"])
        XCTAssertEqual(subject.move(from: 0, to: 2), .rejected(.invalidDestination))
        XCTAssertEqual(subject.move(from: 7, to: 0), .rejected(.indexOutOfRange))
        XCTAssertEqual(subject.items.map(\.id), ["a", "b"])
        var empty = PlayQueue()
        XCTAssertEqual(empty.move(from: 0, to: 0), .rejected(.emptyQueue))
    }

    func testMoveOfCurrentItemFollowsIt() {
        var subject = queue(["a", "b", "c"], at: 0)
        XCTAssertEqual(subject.move(from: 0, to: 2), .applied(.moved(from: 0, to: 2, current: 2)))
        XCTAssertEqual(subject.items.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(subject.current?.id, "a", "重排不得换曲")
    }

    func testMoveOfOtherItemAcrossCurrentAdjustsIndex() {
        var subject = queue(["a", "b", "c"], at: 2)
        XCTAssertEqual(subject.move(from: 0, to: 2), .applied(.moved(from: 0, to: 2, current: 1)))
        XCTAssertEqual(subject.current?.id, "c")
        XCTAssertEqual(subject.items.map(\.id), ["b", "c", "a"])
    }

    func testMoveBackwardOverCurrent() {
        var subject = queue(["a", "b", "c"], at: 0)
        XCTAssertEqual(subject.move(from: 2, to: 0), .applied(.moved(from: 2, to: 0, current: 1)))
        XCTAssertEqual(subject.items.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(subject.current?.id, "a")
    }

    func testMoveToSamePositionIsNoOp() {
        var subject = queue(["a", "b"], at: 1)
        XCTAssertEqual(subject.move(from: 1, to: 1), .applied(.moved(from: 1, to: 1, current: 1)))
        XCTAssertEqual(subject.items.map(\.id), ["a", "b"])
    }

    // MARK: - 推进（裁决表）

    private func step(
        _ ids: [String],
        at index: Int?,
        direction: PlayQueue.Direction,
        trigger: PlayQueue.Trigger,
        mode: LoopMode
    ) -> PlayQueue.Step {
        queue(ids, at: index).step(direction: direction, trigger: trigger, under: mode)
    }

    func testForwardWithinQueueMovesExceptUnderLoopOne() {
        for mode in [LoopMode.off, .all] {
            XCTAssertEqual(step(["a", "b", "c"], at: 0, direction: .forward, trigger: .itemEnded, mode: mode), .moved(to: 1, wrapped: false))
        }
        // `.one`：即使后面还有曲目，itemEnd 也回到当前项（优先于前进）。
        XCTAssertEqual(step(["a", "b", "c"], at: 0, direction: .forward, trigger: .itemEnded, mode: .one), .repeated(at: 0))
        for mode in LoopMode.allCases {
            XCTAssertEqual(step(["a", "b", "c"], at: 1, direction: .forward, trigger: .userInitiated, mode: mode), .moved(to: 2, wrapped: false))
        }
    }

    func testItemEndedUnderOffAtTailStopsAndNeverWraps() {
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemEnded, mode: .off), .stopped)
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemEnded, mode: .off), .stopped)
    }

    func testItemEndedUnderOneRepeatsCurrent() {
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemEnded, mode: .one), .repeated(at: 1))
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemEnded, mode: .one), .repeated(at: 0))
    }

    func testItemEndedUnderAllWrapsTailToHead() {
        XCTAssertEqual(step(["a", "b", "c"], at: 2, direction: .forward, trigger: .itemEnded, mode: .all), .moved(to: 0, wrapped: true))
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemEnded, mode: .all), .repeated(at: 0), "单元素队列回绕即重播")
    }

    func testUserNextAtTailUnderOffIsHeldNotStopped() {
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .userInitiated, mode: .off), .held)
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .userInitiated, mode: .one), .held)
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .userInitiated, mode: .all), .moved(to: 0, wrapped: true))
    }

    func testPreviousAtHead() {
        XCTAssertEqual(step(["a", "b"], at: 0, direction: .backward, trigger: .userInitiated, mode: .off), .held)
        XCTAssertEqual(step(["a", "b"], at: 0, direction: .backward, trigger: .userInitiated, mode: .one), .held)
        XCTAssertEqual(step(["a", "b"], at: 0, direction: .backward, trigger: .userInitiated, mode: .all), .moved(to: 1, wrapped: true))
        XCTAssertEqual(step(["a"], at: 0, direction: .backward, trigger: .userInitiated, mode: .all), .repeated(at: 0))
        XCTAssertEqual(step(["a", "b", "c"], at: 2, direction: .backward, trigger: .userInitiated, mode: .off), .moved(to: 1, wrapped: false))
    }

    /// 失败口径（P1c 钉死的三向一致：注释 = 测试名 = 实现）：
    /// **只要队列还有别处可跳，失败就离开当前项**（`.one` 也不例外，否则对同一坏源无限重试）；
    /// **单元素队列无处可跳** → 只能 `.repeated(当前)`，其「谎报播放」由协调器的一致性闸门收敛。
    func testFailureLeavesCurrentItemWheneverTheQueueHasSomewhereToGo() {
        // `.one` 下失败也必须离开坏项，否则无限重试同一坏源。
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemFailed, mode: .one), .repeated(at: 0),
                       "单元素队列：无处可跳 → 唯一可能的目标是当前项本身（协调器据此进入终态，而不是假装在播）")
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemFailed, mode: .off), .repeated(at: 0))
        XCTAssertEqual(step(["a"], at: 0, direction: .forward, trigger: .itemFailed, mode: .all), .repeated(at: 0))
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemFailed, mode: .one), .moved(to: 0, wrapped: true))
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemFailed, mode: .off), .moved(to: 0, wrapped: true))
    }

    /// 失败与播完在 `.off` 末项**刻意不对称**（评审 P1c 要求钉死的口径）：
    /// 播完 = 队列到头即停；失败 = 回绕首项继续跳（design §9「自动跳下一首」）。
    func testOffTailEndedStopsButFailedWrapsToFirst() {
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemEnded, mode: .off), .stopped)
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemFailed, mode: .off), .moved(to: 0, wrapped: true))
        // `.all` 下两者同构（都回绕），说明不对称只属于 `.off` 的末项。
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemEnded, mode: .all), .moved(to: 0, wrapped: true))
        XCTAssertEqual(step(["a", "b"], at: 1, direction: .forward, trigger: .itemFailed, mode: .all), .moved(to: 0, wrapped: true))
    }

    func testStepOnEmptyQueueIsRejected() {
        for mode in LoopMode.allCases {
            XCTAssertEqual(step([], at: nil, direction: .forward, trigger: .itemEnded, mode: mode), .rejected(.emptyQueue))
            XCTAssertEqual(step([], at: nil, direction: .backward, trigger: .userInitiated, mode: mode), .rejected(.emptyQueue))
        }
    }

    func testStepWithoutSelection() {
        let subject = PlayQueue(items: TestItems.makeMany(["a", "b"]), currentIndex: nil)
        XCTAssertEqual(subject.step(direction: .forward, trigger: .userInitiated, under: .off), .moved(to: 0, wrapped: false))
        XCTAssertEqual(subject.step(direction: .forward, trigger: .itemEnded, under: .all), .rejected(.noCurrentIndex))
    }

    func testStepDoesNotMutate() {
        var subject = queue(["a", "b"], at: 1)
        let before = subject
        _ = subject.step(direction: .forward, trigger: .itemEnded, under: .off)
        _ = subject.step(direction: .forward, trigger: .itemEnded, under: .all)
        XCTAssertEqual(subject, before, "step 是纯查询：不得改变队列")
        subject = queue(["a", "b"], at: 1)
        XCTAssertEqual(subject.items.count, 2)
    }

    // MARK: - 完整链路（replace → 逐步推进 → 清空）

    func testFullOffModeWalkThrough() {
        var subject = PlayQueue()
        _ = subject.replace(TestItems.makeMany(["a", "b"]))
        XCTAssertEqual(subject.current?.id, "a")
        // 首项播完 → 次项；末项播完 → 停止（不 wrap）。
        XCTAssertEqual(subject.step(direction: .forward, trigger: .itemEnded, under: .off), .moved(to: 1, wrapped: false))
        let atTail = queue(["a", "b"], at: 1)
        XCTAssertEqual(atTail.step(direction: .forward, trigger: .itemEnded, under: .off), .stopped)
        // 停止后用户显式 next 仍是 .held（不再前进），previous 可回退。
        XCTAssertEqual(atTail.step(direction: .forward, trigger: .userInitiated, under: .off), .held)
        XCTAssertEqual(atTail.step(direction: .backward, trigger: .userInitiated, under: .off), .moved(to: 0, wrapped: false))
    }

    // MARK: - 环 4 新增：`.tornDown`（teardown 终态的拒绝原因）

    /// 队列数学本身**永不**返回 `.tornDown`（它没有生命周期概念）：该 case 只由
    /// `PlaybackCoordinator` 用作「释放后一律拒绝」的返回值（缺陷 P3 的裁决）。
    /// 这里钉它的 rawValue 与文案，并对照「空队列 ≠ 已释放」不被混淆。
    func testTornDownIsCoordinatorOnlyRejectionAndNeverComesFromQueueMath() {
        XCTAssertEqual(PlayQueue.Failure.tornDown.rawValue, "tornDown")
        XCTAssertEqual(PlayQueue.Failure.tornDown.description, "播放器已释放")
        var subject = PlayQueue()
        for mode in LoopMode.allCases {
            XCTAssertEqual(
                subject.step(direction: .forward, trigger: .itemFailed, under: mode),
                .rejected(.emptyQueue),
                "正向对照：空队列是「队列空」，不得被误判成「已释放」"
            )
        }
        XCTAssertEqual(subject.replace([]), .applied(.replaced(count: 0, current: nil)))
    }
}
