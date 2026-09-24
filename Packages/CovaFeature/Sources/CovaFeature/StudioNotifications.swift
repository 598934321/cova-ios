import CovaCore
import Foundation
import UserNotifications

/// 18 本地通知的**系统侧薄壳**（判定与文案全在 `CovaCore` 的纯规划器里，那部分有测试）。
///
/// spec 的三条时机规则逐条落在这里：
/// · **只在** 09 的「开始制作」成功之后索权；被拒之后不在 App 内反复索、也不自建开关
///   （15 设置页只回显系统状态）；
/// · App 在前台时**不弹**横幅（回前台对账后不发迟到的通知），并把那条待发的兜底通知撤掉；
/// · 登出 ⇒ 撤销全部待发 + 清角标 + 清已发记录。
@MainActor
public enum StudioNotifier {
    /// 点按通知后广播给 UI 的路由事件（userInfo 里的 `sessionId` 是唯一可信来源）。
    public static let didTap = Notification.Name("cova.studioNotification.tap")

    /// 兜底通知的正文。**措辞待用户裁决**（18 §待裁决 1）：这里先按 spec 列出的候选实现，
    /// 并把"待裁决"写在代码里，而不是等裁决前悄悄上一版自己的话术。
    public static let fallbackBody = "两个版本应该好了，去 Cova 听"

    public static func requestPermissionAfterPlanStart() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await currentAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false          // 不再索权：反复弹系统权限框是骚扰，也是 spec 明令禁止的
        default:
            return (try? await center.requestAuthorization(options: [.badge, .sound])) ?? false
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
    public static func revokeAll() async {
        let center = UNUserNotificationCenter.current()
        // 系统侧的"全部"API 名字是 removeAll…，不是 remove…()（后者只有带 identifiers 的重载）。
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
        UserDefaults.standard.removeObject(forKey: scheduledKey)
    }
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
