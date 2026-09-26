import Foundation

// MARK: - Agent 运行记录（P1「轮询断链补腿」）
//
// ## 为什么这一条腿不是 SSE 恢复（DEVELOPMENT.md §4.7 就地更正 §5 P1-5）
// `GET /api/studio/agent-runs/{id}` 是**普通 JSON**（`{run}`），不是事件流。
// 而 `/api/studio/agent` 那条 SSE：**每帧只有 `event:` / `data:` 两行，没有 `id:` 行**；
// 服务端**没有 `Last-Event-ID` 处理、没有环形缓冲** ⇒ 客户端断开期间产生的事件被**静默丢弃**。
// 于是「按事件 id 续流」在这台服务端上**不存在**（三件前置条件一件都没有）：
// · 客户端拿不到可回发的游标（没有 `id:`）；
// · 就算回发了，服务端也没有按游标补发的能力（没有缓冲）；
// · 本仓的 SSE 解析器对 `id`/`retry` 也只是忽略，从不实现回放
//   （`docs/log/20260917.md` 那条「不做完整 SSE 规范」的边界至今成立）。
// ⇒ 能做的只有**轮询对账**：读一次全量 `run`，与上一次快照比 `status` / `currentStep` /
//   `timeline[].sequence` 三件事，见 `AgentRunReconciler`。
//
// ## 词表为什么不在这里
// `run.status` 的取值集、`timeline[]` 条目的键名与那一套**脱敏后的**事件词表，
// 在 iOS 侧都**没有**逐条实测（§7 #13「agent 载荷 schema 未文档化」仍开着）。
// 特别提醒：`timeline` 的词表与 SSE 事件名（`thinking / text / plan_card / error / done /
// run_started / run_waiting_user / run_waiting_worker / run_completed / run_failed`）
// 是**两套东西**（前者是服务端脱敏视图，后者是流上原始事件名）⇒ 不许把 SSE 事件名
// 当 run 状态来判终态，也不许把 run 状态当 `CovaSSEEventType` 喂给流层。
// 所以本文件：① 把这些字段**原样保留**（不丢信息），② 终态判据**由调用方注入**
// （`AgentRunTerminalVocabulary`），③ 词表没覆盖到的状态**永不报终态**（宁可继续轮询）。

/// 一段未定形状的 JSON 载荷（原样保留，等契约钉死再上类型）。
///
/// 存在的理由不是"方便"，是**不发明**：`plan` / `checkpoint` / `timeline` 条目的内部键集
/// 未实测钉死，把它们建成一堆 `String?` 就是替服务端写它没写的字段（硬边界 7），
/// 而把它们建成 `Data` 又丢不了结构却读不出内容。这一格用本仓已有的手法
/// （`GenerationJobDto.metadata` 先留原文、按需再解），只是载荷是嵌套对象而不是字符串。
public enum AgentRunValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: AgentRunValue])
    case array([AgentRunValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: AgentRunValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentRunValue].self) {
            self = .array(value)
        } else {
            // 单值容器读不出上面任何一种：不猜、不吞成 null（那是把"没这种形状"伪装成"值是 null"）。
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "无法归类的 JSON 载荷形状"
            )
        }
    }

    public var text: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    public var integer: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        let rounded = value.rounded()
        // 只在不丢信息时才交整数（20.5 不是 20，也不是 21）。
        return rounded == value ? Int(exactly: rounded) : nil
    }
    public var flag: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: AgentRunValue]? {
        if case .object(let value) = self { value } else { nil }
    }
    public var arrayValue: [AgentRunValue]? {
        if case .array(let value) = self { value } else { nil }
    }
    public var isNull: Bool { if case .null = self { true } else { false } }
}

/// `run.timeline[]` 的一条。
///
/// 契约只钉死了一件：条目带 `sequence`，服务端在**追加时**赋 `timeline.length + 1`
/// （§4.7 的写法）。那一式有两个后果，都写在这一格的文档里：
/// · 序号是在"当时的数组长度"上算的 ⇒ 如果服务端重建过 timeline（截断、重排、脱敏折叠），
///   **序号可能重复也可能跳号** ⇒ 它不是持久游标，只能当"这轮读到过多大"的单调信号用；
/// · 其余键名与那一套脱敏词表未实测 ⇒ 原样留在 `fields`，**不**在这里建 `event`/`kind`/`label`
///   之类的属性（建了就等于替服务端选了一个键名，而选错的那一半是静默 `nil`）。
public struct AgentRunTimelineEntryDto: Decodable, Equatable, Sendable {
    /// 服务端给的位置号；读不出（缺键 / 非数字 / 带小数）⇒ `nil`，**不**按数组下标补一个
    /// （下标是客户端的视角，不是服务端那个号）。
    public let sequence: Int?
    /// 条目全部键的原样载荷（含 `sequence` 自己）。
    public let fields: [String: AgentRunValue]

