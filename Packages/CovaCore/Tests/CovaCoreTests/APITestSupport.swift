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

    var refreshToken: String {
        switch self {
        case .a: return "REFRESH_TOKEN_PLACEHOLDER"
        case .b: return "SECOND_REFRESH"
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

    /// `/me` 给出的权威身份（断言用：登录成功后 `state` 里的 user 必须等于它）。
    var meUser: AuthUser {
        get throws { try JSONDecoder().decode(CovaMeResponse.self, from: meBody).user }
    }

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
