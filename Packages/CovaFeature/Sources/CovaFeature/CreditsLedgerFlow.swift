import CovaCore
import Foundation

// MARK: - 22 co 币明细：屏状态 + 上屏串与读法（§5 P2-3 / §6 A9）
//
// 为什么文案与判据单独一层（同 `MineCopy` 的口径）：22 §6 把 VoiceOver 串逐字钉死
// （「AI 音乐生成，扣 20 co，余额 108，2 小时前，任务」），§7 又把「什么时候整段不渲染」
// 钉成机械判据（`jobId` 为 null ⇒ 不留空位、不留「—」、不留「不可用」说明）。
// 这两类都是"错了会骗人"的口径，埋在 `body` 里就没有任何用例能钉住 —— 视图只负责摆。
//
// 三条今天就把整屏钉死的事实（`LedgerDTOs.swift` 文件头是它们在本仓的唯一登记处）：
// · 请求侧**只有 `limit`**（夹在 1..100）：没有 `offset`/`cursor`/`page`，响应也**没有** `total`
//   ⇒ 「只能看最近 100 条」是**服务端边界**，本屏如实说它，不做一个点了没用的「加载更多」；
// · `reasonLabel` 是服务端字符串，而服务端的映射表与真实 reason **不同步**（24 个在写的 reason
//   里 13 个落到「其他变动」）⇒ 服务端给了标签就**逐字上屏**，客户端一律不再映射第二遍；
// · `jobId` 生产实测在 `studio_create_generation` 这一支恒为 null（§7 #38）⇒ 「任务」链接
//   的**缺位是今天的常态**，不是遗漏，也不许用 `id`/`reason` 拼一个假关联补上。

// MARK: - 一行的金额位

/// 金额方向。
///
/// 判据只有一条：**看 `amount` 的正负**（22 §7「±」那条的第 ① 档）。
/// 第 ② 档（`amount` 恒正时按 `type` 判方向）**今天不施工**：§4.7 明写 `type` 的取值集合
/// 没有在生产实测里钉死，而 `CreditLedgerEntryDto` 也刻意把它留成松散 `String?` 并写明
/// 「本层不据它判方向」—— 拿一个未闭合的枚举去推断方向，等于把服务端账目交给客户端重算。
/// 第 ③ 档（两档都判不出 ⇒ 符号位不渲染）落在这里就是 `.undirected`：
/// **不渲染符号位，只显示数字与「co」**，宁缺不猜。
public enum CreditsLedgerAmountDirection: Equatable, Sendable {
    case credit
    case debit
    case undirected
}

/// 一行右端的金额位（`±amount` + 单位「co」）。
public struct CreditsLedgerAmount: Equatable, Sendable {
    /// 绝对值：符号由 `direction` 表达，屏上那枚前缀由 `symbolPrefix` 给。
    public let magnitude: Int
    public let direction: CreditsLedgerAmountDirection

    /// 屏上前缀。**减号是 `−`（U+2212 MINUS SIGN）而不是半角连字符 `-`（U+002D）**：
    /// 这一位配 `type.mono` 做位对齐，半角 `-` 在等宽字体里会被读成破折号（22 §3.C 的原文理由）。
    /// 这里刻意写成**字面字符**而不是 `"\u{2212}"` 码点转义：`Scripts/d12-copy-check.sh`
    /// 见到 `\u{` 一律判红（禁词可以按码点写进来而脚本不解码），本仓不为一个减号去放宽那条判据。
    public var symbolPrefix: String {
        switch direction {
        case .credit: return "+"
        case .debit: return "−"
        case .undirected: return ""
        }
    }

    /// 屏上那一串（不含单位「co」，单位由视图按 `type.caption` 另摆一枚）。
    public var displayText: String { "\(symbolPrefix)\(magnitude)" }

