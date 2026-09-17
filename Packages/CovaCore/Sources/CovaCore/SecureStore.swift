import Foundation

/// 凭证种类（D5：access + refresh 对）。
public enum CredentialKind: String, CaseIterable, Codable, Sendable {
    case accessToken = "access-token"
    case refreshToken = "refresh-token"
}

/// 一段敏感字符串（token / 密码等）。
///
/// 安全约束（AGENTS 硬边界 3 / D5 / D11）：
/// - `description` / `debugDescription` **恒为** `<redacted>`，任何日志、断言描述、
///   错误描述都不会带出明文；
/// - `customMirror` 同样脱敏 —— `dump` / `Mirror(reflecting:)` 也拿不到 storage；
/// - 只提供 `Decodable`（从 JSON string 读入），**刻意不实现 `Encodable`**：
///   编译期阻止被 JSONEncoder 写到文件/索引（凭证只允许进 Keychain）；
/// - 明文只能经 `rawValue` 取用，调用方承担「不落日志/不落文件」责任。
public struct SecretString: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let storage: String

    public init(_ value: String) {
        storage = value
    }

    public var rawValue: String { storage }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }

    /// 反射面：`dump` / `Mirror` 也只看到占位符。
    public var customMirror: Mirror {
        Mirror(self, children: ["<redacted>": "<redacted>"], displayStyle: .struct)
    }
}

/// 只读解码：token 响应里的 JSON string → `SecretString`。
/// 不实现 `Encodable`（编译期禁止凭证被序列化出去）。
extension SecretString: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = try container.decode(String.self)
    }
}

/// 凭证条目标识：`(principalId, kind)`。
///
/// D5：持久化按 owner 绑定 —— 不同 principalId 的同类凭证是不同条目，互不可见。
public struct SecureStoreItem: Hashable, Sendable {
    public let principalId: PrincipalID
    public let kind: CredentialKind

    public init(principalId: PrincipalID, kind: CredentialKind) {
        self.principalId = principalId
        self.kind = kind
    }
}

/// 凭证存储错误。
///
/// 只携带操作状态码 / 结构性原因 —— **类型层面不存在 token 字段**，描述中不可能出现明文。
public enum SecureStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 底层存储返回的失败状态码（Keychain 为 `OSStatus`）。
    case status(Int32)
    /// 读取到的字节不是合法 UTF-8（凭证损坏）。
    case malformedSecret
    /// owner（principalId）不合法（空/超长/非法字符），拒绝落库以免退化为共享条目。
    case invalidPrincipal(OwnerIdentifierError)

    public var description: String {
        switch self {
        case .status(let code): return "凭证存储操作失败（状态码 \(code)）"
        case .malformedSecret: return "凭证数据不是合法 UTF-8"
        case .invalidPrincipal(let reason): return "凭证 owner 标识不合法（\(reason)）"
        }
    }
}

/// 凭证存储抽象（生产实现 = `KeychainStore`；测试/预览可用 `InMemorySecureStore`）。
///
/// 约定：读取缺失返回 `nil`（不抛错）；删除缺失视为成功（幂等）。
public protocol SecureStore: Sendable {
    func set(_ secret: SecretString, for item: SecureStoreItem) throws
    func secret(for item: SecureStoreItem) throws -> SecretString?
    func removeSecret(for item: SecureStoreItem) throws
    /// 清空指定 owner 的全部凭证（登出/换号；D8）。
    func removeAllSecrets(for principalId: PrincipalID) throws
}

/// 内存凭证存储：用于单元测试、界面预览与本地契约 mock。
///
/// 不做任何持久化；线程安全（`NSLock`）。
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecureStoreItem: String] = [:]

    public init() {}

    public func set(_ secret: SecretString, for item: SecureStoreItem) throws {
        try Self.requireValidPrincipal(item.principalId)
        lock.lock()
        defer { lock.unlock() }
        storage[item] = secret.rawValue
    }

    public func secret(for item: SecureStoreItem) throws -> SecretString? {
        try Self.requireValidPrincipal(item.principalId)
        lock.lock()
        defer { lock.unlock() }
        return storage[item].map(SecretString.init)
    }

    public func removeSecret(for item: SecureStoreItem) throws {
        try Self.requireValidPrincipal(item.principalId)
        lock.lock()
        defer { lock.unlock() }
        storage[item] = nil
    }

    public func removeAllSecrets(for principalId: PrincipalID) throws {
        try Self.requireValidPrincipal(principalId)
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { $0.key.principalId != principalId }
    }

    /// 与 `KeychainStore` / `OwnerScopedJSONStore` 同一校验口径（空 owner 会退化为共享条目，必须拒绝）。
    static func requireValidPrincipal(_ principalId: PrincipalID) throws {
        if let error = OwnerIdentifier.validationError(principalId) {
            throw SecureStoreError.invalidPrincipal(error)
        }
    }
}
