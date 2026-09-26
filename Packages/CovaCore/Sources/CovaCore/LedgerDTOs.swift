import Foundation

// MARK: - co 币流水（P2 明细页）
//
// 契约事实源：DEVELOPMENT.md §4.6 + §4.7「ledger」，2026-09-26 生产只读实测。
// 三条把整屏形状钉死的事实：
// · 请求侧**只有 `limit`**（夹在 1..100，默认 50）：**没有** `offset` / `cursor` / `type` 参数，
//   排序固定 `createdAt DESC, id DESC` ⇒ "只能看最近 100 条"要如实呈现，不许假装能翻页；
// · 响应侧**只有 `{entries}`**：**没有** `total` / `nextCursor` / 余额 ⇒ 本文件不建模那三个键，
//   也不在类型上留一个"以后能接"的可选字段（留了就会有人去渲染它）；
//   余额走权威腿 `GET /api/auth/me`（`entitlements`），不在流水里。
// · `reasonLabel` 由服务端映射表生成，而那张表**与真实 reason 不同步**：24 个在写的 reason 里
//   **13 个落到「其他变动」**（含 `media_extra`、`cova_ai_agent_generation`、灵感商店一族、
//   `iap_credits_purchase`、admin 三件）⇒ 客户端**原样显示服务端字符串，绝不自己再映射一遍**
//   （映射第二遍就是第二套口径，而两套口径迟早对不上——本仓的 min-2 缺陷族）。

/// 流水条目里的 `reason`（账目为什么发生）。
///
/// ⚠️ 本枚举**没有任何中文标签**，也不该有：文案的唯一事实源是服务端的 `reasonLabel`
/// （见文件头）。这里的用途只有两件：① 让"这一条是哪一类账"可作为分支判断（例如跳作品），
/// ② 让新上线的 reason **不丢行**（`.unknown(rawValue)` 保住原拼写）。
///
/// 词表只收 §4.7 逐条实测确认过的那些；灵感商店一族与 admin 三件的**真实拼写未实测**，
/// 因此不列 —— 它们今天都落在 `.unknown` 里，而 `.unknown` 的语义正是"服务端写了什么就是什么"。
/// 顺带钉一条更正：`generation_refund` **不是真实 reason**（§4.6 旧措辞已被 §4.7 就地推翻），
/// 真实值是 `cova_one_step_generation_refund` / `cova_ai_agent_generation_refund`。
public enum CreditLedgerReason: Equatable, Sendable {
    case studioCreateGeneration
    case covaOneStepGeneration
    case covaAiAgentGeneration
    case covaOneStepGenerationRefund
    case covaAiAgentGenerationRefund
    case mediaExtra
    case libraryDownloadCheckout
    case dailyCheckin
    case iapCreditsPurchase
    /// 词表外的值：原拼写在括号里，**不丢行、不改写、不折成"其他"**。
    case unknown(String)

    static let knownRawReasons: [String: CreditLedgerReason] = [
        "studio_create_generation": .studioCreateGeneration,
        "cova_one_step_generation": .covaOneStepGeneration,
        "cova_ai_agent_generation": .covaAiAgentGeneration,
        "cova_one_step_generation_refund": .covaOneStepGenerationRefund,
        "cova_ai_agent_generation_refund": .covaAiAgentGenerationRefund,
        "media_extra": .mediaExtra,
        "library_download_checkout": .libraryDownloadCheckout,
        "daily_checkin": .dailyCheckin,
        "iap_credits_purchase": .iapCreditsPurchase,
    ]

    public init(rawReason: String) {
        self = CreditLedgerReason.knownRawReasons[rawReason] ?? .unknown(rawReason)
    }

    /// 线格式原拼写（`.unknown` 回吐服务端那个词，一个字都不改）。
    public var rawReason: String {
        switch self {
        case .studioCreateGeneration: return "studio_create_generation"
        case .covaOneStepGeneration: return "cova_one_step_generation"
        case .covaAiAgentGeneration: return "cova_ai_agent_generation"
        case .covaOneStepGenerationRefund: return "cova_one_step_generation_refund"
        case .covaAiAgentGenerationRefund: return "cova_ai_agent_generation_refund"
        case .mediaExtra: return "media_extra"
        case .libraryDownloadCheckout: return "library_download_checkout"
        case .dailyCheckin: return "daily_checkin"
        case .iapCreditsPurchase: return "iap_credits_purchase"
        case .unknown(let raw): return raw
        }
    }

