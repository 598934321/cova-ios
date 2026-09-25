@testable import CovaCore
import XCTest

final class CovaEnvironmentTests: XCTestCase {
    func testAPIBaseURLIsPinnedToProductionHTTPSOrigin() {
        let url = CovaEnvironment.apiBaseURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "covalink.cn")
        XCTAssertEqual(url.absoluteString, "https://covalink.cn")
    }

    func testAPIBaseURLUsesDefaultHTTPSPort() {
        XCTAssertNil(CovaEnvironment.apiBaseURL.port)
        XCTAssertEqual(CovaEnvironment.apiPort, 443)
    }

    func testAPIBaseURLRejectsLocalhostAndProviderGateway() {
        let url = CovaEnvironment.apiBaseURL
        XCTAssertNotEqual(url.host, "localhost")
        XCTAssertNotEqual(url.host, "127.0.0.1")
        XCTAssertNotEqual(url.port, 3110)
    }

    func testIsProductionOriginAcceptsOnlyProductionHTTPS() {
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(CovaEnvironment.apiBaseURL))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "http://covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://localhost")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://127.0.0.1:3110")!))
    }

    func testIsProductionOriginRejectsNonDefaultPort() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:8443")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:3110")!))
    }

    func testIsProductionOriginRejectsHTTPSWithoutHost() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https:")!))
    }

    func testIsProductionOriginAcceptsSubpathsAndUppercaseHost() {
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn/api/tracks")!))
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(URL(string: "https://COVALINK.CN/api/tracks")!))
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:443/api/tracks")!))
    }

    func testIsProductionOriginRejectsNonHTTPSchemes() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "ftp://covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "http://covalink.cn:443")!))
    }

    func testIsProductionOriginRejectsHostLookalikes() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn.evil.invalid")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://evil.invalid/?next=covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn.")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://example.invalid")!))
    }

    // MARK: - m-2：userinfo 与非规范端口

    func testIsProductionOriginRejectsUserInfo() {
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://user@covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://user:pass@covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://user@covalink.cn:443/api")!))
    }

    func testIsProductionOriginRejectsNonCanonicalPortSpelling() {
        // URL 会把 :0443 归一化成 port == 443，必须回看原始字符串才能拦下
        XCTAssertEqual(URL(string: "https://covalink.cn:0443")?.port, 443)
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:0443")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:00443")!))
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn:/api")!))
    }

    func testHasCanonicalAuthority() {
        XCTAssertTrue(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://covalink.cn")!))
        XCTAssertTrue(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://covalink.cn:443")!))
        XCTAssertTrue(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://covalink.cn/api/tracks?page=1")!))
        XCTAssertFalse(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://covalink.cn:0443")!))
        XCTAssertFalse(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://covalink.cn:8443")!))
        XCTAssertFalse(CovaEnvironment.hasCanonicalAuthority(URL(string: "https://user@covalink.cn")!))
        XCTAssertFalse(CovaEnvironment.hasCanonicalAuthority(URL(string: "https:covalink.cn")!))
    }

    func testIsProductionOriginRejectsPrivateAndLoopbackHosts() {
        let rejected = [
            "https://localhost",
            "https://sub.localhost",
            "https://device.local",
            "https://service.internal",
            "https://nas.lan",
            "https://router.home",
            "https://10.0.0.5",
            "https://127.0.0.1",
            "https://0.0.0.0",
            "https://169.254.1.1",
            "https://172.16.0.1",
            "https://172.31.255.254",
            "https://192.168.1.10",
            "https://[::1]",
            "https://[fe80::1]",
            "https://[fc00::1]",
            "https://[fd12:3456::1]",
            "https://[::ffff:127.0.0.1]",
            "https://[::]",
            "https://2130706433",
            "https://127.1"
        ]
        for raw in rejected {
            XCTAssertFalse(
                CovaEnvironment.isProductionOrigin(URL(string: raw)!),
                "应拒绝私网/环回出口：\(raw)"
            )
        }
    }

    // MARK: - m-3：纵深防御分类

    func testIsNonPublicHostClassifiesDomainsAndPrivateIPv4() {
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("localhost"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("api.localhost"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("printer.local"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("vault.internal"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("box.lan"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("hub.home"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("LOCALHOST"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("10.1.2.3"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("127.0.0.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("0.0.0.0"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("169.254.9.9"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("172.16.0.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("172.31.9.9"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("192.168.0.1"))

        XCTAssertFalse(CovaEnvironment.isNonPublicHost("covalink.cn"))
        XCTAssertFalse(CovaEnvironment.isNonPublicHost("example.invalid"))
        XCTAssertFalse(CovaEnvironment.isNonPublicHost("8.8.8.8"))
        XCTAssertFalse(CovaEnvironment.isNonPublicHost("172.32.0.1"))
        XCTAssertFalse(CovaEnvironment.isNonPublicHost("a.b.c.d"))
    }

    func testIsNonPublicHostClassifiesIPv6() {
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("fe80::abcd"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("fe80::1%en0"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("fc00::1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("fd00::1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::0"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("0:0:0:0:0:0:0:0"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::ffff:127.0.0.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::ffff:10.0.0.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("::ffff:192.168.1.10"))

        XCTAssertFalse(CovaEnvironment.isNonPublicHost("::ffff:8.8.8.8"))
        XCTAssertFalse(CovaEnvironment.isNonPublicHost("2001:db8::1"))
    }

    func testIsNonPublicHostIsFailClosedOnNonCanonicalNumericForms() {
        // 十进制 / 短写 / 十六进制 / 越界 —— 一律不当公网 host 放行
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("2130706433"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("127.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("1.2.3"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("0x7f000001"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("0x7f.0.0.1"))
        XCTAssertTrue(CovaEnvironment.isNonPublicHost("999.1.1.1"))
    }

    // MARK: - makeAPIURL

    func testMakeAPIURLBuildsProductionURLs() {
        let plain = CovaEnvironment.makeAPIURL(path: "/api/tracks")
        XCTAssertEqual(plain?.absoluteString, "https://covalink.cn/api/tracks")

        let query = CovaEnvironment.makeAPIURL(
            path: "/api/tracks",
            queryItems: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "search", value: "夏日")]
        )
        XCTAssertEqual(query?.host, "covalink.cn")
        XCTAssertEqual(query?.path, "/api/tracks")
        XCTAssertEqual(query?.query?.contains("page=1"), true)
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(query!))
    }

    func testMakeAPIURLRejectsHostOverrides() {
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "api/tracks"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "https://evil.invalid/tracks"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/a://b"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/tracks?page=2"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/tracks#frag"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: ""))
    }

    /// Minor-1 回归：协议相对路径（`//host/...`）与反斜杠形态必须拒绝，
    /// 不得产出 `https://covalink.cn//evil.com/x` 这类「文档说会拒绝、实际放行」的结果。
    func testMakeAPIURLRejectsProtocolRelativeAndBackslashPaths() {
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "//evil.invalid/x"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "//covalink.cn/x"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "///evil.invalid"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/\\evil.invalid/x"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api\\..\\evil"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "\\/evil.invalid"))

        // 对照：正常的双斜杠出现在路径中段（合法）仍应放行，且 host 严格钉死
        let midSlash = CovaEnvironment.makeAPIURL(path: "/api/v1//tracks")
        XCTAssertEqual(midSlash?.host, "covalink.cn")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(midSlash!))
    }

    /// m-3：`.` / `..` 路径段（含百分号编码）必须拒绝；含点但非独立段不误杀。
    func testMakeAPIURLRejectsDotSegments() {
        XCTAssertTrue(CovaEnvironment.containsTraversalSegment("/api/../tracks"))
        XCTAssertTrue(CovaEnvironment.containsTraversalSegment("/api/./tracks"))
        XCTAssertTrue(CovaEnvironment.containsTraversalSegment("/.."))
        XCTAssertTrue(CovaEnvironment.containsTraversalSegment("/api/%2e%2e/tracks"))
        XCTAssertFalse(CovaEnvironment.containsTraversalSegment("/api/v1.2/tracks"))
        XCTAssertFalse(CovaEnvironment.containsTraversalSegment("/api/tracks"))

        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/../tracks"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/../api"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/./tracks"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/."))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/.."))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/%2e%2e/tracks"))
        XCTAssertNil(CovaEnvironment.makeAPIURL(path: "/api/%2E./tracks"))

        let dotted = CovaEnvironment.makeAPIURL(path: "/api/v1.2/tracks")
        XCTAssertEqual(dotted?.path, "/api/v1.2/tracks")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(dotted!))
    }

    // MARK: - resolveMediaURL（R16-1：目录里的相对 audioUrl 必须补成同源绝对地址）

    /// 线上实测形态（2026-09-24 只读探针：`GET /api/tracks` 的 20/20 行 `audioUrl` 都是相对路径，
    /// 而 `cover` 是绝对地址）。旧实现在这里直接 `URL(string:)` + `AudioURL(https:)` ⇒
    /// 没有 scheme ⇒ 被 `.missingScheme` 拒 ⇒ **整库静默不可播**。
    func testResolveMediaURLTurnsRelativeAudioPathIntoSameOriginAbsolute() throws {
        let raw = "/api/tracks/library-9749cdc210a624de9d0da02e/preview-stream"
        let url = try XCTUnwrap(CovaEnvironment.resolveMediaURL(raw))
        XCTAssertEqual(url.absoluteString, "https://covalink.cn\(raw)")
        XCTAssertEqual(url.scheme, "https", "补全后必须带 scheme —— 否则播放侧依旧拒绝")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(url), "补出来的地址必须仍落在唯一生产出口上")
    }

    /// 绝对 https 直链**原样交出**（这条腿不许被动过：封面今天就是绝对 CDN 地址，
    /// 而音频的出口裁决在 `PrivateAudioFetcher` 那一侧，不在补全这一侧）。
    func testResolveMediaURLKeepsAbsoluteHTTPSUnchanged() {
        let absolute = "https://cdn.invalid/review/daily/COVA-20260917-DAILY/A.mp3"
        XCTAssertEqual(CovaEnvironment.resolveMediaURL(absolute)?.absoluteString, absolute)
        XCTAssertEqual(
            CovaEnvironment.resolveMediaURL("https://covalink.cn/api/tracks")?.absoluteString,
            "https://covalink.cn/api/tracks"
        )
    }

    /// 笔记收藏的相对代理地址带查询（`/api/proxy/audio?…&sig=…`）：查询必须随 `queryItems`
    /// 一起进生产出口，而不是把整串当 path 交给 `makeAPIURL`（那里的 `?` 是拒绝项）。
    func testResolveMediaURLPreservesQueryForSameOriginProxyPath() throws {
        let raw = "/api/proxy/audio?url=https%3A%2F%2Fcdn.invalid%2Fsample.mp3&exp=1790000000000"
        let url = try XCTUnwrap(CovaEnvironment.resolveMediaURL(raw))
        XCTAssertEqual(url.host, "covalink.cn")
        XCTAssertEqual(url.path, "/api/proxy/audio")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["url", "exp"])
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(url))
    }

    /// fail-closed 面：一切可能改变 authority 或语义的形态都必须补不出来（**不猜 host**）。
    func testResolveMediaURLFailsClosedOnEscapingShapes() {
        for rejected in [
            "//evil.invalid/x",               // 协议相对：authority 逃逸
            "///evil.invalid",                // 两个前导斜杠同样带 authority
            "api/tracks/1",                   // 不是站内绝对路径
            "http://covalink.cn/a.mp3",       // 降级 scheme
            "file:///tmp/a.mp3",              // 本地地址不得从目录里进来
            "javascript:alert(1)",
            "https://covalink.cn/a.mp3#frag", // 片段从不外发
            "/api/tracks/1/preview-stream#frag",
            "/api\\..\\evil",                 // 反斜杠部分解析器视同 `/`
            "/api/../tracks",                 // 穿越段
            "/api/%2e%2e/tracks",
            "",
        ] {
            XCTAssertNil(CovaEnvironment.resolveMediaURL(rejected), "不该被补全：\(rejected)")
        }
        XCTAssertNil(CovaEnvironment.resolveMediaURL(nil))
    }

    // MARK: - R17-6：补全必须**逐字节保住**百分号编码

    /// 线上口径：部署侧的后端是从**查询参数原文**里读媒体地址的
    /// （`web` 仓 `src/app/api/tracks/[id]/preview-url/route.ts:37,47` 用
    /// `searchParams.get('url')`，签名侧 `src/lib/proxy-audio-sign.ts:49` 同），
    /// 而 Next 的查询解析把 `+` 当**空格**解。旧实现把相对地址拆成 `queryItems` 再重编码，
    /// `%2B` 被解成 `+` 又原样写出 ⇒ 任何含 `+` 的值到服务端就 HMAC 不匹配。
    /// 判据钉在「出站字符串与入站原文逐字节相同」，不是「解码后看起来差不多」。
    func testResolveMediaURLPreservesPercentEncodingVerbatim() throws {
        let raw = "/api/proxy/audio?url=https%3A%2F%2Fcdn.invalid%2Fsample%2Btake.mp3&exp=1790000000000&sig=ab%2Bcd%2Fef%3D%3D"
        let url = try XCTUnwrap(CovaEnvironment.resolveMediaURL(raw))
        XCTAssertEqual(url.absoluteString, "https://covalink.cn\(raw)", "补全只许加 host，查询原文一个字符都不许动")
        XCTAssertEqual(
            url.query,
            "url=https%3A%2F%2Fcdn.invalid%2Fsample%2Btake.mp3&exp=1790000000000&sig=ab%2Bcd%2Fef%3D%3D",
            "R17-6：%2B/%2F/%3D 必须原样留在查询里"
        )
        XCTAssertEqual(url.query?.contains("%2B"), true, "%2B 不许被降级成裸 +")
        // 解码侧读到的仍是原值（`+` 不被解成空格 ⇒ 后端 searchParams.get 拿到的是同一串）。
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["url", "exp", "sig"])
        XCTAssertEqual(items.first?.value, "https://cdn.invalid/sample+take.mp3")
        XCTAssertEqual(items.last?.value, "ab+cd/ef==")
    }

    /// 对照面（不许反向修成双重编码）：已编码的 `%252B` 保持 `%252B`，
    /// 字面 `+` 保持字面 `+`（那是服务端自己写出来的形态，客户端不替它改语义）。
    func testResolveMediaURLDoesNotReEncodeOrDoubleEncodeQueryText() throws {
        let alreadyEncoded = "/api/proxy/audio?url=a%252Bb.mp3&sig=1"
        XCTAssertEqual(
            CovaEnvironment.resolveMediaURL(alreadyEncoded)?.query,
            "url=a%252Bb.mp3&sig=1",
            "R17-6：修复不得变成二次编码"
        )
        let literalPlus = "/api/proxy/audio?url=a+b.mp3&sig=1"
        XCTAssertEqual(
            CovaEnvironment.resolveMediaURL(literalPlus)?.absoluteString,
            "https://covalink.cn/api/proxy/audio?url=a+b.mp3&sig=1"
        )
        // 无查询、只有路径的形态一个字节都不许多（原测试已覆盖，这里补查询为空的边界）。
        XCTAssertEqual(
            CovaEnvironment.resolveMediaURL("/api/tracks/one/preview-stream?")?.absoluteString,
            "https://covalink.cn/api/tracks/one/preview-stream"
        )
        // 绝对 https 直链仍原样交出（这条腿与查询保真无关，不许被顺手动过）。
        XCTAssertEqual(
            CovaEnvironment.resolveMediaURL("https://cdn.invalid/x.mp3?sig=a%2Bb")?.absoluteString,
            "https://cdn.invalid/x.mp3?sig=a%2Bb"
        )
    }

    /// 保真的正面表述：**逐字节**等于「生产 host + 入站原文」，且补出来的地址仍是生产出口。
    /// （任何「先解码再重编码」的实现都会在这一表格上某行失守 —— R17-6 就是 `%2B` 那一行。）
    func testResolveMediaURLIsByteIdenticalToTheInboundTextForEveryAcceptedQueryShape() throws {
        for raw in [
            "/api/tracks/one/preview-stream",
            "/api/tracks/one/preview-stream?seg=2",
            "/api/proxy/audio?url=https%3A%2F%2Fcdn.invalid%2Fa.mp3&exp=1&sig=%2Bx",
            "/api/proxy/audio?a=b%20c&d=%25",
            "/api/proxy/audio?sig=a+b",
            "/api/proxy/audio?sig=%252B",
            "/api/v1//x?q=%2F%2F",
        ] {
            let url = try XCTUnwrap(CovaEnvironment.resolveMediaURL(raw), "补全失败：\(raw)")
            XCTAssertEqual(url.absoluteString, "https://covalink.cn\(raw)", "出站原文与入站原文必须逐字节相同：\(raw)")
            XCTAssertTrue(CovaEnvironment.isProductionOrigin(url), "保真不许把出口放宽：\(raw)")
        }
    }

    // MARK: - D23：两类请求的出口（凭证类钉死同源，公开媒体类走显式名单）

    /// 名单主机本身（唯一事实源在 `sanctionedStorageHosts`）：两个桶、一个存储区。
    func testMediaAllowListContainsExactlyTheSanctionedBucketHosts() {
        XCTAssertEqual(
            CovaEnvironment.sanctionedStorageHosts,
            [
                "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com",
                "covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com",
            ],
            "名单扩容 = 改代码 + 过 D23，不许由运行时输入决定"
        )
        XCTAssertTrue(CovaEnvironment.isSanctionedStorageHost("covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"))
        XCTAssertTrue(CovaEnvironment.isSanctionedStorageHost("COVALINK-AUDIO-1301797874.cos.ap-shanghai.myqcloud.com"),
                      "host 大小写不敏感")
    }

    /// D23②：公开媒体出口 = 生产出口 ∪ 名单；其余一律关（**精确**匹配，不是 `*.myqcloud.com`）。
    func testSanctionedMediaURLOpenssOnlyTheNamedStorageHostsAndKeepsClosingEverythingElse() {
        let accepted = [
            "https://covalink.cn/api/tracks/one/preview-stream",
            "https://covalink.cn:443/covers/a.jpeg",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sign=stub",
        ]
        for text in accepted {
            XCTAssertTrue(CovaEnvironment.isSanctionedMediaURL(URL(string: text)!), "应放行：\(text)")
        }
        let refused = [
            // 近亲主机：把名单当**后缀**挂上去（DNS 上的真正 host 是 attacker.test）
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com.attacker.test/a.jpeg",
            // 前缀相似但不是那台桶（少了点号分隔 ⇒ 完全不同的 host）
            "https://evil-myqcloud.com/a.jpeg",
            "https://myqcloud.com/a.jpeg",
            // 同存储区、别的桶（含用户私产 uploads 桶与别人的同名前缀桶）
            "https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/u.mp3",
            "https://covalink-covers-9999999999.cos.ap-shanghai.myqcloud.com/a.jpeg",
            // 别的地域（换区就是换主机，必须显式过 D23）
            "https://covalink-covers-1301797874.cos.ap-beijing.myqcloud.com/a.jpeg",
            // 生产 host 的子域不是生产 host
            "https://cdn.covalink.cn/a.jpeg",
            "https://covalink.cn.evil.invalid/a.jpeg",
            // 形态不合格
            "http://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/a.jpeg",
            "https://user@covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/a.jpeg",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com:8443/a.jpeg",
            "https://127.0.0.1:3110/a.jpeg",
            "file:///tmp/a.jpeg",
        ]
        for text in refused {
            XCTAssertFalse(CovaEnvironment.isSanctionedMediaURL(URL(string: text)!), "不该放行：\(text)")
        }
    }

    /// D23①（不可谈判的一半）：带凭证的请求只能落在**同一权威**，名单不构成放行理由。
    ///
    /// ⚠️ 定位要说准（R18-4）：本函数答的是「这一类请求**原样**（凭证照带）跟不跟得出去」。
    /// 音频腿问的是 `mediaHopEgress` —— 它多一格「落地是名单上的存储主机 ⇒ 剥掉凭证再发」，
    /// 所以**不能**把这里读成「已授权的整曲播不出来」；那一句已被实测否证，见
    /// `testMediaHopEgressStripsCredentialsAtTheAllowListBoundary`。
    func testCredentialBearingRedirectPolicyNeverLeavesProductionAuthority() {
        let original = URL(string: "https://covalink.cn/api/tracks/one/preview-stream")!
        XCTAssertTrue(CovaEnvironment.mediaRedirectAllowed(
            from: original,
            to: URL(string: "https://covalink.cn/api/tracks/one/preview-stream?sig=rotated")!,
            carriesCredentials: true
        ), "同权威换址是服务端正常形态（NEEDS-15 那条腿）")
        XCTAssertTrue(CovaEnvironment.mediaRedirectAllowed(
            from: original,
            to: URL(string: "https://covalink.cn:443/api/tracks/one/preview-stream")!,
            carriesCredentials: true
        ), "min-2：规范端口是同一台主机")
        for refused in [
            // 已授权分支那一条：302 到整曲桶（NEEDS-29）⇒ 名单里也不行，凭证不出同源
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg",
            // 名单外
            "https://other-authority.invalid/pawned.m4a",
            // 别的 host / 别的端口 / 降级
            "https://cdn.covalink.cn/api/tracks/one/preview-stream",
            "https://covalink.cn:8443/api/tracks/one/preview-stream",
            "http://covalink.cn/api/tracks/one/preview-stream",
        ] {
            XCTAssertFalse(CovaEnvironment.mediaRedirectAllowed(
                from: original,
                to: URL(string: refused)!,
                carriesCredentials: true
            ), "带凭证绝不跟到：\(refused)")
        }
        // 凭证类如果一开始就不在生产出口上（装配错了），落地也不许跟。
        XCTAssertFalse(CovaEnvironment.mediaRedirectAllowed(
            from: URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3")!,
            to: URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full2.mp3")!,
            carriesCredentials: true
        ), "凭证类请求的发起地本身就必须是生产出口")
    }

    /// D23②/③：不带凭证的跳转只能在名单内漂（名单→名单可以，名单→名单外一律拒）。
    func testCredentialFreeRedirectPolicyStaysInsideTheAllowList() {
        let cover = URL(string: "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg")!
        XCTAssertTrue(CovaEnvironment.mediaRedirectAllowed(
            from: cover,
            to: URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3")!,
            carriesCredentials: false
        ), "名单主机之间跳转仍在名单内")
        XCTAssertTrue(CovaEnvironment.mediaRedirectAllowed(
            from: URL(string: "https://covalink.cn/api/media/x")!,
            to: cover,
            carriesCredentials: false
        ), "公开媒体从生产出口落到封面桶是今天的真实形态")
        for refused in [
            "https://evil-myqcloud.com/a.jpeg",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com.attacker.test/a.jpeg",
            "http://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/a.jpeg",
            "file:///tmp/a.jpeg",
        ] {
            XCTAssertFalse(CovaEnvironment.mediaRedirectAllowed(
                from: cover,
                to: URL(string: refused)!,
                carriesCredentials: false
            ), "名单外落地：\(refused)")
        }
        // 发起地本身不在名单内 ⇒ 这一类根本没有资格（配置漂移关在外面）。
        XCTAssertFalse(CovaEnvironment.mediaRedirectAllowed(
            from: URL(string: "https://cdn.invalid/a.jpeg")!,
            to: cover,
            carriesCredentials: false
        ))
    }

    // MARK: - D23① 上收的三条共用件（解析 `Location` / 点名 host / 凭证类裁决）

    /// 相对 `Location` 是 RFC 9110 §10.2.2 允许的形态：必须**相对发起那一条请求**解析。
    /// 这一条解析器今天被音频腿、普通 API 腿、SSE 腿**共用**（旧形状是三处各写一遍）。
    func testRedirectLandingResolvesAgainstTheRequestingURL() throws {
        func response(_ location: String?, status: Int = 302) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://covalink.cn/api/studio/one-step/plans")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: location.map { ["Location": $0] } ?? [:]
            )!
        }
        let requesting = URL(string: "https://covalink.cn/api/tracks/one/deep/preview-stream")!
        XCTAssertEqual(
            CovaEnvironment.redirectLanding(of: response("/api/tracks/two"), requesting: requesting)?.absoluteString,
            "https://covalink.cn/api/tracks/two",
            "根相对：基准是发起那一条的 scheme://authority"
        )
        XCTAssertEqual(
            CovaEnvironment.redirectLanding(of: response("moved.m4a"), requesting: requesting)?.absoluteString,
            "https://covalink.cn/api/tracks/one/deep/moved.m4a",
            "纯相对：换掉最后一段，不是拼到根上"
        )
        XCTAssertEqual(
            CovaEnvironment.redirectLanding(
                of: response("https://covalink.cn/api/studio/agent?slot=2"),
                requesting: requesting
            )?.absoluteString,
            "https://covalink.cn/api/studio/agent?slot=2",
            "绝对形态原样交出"
        )
        XCTAssertNil(CovaEnvironment.redirectLanding(of: response(nil), requesting: requesting), "无 Location 头")
        XCTAssertNil(CovaEnvironment.redirectLanding(of: response(""), requesting: requesting), "空 Location")
        XCTAssertNil(CovaEnvironment.redirectLanding(of: response("   "), requesting: requesting), "只有空白")
        XCTAssertNil(
            CovaEnvironment.redirectLanding(of: response("/api/x#frag"), requesting: requesting),
            "片段从不外发"
        )
        XCTAssertNil(
            CovaEnvironment.redirectLanding(of: response("..\\evil"), requesting: requesting),
            "反斜杠部分解析器视同 /"
        )
    }

    /// 凭证类裁决的三种结局：跟（同源）/ 拒（点名 host）/ 交回状态码（3xx 无 Location）。
    func testCredentialedRedirectDecisionCoversAllThreeOutcomes() throws {
        func response(_ location: String?, status: Int = 302) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://covalink.cn/api/studio/agent")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: location.map { ["Location": $0] } ?? [:]
            )!
        }
        let original = URL(string: "https://covalink.cn/api/studio/agent")!
        // 同源（含规范端口写法）⇒ 跟。
        XCTAssertEqual(
            CovaEnvironment.decideCredentialedRedirect(
                response: response("https://covalink.cn/api/studio/agent?slot=2"),
                original: original
            ),
            .follow(URL(string: "https://covalink.cn/api/studio/agent?slot=2")!)
        )
        XCTAssertEqual(
            CovaEnvironment.decideCredentialedRedirect(
                response: response("https://covalink.cn:443/api/studio/agent?slot=2"),
                original: original
            ),
            .follow(URL(string: "https://covalink.cn:443/api/studio/agent?slot=2")!),
            "min-2：规范端口是同一台主机，不许被误杀"
        )
        // 别家 ⇒ 拒，点名到真收请求的那台。
        for (landing, named) in [
            ("https://evil.invalid/x", "evil.invalid"),
            ("https://covalink.cn.evil.invalid/x", "covalink.cn.evil.invalid"),
            ("https://covalink.cn@evil.invalid/x", "evil.invalid"),
            ("https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/x",
             "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"),
            ("http://covalink.cn/x", "covalink.cn"),
            ("https://covalink.cn:8443/x", "covalink.cn"),
        ] {
            let decision = CovaEnvironment.decideCredentialedRedirect(
                response: response(landing), original: original
            )
            guard case .refused(let refusal) = decision else {
                return XCTFail("落地 \(landing) 必须被拒，实得 \(decision)")
            }
            XCTAssertEqual(refusal.host, named)
            XCTAssertEqual(refusal.rule, .credentialLeg)
        }
        // 3xx 但拿不出 Location ⇒ 服务端故障，不是出口决定。
        XCTAssertEqual(
            CovaEnvironment.decideCredentialedRedirect(response: response(nil), original: original),
            .unresolvable
        )
    }

    /// 点名口径：**只有 host**（小写），path / query / fragment 一概不带（硬边界 3）。
    func testEgressHostLabelKeepsOnlyTheHost() {
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(
                of: URL(string: "https://COVALINK-Covers-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=LEAK#a")!
            ),
            "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"
        )
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(of: URL(string: "https://covalink.cn@evil.invalid/x?sig=LEAK")!),
            "evil.invalid",
            "userinfo 挂甲：真正收到请求的是 @ 之后那一台"
        )
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(of: URL(string: "https://covalink.cn:8443/x")!),
            "covalink.cn",
            "端口不对也是同一台主机被点名（拒绝理由由判据给，不靠标签暗示）"
        )
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(of: URL(string: "file:///tmp/pawned.mp3")!),
            CovaEnvironment.unnameableHostLabel
        )
        XCTAssertFalse(CovaEnvironment.unnameableHostLabel.contains("LEAK"))
    }

    // MARK: - R18-1：host 「精确匹配」的**两个方向**都要钉住（旧用例只钉了一个方向）

    /// 为什么这一条必须存在（R18-1，变异存活 ⇒ 真洞）：`isSanctionedStorageHost` 与 D23 都
    /// 声称「既不是前缀也不是通配」，但旧用例只测了**名单串当前缀**那一个方向
    /// （`….myqcloud.com.attacker.test` ⇒ 真 host 是 attacker.test）。于是把实现改成
    /// `host.hasSuffix(sanctioned)` 之后 **488 tests / 0 failures / EXIT=0** —— 门禁看不见行为改变。
    /// 反方向（真 host **以**我们的桶名**结尾**：桶名的子域、拼在前面的串）一个用例都没有。
    /// 本用例从 `sanctionedStorageBuckets` + `storageZoneSuffix` **推导**输入，
    /// 于是扩容/换区时它自动跟着变，不是一串写死的死名字。
    func testSanctionedHostMatchingRefusesBothThePrefixAndTheSuffixDirection() {
        XCTAssertFalse(CovaEnvironment.sanctionedStorageBuckets.isEmpty, "前置：名单不能是空的（空名单会让本用例恒真）")
        for bucket in CovaEnvironment.sanctionedStorageBuckets {
            let sanctioned = bucket + CovaEnvironment.storageZoneSuffix
            XCTAssertTrue(CovaEnvironment.isSanctionedStorageHost(sanctioned), "前置：名单全名必须放行")
            // 方向①（旧用例已覆盖）：我们的全名当**前缀**、后面挂攻击者的域。
            XCTAssertFalse(
                CovaEnvironment.isSanctionedStorageHost("\(sanctioned).attacker.test"),
                "名单当前缀挂甲必须拒（真 host 是 attacker.test）"
            )
            // 钉 `hasPrefix` 这一支变异：以名单开头、尾巴再长一个字符就不是那台主机。
            XCTAssertFalse(
                CovaEnvironment.isSanctionedStorageHost("\(sanctioned)X"),
                "以名单开头但多一个字符 = 另一台主机（钉 hasPrefix 变异）"
            )
            // 方向②（本次补的洞）：我们的全名当**后缀**、前面挂上去 ⇒ `hasSuffix` 会放行。
            // 2026-09-25 本机 `getaddrinfo` 实测（**推翻了我自己先前准备写的理由**）：
            // 整个 `.cos.ap-shanghai.myqcloud.com` 区域是**通配解析** —— 桶名的子域、甚至
            // `totally-not-a-bucket-xyz99999.cos.ap-shanghai.myqcloud.com` 都返回**同一组 A 记录**
            // ⇒ "子域解析不到 / 不可达"在这里什么也证明不了。而 COS 按 `Host` 头取桶名，
            // 多出来那一截就是**另一台（我们不认的）桶**。拒绝的唯一硬理由是身份：
            // D23 钉的是「精确桶标号 + 精确存储区」；放行它等于允许任意多层前导 label ——
            // 那正好就是 `hasSuffix` 的形状。
            // （另一侧实测：`….com.attacker.test` **不**解析 —— 那一类要的是"别人域名下的
            //   一个名字"，与这一类的"同一台边缘上的另一个桶名"是两种不同的失效方式。）
            for spoofed in [
                "x.\(sanctioned)",                          // 名单主机的**子域**（解析得到，但不是那台桶）
                "evil.attacker.\(sanctioned)",              // 更深一层的子域
                "evil\(sanctioned)",                        // 无点粘连：仍"以名单结尾"
                "1\(sanctioned)",                           // 数字粘连（DNS 上就是另一个 label）
            ] {
                XCTAssertFalse(
                    CovaEnvironment.isSanctionedStorageHost(spoofed),
                    "名单当后缀挂甲必须拒（钉 hasSuffix 变异）：\(spoofed)"
                )
            }
            // 只认「桶名 + 存储区」那一个组合：拆开的两半、换了区、只剩存储区都不算。
            XCTAssertFalse(CovaEnvironment.isSanctionedStorageHost(bucket), "桶名单独不是主机全名：\(bucket)")
            XCTAssertFalse(
                CovaEnvironment.isSanctionedStorageHost("\(bucket).cos.ap-beijing.myqcloud.com"),
                "换存储区就是换主机，必须显式过 D23"
            )
            XCTAssertFalse(
                CovaEnvironment.isSanctionedStorageHost(CovaEnvironment.storageZoneSuffix),
                "存储区后缀本身（前面没有桶名）不是名单"
            )
            XCTAssertFalse(CovaEnvironment.isSanctionedStorageHost("myqcloud.com"), "公共后缀不是名单")
            XCTAssertFalse(CovaEnvironment.isSanctionedStorageHost(""), "空串不是名单")
            XCTAssertFalse(CovaEnvironment.isSanctionedStorageHost(sanctioned + " "), "带空白的 host 不是名单")
            // URL 形态的同一批挂甲也不能从 `isSanctionedMediaURL` 那一道漏出去。
            for refused in ["https://x.\(sanctioned)/a.mp3", "https://evil\(sanctioned)/a.mp3"] {
                XCTAssertFalse(
                    CovaEnvironment.isSanctionedMediaURL(URL(string: refused)!),
                    "URL 形态的同方向挂甲必须拒：\(refused)"
                )
                XCTAssertFalse(
                    CovaEnvironment.mediaRedirectAllowed(
                        from: CovaEnvironment.apiBaseURL.appendingPathComponent("api/tracks/one/preview-stream"),
                        to: URL(string: refused)!,
                        carriesCredentials: false
                    ),
                    "跳转腿也不许跟到它：\(refused)"
                )
            }
        }
    }

    /// 名单串出现在 **path / query / fragment** 里不是 host（R18-1 要的第三个方向）：
    /// 必须拒，而且拒绝时点名的必须是**真 host**（`evil.test`），一个 path/query 字符都不带出去 ——
    /// 签名住在 query（硬边界 3），D23③ 要的只是「看得见是哪一台」。
    func testSanctionedNameInsidePathOrQueryIsRefusedAndNamedByItsRealHostOnly() {
        let bucketHost = CovaEnvironment.sanctionedStorageHosts[0]
        let cases: [(address: String, named: String)] = [
            ("https://evil.test/\(bucketHost)/a.jpeg?sig=LEAK-SIG", "evil.test"),
            ("https://evil.test/?url=https%3A%2F%2F\(bucketHost)%2Fa.mp3&sig=LEAK-SIG", "evil.test"),
            ("https://evil.test/redir#\(bucketHost)", "evil.test"),
            ("https://\(bucketHost).attacker.test/a.jpeg?sig=LEAK-SIG", "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com.attacker.test"),
        ]
        for (address, named) in cases {
            guard let url = URL(string: address) else { return XCTFail("夹具本身必须可解析：\(address)") }
            XCTAssertFalse(CovaEnvironment.isSanctionedMediaURL(url), "名单住在 path/query 里不是名单：\(address)")
            XCTAssertEqual(CovaEnvironment.egressHostLabel(of: url), named, "点名必须是真 host：\(address)")
            let label = CovaEnvironment.egressHostLabel(of: url)
            for forbidden in ["LEAK", "/", "?", "#", "="] {
                XCTAssertFalse(label.contains(forbidden), "标签带出了地址片段 \(forbidden)：\(label)")
            }
            XCTAssertFalse(CovaEnvironment.isProductionOrigin(url), "这些都不是生产出口：\(address)")
        }
        // 对照（同一台真 host，名单串只在 path 里）：**生产出口**那条腿的 path 不构成逃逸，
        // 但点名口径仍然只出 host —— 这条钉的是「点名函数不会被 path 里的名单串带偏」。
        let productionWithBucketInPath = CovaEnvironment.apiBaseURL.appendingPathComponent(bucketHost)
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(productionWithBucketInPath))
        XCTAssertEqual(CovaEnvironment.egressHostLabel(of: productionWithBucketInPath), "covalink.cn")
        XCTAssertFalse(CovaEnvironment.egressHostLabel(of: productionWithBucketInPath).contains(bucketHost))
    }

    /// 收紧**不许**误杀合法形态（TD-9 口径：判据不许过宽）：大写 host、显式规范端口 `:443`、
    /// 签名查询里的 `%2B`（R17-6 刚修过的字节保真，不许在这里退回去）全部照常放行。
    func testLegitimateSanctionedShapesSurviveTheExactMatch() throws {
        let accepted = [
            "https://COVALINK-AUDIO-1301797874.COS.AP-SHANGHAI.MYQCLOUD.COM/tracks/full.mp3",
            "https://Covalink-Covers-1301797874.Cos.Ap-Shanghai.Myqcloud.Com/covers/a.jpeg",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com:443/covers/a.jpeg",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=%2Bx%3D%3D&region=ap-shanghai",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com:443/tracks/full.mp3?sig=%2Bx",
        ]
        for text in accepted {
            let url = try XCTUnwrap(URL(string: text), "夹具本身必须可解析：\(text)")
            XCTAssertTrue(CovaEnvironment.isSanctionedMediaURL(url), "合法形态被误杀：\(text)")
            XCTAssertTrue(
                CovaEnvironment.mediaRedirectAllowed(
                    from: CovaEnvironment.apiBaseURL.appendingPathComponent("api/tracks/one/preview-stream"),
                    to: url,
                    carriesCredentials: false
                ),
                "公开媒体腿的合法落地被误杀：\(text)"
            )
        }
        // R17-6 的保真前提在此钉住：判定用 host，绝不碰查询原文（`%2B` 一旦解成 `+`，
        // 部署侧的 HMAC 就对不上 —— 服务端把 `+` 当空格解）。
        let signed = try XCTUnwrap(
            URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=%2Bx%3D%3D")
        )
        XCTAssertTrue(CovaEnvironment.isSanctionedMediaURL(signed))
        XCTAssertEqual(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
            "sig=%2Bx%3D%3D",
            "出口判定不得改写签名查询原文"
        )
        XCTAssertEqual(signed.absoluteString, "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=%2Bx%3D%3D")
    }

    /// **本次写下的发现（不迁就、只如实钉住）**：`URL.host()` 会**原样保留** DNS 根标签的那个尾点
    /// （`https://…myqcloud.com./x` 的 `host()` 就是带尾点那串），于是精确匹配把 FQDN 绝对形态
    /// 判成**另一台主机**。本仓早就在另一条腿上把这条钉死了：
    /// `testIsProductionOriginRejectsHostLookalikes` 里 `https://covalink.cn.` 是**拒**的。
    /// 因此名单这一侧同样拒 —— 两侧一致（要放宽就必须同时在 `normalizedEgressHost` 与
    /// `normalizedAuthority` 做一次归一，否则会出现「出口放行、来源证明判换人」的两套口径，
    /// 并要翻掉上面那条既有断言；那是放宽已钉判据，属 D23 归属面，留待协调者裁决）。
    /// 真实风险面：尾点形态在我们的 `Location` / `audioUrl` 里从未出现过（30 个样本端点实测），
    /// 而带尾点的**近亲**主机仍然必须拒。
    func testTrailingRootDotIsRefusedConsistentlyOnBothEgressLegs() throws {
        let plain = try XCTUnwrap(
            URL(string: "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg")
        )
        let rootDot = try XCTUnwrap(
            URL(string: "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com./covers/a.jpeg")
        )
        XCTAssertEqual(
            rootDot.host,
            "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com.",
            "前置（发现本体）：Foundation 不折叠根标签尾点，精确匹配因此必然把它判成别台"
        )
        XCTAssertTrue(CovaEnvironment.isSanctionedMediaURL(plain))
        XCTAssertFalse(CovaEnvironment.isSanctionedMediaURL(rootDot), "尾点形态今天一律 fail-closed")
        XCTAssertFalse(
            CovaEnvironment.isSanctionedStorageHost("covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com.")
        )
        // 两侧同口径：生产出口那一侧早就钉了「带尾点不是生产 host」。
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(URL(string: "https://covalink.cn./api/tracks")!))
        // 带尾点的**近亲**（子域 + 尾点）两种口径下都必须拒。
        XCTAssertFalse(CovaEnvironment.isSanctionedMediaURL(
            URL(string: "https://x.covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com./a.jpeg")!
        ))
        // 标签面：点名时把尾点**原样如实**报出来（那是真收请求的那台），不借机折叠。
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(of: rootDot),
            "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com."
        )
    }

    // MARK: - R18-4：媒体腿一跳的裁决（带凭证 / 剥掉凭证 / 拒）三条腿各是什么形状

    private static let audioBucketLanding =
        "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=%2Bx%3D%3D"
    private static let previewOrigin = "https://covalink.cn/api/tracks/library-0001/preview-stream"

    /// 裁决面**只有一个**：`mediaHopEgress` 的答复必须逐格等于 `mediaRedirectAllowed` 的答复
    /// 加上「带凭证的腿落在名单桶上 ⇒ 剥掉凭证再发」这一格。这条用例是**等价关系**本身 ——
    /// 少了它，两个函数会在下一次改动里各漂一半（min-2 那一族）。
    func testMediaHopEgressIsExactlyMediaRedirectPlusTheStrippedCredentialCase() throws {
        let original = try XCTUnwrap(URL(string: Self.previewOrigin))
        let landings = [
            Self.previewOrigin,
            "https://covalink.cn:443/api/tracks/library-0001/preview-stream?seg=2",
            "https://covalink.cn.evil.invalid/x",
            "https://cdn.covalink.cn/x",
            Self.audioBucketLanding,
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg",
            "https://x.covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3",
            "http://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://other-authority.invalid/x.mp3",
        ]
        for carriesCredentials in [true, false] {
            for text in landings {
                let landing = try XCTUnwrap(URL(string: text))
                let allowed = CovaEnvironment.mediaRedirectAllowed(
                    from: original, to: landing, carriesCredentials: carriesCredentials
                )
                let hop = CovaEnvironment.mediaHopEgress(
                    from: original, to: landing, carriesCredentials: carriesCredentials
                )
                if allowed {
                    let expected: CovaEnvironment.MediaHopEgress =
                        carriesCredentials ? .keepCredentials : .withoutCredentials
                    XCTAssertEqual(
                        hop, expected,
                        "旧裁决说可以 ⇒ 新裁决只能给出对应的带/不带凭证：\(text)"
                    )
                }
                // 反向只允许这一格新增：带凭证 + 落地是名单上的**存储主机**（不含生产出口）。
                guard !allowed, case .withoutCredentials = hop else { continue }
                XCTAssertTrue(carriesCredentials, "公开腿不许新增任何放行：\(text)")
                XCTAssertTrue(
                    CovaEnvironment.isSanctionedStorageLanding(landing),
                    "新增的那一格只属于名单存储主机：\(text)"
                )
            }
        }
    }

    /// **R18-4 的那一格**：带凭证的音频腿被 302 到名单桶 ⇒ 可以跟，但那一跳**不带凭证**。
    /// 这就是「已授权整曲第一次能播出来」的判据本体（旧答复是"拒" ⇒ 名单里那台桶按构造不可达）。
    func testMediaHopEgressStripsCredentialsForSanctionedBucketLandings() throws {
        let original = try XCTUnwrap(URL(string: Self.previewOrigin))
        for landing in [
            Self.audioBucketLanding,
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg",
            "https://COVALINK-AUDIO-1301797874.COS.AP-SHANGHAI.MYQCLOUD.COM/tracks/full.mp3",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com:443/tracks/full.mp3?sig=x",
        ] {
            XCTAssertEqual(
                CovaEnvironment.mediaHopEgress(from: original, to: try XCTUnwrap(URL(string: landing)),
                                               carriesCredentials: true),
                .withoutCredentials,
                "名单桶落地必须剥掉凭证再发：\(landing)"
            )
        }
        // 同权威那一格不许被顺手改掉（NEEDS-15 那条腿仍然带着凭证继续）。
        XCTAssertEqual(
            CovaEnvironment.mediaHopEgress(
                from: original, to: try XCTUnwrap(URL(string: "\(Self.previewOrigin)?seg=2")),
                carriesCredentials: true
            ),
            .keepCredentials
        )
        // 公开腿（不带凭证）一格都不许多：与旧裁决同答复。
        XCTAssertEqual(
            CovaEnvironment.mediaHopEgress(
                from: original, to: try XCTUnwrap(URL(string: Self.audioBucketLanding)),
                carriesCredentials: false
            ),
            .withoutCredentials
        )
    }

    /// R18-4 新增那一格的**边界**（其余一律关）：发起地不是生产出口 ⇒ 凭证不出门；落地是子域 /
    /// 前缀挂甲 / 换桶 / 换区 / 降级 / userinfo / 非规范端口 / 名单串住在 path ⇒ `refused`。
    /// 「在 `myqcloud.com` 之下」从来不是放行理由，「以剥凭证为名」也不是。
    func testMediaHopEgressRefusesEverythingOutsideTheNamedBucketHosts() throws {
        let original = try XCTUnwrap(URL(string: Self.previewOrigin))
        for refused in [
            "https://x.covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3",
            "https://evil.covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com.attacker.test/x.mp3",
            "https://evilcovalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://covalink-audio-1301797874.cos.ap-beijing.myqcloud.com/x.mp3",
            "https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com:8443/x.mp3",
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com:0443/x.mp3",
            "http://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://bearer@covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "https://other-authority.invalid/x.mp3",
            "https://evil.test/covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            "file:///tmp/pawned.mp3",
        ] {
            let landing = try XCTUnwrap(URL(string: refused))
            XCTAssertEqual(
                CovaEnvironment.mediaHopEgress(from: original, to: landing, carriesCredentials: true),
                .refused,
                "新增那一格不许吃进这些：\(refused)"
            )
            XCTAssertEqual(
                CovaEnvironment.mediaHopEgress(from: original, to: landing, carriesCredentials: false),
                .refused,
                "公开腿同样不认：\(refused)"
            )
        }
        // 发起地本身不是生产出口 ⇒ 带凭证的腿连"剥了再发"的资格都没有（配置漂移关在外面）。
        let foreign = try XCTUnwrap(
            URL(string: "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg")
        )
        XCTAssertEqual(
            CovaEnvironment.mediaHopEgress(from: foreign, to: try XCTUnwrap(URL(string: Self.audioBucketLanding)),
                                           carriesCredentials: true),
            .refused
        )
    }

    /// **两条凭证腿的不对称是设计，不是漏**：API 腿与 SSE 腿追出去时**原样带着 Bearer**
    /// （`HTTPTransport.hoppingCheckedStream` 从 `original` 复制头），所以名单对它们**不构成**
    /// 放行理由；音频腿能多那一格，只因为它把凭证整条留下。谁把两边"统一"成一个函数，
    /// 这条用例就会红 —— 那正是把 Bearer 送进对象存储的形状。
    func testAPIAndSSECredentialedLegStillRefusesWhatTheAudioLegMayFollowAnonymously() throws {
        let original = try XCTUnwrap(URL(string: Self.previewOrigin))
        let landing = try XCTUnwrap(URL(string: Self.audioBucketLanding))
        let response = HTTPURLResponse(
            url: original, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": Self.audioBucketLanding]
        )!
        XCTAssertEqual(
            CovaEnvironment.mediaHopEgress(from: original, to: landing, carriesCredentials: true),
            .withoutCredentials,
            "前置：音频腿这一格是放行的（否则本用例只钉住了「两边都关」这种假对称）"
        )
        guard case .refused(let refusal) = CovaEnvironment.decideCredentialedRedirect(
            response: response, original: original
        ) else {
            return XCTFail("API/SSE 腿绝不能跟到名单桶：它会把 Bearer 送进对象存储")
        }
        XCTAssertEqual(refusal.host, "covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com")
        XCTAssertEqual(refusal.rule, .credentialLeg)
        XCTAssertFalse(refusal.host.contains("sig"), "点名只出 host，签名住在查询里：\(refusal.host)")
    }

    // MARK: - 第 30 批：交给「再也拦不住下一跳」的消费者之前的裁决

    /// `.publicDirect` 这一条腿的结论：**名单不适用**（不是漏了，是 D23② 的准入条件在这里拿不到）。
    ///
    /// 判据的两重各钉一次，方向不许含糊：
    /// · 生产出口 + 同一权威 ⇒ 放行（`:443` 与不带端口同一台，min-2）；
    /// · 名单上的桶直链（无凭证、`isSanctionedMediaURL == true`）⇒ **仍然拒**：
    ///   这一条一旦交出去，第二跳就不由我们判（`AVPlayer` 自己起网络栈、本层拿不到 delegate）。
    /// 对照必须在这里，而不是只在 CovaPlayer 的入口测一遍：谁把这一格"顺手放宽成名单"，
    /// 判据面本身就染红（第 30 批改掉的正是播放器里那份自己写了一遍规则的复制品）。
    func testPublicDirectEgressStaysOnProductionOriginEvenThoughTheBucketIsSanctioned() throws {
        let production = try XCTUnwrap(URL(string: Self.previewOrigin))
        let origin = CovaEnvironment.apiBaseURL
        XCTAssertTrue(CovaEnvironment.isPublicDirectEgressAllowed(production, origin: origin))
        XCTAssertTrue(
            CovaEnvironment.isPublicDirectEgressAllowed(
                try XCTUnwrap(URL(string: "https://covalink.cn:443/api/tracks/one/preview-stream")),
                origin: origin
            ),
            "min-2：规范端口折叠后仍是同一台出口"
        )
        // 前置：这些落地在**公开媒体腿**上是合格的（名单内），在这一条腿上依然不合格。
        for sanctioned in [
            try XCTUnwrap(URL(string: Self.audioBucketLanding)),
            try XCTUnwrap(
                URL(string: "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg")
            ),
        ] {
            XCTAssertTrue(
                CovaEnvironment.isSanctionedMediaURL(sanctioned),
                "前置：\(sanctioned.host() ?? "?") 在公开媒体名单上"
            )
            XCTAssertFalse(
                CovaEnvironment.isPublicDirectEgressAllowed(sanctioned, origin: origin),
                "名单不构成把地址交给拦不住下一跳的消费者的理由"
            )
        }
        // 注入别的出口只会「一律拒绝」，绝不因此放宽（fail-closed 的那一重）。
        XCTAssertFalse(
            CovaEnvironment.isPublicDirectEgressAllowed(production, origin: try XCTUnwrap(URL(string: "https://evil.invalid")))
        )
        XCTAssertFalse(
            CovaEnvironment.isPublicDirectEgressAllowed(
                try XCTUnwrap(URL(string: "https://covalink.cn:8443/api/tracks/one/preview-stream")),
                origin: origin
            ),
            "非规范端口是另一台主机"
        )
        XCTAssertFalse(
            CovaEnvironment.isPublicDirectEgressAllowed(
                try XCTUnwrap(URL(string: "https://user@covalink.cn/a.m4a")), origin: origin
            ),
            "userinfo 形态不是出口"
        )
        XCTAssertFalse(
            CovaEnvironment.isPublicDirectEgressAllowed(
                try XCTUnwrap(URL(string: "http://covalink.cn/a.m4a")), origin: origin
            ),
            "降级 http 不是出口"
        )
    }
}
