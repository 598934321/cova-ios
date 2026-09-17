@testable import CovaCore
import XCTest

/// TD-22：`OwnerIdentifier` 必须实际拒绝 C0/**C1**/DEL 与不可打印 Unicode（文档与实现一致）。
final class OwnerIdentifierTests: XCTestCase {
    func testRejectsC0C1DelAndNonPrintableUnicode() {
        let rejected: [(label: String, raw: String)] = [
            ("NUL", "\u{00}"),
            ("US", "\u{1F}"),
            ("DEL", "\u{7F}"),
            ("C1-0x80", "\u{80}"),
            ("NEL-0x85", "\u{85}"),
            ("C1-0x9F", "\u{9F}"),
            ("ZWSP", "\u{200B}"),
            ("LEFT-TO-RIGHT-MARK", "\u{200E}"),
            ("LINE-SEP", "\u{2028}"),
            ("PARAGRAPH-SEP", "\u{2029}"),
            ("PRIVATE-USE", "\u{E000}"),
            ("path-slash", "a/b"),
            ("backslash", "a\\b"),
            ("colon", "a:b")
        ]
        for probe in rejected {
            let owner = PrincipalID(rawValue: probe.raw)
            XCTAssertEqual(
                OwnerIdentifier.validationError(owner),
                .invalidCharacters,
                "应拒绝 \(probe.label)"
            )
            XCTAssertNil(OwnerNamespace.directoryName(for: owner), "被拒 owner 不得产生命名空间：\(probe.label)")
        }
    }

    func testAcceptsPrintableIdentifiersIncludingUnicode() {
        let accepted = ["user-0001", "COVA-0001", "a.b", "用户", "😀", "user_1"]
        for raw in accepted {
            XCTAssertNil(OwnerIdentifier.validationError(PrincipalID(rawValue: raw)), "应接受 \(raw)")
            XCTAssertNotNil(OwnerNamespace.directoryName(for: PrincipalID(rawValue: raw)), "应可命名空间化 \(raw)")
        }
    }

    func testStillRejectsEmptyAndOverlong() {
        XCTAssertEqual(OwnerIdentifier.validationError(PrincipalID(rawValue: "")), .empty)
        let tooLong = PrincipalID(rawValue: String(repeating: "a", count: OwnerIdentifier.maximumByteLength + 1))
        XCTAssertEqual(
            OwnerIdentifier.validationError(tooLong),
            .tooLong(maximum: OwnerIdentifier.maximumByteLength)
        )
    }

    func testRequireValidThrowsForC1() {
        XCTAssertThrowsError(try OwnerIdentifier.requireValid(PrincipalID(rawValue: "\u{85}")))
    }

    func testSecureStoreAndOwnerStoreShareTheStricterRule() throws {
        let store = InMemorySecureStore()
        let c1Owner = PrincipalID(rawValue: "\u{85}")
        XCTAssertThrowsError(
            try store.set(SecretString("x"), for: SecureStoreItem(principalId: c1Owner, kind: .accessToken))
        ) { error in
            XCTAssertEqual(error as? SecureStoreError, .invalidPrincipal(.invalidCharacters))
        }
    }
}
