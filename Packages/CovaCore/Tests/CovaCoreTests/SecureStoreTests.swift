import CovaCore
import XCTest

final class SecureStoreTests: XCTestCase {
    private let ownerA = PrincipalID(rawValue: "user-a")
    private let ownerB = PrincipalID(rawValue: "user-b")

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySecureStore()
        let item = SecureStoreItem(principalId: ownerA, kind: .accessToken)
        try store.set(SecretString("access-1"), for: item)
        XCTAssertEqual(try store.secret(for: item), SecretString("access-1"))
    }

    func testInMemoryStoreMissingReturnsNil() throws {
        let store = InMemorySecureStore()
        let item = SecureStoreItem(principalId: ownerA, kind: .refreshToken)
        XCTAssertNil(try store.secret(for: item))
    }

    func testInMemoryStoreOverwritesExistingValue() throws {
        let store = InMemorySecureStore()
        let item = SecureStoreItem(principalId: ownerA, kind: .accessToken)
        try store.set(SecretString("old"), for: item)
        try store.set(SecretString("new"), for: item)
        XCTAssertEqual(try store.secret(for: item), SecretString("new"))
    }

    func testInMemoryStoreRemoveIsIdempotent() throws {
        let store = InMemorySecureStore()
        let item = SecureStoreItem(principalId: ownerA, kind: .accessToken)
        try store.set(SecretString("token"), for: item)
        try store.removeSecret(for: item)
        XCTAssertNil(try store.secret(for: item))
        XCTAssertNoThrow(try store.removeSecret(for: item))
    }

    func testRemoveAllSecretsIsScopedToPrincipal() throws {
        let store = InMemorySecureStore()
        let aAccess = SecureStoreItem(principalId: ownerA, kind: .accessToken)
        let aRefresh = SecureStoreItem(principalId: ownerA, kind: .refreshToken)
        let bAccess = SecureStoreItem(principalId: ownerB, kind: .accessToken)
        try store.set(SecretString("a-access"), for: aAccess)
        try store.set(SecretString("a-refresh"), for: aRefresh)
        try store.set(SecretString("b-access"), for: bAccess)

        try store.removeAllSecrets(for: ownerA)

        XCTAssertNil(try store.secret(for: aAccess))
        XCTAssertNil(try store.secret(for: aRefresh))
        XCTAssertEqual(try store.secret(for: bAccess), SecretString("b-access"))
    }

    // MARK: - 凭证安全：任何描述都不得带出明文

    func testSecretStringDescriptionsNeverExposePlaintext() {
        let plaintext = "super-secret-access-token-9f3a"
        let secret = SecretString(plaintext)
        let surfaces = [
            String(describing: secret),
            String(reflecting: secret),
            "\(secret)",
            String(describing: [secret]),
            String(describing: Optional(secret))
        ]
        for surface in surfaces {
            XCTAssertFalse(surface.contains(plaintext), "描述泄漏明文：\(surface)")
        }
        XCTAssertEqual(secret.description, "<redacted>")
        XCTAssertEqual(secret.debugDescription, "<redacted>")
        XCTAssertEqual(secret.rawValue, plaintext)
    }

    func testSecureStoreErrorDescriptionNeverExposesPlaintext() {
        let plaintext = "super-secret-refresh-token-1234"
        let surfaces = [
            String(describing: SecureStoreError.status(-25300)),
            String(reflecting: SecureStoreError.status(-25300)),
            String(describing: SecureStoreError.malformedSecret)
        ]
        for surface in surfaces {
            XCTAssertFalse(surface.contains(plaintext))
        }
        XCTAssertTrue(SecureStoreError.status(-25300).description.contains("-25300"))
    }

    func testSecureStoreItemIdentityIncludesPrincipalAndKind() {
        let access = SecureStoreItem(principalId: ownerA, kind: .accessToken)
        XCTAssertEqual(access, SecureStoreItem(principalId: ownerA, kind: .accessToken))
        XCTAssertNotEqual(access, SecureStoreItem(principalId: ownerA, kind: .refreshToken))
        XCTAssertNotEqual(access, SecureStoreItem(principalId: ownerB, kind: .accessToken))
    }

    func testSecretStringEqualityAndValueSemantics() {
        XCTAssertEqual(SecretString("x"), SecretString("x"))
        XCTAssertNotEqual(SecretString("x"), SecretString("y"))
    }

    func testPrincipalIDEmptyFlag() {
        XCTAssertTrue(PrincipalID(rawValue: "").isEmpty)
        XCTAssertFalse(PrincipalID(rawValue: "user-a").isEmpty)
    }
}
