import Foundation

// MARK: - 09 屏「歌词编辑」的纯逻辑（无 UI、无网络、可全量用例覆盖）
//
// 这一层存在的理由和 `OneStepPlanParameterCopy` 一模一样：**判据不能留在视图里**。
// 09 §1 把「标题候选 / 歌词编辑均在本屏内（不跳屏）」写进互链那一行，而本屏此前的歌词区
// 是只读平铺（`AISessionDetailView` 的 `sectionsOf` 只画不写）。要落到屏上的东西里，
// 只有"画"留在 SwiftUI 层，其余全部在这里：段落怎么拆、什么算改过、
// 提交出去的整篇长什么样、哪几种情况下**根本不该给编辑入口**、以及每个上屏状态词的中文。
//
// 三条纪律写死在这层，不靠调用方自觉：
// · **不编造边界**（本仓长期裁决）：后端没给的字段/版本/段名一律不现编，
//   拿不准的形态一律"不给编辑入口 + 说清为什么"，而不是开一个会吞掉用户输入的空白编辑器；
// · **未确认成功前不改本地态**：本层不写任何"乐观显示已保存"的状态，成功只从
//   `OneStepLyricsEditOutcome` 里来（那是 2xx 之后才存在的类型）；
// · **一次逻辑写入 = 一把幂等键**（D8）：见 `OneStepLyricsEditTokenLedger`。

/// 段标的括号形态。后端 `lyricsSections` 只认这两种（`web/src/lib/one-step/contracts.ts:413`）。
public enum OneStepLyricsBracket: String, Equatable, Sendable, CaseIterable {
    case square
    case lenticular

    public var open: String {
        switch self {
        case .square: return "["
        case .lenticular: return "【"
        }
    }

    public var close: String {
        switch self {
        case .square: return "]"
        case .lenticular: return "】"
        }
    }
}

/// 一节歌词在编辑器里的样子：**只有 `body` 可写**，段标是后端给的内容，本屏不就地改。
///
/// 为什么不提供改段名：改名在后端是另一条端点（`…/lyrics/sections` 的 `op:'rename'`，
/// `web/src/app/api/studio/one-step/plans/[planCardId]/lyrics/sections/route.ts:15`），
/// 与 PATCH 的"整篇回带"不是一条路；09 §3-G 要的只是"编辑在本屏内"，
/// 于是这一批只接触最直白的那一件：改正文。
public struct OneStepLyricsSectionDraft: Equatable, Sendable {
    /// 后端给的段标（原值；上屏时走 `OneStepLyricsEditingCopy.sectionTitle`）。
    public let label: String
    /// 原文里**有没有**段标行，以及是哪一种括号。
    public let header: OneStepLyricsBracket?
    /// 进编辑器时的正文（已剥段标行、已收掉尾部空白）。
    public let baseBody: String
    /// 用户此刻看到的正文。
    public var body: String
    /// 后端投影里的那一整条原样留着：补丁要按 `sections[]` 回带（`patch.ts:89-103` 拿它记段落编辑历史）。
    public let source: OneStepLyricsSectionDto

    public var isDirty: Bool { body != baseBody }

