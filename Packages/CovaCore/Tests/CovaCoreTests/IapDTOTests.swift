import Foundation
import XCTest

@testable import CovaCore

/// §4.8 IAP 契约面的判据：镜像容错解码、verify 请求形状（jws 不落日志面）、
/// 核销分流（finish 权）、镜像↔ASC 对齐。
final class IapDTOTests: XCTestCase {

    // MARK: 商品镜像

    private func products(_ json: String) throws -> IapProductsResponseDto {
        try JSONDecoder().decode(IapProductsResponseDto.self, from: Data(json.utf8))
    }

    func testMirrorShapeFromWebIapTsDecodesAllSeven() throws {
        // `web/src/lib/iap.ts` `listIapProducts()` 的真实形状：四订阅 + 三 co 包。
        let json = """
        {"products": [
          {"productId":"com.covalink.subscription.creator.monthly","type":"subscription",
           "displayName":"Creator 月度订阅","priceDisplay":"¥39"},
          {"productId":"com.covalink.subscription.pro.monthly","type":"subscription",
           "displayName":"Pro 月度订阅","priceDisplay":"¥99"},
          {"productId":"com.covalink.subscription.pro.yearly","type":"subscription",
           "displayName":"Pro 年度订阅","priceDisplay":"¥899"},
          {"productId":"com.covalink.subscription.enterprise.monthly","type":"subscription",
           "displayName":"Enterprise 月度订阅","priceDisplay":"¥599"},
          {"productId":"com.covalink.credits.emergency","type":"credits",
           "displayName":"应急包 1,200","priceDisplay":"¥9.9","credits":1200},
          {"productId":"com.covalink.credits.standard","type":"credits",
           "displayName":"标准包 4,000","priceDisplay":"¥29","credits":4000},
          {"productId":"com.covalink.credits.pro","type":"credits",
           "displayName":"专业包 10,000","priceDisplay":"¥69","credits":10000}
        ]}
        """
        let response = try products(json)
        XCTAssertEqual(response.products.count, 7)
        XCTAssertEqual(response.dropped, 0)
        XCTAssertEqual(response.products.first?.productId, "com.covalink.subscription.creator.monthly")
        XCTAssertEqual(response.products.last?.credits, 10000)
    }

    /// 一行坏不掉整面：缺 productId 的行丢出来记账，其余照常。
    func testUnreadableRowsAreDroppedAndCounted() throws {
        let response = try products("""
        {"products": [
          {"productId":"a","type":"subscription"},
          {"type":"credits"},
          {"productId":"b","type":"unheard-of-kind"},
          {"productId":"c","type":"credits","credits":1200}
        ]}
        """)
        XCTAssertEqual(response.products.map(\.productId), ["a", "c"])
        XCTAssertEqual(response.dropped, 2)
    }

    func testMissingProductsKeyReadsAsEmpty() throws {
        let response = try products(#"{}"#)
        XCTAssertEqual(response.products, [])
        XCTAssertEqual(response.dropped, 0)
    }

    // MARK: verify 请求体

    func testVerifyRequestShapeAndSecretHandling() throws {
        let dto = IapVerifyRequestDto(
            transactionId: "tx-1", productId: "com.covalink.credits.standard",
            jwsTransaction: SecretString("JWS.PAYLOAD.SIG"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["transactionId", "productId", "jwsTransaction"])
        XCTAssertEqual(json["jwsTransaction"] as? String, "JWS.PAYLOAD.SIG")
        // jws 是凭证：类型收口 SecretString，描述/反射面不许把它吐出来。
        XCTAssertFalse(dto.jwsTransaction!.description.contains("JWS.PAYLOAD"))
        let withoutJws = IapVerifyRequestDto(
            transactionId: "tx-2", productId: "p", jwsTransaction: nil)
        let json2 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutJws)) as? [String: Any])
        XCTAssertEqual(Set(json2.keys), ["transactionId", "productId"],
                       "jws 缺省 = 键不送（不是送 null —— 服务端 `jwsTransaction?` 是可选位）")
    }

    // MARK: 核销分流（finish 权的唯一裁决面）

    func testDispositionByStatusCode() {
        XCTAssertEqual(IapVerifyRule.disposition(statusCode: 200), .verified)
        XCTAssertEqual(IapVerifyRule.disposition(statusCode: 201), .verified)
        XCTAssertEqual(IapVerifyRule.disposition(statusCode: 400), .refused)
        XCTAssertEqual(IapVerifyRule.disposition(statusCode: 402), .refused)
        XCTAssertEqual(IapVerifyRule.disposition(statusCode: 401), .unauthenticated)
        // 404/418/500/503/其它：全部「待重验」（没有明确拒绝的证据前不 finish）。
        for status in [404, 409, 418, 429, 500, 502, 503, 599] {
            XCTAssertEqual(
                IapVerifyRule.disposition(statusCode: status), .pendingVerification,
                "\(status) 不该把已付款交易 finish 掉")
        }
        XCTAssertEqual(IapVerifyRule.transportFailure, .pendingVerification)
    }

    /// 「finish 的分支」恰好是三类：verified/refused/unauthenticated ——
    /// 编译期穷举，新增 case 会立刻要求重新表态（这正是枚举不加 default 的意义）。
    func testFinishableDispositionsAreExactlyTheTerminalOnes() {
        func shouldFinish(_ d: IapVerifyDisposition) -> Bool {
            switch d {
            case .verified, .refused, .unauthenticated: return true
            case .pendingVerification: return false
            }
        }
        XCTAssertTrue(shouldFinish(.verified))
        XCTAssertTrue(shouldFinish(.refused))
        XCTAssertTrue(shouldFinish(.unauthenticated))
        XCTAssertFalse(shouldFinish(.pendingVerification))
    }

    // MARK: 镜像 ↔ ASC 对齐

    private func mirror(_ id: String, type: IapProductDto.Kind = .subscription)
        -> IapProductDto {
        IapProductDto(
            productId: id, type: type, displayName: "n-\(id)",
            priceDisplay: "p-\(id)", credits: type == .credits ? 100 : nil)
    }

    func testAlignmentKeepsMirrorOrderAndBucketsTheGaps() {
        let response = IapProductsResponseDto(
            products: [mirror("a"), mirror("b"), mirror("c")], dropped: 1)
        let alignment = IapAlignment.align(
            mirror: response, storeProductIDs: ["b", "c", "z-store-only"])
        XCTAssertEqual(alignment.purchasable.map(\.productId), ["b", "c"],
                       "可买面按镜像序，不按 ASC 序")
        XCTAssertEqual(alignment.mirrorOnly.map(\.productId), ["a"])
        XCTAssertEqual(alignment.storeOnly, ["z-store-only"])
        XCTAssertEqual(alignment.unreadable, 1)
    }

    /// 两边都空的输入不产出任何可买面（对齐没有默认商品可臆造）。
    func testEmptyInputsYieldNothing() {
        let alignment = IapAlignment.align(
            mirror: IapProductsResponseDto(products: []), storeProductIDs: [])
        XCTAssertTrue(alignment.purchasable.isEmpty)
        XCTAssertTrue(alignment.mirrorOnly.isEmpty)
        XCTAssertTrue(alignment.storeOnly.isEmpty)
        XCTAssertEqual(alignment.unreadable, 0)
    }
}
