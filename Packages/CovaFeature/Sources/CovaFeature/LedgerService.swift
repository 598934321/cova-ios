import CovaCore
import Foundation

/// 积分流水的读腿（§5 P2-3 / §6 A9）。
///
/// 这个端点**只能读最近 100 条**：服务端只解析 `limit`（夹在 1..100，默认 50），
/// **没有** `offset`/`cursor`/类型过滤，排序固定 `createdAt DESC, id DESC`，
/// 响应里也**没有** `total`/`nextCursor`/`balance`（§4.7 实测）。
/// ⇒ 这一层不提供"翻页"方法，也不许在 UI 上做一个点了没用的「加载更多」。
public struct LedgerService: Sendable {

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// 读一页流水。默认 50 条、上限 100 条由 `CreditLedgerQuery` 夹好（恒发 `limit`，
    /// 不写就等于把"服务端默认 50"这个事实偷偷绑死在客户端）。
    public func entries(_ query: CreditLedgerQuery = CreditLedgerQuery()) async throws
        -> CreditLedgerPageDto
    {
        try await client.get(CreditLedgerQuery.path, queryItems: query.queryItems)
    }
}

/// 制作人卡片的读腿（§5 P2-2 / §6 A10）。
///
/// 灰度关闭时服务端回 **200 + `{producers:[]}`**（不是 403），而生产环境
/// `PRODUCER_MODE` 未设 + `NODE_ENV=production` ⇒ 恒为关闭（§4.7）。
/// ⇒ "空列表"与"读失败"必须分成两态交给 UI：前者是**入口不可见**（不是置灰），
/// 后者才是一句"没读到"。把失败画成空态，就等于把灰度没开这个事实替后端说了。
public struct ProducersService: Sendable {

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    public func cards() async throws -> ProducersResponseDto {
        try await client.get(ProducersResponseDto.path)
    }
}
