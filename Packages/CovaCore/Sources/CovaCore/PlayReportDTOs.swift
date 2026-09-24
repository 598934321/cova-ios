import Foundation

/// 播放上报的来源标识 —— **服务端 `POST /api/tracks/play` 的 allowlist 是闭合的**。
///
/// 线上实证（2026-09-24）：`source: "app-ios"` ⇒ 400 `{code:"PLAY_SOURCE_INVALID",
/// error:"播放来源无效"}`；`source: "discover"` ⇒ 200。后端只认这五个值
/// （`play-history` 模块里的字面量列表），客户端自造的任何串都会被拒 ——
/// 所以这里把它做成**类型**而不是字符串常量：非法值不是「建议不要用」，而是**写不出来**。
///
/// 归因口径（今日事实，不假装有精度）：
/// - `.player` 是**默认值**：全 App 只有一个播放面（`CovaPlayer` 常驻播控条），
///   起播方没有把「从哪一层进来」告诉播放层，未指明时按这一层归因；
/// - 其余四值只在**调用点自己已经知道语境**时才显式传入：曲库/广场推荐位是
///   `discover`、歌单与收藏是 `playlist`、作品页/相似曲目是 `track_detail`、
///   生成结果内试听是 `project`；
/// - 语境目前只存在于视图层，`PlaybackItem` 与播放队列刻意不携带来源字段，
///   所以本层唯一的生产调用点（`PlaybackCoordinator` 的集次上报）落 `.player`。
public enum PlayReportSource: String, Codable, CaseIterable, Sendable {
    case discover
    case playlist
    case project
    case trackDetail = "track_detail"
    case player
}

/// 播放上报（api-contracts §2：`POST /api/tracks/play`，`source` ∈ `PlayReportSource` + 幂等键）。
///
/// D8/D10：一次实际播放一个幂等键；`source` 由 `PlayReportSource` 钉在闭合集内。
///
/// 服务端对**同一幂等键**还要求 `(trackId, source)` 完全一致，否则 409
/// `IDEMPOTENCY_CONFLICT` —— 所以重试必须连来源一起复用（`PlayReportCoordinator`
/// 把来源记在集次上，而不是每次提交重新取默认值）。
///
/// TD-24：只接受 `IdempotentRequestToken`（operation 必须为 `.playReport`）；
/// 仅 `Encodable`，无法从任意 JSON 灌入任意幂等键。
public struct PlayReportRequestDto: Encodable, Equatable, Sendable {
    public let trackId: String
    public let source: PlayReportSource
    public let idempotencyKey: IdempotencyKey

    public init(
        trackId: String,
        source: PlayReportSource = .player,
        token: IdempotentRequestToken
    ) throws {
        guard token.operation == .playReport else {
            throw IdempotencyKeyError.operationMismatch
        }
        self.trackId = trackId
        self.source = source
        self.idempotencyKey = token.key
    }

    enum CodingKeys: String, CodingKey {
        case trackId
        case source
        case idempotencyKey
    }
}

/// 播放记录明细（响应内嵌）。
///
/// `source` 是**服务端回显**、保持松散 `String?`：同一幂等键的重放会带回当初落库的值，
/// 而那条记录可能出自别的客户端（Web 的 `discover` 等），这里 fail-closed 只会把
/// 「服务端已经记上了」误判成解码失败，从而触发没有必要的重投。
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
