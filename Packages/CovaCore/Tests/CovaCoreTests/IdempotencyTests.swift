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
    private func canonicalKey(_ operation: IdempotentOperation, hex: String = String(repeating: "a", count: 32)) throws -> IdempotencyKey {
        try IdempotencyKey(validating: operation.keyPrefix + hex)
    }

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

    func testIsCanonicalIsOperationSpecificAndShapeSensitive() throws {
        let checkout = try canonicalKey(.downloadCheckout)
        XCTAssertTrue(checkout.isCanonical(for: .downloadCheckout))
        XCTAssertFalse(checkout.isCanonical(for: .planStart))
        XCTAssertFalse(checkout.isCanonical(for: .playReport))

        let shortHex = try IdempotencyKey(
            validating: IdempotentOperation.planStart.keyPrefix + String(repeating: "a", count: 31)
        )
        XCTAssertFalse(shortHex.isCanonical(for: .planStart))

        let longHex = try IdempotencyKey(
            validating: IdempotentOperation.planStart.keyPrefix + String(repeating: "a", count: 33)
        )
        XCTAssertFalse(longHex.isCanonical(for: .planStart))

        let uppercase = try IdempotencyKey(
            validating: IdempotentOperation.planStart.keyPrefix + String(repeating: "A", count: 32)
        )
        XCTAssertFalse(uppercase.isCanonical(for: .planStart))

        let nonHex = try IdempotencyKey(
            validating: IdempotentOperation.planStart.keyPrefix + String(repeating: "g", count: 32)
        )
        XCTAssertFalse(nonHex.isCanonical(for: .planStart))
    }

    // MARK: - 运行时校验（m2）

    func testKeyRejectsEmptyShortLongControlAndIllegalCharacters() {
        XCTAssertThrowsError(try IdempotencyKey(validating: "")) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .empty)
        }
        XCTAssertThrowsError(try IdempotencyKey(validating: "short")) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .tooShort(minimum: IdempotencyKey.minimumLength))
        }
        XCTAssertThrowsError(try IdempotencyKey(validating: String(repeating: "a", count: IdempotencyKey.maximumLength + 1))) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .tooLong(maximum: IdempotencyKey.maximumLength))
        }
        XCTAssertThrowsError(try IdempotencyKey(validating: "key\r\nX-Injected: 1")) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .controlCharacters)
        }
        XCTAssertThrowsError(try IdempotencyKey(validating: "key with space")) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .invalidCharacters)
        }
        XCTAssertThrowsError(try IdempotencyKey(validating: "key/with/slash")) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .invalidCharacters)
        }
    }

    func testTokenRejectsOperationKeyMismatch() throws {
        let checkoutKey = try canonicalKey(.downloadCheckout)
        XCTAssertThrowsError(try IdempotentRequestToken(operation: .playReport, key: checkoutKey)) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
        XCTAssertThrowsError(try IdempotentRequestToken(operation: .planStart, key: checkoutKey)) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
        XCTAssertNoThrow(try IdempotentRequestToken(operation: .downloadCheckout, key: checkoutKey))
    }

    func testKeyDecodingRejectsInvalidValues() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdempotencyKey.self, from: Data(#""bad key with space""#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdempotencyKey.self, from: Data(#""x""#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdempotencyKey.self, from: Data(#"{"rawValue":"x"}"#.utf8))
        )
    }

    func testKeyEncodesAsSingleJSONString() throws {
        let key = try IdempotencyKey(validating: "play-0001")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(key), as: UTF8.self), #""play-0001""#)
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

    func testRetryReusesSameKeyForDownloadCheckout() throws {
        let token = IdempotentRequestToken(operation: .downloadCheckout)
        let first = try DownloadCheckoutRequestDto(trackIds: ["library-1"], token: token)
        let retry = try DownloadCheckoutRequestDto(trackIds: ["library-1"], token: token)
        let replay = try DownloadCheckoutRequestDto(trackIds: ["library-1"], token: token)
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        XCTAssertEqual(retry.idempotencyKey, replay.idempotencyKey)
        XCTAssertEqual(first.idempotencyKey, token.key)
        XCTAssertTrue(token.key.isCanonical(for: .downloadCheckout))
    }

    func testRetryReusesSameKeyForPlanStart() throws {
        let token = IdempotentRequestToken(operation: .planStart)
        let request = try OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "hash-1",
            token: token
        )
        let retried = try OneStepPlanStartRequestDto(
            sessionId: "session-1",
            planCardId: "plan-1",
            revision: 4,
            snapshotHash: "hash-1",
            token: token
        )
        XCTAssertEqual(request.idempotencyKey, retried.idempotencyKey)
        XCTAssertTrue(token.key.isCanonical(for: .planStart))
    }

    /// 一次逻辑播放 = 一个键，重试/重放复用同键（D8）。
    ///
    /// 旧用例在此钉的是 `source == "app-ios"`，而该值会被服务端 400 拒绝（E2 实测），
    /// 故按更正后的契约改写：同一次播放复用同键时，**归因来源也必须同值** ——
    /// 服务端对同一 `idempotencyKey` 额外比对 `(trackId, source)`，换来源即 409。
    func testRetryReusesSameKeyForPlayReport() throws {
        let token = IdempotentRequestToken(operation: .playReport)
        let request = try PlayReportRequestDto(trackId: "library-1", token: token)
        let retried = try PlayReportRequestDto(trackId: "library-1", token: token)
        XCTAssertEqual(request.idempotencyKey, retried.idempotencyKey)
        XCTAssertEqual(request.source, .player)
        XCTAssertEqual(request.source, retried.source)
        XCTAssertTrue(token.key.isCanonical(for: .playReport))
    }

    /// 显式传入的来源在同键重放时保持可复现（不依赖调用顺序或全局状态）。
    func testPlayReportSourceIsCarriedVerbatimOnRetries() throws {
        let token = IdempotentRequestToken(operation: .playReport)
        let first = try PlayReportRequestDto(trackId: "library-1", source: .playlist, token: token)
        let replay = try PlayReportRequestDto(trackId: "library-1", source: .playlist, token: token)
        XCTAssertEqual(first.source, replay.source)
        // 按**键值**比对而不是编码字节：JSONEncoder 不保证对象键的输出顺序
        // （同一份代码在 iOS 上就会写出不同字节序），比字节会把这条用例写成抛硬币。
        let firstBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any]
        )
        let replayBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(replay)) as? [String: Any]
        )
        XCTAssertEqual(firstBody as NSDictionary, replayBody as NSDictionary)
        XCTAssertEqual(firstBody["source"] as? String, "playlist")
    }

    /// TD-24：写请求 DTO 拒绝 operation↔key 错配（DTO 层不再接受任意键）。
    func testWriteRequestDTOsRejectOperationMismatch() throws {
        let checkoutToken = IdempotentRequestToken(operation: .downloadCheckout)
        let planToken = IdempotentRequestToken(operation: .planStart)
        let playToken = IdempotentRequestToken(operation: .playReport)

        XCTAssertThrowsError(try DownloadCheckoutRequestDto(trackIds: ["t"], token: planToken)) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
        XCTAssertThrowsError(try OneStepPlanStartRequestDto(
            sessionId: "s", planCardId: "p", revision: 1, snapshotHash: "h", token: playToken
        )) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
        XCTAssertThrowsError(try PlayReportRequestDto(trackId: "t", token: checkoutToken)) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
    }

    func testTwoLogicalOperationsGetDifferentKeys() {
        let first = IdempotentRequestToken(operation: .planStart)
        let second = IdempotentRequestToken(operation: .planStart)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(first.operation, second.operation)
    }

    func testExplicitKeyTokenPreservesProvidedKey() throws {
        let key = try canonicalKey(.playReport, hex: String(repeating: "0", count: 32))
        let token = try IdempotentRequestToken(operation: .playReport, key: key)
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
