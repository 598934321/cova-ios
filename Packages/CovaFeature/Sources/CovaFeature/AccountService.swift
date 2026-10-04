import CovaCore
import Foundation

/// 注销请求的落点（§7 #4 + 15 §3.G③，按 web v2.65.0 实契约分流）。
/// **每一种都对应屏上不一样的下一帧**：
/// · `effective` —— 生效态：立即走登出链，Toast「账号已注销」；
/// · `unauthenticated` —— 401「请先登录」：会话已过期（或上一次注销已落地、凭证被吊销），
///   本地登出但**不说「已注销」**——这句话客户端自己证不了；
/// · `unavailable` —— 端点未上线/下线（404/501）：如实显「暂未上线」，不回落登出；
/// · `rejected(message)` —— 其余 4xx：服务端 `error` 原样透传（裸码拦掉）；
/// · `retryable` —— 5xx/未知码与传输层失败：可安全重试（注销幂等：重放至多撞 401）。
public enum AccountDeletionOutcome: Equatable, Sendable {
    case effective
    case unauthenticated
    case unavailable
    case rejected(message: String?)
    case retryable
}

/// `POST /api/auth/delete-account`（§7 #4，web v2.65.0 上线）。
///
/// 走 `performCoded`（不抛非 2xx）而不是 `post` 便捷腿：401/404/501 是契约明写的
/// **正常可预期**落点，要拿到状态码说话，不是让 `CovaAPIError.httpStatus` 把它们和稀泥。
/// 仍然可能抛的只有传输层/出口层错误（已归一）。
public struct AccountService: Sendable {
    public static let deletePath = "/api/auth/delete-account"

    private let client: CovaAPIClient

    public init(client: CovaAPIClient) { self.client = client }

    /// 一次逻辑注销。**调用方持有 token**：同一逻辑操作的重试复用同一把键
    /// （服务端今天不读体里的键；携带它守的是硬边界 5 的客户端纪律，不是服务端契约）。
    public func deleteAccount(
        token: IdempotentRequestToken
    ) async throws -> AccountDeletionOutcome {
        let outcome = try await client.performCoded(
            method: .post, path: Self.deletePath,
            jsonBody: try JSONEncoder().encode(try AccountDeletionRequestDto(token: token))
        )
        return Self.classifyDelete(outcome)
    }

    // MARK: - 分流（纯函数，用例直钉）

    /// 注销回执 → 落点。两种 4xx 分开说：
    /// · 401 = 凭证失效（会话过期，或上一次注销已生效把会话吊销了）→ `.unauthenticated`，
    ///   屏上只说「登录状态已过期」，**不说**「账号已注销」；
    /// · 410 → `.effective`（Gone = 服务端明确说这个账号已经没了）；
    /// · 其余 4xx → `.rejected`（透传服务端人话）；5xx/未知 → `.retryable`（可重试，
    ///   不说「删了」也不说「拒了」）。
    static func classifyDelete(_ outcome: CovaHTTPOutcome) -> AccountDeletionOutcome {
        if outcome.isSuccess { return .effective }
        switch outcome.statusCode {
        case 401:
            return .unauthenticated
        case 410:
            return .effective
        case 404, 501:
            return .unavailable
        default:
            return (400...499).contains(outcome.statusCode)
                ? .rejected(message: Self.serverMessage(outcome.body))
                : .retryable
        }
    }

    /// 服务端 `error` 信封的人话（裸码不上屏，与 `StudioCreateRejection.human` 同一判据）。
    static func serverMessage(_ body: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CovaAPIErrorEnvelope.self, from: body),
              let message = envelope.error, !message.isEmpty else { return nil }
        let isBareCode = message.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
        return isBareCode ? nil : message
    }
}
