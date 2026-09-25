import CovaCore
import Foundation
import XCTest
@testable import CovaPlayer

/// D23①/② + MAJ-8：地址**交给 `AVPlayer` 之前**的那一道出口裁决。
///
/// 判据本身不在这里重写（`CovaEnvironment.isProductionOrigin` / `AudioAuthorityMatch` 是
/// 唯一事实源）；本文件钉的是「公开直链这一类到底能不能出站」与「拒绝时必须看得见 host」。
///
/// 为什么这一层只能判**发起之前**：`AVPlayer` 自己起网络栈、本层拿不到它的 delegate ⇒
/// 地址一交出去，后续跳转就不再由我们裁决。所以 D23② 的存储桶名单在这一条腿**不适用**
/// （名单放行的前提是「链上每一跳都可裁决」，那是音频腿 `MediaEgressHop` 才有的能力）。
final class PlayerEgressTests: XCTestCase {
    private let production = CovaEnvironment.apiBaseURL

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    /// 封面桶/整曲桶的 host 形态（假 host 用保留 TLD；真实名单由 `CovaEnvironment` 单点定义）。
    private static let coverBucket = "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg"
    private static let audioBucket = "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3"

    func testProductionDirectURLIsHandedToThePlayerUnchanged() throws {
        let source = url("https://covalink.cn/api/tracks/library-0001/preview-stream")
        XCTAssertTrue(PlayerEgress.isPlayable(source, origin: production))
        XCTAssertEqual(try PlayerEgress.decide(direct: source, origin: production).get(), source)
    }

    /// D23③ 的可用性要求：桶名/存储区一变，失败必须**点名 host**，而不是一个静默占位。
    /// 30 个样本里每台媒体主机都在名单上 —— 样本不是穷举。
    func testSanctionedBucketDirectURLIsRefusedAndNamed() throws {
        for landing in [Self.coverBucket, Self.audioBucket] {
            let source = url(landing)
            // 前置：这台主机在**公开媒体腿**上是合格的（名单内），不合格的是这一条腿的形态。
            XCTAssertTrue(
                CovaEnvironment.isSanctionedMediaURL(source),
                "前置：\(landing) 应当就在 D23② 的名单上，否则本用例只证明了「全都拒」"
            )
            // 这一条腿不跟 D23② 的名单走（理由见 `PlayerEgress` 的注释）：桶 host 也照样拒。
            XCTAssertFalse(PlayerEgress.isPlayable(source, origin: production))
            XCTAssertThrowsError(try PlayerEgress.decide(direct: source, origin: production).get()) { error in
                guard let failure = error as? PlayerFailure else {
                    return XCTFail("应当是 PlayerFailure：\(error)")
                }
                XCTAssertEqual(failure.kind, .egressRefused)
                // 上屏那句（`PlayerViews` 直接印 `description`）：中文分类 + 点名 host。
                XCTAssertTrue(
                    failure.description.contains(PlayerFailure.Kind.egressRefused.userLabel),
                    "上屏句没有中文分类标签：\(failure.description)"
                )
                XCTAssertFalse(
                    failure.description.contains("egressRefused"),
                    "上屏句露出英文枚举名：\(failure.description)"
                )
                XCTAssertTrue(
                    failure.message.contains(source.host()?.lowercased() ?? ""),
                    "拒绝必须看得见是哪台：\(failure.message)"
                )
            }
        }
    }

    /// 判定只有**一份**（第 30 批的根因：同一个裁决在播放器里被写了两遍）。
    /// `AVPlayerEngine.playableURL` 与 `PlayerEgress.isPlayable` 现在都转授
    /// `CovaEnvironment.isPublicDirectEgressAllowed` —— 这里钉住"转授"这个事实本身：
    /// 谁再在播放器侧起一份自己的判据（哪怕今天答案相同），这一条就会红。
    func testEngineAndPlayerEgressShareOneDecisionSurface() throws {
        let production = CovaEnvironment.apiBaseURL
        for raw in [
            "https://covalink.cn/api/tracks/one/preview-stream",
            "https://covalink.cn:443/api/tracks/one/preview-stream",
            Self.coverBucket,
            Self.audioBucket,
            "https://covalink.cn:8443/a.mp3",
            "https://evil.invalid/a.mp3",
        ] {
            let source = url(raw)
            XCTAssertEqual(
                PlayerEgress.isPlayable(source, origin: production),
                CovaEnvironment.isPublicDirectEgressAllowed(source, origin: production),
                "播放器侧的答案与共享裁决面不一致：\(raw)"
            )
            let item = TestItems.make("shared", source: .publicDirect(try AudioURL(https: source)))
            let engineSaysPlayable: Bool
            switch AVPlayerEngine.playableURL(for: item, egressOrigin: production) {
            case .success: engineSaysPlayable = true
            case .failure: engineSaysPlayable = false
            }
            XCTAssertEqual(
                engineSaysPlayable,
                CovaEnvironment.isPublicDirectEgressAllowed(source, origin: production),
                "引擎闸门的答案与共享裁决面不一致：\(raw)"
            )
        }
    }

