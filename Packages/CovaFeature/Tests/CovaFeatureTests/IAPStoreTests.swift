@testable import CovaFeature
import CovaCore
import Foundation
import XCTest

/// `IAPService`（HTTP 腿）与 `IAPStore`（编排）的判据。
///
/// 零真实网络、零真实 StoreKit：`IapStorefront` 协议把 `Product.products` /
/// `purchase` / `finish` 全隔开，钉的是**编排纪律**——
/// 「什么情况下 `finish` 被调用」「verify 各落点对应哪句话」「恢复购买走哪些集」。
final class IAPStoreTests: XCTestCase {

    // MARK: 假件

    /// StoreKit 接缝的假实现：记账（买了什么、finish 了哪些 id、sync 了几次），
    /// 出队由用例脚本驱动。
    private final class FakeStorefront: IapStorefront, @unchecked Sendable {
        nonisolated(unsafe) var priceTable: [String: String] = [:]
        nonisolated(unsafe) var purchaseResult: IapPurchaseResult = .failed
        nonisolated(unsafe) var unfinished: [IapStoredTransaction] = []
        nonisolated(unsafe) var entitlements: [IapStoredTransaction] = []
        nonisolated(unsafe) var latest: [String: IapStoredTransaction] = [:]
        nonisolated(unsafe) var priceError: Error?
        nonisolated(unsafe) var syncError: Error?
        nonisolated(unsafe) private(set) var finished: [String] = []
        nonisolated(unsafe) private(set) var purchases: [String] = []
        nonisolated(unsafe) private(set) var syncs = 0

        func prices(for productIDs: [String]) async throws -> [String: String] {
            if let priceError { throw priceError }
            return priceTable.filter { productIDs.contains($0.key) }
        }
        func purchase(productID: String) async throws -> IapPurchaseResult {
            purchases.append(productID)
            return purchaseResult
        }
        func unfinishedTransactions() async -> [IapStoredTransaction] { unfinished }
        func currentEntitlements() async -> [IapStoredTransaction] { entitlements }
        func latestTransaction(productID: String) async -> IapStoredTransaction? {
            latest[productID]
        }
        func finish(transactionID: String) async { finished.append(transactionID) }
        func sync() async throws {
            syncs += 1
            if let syncError { throw syncError }
        }
        var updates: AsyncStream<IapPurchaseResult> { AsyncStream { $0.finish() } }
    }

