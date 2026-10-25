@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/me/credits/ledger` 的 `wallet` 段（2026-10-26 补）。
///
/// 生产 2.77.61 逐字核对：`me/credits/ledger/route.ts:88-90` 回
/// `{wallet:{balance, purchasedCredits, purchasedCreditsExpiresAt}, entries}`。
/// 本文件钉三件事：① 有这一段就逐值读到；② 没有这一段不算坏响应（旧服务端/形状漂移）；
/// ③ `wallet` 出事**不许连累 `entries`** —— 流水页的主数据是流水，不是钱包。
final class LedgerWalletDTOTests: XCTestCase {

    private func decode(_ json: String) throws -> CreditLedgerPageDto {
        try JSONDecoder().decode(CreditLedgerPageDto.self, from: Data(json.utf8))
    }

    func testWalletIsDecodedWhenServerProvidesIt() throws {
        let page = try decode(#"""
        {"wallet":{"balance":1234,"purchasedCredits":1000,
          "purchasedCreditsExpiresAt":"2027-01-01T00:00:00.000Z"},
         "entries":[{"id":"l1","amount":-20,"balanceAfter":1234,"reason":"cova_one_step_generation",
                     "reasonLabel":"一步创作","jobId":"job-1","unlinked":false,
                     "createdAt":"2026-10-25T10:00:00.000Z"}]}
        """#)
        XCTAssertEqual(page.wallet?.balance, 1234)
        XCTAssertEqual(page.wallet?.purchasedCredits, 1000)
        XCTAssertEqual(page.wallet?.purchasedCreditsExpiresAt, "2027-01-01T00:00:00.000Z")
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.unreadableItemCount, 0)
    }

    /// 旧服务端（2.77.61 之前）没有这一段 —— 整段缺席是**合法响应**，不是坏形状。
    func testMissingWalletIsNotAnError() throws {
        let page = try decode(#"{"entries":[]}"#)
        XCTAssertNil(page.wallet)
        XCTAssertTrue(page.entries.isEmpty)
    }

    /// `wallet` 形状坏了（字符串 / null / 嵌套怪异）也只退回 nil，`entries` 照旧读到。
    func testMalformedWalletDoesNotKillTheEntries() throws {
        for wallet in [#""wallet":"oops""#, #""wallet":null"#, #""wallet":{"balance":"NaN"}"#] {
            let page = try decode(
                "{" + wallet + #","entries":[{"id":"l1","amount":-1,"balanceAfter":9}]}"#
            )
            XCTAssertNil(page.wallet, wallet)
            XCTAssertEqual(page.entries.count, 1, "流水不许被钱包连累：\(wallet)")
        }
    }

    /// 三个值都缺的 `wallet`（服务端只回 `{}`）⇒ 全 nil，**不填 0**（0 会被印成「余额 0」）。
    func testEmptyWalletNeverInventsZero() throws {
        let page = try decode(#"{"wallet":{},"entries":[]}"#)
        XCTAssertNotNil(page.wallet, "空对象仍然是一段 wallet：它存在，只是每格都没给")
        XCTAssertNil(page.wallet?.balance)
        XCTAssertNil(page.wallet?.purchasedCredits)
        XCTAssertNil(page.wallet?.purchasedCreditsExpiresAt)
    }

    /// `entries` 仍是最硬的一格：缺键/非数组照旧**抛**（空流水与读不懂必须分得开）。
    func testEntriesStayMandatory() {
        XCTAssertThrowsError(try decode(#"{"wallet":{"balance":1}}"#))
        XCTAssertThrowsError(try decode(#"{"wallet":{"balance":1},"entries":"oops"}"#))
    }
}