    public init(sequence: Int?, fields: [String: AgentRunValue]) {
        self.sequence = sequence
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        // 永不抛：整个条目读成对象失败 ⇒ fields 空（一坏条目不许毁掉整份 run 快照）。
        let container = try? decoder.singleValueContainer()
        let raw = ((try? container?.decode([String: AgentRunValue].self)) ?? nil) ?? [:]
        fields = raw
        sequence = raw["sequence"]?.integer
    }

    /// 按调用方已知的键名读一格（**不猜键名**：不认识的键就是拿不到）。
    public func value(for key: String) -> AgentRunValue? { fields[key] }
    public func text(for key: String) -> String? { fields[key]?.text }

    /// 已建模的键名（取证用：能读出服务端今天到底在这条目里放了哪些键）。
    public var presentKeys: Set<String> { Set(fields.keys) }
}

/// 一次 agent 运行的快照（`run` 对象）。
///
/// 键集实测逐字：`id / sessionId / turnId / goal / status / currentStep / plan / checkpoint /
/// timeline / retryCount / stopReason / createdAt / updatedAt`。
/// 全部可选（读不出就是 `nil`，不填默认值），`timeline` 缺省成 `[]` 是唯一例外
/// —— 那一个是数组，"没有条目"与"没给这个键"在 UI 上都画同一片空白，
/// 于是本层用 `hasTimelineKey` 把那件事单独说清楚。
///
/// `description` **脱敏**：`goal` 是用户写的文本、`plan`/`checkpoint`/`timeline` 是 agent 的内部
/// 载荷（§7 #26 已经证明 SSE 事件字典里能出现 `credits` 这类意外字段）⇒ 默认反射会把它们
/// 整包印进日志（硬边界 3）。这里只交出身份、状态、步号与计数，一个载荷字符都不出。
public struct AgentRunDto: Decodable, Equatable, Sendable, CustomStringConvertible {
    public let id: String?
    public let sessionId: String?
    public let turnId: String?
    public let goal: String?
    /// 松散 `String?`：词表未实测（见文件头）。判终态走 `AgentRunTerminalVocabulary`，
    /// 不在这里 `switch` 一组我还没核过的字面量。
    public let status: String?
    public let currentStep: String?
    public let plan: AgentRunValue?
    public let checkpoint: AgentRunValue?
    public let timeline: [AgentRunTimelineEntryDto]
    public let hasTimelineKey: Bool
    public let retryCount: Int?
    public let stopReason: String?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sessionId, turnId, goal, status, currentStep, plan, checkpoint, timeline
        case retryCount, stopReason, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        sessionId = (try? container?.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil
        turnId = (try? container?.decodeIfPresent(String.self, forKey: .turnId)) ?? nil
        goal = (try? container?.decodeIfPresent(String.self, forKey: .goal)) ?? nil
        status = (try? container?.decodeIfPresent(String.self, forKey: .status)) ?? nil
        currentStep = (try? container?.decodeIfPresent(String.self, forKey: .currentStep)) ?? nil
        plan = (try? container?.decodeIfPresent(AgentRunValue.self, forKey: .plan)) ?? nil
        checkpoint = (try? container?.decodeIfPresent(AgentRunValue.self, forKey: .checkpoint)) ?? nil
        // `[Entry?]`：一个 `null` 条目不许把整份 run 判死（Swift 数组解码对非 Optional 元素
        // 在调元素 init **之前**就抛）。
        let wire = (try? container?.decodeIfPresent([AgentRunTimelineEntryDto?].self, forKey: .timeline)) ?? nil
        timeline = (wire ?? []).compactMap { $0 }
        hasTimelineKey = container?.contains(CodingKeys.timeline) ?? false
        retryCount = (try? container?.decodeIfPresent(Int.self, forKey: .retryCount)) ?? nil
        stopReason = (try? container?.decodeIfPresent(String.self, forKey: .stopReason)) ?? nil
        createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        updatedAt = (try? container?.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
    }

    // MARK: 对账用的三个可观测量（就是 §4.7 点名的那三件）

    /// timeline 里读得出的最大 `sequence`（一个都读不出 ⇒ `nil`）。
    public var latestSequence: Int? { timeline.compactMap(\.sequence).max() }

    /// 条目条数（**只在 `sequence` 全都读不出时**才当作进展信号用；正常路径看 `latestSequence`）。
    public var timelineCount: Int { timeline.count }

    /// 步号原样（`nil` = 服务端没给，与 `""` 不同 —— 空串也是"没给可显示的步"）。
    public var stepLabel: String? { WorksListQuery.textIfPresent(currentStep) }

    /// 服务端给的停止原因（终态时的解释文本，原样；读不出 ⇒ `nil`，**不**编"已停止"）。
    public var stopReasonText: String? { WorksListQuery.textIfPresent(stopReason) }

    /// 脱敏摘要（**不含** goal / plan / checkpoint / timeline 载荷）。
    public var description: String {
        "AgentRunDto(id: \(id ?? "<无 id>"), status: \(status ?? "<无>"), "
            + "currentStep: \(currentStep ?? "<无>"), timelineCount: \(timeline.count), "
            + "latestSequence: \(latestSequence.map(String.init) ?? "<无>"), "
            + "retryCount: \(retryCount.map(String.init) ?? "<无>"))"
    }

    public var debugDescription: String { description }
}

/// `GET /api/studio/agent-runs/{id}` 的响应封套 `{run}`。
///
/// 200 但读不出 `run`（`{}` / `{run:null}` / `run` 不是对象）⇒ `run == nil` 且
/// `isUnreadableEnvelope == true`：那是**契约漂移**，不许读成"这次运行不存在"，
/// 也不许读成"运行还在但没进度"（前者会让人去开新会话，后者会让人无限轮询）。
public struct AgentRunResponseDto: Decodable, Equatable, Sendable {
    public let run: AgentRunDto?
    /// `run` 这个键**在**、不是 null、却读不出快照。
    public let runKeyPresentButUnreadable: Bool

