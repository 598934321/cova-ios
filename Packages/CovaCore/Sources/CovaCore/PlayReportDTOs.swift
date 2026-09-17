import Foundation

/// 播放上报（api-contracts 2：`POST /api/tracks/play`，`source: "app-ios"` + 幂等键）。
///
/// D8/D10：一次实际播放一个幂等键；`source` 固定为 `app-ios`（NEEDS-2 待后端 allowlist 放行）。
public struct PlayReportRequestDto: Codable, Equatable, Sendable {
    /// iOS 客户端播放来源标识（D10）。
    public static let appIOSSource = "app-ios"

    public let trackId: String
    public let source: String
    public let idempotencyKey: IdempotencyKey

    public init(trackId: String, source: String = PlayReportRequestDto.appIOSSource, idempotencyKey: IdempotencyKey) {
        self.trackId = trackId
        self.source = source
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case trackId
        case source
        case idempotencyKey
    }
}

/// 播放记录明细（响应内嵌）。
public struct PlayReportRecordDto: Codable, Equatable, Sendable {
    public let trackId: String?
    public let source: String?
    public let playedAt: String?

    enum CodingKeys: String, CodingKey {
        case trackId
        case source
        case playedAt
    }
}

/// `POST /api/tracks/play` 响应（真实实现：`{message, recorded, idempotentReplay, authenticated, play}`）。
///
/// `idempotentReplay == true` 表示该幂等键此前已记录（去重命中），上层据此不再重复计数。
public struct PlayReportResponseDto: Codable, Equatable, Sendable {
    public let message: String?
    public let recorded: Bool?
    public let idempotentReplay: Bool?
    public let authenticated: Bool?
    public let play: PlayReportRecordDto?

    enum CodingKeys: String, CodingKey {
        case message
        case recorded
        case idempotentReplay
        case authenticated
        case play
    }
}
