import CovaCore
import XCTest

/// 09 §3-I 补充制作进度条的映射（纯逻辑）。
///
/// 这批用例守的是三件**谎报风险**最高的事：
/// ① 出现条件只能钉在契约给的两个状态上（多画一格 = 发明）；
/// ② 界面上不得出现英文**态名**（§8 明令），逐状态 × 逐 job 态 × 逐载荷全组合扫；
/// ③ 数字只能说它说得起的东西：**没有** `workflowState` ⇒ 不许填满、不许印百分比
///    （印了等于声称 §3-I 的 `fullMediaReady` 已到，而那个字段确实不在契约里）；
///    **有** `workflowState` ⇒ 反而是"不许**不**填满"—— 五组都收口时还不肯填满，
///    就是把已经测到的进度藏起来（这正是 E5 那条旧主张犯的错，见下）。
///
/// ### 本文件被更正的两条（旧前提被线上数据否证）
/// · `testBarNeverClaimsCompleteInsideTheWindow` 原写「契约没有进度字段 ⇒ 条不许填满」。
///   2026-09-24 只读 GET `…/sessions/:id` 证明 `session.workflowState` 就是进度字段
///   （`{"completedSteps":[6 项],"activeStep":"demo","summaries":{…},"updatedAt":"…"}`），
///   旧版读不到它是因为 `StudioSessionDto` **没建模那个键**。⇒ 改写成
///   `testOnlyARealTerminalWorkflowCanFillTheBar`：条件仍然严，但方向反过来了。
/// · `testNoContractStatusNameEverReachesTheSurface` 原用「不含任何拉丁字母」当代理，
///   那在我们自己产文案时是等价的；左列现在可以放**后端自己写的那句中文**，
///   而实测那句里就有 `Demo`（`"…正在制作两个 Demo。"`），09 §10 的固定文案清单里也写着
///   `Demo 就绪` ⇒ "无拉丁字母"不再等价。改成两条各自成立的断言：
///   我们自己产的面**仍然**零拉丁字母，后端原文那一面**只允许**是 fixture 里那两句之一，
///   而契约原文（12 态 / 6 态 / 14 个环节键）在任何一面上都不许出现。
final class DeliveryProgressPlannerTests: XCTestCase {
    /// 「拉丁字母」这一件事自己说清楚，不依赖 `CharacterSet.asciiLetters`（该成员在本机 SDK 不存在）。
    private static let latinLetters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )

    /// 测试里用到的**后端原文句子**集合（逐字取自 2026-09-24 线上载荷 / 其同形改写）。
    /// 界面上允许出现拉丁字母的**只有**这些 —— 它们是后端写给人看的中文句子，不是态名。
    private static let serverSentences: Set<String> = [
        "一步计划已锁定，正在制作两个 Demo。",
        "完整音频正在恢复中。",
    ]

    /// 线上那份载荷（E5 的起因：旧版断言"契约里没有进度字段"时，这个键就在响应里）。
    private static let capturedPayload = """
    {"completedSteps":["collect","lyrics","style","musician","brief","breakdown"],\
    "activeStep":"demo",\
    "summaries":{"demo":"一步计划已锁定，正在制作两个 Demo。"},\
    "updatedAt":"2026-09-24T13:09:14.778Z"}
    """

    private func state(_ json: String?) -> StudioWorkflowStateDto? {
        json.flatMap { StudioWorkflowStateDto.decode(fromJSONString: $0) }
    }

    private func progress(
        _ status: OneStepPlanStatus = .deliveryPreparing,
        job: GenerationJobStatus? = .processing,
        json: String?
    ) -> DeliveryProgress? {
        DeliveryProgressPlanner.progress(
            planStatus: status, jobStatus: job, workflow: state(json)
        )
    }

    func testBarAppearsOnlyInDeliveryWindow() {
        for status in OneStepPlanStatus.allCases {
            let produced = DeliveryProgressPlanner.progress(planStatus: status, jobStatus: .processing)
            if status == .deliveryPreparing || status == .rehydrating {
                XCTAssertNotNil(produced, "\(status) 应有进度条（09 §9 行 8/9）")
            } else {
                XCTAssertNil(produced, "\(status) 不得出现进度条（09 §3-I 只给了两个状态）")
            }
        }
    }

    /// 同一条**不随 E5 变**：`workflowState` 只回答「走到哪一格」，不回答「该不该画这条」——
    /// §3-I 的收起条件 `fullMediaReady` 仍然没有任何字段撑着（NEEDS-25 收窄后的那一句）。
    func testWorkflowStateNeverWidensTheBarAppearanceRule() {
        let real = state(Self.capturedPayload)
        XCTAssertNotNil(real, "载荷本身要能解出来，否则这条扫的是空气")
        for status in OneStepPlanStatus.allCases {
            let produced = DeliveryProgressPlanner.progress(
                planStatus: status, jobStatus: .processing, workflow: real
            )
            XCTAssertEqual(
                produced != nil, DeliveryProgressPlanner.isInDeliveryWindow(status),
                "\(status) 时带真进度也不得改变出现条件"
            )
        }
    }

    /// 前进序列一步一格、序号唯一；四态「不在这条路上」⇒ 没有位置。
    func testMilestonesFollowTheDocumentedForwardPath() {
        let mapped = DeliveryProgressPlanner.forwardPath.compactMap {
            DeliveryProgressPlanner.milestone(for: $0)
        }
        XCTAssertEqual(mapped, Array(1...8), "里程碑必须等于契约状态在前进序列里的位置")
        XCTAssertEqual(Set(mapped).count, 8, "两个状态撞在同一格 = 假装它们等价")

        for status in [OneStepPlanStatus.patching, .manualRecovery, .retryableFailure, .archived] {
            XCTAssertNil(DeliveryProgressPlanner.milestone(for: status), "\(status) 不是「走到哪一步」")
        }
    }

    /// 取消：文案换「本轮已停止」（§9 末注把这条表现层语义指定给 I 条），里程碑原地不动。
    func testCancelledJobChangesOnlyTheLabel() {
        let running = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .processing
        )
        let stopped = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .cancelled
        )
        XCTAssertEqual(stopped?.label, DeliveryProgressPlanner.stoppedLabel)
        XCTAssertEqual(stopped?.milestone, running?.milestone)
        XCTAssertEqual(stopped?.totalMilestones, running?.totalMilestones)
    }

    /// `rehydrating` 的文案是 §9 行 9 指定的「正在恢复完整音频」，不是 §3-I 的那句。
    /// **有真进度时也让位给它**：五组词表里没有任何词能表达"冷存储文件正在回来"，换掉是丢信息。
    func testRehydratingUsesTheRecoveryPhrase() {
        XCTAssertEqual(
            DeliveryProgressPlanner.progress(planStatus: .rehydrating, jobStatus: .processing)?.label,
            DeliveryProgressPlanner.rehydratingLabel
        )
        XCTAssertEqual(
            DeliveryProgressPlanner.progress(planStatus: .deliveryPreparing, jobStatus: nil)?.label,
            DeliveryProgressPlanner.preparingLabel,
            "job 态取不到也要有 §3-I 的那句固定文案"
        )
        XCTAssertEqual(
            progress(.rehydrating, json: Self.capturedPayload)?.label,
            DeliveryProgressPlanner.rehydratingLabel,
            "§9 行 9 逐字钉了 rehydrating 的条内文案 ⇒ 实测阶梯不得把它盖掉"
        )
    }

    /// VoiceOver 标签按 §7 的形态：句读 + 阶段。
    ///
    /// 更正说明：这条**原名**要守的是「不印百分比」，理由是"我们没有百分比"。
    /// 现在**有**百分比了（真进度下右列印 `60%`，见 `testCapturedRealPayloadDrivesTheLadder`），
    /// 而 §7 要念的形态仍然是「第 N 步，共 M 步」⇒ 断言换成它真正表达的那件事：
    /// **读出来的是步数而不是百分号**，且分母是**真**分母（5 而不是自称的 9）。
    func testVoiceOverLabelCarriesStepNotPercentage() {
        let degraded = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .processing
        )
        XCTAssertEqual(degraded?.voiceOverLabel, "补充制作中，第 7 步，共 9 步")
        XCTAssertFalse(degraded?.voiceOverLabel.contains("%") ?? true)
        XCTAssertEqual(degraded?.stepText, "7/9")

        let real = progress(json: Self.capturedPayload)
        XCTAssertEqual(
            real?.voiceOverLabel,
            "一步计划已锁定，正在制作两个 Demo。第 4 步，共 5 步",
            "分母必须是真分母 5；后端那句自带句号 ⇒ 不再补「，」"
        )
        XCTAssertFalse(real?.voiceOverLabel.contains("%") ?? true)
    }

    // MARK: 词表（09 §3-I 用哪套中文）

    /// 五组标签逐字钉住 —— 出处是 web `DeliveryPanel.tutorialStepsFromWorkflow`
    /// （spec §3-I 只钉了三条**状态文案**，没钉里程碑标签集）。顺带钉住那四步不属于任何一组。
    func testLadderUsesTheWebFiveGroupChineseVocabulary() {
        XCTAssertEqual(
            StudioWorkflowLadder.definitions.map(\.label),
            ["确认需求", "整理曲风与氛围", "确认计划", "歌曲制作", "完成与交付"]
        )
        XCTAssertEqual(StudioWorkflowLadder.stepOrder.count, 14)
        XCTAssertEqual(StudioWorkflowLadder.definitions.count, 5)
        let grouped = Set(StudioWorkflowLadder.definitions.flatMap(\.stepKeys))
        XCTAssertEqual(
            Set(StudioWorkflowLadder.stepOrder).subtracting(grouped).sorted(),
            ["arrange", "mix", "studio", "vocalist"],
            "人工制作四步在 5 组口径里不占键位 —— 它们只通过「走过了」影响进度"
        )
    }

    // MARK: E5 —— 真进度

    /// **线上那份载荷 ⇒ 界面上该是什么**（逐字段核）：焦点第 4 组「歌曲制作」进行中、
    /// 已完成 3/5 ⇒ 60%、左列用后端自己写的那句话。
    ///
    /// `breakdown` 已在 `completedSteps` 里而 `demo` 是 active ⇒ 第 4 组**不能**算收口
    /// （active 优先于 completed，web 同一条），这是"照抄规则、不简化"的证据。
    func testCapturedRealPayloadDrivesTheLadder() throws {
        let groups = try XCTUnwrap(StudioWorkflowLadder.groups(in: state(Self.capturedPayload)))
        XCTAssertEqual(groups.map(\.status), [.completed, .completed, .completed, .active, .pending])

        let shown = try XCTUnwrap(progress(json: Self.capturedPayload))
        XCTAssertEqual(shown.label, "一步计划已锁定，正在制作两个 Demo。", "有后端那句话就用它")
        XCTAssertEqual(shown.milestone, 4, "焦点是第 4 组「歌曲制作」（1 起算）")
        XCTAssertEqual(shown.totalMilestones, 5, "分母 = 交付组数，不是自称的 9")
        XCTAssertEqual(shown.completedMilestones, 3, "只有 3 组真的收口（第 4 组进行中不算）")
        XCTAssertEqual(shown.percent, 60)
        XCTAssertEqual(shown.fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(shown.stepText, "4/5")
        XCTAssertEqual(shown.rightColumnText, "60%", "§3-I 右列本来就是「百分比」位，有数据就印它")
        XCTAssertFalse(StudioWorkflowLadder.isTerminal(groups))
    }

    /// **五组全收口 ⇒ 终态**：填满、印 100%、左列「已完成」（web 在同一条件下的那一句）。
    /// 旧版「永不填满」就是被这条否证的 —— 数据说走完了，界面上却还指着 7/9。
    func testEveryGroupCompletedIsTheTerminalState() throws {
        let terminal = """
        {"completedSteps":["collect","lyrics","style","musician","brief","breakdown","demo",\
        "delivery","extras","copyright"],"activeStep":null,\
        "summaries":{"copyright":"版权申请材料已提交。"}}
        """
        let groups = try XCTUnwrap(StudioWorkflowLadder.groups(in: state(terminal)))
        XCTAssertTrue(StudioWorkflowLadder.isTerminal(groups))

        let shown = try XCTUnwrap(progress(json: terminal))
        XCTAssertEqual(shown.label, StudioWorkflowLadder.terminalLabel, "五组收口 ⇒ 说「已完成」")
        XCTAssertEqual(shown.milestone, 5)
        XCTAssertEqual(shown.totalMilestones, 5)
        XCTAssertEqual(shown.completedMilestones, 5)
        XCTAssertEqual(shown.fraction, 1.0, accuracy: 0.0001, "五组收口还不填满 = 藏起已测到的进度")
        XCTAssertEqual(shown.rightColumnText, "100%")
        XCTAssertEqual(shown.voiceOverLabel, "已完成，第 5 步，共 5 步")
    }

    /// **微妙的那一半**：组内一个键都没被报过完成，仅凭「焦点严格越过该组最大位置」就收口。
    /// 后端有些组的键从来不进 `completedSteps`，没有这半条规则那些组会永远亮着未完成。
    func testActiveIndexPastAGroupKeysCompletesThatGroup() throws {
        // 焦点在 mix（第 12 格），而只有 collect 被报过完成。
        let past = """
        {"completedSteps":["collect"],"activeStep":"mix"}
        """
        let groups = try XCTUnwrap(StudioWorkflowLadder.groups(in: state(past)))
        XCTAssertEqual(groups[1].status, .completed, "整理曲风与氛围(最大位置 3)：12 > 3 ⇒ 收口，键一个都没报过")
        XCTAssertEqual(groups[2].status, .completed, "确认计划(4)")
        XCTAssertEqual(groups[3].status, .completed, "歌曲制作(6)")
        XCTAssertEqual(groups[4].status, .pending, "完成与交付(最大 13)：12 > 13 为假 ⇒ 不许收口")
        XCTAssertFalse(groups.contains { $0.status == .active }, "mix 不属于任何一组")

        let shown = try XCTUnwrap(progress(json: past))
        XCTAssertEqual(shown.completedMilestones, 4)
        XCTAssertEqual(shown.percent, 80)
        XCTAssertEqual(
            shown.label, "歌曲制作",
            "没有 active 组 ⇒ 焦点落在最后一个已完成组（web 的 focusIndex 同一条规则）"
        )
        // 该规则反过来也成立：焦点刚越过 style(2) 时，只有 collect 那组的 max=0 被越过。
        let early = try XCTUnwrap(
            StudioWorkflowLadder.groups(in: state(#"{"activeStep":"style"}"#))
        )
        XCTAssertEqual(early.map(\.status), [.completed, .active, .pending, .pending, .pending])
    }

    /// **未知键不得发明进度**（两种失败都要拦）：
    /// · 一个认识的信号都没有 ⇒ 整条退化成今天的样子（不是 0/5，也不是 5/5）；
    /// · 未知键混在真载荷里 ⇒ 数字与不含它时**逐字节相同**；
    /// · 未知 `activeStep` ⇒ 「走过了」这条规则**不触发**（不能当成"走到末尾"把后面几组扫空）。
    func testUnknownStepKeysNeverFabricateProgress() throws {
        // ① 全是未知键
        let onlyUnknown = #"{"completedSteps":["quantum","tunneling"],"activeStep":"timemachine"}"#
        XCTAssertNil(StudioWorkflowLadder.groups(in: state(onlyUnknown)), "不认识 ⇒ 不画梯子")
        let degraded = DeliveryProgressPlanner.progress(planStatus: .deliveryPreparing, jobStatus: .processing)
        let fromGarbage = progress(json: onlyUnknown)
        XCTAssertEqual(fromGarbage, degraded, "全是未知键时必须与「没有 workflowState」逐字节相同")
        XCTAssertEqual(fromGarbage?.rightColumnText, "7/9")
        XCTAssertNil(fromGarbage?.percent, "不认识的东西不许被印成百分比")

        // ② 未知键混进真载荷 ⇒ 结果不变
        let withUnknown = """
        {"completedSteps":["collect","lyrics","style","musician","brief","breakdown","quantum"],\
        "activeStep":"demo","summaries":{"demo":"一步计划已锁定，正在制作两个 Demo。"}}
        """
        XCTAssertEqual(
            progress(json: withUnknown), progress(json: Self.capturedPayload),
            "多一个不认识的完成键不得改变任何数字"
        )

        // ③ 未知 activeStep：collect 报过完成 ⇒ 只有第 1 组收口，其余一律 pending
        let unknownActive = try XCTUnwrap(
            StudioWorkflowLadder.groups(in: state(#"{"completedSteps":["collect"],"activeStep":"quantum"}"#))
        )
        XCTAssertEqual(unknownActive.map(\.status), [.completed, .pending, .pending, .pending, .pending])
    }

    /// **没有 / 空 / 解不出的 workflowState ⇒ 今天的行为一字不变**（E5 的回归面）。
    /// 三个入口（nil、`""`、坏 JSON、空对象）与旧的 2 参调用点**逐个比相等**，
    /// 而不是只比"看起来没炸"。
    func testMissingOrUnreadableWorkflowStateKeepsTodaysOutput() {
        let unusable: [String?] = [nil, "", "   ", "null", "[]", "not json", "{}", "{bad", #"{"activeStep":3}"#]
        for status in [OneStepPlanStatus.deliveryPreparing, .rehydrating] {
            let baseline = DeliveryProgressPlanner.progress(planStatus: status, jobStatus: .processing)
            let baselineLabel = status == .rehydrating
                ? DeliveryProgressPlanner.rehydratingLabel : DeliveryProgressPlanner.preparingLabel
            XCTAssertEqual(baseline?.label, baselineLabel, "退化路的左列还是 §3-I/§9 那两句")
            for json in unusable {
                let shown = progress(status, json: json)
                XCTAssertEqual(shown, baseline, "「\(json ?? "<nil>")」不该改变任何展示量")
                XCTAssertNil(shown?.percent, "没有实测阶梯就没有百分比")
                XCTAssertEqual(shown?.rightColumnText, shown?.stepText, "右列退回阶段计数")
            }
            let collecting = progress(status, job: nil, json: nil)
            XCTAssertEqual(collecting?.totalMilestones, 9)
        }
    }

    /// 取消 / 真进度：文案换「本轮已停止」，数字仍然说实测的那一套（不后退也不前进）。
    func testCancelledJobKeepsTheRealNumbers() {
        let running = progress(json: Self.capturedPayload)
        let stopped = progress(job: .cancelled, json: Self.capturedPayload)
        XCTAssertEqual(stopped?.label, DeliveryProgressPlanner.stoppedLabel)
        XCTAssertEqual(stopped?.milestone, running?.milestone)
        XCTAssertEqual(stopped?.totalMilestones, running?.totalMilestones)
        XCTAssertEqual(stopped?.completedMilestones, running?.completedMilestones)
        XCTAssertEqual(stopped?.percent, running?.percent)
    }

    // MARK: 填满与谎报（本文件被更正的那两条）

    /// **改写自** `testBarNeverClaimsCompleteInsideTheWindow`。
    /// 旧断言「窗口内永不填满」的前提是"契约没有进度字段"，2026-09-24 的
    /// `session.workflowState` 把它否证了 ⇒ 现在两半都钉：
    /// · 没有实测阶梯 ⇒ 仍然**不许**填满（`fullMediaReady` 确实不在契约里，旧结论这一半还成立）；
    /// · 有实测阶梯 ⇒ 只有五组全收口才允许填满（走不到收口时就停在已完成的那一格）。
    func testOnlyARealTerminalWorkflowCanFillTheBar() throws {
        for status in [OneStepPlanStatus.deliveryPreparing, .rehydrating] {
            let degraded = try XCTUnwrap(
                DeliveryProgressPlanner.progress(planStatus: status, jobStatus: .processing)
            )
            XCTAssertLessThan(degraded.fraction, 1.0, "\(status) 时无真进度，填满就是谎报已交付")
            XCTAssertLessThan(degraded.milestone, degraded.totalMilestones)
            XCTAssertGreaterThan(degraded.fraction, 0)

            let running = try XCTUnwrap(progress(status, json: Self.capturedPayload))
            XCTAssertLessThan(running.fraction, 1.0, "\(status) 时五组还没走完 ⇒ 不许满")
            XCTAssertEqual(running.fraction, 0.6, accuracy: 0.0001)
        }
        let terminal = try XCTUnwrap(progress(json: """
        {"completedSteps":["collect","lyrics","style","musician","brief","breakdown","demo",\
        "delivery","extras","copyright"],"activeStep":null}
        """))
        XCTAssertEqual(terminal.fraction, 1.0, accuracy: 0.0001, "实测走完了还不填满 = 把进度藏起来")
        XCTAssertEqual(terminal.percent, 100)
    }

    /// **改写自** `testNoContractStatusNameEverReachesTheSurface`（原用"零拉丁字母"当代理）。
    /// 12 × 7 × 6 载荷全组合扫三个展示面，三条各自成立：
    /// · 契约原文（态名 / 环节键）在任何一面上都不许出现；
    /// · **我们自己产**的文案零拉丁字母；
    /// · 允许带拉丁字母的那一面，必须**逐字等于**后端原文句子之一（不是"随便一句带英文的话"）。
    func testNoContractStatusNameEverReachesTheSurface() {
        let payloads: [String?] = [
            nil,
            Self.capturedPayload,
            #"{"completedSteps":["collect"],"activeStep":"mix"}"#,
            #"{"completedSteps":["collect"],"activeStep":"lyrics"}"#,
            #"{"completedSteps":["quantum"],"activeStep":"timemachine"}"#,
            #"{"activeStep":"studio","summaries":{"studio":"正在录音棚录制。"}}"#,
        ]
        let jobStates: [GenerationJobStatus?] = [
            nil, .queued, .submitted, .processing, .succeeded, .failed, .cancelled,
        ]
        for status in OneStepPlanStatus.allCases {
            for job in jobStates {
                for json in payloads {
                    guard let progress = DeliveryProgressPlanner.progress(
                        planStatus: status, jobStatus: job, workflow: state(json)
                    ) else { continue }
                    let faces = [
                        progress.label, progress.stepText, progress.rightColumnText, progress.voiceOverLabel,
                    ]
                    // 左列单独钉：要么**整面**零拉丁字母（我们自己产的），要么逐字等于后端原文句子之一。
                    let labelHasLatin = progress.label.rangeOfCharacter(from: Self.latinLetters) != nil
                    XCTAssertTrue(
                        !labelHasLatin || Self.serverSentences.contains(progress.label),
                        "左列出现了不属于后端原文的拉丁字母：\(progress.label)"
                    )
                    for face in faces {
                        XCTAssertFalse(
                            face.contains(status.rawValue),
                            "英文态名泄漏：\(face) ← \(status)/\(String(describing: job))/\(json ?? "nil")"
                        )
                        if let job { XCTAssertFalse(face.contains(job.rawValue)) }
                        for key in StudioWorkflowLadder.stepOrder {
                            XCTAssertFalse(
                                face.contains(key),
                                "环节键原文泄漏：\(face) ← \(key)/\(json ?? "nil")"
                            )
                        }
                        // 把后端原文句子整句抠掉之后，**剩下的是我们自己拼的每一寸文字** ⇒ 必须零拉丁字母。
                        // （直接对整面判"零拉丁"不再等价：VoiceOver 那面是"原句 + 第 N 步"的复合串。）
                        var ours = face
                        for sentence in Self.serverSentences {
                            ours = ours.replacingOccurrences(of: sentence, with: "")
                        }
                        XCTAssertNil(
                            ours.rangeOfCharacter(from: Self.latinLetters),
                            "自产文案里出现了拉丁字母（英文态名泄漏）：\(face) ← \(status)/\(String(describing: job))/\(json ?? "nil")"
                        )
                    }
                }
            }
        }
    }
}
