import CovaCore
import Foundation

// MARK: - 23 制作人入口：取数与两本账（§5 P2-2 / §6 A10）
//
// A10 的字面口径只有两句，但两句合起来把这屏的形状钉死了：
// · **空 = 入口不可见**（不是置灰、不是"暂未开放"、不是骨架）：灰度关闭时服务端回
//   **200 + `{producers:[]}`**，而那**就是今天的生产现状**（`PRODUCER_MODE` 未设 ⇒ 恒关）；
// · **取不到 ≠ 空**：请求失败 / 429 / 离线无缓存 / 根形状解不出 / 整份都是读不出的卡，
//   这几种情形**不许**把"契约漂了"伪装成"这个账号没有制作人"。
//
// 于是屏上那两本账分成两个字段（`AppSession.producerCards` / `producersReadFailed`），
// 而**不能压成一个 optional**：压成一个就没法表达"手里还留着上一次读得懂的那一份"。
// 观感上两者今天确实同一个样子（都不可见，23 §7 六情形收敛），差别全在**账上**：
// 一次失败**不清空**已读到的卡（§4 离线那一格：只读展示不需要网络，缓存非空就照旧显示）。
//
// ⚠️ **非空分支今天没有设备证据**（23 §7 明写"必须说白"）：生产 `GET /api/studio/producers`
// 恒回 `{producers:[]}`，本仓没有已开灰度的账号、也没有可开 flag 的测试环境
// ⇒ A10 前半（"灰度账号 → 面板出现制作人卡"）在设备上**不可执行**。
// 本文件的非空路径由 fixture 单测覆盖（`ProducersEntryLegTests`），
// 它证明的是「解码不崩、字段各归其槽位、未释义字段确实不上屏」，
// **不证明**服务端真会返回那个形状（fixture 是按契约 §4.6 拼的，不是抓来的）。
// 拿到灰度账号之前，不得用 fixture 截图声称 A10 已通过。

/// 一次 producers 读的**两类**结论。
///
/// 为什么不是 `Result<ProducersResponseDto, Error>`：`Error` 不是 `Equatable`/`Sendable`，
/// 而那正是本格的要点 —— 屏上不需要知道"为什么没读到"（23 §4：一律保持不可见、不 Toast、
/// 不横幅、不重试），只需要知道"这一格**不是**'服务端说没有'"。
public enum ProducersRead: Equatable, Sendable {
    case responded(ProducersResponseDto)
    /// 请求失败 / 429 / 超时 / 离线 / 根形状解不出（`CovaAPIError.decoding`）都在这一格。
    case unreadable
}

/// 两本账的一份快照（屏上可见的那两格）。
public struct ProducersAccounts: Equatable, Sendable {
    public var cards: [ProducerCardDto] = []
    public var readFailed = false

    public init(cards: [ProducerCardDto] = [], readFailed: Bool = false) {
        self.cards = cards
        self.readFailed = readFailed
    }
}

/// 「这一份卡属于谁 / 这次启动取过没有 / 在途那一次」。
///
/// 为什么是文件级 `@MainActor` 簿记而不是 `AppSession` 的属性：`AppSession.swift` 由协调者持有、
/// 不属本任务的可改面，而那两本屏上的账已经在那边了。这一本纯粹是**取数簿**（不是内容），
/// 落在自己文件里、`@MainActor` 隔离 ⇒ Swift 6 严格并发下合法，读写点与那两本账完全同一处。
/// 它承担的正是 `meOwner` / `recentHistoryOwner` 在别的屏上承担的同一件事：D9 owner 分桶。
@MainActor private struct ProducersFetchLedger {
    /// 现在手里这批卡属于哪个身份（`nil` = 没有一份可信的卡）。灰度按账号开 ⇒ 换号必重取。
    var owner: String?
    /// 最近一次为该身份发起过取数（23 §7「一次冷启动取一次」）。
    var startedFor: String?
    /// 在途那一次（两处宿主同一帧都要时只发一发，120/时 的限流窗口耗不起）。
    var inFlight: Task<Void, Never>?
    /// 请求代号：迟到的旧一代不落账（与 `meRequestID` 同一条腿）。
    var requestID = 0
}

@MainActor private var producersFetch = ProducersFetchLedger()

extension AppSession {

    /// 入口该不该出现（23 §7 第一条硬规则）。
    ///
    /// 判据是**手里这批属于当前身份卡的数量 > 0**：
    /// · **不是** HTTP 状态（契约未记该端点有 `ok` 位 ⇒ 不发明）；
    /// · **不是** 本地推断"这个账号是否灰度"（客户端拿不到灰度位）；
    /// · 「还没取到」与「取到零张」在这里也**同一个表现**（都不可见）—— 这正是 §4 要的：
    ///   默认态就是不可见，任何骨架或占位都会把一个不存在的能力显成一个入口。
    /// owner 那一格是 D9 的落点：上一个灰度账号的缓存不许污染普通账号的入口。
    public var producersEntranceVisible: Bool {
        guard case .signedIn(let user) = authPhase else { return false }
        return producersFetch.owner == user.id && !producerCards.isEmpty
    }

