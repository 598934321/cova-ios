import XCTest
import CovaCore
import Foundation
@testable import CovaPlayer

/// 私有音频**落盘式**传输（`URLSessionPrivateAudioTransport`）的离线测试。
///
/// 零网络：自定义 `URLProtocol` 在建立 socket 之前就接管请求；且主机刻意用保留的
/// 不可解析 TLD `.invalid` —— 万一桩没接管，结果是「测试变红」而不是真的出网。
/// （对照 `SSETransportConfigurationTests` 的同类做法。）
private final class StubAudioURLProtocol: URLProtocol {
    struct Script {
        var statusCode = 200
        var chunks: [Data] = []
        var contentLength: Int?
        var failure: Error?
        /// 环 4（C2）：**落地权威**。URLSession 自动跟随重定向之后，交给调用方的
        /// `HTTPURLResponse.url` 就是重定向终点那一条（可能是另一台主机）。桩没有 socket、
        /// 也不重放跳转链，因此直接把「重定向之后」的响应形态交出来：`url` 用它。
        /// nil = 未发生重定向（响应的权威就是请求的权威）。
        var landedURLString: String?
        /// 环 4（C2）：落地跳要写的字节（nil = 沿用 `chunks`）。
        var landingChunks: [Data]?
        /// 环 4（C2）：非 HTTP 响应（走 `URLResponse`），用于「响应形态不对就 fail-closed」。
        var respondsAsPlainURLResponse = false
        /// 环 4 第 6 批（MAJ-4）：**响应头与部分字节已交出之后**再抛出的错误 ——
        /// 这才是真实会话被 `invalidateAndCancel()` 时的形态（`bytes(for:)` 已经返回了，
        /// 裸 `-999` 从 `for try await byte` 那一段冒出来）。nil = 正常收尾。
        var midStreamFailure: Error?
        /// 环 4 第 6 批（MAJ-4）：`midStreamFailure` 生效前先交出的块数（默认 1，
        /// 保证「已经写了字节」再失败 —— 零字节失败走的是 `bytes(for:)` 那条已归一的腿）。
        var chunksBeforeFailure = 1
        /// D23（R17-3）：按**请求绝对地址**覆写的脚本 —— 一次传输里出站两次（原请求 +
        /// 传输自己追的那一跳）时，用这一条把第二跳单独脚本化（键不命中就沿用主脚本）。
        var responses: [String: Script] = [:]
        /// D23（R17-3）：响应头 `Location`（跳转目标）。与 `statusCode` 3xx 搭配使用；
        /// nil = 这一条响应不带跳转。
        var location: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script = Script()
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

    static func configure(_ update: Script) {
        lock.lock()
        defer { lock.unlock() }
        script = update
        capturedRequests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    /// 锁内「记录请求 + 取脚本快照」，避免 `startLoading`（URLSession 后台线程）裸读静态可变状态。
    private static func snapshot(for request: URLRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        return script
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scripted = Self.snapshot(for: request)
        // D23：第二跳（传输自己按裁决追出去的那一次）可以单独脚本化；键不命中就沿用主脚本。
        let key = request.url?.absoluteString ?? ""
        let current = scripted.responses[key] ?? scripted
        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var headers: [String: String] = ["Content-Type": "audio/mp4"]
        if let length = current.contentLength {
            headers["Content-Length"] = String(length)
        }
        // D23：3xx + Location 是「服务端要求换地址」的唯一载体（跳转目标不许是签名地址，
        // 测试夹具一律用 `.invalid` 保留 TLD）。
        if let location = current.location {
            headers["Location"] = location
        }
        let body = current.landingChunks ?? current.chunks
        let target = current.landedURLString.flatMap(URL.init(string:)) ?? request.url!
        let response: URLResponse
        if current.respondsAsPlainURLResponse {
            response = URLResponse(
                url: target,
                mimeType: "audio/mp4",
                expectedContentLength: body.reduce(0) { $0 + $1.count },
                textEncodingName: nil
            )
        } else {
            response = HTTPURLResponse(
                url: target,
                statusCode: current.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let midStream = current.midStreamFailure {
            // 先写掉一部分字节再失败：错误从**读循环**里冒出来，而不是从 `bytes(for:)`。
            for chunk in body.prefix(max(0, current.chunksBeforeFailure)) {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocol(self, didFailWithError: midStream)
            return
        }
        for chunk in body {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// D23 用例用：跳转回调的答案盒（`completionHandler` 是 escaping 的，局部 var 捕获在
/// Swift 6 严格并发下不成立；锁内一次性记账，断言在回调之后读）。
private final class RedirectAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var didRecord = false
    private var recorded: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        didRecord = true
        recorded = request
    }

    var didAnswer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRecord
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class PrivateAudioTransportTests: XCTestCase {
    private static let host = "https://audio.invalid"

    private func makeTransport() -> URLSessionPrivateAudioTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        return URLSessionPrivateAudioTransport(session: URLSession(configuration: configuration))
    }

    private func sourceURL(_ path: String = "/private/one.m4a") -> URL {
        URL(string: "\(Self.host)\(path)")!
    }

    private func target(in directory: TemporaryDirectory, name: String = "out.part") -> URL {
        directory.url.appendingPathComponent(name)
    }

    // MARK: - 环 4 · C2：响应权威必须仍是发起那一台主机

    /// C2：URLSession 默认自动跟随**跨主机**重定向，交给调用方的 `HTTPURLResponse.url` 就是
    /// 落地那一条。不在写盘前判，任意主机的字节就会被当作 `file://` 交付播放 ——
    /// 判据必须在 `createFile` 之前，因此被拒时连文件都不该存在（一个字节都不写）。
    ///
    /// 离线口径：桩不重放跳转链（`URLProtocol` 不触发 URLSession 的重定向跟随），而是直接交出
    /// 「落地权威是另一台主机」的响应 —— 那正是传输层唯一能观测到的事实。
    func testCrossHostRedirectIsRejectedBeforeAnyByteIsWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = "https://other-authority.invalid/pawned.m4a"
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [],
            contentLength: nil,
            failure: nil,
            landedURLString: landing,
            landingChunks: [Data(repeating: 0x7f, count: 64)],
            respondsAsPlainURLResponse: false
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: SecretString("stub-token"), to: file, expectedBytes: nil
            )
            XCTFail("落地权威换人必须被拒绝")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .hostRejected(host: "other-authority.invalid"),
                           "跨主机重定向必须按权威不符拒绝：\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "被拒时一个字节都不该写盘")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? ["<读不到目录>"]
        XCTAssertTrue(leftovers.isEmpty, "不该留下任何临时文件：\(leftovers)")
        // 前置条件自证：传输层问的是生产权威，而响应报回来的权威是另一台主机（否则什么都没测到）。
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.url?.host, "audio.invalid")
        XCTAssertNotEqual(captured.first?.url?.absoluteString, landing)
    }

    /// C2 的对照（TD-9：合法工程不得误红）：同权威的重定向（换 path / 换 query）必须正常放行。
    func testSameAuthorityRedirectIsAcceptedAndWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [],
            contentLength: nil,
            failure: nil,
            landedURLString: "https://audio.invalid/private/moved.m4a?sig=rotated",
            landingChunks: [Data(repeating: 0x33, count: 24)],
            respondsAsPlainURLResponse: false
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 24, "同一台主机的落地字节必须照常交付")
        XCTAssertEqual(receipt.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file).count, 24)
    }

