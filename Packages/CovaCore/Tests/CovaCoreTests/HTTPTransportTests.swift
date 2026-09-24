@testable import CovaCore
import Foundation
import XCTest

final class HTTPTransportTests: XCTestCase {
    private let url = URL(string: "https://covalink.cn/api/tracks/1")!

    func testTimeoutConstantMatchesContract() {
        XCTAssertEqual(URLSessionTransport.timeout, 15)
    }

    func testDefaultSessionUsesEphemeralConfigWithoutCache() {
        let session = URLSessionTransport.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 15)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testMakeURLRequestCarriesMethodHeadersBodyAndTimeout() throws {
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Authorization": "Bearer token-1", "Content-Type": "application/json"],
            body: Data(#"{"a":1}"#.utf8)
        )
        let urlRequest = URLSessionTransport.makeURLRequest(request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.timeoutInterval, 15)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.httpBody, Data(#"{"a":1}"#.utf8))
    }

    func testMapResponseExtractsStatusCodeAndBody() throws {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let mapped = try URLSessionTransport.map(data: Data("body".utf8), response: response)
        XCTAssertEqual(mapped.statusCode, 404)
        XCTAssertEqual(mapped.body, Data("body".utf8))
    }

    func testMapResponseRejectsNonHTTPResponse() {
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(try URLSessionTransport.map(data: Data(), response: response)) { error in
            XCTAssertEqual(error as? CovaAPIError, .invalidResponse)
        }
    }

    func testNormalizePassesThroughCovaAPIError() {
        XCTAssertEqual(CovaAPIError.normalize(CovaAPIError.timeout), .timeout)
    }

    func testNormalizeMapsCancellationError() {
        XCTAssertEqual(CovaAPIError.normalize(CancellationError()), .cancelled)
    }

    func testNormalizeMapsURLErrorsByCode() {
        XCTAssertEqual(CovaAPIError.normalize(URLError(.timedOut)), .timeout)
        XCTAssertEqual(CovaAPIError.normalize(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CovaAPIError.normalize(URLError(.cancelled)), .cancelled)
    }

    func testNormalizeMapsUnknownErrorToTransportCode() {
        let error = NSError(domain: "probe.domain", code: 4321)
        XCTAssertEqual(CovaAPIError.normalize(error), .transport(code: 4321))
    }

    func testRequestDescriptionAndMirrorNeverExposeHeadersOrBody() {
        let token = "LEAK-REQUEST-TOKEN"
        let body = "LEAK-REQUEST-BODY"
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Authorization": "Bearer \(token)", "X-Probe": body],
            body: Data(body.utf8)
        )
        let rendered = renderAllSurfaces(request)
        XCTAssertFalse(rendered.contains(token), "请求描述泄漏 header：\(rendered)")
        XCTAssertFalse(rendered.contains(body), "请求描述泄漏 body：\(rendered)")
        XCTAssertTrue(request.description.contains("POST"))
        XCTAssertTrue(request.description.contains("/api/tracks/1"))
        XCTAssertEqual(request.debugDescription, request.description)
    }

    func testResponseDescriptionAndMirrorNeverExposeBody() {
        let secret = "https://cdn.invalid/audio/x.mp3?signature=LEAK-SIGNED-URL"
        let response = HTTPResponse(statusCode: 200, body: Data(secret.utf8))
        let rendered = renderAllSurfaces(response)
        XCTAssertFalse(rendered.contains(secret), "响应描述泄漏 body：\(rendered)")
        XCTAssertEqual(response.description, "HTTPResponse(status: 200)")
    }

    // MARK: - D23①：带凭证的普通 API 腿，跳转在**出站之前**裁决

    /// 用例共用的生产形态：会话带守卫、腿带 Bearer。
    private func guardedTransport() -> URLSessionTransport {
        URLSessionTransport(session: makeEgressStubSession(withGuard: true))
    }

    private func credentialedRequest(
        path: String = "/api/studio/agent",
        method: HTTPMethod = .post
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: URL(string: "https://covalink.cn\(path)")!,
            headers: ["Authorization": "Bearer stub-token", "Accept": "application/json"],
            body: method == .get ? nil : Data(#"{"a":1}"#.utf8)
        )
    }

    /// 接线（根因面）：生产那条建会话的腿**必须**挂上跳转守卫。
    /// 旧实现 `URLSession(configuration:)` 没有 delegate ⇒ 服务端一次 302 就在任何人裁决
    /// 之前被 URLSession 自己跟掉（2026-09-25 本地环回探针实测：落地那台确实收到 GET）。
    func testDefaultSessionCarriesTheRedirectGuard() {
        let session = URLSessionTransport.makeDefaultSession()
        XCTAssertTrue(
            session.delegate is CredentialedRedirectGuard,
            "凭证类会话必须自带「一律不自动跟随」的守卫"
        )
        XCTAssertNil(session.configuration.urlCache, "无磁盘缓存这条不许被顺手放宽")
    }

    /// 守卫本体：任何自动跳转都被回成 `nil`（连同源的也不**自动**跟：跟不跟由本层裁决）。
    func testRedirectGuardRefusesEveryAutomaticRedirect() {
        let redirectGuard = CredentialedRedirectGuard()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EgressStubURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        // 桩的请求账本是**类级共享**的（跨用例不清零）：先过一次空脚本把账本清干净，
        // 否则「零出站」这条断言读的是上一个用例留下的数量。
        EgressStubURLProtocol.configure(.init(statusCode: 200))
        // 任务只创建、**从不 resume** ⇒ 这一条腿一个字节都不许多出设备。
        let task = session.dataTask(with: URLRequest(url: URL(string: "https://covalink.cn/api/x")!))
        let redirect = HTTPURLResponse(
            url: URL(string: "https://covalink.cn/api/x")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://covalink.cn/api/y"]
        )!
        // `completionHandler` 是 escaping 的：局部 var 捕获在 Swift 6 严格并发下不成立，
        // 用锁内一次性记账的答案盒（与音频层同名夹具同一形状）。
        let answer = RedirectAnswer()
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://covalink.cn/api/y")!),
            completionHandler: { answer.record($0) }
        )
        XCTAssertTrue(answer.didAnswer, "守卫必须真的回答这个跳转（不回答 = 任务永远挂在那里）")
        XCTAssertNil(answer.request, "守卫必须交出 nil（一律不自动跟随，裁决权收归 `CredentialedEgressHop`）")
        XCTAssertTrue(EgressStubURLProtocol.captured().isEmpty, "任务从未启动 ⇒ 一次出站都不该发生")
    }

