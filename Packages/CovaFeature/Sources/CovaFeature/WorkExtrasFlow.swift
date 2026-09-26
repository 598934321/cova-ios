import CovaCore
import CovaPlayer
import Foundation

// MARK: - 21 补充制作（extras 快照）：两宿主一容器 + 三条腿（§5 P2-1 / §6 A8）
//
// 规格：`design/screens/21-work-extras.md`。本文件是**裁决面**（哪些行存在、每格取什么、
// 失败怎么说），视图只负责摆；判据全是纯函数 ⇒ `WorkExtrasFlowTests` 不碰网络、不起模拟器
// 就能把它们钉住（也能红）。
//
// 四条"错了会骗人"的口径先写在这里：
//
// 1. **作品路径不渲染任何价格**（§1 表 / §2 差异 / §3.D2 / §3.H）。契约 §4.7 实测
//    「作品级这一支服务端不扣费」，而 `WorkExtrasResponseDto` 连 `deliveryRevision` 都没有 ⇒
//    这一条腿既不计价也不对账。屏上只留一句中性事实「这里不消耗 co」。
//    注意这是**路径属性**（走哪个端点），不是某次响应的数值 ⇒ 与 19 §3.D「`charge == 0`
//    那一行不渲染」方向相反，理由在 §7 末段。
// 2. **0 不是事实，是"还没选"**：勾选数 = 0 ⇒ D2 合计行整行不渲染，绝不写「预计消耗 0 co」；
//    `creditsBalance` 取不到 ⇒ 只显合计、**删掉余额位**，绝不显 0（§3.D2 + 09 §8）。
// 3. **`files[].type` 认不出是哪一个 key**（所以 §3.D 的"在途/已完成的 key 从 D 组消失"
//    只能做一半）。取证面（2026-09-27 只读核对 `../web` 的 `src/lib/studio/extras-service.ts`）：
//      · `fileTypeForKind`（:313-322）：`master_wav`⇒`audio-wav`、`accompaniment`⇒
//        `instrumental-wav`/`instrumental-mp3`、**`stems` 与 `vocals` 同为 `stems`**、
//        `video`⇒`video`、**`timing`/`lyrics`/`metadata` 同为 `doc`**；
//      · 待做行的 `type` 由 key 投影（:377）：`stems` 与 `vocal_stems` 同样都写 `stems`。
//    ⇒ 只有 `audio-wav`（= `wav`）、`instrumental-wav`/`instrumental-mp3`（= `accompaniment`）、
//    `video`（= `lyrics_video`）三格是一对一；`stems` 分不出「分轨 vs 人声分轨」，
//    `doc` 连"是不是本屏的产物"都分不出。不自拼映射（硬边界 7），只按这张表隐藏，
//    认不出的那些 key 继续留在 D 组 —— **重复提交是无害的**：同文件 :465-474 在计费前先查
//    `prior`，已有产物的 key 不进 `chargeable`（服务端幂等复用，契约 §4.4）。
//    把这一格做精确缺的就是 21 的**待答 1**（`files[]` 条目的完整字段清单 / 可渲染的产物身份）。
// 4. **进度字段不存在** ⇒ 屏上没有百分比、没有剩余时间、没有 ETA（§3.F + §7 不得发明）。
//    在途只有一枚菊花（17-S8「不确定指示」专用规则）。
//
// 幂等（§7 幂等条 / 硬边界 5）：extras 两条 POST 的 `idempotencyKey` **字段名与是否必带都没
// 写进契约**（21 待答 8），`IdempotentOperation` 也没有 extras 那一格（CovaCore 既有文件，
// 本任务不可改），而协调者预接好的 `ExtrasService` 那四个方法**没有**幂等参数 ⇒
// 本屏不猜一个字段名发出去（那是替服务端决定它的契约长什么样），落的是客户端这一侧
// 能独自做到的那一半：一次点击 = 一个新的提交代号（`WorkExtrasState.submissionID`）、
// 在途期间第二次点击在两条路上都到不了（`submissionInFlight` + 主钮菊花 + `.disabled`）、
// 任何失败都**不自动重发**写操作（§4 的 502/503 行只把主钮放回可点，等用户再点一次）。
// ⇒ 屏上也就**不**出现「服务端告诉我们这是复用」那一类断言（§8 并发冲突条 / 手册 §7 #40）。

// MARK: - 宿主（§1「同一容器两种宿主」）

/// 面板宿主：**两路径共用一个容器**，差异只在计费面与请求端点（§1 的三处不同形）。
public enum WorkExtrasHost: Equatable, Sendable {
    /// 作品路径：`POST|GET /api/studio/create/works/{id}/extras`。**不计价、不对账**。
    ///
    /// `id` **只许是行自己的伪 id** `{jobId}:{candidateId}`：裸 jobId 服务端回 404（§4.7），
    /// 而那一句与"作品不存在"在屏上根本分不开 ⇒ `WorkExtrasEndpoint.workPath` 在本地就先拦，
    /// 拦下来的那一句话由整块失败态说出来（那是客户端自己的话，不是服务端的）。
    ///
    /// `instrumental`：宿主那一行给的事实（20 的行 / 09 的候选卡）。它只决定
    /// `WorkExtraKey.allowedKeys(instrumental:)` 滤不滤那四项。`nil`（宿主读不出）⇒ **不滤**：
    /// 滤掉是替服务端做一个我们不知道成立与否的决定，不滤最多换一次服务端的权威答复。
    case work(id: String, instrumental: Bool?)
    /// 会话路径：`GET|POST /api/studio/extras`（读用 `?sessionId=`）。这一条腿按 key 扣 co，
    /// 也是唯一回 `deliveryRevision` 的那一条。
    case session(id: String, instrumental: Bool?)

    /// 走的是哪一条腿（计费裁决的唯一依据 —— 它是路径属性，不是某个响应字段）。
    public var chargesCredits: Bool {
        if case .session = self { return true }
        return false
    }

    /// B 区标题（§3.B：两条措辞都**不带**任何计费字样）。
    public var title: String { chargesCredits ? WorkExtrasCopy.sessionTitle : WorkExtrasCopy.title }

    /// 提交成功那一句 Toast（§4 成功行：会话路径「已开始补充制作」/ 作品路径「已开始制作」）。
    public var startedToast: String {
        chargesCredits ? WorkExtrasCopy.startedSession : WorkExtrasCopy.startedWork
    }

    /// 宿主给的"是否纯音乐"（§3.D 滤除的唯一依据）。
    public var instrumental: Bool? {
        switch self {
        case .work(_, let flag), .session(_, let flag): return flag
        }
    }

    /// `.task(id:)` 键用的一段（枚举直接插值会把 `instrumental: nil` 这种工程词带进键里）。
    var cacheKey: String {
        switch self {
        case .work(let id, let flag): return "w:\(id):\(flag.map { $0 ? "1" : "0" } ?? "?")"
        case .session(let id, let flag): return "s:\(id):\(flag.map { $0 ? "1" : "0" } ?? "?")"
        }
    }
}

// MARK: - 上屏串（§8 文案清单，一句不多）

