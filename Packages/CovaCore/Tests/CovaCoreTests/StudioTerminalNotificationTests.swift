import CovaCore
import XCTest

/// 18 真终态那条腿的判据层与幂等账（`StudioTerminalNotification` / `StudioNotificationClaimLedger`）。
///
/// 这一族用例存在的理由只有一句：`StudioNotificationPlanner` 早就算好了真文案，
/// 但**没有任何一处调用它** ⇒ 用户收到的只有 `plans/start` 时预约的那条 30 分钟兜底串。
/// 所以这里钉的不是"文案对不对"（那归 `StudioNotificationPlanTests`），而是
/// **"在什么事实面前才允许把真文案交给系统，以及一次还是两次"**。
///
/// 夹具走 `JSONSerialization` 造真实响应形态（与 `StudioNotificationPlanTests` 同一口径，
/// 不用 DTO 的内部 memberwise 构造器）。
final class StudioTerminalNotificationTests: XCTestCase {
    private func candidate(id: String, title: String, status: String, url: String? = nil)
        -> [String: Any] {
        var dict: [String: Any] = ["id": id, "title": title, "audioDownloadStatus": status]
        if let url { dict["audioUrl"] = url }
        return dict
    }

    private func job(
        id: String = "job-1", status: GenerationJobStatus = .succeeded, candidates: [[String: Any]]
    ) -> GenerationJobDto {
        let metadata = try! JSONSerialization.data(withJSONObject: ["candidates": candidates])
        let payload: [String: Any] = [
            "id": id,
            "status": status.rawValue,
            "sessionId": "s-1",
            "costCredits": 30,
            "metadata": String(data: metadata, encoding: .utf8)!,
        ]
        return try! JSONDecoder().decode(
            GenerationJobDto.self, from: try! JSONSerialization.data(withJSONObject: payload)
        )
    }

    private let readyPair = [
        [
            "id": "c1", "title": "夏夜回声", "audioDownloadStatus": "ready",
            "audioUrl": "https://cdn.example/a.m4a?sig=SECRET",
        ] as [String: Any],
        [
            "id": "c2", "title": "晚风站台", "audioDownloadStatus": "ready",
            "audioUrl": "https://cdn.example/b.m4a?sig=SECRET",
        ] as [String: Any],
    ]

    private func decide(
        _ job: GenerationJobDto?,
        owner: String? = "u-1",
        sessionID: String? = "s-1",
        authorization: StudioNotificationAuthorization = .allowed,
        watchedInFlight: Bool = true,
        ledger: inout StudioNotificationClaimLedger
    ) -> StudioTerminalNotification.Decision {
        StudioTerminalNotification.decide(
            job: job, sessionID: sessionID, planCardID: "p-1", owner: owner,
            authorization: authorization, watchedInFlight: watchedInFlight, ledger: &ledger
        )
    }

    // MARK: 真终态才交给系统

    /// 核心探针：双就绪 + 已授权 + 本机在等 ⇒ 交出去的是**带两个真歌名的正文**，
    /// 不是那条未定名的兜底串。这条一旦红，就退回"有规划器没调用点"那个缺陷。
    func testTerminalRoundHandsTheRealNamedCopyToTheSystem() {
        var ledger = StudioNotificationClaimLedger()
        let decision = decide(job(candidates: readyPair), ledger: &ledger)
        XCTAssertEqual(decision.outcome, .scheduled)
        XCTAssertEqual(decision.plan?.body, "「夏夜回声」「晚风站台」两个版本都完成了")
        XCTAssertEqual(decision.plan?.title, "你的歌做好了")
        XCTAssertNotEqual(decision.plan?.body, "两个版本应该好了，去 Cova 听", "兜底串不得冒充终态文案")
        XCTAssertEqual(decision.plan?.identifier, "cova-generation-job-1")
        XCTAssertEqual(ledger.count, 1)
    }

