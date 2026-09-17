import Foundation
import Security

/// 一次 Keychain 条目查询的规范形态（纯值，可单测）。
///
/// 绑定规则（D5）：`account = "<principalId>.<kind>"`，不同 owner 的同类凭证落入不同条目；
/// `service` 固定，避免污染系统其它 Keychain 条目。
struct KeychainItemQuery: Equatable, Sendable {
    static let service = "cn.covalink.ios.credentials"

    let account: String

    init(item: SecureStoreItem) {
        account = "\(item.principalId.rawValue).\(item.kind.rawValue)"
    }

    /// 新增条目需带的属性：generic password + service + account + `ThisDeviceOnly`。
    var insertAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    /// 检索/更新/删除用的定位属性（不含 accessibility / value）。
    var searchAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }
}

/// 注入层：把对 `SecItem*` 的调用收敛为 4 个操作，便于在**不触碰真实 Keychain** 的前提下单测。
protocol KeychainItemOperating: Sendable {
    func insert(_ query: KeychainItemQuery, value: Data) -> Int32
    func read(_ query: KeychainItemQuery) -> (status: Int32, value: Data?)
    func update(_ query: KeychainItemQuery, value: Data) -> Int32
    func delete(_ query: KeychainItemQuery) -> Int32
}

/// 真实 Keychain 操作层（iOS/macOS 的 Security.framework，平台中立）。
struct SystemKeychainItemOperating: KeychainItemOperating {
    func insert(_ query: KeychainItemQuery, value: Data) -> Int32 {
        var attributes = query.insertAttributes
        attributes[kSecValueData as String] = value
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func read(_ query: KeychainItemQuery) -> (status: Int32, value: Data?) {
        var attributes = query.searchAttributes
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (status, nil)
        }
        return (status, data)
    }

    func update(_ query: KeychainItemQuery, value: Data) -> Int32 {
        let changes = [kSecValueData as String: value] as CFDictionary
        return SecItemUpdate(query.searchAttributes as CFDictionary, changes)
    }

    func delete(_ query: KeychainItemQuery) -> Int32 {
        SecItemDelete(query.searchAttributes as CFDictionary)
    }
}

/// 生产凭证存储：Keychain generic password（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。
///
/// - 不落明文文件；Keychain 在设备锁屏后首次解锁前不可读（`AfterFirstUnlock`），
///   且**不参与备份迁移**（`ThisDeviceOnly`）；
/// - 所有错误只带 `OSStatus`，不含 token 明文；
/// - `SecItem*` 通过注入层调用 —— 单测使用假操作层，**永不触碰真实 Keychain**。
public struct KeychainStore: SecureStore {
    private let operations: any KeychainItemOperating

    public init() {
        operations = SystemKeychainItemOperating()
    }

    init(operations: any KeychainItemOperating) {
        self.operations = operations
    }

    public func set(_ secret: SecretString, for item: SecureStoreItem) throws {
        let query = KeychainItemQuery(item: item)
        let data = Data(secret.rawValue.utf8)
        let status = operations.insert(query, value: data)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = operations.update(query, value: data)
            guard updateStatus == errSecSuccess else {
                throw SecureStoreError.status(updateStatus)
            }
        default:
            throw SecureStoreError.status(status)
        }
    }

    public func secret(for item: SecureStoreItem) throws -> SecretString? {
        let query = KeychainItemQuery(item: item)
        let result = operations.read(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.value, let value = String(data: data, encoding: .utf8) else {
                throw SecureStoreError.malformedSecret
            }
            return SecretString(value)
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.status(result.status)
        }
    }

    public func removeSecret(for item: SecureStoreItem) throws {
        let status = operations.delete(KeychainItemQuery(item: item))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.status(status)
        }
    }

    public func removeAllSecrets(for principalId: PrincipalID) throws {
        for kind in CredentialKind.allCases {
            try removeSecret(for: SecureStoreItem(principalId: principalId, kind: kind))
        }
    }
}
