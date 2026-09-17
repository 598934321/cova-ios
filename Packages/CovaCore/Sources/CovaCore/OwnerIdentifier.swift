import Foundation

/// owner（principalId）作为存储命名空间 / Keychain 绑定键时的校验错误。
///
/// 空值、超长、控制字符与路径分隔符一律拒绝（fail-closed）。
/// `OwnerScopedJSONStore` 与 `SecureStore` 实现共用同一校验口径。
public enum OwnerIdentifierError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case tooLong(maximum: Int)
    case invalidCharacters

    public var description: String {
        switch self {
        case .empty: return "owner 标识为空"
        case .tooLong(let maximum): return "owner 标识超长（上限 \(maximum) 字节）"
        case .invalidCharacters: return "owner 标识含非法字符"
        }
    }
}

/// owner 标识校验（`PrincipalID` 来自服务端，不可信）。
///
/// 口径（与 `OwnerScopedJSONStore` 文件名校验一致，均为 fail-closed）：
/// - 非空；
/// - UTF-8 字节数 ≤ `maximumByteLength`（保证 hex 转义后的目录名 ≤ 文件系统 255 字节上限）；
/// - 只允许可打印字符，拒绝 C0/C1 控制字符、DEL、`/`、`\`、`:`。
public enum OwnerIdentifier {
    /// 上限按 UTF-8 字节数计：hex 编码后 2 倍 + `owner-` 前缀仍 ≤ 255。
    public static let maximumByteLength = 120

    /// 校验；不合法返回原因，合法返回 `nil`。
    public static func validationError(_ principalId: PrincipalID) -> OwnerIdentifierError? {
        let raw = principalId.rawValue
        if raw.isEmpty { return .empty }
        if raw.utf8.count > maximumByteLength { return .tooLong(maximum: maximumByteLength) }
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F { return .invalidCharacters }
            if value == 0x2F || value == 0x5C || value == 0x3A { return .invalidCharacters }
        }
        return nil
    }

    /// 抛出式入口。
    public static func requireValid(_ principalId: PrincipalID) throws {
        if let error = validationError(principalId) { throw error }
    }
}
