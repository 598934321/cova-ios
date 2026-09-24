import Foundation

/// 业务错误响应封套（后端统一返回 `{error, code?}`）。
public struct CovaAPIErrorEnvelope: Codable, Equatable, Sendable {
    public let error: String?
    public let code: String?

    /// 对外构造（客户端可用它构造错误载荷/桩数据）。
    public init(error: String?, code: String?) {
        self.error = error
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case error
        case code
    }
}

/// D23①/② 的**出口拒绝**事实：某一条跳转的落地不在这一类请求允许的出口内，
/// 于是那一次出站**根本没有发生**（裁决在出站之前，不是投递之后再后悔）。
///
/// 为什么它不是 `CovaAPIError` 的一个新 case（跨模块加 case 会把
/// `Packages/CovaPlayer/Sources/CovaPlayer/PlayReportCoordinator.swift:66-77` 那道
/// **无 default 的穷举 switch** 直接编不过 —— 那是本批不许改的文件），而是一件独立错误：
/// 独立类型既能带上「点名 host」这个新载荷，又逼着每个归一化点显式表态它落在哪一档。
/// 表态已由 `CovaAPIError.normalize(_:)` 完成：`.invalidRequestURL`
/// （`isRetryable == false`、`httpStatusCode == nil`）—— **绝不落进 `.transport(code:)`**，
/// 那一档是可重试的，出口裁决被读成「网络抖了一下」就是一次刷新/重放环
/// （落地主机不会因为你换了 token 就变成生产出口）。
///
/// **安全（AGENTS 硬边界 3）**：载荷只有 host 一个字符串，类型层面不存在
/// URL / query / header / token 字段；被拒地址上的签名查询串在这里无处可放。
public struct CovaEgressRefusal: Error, Equatable, Hashable, Sendable,
    CustomStringConvertible, LocalizedError
{
    /// 哪一类请求的边界被拒（D23 的两类各一条，与 `mediaRedirectAllowed` 同轴）。
    public enum Rule: String, Equatable, Sendable, CaseIterable {
        /// 带凭证的一类：落地必须仍是同一权威的生产出口（名单不构成放行理由）。
        case credentialLeg
        /// 不带凭证的一类：落地必须在许可名单的存储主机之内。
        case publicMediaLeg
    }

    /// 被拒的落地主机（`CovaEnvironment.egressHostLabel` 的口径：只有 host，取不出则占位）。
    public let host: String
    /// 触发拒绝的那一条类别规则（决定上屏那句话怎么说）。
    public let rule: Rule

    public init(host: String, rule: Rule = .credentialLeg) {
        self.host = host
        self.rule = rule
    }

    /// 出口裁决**不是**传输故障：重试不会改变结果（重放只会把同一条拒绝再判一次）。
    public var isRetryable: Bool { false }

    /// 归一进 `CovaAPIError` 世界的那一档（不可重试、也不是 401 ⇒ 不触发刷新重放）。
    public var asCovaAPIError: CovaAPIError { .invalidRequestURL }

    /// 上屏/日志文本：分支 + 主机名，**没有** scheme 之外的任何地址片段。
    public var description: String {
        switch rule {
        case .credentialLeg:
            return "跳转被拒绝：落地 \(host) 不是生产出口（凭证不出出口，该次请求未发出）"
        case .publicMediaLeg:
            return "跳转被拒绝：落地 \(host) 不在许可名单的存储主机内（该次请求未发出）"
        }
    }

    public var errorDescription: String? { description }
}

/// 统一的 API 错误模型。
///
/// 设计约束：
/// - 可判等（`Equatable`）便于测试与去重；
/// - 携带 HTTP 状态码与服务端业务码；
/// - `redactedDescription` 只输出分支名与码 —— **类型层面不存在 URL/token 字段**，
///   因此凭证与签名 URL 不可能被写进日志（AGENTS 硬边界 3）。
public enum CovaAPIError: Error, Equatable, Sendable {
    /// 网络不可用（未连接/连接丢失/DNS 失败等）。
    case offline
    /// 请求超时（契约 15s）。
    case timeout
    /// 请求被取消。
    case cancelled
    /// 其它传输层失败，带底层错误码。
    case transport(code: Int)
    /// 响应不是合法 HTTP 响应（无状态码）。
    case invalidResponse
    /// 出站 URL 未通过出口守卫（D10）：非生产 origin、相对路径非法等。请求**未发出**。
    case invalidRequestURL
    /// 会话已变化（换号/登出/新 generation）：在途请求不得用新账号凭证重放（D8）。
    case sessionChanged
    /// 凭证存储读取失败（Keychain 等返回异常状态）——与「本无凭证」不同，必须可观测。
    case credentialReadFailed
    /// 401：凭证缺失/过期（上层触发 single-flight refresh 后重放一次）。
    case unauthorized(apiCode: String?)
    /// 非 2xx 且非 401。
    case httpStatus(code: Int, apiCode: String?)
    /// 响应解码失败；`field` 为可定位字段名，不含任何原始响应内容。
    case decoding(field: String?)