    /// D23①（跨源那一半）：**带凭证**的腿被 302 到别家 ⇒ 拒绝，且落地那台一次都不许多。
    func testCrossOriginRedirectIsRefusedWithoutAnyEgress() async throws {
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: "https://evil.invalid/api/studio/agent",
            responses: ["https://evil.invalid/api/studio/agent": .init(statusCode: 200, body: Data(#"{"ok":1}"#.utf8))]
        ))
        do {
            _ = try await guardedTransport().send(credentialedRequest())
            XCTFail("跨源跳转必须被拒")
        } catch let refusal as CovaEgressRefusal {
            XCTAssertEqual(refusal, CovaEgressRefusal(host: "evil.invalid", rule: .credentialLeg))
            XCTAssertTrue(refusal.description.contains("evil.invalid"), "拒绝必须点名 host：\(refusal)")
            XCTAssertFalse(refusal.isRetryable, "出口裁决不是「网络抖了一下」：\(refusal)")
        }
        XCTAssertEqual(EgressStubURLProtocol.capturedHosts(), ["covalink.cn"], "落地那台一次都不许多")
    }

    /// D23① 的**非谈判**那一半：许可名单（封面桶）**不构成**凭证类的放行理由。
    func testRedirectOntoTheMediaAllowListIsRefusedForCredentialBearingCalls() async throws {
        let bucket = "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/redirect"
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: bucket,
            responses: [bucket: .init(statusCode: 200, body: Data(#"{"ok":1}"#.utf8))]
        ))
        do {
            _ = try await guardedTransport().send(credentialedRequest())
            XCTFail("带 Bearer 的请求不得跟到存储桶")
        } catch let refusal as CovaEgressRefusal {
            XCTAssertEqual(refusal.host, "covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com")
        }
        XCTAssertEqual(EgressStubURLProtocol.capturedHosts(), ["covalink.cn"])
    }

    /// D23①（同源那一半，TD-9 的反面：合法工程不得误红）：服务端一次正常的换址必须**由本层**追。
    func testSameOriginRedirectIsFollowedByTheTransportItself() async throws {
        let landing = "https://covalink.cn/api/studio/agent?slot=2"
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: landing,
            responses: [landing: .init(statusCode: 200, body: Data(#"{"moved":1}"#.utf8))]
        ))
        let response = try await guardedTransport().send(credentialedRequest())
        XCTAssertEqual(response.statusCode, 200, "同权威跳转的响应必须照常交付")
        XCTAssertEqual(response.body, Data(#"{"moved":1}"#.utf8))
        let captured = EgressStubURLProtocol.captured()
        XCTAssertEqual(captured.map(\.url?.absoluteString), ["https://covalink.cn/api/studio/agent", landing])
        XCTAssertEqual(captured.last?.httpMethod, "GET", "302 之后按 HTTP 语义改 GET（与 URLSession 过去的自动跟随同口径）")
        XCTAssertEqual(
            captured.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer stub-token",
            "同一权威之内凭证延续（判据已保证落地就是这台主机）"
        )
    }

    /// 服务端常给相对 `Location`（RFC 9110 §10.2.2）：必须相对**发起那一条请求**解析。
    func testRelativeRedirectLocationIsResolvedAgainstTheRequestingURL() async throws {
        let landing = "https://covalink.cn/api/studio/moved"
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: "/api/studio/moved",
            responses: [landing: .init(statusCode: 200, body: Data("{}".utf8))]
        ))
        let response = try await guardedTransport().send(credentialedRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(EgressStubURLProtocol.captured().last?.url?.absoluteString, landing)
    }

    /// 形近主机（`covalink.cn` 之后再接一段）不是 covalink.cn：拒，并且如实点名整台。
    func testNearMissHostIsRefusedAndNamedInFull() async throws {
        let landing = "https://covalink.cn.evil.invalid/api/studio/agent"
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: landing,
            responses: [landing: .init(statusCode: 200, body: Data("{}".utf8))]
        ))
        do {
            _ = try await guardedTransport().send(credentialedRequest())
            XCTFail("形近主机必须按别家处理")
        } catch let refusal as CovaEgressRefusal {
            XCTAssertEqual(refusal.host, "covalink.cn.evil.invalid")
        }
        XCTAssertEqual(EgressStubURLProtocol.capturedHosts(), ["covalink.cn"])
    }

    /// userinfo 挂甲：`https://covalink.cn@evil.test/` 真正收到请求的是 `evil.test`。
    func testUserInfoBearingLocationIsRefusedAndNamesTheRealHost() async throws {
        let landing = "https://covalink.cn@evil.invalid/api/studio/agent"
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: landing,
            responses: [landing: .init(statusCode: 200, body: Data("{}".utf8))]
        ))
        do {
            _ = try await guardedTransport().send(credentialedRequest())
            XCTFail("userinfo 形态必须被拒")
        } catch let refusal as CovaEgressRefusal {
            XCTAssertEqual(refusal.host, "evil.invalid", "点名要点对到真收请求的那台：\(refusal)")
        }
        XCTAssertEqual(EgressStubURLProtocol.capturedHosts(), ["covalink.cn"])
    }

