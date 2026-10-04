import Foundation

// §7 #4 删号契约面（2026-10-02 对齐 web v2.65.0 实契约）：
//   `POST /api/auth/delete-account` —— 需登录；**无请求体**（端点不读体：密码、冷静期、
//   撤销键一律不存在，客户端不发明）；2xx `{ok:true}` 即生效——身份字段清空匿名化、
//   全部会话吊销；401 `{error:"请先登录"}` = 凭证已失效/已注销。
// 重复提交天然安全：注销成功后凭证已吊销，重放只会撞 401。
// `idempotencyKey` 仍随体携带（硬边界 5：写操作必带键）：服务端今天不读，
// 但这是客户端纪律且服务端将来收键时无需改客户端。operation = `.accountDeletion`。

/// `POST /api/auth/delete-account` 请求体。
public struct AccountDeletionRequestDto: Encodable, Sendable {
    public let idempotencyKey: IdempotencyKey

    public init(token: IdempotentRequestToken) throws {
        guard token.operation == .accountDeletion else {
            throw IdempotencyKeyError.operationMismatch
        }
        self.idempotencyKey = token.key
    }

    enum CodingKeys: String, CodingKey { case idempotencyKey }
}

/// `POST /api/auth/delete-account` 的响应（实测形态 `{ok:true}`）。
/// 容错口径：所有键可缺、未知键忽略——`ok != true` 的 2xx 由分流层决定怎么读，
/// 本 DTO 只管把信封原样摆出来。
public struct AccountDeletionResponseDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    /// 服务端人话（可为空）；裸码形态由 `AccountService.serverMessage` 拦在上屏前。
    public let message: String?

    enum CodingKeys: String, CodingKey { case ok, message }

    public init(ok: Bool?, message: String?) {
        self.ok = ok
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
    }
}