    /// 生成/补充制作这一族（唯一有"任务"可跳的那些条）。
    ///
    /// 判据故意**不含** `library_download_checkout`：那是库曲订单，不是作品任务。
    public var isGenerationBearing: Bool {
        switch self {
        case .studioCreateGeneration, .covaOneStepGeneration, .covaAiAgentGeneration,
             .covaOneStepGenerationRefund, .covaAiAgentGenerationRefund, .mediaExtra:
            return true
        case .dailyCheckin, .libraryDownloadCheckout, .iapCreditsPurchase, .unknown:
            return false
        }
    }

    /// 退款类（金额为正的入账；但**方向只由 `amount` 的正负决定**，本判据不推断符号）。
    public var isRefund: Bool {
        switch self {
        case .covaOneStepGenerationRefund, .covaAiAgentGenerationRefund: return true
        default: return false
        }
    }
}

/// `{entries}` 里的一条流水。
///
/// 键集实测**逐字**：`id / type / amount / balanceAfter / reason / reasonLabel / jobId /
/// unlinked / createdAt`。
///
/// 三条不能马虎的口径：
/// · `type` 的取值集**没有**在生产实测里钉死 ⇒ 松散 `String?` 原样保留，本层**不据它判方向**
///   （方向只看 `amount` 的正负）；建模一个没实测过的闭集就是把"以为知道"写进类型。
/// · `amount` / `balanceAfter` 建模为 `Int?`（co 币在服务端是整数；同 `StudioCreateErrorDto.balance`）。
///   读不出就是 `nil`，**不填 0**：`0` 会被渲染成「+0 co」，那是把一次漂移说成一笔零元账。
/// · `reasonLabel` 是**服务端字符串**，本层不做第二遍映射（文件头那条）。
public struct CreditLedgerEntryDto: Decodable, Equatable, Sendable {
    public let id: String?
    public let type: String?
    public let amount: Int?
    public let balanceAfter: Int?
    /// 服务端账目原因原拼写（`reasonKind` 是它的分类视图）。
    public let reason: String?
    /// 服务端映射出来的中文标签 —— 上屏只用它，逐字。
    public let reasonLabel: String?
    /// 由服务端从 `metadata.jobId` 解出；**可为 `null`**（见 `isLinkedToJob` 的文档）。
    public let jobId: String?
    /// 服务端的"没挂上任务"标位。
    public let unlinked: Bool?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, amount, balanceAfter, reason, reasonLabel, jobId, unlinked, createdAt
    }

    /// 显式成员初始化（有 `init(from:)` 就没有合成 memberwise；给出来让测试能从模块外造一行）。
    public init(
        id: String?, type: String?, amount: Int?, balanceAfter: Int?, reason: String?,
        reasonLabel: String?, jobId: String?, unlinked: Bool?, createdAt: String?
    ) {
        self.id = id
        self.type = type
        self.amount = amount
        self.balanceAfter = balanceAfter
        self.reason = reason
        self.reasonLabel = reasonLabel
        self.jobId = jobId
        self.unlinked = unlinked
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        type = (try? container?.decodeIfPresent(String.self, forKey: .type)) ?? nil
        amount = (try? container?.decodeIfPresent(Int.self, forKey: .amount)) ?? nil
        balanceAfter = (try? container?.decodeIfPresent(Int.self, forKey: .balanceAfter)) ?? nil
        reason = (try? container?.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        reasonLabel = (try? container?.decodeIfPresent(String.self, forKey: .reasonLabel)) ?? nil
        jobId = (try? container?.decodeIfPresent(String.self, forKey: .jobId)) ?? nil
        unlinked = (try? container?.decodeIfPresent(Bool.self, forKey: .unlinked)) ?? nil
        createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
    }

    /// 流水身份（读不出来 ⇒ `nil`；本层不合成一个"临时 id"，那会让去重/跳转都指向错觉）。
    public var resolvedId: String? { WorksListQuery.textIfPresent(id) }

    /// 原因的分类视图（`reason` 缺席 ⇒ `nil`，**不是** `.unknown("")`：没给就是没给）。
    public var reasonKind: CreditLedgerReason? {
        reason.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : CreditLedgerReason(rawReason: trimmed)
        }
    }

    /// 上屏文案：**服务端给的 `reasonLabel` 原文**。
    ///
    /// 空白按"没给"处理并返回 `nil`，由 UI 决定占位；本层**不许**在这里回落成「其他变动」——
    /// 那一句是服务端的映射结果，不是客户端的兜底词（客户端兜一次，两处口径就分家了）。
    public var displayReason: String? { WorksListQuery.textIfPresent(reasonLabel) }

    /// 挂到了任务：`jobId` 是**非空字符串**（空串是服务端"解不出 metadata.jobId"的一种写法，
    /// 与 null 同义 ⇒ 不许渲染「任务」链接）。
    public var linkedJobId: String? { WorksListQuery.textIfPresent(jobId) }

    /// 这一条能不能跳去任务/作品。`nil` ⇒ **不渲染链接，也不猜一个号**（§4.6 既定口径）。
    public var canLinkToJob: Bool { linkedJobId != nil }

    /// 「没挂上任务」的最终判据：**只看拿不拿得到 `jobId`**。
    ///
    /// 服务端恒给 `unlinked`，而它的定义式就是 `unlinked == (jobId == nil)`（§4.7）——
    /// 于是这个布尔在本层是**冗余**的：判"能不能跳"要看的那个载荷只有 `jobId`。
    /// 留着它只为了一件事：交叉核对（见 `linkageDrift`）。
    public var isUnlinked: Bool { linkedJobId == nil }

    /// 服务端两个字段自相矛盾（`unlinked` 与 `jobId == nil` 对不上）的形状漂移。
    /// 两个方向都算：`unlinked=true` 却带着 jobId（该跳的没给入口），
    /// `unlinked=false` 却没有 jobId（给了入口而无处可跳）。
    /// 本层不判谁对、也不"以哪一个为准地改写另一个"，只把它数出来给取证用
    /// （§4.6 记的生产实测就正落在 `studio_create_generation` 这一支上，见 §7 #38）。
    public var linkageDrift: Bool {
        guard let unlinked else { return false }
        return unlinked != (linkedJobId == nil)
    }

    /// 金额方向：只看 `amount` 的正负；`nil`（读不出）⇒ `nil`，**不**归零。
    public var creditedAmount: Int? {
        guard let amount else { return nil }
        return amount > 0 ? amount : nil
    }

    public var debitedAmount: Int? {
        guard let amount else { return nil }
        return amount < 0 ? amount : nil
    }
}

