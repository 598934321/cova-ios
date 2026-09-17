import CovaCore
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

struct TestStack {
    let secureStore: InMemorySecureStore
    let ownerStore: InMemoryOwnerStore
    let lifecycle: SessionLifecycle
}

func makeTestStack(cleaners: [any LocalSessionStateClearing] = []) -> TestStack {
    let secureStore = InMemorySecureStore()
    let ownerStore = InMemoryOwnerStore()
    let lifecycle = SessionLifecycle(secureStore: secureStore, ownerStore: ownerStore, cleaners: cleaners)
    return TestStack(secureStore: secureStore, ownerStore: ownerStore, lifecycle: lifecycle)
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
    static let unauthorized = Data(#"{"error":"unauthorized"}"#.utf8)
    static let ok = Data("{}".utf8)
}

struct EmptyDTO: Decodable, Equatable {}