    /// 取制作人卡。**一次冷启动取一次**，`force` 才重发；在途合流；失败**不重试**。
    ///
    /// 为什么不排队重试、不做"稍后自动再试"的定时器（23 §7 限流面）：看不见的能力不该占后台配额，
    /// 而 120/时 的窗口意味着"取不到就当没有"才是这个功能的正确姿势。
    public func loadProducerCards(force: Bool = false) async {
        guard case .signedIn(let user) = authPhase else {
            // 23 §1：面板在创作输入卡内、游客被 17-S6 拦在门外 ⇒ 今天只在登录态可见。
            // 转游客/登出：两本账立即作废，不留上一账号的卡（D5/D8/D9）。
            clearProducerCards()
            return
        }
        if producersFetch.owner != nil, producersFetch.owner != user.id {
            // "没经登出直接换号"那一支（`signOut` 之外）：上一身份那一份先清再判。
            clearProducerCards()
        }
        if !force, producersFetch.startedFor == user.id {
            if let running = producersFetch.inFlight { await running.value }
            return
        }
        producersFetch.startedFor = user.id
        producersFetch.requestID += 1
        let generation = producersFetch.requestID
        let service = producersService
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let read: ProducersRead
            do {
                read = .responded(try await service.cards())
            } catch {
                // 401/403 也在这一格：会话层统一处理（§4「一律保持不可见，不 Toast、不横幅」），
                // 本屏不各自弹登录框，也不把"没权限"说成"没有制作人"。
                read = .unreadable
            }
            guard producersFetch.requestID == generation else { return }   // 迟到的旧一代：不落账
            let next = Self.producersAccounts(after: read, previous: self.producerCards)
            self.producerCards = next.cards
            self.producersReadFailed = next.readFailed
            // 只有"读得懂"的那一次才把这一份挂到当前身份名下（§4 不可见态不需要归属）。
            if !next.readFailed { producersFetch.owner = user.id }
            if producersFetch.requestID == generation { producersFetch.inFlight = nil }
        }
        producersFetch.inFlight = operation
        await operation.value
    }

    /// 两本账作废（登出 / 转游客 / 换号）。
    public func clearProducerCards() {
        producerCards = []
        producersReadFailed = false
        producersFetch = ProducersFetchLedger()
    }

    /// 一次读落到两本账上的**唯一**写法（纯函数 ⇒ 不碰网络也能把三格判据钉住）。
    ///
    /// 三格的分工：
    /// 1. `.unreadable` ⇒ **不清账**：`cards` 原样留着（上一次读得懂的那一份），`readFailed = true`。
    ///    把失败画成空态，等于替后端说"这个账号没有制作人" —— 而客户端没有这个资格；
    /// 2. `producers` 为空**而** `unreadableItemCount > 0` ⇒ 那是"整份都读不懂"，同样不清账、
    ///    同样不算空（`ProducersResponseDto.isDefinitivelyEmpty` 就是为分这两格而存在的）；
    /// 3. 其余 ⇒ 原样交给服务端事实：零张 ⇒ 入口隐藏（A10 那句"不是置灰"就落在这一格）；
    ///    有卡 ⇒ 画卡，`unreadableItemCount > 0` 时另记一笔"这次有读不懂的东西"。
    public static func producersAccounts(
        after read: ProducersRead, previous: [ProducerCardDto]
    ) -> ProducersAccounts {
        switch read {
        case .unreadable:
            return ProducersAccounts(cards: previous, readFailed: true)
        case .responded(let page):
            let unreadable = page.unreadableItemCount > 0
            if page.producers.isEmpty, unreadable {
                // 第 2 格：一条都没读出来 ≠ 一条都没有。留着上一份，别把入口藏掉。
                return ProducersAccounts(cards: previous, readFailed: true)
            }
            return ProducersAccounts(cards: page.producers, readFailed: unreadable)
        }
    }
}

// MARK: - 卡面的槽位取值（纯函数，可测）

/// 一条步骤的显示事实。
///
/// `number` 由**数组下标 +1** 得出（§3.G：契约无 `order` 字段 ⇒ 序号没有第二个来源）。
/// `id` 是**本地**下标（服务端那个 `stages[].id` 未说明用途 ⇒ 不外露、也不当排序键用）。
public struct ProducerStageRow: Equatable, Sendable, Identifiable {
    public let id: Int
    public let number: Int
    public let label: String?
    public let summary: String?

    public var hasSummary: Bool { summary != nil }