    /// 空段判定（保存前的那道自核）：只看有没有非空白字符。
    public var hasContent: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 编辑入口**不该出现**的那几种形态，每一种都带一句能上屏的话。
///
/// 这一族是"不编造边界"的落点：宁可少一个钮，也不给一个会把用户输入静默丢掉的钮。
public enum OneStepLyricsEditingBlock: Equatable, Sendable {
    /// 这张卡没有歌词（纯音乐、或后端没带 `lyrics`）⇒ 09 §8：**整段不渲染**，所以 `userCopy` 是 nil。
    case noLyrics
    /// 有 `lyrics` 但没分段 ⇒ 只能整篇改，而整篇改会把"没分好段"这件事写进下一版；
    /// 本屏不做（不猜分段规则），说清原因。
    case sectionsMissing
    /// 某一段连 `text` 键都没有 ⇒ 拼回去时那一段会**凭空消失**（不是空段，是没有段）。
    case sectionTextMissing
    /// 卡没有 `revision` ⇒ 乐观并发的基线都没有，发出去就是让后端替我猜。
    case cardRevisionUnknown
    /// 卡的 `sessionId` 与当前会话不一致 ⇒ 后端会按"不属于这个会话"处理（`patch.ts:62`），不发。
    case cardSessionMismatch
    /// 标题池不完整（候选取不到、或页码落在后端允许的 0…4 之外）。
    /// 改歌词**必须**连同标题池一起提交（`patch.ts:139` 的 `stale_title_pool`），
    /// 池子不完整就是"必然 400"，所以在这里就停住。
    case titlePoolIncomplete

    /// 上屏那句话。**`noLyrics` 刻意给 nil**：09 §8 明令「`lyrics` 空 → 「歌词」节不渲染
    /// （不显「无歌词」）」，纯音乐的说法由参数行那枚「纯音乐」chip 承担。
    public var userCopy: String? {
        switch self {
        case .noLyrics: return nil
        case .sectionsMissing: return "这份歌词还没分段，这一屏先不就地改。"
        case .sectionTextMissing: return "有一段歌词没取到正文，就地保存会把它丢掉，这次先不保存。"
        case .cardRevisionUnknown: return "没读到这张计划的版本，编辑先不可用。"
        case .cardSessionMismatch: return "这张卡不属于当前会话，编辑已停用。"
        case .titlePoolIncomplete: return "标题候选不完整，歌词编辑先不可用（保存要连同标题池一起提交）。"
        }
    }
}

/// 09 屏歌词区的**唯一裁决面**：能不能编辑、拼出去的是什么、哪些值可以上屏。
public struct OneStepLyricsEditor: Equatable, Sendable {
    public let planCardId: String
    public let sessionID: String
    /// 乐观并发基线（发出去当 `expectedRevision`）。
    public let cardRevision: Int
    /// 歌词字段版本；**读不到就是读不到** ⇒ 不发 `targetVersions`，界面上也不印版本号。
    public let lyricsRevision: Int?
    /// 后端文档级的字段（source / sourceText），保存时原样回带，不现编。
    public let documentSource: String?
    public let documentSourceText: String?
    public let titleCandidates: [String]
    public let titlePage: Int
    public private(set) var drafts: [OneStepLyricsSectionDraft]

    /// 有任何一段被改过。
    public var isDirty: Bool { drafts.contains { $0.isDirty } }

    /// 被改过的段（给"改了几段"这格读数，也给 VoiceOver 说清当前状态）。
    public var dirtyCount: Int { drafts.filter(\.isDirty).count }

    // MARK: 建与判

    /// 这张卡能不能就地编辑。**nil = 可以**。视图层拿它决定"渲染编辑钮还是什么都不渲染"。
    public static func block(
        for plan: OneStepPlanCardDto, sessionID: String
    ) -> OneStepLyricsEditingBlock? {
        guard plan.sessionId == nil || plan.sessionId == sessionID else { return .cardSessionMismatch }
        guard let lyrics = plan.lyrics else { return .noLyrics }
        guard let sections = lyrics.sections else { return .sectionsMissing }
        guard !sections.isEmpty else { return .sectionsMissing }
        guard sections.allSatisfy({ $0.text != nil }) else { return .sectionTextMissing }
        guard plan.revision != nil else { return .cardRevisionUnknown }
        guard let candidates = plan.title?.candidates, !candidates.isEmpty else {
            return .titlePoolIncomplete
        }
        // 0…4 是后端自己的页码区间（`contracts.ts:575`），缺省按 0（同 `input.page || 0`）。
        let page = plan.title?.page ?? 0
        guard (0...4).contains(page) else { return .titlePoolIncomplete }
        return nil
    }