    /// 自指 `Location` 不许变成出站风暴：界住之后把 3xx 如实交付（不是伪造成出口决定）。
    func testRedirectChainStopsAfterABoundedNumberOfHops() async throws {
        EgressStubURLProtocol.configure(.init(
            statusCode: 302,
            location: "https://covalink.cn/api/studio/agent"
        ))
        let response = try await guardedTransport().send(credentialedRequest())
        XCTAssertEqual(response.statusCode, 302, "超界之后交付状态码，由上层如实报错")
        XCTAssertEqual(
            EgressStubURLProtocol.captured().count,
            URLSessionTransport.maximumRedirectHops + 1,
            "跳转链必须被界住"
        )
    }

    /// 3xx 却没有 `Location`：那是服务端故障，不是出口决定 —— 两类错误不许混成一条。
    func testRedirectWithoutLocationHeaderIsDeliveredAsStatus() async throws {
        for status in [301, 302, 307] {
            EgressStubURLProtocol.configure(.init(statusCode: status))
            let response = try await guardedTransport().send(
                credentialedRequest(method: .get)
            )
            XCTAssertEqual(response.statusCode, status, "\(status) 无 Location 必须原样交付")
            XCTAssertEqual(EgressStubURLProtocol.captured().count, 1)
        }
    }