    /// §6 那一停：「第 1 步，需求确认，先聊清楚要什么〔，展开 按钮〕」。
    /// 折叠态的展开语义**跟着标签走**（§6：不得只靠符号颜色表达），所以 `expanded` 是入参。
    public func spokenLabel(expanded: Bool) -> String {
        var parts = ["第 \(number) 步"]
        if let label { parts.append(label) }
        if let summary { parts.append(summary) }
        if hasSummary { parts.append(expanded ? ProducersCopy.collapse : ProducersCopy.expand) }
        return parts.joined(separator: "，")
    }
}

/// 卡上每个槽位"取什么、取不到怎么办"的裁决面。
///
/// 为什么单独一层（同 `MineCopy` / `CreditsLedgerCopy`）：§3 的每一项都带一句
/// "取不到 ⇒ 那一格不渲染"，而 §7 的表又钉了"哪些字段今天**不许**外露"。
/// 这类判据埋在 `body` 里就没法被用例钉住，视图因此只负责摆。
enum ProducersPanelFacts {

    /// 空白与纯空白都当"服务端没给"（同 `WorksListQuery.textIfPresent`，不另写一份）。
    static func text(_ raw: String?) -> String? { WorksListQuery.textIfPresent(raw) }

    /// §6 卡头那一停：「<displayName>，制作人，<tagline>，非交互内容」。
    ///
    /// · 「制作人」是**类别词**（朗读用），不是屏上文字 —— 屏上 §3.E 明令不加这个前缀；
    /// · 「非交互内容」必须念出来（§6：卡不可点的必然代价写在标签里，而不是写在屏幕上）；
    /// · 缺位的段不进标签、也不留空逗号（与 `CreditsLedgerRow.spokenLabel` 同一口径）。
    static func headerSpokenLabel(_ card: ProducerCardDto) -> String {
        var parts: [String] = []
        if let title = card.displayTitle { parts.append(title) }
        parts.append(ProducersCopy.sectionTitle)
        if let tagline = text(card.tagline) { parts.append(tagline) }
        parts.append(ProducersCopy.nonInteractiveSpoken)
        return parts.joined(separator: "，")
    }

    /// `stages[]` → 行。**顺序 = 响应顺序，不重排**（§3.G：`stages[].id` 未说明用途）。
    /// `label` 与 `summary` 都取不到 ⇒ 那一行不渲染，但**序号仍按下标**：
    /// 把"这一条没内容"抹平成"这一条不存在"会让后面的序号自己往前挪，
    /// 而用户对照的是服务端那份步骤表，不是本屏的重编号。
    static func stageRows(_ stages: [ProducerStageDto]) -> [ProducerStageRow] {
        stages.enumerated().compactMap { index, stage in
            let label = text(stage.label)
            let summary = text(stage.summary)
            guard label != nil || summary != nil else { return nil }
            return ProducerStageRow(id: index, number: index + 1, label: label, summary: summary)
        }
    }

    /// `deliverables[]` → chip 文本：**只认服务端 `label`**（§3.H：条目类型未文档化 ⇒
    /// 取不到展示字段就**该条不渲染**）。刻意**不**拿 `kind` 编一个中文名：那是本仓反复
    /// 纠正的"从字段名想象功能"，而 `ProducerDeliverableKind` 的 8 个值没有一个有过中文口径。
    static func deliverableLabels(_ items: [ProducerDeliverableDto]) -> [String] {
        items.compactMap(\.displayLabel)
    }

    /// `extensions[]` → chip 文本。同上：只认 `label`。
    /// `enabled` 不参与渲染 —— 它是 P3 的开关位（`nil` 与 `false` 在屏上必须不同，
    /// 而本屏没有任何一格能表达那个区别 ⇒ 与其压成一个，不如两段都不显）。
    static func extensionLabels(_ items: [ProducerExtensionDto]) -> [String] {
        items.compactMap { text($0.label) }
    }

    // MARK: chips 截断（§8 极值那一档：计数档）

    /// §8「chips >30 个 ⇒ 前 20 + 「+N」」。
    static let chipCountThreshold = 30
    static let chipCountShown = 20

    /// chips 的一段窗口。
    struct ChipWindow: Equatable, Sendable {
        var shown: [String]
        var droppedCount: Int?
    }

    /// 未点开时按计数档切；点开后全量（§3.H「点开 = 展开全部」）。
    ///
    /// ⚠️ §3.H 还要「最多 3 行」那一条**行**档，今天**未施工**（SwiftUI 的 `Layout`
    /// 不把"摆下了几枚"回写成视图状态）。理由与后果写在 `ChipFlowContainer` 的注释里。
    static func chipWindow(_ labels: [String], showsAll: Bool) -> ChipWindow {
        guard showsAll == false, labels.count > chipCountThreshold else {
            return ChipWindow(shown: labels, droppedCount: nil)
        }
        return ChipWindow(
            shown: Array(labels.prefix(chipCountShown)),
            droppedCount: labels.count - chipCountShown
        )
    }
}