/// 本屏全部字面量。
///
/// 两条纪律：① 只允许 §8 清单里的串，含它点名的**复用串**（`保存到本机` / `已在本机` /
/// `删除本机文件？` / `重试` / `取消` / `预计消耗 %d co` / `本次合计预计消耗 %d co` / `余额 %d`，
/// 出处 09 与 19）；② A15 词表只用 `co / 作品 / 任务` ⇒ 「积分」「歌曲任务」这类漂移词在这里
/// 没有位置；「价目表」三字也不许上屏（§7 末段明令 —— 上屏形态只有那两串 `预计消耗`）。
enum WorkExtrasCopy {
    /// B 标题（作品路径形态）。
    static let title = "补充制作"
    /// B 标题（会话路径形态）。
    static let sessionTitle = "补充制作 · 这次会话"
    /// C 分组标题。
    static let deliveredHeader = "已经做好的"
    /// D 分组标题。
    static let selectableHeader = "可以再做的"
    /// F 分组标题。
    static let queueHeader = "制作队列"
    /// 六枚 key 的标签（§7 表「本屏标签」列，逐字）。
    static let keyWav = "母带 WAV"
    static let keyStems = "分轨"
    static let keyVocalStems = "人声分轨"
    static let keyAccompaniment = "伴奏"
    static let keyLyricsTiming = "歌词时间轴"
    static let keyLyricsVideo = "歌词视频"
    /// 六枚 key 的副标（§7 表「是什么」列，逐字）。
    static let captionWav = "更高规格的成品音频"
    static let captionStems = "分开的轨道包"
    static let captionVocalStems = "单独的人声轨道"
    static let captionAccompaniment = "去掉人声的伴奏轨"
    static let captionLyricsTiming = "对齐过的歌词文件"
    static let captionLyricsVideo = "带词的短视频"
    /// G 主钮。
    static let start = "开始补充制作"
    /// H 事实行（**仅作品路径**；§3.H + 待裁决 1）。
    static let noCostHere = "这里不消耗 co"
    /// F 行状态文字（§3.F，`color.warning`）。
    static let preparing = "制作中"
    /// C 行动作两态 + 二次确认（复用 19 的定稿串）。
    static let save = "保存到本机"
    static let saved = "已在本机"
    static let deleteLocal = "删除本机文件？"
    static let delete = "删除"
    static let cancel = "取消"
    /// 首载失败的整块替换（§4 表第一行 ③ 形态）+ 两个钮。
    static let readFailed = "补充制作没取到"
    static let retry = "重试"
    static let close = "关闭"
    /// 提交成功 Toast（两宿主各一句，**不带数字** —— §4 成功行）。
    static let startedSession = "已开始补充制作"
    static let startedWork = "已开始制作"
    /// 409 那一档的行内话（§4 表；中性事实，**不**进错误色 —— §6 末段）。
    static let alreadyInFlight = "这个已经在做了"
    /// 取件失败 / 写失败（§4 表最后两行，都是**行内**不是 Toast）。
    static let fileNotFetched = "这个文件没取到，重试"
    static let noSpace = "空间不够了，清一清再试"
    /// 离线条（§4 离线行，sheet 内的细条形态）。
    static let offline = "离线：补充制作需要联网"
    /// 402 缺 `required` 那一支（§4 表 + 待答 9：extras 的 402 载荷未记录 ⇒ 走这一句）。
    static let insufficientBalance = "余额不足"
    /// §6 朗读片段：勾选态必须由语义值表达，不靠颜色。
    static let checked = "已勾选"
    static let unchecked = "未勾选"
    static let checkboxSpoken = "复选框"
    static let buttonSpoken = "按钮"
    /// 多候选标签之间的分隔（§3.C 的标签位只能落 key 的中文名，而一个 `type` 可能是两个
    /// key 之一 ⇒ 说的是"这一条产物是这两者之一"，不是替服务端指认其中一个）。
    static let candidateJoin = " / "

    /// `预计消耗 %d co`（§3.D 价目位；**只在会话路径**出现）。
    static func expectedCost(_ credits: Int) -> String { "预计消耗 \(credits) co" }
    /// `本次合计预计消耗 %d co`（§3.D2）。
    static func totalExpectedCost(_ credits: Int) -> String { "本次合计预计消耗 \(credits) co" }
    /// `余额 %d`（§3.D2 的余额位；取不到 ⇒ 整位不渲染，**不显 0、不显 `--`** ——
    /// 21 的清单里没有 `--` 那一档，缺位就是不渲染）。
    static func balance(_ credits: Int) -> String { "余额 \(credits)" }
    /// `余额不足，本次需要 %d co`（§4 表）。今天**不会**被触发：extras 的 402 载荷里有没有
    /// `required` 未记录（待答 9）⇒ 一律走缺值那一句。留着是为了 `required` 一旦有据可查时
    /// 不必改判据、只改取值那一格。
    static func insufficientBalance(required: Int) -> String { "余额不足，本次需要 \(required) co" }

    static func keyLabel(_ key: WorkExtraKey) -> String {
        switch key {
        case .wav: return keyWav
        case .stems: return keyStems
        case .vocalStems: return keyVocalStems
        case .accompaniment: return keyAccompaniment
        case .lyricsTiming: return keyLyricsTiming
        case .lyricsVideo: return keyLyricsVideo
        }
    }

    static func keyCaption(_ key: WorkExtraKey) -> String {
        switch key {
        case .wav: return captionWav
        case .stems: return captionStems
        case .vocalStems: return captionVocalStems
        case .accompaniment: return captionAccompaniment
        case .lyricsTiming: return captionLyricsTiming
        case .lyricsVideo: return captionLyricsVideo
        }
    }
}

// MARK: - 渲染事实（纯函数层）

/// C / D / F 三组行的形状，以及"这一格取什么、取不到怎么办"。
///
/// 单独一层的原因与 `ProducersPanelFacts` / `CreditsLedgerCopy` 同一处：§3 的每一项都带一句
/// "取不到 ⇒ 那一格不渲染"，这类判据埋在 `body` 里就没法被用例钉住，视图因此只负责摆。
enum WorkExtrasPanelFacts {

    /// §3.D 恒定的**展示顺序**（按制作工序）：`wav → stems → vocal_stems → accompaniment →
    /// lyrics_timing → lyrics_video`，与响应数组顺序无关（服务端数组顺序未文档化）。
    ///
    /// ⚠️ 它**不等于** `WorkExtraKey.allKeysInContractOrder`：那一份是契约卡列键的顺序
    /// （`lyrics_video` 排在 `lyrics_timing` 之前），最后两项与屏序相反。两份顺序各有各的用处，
    /// 混用会让"屏上的顺序"跟着契约卡的排版走 —— 而 §3.D 钉的是制作工序。
    static let displayOrder: [WorkExtraKey] = [
        .wav, .stems, .vocalStems, .accompaniment, .lyricsTiming, .lyricsVideo,
    ]

    /// 这一屏**存在**哪些 key 行（§3.D：不可用的一律整行不渲染 —— 不是置灰、不是"当前不支持"）。
    ///
    /// 滤除依据只有一个：`WorkExtraKey.allowedKeys(instrumental:)`（服务端在
    /// `instrumental == true` 时把 `lyrics_video`/`vocal_stems`/`accompaniment`/`lyrics_timing`
    /// 四项滤掉了，§4.7 实测 ⇒ 客户端选项集必须跟着滤）。顺序再按 §3.D 的屏序重排。
    static func allowedKeys(instrumental: Bool?) -> [WorkExtraKey] {
        let allowed = Set(WorkExtraKey.allowedKeys(instrumental: instrumental))
        return displayOrder.filter { allowed.contains($0) }
    }

    /// 产物类型 → **唯一**对应的 key；认不出 ⇒ `nil`（不猜，见文件头第 3 条）。
    static func key(for kind: WorkExtraFileKind?) -> WorkExtraKey? {
        switch kind {
        case .audioWav: return .wav
        case .instrumentalWav, .instrumentalMp3: return .accompaniment
        case .video: return .lyricsVideo
        case .stems, .doc, .cover, .other, .unknown, nil: return nil
        }
    }

