import Foundation

/// 会员套餐（api-contracts 1：`free` / `creator` / `pro` / `enterprise`，封闭集合）。
public enum CovaPlan: String, Codable, Equatable, Sendable {
    case free
    case creator
    case pro
    case enterprise
}

/// 认证用户（api-contracts 1）。
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
public struct CovaLoginRequestDto: Codable, Equatable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case email
        case password
    }
}

/// `POST /api/auth/login` 响应（契约目标形态：`{user, token, refreshToken, expiresIn}`）。
///
/// **契约目标形态**：真实实现当前返回的 `user` 只有 `{id, email, name, role}`
/// （缺 `covaId/phone/isArtist/isPartner`），无法解码为完整 `AuthUser` ——
/// 已登记 `docs/NEEDS.md`（`AUTH-LOGIN-TOKENS` 补充项）。此处按契约建模，**不以非契约响应为基准**。
public struct CovaLoginResponseDto: Codable, Equatable, Sendable {
    public let user: AuthUser
    /// access token（Bearer）。禁止写日志/持久化索引（AGENTS 硬边界 3）。
    public let token: String
    /// refresh token（旋转）。
    public let refreshToken: String
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
public struct CovaRefreshResponseDto: Codable, Equatable, Sendable {
    public let token: String
    public let refreshToken: String
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
