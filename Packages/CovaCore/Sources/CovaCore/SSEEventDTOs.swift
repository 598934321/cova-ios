import Foundation

/// SSE 事件类型（api-contracts 4：`thinking / text / plan_card / error / done / run_*`）。
///
/// 契约点名的 5 种是一等分支；`run_*` 生命周期事件保留事件名（语义由上层按需处理）；
/// 其余事件名归入 `unknown` —— **不丢事件名、不臆造语义**，同时保证前向兼容。
public enum CovaSSEEventType: Equatable, Sendable {
    case thinking
    case text
    case planCard
    case error
    case done
    case runLifecycle(String)
    case unknown(String)

    public init(rawName: String) {
        switch rawName {
        case "thinking": self = .thinking
        case "text": self = .text
        case "plan_card": self = .planCard
        case "error": self = .error
        case "done": self = .done
        default: self = rawName.hasPrefix("run_") ? .runLifecycle(rawName) : .unknown(rawName)
        }
    }

    /// 线上事件名（`event:` 行的值）。
    public var rawName: String {
        switch self {
        case .thinking: return "thinking"
        case .text: return "text"
        case .planCard: return "plan_card"
        case .error: return "error"
        case .done: return "done"
        case .runLifecycle(let name), .unknown(let name): return name
        }
    }
}

/// `thinking` / `text` / `error` 事件共用的载荷（`{text}`）。
public struct CovaSSETextEventDto: Codable, Equatable, Sendable {
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case text
    }
}

/// 一条 SSE 帧：事件类型 + 原始 JSON 载荷。
///
/// `plan_card` 事件的载荷即计划卡投影本身，可直接解码为 `OneStepPlanCardDto`。
///
/// `isMalformed` 由增量解析器（`SSEFrameParser`）标注：载荷不是合法 JSON 时为 `true`。
/// 它是 D6「3 个坏事件」降级计数的依据，**不是**事件语义的一部分（`event` 仍如实保留事件名）。
public struct CovaSSEFrame: Equatable, Sendable {
    public let event: CovaSSEEventType
    public let payload: Data
    public let isMalformed: Bool

    public init(event: CovaSSEEventType, payload: Data, isMalformed: Bool = false) {
        self.event = event
        self.payload = payload
        self.isMalformed = isMalformed
    }

    public init(rawEventName: String, payload: Data, isMalformed: Bool = false) {
        self.event = CovaSSEEventType(rawName: rawEventName)
        self.payload = payload
        self.isMalformed = isMalformed
    }

    /// 载荷解码；失败返回 `nil`（上层按坏事件计数处理，见 D6 降级规则）。
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }

    /// 计划卡 → `plan_card` 帧（轮询降级结果统一为事件流时使用）。
    ///
    /// 编码失败返回 `nil`（`OneStepPlanCardDto` 可编码，正常路径不会发生）。
    public static func planCard(_ card: OneStepPlanCardDto) -> CovaSSEFrame? {
        guard let data = try? JSONEncoder().encode(card) else { return nil }
        return CovaSSEFrame(event: .planCard, payload: data)
    }
}
