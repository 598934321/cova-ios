import Foundation

/// 09 §3-I「补充制作进度条」的映射（`design/screens/09-ai-session-detail.md` §3-I / §8 / §9 / §10）。
///
/// ### 更正：本文件旧版的前提是**错的**（E5）
/// 旧版开头写着「契约里**不存在任何进度字段**」，并据此做了两件事：右列固定成 `7/9` 这类阶段计数、
/// 轨道**永不填满**（"填满等于声称完整音频已交付，而那正是没有依据的一件事"）。
/// **那句话不成立。** 2026-09-24 真实账号只读 GET `…/sessions/:id`，返回里
/// `session.workflowState` 就是一个 JSON 字符串（与 `GenerationJobDto.metadata` 同一条形态约定），
/// 实测载荷逐字：
///
/// ```json
/// {"completedSteps":["collect","lyrics","style","musician","brief","breakdown"],
///  "activeStep":"demo",
///  "summaries":{"demo":"一步计划已锁定，正在制作两个 Demo。"},
///  "updatedAt":"2026-09-24T13:09:14.778Z"}
/// ```
///
/// 它给的正是「走到哪一格」。当时读不到，是因为 `StudioSessionDto` **没建模那个键** ——
/// 「客户端没读的字段」被当成了「后端没有的字段」，于是把一个可实现的进度位设计成了永远收不口的死屏。
/// ⇒ 现在：**有 `workflowState` ⇒ 画实测阶梯（含 §3-I 要的百分比，可填满）；
/// 没有 / 解不出 ⇒ 逐字节退回旧的那条路**（§9 行 8/9 的三条固定文案 + `7/9` + 不填满）。
/// 旧那条推断里**仍然成立**的两件事留着：① `fullMediaReady`（§3-I 的收起条件）与字节级进度**确实**
/// 不在契约里 ⇒ 条的**出现/收起**仍只看 `OneStepPlanStatus`；② 英文态名不得外溢（§8）。
/// 缺口收窄后的 NEEDS-25 新框法见 `docs/NEEDS.md`。
///
/// ### 词表：为什么是 web 的那 5 组中文
/// spec §3-I/§9/§10 自己钉的只有三条**状态文案**（`补充制作中` / `正在恢复完整音频` / `本轮已停止`），
/// **没有**钉里程碑标签集。环节词表因此取产品的既有实现 —— web 客户端：
/// · 14 步的**规范顺序**来自 `web/src/app/studio/types.ts` 的 `WORKFLOW_STEPS`
///   （`collect 信息整理, lyrics 歌词, style 曲风分析, musician 音乐人, brief 计划确认,
///   breakdown 计划确认, demo 歌曲制作, delivery 交付, extras 补充制作, arrange 编曲制作,
///   vocalist 歌手录制, studio 录音棚录制, mix 分轨混音, copyright 版权申请`）；
/// · **5 个交付组**与其标签来自同仓 `delivery/DeliveryPanel.tsx` 的 `tutorialStepsFromWorkflow`
///   （那五组正是 §3-I 这块「交付侧进度」的口径），完成规则也照抄，**不简化**（见 `StudioWorkflowLadder`）。
/// 上面那三条 spec 固定文案各有其位：`补充制作中` = 无真进度的退化路；
/// `正在恢复完整音频` = `rehydrating`（**有**真进度时也让它赢，理由见 `resolvedLabel`）；
/// `本轮已停止` = job `cancelled`（同样赢过实测文案）。
public struct DeliveryProgress: Equatable, Sendable {
    /// 左列文案：有真进度 ⇒ 当前交付组的中文名（或后端 `summaries[activeStep]` 那句）；
    /// 否则 ⇒ §3-I / §9 / §9 末注的三条固定串之一。
    public let label: String
    /// 1...totalMilestones —— VoiceOver 的「第 N 步」（web 同一条规则：终态时 N = total）。
    public let milestone: Int
    public let totalMilestones: Int
    /// **已完成**的格数 —— 轨道填充与百分比的分子。
    /// 退化路里它等于 `milestone`（旧版 `fraction` 就是 `milestone/total`，一个字节都不变）；
    /// 真进度里它是「5 组里有几组已收口」，与 `milestone`（焦点在第几步）可以不同：
    /// 实测载荷下焦点是第 4 组（进行中），已完成是 3 组。
    public let completedMilestones: Int
    /// §3-I 右列的**百分比**。**只有**真进度（`workflowState`）支持时才非空 ——
    /// 它度量的是「5 个交付组完成了几组」这个环节阶梯，**不是**字节数也不是耗时。
    /// 退化为契约状态映射时它是 `nil`（那时候没有可印的数字，旧版那句「不印猜出来的数字」仍然对）。
    public let percent: Int?