    enum CodingKeys: String, CodingKey { case run }

    public init(run: AgentRunDto?, runKeyPresentButUnreadable: Bool = false) {
        self.run = run
        self.runKeyPresentButUnreadable = runKeyPresentButUnreadable
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let keyPresent = root.contains(CodingKeys.run)
        let isNull = keyPresent ? ((try? root.decodeNil(forKey: .run)) ?? true) : true
        if keyPresent, !isNull {
            // `AgentRunDto` 自己**永不抛**（每个字段各自 `try?`），所以"run 是一个字符串"这种
            // 形状若直接交给它，会得到一个"有 run 但每个字段都是 nil"的幻影快照 ——
            // 那比报错更坏（UI 会画出一条根本不存在的运行）。先探一下它到底是不是对象。
            let isObject = ((try? root.decode(RunObjectProbe.self, forKey: .run)) ?? nil)?.isObject == true
            run = isObject ? ((try? root.decodeIfPresent(AgentRunDto.self, forKey: .run)) ?? nil) : nil
            runKeyPresentButUnreadable = run == nil
        } else {
            run = nil
            runKeyPresentButUnreadable = false   // 缺键 / null 是「没给行」，不是「给了读不出的行」
        }
    }

    /// 拿到了一次可用的运行快照。
    public var hasRun: Bool { run != nil }

    /// 200 里根本没有可读的 run（缺键 / null / 形状不对三种都算，UI 一律按"读不懂"处理）。
    public var isUnreadableEnvelope: Bool { run == nil }

    // MARK: 端点

    /// `GET /api/studio/agent-runs/{id}`（登录态；401 未认证、404 `运行记录不存在`）。
    public static let pathPrefix = "/api/studio/agent-runs"

