@testable import CovaCore
import Foundation
import XCTest

/// `CovaAPIClient.performCoded` 的判据（A4 的地基）。
///
/// 这条腿存在的唯一理由：**错误信封里的文案不能死在归一化那一步**。
/// `perform` 把非 2xx 收成 `.httpStatus(code:apiCode:)`，而 `apiCode` 只是信封的 `code` 键
/// —— 402 那一档服务端根本不给 `code`，`error` 值是英文码、数字在 `balance`/`required` 里，
/// 归一化之后全丢。所以「需要文案的端点」自己拿原始结果，由端点级纯函数分诊。
///
/// 因此本文件钉三件事：非 2xx **不抛**、传输与出口失败**照抛**、401 仍走**同一套** single-flight
/// 重放（两条腿共用 `performRaw`，不许各自实现一遍刷新）。
private actor CodedTransport: HTTPTransport {
    static let targetPath = "/api/studio/create/generate"
    static let oldAccess = "ACCESS_TOKEN_PLACEHOLDER"
    static let creditsBody = Data(#"{"error":"credits_insufficient","balance":3,"required":20}"#.utf8)

    enum Mode: Sendable { case creditsInsufficient, offline }
    private let mode: Mode
    private var recorded: [HTTPRequest] = []

    init(mode: Mode) { self.mode = mode }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        switch request.url.path {
        case CovaAuthSession.loginPath: return TestAccount.a.loginResponse
        case CovaAuthSession.mePath: return TestAccount.a.meResponse
        case CovaAuthSession.refreshPath:
            return HTTPResponse(statusCode: 200, body: TestTransportData.refresh)
        case Self.targetPath:
            switch mode {
            case .offline:
                throw CovaAPIError.offline
            case .creditsInsufficient:
                // 旧 token 先撞 401（逼出刷新重放），刷新之后才回真正的业务错误。
                if request.bearerToken == Self.oldAccess {
                    return HTTPResponse(statusCode: 401, body: TestTransportData.unauthorized)
                }
                return HTTPResponse(statusCode: 402, body: Self.creditsBody)
            }
        default:
            return HTTPResponse(statusCode: 404, body: Data())
        }
    }

    func requestCount(path: String) -> Int { recorded.filter { $0.url.path == path }.count }
    func recordedRequests() -> [HTTPRequest] { recorded }
}

final class APIClientCodedOutcomeTests: XCTestCase {

    private func signedInClient(
        mode: CodedTransport.Mode
    ) async throws -> (CovaAPIClient, CodedTransport) {
        let transport = CodedTransport(mode: mode)
        let stack = makeTestStack()
        let session = makeAuthSession(transport: transport, stack: stack)
        try await session.signIn(
            email: "tester@example.invalid", password: SecretString("placeholder")
        )
        return (CovaAPIClient(transport: transport, credentials: session), transport)
    }

    /// 非 2xx **不抛**：状态码与响应体原样交回（否则 A4 的文案无处可取）。
    func testNon2xxIsReturnedNotThrown() async throws {
        let (client, _) = try await signedInClient(mode: .creditsInsufficient)
        let outcome = try await client.performCoded(
            method: .post, path: CodedTransport.targetPath, jsonBody: Data("{}".utf8)
        )
        XCTAssertEqual(outcome.statusCode, 402)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(outcome.body, CodedTransport.creditsBody, "响应体必须逐字节交回")
        // 端点级分诊就吃这一份原始结果（这条断言把两层真的接起来，不是各测各的）。
        let rejection = StudioCreateRejection.classify(
            statusCode: outcome.statusCode, body: outcome.body
        )
        XCTAssertEqual(rejection, .creditsInsufficient(balance: 3, required: 20))
        XCTAssertEqual(rejection.userMessage, "余额不足，本次需要 20 co")
    }

    /// 401 仍走 single-flight 重放**一次**：两条腿共用 `performRaw`，
    /// 撤掉这一条就等于 `performCoded` 自己另写了一套刷新（必然漂移）。
    func testUnauthorizedStillTriggersOneRefreshAndReplay() async throws {
        let (client, transport) = try await signedInClient(mode: .creditsInsufficient)
        let outcome = try await client.performCoded(
            method: .post, path: CodedTransport.targetPath, jsonBody: Data("{}".utf8)
        )
        XCTAssertEqual(outcome.statusCode, 402, "重放之后的结果才是交回给调用方的那一份")
        let refreshes = await transport.requestCount(path: CovaAuthSession.refreshPath)
        XCTAssertEqual(refreshes, 1, "401 只许触发一次刷新")
        let attempts = await transport.requestCount(path: CodedTransport.targetPath)
        XCTAssertEqual(attempts, 2, "原始一次 + 重放一次")
    }

    /// 传输层失败**照抛**：那种情况压根没有一个 HTTP 结果可交（不许伪造一个状态码）。
    func testTransportFailureStillThrowsInsteadOfFakingAnOutcome() async throws {
        let (client, _) = try await signedInClient(mode: .offline)
        do {
            _ = try await client.performCoded(
                method: .post, path: CodedTransport.targetPath, jsonBody: Data("{}".utf8)
            )
            XCTFail("离线必须抛错，而不是回一个假状态码")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .offline)
        }
    }

    /// 2xx 那一档与 `perform` 交给解码器的是同一份字节。
    func testSuccessBodyMatchesWhatPerformWouldDecode() async throws {
        let (client, _) = try await signedInClient(mode: .creditsInsufficient)
        let outcome = try await client.performCoded(
            method: .get, path: CovaAuthSession.mePath
        )
        XCTAssertEqual(outcome.statusCode, 200)
        XCTAssertTrue(outcome.isSuccess)
        let data = try await client.perform(method: .get, path: CovaAuthSession.mePath)
        XCTAssertEqual(outcome.body, data)
    }

    /// 出口守卫不因换腿而松：非生产 origin 的路径压根构造不出请求。
    func testEgressGuardStillAppliesToTheCodedLeg() async throws {
        let (client, _) = try await signedInClient(mode: .creditsInsufficient)
        do {
            _ = try await client.performCoded(method: .get, path: "http://127.0.0.1:3110/api/tracks")
            XCTFail("非生产出口必须被拒（硬边界 2）")
        } catch let error as CovaAPIError {
            XCTAssertEqual(error, .invalidRequestURL)
        }
    }

    /// 回执面不带敏感串：描述/反射只有状态码与字节数（硬边界 3）。
    func testOutcomeDescriptionDoesNotCarryTheBody() {
        let outcome = CovaHTTPOutcome(
            statusCode: 402, body: CodedTransport.creditsBody
        )
        let described = outcome.description
        let debug = outcome.debugDescription
        let reflected = String(reflecting: outcome)
        for text in [described, debug, reflected] {
            XCTAssertFalse(text.contains("credits_insufficient"))
            XCTAssertFalse(text.contains("balance"))
            XCTAssertTrue(text.contains("402"))
        }
        XCTAssertEqual(reflected, described, "反射面与描述面同源，不另开一个泄漏口")
    }
}
