import CovaCore
import XCTest

final class CovaAPIErrorTests: XCTestCase {
    func testClassifyHTTPStatusSuccessReturnsNil() {
        XCTAssertNil(CovaAPIError.classify(httpStatus: 200, apiCode: nil))
        XCTAssertNil(CovaAPIError.classify(httpStatus: 204, apiCode: "IGNORED"))
        XCTAssertNil(CovaAPIError.classify(httpStatus: 299, apiCode: nil))
    }

    func testClassifyHTTPStatusMapsUnauthorizedSeparately() {
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 401, apiCode: nil), .unauthorized(apiCode: nil))
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 401, apiCode: "TOKEN_EXPIRED"),
            .unauthorized(apiCode: "TOKEN_EXPIRED")
        )
    }

    func testClassifyHTTPStatusMapsOtherFailures() {
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 400, apiCode: "INVALID"),
            .httpStatus(code: 400, apiCode: "INVALID")
        )
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 402, apiCode: "INSUFFICIENT_CREDITS"),
            .httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS")
        )
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 302, apiCode: nil), .httpStatus(code: 302, apiCode: nil))
        XCTAssertEqual(CovaAPIError.classify(httpStatus: 500, apiCode: nil), .httpStatus(code: 500, apiCode: nil))
    }

    func testClassifyBodyExtractsBusinessCode() throws {
        let withCode = try Fixture.data("error-envelope-code")
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 402, body: withCode),
            .httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS")
        )
        XCTAssertNil(CovaAPIError.classify(httpStatus: 200, body: withCode))
    }

    func testClassifyBodyToleratesRealErrorWithoutCode() throws {
        // 真实公共错误响应（404）只有 {error}，没有 code
        let real = try Fixture.data("error-envelope")
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 404, body: real),
            .httpStatus(code: 404, apiCode: nil)
        )
    }

    func testClassifyBodyToleratesNonEnvelopePayloads() {
        let malformed = Data("not json at all".utf8)
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 503, body: malformed),
            .httpStatus(code: 503, apiCode: nil)
        )
        let empty = Data()
        XCTAssertEqual(
            CovaAPIError.classify(httpStatus: 401, body: empty),
            .unauthorized(apiCode: nil)
        )
    }

    func testClassifyTransportErrorCodes() {
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorNotConnectedToInternet), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorNetworkConnectionLost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorDataNotAllowed), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCannotConnectToHost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCannotFindHost), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorDNSLookupFailed), .offline)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorTimedOut), .timeout)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: NSURLErrorCancelled), .cancelled)
        XCTAssertEqual(CovaAPIError.classify(transportErrorCode: -1234), .transport(code: -1234))
    }

    func testClassifyDecodingErrorsKeepsFieldPathOnly() throws {
        struct Probe: Decodable {
            let name: String
            enum CodingKeys: String, CodingKey { case name }
        }
        struct Outer: Decodable {
            let values: [Probe]
        }

        let missingKey = Data(#"{"other":1}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: missingKey)
            XCTFail("应因缺少 name 解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: "name"))
        }

        let typeMismatch = Data(#"{"name":123}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: typeMismatch)
            XCTFail("应因类型不符解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: "name"))
        }

        let corrupted = Data("{".utf8)
        do {
            _ = try JSONDecoder().decode(Outer.self, from: corrupted)
            XCTFail("应因 JSON 结构损坏解码失败")
        } catch let error as DecodingError {
            XCTAssertEqual(CovaAPIError.classify(decoding: error), .decoding(field: nil))
        }
    }

    func testHTTPStatusCodeProjection() {
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: nil).httpStatusCode, 401)
        XCTAssertEqual(CovaAPIError.httpStatus(code: 503, apiCode: nil).httpStatusCode, 503)
        XCTAssertNil(CovaAPIError.offline.httpStatusCode)
        XCTAssertNil(CovaAPIError.decoding(field: "x").httpStatusCode)
    }

    func testIsRetryable() {
        XCTAssertTrue(CovaAPIError.offline.isRetryable)
        XCTAssertTrue(CovaAPIError.timeout.isRetryable)
        XCTAssertTrue(CovaAPIError.transport(code: -1).isRetryable)
        XCTAssertTrue(CovaAPIError.httpStatus(code: 500, apiCode: nil).isRetryable)
        XCTAssertTrue(CovaAPIError.httpStatus(code: 429, apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.httpStatus(code: 400, apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.unauthorized(apiCode: nil).isRetryable)
        XCTAssertFalse(CovaAPIError.cancelled.isRetryable)
        XCTAssertFalse(CovaAPIError.invalidResponse.isRetryable)
        XCTAssertFalse(CovaAPIError.decoding(field: nil).isRetryable)
    }

    func testRedactedDescriptionsCarryNoSensitiveData() {
        XCTAssertEqual(CovaAPIError.offline.redactedDescription, "网络不可用")
        XCTAssertEqual(CovaAPIError.timeout.redactedDescription, "请求超时")
        XCTAssertEqual(CovaAPIError.cancelled.redactedDescription, "请求已取消")
        XCTAssertEqual(CovaAPIError.transport(code: -50).redactedDescription, "传输错误(-50)")
        XCTAssertEqual(CovaAPIError.invalidResponse.redactedDescription, "响应格式无效")
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: nil).redactedDescription, "未授权(no_code)")
        XCTAssertEqual(CovaAPIError.unauthorized(apiCode: "TOKEN_EXPIRED").redactedDescription, "未授权(TOKEN_EXPIRED)")
        XCTAssertEqual(
            CovaAPIError.httpStatus(code: 402, apiCode: "INSUFFICIENT_CREDITS").redactedDescription,
            "服务端错误(402/INSUFFICIENT_CREDITS)"
        )
        XCTAssertEqual(CovaAPIError.httpStatus(code: 500, apiCode: nil).redactedDescription, "服务端错误(500/no_code)")
        XCTAssertEqual(CovaAPIError.decoding(field: "title").redactedDescription, "响应解码失败(title)")
        XCTAssertEqual(CovaAPIError.decoding(field: nil).redactedDescription, "响应解码失败(unknown)")

        let signedURL = "https://cdn.invalid/audio/x.mp3?signature=SECRET"
        let descriptions = [
            CovaAPIError.transport(code: -1).redactedDescription,
            CovaAPIError.httpStatus(code: 403, apiCode: "FORBIDDEN").redactedDescription,
            CovaAPIError.decoding(field: "url").redactedDescription
        ]
        for text in descriptions {
            XCTAssertFalse(text.contains("SECRET"))
            XCTAssertFalse(text.contains(signedURL))
            XCTAssertFalse(text.contains("http"))
        }
    }

    func testErrorEnvelopeDecoding() throws {
        let envelope = try Fixture.decode(CovaAPIErrorEnvelope.self, "error-envelope-code")
        XCTAssertEqual(envelope.code, "INSUFFICIENT_CREDITS")
        XCTAssertEqual(envelope.error, "积分不足")

        let real = try Fixture.decode(CovaAPIErrorEnvelope.self, "error-envelope")
        XCTAssertEqual(real.error, "曲目未找到")
        XCTAssertNil(real.code)

        let minimal = try JSONDecoder().decode(CovaAPIErrorEnvelope.self, from: Data("{}".utf8))
        XCTAssertNil(minimal.error)
        XCTAssertNil(minimal.code)
    }

    // MARK: - D23①：出口拒绝的**分类**（错分就等于重试环）

    /// 归一化必须显式认得 `CovaEgressRefusal`，且**带着 host + rule 一起过去**（第 30 批③）。
    ///
    /// 旧口径（本次改动之前）里根本没有这一支 ⇒ 任何出口拒绝都会掉进末尾的
    /// `.transport(code:)`，而 `.transport` 是 `isRetryable == true` ⇒
    /// 「落地主机不对」被上层读成「网络抖了一下」= 刷新/重放环（reviewer 点名的错分面）。
    /// 上一批补了那一支，但把它归成 `.invalidRequestURL` —— 于是 host 在归一那一刻死了，
    /// 屏幕上只剩一句「请求地址非法（已拒绝出站）」⇒ 本批改成 `.egressRefused(refusal)`。
    /// 今天钉着的那两条属性一条都不松：**不可重试** + **绝不等于 `.transport(code:)`**。
    func testEgressRefusalNormalizesToANonRetryableBranch() {
        let refusal = CovaEgressRefusal(host: "evil.invalid", rule: .credentialLeg)
        let normalized = CovaAPIError.normalize(refusal)
        XCTAssertEqual(normalized, .egressRefused(refusal))
        XCTAssertEqual(normalized.egressRefusal, refusal, "host 与 rule 必须活着到归一之后")
        XCTAssertEqual(normalized.egressRefusal?.host, "evil.invalid")
        XCTAssertEqual(normalized.egressRefusal?.rule, .credentialLeg)
        XCTAssertFalse(normalized.isRetryable, "出口裁决不是传输故障：重试不会改变结果")
        XCTAssertNil(normalized.httpStatusCode, "不得被读成 401 ⇒ 不触发刷新重放")
        XCTAssertFalse(normalized.redactedDescription.isEmpty)
        // 第 30 批③的另一半：拒绝不得被读成任何一种传输档（那是刷新/重放环的门）。
        if case .transport = normalized { return XCTFail("出口拒绝被归成 .transport(code:) ⇒ 重试环") }
        XCTAssertNotEqual(normalized, .invalidRequestURL, "拍平回通用错误就是本批要修的那一格")
        // 反面对照（判据不许过宽）：真正的传输故障仍然可重试，本次没顺手收紧别处。
        XCTAssertTrue(CovaAPIError.normalize(URLError(.timedOut)).isRetryable)
        XCTAssertTrue(CovaAPIError.normalize(NSError(domain: "probe.domain", code: 4321)).isRetryable)
        XCTAssertFalse(refusal.isRetryable)
        XCTAssertEqual(refusal.asCovaAPIError, .egressRefused(refusal))
        // `egressRefusal` 只对拒绝分支成立（别让调用方拿着一句"地址非法"去读 host）。
        XCTAssertNil(CovaAPIError.invalidRequestURL.egressRefusal)
        XCTAssertNil(CovaAPIError.transport(code: 4321).egressRefusal)
        // 已经归一的错误再走一次 `normalize` 必须原样返回（`CovaAPIClient.send` 就是这么调的）。
        XCTAssertEqual(CovaAPIError.normalize(normalized), normalized)
    }

    /// 上屏/日志那一句：点名 host，但**只有** host —— 而且两类规则要能分得开。
    /// 第 30 批③的判据：`redactedDescription` 是 UI 与日志共用的面，过去它只说
    /// 「请求地址非法（已拒绝出站）」，谁都不知道是哪一台。
    func testNormalizedEgressRefusalNamesTheHostAndNothingElse() {
        let signed = URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=LEAK-SIGNATURE&a-key=LEAK-KEY")!
        for rule in CovaEgressRefusal.Rule.allCases {
            let refusal = CovaEgressRefusal(
                host: CovaEnvironment.egressHostLabel(of: signed), rule: rule
            )
            let text = CovaAPIError.normalize(refusal).redactedDescription
            XCTAssertTrue(text.contains(refusal.host), "必须看得见是哪一台：\(text)")
            XCTAssertTrue(text.contains(rule.userLabel), "两类规则要在文案上分得开：\(text)")
            for forbidden in ["LEAK-SIGNATURE", "LEAK-KEY", "sig=", "a-key", "?", "/", "tracks", "https", "://"] {
                XCTAssertFalse(text.contains(forbidden), "日志面上屏泄漏 \(forbidden)：\(text)")
            }
            // 上屏串里不许出现英文枚举名（本仓"屏上无英文态名"判据，`rawValue` 只进代码）。
            XCTAssertFalse(text.contains(rule.rawValue), "露出了英文枚举名：\(text)")
        }
        // 两条 rule 的话不同（名单问题 ≠ 出口问题），两个 host 也不同名（同一台 ≠ 另一台）。
        let credential = CovaAPIError.egressRefused(CovaEgressRefusal(host: "a.invalid", rule: .credentialLeg))
        let publicMedia = CovaAPIError.egressRefused(CovaEgressRefusal(host: "a.invalid", rule: .publicMediaLeg))
        let otherHost = CovaAPIError.egressRefused(CovaEgressRefusal(host: "b.invalid", rule: .credentialLeg))
        XCTAssertNotEqual(credential.redactedDescription, publicMedia.redactedDescription)
        XCTAssertNotEqual(credential, otherHost)
        // 取不出 host 时仍是那个占位串，绝不回退成整条地址。
        let unnamed = CovaAPIError.egressRefused(
            CovaEgressRefusal(host: CovaEnvironment.egressHostLabel(of: URL(string: "file:///tmp/pawned.mp3?sig=LEAK")!))
        )
        XCTAssertEqual(unnamed.egressRefusal?.host, CovaEnvironment.unnameableHostLabel)
        XCTAssertFalse(unnamed.redactedDescription.contains("LEAK"))
        XCTAssertFalse(unnamed.redactedDescription.contains("pawned"))
    }

    /// 拒绝必须**点名 host**（桶名/存储区一变要看得见），且一个签名字符都不许带。
    func testEgressRefusalNamesTheOffendingHostAndNothingElse() throws {
        let signed = URL(string: "https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/tracks/full.mp3?sig=LEAK-SIGNATURE&a-key=LEAK-KEY")!
        let refusal = CovaEgressRefusal(
            host: CovaEnvironment.egressHostLabel(of: signed),
            rule: .publicMediaLeg
        )
        XCTAssertTrue(refusal.host == "covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com")
        XCTAssertTrue(refusal.description.contains(refusal.host), "拒绝信息必须看得见是哪台：\(refusal)")
        for secret in ["LEAK-SIGNATURE", "LEAK-KEY", "full.mp3", "sig=", "?"] {
            XCTAssertFalse(refusal.description.contains(secret), "拒绝信息泄漏：\(secret)")
        }
        // 全部描述/反射面（含 `dump` / 数组 / Optional 包裹）都不许带出签名地址的任何片段。
        let rendered = renderAllSurfaces(refusal)
        XCTAssertFalse(rendered.contains("LEAK"), "反射面泄漏签名：\(rendered)")
        XCTAssertFalse(rendered.contains("tracks"), "反射面泄漏路径：\(rendered)")
        XCTAssertEqual(refusal.errorDescription, refusal.description)
        XCTAssertEqual(refusal.rule, .publicMediaLeg)
    }

    /// 取不出 host 时的占位也必须**诚实**：宁可以说「没有主机」，也不能回退成整串地址。
    func testEgressHostLabelFailsClosedToAPlaceholder() {
        XCTAssertEqual(
            CovaEnvironment.egressHostLabel(of: URL(string: "file:///tmp/pawned.mp3?sig=LEAK")!),
            CovaEnvironment.unnameableHostLabel
        )
        let refusal = CovaEgressRefusal(host: CovaEnvironment.unnameableHostLabel)
        XCTAssertTrue(refusal.description.contains(CovaEnvironment.unnameableHostLabel))
        XCTAssertFalse(refusal.description.contains("LEAK"))
        XCTAssertFalse(refusal.description.contains("pawned"))
    }

    /// 两类规则各有各的一句话（D23 的分型在错误面上也要留痕），且都不可重试。
    func testEgressRefusalRulesAreDistinguishable() {
        for rule in CovaEgressRefusal.Rule.allCases {
            let refusal = CovaEgressRefusal(host: "somewhere.invalid", rule: rule)
            XCTAssertFalse(refusal.isRetryable)
            XCTAssertTrue(refusal.description.contains("somewhere.invalid"))
            XCTAssertNotEqual(
                refusal.description,
                CovaEgressRefusal(host: "somewhere.invalid", rule: rule == .credentialLeg ? .publicMediaLeg : .credentialLeg).description,
                "两类拒绝必须说不同的话（名单问题 ≠ 出口问题）"
            )
        }
        XCTAssertEqual(CovaEgressRefusal.Rule.allCases.count, 2)
    }
}
