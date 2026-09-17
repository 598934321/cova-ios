import Foundation

/// 网络出口守卫（D10）：全 App 只允许 `https://covalink.cn` 的 HTTPS API。
///
/// 本类型是**纯逻辑**（仅依赖 Foundation），可在 iOS 与 macOS 同时编译；
/// 任何平台条件编译都被门禁整类禁止（见 `Scripts/check.sh` 3/8 不变量）。
public enum CovaEnvironment {
    /// 唯一生产出口。禁止指向 staging、私网或本地 provider 网关（127.0.0.1:3110）。
    public static let apiBaseURL = URL(string: "https://covalink.cn")!

    /// 唯一允许的默认 HTTPS 端口。
    public static let apiPort = 443

    /// 出站 URL 的 fail-closed 判定：任一条不满足即拒绝。
    ///
    /// 拒绝面：非 `https`、无 host、私网/环回/链路本地/内网域名、host 非生产 host、
    /// 显式非 443 端口（含 3110 provider 网关）。
    public static func isProductionOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        guard !isNonPublicHost(host) else { return false }
        guard host == apiBaseURL.host()?.lowercased() else { return false }
        guard url.port == nil || url.port == apiPort else { return false }
        return true
    }

    /// 相对路径 + 查询项 → 生产 origin 下的绝对 URL。
    ///
    /// 任何可能改写 host 的输入（绝对 URL、协议相对路径、内嵌 `?`/`#`）一律返回 `nil`，
    /// 使「出口唯一」在构造层就无法被绕过。
    public static func makeAPIURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        guard !path.contains("://") else { return nil }
        guard !path.contains("?") && !path.contains("#") else { return nil }
        var components = URLComponents()
        components.scheme = apiBaseURL.scheme
        components.host = apiBaseURL.host()
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, isProductionOrigin(url) else { return nil }
        return url
    }

    /// 私网 / 环回 / 链路本地 / 内网域名判定。`internal` 仅为可测性（`@testable import`）。
    static func isNonPublicHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") {
            if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
                return true
            }
            return false
        }
        let labels = host.split(separator: ".")
        guard labels.count == 4 else { return false }
        let octets = labels.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }
}