    /// §6：朗读**必须带方向词**（「扣」「加」），且**不**念符号名（不念「减号」）。
    /// 判不出方向时只念数字与单位 —— 不补一句「变动」之类的猜测词。
    public var spokenText: String {
        switch direction {
        case .credit: return "加 \(magnitude) co"
        case .debit: return "扣 \(magnitude) co"
        case .undirected: return "\(magnitude) co"
        }
    }
}

// MARK: - 一行

/// 一条流水 → 屏上一行该出现的四要素 + 那枚可选的「任务」链接。
///
/// `nil`（这一行**不渲染**）只有一种成因：**读不出稳定 `id`**（22 §7 异常值条：
/// 无稳定标识会造成重复行与误删风险）。其余任何字段缺失都只让**那一格**不渲染，
/// 行本身留着 —— 明细行不能因为后端少给一个字段就消失。
public struct CreditsLedgerRow: Equatable, Sendable, Identifiable {
    public let id: String
    /// 第一行左侧：原因标签（服务端 `reasonLabel` 逐字，缺失才走本地回落表）。
    public let reasonText: String
    /// `nil` ⇒ 金额位**整段不渲染**（`amount` 缺失；行仍保留）。
    public let amount: CreditsLedgerAmount?
    /// `balanceAfter`：可信值。`nil` ⇒ 那位显 `--`（TG-29）。
    public let balanceValue: Int?
    /// 相对时间（08 §8 唯一源 `StudioRelativeTime`）。`nil` ⇒ 时间位不渲染（不显「—」噪声）。
    public let timeText: String?
    /// 「任务」链接的**唯一**来源：非 `nil` 才渲染那一枚。
    ///
    /// 这条判据就是 §7 #38 的现场：今天整屏这里都是 `nil`，所以屏上**没有任何**「任务」钮。
    /// 实现不得为让判据好看而用别的字段填一个号。
    public let linkedJobID: String?

    public var showsJobLink: Bool { linkedJobID != nil }

    /// 行 → 显示事实。`now` / `calendar` 由调用方给（本函数无时钟 ⇒ 可断言，
    /// 与 `StudioRelativeTime.text(_:now:calendar:)` 同一个理由）。
    public init?(entry: CreditLedgerEntryDto, now: Date, calendar: Calendar) {
        guard let rowID = entry.resolvedId else { return nil }
        self.id = rowID
        self.reasonText = CreditsLedgerCopy.reason(for: entry)
        self.amount = CreditsLedgerAmount(entry: entry)
        self.balanceValue = CreditsLedgerCopy.believableBalance(entry.balanceAfter)
        self.timeText = StudioRelativeTime.text(entry.createdAt, now: now, calendar: calendar)
        self.linkedJobID = entry.linkedJobId
    }

    /// §6 的复合标签，顺序即心智：原因 → 金额（带方向词）→ **余额紧跟金额** → 时间 →
    /// 「任务」（仅当那一枚真的存在；不存在时序列里也不许有占位元素）。
    ///
    /// 末尾那句「任务」由视图另加 `.isButton` 特征 ⇒ VoiceOver 念成「…，任务，按钮」，
    /// 与 §6 的「〔，任务 按钮〕」同形。
    public var spokenLabel: String {
        var parts: [String] = [reasonText]
        if let amount { parts.append(amount.spokenText) }
        parts.append(CreditsLedgerCopy.spokenBalance(balanceValue))
        if let timeText { parts.append(timeText) }
        if showsJobLink { parts.append(CreditsLedgerCopy.jobLink) }
        return parts.joined(separator: "，")
    }
}

extension CreditsLedgerAmount {
    /// `amount` 的正负 → 方向与绝对值。缺失 ⇒ `nil`（那一整段不渲染，**不按 0 顶**：
    /// 把一次读不出来说成一笔零元账，是 11 §7 明令禁止的那类"用 0 冒充没有"）。
    init?(entry: CreditLedgerEntryDto) {
        guard let amount = entry.amount else { return nil }
        // 0 既不是入账也不是扣费：方向判不出 ⇒ `.undirected`（第 ③ 档，符号位不渲染）。
        if amount > 0 { self.init(magnitude: amount, direction: .credit) }
        else if amount < 0 { self.init(magnitude: -amount, direction: .debit) }
        else { self.init(magnitude: 0, direction: .undirected) }
    }
}