    /// 轨道填充比例（`color.accent` 那一段）。
    public var fraction: Double { Double(completedMilestones) / Double(totalMilestones) }
    /// 「第几格 / 共几格」的短计数（退化路的右列）。
    public var stepText: String { "\(milestone)/\(totalMilestones)" }
    /// 有实测阶梯时 §3-I 要的那一列。
    public var percentText: String? { percent.map { "\($0)%" } }
    /// 界面右列**该印**的那一格：有百分比 ⇒ 百分比（§3-I 原文就是「右百分比」）；
    /// 没有 ⇒ 阶段计数（今天的样子，不占位、不编数）。
    public var rightColumnText: String { percentText ?? stepText }
    /// VoiceOver（09 §7）：值变化**不**逐帧播报，只在元素被聚焦时读当前值。
    /// 「第 N 步，共 M 步」这个既有句式保留，M 换成**真**分母。
    /// 后端那句话自带句号（实测 `"…两个 Demo。"`）⇒ 句末标点已存在时不再补「，」，
    /// 免得念成「…两个 Demo。，第 4 步」。
    public var voiceOverLabel: String {
        let step = "第 \(milestone) 步，共 \(totalMilestones) 步"
        if label.hasSuffix("。") || label.hasSuffix("！") || label.hasSuffix("？")
            || label.hasSuffix("…") || label.hasSuffix(".") {
            return "\(label)\(step)"
        }
        return "\(label)，\(step)"
    }

    public init(
        label: String,
        milestone: Int,
        totalMilestones: Int,
        completedMilestones: Int? = nil,
        percent: Int? = nil
    ) {
        self.label = label
        self.milestone = milestone
        self.totalMilestones = totalMilestones
        self.completedMilestones = completedMilestones ?? milestone
        self.percent = percent
    }
}

/// 交付组的一个位置状态（与 web `StepStatus` 的可见子集同形；`skipped` 在这里不参与投影）。
public enum StudioWorkflowGroupStatus: String, Equatable, Sendable {
    case pending
    case active
    case completed
}

/// 投影后的**一个**交付组。
public struct StudioWorkflowGroup: Equatable, Sendable {
    public let key: String
    public let label: String
    public let stepKeys: [String]
    public let status: StudioWorkflowGroupStatus

    public init(key: String, label: String, stepKeys: [String], status: StudioWorkflowGroupStatus) {
        self.key = key
        self.label = label
        self.stepKeys = stepKeys
        self.status = status
    }
}

