@testable import CovaCore
import Foundation
import XCTest

private func planCards() throws -> [OneStepPlanCardDto] {
    try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards").planCards
}

private func changedPlanCard() throws -> OneStepPlanCardDto {
    try JSONDecoder().decode(
        OneStepPlanCardDto.self,
        from: Data(#"{"planCardId":"plan-test-0001","status":"ready","revision":5}"#.utf8)
    )
}

private func agentRequest() throws -> HTTPRequest {
    try CovaSSERequests.agent(jsonBody: Data("{}".utf8))
}

private func planCardCount(_ collector: FrameCollector) async -> Int {
    await collector.snapshot().filter { $0.event == .planCard }.count
}

private struct CoordinatorHarness {
    let coordinator: OneStepStreamCoordinator
    let collector: FrameCollector
    let consumer: Task<Void, Never>
    let completed: CompletionFlag
}

private func startCoordinator(
    clock: VirtualClock,
    sse: FakeSSEStreamingTransport,
    poller: FakePlanPoller,
    policy: OneStepDegradationPolicy = OneStepDegradationPolicy()
) async throws -> CoordinatorHarness {
    let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller, policy: policy)
    let stream = try await coordinator.start(sessionId: "session-test-0001", agentRequest: try agentRequest())
    let collector = FrameCollector()
    let completed = CompletionFlag()
    let consumer = Task {
        for await frame in stream { await collector.append(frame) }
        await completed.mark()
    }
    return CoordinatorHarness(coordinator: coordinator, collector: collector, consumer: consumer, completed: completed)
}

final class OneStepStreamCoordinatorTests: XCTestCase {
    // MARK: - 触发条件一：10s 无首事件

    func testFirstEventTimeoutDegradesAndTerminatesSSE() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await sse.waitUntilOpened()
        let callsBefore = await poller.callCount()
        XCTAssertEqual(callsBefore, 0)

        await clock.advance(by: 10)
        await assertEventually { await poller.callCount() >= 1 }
        let trigger = await harness.coordinator.degradationTrigger()
        let phase = await harness.coordinator.currentPhase()
        let sessionIds = await poller.sessionIds()
        XCTAssertEqual(trigger, .firstEventTimeout)
        XCTAssertEqual(phase, .polling)
        XCTAssertEqual(sessionIds, ["session-test-0001"])

        await assertEventually { await planCardCount(harness.collector) == 2 }

        // 严格不并发：SSE 流已终止，降级后注入的字节不再被消费。
        await assertEventually { await sse.isTerminated() }
        let before = await harness.collector.snapshot().count
        await sse.send("event: text\ndata: {\"text\":\"late\"}\n\n")
        for _ in 0..<200 { await Task.yield() }
        let after = await harness.collector.snapshot()
        XCTAssertEqual(after.count, before)
        XCTAssertFalse(after.contains { $0.decodePayload(CovaSSETextEventDto.self)?.text == "late" })

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - 触发条件二：30s 静默

    func testSilenceTimeoutDegrades() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: thinking\ndata: {\"text\":\"a\"}\n\n")
        await assertEventually { await harness.collector.snapshot().count >= 1 }

        await advanceUntil(clock) { await harness.coordinator.degradationTrigger() == .silenceTimeout }
        await advanceUntil(clock) { await planCardCount(harness.collector) == 2 }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - 触发条件三：3 个坏事件

    func testThreeMalformedEventsDegrade() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        for _ in 0..<3 {
            await sse.send("event: text\ndata: ###\n\n")
        }
        await assertEventually { await harness.coordinator.degradationTrigger() == .malformedEvents(count: 3) }
        let malformed = await harness.coordinator.malformedEventCount()
        XCTAssertEqual(malformed, 3)
        await assertEventually { await planCardCount(harness.collector) == 2 }
        let frames = await harness.collector.snapshot()
        XCTAssertFalse(frames.contains { $0.event == .text })

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - 触发条件四：done 前 EOF