// MARK: - 上屏串（22 §8 文案清单逐条）

/// 本屏全部**由响应派生**的文案与判据。
///
/// D12（硬边界 9）：与 11 同为站内仅有两个允许出现「余额」话题的屏，且**只作展示** ——
/// 这里没有购买/充值/价格类字样，也没有「余额不足」（那是提交类屏的话术，本屏全是读）。
/// A15：只用 `co / 作品 / 任务` 词表；「变动」是本屏新增的中性域词（描述 ledger 每一行）。
public enum CreditsLedgerCopy {
    /// A 导航条标题（§3.A：push 屏用 `type.headline`）。
    public static let title = "co 币明细"
    /// B 摘要行的量词（值 = **本地已渲染条目数**；响应没有 `total`，见文件头）。
    public static let changesUnit = "条变动"
    /// §7 ③④ 的回落词：未识别 `reason`、以及 `reasonLabel` 与 `reason` 同时缺失。
    /// 它同时也是服务端映射表对 13 个 reason 给出的那一句 ⇒ 客户端兜这一句
    /// 与**服务端自己的降级口径一致**，不是第二套术语。
    public static let otherChange = "其他变动"
    /// 「余额 %d」的标签位（数字另用 `type.mono` 摆，见 `CreditsLedgerRow` 的调用点）。
    public static let balanceLabel = "余额"
    /// D 区那枚文字钮。**出现条件只有一个**：`CreditsLedgerRow.linkedJobID != nil`。
    public static let jobLink = "任务"
    /// E 尾部行的第 1 语义（17 §10 的统一措辞）。
    public static let tailExhausted = "已显示全部"
    /// 空态三段 + 主 CTA 落点（§4：CTA 是**本屏唯一**允许 `gradient.brandButton` 的地方）。
    public static let emptyTitle = "还没有变动记录"
    public static let emptyHint = "你的 co 变动会记在这里"
    public static let emptyAction = "做一首歌"
    /// 整屏错误与刷新 Toast 共用同一句（§4：① Toast「明细没取到」/ ④ 整屏「明细没取到」+「重试」）。
    public static let readFailed = "明细没取到"
    public static let retry = "重试"
    /// 缓存时限表达，不是错误色（§5）。
    public static let unsynced = "未同步"
    public static let offlineBanner = "离线，展示上次内容"
    /// §4 离线那一格的**无缓存**分支（整屏那一句，与上面那条互斥）。
    public static let offlineNoCache = "离线：明细需要联网"
    /// TG-29「数值占位符」档未入库 ⇒ 与 11 屏 `MineCopy.unknownValue` **同一串**（在这里
    /// 重述一次而不是引用它：`MineCopy` 是 11 的私有词表，跨屏引用会把两屏的文案账并成一账）。
    public static let unknownValue = "--"
    /// 单位（A15 的 `co`，与 11/19 同词）。
    public static let creditUnit = "co"

    /// E 尾部行的第 2 语义（TG-50 那一档）：**服务端边界**的陈述，不是"加载失败"的道歉
    /// ⇒ 视图按 `color.muted` 中性色摆、不配告警符号。
    ///
    /// 数字不写死在字面量里，而是引用 `CreditLedgerQuery.maximumVisibleEntries`：
    /// 那句话说的就是服务端窗口，窗口一变这句话必须跟着变 —— 写死就是第二套口径。
    public static let tailBoundary = "这里只有最近 \(CreditLedgerQuery.maximumVisibleEntries) \(changesUnit)"

