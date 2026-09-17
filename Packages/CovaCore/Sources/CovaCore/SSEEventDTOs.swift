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
public struct CovaSSEFrame: Equatable, Sendable {
    public let event: CovaSSEEventType
    public let payload: Data

    public init(event: CovaSSEEventType, payload: Data) {
        self.event = event
        self.payload = payload
    }

    public init(rawEventName: String, payload: Data) {
        self.event = CovaSSEEventType(rawName: rawEventName)
        self.payload = payload
    }

    /// 载荷解码；失败返回 `nil`（上层按坏事件计数处理，见 D6 降级规则）。
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }
}
