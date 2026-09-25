import Foundation

/// 业务错误响应封套（后端统一返回 `{error, code?}`）。
public struct CovaAPIErrorEnvelope: Codable, Equatable, Sendable {
    public let error: String?
    public let code: String?

    /// 对外构造（客户端可用它构造错误载荷/桩数据）。
    public init(error: String?, code: String?) {
        self.error = error
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case error
        case code
    }
}

/// D23①/② 的**出口拒绝**事实：某一条跳转的落地不在这一类请求允许的出口内，
/// 于是那一次出站**根本没有发生**（裁决在出站之前，不是投递之后再后悔）。
///
/// 载荷只有 `host` + `rule` 两个字符串，类型层面不存在 URL / query / header / token 字段；
/// 被拒地址上的签名查询串在这里无处可放（AGENTS 硬边界 3）。
///
/// 归一化后的落点（第 30 批③改的正是这一格）：`asCovaAPIError` →
/// **`.egressRefused(self)`**，host 与 rule 随错误一起走。两条属性到今天仍然一个字不改：
/// · **不可重试**（`isRetryable == false`）；
/// · **绝不落进 `.transport(code:)`** —— 那一档是可重试的，出口裁决被读成「网络抖了一下」
///   就是一次刷新/重放环（落地主机不会因为你换了 token 就变成生产出口）。
///
/// 为什么第 30 批把「独立类型 + 拍平成 `.invalidRequestURL`」换成「带上 payload 的独立分支」：
/// 上一批的判断是「跨模块加 case 会撞编译不过的穷举 switch，所以宁可独立」—— 那句话到今天
/// 只对了一半：真正该付的代价（`LoginFailureCopy.classify`、`PlayReportFailure.classify` 两处
/// **刻意不带 default** 的穷举）都在本仓、都可改，而省不下的是**信息**：host 在进入
/// `CovaAPIError` 的那一刻就死了，屏幕上只剩一句「请求地址非法（已拒绝出站）」，
/// 与 D23③「拒绝必须看得见是哪一台」直接冲突。新增 case 反而把"必须表态"变成编译期义务 ——
/// 以后每多一个错误消费点，就得显式说一次拒绝算哪一类，拍平不再是静默的默认行为。
public struct CovaEgressRefusal: Error, Equatable, Hashable, Sendable,
    CustomStringConvertible, LocalizedError
{
    /// 哪一类请求的边界被拒（D23 的两类各一条，与 `mediaRedirectAllowed` 同轴）。
    public enum Rule: String, Equatable, Sendable, CaseIterable {
        /// 带凭证的一类：落地必须仍是同一权威的生产出口（名单不构成放行理由）。
        case credentialLeg
        /// 不带凭证的一类：落地必须在许可名单的存储主机之内。
        case publicMediaLeg

        /// 给人看的分支名（中文）。`rawValue` 是英文枚举名，只能进代码与日志键，
        /// 不能进上屏串 —— 本仓「屏上无英文态名」的判据（见 `PlayerFailure.Kind.userLabel`）。
        public var userLabel: String {
            switch self {
            case .credentialLeg: return "凭证腿"
            case .publicMediaLeg: return "公开媒体腿"
            }
        }
    }

    /// 被拒的落地主机（`CovaEnvironment.egressHostLabel` 的口径：只有 host，取不出则占位）。
    public let host: String
    /// 触发拒绝的那一条类别规则（决定上屏那句话怎么说）。
    public let rule: Rule

    public init(host: String, rule: Rule = .credentialLeg) {
        self.host = host
        self.rule = rule
    }

    /// 出口裁决**不是**传输故障：重试不会改变结果（重放只会把同一条拒绝再判一次）。
    public var isRetryable: Bool { false }

    /// 归一进 `CovaAPIError` 世界：带着 host + rule 的独立分支
    /// （不可重试、也不是 401 ⇒ 不触发刷新重放；第 30 批③之前这里是 `.invalidRequestURL`，
    /// 一次归一就把 host 和 rule 全丢了）。
    public var asCovaAPIError: CovaAPIError { .egressRefused(self) }

    /// 上屏/日志文本：分支 + 主机名，**没有** scheme 之外的任何地址片段。
    public var description: String {
        switch rule {
        case .credentialLeg:
            return "跳转被拒绝：落地 \(host) 不是生产出口（凭证不出出口，该次请求未发出）"
        case .publicMediaLeg:
            return "跳转被拒绝：落地 \(host) 不在许可名单的存储主机内（该次请求未发出）"
        }
    }

    public var errorDescription: String? { description }
}