    /// 这一条产物**可能**是哪几个 key（隐藏判据之外的两件事要用它：行标签、
    /// 以及"这次读有没有替某个在途 key 说话"）。顺序按屏序 ⇒ 多值时标签是
    /// 「分轨 / 人声分轨」这一形态。
    static func candidateKeys(for kind: WorkExtraFileKind?) -> [WorkExtraKey] {
        if let only = key(for: kind) { return [only] }
        switch kind {
        case .stems: return [.stems, .vocalStems]
        // `doc` 连"是不是本屏的产物"都不敢断言（`歌词.txt` / `制作参数.json` 也投影成 `doc`）⇒ 空集。
        case .audioWav, .instrumentalWav, .instrumentalMp3, .video, .doc, .cover, .other,
             .unknown, nil:
            return []
        }
    }

    /// 这一条产物的标签（§3.C：唯一恒真的信息是 key 的中文名）。
    static func rowLabel(for kind: WorkExtraFileKind?) -> String {
        candidateKeys(for: kind)
            .map(WorkExtrasCopy.keyLabel)
            .joined(separator: WorkExtrasCopy.candidateJoin)
    }

    /// 服务端已经替这一格说话了：状态落在"已完成 / 制作中"两态之一（**不要求**类型认得出 key，
    /// 那是另一件事 —— 见 `rowIsNameable`）。
    ///
    /// `failed` / `cancelled` / `unrecognised` 三态不进这里：§8 的清单里没有"失败/已取消"那一类词，
    /// 而 §3.C 明写「唯一恒真的信息是 key 的中文名与**状态（已完成 / 制作中）**」⇒
    /// 那一格今天没有可渲染的口径（待答 1）。把 `version` 的原串印上屏更是 §7 直接禁掉的
    /// （露出来是工程词/英文态名，违反 A15 与 17 §10）。
    static func isServerSideInFlightOrDone(_ file: WorkExtraDeliveryFileDto) -> Bool {
        switch file.deliveryState {
        case .ready, .preparing: return true
        case .failed, .cancelled, .unrecognised: return false
        }
    }

    /// 这一条产物有没有**可说的标签**（§3.C：标签位唯一可依赖的就是 key 的中文名）。
    /// 认不出的那些（`doc` / `cover` / `other` / 未释义类型）不渲染成行 —— 不是藏起来，
    /// 是那一格没有一句真话可说；缺的字段就是待答 1。
    static func rowIsNameable(_ file: WorkExtraDeliveryFileDto) -> Bool {
        candidateKeys(for: file.kind).isEmpty == false
    }

    /// 已经**不该出现在 D 组**的 key（§3.D「已做完 / 在途的 key 不在这里，同一 key 只出现在一处」）。
    ///
    /// 状态判据与 C/F 组用的是同一个 `isServerSideInFlightOrDone` ⇒ "从 D 组消失"与
    /// "出现在 C/F 组"这两件事不可能各自漂走。类型认不出的那些 key（`stems` 系与 `doc` 系）
    /// **继续留在 D 组**：重复提交不重做也不重扣（`extras-service.ts:465-474` 在计费前先查
    /// `prior`），漏隐藏的代价只是"多点一次"，而错隐藏的代价是把一件还没做的事从屏上抹掉。
    static func hiddenKeys(in files: [WorkExtraDeliveryFileDto]) -> Set<WorkExtraKey> {
        var hidden = Set<WorkExtraKey>()
        for file in files where isServerSideInFlightOrDone(file) {
            if let mapped = key(for: file.kind) { hidden.insert(mapped) }
        }
        return hidden
    }

    /// C 组（已经做好的）。`files` 为空 ⇒ 空数组 ⇒ C 组连同标题整组不渲染（§3.C）。
    static func deliveredRows(
        in files: [WorkExtraDeliveryFileDto], saved: Set<String>
    ) -> [WorkExtraDeliveredRow] {
        let rows: [WorkExtraDeliveredRow] = files.compactMap { file -> WorkExtraDeliveredRow? in
            guard file.deliveryState == .ready, let id = file.id, id.isEmpty == false,
                  rowIsNameable(file) else { return nil }
            return WorkExtraDeliveredRow(
                artifactID: id,
                label: rowLabel(for: file.kind),
                symbol: symbol(for: file.kind),
                isSaved: saved.contains(id),
                orderKey: candidateKeys(for: file.kind).first
            )
        }
        return sorted(rows, by: \.orderKey)
    }

    /// F 组（制作队列）= 服务端在途行 + 本屏已提交而服务端快照还没替它说话的那些 key。
    ///
    /// `localClaims` 那一半的存在理由：§4 的 409 行要「该 key 行迁入 F 组」，而那一格服务端
    /// **没有**给任何产物行 ⇒ 屏上不能凭空少一项。
    static func queueRows(
        in files: [WorkExtraDeliveryFileDto], localClaims: Set<WorkExtraKey>
    ) -> [WorkExtraQueueRow] {
        let server: [WorkExtraQueueRow] = files.compactMap { file -> WorkExtraQueueRow? in
            guard file.deliveryState == .preparing, let id = file.id, id.isEmpty == false,
                  rowIsNameable(file) else { return nil }
            return WorkExtraQueueRow(
                id: id,
                label: rowLabel(for: file.kind),
                symbol: symbol(for: file.kind),
                showsIndeterminate: true,
                // 「制作中」只跟着 `.preparing`。`.unrecognised`（没有 url、`version` 又不是那三个
                // 已知状态文本）走不到这里 —— 它既不显状态也不显菊花：把一个新出现的、
                // 我们不认识的态名画成"制作中"，就是替服务端说了一件它没说过的事。
                statusText: WorkExtrasCopy.preparing,
                orderKey: candidateKeys(for: file.kind).first
            )
        }
        let claims: [WorkExtraQueueRow] = localClaims.map { key in
            WorkExtraQueueRow(
                id: "local:\(key.rawValue)",
                label: WorkExtrasCopy.keyLabel(key),
                symbol: WorkExtrasPanelFacts.symbol(for: key),
                showsIndeterminate: true,
                statusText: WorkExtrasCopy.preparing,
                orderKey: key
            )
        }
        // 两组一起按屏序排（§3.D 的顺序纪律只管 C/F 组里"认得出 key"的那些行；认不出的不重排）。
        return sorted(server + claims, by: \.orderKey)
    }

    /// D 组（可以再做的）：屏序 × 可用键 × 未被隐藏。
    ///
    /// `chargesCredits == false`（作品路径）⇒ `costText` **恒 nil**：那一条腿服务端分文不收，
    /// 把会话级价目表搬到这条腿上渲染就是编一份不存在的账单（§7 作品路径不计费条）。
    static func selectableRows(
        instrumental: Bool?, files: [WorkExtraDeliveryFileDto],
        localClaims: Set<WorkExtraKey>, selected: Set<WorkExtraKey>, chargesCredits: Bool
    ) -> [WorkExtraSelectableRow] {
        let hidden = hiddenKeys(in: files).union(localClaims)
        return allowedKeys(instrumental: instrumental).compactMap { key in
            guard hidden.contains(key) == false else { return nil }
            return WorkExtraSelectableRow(
                key: key,
                label: WorkExtrasCopy.keyLabel(key),
                caption: WorkExtrasCopy.keyCaption(key),
                costText: chargesCredits
                    ? WorkExtrasCopy.expectedCost(key.sessionDeductionCredits) : nil,
                credits: chargesCredits ? key.sessionDeductionCredits : nil,
                isSelected: selected.contains(key)
            )
        }
    }

    /// D2 合计行（**仅会话路径**、勾选数 > 0）。
    static func totalLine(
        selected: Set<WorkExtraKey>, chargesCredits: Bool, balance: Int?
    ) -> WorkExtrasTotalLine? {
        guard chargesCredits else { return nil }
        let keys = displayOrder.filter { selected.contains($0) }
        guard !keys.isEmpty else { return nil }
        // 合计算法 = 勾选 key 的价目求和（整数、无阶梯、无折扣 —— 契约没有优惠概念）。
        // 求和只许有这一条写法：`WorkExtraKey.sessionDeductionTotal(for:)`（去重后算）。
        // 本屏不再自己加第二遍：两处口径迟早会漂，而 §9 的算术判据（全 6 项 = 260）盯的是同一格。
        let total = WorkExtraKey.sessionDeductionTotal(for: keys)
        return WorkExtrasTotalLine(
            text: WorkExtrasCopy.totalExpectedCost(total),
            credits: total,
            balanceText: balance.map { WorkExtrasCopy.balance($0) },
            balance: balance
        )
    }

