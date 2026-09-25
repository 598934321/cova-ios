import CovaCore
import Foundation
import UserNotifications

/// 18 本地通知的**系统侧薄壳**（判定与文案全在 `CovaCore` 的纯规划器里，那部分有测试）。
///
/// spec 的四条时机规则逐条落在这里：
/// · **只在** 09 的「开始制作」成功之后索权；被拒之后不在 App 内反复索、也不自建开关
///   （15 设置页只回显系统状态）；
/// · 真终态（D7：前两个候选都 settled）到达时**把规划器算出的那份真文案交给系统** ——
///   `reconcileTerminal(...)` 就是那唯一一句调用点（此前规划器有、文案有，却没人调用，
///   用户收到的只有下面那条兜底串）；
/// · App 在前台时**不弹**横幅（`StudioNotificationDelegate.willPresent` 返回空展示项），
///   而"回前台才看到早已终态"那一档连排都不排（判据层的 `lateObservation`）；
///   真终态一旦看到，那条待发的兜底通知就撤掉；
/// · 登出 ⇒ 撤销全部待发 + 清角标 + 清已发记录。
@MainActor
public enum StudioNotifier {
    /// 点按通知后广播给 UI 的路由事件（userInfo 里的 `sessionId` 是唯一可信来源）。
    public static let didTap = Notification.Name("cova.studioNotification.tap")

    /// 兜底通知的正文。**措辞待用户裁决**（18 §待裁决 1）：这里先按 spec 列出的候选实现，
    /// 并把"待裁决"写在代码里，而不是等裁决前悄悄上一版自己的话术。
    public static let fallbackBody = "两个版本应该好了，去 Cova 听"

