import CovaCore
import XCTest

final class SessionGenerationTests: XCTestCase {
    func testInitialGenerationIsZero() async {
        let tracker = SessionGenerationTracker()
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot, .initial)
        XCTAssertEqual(snapshot.value, 0)
    }

    func testInitWithCustomGeneration() async {
        let tracker = SessionGenerationTracker(initial: SessionGeneration(value: 41))
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.value, 41)
    }

    func testAdvanceIncrementsMonotonically() async {
        let tracker = SessionGenerationTracker()
        let first = await tracker.advance()
        let second = await tracker.advance()
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 2)
        XCTAssertLessThan(first, second)
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot, second)
    }

    func testIsCurrentInvalidatedAfterAdvance() async {
        let tracker = SessionGenerationTracker()
        let before = await tracker.snapshot()
        _ = await tracker.advance()
        let afterAdvance = await tracker.snapshot()
        let beforeStillCurrent = await tracker.isCurrent(before)
        let afterStillCurrent = await tracker.isCurrent(afterAdvance)
        XCTAssertFalse(beforeStillCurrent)
        XCTAssertTrue(afterStillCurrent)
    }

    func testValidateThrowsStaleSessionErrorForOldGeneration() async {
        let tracker = SessionGenerationTracker()
        let stale = await tracker.snapshot()
        _ = await tracker.advance()
        let current = await tracker.snapshot()

        do {
            try await tracker.validate(stale)
            XCTFail("应抛 StaleSessionError")
        } catch let error as StaleSessionError {
            XCTAssertEqual(error.expected, stale)
            XCTAssertEqual(error.actual, current)
            XCTAssertTrue(error.description.contains("gen-0"))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testValidateAcceptsCurrentGeneration() async {
        let tracker = SessionGenerationTracker()
        let current = await tracker.snapshot()
        do {
            try await tracker.validate(current)
        } catch {
            XCTFail("当前 generation 不应抛错：\(error)")
        }
    }

    func testConcurrentAdvancesAreUniqueAndMonotonic() async {
        let tracker = SessionGenerationTracker()
        let values = await withTaskGroup(of: SessionGeneration.self, returning: [SessionGeneration].self) { group in
            for _ in 0..<200 {
                group.addTask { await tracker.advance() }
            }
            var collected: [SessionGeneration] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }
        XCTAssertEqual(values.count, 200)
        XCTAssertEqual(Set(values.map(\.value)).count, 200)
        XCTAssertEqual(values.map(\.value).sorted(), Array(1...200).map(UInt64.init))
    }

    func testAdvancedValueAndDescription() {
        let generation = SessionGeneration(value: 7)
        XCTAssertEqual(generation.advanced().value, 8)
        XCTAssertEqual(generation.description, "gen-7")
        XCTAssertLessThan(SessionGeneration(value: 1), SessionGeneration(value: 2))
    }
}