    /// H 事实行（仅作品路径）。会话路径 ⇒ `nil`，那一格连容器都不占。
    static func factLine(chargesCredits: Bool) -> String? {
        chargesCredits ? nil : WorkExtrasCopy.noCostHere
    }

    /// §3.C 的四类符号（音频 `waveform` / 压缩包 `archivebox` / 视频 `film` / 文本 `text.quote`）。
    static func symbol(for key: WorkExtraKey) -> String {
        switch key {
        case .wav, .accompaniment: return "waveform"
        case .stems, .vocalStems: return "archivebox"
        case .lyricsTiming: return "text.quote"
        case .lyricsVideo: return "film"
        }
    }

    /// 类型给的符号（认不出 key 时按**类型**给：`stems` 是压缩包、`doc` 是文本 —— 这两件事
    /// 与它是哪一个 key 无关）。`cover`/`other`/未释义类型不在 §3.C 的四类里 ⇒ 符号位不渲染，
    /// 不借一个"看起来像"的图标冒充。
    static func symbol(for kind: WorkExtraFileKind?) -> String? {
        if let key = key(for: kind) { return symbol(for: key) }
        switch kind {
        case .stems: return "archivebox"
        case .doc: return "text.quote"
        default: return nil
        }
    }

    /// 一次读有没有替这个在途 key 说话（本地在途行要不要收掉）。
    ///
    /// 判据是"快照里存在一条**可能是**它的行"，不是"存在一条**是**它的行"—— 后者需要
    /// `files[]` 的产物身份字段（待答 1）。代价写在名字旁边：同时提交 `stems` 与 `vocal_stems`
    /// 而服务端只回一条 `stems` 行时，两条本地在途会被这一条行一起收掉（少显一行，不多显）。
    static func snapshotAccounts(for key: WorkExtraKey, in files: [WorkExtraDeliveryFileDto]) -> Bool {
        files.contains { file in
            isServerSideInFlightOrDone(file) && candidateKeys(for: file.kind).contains(key)
        }
    }

    // MARK: 朗读标签（§6 的"一停"逐条）

    /// D 行：「<标签>，<副标>，预计消耗 N co，复选框，未勾选」。
    /// 作品路径**没有**价目片段（`costText == nil` ⇒ 那一段整个不进标签）。
    static func selectableSpokenLabel(_ row: WorkExtraSelectableRow) -> String {
        var parts = [row.label, row.caption]
        if let costText = row.costText { parts.append(costText) }
        parts.append(WorkExtrasCopy.checkboxSpoken)
        parts.append(row.isSelected ? WorkExtrasCopy.checked : WorkExtrasCopy.unchecked)
        return parts.joined(separator: "，")
    }

    /// C 行：「<标签>，保存到本机 按钮」/「<标签>，已在本机，删除本机文件 按钮」（§6）。
    static func deliveredSpokenLabel(_ row: WorkExtraDeliveredRow) -> String {
        if row.isSaved {
            return "\(row.label)，\(WorkExtrasCopy.saved)，删除本机文件 \(WorkExtrasCopy.buttonSpoken)"
        }
        return "\(row.label)，\(WorkExtrasCopy.save) \(WorkExtrasCopy.buttonSpoken)"
    }

    /// F 行：「<标签>，制作中」。
    static func queueSpokenLabel(_ row: WorkExtraQueueRow) -> String {
        guard let statusText = row.statusText else { return row.label }
        return "\(row.label)，\(statusText)"
    }

    ///  decorate-sort-undecorate：认得出屏序位置的行按屏序，认不出的排到可读行之后并保持
    /// 服务端给的相对顺序（不重排 = 不假装我们知道它该排哪儿）。
    private static func sorted<R>(
        _ rows: [R], by orderKey: KeyPath<R, WorkExtraKey?>
    ) -> [R] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let left = index(of: lhs.element[keyPath: orderKey])
                let right = index(of: rhs.element[keyPath: orderKey])
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func index(of key: WorkExtraKey?) -> Int {
        guard let key, let position = displayOrder.firstIndex(of: key) else {
            return displayOrder.count
        }
        return position
    }
}

// MARK: - 行模型

/// 一行「可以再做的」（§3.E：勾选圈 + 标签 + 副标 +（会话路径）价目位）。
public struct WorkExtraSelectableRow: Equatable, Sendable, Identifiable {
    public let key: WorkExtraKey
    public let label: String
    public let caption: String
    /// `预计消耗 %d co`；**作品路径恒 nil** ⇒ 那一格不渲染（不是显 0、不是显「—」）。
    public let costText: String?
    /// 价目数字本身（会话路径）；作品路径 nil ⇒ 合计行也不可能从这条腿上算出任何东西。
    public let credits: Int?
    public let isSelected: Bool

    public init(
        key: WorkExtraKey, label: String, caption: String, costText: String?,
        credits: Int?, isSelected: Bool
    ) {
        self.key = key
        self.label = label
        self.caption = caption
        self.costText = costText
        self.credits = credits
        self.isSelected = isSelected
    }

    public var id: String { key.rawValue }
}

/// 一行「已经做好的」（§3.C：符号 + 标签 +（副行不渲染）+ 右侧文字钮）。
public struct WorkExtraDeliveredRow: Equatable, Sendable, Identifiable {
    /// 产物身份（`files[].id`）—— 也是 `WorkDownloadStore` 的键（见 `saveWorkExtraArtifact`）。
    public let artifactID: String
    public let label: String
    public let symbol: String?
    /// 已在本机 ⇒ `checkmark.circle` + 「已在本机」，再点 = 删除本机文件（二次确认）。
    public let isSaved: Bool
    /// 本屏候选集的首项（排序用；`nil` = 没有屏序位置）。
    public let orderKey: WorkExtraKey?

    public init(
        artifactID: String, label: String, symbol: String?, isSaved: Bool,
        orderKey: WorkExtraKey?
    ) {
        self.artifactID = artifactID
        self.label = label
        self.symbol = symbol
        self.isSaved = isSaved
        self.orderKey = orderKey
    }

    public var id: String { artifactID }
}

/// 一行「制作队列」（§3.F）。
public struct WorkExtraQueueRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let symbol: String?
    /// 菊花（17-S8 不确定指示）。Reduce Motion 下由视图退化成**静态**指示，仍然在场。
    public let showsIndeterminate: Bool
    /// 「制作中」。**只有 `.preparing` 才非 nil** —— `.unrecognised` 的原串绝不进这里。
    public let statusText: String?
    /// §3.F 的硬判据：pending 没有 url ⇒ 「保存到本机」**整钮不渲染**（不是禁用态）。
    public let showsSaveAction: Bool
    public let orderKey: WorkExtraKey?

    public init(
        id: String, label: String, symbol: String?, showsIndeterminate: Bool,
        statusText: String?, orderKey: WorkExtraKey?
    ) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.showsIndeterminate = showsIndeterminate
        self.statusText = statusText
        // 这一格里没有 url 是判据而不是选项：队列行**不许**长出一个下载钮（§3.F + 09 §5）。
        self.showsSaveAction = false
        self.orderKey = orderKey
    }
}

/// D2 合计行（会话路径、勾选数 > 0 才存在）。
public struct WorkExtrasTotalLine: Equatable, Sendable {
    public let text: String
    public let credits: Int
    /// 「余额 %d」整串；余额取不到 ⇒ nil ⇒ **余额位不渲染**（§3.D2：不得显 0）。
    public let balanceText: String?
    public let balance: Int?

