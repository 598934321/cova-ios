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

    func testDirectoryNameEscapesUnsafePrincipalIds() {
        let traversal = OwnerNamespace.directoryName(for: PrincipalID(rawValue: "../../evil"))
        XCTAssertNotNil(traversal)
        XCTAssertTrue(traversal?.hasPrefix("owner-") == true)
        XCTAssertFalse(traversal?.contains("/") == true)
        XCTAssertFalse(traversal?.contains("\\") == true)

        let dotDot = OwnerNamespace.directoryName(for: PrincipalID(rawValue: ".."))
        XCTAssertEqual(dotDot, "owner-..")

        let unicode = OwnerNamespace.directoryName(for: PrincipalID(rawValue: "user 中文"))
        XCTAssertTrue(unicode?.hasPrefix("owner-") == true)
        XCTAssertFalse(unicode?.contains("/") == true)
    }

    func testEmptyPrincipalIdIsRejected() {
        XCTAssertNil(OwnerNamespace.directoryName(for: PrincipalID(rawValue: "")))
        XCTAssertThrowsError(
            try store.save(SampleState(plays: 1, tags: []), name: "state", owner: PrincipalID(rawValue: ""))
        ) { error in
            XCTAssertEqual(error as? OwnerStoreError, .invalidName)
        }
    }

    func testPathTraversalPrincipalStaysInsideBaseDirectory() throws {
        let evil = PrincipalID(rawValue: "../../evil")
        try store.save(SampleState(plays: 7, tags: []), name: "state", owner: evil)
        XCTAssertEqual(try store.load(SampleState.self, name: "state", owner: evil)?.plays, 7)

        // 逃逸检查：baseDirectory 之外不应出现我们写入的内容。
        let parentEscape = baseDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("evil", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentEscape.path))
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
        let directory = baseDirectory.appendingPathComponent("owner-user-a", isDirectory: true)
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
        XCTAssertTrue(OwnerStoreError.invalidName.description.contains("名称"))
        XCTAssertTrue(OwnerStoreError.encodingFailed.description.contains("编码"))
        XCTAssertTrue(OwnerStoreError.decodingFailed.description.contains("解码"))
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
