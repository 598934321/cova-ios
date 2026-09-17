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
/// - 只允许可打印字符：拒绝 **C0（0x00–0x1F）、C1（0x80–0x9F）、DEL（0x7F）**，
///   以及不可打印 Unicode（format / line separator / paragraph separator / surrogate /
///   private-use / unassigned），并拒绝 `/`、`\`、`:`。
///
/// TD-22：此前实现只匹配 `< 0x20 || == 0x7F`，C1 与不可打印 Unicode 会漏过；
/// 现改为按 Unicode 标量属性判定，文档与实现一致。
public enum OwnerIdentifier {
    /// 上限按 UTF-8 字节数计：hex 编码后 2 倍 + `owner-` 前缀仍 ≤ 255。
    public static let maximumByteLength = 120

    /// 校验；不合法返回原因，合法返回 `nil`。
    public static func validationError(_ principalId: PrincipalID) -> OwnerIdentifierError? {
        let raw = principalId.rawValue
        if raw.isEmpty { return .empty }
        if raw.utf8.count > maximumByteLength { return .tooLong(maximum: maximumByteLength) }
        for scalar in raw.unicodeScalars where isDisallowedScalar(scalar) {
            return .invalidCharacters
        }
        return nil
    }

    /// 不可打印 / 不可用于命名空间的 Unicode 标量判定。
    ///
    /// `CharacterSet.controlCharacters` 即 Unicode 通用类别 `Cc`（含 C0、DEL、C1）；
    /// 再显式拒绝 `Cf`（format，如零宽字符）、行/段分隔符与代理/私用/未分配码位。
    static func isDisallowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .format,
             .lineSeparator,
             .paragraphSeparator,
             .surrogate,
             .privateUse,
             .unassigned:
            return true
        default:
            break
        }
        let value = scalar.value
        return value == 0x2F || value == 0x5C || value == 0x3A
    }

    /// 抛出式入口。
    public static func requireValid(_ principalId: PrincipalID) throws {
        if let error = validationError(principalId) { throw error }
    }
}