    public init(text: String, credits: Int, balanceText: String?, balance: Int?) {
        self.text = text
        self.credits = credits
        self.balanceText = balanceText
        self.balance = balance
    }

    /// §6 那一停：「本次合计预计消耗 40 co，余额 128」；缺余额 ⇒ 少最后一段（不念「余额 未取到」）。
    public var spokenLabel: String {
        guard let balanceText else { return text }
        return "\(text)，\(balanceText)"
    }
}

// MARK: - 读失败的分诊（§4 表第一行 + 离线行）

/// extras 快照读的失败档。四类各有各的表现，不并成一句「操作失败」。
public enum WorkExtrasReadFailure: Equatable, Sendable {
    /// 网络类。本仓**没有**可达性探针 ⇒ "离线"的唯一依据就是这一格（§4 离线行据此渲染，
    /// 而不是靠 UI 猜）；真离线时首载必然落在这里。
    case network
    /// 服务端原文 / 状态码句（透传，A4/A15：不编「未知错误」糊词）。
    case server(String)
    /// 401/403：关面板 + 17-S6 由**会话层**统一处理（§4 + 17 §5 禁令：各屏不各自弹登录框）。
    case unauthenticated
    /// 2xx 但形状读不出：是**我们**的解码器没对上他们的契约 ⇒ 不记到后端账上，也不冒充成功。
    case unreadable
    /// 本地校验就没发出去（裸 jobId / 缺 sessionId）：这一句是客户端自己的话，
    /// 不许长成"服务端 400"的样子。
    case clientSide(String)
}

// MARK: - 屏状态（`AppSession.workExtras` 持有唯一一份）

/// 21 面板的全部状态（一个值类型 ⇒ 视图只读它，不散着读七八个属性）。
///
/// 为什么账本在会话层而不是视图的 `@State`：§8 并发冲突条要「20 的行 ⋯ 连点两次 ⇒ 复用已开的
/// sheet（不叠第二层）」，而 §7 的 `deliveryRevision` 对账要一份跨"读"存活的旧值可比 ——
/// 两件事都需要一个跨视图宿主的宿主（同 `CreditsLedgerState` 的那条理由）。
public struct WorkExtrasState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 还没发过（面板还没为任何宿主开过）。
        case idle
        /// 首载在途（§4 加载：**C/F 不骨架** —— 它们可能整组不存在；D 组骨架 + B/G 呼吸）。
        case loading
        /// 手里有读得懂的快照。
        case ready
        /// 首载失败 ⇒ **sheet 内整块替换**（§4 表第一行的 ③ 形态，07 §4 先例）。
        case failed(WorkExtrasReadFailure)
    }

    public var phase: Phase = .idle
    /// 当前面板的宿主（两宿主一容器：标题、计价面、走哪条腿全看它）。
    public var host: WorkExtrasHost?
    /// 最近一次**读得懂**的产物清单（条目原样保留，重排只发生在渲染层）。
    public var files: [WorkExtraDeliveryFileDto] = []
    /// 会话腿的工作流计数器（§7：只做对账、**绝不上屏** —— A15 也不允许露 `revision`）。
    ///
    /// `nil` 有两种来源，都不许折成 0：① 作品腿**恒无**这一格（`WorkExtrasResponseDto`
    /// 类型面上就没有那个属性）；② 会话腿缺值 ⇒ §7 把静默重取退化为"重开面板才重取"。
    public var deliveryRevision: Int?
    /// D 组勾选态。
    public var selectedKeys: Set<WorkExtraKey> = []
    /// 本屏已提交、而服务端快照还没替它说话的那些 key（§4 的 409 行要它们留在 F 组）。
    public var locallyQueuedKeys: Set<WorkExtraKey> = []
    /// 已落本机的产物 id（事实源是 `WorkDownloadStore` 的**盘上文件**，不是内存猜测）。
    public var savedArtifactIDs: Set<String> = []
    /// 正在取件的产物 id（在途去重：同一格连点只许打一次出口；那一格给菊花不给百分比）。
    public var savingArtifactIDs: Set<String> = []
    /// 行内失败原文（键 = 产物 id；§4 最后两行都是"行内"，不是 Toast）。
    public var rowMessages: [String: String] = [:]
    /// 提交在途 ⇒ 主钮菊花 + 不可二次点击（一次点击 = 一键的客户端那一半）。
    public var submissionInFlight = false
    /// 提交失败的行内原文（§4 的 ② 行：主钮下方一行，`color.error`，勾选保留）。
    public var submitMessage: String?
    /// 409「等着就行」那一档的行内话（**不是**错误：不进错误色、不弹 Toast）。
    public var waitingNote: String?
    /// 读失败（决定整块替换说什么，也决定离线条要不要出现）。
    public var readFailure: WorkExtrasReadFailure?
    /// 请求代号：每次发起 +1，迟到的旧一代不落账（D8 串号；换宿主/换号都算旧一代）。
    public var requestID = 0
    /// 提交代号：一次点击一个。**同一代号的重发不发生**（本屏没有任何自动重发路径）。
    public var submissionID = 0
    /// 这一份快照属于谁（extras 是私有数据 ⇒ 按 principalId 分桶，换号即作废，D5/D8/D9）。
    public var ownerID: String?
    /// 401/403 时请宿主关掉 sheet（§4：关闭 sheet + 17-S6，登录框归会话层）。
    public var dismissRequested = false

    public init(host: WorkExtrasHost? = nil, ownerID: String? = nil) {
        self.host = host
        self.ownerID = ownerID
    }

    // MARK: 派生面（视图只读这些）

    /// 走的是哪一条腿。宿主没定 ⇒ 按**不扣费**那一侧收：宁可不显数字，也不凭空显。
    public var chargesCredits: Bool { host?.chargesCredits == true }

    /// B 标题。
    public var title: String { host?.title ?? WorkExtrasCopy.title }

    /// 本屏存在哪些 key 行（§3.D 滤除 + 屏序）。
    public var allowedKeys: [WorkExtraKey] {
        WorkExtrasPanelFacts.allowedKeys(instrumental: host?.instrumental)
    }

    /// D 组行。
    public var selectableRows: [WorkExtraSelectableRow] {
        WorkExtrasPanelFacts.selectableRows(
            instrumental: host?.instrumental, files: files, localClaims: locallyQueuedKeys,
            selected: selectedKeys, chargesCredits: chargesCredits
        )
    }

    /// C 组行。
    public var deliveredRows: [WorkExtraDeliveredRow] {
        WorkExtrasPanelFacts.deliveredRows(in: files, saved: savedArtifactIDs)
    }

    /// F 组行（队列为空 ⇒ 整组不渲染，§3.F）。
    public var queueRows: [WorkExtraQueueRow] {
        WorkExtrasPanelFacts.queueRows(in: files, localClaims: locallyQueuedKeys)
    }

    /// 当前有效勾选：只数**还在 D 组**的那些。一个 key 被服务端答成已完成/在途之后，
    /// 它残留的勾选态既不该继续参与合计，也不该被提交出去（那是在提交一件已经做好的事）。
    public var effectiveSelection: [WorkExtraKey] {
        selectableRows.filter(\.isSelected).map(\.key)
    }

    /// D2 合计行（作品路径 / 零勾选 ⇒ nil ⇒ 整行不渲染）。
    public func totalLine(balance: Int?) -> WorkExtrasTotalLine? {
        WorkExtrasPanelFacts.totalLine(
            selected: Set(effectiveSelection), chargesCredits: chargesCredits, balance: balance
        )
    }

    /// H 事实行（仅作品路径）。
    public var factLine: String? { WorkExtrasPanelFacts.factLine(chargesCredits: chargesCredits) }

    /// C 组在不在（§3.C：`files` 为空数组 ⇒ 连标题一起不渲染，也**不**给"还没有交付物"空态）。
    public var showsDeliveredSection: Bool { !deliveredRows.isEmpty }

    /// F 组在不在。
    public var showsQueueSection: Bool { !queueRows.isEmpty }

    /// D 组 + G 主钮在不在（§3.G：全部 key 都不可用 ⇒ 两组**一并消失**，只剩 C 组，
    /// 不出现"没有可做的了"那种空壳说明）。
    public var showsSelectableSection: Bool { !selectableRows.isEmpty }

    /// 首载骨架（只在手里什么都还没有时铺）。
    public var showsSkeleton: Bool { phase == .idle || phase == .loading }

    /// 整块替换（§4 表第一行的 ③ 形态）。
    public var showsWholePanelFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 离线条 + D/F/G 整块不渲染（§4 离线行：无网络则无可提交）。
    public var showsOfflineStrip: Bool { readFailure == .network }

    /// 可提交：有有效勾选、不在提交在途、且这一条腿还活着（离线/整块失败时那几格根本不渲染）。
    /// 勾选 0 项时主钮走 disabled 形态且**没有任何解释文案**（§3.G：空选择不需要教训用户）。
    public var canSubmit: Bool {
        !submissionInFlight && !effectiveSelection.isEmpty && showsSelectableSection
    }

    // MARK: 落到状态上的纯腿

    /// 一次读得懂的快照落到屏上（**整表替换**；§7：下拉刷新在 sheet 内不提供）。
    ///
    /// 这一格里三件事同时发生，缺一个就会画出错的东西：
    /// ① 已经不在 D 组的 key 要从勾选里掉出去（留着就是"提交一件已经做好的事"）；
    /// ② 本地在途行只要被快照说上了就收掉（否则同一 key 在 F 组有两行）；
    /// ③ 提交后的行内失败原文清掉（这一次读成功说明事情在往前走，旧的那一句该让位）。
    mutating func applySnapshot(_ snapshot: [WorkExtraDeliveryFileDto], revision: Int?) {
        files = snapshot
        deliveryRevision = revision
        readFailure = nil
        waitingNote = nil
        submitMessage = nil
        locallyQueuedKeys = locallyQueuedKeys.filter {
            WorkExtrasPanelFacts.snapshotAccounts(for: $0, in: snapshot) == false
        }
        let hidden = WorkExtrasPanelFacts.hiddenKeys(in: snapshot).union(locallyQueuedKeys)
        let present = Set(allowedKeys)
        selectedKeys = selectedKeys.subtracting(hidden).intersection(present)
        phase = .ready
    }

    /// 一次读失败。手里还有快照时**不清账**：§4 只给了"首载失败"那一格，而把已经读到的那些
    /// 产物被一次失败的刷新抹掉，比多一个"这一份可能旧了"的记号坏得多。
    mutating func applyReadFailure(_ failure: WorkExtrasReadFailure) {
        readFailure = failure
        if files.isEmpty { phase = .failed(failure) }
    }

    /// 提交失败的两种处置（§4 表 409 行 vs 其余行）。返回 `true` = "等着就行"那一档。
    mutating func applySubmitFailure(keepsWaiting: Bool, submittedKeys: [WorkExtraKey]) -> Bool {
        if keepsWaiting {
            // 「还在做」不是失败：行留在 F 组、说一次中性事实、**不**弹错误 Toast（需求 9 + §4）。
            locallyQueuedKeys.formUnion(submittedKeys)
            selectedKeys.subtract(submittedKeys)
            waitingNote = WorkExtrasCopy.alreadyInFlight
            submitMessage = nil
            return true
        }
        waitingNote = nil
        return false
    }
}