/// `GET /api/me/credits/ledger` 的响应：**只有 `{entries}`**。
///
/// **没有** `total` / `nextCursor` / `balance`（§4.7 逐条实测）⇒ 本类型没有那三个属性，
/// 于是「共 N 条」「下一页」「当前余额」在这一屏都**无从渲染** —— 这是如实，不是缺功能。
/// 排序固定 `createdAt DESC, id DESC` ⇒ 客户端**不重排**（重排会把服务端的稳定序打乱，
/// 而"同一页两次读出的顺序不同"就是用户会报的那个 bug）。
///
/// 逐行容错：读不出 `id` 的行计入 `unreadableItemCount` 而不是丢成看不见的差值
/// （没有 `total` 可对照 ⇒ 这个计数是"少了几行"唯一的可见面）。
public struct CreditLedgerPageDto: Decodable, Equatable, Sendable {
    /// 端点路径（登录态只读）。
    public static let path = "/api/me/credits/ledger"

    public let entries: [CreditLedgerEntryDto]
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey { case entries }

    public init(entries: [CreditLedgerEntryDto], unreadableItemCount: Int) {
        self.entries = entries
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // `entries` 缺键 / null / 非数组 ⇒ **抛**：空流水（"这个账号还没有账目"）与
        // "读不懂这份响应"必须是两件事（同 `ProducersResponseDto` 那条判据）。
        // `[WireEntry?]`：一个 `null` 元素不许把整页账目判死（见 ProducersDTOs 文件头那条 Swift 数组解码事实）。
        let wire = try root.decode([WireEntry?].self, forKey: .entries)
        var rows: [CreditLedgerEntryDto] = []
        var unreadable = 0
        rows.reserveCapacity(wire.count)
        for element in wire {
            if let element {
                let entry = element.materialize()
                if entry.resolvedId != nil {
                    rows.append(entry)
                } else {
                    unreadable += 1
                }
            } else {
                unreadable += 1
            }
        }
        entries = rows
        unreadableItemCount = unreadable
    }