    public static func requestPermissionAfterPlanStart() async -> Bool {
        switch await authorization() {
        case .allowed:
            return true
        case .denied:
            return false          // 不再索权：反复弹系统权限框是骚扰，也是 spec 明令禁止的
        case .undecided:
            // 这是全 App 唯一的索权时刻（09「开始制作」成功之后，有明确收益的那一刻）。
            return (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.badge, .sound])) ?? false
        }
    }

    public static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// 排产成功后登记一条「约 N 分钟」的兜底通知（上限 30 分钟）；真终态到达时撤销。
    /// 载荷只带路由字段 —— 没有任何 URL、音频地址、token、余额或扣费数字。
    public static func scheduleFallback(
        sessionID: String, jobID: String, planCardID: String?, afterMinutes: Double
    ) async {
        let minutes = min(max(afterMinutes, 1), 30)
        let content = UNMutableNotificationContent()
        content.title = StudioNotificationPlan.fixedTitle
        content.body = fallbackBody
        var userInfo: [String: String] = [
            StudioNotificationPlan.sessionKey: sessionID,
            StudioNotificationPlan.jobKey: jobID,
            StudioNotificationPlan.sourceKey: StudioNotificationPlan.sourceValue,
        ]
        if let planCardID { userInfo[StudioNotificationPlan.planCardKey] = planCardID }
        content.userInfo = userInfo
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: minutes * 60, repeats: false)
        let identifier = StudioNotificationPlanner.identifier(jobID: jobID)
        rememberScheduled(identifier)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    // MARK: 真终态通知的调用面（18 §7 调度口径第 1 条 / 第 2 条后半句）

    /// 「已把这条排过」的本地记录（18 §7 幂等 + §8 登出清账）。owner 分桶的账本本身在
    /// `CovaCore/StudioTerminalNotification.swift`（那一份有确定性用例），这里只负责落盘与读取。
    static let claimsKey = "cova.terminalNotification.claims"

    /// 09 每拿到一份**权威载荷**时调这一句（进屏 / 下拉对账 / 计划卡帧收口）。
    ///
    /// 它是 `StudioNotificationPlanner` 唯一的调用点 —— 之前规划器有、文案有、幂等标识有，
    /// 但没有任何一处把真终态文案交给系统，用户收到的只有那条 30 分钟兜底串。
    /// 返回值是「这一次到底排没排上」的事实（`userLabel` 是中文），**不**谎称已投递。
    @discardableResult
    public static func reconcileTerminal(
        job: GenerationJobDto?,
        sessionID: String,
        planCardID: String?,
        owner: String?,
        watchedInFlight: Bool
    ) async -> StudioTerminalNotificationOutcome {
        await reconcileTerminal(
            job: job, sessionID: sessionID, planCardID: planCardID, owner: owner,
            watchedInFlight: watchedInFlight, defaults: .standard, system: .live
        )
    }

    /// 同一条腿的可注入形态（用例走这一条）：需要被替换的只有**三件系统动作**，
    /// 判据与账本都是 CovaCore 的纯逻辑。真投递在单元测试里没有可观察的产物（看不见横幅），
    /// 而这里要钉的是"什么时候才允许把真文案交给系统"。
    @discardableResult
    static func reconcileTerminal(
        job: GenerationJobDto?,
        sessionID: String,
        planCardID: String?,
        owner: String?,
        watchedInFlight: Bool,
        defaults: UserDefaults,
        system: StudioNotificationSystem
    ) async -> StudioTerminalNotificationOutcome {
        var ledger = loadClaims(in: defaults)
        let before = ledger
        let decision = StudioTerminalNotification.decide(
            job: job, sessionID: sessionID, planCardID: planCardID, owner: owner,
            authorization: await system.authorization(),
            watchedInFlight: watchedInFlight, ledger: &ledger
        )
        guard decision.outcome == .scheduled else {
            // 真终态已经看到（`plan != nil`）但这一轮不投 ⇒ 那条**未定名的兜底预约**仍必须撤：
            // 用户此刻正在看结果，几小时后弹一句「两个版本应该好了」只是噪音（§8 并发冲突）。
            if decision.shouldRevokeFallback, let jobID = decision.plan?.jobID {
                await system.revoke(jobID)
            }
            if ledger != before { persistClaims(ledger, in: defaults) }
            return decision.outcome
        }
        guard let plan = decision.plan, let jobID = plan.jobID else {
            if ledger != before { persistClaims(ledger, in: defaults) }
            return .payloadUnusable
        }
        guard await system.deliver(plan) else {
            // 系统没收下 ⇒ 账必须回退，否则这一轮再也不有一次机会（占着账的是"没发生的事"）。
            ledger.release(owner: owner, sessionID: sessionID, jobID: jobID)
            persistClaims(ledger, in: defaults)
            return .systemRefused
        }
        rememberScheduled(plan.identifier)
        persistClaims(ledger, in: defaults)
        return .scheduled
    }

    /// 系统授权态收成判据层的三档 —— 「能不能投」的唯一裁决点。
    ///
    /// `provisional`/`ephemeral` 算可投（与 15 设置 E 行的「已开启」同一口径），
    /// `notDetermined` 单列：它意味着**不在这里索权**（spec 钉死只在 09「开始制作」成功后问一次）。
    static func authorization(for status: UNAuthorizationStatus) -> StudioNotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .undecided      // `notDetermined` 与"系统不让问"都归这一档
        }
    }

    static func authorization() async -> StudioNotificationAuthorization {
        authorization(for: await currentAuthorizationStatus())
    }

    /// 立刻投递真终态文案（触发器 `nil` = 延迟 0，spec §7 前台口径）。
    static func deliverTerminalViaSystem(_ plan: StudioNotificationPlan) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.userInfo = plan.userInfo
        let request = UNNotificationRequest(
            identifier: plan.identifier, content: content, trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    static func loadClaims(in defaults: UserDefaults) -> StudioNotificationClaimLedger {
        StudioNotificationClaimLedger(
            (defaults.dictionary(forKey: claimsKey) as? [String: [String]]) ?? [:]
        )
    }

    static func persistClaims(_ ledger: StudioNotificationClaimLedger, in defaults: UserDefaults) {
        defaults.set(ledger.records, forKey: claimsKey)
    }

    /// 真终态到达（或本轮已在前台对账过）⇒ 撤掉待发的那一条，不让它迟到补刀。
    public static func cancel(jobID: String) async {
        let identifier = StudioNotificationPlanner.identifier(jobID: jobID)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        forgetScheduled(identifier)
    }

    /// 我们自己登记过的标识（UserDefaults 里一份清单）。
    /// 为什么要自己记：`UNNotification` 身上没有可直接撤的标识，
    /// 而「登出要清已发记录」这条承诺必须能指到具体 id 才能兑现。
    private static let scheduledKey = "cova.scheduledNotificationIDs"

    static func rememberScheduled(_ identifier: String) {
        var ids = UserDefaults.standard.stringArray(forKey: scheduledKey) ?? []
        if !ids.contains(identifier) { ids.append(identifier) }
        UserDefaults.standard.set(ids, forKey: scheduledKey)
    }

    static func forgetScheduled(_ identifier: String) {
        var ids = UserDefaults.standard.stringArray(forKey: scheduledKey) ?? []
        ids.removeAll { $0 == identifier }
        UserDefaults.standard.set(ids, forKey: scheduledKey)
    }

    /// 登出/换号：撤销全部待发 + 清已发记录 + 角标归零（spec 明令三件都要做）。
    public static func revokeAll(in defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        // 系统侧的"全部"API 名字是 removeAll…，不是 remove…()（后者只有带 identifiers 的重载）。
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
        defaults.removeObject(forKey: scheduledKey)
        // 「已发记录」也在这一并把整本清掉（D8）：留着它，下一个身份在同一轮里
        // 就会被"这一轮已经通知过了"挡掉 —— 那是把上一个账号的事实记到他头上。
        clearClaims(in: defaults)
    }

    /// 清「已发记录」这一步单独成函数：它是登出承诺里**不需要系统**的那一半，
    /// 所以它可以被用例直接钉住（`revokeAll` 的其余两句都要问系统，在单测里没有可观察产物）。
    static func clearClaims(in defaults: UserDefaults) {
        defaults.removeObject(forKey: claimsKey)
    }
}

