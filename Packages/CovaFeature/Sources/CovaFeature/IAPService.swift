import CovaCore
import Foundation
import StoreKit
import SwiftUI

/// StoreKit 2 的**接缝**：IAP 编排的全部「能骗人而钉得住」的判据在 `IAPStore` 层，
/// 这一层协议让测试不碰真 App Store（任务书明令不加 `.storekit` 测试配置）。
/// 实现只回**事实**（买到的交易 id + JWS、待审批、取消），核销分诊不在这层做。
public protocol IapStorefront: Sendable {
    /// productId → 本地化展示价（`Product.displayPrice`）。取不到的 id 不进字典。
    func prices(for productIDs: [String]) async throws -> [String: String]
    /// `Product.purchase()` 的归一化结果。
    func purchase(productID: String) async throws -> IapPurchaseResult
    /// **未完成交易**（`Transaction.unfinished`）：启动重验兜底 + `updates` 之外的真来源。
    func unfinishedTransactions() async -> [IapStoredTransaction]
    /// **当前权益**（`Transaction.currentEntitlements`）：恢复购买里补订阅的那本账
    /// （已 finish 的续订仍是最新权益）。
    func currentEntitlements() async -> [IapStoredTransaction]
    /// `Transaction.latest(for:)`：**无论 finish 与否**都回该商品最近一笔
    /// （consumable 核销前被 finish 的异常兜底 —— 恢复购买靠它把交易找回来）。
    func latestTransaction(productID: String) async -> IapStoredTransaction?
    /// `transaction.finish()` —— 只允许在 verify 200 / 400 / 401 / 402 之后调用（§4.8）。
    /// 实现按 transactionID 在 `unfinished` 集里找真交易对象（id 对不上 = 已 finish，静默）。
    func finish(transactionID: String) async
    /// `AppStore.sync()`（恢复购买第一步）。
    func sync() async throws
    /// `Transaction.updates` 流：只出**验签过的成功交易**（pending/cancel 不进流）。
    var updates: AsyncStream<IapPurchaseResult> { get }
}

/// 一笔已买到的交易（StoreKit 侧事实）。JWS 是凭证 ⇒ `SecretString` 收口。
public struct IapStoredTransaction: Equatable, Sendable {
    public let productID: String
    public let transactionID: String
    public let jws: SecretString
    public init(productID: String, transactionID: String, jws: SecretString) {
        self.productID = productID
        self.transactionID = transactionID
        self.jws = jws
    }
}

public enum IapPurchaseResult: Equatable, Sendable {
    /// `.success(verified:)`：验签过 StoreKit 侧签名的新交易。
    case success(IapStoredTransaction)
    /// Ask-to-Buy / 家长审批等挂起（交易未成交，服务端什么都没收到）。
    case pending
    case userCancelled
    /// `purchase()` 抛出的其它失败（系统态，不带核销语义）。
    case failed
}

/// 编排层对用户的一次购买动作给出的最终话（视图只消费它）。
public enum IapPurchaseOutcome: Equatable, Sendable {
    /// 核销成功（verify 200 + finish）。
    case fulfilled
    /// 服务端明确拒（400/402，finish 已做，Apple 侧不会再送）。
    case refused
    /// 401：登录态问题（finish 已做；交易本体在 Apple 侧仍然可查，重新登录后
    /// 「恢复购买」会再核一次）。
    case unauthenticated
    /// 购买成功但核销待重试（503/网络）：**没 finish**，`updates`/启动重验兜底。
    case pendingVerification
    /// 挂起（Ask-to-Buy 等）：什么都没发生，交易在系统侧排队。
    case pendingApproval
    case cancelled
    case failed

    /// 上屏话术（13 §8 文案清单；`cancelled` 返回 nil = 静默，不是被忘掉的格）。
    public var userMessage: String? {
        switch self {
        case .fulfilled: return "已到账"
        case .refused: return "核销被拒，请联系客服"
        case .unauthenticated: return "登录状态已过期，重新登录后点「恢复购买」"
        case .pendingVerification: return "购买成功，权益稍后到账"
        case .pendingApproval: return "已提交，待审批"
        case .cancelled: return nil
        case .failed: return "购买没成功，请重试"
        }
    }
}

/// 恢复购买的汇总（视图 Toast 只说三档：没有可恢复的 / 全清 / 有未决的）。
public enum IapRestoreOutcome: Equatable, Sendable {
    case nothingToRestore
    case allFulfilled(count: Int)
    /// 有待核/被拒/401 的混在一起：一句中性话术，逐笔细节交给核销日志以外的事实
    /// （服务端 `iap_transactions` 账是唯一的真账）。
    case hasUnresolved
}