    /// 以卡上当前载荷建编辑器；被 `block` 拦下的形态返回 nil（调用方必须先判 `block`）。
    public init?(plan: OneStepPlanCardDto, sessionID: String) {
        guard Self.block(for: plan, sessionID: sessionID) == nil,
            let lyrics = plan.lyrics,
            let rawSections = lyrics.sections,
            let cardRevision = plan.revision,
            let candidates = plan.title?.candidates
        else { return nil }
        self.planCardId = plan.planCardId
        self.sessionID = sessionID
        self.cardRevision = cardRevision
        self.lyricsRevision = lyrics.revision
        self.documentSource = lyrics.source
        self.documentSourceText = lyrics.sourceText
        self.titleCandidates = candidates
        self.titlePage = plan.title?.page ?? 0
        self.drafts = Self.sortedSections(rawSections).map { item in
            let split = Self.split(header: item.text ?? "")
            let label = item.label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? split.label
                ?? ""
            return OneStepLyricsSectionDraft(
                label: label,
                header: split.bracket,
                baseBody: Self.trimTrailing(split.body),
                body: Self.trimTrailing(split.body),
                source: item
            )
        }
    }

    /// 按 `order` 升序，**缺号/重号时用数组原序兜底**（Swift 的 `sorted` 不保证稳定，
    /// 而"未编辑的段不许被我的排序打乱顺序"是数据完整性问题，不能交给运气）。
    static func sortedSections(_ raw: [OneStepLyricsSectionDto]) -> [OneStepLyricsSectionDto] {
        raw.enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.order ?? lhs.offset
                let r = rhs.element.order ?? rhs.offset
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    /// 剥段标行：行首（允许水平缩进）一个 `[...]` 或 `【...】`，其后只允许行内空白 + 换行。
    /// 与后端 `lyricsSections` 的识别口径同一形状（`contracts.ts:413`）。
    ///
    /// 换行一律用 `Character.isNewline` 判、一次吃掉**一个字符簇**：CRLF 在 Swift 里是
    /// **一个** `Character`（`\r\n` 同属一个扩展字形簇），拿 `== "\r"` / `== "\n"` 逐格比
    /// 会把整行认成"段标后面还跟着正文"⇒ CRLF 歌词本被当成没有段标（用例先红在这一格）。
    static func split(header text: String) -> (label: String?, bracket: OneStepLyricsBracket?, body: String) {
        let chars = Array(text)
        var index = 0
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        let bracket: OneStepLyricsBracket
        let closing: Character
        switch chars.indices.contains(index) ? chars[index] : nil {
        case "[": bracket = .square; closing = "]"
        case "【": bracket = .lenticular; closing = "】"
        default: return (nil, nil, text)
        }
        index += 1
        var label = ""
        while index < chars.count, chars[index] != closing, !chars[index].isNewline {
            label.append(chars[index])
            index += 1
        }
        guard index < chars.count, chars[index] == closing, !label.trimmingCharacters(in: .whitespaces).isEmpty
        else { return (nil, nil, text) }
        index += 1
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        // 段标行必须自己成一行：后面既没换行也不是结尾 ⇒ 是**行内**方括号（正文里的"[男]"式声部标记
        // 或一句普通括号），不是段标 ⇒ 整条都算正文。
        guard index >= chars.count || chars[index].isNewline else { return (nil, nil, text) }
        if index < chars.count { index += 1 }
        return (label.trimmingCharacters(in: .whitespaces), bracket, String(chars[index...]))
    }

    static func trimTrailing(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return String(text[text.startIndex..<end])
    }

    // MARK: 改

    /// 改某一段的正文。返回**没有**生效时不需要任何"部分成功"：越界就是不改。
    public mutating func editBody(_ body: String, at order: Int) {
        guard drafts.indices.contains(order) else { return }
        drafts[order].body = body
    }

    public mutating func reset() {
        for index in drafts.indices { drafts[index].body = drafts[index].baseBody }
    }

    // MARK: 拼回去的整篇

    /// 提交给服务端的整篇歌词。
    ///
    /// 两条口径：
    /// · **没改过的段原样回带**（连尾部换行都不动）—— 我这一屏的排序/剥行只是读法，
    ///   不许变成用户没做过的写。web 的 `joinEditedSections` 会连未编辑段一起重排
    ///   （`web/src/app/studio/lib/oneStepCardEdits.ts:106-117`），这里刻意比它保守。
    /// · **改过的段**按"段标行 + 正文 + 空行分隔"重拼（同一处 web 实现的形态），
    ///   原本没有段标的段**不补一个段标**（那是现编内容）。
    public func joinedLyrics() -> String {
        let last = drafts.count - 1
        var out = ""
        for (index, draft) in drafts.enumerated() {
            if !draft.isDirty {
                out += draft.source.text ?? ""
                continue
            }
            out += Self.sectionText(draft: draft, isLast: index == last)
        }
        return out
    }

    /// 保存前自核（中文，nil = 可以发）。
    ///
    /// 这一道自核只为**不浪费一次写、且不让用户以为已经保存**：服务端另有自己的下限
    /// （`nonEmpty(displayText)`，`contracts.ts:494`），我不拿它当唯一防线。
    /// 长度上限**不在这里判**：后端算的是 UTF-16 单元数，客户端算的是字形簇，
    /// 两套尺子在此刻并不等价 ⇒ 越界由服务端拒，草稿留着，一句"没保存上"接住。
    public func saveBlock() -> String? {
        guard isDirty else { return "没有改动需要保存。" }
        // 「第 N 段」数的是**文档里的第几段**，不是"第几个改过的段" —— 用后者会把用户
        // 指向错的那一段（改过的段可能只有第二段是空的，而提示会说"第 1 段"）。
        if let empty = drafts.firstIndex(where: { $0.isDirty && !$0.hasContent }) {
            return "第 \(empty + 1) 段是空的：要删掉整段请改用「修改要求」，就地保存不接受空段。"
        }
        let whole = Self.trimTrailing(joinedLyrics())
        guard !whole.isEmpty else { return "歌词不能整篇清空。" }
        return nil
    }

    // MARK: 载荷

    /// 载荷指纹 = 「这次要写进去的那一篇」。同一段改动**原样重发** ⇒ 指纹相同 ⇒ 复用同一把幂等键
    /// （后端 `store.ts:373` 对同键同载荷走重放，不会写第二次）；
    /// 用户又改了一个字 ⇒ 指纹变了 ⇒ 那确实是一次新的写，拿新键。
    public var payloadFingerprint: String {
        "\(cardRevision)|\(lyricsRevision.map(String.init) ?? "none")|\(joinedLyrics())"
    }

    /// 构造 `PATCH` 载荷。`saveBlock()` 非 nil 时**必须**不调用它（视图层已按这个顺序走）。
    public func patchRequest(key: IdempotencyKey) -> OneStepLyricsPatchRequestDto {
        let text = joinedLyrics()
        let last = drafts.count - 1
        let sections = drafts.enumerated().map { index, draft -> OneStepLyricsSectionDto in
            guard draft.isDirty else { return draft.source }   // 未改的段：连尾部空白都不动
            return draft.source.replacingText(
                Self.sectionText(draft: draft, isLast: index == last)
            )
        }
        let lyrics = OneStepLyricsPatchDocumentDto(
            source: documentSource,
            sourceText: documentSourceText,
            sections: sections,
            displayText: text,
            generationText: text,
            revision: lyricsRevision
        )
        return OneStepLyricsPatchRequestDto(
            sessionId: sessionID,
            planCardId: planCardId,
            expectedRevision: cardRevision,
            idempotencyKey: key,
            lyrics: lyrics,
            titlePool: OneStepLyricsPatchTitlePoolDto(candidates: titleCandidates, page: titlePage),
            targetVersions: lyricsRevision.map { .init(lyrics: $0) }
        )
    }

    /// 一段的重拼形态（与 web `joinEditedSections:115` 同构：非末段以空行分隔、末段不留尾）。
    static func sectionText(draft: OneStepLyricsSectionDraft, isLast: Bool) -> String {
        var piece = ""
        if let bracket = draft.header, !draft.label.isEmpty {
            piece += "\(bracket.open)\(draft.label)\(bracket.close)\n"
        }
        piece += Self.trimTrailing(draft.body)
        if !isLast { piece += "\n\n" }
        return piece
    }

    /// 当前状态那一句（给读数位与 VoiceOver；**中文**，且没有改动时不吹"已保存"）。
    public var statusCopy: String {
        guard isDirty else { return "未改动" }
        return "已改动 \(dirtyCount) 段"
    }
}

// MARK: - 幂等键（一次逻辑写入 = 一把键；D8 / AGENTS 硬边界 5）

/// 就地编辑这条写路径的幂等凭据。
///
/// 为什么不复用 `IdempotentRequestToken(operation: .planStart)`：那个 operation 的键前缀
/// 写的是 `plan-start`，把一次歌词编辑记成一次启动计划 ⇒ 日志与后端账目上都会指错事。
/// 为什么不在 `IdempotentOperation` 里加一个 case：那是既有文件的改动，
/// 属跨域接线（协调者裁定），本批评不动它 —— 于是这里用同一道字符集闸门
/// （`IdempotencyKey(validating:)`）自成一型，前缀 `cova-card-edit-`。
/// 键的字符集仍是服务端校验正则 `[A-Za-z0-9._:-]{8,128}` 的子集。
public struct OneStepLyricsEditToken: Hashable, Sendable {
    public static let keyPrefix = "cova-card-edit-"
    public let key: IdempotencyKey

