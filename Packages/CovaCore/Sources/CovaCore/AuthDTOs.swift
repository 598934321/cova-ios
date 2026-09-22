import Foundation

/// 会员套餐（api-contracts 1：`free` / `creator` / `pro` / `enterprise`，封闭集合）。
public enum CovaPlan: String, Codable, Equatable, Sendable {
    case free
    case creator
    case pro
    case enterprise
}

/// 认证用户（api-contracts 1）。
///
/// **解码容忍（NEEDS-1 未闭合期间）**：真实 `POST /api/auth/login` 的 `user` 只回
/// `{id, email, name, role}`。身份标记 `isArtist` / `isPartner` 缺席时按 `false` 读 ——
/// 这是**保守**方向（缺席 ⇒ 不授予艺术家/合作方身份，绝不放大权限），也不是把非契约响应
/// 当成契约：`docs/NEEDS.md` #1 仍是开放项，补齐后这两个键会真实出现。
/// `id / name / role` 保持严格必需（缺任一个 = 无法标识用户，必须报错而不是猜）。
public struct AuthUser: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: String
    public let email: String?
    public let covaId: String?
    public let phone: String?
    public let isArtist: Bool
    public let isPartner: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case email
        case covaId
        case phone
        case isArtist
        case isPartner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(String.self, forKey: .role)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        covaId = try container.decodeIfPresent(String.self, forKey: .covaId)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        isArtist = try container.decodeIfPresent(Bool.self, forKey: .isArtist) ?? false
        isPartner = try container.decodeIfPresent(Bool.self, forKey: .isPartner) ?? false
    }
}

/// 权益（api-contracts 1）。`subscriptionId` / `activeUntil` 为真实响应附加字段。
public struct Entitlements: Codable, Equatable, Sendable {
    public let plan: CovaPlan
    public let creditsBalance: Int
    public let monthlyCredits: Int
    public let canDownload: Bool
    public let canUseCovaAI: Bool
    public let canRequestProjects: Bool
    public let subscriptionId: String?
    public let activeUntil: String?

    enum CodingKeys: String, CodingKey {
        case plan
        case creditsBalance
        case monthlyCredits
        case canDownload
        case canUseCovaAI
        case canRequestProjects
        case subscriptionId
        case activeUntil
    }
}

/// `GET /api/auth/me` 响应（api-contracts 1：`{user, entitlements}`）。
public struct CovaMeResponse: Codable, Equatable, Sendable {
    public let user: AuthUser
    public let entitlements: Entitlements

    enum CodingKeys: String, CodingKey {
        case user
        case entitlements
    }
}

// MARK: - 登录 / 刷新 / 登出（api-contracts 1）

/// `POST /api/auth/login` 请求体。
///
/// TD-23（硬边界 3）：`password` 为 `SecretString` —— 描述/反射/Mirror 面恒为 `<redacted>`，
/// 且**不可编码**。这里以自定义 `encode(to:)` 在写请求体时取 `rawValue`：
/// 密码只有在「发往生产 origin 的请求体」这一条路径上才会成为明文字节。
public struct CovaLoginRequestDto: Codable, Equatable, Sendable {
    public let email: String
    public let password: SecretString

    public init(email: String, password: SecretString) {
        self.email = email
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case email
        case password
    }

    /// 手写编码：`SecretString` 不实现 `Encodable`，此处是密码进入请求体的唯一出口。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(password.rawValue, forKey: .password)
    }
}

/// `POST /api/auth/login` 响应（契约目标形态：`{user, token, refreshToken, expiresIn}`）。
///
/// **真实形态与契约的差异（NEEDS-1，D20 处置）**：真实实现返回的 `user` 只有
/// `{id, email, name, role}`。契约形态仍是建模基准（`covaId/phone/isArtist/isPartner` 一个不删），
/// 但解码对**缺席的可选身份字段**容忍（布尔缺席 ⇒ `false`，保守方向），否则用户在本机上
/// 永远登不进来、登录后的播放与上报链路无从验收。`id/name/role` 保持严格必需。
/// 后端补齐后这两个键会真实出现，容忍逻辑自动退化为无操作；`docs/NEEDS.md` #1 仍为开放项。
///
/// token 字段为 `SecretString`（§5）：只读解码、描述/反射全脱敏、**不可编码**（编译期禁止误持久化）。
public struct CovaLoginResponseDto: Decodable, Equatable, Sendable {
    public let user: AuthUser
    /// access token（Bearer）。禁止写日志/持久化索引（AGENTS 硬边界 3）。
    public let token: SecretString
    /// refresh token（旋转）。
    public let refreshToken: SecretString
    /// access token 有效期（秒）。
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case user
        case token
        case refreshToken
        case expiresIn
    }
}

/// `POST /api/auth/refresh` 响应（真实实现：`{token, refreshToken, expiresIn}`）。
///
/// 请求侧不携带 body：真实实现从 `Authorization: Bearer <refreshToken>` 头（或 Web cookie）读取。
/// token 字段同 `CovaLoginResponseDto` 使用 `SecretString`（只读、脱敏、不可编码）。
public struct CovaRefreshResponseDto: Decodable, Equatable, Sendable {
    public let token: SecretString
    public let refreshToken: SecretString
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case token
        case refreshToken
        case expiresIn
    }
}

/// `POST /api/auth/logout` 响应（真实实现：`{message}`）。
public struct CovaLogoutResponseDto: Codable, Equatable, Sendable {
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case message
    }
}
