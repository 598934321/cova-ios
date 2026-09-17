import Foundation

/// 下载条目（api-contracts 3：`DownloadItemDto`）。
///
/// 注意：`url` 是**授权后可下载的签名/代理地址**，属敏感数据 —— 禁止写日志、禁止进持久化索引
/// （AGENTS 硬边界 3 / D7）。
public struct DownloadItemDto: Codable, Equatable, Sendable {
    public let trackId: String
    public let downloadId: String
    public let url: String?
    public let filename: String?
    public let owned: Bool?

    enum CodingKeys: String, CodingKey {
        case trackId
        case downloadId
        case url
        case filename
        case owned
    }
}

/// `GET /api/downloads/checkout` 响应（api-contracts 3：`{downloadCredits, balance, enabled, format:'mp3'}`）。
/// 匿名访问时 `balance` 为 `null` → 全部字段可选。
public struct DownloadCheckoutInfoDto: Codable, Equatable, Sendable {
    public let downloadCredits: Int?
    public let balance: Int?
    public let enabled: Bool?
    public let format: String?

    enum CodingKeys: String, CodingKey {
        case downloadCredits
        case balance
        case enabled
        case format
    }
}

/// `POST /api/downloads/checkout` 响应：
/// `{batchId, chargedCredits, skippedOwned[], balance, downloads[], items[]}`。
/// `downloads` / `items` 为同一集合的两个键名，均建模以容忍后端择一返回。
public struct DownloadCheckoutResponseDto: Codable, Equatable, Sendable {
    public let batchId: String?
    public let chargedCredits: Int?
    public let skippedOwned: [String]?
    public let balance: Int?
    public let downloads: [DownloadItemDto]?
    public let items: [DownloadItemDto]?

    enum CodingKeys: String, CodingKey {
        case batchId
        case chargedCredits
        case skippedOwned
        case balance
        case downloads
        case items
    }

    /// 便利访问：条目列表（`downloads` 优先，回落 `items`）。
    public var resolvedItems: [DownloadItemDto] {
        downloads ?? items ?? []
    }
}
