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

    /// 出口形态守卫（两类请求共用，D23）：`https` + 有 host + 无 userinfo + authority 规范
    /// + 非私网/环回/内网域名 + 规范端口。合格则返回**归一化 host**，否则 nil（fail-closed）。
    ///
    /// 抽出来只为了让「生产出口」与「许可名单存储主机」不可能长两套口径 ——
    /// min-2 的教训就是同一个规范端口规则在两处各写一遍、其中一处漏改。
    static func normalizedEgressHost(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        guard hasCanonicalAuthority(url) else { return nil }
        guard !isNonPublicHost(host) else { return nil }
        guard url.port == nil || url.port == apiPort else { return nil }
        return host
    }

    /// 出站 URL 的 fail-closed 判定：任一条不满足即拒绝。
    ///
    /// 拒绝面：非 `https`、无 host、带 userinfo（`https://user@…`）、authority 非规范
    /// （如 `:0443`）、私网/环回/链路本地/内网域名、host 非生产 host、显式非 443 端口
    /// （含 3110 provider 网关）。
    public static func isProductionOrigin(_ url: URL) -> Bool {
        normalizedEgressHost(of: url) == apiBaseURL.host()?.lowercased()
    }

    // MARK: - D23：两类请求的出口（凭证类钉死同源，公开媒体类走显式名单）

    /// 对象存储桶域名的**公共后缀**（腾讯云 COS 三段式域名的后两段：`.cos.<地域>.myqcloud.com`）。
    public static let storageZoneSuffix = ".cos.ap-shanghai.myqcloud.com"

    /// 许可名单上的**桶名**（D23② 的唯一事实源，2026-09-25 只读核对 `web` 仓
    /// `src/lib/page-media.ts:91-96` 与 `src/lib/catalog-audio-url.ts:10-12`）：
    /// · `covalink-covers-…`：封面桶，**公开读**（App 里每一张封面今天就在这台主机上）；
    /// · `covalink-audio-…`：整曲桶，私有读，只允许**服务端签发的地址**出现在查询串里
    ///   （NEEDS-29 未解锁前它仍然是「有权益分支的落地主机」，不是凭证出口）。
    ///
    /// 刻意**不**放宽成 `*.myqcloud.com`：那样会把 `covalink-uploads-…`（用户私产桶）与
    /// 任何别人账号下同前缀的桶一起放进来 —— `web` 侧正因为这个被否过一次。
    /// 名单按「桶名 + 存储区」**精确**匹配（既不是前缀也不是通配）：新增桶 = 改这一行 + 过 D23。
    public static let sanctionedStorageBuckets: [String] = [
        "covalink-covers-1301797874",
        "covalink-audio-1301797874",
    ]

    /// 许可名单主机全名（`桶.存储区`）。
    public static let sanctionedStorageHosts: [String] = CovaEnvironment.sanctionedStorageBuckets
        .map { "\($0)\(CovaEnvironment.storageZoneSuffix)" }

    /// D23②：host 是否就是名单上的那台存储主机（精确全等，大小写不敏感）。
    public static func isSanctionedStorageHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        return sanctionedStorageHosts.contains { $0.lowercased() == host }
    }

    /// D23②：**不带凭证**的公开媒体出口判定 = 生产出口 ∪ 许可名单存储主机。
    ///
    /// 这不是「任何 https 主机」：名单之外的桶、别的地域（`.cos.ap-beijing.…`）、
    /// 前缀相似的 `evil-myqcloud.com`、把名单主机当后缀挂上去的
    /// `covalink-covers-….myqcloud.com.attacker.test` 一律不合格。
    public static func isSanctionedMediaURL(_ url: URL) -> Bool {
        guard let host = normalizedEgressHost(of: url) else { return false }
        return host == apiBaseURL.host()?.lowercased() || isSanctionedStorageHost(host)
    }

    /// 权威归一化（`scheme://host`，**规范端口折叠**）：`covalink.cn` 与 `covalink.cn:443`
    /// 是同一台主机（min-2），非规范端口就是另一台主机。非 https / 无 host → nil。
    public static func normalizedAuthority(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if let port = url.port, port != apiPort { return "\(url.scheme!.lowercased())://\(host):\(port)" }
        return "https://\(host)"
    }

    /// 两条地址是否同一台主机（任一边取不出权威即 false）。
    public static func isSameAuthority(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let first = normalizedAuthority(of: lhs), let second = normalizedAuthority(of: rhs) else {
            return false
        }
        return first == second
    }

    /// **D23 的唯一跳转裁决面**：一条 3xx 的 `Location` 能不能被跟。
    ///
    /// · `carriesCredentials == true`（请求带 `Authorization: Bearer …`）⇒ 落地必须**仍是同一权威**
    ///   且仍在生产出口内。许可名单**不构成**放行理由 —— 凭证永不出生产出口，这是不可谈判的一半
    ///   （硬边界 2/3、D5、D7、D10）。
    /// · `carriesCredentials == false`（公开媒体：封面、签名地址）⇒ 落地必须在
    ///   `isSanctionedMediaURL` 名单内，且**发起那一条本身也得在名单内**
    ///   （名单主机之间跳转仍在名单内；名单外根本没有发起的资格）。
    /// · 两类共用出口形态守卫：不许降级 http、不许 userinfo、不许非规范端口、不许私网。
    public static func mediaRedirectAllowed(
        from original: URL,
        to landing: URL,
        carriesCredentials: Bool
    ) -> Bool {
        if carriesCredentials {
            guard isProductionOrigin(original), isProductionOrigin(landing) else { return false }
            return isSameAuthority(original, landing)
        }
        return isSanctionedMediaURL(original) && isSanctionedMediaURL(landing)
    }

    /// 取不出主机时的**占位标签**（拒绝信息里宁可点名"没有主机"，也不许回退成整串地址 ——
    /// 签名就住在 query 里，整串一旦进错误对象就可能进日志；AGENTS 硬边界 3）。
    public static let unnameableHostLabel = "<无主机名>"

    /// 拒绝时要点名的那一台主机：**只有 host**（小写），path / query / fragment 一概不带。
    ///
    /// D23③ 的可用性要求：桶名或存储区一变，失败必须是「看得见的 host」，
    /// 而不是一句"请求地址非法"让人去猜是哪台。userinfo 形态（`https://covalink.cn@evil.test/`）
    /// 在这里被如实报成 `evil.test` —— 那才是真正收到请求的那一台。
    public static func egressHostLabel(of url: URL) -> String {
        guard let host = url.host()?.lowercased(), host.isEmpty == false else {
            return unnameableHostLabel
        }
        return host
    }

    /// 3xx 的 `Location` → 绝对落地地址；拿不出来（空头/空值/形状可疑）→ nil。
    ///
    /// 相对 `Location` 是 RFC 9110 §10.2.2 允许的形态，必须**相对发起那一条请求**解析
    /// （不是相对生产根，更不是字符串拼接）。D23 之后这一条从 CovaPlayer 的 `MediaEgressHop`
    /// 上收到本文件：音频腿、普通 API 腿、SSE 腿用的是同一个解析器，不再各写一遍。
    public static func redirectLanding(of response: HTTPURLResponse, requesting url: URL) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Location") else { return nil }
        let target = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.isEmpty == false else { return nil }
        // 片段从不外发、反斜杠部分解析器视同 `/` —— 与 `resolveMediaURL` 同口径。
        guard target.contains("#") == false, target.contains("\\") == false else { return nil }
        if let absolute = URL(string: target), absolute.scheme != nil { return absolute }
        return URL(string: target, relativeTo: url)?.absoluteURL
    }

    /// 凭证类跳转的裁决结果（**只处理 3xx**：非跳转由调用方按状态码交付）。
    public enum CredentialedRedirect: Equatable, Sendable {
        /// 落地仍是同一权威的生产出口 ⇒ 允许**调用方自己**重建请求再发一次。
        case follow(URL)
        /// 落地不是生产出口（或形态不合格）⇒ 那一次出站**绝不发生**，并把 host 如实交出去。
        case refused(CovaEgressRefusal)
        /// 3xx 但没有可用的 `Location` ⇒ 服务端故障，不是出口决定（交付状态码，别伪装成拒绝）。
        case unresolvable
    }

    /// **D23① 的唯一跳转裁决面**：一条带凭证的 3xx 能不能追，以及追到哪里。
    ///
    /// 判据本身仍是 `mediaRedirectAllowed`（音频腿、封面腿、这两条凭证腿共用同一个函数），
    /// 本函数只多做两件它做不到的事：把相对 `Location` 解析出来、把拒绝点名到 host。
    /// 「许可名单」在这里**不构成**放行理由 —— 凭证永不出生产出口（硬边界 2/3、D5、D7、D10）。
    public static func decideCredentialedRedirect(
        response: HTTPURLResponse,
        original: URL
    ) -> CredentialedRedirect {
        guard let landing = redirectLanding(of: response, requesting: original) else {
            return .unresolvable
        }
        guard mediaRedirectAllowed(from: original, to: landing, carriesCredentials: true) else {
            return .refused(CovaEgressRefusal(host: egressHostLabel(of: landing), rule: .credentialLeg))
        }
        return .follow(landing)
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
        guard !containsTraversalSegment(path) else { return nil }
        var components = URLComponents()
        components.scheme = apiBaseURL.scheme
        components.host = apiBaseURL.host()
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, isProductionOrigin(url) else { return nil }
        return url
    }

    /// 目录/收藏里音频与封面地址原文（`audioUrl` / `cover`）→ 可出站绝对地址（R16-1）。
    ///
    /// 为什么必须有这一层（2026-09-24 只读探针，`GET /api/tracks`）：**20/20 行的
    /// `audioUrl` 是相对路径**（`/api/tracks/<id>/preview-stream`），而 `cover` 是绝对地址。
    /// 服务端把整曲桶转私有读后，公开响应只发本站代理端点（`web` 仓
    /// `src/lib/catalog-audio-url.ts` 顶部注释 + `src/lib/api-dto.ts:135-137`），
    /// 而旧客户端直接 `URL(string: track.audioUrl)` 交给 `AudioURL(https:)` ——
    /// 相对地址没有 scheme ⇒ `.missingScheme` ⇒ 每一行都映射成 `nil`，**整库静默不可播**
    /// （封面还是绝对地址，所以画面正常，故障看不见）。
    ///
    /// 判定只补同源绝对地址，**不放宽出口守卫**：
    /// · 绝对 `https` 直链原样交出（host 由下游裁决：封面归封面，音频归
    ///   `PrivateAudioFetcher` 的 `isProductionOrigin` 那一道）；
    /// · 无 scheme、无 authority、以 `/` 开头的站内路径 → 钉死生产 host，**查询原文逐字节
    ///   带走**（笔记收藏的 `/api/proxy/audio?…&sig=…` 就是这一形态；R17-6）；
    /// · 其余一律 `nil`（fail-closed，**不猜 host**）：`http://`、`file://`、任何非 https scheme、
    ///   `//evil.invalid/x`（协议相对，authority 逃逸）、`///evil.invalid`、
    ///   `api/tracks/1`（非站内绝对路径）、含 `#` 片段、含反斜杠、`.`/`..` 与 `%2e` 穿越段。
    public static func resolveMediaURL(_ raw: String?) -> URL? {
        guard let raw, raw.isEmpty == false else { return nil }
        // 片段（`#…`）从不发给出口：签名与状态都住在 query 里，带片段的值是拼接出错的信号，
        // 而不是「可以安全丢弃的一半」。反斜杠部分解析器视同 `/`，同样直接拒。
        guard raw.contains("#") == false, raw.contains("\\") == false else { return nil }
        guard let parsed = URL(string: raw) else { return nil }
        if let scheme = parsed.scheme?.lowercased() {
            return scheme == "https" ? parsed : nil
        }
        // 相对形态：只认「无 authority 的站内绝对路径」。`//host/x` 有 host，`///host` 有两个
        // 前导斜杠 —— 两者都是 authority 逃逸的形状，绝不补全。
        guard parsed.host == nil, raw.hasPrefix("//") == false, parsed.path.hasPrefix("/") else {
            return nil
        }
        let components = URLComponents(string: raw)
        guard components?.fragment == nil else { return nil }
        // R17-6：**不再**走 `queryItems` 往返。旧实现把查询解码成项、再由 `makeAPIURL` 重新编码，
        // 于是 `%2B` 被发成裸 `+`、`%3A%2F%2F` 被发成 `://`、`%3D%3D` 被发成 `==`。
        // 而部署侧的后端是从**查询原文**里读媒体地址的（`web` 仓
        // `src/app/api/tracks/[id]/preview-url/route.ts:37,47` 的 `searchParams.get('url')`、
        // `src/lib/proxy-audio-sign.ts:49` 的签名比对），Next 的查询解析把 `+` 当**空格**解
        // ⇒ 任何含 `+` 的值到服务端都对不上 HMAC（今天出厂的 `sig` 是十六进制所以未爆，
        // 但「保真」不许依赖别人的字符集）。
        // 补全只做一件事：在生产 origin 前拼上**原文**（一个字符都不改），再把重拼结果逐字节
        // 比一遍 —— 任何被 Foundation 悄悄「修复」过的形态（空格、控制字符…）都 fail-closed 丢掉，
        // 而不是发出一条「我以为发不出去」的地址。修复方向不是二次编码（那会把 `%252B` 再降一档）。
        let path: String
        if let separator = raw.firstIndex(of: "?") {
            path = String(raw[..<separator])
        } else {
            path = raw
        }
        guard makeAPIURL(path: path) != nil else { return nil }
        let anchored = apiBaseURL.absoluteString + (raw.hasSuffix("?") ? String(raw.dropLast()) : raw)
        guard let url = URL(string: anchored), url.absoluteString == anchored, isProductionOrigin(url) else {
            return nil
        }
        return url
    }

    /// 路径穿越守卫（m-3）：拒绝 `.` / `..` 路径段，以及百分号编码的 `%2e`（大小写不敏感）。
    ///
    /// host 已由 `makeAPIURL` 钉死为生产 host，因此穿越无法改变 origin；本检查是纵深防御，
    /// 与文档「拒绝路径穿越」的表述对齐（fail-closed）。
    static func containsTraversalSegment(_ path: String) -> Bool {
        if path.lowercased().contains("%2e") { return true }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." }
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
