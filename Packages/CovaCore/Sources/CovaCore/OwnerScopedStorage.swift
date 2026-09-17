import Foundation

/// owner 绑定持久化错误。
public enum OwnerStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// principalId 不合法（空/超长/非法字符）。
    case invalidOwner(OwnerIdentifierError)
    /// 条目名不合法（空、路径分隔符、`.`/`..`、超长、非法字符）。
    case invalidName
    case encodingFailed
    case decodingFailed
    /// 底层文件系统错误（名称过长、权限、磁盘等）；**不携带路径**，避免泄漏。
    case ioFailure

    public var description: String {
        switch self {
        case .invalidOwner(let reason): return "owner 标识不合法（\(reason)）"
        case .invalidName: return "owner 存储名称不合法"
        case .encodingFailed: return "owner 数据编码失败"
        case .decodingFailed: return "owner 数据解码失败"
        case .ioFailure: return "owner 数据读写失败"
        }
    }
}

/// owner 绑定持久化抽象（D9：Codable JSON + 沙盒文件）。
///
/// 所有读写都按 `owner`（principalId）命名空间隔离；`removeAll(owner:)` 用于登出/换号。
public protocol OwnerScopedStoring: Sendable {
    func load<Value: Codable>(_ type: Value.Type, name: String, owner: PrincipalID) throws -> Value?
    func save<Value: Codable>(_ value: Value, name: String, owner: PrincipalID) throws
    func remove(name: String, owner: PrincipalID) throws
    func removeAll(owner: PrincipalID) throws
}

/// principalId / 条目名 → 文件系统命名空间的转义与校验。
enum OwnerNamespace {
    /// 命名空间目录统一前缀，避免与任何真实路径或 `.`/`..` 语义冲突。
    static let directoryPrefix = "owner-"
    /// 条目名上限（UTF-8 字节数）。
    static let maximumNameLength = 120

    /// principalId → 安全目录名。
    ///
    /// 采用 **UTF-8 字节的小写 hex** 编码：既无路径分隔符，又在**大小写不敏感文件系统**
    /// （macOS 默认 APFS）下保持唯一 —— `User` 与 `user` 编码为不同目录。
    static func directoryName(for principalId: PrincipalID) -> String? {
        guard OwnerIdentifier.validationError(principalId) == nil else { return nil }
        var out = directoryPrefix
        out.reserveCapacity(directoryPrefix.count + principalId.rawValue.utf8.count * 2)
        for byte in principalId.rawValue.utf8 {
            out += String(format: "%02x", byte)
        }
        return out
    }

    /// 条目名合法性：非空、字节数受限、字符集 `[A-Za-z0-9._-]`、不等于 `.` / `..`。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameLength else { return false }
        guard name != ".", name != ".." else { return false }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 0x61 && value <= 0x7A)
                || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x30 && value <= 0x39)
                || value == 0x2D || value == 0x5F || value == 0x2E
            if !allowed { return false }
        }
        return true
    }
}

/// 生产 owner 持久化：`<baseDirectory>/owner-<hex principalId>/<name>.json`（JSON，sorted keys）。
///
/// `baseDirectory` 可注入 —— 测试使用临时目录，不写入用户真实 Application Support。
public struct OwnerScopedJSONStore: OwnerScopedStoring {
    private let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// 默认落点：Application Support/Cova/owners（沙盒内）。
    public static func defaultBaseDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("Cova", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
    }

    public func load<Value: Codable>(_ type: Value.Type, name: String, owner: PrincipalID) throws -> Value? {
        let url = try resolvedURL(name: name, owner: owner)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            do {
                return try JSONDecoder().decode(Value.self, from: data)
            } catch {
                throw OwnerStoreError.decodingFailed
            }
        } catch let error as OwnerStoreError {
            throw error
        } catch {
            throw OwnerStoreError.ioFailure
        }
    }

    public func save<Value: Codable>(_ value: Value, name: String, owner: PrincipalID) throws {
        let url = try resolvedURL(name: name, owner: owner)
        let data: Data
        do {
            data = try Self.encoder.encode(value)
        } catch {
            throw OwnerStoreError.encodingFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw OwnerStoreError.ioFailure
        }
    }

    public func remove(name: String, owner: PrincipalID) throws {
        let url = try resolvedURL(name: name, owner: owner)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        } catch {
            throw OwnerStoreError.ioFailure
        }
    }

    public func removeAll(owner: PrincipalID) throws {
        if let reason = OwnerIdentifier.validationError(owner) {
            throw OwnerStoreError.invalidOwner(reason)
        }
        guard let namespace = OwnerNamespace.directoryName(for: owner) else {
            throw OwnerStoreError.invalidOwner(.invalidCharacters)
        }
        let directory = baseDirectory.appendingPathComponent(namespace, isDirectory: true)
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw OwnerStoreError.ioFailure
        }
    }

    private func resolvedURL(name: String, owner: PrincipalID) throws -> URL {
        if let reason = OwnerIdentifier.validationError(owner) {
            throw OwnerStoreError.invalidOwner(reason)
        }
        guard OwnerNamespace.isValidName(name), let namespace = OwnerNamespace.directoryName(for: owner) else {
            throw OwnerStoreError.invalidName
        }
        let url = baseDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
        // 纵深防御：转义后仍强制校验结果落在 baseDirectory 内。
        let basePath = baseDirectory.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved.hasPrefix(basePath + "/") else { throw OwnerStoreError.invalidName }
        return url
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
