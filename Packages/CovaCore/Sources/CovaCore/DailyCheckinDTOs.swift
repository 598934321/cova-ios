import Foundation

// §5 P3「每日签到」的契约面。真实形状取自 `../web`（就是线上那套）：
//   `src/app/api/me/checkin/route.ts`
//     GET  → 200 `{checkedInToday: boolean, dailyAmount: number}` / 未登录 401 `请先登录`
//     POST → 200 `{ok: true, alreadyCheckedIn: boolean, granted: number, balance: number}` / 401
//   服务端注释明写这一支**幂等**（"重复点击/多 tab 不重复入账"），
//   所以它不需要客户端再带一枚幂等键 —— 硬边界 5 管的是**扣费**写操作，
//   签到是发放，且幂等由服务端按天保证。这一格是谁的保证就写谁的，不冒领。

/// `GET /api/me/checkin` 的响应。
///
/// 两个键都是布尔/数字，**没有**"今天能不能签"这种第三种答案 ⇒
/// 读不懂与"没签"必须分开：读不懂时屏上不许出现一枚点下去什么也不会发生的钮。
public struct DailyCheckinStateDto: Decodable, Equatable, Sendable {
    public let checkedInToday: Bool?
    public let dailyAmount: Int?

    enum CodingKeys: String, CodingKey { case checkedInToday, dailyAmount }

    public init(checkedInToday: Bool?, dailyAmount: Int?) {
        self.checkedInToday = checkedInToday
        self.dailyAmount = dailyAmount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 键在但值不是布尔/整数 ⇒ 留 `nil`（"没给可判的值"），不折成 false / 0。
        // 折成 false 的后果很具体：屏上会摆一枚"签到领 0 co"的钮，而它点了也不会给东西。
        let flag = (try? c.decodeIfPresent(Bool.self, forKey: .checkedInToday)) ?? nil
        checkedInToday = (c.contains(.checkedInToday) && flag == nil) ? nil : flag
        let amount = (try? c.decodeIfPresent(Int.self, forKey: .dailyAmount)) ?? nil
        dailyAmount = (c.contains(.dailyAmount) && amount == nil) ? nil : amount
    }

    /// 这一份读数**足以**决定屏上摆哪一格吗（两格都要有值才算）。
    public var isDecidable: Bool { checkedInToday != nil && dailyAmount != nil }

    public static let path = "/api/me/checkin"
}

/// `POST /api/me/checkin` 的响应。
public struct DailyCheckinResultDto: Decodable, Equatable, Sendable {
    public let ok: Bool?
    public let alreadyCheckedIn: Bool?
    public let granted: Int?
    public let balance: Int?

    enum CodingKeys: String, CodingKey { case ok, alreadyCheckedIn, granted, balance }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        alreadyCheckedIn = (try? c.decodeIfPresent(Bool.self, forKey: .alreadyCheckedIn)) ?? nil
        granted = (try? c.decodeIfPresent(Int.self, forKey: .granted)) ?? nil
        balance = (try? c.decodeIfPresent(Int.self, forKey: .balance)) ?? nil
    }

    /// 200 但 `ok` 不是**真**：这一趟没成。
    /// 服务端对失败没有给机器可读的码 ⇒ 客户端只能说"没成"，不能替它编一句原因。
    public var succeeded: Bool { ok == true }
}

/// 屏上那一格的状态。**由两格真值拼出来**，不是一个可以被"默认值"糊过去的枚举。
public enum DailyCheckinBoard: Equatable, Sendable {
    /// 今天还没签，签一下给 `amount` co。
    case available(amount: Int)
    /// 今天已经签过了。
    case done
    /// 服务端没给可判的值（或读失败）⇒ 这一格**不出现**，而不是画成一枚假的钮。
    case unknown
}

public enum DailyCheckinRule {
    /// 读数 → 屏上那一格。`nil` 走 `unknown`（缺读数不是"没签"）。
    public static func board(from state: DailyCheckinStateDto?) -> DailyCheckinBoard {
        guard let state, state.isDecidable else { return .unknown }
        if state.checkedInToday == true { return .done }
        guard let amount = state.dailyAmount, amount > 0 else { return .unknown }
        return .available(amount: amount)
    }

    /// 签完之后按 POST 的回执换格。
    ///
    /// 为什么不能直接沿用"签完了 ⇒ `.done`"：`granted` 可能是 0（今天已签过的那条腿回来），
    /// 也可能是服务端发放额度配成 0 —— 后者画"已签到"是给一个什么都没拿到的人一句假话。
    public static func board(fromResult result: DailyCheckinResultDto) -> DailyCheckinBoard {
        guard result.succeeded else { return .unknown }
        if result.granted != nil { return .done }
        return .unknown
    }

    /// 「签到领 N co」这句文案里的数字只从服务端读数来；读不出就整句不出现。
    public static func actionTitle(_ board: DailyCheckinBoard) -> String? {
        switch board {
        case .available(let amount): return "签到领 \(amount) co"
        case .done: return "今天已签到"
        case .unknown: return nil
        }
    }
}