/// `GET /api/iap/products` + `POST /api/iap/verify`（§4.8）。
///
/// 与 `AccountService` 同一纪律：verify 走 `performCoded`（不抛非 2xx）——
/// 402 拒核与 503 通道故障是**正常可预期**的落点，要拿状态码进 `IapVerifyRule`
/// 分诊，不是让 `CovaAPIError.httpStatus` 把它们和 404 和稀泥。
/// 仍然抛的只有传输层/出口层错误，调用方一律按 `.pendingVerification`（不 finish）收。
public struct IAPService: Sendable {
    public static let productsPath = "/api/iap/products"
    public static let verifyPath = "/api/iap/verify"

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// 商品镜像（服务端配的"哪些能买 + 兜底展示文案"）。
    public func products() async throws -> IapProductsResponseDto {
        try await client.get(Self.productsPath)
    }

    /// 核销一笔 StoreKit 交易。返回分流结论，finish 与否由 `IAPStore` 依结论执行。
    /// 核销幂等 = 服务端 `transaction_id` UNIQUE（§4.8），请求体不带客户端幂等键。
    public func verify(
        transactionId: String, productId: String, jwsTransaction: SecretString
    ) async throws -> IapVerifyDisposition {
        let body = IapVerifyRequestDto(
            transactionId: transactionId, productId: productId,
            jwsTransaction: jwsTransaction)
        let outcome = try await client.performCoded(
            method: .post, path: Self.verifyPath,
            jsonBody: try JSONEncoder().encode(body)
        )
        return IapVerifyRule.disposition(statusCode: outcome.statusCode)
    }
}

/// IAP 编排层（无状态，幂等由服务端 transaction_id 承担）。
///
/// 纪律写死在类型上：
/// · `IapStorefront.finish` 只在 `verified` / `refused` / `unauthenticated` 后被调用 ——
///   这一层**不可能**在「没核销成」的情况下把交易从 Apple 账本里抹掉；
/// · verify 抛错（传输层）= `.pendingVerification`（不 finish）；
/// · 核销成功后经 `onEntitlementsChanged` 回调让 `AppSession` 刷 `/me` ——
///   这层不自己改权益账，只发"该去刷新"的信号。
public struct IAPStore: Sendable {
    private let storefront: any IapStorefront
    private let service: IAPService
    /// 核销成功后的回调（刷权益）。`@Sendable` + 非 isolated：调用方自己保证线程安全。
    /// `internal(set)`：持有者是引用型会话对象时无法在 init 里捕获 self（weak 也不行），
    /// 装配走「先建 store、再装回调」两步。
    internal var onFulfilled: @Sendable (IapStoredTransaction) -> Void

    public init(
        storefront: any IapStorefront,
        service: IAPService,
        onFulfilled: @escaping @Sendable (IapStoredTransaction) -> Void = { _ in }
    ) {
        self.storefront = storefront
        self.service = service
        self.onFulfilled = onFulfilled
    }

    /// `Transaction.updates` 的透出（AppSession 常驻监听）。
    public var updates: AsyncStream<IapPurchaseResult> { storefront.updates }

    /// 商品镜像（`GET /api/iap/products`）直通。
    public func products() async throws -> IapProductsResponseDto {
        try await service.products()
    }

    /// 镜像 ↔ ASC 对齐 → 屏上可买的行（id → 本地价）。
    /// 失败抛错（调用方按"购买区整块不渲染"回落）。
    public func alignedStorefront(
        mirror: IapProductsResponseDto
    ) async throws -> (alignment: IapAlignment, prices: [String: String]) {
        let prices = try await storefront.prices(for: mirror.products.map(\.productId))
        return (IapAlignment.align(mirror: mirror, storeProductIDs: Set(prices.keys)), prices)
    }

    /// 购买一档 → 核销 → 分流。返回最终话（视图 Toast 用）。
    public func purchase(productID: String) async -> IapPurchaseOutcome {
        let result: IapPurchaseResult
        do {
            result = try await storefront.purchase(productID: productID)
        } catch {
            return .failed
        }
        switch result {
        case .pending: return .pendingApproval
        case .userCancelled: return .cancelled
        case .failed: return .failed
        case .success(let transaction):
            return await settle(transaction)
        }
    }

    /// 核销一笔交易并按分流决定 finish。`updates` 流与恢复购买共用这条腿。
    public func settle(_ transaction: IapStoredTransaction) async -> IapPurchaseOutcome {
        let disposition: IapVerifyDisposition
        do {
            disposition = try await service.verify(
                transactionId: transaction.transactionID,
                productId: transaction.productID,
                jwsTransaction: transaction.jws
            )
        } catch {
            return .pendingVerification   // 没拿到 HTTP 结果 = 交易去向未定，不 finish
        }
        switch disposition {
        case .verified:
            await storefront.finish(transactionID: transaction.transactionID)
            onFulfilled(transaction)
            return .fulfilled
        case .refused:
            await storefront.finish(transactionID: transaction.transactionID)
            return .refused
        case .unauthenticated:
            await storefront.finish(transactionID: transaction.transactionID)
            return .unauthenticated
        case .pendingVerification:
            return .pendingVerification   // 刻意不 finish：Apple 侧留着，重验兜底
        }
    }

