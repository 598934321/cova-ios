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
}
