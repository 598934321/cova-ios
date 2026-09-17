import Foundation

/// HTTP 方法（仅列出契约用到的动词）。
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// 出站 HTTP 请求。
///
/// **安全（AGENTS 硬边界 3）**：`headers` 可能含 `Authorization: Bearer <token>`，
/// `body` 可能含密码/幂等键。因此本类型实现 `CustomStringConvertible` /
/// `CustomDebugStringConvertible` / `CustomReflectable`：描述与反射面**只暴露方法与路径**，
/// 任何日志（含 `dump` / `Mirror` / 数组 / Optional 包裹）都不会带出 header/body 明文。
public struct HTTPRequest: Sendable {
    public let method: HTTPMethod
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "\(method.rawValue) \(url.path)" }
    public var debugDescription: String { description }

    /// 反射面只保留方法与路径：`dump` 不会展开含 Bearer 的 headers。
    public var customMirror: Mirror {
        Mirror(self, children: ["method": method.rawValue, "path": url.path], displayStyle: .struct)
    }
}

/// 出站 HTTP 响应。
///
/// 响应体可能含签名 URL / 候选音频 URL，故描述与反射面**只暴露状态码**。
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "HTTPResponse(status: \(statusCode))" }
    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["statusCode": statusCode], displayStyle: .struct)
    }
}

/// 传输抽象。生产实现 = `URLSessionTransport`；单测/预览 = 注入的假传输层。
///
/// 实现约定：所有失败都以 `CovaAPIError` 抛出（`URLSessionTransport` 内部完成映射），
/// 这样 API client / 认证层无需理解底层框架错误。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 生产传输层：`URLSession`，超时 15s（api-contracts 前言）。
///
/// 纯映射逻辑（URLRequest 构造 / 响应映射 / 错误映射）抽为静态函数，
/// 便于**不发任何网络请求**地对齐超时、取消、状态码与解码分支。
public struct URLSessionTransport: HTTPTransport {
    /// 契约超时（15s）。
    public static let timeout: TimeInterval = 15

    private let session: URLSession

    public init() {
        session = Self.makeDefaultSession()
    }

    /// 测试注入口（可传入自定义配置的 `URLSession`）。
    init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: Self.makeURLRequest(request))
            return try Self.map(data: data, response: response)
        } catch {
            throw CovaAPIError.normalize(error)
        }
    }

    /// 默认会话：无缓存、无 Cookie 持久化，请求/资源超时均为契约 15s。
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    static func map(data: Data, response: URLResponse) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CovaAPIError.invalidResponse
        }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }
}
