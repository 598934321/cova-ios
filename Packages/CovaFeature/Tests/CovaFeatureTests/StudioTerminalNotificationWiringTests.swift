import CovaCore
import Foundation
import UserNotifications
import XCTest

@testable import CovaFeature

/// 18 真终态通知的**调用点**（`StudioNotifier.reconcileTerminal`）。
///
/// 这一批评的不是文案（`CovaCore/StudioNotificationPlanTests` 已经逐条钉过），而是
/// 「规划器的那份真文案到底有没有被交给系统、以及交几次」。缺陷的原始形状正是
/// **有规划器无调用点** ⇒ 用户收到的只有 `plans/start` 预约的那条 30 分钟兜底串。
///
/// 三件系统动作（读授权 / 投递 / 撤销）全部注入 ⇒ **本文件一次都没有碰
/// `UNUserNotificationCenter.current()`**：真横幅在这台机器上看不见，
/// 而"什么时候才允许投"是判定，判定可以判对错。
///
/// 落盘的账本用**独立 suite**（`UUID` 命名）—— 不碰 `UserDefaults.standard`，
/// 免得用例之间、以及与真机上的用户数据之间互相污染。
@MainActor
final class StudioTerminalNotificationWiringTests: XCTestCase {

    /// 记录每一次系统侧动作。**不做 actor 也不加锁**：`XCTAssertEqual` 的实参是
    /// nonisolated autoclosure，actor 属性在断言里读不到；本文件每条用例都是
    /// 「发一条腿 → await 到完成 → 才看账」，没有并发窗口（与 `StudioLyricsServiceTests`
    /// 里 `StubTransport` 同一口径，`nonisolated(unsafe)` 只是把这一层前提写明）。
    ///
    /// `deliver` **不做任何过滤**：用例要钉的就是"判定层有没有在不该投的时候投"，
    /// 所以 recorder 收到什么就记什么 —— 它自己替判定层把关等于把缺陷藏回账上。
    private final class Recorder: @unchecked Sendable {
        nonisolated(unsafe) var delivered: [StudioNotificationPlan] = []
        nonisolated(unsafe) var revoked: [String] = []
        var authorization: StudioNotificationAuthorization = .allowed
        var deliveryWorks = true

