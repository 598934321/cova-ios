import CovaCore
import Foundation
import XCTest

private struct LibraryState: Codable, Equatable {
    var plays: Int
}

private struct CleanupProbeError: Error, Equatable {}

private actor RecordingCleaner: LocalSessionStateClearing {
    private var playQueueClearCount = 0
    private var clearedMediaOwners: [PrincipalID] = []
    private var tornDownOwners: [PrincipalID] = []

    func snapshot() -> (playQueueClears: Int, mediaOwners: [PrincipalID], teardownOwners: [PrincipalID]) {
        (playQueueClearCount, clearedMediaOwners, tornDownOwners)
    }

    func clearPlayQueue() async throws {
        playQueueClearCount += 1
    }

    func clearPrivateMediaCache(owner: PrincipalID) async throws {
        clearedMediaOwners.append(owner)
    }

    func tearDownPlayback(owner: PrincipalID) async throws {
        tornDownOwners.append(owner)
    }
}

/// 按需让某些清理步骤失败，用于验证 best-effort 不短路（m5）。
private actor FailingCleaner: LocalSessionStateClearing {
    enum Step: Hashable, Sendable {
        case playQueue
        case privateMediaCache
        case playbackTeardown
    }

    private let failingSteps: Set<Step>
    private var executed: [Step] = []

    init(failingSteps: Set<Step>) {
        self.failingSteps = failingSteps
    }

    func executedSteps() -> [Step] {
        executed
    }

    func clearPlayQueue() async throws {
        executed.append(.playQueue)
        if failingSteps.contains(.playQueue) { throw CleanupProbeError() }
    }

    func clearPrivateMediaCache(owner: PrincipalID) async throws {
        executed.append(.privateMediaCache)
        if failingSteps.contains(.privateMediaCache) { throw CleanupProbeError() }
    }

    func tearDownPlayback(owner: PrincipalID) async throws {
        executed.append(.playbackTeardown)
        if failingSteps.contains(.playbackTeardown) { throw CleanupProbeError() }
    }
}

private struct FailingSecureStore: SecureStore {
    func set(_ secret: SecretString, for item: SecureStoreItem) throws { throw CleanupProbeError() }
    func secret(for item: SecureStoreItem) throws -> SecretString? { throw CleanupProbeError() }
    func removeSecret(for item: SecureStoreItem) throws { throw CleanupProbeError() }
    func removeAllSecrets(for principalId: PrincipalID) throws { throw CleanupProbeError() }
}

private struct FailingOwnerStore: OwnerScopedStoring {
    func load<Value: Codable>(_ type: Value.Type, name: String, owner: PrincipalID) throws -> Value? {
        throw CleanupProbeError()
    }

    func save<Value: Codable>(_ value: Value, name: String, owner: PrincipalID) throws {
        throw CleanupProbeError()
    }

    func remove(name: String, owner: PrincipalID) throws {
        throw CleanupProbeError()
    }

    func removeAll(owner: PrincipalID) throws {
        throw CleanupProbeError()
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
        let snapshot = await cleaner.snapshot()
        XCTAssertEqual(snapshot.playQueueClears, 1)
        XCTAssertEqual(snapshot.mediaOwners, [ownerA])
        XCTAssertEqual(snapshot.teardownOwners, [ownerA])
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
        let snapshot = await cleaner.snapshot()
        XCTAssertEqual(snapshot.mediaOwners, [ownerA])
        XCTAssertEqual(snapshot.teardownOwners, [ownerA])
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

    // MARK: - m5：best-effort，不短路，聚合上报

    func testSignOutRunsAllCleanupStepsEvenWhenSomeFail() async throws {
        let cleaner = FailingCleaner(failingSteps: [.playQueue, .playbackTeardown])
        let lifecycle = SessionLifecycle(
            secureStore: FailingSecureStore(),
            ownerStore: FailingOwnerStore(),
            cleaners: [cleaner]
        )
        _ = await lifecycle.beginSession(owner: ownerA)

        do {
            try await lifecycle.signOut(owner: ownerA)
            XCTFail("应当聚合上报清理失败")
        } catch let failure as SessionCleanupFailure {
            XCTAssertEqual(
                Set(failure.failedComponents),
                [.credentials, .ownerData, .playQueue, .playbackTeardown]
            )
            XCTAssertFalse(failure.failedComponents.contains(.privateMediaCache))
            XCTAssertTrue(failure.description.contains("credentials"))
        }

        let executed = await cleaner.executedSteps()
        XCTAssertEqual(Set(executed), [.playQueue, .privateMediaCache, .playbackTeardown])

        // 清理阶段失败不应阻止 generation 推进 / activeOwner 清空
        let generation = await lifecycle.currentGeneration()
        XCTAssertEqual(generation.value, 2)
        let owner = await lifecycle.currentOwner()
        XCTAssertNil(owner)
    }

    func testSwitchAccountStillSwitchesOwnerWhenCleanupFails() async throws {
        let cleaner = FailingCleaner(failingSteps: [.privateMediaCache])
        let lifecycle = SessionLifecycle(
            secureStore: FailingSecureStore(),
            ownerStore: FailingOwnerStore(),
            cleaners: [cleaner]
        )

        do {
            try await lifecycle.switchAccount(from: ownerA, to: ownerB)
            XCTFail("应当聚合上报清理失败")
        } catch let failure as SessionCleanupFailure {
            XCTAssertEqual(Set(failure.failedComponents), [.credentials, .ownerData, .privateMediaCache])
        }
        let owner = await lifecycle.currentOwner()
        XCTAssertEqual(owner, ownerB)
    }
}
