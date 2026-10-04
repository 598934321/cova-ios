@testable import CovaFeature
import CovaCore
import Foundation
import XCTest

/// `AccountService`（§7 #4 注销链，2026-10-02 对齐 web v2.65.0）的**出站形状 + 回执分流**判据。
///
/// 与 `StudioLyricsServiceTests` 同一口径：注入假传输层，零真实网络、零真实写入；
/// 钉「发到哪、body 长什么样、2xx/401/410/404/501/4xx/5xx 各落哪一档」——
/// 「暂未上线」「会话过期」「被拒」「可重试」必须分得开。
final class AccountServiceTests: XCTestCase {

    // MARK: 装配（与 StudioLyricsServiceTests 同形，本文件内独立一份，不共享私有类型）

    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse
        private let handler: Handler
        nonisolated(unsafe) private var recorded: [HTTPRequest] = []
        init(_ handler: @escaping Handler) { self.handler = handler }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.append(request)
            return try handler(request)
        }
        var requests: [HTTPRequest] { recorded }
    }

    private struct NoCredentials: APICredentialProviding {
        func currentSession() async throws -> AuthSessionSnapshot? { nil }
        func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
            throw CovaAPIError.unauthorized(apiCode: nil)
        }
    }

    private func service(_ handler: @escaping StubTransport.Handler)
        -> (AccountService, StubTransport) {
        let transport = StubTransport(handler)
        return (
            AccountService(client: CovaAPIClient(transport: transport, credentials: NoCredentials())),
            transport
        )
    }

    private let deleteToken = IdempotentRequestToken(operation: .accountDeletion)

    // MARK: 出站形状

    func testDeletePostsToDeleteAccountPathWithOnlyTheKey() async throws {
        let (account, transport) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        _ = try await account.deleteAccount(token: deleteToken)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/auth/delete-account")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(
            Set(body.keys), ["idempotencyKey"],
            "端点不读体：只有硬边界 5 的幂等键随体携带，不发明 password/pendingUntil 等字段")
        XCTAssertEqual(body["idempotencyKey"] as? String, deleteToken.key.rawValue)
    }

    // MARK: 回执分流

    func testOkIsEffective() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .effective)
    }

    /// 2xx 就算信封不完整也按生效读：端点语义是"立刻注销"，没有受理态那一档可等。
    func testTwoHundredWithoutOkStillReadsAsEffective() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 204, body: Data())
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .effective)
    }

    /// 401 = 凭证失效（会话过期/已被注销吊销）→ `.unauthenticated`：
    /// 屏上只说「登录状态已过期」，**不**说「已注销」。
    func testUnauthorizedReadsAsUnauthenticatedNotDeletion() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 401, body: Data(#"{"error":"请先登录"}"#.utf8))
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .unauthenticated)
    }

    /// 410 Gone：服务端明说账号已经没了 ⇒ 生效态回落。
    func testGoneIsEffective() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 410, body: Data(#"{"error":"gone"}"#.utf8))
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .effective)
    }

    /// 端点下线/不存在：404 与 501 都必须落在「暂未上线」那一档，
    /// **不许**被 4xx 兜底说成「被拒绝」，更不许说成生效。
    func testNotDeployedReadsAsUnavailable() async throws {
        for status in [404, 501] {
            let (account, _) = service { _ in
                HTTPResponse(statusCode: status, body: Data(#"{"error":"not found"}"#.utf8))
            }
            let outcome = try await account.deleteAccount(token: deleteToken)
            XCTAssertEqual(outcome, .unavailable,
                "\(status) 应是端点未上线，不是拒绝")
        }
    }

    /// 其余 4xx → `.rejected`，服务端 `error` 原文透传。
    func testOther4xxPassServerMessageThrough() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 400, body: Data(#"{"error":"请求格式不正确"}"#.utf8))
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .rejected(message: "请求格式不正确"))
    }

    /// 裸码形状的 `error`（全 ASCII 标识符）不透传 —— 屏上不出现英文码。
    func testBareCodeErrorMessageIsDropped() async throws {
        let (account, _) = service { _ in
            HTTPResponse(statusCode: 422, body: Data(#"{"error":"account_locked"}"#.utf8))
        }
        let outcome = try await account.deleteAccount(token: deleteToken)
        XCTAssertEqual(outcome, .rejected(message: nil))
    }

    /// 5xx → `.retryable`（可重试档）：不说"拒了"也不说"没上线"，重放安全（至多撞 401）。
    func testServerErrorIsRetryable() async throws {
        for status in [500, 503] {
            let (account, _) = service { _ in
                HTTPResponse(statusCode: status, body: Data())
            }
            let outcome = try await account.deleteAccount(token: deleteToken)
            XCTAssertEqual(outcome, .retryable, "\(status) 应是可重试档")
        }
    }

    /// 传输层失败**照抛**（`performCoded` 只吞非 2xx）：离线是"没提交"，不是"被拒"。
    /// 抛出的错误经 `CovaAPIError.normalize` 归一，所以它必须落在**可重试的传输档**，
    /// 而不是被折成 `.retryable`/`.rejected` 之类的业务落点。
    func testTransportErrorPropagates() async throws {
        struct Offline: Error {}
        let (account, _) = service { _ in throw Offline() }
        do {
            _ = try await account.deleteAccount(token: deleteToken)
            XCTFail("传输层失败必须抛，不许折成业务落点")
        } catch {
            guard let apiError = error as? CovaAPIError else {
                return XCTFail("传输层失败应归一成 CovaAPIError，实际抛出 \(error)")
            }
            XCTAssertTrue(
                apiError.isRetryable && apiError.httpStatusCode == nil,
                "传输层失败归一后仍是可重试档、不带 HTTP 状态码：\(apiError.redactedDescription)")
        }
    }
}
