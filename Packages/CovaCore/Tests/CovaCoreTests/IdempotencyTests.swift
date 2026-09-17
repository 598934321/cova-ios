import CovaCore
import XCTest

/// SplitMix64：确定性随机源，仅用于测试幂等键生成（生产用 SystemRandomNumberGenerator）。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class IdempotencyTests: XCTestCase {
    func testGeneratedKeyMatchesOperationPrefixAndCanonicalShape() {
        for operation in IdempotentOperation.allCases {
            let key = IdempotencyKeyGenerator.generate(for: operation)
            XCTAssertTrue(key.rawValue.hasPrefix("cova-\(operation.rawValue)-"), "前缀不符：\(key)")
            XCTAssertTrue(key.isCanonical(for: operation), "非规范形态：\(key)")
            XCTAssertEqual(
                key.rawValue.count,
                operation.keyPrefix.count + IdempotencyKeyGenerator.hexLength
            )
        }
    }

    func testKeySuffixIsLowercaseHexOnly() {
        let key = IdempotencyKeyGenerator.generate(for: .playReport)
        let suffix = key.rawValue.dropFirst(IdempotentOperation.playReport.keyPrefix.count)
        XCTAssertEqual(suffix.count, 32)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testDifferentOperationsAreNotCanonicalForEachOther() {
        let checkout = IdempotencyKeyGenerator.generate(for: .downloadCheckout)
        XCTAssertFalse(checkout.isCanonical(for: .planStart))
        XCTAssertFalse(checkout.isCanonical(for: .playReport))
    }

    func testIsCanonicalRejectsMalformedKeys() {
        XCTAssertFalse(IdempotencyKey(rawValue: "").isCanonical(for: .planStart))
        XCTAssertFalse(IdempotencyKey(rawValue: "plan-start-abc").isCanonical(for: .planStart))
        XCTAssertFalse(IdempotencyKey(rawValue: "cova-plan-start-").isCanonical(for: .planStart))
        XCTAssertFalse(
            IdempotencyKey(rawValue: "cova-plan-start-" + String(repeating: "a", count: 31))
                .isCanonical(for: .planStart)
        )
        XCTAssertFalse(
            IdempotencyKey(rawValue: "cova-plan-start-" + String(repeating: "a", count: 33))
                .isCanonical(for: .planStart)
        )
        XCTAssertFalse(
            IdempotencyKey(rawValue: "cova-plan-start-" + String(repeating: "A", count: 32))
                .isCanonical(for: .planStart)
        )
        XCTAssertFalse(
            IdempotencyKey(rawValue: "cova-plan-start-" + String(repeating: "g", count: 32))
                .isCanonical(for: .planStart)
        )
        XCTAssertFalse(
            IdempotencyKey(rawValue: "cova-download-checkout-" + String(repeating: "0", count: 32))
                .isCanonical(for: .planStart)
        )
    }

    func testSeededGeneratorIsDeterministic() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        var other = SeededGenerator(seed: 43)
        let keyA = IdempotencyKeyGenerator.generate(for: .planStart, using: &first)
        let keyB = IdempotencyKeyGenerator.generate(for: .planStart, using: &second)
        let keyC = IdempotencyKeyGenerator.generate(for: .planStart, using: &other)
        XCTAssertEqual(keyA, keyB)
        XCTAssertNotEqual(keyA, keyC)
        XCTAssertTrue(keyA.isCanonical(for: .planStart))
    }

    func testTwoGenerationRunsProduceDistinctKeys() {
        var keys = Set<IdempotencyKey>()
        for _ in 0..<300 {
            keys.insert(IdempotencyKeyGenerator.generate(for: .downloadCheckout))
        }
        XCTAssertEqual(keys.count, 300)
    }

    func testConcurrentGenerationDoesNotCollide() async {
        let keys = await withTaskGroup(of: IdempotencyKey.self, returning: [IdempotencyKey].self) { group in
            for _ in 0..<200 {
                group.addTask { IdempotencyKeyGenerator.generate(for: .playReport) }
            }
            var collected: [IdempotencyKey] = []
            for await key in group {
                collected.append(key)
            }
            return collected
        }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.isCanonical(for: .playReport) })
    }

    // MARK: - 一次逻辑操作一个键；重试/重放复用同一个键

    func testRetryReusesSameKeyForDownloadCheckout() {
        let token = IdempotentRequestToken(operation: .downloadCheckout)
        let first = DownloadCheckoutRequestDto(trackIds: ["library-1"], idempotencyKey: token.key.rawValue)
        let retry = DownloadCheckoutRequestDto(trackIds: ["library-1"], idempotencyKey: token.key.rawValue)
        let replay = DownloadCheckoutRequestDto(trackIds: ["library-1"], idempotencyKey: token.key.rawValue)
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(retry.idempotencyKey, replay.idempotencyKey)
        XCTAssertEqual(token.key.rawValue, first.idempotencyKey)
        XCTAssertTrue(token.key.isCanonical(for: .downloadCheckout))
    }

    func testRetryReusesSameKeyForPlanStart() {
        let token = IdempotentRequestToken(operation: .planStart)
        let request = OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "hash-1",
            idempotencyKey: token.key.rawValue
        )
        let retried = OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "hash-1",
            idempotencyKey: token.key.rawValue
        )
        XCTAssertEqual(request.idempotencyKey, retried.idempotencyKey)
        XCTAssertTrue(token.key.isCanonical(for: .planStart))
    }

    func testRetryReusesSameKeyForPlayReport() {
        let token = IdempotentRequestToken(operation: .playReport)
        let request = PlayReportRequestDto(trackId: "library-1", idempotencyKey: token.key.rawValue)
        let retried = PlayReportRequestDto(trackId: "library-1", idempotencyKey: token.key.rawValue)
        XCTAssertEqual(request.idempotencyKey, retried.idempotencyKey)
        XCTAssertEqual(request.source, "app-ios")
        XCTAssertTrue(token.key.isCanonical(for: .playReport))
    }

    func testTwoLogicalOperationsGetDifferentKeys() {
        let first = IdempotentRequestToken(operation: .planStart)
        let second = IdempotentRequestToken(operation: .planStart)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(first.operation, second.operation)
    }

    func testExplicitKeyTokenPreservesProvidedKey() {
        let key = IdempotencyKey(rawValue: "cova-play-report-" + String(repeating: "0", count: 32))
        let token = IdempotentRequestToken(operation: .playReport, key: key)
        XCTAssertEqual(token.key, key)
    }

    func testKeyCodableRoundTrip() throws {
        let key = IdempotencyKeyGenerator.generate(for: .downloadCheckout)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(IdempotencyKey.self, from: data)
        XCTAssertEqual(decoded, key)
    }

    func testKeyDescriptionIsRawValue() {
        let key = IdempotencyKeyGenerator.generate(for: .playReport)
        XCTAssertEqual(key.description, key.rawValue)
        XCTAssertEqual("\(key)", key.rawValue)
    }
}
