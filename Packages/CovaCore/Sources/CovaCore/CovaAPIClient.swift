import Foundation

/// 出站请求组装：**唯一**把相对路径变成绝对 URL 的入口，均经 `CovaEnvironment` 守卫（D10）。
enum APIRequestBuilder {
    static func make(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        bearer: SecretString? = nil,
        jsonBody: Data? = nil
    ) throws -> HTTPRequest {
        guard let url = CovaEnvironment.makeAPIURL(path: path, queryItems: queryItems) else {
            throw CovaAPIError.invalidRequestURL
        }
        var headers: [String: String] = ["Accept": "application/json"]
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
            return try Self.payload(from: response)
        }
        let refreshed = try await credentials.refreshAccessToken(for: snapshot)
        let replay = try APIRequestBuilder.make(
            method: method,
            path: path,
            queryItems: queryItems,
            bearer: refreshed,
            jsonBody: jsonBody
        )
        return try Self.payload(from: try await send(replay))
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
