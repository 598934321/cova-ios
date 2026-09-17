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

    func testSecretStringMirrorDoesNotExposePlaintext() {
        let plaintext = "mirror-secret-42"
        let secret = SecretString(plaintext)
        let reflected = Mirror(reflecting: secret)
        let renderedChildren = reflected.children.map { String(describing: $0.value) }
        XCTAssertFalse(renderedChildren.joined().contains(plaintext), "Mirror 泄漏 storage")
        XCTAssertFalse(reflected.children.contains { ($0.value as? String) == plaintext })
        XCTAssertTrue(renderedChildren.joined().contains("<redacted>"))
    }

    func testSecretStringDecodesFromJSONStringOnly() throws {
        let decoded = try JSONDecoder().decode(SecretString.self, from: Data(#""decoded-token""#.utf8))
        XCTAssertEqual(decoded.rawValue, "decoded-token")
        XCTAssertEqual(String(reflecting: decoded), "<redacted>")
    }

    func testSecureStoreErrorDescriptionNeverExposesSecretValue() {
        let plaintext = "super-secret-refresh-token-1234"
        let secret = SecretString(plaintext)
        let error = SecureStoreError.status(-25300)
        // 真实断言：把 secret 与 error 一起渲染，仍不得出现明文。
        let rendered = "\(secret) \(error) \([secret]) \(String(reflecting: error)) \(error.description)"
        XCTAssertFalse(rendered.contains(plaintext), "错误描述泄漏明文：\(rendered)")
        XCTAssertTrue(error.description.contains("-25300"))
    }

    // MARK: - owner 绑定：空/非法 principalId 必须拒绝（M1）

    func testInMemoryStoreRejectsEmptyAndInvalidPrincipal() {
        let store = InMemorySecureStore()
        let empty = SecureStoreItem(principalId: PrincipalID(rawValue: ""), kind: .accessToken)
        XCTAssertThrowsError(try store.set(SecretString("x"), for: empty)) { error in
            XCTAssertEqual(error as? SecureStoreError, .invalidPrincipal(.empty))
        }

        let tooLong = SecureStoreItem(
            principalId: PrincipalID(rawValue: String(repeating: "a", count: OwnerIdentifier.maximumByteLength + 1)),
            kind: .accessToken
        )
        XCTAssertThrowsError(try store.secret(for: tooLong)) { error in
            XCTAssertEqual(
                error as? SecureStoreError,
                .invalidPrincipal(.tooLong(maximum: OwnerIdentifier.maximumByteLength))
            )
        }

        let withControl = SecureStoreItem(principalId: PrincipalID(rawValue: "user\n1"), kind: .accessToken)
        XCTAssertThrowsError(try store.removeSecret(for: withControl)) { error in
            XCTAssertEqual(error as? SecureStoreError, .invalidPrincipal(.invalidCharacters))
        }

        let withSlash = SecureStoreItem(principalId: PrincipalID(rawValue: "a/b"), kind: .refreshToken)
        XCTAssertThrowsError(try store.removeAllSecrets(for: withSlash.principalId)) { error in
            XCTAssertEqual(error as? SecureStoreError, .invalidPrincipal(.invalidCharacters))
        }
    }

    func testSecureStoreErrorInvalidPrincipalDescriptionContainsNoPlaintext() {
        let error = SecureStoreError.invalidPrincipal(.empty)
        XCTAssertTrue(error.description.contains("owner"))
        XCTAssertEqual(error, .invalidPrincipal(.empty))
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