/// 09 §3-I 的**阶梯词表**：14 步规范序 + 5 个交付组 + 把 `workflowState` 投到那 5 格的规则。
///
/// 完成规则**逐条照抄** web `tutorialStepsFromWorkflow`（不简化，因为简化会把两组错标成同一状态）：
/// 1. **active 优先于 completed**：`status = isActive ? active : (isCompleted ? completed : pending)`。
///    实测那份载荷正是这一条在起作用：`breakdown` 已在 `completedSteps` 里、而 `activeStep` 是
///    `demo` —— 同组的另一个键还在做，那一格**不能**算收口（`歌曲制作` = active，不是 completed）。
/// 2. **completed = 组内任一键被后端报过完成 ⇒ 或 焦点位置严格越过该组的最大位置**。
///    后一半是这条规则的全部微妙处：**后端不保证把每一组的键都报进 `completedSteps`** ——
///    没有那半条，一个键没被报过的组会**永远**亮着未完成（进度条从此收不了口）。
///    如实写明：2026-09-24 那份实测载荷里三个早期组的键**恰好都报过**，所以这半条在那份载荷上
///    看不出来 —— 它由用例 `testActiveIndexPastAGroupsKeysCompletesThatGroup`
///    （`{"completedSteps":["collect"],"activeStep":"mix"}`）单独钉住，形状取自 web 同一处规则。
/// 3. 未知键 ⇒ **不给位置**，因此既不能点亮某一格，也不能让「走过去了」这条规则成立
///    （`activeStep` 不认识 ⇒ 这条规则整体不触发，而不是当成 0 或当成末尾）。
///
/// ### 与 web 的一处**有意**不同（写清楚，别将来当成 bug）
/// web 把 `visibleWorkflowSteps`（把 `breakdown` 并进 `brief`、丢掉重复项）之后的**13 项数组**
/// 喂给 `tutorialStepsFromWorkflow`，而数组下标却和 14 项的 `WORKFLOW_STEPS` 序位比大小 ⇒
/// 位置 ≥5 的组在 web 里比"真实步序"少 1（`demo` 是数组第 6 项、词表第 7 项）。
/// 本实现两边都用**同一把 14 格尺**：规则说的是「焦点是否走过该组的键」，
/// 那就必须在同一个索引空间里比。实测载荷下两把尺给出**同一个**答案（`6 > 6` 与 `5 > 6` 都是假），
/// 差别只在 `activeStep ≥ delivery` 时本实现更早把 `歌曲制作` 收成 completed —— 那才是原意的样子。
public enum StudioWorkflowLadder {
    /// 14 步的规范序（`WORKFLOW_STEPS` 的 key 顺序）。**唯一**的位置来源。
    public static let stepOrder: [String] = [
        "collect", "lyrics", "style", "musician", "brief", "breakdown", "demo",
        "delivery", "extras", "arrange", "vocalist", "studio", "mix", "copyright",
    ]

    /// 一个交付组的定义（键 + 中文标签，标签逐字取自 web `tutorialStepsFromWorkflow`）。
    public struct Definition: Equatable, Sendable {
        public let key: String
        public let label: String
        public let stepKeys: [String]
    }

    /// 5 个交付组。**注意**：`arrange/vocalist/studio/mix` 四步不属于任何一组 ——
    /// 那是人工制作子流程（web 的完整阶梯里才逐条显示），5 组口径把它们**并进**
    /// `完成与交付` 的语义里但不列其键。后果照抄：焦点走到 `mix`（第 12 格）时，
    /// 前四组因「走过了」而收口，`完成与交付`（最大位置 13 = `copyright`）仍未收口。
    public static let definitions: [Definition] = [
        Definition(key: "group-collect", label: "确认需求", stepKeys: ["collect"]),
        Definition(key: "group-style", label: "整理曲风与氛围", stepKeys: ["style", "lyrics", "musician"]),
        Definition(key: "group-brief", label: "确认计划", stepKeys: ["brief"]),
        Definition(key: "group-demo", label: "歌曲制作", stepKeys: ["breakdown", "demo"]),
        Definition(key: "group-delivery", label: "完成与交付", stepKeys: ["delivery", "extras", "copyright"]),
    ]

    /// 词表里全部认识的键。
    public static let knownKeys: Set<String> = Set(stepOrder)

    /// 后端报过的完成键里，**我们认识**的那部分。
    /// 不认识的键被丢掉而不是"排到最后"：那才是"不发明位置"（规则 3）。
    static func completedKeys(in state: StudioWorkflowStateDto) -> Set<String> {
        Set(state.completedSteps ?? []).intersection(knownKeys)
    }

