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

private func startCoordinator(
    clock: VirtualClock,
    sse: FakeSSEStreamingTransport,
    poller: FakePlanPoller
) async throws -> (coordinator: OneStepStreamCoordinator, collector: FrameCollector, consumer: Task<Void, Never>) {
    let coordinator = OneStepStreamCoordinator(clock: clock, transport: sse, poller: poller)
    let stream = await coordinator.start(sessionId: "session-test-0001", agentRequest: try agentRequest())
    let collector = FrameCollector()
    let consumer = Task { for await frame in stream { await collector.append(frame) } }
    return (coordinator, collector, consumer)
}

final class OneStepStreamCoordinatorTests: XCTestCase {
    // MARK: - 触发条件一：10s 无首事件

    func testFirstEventTimeoutDegradesAndTerminatesSSE() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        let waiterReady = await waitUntil { await clock.pendingWaiterCount() > 0 }
        XCTAssertTrue(waiterReady)
        await sse.waitUntilOpened()
        let callsBefore = await poller.callCount()
        XCTAssertEqual(callsBefore, 0)

        await clock.advance(by: 10)
        let polled = await waitUntil { await poller.callCount() >= 1 }
        XCTAssertTrue(polled)
        let trigger = await coordinator.degradationTrigger()
        let phase = await coordinator.currentPhase()
        let sessionIds = await poller.sessionIds()
        XCTAssertEqual(trigger, .firstEventTimeout)
        XCTAssertEqual(phase, .polling)
        XCTAssertEqual(sessionIds, ["session-test-0001"])

        let delivered = await waitUntil { await planCardCount(collector) == 2 }
        XCTAssertTrue(delivered)

        // 严格不并发：SSE 流已终止，降级后注入的字节不再被消费。
        let terminated = await waitUntil { await sse.isTerminated() }
        XCTAssertTrue(terminated)
        let before = await collector.snapshot().count
        await sse.send("event: text\ndata: {\"text\":\"late\"}\n\n")
        for _ in 0..<200 { await Task.yield() }
        let after = await collector.snapshot()
        XCTAssertEqual(after.count, before)
        XCTAssertFalse(after.contains { $0.decodePayload(CovaSSETextEventDto.self)?.text == "late" })

