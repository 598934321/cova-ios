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