    /// 投递面的**第二道**（与音频腿 `AudioAuthorityMatch` 同名，不许拆）：注入式会话挂不上守卫，
    /// 于是「响应的最终权威已经换人」只能在这里拦 —— 判在交付之前，一个字节都不交。
    func testLandedResponseFromAnotherAuthorityIsRefusedByTheSecondGuard() async throws {
        EgressStubURLProtocol.configure(.init(
            statusCode: 200,
            body: Data(#"{"pawned":1}"#.utf8),
            landedURLString: "https://evil.invalid/api/studio/agent"
        ))
        let transport = URLSessionTransport(session: makeEgressStubSession(withGuard: false))
        do {
            _ = try await transport.send(credentialedRequest())
            XCTFail("落地权威换人必须被拒")
        } catch let refusal as CovaEgressRefusal {
            XCTAssertEqual(refusal.host, "evil.invalid")
            XCTAssertTrue(refusal.description.contains("evil.invalid"))
        }
    }

    /// 纯决策面（零 URLSession）：追一跳长什么样 —— 方法/载荷按跳转语义重建，界与形态都收紧。
    func testHopRequestRebuildRules() throws {
        func response(_ status: Int, _ location: String?) -> HTTPURLResponse {
            var headers: [String: String] = [:]
            if let location { headers["Location"] = location }
            return HTTPURLResponse(
                url: URL(string: "https://covalink.cn/api/studio/agent")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }
        var previous = URLRequest(url: URL(string: "https://covalink.cn/api/studio/agent")!)
        previous.httpMethod = "POST"
        previous.timeoutInterval = URLSessionTransport.timeout
        previous.httpBody = Data("body".utf8)
        previous.setValue("Bearer stub-token", forHTTPHeaderField: "Authorization")

        // 非 3xx ⇒ 不追（响应原样交付）。
        XCTAssertNil(try CredentialedEgressHop.request(after: response(200, nil), following: previous, hopsRemaining: 1))
        // 3xx 无 Location ⇒ 同样不追（服务端故障，不是出口决定）。
        XCTAssertNil(try CredentialedEgressHop.request(after: response(302, nil), following: previous, hopsRemaining: 1))
        // 同源 302 ⇒ 追，改 GET 并丢体；超时沿用上一跳（SSE 的 60s 不会被折回 15s）。
        let moved = try XCTUnwrap(try CredentialedEgressHop.request(
            after: response(302, "https://covalink.cn/api/studio/agent?slot=2"),
            following: previous, hopsRemaining: 1
        ))
        XCTAssertEqual(moved.httpMethod, "GET")
        XCTAssertNil(moved.httpBody)
        XCTAssertEqual(moved.timeoutInterval, URLSessionTransport.timeout)
        XCTAssertEqual(moved.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
        // 307/308 ⇒ 方法与体都保留。
        for status in [307, 308] {
            let kept = try XCTUnwrap(try CredentialedEgressHop.request(
                after: response(status, "https://covalink.cn/api/studio/moved"),
                following: previous, hopsRemaining: 1
            ))
            XCTAssertEqual(kept.httpMethod, "POST", "\(status) 必须保留方法")
            XCTAssertEqual(kept.httpBody, Data("body".utf8), "\(status) 必须保留请求体")
        }
        // 跨源 / 名单主机 / 降级形态 ⇒ 抛出点名拒绝（不是返回 nil「当没看见」）。
        for refused in [
            "https://evil.invalid/x",
            "https://covalink.cn.evil.invalid/x",
            "https://covalink-covers-1301797874.cos.ap-shanghai.myqcloud.com/x",
            "http://covalink.cn/x",
            "https://covalink.cn:8443/x",
            "https://covalink.cn@evil.invalid/x",
        ] {
            do {
                _ = try CredentialedEgressHop.request(after: response(302, refused), following: previous, hopsRemaining: 1)
                XCTFail("应当抛出拒绝：\(refused)")
            } catch let error as CovaEgressRefusal {
                XCTAssertFalse(error.isRetryable)
                XCTAssertEqual(error.rule, .credentialLeg)
            }
        }
        // 形状可疑（片段 / 反斜杠）：拿不出落地 ⇒ 不追，交给状态码，而不是猜一条地址。
        XCTAssertNil(try CredentialedEgressHop.request(
            after: response(302, "https://covalink.cn/x#frag"), following: previous, hopsRemaining: 1
        ))
        XCTAssertNil(try CredentialedEgressHop.request(
            after: response(302, "..\\evil"), following: previous, hopsRemaining: 1
        ))
        // 预算耗尽**只关掉「再发一次」**，不许把投递面的兜底一起跳过：
        // 落地权威已经换人的响应在第 6 跳上仍然必须被拒（否则兜底留一个洞）。
        XCTAssertThrowsError(try CredentialedEgressHop.request(
            after: HTTPURLResponse(
                url: URL(string: "https://evil.invalid/api/studio/agent")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!,
            following: previous,
            hopsRemaining: 0
        )) { error in
            XCTAssertEqual((error as? CovaEgressRefusal)?.host, "evil.invalid")
        }
        // 同源落地 + 零预算 ⇒ 不追，也不误报（响应原样交付，由调用方按状态码映射）。
        XCTAssertNil(try CredentialedEgressHop.request(
            after: HTTPURLResponse(
                url: URL(string: "https://covalink.cn/api/studio/moved")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!,
            following: previous,
            hopsRemaining: 0
        ))
    }
}
