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
/// **唯一的例外**是 D23① 的出口拒绝 `CovaEgressRefusal` —— 它带着「被拒的是哪台 host」，
/// 而任何只认 `CovaAPIError` 的调用方都会经 `normalize` 把它归到**不可重试**的
/// `.invalidRequestURL`（漏了那一支就会被读成 `.transport(code:)` ⇒ 重试环）。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// D23①：带凭证那两条腿（普通 API + SSE）的会话级跳转守卫 —— **一律不自动跟随**。
///
/// 形状与音频腿的 `AudioRedirectGuard` 完全一致，理由是同一个：只要 URLSession 还留着
/// 自动跟随，302 的那一跳就在**任何人裁决之前**已经出站（2026-09-25 本地环回探针实测）。
/// 一律拒 ⇒ 3xx 带着 `Location` 原样回到调用方，「跟不跟」只剩 `CredentialedEgressHop`
/// 一个判定点、一个可测点；在这里按名单放行等于把同一个判定写两遍、且那一遍在 XCTest 里不可观测。
final class CredentialedRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// D23①：凭证类跳转的**唯一出站裁决**（普通 API 腿与 SSE 腿共用；判据本身在
/// `CovaEnvironment.decideCredentialedRedirect`，与音频腿 `MediaEgressHop` 同一面）。
///
/// 为什么"追"要由本层做而不是交给 URLSession：交出去就等于把「哪一台主机可以收到这条
/// 带 Bearer 的请求」这个决定让给别人的配置。追的时候请求由这里**重建**（方法/载荷按
/// RFC 9110 的跳转语义），并且只在「落地与发起同一权威」时才延续请求头 ——
/// 判据已经保证这一点，所以这里不存在把凭证递给别家主机的路径。
enum CredentialedEgressHop {
    /// 307/308 保留方法与请求体，301/302/303 改 GET 并丢体（与 URLSession 过去的
    /// 自动跟随同口径 ⇒ 补上守卫不会改变合法跳转的行为，只把非法跳转变成「一次都不出」）。
    static let methodPreservingStatusCodes: Set<Int> = [307, 308]

    /// 这一条响应之后还要不要出站、出到哪。
    ///
    /// - Parameter hopsRemaining: 调用方还剩多少跳转预算。**先**做投递面的权威核对、
    ///   **再**看预算 ⇒ 预算耗尽时也只是「不再发下一次请求」，绝不会连兜底一起跳过。
    /// - Returns: 新请求 = 允许追的那一跳；`nil` = 不是 3xx（3xx 而无可用 `Location`、
    ///   或预算已尽），响应可以原样交付，由调用方按状态码映射。
    /// - Throws: `CovaEgressRefusal` —— 落地不在生产出口内，**那一次出站绝不发生**。
    static func request(
        after response: URLResponse,
        following previous: URLRequest,
        hopsRemaining: Int
    ) throws -> URLRequest? {
        guard let http = response as? HTTPURLResponse, let original = previous.url else { return nil }
        // 第二道（投递面兜底，与音频腿 `AudioAuthorityMatch` 同名）：响应的**最终**权威必须仍是
        // 发起那一台。注入式会话（测试桩、任何不带本层守卫的 `URLSession`）拿不到
        // 「先拒再决定」的能力，这一道就是它唯一的防线 —— 不许拆。
        if let landed = http.url, !CovaEnvironment.isSameAuthority(original, landed) {
            throw CovaEgressRefusal(
                host: CovaEnvironment.egressHostLabel(of: landed),
                rule: .credentialLeg
            )
        }
        guard (300..<400).contains(http.statusCode), hopsRemaining > 0 else { return nil }
        switch CovaEnvironment.decideCredentialedRedirect(response: http, original: original) {
        case .unresolvable:
            return nil
        case .refused(let refusal):
            throw refusal
        case .follow(let landing):
            var next = URLRequest(url: landing)
            next.timeoutInterval = previous.timeoutInterval
            if methodPreservingStatusCodes.contains(http.statusCode) {
                next.httpMethod = previous.httpMethod ?? "GET"
                next.httpBody = previous.httpBody
            } else {
                next.httpMethod = "GET"
            }
            // 头只在同一权威内延续（判据已保证），不继承任何别处来的东西。
            for (field, value) in previous.allHTTPHeaderFields ?? [:] {
                next.setValue(value, forHTTPHeaderField: field)
            }
            return next
        }
    }
}

/// 生产传输层：`URLSession`，超时 15s（api-contracts 前言）。
///
/// 纯映射逻辑（URLRequest 构造 / 响应映射 / 错误映射 / 跳转裁决）抽为静态函数，
/// 便于**不发任何网络请求**地对齐超时、取消、状态码与解码分支。
public struct URLSessionTransport: HTTPTransport {
    /// 契约超时（15s）。
    public static let timeout: TimeInterval = 15

    /// D23：一次调用里允许**自己**追出去的跳转上限（与音频腿 `maximumRedirectHops` 同值）：
    /// 自指 `Location` 不许变成出站风暴；超界就把 3xx 原样交付，由状态码如实报错。
    public static let maximumRedirectHops = 5

    /// 无状态守卫：所有代际的会话共用同一个实例。
    private static let redirectGuard = CredentialedRedirectGuard()

    private let session: URLSession

    public init() {
        session = Self.makeDefaultSession()
    }

    /// 测试注入口（可传入自定义配置的 `URLSession`）。
    ///
    /// ⚠ 注入的会话**带不上**本层的跳转守卫（`URLSession` 的 delegate 在创建时就定死了），
    /// 走这条腿的用例只测得到投递面的第二道兜底；生产装配一个都不走，D23 的接线由
    /// `makeDefaultSession()` 那条腿被测到。
    init(session: URLSession) {
        self.session = session
    }

    /// 发送并按 D23 自己裁决跳转（最多 `maximumRedirectHops` 跳）。
    ///
    /// 出口拒绝（`CovaEgressRefusal`）在 `do/catch` **之外**抛出：把它交给
    /// `CovaAPIError.normalize` 归一成 `.transport(code:)` 就是「主机不对 → 可重试」的
    /// 错分现场，所以这一条不许顺手并进统一的 catch。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var current = Self.makeURLRequest(request)
        var hopsRemaining = Self.maximumRedirectHops
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: current)
            } catch {
                throw CovaAPIError.normalize(error)
            }
            if let next = try CredentialedEgressHop.request(
                after: response,
                following: current,
                hopsRemaining: hopsRemaining
            ) {
                current = next
                hopsRemaining -= 1
                continue
            }
            return try Self.map(data: data, response: response)
        }
    }

    /// 默认会话：无缓存、无 Cookie 持久化，请求/资源超时均为契约 15s。
    ///
    /// D23①：会话**必须**带 `CredentialedRedirectGuard` 创建 —— 少了它，服务端一次 302
    /// 就会在任何人裁决之前被 URLSession 自己跟掉（那是 R17-3 的根因）。
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
    }

    /// `timeoutInterval` 默认取契约 15s；SSE 长连接传入更长的空闲阈值（见 `URLSessionSSETransport`）。
    static func makeURLRequest(
        _ request: HTTPRequest,
        timeoutInterval: TimeInterval = URLSessionTransport.timeout
    ) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeoutInterval)
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