    /// 生成一次新写入的键。自造前缀理论上恒合法，但仍走**同一道校验**：
    /// 以后有人改了前缀（加了非法字符）会在这一刻抛错，而不是发出一个未校验的键。
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: IdempotencyKeyGenerator.randomByteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: UInt8.min...UInt8.max) }
        self.key = try IdempotencyKey(validating: Self.keyPrefix + IdempotencyKeyGenerator.hexString(bytes))
    }

    /// 显式给键（测试/恢复）：前缀不对即抛 `operationMismatch`，与 token 类型同一口径。
    public init(key: IdempotencyKey) throws {
        guard key.rawValue.hasPrefix(Self.keyPrefix) else {
            throw IdempotencyKeyError.operationMismatch
        }
        self.key = key
    }
}

/// 歌词编辑的幂等键账本。
///
/// 与 `PlanStartTokenLedger` 的差别是**有意的**：那条按 `(会话,卡,revision)` 记账，
/// 因为"重试启动"的载荷天生不变；这一条的载荷会变（用户会接着改字），
/// 所以记账的键必须带上**载荷指纹**，否则"同键不同载荷"会被后端判成
/// `idempotency_conflict`（`store.ts:375`）。也正因为指纹会随 revision 前进而变，
/// 这里不需要 `invalidate`：成功之后卡面 revision 一定变，下一次写自然拿新键。
public struct OneStepLyricsEditTokenLedger: Sendable {
    private var tokens: [String: OneStepLyricsEditToken] = [:]