    func testEOFBeforeDoneDegrades() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.endStream()
        await assertEventually { await harness.coordinator.degradationTrigger() == .eofBeforeDone }
        await assertEventually { await planCardCount(harness.collector) == 2 }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    func testTransportFailureDegradesAsEOF() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.failStream(CovaAPIError.timeout)
        await assertEventually { await harness.coordinator.degradationTrigger() == .eofBeforeDone }
        await assertEventually { await planCardCount(harness.collector) == 2 }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - m1：EOF 残帧坏事件口径

    func testEOFResidualMalformedEventsSurfaceInTrigger() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: text\ndata: ###\n\n")
        await sse.send("event: text\ndata: ###\n\n")
        await assertEventually { await harness.coordinator.malformedEventCount() == 2 }
        // 残帧（无空行收尾）→ EOF 处丢弃并计坏事件 → 达到阈值，降级原因应为 malformedEvents(3)。
        await sse.send("event: text\ndata: {\"text\":")
        await sse.endStream()
        await assertEventually { await harness.coordinator.degradationTrigger() == .malformedEvents(count: 3) }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    /// Minor-1：协议级坏事件（超长行）也要回传协调器参与「3 个坏事件」判定。
    func testOverlongEventsParticipateInDegradation() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        let long = String(repeating: "x", count: SSEFrameParser.maxLineBytes + 50)
        for _ in 0..<3 {
            await sse.send("event: text\ndata: \(long)\n\n")
        }
        await assertEventually { await harness.coordinator.degradationTrigger() == .malformedEvents(count: 3) }
        let malformed = await harness.coordinator.malformedEventCount()
        XCTAssertEqual(malformed, 3)
        await assertEventually { await planCardCount(harness.collector) == 2 }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - m2：SSE 已投递的计划卡不再被首轮轮询重复

    func testSSEDeliveredPlanCardIsNotReEmittedByFirstPoll() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let card = try planCards()[0]
        await poller.enqueue([card])
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        let json = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        await sse.send("event: plan_card\ndata: \(json)\n\n")
        await assertEventually { await planCardCount(harness.collector) == 1 }

        await advanceUntil(clock) { await poller.callCount() >= 1 }
        for _ in 0..<300 { await Task.yield() }
        let count = await planCardCount(harness.collector)
        XCTAssertEqual(count, 1)

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - 终止条件

    func testDoneTerminatesWithoutPolling() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: done\ndata: {}\n\n")
        // 等消费者真正跑完（含最后一帧 append），避免状态位与投递之间的测试侧竞态（M4）。
        await assertEventually { await harness.completed.isCompleted() }
        let frames = await harness.collector.snapshot()
        XCTAssertEqual(frames.last?.event, .done)

