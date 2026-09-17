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
}
