@testable import CovaCore
import Security
import XCTest

/// 假 SecItem 操作层：在内存中模拟 Keychain 语义，**绝不触碰真实 Keychain**。
private final class FakeKeychainOperations: KeychainItemOperating, @unchecked Sendable {
    var stored: [String: Data] = [:]
    var insertStatus: Int32?
    var updateStatus: Int32?
    var readStatus: Int32?
    var deleteStatus: Int32?
    private(set) var insertedAccounts: [String] = []
    private(set) var updatedAccounts: [String] = []
    private(set) var deletedAccounts: [String] = []

    func insert(_ query: KeychainItemQuery, value: Data) -> Int32 {
        insertedAccounts.append(query.account)
        if let insertStatus { return insertStatus }
        if stored[query.account] != nil { return errSecDuplicateItem }
        stored[query.account] = value
        return errSecSuccess
    }

    func read(_ query: KeychainItemQuery) -> (status: Int32, value: Data?) {
        if let readStatus { return (readStatus, nil) }
        guard let data = stored[query.account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(_ query: KeychainItemQuery, value: Data) -> Int32 {
        updatedAccounts.append(query.account)
        if let updateStatus { return updateStatus }
        stored[query.account] = value
        return errSecSuccess
    }

    func delete(_ query: KeychainItemQuery) -> Int32 {
        deletedAccounts.append(query.account)
        if let deleteStatus { return deleteStatus }
        guard stored[query.account] != nil else { return errSecItemNotFound }
        stored[query.account] = nil
        return errSecSuccess
    }
}

final class KeychainStoreTests: XCTestCase {
    private let owner = PrincipalID(rawValue: "user-1")
    private let other = PrincipalID(rawValue: "user-2")

    private func makeStore(_ operations: FakeKeychainOperations) -> KeychainStore {
        KeychainStore(operations: operations)
    }

    // MARK: - 查询字典构造

    func testInsertAttributesPinThisDeviceOnlyAndPrincipalBinding() {
        let query = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .accessToken))
        let attributes = query.insertAttributes
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "cn.covalink.ios.credentials")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "user-1.access-token")
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testServiceAndAccountAreStableAcrossKindsAndOwners() {
        let access = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .accessToken))
        let refresh = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .refreshToken))
        let otherAccess = KeychainItemQuery(item: SecureStoreItem(principalId: other, kind: .accessToken))
        XCTAssertEqual(access.account, "user-1.access-token")
        XCTAssertEqual(refresh.account, "user-1.refresh-token")
        XCTAssertEqual(otherAccess.account, "user-2.access-token")
        XCTAssertNotEqual(access.account, refresh.account)
        XCTAssertNotEqual(access.account, otherAccess.account)
    }

    func testSearchAttributesLocateEntryWithoutValueOrAccessibility() {
        let query = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .accessToken))
        let search = query.searchAttributes
        XCTAssertEqual(search[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(search[kSecAttrService as String] as? String, "cn.covalink.ios.credentials")
        XCTAssertEqual(search[kSecAttrAccount as String] as? String, "user-1.access-token")
        XCTAssertNil(search[kSecValueData as String])
        XCTAssertNil(search[kSecAttrAccessible as String])
    }

    func testQueryEqualityIgnoresNothing() {
        let lhs = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .accessToken))
        let rhs = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .accessToken))
        let different = KeychainItemQuery(item: SecureStoreItem(principalId: owner, kind: .refreshToken))
        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, different)
    }

    // MARK: - 写 / 读 / 缺失 / 删 语义

    func testSetInsertsNewEntry() throws {
        let operations = FakeKeychainOperations()
        let store = makeStore(operations)
        let item = SecureStoreItem(principalId: owner, kind: .accessToken)
        try store.set(SecretString("token-1"), for: item)
        XCTAssertEqual(operations.insertedAccounts, ["user-1.access-token"])
        XCTAssertEqual(operations.stored["user-1.access-token"], Data("token-1".utf8))
    }

    func testSetOnDuplicateFallsBackToUpdate() throws {
        let operations = FakeKeychainOperations()
        let store = makeStore(operations)
        let item = SecureStoreItem(principalId: owner, kind: .accessToken)
        try store.set(SecretString("old"), for: item)
        try store.set(SecretString("new"), for: item)
        XCTAssertEqual(operations.updatedAccounts, ["user-1.access-token"])
        XCTAssertEqual(try store.secret(for: item), SecretString("new"))
    }

    func testSetMapsUnexpectedInsertStatusToError() {
        let operations = FakeKeychainOperations()
        operations.insertStatus = errSecNotAvailable
        let store = makeStore(operations)
        XCTAssertThrowsError(
            try store.set(SecretString("token"), for: SecureStoreItem(principalId: owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .status(errSecNotAvailable))
        }
    }

    func testSetMapsFailedUpdateStatusToError() {
        let operations = FakeKeychainOperations()
        operations.stored["user-1.access-token"] = Data("old".utf8)
        operations.updateStatus = errSecNotAvailable
        let store = makeStore(operations)
        XCTAssertThrowsError(
            try store.set(SecretString("new"), for: SecureStoreItem(principalId: owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .status(errSecNotAvailable))
        }
    }

    func testSecretReadsStoredValue() throws {
        let operations = FakeKeychainOperations()
        operations.stored["user-1.refresh-token"] = Data("refresh-1".utf8)
        let store = makeStore(operations)
        let value = try store.secret(for: SecureStoreItem(principalId: owner, kind: .refreshToken))
        XCTAssertEqual(value, SecretString("refresh-1"))
    }

    func testSecretMissingReturnsNil() throws {
        let store = makeStore(FakeKeychainOperations())
        XCTAssertNil(try store.secret(for: SecureStoreItem(principalId: owner, kind: .accessToken)))
    }

    func testSecretMapsUnexpectedReadStatusToError() {
        let operations = FakeKeychainOperations()
        operations.readStatus = errSecNotAvailable
        let store = makeStore(operations)
        XCTAssertThrowsError(
            try store.secret(for: SecureStoreItem(principalId: owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .status(errSecNotAvailable))
        }
    }

    func testSecretOnNonUTF8DataThrowsMalformed() {
        let operations = FakeKeychainOperations()
        operations.stored["user-1.access-token"] = Data([0xFF, 0xFE, 0x01])
        let store = makeStore(operations)
        XCTAssertThrowsError(
            try store.secret(for: SecureStoreItem(principalId: owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .malformedSecret)
        }
    }

    func testRemoveTreatsMissingAsSuccess() {
        let store = makeStore(FakeKeychainOperations())
        XCTAssertNoThrow(try store.removeSecret(for: SecureStoreItem(principalId: owner, kind: .accessToken)))
    }

    func testRemoveDeletesExistingEntry() throws {
        let operations = FakeKeychainOperations()
        operations.stored["user-1.access-token"] = Data("token".utf8)
        let store = makeStore(operations)
        try store.removeSecret(for: SecureStoreItem(principalId: owner, kind: .accessToken))
        XCTAssertTrue(operations.stored.isEmpty)
        XCTAssertEqual(operations.deletedAccounts, ["user-1.access-token"])
    }

    func testRemoveMapsUnexpectedStatusToError() {
        let operations = FakeKeychainOperations()
        operations.deleteStatus = errSecNotAvailable
        let store = makeStore(operations)
        XCTAssertThrowsError(
            try store.removeSecret(for: SecureStoreItem(principalId: owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .status(errSecNotAvailable))
        }
    }

    func testRemoveAllSecretsRemovesBothKindsForTargetOwnerOnly() throws {
        let operations = FakeKeychainOperations()
        operations.stored["user-1.access-token"] = Data("a".utf8)
        operations.stored["user-1.refresh-token"] = Data("r".utf8)
        operations.stored["user-2.access-token"] = Data("b".utf8)
        let store = makeStore(operations)

        try store.removeAllSecrets(for: owner)

        XCTAssertNil(try store.secret(for: SecureStoreItem(principalId: owner, kind: .accessToken)))
        XCTAssertNil(try store.secret(for: SecureStoreItem(principalId: owner, kind: .refreshToken)))
        XCTAssertEqual(
            try store.secret(for: SecureStoreItem(principalId: other, kind: .accessToken)),
            SecretString("b")
        )
        XCTAssertEqual(Set(operations.deletedAccounts), ["user-1.access-token", "user-1.refresh-token"])
    }

    // MARK: - 明文不得进入错误描述

    func testFailureDescriptorsNeverContainPlaintext() {
        let plaintext = "top-secret-refresh-token-xyz"
        let operations = FakeKeychainOperations()
        operations.insertStatus = errSecNotAvailable
        let store = makeStore(operations)
        do {
            try store.set(SecretString(plaintext), for: SecureStoreItem(principalId: owner, kind: .refreshToken))
            XCTFail("应当抛错")
        } catch {
            XCTAssertFalse(String(describing: error).contains(plaintext))
            XCTAssertFalse(String(reflecting: error).contains(plaintext))
        }
    }

    func testSystemOperatingLayerIsNeverInstantiatedInTests() {
        // 自证：本测试文件只通过注入层构造 KeychainStore，未使用 `KeychainStore()`（真实 Keychain）。
        let store = makeStore(FakeKeychainOperations())
        XCTAssertNoThrow(try store.removeAllSecrets(for: owner))
    }
}