        // done 之后的正常 EOF 不降级、不轮询。
        await sse.endStream()
        for _ in 0..<200 { await Task.yield() }
        let calls = await poller.callCount()
        let trigger = await harness.coordinator.degradationTrigger()
        let phase = await harness.coordinator.currentPhase()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(trigger)
        XCTAssertEqual(phase, .finished)
        await awaitConsumer(harness.consumer)
    }

    func testExplicitErrorEventTerminates() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: error\ndata: {\"text\":\"boom\"}\n\n")
        await assertEventually { await harness.completed.isCompleted() }
        let frames = await harness.collector.snapshot()
        XCTAssertEqual(frames.last?.event, .error)
        XCTAssertEqual(frames.last?.decodePayload(CovaSSETextEventDto.self)?.text, "boom")
        for _ in 0..<200 { await Task.yield() }
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    func testCancelTerminatesStreamAndSSE() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await harness.coordinator.cancel()
        let phase = await harness.coordinator.currentPhase()
        XCTAssertEqual(phase, .finished)
        await assertEventually { await sse.isTerminated() }
        await awaitConsumer(harness.consumer)
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)
    }

    // MARK: - M2：单次使用语义

    func testSecondStartIsRejectedAndFirstStreamStillWorks() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)
        await sse.waitUntilOpened()

        do {
            _ = try await harness.coordinator.start(sessionId: "other", agentRequest: try agentRequest())
            XCTFail("重复 start 应抛错")
        } catch let error as OneStepStreamCoordinator.LifecycleError {
            XCTAssertEqual(error, .alreadyStarted)
        }

        // 首流未被遗弃：done 正常结束。
        await sse.send("event: done\ndata: {}\n\n")
        await assertEventually { await harness.completed.isCompleted() }
        let frames = await harness.collector.snapshot()
        XCTAssertEqual(frames.last?.event, .done)
        await awaitConsumer(harness.consumer)

        do {
            _ = try await harness.coordinator.start(sessionId: "other", agentRequest: try agentRequest())
            XCTFail("终态后 start 应抛错")
        } catch let error as OneStepStreamCoordinator.LifecycleError {
            XCTAssertEqual(error, .alreadyFinished)
        }
    }

    func testStartAfterCancelIsRejected() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)
        await sse.waitUntilOpened()

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)

        do {
            _ = try await harness.coordinator.start(sessionId: "again", agentRequest: try agentRequest())
            XCTFail("终态后 start 应抛错")
        } catch let error as OneStepStreamCoordinator.LifecycleError {
            XCTAssertEqual(error, .alreadyFinished)
        }
    }

    // MARK: - M-1：确定性取消语义

    /// 先 cancel 再 start：协调器锁定终态，start 抛错，绝不打开 SSE。
    func testCancelBeforeStartLocksCoordinatorTerminated() async throws {
        let clock = VirtualClock(yields: 8)
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)

        await coordinator.cancel()
        let terminated = await coordinator.isTerminated()
        XCTAssertTrue(terminated)

        do {
            _ = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
            XCTFail("cancel 后 start 应抛错")
        } catch let error as OneStepStreamCoordinator.LifecycleError {
            XCTAssertEqual(error, .alreadyFinished)
        }
        let streamCalls = await sse.streamCalls()
        XCTAssertEqual(streamCalls, 0, "cancel 后绝不发起 SSE 传输")
        let opened = await sse.isOpened()
        XCTAssertFalse(opened, "cancel 后绝不打开 SSE")
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)
    }

    /// start 后立即 cancel：终态、SSE 终止、无投递。
    func testStartThenImmediateCancelTerminates() async throws {
        let clock = VirtualClock(yields: 8)
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)
        await sse.waitUntilOpened()

        await harness.coordinator.cancel()
        let terminated = await harness.coordinator.isTerminated()
        XCTAssertTrue(terminated)
        await assertEventually { await sse.isTerminated() }
        await assertEventually { await harness.completed.isCompleted() }
        let frames = await harness.collector.snapshot()
        XCTAssertTrue(frames.isEmpty)
        await awaitConsumer(harness.consumer)
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)
    }

    /// M-1 契约（确定性）：`start` 悬停在首个 `await now()` 时 `cancel()`——此后**绝不**发起传输。
    func testCancelDuringStartAwaitWindowSuppressesTransport() async throws {
        let clock = GatedNowClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)

        let startTask = Task { try await coordinator.start(sessionId: "s", agentRequest: try agentRequest()) }
        await assertEventually { await clock.isNowBlocked() }
        await coordinator.cancel()
        await clock.openNowGate()
        let stream = try await startTask.value
        for _ in 0..<300 { await Task.yield() }

        let calls = await sse.streamCalls()
        XCTAssertEqual(calls, 0, "start await 窗口内 cancel：不得发起 SSE 传输")
        let terminated = await coordinator.isTerminated()
        XCTAssertTrue(terminated)

        let collector = FrameCollector()
        let consumer = Task { for await frame in stream { await collector.append(frame) } }
        await awaitConsumer(consumer)
        let frames = await collector.snapshot()
        XCTAssertTrue(frames.isEmpty)
    }

    /// D16①（确定性计数器）：`cancel()` 返回后不再调度新的轮询周期。
    func testCancelStopsSchedulingNewPollCycles() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)
        let stream = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
        let collector = FrameCollector()
        let consumer = Task { for await frame in stream { await collector.append(frame) } }

        await sse.waitUntilOpened()
        await advanceUntil(clock) { await coordinator.currentPhase() == .polling }
        let cyclesAtCancel = await coordinator.scheduledPollCycleCount()
        XCTAssertEqual(cyclesAtCancel, 1, "降级应恰好调度一个轮询周期")

        await coordinator.cancel()
        // 时间大幅推进也不得再调度新周期（取消已终止定时器 + 状态机终态）。
        await clock.advance(by: 10_000)
        for _ in 0..<300 { await Task.yield() }
        let cyclesAfter = await coordinator.scheduledPollCycleCount()
        XCTAssertEqual(cyclesAfter, cyclesAtCancel, "cancel 返回后不得再调度新的轮询周期")

        await awaitConsumer(consumer)
    }

    /// Minor-1（确定性注入点）：**轮询任务闭包内**的取消守卫阻止取消后进入 `pollPlans`。
    ///
    /// 注入点让轮询任务停在守卫**之前**；cancel 后再放行 → 守卫必须直接返回。
    /// （`performPoll` 方法入口的 `isFinished` 守卫不可达，已删除，不在此锁定。）
    func testPollTaskCancellationGuardPreventsCallAfterCancel() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)
        let gate = AsyncGate()
        await coordinator.setBeforePollTaskStart { await gate.wait() }

        let stream = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
        let collector = FrameCollector()
        let consumer = Task { for await frame in stream { await collector.append(frame) } }

        await sse.waitUntilOpened()
        await advanceUntil(clock) { await coordinator.currentPhase() == .polling }
        await assertEventually { await gate.isWaiting() }

        await coordinator.cancel()
        await gate.open()
        for _ in 0..<300 { await Task.yield() }

        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0, "取消后顶层守卫必须阻止本轮周期进入 pollPlans")
        let cycles = await coordinator.scheduledPollCycleCount()
        XCTAssertEqual(cycles, 1)
        await awaitConsumer(consumer)
    }

    /// D16：（SSE 入口）注入点确定性锁定 consume 顶层守卫。
    func testSSETopGuardPreventsTransportCallAfterCancel() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)
        let gate = AsyncGate()
        await coordinator.setBeforeSSETaskStart { await gate.wait() }

        let stream = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
        let collector = FrameCollector()
        let consumer = Task { for await frame in stream { await collector.append(frame) } }

        await assertEventually { await gate.isWaiting() }
        await coordinator.cancel()
        await gate.open()
        for _ in 0..<300 { await Task.yield() }

        let calls = await sse.streamCalls()
        XCTAssertEqual(calls, 0, "取消后 SSE 顶层守卫必须阻止发起传输")
        let terminated = await coordinator.isTerminated()
        XCTAssertTrue(terminated)
        // D16①：SSE 周期只调度一次，取消后不再新增。
        let sseCycles = await coordinator.scheduledSSECycleCount()
        XCTAssertEqual(sseCycles, 1, "取消后不得再调度新的 SSE 周期")
        await awaitConsumer(consumer)
        let frames = await collector.snapshot()
        XCTAssertTrue(frames.isEmpty)
    }

    /// 并发 start ∥ cancel：无论调度顺序如何，最终都不得存在未取消的活跃会话，
    /// 且 cancel 返回后传输调用数不再增加。
    func testConcurrentStartAndCancelLeavesNoActiveSession() async throws {
        for iteration in 0..<120 {
            let clock = VirtualClock(yields: 300)
            let sse = FakeSSEStreamingTransport()
            let poller = FakePlanPoller()
            let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)

            let startTask = Task { try await coordinator.start(sessionId: "s", agentRequest: try agentRequest()) }
            let cancelTask = Task { await coordinator.cancel() }
            await cancelTask.value
            let result = await startTask.result

            switch result {
            case .success(let stream):
                let collector = FrameCollector()
                let completed = CompletionFlag()
                let consumer = Task {
                    for await frame in stream { await collector.append(frame) }
                    await completed.mark()
                }
                await awaitConsumer(consumer)
                let frames = await collector.snapshot()
                XCTAssertTrue(frames.isEmpty, "第 \(iteration) 次：取消后不得投递帧")
            case .failure(let error):
                XCTAssertEqual(
                    error as? OneStepStreamCoordinator.LifecycleError,
                    .alreadyFinished,
                    "第 \(iteration) 次：cancel 先于 start 应抛 alreadyFinished"
                )
            }

            for _ in 0..<300 { await Task.yield() }
            let terminated = await coordinator.isTerminated()
            XCTAssertTrue(terminated, "第 \(iteration) 次：协调器必须终态")
            let phase = await coordinator.currentPhase()
            XCTAssertTrue(
                phase == nil || phase == .finished,
                "第 \(iteration) 次：不得停在 \(String(describing: phase))"
            )
            // D16①：cancel 后不再调度新周期（本场景未推进时钟，SSE 后无降级，故均为 0）。
            let pollCycles = await coordinator.scheduledPollCycleCount()
            XCTAssertEqual(pollCycles, 0, "第 \(iteration) 次：取消后不得调度轮询周期")
            // D16②：若已授权发起过 SSE 传输，必须已终止。
            if await sse.isOpened() {
                await assertEventually { await sse.isTerminated() }
            }
        }
    }

    // MARK: - M1：跨 await 读-改-写竞态

    func testConcurrentFrameAndCancelNeverRegressOrHang() async throws {
        for iteration in 0..<150 {
            let clock = VirtualClock(yields: 8)
            let sse = FakeSSEStreamingTransport()
            let poller = FakePlanPoller()
            let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)
            await sse.waitUntilOpened()

            async let sending: Void = sse.send("event: thinking\ndata: {\"text\":\"a\"}\n\n")
            async let cancelling: Void = harness.coordinator.cancel()
            _ = await (sending, cancelling)

            await assertEventually { await harness.completed.isCompleted() }
            let phase = await harness.coordinator.currentPhase()
            let calls = await poller.callCount()
            XCTAssertEqual(phase, .finished, "第 \(iteration) 次：cancel 不得被并发帧回退")
            XCTAssertEqual(calls, 0, "第 \(iteration) 次：取消后不得轮询")
            await awaitConsumer(harness.consumer)
        }
    }

    /// 同一降级动作不得重复发起轮询。
    ///
    /// 用极大 `pollInterval` 把「合法节拍轮询」排除出观测窗，口径只针对「并发 tick/坏事件导致的
    /// 重复降级」——避免把跨过 5s 节拍的合法第二次轮询误判为重复（Minor-1）。
    func testDegradeIsIdempotentUnderConcurrentTickAndMalformedFrame() async throws {
        let isolatedPolicy = OneStepDegradationPolicy(pollInterval: 1000)
        for iteration in 0..<100 {
            let clock = VirtualClock(yields: 8)
            let sse = FakeSSEStreamingTransport()
            let poller = FakePlanPoller()
            await poller.enqueue(try planCards())
            await poller.enqueue(try planCards())
            await poller.enqueue(try planCards())
            let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller, policy: isolatedPolicy)
            await sse.waitUntilOpened()

            await sse.send("event: text\ndata: ###\n\n")
            await sse.send("event: text\ndata: ###\n\n")
            await assertEventually { await harness.coordinator.malformedEventCount() == 2 }
            await assertEventually { await clock.pendingWaiterCount() > 0 }

            async let third: Void = sse.send("event: text\ndata: ###\n\n")
            async let tick: Void = clock.advance(by: 10)
            _ = await (third, tick)

            await assertEventually { await poller.callCount() >= 1 }
            for _ in 0..<300 { await Task.yield() }
            let calls = await poller.callCount()
            let phase = await harness.coordinator.currentPhase()
            XCTAssertEqual(calls, 1, "第 \(iteration) 次：同一次降级只能发起一次轮询")
            XCTAssertEqual(phase, .polling, "第 \(iteration) 次")
            _ = await harness.collector.snapshot()

            await harness.coordinator.cancel()
            await awaitConsumer(harness.consumer)
        }
    }

    // MARK: - 轮询节拍与去重

    func testPollingCadenceAndDeduplication() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let original = try planCards()
        await poller.enqueue(original)
        await poller.enqueue(original)
        await poller.enqueue([try changedPlanCard()])
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await clock.advance(by: 10)
        await assertEventually { await planCardCount(harness.collector) == 2 }

        // 第二个节拍：同一批卡不变 → 不重发。
        await advanceUntil(clock) { await poller.callCount() >= 2 }
        for _ in 0..<200 { await Task.yield() }
        let countAfterSecondTick = await planCardCount(harness.collector)
        XCTAssertEqual(countAfterSecondTick, 2)

        // 第三个节拍：revision 变化 → 只补发变化的那张。
        await advanceUntil(clock) { await planCardCount(harness.collector) == 3 }
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 3)

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    func testPollFailureIsRetriedNextTick() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(failure: CovaAPIError.timeout)
        await poller.enqueue(try planCards())
        let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await clock.advance(by: 10)
        await assertEventually { await poller.callCount() == 1 }
        for _ in 0..<100 { await Task.yield() }
        let afterFailure = await planCardCount(harness.collector)
        XCTAssertEqual(afterFailure, 0)

        await advanceUntil(clock) { await planCardCount(harness.collector) == 2 }

        await harness.coordinator.cancel()
        await awaitConsumer(harness.consumer)
    }

    // MARK: - Minor-2：轮询回包 ∥ 取消

    func testPollResponseConcurrentWithCancelIsNotDelivered() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let gate = GatedPlanPoller(response: try planCards())
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: gate)
        let stream = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
        let collector = FrameCollector()
        let completed = CompletionFlag()
        let consumer = Task {
            for await frame in stream { await collector.append(frame) }
            await completed.mark()
        }

        await sse.waitUntilOpened()
        await advanceUntil(clock) { await gate.callCount() == 1 }

        // 回包被闸门拦住：此刻 cancel 与回包并发。
        await coordinator.cancel()
        await gate.release()
        await assertEventually { await completed.isCompleted() }
        for _ in 0..<200 { await Task.yield() }

        let frames = await collector.snapshot()
        XCTAssertTrue(frames.isEmpty, "取消后不得投递轮询结果")
        let phase = await coordinator.currentPhase()
        XCTAssertEqual(phase, .finished)
        let calls = await gate.callCount()
        XCTAssertEqual(calls, 1, "不得重复降级/重复轮询")
        await awaitConsumer(consumer)
    }

    /// Minor-2：慢回包（耗时远超 5s 节拍）完成后不得立即背靠背补发下一次轮询。
    func testSlowPollResponseDoesNotTriggerBackToBackPoll() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let gate = GatedPlanPoller(response: try planCards())
        let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: gate)
        let stream = try await coordinator.start(sessionId: "s", agentRequest: try agentRequest())
        let collector = FrameCollector()
        let completed = CompletionFlag()
        let consumer = Task {
            for await frame in stream { await collector.append(frame) }
            await completed.mark()
        }

        await sse.waitUntilOpened()
        await advanceUntil(clock) { await gate.callCount() == 1 }   // 降级首轮，回包被闸门拦住

        // 时间跳跃远超 5s（回包仍未返回）。
        await clock.advance(by: 100)
        await gate.releaseOne()
        for _ in 0..<300 { await Task.yield() }
        let callsAfterSlowResponse = await gate.callCount()
        XCTAssertEqual(callsAfterSlowResponse, 1, "慢回包完成后不得立即背靠背补发")

        // 完成时刻起算 5s 后才允许下一拍。
        await clock.advance(by: 5)
        await advanceUntil(clock) { await gate.callCount() == 2 }

        await coordinator.cancel()
        await awaitConsumer(consumer)
    }
}