    public init() {}

    public mutating func token(
        planCardID: String, fingerprint: String
    ) throws -> OneStepLyricsEditToken {
        let scope = "\(planCardID)|\(fingerprint)"
        if let existing = tokens[scope] { return existing }
        let fresh = try OneStepLyricsEditToken()
        tokens[scope] = fresh
        return fresh
    }

    /// 已记账的键数量（用例钉"同一篇改动重发十次只有一把键"）。
    public var count: Int { tokens.count }
}

// MARK: - 上屏词（09 §7 / §9「不在界面上出现英文态名」）

/// 09 歌词区的**唯一文案映射面**：版本读数、段标题、面板状态、失败话术。
///
/// 形状与 `CovaPlan.userLabel` / `PlayerFailure.Kind.userLabel` / `LoopMode.userLabel`
/// 同族：`rawValue` 是线格式与代码用的名字，上屏一律走中文，且**每个 case 都必须有**
/// （用例 `testEveryPhaseHasChineseLabel` 逐 case 钉，防止以后加一档漏一档）。
public enum OneStepLyricsPanelPhase: String, CaseIterable, Equatable, Sendable {
    /// 只读平铺（还没进编辑）
    case readOnly
    /// 编辑中，没保存
    case editing
    /// 保存请求在途
    case saving
    /// 重做在途（**这条按 token 实扣**，见 `StudioService.regenerateLyrics`）
    case regenerating
    /// 后端已确认写入（回显读到了新卡）
    case saved
    /// 已 2xx 但回显读不出来：写发生了，不谎称"界面已更新"，也不谎称失败
    case savedWithoutEcho
    /// 基线已被别处推进（409 conflict）
    case stale
    /// 这一次写被拒（400/404/402/…，具体哪一档由 `OneStepLyricsEditRejection` 说）
    case failed