    /// 完整路径；run id 不能安全进路径段 ⇒ `nil`（**不发**）。
    /// 校验复用 `WorksPathEncoding`（同一个"标识进路径"的判据不许有第二份）。
    public static func path(runID: String) -> String? {
        guard let identifier = WorksPathEncoding.safeIdentifier(runID) else { return nil }
        return "\(Self.pathPrefix)/\(identifier)"
    }
}

/// 只回答一件事：这个值**是不是一个对象**（`AgentRunDto` 永不抛，所以必须另有探针）。
private struct RunObjectProbe: Decodable {
    let isObject: Bool
    init(from decoder: Decoder) throws {
        isObject = (try? decoder.container(keyedBy: NoProbeKey.self)) != nil
    }

    /// 探针用的键集：一个真实键都不查，只问"能不能拿到 keyed 容器"。
    enum NoProbeKey: String, CodingKey { case sentinel = "__shape_probe__" }
}

// MARK: - 终态判据（由调用方注入）

/// run 的终态词表。
///
/// **为什么不由本层写死**：`run.status` 的取值集在 iOS 侧没被逐条实测（§7 #13/#34 都还开着）。
/// 在这一格写死 `case "completed", "succeeded"` 之类的清单，就是我替服务端发明了一份词表 ——
/// 而它的坏法很难看：词表少写一个值 ⇒ 已完成的运行被读成"还在跑" ⇒ 轮询永不停。
/// 所以本类型的默认值是**空集**，语义是"我还没资格判终态"，由接线那一层
/// （`CovaFeature` 的 service，或后端给出词表后）填进来。
public struct AgentRunTerminalVocabulary: Equatable, Sendable {
    public let successStatuses: Set<String>
    public let failureStatuses: Set<String>

    public init(successStatuses: Set<String> = [], failureStatuses: Set<String> = []) {
        // 同一个状态同时进两个集合是配置错误（判出来的终态取决于枚举顺序）：
        // 这里把它当**失败优先**处理，因为"停轮询并报失败"比"停轮询并报成功"少骗人。
        self.successStatuses = successStatuses
        self.failureStatuses = failureStatuses
    }

    /// 尚未注入（空集）⇒ 本层**永不**报终态。
    public static let notDeclared = AgentRunTerminalVocabulary()

    public var isDeclared: Bool { !successStatuses.isEmpty || !failureStatuses.isEmpty }