    /// 关联的 HTTP 状态码（若为 HTTP 层错误）。
    public var httpStatusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .httpStatus(let code, _): return code
        default: return nil
        }
    }

    /// 是否适合重试（传输类 + 5xx + 429）。
    public var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .transport: return true
        case .httpStatus(let code, _): return code >= 500 || code == 429
        default: return false
        }
    }

    /// 可安全写日志的描述：只有分支名与码。
    public var redactedDescription: String {
        switch self {
        case .offline: return "网络不可用"
        case .timeout: return "请求超时"
        case .cancelled: return "请求已取消"
        case .transport(let code): return "传输错误(\(code))"
        case .invalidResponse: return "响应格式无效"
        case .invalidRequestURL: return "请求地址非法（已拒绝出站）"
        case .sessionChanged: return "会话已变化（已放弃重放）"
        case .credentialReadFailed: return "凭证读取失败"
        case .unauthorized(let apiCode): return "未授权(\(apiCode ?? "no_code"))"
        case .httpStatus(let code, let apiCode): return "服务端错误(\(code)/\(apiCode ?? "no_code"))"
        case .decoding(let field): return "响应解码失败(\(field ?? "unknown"))"
        }
    }

    /// HTTP 状态码 + 业务码 → 错误。2xx 返回 `nil`（表示成功）。
    public static func classify(httpStatus: Int, apiCode: String?) -> CovaAPIError? {
        if (200...299).contains(httpStatus) { return nil }
        if httpStatus == 401 { return .unauthorized(apiCode: apiCode) }
        return .httpStatus(code: httpStatus, apiCode: apiCode)
    }

    /// HTTP 状态码 + 响应体 → 错误。响应体非预期结构时忽略业务码，不因此丢失状态码。
    public static func classify(httpStatus: Int, body: Data) -> CovaAPIError? {
        let envelope = try? JSONDecoder().decode(CovaAPIErrorEnvelope.self, from: body)
        return classify(httpStatus: httpStatus, apiCode: envelope?.code)
    }

    /// `URLError` 错误码 → 错误（纯整数映射，便于无网络依赖地测试）。
    public static func classify(transportErrorCode: Int) -> CovaAPIError {
        switch transportErrorCode {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .offline
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorCancelled:
            return .cancelled
        default:
            return .transport(code: transportErrorCode)
        }
    }

    /// 任意底层错误 → 统一的 `CovaAPIError`（传输层与认证层共用）。
    ///
    /// 已是 `CovaAPIError` 的原样返回；**出口拒绝**（`CovaEgressRefusal`）→ `.invalidRequestURL`
    /// （不可重试，且不是 401）—— 这一支必须在 `NSURLErrorDomain` 之前显式判：
    /// 漏掉它并不会崩，而是会掉进末尾的 `.transport(code:)` 那一档，把「主机不对」
    /// 伪装成「网络抖了一下」⇒ 上层按可重试处理 = 刷新/重放环（R17-3b 的错分面）。
    /// `CancellationError` → `.cancelled`；`NSURLErrorDomain` → 整数映射；
    /// 其余 → `.transport(code:)`（失败路径，不携带明文）。
    public static func normalize(_ error: Error) -> CovaAPIError {
        if let api = error as? CovaAPIError { return api }
        if let refusal = error as? CovaEgressRefusal { return refusal.asCovaAPIError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(transportErrorCode: nsError.code)
        }
        return .transport(code: nsError.code)
    }

    /// 解码失败 → 错误（只保留字段路径，不保留原始响应）。
    public static func classify(decoding error: DecodingError) -> CovaAPIError {
        switch error {
        case .keyNotFound(let key, _): return .decoding(field: key.stringValue)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return .decoding(field: context.codingPath.last?.stringValue)
        case .dataCorrupted(let context):
            return .decoding(field: context.codingPath.last?.stringValue)
        @unknown default:
            return .decoding(field: nil)
        }
    }
}
