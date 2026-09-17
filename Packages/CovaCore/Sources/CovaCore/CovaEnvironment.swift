import Foundation

public enum CovaEnvironment {
    public static let apiBaseURL = URL(string: "https://covalink.cn")!

    public static func isProductionOrigin(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host() else { return false }
        guard host == apiBaseURL.host() else { return false }
        guard url.port == nil || url.port == 443 else { return false }
        return true
    }
}