/// 18 的系统侧三个动作（授权读取 / 投递 / 撤销），抽成一面的理由见 `StudioNotifier` 里
/// 那条可注入的 `reconcileTerminal`：生产走 `.live`，用例注入 recorder。
struct StudioNotificationSystem: Sendable {
    var authorization: @MainActor @Sendable () async -> StudioNotificationAuthorization
    var deliver: @MainActor @Sendable (StudioNotificationPlan) async -> Bool
    var revoke: @MainActor @Sendable (String) async -> Void

    init(
        authorization: @escaping @MainActor @Sendable () async -> StudioNotificationAuthorization,
        deliver: @escaping @MainActor @Sendable (StudioNotificationPlan) async -> Bool,
        revoke: @escaping @MainActor @Sendable (String) async -> Void
    ) {
        self.authorization = authorization
        self.deliver = deliver
        self.revoke = revoke
    }

    /// 生产实现。投递用的标识与那条兜底预约**同一个** ⇒ 同 id 的 `add` 本身就是替换，
    /// 用户不会在一轮里收到两条（spec §7「撤掉预约并发改为即时内容通知」）。
    static let live = StudioNotificationSystem(
        authorization: { await StudioNotifier.authorization() },
        deliver: { plan in await StudioNotifier.deliverTerminalViaSystem(plan) },
        revoke: { jobID in await StudioNotifier.cancel(jobID: jobID) }
    )
}

/// 通知代理：前台不弹、点按只按 `sessionId` 路由（缺失就回落首页，不猜路由）。
///
/// 类本身**不是** `@MainActor`：`UNUserNotificationCenterDelegate` 由系统在其自有队列回调，
/// 把整类钉在主 actor 上会让 conformance 跨隔离（Swift 6 直接拒绝）。需要主 actor 的部分
/// 用 `Task { @MainActor in … }` 显式跳。
public final class StudioNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public override init() { super.init() }

    /// 前台收到 ⇒ 不展示（App 已经在前面了，再弹一次就是重复提示），并撤销该条待发请求。
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let jobID = userInfo[StudioNotificationPlan.jobKey] as? String {
            Task { @MainActor in await StudioNotifier.cancel(jobID: jobID) }
        }
        completionHandler([])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo
        // 先把载荷收成 `[String: String]` 再跳主 actor：`[AnyHashable: Any]` 不是 Sendable，
        // 直接送进 Task 就是把一个可变引用交给另一个隔离域（Swift 6 判数据竞争）。
        var payload: [String: String] = [:]
        for key in [
            StudioNotificationPlan.sessionKey, StudioNotificationPlan.jobKey,
            StudioNotificationPlan.planCardKey, StudioNotificationPlan.candidateKey,
            StudioNotificationPlan.sourceKey,
        ] {
            if let value = raw[key] as? String { payload[key] = value }
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: StudioNotifier.didTap, object: nil, userInfo: payload)
        }
        completionHandler()
    }
}
