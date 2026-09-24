import CovaFeature
import SwiftUI
import UserNotifications

@main
struct CovaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CovaRootView()
        }
    }
}

/// 18 的委托挂载点：通知代理必须在启动时就位，
/// 否则「前台不弹 + 点按按 sessionId 路由」这两条行为只在冷启动后第一次生效。
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let studioNotifications = StudioNotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = studioNotifications
        return true
    }
}