// MARK: - 会话层腿（读 / 提交 / 取件落盘）

extension AppSession {

    /// 面板 `.task(id:)` 的键：**当前登录身份 + 宿主**（§1 登录门槛：extras 三端点都要 Bearer）。
    ///
    /// 为什么键里要带宿主而不是裸 `.task`：两宿主共用一个面板容器，换一行作品或走查路由
    /// 落在"会话还在恢复"的那一帧时，裸 `.task` 不会重跑 ⇒ 上一首的快照会留在这一首的屏上，
    /// 或者登录后永远停在「登录状态已过期」（`CreditsLedgerView` 那条腿的同一课）。
    public var workExtrasOwnerKey: String {
        guard case .signedIn(let user) = authPhase else { return "unsigned-in" }
        guard let host = workExtras.host else { return user.id }
        return "\(user.id)|\(host.cacheKey)"
    }

    /// 打开面板：记宿主 + 取一次快照（§7「进入本屏取一次快照」）。
    ///
    /// 同一宿主已经读过就不再读（§8：连点两次「补充制作」复用已开的 sheet、两处共读一份状态，
    /// 不各自发 GET）。换宿主 = 整本重开：一份 extras 快照属于一行作品/一次会话，不是全局账。
    public func openWorkExtras(host: WorkExtrasHost) async {
        if workExtras.host != host {
            workExtras = WorkExtrasState(host: host)
        }
        guard workExtras.phase == .idle else { return }
        await loadWorkExtras()
    }

    /// 关闭面板（宿主的 dismiss 钩子）。
    ///
    /// **这一句是「重开即重取」的实现落点**：作品腿没有 `deliveryRevision` ⇒ §7 把对账退化成
    /// "重开面板即重取"，所以关掉时手里那份必须丢掉，否则重开看到的还是上一次那份。
    public func closeWorkExtras() {
        workExtras = WorkExtrasState()
    }

    /// 读一次快照。走哪条腿由宿主决定（两条腿的响应类型不同，不共用一条代码路径：
    /// `WorkExtrasResponseDto` 没有计数器，`SessionExtrasResponseDto` 有）。
    ///
    /// `silent == true` = 计数器变化后的静默替换（§7）：不铺骨架、失败也不把面板判回错误态。
    public func loadWorkExtras(silent: Bool = false) async {
        guard case .signedIn(let user) = authPhase, let host = workExtras.host else {
            if !silent {
                // 游客/恢复中：不发（发了只是换一次 401），也不把上一个身份的快照留着。
                // 整块那一句会说「登录状态已过期」，而登录框由会话层统一 present（17 §5 禁令）。
                workExtras.applyReadFailure(.unauthenticated)
                workExtras.dismissRequested = true
            }
            return
        }
        if workExtras.ownerID != user.id {
            workExtras = WorkExtrasState(host: host, ownerID: user.id)
        }
        guard silent || workExtras.phase != .loading else { return }   // 在途去重：连点重试只发一发
        workExtras.requestID += 1
        let generation = workExtras.requestID
        if !silent, workExtras.files.isEmpty { workExtras.phase = .loading }
        let service = extrasService
        do {
            let snapshot: [WorkExtraDeliveryFileDto]
            let revision: Int?
            switch host {
            case .work(let id, _):
                let page = try await service.files(workID: id)
                snapshot = page.files
                revision = nil        // 作品腿**没有**计数器（类型面上就没有这一格，不是"读成 nil"）
            case .session(let id, _):
                let page = try await service.files(sessionID: id)
                snapshot = page.files
                revision = page.deliveryRevision    // 缺值 ⇒ nil，**不填 0**
            }
            guard workExtras.requestID == generation else { return }   // 迟到的旧一代：不落账
            workExtras.applySnapshot(snapshot, revision: revision)
            await refreshWorkExtrasSavedMarks()
        } catch let failure as ExtrasFailure {
            let readFailure = Self.workExtrasReadFailure(for: failure)
            guard workExtras.requestID == generation else { return }
            guard silent == false else { return }
            workExtras.applyReadFailure(readFailure)
            if readFailure == .unauthenticated { workExtras.dismissRequested = true }
        } catch {
            guard workExtras.requestID == generation, silent == false else { return }
            workExtras.applyReadFailure(.server(CatalogService.classify(error).userText))
        }
    }