    /// 「取满了」与「取到底了」的裁决（§7 硬规则 ②④：两句互斥、必居其一；空列表整行不渲染）。
    ///
    /// `visibleEntries == maximumVisibleEntries` ⇒ 只能断言"这一窗读满了"，
    /// **不能**断言"这就是全部" —— 响应没有 `total`，说「已显示全部」就是替服务端撒谎。
    public static func tailText(visibleEntries: Int) -> String? {
        if visibleEntries == 0 { return nil }
        return visibleEntries >= CreditLedgerQuery.maximumVisibleEntries ? tailBoundary : tailExhausted
    }

    /// 尾部行在说的是**边界**而不是穷尽（视图据此挑措辞档；取证判据第 1 条）。
    public static func tailIsBoundary(visibleEntries: Int) -> Bool {
        visibleEntries >= CreditLedgerQuery.maximumVisibleEntries
    }

    /// B 摘要行：`entries` 为空 ⇒ `nil`（§3.B「空态自己说话」，不出现「0 条变动」）。
    public static func summaryText(visibleEntries: Int) -> String? {
        guard visibleEntries > 0 else { return nil }
        return "\(visibleEntries) \(changesUnit)"
    }

    /// 「有 N 行我没读出来」。**这一句不在 22 §8 的文案清单里**，为什么仍然要说：
    /// `CreditLedgerPageDto` 的口径是"读不出 `id` 的行计入 `unreadableItemCount` 而不是丢成
    /// 看不见的差值"，而响应没有 `total` 可对照 ⇒ 这一句是"屏上少了几行"唯一的可见面。
    /// 让它静默消失，就是本仓反复登记的"静默丢行"缺陷族。已作为**文案清单的增补**登记在交付说明里。
    public static func unreadableText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(changesUnit)没读出来"
    }

    /// 「余额 %d」的屏上值位（§7 异常值条）。
    ///
    /// · `nil`（服务端没给 / 读不出）与**负数** ⇒ `--`：可疑数字不上屏（11 §7 同规则）。
    /// · 真正的 0 ⇒ 「0」：零余额不是错误态，**不**用告警色、**不**加催促文案（§8）。
    /// · 「异常大」那一档**没有阈值可依据**（§7 未给数、TG 未入库）⇒ 与 `MineCopy.balance`
    ///   同一口径：**不自造阈值，原样显**。自造一个"超过 N 就算异常"的数，
    ///   等于把一次业务判断写成客户端常量，而这一屏没有那个判断的授权。
    public static func believableBalance(_ raw: Int?) -> Int? {
        guard let raw, raw >= 0 else { return nil }
        return raw
    }

    /// 「余额 %d」/ 缺位时 `--`（`type.mono` 那一格）。
    public static func balanceValueText(_ raw: Int?) -> String {
        guard let value = believableBalance(raw) else { return unknownValue }
        return "\(value)"
    }

    /// §6：`--` 那一格念「余额未同步」而不是「余额 减减」—— 与抽屉余额胶囊（04 §3.G）
    /// 已有的读法同一串，不另造一句。
    public static func spokenBalance(_ raw: Int?) -> String {
        guard let value = believableBalance(raw) else { return "\(balanceLabel)未同步" }
        return "\(balanceLabel) \(value)"
    }

    /// 第一行左侧的原因标签。优先级 = §7 的四条：
    /// ① `reasonLabel` 非空 ⇒ **照原值上屏**（iOS 不翻译、不改写、不"统一术语"）；
    /// ② 缺失 ⇒ 按 `reason` 查**契约已给**的本地表（`fallbackReasonText(for:)`，四条以内）；
    /// ③ 未识别 `reason`（含后端新增值）⇒ 「其他变动」，**绝不**把 `studio_create_generation`
    ///    这类英文码原样印上屏（17 §10 禁技术词 + A15）；
    /// ④ 两者同时缺失 ⇒ 回落「其他变动」（不留空行）。
    ///
    /// ⚠️ 这张表**不是**服务端映射表的副本 —— 它只在服务端一个字都没给时才有机会说话。
    /// 服务端给了标签（含把它降级成「其他变动」那 13 个 reason）一律逐字照上，
    /// 客户端再映射一遍就是第二套口径，而两套口径迟早对不上（`LedgerDTOs.swift` 文件头那条）。
    public static func reason(for entry: CreditLedgerEntryDto) -> String {
        if let serverLabel = entry.displayReason { return serverLabel }
        guard let kind = entry.reasonKind else { return otherChange }
        return fallbackReasonText(for: kind)
    }

    /// §7 ② 的那张表：**契约给过中文的四条以内**，其余一律 ③ 落「其他变动」。
    /// 写成 switch 而不是字典，是为了让"后端新增一个 reason ⇒ CovaCore 的枚举多一个 case"
    /// 在**编译期**就把这里问一遍（字典会静默把它归进兜底那一格）。
    ///
    /// 刻意**不**收录的：
    /// · `generation_refund` —— §4.7 就地推翻：它不是真实 reason，退款标签挂在
    ///   `cova_one_step_generation_refund` / `cova_ai_agent_generation_refund` 身上；
    /// · `cova_one_step_generation` / `cova_ai_agent_generation` / `media_extra` /
    ///   `library_download_checkout` / `iap_credits_purchase` 与灵感商店一族
    ///   —— 契约从没给过中文，而 §4.7 实测服务端自己也把它们映射成「其他变动」。
    ///   这就是 §7 待答（3）（extras 一族到底叫什么）今天的降级面。
    static func fallbackReasonText(for kind: CreditLedgerReason) -> String {
        switch kind {
        case .studioCreateGeneration: return "AI 音乐生成"
        case .covaOneStepGenerationRefund, .covaAiAgentGenerationRefund: return "生成失败退款"
        case .dailyCheckin: return "每日签到"
        case .covaOneStepGeneration, .covaAiAgentGeneration, .mediaExtra,
             .libraryDownloadCheckout, .iapCreditsPurchase, .unknown:
            return otherChange
        }
    }
}