        var system: StudioNotificationSystem {
            StudioNotificationSystem(
                authorization: { [weak self] in
                    self?.authorization ?? .allowed
                },
                deliver: { [weak self] plan in
                    guard let self, self.deliveryWorks else { return false }
                    self.delivered.append(plan)
                    return true
                },
                revoke: { [weak self] jobID in
                    self?.revoked.append(jobID)
                }
            )
        }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "cova.notification.tests.\(UUID().uuidString)")!
    }

    private func candidate(id: String, title: String, status: String, url: String? = nil)
        -> [String: Any] {
        var dict: [String: Any] = ["id": id, "title": title, "audioDownloadStatus": status]
        if let url { dict["audioUrl"] = url }
        return dict
    }

    private func job(id: String = "job-1", status: GenerationJobStatus = .succeeded,
                     candidates: [[String: Any]]) -> GenerationJobDto {
        let metadata = try! JSONSerialization.data(withJSONObject: ["candidates": candidates])
        let payload: [String: Any] = [
            "id": id, "status": status.rawValue, "sessionId": "s-1", "costCredits": 30,
            "metadata": String(data: metadata, encoding: .utf8)!,
        ]
        return try! JSONDecoder().decode(
            GenerationJobDto.self, from: try! JSONSerialization.data(withJSONObject: payload)
        )
    }

    private var readyPair: [[String: Any]] {
        [
            candidate(id: "c1", title: "夏夜回声", status: "ready", url: "https://cdn.example/a?sig=SECRET"),
            candidate(id: "c2", title: "晚风站台", status: "ready", url: "https://cdn.example/b?sig=SECRET"),
        ]
    }

    private var pendingPair: [[String: Any]] {
        [
            candidate(id: "c1", title: "夏夜回声", status: "ready", url: "https://cdn.example/a"),
            candidate(id: "c2", title: "晚风站台", status: "pending"),
        ]
    }

    /// 一条**两版全失败**的载荷：D7 的终局，18 §8 明令照发。
    private var failedPair: [[String: Any]] {
        [
            candidate(id: "c1", title: "A", status: "failed"),
            candidate(id: "c2", title: "B", status: "failed"),
        ]
    }

    private func reconcile(
        _ subject: GenerationJobDto?, owner: String? = "u-1", sessionID: String = "s-1",
        watchedInFlight: Bool = true, in store: UserDefaults, using recorder: Recorder
    ) async -> StudioTerminalNotificationOutcome {
        await StudioNotifier.reconcileTerminal(
            job: subject, sessionID: sessionID, planCardID: "p-1", owner: owner,
            watchedInFlight: watchedInFlight, defaults: store, system: recorder.system
        )
    }

    // MARK: 调用点存在，且交出去的是真文案

    /// 核心探针：双就绪 + 已授权 + 本机在等 ⇒ 系统收到的是**带两个真歌名**的那一条，
    /// 而不是兜底串。这一条一旦红 = 回到"有规划器无调用点"。
    func testTerminalRoundDeliversTheRealCopyOnce() async {
        let recorder = Recorder()
        let store = defaults()
        let outcome = await reconcile(job(candidates: readyPair), in: store, using: recorder)
        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(recorder.delivered.count, 1)
        // 用 `first` 而不是 `[0]`：探针要能**红**，不能把测试进程一起带崩（崩了后面的用例全不跑）。
        guard let plan = recorder.delivered.first else { return XCTFail("没有交给系统的投递") }
        XCTAssertEqual(plan.title, "你的歌做好了")
        XCTAssertEqual(plan.body, "「夏夜回声」「晚风站台」两个版本都完成了")
        XCTAssertNotEqual(plan.body, StudioNotifier.fallbackBody, "兜底串不得冒充终态文案")
        XCTAssertEqual(plan.identifier, "cova-generation-job-1")
        XCTAssertEqual(plan.userInfo["sessionId"], "s-1")
        XCTAssertEqual(plan.userInfo["jobId"], "job-1")
        XCTAssertEqual(plan.userInfo["planCardId"], "p-1")
        XCTAssertEqual(plan.userInfo["source"], "local-notification")
        // 同标识的 `add` 本身就是替换那条兜底预约 ⇒ 不再额外撤一次（撤了会把刚排上的这条也摘掉）。
        XCTAssertTrue(recorder.revoked.isEmpty, "投递这一条不得同时撤自己")
    }

    /// 失败也发（18 §8 待裁决 6 选的是"是"），而且用的是失败那一档自己的话术。
    func testBothFailedRoundDeliversItsOwnCopy() async {
        let recorder = Recorder()
        let outcome = await reconcile(
            job(status: .failed, candidates: failedPair), in: defaults(), using: recorder
        )
        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(recorder.delivered.map(\.body), ["这次两个版本都没做成"])
    }

    /// D7：一就绪一未定 ⇒ 一次都不投，也**不撤**那条兜底预约（本轮还没结束，预约是对的）。
    func testNotSettledRoundTouchesNeitherTheSystemNorTheBooking() async {
        let recorder = Recorder()
        let store = defaults()
        let outcome = await reconcile(job(candidates: pendingPair), in: store, using: recorder)
        XCTAssertEqual(outcome, .notTerminal)
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertTrue(recorder.revoked.isEmpty)
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0)
    }

    // MARK: 幂等：同一 (会话, 任务) 至多一次

    /// 重复轮询 / 反复进屏 ⇒ 只投一次。**第二次换一个新的 `UserDefaults` 实例**，
    /// 钉的是"账落在盘上"而不是"活在内存里"（18 §7 的已发记录要活过冷启动）。
    func testRepeatedObservationDeliversExactlyOnceAcrossInstances() async {
        let recorder = Recorder()
        let suite = "cova.notification.tests.shared.\(UUID().uuidString)"
        let subject = job(candidates: readyPair)
        let first = await reconcile(subject, in: UserDefaults(suiteName: suite)!, using: recorder)
        let second = await reconcile(subject, in: UserDefaults(suiteName: suite)!, using: recorder)
        // 第三次换一份**空账**的盘 ⇒ 这是一次全新的观察，允许再投：用例据此证明去重靠的是
        // 落盘的账，而不是进程内的偶然状态。
        let third = await reconcile(subject, in: defaults(), using: recorder)
        XCTAssertEqual(first, .scheduled)
        XCTAssertEqual(second, .alreadyScheduled)
        XCTAssertEqual(third, .scheduled)
        XCTAssertEqual(recorder.delivered.count, 2)
    }

    /// 换号不得继承上一个账号的"已通知"（D5/D8/D22 的同一族隔离）。
    func testNextOwnerIsNotSuppressedByThePreviousAccountClaim() async {
        let recorder = Recorder()
        let store = defaults()
        let subject = job(candidates: readyPair)
        let first = await reconcile(subject, owner: "u-1", in: store, using: recorder)
        let second = await reconcile(subject, owner: "u-2", in: store, using: recorder)
        XCTAssertEqual(first, .scheduled)
        XCTAssertEqual(second, .scheduled)
        XCTAssertEqual(recorder.delivered.count, 2)
    }

    /// 登出那一步的「清已发记录」：清完之后同一个任务在新一次观察里可以重排。
    /// （这里只钉**不需要系统**的那一半 —— `revokeAll` 的另两句要问系统，在单测里没有产物。）
    func testClearClaimsWipesTheLedgerForTheNextOwner() async {
        let recorder = Recorder()
        let store = defaults()
        let subject = job(candidates: readyPair)
        let first = await reconcile(subject, in: store, using: recorder)
        XCTAssertEqual(first, .scheduled)
        StudioNotifier.clearClaims(in: store)
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0)
        let afterClear = await reconcile(subject, in: store, using: recorder)
        XCTAssertEqual(afterClear, .scheduled)
    }

    /// 账本被写坏（类型不对）时**不得**把通知永久闷掉：读不回就当没有账。
    func testCorruptedClaimsStoreFallsBackToAnEmptyLedger() async {
        let recorder = Recorder()
        let store = defaults()
        store.set(["p:u-1": 1], forKey: StudioNotifier.claimsKey)
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0)
        let outcome = await reconcile(job(candidates: readyPair), in: store, using: recorder)
        XCTAssertEqual(outcome, .scheduled, "读不回账不得等于永久闷掉通知")
    }

    // MARK: 授权诚实 / 迟到诚实

    /// 用户关了系统通知 ⇒ **一次都不投**，也不谎称排上；返回值就是没排上的那一档。
    func testDeniedAuthorizationNeverReachesDelivery() async {
        let recorder = Recorder()
        recorder.authorization = .denied
        let store = defaults()
        let outcome = await reconcile(job(candidates: readyPair), in: store, using: recorder)
        XCTAssertEqual(outcome, .authorizationDenied)
        XCTAssertEqual(outcome.userLabel, "系统通知没开启，改由会话页承担")
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0, "没投出去的不许记账")
    }

    /// `notDetermined` 同样不投：这里不是索权的时机。
    func testUndecidedAuthorizationNeverReachesDelivery() async {
        let recorder = Recorder()
        recorder.authorization = .undecided
        let outcome = await reconcile(job(candidates: readyPair), in: defaults(), using: recorder)
        XCTAssertEqual(outcome, .authorizationUndecided)
        XCTAssertTrue(recorder.delivered.isEmpty)
    }

    /// 授权三档的映射本身（含 `provisional`/`ephemeral` 算可投 —— 与 15 的「已开启」同一口径）。
    /// 只构造枚举常量，不碰 `UNUserNotificationCenter.current()`。
    func testAuthorizationMappingMatchesTheSettingsVocabulary() {
        XCTAssertEqual(StudioNotifier.authorization(for: .authorized), .allowed)
        XCTAssertEqual(StudioNotifier.authorization(for: .provisional), .allowed)
        XCTAssertEqual(StudioNotifier.authorization(for: .ephemeral), .allowed)
        XCTAssertEqual(StudioNotifier.authorization(for: .denied), .denied)
        XCTAssertEqual(StudioNotifier.authorization(for: .notDetermined), .undecided)
    }

    /// 迟到的对账（App 被杀后重启、本机没有在等的这一路）⇒ 不投**迟到**的通知，
    /// 但那条未定名的兜底预约必须撤（用户此刻正在看结果，18 §8 并发冲突）。
    func testLateObservationDeliversNothingButRevokesTheStaleBooking() async {
        let recorder = Recorder()
        let store = defaults()
        let outcome = await reconcile(
            job(candidates: readyPair), watchedInFlight: false, in: store, using: recorder
        )
        XCTAssertEqual(outcome, .lateObservation)
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertEqual(recorder.revoked, ["job-1"])
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0)
    }

    /// 授权被关的那一档也要撤兜底（同上一条的理由：终态已经看到了）。
    func testDeniedAuthorizationStillRevokesTheStaleBooking() async {
        let recorder = Recorder()
        recorder.authorization = .denied
        _ = await reconcile(job(candidates: readyPair), in: defaults(), using: recorder)
        XCTAssertEqual(recorder.revoked, ["job-1"])
    }

    // MARK: 真投递失败不许谎称成功

    /// 系统没收下 ⇒ 回 `.systemRefused`、账回退，下一次观察还有一次机会。
    /// 这条钉的是"不许把没发生的事记成已发"——占着账就等于把这一轮唯一的机会烧掉。
    func testFailedDeliveryReleasesTheClaimAndStillAllowsARetry() async {
        let recorder = Recorder()
        recorder.deliveryWorks = false
        let store = defaults()
        let subject = job(candidates: readyPair)
        let refused = await reconcile(subject, in: store, using: recorder)
        XCTAssertEqual(refused, .systemRefused)
        XCTAssertEqual(StudioNotifier.loadClaims(in: store).count, 0)
        XCTAssertTrue(recorder.delivered.isEmpty)

        recorder.deliveryWorks = true
        let retried = await reconcile(subject, in: store, using: recorder)
        XCTAssertEqual(retried, .scheduled)
        XCTAssertEqual(recorder.delivered.count, 1)
    }

    // MARK: 载荷卫生（这条腿自己的那一遍）

    /// **交给系统的那一份**里不许有 URL / 签名串 / 金额 / 诱导词（AGENTS 硬边界 3 + D12）。
    func testDeliveredPayloadHasNoUrlsTokensOrMoney() async {
        let recorder = Recorder()
        _ = await reconcile(job(candidates: readyPair), in: defaults(), using: recorder)
        XCTAssertEqual(recorder.delivered.count, 1)
        guard let plan = recorder.delivered.first else { return XCTFail("没有交给系统的投递") }
        let blob = ([plan.title, plan.body] + plan.userInfo.values + [plan.identifier])
            .joined(separator: "|")
        for forbidden in [
            "http", "covalink", "SECRET", "audioUrl", "token", "co 币", "余额", "价格", "30",
            "充值", "购买", "升级", "下载", "点击查看", "领取",
        ] {
            XCTAssertFalse(blob.contains(forbidden), "交出去的载荷里不得有 \(forbidden)：\(blob)")
        }
    }
}
