import Foundation

/// 「上次活动 owner（principalId）」的持久化指针。
///
/// 冷启动恢复（M-2）需要在**不知道状态机当前 owner** 的情况下定位凭证命名空间；
/// token 本身存 Keychain 且按 principalId 绑定，故这里只持久化非敏感的 principalId 指针。
/// 指针不是凭证，但仍按 owner 校验口径转义/校验（脏数据一律拒绝）。
public protocol ActiveOwnerStoring: Sendable {
    func loadActiveOwner() throws -> PrincipalID?
    /// `nil` 表示清除指针（登出/换号/凭证吊销）。
    func saveActiveOwner(_ owner: PrincipalID?) throws
}

/// 指针读写错误（不携带任何 token；路径不进错误）。
public enum ActiveOwnerStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case ioFailure
    case decodingFailed
    case invalidOwner(OwnerIdentifierError)

    public var description: String {
        switch self {
        case .ioFailure: return "活动 owner 指针读写失败"
        case .decodingFailed: return "活动 owner 指针解码失败"
        case .invalidOwner(let reason): return "活动 owner 指针不合法（\(reason)）"
        }
    }
}

/// 内存实现（单测 / 预览）。
public final class InMemoryActiveOwnerStore: ActiveOwnerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var owner: PrincipalID?

    public init(owner: PrincipalID? = nil) {
        self.owner = owner
    }

    public func loadActiveOwner() throws -> PrincipalID? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }

    public func saveActiveOwner(_ owner: PrincipalID?) throws {
        if let owner, let reason = OwnerIdentifier.validationError(owner) {
            throw ActiveOwnerStoreError.invalidOwner(reason)
        }
        lock.lock()
        defer { lock.unlock() }
        self.owner = owner
    }
}

/// 生产实现：`<baseDirectory>/active-owner.json`（Codable JSON + 原子写；D9）。
public struct FileActiveOwnerStore: ActiveOwnerStoring {
    private struct Payload: Codable {
        let principalId: String
    }

    private let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// 默认落点：Application Support/Cova/session（沙盒内，非敏感）。
    public static func defaultBaseDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("Cova", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
    }

    public func loadActiveOwner() throws -> PrincipalID? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let owner = PrincipalID(rawValue: payload.principalId)
            if let reason = OwnerIdentifier.validationError(owner) {
                throw ActiveOwnerStoreError.invalidOwner(reason)
            }
            return owner
        } catch let error as ActiveOwnerStoreError {
            throw error
        } catch is DecodingError {
            throw ActiveOwnerStoreError.decodingFailed
        } catch {
            throw ActiveOwnerStoreError.ioFailure
        }
    }

    public func saveActiveOwner(_ owner: PrincipalID?) throws {
        let url = fileURL
        do {
            guard let owner else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            if let reason = OwnerIdentifier.validationError(owner) {
                throw ActiveOwnerStoreError.invalidOwner(reason)
            }
            let data = try JSONEncoder().encode(Payload(principalId: owner.rawValue))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: [.atomic])
            // m-2：内容仅 principalId（非敏感），仍按最小权限收紧为 0600。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as ActiveOwnerStoreError {
            throw error
        } catch {
            throw ActiveOwnerStoreError.ioFailure
        }
    }

    private var fileURL: URL {
        baseDirectory.appendingPathComponent("active-owner.json", isDirectory: false)
    }
}