    /// 点一格「可以再做的」（§3.E 多选态）。勾选态由**语义值**表达（§6：不得只靠颜色）。
    public func toggleWorkExtra(_ key: WorkExtraKey) {
        guard workExtras.submissionInFlight == false else { return }
        // 已经不在 D 组的 key（在途/已完成）不接受勾选：那一行屏上根本不存在，但类型面上
        // 仍可能被别的调用递进来 ⇒ 这里再挡一次，别留下一个看不见的勾选。
        guard workExtras.selectableRows.contains(where: { $0.key == key }) else { return }
        if workExtras.selectedKeys.contains(key) {
            workExtras.selectedKeys.remove(key)
        } else {
            workExtras.selectedKeys.insert(key)
        }
        workExtras.submitMessage = nil
        workExtras.waitingNote = nil
    }

    /// 主钮「开始补充制作」。
    ///
    /// 幂等纪律（§7 / 硬边界 5）的客户端那一半落在这里，另一半（上线字段）阻塞在待答 8，
    /// 理由见文件头：一次点击 = 一个新的提交代号，也是**唯一**一次 POST；在途时这里直接
    /// `return`、视图侧同时把主钮换成菊花并 `disabled`；任何失败都不自动重发。
    public func submitWorkExtras() {
        guard workExtras.canSubmit, let host = workExtras.host else { return }
        let keys = workExtras.effectiveSelection
        guard !keys.isEmpty else { return }
        workExtras.submissionID += 1
        workExtras.submissionInFlight = true
        workExtras.submitMessage = nil
        workExtras.waitingNote = nil
        // 勾选就地收进"在途"那一格：那几行立刻从 D 组迁进 F 组（§4 成功行的"乐观迁入"，
        // 服务端回执到达前也不留空档；回执一到就被 `applySnapshot` 收掉重复的那一份）。
        workExtras.locallyQueuedKeys.formUnion(keys)
        workExtras.selectedKeys.subtract(keys)
        let submission = workExtras.submissionID
        let service = extrasService
        Task { @MainActor [weak self] in
            await self?.runWorkExtrasSubmission(
                host: host, keys: keys, service: service, submission: submission
            )
        }
    }

    private func runWorkExtrasSubmission(
        host: WorkExtrasHost, keys: [WorkExtraKey], service: ExtrasService, submission: Int
    ) async {
        defer {
            if workExtras.submissionID == submission { workExtras.submissionInFlight = false }
        }
        do {
            switch host {
            case .work(let id, _):
                let receipt = try await service.request(workID: id, keys: keys)
                guard workExtras.submissionID == submission else { return }
                workExtras.applySnapshot(receipt.files, revision: nil)
                // 随后**必须**再 GET 一次复列：这一条腿没有 `deliveryRevision` ⇒
                // 没有"版本变了"的判据，GET 是 C/F 两组回到服务端事实的唯一一条腿
                // （A8 后半句「GET 复列 ⇒ 不产生第二次制作」盯的就是这一次读）。
                await loadWorkExtras(silent: true)
            case .session(let id, _):
                let before = workExtras.deliveryRevision
                let receipt = try await service.request(sessionID: id, keys: keys)
                guard workExtras.submissionID == submission else { return }
                // 会话腿：POST 回执**就是**最新快照（含服务端自己写的那几条
                // `补充制作准备中` 行），所以不无脑补 GET；计数器只用来决定要不要静默重取（§7）。
                workExtras.applySnapshot(receipt.files, revision: receipt.deliveryRevision)
                if Self.workExtrasRevisionAdvanced(
                    previous: before, next: receipt.deliveryRevision
                ) {
                    await loadWorkExtras(silent: true)
                }
                await refreshWorkExtrasSavedMarks()
                // §7 余额行：提交成功后**强制刷新** `/me`（09 §3.G 同规则）。
                // 这一格是本屏唯一允许余额出现的地方，且只作事实展示 ——
                // 全仓没有充值/购买入口（D12 硬边界 9）。
                guard workExtras.submissionID == submission else { return }
                await loadMe(force: true)
            }
            guard workExtras.submissionID == submission else { return }
            // Toast 里不报数字（§4 成功行：数字已经在 D2 说过，重复即噪声）。
            showToast(host.startedToast)
        } catch let failure as ExtrasFailure {
            guard workExtras.submissionID == submission else { return }
            let keepsWaiting = failure.shouldKeepWaiting
            let handled = workExtras.applySubmitFailure(
                keepsWaiting: keepsWaiting, submittedKeys: keys
            )
            if handled { return }   // 「等着就行」：不弹错误 Toast（§4 的 409 行 + 需求 9）
            let readFailure = Self.workExtrasReadFailure(for: failure)
            if readFailure == .unauthenticated {
                // §4：关闭 sheet + 17-S6，本屏不自建登录框。
                workExtras.dismissRequested = true
                return
            }
            // 其余档：§4 要的是**行内**一句（主钮下方），不是 Toast —— 错误得留在屏上让人读得完；
            // Toast 会自己消失，把「余额不足」闪一下等于没说。勾选保留（§4 的 400 行）。
            workExtras.submitMessage = Self.workExtrasSubmitMessage(for: failure, host: host)
        } catch {
            guard workExtras.submissionID == submission else { return }
            workExtras.submitMessage = CatalogService.classify(error).userText
        }
    }

    /// 会话腿的计数器对账（§7）。
    ///
    /// 只有**两边都有值且不相等**才认为"工作流计数器动了"。任一边 `nil` ⇒ `false`：
    /// 把"没有计数器"折成 0，一次真变化就会被静默吞掉（`nil != 0`，这一格与
    /// `SessionExtrasResponseDto` 的解码口径是同一句话）。
    public static func workExtrasRevisionAdvanced(previous: Int?, next: Int?) -> Bool {
        guard let previous, let next else { return false }
        return next != previous
    }

    /// 提交失败那一行的字。
    ///
    /// 402 是本屏唯一需要**改写**的一格（§4 表：extras 的 402 载荷是否带 `required` 未记录
    /// ⇒ 缺值走「余额不足」）。改写只在这一条上发生，且**只在会话路径**：作品路径服务端不扣费，
    /// 那一条腿上的 402 与余额没有因果关系，替它说「余额不足」就是编造因果。
    /// 任何情况下都不出现补余额的引导（D12）。
    static func workExtrasSubmitMessage(for failure: ExtrasFailure, host: WorkExtrasHost) -> String? {
        if host.chargesCredits, case .rejected(.server(statusCode: 402, _)) = failure {
            return WorkExtrasCopy.insufficientBalance
        }
        return failure.userMessage
    }

    /// `ExtrasFailure` → 读失败档（每一档的表现不同，见 `WorkExtrasReadFailure`）。
    static func workExtrasReadFailure(for failure: ExtrasFailure) -> WorkExtrasReadFailure {
        switch failure {
        case .rejected(let rejection):
            if case .unauthenticated = rejection { return .unauthenticated }
            return .server(rejection.userMessage)
        case .transport(let catalogFailure):
            switch catalogFailure {
            case .network: return .network
            case .unauthenticated: return .unauthenticated
            case .server(let message), .backendGap(let message): return .server(message)
            }
        case .localValidation(let error):
            // 一次请求都没发出去 ⇒ 别长成"服务端 400"的样子。
            return .clientSide(String(describing: error))
        case .unreadableResponse:
            return .unreadable
        }
    }

    // MARK: 取件落盘（§9 判据：四屏里今天唯一能真落盘的那条下载腿）

