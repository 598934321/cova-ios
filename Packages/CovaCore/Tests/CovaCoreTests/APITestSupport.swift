@testable import CovaCore
import Foundation
import XCTest

/// 记录请求并按 `handler` 返回的假传输层（**零真实网络**）。
actor FakeHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let handler: Handler
    private var recorded: [HTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        return try await handler(request)
    }

    func recordedRequests() -> [HTTPRequest] { recorded }
    func requestCount(path: String) -> Int { recorded.filter { $0.url.path == path }.count }
}

extension HTTPRequest {
    /// 测试便利：取出 Bearer 值（不用于任何日志输出）。
    var bearerToken: String? {
        guard let value = headers["Authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }
}

/// 内存 owner 持久化（测试用；不写真实沙盒）。
final class InMemoryOwnerStore: OwnerScopedStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func key(_ owner: PrincipalID, _ name: String) -> String { "\(owner.rawValue)/\(name)" }

    func load<Value: Codable>(_ type: Value.Type, name: String, owner: PrincipalID) throws -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[key(owner, name)] else { return nil }
        return try decoder.decode(Value.self, from: data)
    }

    func save<Value: Codable>(_ value: Value, name: String, owner: PrincipalID) throws {
        let data = try encoder.encode(value)
        lock.lock()
        defer { lock.unlock() }
        storage[key(owner, name)] = data
    }

    func remove(name: String, owner: PrincipalID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key(owner, name)] = nil
    }

    func removeAll(owner: PrincipalID) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(owner.rawValue)/"
        storage = storage.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// 读取总是抛错的凭证存储（m-2：读失败必须可观测，不能等同于「本无凭证」）。
///
/// `failingReads` 可在登录后翻转为 `true`：登录本身（两步流的 `/me`）也要读 access token，
/// 所以「一上来就读不出」的存储会把登录打断；能翻转才既能建立一次真实登录、
/// 又能覆盖「登录之后 keychain 读不出」这一 m-2 场景。
final class ReadFailingSecureStore: SecureStore, @unchecked Sendable {
    private let inner: InMemorySecureStore
    private let lock = NSLock()
    private var failing: Bool

    init(inner: InMemorySecureStore, failingReads: Bool = true) {
        self.inner = inner
        self.failing = failingReads
    }

    func setFailingReads(_ value: Bool) {
        lock.lock()
        failing = value
        lock.unlock()
    }

    func set(_ secret: SecretString, for item: SecureStoreItem) throws {
        try inner.set(secret, for: item)
    }

    func secret(for item: SecureStoreItem) throws -> SecretString? {
        lock.lock()
        let shouldFail = failing
        lock.unlock()
        guard shouldFail else { return try inner.secret(for: item) }
        throw SecureStoreError.status(-25300)
    }

    func removeSecret(for item: SecureStoreItem) throws {
        try inner.removeSecret(for: item)
    }

    func removeAllSecrets(for principalId: PrincipalID) throws {
        try inner.removeAllSecrets(for: principalId)
    }
}

// MARK: - 登录两步流（`POST /api/auth/login` → `GET /api/auth/me`）测试装配

/// 测试账号在登录两步流中的**成对**响应。
///
/// 生产 `signIn` 两步：`/login` 只建立凭证，`/me` 才是权威身份，且两步的 `user.id` 必须一致
/// （不一致即 fail-closed，见 `CovaAuthSession.signIn`）。因此「stub 了登录」的测试必须同时
/// stub `/me`，且两份响应同 id —— 本类型把两者绑成一个值，让「只装其一」无处可藏。
enum TestAccount: String, CaseIterable, Sendable {
    case a
    case b

    var principal: PrincipalID {
        switch self {
        case .a: return PrincipalID(rawValue: "user-0001")
        case .b: return PrincipalID(rawValue: "user-0002")
        }
    }

    var accessToken: String {
        switch self {
        case .a: return "ACCESS_TOKEN_PLACEHOLDER"
        case .b: return "SECOND_ACCESS"
        }
    }

    /// `POST /api/auth/login` 响应体（`user.id == principal.rawValue`）。
    var loginBody: Data {
        switch self {
        case .a:
            return TestTransportData.login
        case .b:
            return Data(
                #"{"user":{"id":"user-0002","name":"乙","role":"user","email":"b@example.invalid","covaId":null,"phone":null,"isArtist":false,"isPartner":false},"token":"SECOND_ACCESS","refreshToken":"SECOND_REFRESH","expiresIn":7200}"#.utf8
            )
        }
    }

