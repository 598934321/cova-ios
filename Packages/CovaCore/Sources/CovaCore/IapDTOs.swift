import Foundation

// §4.8（2026-10-01 拍板）App 内购买的契约面。形状逐行取自
// `web/src/lib/iap.ts` 与 `web/src/app/api/iap/**`：
//   GET  /api/iap/products → `{products[]}`，行 = {productId, type, displayName, priceDisplay}
//   POST /api/iap/verify   → `{transactionId, productId, jwsTransaction}`；
//        200 `{message, entitlements, transactionId}`；400 缺参 / 401 未登录 /
//        402 核销拒绝（retryable=false）/ 503 验签通道故障（retryable=true）。
//
// 硬边界 3：`jwsTransaction` 是交易凭证 ⇒ `SecretString` 收口（不进日志/反射面），
// 自定义 encode 是它成为明文字节的唯一出口。

/// `GET /api/iap/products` 的一行镜像。字段口径与 `IapProduct`（web）一致；
/// 解码对**缺键**容忍（行留下来，由对齐层决定它配不配出购买钮），对**错型**fail-closed。
public struct IapProductDto: Decodable, Equatable, Sendable, Identifiable {
    /// 商品类别（服务端闭合集 `subscription | credits`；未知值 = 解码失败的行）。
    public enum Kind: String, Codable, Equatable, Sendable {
        case subscription
        case credits
    }

    public let productId: String
    public let type: Kind
    /// 服务端配的展示名（兜底；价格/图标以 StoreKit 为准）。
    public let displayName: String?
    /// 服务端配的展示价（兜底；屏上价格以 `Product.displayPrice` 为准）。
    public let priceDisplay: String?
    /// co 包的内容量（仅 credits 类有；订阅类为 nil）。
    public let credits: Int?
    /// 订阅档位（仅 subscription 类有：`creator|pro|enterprise`）。
    public let plan: String?

    public var id: String { productId }

    enum CodingKeys: String, CodingKey {
        case productId, type, displayName, priceDisplay, credits, plan
    }

    public init(
        productId: String, type: Kind, displayName: String?,
        priceDisplay: String?, credits: Int? = nil, plan: String? = nil
    ) {
        self.productId = productId
        self.type = type
        self.displayName = displayName
        self.priceDisplay = priceDisplay
        self.credits = credits
        self.plan = plan
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // productId 与 type 是行的身份：缺任一个这行就没有可买面，fail-closed。
        productId = try c.decode(String.self, forKey: .productId)
        type = try c.decode(Kind.self, forKey: .type)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        priceDisplay = (try? c.decodeIfPresent(String.self, forKey: .priceDisplay)) ?? nil
        credits = (try? c.decodeIfPresent(Int.self, forKey: .credits)) ?? nil
        plan = (try? c.decodeIfPresent(String.self, forKey: .plan)) ?? nil
    }
}

/// `GET /api/iap/products` 的响应。
///
/// 逐行容错：`products` 数组里**读不出的行单独丢**（不因为一行坏掉整面挂零），
/// `dropped` 记账让「服务端发了一行客户端不认识的商品」看得见、解释得出。
public struct IapProductsResponseDto: Decodable, Equatable, Sendable {
    public let products: [IapProductDto]
    /// 解码失败的行数（>0 = 服务端发了本端不认识的形状；屏上不渲染，但账上不许静默）。
    public let dropped: Int

    enum CodingKeys: String, CodingKey { case products }

    public init(products: [IapProductDto], dropped: Int = 0) {
        self.products = products
        self.dropped = dropped
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 逐格容错：数组里读不出的一行单独丢（superDecoder 每取一格推进一次游标），
        // 不因为一行坏掉整面挂零。
        var parsed: [IapProductDto] = []
        var lost = 0
        if var array = try? c.nestedUnkeyedContainer(forKey: .products) {
            while !array.isAtEnd {
                // superDecoder() 无条件推进游标 —— 用 `decode` 直接取，坏了的行
                // 会不会推进取决于错误路径，可能死循环；先取子解码器再解是确定推进的。
                let cell = (try? array.superDecoder()).flatMap {
                    try? IapProductDto(from: $0)
                }
                if let cell { parsed.append(cell) } else { lost += 1 }
            }
        }
        products = parsed
        dropped = lost
    }
}


/// `POST /api/iap/verify` 请求体。**核销幂等由服务端 `transaction_id` UNIQUE 承担**
/// （§4.8），请求体不带客户端幂等键——一次交易只对应一次核销语义。
public struct IapVerifyRequestDto: Encodable, Sendable {
    public let transactionId: String
    public let productId: String
    /// StoreKit 2 `VerificationResult` 验签解出的 JWS（凭证：SecretString 收口）。
    public let jwsTransaction: SecretString?