/// 统一的 API 错误模型。
///
/// 设计约束：
/// - 可判等（`Equatable`）便于测试与去重；
/// - 携带 HTTP 状态码与服务端业务码；
/// - `redactedDescription` 只输出分支名与码 —— **类型层面不存在 URL/token 字段**，
///   因此凭证与签名 URL 不可能被写进日志（AGENTS 硬边界 3）。
///   唯一的例外是 `.egressRefused`：它输出的是 `CovaEnvironment.egressHostLabel` 口径的
///   **裸 host**（path / query / fragment 一概不带，取不出 host 时是固定占位串）——
///   D23③ 要的恰恰是"看得见是哪一台"，而 host 不是秘密、签名才是。
public enum CovaAPIError: Error, Equatable, Sendable {
    /// 网络不可用（未连接/连接丢失/DNS 失败等）。
    case offline
    /// 请求超时（契约 15s）。
    case timeout
    /// 请求被取消。
    case cancelled
    /// 其它传输层失败，带底层错误码。
    case transport(code: Int)
    /// 响应不是合法 HTTP 响应（无状态码）。
    case invalidResponse
    /// 出站 URL 未通过出口守卫（D10）：非生产 origin、相对路径非法等。请求**未发出**。
    case invalidRequestURL
    /// **D23 的出口拒绝**（第 30 批③）：某一跳的落地不在这一类请求允许的出口内，
    /// 那一次出站**没有发生**。payload 带着被点名的 host 与触发的那条 rule。
    ///
    /// 为什么不并进 `.invalidRequestURL`（两条都"没出站"，看着是一类）：
    /// · `.invalidRequestURL` 是**本层构造不出合法地址**（`makeAPIURL` 失败、SSE 入口复核失败），
    ///   根本没有一个"落地"可点名；`.egressRefused` 是**服务端把我们指向了别家**，
    ///   那是后端契约（NEEDS-29）的可见面，两者的处理方与话术都不同；
    /// · 给已有 case 加 payload 会波及三个不相关的构造点（含 out-of-bounds 的
    ///   `CovaFeature/CatalogService.swift:97,117`），且要它们现编一个"拒绝理由"；
    /// · 新增 case 逼着两处**刻意无 default** 的穷举 switch（`LoginFailureCopy.classify`、
    ///   `PlayReportFailure.classify`）当场表态 —— 这正是把"拍平"从静默默认行为变成
    ///   编译期义务的唯一机制（`CovaEgressRefusal` 的注释记着上一批为什么反过来判）。
    /// 与今天的用例同源的两条属性：`isRetryable == false`、`httpStatusCode == nil`，
    /// 且**永远不等于** `.transport(code:)`（那一档可重试 ⇒ 刷新/重放环）。
    case egressRefused(CovaEgressRefusal)
    /// 会话已变化（换号/登出/新 generation）：在途请求不得用新账号凭证重放（D8）。
    case sessionChanged
    /// 凭证存储读取失败（Keychain 等返回异常状态）——与「本无凭证」不同，必须可观测。
    case credentialReadFailed
    /// 401：凭证缺失/过期（上层触发 single-flight refresh 后重放一次）。
    case unauthorized(apiCode: String?)
    /// 非 2xx 且非 401。
    case httpStatus(code: Int, apiCode: String?)
    /// 响应解码失败；`field` 为可定位字段名，不含任何原始响应内容。
    case decoding(field: String?)