// MARK: - 失败的分类

/// 本屏读失败的那一件事。
///
/// 为什么不直接存 `CatalogFailure`：它是**另一个模块文件里 public 的枚举**，
/// 带关联值 ⇒ 在 resilient 模块里不是隐式 `Sendable`，塞进 `CreditsLedgerState: Sendable`
/// 编译期就红；而给别人的类型补一条 `Sendable` 扩展会把两屏的账并成一账
/// （别人也在改那个类型）。所以这里只做一次同形映射，`userText` 仍引用已有的那一条腿。
public enum CreditsLedgerFailure: Equatable, Sendable {
    case network
    case server(String)
    case unauthenticated
    case backendGap(String)

    init(_ failure: CatalogFailure) {
        switch failure {
        case .network: self = .network
        case .server(let message): self = .server(message)
        case .unauthenticated: self = .unauthenticated
        case .backendGap(let id): self = .backendGap(id)
        }
    }

    init(_ error: Error) {
        self.init(CatalogService.classify(error))
    }

    /// 整屏错误那一格的副行（标题恒为「明细没取到」）。四类各有各的说法，不并成"未知错误"：
    /// · `.network` → 「离线：明细需要联网」（22 §8 为"整屏无缓存可读"开的那一句；
    ///   有旧行时说的是横幅「离线，展示上次内容」，两句话不能混）；
    /// · `.server` / `.backendGap` → 服务端给回的那句 / 「后端契约缺口（NEEDS-…）」
    ///   （`CatalogFailure.userText` 已有的那一条腿，这里不重述）；
    /// · `.unauthenticated` → 「登录状态已过期」（17-S3/04 同串；401 由会话层统一处理，
    ///   本屏不自己弹登录框 —— §4 明文）。
    var userText: String {
        switch self {
        // 「离线：明细需要联网」是 22 §8 清单里为**整屏无缓存可读**开的那一句；
        // 有旧行时说的是横幅「离线，展示上次内容」，两句话不能混。
        case .network: return CreditsLedgerCopy.offlineNoCache
        case .server(let message), .backendGap(let message): return message
        case .unauthenticated: return CatalogFailure.unauthenticated.userText
        }
    }