    private struct NoCredentials: APICredentialProviding {
        func currentSession() async throws -> AuthSessionSnapshot? { nil }
        func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
            throw CovaAPIError.unauthorized(apiCode: nil)
        }
    }

    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse
        private let handler: Handler
        nonisolated(unsafe) private var recorded: [HTTPRequest] = []
        init(_ handler: @escaping Handler) { self.handler = handler }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.append(request)
            return handler(request)
        }
        var requests: [HTTPRequest] { recorded }
    }

    /// 装配：假 storefront + 假传输层 + 核销成功计数。
    private func store(
        verifyStatus: Int, storefront: FakeStorefront = FakeStorefront()
    ) -> (IAPStore, StubTransport, FulfillmentLog) {
        let transport = StubTransport { _ in
            HTTPResponse(statusCode: verifyStatus, body: Data(#"{"message":"ok"}"#.utf8))
        }
        let log = FulfillmentLog()
        let store = IAPStore(
            storefront: storefront,
            service: IAPService(
                client: CovaAPIClient(transport: transport, credentials: NoCredentials())),
            onFulfilled: { tx in log.record(tx.transactionID) }
        )
        return (store, transport, log)
    }

    /// onFulfilled 的收件箱（@Sendable 闭包 ⇒ 需要一个可跨域的可变账）。
    private final class FulfillmentLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    private let tx = IapStoredTransaction(
        productID: "com.covalink.credits.standard",
        transactionID: "tx-9",
        jws: SecretString("JWS"))

    // MARK: verify 出站形状

    func testVerifyPostsExactContractShape() async throws {
        let (store, transport, _) = store(verifyStatus: 200)
        _ = await store.settle(tx)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/iap/verify")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["transactionId", "productId", "jwsTransaction"],
                       "核销请求不带客户端幂等键（幂等 = 服务端 transaction_id UNIQUE）")
        XCTAssertEqual(body["transactionId"] as? String, "tx-9")
        XCTAssertEqual(body["jwsTransaction"] as? String, "JWS")
    }

    // MARK: settle 分流 → finish 纪律（§4.8 的核心判据）

    func testVerifiedFinishesAndFiresFulfillment() async throws {
        let fake = FakeStorefront()
        let (store, _, log) = store(verifyStatus: 200, storefront: fake)
        let outcome = await store.settle(tx)
        XCTAssertEqual(outcome, .fulfilled)
        XCTAssertEqual(fake.finished, ["tx-9"], "verify 200 才允许 finish")
        XCTAssertEqual(log.all, ["tx-9"], "核销成功必须回调刷权益")
    }

    func testRefusedAlsoFinishesButDoesNotFulfill() async throws {
        for status in [400, 402] {
            let fake = FakeStorefront()
            let (store, _, log) = store(verifyStatus: status, storefront: fake)
            let outcome = await store.settle(tx)
            XCTAssertEqual(outcome, .refused)
            XCTAssertEqual(fake.finished, ["tx-9"],
                           "\(status) 是明确拒绝 ⇒ finish 阻断 Apple 侧重试风暴")
            XCTAssertTrue(log.all.isEmpty, "核销被拒不该触发权益刷新")
        }
    }

    func testUnauthenticatedFinishesAndKeepsItSilent() async throws {
        let fake = FakeStorefront()
        let (store, _, log) = store(verifyStatus: 401, storefront: fake)
        let outcome = await store.settle(tx)
        XCTAssertEqual(outcome, .unauthenticated)
        XCTAssertEqual(fake.finished, ["tx-9"])
        XCTAssertTrue(log.all.isEmpty)
    }

    /// 503（验签通道故障，§7 #56 的当前形态）与未知 4xx：**绝不 finish**。
    func testPendingVerificationNeverFinishes() async throws {
        for status in [503, 500, 404, 599] {
            let fake = FakeStorefront()
            let (store, _, log) = store(verifyStatus: status, storefront: fake)
            let outcome = await store.settle(tx)
            XCTAssertEqual(outcome, .pendingVerification)
            XCTAssertTrue(fake.finished.isEmpty,
                          "\(status) 下 finish = 把已付款交易从 Apple 账上抹掉")
            XCTAssertTrue(log.all.isEmpty)
        }
    }

    /// verify 传输层抛错（离线/超时）：同样不 finish。
    func testTransportFailureDuringVerifyDoesNotFinish() async throws {
        struct Offline: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                throw URLError(.notConnectedToInternet)
            }
        }
        let fake = FakeStorefront()
        let log = FulfillmentLog()
        let store = IAPStore(
            storefront: fake,
            service: IAPService(
                client: CovaAPIClient(transport: Offline(), credentials: NoCredentials())),
            onFulfilled: { tx in log.record(tx.transactionID) })
        let outcome = await store.settle(tx)
            XCTAssertEqual(outcome, .pendingVerification)
        XCTAssertTrue(fake.finished.isEmpty)
    }

    // MARK: purchase 编排

    func testPurchaseSuccessFlowsThroughVerify() async throws {
        let fake = FakeStorefront()
        fake.purchaseResult = .success(tx)
        let (store, transport, log) = store(verifyStatus: 200, storefront: fake)
        let outcome = await store.purchase(productID: tx.productID)
        XCTAssertEqual(outcome, .fulfilled)
        XCTAssertEqual(fake.purchases, [tx.productID])
        XCTAssertEqual(transport.requests.count, 1, "买到的交易必须走一次 verify")
        XCTAssertEqual(fake.finished, ["tx-9"])
        XCTAssertEqual(log.all, ["tx-9"])
    }

    func testPurchasePendingAndCancelledNeverReachVerify() async throws {
        for result in [IapPurchaseResult.pending, .userCancelled] {
            let fake = FakeStorefront()
            fake.purchaseResult = result
            let (store, transport, _) = store(verifyStatus: 200, storefront: fake)
            let outcome = await store.purchase(productID: "p")
            XCTAssertEqual(
                outcome, result == .pending ? .pendingApproval : .cancelled)
            XCTAssertEqual(transport.requests.count, 0,
                           "待审批/取消根本没成交 ⇒ 不许发核销请求")
            XCTAssertTrue(fake.finished.isEmpty)
        }
    }

    func testPurchaseStoreKitFailureSkipsVerify() async throws {
        let fake = FakeStorefront()
        fake.purchaseResult = .failed
        let (store, transport, _) = store(verifyStatus: 200, storefront: fake)
        let outcome = await store.purchase(productID: "p")
            XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: 恢复购买（AppStore.sync + latest(for:) + unfinished/entitlements 三路并入）

    func testRestoreCoversLatestForEachProductAndUnfinished() async throws {
        let fake = FakeStorefront()
        fake.unfinished = [tx]
        fake.latest["com.covalink.subscription.pro.yearly"] = IapStoredTransaction(
            productID: "com.covalink.subscription.pro.yearly",
            transactionID: "tx-sub", jws: SecretString("J2"))
        let (store, transport, log) = store(verifyStatus: 200, storefront: fake)
        let outcome = await store.restore(
            productIDs: [tx.productID, "com.covalink.subscription.pro.yearly"])
        XCTAssertEqual(fake.syncs, 1, "恢复第一步必须是 AppStore.sync()")
        XCTAssertEqual(outcome, .allFulfilled(count: 2))
        XCTAssertEqual(Set(fake.finished), ["tx-9", "tx-sub"])
        XCTAssertEqual(transport.requests.count, 2, "两笔交易各走一次 verify")
        XCTAssertEqual(Set(log.all), ["tx-9", "tx-sub"])
    }

    func testRestoreEmptySetSaysNothingToRestore() async throws {
        let fake = FakeStorefront()
        let (store, transport, _) = store(verifyStatus: 200, storefront: fake)
        let outcome = await store.restore(productIDs: ["a", "b"])
        XCTAssertEqual(outcome, .nothingToRestore)
        XCTAssertEqual(fake.syncs, 1)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testRestoreWithUnresolvedSettlesHonestOutcome() async throws {
        let fake = FakeStorefront()
        fake.unfinished = [tx]
        let (store, _, _) = store(verifyStatus: 503, storefront: fake)
        let outcome = await store.restore(productIDs: [])
        XCTAssertEqual(outcome, .hasUnresolved)
        XCTAssertTrue(fake.finished.isEmpty, "恢复时 503 同样不许 finish")
    }

    /// 核销服务在，StoreKit 拉价失败 → 对齐整段抛错（屏上按"整块不渲染"回落）。
    func testAlignedStorefrontPriceFailurePropagates() async throws {
        let fake = FakeStorefront()
        fake.priceError = URLError(.timedOut)
        let (store, _, _) = store(verifyStatus: 200, storefront: fake)
        do {
            _ = try await store.alignedStorefront(
                mirror: IapProductsResponseDto(products: [
                    IapProductDto(
                        productId: "a", type: .subscription,
                        displayName: nil, priceDisplay: nil)
                ]))
            XCTFail("拉价失败必须抛，不许静默画一排无价卡")
        } catch {}
    }
}

/// `IapPurchaseOutcome.userMessage` 的文案表（13 §8 逐字）。
final class IapOutcomeCopyTests: XCTestCase {
    func testMessagesMatchSpecAndCancelledStaysSilent() {
        XCTAssertEqual(IapPurchaseOutcome.fulfilled.userMessage, "已到账")
        XCTAssertEqual(IapPurchaseOutcome.refused.userMessage, "核销被拒，请联系客服")
        XCTAssertEqual(
            IapPurchaseOutcome.unauthenticated.userMessage,
            "登录状态已过期，重新登录后点「恢复购买」")
        XCTAssertEqual(
            IapPurchaseOutcome.pendingVerification.userMessage, "购买成功，权益稍后到账")
        XCTAssertEqual(IapPurchaseOutcome.pendingApproval.userMessage, "已提交，待审批")
        XCTAssertNil(IapPurchaseOutcome.cancelled.userMessage, "取消是静默回落，不是话术")
        XCTAssertEqual(IapPurchaseOutcome.failed.userMessage, "购买没成功，请重试")
    }
}