    /// `GET /api/auth/me` 响应体：`user.id` 与本账号 `loginBody` 一致，身份字段由 `/me` 给全。
    var meBody: Data {
        switch self {
        case .a:
            return TestTransportData.me
        case .b:
            return Data(
                #"{"user":{"id":"user-0002","name":"乙","role":"user","email":"b@example.invalid","covaId":"COVA-0002","phone":null,"isArtist":false,"isPartner":false},"entitlements":{"plan":"free","subscriptionId":null,"activeUntil":null,"creditsBalance":0,"monthlyCredits":0,"canDownload":true,"canUseCovaAI":true,"canRequestProjects":false}}"#.utf8
            )
        }
    }

    var loginResponse: HTTPResponse { HTTPResponse(statusCode: 200, body: loginBody) }
    var meResponse: HTTPResponse { HTTPResponse(statusCode: 200, body: meBody) }

    func item(_ kind: CredentialKind) -> SecureStoreItem {
        SecureStoreItem(principalId: principal, kind: kind)
    }
}

/// 登录两步流的派发脚本：按顺序给出各账号的 `/login`，并按 `/me` 出示的 access token
/// 找回**签发该 token 的账号**、回它的 `/me`。
///
/// 用 token 而非「第几次调用」配对，切号 / 并发场景下不会把 B 的身份错发给 A 的 `/me`。
/// 未知 token 直接 401（不兜底空 body）：漏装或装错 `/me` 会立刻红，而不是被掩盖。
final class AuthFlowScript: @unchecked Sendable {
    private let accounts: [TestAccount]
    private let lock = NSLock()
    private var served = 0

    init(accounts: [TestAccount] = [.a]) {
        self.accounts = accounts
    }

    /// 第 N 次登录回第 N 个账号；账号用尽后停在最后一个（切到 B 之后再登录仍是 B）。
    func nextLoginResponse() -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        served += 1
        return accounts[min(served, accounts.count) - 1].loginResponse
    }

    func meResponse(for request: HTTPRequest) -> HTTPResponse {
        guard let bearer = request.bearerToken,
              let account = accounts.first(where: { $0.accessToken == bearer }) else {
            return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
        }
        return account.meResponse
    }
}

/// 装好登录两步流的假传输层：`/login` 与 `/me` 由 `script` 成对派发。
///
/// - Parameters:
///   - script: 账号脚本（默认单账号 A）。
///   - other: 其余路由（刷新 / 登出 / 受保护资源）由调用方脚本化；默认 200 `{}`。
func makeAuthTransport(
    script: AuthFlowScript = AuthFlowScript(),
    other: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse = { _ in
        HTTPResponse(statusCode: 200, body: TestTransportData.ok)
    }
) -> FakeHTTPTransport {
    FakeHTTPTransport { request in
        switch request.url.path {
        case CovaAuthSession.loginPath:
            return script.nextLoginResponse()
        case CovaAuthSession.mePath:
            return script.meResponse(for: request)
        default:
            return try await other(request)
        }
    }
}

struct TestStack {
    let secureStore: InMemorySecureStore
    let ownerStore: InMemoryOwnerStore
    let lifecycle: SessionLifecycle
    let activeOwnerStore: InMemoryActiveOwnerStore
}

func makeTestStack(cleaners: [any LocalSessionStateClearing] = []) -> TestStack {
    let secureStore = InMemorySecureStore()
    let ownerStore = InMemoryOwnerStore()
    let lifecycle = SessionLifecycle(secureStore: secureStore, ownerStore: ownerStore, cleaners: cleaners)
    return TestStack(
        secureStore: secureStore,
        ownerStore: ownerStore,
        lifecycle: lifecycle,
        activeOwnerStore: InMemoryActiveOwnerStore()
    )
}

func makeAuthSession(
    transport: any HTTPTransport,
    stack: TestStack
) -> CovaAuthSession {
    CovaAuthSession(
        transport: transport,
        secureStore: stack.secureStore,
        lifecycle: stack.lifecycle,
        activeOwnerStore: stack.activeOwnerStore
    )
}