    /// 产物 → 直存请求。
    ///
    /// ⚠️ **`files[].url` 原样消费**（§7 取件条 / 硬边界 7）：地址里嵌的 jobId 是 **worker job**
    /// 而不是生成 job，产物端点 `artifacts/:jobId/:artifactId` 在本层**不建模**
    /// （`WorkExtraDeliveryFileDto` 根本没有那个构造器，拆错了不报错、只是打到别人的产物上）。
    /// 这里唯一的改写是 `resolveMediaURL`（把相对形态补成同源绝对地址），**不做**
    /// `intent=play → download` 那类重写：那是作品音频 `audioUrl` 的专属改道，而 extras 的取件
    /// 本来就是同源 200 流（`Content-Disposition: attachment`），`accompaniment` 是同源 302 到
    /// `intent=download` —— 逐跳出口裁决已在传输层覆盖（`AudioRedirectGuard` +
    /// `CovaEnvironment.mediaHopEgress`），名单外桶不出现在这条路上（§7 与 #39 划清的那一段）。
    ///
    /// owner 不成立 ⇒ 不存（**fail-closed**）：没有归属就没有可清除的那一份，
    /// 而不是先落进一个无主目录再指望 store 拒掉它。
    public static func workExtrasDownloadRequest(
        artifact: WorkExtraDeliveryFileDto, session: PlaybackSessionContext?
    ) -> WorkDownloadRequest? {
        // 同一个 store、同一份清单、同一套 owner 分桶与出口裁决 ⇒ 不为本屏新开第二个存储面
        // （那会多一套要各自写对的清单/权限/清除逻辑）。代价明写在这里：
        // `WorkDownloadRequest.workId` 这个**字段名**说的是作品，而这里装的是**产物 id**
        // （`extra-<workerJobId>-<artifactId>`）；两者格式互不重叠（作品是 `{jobId}:{candidateId}`），
        // 而本屏的「已在本机」只按产物 id 查、不读 19 那一本 `savedWorkIDs`。
        // 另一处已知代价：`WorkDownloadPath.fileName` 的扩展名恒为 `.mp3`（那是作品音频的容器），
        // 分轨 zip / 歌词 json / 歌词视频 mp4 落到本机时**文件名字尾会写错**、字节是对的
        // —— 改它等于改 store 的命名面（不属于本任务可改文件），已登记在交付说明。
        guard session?.owner != nil, let raw = artifact.url?.rawValue,
              let resolved = CovaEnvironment.resolveMediaURL(raw),
              let source = try? AudioURL(https: resolved),
              let artifactID = artifact.id, artifactID.isEmpty == false,
              WorkExtrasPanelFacts.rowIsNameable(artifact) else { return nil }
        return WorkDownloadRequest(
            workId: artifactID,
            title: WorkExtrasPanelFacts.rowLabel(for: artifact.kind),
            artist: nil,
            duration: nil,
            source: source,
            session: session ?? .unauthenticated
        )
    }

    /// 点「保存到本机」：同源取件 → 校验非空 → 落 Documents → 行转「已在本机」。
    ///
    /// 「先取完、校验非空，再上屏」（§7 末段）：非 0 字节与截断拒绝已经钉在
    /// `WorkDownloadStore.performSave` 里（`.emptyDownload` / `.truncated`），所以这里
    /// **不**自己写文件、也**不**在成功之前改行态 —— 落盘没成而屏上先说「已在本机」就是虚报。
    public func saveWorkExtraArtifact(artifactID: String) async {
        guard let artifact = workExtras.files.first(where: { $0.id == artifactID }),
              workExtras.savingArtifactIDs.contains(artifactID) == false,
              let context = await workExtrasPlaybackSession() else { return }
        guard let request = Self.workExtrasDownloadRequest(artifact: artifact, session: context)
        else {
            // 地址读不出去（缺 url / 形状不合格）：回落 + 行内那一句，不打一次明知会失败的出站。
            workExtras.rowMessages[artifactID] = WorkExtrasCopy.fileNotFetched
            return
        }
        workExtras.savingArtifactIDs.insert(artifactID)
        workExtras.rowMessages[artifactID] = nil
        defer { workExtras.savingArtifactIDs.remove(artifactID) }
        switch await workDownloads.save(request) {
        case .success(let entry):
            // 盘上事实优先：以 store 回来的条目 id 记账，而不是拿请求里那个字符串自证。
            workExtras.savedArtifactIDs.insert(entry.workId)
        case .failure(let error):
            workExtras.savedArtifactIDs.remove(artifactID)
            workExtras.rowMessages[artifactID] = Self.workExtrasSaveFailureText(error)
        }
    }

    /// 已在本机的再点一次 = 删除本机文件（19 §3.E 同一条腿，二次确认 Dialog 在视图侧）。
    public func removeSavedWorkExtraArtifact(artifactID: String) async {
        guard let owner = await workExtrasPlaybackSession()?.owner else { return }
        if await workDownloads.remove(workId: artifactID, owner: owner) {
            workExtras.savedArtifactIDs.remove(artifactID)
            workExtras.rowMessages[artifactID] = nil
        } else {
            // 「删掉了」与「盘上还在」是两句话：后者不许报成功（store 的 `remove` 就是为此存在，
            // 本层不覆写它的口径）。
            workExtras.rowMessages[artifactID] = WorkExtrasCopy.fileNotFetched
        }
    }

    /// 刷新「已在本机」标记（事实源 = 盘上文件存在且非 0 字节，见 `WorkDownloadStore.entries`）。
    ///
    /// 只扫本屏快照里有的那些产物：清单会随别处的保存变长，本屏只关心"这一行的文件在不在"。
    public func refreshWorkExtrasSavedMarks() async {
        guard let owner = await workExtrasPlaybackSession()?.owner else {
            workExtras.savedArtifactIDs = []
            return
        }
        let present = Set(workExtras.files.compactMap(\.id))
        var saved = Set<String>()
        for entry in await workDownloads.entries(owner: owner) where present.contains(entry.workId) {
            saved.insert(entry.workId)
        }
        workExtras.savedArtifactIDs = saved
    }

    /// 登出/换号：这一屏的账整本作废（D5/D8/D9）。
    ///
    /// 本机文件**不在这里删** —— 那一份归 `AppSession.resetWorkDownloads(owner:)`（19 那条腿）
    /// 统一清；同一个 store 只许有一个清除点，两处各删一份迟早会删错人。
    public func clearWorkExtras() {
        workExtras = WorkExtrasState()
    }

    /// 取件的失败话术（§4 最后两行，且**只有**这两行）。
    ///
    /// `ENOSPC` ⇒ 「空间不够了，清一清再试」；其余（非 ENOSPC 的写失败、`hostRejected`、
    /// 空文件、截断、坏状态码）⇒ 「这个文件没取到，重试」。为什么把非 ENOSPC 的写失败也算进
    /// "没取到"：从用户的座位上那是同一个结果 —— 文件不在本机、下一步还是重试；
    /// §8 的清单里没有第三句，硬造一句不如收进已有的那一句。
    static func workExtrasSaveFailureText(_ error: PlayerError) -> String {
        if case .writeFailed(let code) = error, code == ENOSPC { return WorkExtrasCopy.noSpace }
        return WorkExtrasCopy.fileNotFetched
    }

    /// 凭证快照（owner 分桶与 generation 作废都靠它）。读不出来 = `nil` ⇒ **不做**，不猜身份。
    ///
    /// 19 与 20 的同名辅助都是 `private`（`StudioCreateFlow.swift:280`、`WorksListFlow.swift:666`），
    /// 跨文件够不到；动它们的可见性就是改别人正在编辑的文件 ⇒ 这里各写一份，三处判据逐字一致。
    private func workExtrasPlaybackSession() async -> PlaybackSessionContext? {
        guard let snapshot = try? await auth.currentSession() else { return nil }
        return PlaybackSessionContext(owner: snapshot.principal, generation: snapshot.generation)
    }
}
