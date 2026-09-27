import CovaCore
import Foundation

/// 每日签到的两条腿（§5 P3）。
///
/// GET 读今日状态、POST 领取。**幂等这一格是服务端的**：`me/checkin/route.ts` 的注释明写
/// "幂等，重复点击/多 tab 不重复入账" ⇒ 客户端不再带幂等键（硬边界 5 管的是扣费写操作，
/// 签到是发放）。UI 侧的在途禁用只是让手不抖，不是协议保证 —— 这句话不冒领别人的功劳。
public struct CheckinService: Sendable {
    /// 服务端这一支不读请求体；参数全在身份里。
    private struct EmptyBody: Encodable {}

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    public func state() async throws -> DailyCheckinStateDto {
        try await client.get(DailyCheckinStateDto.path)
    }

    public func checkIn() async throws -> DailyCheckinResultDto {
        try await client.post(DailyCheckinStateDto.path, body: EmptyBody())
    }
}
