@testable import CovaFeature
import CovaCore
import Foundation
import XCTest

/// `StudioService` 新加的三条歌词腿（就地保存 / 重做 / 版本回读）。
///
/// 全部走注入的假传输层 ⇒ **零真实网络、零真实写入**：本批评的判据里最重要的一条就是
/// "一次都不碰生产账号的数据"，所以这些用例连一个真 endpoint 都不发。
/// 钉的是**发到哪、带不带幂等键、2xx 与 409 分不分得开** —— 这三件都能判对错，
/// 而"后端会不会接受这份载荷"由服务端自己判（形状出处已逐行写在 `OneStepLyricsEditDTOs.swift`）。
final class StudioLyricsServiceTests: XCTestCase {

    // MARK: 装配

    /// 记录每一次出站并按脚本交回响应（**零真实网络、零真实写入**）。
    ///
    /// 记账不用锁也不做成 actor：`XCTAssertEqual` 的实参是 nonisolated autoclosure，
    /// actor 属性在断言里根本读不到。用例每次只发一条腿、且 `await` 到完成才看账 ⇒
    /// 这里没有并发窗口，`nonisolated(unsafe)` 只是把这层"用例自己保证串行"的前提写明。
    private final class StubTransport: HTTPTransport, @unchecked Sendable {
        typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse
        private let handler: Handler
        nonisolated(unsafe) private var recorded: [HTTPRequest] = []

        init(_ handler: @escaping Handler) { self.handler = handler }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            recorded.append(request)
            return handler(request)
        }