    /// 可跳去任务的那些行（`jobId` 非空）。A9 的「点击「任务」跳转」只有这一份数据来源。
    public var linkableEntries: [CreditLedgerEntryDto] { entries.filter(\.canLinkToJob) }

    /// 服务端两个字段打架的行（客户端不自己判谁对，只把它数出来给取证用）。
    public var driftingEntries: [CreditLedgerEntryDto] { entries.filter(\.linkageDrift) }

    /// 不可抛的线格式（一行坏形状不许连累同批其它行）。
    struct WireEntry: Decodable {
        let id: String?
        let type: String?
        let amount: Int?
        let balanceAfter: Int?
        let reason: String?
        let reasonLabel: String?
        let jobId: String?
        let unlinked: Bool?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, type, amount, balanceAfter, reason, reasonLabel, jobId, unlinked, createdAt
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
            type = (try? container?.decodeIfPresent(String.self, forKey: .type)) ?? nil
            amount = (try? container?.decodeIfPresent(Int.self, forKey: .amount)) ?? nil
            balanceAfter = (try? container?.decodeIfPresent(Int.self, forKey: .balanceAfter)) ?? nil
            reason = (try? container?.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            reasonLabel = (try? container?.decodeIfPresent(String.self, forKey: .reasonLabel)) ?? nil
            jobId = (try? container?.decodeIfPresent(String.self, forKey: .jobId)) ?? nil
            unlinked = (try? container?.decodeIfPresent(Bool.self, forKey: .unlinked)) ?? nil
            createdAt = (try? container?.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        }

        func materialize() -> CreditLedgerEntryDto {
            CreditLedgerEntryDto(
                id: id, type: type, amount: amount, balanceAfter: balanceAfter, reason: reason,
                reasonLabel: reasonLabel, jobId: jobId, unlinked: unlinked, createdAt: createdAt
            )
        }
    }
}

/// 流水页的请求构造（纯函数：输出的就是发出去的查询串）。
///
/// 类型面上**没有** `offset` / `cursor` / `page` / `type` 这些属性（§4.7：服务端不读它们）。
/// 这个"没有"是有意为之：一旦留了参数，调用方就会以为自己真的在翻页。
public struct CreditLedgerQuery: Equatable, Sendable {
    public static let path = CreditLedgerPageDto.path

    /// 服务端窗口（§4.7：夹在 1..100，默认 50）。
    public static let defaultLimit = 50
    public static let minimumLimit = 1
    public static let maximumLimit = 100

    /// 已经夹好的条数（永远是服务端认识的形状）。
    public var limit: Int

    public init(limit: Int = CreditLedgerQuery.defaultLimit) {
        self.limit = Self.clamped(limit)
    }

    static func clamped(_ value: Int) -> Int {
        min(max(value, minimumLimit), maximumLimit)
    }

    /// 只有 `limit` 这一个键（恒发）。
    ///
    /// 恒发的理由与 `TrackListQuery` 相反方向但同一原则：`limit` 是本页**唯一**的取数参数，
    /// 不写就等于把"默认 50"这个服务端事实偷偷绑死在客户端；写出来，
    /// 「同一个请求 = 同一个地址」才可断言。
    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit))]
    }

    /// 一次请求能取回的最大条数（= 服务端窗口上限）；「只能看最近 100 条」这句话的机械形态。
    public static var maximumVisibleEntries: Int { maximumLimit }
}