    /// C2：`http.url` 取不到（nil）时 fail-closed —— 「不知道字节来自谁」就等于不能写盘。
    /// C2：响应根本不是 `HTTPURLResponse`（没有状态码、没有权威）→ 同样按权威不可知拒绝。
    func testNonHTTPResponseIsRejectedAsHostRejected() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x02, count: 8)],
            contentLength: nil,
            failure: nil,
            respondsAsPlainURLResponse: true
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
            )
            XCTFail("非 HTTP 响应不得被当作可用音频")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .hostRejected(host: "audio.invalid"),
                           "响应形态不可知时点名**发起**那一台（不是整串地址）")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// C2 的纯决策面：origin 归一化与判定表（零 URLSession，把「等价」与「不等价」逐条钉住）。
    func testAuthorityMatchDecisionTable() {
        let base = URL(string: "https://audio.invalid/private/one.m4a?sig=a")!
        XCTAssertEqual(AudioAuthorityMatch.origin(of: base), "https://audio.invalid")
        // query / path / fragment 都不属于权威。
        XCTAssertEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid/other/x.m4a?sig=b#f")!),
            AudioAuthorityMatch.origin(of: base)
        )
        XCTAssertTrue(AudioAuthorityMatch.matches(requestURL: base, responseURL: base))
        // 权威不同（主机、端口、方案）一律不匹配。
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "https://other-authority.invalid/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "https://audio.invalid:8443/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "http://audio.invalid/one.m4a")!
        ), "降级到 http 不是同一权威")
        // 缺信息一律 fail-closed。
        XCTAssertFalse(AudioAuthorityMatch.matches(requestURL: base, responseURL: nil))
        XCTAssertNil(AudioAuthorityMatch.origin(of: nil))
        XCTAssertNil(AudioAuthorityMatch.origin(of: URL(string: "file:///tmp/x.m4a")!))
        // 大小写不敏感（权威比对不能因为服务端回了个大写主机名就误判）。
        XCTAssertTrue(AudioAuthorityMatch.matches(
            requestURL: base,
            responseURL: URL(string: "HTTPS://AUDIO.INVALID/private/one.m4a")!
        ))
        // min-2：规范端口（443）**不**参与权威字符串 —— `covalink.cn` 与 `covalink.cn:443`
        // 是同一台主机，旧口径把端口写进 origin，于是服务端一次合法的重定向就被误杀。
        XCTAssertEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid:443/one.m4a")!),
            "https://audio.invalid"
        )
        XCTAssertEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid:443/one.m4a")!),
            AudioAuthorityMatch.origin(of: base)
        )
        // 非规范端口仍然是「另一台主机」（判定不得因为折叠而变宽）。
        XCTAssertNotEqual(
            AudioAuthorityMatch.origin(of: URL(string: "https://audio.invalid:8443/one.m4a")!),
            AudioAuthorityMatch.origin(of: base)
        )
    }

    /// R16-1 的两条真实形态（2026-09-24 只读核对 `web` 仓
    /// `src/app/api/tracks/[id]/preview-stream/route.ts:47-55`）：
    /// · 未授权 → **同源** 200 的裁剪字节段 ⇒ 权威匹配成立（整库预览能播的那一条腿）；
    /// · 已授权 → 302 到**看起来像**对象存储的别家 host ⇒ 权威换人，一律不认。
    ///
    /// ⚠️ 本用例**不是**在说"已授权那一条腿必须被拒"（R18-4 已改掉那个结论）：落在
    /// **许可名单**那台整曲桶时，出口判定会放行并以「无凭证的公开请求」重发（见
    /// `testCredentialedRedirectOntoTheAudioBucketIsRefollowedWithoutCredentialsAndDeliversBytes`）。
    /// 这里钉的是**投递面的来源证明**：响应的最终权威必须就是发起那一条主机 —— 与它在不在名单上无关。
    /// 守卫**不许**因为「已购用户播不了」就被放宽：它守的是「字节不得来自许可出口之外」。
    func testPreviewStreamSameAuthorityMatchesWhileALookalikeBucketHostDoesNot() {
        let requested = URL(string: "https://covalink.cn/api/tracks/library-0001/preview-stream")!
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(requested), "前置：补全后的相对地址就是生产出口")
        // 同源落地（换 query 也算同一台主机）。
        XCTAssertTrue(AudioAuthorityMatch.matches(
            requestURL: requested,
            responseURL: URL(string: "https://covalink.cn/api/tracks/library-0001/preview-stream?seg=1")!
        ))
        // 形似对象存储、但**不是**发起那一台的落地（假 host，`.invalid` 保留 TLD）。
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: requested,
            responseURL: URL(string: "https://cova-audio-fake.cos.cn-shanghai-legacy.invalid/tracks/full.mp3")!
        ), "别家 host 的落地必须被显式拒绝，而不是悄悄把预览段当整曲交付")
    }

    /// min-2（复审探针同名）：同源判定与出口守卫必须同口径 ——
    /// `isProductionOrigin` 放行 `https://covalink.cn:443`，那么同源判定就不能把它判成另一台主机，
    /// 否则 NEEDS-15 未解锁之前又多了一个人工堵点（合法的带端口重定向被当成权威换人而 `.hostRejected`）。
    func testCanonicalPortMatchesProductionAuthority() {
        let plain = URL(string: "https://covalink.cn/api/media/one.m4a?sig=a")!
        let canonical = URL(string: "https://covalink.cn:443/api/media/one.m4a?sig=b")!
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(plain))
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(canonical), "前置：出口守卫放行规范端口")
        XCTAssertTrue(
            AudioAuthorityMatch.matches(requestURL: plain, responseURL: canonical),
            "min-2：两台「同一台主机」不得被判成换人（合法重定向被误杀）"
        )
        XCTAssertTrue(AudioAuthorityMatch.matches(requestURL: canonical, responseURL: plain))
        // 反向对照（TD-9）：非规范端口与别的 host 一律仍是换人。
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: plain,
            responseURL: URL(string: "https://covalink.cn:8443/api/media/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: plain,
            responseURL: URL(string: "https://cdn.covalink.cn/api/media/one.m4a")!
        ))
        XCTAssertFalse(AudioAuthorityMatch.matches(
            requestURL: plain,
            responseURL: URL(string: "http://covalink.cn/api/media/one.m4a")!
        ))
        // 零主机名/空 host 一律 fail-closed。
        XCTAssertNil(AudioAuthorityMatch.origin(of: URL(string: "https://:443/x")!))
    }

    /// min-2 在真实管道上的那一腿：带 `:443` 的**合法同权威落地**必须照常交付字节，
    /// 而不是在写盘之前被 `.hostRejected` 掐掉。
    func testLandingOnCanonicalPortStillDeliversBytes() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [],
            contentLength: nil,
            failure: nil,
            landedURLString: "https://audio.invalid:443/private/moved.m4a?sig=rotated",
            landingChunks: [Data(repeating: 0x4b, count: 18)],
            respondsAsPlainURLResponse: false,
            midStreamFailure: nil,
            chunksBeforeFailure: 1
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 18, "min-2：规范端口落地不是换权威")
        XCTAssertEqual(try Data(contentsOf: file).count, 18)
    }

    // MARK: - D23（R17-3）：跳转在**出站之前**裁决，而不是在投递时拒绝

    /// 出口面的事实（本组用例的前提，2026-09 探针实测）：
    /// · 真 socket 上 URLSession **会**自动跟随跨主机 302（落地那台确实收到 GET），
    ///   而 `URLProtocol` 桩不触发那套机器 ⇒ 桩只能交出「已经落地」的响应形态（上一段 C2 用例）。
    /// · 因此本组用例钉的是**传输自己那一条跳转腿**：302 + `Location` 交回调用方时，
    ///   追不追这一跳由 D23 的类别裁决决定，而「不追」必须是**一次出站都没有**。
    private static let productionAudioPath = "https://covalink.cn/api/tracks/library-0001/preview-stream"
    /// 许可名单上的公开媒体桶（D23②，形态取自 `web` 仓 `src/lib/page-media.ts:95`）。
    private static let sanctionedCoverLanding =
        "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg"
    /// 整曲桶（**已授权那一条腿的落地**，R18-4 要放行的就是它；名单事实源在 `CovaEnvironment`）。
    private static let sanctionedAudioLanding =
        "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=stub"
    /// 名单外（假 host，`.invalid` 保留 TLD：桩万一没接管，结果是红而不是出网）。
    private static let unsanctionedLanding = "https://other-authority.invalid/pawned.m4a"

    private func hopScript(_ body: Data) -> StubAudioURLProtocol.Script {
        .init(
            statusCode: 200,
            chunks: [],
            contentLength: body.count,
            failure: nil,
            landingChunks: [body],
            responses: [:],
            location: nil
        )
    }

    /// D23①：同一权威内的合法跳转必须由**传输自己**追出去并交付字节（旧实现在这里
    /// 直接把 302 当成 `badStatus(302)` 失败 —— 「自动跟随」已经被出口守卫拿掉了，
    /// 不追就等于把服务端一次正常的换址判成故障）。
    func testSanctionedSameAuthorityRedirectIsFollowedByTheTransportItself() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = "\(Self.productionAudioPath)?seg=2"
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [landing: hopScript(Data(repeating: 0x27, count: 24))],
            location: landing
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("stub-token"),
            to: file,
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 24, "同权威跳转的字节必须照常交付")
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.absoluteString), [Self.productionAudioPath, landing])
        XCTAssertEqual(try Data(contentsOf: file).count, 24)
    }

    /// D23①（非 negotiable 的那一半）+ **R18-4（改的就是这一条）**：带凭证的请求被 302 到
    /// 许可名单上的存储主机时，传输必须**以不带凭证的公开请求重发那一条落地**并正常交付字节。
    ///
    /// 为什么这不是把闸放宽（旧用例读起来像"这里必须拒"）：`Authorization` 一个字节都不出
    /// 生产出口 —— D23① 不可谈判的那一半原样成立；出网的只有服务端自己签发给本账号的那一条
    /// 地址，而 `web` 仓 `src/lib/page-media.ts:122` 今天就把同一个地址公开给浏览器
    /// `<audio src>`（只带 Referer、从不带 Bearer）。旧实现在这里 `.hostRejected` 的真实后果是
    /// **名单里那台桶按构造永远不可达 ⇒ 已购整曲在这个 App 里从未播通过**。
    ///
    /// 本用例同时钉三件正向事实：①第二跳**没有** `Authorization`；②第二跳**一个头都不继承**
    /// （含签名查询 `%2B` 的逐字节保真 —— R17-6 的成果不许在这里退回去）；③字节真的落盘了。
    func testCredentialedRedirectOntoTheAudioBucketIsRefollowedWithoutCredentialsAndDeliversBytes() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        // 签名查询刻意带 `%2B` / `%3D`：解码再编码就会把签名发坏（服务端把 `+` 当空格解）。
        let landing =
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=%2Bx%3D%3D&region=ap-shanghai"
        let body = Data(repeating: 0x6a, count: 4096)
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [landing: hopScript(body)],
            location: landing
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("stub-token"),
            to: file,
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 4096, "已授权那一条腿必须真的拿到整曲字节")
        XCTAssertEqual(try Data(contentsOf: file).count, 4096)
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.absoluteString), [Self.productionAudioPath, landing])
        // ① 两条出站里只有**第一条**（生产出口）带 Bearer。
        XCTAssertEqual(captured.first?.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
        XCTAssertNil(
            captured.last?.value(forHTTPHeaderField: "Authorization"),
            "凭证跟着跳转漂到存储主机 = D23① 的红线"
        )
        // ② 重建的那一条**不带任何**头（不是「剥掉 Authorization」，是「一条都不继承」）。
        XCTAssertTrue(
            captured.last?.allHTTPHeaderFields?.isEmpty ?? false,
            "第二跳长出了继承来的头：\(captured.last?.allHTTPHeaderFields?.keys.sorted() ?? [])"
        )
        XCTAssertEqual(captured.last?.httpMethod, "GET")
        // ③ 签名地址逐字节原样（出口判定只读 host，绝不重编码查询）。
        XCTAssertEqual(captured.last?.url?.absoluteString, landing)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(captured.last?.url), resolvingAgainstBaseURL: false)?
                .percentEncodedQuery,
            "sig=%2Bx%3D%3D&region=ap-shanghai"
        )
    }

    /// 同一条腿在**封面桶**上的形态：裁决看的是「在不在名单上」，不是「这是不是整曲桶」。
    func testCredentialedRedirectOntoTheCoverBucketIsAlsoRefollowedWithoutCredentials() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let body = Data(repeating: 0x11, count: 12)
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [Self.sanctionedCoverLanding: hopScript(body)],
            location: Self.sanctionedCoverLanding
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("stub-token"),
            to: file,
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 12)
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.count, 2, "裁决必须是「跟并交付」，不是「一次都不许多」")
        XCTAssertNil(captured.last?.value(forHTTPHeaderField: "Authorization"))
    }

    /// 凭证**绝不**因为落地在名单上就跟出去（R18-4 之后仍然成立的不变量）。
    /// 刻意从「名单主机实际收到的那一条请求」反着查，而不是只比 `captured[1]` 的序号 ——
    /// 万一将来有人把顺序或跳数改了，这一条仍然指着真事实。
    func testCredentialsNeverReachTheSanctionedBucketAcrossTheWholeHopChain() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = Self.sanctionedAudioLanding
        StubAudioURLProtocol.configure(.init(
            statusCode: 302, chunks: [], contentLength: 0, failure: nil, landingChunks: [],
            responses: [landing: hopScript(Data(repeating: 0x0b, count: 16))], location: landing
        ))
        _ = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("super-secret-stub-token"),
            to: target(in: directory),
            expectedBytes: nil
        )
        let captured = StubAudioURLProtocol.captured()
        let bucketRequests = captured.filter { $0.url?.host == URL(string: landing)?.host }
        XCTAssertEqual(bucketRequests.count, 1, "前置：确实出站到了名单主机（否则本用例恒真）")
        XCTAssertEqual(
            captured.first?.value(forHTTPHeaderField: "Authorization"), "Bearer super-secret-stub-token",
            "前置：生产出口那一条是带了凭证的（否则「没有漏」这句是恒真）"
        )
        for request in bucketRequests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                XCTAssertFalse(value.contains("super-secret-stub-token"), "头 \(name) 带出了凭证")
            }
        }
    }

    /// 新这条腿**没有把界放宽**：名单内两台互相指回去（名单内跳转本来就合法）⇒ 只能靠预算拦。
    /// 超界之后如实报 `badStatus(302)`，预算一次都不许多花，且界内每一次出名单都不带 Bearer。
    func testStrippedCredentialChainIsStillBoundedAndNeverCarriesBearer() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let covers = Self.sanctionedCoverLanding
        let audio = Self.sanctionedAudioLanding
        StubAudioURLProtocol.configure(.init(
            statusCode: 302, chunks: [], contentLength: 0, failure: nil, landingChunks: [],
            responses: [
                covers: .init(statusCode: 302, chunks: [], contentLength: 0, failure: nil,
                              landingChunks: [], responses: [:], location: audio),
                audio: .init(statusCode: 302, chunks: [], contentLength: 0, failure: nil,
                             landingChunks: [], responses: [:], location: covers),
            ],
            location: covers
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("super-secret-stub-token"),
                to: target(in: directory),
                expectedBytes: nil
            )
            XCTFail("名单内自指链也必须被界住")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .badStatus(302), "超界收尾成状态故障，而不是继续出站：\(error)")
        }
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(
            captured.count, 1 + URLSessionPrivateAudioTransport.maximumRedirectHops,
            "出站次数必须正好等于预算（一条都不许多）"
        )
        XCTAssertEqual(captured.first?.value(forHTTPHeaderField: "Authorization"), "Bearer super-secret-stub-token")
        for request in captured.dropFirst() {
            XCTAssertNil(
                request.value(forHTTPHeaderField: "Authorization"),
                "出生产出口之后还有 Bearer：\(request.url?.host ?? "?")"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(in: directory).path), "超界不得留下文件")
    }

    /// 名单主机的**子域**（R18-1 的那个方向）在音频腿上同样不可达：只出站一次。
    func testCredentialedRedirectToASubdomainOfASanctionedHostIsRefusedWithoutAnyEgress() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = "https://x.covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=x"
        StubAudioURLProtocol.configure(.init(
            statusCode: 302, chunks: [], contentLength: 0, failure: nil, landingChunks: [],
            responses: [landing: hopScript(Data(repeating: 0x0c, count: 8))], location: landing
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("stub-token"),
                to: file,
                expectedBytes: nil
            )
            XCTFail("名单当后缀挂甲必须拒")
        } catch let error as PlayerError {
            XCTAssertEqual(
                error,
                .hostRejected(host: "x.covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com"),
                "拒绝要点名**那台真 host**（只有 host，不带 ?sig=）：\(error)"
            )
        }
        XCTAssertEqual(StubAudioURLProtocol.captured().map(\.url?.host), ["covalink.cn"],
                       "被拒的那一跳一个出站都不许多")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// **来源证明（MAJ-10）在剥掉凭证之后仍然成立**：字节必须来自「我们亲手核准的那一条落地」。
    /// 造法：302 指向整曲桶（已核准），而**那一次请求的响应**自称来自另一台主机 ——
    /// 那台也在名单上（封面桶）也一样不行：证明的是「哪一条」，不是「在不在名单上」。
    func testBytesFromALandingOtherThanTheAuthorizedOneAreStillRejectedAfterTheCredentialDrop() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let authorized = Self.sanctionedAudioLanding
        var landingScript = hopScript(Data(repeating: 0x0d, count: 64))
        landingScript.landedURLString = Self.sanctionedCoverLanding
        StubAudioURLProtocol.configure(.init(
            statusCode: 302, chunks: [], contentLength: 0, failure: nil, landingChunks: [],
            responses: [authorized: landingScript], location: authorized
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("stub-token"),
                to: file,
                expectedBytes: nil
            )
            XCTFail("字节来自没被核准的那一条 ⇒ 必须拒绝")
        } catch let error as PlayerError {
            XCTAssertEqual(
                error,
                .hostRejected(host: "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"),
                "点名的必须是**那条自称的**主机（名单内也一样）：\(error)"
            )
        }
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.absoluteString), [Self.productionAudioPath, authorized],
                       "第二跳确实发出了（否则本用例只是恒真地复演旧行为）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "来源不可证时一个字节都不许落盘")
    }

    /// D23③（其余一律关）：名单外主机的 302 同样在发起前被拒 —— 这条腿今天是
    /// 「先出站、落地时再拒」（reviewer 实测），错误码也不对（302 被当成状态码故障）。
    func testCredentialBearingRedirectToUnsanctionedHostIsRefusedWithoutAnyEgress() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [Self.unsanctionedLanding: hopScript(Data(repeating: 0x02, count: 8))],
            location: Self.unsanctionedLanding
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("stub-token"),
                to: file,
                expectedBytes: nil
            )
            XCTFail("名单外主机不得被访问")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .hostRejected(host: "other-authority.invalid"),
                           "出口裁决必须是主机拒绝，不是 badStatus(302)：\(error)")
        }
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.host), ["covalink.cn"], "落地那台一次都不许多：\(captured.compactMap(\.url?.host))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// D23②：**不带凭证**的公开媒体可以跟到许可名单上的存储桶，且追出去那一次
    /// 绝不许带上 Authorization（凭证永远不进名单主机 —— 这是名单放行的前提条件）。
    func testCredentialFreeRedirectOntoTheMediaAllowListIsFollowedWithoutCredentials() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [Self.sanctionedCoverLanding: hopScript(Data(repeating: 0x03, count: 12))],
            location: Self.sanctionedCoverLanding
        ))
        let file = target(in: directory)
        let receipt = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: nil,
            to: file,
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 12, "公开媒体跟到名单桶必须交付字节")
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.absoluteString), [Self.productionAudioPath, Self.sanctionedCoverLanding])
        XCTAssertTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil },
                      "许可名单主机上永远不许出现 Bearer")
    }

    /// D23②的收口（**公开腿：R18-4 一个字都没动它**）：名单内主机之间的跳转仍然要在名单内，
    /// 但**降级到 http / 带 userinfo / 挂甲**一律按名单外处理（形态合法不等于权威合法）。
    /// 点名口径同时钉住：错误里只有 host，path 与查询一概不带出去（硬边界 3）。
    func testCredentialFreeRedirectToDowngradedOrSpoofedHostIsRefused() async throws {
        let bucketHost = "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com"
        for (landing, namedHost) in [
            ("http://\(bucketHost)/covers/LEAK-PATH.jpeg", bucketHost),
            ("https://user@\(bucketHost)/covers/a.jpeg?sig=LEAK-SIG", bucketHost),
            ("https://\(bucketHost).attacker.test/a.jpeg?sig=LEAK-SIG", "\(bucketHost).attacker.test"),
            ("https://evil-myqcloud.com/covers/a.jpeg", "evil-myqcloud.com"),
            ("file:///tmp/pawned.m4a", CovaEnvironment.unnameableHostLabel),
        ] {
            let directory = TemporaryDirectory()
            defer { directory.remove() }
            StubAudioURLProtocol.configure(.init(
                statusCode: 302,
                chunks: [],
                contentLength: 0,
                failure: nil,
                landingChunks: [],
                responses: [landing: hopScript(Data(repeating: 0x04, count: 6))],
                location: landing
            ))
            let file = target(in: directory)
            do {
                _ = try await makeTransport().writeAudio(
                    from: URL(string: Self.productionAudioPath)!,
                    authorization: nil,
                    to: file,
                    expectedBytes: nil
                )
                XCTFail("落地形态不合格却跟进了出站：\(landing)")
            } catch let error as PlayerError {
                XCTAssertEqual(error, .hostRejected(host: namedHost),
                               "落地 \(landing) 必须按名单外拒绝：\(error)")
                for secret in ["LEAK-PATH", "LEAK-SIG", "/covers", "?sig=", "://"] {
                    XCTAssertFalse(error.description.contains(secret), "错误文本带出了地址片段：\(error.description)")
                }
            }
            XCTAssertEqual(StubAudioURLProtocol.captured().count, 1, "落地 \(landing) 不得出站第二次")
        }
    }

    /// 服务端常给相对 `Location`（RFC 9110 §10.2.2 允许）：必须相对**发起那一条请求**解析，
    /// 而不是相对生产根、也不是当字符串拼接。
    func testRelativeRedirectLocationIsResolvedAgainstTheRequestingURL() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let landing = "https://covalink.cn/api/tracks/library-0001/moved.m4a"
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [landing: hopScript(Data(repeating: 0x05, count: 9))],
            location: "/api/tracks/library-0001/moved.m4a"
        ))
        let receipt = try await makeTransport().writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("stub-token"),
            to: target(in: directory),
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 9)
        XCTAssertEqual(StubAudioURLProtocol.captured().last?.url?.absoluteString, landing)
    }

    /// 新代码自己的界：跳转链必须有界（恶意/故障服务端自指 `Location` 不许变成出站风暴）。
    /// 这条对旧实现是恒真（旧实现一跟都不跟），它守的是本次改动引入的能力。
    func testRedirectChainStopsAfterABoundedNumberOfHops() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 302,
            chunks: [],
            contentLength: 0,
            failure: nil,
            landingChunks: [],
            responses: [:],
            location: Self.productionAudioPath
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("stub-token"),
                to: target(in: directory),
                expectedBytes: nil
            )
            XCTFail("自指跳转链必须被界住")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .badStatus(302), "超界必须收尾成可分类的状态错误，而不是继续出站：\(error)")
        }
        let captured = StubAudioURLProtocol.captured()
        XCTAssertGreaterThan(captured.count, 1, "这一条要求传输确实追过跳转")
        XCTAssertLessThanOrEqual(captured.count, 8, "跳转链无界：\(captured.count) 次出站")
    }

    /// 3xx 却没有 `Location`：那是服务端故障，不是出口决定 —— 两类错误不许混成一条。
    func testRedirectWithoutLocationHeaderIsAStatusFailureNotAHostRejection() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        for status in [301, 302, 307] {
            StubAudioURLProtocol.configure(.init(
                statusCode: status, chunks: [], contentLength: 0, failure: nil,
                landingChunks: [], responses: [:], location: nil
            ))
            do {
                _ = try await makeTransport().writeAudio(
                    from: URL(string: Self.productionAudioPath)!,
                    authorization: SecretString("stub-token"),
                    to: target(in: directory, name: "hop-\(status).part"),
                    expectedBytes: nil
                )
                XCTFail("无 Location 的 \(status) 必须失败")
            } catch let error as PlayerError {
                XCTAssertEqual(error, .badStatus(status), "\(status) 无 Location 必须如实报状态码：\(error)")
            }
            XCTAssertEqual(StubAudioURLProtocol.captured().count, 1)
        }
    }

    // MARK: - D23 的纯裁决面（零 URLSession）与守卫接线

    /// `Location` 解析：相对形态相对**发起那一条**解析；形状可疑/空值一律拿不出来。
    func testRedirectLocationParsingRules() {
        func response(_ location: String?, status: Int = 302) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://covalink.cn/api/tracks/one/preview-stream")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: location.map { ["Location": $0] } ?? [:]
            )!
        }
        let requesting = URL(string: "https://covalink.cn/api/tracks/one/deep/preview-stream")!
        XCTAssertEqual(
            MediaEgressHop.landing(of: response("/api/tracks/two"), requesting: requesting)?.absoluteString,
            "https://covalink.cn/api/tracks/two",
            "根相对：基准是发起那一条的 scheme://authority"
        )
        XCTAssertEqual(
            MediaEgressHop.landing(of: response("moved.m4a"), requesting: requesting)?.absoluteString,
            "https://covalink.cn/api/tracks/one/deep/moved.m4a",
            "纯相对：基准是发起那一条整串（RFC 9110 ⇒ 换掉最后一段，不是拼到根上）"
        )
        XCTAssertEqual(
            MediaEgressHop.landing(of: response(Self.sanctionedCoverLanding), requesting: requesting)?.absoluteString,
            Self.sanctionedCoverLanding
        )
        XCTAssertNil(MediaEgressHop.landing(of: response(nil), requesting: requesting), "无 Location 头")
        XCTAssertNil(MediaEgressHop.landing(of: response(""), requesting: requesting), "空 Location")
        XCTAssertNil(MediaEgressHop.landing(of: response("   "), requesting: requesting), "只有空白")
        XCTAssertNil(
            MediaEgressHop.landing(of: response("/api/tracks/two#frag"), requesting: requesting),
            "片段从不外发"
        )
        XCTAssertNil(
            MediaEgressHop.landing(of: response("/api\\..\\evil"), requesting: requesting),
            "反斜杠部分解析器视同 /"
        )
    }

    /// 追出去的那一条请求：类别裁决 + 凭证只沿同一权威（名单主机永远拿不到 Bearer）。
    func testHoppedRequestRebuildKeepsCredentialsOffAllowListedHosts() throws {
        let landingBucket = URL(string: Self.sanctionedCoverLanding)!
        let production = URL(string: Self.productionAudioPath)!
        var credentialled = URLRequest(url: production)
        credentialled.setValue("Bearer stub-token", forHTTPHeaderField: "Authorization")

        // 凭证类 → 名单桶（R18-4）：**建得出来，而且一条凭证都不带**（旧实现这里返回 nil
        // ⇒ 名单里那台桶按构造不可达 ⇒ 已购整曲从未播通）。裁决的是"能不能出站"，
        // 不是"要不要带着头过去"：出得去，但只能以公开请求的身份出去。
        let stripped = try XCTUnwrap(MediaEgressHop.hoppedRequest(
            to: landingBucket, from: credentialled, original: credentialled, timeout: 15
        ), "凭证腿跟到名单桶必须建出一条无凭证请求")
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"), "名单主机一次都拿不到 Bearer")
        XCTAssertTrue(stripped.allHTTPHeaderFields?.isEmpty ?? false,
                      "剥掉凭证不是只剥 Authorization：一条头都不许继承")
        XCTAssertEqual(stripped.url, landingBucket)
        XCTAssertEqual(stripped.httpMethod, "GET")
        XCTAssertEqual(stripped.timeoutInterval, 15)

        // 凭证类 → 同权威：放行且 Bearer 原样延续（同源换址是正常形态）。
        let sameAuthority = URL(string: "\(Self.productionAudioPath)?seg=2")!
        let kept = try XCTUnwrap(MediaEgressHop.hoppedRequest(
            to: sameAuthority, from: credentialled, original: credentialled, timeout: 15
        ))
        XCTAssertEqual(kept.url, sameAuthority)
        XCTAssertEqual(kept.httpMethod, "GET")
        XCTAssertEqual(kept.timeoutInterval, 15)
        XCTAssertEqual(kept.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")

        // 公开媒体类（无凭证）→ 名单桶：放行，且**一个头都不许多**（不继承上一跳）。
        var anonymous = URLRequest(url: production)
        anonymous.setValue("Bearer should-not-exist", forHTTPHeaderField: "X-Stub-Legacy")
        let opened = try XCTUnwrap(MediaEgressHop.hoppedRequest(
            to: landingBucket, from: anonymous, original: anonymous, timeout: 15
        ))
        XCTAssertNil(opened.value(forHTTPHeaderField: "Authorization"), "公开腿不许凭空长出凭证")
        XCTAssertNil(opened.value(forHTTPHeaderField: "X-Stub-Legacy"), "跳转请求由本层重建，不继承上一跳的自定义头")
        XCTAssertEqual(opened.httpMethod, "GET")

        // 名单外落地一律建不出请求（**含带凭证的腿**：过名单 ≠ 过得了挂甲与降级）。
        for refused in [
            Self.unsanctionedLanding,
            "http://covalink.cn/x.m4a",
            "file:///tmp/x.m4a",
            // R18-1 的方向：名单主机的子域（解析得到，但不是那台桶）。
            "https://x.covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/covers/a.jpeg",
            // 名单串当前缀挂甲。
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com.attacker.test/x.mp3",
            // 换区 / 别的桶。
            "https://covalink-audio-1301797874.cos.ap-beijing.myqcloud.com/x.mp3",
            "https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/x.mp3",
            // 规范端口以外的端口：非规范端口就是另一台主机。
            "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com:8443/x.mp3",
        ] {
            let url = try XCTUnwrap(URL(string: refused))
            XCTAssertNil(MediaEgressHop.hoppedRequest(
                to: url, from: anonymous, original: anonymous, timeout: 15
            ), "名单外（公开腿）：\(refused)")
            XCTAssertNil(MediaEgressHop.hoppedRequest(
                to: url, from: credentialled, original: credentialled, timeout: 15
            ), "名单外（凭证腿也不许以「剥了凭证」的名义出去）：\(refused)")
        }
        // 发起腿本身不是生产出口时，凭证类也不许借名单落地（装配漂移关在外面）。
        var foreign = URLRequest(url: URL(string: Self.sanctionedCoverLanding)!)
        foreign.setValue("Bearer stub-token", forHTTPHeaderField: "Authorization")
        XCTAssertNil(MediaEgressHop.hoppedRequest(
            to: URL(string: Self.sanctionedAudioLanding)!, from: foreign, original: foreign, timeout: 15
        ), "凭证类的发起地本身必须仍是生产出口")
    }

    /// 守卫接线（D23 的根因面）：生产那一条建会话的腿**必须**挂上跳转守卫。
    /// 旧实现 `URLSession(configuration:)` 没有 delegate ⇒ URLSession 自己就把 302 跟掉了
    /// （真 socket 上落地主机确实会收到 GET —— 2026-09-25 本地环回探针实测）。
    func testTransportBuiltSessionCarriesTheRedirectGuard() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let stubConfiguration = URLSessionConfiguration.ephemeral
        stubConfiguration.protocolClasses = [StubAudioURLProtocol.self]
        let transport = URLSessionPrivateAudioTransport(configuration: { stubConfiguration })
        XCTAssertFalse(
            transport.currentSessionCarriesRedirectGuard,
            "没人请求就不该建会话（换代只在真正需要时发生）"
        )
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x1a, count: 5)], contentLength: 5, failure: nil
        ))
        _ = try await transport.writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: SecretString("stub-token"),
            to: target(in: directory),
            expectedBytes: nil
        )
        XCTAssertTrue(transport.currentSessionCarriesRedirectGuard, "出口守卫必须在**发起之前**就在位")
        await transport.cancelInFlightTransfers()
        _ = try await transport.writeAudio(
            from: URL(string: Self.productionAudioPath)!,
            authorization: nil,
            to: target(in: directory, name: "second.part"),
            expectedBytes: nil
        )
        XCTAssertTrue(transport.currentSessionCarriesRedirectGuard, "换代之后守卫必须在位（不许只挂第一代）")
        transport.shutDown()
    }

    /// 守卫本体：任何自动跳转都被拒（`completionHandler(nil)`），任务从未被启动 ⇒ 零出站。
    ///
    /// 这是 delegate 方法**本身**的判据（`URLProtocol` 桩不驱动 URLSession 的跳转机器，
    /// 所以「跟了没有」在桩上不可见 —— 那半由上面 `openCheckedStream` 的循环用例承担）。
    func testRedirectGuardRefusesEveryAutomaticRedirectWithoutStartingTheTask() throws {
        // 桩的请求账本是**类级共享**的（跨用例不清零）：先空脚本过一次，把账本清干净，
        // 否则「零出站」这条断言读的是上一个用例留下的数量。
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [], contentLength: 0, failure: nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        let redirectGuard = AudioRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // 任务只创建、**从不 resume** ⇒ 这一条腿一个字节都不许多出设备。
        let task = session.dataTask(with: URLRequest(url: URL(string: Self.productionAudioPath)!))
        let redirect = HTTPURLResponse(
            url: URL(string: Self.productionAudioPath)!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": Self.sanctionedCoverLanding]
        )!
        let answer = RedirectAnswer()
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: Self.sanctionedCoverLanding)!),
            completionHandler: { answer.record($0) }
        )
        XCTAssertTrue(answer.didAnswer, "守卫必须真的回答这个跳转（不回答 = 任务永远挂在那里）")
        XCTAssertNil(answer.request, "守卫必须交出 nil（连名单内的落地也不**自动**跟：跟不跟由 writeAudio 裁决）")
        XCTAssertEqual(StubAudioURLProtocol.captured().count, 0, "任务从未启动 ⇒ 一次出站都不该发生")
    }

    /// 等价变异防线（TD-9 口径）：跳转守卫不许把「拒跟随」写成「取消整个任务」。
    /// 取消会让上层收到裸 `-999` → 被归一成 `.cancelled`，从而**看不见**出口裁决；
    /// 正确形态是把 3xx 原样交回调用方（由 `openCheckedStream` 抛 `.hostRejected`）。
    func testRefusedRedirectStillSurfacesThe302ToTheCaller() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 302, chunks: [], contentLength: 0, failure: nil,
            landingChunks: [], responses: [:], location: Self.unsanctionedLanding
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: URL(string: Self.productionAudioPath)!,
                authorization: SecretString("stub-token"),
                to: target(in: directory),
                expectedBytes: nil
            )
            XCTFail("必须失败")
        } catch let error as PlayerError {
            XCTAssertNotEqual(error, .cancelled, "出口裁决不许长成取消的样子")
            XCTAssertEqual(error, .hostRejected(host: "other-authority.invalid"))
        }
    }

    // MARK: - 环 4 · 第 6 批 MAJ-4：读循环里的取消必须归一，不许算成写失败

    /// MAJ-4：会话被 `invalidateAndCancel()`（登出 / 换号 / 上层取消）之后，在途字节流抛上来的是
    /// 裸 `NSURLErrorDomain/-999`。旧实现里 `for try await byte` 与 `handle.synchronize()`
    /// **都不在任何 `catch` 内**（只有 `bytes(for:)` 那一段做了归一），于是裸错误一路逃到
    /// 准备器 → `writeFailed(-999)` → `missingFile` → **计入失败连击**。
    /// 本用例走的是**真实** `URLSessionPrivateAudioTransport` + 真实读循环。
    func testRealTransportCancellationTerminatesInFlightStream() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x5a, count: 32)],
            contentLength: nil,
            failure: nil,
            respondsAsPlainURLResponse: false,
            midStreamFailure: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            chunksBeforeFailure: 1
        ))
        let file = target(in: directory)
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: SecretString("stub-token"), to: file, expectedBytes: nil
            )
            XCTFail("在途流被作废必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .cancelled, "MAJ-4：读循环里的 -999 必须归一为取消：\(error)")
        }
        let kind = PlaybackCoordinator.kind(for: PlayerError.cancelled)
        XCTAssertEqual(kind, .cancelled)
        XCTAssertFalse(
            PlayerFailure(kind: kind, message: "").countsTowardFailureStreak,
            "取消绝不进 design §9 的失败连击"
        )
        let described = String(describing: PlayerError.cancelled)
        XCTAssertFalse(described.contains("999"), "归一后的错误不回显底层码：\(described)")
    }

    /// MAJ-4 的对照腿（TD-9：判据不许过宽）：读循环里冒出来的**非取消**网络错误仍然是失败，
    /// 而且必须归到「网络类可重试」而不是「写入失败」。
    func testMidStreamNetworkFailureIsNotSilentlyTreatedAsCancellation() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x11, count: 16)],
            contentLength: nil,
            failure: nil,
            respondsAsPlainURLResponse: false,
            midStreamFailure: URLError(.networkConnectionLost),
            chunksBeforeFailure: 1
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
            )
            XCTFail("半路断线必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .badStatus(0), "非取消的流内错误仍按网络失败分类：\(error)")
            XCTAssertTrue(
                PlayerFailure(kind: PlaybackCoordinator.kind(for: error), message: "")
                    .countsTowardFailureStreak,
                "它照旧计入连击（归一不得顺手放宽）"
            )
        }
    }

    /// MAJ-4 的纯函数面：归一判据本身可穷举（零 URLSession，防止「只测了一条真实路径」）。
    func testStreamErrorNormalizationTable() {
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.normalizedStreamError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            ),
            .cancelled
        )
        XCTAssertEqual(URLSessionPrivateAudioTransport.normalizedStreamError(CancellationError()), .cancelled)
        XCTAssertEqual(URLSessionPrivateAudioTransport.normalizedStreamError(PlayerError.cancelled), .cancelled)
        // 已分类的 PlayerError（m14 的短写）原样上抛，不得被顺手改写。
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.normalizedStreamError(PlayerError.writeFailed(ENOSPC)),
            .writeFailed(ENOSPC)
        )
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.normalizedStreamError(URLError(.timedOut)),
            .badStatus(0)
        )
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.normalizedStreamError(
                NSError(domain: NSCocoaErrorDomain, code: 516)
            ),
            .writeFailed(516)
        )
    }

    /// MAJ-3 的出口腿：`cancelInFlightTransfers()` 已从「协议默认空实现」变成**必须实现**，
    /// 真实出口实现的是「掐当前这一代 + 换代」，且之后的请求照常服务。
    func testInFlightCancellationIsARequiredWitnessNotADefaultNoOp() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let transport: any PrivateAudioTransport = makeTransport()
        // 协议面（无具体类型可 `as?`）也必须能调用作废 —— 这就是「义务在类型里」的含义。
        await transport.cancelInFlightTransfers()
        let concrete = try XCTUnwrap(transport as? URLSessionPrivateAudioTransport)
        XCTAssertEqual(concrete.cancellationCount, 1, "没有默认实现可躲：真实出口自己记账了这一次作废")
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x27, count: 9)], contentLength: 9, failure: nil
        ))
        let receipt = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 9, "作废只掐旧代，出口仍在新代服务")
        XCTAssertEqual(concrete.sessionGeneration, 2)
    }

    // MARK: - 环 4 · m12：落盘权限收紧

    func testWrittenFileCarriesOwnerOnlyPermissions() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x55, count: 16)], contentLength: 16, failure: nil
        ))
        let file = target(in: directory)
        _ = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int32Value
        XCTAssertEqual(mode & 0o777, 0o600, "私有音频只能是 owner 可读写（实得 \(String(format: "%04o", mode))）")
        // m12 的反面：任何「组可读 / 其它可读」位都不许出现。
        XCTAssertEqual(mode & 0o077, 0)
    }

    func testFileAttributeTemplateCarriesOnlyTheOwnerReadWriteBits() {
        let raw = URLSessionPrivateAudioTransport.fileAttributes()[.posixPermissions] as? NSNumber
        XCTAssertEqual(raw?.int32Value, 0o600)
        XCTAssertEqual(PrivateAudioPath.fileMode, 0o600)
        XCTAssertEqual(
            Set(URLSessionPrivateAudioTransport.fileAttributes().keys.map(\.rawValue)),
            Set([FileAttributeKey.posixPermissions.rawValue])
        )
    }

    // MARK: - 环 4 · m14：写盘失败与短写都必须被判定

    /// `createFile` 返回 false（父目录不存在 → 不可写）时不得靠「句柄为 nil」猜错误码。
    func testUncreatableDestinationMapsToWriteFailedEINVAL() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x11, count: 16)], contentLength: 16, failure: nil
        ))
        let missingParent = directory.url
            .appendingPathComponent("no-such-directory", isDirectory: true)
            .appendingPathComponent("out.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.deletingLastPathComponent().path))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: missingParent, expectedBytes: nil
            )
            XCTFail("建不出文件必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .writeFailed(EINVAL), "建档失败必须报 EINVAL：\(error)")
        }
    }

    /// m14：短写（实际推进量 < 请求量）必须以 `writeFailed` 抛出，绝不把半截文件当成功。
    func testShortWriteIsRejectedInsteadOfSilentlyTruncated() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x22, count: 40)], contentLength: 40, failure: nil
        ))
        for reportedAdvance in [-1, 0] {
            // `-1` = 少写一字节；`0` = 完全没推进（磁盘满 / 句柄失效的可观测形态）。
            let shortWriter: PrivateAudioChunkWrite = { data, handle in
                if reportedAdvance < 0 {
                    return try URLSessionPrivateAudioTransport.defaultChunkWrite(Data(data.dropLast()), handle)
                }
                return 0
            }
            let file = directory.url.appendingPathComponent("short-\(reportedAdvance).part")
            do {
                _ = try await makeScriptedTransport(chunkWrite: shortWriter).writeAudio(
                    from: sourceURL(), authorization: nil, to: file, expectedBytes: nil
                )
                XCTFail("短写必须被拒绝（推进量 \(reportedAdvance)）")
            } catch let error as PlayerError {
                XCTAssertEqual(error, .writeFailed(ENOSPC), "短写必须报 ENOSPC：\(error)")
            }
        }
    }

    /// 判定面与真实原语的分工：原语如实报推进量，判定始终在管道里。
    func testChunkWritePrimitiveAndJudgement() throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let file = target(in: directory)
        FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: PrivateAudioPath.fileAttributes)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: file.path))
        defer { try? handle.close() }

        let payload = Data(repeating: 0x77, count: 5)
        XCTAssertEqual(
            try URLSessionPrivateAudioTransport.defaultChunkWrite(payload, handle),
            payload.count,
            "生产原语必须如实报告 offsetInFile 的推进量"
        )
        XCTAssertEqual(try Data(contentsOf: file).count, 5)

        let honest = makeScriptedTransport(chunkWrite: { data, handle in try URLSessionPrivateAudioTransport.defaultChunkWrite(data, handle) })
        XCTAssertEqual(try honest.writeChunk(Data([1, 2, 3]), to: handle), 3)
        let lying = makeScriptedTransport(chunkWrite: { _, _ in 2 })
        XCTAssertThrowsError(try lying.writeChunk(Data([1, 2, 3]), to: handle)) { error in
            XCTAssertEqual(error as? PlayerError, .writeFailed(ENOSPC))
        }
    }

    /// m14 的错误分类面：任何底层错误都只以整数码出去（不带路径 / 句柄描述）。
    func testWriteErrorMappingNeverEchoesPaths() throws {
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.mapWriteError(NSError(domain: NSCocoaErrorDomain, code: 516)),
            .writeFailed(EIO)
        )
        XCTAssertEqual(
            URLSessionPrivateAudioTransport.mapWriteError(PlayerError.cancelled),
            .cancelled,
            "已分类的错误必须原样透出（取消不得被改写成 I/O 失败）"
        )
        let described = String(describing: URLSessionPrivateAudioTransport.mapWriteError(
            NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [NSFilePathErrorKey: "/私密/路径"])
        ))
        XCTAssertFalse(described.contains("私密"))
        XCTAssertFalse(described.contains("/"))
    }

    // MARK: - 环 4 · M8：作废在途而不是打死出口

    func testCancelInFlightTransfersAdvancesGenerationAndKeepsExitUsable() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x3d, count: 11)], contentLength: 11, failure: nil
        ))
        let transport = makeTransport()
        XCTAssertEqual(transport.sessionGeneration, 1, "注入的会话就是第 1 代")
        XCTAssertEqual(transport.cancellationCount, 0)
        _ = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )

        await transport.cancelInFlightTransfers()
        let cancellations = transport.cancellationCount
        XCTAssertEqual(cancellations, 1, "作废次数必须可观测（清理真的发生了）")
        XCTAssertEqual(transport.sessionGeneration, 1, "作废只摘走当前这一代，不预生成新会话")

        // 关键（旧行为）：一次性 `invalidateAndCancel()` 之后出口永久不再接受任务。
        let receipt = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory, name: "after-cancel.part"), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 11, "作废在途之后必须仍能服务下一次请求")
        let generation = transport.sessionGeneration
        XCTAssertEqual(generation, 2, "换代而不是打死")

        // 换代是惰性的：连续请求复用同一代（不得每次掐一次就 +1）。
        _ = try await transport.writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory, name: "same-generation.part"), expectedBytes: nil
        )
        XCTAssertEqual(transport.sessionGeneration, 2)
        await transport.cancelInFlightTransfers()
        XCTAssertEqual(transport.cancellationCount, 2)
        XCTAssertEqual(transport.sessionGeneration, 2)
    }

    /// 两次作废之间没有请求时，第二次作废不得凭空造会话（幂等的下线动作）。
    func testConsecutiveCancellationsWithoutTrafficDoNotLeakSessions() async {
        let transport = makeTransport()
        await transport.cancelInFlightTransfers()
        await transport.cancelInFlightTransfers()
        XCTAssertEqual(transport.cancellationCount, 2)
        XCTAssertEqual(transport.sessionGeneration, 1, "没人请求就不该换代")
    }

    func testShutDownIsTerminalWhileCancellationIsNot() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x08, count: 6)], contentLength: 6, failure: nil
        ))
        let transport = makeTransport()
        transport.shutDown()
        do {
            _ = try await transport.writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
            )
            XCTFail("终态下线之后不得再发起任何请求")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(transport.sessionGeneration, 1, "终态下线不得换代（出口没有再服务过）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(in: directory).path))
        transport.invalidateAndCancel()
        XCTAssertEqual(transport.sessionGeneration, 1)
    }

    /// 环 4 用：可注入分块写原语的会话桩（`makeTransport()` 的扩展形态，不动既有夹具）。
    private func makeScriptedTransport(chunkWrite: PrivateAudioChunkWrite? = nil) -> URLSessionPrivateAudioTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAudioURLProtocol.self]
        return URLSessionPrivateAudioTransport(
            session: URLSession(configuration: configuration),
            chunkWrite: chunkWrite
        )
    }

    // MARK: - 正常路径

    func testStreamedBodyIsWrittenToDiskAndReceiptReportsBytes() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let body = Data(repeating: 0x7f, count: 140)
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [body], contentLength: 140, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: SecretString("stub-token-should-never-be-logged"),
            to: target(in: directory),
            expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 140)
        XCTAssertEqual(receipt.expectedBytes, 140)
        XCTAssertEqual(receipt.statusCode, 200)
        XCTAssertTrue(receipt.isComplete)
        let file = target(in: directory)
        let written = try Data(contentsOf: file)
        XCTAssertEqual(written.count, 140)
    }

    func testPayloadCrossingChunkBoundaryIsFullyWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let total = URLSessionPrivateAudioTransport.writeChunkBytes + 7
        let first = Data(repeating: 0x11, count: URLSessionPrivateAudioTransport.writeChunkBytes)
        let second = Data(repeating: 0x22, count: 7)
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [first, second], contentLength: total, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: nil,
            to: target(in: directory),
            expectedBytes: total
        )
        XCTAssertEqual(receipt.bytesWritten, total, "整块 + 残块都必须落盘")
        XCTAssertEqual(try Data(contentsOf: target(in: directory)).count, total)
    }

    func testBearerHeaderIsAttachedAndNeverEchoedThroughReceiptOrError() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let token = "super-secret-token-value"
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([1, 2, 3])], contentLength: 3, failure: nil))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: SecretString(token),
            to: target(in: directory),
            expectedBytes: nil
        )
        let described = String(describing: receipt)
        XCTAssertFalse(described.contains(token), "回执描述不得带出凭证")
        XCTAssertFalse(described.lowercased().contains("authorization"))
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.count, 1)
        let header = captured.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header?.hasPrefix("Bearer "), true, "Bearer 必须由凭证提供器注入")
        XCTAssertEqual(header?.count, "Bearer ".count + token.count)
    }

    func testAbsentAuthorizationSendsNoHeader() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([0])], contentLength: nil, failure: nil))
        _ = try await makeTransport().writeAudio(
            from: sourceURL(),
            authorization: nil,
            to: target(in: directory),
            expectedBytes: nil
        )
        let header = StubAudioURLProtocol.captured().first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(header)
    }

    // MARK: - 状态与错误分类

    func testNon2xxStatusBecomesBadStatusWithCodeOnly() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 503, chunks: [], contentLength: nil, failure: nil))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(),
                authorization: nil,
                to: target(in: directory),
                expectedBytes: nil
            )
            XCTFail("非 2xx 必须抛错")
        } catch let error as PlayerError {
            guard case .badStatus(let code) = error else { return XCTFail("应为 badStatus：\(error)") }
            XCTAssertEqual(code, 503)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(in: directory).path), "错误响应不得留下文件")
    }

    func testTransportFailuresAreClassifiedAsCancellationOrBadStatus() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [], contentLength: nil, failure: URLError(.cancelled)))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
            )
            XCTFail("取消必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .cancelled)
        }

        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [], contentLength: nil, failure: URLError(.networkConnectionLost)
        ))
        do {
            _ = try await makeTransport().writeAudio(
                from: sourceURL(), authorization: nil, to: target(in: directory, name: "lost.part"), expectedBytes: nil
            )
            XCTFail("传输失败必须抛错")
        } catch let error as PlayerError {
            XCTAssertEqual(error, .badStatus(0))
        }
    }

    func testTruncatedAgainstDeclaredLengthIsReportedNotHidden() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200,
            chunks: [Data(repeating: 0x33, count: 10)],
            contentLength: 999,
            failure: nil
        ))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 10)
        XCTAssertEqual(receipt.expectedBytes, 999, "服务端声明的长度必须透传给上层判定")
        XCTAssertFalse(receipt.isComplete)
    }

    func testCallerExpectationIsUsedWhenServerDeclaresNothing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(
            statusCode: 200, chunks: [Data(repeating: 0x44, count: 12)], contentLength: nil, failure: nil
        ))
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: 12
        )
        XCTAssertEqual(receipt.expectedBytes, 12, "无 Content-Length 时退回调用方期望值")
        XCTAssertTrue(receipt.isComplete)
    }

    func testEmptyBodyYieldsZeroByteReceipt() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 204, chunks: [], contentLength: 0, failure: nil))
        // 204 属 2xx：回执必须如实报 0 字节，由上层按「空文件」拒绝（D7「校验非空」）。
        let receipt = try await makeTransport().writeAudio(
            from: sourceURL(), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        XCTAssertEqual(receipt.bytesWritten, 0)
        XCTAssertFalse(receipt.isComplete)
        XCTAssertEqual(receipt.statusCode, 204)
    }

    // MARK: - 生产默认与会话生命周期

    func testDefaultTransportPinsAudioShapedTimeouts() {
        let transport = URLSessionPrivateAudioTransport()
        XCTAssertEqual(URLSessionPrivateAudioTransport.requestTimeout, 15, "建连/首字节超时（大文件读）")
        XCTAssertEqual(URLSessionPrivateAudioTransport.resourceTimeout, 7 * 24 * 60 * 60)
        XCTAssertGreaterThan(URLSessionPrivateAudioTransport.resourceTimeout, 60 * 60)
        XCTAssertGreaterThan(URLSessionPrivateAudioTransport.writeChunkBytes, 0)
        transport.invalidateAndCancel()
    }

    func testGETIsTheOnlyMethodIssued() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        StubAudioURLProtocol.configure(.init(statusCode: 200, chunks: [Data([9])], contentLength: 1, failure: nil))
        _ = try await makeTransport().writeAudio(
            from: sourceURL("/private/two.m4a"), authorization: nil, to: target(in: directory), expectedBytes: nil
        )
        let captured = StubAudioURLProtocol.captured()
        XCTAssertEqual(captured.first?.httpMethod, "GET")
        XCTAssertEqual(captured.first?.url?.host, "audio.invalid")
    }
}
