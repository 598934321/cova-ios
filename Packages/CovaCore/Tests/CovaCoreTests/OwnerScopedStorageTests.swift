@testable import CovaCore
import Foundation
import XCTest

private struct SampleState: Codable, Equatable {
    var plays: Int
    var tags: [String]
}

final class OwnerScopedStorageTests: XCTestCase {
    private var baseDirectory: URL!
    private var store: OwnerScopedJSONStore!
    private let ownerA = PrincipalID(rawValue: "user-a")
    private let ownerB = PrincipalID(rawValue: "user-b")

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cova-core-ownerstore-\(UUID().uuidString)", isDirectory: true)
        store = OwnerScopedJSONStore(baseDirectory: baseDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func testSaveThenLoadRoundTrip() throws {
        let state = SampleState(plays: 3, tags: ["scene", "mood"])
        try store.save(state, name: "state", owner: ownerA)
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: ownerA), state)
    }

    func testLoadMissingReturnsNil() throws {
        XCTAssertNil(try store.load(SampleState.self, name: "state", owner: ownerA))
    }

    func testSaveOverwritesExistingValue() throws {
        try store.save(SampleState(plays: 1, tags: []), name: "state", owner: ownerA)
        try store.save(SampleState(plays: 9, tags: ["x"]), name: "state", owner: ownerA)
        XCTAssertEqual(
            try store.load(SampleState.self, name: "state", owner: ownerA),
            SampleState(plays: 9, tags: ["x"])
        )
    }

    func testTwoPrincipalsAreIsolated() throws {
        try store.save(SampleState(plays: 1, tags: ["a"]), name: "state", owner: ownerA)
        try store.save(SampleState(plays: 2, tags: ["b"]), name: "state", owner: ownerB)

        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: ownerA)?.plays, 1)
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: ownerB)?.plays, 2)
    }

    /// m3：大小写不敏感卷（macOS 默认 APFS）下，仅大小写不同的 owner 也必须互不可见。
    func testCaseOnlyDifferentOwnersStayIsolatedOnCaseInsensitiveFilesystem() throws {
        let upper = PrincipalID(rawValue: "User")
        let lower = PrincipalID(rawValue: "user")
        XCTAssertNotEqual(OwnerNamespace.directoryName(for: upper), OwnerNamespace.directoryName(for: lower))

        try store.save(SampleState(plays: 11, tags: []), name: "state", owner: upper)
        try store.save(SampleState(plays: 22, tags: []), name: "state", owner: lower)

        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: upper)?.plays, 11)
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: lower)?.plays, 22)

        try store.removeAll(owner: upper)
        XCTAssertNil(try store.load(SampleState.self, name: "state", owner: upper))
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: lower)?.plays, 22)
    }

    func testRemoveAllOnlyAffectsTargetOwner() throws {
        try store.save(SampleState(plays: 1, tags: []), name: "state", owner: ownerA)
        try store.save(SampleState(plays: 1, tags: []), name: "other", owner: ownerA)
        try store.save(SampleState(plays: 2, tags: []), name: "state", owner: ownerB)

        try store.removeAll(owner: ownerA)

        XCTAssertNil(try store.load(SampleState.self, name: "state", owner: ownerA))
        XCTAssertNil(try store.load(SampleState.self, name: "other", owner: ownerA))
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: ownerB)?.plays, 2)
    }

    func testRemoveAllOnUnknownOwnerIsIdempotent() {
        XCTAssertNoThrow(try store.removeAll(owner: ownerA))
        XCTAssertNoThrow(try store.removeAll(owner: ownerA))
    }

    func testRemoveSingleNameOnlyAffectsThatName() throws {
        try store.save(SampleState(plays: 1, tags: []), name: "state", owner: ownerA)
        try store.save(SampleState(plays: 2, tags: []), name: "queue", owner: ownerA)

        try store.remove(name: "state", owner: ownerA)

        XCTAssertNil(try store.load(SampleState.self, name: "state", owner: ownerA))
        XCTAssertEqual(try store.load(SampleState.self, name: "queue", owner: ownerA)?.plays, 2)
    }

    func testRemoveMissingNameIsIdempotent() {
        XCTAssertNoThrow(try store.remove(name: "state", owner: ownerA))
    }

    // MARK: - 命名空间安全

    func testDirectoryNameIsHexEscaped() {
        let traversal = OwnerNamespace.directoryName(for: PrincipalID(rawValue: ".."))
        XCTAssertEqual(traversal, "owner-2e2e")
        XCTAssertFalse(traversal?.contains(".") == true)

        let unicode = OwnerNamespace.directoryName(for: PrincipalID(rawValue: "用户"))
        XCTAssertTrue(unicode?.hasPrefix("owner-") == true)
        XCTAssertFalse(unicode?.contains("/") == true)
        // 仅 hex 字符构成
        XCTAssertTrue(unicode?.dropFirst(OwnerNamespace.directoryPrefix.count).allSatisfy(\.isHexDigit) == true)
    }

    func testPrincipalIdWithPathSeparatorsIsRejected() {
        for raw in ["../../evil", "a/b", "a\\b", "a:b", "user\n1"] {
            let owner = PrincipalID(rawValue: raw)
            XCTAssertThrowsError(try store.save(SampleState(plays: 1, tags: []), name: "state", owner: owner)) { error in
                XCTAssertEqual(error as? OwnerStoreError, .invalidOwner(.invalidCharacters), "owner=\(raw)")
            }
        }
    }

    func testEmptyPrincipalIdIsRejected() {
        XCTAssertNil(OwnerNamespace.directoryName(for: PrincipalID(rawValue: "")))
        XCTAssertThrowsError(
            try store.save(SampleState(plays: 1, tags: []), name: "state", owner: PrincipalID(rawValue: ""))
        ) { error in
            XCTAssertEqual(error as? OwnerStoreError, .invalidOwner(.empty))
        }
        XCTAssertThrowsError(try store.removeAll(owner: PrincipalID(rawValue: ""))) { error in
            XCTAssertEqual(error as? OwnerStoreError, .invalidOwner(.empty))
        }
    }

    /// m4：owner 超长必须在校验层被拒绝（而不是让文件系统抛未映射错误）。
    func testOverlongPrincipalIdIsRejectedBeforeFilesystem() {
        let tooLong = PrincipalID(rawValue: String(repeating: "a", count: OwnerIdentifier.maximumByteLength + 1))
        XCTAssertThrowsError(try store.save(SampleState(plays: 1, tags: []), name: "state", owner: tooLong)) { error in
            XCTAssertEqual(
                error as? OwnerStoreError,
                .invalidOwner(.tooLong(maximum: OwnerIdentifier.maximumByteLength))
            )
        }
        XCTAssertThrowsError(try store.load(SampleState.self, name: "state", owner: tooLong)) { error in
            XCTAssertEqual(
                error as? OwnerStoreError,
                .invalidOwner(.tooLong(maximum: OwnerIdentifier.maximumByteLength))
            )
        }
    }

    /// m4：底层文件系统错误必须映射为 `OwnerStoreError`（而非裸 `NSError`）。
    func testFilesystemFailureIsMappedToOwnerStoreError() throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cova-core-blocker-\(UUID().uuidString)")
        try Data("blocker".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }

        // baseDirectory 是一个普通文件 → 创建 owner 目录必然失败。
        let brokenStore = OwnerScopedJSONStore(baseDirectory: blockingFile)
        XCTAssertThrowsError(
            try brokenStore.save(SampleState(plays: 1, tags: []), name: "state", owner: ownerA)
        ) { error in
            XCTAssertEqual(error as? OwnerStoreError, .ioFailure)
        }
    }

    func testInvalidNamesAreRejectedForAllOperations() {
        let invalid = ["", "..", ".", "a/b", "a\\b", "a:b", String(repeating: "x", count: 200)]
        for name in invalid {
            XCTAssertThrowsError(try store.save(SampleState(plays: 1, tags: []), name: name, owner: ownerA)) { error in
                XCTAssertEqual(error as? OwnerStoreError, .invalidName, "name=\(name)")
            }
            XCTAssertThrowsError(try store.load(SampleState.self, name: name, owner: ownerA)) { error in
                XCTAssertEqual(error as? OwnerStoreError, .invalidName, "name=\(name)")
            }
            XCTAssertThrowsError(try store.remove(name: name, owner: ownerA)) { error in
                XCTAssertEqual(error as? OwnerStoreError, .invalidName, "name=\(name)")
            }
        }
    }

    // MARK: - 损坏数据

    func testCorruptedJSONThrowsDecodingFailed() throws {
        let namespace = try XCTUnwrap(OwnerNamespace.directoryName(for: ownerA))
        let directory = baseDirectory.appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try store.load(SampleState.self, name: "state", owner: ownerA)) { error in
            XCTAssertEqual(error as? OwnerStoreError, .decodingFailed)
        }
    }

    func testDefaultBaseDirectoryIsAvailable() {
        XCTAssertNotNil(OwnerScopedJSONStore.defaultBaseDirectory())
    }

    func testOwnerStoreErrorDescriptions() {
        XCTAssertTrue(OwnerStoreError.invalidOwner(.empty).description.contains("owner"))
        XCTAssertTrue(OwnerStoreError.invalidName.description.contains("名称"))
        XCTAssertTrue(OwnerStoreError.encodingFailed.description.contains("编码"))
        XCTAssertTrue(OwnerStoreError.decodingFailed.description.contains("解码"))
        XCTAssertTrue(OwnerStoreError.ioFailure.description.contains("读写"))
    }

    func testEncodingFailureIsMapped() {
        struct Unencodable: Codable {
            init() {}

            init(from decoder: Decoder) throws {
                throw OwnerStoreError.decodingFailed
            }

            func encode(to encoder: Encoder) throws {
                throw OwnerStoreError.encodingFailed
            }
        }

        XCTAssertThrowsError(try store.save(Unencodable(), name: "state", owner: ownerA)) { error in
            XCTAssertEqual(error as? OwnerStoreError, .encodingFailed)
        }
    }
}