    /// 两版全失败**照发**（18 §8「失败也要通知」），且这是真文案而不是兜底句。
    func testBothFailedRoundStillHandsOverItsOwnCopy() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(status: .failed, candidates: [
            candidate(id: "c1", title: "A", status: "failed"),
            candidate(id: "c2", title: "B", status: "failed"),
        ])
        let decision = decide(subject, ledger: &ledger)
        XCTAssertEqual(decision.outcome, .scheduled)
        XCTAssertEqual(decision.plan?.body, "这次两个版本都没做成")
    }

    /// D7 取证项：`succeeded` 但前两个候选没都 settled ⇒ **不发**，而且**不记账**
    /// （记了账就等于把"没发生的一次"烧掉了这一轮唯一的机会）。
    func testNotBothSettledNeitherSchedulesNorClaims() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: [
            candidate(id: "c1", title: "A", status: "ready", url: "https://cdn.example/a"),
            candidate(id: "c2", title: "B", status: "pending"),
        ])
        let decision = decide(subject, ledger: &ledger)
        XCTAssertEqual(decision.outcome, .notTerminal)
        XCTAssertNil(decision.plan)
        XCTAssertFalse(decision.shouldRevokeFallback)   // 还没结束 ⇒ 那条兜底预约得留着
        XCTAssertEqual(ledger.count, 0)
    }

    /// 没有 job 载荷（会话里还没有任务）同样是"没终态"，不是"载荷坏了"。
    func testMissingJobIsNotTerminalRatherThanUnusable() {
        var ledger = StudioNotificationClaimLedger()
        XCTAssertEqual(decide(nil, ledger: &ledger).outcome, .notTerminal)
        XCTAssertEqual(ledger.count, 0)
    }

    /// 任务号为空 ⇒ 没有可以作为幂等键的东西。
    func testTerminalWithoutJobIDIsReportedAsUnusablePayload() {
        var ledger = StudioNotificationClaimLedger()
        let blank = job(id: "   ", candidates: readyPair)
        let decision = decide(blank, ledger: &ledger)
        XCTAssertEqual(decision.outcome, .payloadUnusable)
        XCTAssertEqual(ledger.count, 0)
    }

    // MARK: 幂等：同一 (会话, 任务) 至多一次

    /// 重复轮询 / 反复进屏 ⇒ 第二次只有"已经通知过了"，且**不再交出去**。
    func testSecondObservationOfTheSameJobIsNotScheduledAgain() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: readyPair)
        XCTAssertEqual(decide(subject, ledger: &ledger).outcome, .scheduled)
        let again = decide(subject, ledger: &ledger)
        XCTAssertEqual(again.outcome, .alreadyScheduled)
        XCTAssertEqual(again.plan?.body, "「夏夜回声」「晚风站台」两个版本都完成了")
        XCTAssertEqual(ledger.count, 1, "十次观察也只有一条账")
        for _ in 0..<8 { XCTAssertEqual(decide(subject, ledger: &ledger).outcome, .alreadyScheduled) }
        XCTAssertEqual(ledger.count, 1)
    }

    /// 换一轮制作（新任务号）⇒ 是新的一次，该再通知一次（18 §8「每轮各一条，按 jobId 去重」）。
    func testNewJobInSameSessionIsANewNotification() {
        var ledger = StudioNotificationClaimLedger()
        XCTAssertEqual(decide(job(id: "job-1", candidates: readyPair), ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(decide(job(id: "job-2", candidates: readyPair), ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(ledger.count, 2)
    }

    /// owner 隔离（D5/D8/D22）：同一个任务号挂在**另一个人**名下时，不得继承上一个账号的"已通知"。
    func testClaimDoesNotSuppressAnotherOwner() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: readyPair)
        XCTAssertEqual(decide(subject, owner: "u-1", ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(decide(subject, owner: "u-2", ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(ledger.count, 2)
    }

    /// 同一 owner 下不同会话的同一个任务号是两条独立事实（条目含会话号）。
    func testSameJobUnderDifferentSessionsAreSeparateEntries() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: readyPair)
        XCTAssertEqual(decide(subject, sessionID: "s-1", ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(decide(subject, sessionID: "s-2", ledger: &ledger).outcome, .scheduled)
        XCTAssertTrue(ledger.isClaimed(owner: "u-1", sessionID: "s-1", jobID: "job-1"))
        XCTAssertFalse(ledger.isClaimed(owner: "u-1", sessionID: "s-3", jobID: "job-1"))
    }

    /// 登出/换号：整桶作废只影响那一个身份。
    func testResetOwnerDropsOnlyThatOwner() {
        var ledger = StudioNotificationClaimLedger()
        ledger.claim(owner: "u-1", sessionID: "s-1", jobID: "job-1")
        ledger.claim(owner: "u-2", sessionID: "s-1", jobID: "job-1")
        ledger.reset(owner: "u-1")
        XCTAssertFalse(ledger.isClaimed(owner: "u-1", sessionID: "s-1", jobID: "job-1"))
        XCTAssertTrue(ledger.isClaimed(owner: "u-2", sessionID: "s-1", jobID: "job-1"))
        ledger.removeAll()
        XCTAssertEqual(ledger.count, 0)
    }

    /// 落盘形态必须能原样读回来（「本地已发记录」要活过冷启动，否则重进 09 就是第二条通知）。
    func testRecordsRoundTripThroughPersistence() {
        var ledger = StudioNotificationClaimLedger()
        ledger.claim(owner: "u-1", sessionID: "s-1", jobID: "job-1")
        ledger.claim(owner: "  ", sessionID: "s-2", jobID: "job-2")   // 无身份那一档另开一桶
        let restored = StudioNotificationClaimLedger(ledger.records)
        XCTAssertEqual(restored, ledger)
        XCTAssertNotEqual(
            StudioNotificationClaimLedger().bucketNames, restored.bucketNames,
            "夹具得真的产生内容（否则这条断言恒真）"
        )
    }

    /// 无身份（游客/恢复中）与真身份分桶：真身份前缀 `p:` ⇒ 任何 principalId 都撞不上匿名桶。
    func testAnonymousBucketCannotCollideWithAnyOwner() {
        XCTAssertEqual(StudioNotificationClaimLedger.bucket(for: nil), "-")
        XCTAssertEqual(StudioNotificationClaimLedger.bucket(for: "   "), "-")
        XCTAssertEqual(StudioNotificationClaimLedger.bucket(for: "u-1"), "p:u-1")
        XCTAssertEqual(StudioNotificationClaimLedger.bucket(for: "-"), "p:-")
    }

    /// 任务号是幂等键的主体：空任务号**拒绝记账**，而不是落进一条看不见的账把这一轮烧掉。
    func testBlankJobIDIsNotClaimable() {
        var ledger = StudioNotificationClaimLedger()
        XCTAssertFalse(ledger.claim(owner: "u-1", sessionID: "s-1", jobID: "  "))
        XCTAssertNil(StudioNotificationClaimLedger.entry(sessionID: "s-1", jobID: ""))
        XCTAssertEqual(ledger.count, 0)
        XCTAssertEqual(StudioNotificationClaimLedger.entry(sessionID: nil, jobID: "job-1"), "|job-1")
    }

    // MARK: 授权诚实 / 迟到诚实

    /// 授权被关：没排上就是没排上，**不记已发账**（用户之后开了通知、还在等的那一轮才还有机会）。
    func testDeniedAuthorizationDoesNotScheduleNorClaim() {
        var ledger = StudioNotificationClaimLedger()
        let decision = decide(job(candidates: readyPair), authorization: .denied, ledger: &ledger)
        XCTAssertEqual(decision.outcome, .authorizationDenied)
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(
            decision.shouldRevokeFallback,
            "用户正看着终态 ⇒ 那条未定名的兜底预约必须撤，不能几小时后补一句「应该好了」"
        )
    }

    /// `notDetermined` 不算"可以投"：不在这里弹权限框（spec 只在 09 开始制作成功后索权）。
    func testUndecidedAuthorizationDoesNotSchedule() {
        var ledger = StudioNotificationClaimLedger()
        XCTAssertEqual(
            decide(job(candidates: readyPair), authorization: .undecided, ledger: &ledger).outcome,
            .authorizationUndecided
        )
        XCTAssertEqual(ledger.count, 0)
    }

    /// 迟到的对账（App 被杀后重启、本机没有在等的这一路）⇒ **不发迟到的通知**，也照样撤兜底。
    func testLateObservationIsNotScheduled() {
        var ledger = StudioNotificationClaimLedger()
        let decision = decide(job(candidates: readyPair), watchedInFlight: false, ledger: &ledger)
        XCTAssertEqual(decision.outcome, .lateObservation)
        XCTAssertEqual(ledger.count, 0)
        XCTAssertTrue(decision.shouldRevokeFallback)
    }

    /// 顺序判据：已经通知过的时候，报的是"这一轮已经通知过了"，
    /// 而不是只在第一次才成立的"系统没开启"（否则同一件事在两次观察里说成两样）。
    func testAlreadyClaimedOutranksAuthorizationAndLateness() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: readyPair)
        XCTAssertEqual(decide(subject, ledger: &ledger).outcome, .scheduled)
        XCTAssertEqual(
            decide(subject, authorization: .denied, watchedInFlight: false, ledger: &ledger).outcome,
            .alreadyScheduled
        )
    }

    /// 真投递失败 ⇒ 账必须回退（占着账的是"没发生的事"，回退后下一轮观察还有一次机会）。
    func testReleaseAfterFailedDeliveryRestoresTheChance() {
        var ledger = StudioNotificationClaimLedger()
        let subject = job(candidates: readyPair)
        XCTAssertEqual(decide(subject, ledger: &ledger).outcome, .scheduled)
        guard let jobID = decide(subject, ledger: &ledger).plan?.jobID else { return XCTFail("应有任务号") }
        ledger.release(owner: "u-1", sessionID: "s-1", jobID: jobID)
        XCTAssertEqual(ledger.count, 0)
        var afterRelease = ledger
        XCTAssertEqual(decide(subject, ledger: &afterRelease).outcome, .scheduled)
    }

    /// 载荷卫生再钉一次：**交出去的那一份**里不许有 URL / 签名串 / 金额（AGENTS 硬边界 3 + D12）。
    func testHandedOverPayloadCarriesNoUrlsOrMoney() {
        var ledger = StudioNotificationClaimLedger()
        guard let plan = decide(job(candidates: readyPair), ledger: &ledger).plan else {
            return XCTFail("应有计划")
        }
        let blob = ([plan.title, plan.body] + plan.userInfo.values + [plan.identifier])
            .joined(separator: "|")
        for forbidden in ["http", "SECRET", "audioUrl", "co 币", "余额", "价格", "30", "充值", "下载"] {
            XCTAssertFalse(blob.contains(forbidden), "交出去的载荷里不得有 \(forbidden)：\(blob)")
        }
        XCTAssertEqual(plan.userInfo["source"], "local-notification")
    }

    // MARK: 「屏上无英文态名」判据

    /// 逐 case 钉：八档结局的上屏标签全是中文，且不露枚举名 / wire 值。
    func testEveryOutcomeSurfacesChineseLabelAndNeverTheEnumName() {
        for outcome in StudioTerminalNotificationOutcome.allCases {
            XCTAssertFalse(
                outcome.userLabel.isEmpty, "\(outcome) 没有中文标签"
            )
            XCTAssertNotEqual(outcome.userLabel, outcome.rawValue)
            XCTAssertFalse(
                outcome.userLabel.contains(outcome.rawValue),
                "\(outcome) 的上屏串露出了 wire 值：\(outcome.userLabel)"
            )
            XCTAssertFalse(
                outcome.userLabel.rangeOfCharacter(
                    from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
                ) != nil,
                "\(outcome) 的上屏串里不该有拉丁字母：\(outcome.userLabel)"
            )
        }
        // 加一档必须同时加中文（`allCases` 数一下，防止"新 case 沿用别人的话术"）。
        XCTAssertEqual(StudioTerminalNotificationOutcome.allCases.count, 8)
    }

    /// 结局之间不得共用同一句话（同一张表里两个 case 一个词 = 用户分不清是哪件事）。
    func testOutcomeLabelsAreAllDistinct() {
        let labels = StudioTerminalNotificationOutcome.allCases.map(\.userLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    /// 授权三档的形状（`allowed` 含 provisional/ephemeral 那一档由薄壳映射，用例钉词表本身）。
    func testAuthorizationVocabularyHasThreeRungs() {
        XCTAssertEqual(StudioNotificationAuthorization.allCases, [.allowed, .denied, .undecided])
    }
}

private extension StudioNotificationClaimLedger {
    var bucketNames: Set<String> { Set(records.keys) }
}
