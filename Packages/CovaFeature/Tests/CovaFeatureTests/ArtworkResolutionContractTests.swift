import CovaCore
import CovaUI
@testable import CovaFeature
import XCTest

/// 裁决面本身的契约（放在 CovaFeature 测试目标里跑：CovaUI 至今没有测试目标，
/// 而这一层的判据在 R18-2 之前**一条测试都没有**）。
///
/// 三条契约：
/// · 三档结论互斥且都能读出一个结论（`.absent` 不是故障、`.refused` 必须说得出 host）；
/// · 站内相对补全**逐字节**保留查询串（R17-6 的 `%2B` 纪律延伸到美术腿）；
/// · 拒绝文本只有 host —— 路径 / 查询 / userinfo 一个字都不许出现（硬边界 3）。
final class ArtworkResolutionContractTests: XCTestCase {

    func testAbsentIsALegitimateNilAndCarriesNoFaultText() {
        for raw in [nil, ""] {
            let resolution = CovaArtworkResolution(serverValue: raw)
            XCTAssertAbsent(resolution, "原文 \(String(describing: raw))")
            XCTAssertNil(resolution.url)
            XCTAssertNil(resolution.refusalMessage, "没给图不是故障，不许产出拒绝文案")
        }
    }

    func testResolvedCarriesAnAddressAndNoFaultText() throws {
        let relative = CovaArtworkResolution(serverValue: "/uploads/avatars/x.png")
        XCTAssertEqual(relative.url?.absoluteString, ArtworkFixture.production("/uploads/avatars/x.png"))
        XCTAssertNil(relative.refusalMessage)

        let absolute = CovaArtworkResolution(serverValue: try ArtworkFixture.sanctioned("/covers/y.png"))
        XCTAssertNotNil(absolute.url)
        XCTAssertNil(absolute.refusalMessage)
    }

    /// 五种「给了但不可出站」的形态，逐一要求点名 host。
    func testEveryUnusableShapeRefusesAndNamesTheHost() {
        let cases: [(String, String)] = [
            ("https://covers.evil.test/a.png", "covers.evil.test"),
            ("https://covalink.cn.evil.test/a.png", "covalink.cn.evil.test"),   // 后缀挂甲
            ("https://covalink.cn.covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/a.png",
             "covalink.cn.covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"),  // 名单主机当后缀
            ("https://covalink.cn@evil.test/a.png", "evil.test"),                     // userinfo 逃逸
            ("http://covers.invalid/a.png", "covers.invalid"),                        // 降级 http
            ("//covers.evil.test/a.png", "covers.evil.test"),                         // 协议相对
        ]
        for (raw, host) in cases {
            let resolution = CovaArtworkResolution(serverValue: raw)
            XCTAssertRefused(resolution, host: host, "原文 \(raw)")
            XCTAssertNil(resolution.url, "被拒的地址不得交出去：\(raw)")
        }
    }

    /// 无 host 可点名的形态（裸相对路径）：仍然拒，但**绝不回显原串**。
    func testHostlessRelativeRefusesWithPlaceholderAndNoEcho() {
        let resolution = CovaArtworkResolution(serverValue: "covers/a.png?sig=a%2Bb")
        let message = XCTAssertRefused(resolution, host: CovaEnvironment.unnameableHostLabel)
        XCTAssertEqual(message, CovaArtworkResolution(serverValue: "covers/a.png").refusalMessage,
                       "无 host 的两种原文必须落进同一档，且不因内容不同而泄漏任何片段")
        for fragment in ["covers", "a.png", "sig", "a%2Bb"] {
            XCTAssertFalse((message ?? "").contains(fragment), "拒绝文本泄漏了 \(fragment)")
        }
    }

    /// 拒绝文本的组成：**只有** host 与固定句式。
    func testRefusalMessageContainsNothingButHostAndFixedSentence() throws {
        let message = try XCTUnwrap(
            XCTAssertRefused(
                CovaArtworkResolution(serverValue: "https://covers.evil.test/secret/path.png?sig=topsecret&token=bearer-ish"),
                host: "covers.evil.test"
            )
        )
        XCTAssertEqual(message, "美术地址不可出站：covers.evil.test 不是生产出口也不在许可名单的存储主机内（该次请求未发出）")
    }

    /// **查询串逐字节**（R17-6 的纪律延伸到美术腿）：补全只加 origin 前缀，一个字符都不改。
    /// 这些形态全部来自线上真会出现的形状：签名参数、`%2B`、`%3A%2F%2F`、重复键、已二次编码。
    func testSiteRelativeCoverQuerySurvivesByteForByte() {
        let raws = [
            "/api/covers/p1.png?width=640&height=640&format=webp",
            "/api/covers/p2.png?sig=9f%2Bab",
            "/api/proxy/cover?url=https%3A%2F%2Fcdn.invalid%2Fa.png&sig=aa%2B%3D%3D",
            "/api/covers/p3.png?width=640&width=320",
            "/api/covers/p4.png?sig=a%252Bb",
            "/api/covers/p5.png?a=1&b=&c=%20",
            "/api/covers/p6.png?x=1%3B2&y=a,b",
        ]
        for raw in raws {
            let resolution = CovaArtworkResolution(serverValue: raw)
            // 与「origin + 原文」逐字节相等：任何重排、重编码、丢参都会在这里红。
            XCTAssertResolved(resolution, equals: ArtworkFixture.production(raw), "原文 \(raw)")
        }
    }

    /// 已经补全过的绝对地址（本机账 / 播放器交来的）再过一次**同一条**名单判据。
    func testAlreadyResolvedURLLegUsesTheSameListRule() throws {
        XCTAssertAbsent(CovaArtworkResolution(resolvedURL: nil))
        let sanctioned = CovaArtworkResolution(
            resolvedURL: URL(string: try ArtworkFixture.sanctioned("/covers/z.png"))
        )
        XCTAssertResolved(sanctioned, equals: try ArtworkFixture.sanctioned("/covers/z.png"))
        XCTAssertRefused(
            CovaArtworkResolution(resolvedURL: URL(string: "https://covalink.cn.evil.test/z.png")),
            host: "covalink.cn.evil.test",
            "已解析不等于可出站"
        )
    }

    /// 多候选字段：**第一个非空**原文参与裁决（旧 `??` 链会让空串把后面的真值挡掉）。
    func testServerValuesTakesFirstNonEmptyCandidate() {
        XCTAssertAbsent(CovaArtworkResolution(serverValues: [nil, "", nil]))
        XCTAssertResolved(
            CovaArtworkResolution(serverValues: [nil, "", "/api/covers/late.png?sig=a%2Bb"]),
            equals: ArtworkFixture.production("/api/covers/late.png?sig=a%2Bb")
        )
        XCTAssertRefused(
            CovaArtworkResolution(serverValues: ["https://first.evil.test/a.png", "/api/covers/b.png"]),
            host: "first.evil.test",
            "第一个非空值参与裁决后即定案，不逐个放宽重试"
        )
    }
}