    /// `activeStep` → 认识的键（未知 ⇒ `nil`，**不**给位置）。
    static func activeStep(in state: StudioWorkflowStateDto) -> String? {
        guard let step = state.activeStep, knownKeys.contains(step) else { return nil }
        return step
    }

    /// 5 格投影。返回 `nil` 的含义只有一个：**这份载荷不足以宣称任何进度** ⇒ 调用方退回契约状态映射。
    ///
    /// 判据是「一个**认识的**信号都没有」：`completedSteps` 全是未知键 + `activeStep` 缺失或未知。
    /// 那种载荷确实存在（后端加了新环节、客户端词表跟不上），而把它画成「0 步 / 5 步」
    /// 或「全完成」都是把不认识说成认识 —— 退化成今天的样子才是诚实的。
    public static func groups(in state: StudioWorkflowStateDto?) -> [StudioWorkflowGroup]? {
        guard let state else { return nil }
        let completed = completedKeys(in: state)
        let active = activeStep(in: state)
        guard !completed.isEmpty || active != nil else { return nil }
        // 焦点位置：只认识的那一个键才有位置；未知/缺失 ⇒ `nil` ⇒ 「走过了」这条规则**不触发**。
        let activeIndex = active.flatMap { stepOrder.firstIndex(of: $0) }
        return definitions.map { definition in
            let positions = definition.stepKeys.compactMap { stepOrder.firstIndex(of: $0) }
            let isActive = active.map { definition.stepKeys.contains($0) } ?? false
            let anyKeyCompleted = definition.stepKeys.contains { completed.contains($0) }
            // 规则 2 的后半：严格越过该组的最大位置。`positions` 与 `activeIndex` 任缺其一
            // 都**不触发**这条规则（未知键不给位置 = 规则 3），所以不用强制解包去凑一个数。
            let passed: Bool
            if let activeIndex, let groupMax = positions.max() {
                passed = activeIndex > groupMax
            } else {
                passed = false
            }
            let status: StudioWorkflowGroupStatus = isActive ? .active
                : (anyKeyCompleted || passed) ? .completed : .pending
            return StudioWorkflowGroup(
                key: definition.key, label: definition.label,
                stepKeys: definition.stepKeys, status: status
            )
        }
    }

    /// 「第 N 步」的焦点位（照抄 web 的 `focusIndex`）：**第一个** active 组；一个都没有 ⇒
    /// 最后一个 completed 组；两个都没有 ⇒ 第 1 格（`max(0, …)`）。
    public static func focusIndex(of groups: [StudioWorkflowGroup]) -> Int {
        if let active = groups.firstIndex(where: { $0.status == .active }) { return active }
        if let lastCompleted = groups.lastIndex(where: { $0.status == .completed }) { return lastCompleted }
        return 0
    }

    /// 终态 = 5 组全 completed（`completedCount === total`，与 web 同一判据）。
    public static func isTerminal(_ groups: [StudioWorkflowGroup]) -> Bool {
        !groups.isEmpty && groups.allSatisfy { $0.status == .completed }
    }

    /// 全部 5 组收口时界面上说的那句。词表出处同组标签：web `WorkflowProgressInner`
    /// 在 `completedCount === total` 时把当前标签换成 `'已完成'`（**不是**发明 —— 而 spec §3-I
    ///  expects 这时候条已经因 `fullMediaReady` 收起，那个字段契约里没有 ⇒ 见 NEEDS-25）。
    public static let terminalLabel = "已完成"
}

public enum DeliveryProgressPlanner {
    /// 左列三个固定文案（逐字取自 spec §3-I / §9 行 9 / §9 末注，禁改）。
    public static let preparingLabel = "补充制作中"
    public static let rehydratingLabel = "正在恢复完整音频"
    public static let stoppedLabel = "本轮已停止"