    /// 「手里有旧行 + 这一次是网络类失败」⇒ 17-S4 的离线条（§4 离线那一格）。
    var isNetworkLike: Bool {
        if case .network = self { return true }
        return false
    }
}

// MARK: - 屏状态

/// 22 屏的全部状态（一个值类型 ⇒ 视图只读它）。`AppSession.creditsLedger` 持有唯一一份。
///
/// 为什么账本在会话层而不是视图的 `@State`：`FavoritesView` 那一族把账记在视图里，
/// 于是退屏即丢；本屏的旧行在刷新失败时**必须留着**（22 §4 的①形态 + 离线条），
/// 而"留着的那一份属于谁"还要能按身份作废（D5/D8/D9）—— 三件事都需要一个跨视图存活的宿主。
public struct CreditsLedgerState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// 还没发过（游客、或深链直入的第一帧）。画法与 `.loading` 同一档：都还没有行可显。
        case idle
        /// 读在途。
        case loading
        /// 手里有内容可摆：新鲜的成功结果，**或**上一次成功留下的旧行（`outOfSync` 说后者）。
        case ready
        /// 一次读失败**且手里没有行**⇒ 整屏「明细没取到」+「重试」。
        case failed
    }

    public var phase: Phase = .idle
    /// 上一次**读得懂**的流水（原样保留服务端顺序，客户端不重排 —— §7 排序条）。
    public var entries: [CreditLedgerEntryDto] = []
    /// 服务端给了、但本层读不出稳定 `id` 的行数（§7 异常值条 ⇒ 屏上要说的一句，见
    /// `CreditsLedgerCopy.unreadableText`）。
    public var unreadableItemCount = 0
    /// 最近一次失败（成功即清）。有旧行时它只决定横幅说哪一句，不改变 `phase`。
    public var failure: CreditsLedgerFailure?
    /// 屏上那一份是旧的：有旧行 + 最近一次读失败（§4 的「未同步」= 缓存时限表达，不是错误色）。
    public var outOfSync = false
    /// 这一本账属于谁（§7 隐私条：账目是私有数据 ⇒ 按 principalId 分桶）。
    /// `nil` = 无主（游客/已作废），此时**没有任何行可摆**。
    public var ownerID: String?
    /// 请求代号：每发起一次 +1。**迟到的旧一代只认自己那一代的账** ——
    /// 否则换号后旧请求返回，会把上一个人的流水落进这个人的屏（D8 串号，本仓已吃过一次）。
    public var requestID = 0

    public init(ownerID: String? = nil) {
        self.ownerID = ownerID
    }

    // MARK: 落到状态上的两条纯腿（视图/网络层只调它们 ⇒ 判据可被用例钉住）

    /// 一次成功读：**整表替换**（§4 下拉刷新条：不是追加，本屏没有追加语义）。
    mutating func apply(_ page: CreditLedgerPageDto) {
        entries = page.entries
        unreadableItemCount = page.unreadableItemCount
        failure = nil
        outOfSync = false
        phase = .ready
    }

    /// 一次失败：**不清空旧行**（§4「刷新失败 → 保留旧行」）。
    /// 返回 `true` = 这次要把「明细没取到」以 Toast 形态说一次（有旧行可留的那一档）；
    /// `false` = 由整屏错误块自己说话（首载无缓存那一档）。
    mutating func applyFailure(_ newFailure: CreditsLedgerFailure) -> Bool {
        failure = newFailure
        if entries.isEmpty {
            phase = .failed
            outOfSync = false
            return false
        }
        phase = .ready
        outOfSync = true
        return true
    }

    // MARK: 视图读的派生面

    /// 首载骨架：只有在**没有任何行可摆**时才骨架（刷新在途是保留旧行 + 系统刷新控件）。
    public var showsSkeleton: Bool {
        entries.isEmpty && (phase == .idle || phase == .loading)
    }

    /// 整屏错误：失败**且**没有旧行（§4 首载失败无缓存）。
    public var showsWholeScreenFailure: Bool { phase == .failed }

    /// 空态（登录后 0 条）。只有"`ready` 且一行都没摆出来**而且**没有任何读不懂的行"
    /// 才说"还没有变动记录"；`unreadableItemCount > 0` 时那是"读不懂"，不是"没有"
    /// （那一句由 `unreadableText` 自己说）。
    public var showsEmptyState: Bool {
        phase == .ready && entries.isEmpty && unreadableItemCount == 0
    }

    /// 行（顺序 = 服务端顺序，**不重排**；读不出 `id` 的行在这里会被丢掉，
    /// 但那种行在解码阶段就已计入 `unreadableItemCount`，两处的账是同一本）。
    public func rows(now: Date, calendar: Calendar) -> [CreditsLedgerRow] {
        entries.compactMap { CreditsLedgerRow(entry: $0, now: now, calendar: calendar) }
    }

    public var visibleEntryCount: Int { entries.count }

    public var summaryText: String? { CreditsLedgerCopy.summaryText(visibleEntries: visibleEntryCount) }

    public var tailText: String? { CreditsLedgerCopy.tailText(visibleEntries: visibleEntryCount) }

    /// 尾部行说的是**边界**还是**穷尽**（§7 硬规则 ②④ 的取证判据）。
    public var tailIsBoundary: Bool { CreditsLedgerCopy.tailIsBoundary(visibleEntries: visibleEntryCount) }

    public var unreadableText: String? { CreditsLedgerCopy.unreadableText(unreadableItemCount) }

    /// 「未同步」：有旧行而最近一次读失败（§3.B 右上一次性标记）。
    public var showsUnsyncedMark: Bool { outOfSync && !entries.isEmpty }

    /// 17-S4 离线条：只在"网络类失败 + 手里还有旧行"时出现（§4 离线那一格）。
    public var showsOfflineBanner: Bool {
        showsUnsyncedMark && failure?.isNetworkLike == true
    }

    /// 屏上会出现的「任务」钮数量（A9 判据的前半：今天这一份**恒为空**，
    /// 因为生产实测每条 `jobId` 都是 null —— 见 `CreditLedgerEntryDto.linkedJobId`）。
    public var linkableJobIDs: [String] {
        entries.compactMap(\.linkedJobId)
    }
}

