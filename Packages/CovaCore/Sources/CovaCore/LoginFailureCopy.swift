import Foundation

/// 10 登录失败话术的**唯一裁决面**（design/screens/10-login.md §4 错误表 + §8 文案清单 + §9 验收第 2 条）。
///
/// 为什么必须是一层纯函数而不是 `AppSession` 里那句拼接：旧写法是
/// `authPhase = .failed("登录失败：\(error.redactedDescription)")`，把分支名与服务端业务码
/// （`apiCode` 是响应体里的字符串，服务端可控）一起印上了屏 —— 那是「后端原值上屏」这一族的
/// 第五处。而 10 §9 要的恰恰相反：**固定四句话术、一字不改**。
///
/// 两条不可谈判的判据：
/// · **防枚举**（§9 验收第 2 条）：凭证被拒只有**一种**读法。400/401 都落 `invalidCredentials`
///   —— 若把 400（字段校验/凭证错）与 401（凭证错）说成两句，攻击者就能靠措辞差异
///   判出「这个邮箱有没有账号」，本屏的防枚举设计当场作废。
/// · **不许伪装成凭证错**：`offline` / 超时 / 5xx / 解码失败 / 会话变化**永远**拿不到
///   `invalidCredentials`。服务器没答上来时说「邮箱或密码不正确」，会让用户反复改一个本来正确的密码。
///
/// 表外形态（如 404/422/未知码、`sessionChanged`）§4 没有为它钉话术，一律落 `serverUnreachable`
/// —— 宁可用那句中性的「没成功，检查网络再试」，也不 §8 清单之外现编新词，更不退回复读服务端原文。
public enum LoginFailureCopy {
    /// §4 行「凭证被拒（401）」：**统一话术，不区分账号不存在 / 密码错**（防枚举）。
    public static let invalidCredentials = "邮箱或密码不正确"
    /// §4 行「传输/超时/5xx/解码失败」。
    public static let serverUnreachable = "登录没成功，检查一下网络再试"
    /// §4「离线」行。
    public static let offline = "离线：登录需要联网"
    /// §4 行「服务端要求验证（人机/风控）」（403）。
    public static let webVerificationRequired = "这个账号需要网页端继续验证"

    /// 任意底层错误 → 上屏话术。先经 `CovaAPIError.normalize` 归一，所以调用方
    /// 不需要自己分辨 `NSError` / `CancellationError`（`redactedDescription` 也不参与拼串）。
    public static func message(for error: Error) -> String {
        classify(CovaAPIError.normalize(error))
    }

    /// 已归一错误的分支 → 话术。**不加 `default`**：`CovaAPIError` 以后新增分支时必须在这里
    /// 显式表态它算凭证错还是算没答上来，不许悄悄落到"读服务端原文"那一侧。
    public static func classify(_ error: CovaAPIError) -> String {
        switch error {
        case .unauthorized:
            return invalidCredentials
        case .httpStatus(let code, _):
            // 状态码是唯一依据：`apiCode`（服务端字符串）在这里被**丢弃**，
            // 既不进话术也不进分支判断 —— 否则话术又变回服务端可控的 oracle。
            switch code {
            case 400, 401: return invalidCredentials
            case 403: return webVerificationRequired
            default: return serverUnreachable
            }
        case .offline:
            return offline
        case .egressRefused,
             .timeout, .cancelled, .transport, .invalidResponse, .invalidRequestURL,
             .sessionChanged, .credentialReadFailed, .decoding:
            // `.egressRefused`（出口裁决把这一跳关掉了）走的是同一句中性话术，两半都要说清：
            // · **绝不算凭证错**：一次出站都没发生，服务器根本没答过"邮箱或密码对不对"，
            //   说 `invalidCredentials` 就是让用户去改一个本来正确的密码（本层第 14 行的判据）；
            // · 也**不在这里点名 host**：§4/§8 给这一屏钉死的是**固定四句**，第 30 批不现编第五句
            //   （那是 design 的事，`docs/` 与 `design/` 本批为边界外）。拒绝的点名面在
            //   `redactedDescription` 与 `egressRefusal` 上 —— 播放器与目录那两类"能命名"的面
            //   才用它（`CatalogService.classify` 走 `default` 分支，会带出 host）。
            return serverUnreachable
        }
    }
}
