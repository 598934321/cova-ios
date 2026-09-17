import CovaCore
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
    poller: FakePlanPoller
) async throws -> CoordinatorHarness {
    let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)
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

    func testDegradeIsIdempotentUnderConcurrentTickAndMalformedFrame() async throws {
        for iteration in 0..<100 {
            let clock = VirtualClock(yields: 8)
            let sse = FakeSSEStreamingTransport()
            let poller = FakePlanPoller()
            await poller.enqueue(try planCards())
            await poller.enqueue(try planCards())
            await poller.enqueue(try planCards())
            let harness = try await startCoordinator(clock: clock, sse: sse, poller: poller)
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
            XCTAssertEqual(calls, 1, "第 \(iteration) 次：降级只能发起一次轮询")
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