    /// 契约里真实存在的**前进序列**（`OneStepPlanStatus` 的正常推进路径）。
    ///
    /// 少掉的四态（`patching` 修改中 / `manual_recovery` 需人工处理 /
    /// `retryable_failure` 未完成可重试 / `archived` 已归档）不是"走到哪一步"，
    /// 是"这一轮不在这条路上" ⇒ 没有位置，返回 `nil`。
    /// **仅**在拿不到 `workflowState` 时用（旧版把它当成唯一的进度源，那是 E5 的错）。
    public static let forwardPath: [OneStepPlanStatus] = [
        .analyzing, .ready, .starting, .generating,
        .mediaStaging, .demosReady, .deliveryPreparing, .rehydrating,
    ]

    /// 退化路的分母 = 前进序列 + **一格完成态**（§3-I 的 `fullMediaReady`，契约确实没给）。
    /// 这一格在退化路上永远不会被指到 ⇒ 无真进度时条**至多**走到 `8/9`（旧版这条仍然成立）。
    public static var totalMilestones: Int { forwardPath.count + 1 }

    /// 状态 → 退化路里程碑（1 起算）；不在前进序列上 ⇒ `nil`。
    public static func milestone(for status: OneStepPlanStatus) -> Int? {
        guard let index = forwardPath.firstIndex(of: status) else { return nil }
        return index + 1
    }

    /// §3-I 的出现条件：**仅** `delivery_preparing` 或 `rehydrating`。
    /// 其余状态（包括两格之间的 `demos_ready` 与之后的 `archived`）一律不出现该条 ——
    /// §9 表把这一条钉在行 8/行 9 的「卡体附加表现」列，多画就是发明。
    /// 这一条**不随 E5 变**：`workflowState` 只回答「走到哪一格」，不回答「该不该画这条」
    /// （§3-I 的收起条件 `fullMediaReady` 仍缺 ⇒ NEEDS-25 收窄后的那一句）。
    public static func isInDeliveryWindow(_ status: OneStepPlanStatus) -> Bool {
        status == .deliveryPreparing || status == .rehydrating
    }

    /// 退化路（无 `workflowState`）：旧版那条映射，**逐字节不变**。
    public static func progress(
        planStatus: OneStepPlanStatus,
        jobStatus: GenerationJobStatus?
    ) -> DeliveryProgress? {
        progress(planStatus: planStatus, jobStatus: jobStatus, workflow: nil)
    }

    /// 算出该画什么。
    ///
    /// · `workflow` 能撑起 5 格阶梯 ⇒ 里程碑/分母/百分比来自**实测**；左列文案见下面的优先级。
    /// · 撑不起 ⇒ 退回 `planStatus` 的固定映射 = 今天界面看到的那个东西，一个字节没变。
    /// · `jobStatus` 仍然**只影响文案**：本轮被取消 ⇒ 「本轮已停止」
    ///   （§9 末注把这条表现层语义指定给 I 条），数字原地不动、不后退也不前进。
    ///
    /// ### 左列文案的优先级（spec 自钉的串 与 实测词表 谁赢）
    /// §3-I 只钉了三条**状态文案**，**没有**钉里程碑标签集 ⇒ 裁决按「谁携带更多信息」：
    /// 1. `cancelled` ⇒ 「本轮已停止」。停止是一个必须盖过进度的话的事实，不能被"走到第 4 格"粉饰。
    /// 2. `rehydrating` ⇒ 「正在恢复完整音频」（§9 行 9 逐字指定的就是这一格的条内文案）。
    ///    五组阶梯里**没有**任何词能表达"冷存储文件正在回来"这件事，换掉等于丢信息。
    /// 3. 有实测阶梯 ⇒ 后端为当前环节写的那句话（`summaries[activeStep]`），否则焦点组的中文标签。
    ///    这一条正是 §3-I 左列在"有真数据"时该显示的东西 —— 「补充制作中」回答不了"哪一步"。
    /// 4. 拿不到真进度 ⇒ §3-I 那句「补充制作中」（今天的行为）。
    public static func progress(
        planStatus: OneStepPlanStatus,
        jobStatus: GenerationJobStatus?,
        workflow: StudioWorkflowStateDto?
    ) -> DeliveryProgress? {
        guard isInDeliveryWindow(planStatus), let fallbackMilestone = milestone(for: planStatus) else {
            return nil
        }
        if let real = realProgress(from: workflow) {
            return DeliveryProgress(
                label: resolvedLabel(for: planStatus, jobStatus: jobStatus, real: real),
                milestone: real.milestone,
                totalMilestones: real.totalMilestones,
                completedMilestones: real.completedMilestones,
                percent: real.percent
            )
        }
        return DeliveryProgress(
            label: resolvedLabel(for: planStatus, jobStatus: jobStatus, real: nil),
            milestone: fallbackMilestone,
            totalMilestones: totalMilestones
        )
    }