    /// 关联的 HTTP 状态码（若为 HTTP 层错误）。
    public var httpStatusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .httpStatus(let code, _): return code
        default: return nil
        }
    }

    /// 是否适合重试（传输类 + 5xx + 429）。
    ///
    /// 出口拒绝（`.egressRefused` / `.invalidRequestURL`）**不在**这份名单里：
    /// 重放只会把同一条拒绝再判一次，落地主机不会因为换了 token 就变成生产出口。
    public var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .transport: return true
        case .httpStatus(let code, _): return code >= 500 || code == 429
        default: return false
        }
    }

    /// 出口拒绝的事实本身（host + rule），非拒绝分支返回 nil。
    ///
    /// 为什么要这个取值面而不是让调用方自己 `switch`：UI 侧要说"是哪一台"时必须拿到
    /// 那个 host，而 `switch` 一处、`default` 一档的写法正是把拒绝再拍平一次的入口。
    public var egressRefusal: CovaEgressRefusal? {
        guard case .egressRefused(let refusal) = self else { return nil }
        return refusal
    }

    /// 可安全写日志的描述：只有分支名与码。
    public var redactedDescription: String {
        switch self {
        case .offline: return "网络不可用"
        case .timeout: return "请求超时"
        case .cancelled: return "请求已取消"
        case .transport(let code): return "传输错误(\(code))"
        case .invalidResponse: return "响应格式无效"
        case .invalidRequestURL: return "请求地址非法（已拒绝出站）"
        case .egressRefused(let refusal):
            // 只有 host + 分支名（`egressHostLabel` 的口径：path/query 一概不带）。
            // 分隔符刻意用「，」而不是「/」：拒绝串里出现斜杠就等于把地址形状带了回来，
            // 而用例钉的是"点名的面里不许有 `/`、`?`、`=`"。
            return "出口已拒绝(\(refusal.rule.userLabel)，\(refusal.host))"
        case .sessionChanged: return "会话已变化（已放弃重放）"
        case .credentialReadFailed: return "凭证读取失败"
        case .unauthorized(let apiCode): return "未授权(\(apiCode ?? "no_code"))"
        case .httpStatus(let code, let apiCode): return "服务端错误(\(code)/\(apiCode ?? "no_code"))"
        case .decoding(let field): return "响应解码失败(\(field ?? "unknown"))"
        }
    }

    /// HTTP 状态码 + 业务码 → 错误。2xx 返回 `nil`（表示成功）。
    public static func classify(httpStatus: Int, apiCode: String?) -> CovaAPIError? {
        if (200...299).contains(httpStatus) { return nil }
        if httpStatus == 401 { return .unauthorized(apiCode: apiCode) }
        return .httpStatus(code: httpStatus, apiCode: apiCode)
    }

    /// HTTP 状态码 + 响应体 → 错误。响应体非预期结构时忽略业务码，不因此丢失状态码。
    public static func classify(httpStatus: Int, body: Data) -> CovaAPIError? {
        let envelope = try? JSONDecoder().decode(CovaAPIErrorEnvelope.self, from: body)
        return classify(httpStatus: httpStatus, apiCode: envelope?.code)
    }

    /// `URLError` 错误码 → 错误（纯整数映射，便于无网络依赖地测试）。
    public static func classify(transportErrorCode: Int) -> CovaAPIError {
        switch transportErrorCode {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .offline
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorCancelled:
            return .cancelled
        default:
            return .transport(code: transportErrorCode)
        }
    }

    /// 任意底层错误 → 统一的 `CovaAPIError`（传输层与认证层共用）。
    ///
    /// 已是 `CovaAPIError` 的原样返回；**出口拒绝**（`CovaEgressRefusal`）→ `.egressRefused(refusal)`
    /// （不可重试、不是 401，且 host + rule 随错误一起走 —— 第 30 批③之前它被拍平成
    /// `.invalidRequestURL`，点名能力在归一那一刻就死了）。
    /// 这一支必须在 `NSURLErrorDomain` 之前显式判：
    /// 漏掉它并不会崩，而是会掉进末尾的 `.transport(code:)` 那一档，把「主机不对」
    /// 伪装成「网络抖了一下」⇒ 上层按可重试处理 = 刷新/重放环（R17-3b 的错分面）。
    /// `CancellationError` → `.cancelled`；`NSURLErrorDomain` → 整数映射；
    /// 其余 → `.transport(code:)`（失败路径，不携带明文）。
    public static func normalize(_ error: Error) -> CovaAPIError {
        if let api = error as? CovaAPIError { return api }
        if let refusal = error as? CovaEgressRefusal { return refusal.asCovaAPIError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(transportErrorCode: nsError.code)
        }
        return .transport(code: nsError.code)
    }

    /// 解码失败 → 错误（只保留字段路径，不保留原始响应）。
    public static func classify(decoding error: DecodingError) -> CovaAPIError {
        switch error {
        case .keyNotFound(let key, _): return .decoding(field: key.stringValue)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return .decoding(field: context.codingPath.last?.stringValue)
        case .dataCorrupted(let context):
            return .decoding(field: context.codingPath.last?.stringValue)
        @unknown default:
            return .decoding(field: nil)
        }
    }
}
