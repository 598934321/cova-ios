import CovaCore
import Foundation
import XCTest

private struct LibraryState: Codable, Equatable {
    var plays: Int
}

private actor RecordingCleaner: LocalSessionStateClearing {
    private var playQueueClearCount = 0
    private var clearedMediaOwners: [PrincipalID] = []

    func snapshot() -> (playQueueClears: Int, mediaOwners: [PrincipalID]) {
        (playQueueClearCount, clearedMediaOwners)
    }

    func clearPlayQueue() async {
        playQueueClearCount += 1
    }

    func clearPrivateMediaCache(owner: PrincipalID) async {
        clearedMediaOwners.append(owner)
    }
}

final class SessionLifecycleTests: XCTestCase {
    private var baseDirectory: URL!
    private var ownerStore: OwnerScopedJSONStore!
    private let ownerA = PrincipalID(rawValue: "user-a")
    private let ownerB = PrincipalID(rawValue: "user-b")
    private let stateName = "library-state"

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cova-core-lifecycle-\(UUID().uuidString)", isDirectory: true)
        ownerStore = OwnerScopedJSONStore(baseDirectory: baseDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func makeLifecycle(
        secureStore: InMemorySecureStore,
        cleaner: RecordingCleaner
    ) -> SessionLifecycle {
        SessionLifecycle(secureStore: secureStore, ownerStore: ownerStore, cleaners: [cleaner])
    }

    func testBeginSessionAdvancesGenerationAndSetsOwner() async {
        let lifecycle = makeLifecycle(secureStore: InMemorySecureStore(), cleaner: RecordingCleaner())
        let before = await lifecycle.currentGeneration()
        let after = await lifecycle.beginSession(owner: ownerA)
        XCTAssertEqual(after.value, before.value + 1)
        let owner = await lifecycle.currentOwner()
        XCTAssertEqual(owner, ownerA)
    }

    func testSignOutAdvancesGenerationAndClearsOwnerScopedState() async throws {
        let secureStore = InMemorySecureStore()
        try secureStore.set(SecretString("a-access"), for: SecureStoreItem(principalId: ownerA, kind: .accessToken))
        try secureStore.set(SecretString("a-refresh"), for: SecureStoreItem(principalId: ownerA, kind: .refreshToken))
        try secureStore.set(SecretString("b-access"), for: SecureStoreItem(principalId: ownerB, kind: .accessToken))
        try ownerStore.save(LibraryState(plays: 1), name: stateName, owner: ownerA)
        try ownerStore.save(LibraryState(plays: 2), name: stateName, owner: ownerB)
        let cleaner = RecordingCleaner()
        let lifecycle = makeLifecycle(secureStore: secureStore, cleaner: cleaner)
        _ = await lifecycle.beginSession(owner: ownerA)
        let inFlightGeneration = await lifecycle.currentGeneration()

        try await lifecycle.signOut(owner: ownerA)

        let afterSignOut = await lifecycle.currentGeneration()
        XCTAssertGreaterThan(afterSignOut, inFlightGeneration)
        let staleStillCurrent = await lifecycle.isCurrent(inFlightGeneration)
        XCTAssertFalse(staleStillCurrent)

        XCTAssertNil(try secureStore.secret(for: SecureStoreItem(principalId: ownerA, kind: .accessToken)))
        XCTAssertNil(try secureStore.secret(for: SecureStoreItem(principalId: ownerA, kind: .refreshToken)))
        XCTAssertEqual(
            try secureStore.secret(for: SecureStoreItem(principalId: ownerB, kind: .accessToken)),
            SecretString("b-access")
        )
        XCTAssertNil(try ownerStore.load(LibraryState.self, name: stateName, owner: ownerA))
        XCTAssertEqual(try ownerStore.load(LibraryState.self, name: stateName, owner: ownerB)?.plays, 2)
        let cleanerSnapshot = await cleaner.snapshot()
        XCTAssertEqual(cleanerSnapshot.playQueueClears, 1)
        XCTAssertEqual(cleanerSnapshot.mediaOwners, [ownerA])
        let activeOwner = await lifecycle.currentOwner()
        XCTAssertNil(activeOwner)
    }

    func testSignOutInvalidatesInFlightGenerationValidation() async throws {
        let lifecycle = makeLifecycle(secureStore: InMemorySecureStore(), cleaner: RecordingCleaner())
        _ = await lifecycle.beginSession(owner: ownerA)
        let inFlight = await lifecycle.currentGeneration()

        try await lifecycle.signOut(owner: ownerA)

        do {
            try await lifecycle.validate(inFlight)
            XCTFail("登出后的在途 generation 必须失效")
        } catch let error as StaleSessionError {
            XCTAssertEqual(error.expected, inFlight)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
        let newGeneration = await lifecycle.currentGeneration()
        do {
            try await lifecycle.validate(newGeneration)
        } catch {
            XCTFail("新 generation 不应被判为过期：\(error)")
        }
    }

    func testSwitchAccountClearsPreviousOwnerAndActivatesNew() async throws {
        let secureStore = InMemorySecureStore()
        try secureStore.set(SecretString("a-access"), for: SecureStoreItem(principalId: ownerA, kind: .accessToken))
        try secureStore.set(SecretString("b-access"), for: SecureStoreItem(principalId: ownerB, kind: .accessToken))
        try ownerStore.save(LibraryState(plays: 1), name: stateName, owner: ownerA)
        try ownerStore.save(LibraryState(plays: 2), name: stateName, owner: ownerB)
        let cleaner = RecordingCleaner()
        let lifecycle = makeLifecycle(secureStore: secureStore, cleaner: cleaner)
        _ = await lifecycle.beginSession(owner: ownerA)
        let inFlightGeneration = await lifecycle.currentGeneration()

        try await lifecycle.switchAccount(from: ownerA, to: ownerB)

        XCTAssertNil(try secureStore.secret(for: SecureStoreItem(principalId: ownerA, kind: .accessToken)))
        XCTAssertEqual(
            try secureStore.secret(for: SecureStoreItem(principalId: ownerB, kind: .accessToken)),
            SecretString("b-access")
        )
        XCTAssertNil(try ownerStore.load(LibraryState.self, name: stateName, owner: ownerA))
        XCTAssertEqual(try ownerStore.load(LibraryState.self, name: stateName, owner: ownerB)?.plays, 2)
        let cleanerSnapshot = await cleaner.snapshot()
        XCTAssertEqual(cleanerSnapshot.mediaOwners, [ownerA])
        let activeOwner = await lifecycle.currentOwner()
        XCTAssertEqual(activeOwner, ownerB)
        let staleStillCurrent = await lifecycle.isCurrent(inFlightGeneration)
        XCTAssertFalse(staleStillCurrent)
    }

    func testSignOutWorksWithoutCleaners() async throws {
        let lifecycle = SessionLifecycle(secureStore: InMemorySecureStore(), ownerStore: ownerStore)
        try await lifecycle.signOut(owner: ownerA)
        let generation = await lifecycle.currentGeneration()
        XCTAssertEqual(generation.value, 1)
    }

    func testSignOutFromOneOwnerDoesNotClearOtherOwnersCredentials() async throws {
        let secureStore = InMemorySecureStore()
        try secureStore.set(SecretString("a-access"), for: SecureStoreItem(principalId: ownerA, kind: .accessToken))
        try secureStore.set(SecretString("b-refresh"), for: SecureStoreItem(principalId: ownerB, kind: .refreshToken))
        let lifecycle = makeLifecycle(secureStore: secureStore, cleaner: RecordingCleaner())

        try await lifecycle.signOut(owner: ownerA)

        XCTAssertNil(try secureStore.secret(for: SecureStoreItem(principalId: ownerA, kind: .accessToken)))
        XCTAssertEqual(
            try secureStore.secret(for: SecureStoreItem(principalId: ownerB, kind: .refreshToken)),
            SecretString("b-refresh")
        )
    }
}