    public var userLabel: String {
        switch self {
        case .readOnly: return "可编辑"
        case .editing: return "编辑中，未保存"
        case .saving: return "正在保存"
        case .regenerating: return "正在重做歌词"
        case .saved: return "已保存"
        case .savedWithoutEcho: return "已提交，卡面待刷新"
        case .stale: return "计划已在别处更新"
        case .failed: return "这次没保存上"
        }
    }
}

/// 保存/重做被拒的那一类事实。
///
/// 判定输入的 `code` 是服务端信封里的业务码（`web/src/app/api/studio/one-step/plans/
/// [planCardId]/shared.ts:33-50` 与 `store.ts` 抛的那些 `code`），
/// **上屏一律走 `userCopy`**：业务码是英文，一个都不许出现在屏上。
public enum OneStepLyricsEditRejection: Equatable, Sendable, Error {
    /// 409 `conflict`：卡的 revision 已经不是我这一份了（两设备/另一屏改过）。
    case staleCard
    /// 409 `idempotency_conflict`：这把键被另一份载荷用过了（账本被绕开时的可见面）。
    case idempotencyConflict
    /// 402 `topup_required`（或任何 402）：**重做**在预检处被拦，本轮一次模型调用都没发 ⇒ 没扣费。
    case insufficientBalance
    /// 403/404：这张卡不归我，或不在了。
    case cardGone
    /// 其余非 2xx（400 invalid_patch / 413 llm_input_cap / 5xx …）。
    case rejected(status: Int?)

    /// 从 `CovaAPIError` 归类。**只认这一族**：不是 `CovaAPIError` 的错误返回 nil，
    /// 交给上层按网络/服务端故障说，而不是我在这里替它编一句"保存失败"。
    public static func classify(_ error: Error) -> OneStepLyricsEditRejection? {
        guard let api = error as? CovaAPIError else { return nil }
        switch api {
        case .httpStatus(let code, let apiCode):
            switch (code, apiCode) {
            case (409, "conflict"), (409, "revision_conflict"): return .staleCard
            case (409, "idempotency_conflict"): return .idempotencyConflict
            case (402, _): return .insufficientBalance
            case (403, _), (404, _): return .cardGone
            default: return .rejected(status: code)
            }
        case .unauthorized: return .cardGone
        default: return nil
        }
    }