    public func terminality(of status: String?) -> AgentRunTerminality {
        guard let status, !status.isEmpty else { return .unknown }
        // 失败优先（见 init 的注释）。
        if failureStatuses.contains(status) { return .failure }
        if successStatuses.contains(status) { return .success }
        return .running
    }
}

public enum AgentRunTerminality: Equatable, Sendable {
    case success
    case failure
    /// 词表认识这个值，且它不是终态（还在跑）。
    case running
    /// 空 / 读不出 —— 与 `.running` 不同：那是"没有可判的状态"。
    case unknown
}

// MARK: - 轮询对账

/// 一次"上一份快照 → 这一份快照"的对账结论。
public enum AgentRunReconciliation: Equatable, Sendable {
    /// 两次读数没有任何可观察差别。
    case unchanged
    /// 有进展（`status` / `currentStep` / `timeline` 最大 `sequence` / 条目数 / `retryCount` 至少一项变大或改变）。
    ///
    /// 首帧也走这一格（没有基线可对账时报"没进展"是假话 —— 屏幕上刚刚多出一份可显示的东西）。
    case progressed
    /// 终态成功。**只有注入的词表认得这个状态时才会报**（见 `AgentRunTerminalVocabulary`）。
    case terminalSuccess
    /// 终态失败，携服务端的 `stopReason` 原文（没给 ⇒ `nil`，不编一句"运行失败"的原因）。
    case terminalFailed(stopReason: String?)
    /// 两次读数不属于同一次运行（id 都在且不同）⇒ **不是**"没进展"，是拿错了快照。
    case identityMismatch(expectedRunID: String?, observedRunID: String?)
}

/// 轮询对账（纯函数，零 timer、零网络：调度在调用方，判据在这里）。
public enum AgentRunReconciler {
    /// 前一份快照 + 刚读到的这一份 ⇒ 该按哪件事行动。
    ///
    /// 判据顺序是刻意的：
    /// ① 身份不符先报（拿错快照时后面每一个比较都没意义）；
    /// ② **终态优先于"进展"**：已经读到终态就交终态，哪怕顺带还有新条目 ——
    ///   调用方拿到终态要**停轮询**，把它降级成 `.progressed` 就是让轮询永不停；
    /// ③ 已在同一终态上再读到同一次终态 ⇒ **仍报终态**，不报 `.unchanged`
    ///   （"停轮询"这个信号不能因为两次读数恰好相同就消失）；
    /// ④ 词表没注入 / 不认识这个 status ⇒ **不报终态**，只报 `.progressed` / `.unchanged`
    ///   （宁可持续轮询，也不猜一次"它结束了"；猜错的代价是 UI 提前收尾或永不收尾）。
    public static func reconcile(
        previous: AgentRunDto? = nil,
        fresh: AgentRunDto,
        terminal: AgentRunTerminalVocabulary = .notDeclared
    ) -> AgentRunReconciliation {
        if let previousID = previous?.id.flatMap(WorksListQuery.textIfPresent),
           let freshID = fresh.id.flatMap(WorksListQuery.textIfPresent),
           previousID != freshID {
            return .identityMismatch(expectedRunID: previousID, observedRunID: freshID)
        }

        switch terminal.terminality(of: fresh.status) {
        case .success:
            return .terminalSuccess
        case .failure:
            return .terminalFailed(stopReason: fresh.stopReasonText)
        case .running, .unknown:
            break   // 不是终态（或者本层没资格判）⇒ 往下比进展
        }

        guard let previous else { return .progressed }

        if previous.status != fresh.status { return .progressed }
        if previous.currentStep != fresh.currentStep { return .progressed }
        if let before = previous.latestSequence, let after = fresh.latestSequence {
            if after > before { return .progressed }
        }
        // sequence 全都读不出来时，条目数才是唯一看得见的进展（服务端把号跳着发也得有个兜底）。
        if previous.latestSequence == nil, fresh.latestSequence == nil,
           fresh.timelineCount > previous.timelineCount {
            return .progressed
        }
        // retryCount 与 status/currentStep 同一口径：**变了**就是进展（不判方向，
        // 因为"从 nil 变成 1"和"从 1 变成 2"都是同一种可见变化，而客户端无权解释它）。
        if previous.retryCount != fresh.retryCount { return .progressed }
        return .unchanged
    }
}

// MARK: - 失败分诊

/// `GET /api/studio/agent-runs/{id}` 的失败分档。
///
/// 这一条腿只有两档是**契约**：401 未认证、404 `运行记录不存在`（§4.7）。
/// 其余状态一律落 `.server` 并**透传服务端原文** —— 本层不给一个我没见过的状态码编话术
/// （与 `StudioCreateRejection` / `WorkActionRejection` 同一族判据：屏上无英文码、不编「未知错误」）。
public enum AgentRunRejection: Equatable, Sendable {
    /// 401/403：交给登录态处理。
    case unauthenticated
    /// 404 `运行记录不存在` —— 这一档**不能**读成"运行失败了"：
    /// 记录不存在与那次运行没成功是两件事（前者多半是 id 拿错或跨账号）。
    case runMissing(serverMessage: String?)
    /// 429：限流。
    case rateLimited(serverMessage: String?)
    case server(statusCode: Int, serverMessage: String?)

    public var userMessage: String {
        switch self {
        case .unauthenticated:
            return "登录状态已过期"
        case .runMissing(let message):
            return WorkActionRejection.human(message) ?? "找不到这条运行记录"
        case .rateLimited(let message):
            return WorkActionRejection.human(message) ?? "操作太频繁了，稍后再试"
        case .server(let statusCode, let message):
            return WorkActionRejection.human(message) ?? "服务端错误（\(statusCode)）"
        }
    }

    /// 信封就是 §4.7 记的那个 `{error: String}` —— 复用 `WorkActionErrorDto`，
    /// 不在这里再写一份 `{error}` 的解码（同一个形状两处实现是本仓的复发缺陷族）。
    public static func classify(statusCode: Int, body: Data?) -> AgentRunRejection {
        let message = body.flatMap {
            try? JSONDecoder().decode(WorkActionErrorDto.self, from: $0)
        }?.error
        switch statusCode {
        case 401, 403:
            return .unauthenticated
        case 404:
            return .runMissing(serverMessage: message)
        case 429:
            return .rateLimited(serverMessage: message)
        default:
            return .server(statusCode: statusCode, serverMessage: message)
        }
    }
}