final class HTTPOneStepPlanPollerTests: XCTestCase {
    func testDecodesPlanCardsAndUsesContractEndpoint() async throws {
        let body = try Fixture.data("one-step-plan-cards")
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 200, body: body)
        }
        let poller = HTTPOneStepPlanPoller(transport: transport)

        let cards = try await poller.pollPlans(sessionId: "s-1")
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].planCardId, "plan-test-0001")

        let recorded = await transport.recordedRequests()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].url.path, "/api/studio/one-step/plans")
        XCTAssertEqual(recorded[0].url.query, "sessionId=s-1")
    }

    func testNonSuccessStatusMapsToAPIError() async throws {
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8))
        }
        let poller = HTTPOneStepPlanPoller(transport: transport)
        do {
            _ = try await poller.pollPlans(sessionId: "s-1")
            XCTFail("应抛错")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .httpStatus(code: 500, apiCode: nil))
        }
    }

    func testMalformedBodyMapsToDecodingError() async throws {
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"unexpected":true}"#.utf8))
        }
        let poller = HTTPOneStepPlanPoller(transport: transport)
        do {
            _ = try await poller.pollPlans(sessionId: "s-1")
            XCTFail("应抛错")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .decoding(field: "planCards"))
        }
    }

    /// Minor-1（确定性）：`pollPlans` 传输入口守卫——**已取消的任务**调用它必须抛取消错误且不发请求。
    ///
    /// 用 `AsyncGate` 把任务停在 `pollPlans` **之前**，取消后再放行，确保进入 `pollPlans` 时任务已取消
    /// （不依赖「`Task{}` 是否抢在 cancel 前启动」的调度竞态，符合 D16⑤）。
    func testPollPlansCancelledTaskDoesNotTransport() async throws {
        let body = try Fixture.data("one-step-plan-cards")
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(statusCode: 200, body: body)
        }
        let poller = HTTPOneStepPlanPoller(transport: transport)
        let gate = AsyncGate()

        let task = Task { () -> Bool in
            await gate.wait()
            do {
                _ = try await poller.pollPlans(sessionId: "s-1")
                return false
            } catch {
                return error is CancellationError || (error as? CovaAPIError) == .cancelled
            }
        }
        await assertEventually { await gate.isWaiting() }
        task.cancel()
        await gate.open()

        let cancelled = await task.value
        XCTAssertTrue(cancelled, "已取消任务应抛 CancellationError/.cancelled")
        let calls = await transport.requestCount(path: "/api/studio/one-step/plans")
        XCTAssertEqual(calls, 0, "进入 pollPlans 时任务已取消，不得发起请求")
    }

    func testRequestFactoryUsesProductionOriginAndSSEAccept() throws {
        let agent = try CovaSSERequests.agent(jsonBody: Data("{}".utf8))
        XCTAssertEqual(agent.method, .post)
        XCTAssertEqual(agent.url.absoluteString, "https://covalink.cn/api/studio/agent")
        XCTAssertEqual(agent.headers["Accept"], "text/event-stream")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(agent.url))

        let plans = try CovaSSERequests.oneStepPlans(sessionId: "abc 123")
        XCTAssertEqual(plans.method, .get)
        XCTAssertEqual(plans.url.path, "/api/studio/one-step/plans")
        XCTAssertEqual(plans.headers["Accept"], "application/json")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(plans.url))
    }
}