    /// 上面那 4 条优先级的实现（一处裁决，两条路径共用 ⇒ 不会各写一份而漂移）。
    private static func resolvedLabel(
        for planStatus: OneStepPlanStatus,
        jobStatus: GenerationJobStatus?,
        real: DeliveryProgress?
    ) -> String {
        if jobStatus == .cancelled { return stoppedLabel }
        if planStatus == .rehydrating { return rehydratingLabel }
        return real?.label ?? preparingLabel
    }

    /// 实测阶梯 → 展示量。**只**做词表已算好的投影，不碰 §3-I 的出现条件。
    /// `nil` = 这份 `workflowState` 撑不起梯子（缺 / 空 / 非法 / 全是未知键）⇒ 调用方退化。
    static func realProgress(from state: StudioWorkflowStateDto?) -> DeliveryProgress? {
        guard let state, let groups = StudioWorkflowLadder.groups(in: state) else { return nil }
        return deliveryProgress(from: state, groups: groups)
    }

    /// 左列文案（web `WorkflowProgressInner` 的同一条优先级）：
    /// ① 5 组全收口 ⇒ 「已完成」；② 后端自己为当前环节写的那句话
    /// （`summaries[activeStep]`，实测 `"一步计划已锁定，正在制作两个 Demo。"`）⇒ 原样用它；
    /// ③ 焦点格的中文标签。`activeStep` 不认识/缺失 ⇒ 不查 `summaries`（不拿猜测的键去取句子）。
    static func label(for groups: [StudioWorkflowGroup], in state: StudioWorkflowStateDto) -> String {
        if StudioWorkflowLadder.isTerminal(groups) { return StudioWorkflowLadder.terminalLabel }
        let focus = groups[StudioWorkflowLadder.focusIndex(of: groups)]
        if let step = StudioWorkflowLadder.activeStep(in: state),
           let sentence = state.summaries?[step], !sentence.isEmpty {
            return sentence
        }
        return focus.label
    }

    /// 把投影结果压成展示三元组（文案 / 「第 N 步」/ 已完成格数 + 百分比）。
    ///
    /// 输入形状由 `realProgress` 唯一决定：`groups(in:)` 要么 `nil`，要么**恰好**
    /// `definitions.count`（= 5）项 ⇒ 这里不写 `total == 0` 那种兜底（那个状态不可达，
    /// 写出来就是一条永远绿着的假守卫）。
    static func deliveryProgress(
        from state: StudioWorkflowStateDto,
        groups: [StudioWorkflowGroup]
    ) -> DeliveryProgress {
        let total = groups.count
        let completed = groups.filter { $0.status == .completed }.count
        // 「第 N 步」= 焦点位 + 1，终态时钳到 total（web: `currentNumber`）。
        let number = completed == total ? total : min(focusNumber(groups), total)
        return DeliveryProgress(
            label: label(for: groups, in: state),
            milestone: number,
            totalMilestones: total,
            completedMilestones: completed,
            // §3-I 的百分比 = **已完成组数**占比（环节阶梯，不是字节/耗时）。四舍五入到整数。
            percent: Int((Double(completed) / Double(total) * 100).rounded())
        )
    }

    private static func focusNumber(_ groups: [StudioWorkflowGroup]) -> Int {
        StudioWorkflowLadder.focusIndex(of: groups) + 1
    }
}