// MARK: - 会话层腿（读 + 「任务」跳转）

extension AppSession {

    /// 本屏恒发的那**一个**请求（22 §7 硬规则 ①）。
    ///
    /// `limit` 取服务端窗口上限 100：这一屏没有翻页能力可依赖，一次读满就是全部可读的东西。
    /// 类型面上**不存在** `offset` / `page` / `cursor` 这三个参数（`CreditLedgerQuery` 没有它们）
    /// ⇒ "不假装分页"这件事在编译期就成立，而不是靠调用方自觉。
    public static func creditsLedgerQuery() -> CreditLedgerQuery {
        CreditLedgerQuery(limit: CreditLedgerQuery.maximumVisibleEntries)
    }

    /// 视图 `.task(id:)` 的键：**当前登录身份**（游客/恢复中 ⇒ 固定串）。
    ///
    /// 为什么要这个键而不是裸 `.task`：深链与走查路由可能落在"会话还在恢复"的那一帧，
    /// 裸 `.task` 只在挂载时跑一次 ⇒ 那一帧被判成游客、之后真的登录上了也不会重取，
    /// 屏会一直停在「登录状态已过期」。身份一变就要重取（同一屏活着的时候换号也走这一格）。
    public var creditsLedgerOwnerKey: String {
        if case .signedIn(let user) = authPhase { return user.id }
        return "unsigned-in"
    }