/// 把值在全部描述/反射面渲染成文本（用于泄漏断言）。
func renderAllSurfaces(_ value: Any) -> String {
    var out = ""
    out += String(describing: value)
    out += String(reflecting: value)
    out += "\(value)"
    out += String(describing: [value])
    out += String(describing: Optional(value))
    out += dumpString(value)
    for child in Mirror(reflecting: value).children {
        out += String(describing: child.value)
        out += String(reflecting: child.value)
    }
    return out
}

struct TextCollector: TextOutputStream {
    var output = ""
    mutating func write(_ string: String) { output += string }
}

func dumpString(_ value: Any) -> String {
    var collector = TextCollector()
    dump(value, to: &collector)
    return collector.output
}

enum TestTransportData {
    static let login = try! Fixture.data("auth-login")
    static let refresh = try! Fixture.data("auth-refresh")
    static let me = try! Fixture.data("auth-me")
    static let unauthorized = Data(#"{"error":"unauthorized"}"#.utf8)
    static let ok = Data("{}".utf8)
}

struct EmptyDTO: Decodable, Equatable {}

// MARK: - D23① 出口裁决用例共用的 URLSession 桩

/// 跳转回调的答案盒（`completionHandler` 是 escaping 的，局部 var 捕获在 Swift 6
/// 严格并发下不成立；锁内一次性记账，断言在回调之后读）。形状照音频层同名夹具。
final class RedirectAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var didRecord = false
    private var recorded: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        didRecord = true
        recorded = request
    }

    var didAnswer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRecord
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 记录**每一次出站**并按脚本交回响应（含 `Location`）的 `URLProtocol` 桩（零真实网络）。
///
/// 形状照 `PrivateAudioTransportTests.StubAudioURLProtocol`（那边已验证：`URLProtocol` 桩
/// **不驱动** URLSession 的自动跟随机器，3xx 会原样交回调用方 ⇒ 「追不追」这一判完全落在
/// 我们自己的代码里，于是「被拒 ⇒ 一次出站都没有」是**可断言**的，而不是叙事。
///
/// host 一律用保留 TLD `.invalid`：桩万一没接管，结果是测试变红而不是真的出网。
final class EgressStubURLProtocol: URLProtocol {
    struct Script {
        var statusCode = 200
        var body = Data()
        /// 3xx 的 `Location`（nil = 这一条响应不带跳转）。
        var location: String?
        /// 额外响应头（默认只给 Content-Type）。
        var headers: [String: String] = [:]
        /// 按**请求绝对地址**覆写的脚本：传输自己追出去的那一跳用它单独脚本化。
        var responses: [String: Script] = [:]
        /// 响应的**最终权威**（投递面兜底用例：模拟「已经被跟到别家」的形态）。
        var landedURLString: String?
        var failure: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script = Script()
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

    static func configure(_ update: Script) {
        lock.lock()
        defer { lock.unlock() }
        script = update
        capturedRequests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    /// 已出站的地址（断言「落地那台一次都没被访问」用）。
    static func capturedHosts() -> [String] {
        captured().compactMap(\.url?.host)
    }

    /// 锁内「记录请求 + 取脚本快照」，避免 `startLoading`（后台线程）裸读静态可变状态。
    private static func snapshot(for request: URLRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        return script
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scripted = Self.snapshot(for: request)
        let key = request.url?.absoluteString ?? ""
        let current = scripted.responses[key] ?? scripted
        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var headers = ["Content-Type": "application/json"]
        for (field, value) in current.headers { headers[field] = value }
        if let location = current.location { headers["Location"] = location }
        let target = current.landedURLString.flatMap(URL.init(string:)) ?? request.url!
        let response = HTTPURLResponse(
            url: target,
            statusCode: current.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !current.body.isEmpty { client?.urlProtocol(self, didLoad: current.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 装好 `EgressStubURLProtocol` 的会话配置。
///
/// - Parameter withGuard: 是否按**生产装配**那样把 D23① 的跳转守卫挂成 delegate。
///   true = 与生产同一条建会话的腿（测「出站之前拒」）；false = 注入式会话（只能测投递面兜底）。
func makeEgressStubSession(withGuard: Bool) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EgressStubURLProtocol.self]
    guard withGuard else { return URLSession(configuration: configuration) }
    return URLSession(
        configuration: configuration,
        delegate: CredentialedRedirectGuard(),
        delegateQueue: nil
    )
}
