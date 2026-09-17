import Foundation

/// 业务错误响应封套（后端统一返回 `{error, code?}`）。
public struct CovaAPIErrorEnvelope: Codable, Equatable, Sendable {
    public let error: String?
    public let code: String?

    enum CodingKeys: String, CodingKey {
        case error
        case code
    }
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