    public init(transactionId: String, productId: String, jwsTransaction: SecretString?) {
        self.transactionId = transactionId
        self.productId = productId
        self.jwsTransaction = jwsTransaction
    }

    enum CodingKeys: String, CodingKey { case transactionId, productId, jwsTransaction }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(productId, forKey: .productId)
        try c.encodeIfPresent(jwsTransaction?.rawValue, forKey: .jwsTransaction)
    }
}

/// `POST /api/iap/verify` 成功回执。`entitlements` 服务端会回最新权益，
/// 但客户端权益账以 `loadMe(force:)` 为准（单事实源），这里只读 `message`/`transactionId`。
public struct IapVerifyResponseDto: Decodable, Equatable, Sendable {
    public let message: String?
    public let transactionId: String?

    public init(message: String?, transactionId: String?) {
        self.message = message
        self.transactionId = transactionId
    }
}

/// verify 分流（§4.8「客户端纪律」的类型化裁决面）。**finish 权只在这一层**：
/// UI/编排层拿 `disposition` 说话，不自己按状态码猜。
public enum IapVerifyDisposition: Equatable, Sendable {
    /// 核销成功：`transaction.finish()` + `loadMe(force: true)` 刷权益 + 「已到账」。
    case verified
    /// 服务端明确拒（400/402）：finish（阻断重试风暴），话术「核销被拒，请联系客服」。
    case refused
    /// 401：会话问题。**finish**（交易与本次会话核销语义已死，重放只会再撞 401），
    /// 但话术与 402 分开：提示登录态问题，不说"被拒"。
    case unauthenticated
    /// 交易未核销但凭证留在 Apple 侧：503（验签通道故障）/网络错/其它 5xx/
    /// 未知码一律**不 finish**，留 `Transaction.updates` 与启动重验兜底。
    case pendingVerification
}

public enum IapVerifyRule {
    /// HTTP 结果 → 分流。判别面只用状态码（402/400 的 `error` 文案不影响落点），
    /// 响应体里 `retryable:true` 的 503 与裸 503 同档。
    public static func disposition(statusCode: Int) -> IapVerifyDisposition {
        if (200...299).contains(statusCode) { return .verified }
        switch statusCode {
        case 400, 402:
            return .refused
        case 401:
            return .unauthenticated
        default:
            // 404（路由在但用户/商品没了）到 5xx 都收进「待重验」：
            // 没有拿到"服务端明确拒绝"的证据之前，绝不替它 finish 掉一笔已付款的交易。
            return .pendingVerification
        }
    }

    /// 传输层错误（没有 HTTP 结果）：交易去向未定，**不 finish**。
    public static let transportFailure: IapVerifyDisposition = .pendingVerification
}

/// 镜像↔ASC 对齐（纯函数，不让视图层做这件事）：
/// 返回**可买的镜像行**（ASC 拉得到的那些），以及两类缺口的账。
public struct IapAlignment: Equatable, Sendable {
    /// 镜像在、StoreKit 也在 ⇒ 屏上正常可买。
    public let purchasable: [IapProductDto]
    /// 镜像在、StoreKit 不在 ⇒ 不渲染购买钮（服务端配了但 ASC 没配）。
    public let mirrorOnly: [IapProductDto]
    /// StoreKit 在、镜像不在 ⇒ **不出现**（镜像不认识它，verify 一定 400 未知商品）。
    public let storeOnly: [String]
    /// 镜像里 decode 掉/缺 productId 的行数（`products.dropped` 透传）。
    public let unreadable: Int

    /// 镜像行序优先（服务端的排序 = 展示意图）；同一行在两边都取得到才算可买。
    public static func align(
        mirror: IapProductsResponseDto, storeProductIDs: Set<String>
    ) -> IapAlignment {
        var purchasable: [IapProductDto] = []
        var mirrorOnly: [IapProductDto] = []
        var seen: Set<String> = []
        for product in mirror.products {
            if storeProductIDs.contains(product.productId) {
                purchasable.append(product)
            } else {
                mirrorOnly.append(product)
            }
            seen.insert(product.productId)
        }
        return IapAlignment(
            purchasable: purchasable,
            mirrorOnly: mirrorOnly,
            storeOnly: storeProductIDs.subtracting(seen).sorted(),
            unreadable: mirror.dropped
        )
    }
}