    public var userCopy: String {
        switch self {
        case .staleCard: return "计划已在别处更新，这句改动没有保存上；重新进来会以最新那份为准。"
        case .idempotencyConflict: return "后端认出这不是一次重发，改动没有保存；再点一次保存即可。"
        case .insufficientBalance: return "这次没有扣费，余额不足以重做歌词。"
        case .cardGone: return "这张计划卡已经不在了。"
        case .rejected: return "这次没保存上，服务端拒绝了这次提交。"
        }
    }
}

/// 一次**已成功**（2xx）的写能给出哪几种事实。
///
/// 没有"失败也算已保存"那一档：失败路径由 `OneStepLyricsEditRejection` 与网络故障分管。
public enum OneStepLyricsEditOutcome: Equatable, Sendable {
    /// 写进去并且读回了新卡面。
    case saved(OneStepPlanCardDto)
    /// 后端把这次当同一次提交**重放**了（同键同载荷，`store.ts:374-381`）：没有第二次写。
    case replayed(OneStepPlanCardDto)
    /// 2xx 但回显解不出来：**写已经发生**，只是卡面要下次读才算数。
    case landedWithoutEcho
}

/// 一次重做的结果（**这一条会扣钱**，扣多少由后端结算给）。
public struct OneStepLyricsRegenerateOutcome: Equatable, Sendable {
    public let card: OneStepPlanCardDto?
    /// 真实扣数；`nil` = 后端没给这一格 ⇒ 界面上什么都不说，不印 0。
    public let charged: Int?
    public let balance: Int?
    /// 后端明说"结算时扣不动"（`llm-metering.ts:152-154`：`charged:0` + `insufficient:true`）。
    public let insufficient: Bool?

    /// 扣费话术：三种事实各说各的，**绝不把"没读到"说成"没扣"**。
    public var chargeCopy: String {
        if insufficient == true { return "这次没能扣费：余额不足，歌词没有重做。" }
        guard let charged else { return "歌词已重做，这次扣了多少没读到，以账单为准。" }
        return "歌词已重做，这次消耗 \(charged) co。"
    }
}

/// 09 歌词区的读数文案（版本号、段标题）。
public enum OneStepLyricsEditingCopy {
    /// 「第 N 版」。**nil → nil**：09 §9 与"不编造边界"都要这一格 —— 后端没给
    /// `lyrics.revision` 时不许印一个现编的"第 1 版"。
    public static func versionLabel(_ revision: Int?) -> String? {
        guard let revision, revision >= 1 else { return nil }
        return "第 \(revision) 版"
    }

    /// 段标题：后端给的 `label` 是内容（模型写的段名），原样上屏；
    /// 没有就回落「段落 N」—— 这一枚不是现编，与 web 同一回落口径
    /// （`web/src/app/studio/components/chat/one-step/plan-card-bits.tsx:135`）。
    public static func sectionTitle(label: String?, order: Int) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "段落 \(order + 1)" : trimmed
    }

    /// 「第 N 版 · 共 M 版」。**只在两个数都对得上的时候才报"共 M 版"**：
    /// · 当前版本 `nil` ⇒ 只回 nil（连"第 N 版"都不印，见上）；
    /// · 版本列表没给 / 空 ⇒ 只回「第 N 版」，不印"共 0 版"糊弄人；
    /// · 列表里没有当前这一版 ⇒ 账对不上（后端承诺升序且补齐缺号，`store.ts:541-560`），
    ///   于是仍只回「第 N 版」—— 不拿一份对不上的清单去数总数。
    /// 重复版本号按去重后的集合数（后端补齐缺号后不该有重号，出现就不吹"共几版"这个数）。
    public static func versionSummary(
        _ versions: [OneStepFieldVersionDto], current: Int?
    ) -> String? {
        guard let base = versionLabel(current) else { return nil }
        let numbered = versions.compactMap(\.version)
        guard numbered.contains(where: { $0 == current }) else { return base }
        let distinct = Set(numbered)
        guard distinct.count > 1 else { return base }
        return "\(base) · 共 \(distinct.count) 版"
    }
}