    /// 硬边界 3：错误文本里只有 host —— 签名住在 query，路径段也可能带签名（`/<sig>/<key>`）。
    func testRefusalTextCarriesNoSignatureNoPath() throws {
        let signed = url(
            "https://evil.invalid/tracks/LEAK-PATH.mp3?sig=LEAK-SIGNATURE&q-key=LEAK-KEY#LEAK-FRAGMENT"
        )
        let failure = PlayerEgress.rejection(for: signed)
        for secret in ["LEAK-SIGNATURE", "LEAK-KEY", "LEAK-PATH", "LEAK-FRAGMENT", "?", "sig=", "tracks"] {
            XCTAssertFalse(failure.description.contains(secret), "上屏文本泄漏：\(secret)")
        }
        XCTAssertTrue(failure.description.contains("evil.invalid"))
        // 全反射面（`dump` / 数组 / Optional 包裹）同样不许带出地址片段。
        var rendered = ""
        rendered += String(describing: failure) + String(reflecting: failure)
        rendered += String(describing: [failure]) + String(describing: Optional(failure))
        var collector = DumpCollector()
        dump(failure, to: &collector)
        rendered += collector.output
        XCTAssertFalse(rendered.contains("LEAK"), "反射面泄漏：\(rendered)")
    }

    /// 形近主机与 userinfo 挂甲：`covalink.cn` 之后再接一段不是它，`@` 之前的也不是它。
    func testLookalikeAndUserInfoHostsAreRefused() {
        for landing in [
            "https://covalink.cn.evil.invalid/api/x.mp3",
            "https://covalink.cn@evil.invalid/api/x.mp3",
            "https://evil.covalink.cn.invalid/api/x.mp3",
            "http://covalink.cn/api/x.mp3",
            "https://covalink.cn:8443/api/x.mp3",
            "https://covalink.cn:0443/api/x.mp3",
            "https://127.0.0.1/api/x.mp3",
            "https://localhost/api/x.mp3",
            "file:///tmp/pawned.mp3",
        ] {
            XCTAssertFalse(
                PlayerEgress.isPlayable(url(landing), origin: production),
                "应当拒绝：\(landing)"
            )
        }
    }

    /// 注入别的 origin **不放宽任何判定**（fail-closed）：①生产出口先拦，②门面权威再拦。
    func testInjectedOriginNeverWidensTheEgress() {
        let source = url("https://covalink.cn/api/tracks/one/preview-stream")
        XCTAssertTrue(PlayerEgress.isPlayable(source, origin: production))
        XCTAssertFalse(
            PlayerEgress.isPlayable(source, origin: url("https://evil.invalid")),
            "注入非法出口只会「一律拒绝」，不可能把出口放宽到别处"
        )
        // 规范端口折叠同源（min-2）：`:443` 与不带端口是同一台主机。
        XCTAssertTrue(
            PlayerEgress.isPlayable(
                url("https://covalink.cn:443/api/tracks/one/preview-stream"),
                origin: production
            )
        )
        // 非规范端口是**另一台**主机：与门面的权威不同 ⇒ 即便在生产出口内也不交出去。
        XCTAssertFalse(
            PlayerEgress.isPlayable(
                url("https://covalink.cn/api/tracks/one/preview-stream"),
                origin: url("https://covalink.cn:8443")
            )
        )
    }

    /// 与音频腿**同一个解析器**（D23 的「一个判据面，不是三处各写一遍」）。
    func testAudioHopLandingParserIsTheSharedCovaCoreOne() throws {
        let requesting = url("https://covalink.cn/api/tracks/one/deep/preview-stream")
        let redirect = HTTPURLResponse(
            url: requesting,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/api/tracks/two"]
        )!
        XCTAssertEqual(
            MediaEgressHop.landing(of: redirect, requesting: requesting)?.absoluteString,
            CovaEnvironment.redirectLanding(of: redirect, requesting: requesting)?.absoluteString,
            "音频腿的 Location 解析必须就是 CovaCore 那一个"
        )
        XCTAssertEqual(
            MediaEgressHop.landing(of: redirect, requesting: requesting)?.absoluteString,
            "https://covalink.cn/api/tracks/two"
        )
    }
}

/// `dump` 的收口（反射面断言用）。
private struct DumpCollector: TextOutputStream {
    var output = ""
    mutating func write(_ string: String) { output += string }
}
