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
    /// 拒绝面：非 `https`、无 host、带 userinfo（`https://user@…`）、authority 非规范
    /// （如 `:0443`）、私网/环回/链路本地/内网域名、host 非生产 host、显式非 443 端口
    /// （含 3110 provider 网关）。
    public static func isProductionOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard hasCanonicalAuthority(url) else { return false }
        guard !isNonPublicHost(host) else { return false }
        guard host == apiBaseURL.host()?.lowercased() else { return false }
        guard url.port == nil || url.port == apiPort else { return false }
        return true
    }

    /// 相对路径 + 查询项 → 生产 origin 下的绝对 URL。
    ///
    /// 拒绝一切可能造成 authority 逃逸的路径形态：不以 `/` 开头、以 `//` 开头（协议相对）、
    /// 内嵌 `://`、内嵌 `?`/`#`（请求自带查询用 `queryItems`）、含反斜杠（部分解析器视同 `/`）。
    public static func makeAPIURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        guard !path.hasPrefix("//") else { return nil }
        guard !path.contains("://") else { return nil }
        guard !path.contains("?") && !path.contains("#") else { return nil }
        guard !path.contains("\\") else { return nil }
        var components = URLComponents()
        components.scheme = apiBaseURL.scheme
        components.host = apiBaseURL.host()
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, isProductionOrigin(url) else { return nil }
        return url
    }

    /// authority 规范性：`URL` 会把 `:0443` 归一化成 `port == 443`，只有回到原始字符串
    /// 才能发现非规范端口写法；带 `@`（userinfo）同样在此拦下（纵深防御，与 `url.user` 双保险）。
    static func hasCanonicalAuthority(_ url: URL) -> Bool {
        let text = url.absoluteString
        guard let separator = text.range(of: "://") else { return false }
        let authority = text[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("@") else { return false }
        guard let colon = authority.lastIndex(of: ":") else { return true }
        return authority[authority.index(after: colon)...] == String(apiPort)
    }

    /// 私网 / 环回 / 链路本地 / 内网域名 / 非规范数值主机判定。
    /// `internal` 仅为可测性（`@testable import`）。
    static func isNonPublicHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") { return isNonPublicIPv6Host(host) }
        return isNonPublicNumericHost(host)
    }

    /// IPv6（含 IPv4-mapped/embedded 与未指定地址）。
    static func isNonPublicIPv6Host(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        // "::" / "::0" / "0:0:0:0:0:0:0:0"：未指定地址
        if address.split(separator: ":").allSatisfy({ $0.isEmpty || Int($0) == 0 }) { return true }
        if address == "::1" { return true }
        if address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
        // IPv4-mapped / embedded：取最后一个 ":" 之后的部分，按 IPv4 规则判定
        if let lastColon = address.lastIndex(of: ":") {
            let tail = String(address[address.index(after: lastColon)...])
            if tail.contains(".") { return isNonPublicNumericHost(tail) }
        }
        return false
    }

    /// 数值主机（IPv4 及其非规范写法：短写、十进制、十六进制、越界）——一律 fail-closed。
    static func isNonPublicNumericHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: { $0.hasPrefix("0x") }) { return true }
        let octets = labels.compactMap { Int($0) }
        guard octets.count == labels.count else { return false }
        if octets.count == 4 {
            guard octets.allSatisfy({ (0...255).contains($0) }) else { return true }
            return isPrivateIPv4(octets)
        }
        // 1–3 段纯数字：短写/十进制歧义形式，不作为公网 host 放行
        return true
    }

    static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }
}
