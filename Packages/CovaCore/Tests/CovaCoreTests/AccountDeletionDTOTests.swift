import Foundation
import XCTest

@testable import CovaCore

/// §7 #4 注销契约面的判据（2026-10-02 对齐 web v2.65.0 `POST /api/auth/delete-account`）：
/// 请求体只剩幂等键、响应信封容错、幂等键型绑定。
final class AccountDeletionDTOTests: XCTestCase {

    // MARK: 请求体：只有幂等键一个字段，且键型钉死

    func testDeleteRequestCarriesOnlyCanonicalKey() throws {
        let token = IdempotentRequestToken(operation: .accountDeletion)
        let body = try AccountDeletionRequestDto(token: token)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys), ["idempotencyKey"],
            "注销端点不读体，体里只留硬边界 5 的那把键——多一个键都是客户端在发明契约")
        XCTAssertEqual(json["idempotencyKey"] as? String, token.key.rawValue)
        XCTAssertTrue(token.key.isCanonical(for: .accountDeletion))
    }

    func testDeleteRequestRejectsForeignOperation() {
        // 拿别的操作的键来发注销 = 串操作，编译期管不住就在构造期拦。
        XCTAssertThrowsError(
            try AccountDeletionRequestDto(
                token: IdempotentRequestToken(operation: .playReport))
        ) { XCTAssertEqual($0 as? IdempotencyKeyError, .operationMismatch) }
    }

    /// 键型进 `isCanonical` 闭环：前缀 + 32 位小写 hex 都要对。
    func testAccountDeletionKeyHasCanonicalShape() {
        let key = IdempotencyKeyGenerator.generate(for: .accountDeletion)
        XCTAssertTrue(key.rawValue.hasPrefix("cova-account-delete-"))
        XCTAssertTrue(key.isCanonical(for: .accountDeletion))
        XCTAssertFalse(key.isCanonical(for: .playReport))
    }

    // MARK: 响应信封容错（`{ok:true}` 是实测形态；缺键/异形不炸）

    private func response(_ json: String) throws -> AccountDeletionResponseDto {
        try JSONDecoder().decode(AccountDeletionResponseDto.self, from: Data(json.utf8))
    }

    func testResponseDecodesRealShape() throws {
        let dto = try response(#"{"ok":true}"#)
        XCTAssertEqual(dto.ok, true)
        XCTAssertNil(dto.message)
    }

    func testResponseToleratesMessageAndUnknownKeys() throws {
        let dto = try response(
            #"{"ok":true,"message":"已注销","pendingUntil":"2026-10-08","extra":{"x":1}}"#)
        XCTAssertEqual(dto.ok, true)
        XCTAssertEqual(dto.message, "已注销")
        // 历史需求里的 pendingUntil 键即使出现也**不进模型**——契约没有冷静期，
        // 收了它就会有代码路径以为自己能撤销。
    }

    func testResponseToleratesMissingEnvelope() throws {
        let dto = try response(#"{}"#)
        XCTAssertNil(dto.ok)
        XCTAssertNil(dto.message)
    }

    func testTypeMismatchedKeysAreTolerated() throws {
        // 数字/对象形态的字段不把它炸成解码错——键值读不出来就是 nil。
        let dto = try response(#"{"ok":1,"message":{"x":1}}"#)
        XCTAssertNil(dto.ok)
        XCTAssertNil(dto.message)
    }

    /// `ok:false` 也要能解（分流层决定怎么读，DTO 不替它裁决）。
    func testResponseDecodesFalseOk() throws {
        let dto = try response(#"{"ok":false,"message":"请先登录"}"#)
        XCTAssertEqual(dto.ok, false)
        XCTAssertEqual(dto.message, "请先登录")
    }
}
