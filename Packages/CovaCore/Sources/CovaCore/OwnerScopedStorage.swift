import Foundation

/// owner 绑定持久化错误。
public enum OwnerStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// principalId 或条目名不合法（空、路径分隔符、`.`/`..` 等）。
    case invalidName
    case encodingFailed
    case decodingFailed

    public var description: String {
        switch self {
        case .invalidName: return "owner 存储名称不合法"
        case .encodingFailed: return "owner 数据编码失败"
        case .decodingFailed: return "owner 数据解码失败"
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
    static let maximumNameLength = 128

    /// principalId → 安全目录名（不可信输入必须转义；空 principalId 返回 nil）。
    static func directoryName(for principalId: PrincipalID) -> String? {
        guard !principalId.rawValue.isEmpty else { return nil }
        var out = directoryPrefix
        for byte in principalId.rawValue.utf8 {
            if isSafeByte(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// 条目名合法性：非空、长度受限、无路径分隔符/控制字符、不等于 `.` / `..`。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maximumNameLength else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    private static func isSafeByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"),
             UInt8(ascii: "_"),
             UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }
}

/// 生产 owner 持久化：`<baseDirectory>/owner-<escaped principalId>/<name>.json`（JSON，sorted keys）。
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
        guard let url = fileURL(name: name, owner: owner) else { throw OwnerStoreError.invalidName }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw OwnerStoreError.decodingFailed
        }
    }

    public func save<Value: Codable>(_ value: Value, name: String, owner: PrincipalID) throws {
        guard let url = fileURL(name: name, owner: owner) else { throw OwnerStoreError.invalidName }
        let data: Data
        do {
            data = try Self.encoder.encode(value)
        } catch {
            throw OwnerStoreError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    public func remove(name: String, owner: PrincipalID) throws {
        guard let url = fileURL(name: name, owner: owner) else { throw OwnerStoreError.invalidName }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func removeAll(owner: PrincipalID) throws {
        guard let namespace = OwnerNamespace.directoryName(for: owner) else {
            throw OwnerStoreError.invalidName
        }
        let directory = baseDirectory.appendingPathComponent(namespace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func fileURL(name: String, owner: PrincipalID) -> URL? {
        guard OwnerNamespace.isValidName(name) else { return nil }
        guard let namespace = OwnerNamespace.directoryName(for: owner) else { return nil }
        let url = baseDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
        // 纵深防御：转义后仍强制校验结果落在 baseDirectory 内。
        let basePath = baseDirectory.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved.hasPrefix(basePath + "/") else { return nil }
        return url
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