        await coordinator.cancel()
        _ = await consumer.value
    }

    // MARK: - 触发条件二：30s 静默

    func testSilenceTimeoutDegrades() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: thinking\ndata: {\"text\":\"a\"}\n\n")
        let gotFrame = await waitUntil { await collector.snapshot().count >= 1 }
        XCTAssertTrue(gotFrame)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await clock.advance(by: 30)
        let degraded = await waitUntil { await coordinator.degradationTrigger() == .silenceTimeout }
        XCTAssertTrue(degraded)
        let delivered = await waitUntil { await planCardCount(collector) == 2 }
        XCTAssertTrue(delivered)

        await coordinator.cancel()
        _ = await consumer.value
    }

    // MARK: - 触发条件三：3 个坏事件

    func testThreeMalformedEventsDegrade() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        for _ in 0..<3 {
            await sse.send("event: text\ndata: ###\n\n")
        }
        let degraded = await waitUntil { await coordinator.degradationTrigger() == .malformedEvents(count: 3) }
        XCTAssertTrue(degraded)
        let malformed = await coordinator.malformedEventCount()
        XCTAssertEqual(malformed, 3)
        let delivered = await waitUntil { await planCardCount(collector) == 2 }
        XCTAssertTrue(delivered)
        let frames = await collector.snapshot()
        XCTAssertFalse(frames.contains { $0.event == .text })

        await coordinator.cancel()
        _ = await consumer.value
    }

    // MARK: - 触发条件四：done 前 EOF

    func testEOFBeforeDoneDegrades() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.endStream()
        let degraded = await waitUntil { await coordinator.degradationTrigger() == .eofBeforeDone }
        XCTAssertTrue(degraded)
        let delivered = await waitUntil { await planCardCount(collector) == 2 }
        XCTAssertTrue(delivered)

        await coordinator.cancel()
        _ = await consumer.value
    }

    func testTransportFailureDegradesAsEOF() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.failStream(CovaAPIError.timeout)
        let degraded = await waitUntil { await coordinator.degradationTrigger() == .eofBeforeDone }
        XCTAssertTrue(degraded)
        let delivered = await waitUntil { await planCardCount(collector) == 2 }
        XCTAssertTrue(delivered)

        await coordinator.cancel()
        _ = await consumer.value
    }

    // MARK: - 终止条件

    func testDoneTerminatesWithoutPolling() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: done\ndata: {}\n\n")
        let finished = await waitUntil { await coordinator.currentPhase() == .finished }
        XCTAssertTrue(finished)
        let frames = await collector.snapshot()
        XCTAssertTrue(frames.contains { $0.event == .done })

        // done 之后的正常 EOF 不降级、不轮询。
        await sse.endStream()
        for _ in 0..<200 { await Task.yield() }
        let calls = await poller.callCount()
        let trigger = await coordinator.degradationTrigger()
        let phase = await coordinator.currentPhase()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(trigger)
        XCTAssertEqual(phase, .finished)
        _ = await consumer.value
    }

    func testExplicitErrorEventTerminates() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await sse.send("event: error\ndata: {\"text\":\"boom\"}\n\n")
        let finished = await waitUntil { await coordinator.currentPhase() == .finished }
        XCTAssertTrue(finished)
        let frames = await collector.snapshot()
        XCTAssertEqual(frames.last?.event, .error)
        XCTAssertEqual(frames.last?.decodePayload(CovaSSETextEventDto.self)?.text, "boom")
        for _ in 0..<200 { await Task.yield() }
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)

        await coordinator.cancel()
        _ = await consumer.value
    }

    func testCancelTerminatesStreamAndSSE() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        let (coordinator, _, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await sse.waitUntilOpened()
        await coordinator.cancel()
        let phase = await coordinator.currentPhase()
        XCTAssertEqual(phase, .finished)
        let terminated = await waitUntil { await sse.isTerminated() }
        XCTAssertTrue(terminated)
        _ = await consumer.value
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 0)
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
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await clock.advance(by: 10)
        await assertEventually { await planCardCount(collector) == 2 }

        // 第二个节拍：同一批卡不变 → 不重发。
        await clock.advance(by: 5)
        await assertEventually { await poller.callCount() >= 2 }
        for _ in 0..<200 { await Task.yield() }
        let countAfterSecondTick = await planCardCount(collector)
        XCTAssertEqual(countAfterSecondTick, 2)

        // 第三个节拍：revision 变化 → 只补发变化的那张。
        await clock.advance(by: 5)
        await assertEventually { await planCardCount(collector) == 3 }
        let calls = await poller.callCount()
        XCTAssertEqual(calls, 3)

        await coordinator.cancel()
        _ = await consumer.value
    }

    func testPollFailureIsRetriedNextTick() async throws {
        let clock = VirtualClock()
        let sse = FakeSSEStreamingTransport()
        let poller = FakePlanPoller()
        await poller.enqueue(failure: CovaAPIError.timeout)
        await poller.enqueue(try planCards())
        let (coordinator, collector, consumer) = try await startCoordinator(clock: clock, sse: sse, poller: poller)

        await assertEventually { await clock.pendingWaiterCount() > 0 }
        await clock.advance(by: 10)
        await assertEventually { await poller.callCount() == 1 }
        for _ in 0..<100 { await Task.yield() }
        let afterFailure = await planCardCount(collector)
        XCTAssertEqual(afterFailure, 0)

        await clock.advance(by: 5)
        await assertEventually { await planCardCount(collector) == 2 }

        await coordinator.cancel()
        _ = await consumer.value
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
