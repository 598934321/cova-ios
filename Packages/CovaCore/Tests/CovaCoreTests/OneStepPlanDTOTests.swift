@testable import CovaCore
import XCTest

final class OneStepPlanDTOTests: XCTestCase {
    func testPlanStatusCoversExactlyTwelveContractStates() {
        XCTAssertEqual(OneStepPlanStatus.allCases.count, 12)
        XCTAssertEqual(
            Set(OneStepPlanStatus.allCases.map(\.rawValue)),
            [
                "analyzing", "ready", "patching", "starting", "generating", "media_staging",
                "demos_ready", "delivery_preparing", "rehydrating", "manual_recovery",
                "retryable_failure", "archived"
            ]
        )
    }

    func testPlanStatusDecodesEveryContractValue() throws {
        for status in OneStepPlanStatus.allCases {
            let decoded = try JSONDecoder().decode(
                OneStepPlanStatus.self,
                from: Data("\"\(status.rawValue)\"".utf8)
            )
            XCTAssertEqual(decoded, status)
        }
    }

    func testUnknownPlanStatusFailsDecoding() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(OneStepPlanStatus.self, from: Data("\"cancelled\"".utf8))
        )
    }

    func testPlanTypeDecodesContractValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"vocal\"".utf8)), .vocal)
        XCTAssertEqual(
            try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"instrumental\"".utf8)),
            .instrumental
        )
        XCTAssertThrowsError(try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"choir\"".utf8)))
    }

    func testDecodesFullPlanCardProjection() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        XCTAssertEqual(response.planCards.count, 2)

        let card = response.planCards[0]
        XCTAssertEqual(card.contractVersion, "cova.one-step-plan.v1")
        XCTAssertEqual(card.planCardId, "plan-test-0001")
        XCTAssertEqual(card.sessionId, "session-test-0001")
        XCTAssertEqual(card.cardIndex, 0)
        XCTAssertEqual(card.revision, 4)
        XCTAssertEqual(card.status, .demosReady)
        XCTAssertEqual(card.type, .vocal)
        XCTAssertEqual(card.summary, "夏日广告配乐，明亮流行")
        XCTAssertEqual(card.sourceMessage?.messageId, "msg-test-0001")
        XCTAssertEqual(card.title?.selected, "Summer Signal")
        XCTAssertEqual(card.title?.candidates?.count, 3)
        XCTAssertEqual(card.title?.pageSize, 10)
        XCTAssertEqual(card.title?.total, 50)
        XCTAssertEqual(card.style?.analysisZh?.isEmpty, false)
        XCTAssertEqual(card.style?.promptEn?.isEmpty, false)
        XCTAssertEqual(card.style?.revision, 2)
        XCTAssertEqual(card.variants?.count, 2)
        XCTAssertEqual(card.variants?[0].direction, "melody-led")
        XCTAssertEqual(card.snapshotHash, "snapshot-test")
        XCTAssertEqual(card.credits, 315)
        XCTAssertEqual(card.updatedAt, "2026-09-17T02:00:00.000Z")
    }

    func testDecodesLyricsDocumentSections() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let lyrics = try XCTUnwrap(response.planCards[0].lyrics)
        XCTAssertEqual(lyrics.source, "generated")
        XCTAssertEqual(lyrics.revision, 3)
        XCTAssertEqual(lyrics.operation, "regenerate")
        XCTAssertEqual(lyrics.sections?.count, 2)
        XCTAssertEqual(lyrics.sections?[0].type, "intro")
        XCTAssertEqual(lyrics.sections?[1].label, "副歌")
        XCTAssertEqual(lyrics.sections?[1].order, 1)
        XCTAssertEqual(lyrics.displayText?.contains("夏日信号"), true)
    }

    func testDecodesParametersAndIgnoresUnionTypedFields() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let parameters = try XCTUnwrap(response.planCards[0].parameters)
        XCTAssertEqual(parameters.operation, "create")
        XCTAssertEqual(parameters.vocalGender, "f")
        XCTAssertEqual(parameters.weirdness, 0.3)
        XCTAssertEqual(parameters.styleWeight, 0.7)
        XCTAssertEqual(parameters.targetDurationSec, 120)
        XCTAssertEqual(parameters.durationSec, 120)
        XCTAssertEqual(parameters.bpm, 118)
        XCTAssertEqual(parameters.styleTags, ["A07:instrument:钢琴"])
        XCTAssertEqual(parameters.availableCoverUploadIds, [])
    }

    func testMinimalPlanCardToleratesMissingOptionalBlocks() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let minimal = response.planCards[1]
        XCTAssertEqual(minimal.planCardId, "plan-test-0002")
        XCTAssertEqual(minimal.status, .analyzing)
        XCTAssertNil(minimal.sessionId)
        XCTAssertNil(minimal.title)
        XCTAssertNil(minimal.style)
        XCTAssertNil(minimal.lyrics)
        XCTAssertNil(minimal.parameters)
        XCTAssertNil(minimal.credits)
        XCTAssertNil(minimal.type)
        XCTAssertNil(minimal.variants)
    }

    func testPlanCardIgnoresUnknownNestedFields() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        XCTAssertEqual(response.planCards[0].planCardId, "plan-test-0001")
        XCTAssertEqual(response.planCards[0].lyrics?.sourceHash, "hash-test")
    }

    func testMissingPlanCardIdentityFailsDecoding() {
        let json = Data(#"{"planCards":[{"status":"ready"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: json))
    }
}
