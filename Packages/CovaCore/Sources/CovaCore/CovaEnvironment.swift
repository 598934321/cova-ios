import Foundation

public enum CovaEnvironment {
    public static let apiBaseURL = URL(string: "https://covalink.cn")!

    public static func isProductionOrigin(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host() else { return false }
        return host == apiBaseURL.host()
    }
}
