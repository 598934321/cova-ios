import CovaCore
import XCTest

final class SSEEventDTOTests: XCTestCase {
    func testParsesContractNamedEvents() {
        XCTAssertEqual(CovaSSEEventType(rawName: "thinking"), .thinking)
        XCTAssertEqual(CovaSSEEventType(rawName: "text"), .text)
        XCTAssertEqual(CovaSSEEventType(rawName: "plan_card"), .planCard)
        XCTAssertEqual(CovaSSEEventType(rawName: "error"), .error)
        XCTAssertEqual(CovaSSEEventType(rawName: "done"), .done)
    }

    func testParsesRunLifecycleEvents() {
        XCTAssertEqual(CovaSSEEventType(rawName: "run_started"), .runLifecycle("run_started"))
        XCTAssertEqual(CovaSSEEventType(rawName: "run_waiting_user"), .runLifecycle("run_waiting_user"))
        XCTAssertEqual(CovaSSEEventType(rawName: "run_failed"), .runLifecycle("run_failed"))
    }

    func testUnknownEventIsPreservedNotDiscarded() {
        XCTAssertEqual(CovaSSEEventType(rawName: "questionnaire"), .unknown("questionnaire"))
        XCTAssertEqual(CovaSSEEventType(rawName: ""), .unknown(""))
    }

    func testRawNameRoundTrips() {
        let names = ["thinking", "text", "plan_card", "error", "done", "run_started", "song_match_plan"]
        for name in names {
            XCTAssertEqual(CovaSSEEventType(rawName: name).rawName, name)
        }
    }

    func testTextPayloadDecoding() throws {
        let frame = CovaSSEFrame(rawEventName: "thinking", payload: Data(#"{"text":"正在分析曲风"}"#.utf8))
        XCTAssertEqual(frame.event, .thinking)
        let payload = try XCTUnwrap(frame.decodePayload(CovaSSETextEventDto.self))
        XCTAssertEqual(payload.text, "正在分析曲风")
    }

    func testPlanCardPayloadDecodesAsPlanCard() throws {
        let json = Data(
            #"{"planCardId":"p1","status":"ready","title":{"selected":"A","candidates":["A"]}}"#.utf8
        )
        let frame = CovaSSEFrame(rawEventName: "plan_card", payload: json)
        XCTAssertEqual(frame.event, .planCard)
        let card = try XCTUnwrap(frame.decodePayload(OneStepPlanCardDto.self))
        XCTAssertEqual(card.planCardId, "p1")
        XCTAssertEqual(card.status, .ready)
        XCTAssertEqual(card.title?.selected, "A")
    }

    func testMalformedPayloadDecodesToNilInsteadOfThrowing() {
        let frame = CovaSSEFrame(event: .done, payload: Data("not json".utf8))
        XCTAssertNil(frame.decodePayload(CovaSSETextEventDto.self))
    }

    func testTextPayloadToleratesMissingText() throws {
        let frame = CovaSSEFrame(event: .done, payload: Data("{}".utf8))
        XCTAssertNil(try XCTUnwrap(frame.decodePayload(CovaSSETextEventDto.self)).text)
    }
}