    /// 读流水。`refresh == true` 是下拉刷新（失败时保留旧行并 Toast 一句）。
    ///
    /// 一次进入取一次、下拉重取；**没有**自动轮询、没有 `>5min` 静默重取（§7 刷新/缓存条：
    /// TG-09 的缓存窗口只用于离线展示，不用来判定"要不要再拉一次"）。
    public func loadCreditsLedger(refresh: Bool = false) async {
        guard case .signedIn(let user) = authPhase else {
            // 22 §1：本屏需登录。游客/恢复中**不发**（发了只是换一次 401），
            // 也不许把上一个身份的账留在屏上（D8 owner 隔离）。
            resetCreditsLedger()
            // 但也不能停在骨架上："永远在加载"是一个比错误更坏的假动作。
            // 深链直入的游客因此落整屏那一格，副行说「登录状态已过期」——
            // 而**不**在此 present 登录框（§4：会话层统一处理，各屏不各自弹）。
            _ = creditsLedger.applyFailure(.unauthenticated)
            return
        }
        if creditsLedger.ownerID != user.id {
            // 换号（含"没经登出直接换号"那一支）：整本作废后重新记一次归属。
            creditsLedger = CreditsLedgerState(ownerID: user.id)
        }
        guard creditsLedger.phase != .loading else { return }   // 在途去重：连点刷新只发一发
        creditsLedger.phase = .loading
        creditsLedger.requestID += 1
        let generation = creditsLedger.requestID
        let service = ledgerService
        let query = Self.creditsLedgerQuery()
        do {
            let page = try await service.entries(query)
            guard creditsLedger.requestID == generation else { return }   // 迟到的旧一代：不落账
            creditsLedger.apply(page)
        } catch {
            guard creditsLedger.requestID == generation else { return }
            let toasts = creditsLedger.applyFailure(CreditsLedgerFailure(error))
            // §4：刷新失败 ⇒ ① Toast「明细没取到」并保留旧行；首载失败无缓存 ⇒ 整屏 ④，不重复弹。
            if toasts, refresh { showToast(CreditsLedgerCopy.readFailed, isError: true) }
        }
    }

    /// 整本作废（登出 / 换号 / 转游客）。账目是私有数据，一份都不留（D5/D8/D9）。
    public func resetCreditsLedger() {
        creditsLedger = CreditsLedgerState()
    }

    /// 「任务」钮的落点。**只在 `linkedJobID != nil` 时被调用**（视图那一侧的
    /// `showsJobLink` 已经把 null 挡在渲染之前，这里再挡一次空串，两层都不猜号）。
    ///
    /// 落点 = 20「我的作品」的**任务定位形态**（22 §1 互链条）：
    /// `Route.worksList(jobID:)` 把锚点作为路由载荷带过去，`WorksListView.task` 调
    /// `loadWorksList(anchoredTo:)` 读它 —— 早前那段"载荷带不过去"的偏差说明已作废。
    /// 跨页签（22 属「我的」栈、20 属「创作」栈，04 §3）⇒ 走 `navigate`：创作栈先回根再推。
    public func openCreditsLedgerJob(_ jobID: String) {
        guard CreditsLedgerRow.jobIDIsUsable(jobID) else { return }
        navigate(to: .worksList(jobID: jobID))
    }
}

extension CreditsLedgerRow {
    /// 链接值能不能用：**非空、非纯空白**才算能用（22 §3.D：`jobId` 为 null / 缺键 / 空串
    /// ⇒ 整枚不渲染）。空串是服务端"解不出 `metadata.jobId`"的另一种写法，与 null 同义。
    static func jobIDIsUsable(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