    /// **启动重验兜底**：把 `unfinished` 集逐条重新核销。
    /// 只有已登录才调（游客核销必 401 → finish，把可恢复的账提前结案）。
    /// 返回扫到的笔数。
    @discardableResult
    public func settleUnfinished() async -> Int {
        let list = await storefront.unfinishedTransactions()
        for transaction in list { _ = await settle(transaction) }
        return list.count
    }

    /// 恢复购买 = `AppStore.sync()` + `latest(for:)` 逐商品重验（§4.8 明文路径）。
    /// `latest(for:)` 连已 finish 的最近一笔都给，所以「核销前被 finish」的异常态
    /// 也能从这里把交易找回来；`unfinished`/`currentEntitlements` 一并并入去重。
    public func restore(productIDs: [String]) async -> IapRestoreOutcome {
        do { try await storefront.sync() } catch { return .hasUnresolved }
        var unique: [String: IapStoredTransaction] = [:]
        for transaction in await storefront.unfinishedTransactions()
            + storefront.currentEntitlements() {
            unique[transaction.transactionID] = transaction
        }
        for productID in productIDs {
            if let transaction = await storefront.latestTransaction(productID: productID) {
                unique[transaction.transactionID] = transaction
            }
        }
        guard !unique.isEmpty else { return .nothingToRestore }
        var allFulfilled = true
        for transaction in unique.values {
            switch await settle(transaction) {
            case .fulfilled: continue
            default: allFulfilled = false
            }
        }
        return allFulfilled ? .allFulfilled(count: unique.count) : .hasUnresolved
    }
}

// MARK: - 生产 Storefront（系统 API 逐条对应，无业务判断）

public struct StoreKit2Storefront: IapStorefront {
    public init() {}

    public func prices(for productIDs: [String]) async throws -> [String: String] {
        let products = try await Product.products(for: productIDs)
        var out: [String: String] = [:]
        for product in products { out[product.id] = product.displayPrice }
        return out
    }

    public func purchase(productID: String) async throws -> IapPurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            return .failed   // 对齐层的洞漏到这里的兜底：ASC 没这个商品 ⇒ 买不了
        }
        switch try await product.purchase() {
        case .success(let verification):
            if let stored = Self.stored(from: verification) {
                return .success(stored)
            }
            return .failed   // StoreKit 侧验签没过 ⇒ 不进核销链
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .failed
        }
    }

    public func unfinishedTransactions() async -> [IapStoredTransaction] {
        var out: [IapStoredTransaction] = []
        for await result in StoreKit.Transaction.unfinished {
            if let stored = Self.stored(from: result) { out.append(stored) }
        }
        return out
    }

    public func currentEntitlements() async -> [IapStoredTransaction] {
        var out: [IapStoredTransaction] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            if let stored = Self.stored(from: result) { out.append(stored) }
        }
        return out
    }

    /// `latest(for:)` 连已 finish 的最近一笔都给 ⇒ consumable 的异常态兜底靠它。
    public func latestTransaction(productID: String) async -> IapStoredTransaction? {
        guard let result = await StoreKit.Transaction.latest(for: productID) else { return nil }
        return Self.stored(from: result)
    }

    /// finish 只能对 `unfinished` 集里的真交易做（`currentEntitlements` 里的订阅
    /// 不该被 finish——finish 是"这笔交付完了"的语义，续订权益不是一次性交付）。
    public func finish(transactionID: String) async {
        for await result in StoreKit.Transaction.unfinished {
            if case .verified(let transaction) = result,
               String(transaction.id) == transactionID {
                await transaction.finish()
                return
            }
        }
    }

    public func sync() async throws {
        try await AppStore.sync()
    }

    public var updates: AsyncStream<IapPurchaseResult> {
        AsyncStream { continuation in
            let task = Task {
                for await result in StoreKit.Transaction.updates {
                    if let stored = Self.stored(from: result) {
                        continuation.yield(.success(stored))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `VerificationResult<Transaction>` → 内部载荷（只收 verified 那一格）。
    static func stored(
        from result: VerificationResult<StoreKit.Transaction>
    ) -> IapStoredTransaction? {
        guard case .verified(let transaction) = result else { return nil }
        return IapStoredTransaction(
            productID: transaction.productID,
            transactionID: String(transaction.id),
            jws: SecretString(result.jwsRepresentation)
        )
    }
}
