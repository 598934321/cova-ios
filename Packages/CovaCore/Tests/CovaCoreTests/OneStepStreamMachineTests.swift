import CovaCore
import Foundation
import XCTest

final class OneStepStreamMachineTests: XCTestCase {
    private func makeMachine(
        policy: OneStepDegradationPolicy = OneStepDegradationPolicy(),
        startedAt: TimeInterval = 0
    ) -> OneStepStreamMachine {
        OneStepStreamMachine(policy: policy, startedAt: startedAt)
    }

    private func cards() throws -> [OneStepPlanCardDto] {
        try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards").planCards
    }

    func testFirstEventTimeoutDegrades() {
        var machine = makeMachine()
        XCTAssertTrue(machine.deadlineReached(at: 9.999).isEmpty)
        XCTAssertEqual(machine.phase, .streaming)

        let actions = machine.deadlineReached(at: 10)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.phase, .polling)
        XCTAssertEqual(machine.degradedBy, .firstEventTimeout)
    }

    func testSilenceTimeoutDegradesAfterLastActivity() {
        var machine = makeMachine()
        XCTAssertEqual(machine.frameReceived(makeSSEFrame("thinking", "{\"text\":\"a\"}"), at: 2), [
            .emitFrame(CovaSSEFrame(rawEventName: "thinking", payload: Data("{\"text\":\"a\"}".utf8)))
        ])
        XCTAssertTrue(machine.deadlineReached(at: 31.999).isEmpty)
        let actions = machine.deadlineReached(at: 32)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.degradedBy, .silenceTimeout)
    }

    func testThreeMalformedFramesDegrade() {
        var machine = makeMachine()
        XCTAssertTrue(machine.frameReceived(makeSSEFrame("text", "bad", malformed: true), at: 1).isEmpty)
        XCTAssertTrue(machine.frameReceived(makeSSEFrame("text", "bad", malformed: true), at: 2).isEmpty)
        XCTAssertEqual(machine.phase, .streaming)
        XCTAssertEqual(machine.malformedEventCount, 2)

        let actions = machine.frameReceived(makeSSEFrame("text", "bad", malformed: true), at: 3)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.degradedBy, .malformedEvents(count: 3))
        XCTAssertEqual(machine.phase, .polling)
    }

    func testMalformedFramesAreNotForwarded() {
        var machine = makeMachine()
        let actions = machine.frameReceived(makeSSEFrame("text", "{}", malformed: true), at: 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(machine.malformedEventCount, 1)
    }

    func testEOFBeforeDoneDegrades() {
        var machine = makeMachine()
        let actions = machine.streamEnded(at: 4)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.degradedBy, .eofBeforeDone)
    }

    func testDiscardedMalformedEventsCountTowardMalformedTrigger() {
        var machine = makeMachine()
        _ = machine.frameReceived(makeSSEFrame("text", "bad", malformed: true), at: 1)
        _ = machine.frameReceived(makeSSEFrame("text", "bad", malformed: true), at: 2)
        let actions = machine.recordDiscardedMalformedEvents(1, at: 3)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.degradedBy, .malformedEvents(count: 3))
        XCTAssertEqual(machine.malformedEventCount, 3)
    }

    func testDiscardedMalformedEventBelowThresholdStillReportsEOF() {
        var machine = makeMachine()
        XCTAssertTrue(machine.recordDiscardedMalformedEvents(1, at: 1).isEmpty)
        XCTAssertEqual(machine.malformedEventCount, 1)
        let actions = machine.streamEnded(at: 2)
        XCTAssertEqual(actions, [.terminateStreaming, .pollNow])
        XCTAssertEqual(machine.degradedBy, .eofBeforeDone)
    }

    func testSSEDeliveredPlanCardRegistersSignatureForPollDedupe() throws {
        var machine = makeMachine()
        let card = try cards()[0]
        let payload = try JSONEncoder().encode(card)
        let frame = CovaSSEFrame(event: .planCard, payload: payload)
        XCTAssertEqual(machine.frameReceived(frame, at: 1).count, 1)
        _ = machine.streamEnded(at: 2)
        // 首轮轮询返回同一张卡：已被 SSE 登记 → 不重复投递。
        XCTAssertTrue(machine.pollReceived([card], at: 3).isEmpty)
    }

    func testDoneYieldsFrameAndFinishes() {
        var machine = makeMachine()
        let frame = makeSSEFrame("done", "{}")
        let actions = machine.frameReceived(frame, at: 1)
        XCTAssertEqual(actions, [.emitFrame(frame), .finish])
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertNil(machine.nextDeadline())
    }

    func testErrorEventFinishes() {
        var machine = makeMachine()
        let frame = makeSSEFrame("error", "{\"text\":\"boom\"}")
        let actions = machine.frameReceived(frame, at: 1)
        XCTAssertEqual(actions, [.emitFrame(frame), .finish])
        XCTAssertEqual(machine.phase, .finished)
    }

    func testEOFAfterDoneDoesNotDegrade() {
        var machine = makeMachine()
        _ = machine.frameReceived(makeSSEFrame("done", "{}"), at: 1)
        XCTAssertTrue(machine.streamEnded(at: 2).isEmpty)
        XCTAssertNil(machine.degradedBy)
        XCTAssertEqual(machine.phase, .finished)
    }

    func testCancelTerminates() {
        var machine = makeMachine()
        XCTAssertEqual(machine.cancel(), [.terminateStreaming, .finish])
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertTrue(machine.cancel().isEmpty)
    }

    func testDeadlineScheduleBeforeAndAfterFirstEvent() {
        var machine = makeMachine()
        XCTAssertEqual(machine.nextDeadline(), 10)
        _ = machine.frameReceived(makeSSEFrame("thinking", "{}"), at: 3)
        XCTAssertEqual(machine.nextDeadline(), 33)
    }

    func testPollingCadenceAndNoOverlap() throws {
        var machine = makeMachine()
        _ = machine.streamEnded(at: 0)
        // 降级即发起首轮：lastPollAt = 0、awaitingPoll = true。
        XCTAssertNil(machine.nextDeadline())
        XCTAssertTrue(machine.deadlineReached(at: 1).isEmpty)

        let polled = machine.pollReceived(try cards(), at: 1)
        XCTAssertEqual(polled.count, 1)
        guard case .emitPlanCards(let emitted) = polled[0] else {
            return XCTFail("应为计划卡动作")
        }
        XCTAssertEqual(emitted.count, 2)
        // 节拍自「发起轮询」起算（lastPollAt=0）→ 下一次唤醒 5s。
        XCTAssertEqual(machine.nextDeadline(), 5)

        XCTAssertTrue(machine.deadlineReached(at: 4.999).isEmpty)
        XCTAssertEqual(machine.deadlineReached(at: 5), [.pollNow])
        // awaitingPoll 期间不重复触发。
        XCTAssertTrue(machine.deadlineReached(at: 100).isEmpty)
    }

    func testPollingDeduplicatesUnchangedCards() throws {
        var machine = makeMachine()
        _ = machine.streamEnded(at: 0)
        let planCards = try cards()
        XCTAssertEqual(machine.pollReceived(planCards, at: 1).count, 1)
        XCTAssertTrue(machine.pollReceived(planCards, at: 2).isEmpty)
    }

    func testPollFailureReschedulesNextTick() throws {
        var machine = makeMachine()
        _ = machine.streamEnded(at: 0)
        XCTAssertTrue(machine.pollFailed(at: 2).isEmpty)
        XCTAssertEqual(machine.nextDeadline(), 7)
        XCTAssertEqual(machine.deadlineReached(at: 7), [.pollNow])
    }

    func testActionsIgnoredOutsideMatchingPhase() throws {
        var machine = makeMachine()
        _ = machine.frameReceived(makeSSEFrame("done", "{}"), at: 1)
        XCTAssertTrue(machine.frameReceived(makeSSEFrame("text", "{}"), at: 2).isEmpty)
        XCTAssertTrue(machine.deadlineReached(at: 100).isEmpty)
        XCTAssertTrue(machine.pollReceived(try cards(), at: 100).isEmpty)
        XCTAssertTrue(machine.pollFailed(at: 100).isEmpty)
    }
}
