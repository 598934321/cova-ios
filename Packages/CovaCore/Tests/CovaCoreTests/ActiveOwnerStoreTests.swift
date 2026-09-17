@testable import CovaCore
import Foundation
import XCTest

final class ActiveOwnerStoreTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cova-active-owner-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: - 内存实现

    func testInMemoryStoreRoundTripAndClear() throws {
        let store = InMemoryActiveOwnerStore()
        XCTAssertNil(try store.loadActiveOwner())
        try store.saveActiveOwner(PrincipalID(rawValue: "user-1"))
        XCTAssertEqual(try store.loadActiveOwner(), PrincipalID(rawValue: "user-1"))
        try store.saveActiveOwner(nil)
        XCTAssertNil(try store.loadActiveOwner())
    }

    func testInMemoryStoreRejectsInvalidOwner() {
        let store = InMemoryActiveOwnerStore()
        XCTAssertThrowsError(try store.saveActiveOwner(PrincipalID(rawValue: "a/b"))) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .invalidOwner(.invalidCharacters))
        }
        XCTAssertThrowsError(try store.saveActiveOwner(PrincipalID(rawValue: ""))) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .invalidOwner(.empty))
        }
    }

    // MARK: - 文件实现

    func testFileStoreMissingReturnsNil() throws {
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        XCTAssertNil(try store.loadActiveOwner())
    }

    func testFileStoreRoundTripAndClear() throws {
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        try store.saveActiveOwner(PrincipalID(rawValue: "user-0001"))
        XCTAssertEqual(try store.loadActiveOwner(), PrincipalID(rawValue: "user-0001"))
        // 覆盖写（换号）
        try store.saveActiveOwner(PrincipalID(rawValue: "user-0002"))
        XCTAssertEqual(try store.loadActiveOwner(), PrincipalID(rawValue: "user-0002"))
        try store.saveActiveOwner(nil)
        XCTAssertNil(try store.loadActiveOwner())
        XCTAssertNoThrow(try store.saveActiveOwner(nil), "清除缺失指针必须幂等")
    }

    func testFileStoreSupportsUnicodeOwner() throws {
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        let owner = PrincipalID(rawValue: "用户-1")
        try store.saveActiveOwner(owner)
        XCTAssertEqual(try store.loadActiveOwner(), owner)
    }

    func testFileStoreRejectsInvalidOwnerWithoutWriting() throws {
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        XCTAssertThrowsError(try store.saveActiveOwner(PrincipalID(rawValue: "\u{85}"))) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .invalidOwner(.invalidCharacters))
        }
        XCTAssertNil(try store.loadActiveOwner())
    }

    func testFileStoreReportsCorruptedPayload() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: baseDirectory.appendingPathComponent("active-owner.json"))
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        XCTAssertThrowsError(try store.loadActiveOwner()) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .decodingFailed)
        }
    }

    func testFileStoreReportsInvalidPersistedOwner() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data(#"{"principalId":"a/b"}"#.utf8)
            .write(to: baseDirectory.appendingPathComponent("active-owner.json"))
        let store = FileActiveOwnerStore(baseDirectory: baseDirectory)
        XCTAssertThrowsError(try store.loadActiveOwner()) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .invalidOwner(.invalidCharacters))
        }
    }

    func testFileStoreMapsFilesystemFailure() throws {
        let blocking = FileManager.default.temporaryDirectory
            .appendingPathComponent("cova-active-owner-blocker-\(UUID().uuidString)")
        try Data("blocker".utf8).write(to: blocking)
        defer { try? FileManager.default.removeItem(at: blocking) }
        let store = FileActiveOwnerStore(baseDirectory: blocking)
        XCTAssertThrowsError(try store.saveActiveOwner(PrincipalID(rawValue: "user-1"))) { error in
            XCTAssertEqual(error as? ActiveOwnerStoreError, .ioFailure)
        }
    }

    func testDefaultBaseDirectoryIsAvailable() {
        XCTAssertNotNil(FileActiveOwnerStore.defaultBaseDirectory())
    }

    func testErrorDescriptionsCarryNoPlaintext() {
        XCTAssertTrue(ActiveOwnerStoreError.ioFailure.description.contains("读写"))
        XCTAssertTrue(ActiveOwnerStoreError.decodingFailed.description.contains("解码"))
        XCTAssertTrue(ActiveOwnerStoreError.invalidOwner(.empty).description.contains("owner"))
    }
}
