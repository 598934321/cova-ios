import Foundation

/// 一次 HTTP 往返的**裸结果**（状态码 + 响应体），由 `CovaAPIClient.performCoded` 交付。
///
/// 刻意只有两格：没有 URL、没有 header、没有凭证字段 ⇒ 它进日志也带不出敏感串
/// （硬边界 3）。`description` 只印状态码与字节数，**不印响应体**：错误信封里
/// 偶尔会有服务端回显的地址片段，「不印」比「印了再脱敏」少一个失守面。
public struct CovaHTTPOutcome: Equatable, Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200...299).contains(statusCode) }
}

extension CovaHTTPOutcome: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CovaHTTPOutcome(status: \(statusCode), bytes: \(body.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["statusCode": statusCode, "bytes": body.count], displayStyle: .struct)
    }
}

/// 出站请求组装：**唯一**把相对路径变成绝对 URL 的入口，均经 `CovaEnvironment` 守卫（D10）。
enum APIRequestBuilder {
    static func make(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        bearer: SecretString? = nil,
        jsonBody: Data? = nil,
        accept: String = "application/json"
    ) throws -> HTTPRequest {
        guard let url = CovaEnvironment.makeAPIURL(path: path, queryItems: queryItems) else {
            throw CovaAPIError.invalidRequestURL
        }
        var headers: [String: String] = ["Accept": accept]
        if jsonBody != nil {
            headers["Content-Type"] = "application/json"
        }
        if let bearer {
            headers["Authorization"] = "Bearer \(bearer.rawValue)"
        }
        return HTTPRequest(method: method, url: url, headers: headers, body: jsonBody)
    }
}

/// Cova API 客户端（D5/D10）。
///
/// 线性流程：出口守卫 → Bearer 注入 → 发送 →（401 且附带过 token）single-flight refresh →
/// 重放**一次** → 2xx 返回 / 其余映射为 `CovaAPIError`。
///
/// single-flight 由 `APICredentialProviding`（`CovaAuthSession`）实现：并发 401 共享同一次刷新，
/// 本类型只负责「等刷新完成 → 各自重放一次 → 仍 401 即失败（不再刷新）」。
public actor CovaAPIClient {
    private let transport: any HTTPTransport
    private let credentials: any APICredentialProviding
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(transport: any HTTPTransport, credentials: any APICredentialProviding) {
        self.transport = transport
        self.credentials = credentials
    }

    // MARK: - 类型化便捷调用

    public func get<Response: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Response {
        let data = try await perform(method: .get, path: path, queryItems: queryItems, jsonBody: nil)
        return try decode(Response.self, from: data)
    }

    public func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let data = try encoder.encode(body)
        let payload = try await perform(method: .post, path: path, queryItems: [], jsonBody: data)
        return try decode(Response.self, from: payload)
    }

    public func patch<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let data = try encoder.encode(body)
        let payload = try await perform(method: .patch, path: path, queryItems: [], jsonBody: data)
        return try decode(Response.self, from: payload)
    }

    public func delete<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let data = try encoder.encode(body)
        let payload = try await perform(method: .delete, path: path, queryItems: [], jsonBody: data)
        return try decode(Response.self, from: payload)
    }

    // MARK: - 底层执行

    /// 执行一次请求并返回 2xx 响应体（非 2xx 抛 `CovaAPIError`）。
    ///
    /// 会话绑定（M-1）：
    /// - 请求发出前捕获 `AuthSessionSnapshot`（owner + generation + 所用 access token）；
    /// - 仅当本次请求**附带过** access token 时才处理 401；
    /// - 重放前由 `refreshAccessToken(for:)` 校验「owner 与 generation 未变」，
    ///   变了即 `.sessionChanged` —— 绝不用新账号凭证重放旧账号的在途请求（D8）；
    /// - 重放仅一次，不再二次刷新。
    @discardableResult
    public func perform(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: Data? = nil
    ) async throws -> Data {
        let response = try await performRaw(
            method: method, path: path, queryItems: queryItems, jsonBody: jsonBody
        )
        return try Self.payload(from: response)
    }

    /// 与 `perform` **同一条腿**（出口守卫 → Bearer 注入 → 401 single-flight 重放一次），
    /// 但把 `HTTPResponse` 原样交回来，不做「非 2xx 即抛」那一步。
    private func performRaw(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: Data? = nil
    ) async throws -> HTTPResponse {
        let snapshot = try await credentials.currentSession()
        let request = try APIRequestBuilder.make(
            method: method,
            path: path,
            queryItems: queryItems,
            bearer: snapshot?.accessToken,
            jsonBody: jsonBody
        )
        let response = try await send(request)
        guard response.statusCode == 401, let snapshot else {
            return response
        }
        let refreshed = try await credentials.refreshAccessToken(for: snapshot)
        let replay = try APIRequestBuilder.make(
            method: method,
            path: path,
            queryItems: queryItems,
            bearer: refreshed,
            jsonBody: jsonBody
        )
        return try await send(replay)
    }

    /// 非 2xx **不抛**的那条腿：状态码 + 响应体交给调用方，由端点契约自己解错误信封。
    ///
    /// 为什么需要它（而不是把文案塞进 `CovaAPIError`）：`.httpStatus(code:apiCode:)`
    /// 只保留信封里的 `code`，**刻意丢掉 `error` 文案** —— 那是 10 登录防枚举的取舍
    /// （`LoginFailureCopy`：状态码是唯一依据，服务端字符串既不进话术也不进分支）。
    /// 而 studio/create 的验收要求正相反（DEVELOPMENT.md A4：400 要**透传**服务端中文原文、
    /// 402 要按 `balance`/`required` 组装「余额不足，本次需要 N co」）。
    /// 两屏的口径冲突不该由一个共享错误枚举来和稀泥 ⇒ 需要文案的端点自己拿原始信封，
    /// 由 `StudioCreateRejection.classify` 那样的**端点级**纯函数分诊。
    ///
    /// 仍然抛的只有传输层与出口裁决（离线/超时/取消/`.egressRefused`/会话变化）——
    /// 那些压根没有一个 HTTP 结果可交。
    public func performCoded(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: Data? = nil
    ) async throws -> CovaHTTPOutcome {
        let response = try await performRaw(
            method: method, path: path, queryItems: queryItems, jsonBody: jsonBody
        )
        return CovaHTTPOutcome(statusCode: response.statusCode, body: response.body)
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw CovaAPIError.normalize(error)
        }
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw CovaAPIError.classify(decoding: error)
        } catch {
            throw CovaAPIError.decoding(field: nil)
        }
    }

    /// 2xx → body；其余 → 错误（响应体仅用于提取业务码，不进入日志）。
    static func payload(from response: HTTPResponse) throws -> Data {
        if (200...299).contains(response.statusCode) {
            return response.body
        }
        throw CovaAPIError.classify(httpStatus: response.statusCode, body: response.body) ?? .invalidResponse
    }
}
