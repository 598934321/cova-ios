import CovaFeature
import SwiftUI
import UserNotifications

@main
struct CovaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 走查钩子（与 `COVA_PREVIEW_TAB` / `_SHEET` / `_ROUTE` 同一族，**只为模拟器截图存在**）：
    /// `COVA_PREVIEW_DYNTYPE=ax3` 把整棵视图树钉到某个 Dynamic Type 档，13/05/16/12 各屏
    /// 「AX 档改排版」这件事才有可拍的证据（`simctl ui` 只能改外观，改不了系统文字档）。
    /// **未设置时不加这个修饰符** —— 生产沿用系统设置，而不是把字号钉回某个默认值。
    private var previewDynamicType: DynamicTypeSize? {
        guard let raw = ProcessInfo.processInfo.environment["COVA_PREVIEW_DYNTYPE"]
            ?? UserDefaults.standard.string(forKey: "COVA_PREVIEW_DYNTYPE") else { return nil }
        switch raw.lowercased() {
        case "ax1": return .accessibility1
        case "ax2": return .accessibility2
        case "ax3": return .accessibility3
        case "ax4": return .accessibility4
        case "ax5": return .accessibility5
        case "xl": return .extraLarge
        case "xxl": return .extraExtraLarge
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let size = previewDynamicType {
                    CovaRootView().dynamicTypeSize(size)
                } else {
                    CovaRootView()
                }
            }
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
