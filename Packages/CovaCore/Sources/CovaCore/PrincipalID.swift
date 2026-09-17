import Foundation

/// 账号主体标识（D5/D9 的 owner 绑定键）。
///
/// 与任何 DTO 解耦：`AuthUser.id` / `user.id` 可映射到本类型，但 CovaCore 的存储层不依赖认证 DTO。
/// 取值来自服务端，**不可信**：作为文件/Keychain 命名空间前必须先转义（见 `OwnerNamespace`）。
public struct PrincipalID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isEmpty: Bool { rawValue.isEmpty }
}