        var requests: [HTTPRequest] { recorded }
    }

    /// 无凭证的凭证面：这些用例不测 401 重放，只要请求能出去、且**不带**任何真 token。
    private struct NoCredentials: APICredentialProviding {
        func currentSession() async throws -> AuthSessionSnapshot? { nil }
        func refreshAccessToken(for snapshot: AuthSessionSnapshot) async throws -> SecretString {
            throw CovaAPIError.unauthorized(apiCode: nil)
        }
    }

    private func service(_ handler: @escaping StubTransport.Handler) -> (StudioService, StubTransport) {
        let transport = StubTransport(handler)
        return (
            StudioService(client: CovaAPIClient(transport: transport, credentials: NoCredentials())),
            transport
        )
    }

    private let cardJSON = """
        {"planCardId": "pc-1", "status": "ready", "sessionId": "s-1", "revision": 7, \
        "snapshotHash": "sha256:abc", "type": "vocal", \
        "title": {"selected": "夜航", "candidates": ["夜航"], "page": 0}, \
        "lyrics": {"source": "generated", "sections": [\
        {"sectionId": "a", "type": "verse", "label": "主歌一", "text": "[主歌一]\\n旧词\\n", "order": 0}], \
        "displayText": "[主歌一]\\n旧词\\n", "generationText": "[主歌一]\\n旧词\\n", "revision": 3}}
        """

    private func plan(_ json: String) -> OneStepPlanCardDto {
        try! JSONDecoder().decode(OneStepPlanCardDto.self, from: Data(json.utf8))
    }

    private func request(for plan: OneStepPlanCardDto) throws -> OneStepLyricsPatchRequestDto {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: plan, sessionID: "s-1"))
        editor.editBody("新写的第二行", at: 0)
        return editor.patchRequest(key: try OneStepLyricsEditToken().key)
    }

    // MARK: 就地保存（不扣费那条腿）

    func testSaveSendsOnePatchToTheCardItselfAndCarriesTheIdempotencyKey() async throws {
        let (studio, transport) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"planCard": {"planCardId": "pc-1", "status": "ready", "revision": 8}, "replayed": false}"#.utf8))
        }
        let outgoing = try request(for: plan(cardJSON))
        let outcome = try await studio.saveLyrics(outgoing)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1, "一次保存就是一次出站，不偷偷补第二次")
        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.url.path, "/api/studio/one-step/plans/pc-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["targetFields"] as? [String], ["lyrics", "titlePool"])
        XCTAssertEqual(body["idempotencyKey"] as? String, outgoing.idempotencyKey.rawValue)
        XCTAssertEqual(request.headers["Authorization"], nil, "无凭证装配下不该凭空长出授权头")

        switch outcome {
        case .saved(let card): XCTAssertEqual(card.revision, 8, "卡面以后端回显的那一份为准")
        default: XCTFail("应当是已保存：\(outcome)")
        }
    }

    /// 同键同载荷的重放**不是第二次写**（`store.ts:374-381`）⇒ 必须是另一个 case，
    /// 否则界面上"已保存"和账上"只写了一次"就各说各话。
    func testReplayedEchoIsDistinguishedFromAFreshWrite() async throws {
        let (studio, _) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"planCard": {"planCardId": "pc-1", "status": "ready"}, "replayed": true}"#.utf8))
        }
        let outcome = try await studio.saveLyrics(try request(for: plan(cardJSON)))
        guard case .replayed = outcome else { return XCTFail("应当是重放：\(outcome)") }
    }

    /// 2xx 的回显读不出来 ⇒ **不能说失败**（说失败会诱导用户再改一遍 = 真·第二次写）。
    func testUnreadableEchoAfterTwoHundredIsLandedNotFailed() async throws {
        let (studio, transport) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"planCard": {"status": "ready"}}"#.utf8))
        }
        let outcome = try await studio.saveLyrics(try request(for: plan(cardJSON)))
        XCTAssertEqual(outcome, .landedWithoutEcho)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMissingEchoInBodyIsLandedNotFailed() async throws {
        let (studio, _) = service { _ in HTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        let outcome = try await studio.saveLyrics(try request(for: plan(cardJSON)))
        XCTAssertEqual(outcome, .landedWithoutEcho)
    }

    /// 409 `conflict`（我在改一份已经过期的卡）与"回显读不出来"必须分得开。
    func testStaleCardConflictIsAThrowAndNeverAnEchoGap() async throws {
        let (studio, _) = service { _ in
            HTTPResponse(statusCode: 409, body: Data(#"{"error":"one-step plan revision is stale","code":"conflict"}"#.utf8))
        }
        do {
            _ = try await studio.saveLyrics(try request(for: plan(cardJSON)))
            XCTFail("409 必须抛，不能吞成已保存")
        } catch {
            XCTAssertEqual(OneStepLyricsEditRejection.classify(error), .staleCard)
            XCTAssertFalse(StudioService.isUnreadableSuccessEcho(error))
        }
    }

    func testNetworkFailureIsNeitherRejectionNorEcho() async throws {
        let (studio, _) = service { _ in HTTPResponse(statusCode: 599, body: Data()) }
        do {
            _ = try await studio.saveLyrics(try request(for: plan(cardJSON)))
            XCTFail("非 2xx 必须抛")
        } catch {
            XCTAssertEqual(OneStepLyricsEditRejection.classify(error), .rejected(status: 599))
            XCTAssertFalse(StudioService.isUnreadableSuccessEcho(error))
            // 归到 UI 能说的那三类里，不新造第四类话术
            XCTAssertTrue(StudioService.classify(error).uiMessage.contains("599"))
        }
    }

    // MARK: 重做（**扣费**那条腿）

    func testRegeneratePostsTheEnvelopeOnlyAndEchoesTheCharge() async throws {
        let (studio, transport) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"planCard": {"planCardId": "pc-1", "status": "ready", "revision": 8}, "replayed": false, "credits": {"turnId": "t-1", "charged": 3, "balance": 44, "insufficient": false}}"#.utf8))
        }
        let key = try OneStepLyricsEditToken().key
        let outcome = try await studio.regenerateLyrics(sessionID: "s-1", plan: plan(cardJSON), key: key)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/studio/one-step/plans/pc-1/lyrics/regenerate")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["sessionId", "expectedRevision", "idempotencyKey"]), "扣费端点一个多余键都不发明")
        XCTAssertEqual(outcome.charged, 3)
        XCTAssertEqual(outcome.balance, 44)
        XCTAssertTrue(outcome.chargeCopy.contains("3 co"), outcome.chargeCopy)
    }

    /// 402 `topup_required` 是"预检拦下、一次模型调用都没发"⇒ 话术必须是**没扣费**，
    /// 且本层绝不自动重试（重试 = 再一次真实计费请求）。
    func testInsufficientBalanceKeepsTheNoChargeFactAndRetriesNothing() async throws {
        let (studio, transport) = service { _ in
            HTTPResponse(statusCode: 402, body: Data(#"{"error":"余额不足","code":"topup_required","balance":0}"#.utf8))
        }
        do {
            _ = try await studio.regenerateLyrics(
                sessionID: "s-1", plan: plan(cardJSON), key: try OneStepLyricsEditToken().key
            )
            XCTFail("402 必须抛")
        } catch {
            let rejection = try XCTUnwrap(OneStepLyricsEditRejection.classify(error))
            XCTAssertEqual(rejection, .insufficientBalance)
            XCTAssertTrue(rejection.userCopy.hasPrefix("这次没有扣费"), rejection.userCopy)
        }
        XCTAssertEqual(transport.requests.count, 1, "服务层不替用户重试扣费请求")
    }

    /// 结算说"扣不动"（`insufficient:true` + `charged:0`）⇒ 话术不许出现"已重做"。
    func testSettlementShortfallSaysNoChargeHappened() async throws {
        let (studio, _) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"credits": {"charged": 0, "balance": 0, "insufficient": true}}"#.utf8))
        }
        let outcome = try await studio.regenerateLyrics(
            sessionID: "s-1", plan: plan(cardJSON), key: try OneStepLyricsEditToken().key
        )
        XCTAssertTrue(outcome.chargeCopy.contains("没能扣费"), outcome.chargeCopy)
        XCTAssertNil(outcome.card, "没回显卡面就是没回显，不拿旧卡冒充新的")
    }

    /// 缺 `revision` ⇒ **一次请求都不发**：没有基线的计费写操作等于让后端替我猜版本。
    func testRegenerateWithoutRevisionSendsNothing() async throws {
        let (studio, transport) = service { _ in HTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        let noRevision = cardJSON.replacingOccurrences(of: "\"revision\": 7,", with: "")
        do {
            _ = try await studio.regenerateLyrics(
                sessionID: "s-1", plan: plan(noRevision), key: try OneStepLyricsEditToken().key
            )
            XCTFail("缺 revision 必须就地拒绝")
        } catch {
            guard let failure = error as? CatalogFailure else {
                return XCTFail("应当归到后端缺口那一类：\(error)")
            }
            if case .backendGap = failure { return }
            XCTFail("应当是后端缺口那一档，实际是 \(failure)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: 版本回读（只读）

    func testLyricVersionsAsksForTheLyricsFieldAndToleratesAnAbsentList() async throws {
        let (studio, transport) = service { _ in
            HTTPResponse(statusCode: 200, body: Data(#"{"versions": [{"field": "lyrics", "version": 1}, {"field": "lyrics", "version": 2}]}"#.utf8))
        }
        let versions = try await studio.lyricVersions(planCardID: "pc-1")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/api/studio/one-step/plans/pc-1/versions")
        XCTAssertTrue(request.url.query?.contains("field=lyrics") ?? false, request.url.query ?? "无 query")
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(
            OneStepLyricsEditingCopy.versionSummary(versions, current: 2), "第 2 版 · 共 2 版"
        )
    }

    /// 后端没给 `versions` 键（或给空）⇒ 空数组，界面退回只报当前版，不印"共 0 版"。
    func testAbsentVersionListDegradesToAnEmptyArray() async throws {
        let (studio, _) = service { _ in HTTPResponse(statusCode: 200, body: Data(#"{"sectionHistory": []}"#.utf8)) }
        let versions = try await studio.lyricVersions(planCardID: "pc-1")
        XCTAssertTrue(versions.isEmpty)
        XCTAssertEqual(OneStepLyricsEditingCopy.versionSummary(versions, current: 3), "第 3 版")
    }
}
