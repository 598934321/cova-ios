import CovaCore
import XCTest

/// 编码后 JSON 的**裸线格式探针**：只读 `source` 字符串本身，不经任何客户端类型，
/// 这样「服务端收不收」这一事实不依赖被测代码的措辞。
private struct PlayReportWireProbe: Decodable {
    let source: String
}

/// 播放上报 DTO 与 `POST /api/tracks/play` 的线上契约。
///
/// **本文件的既有期望按更正后的契约重写**（E2）：旧用例钉的是
/// `source == "app-ios"`，而 2026-09-24 线上实证该值被 400 拒绝
/// （`{code:"PLAY_SOURCE_INVALID", error:"播放来源无效"}`），即那条断言钉住的是
/// 一个真实缺陷（播放历史从未被本客户端记录）。改写期望是为了把线格式对准服务端
/// 的闭合 allowlist，不是删断言。
final class PlayReportDTOTests: XCTestCase {
    /// 服务端 source allowlist（闭合集）在本文件里的**独立副本**。
    ///
    /// 刻意不从 `PlayReportSource` 推导：否则「枚举的取值都在 allowlist 内」就退化成
    /// 「枚举等于自己」的自证，任何取值写错都抓不到。
    /// 依据：2026-09-24 线上 400/200 实测 + 后端 `play-history` 模块的字面量列表。
    private let acceptedSources: Set<String> = [
        "discover", "playlist", "project", "track_detail", "player",
    ]

    private func playToken() throws -> IdempotentRequestToken {
        try IdempotentRequestToken(
            operation: .playReport,
            key: IdempotencyKey(validating: IdempotentOperation.playReport.keyPrefix + String(repeating: "0", count: 32))
        )
    }

    private func encodedSource(_ request: PlayReportRequestDto) throws -> String {
        try JSONDecoder().decode(PlayReportWireProbe.self, from: JSONEncoder().encode(request)).source
    }

    // MARK: - 来源：闭合集

    /// 每一个 case 编码出的 `source` 都必须是服务端接受的那五个值之一，
    /// 且整个取值集合与 allowlist **恰好相等**（少一个 = 归因能力缺失，多一个 = 会被 400）。
    func testEverySourceCaseEncodesOntoTheServerAllowlist() throws {
        var observed: Set<String> = []
        for source in PlayReportSource.allCases {
            let wire = try encodedSource(
                try PlayReportRequestDto(trackId: "library-1", source: source, token: playToken())
            )
            XCTAssertTrue(acceptedSources.contains(wire), "服务端会 400 拒绝 source=\"\(wire)\"")
            observed.insert(wire)
        }
        XCTAssertEqual(observed, acceptedSources, "客户端可表达的取值必须与服务端闭合集一一对应")
    }

    /// 唯一「Swift 名字 ≠ 线格式取值」的一支：`trackDetail` 必须写成 `track_detail`。
    func testTrackDetailCaseCarriesTheServerSpelling() throws {
        let wire = try encodedSource(
            try PlayReportRequestDto(trackId: "library-1", source: .trackDetail, token: playToken())
        )
        XCTAssertEqual(wire, "track_detail")
    }

    /// 默认归因：本 App 只有唯一播放面，未指明语境时按 `player` 报（而非自造值）。
    func testDefaultSourceIsThePlayerSurface() throws {
        let wire = try encodedSource(try PlayReportRequestDto(trackId: "library-1", token: playToken()))
        XCTAssertEqual(wire, "player")
    }

    /// 反证 E2：任何一条路径都不再可能把 `app-ios` 写进请求体。
    func testRejectedLegacySourceIsGoneFromEveryCase() throws {
        for source in PlayReportSource.allCases {
            let wire = try encodedSource(
                try PlayReportRequestDto(trackId: "library-1", source: source, token: playToken())
            )
            XCTAssertNotEqual(wire, "app-ios", "旧常量不在服务端 allowlist 内（E2 根因）")
        }
    }

    // MARK: - 请求体字段名（D8 幂等键 + 契约键名）

    func testRequestUsesContractKeysAndFixtureShape() throws {
        let request = try PlayReportRequestDto(trackId: "library-1", token: playToken())
        XCTAssertEqual(request.trackId, "library-1")
        XCTAssertEqual(request.source, .player)
        XCTAssertEqual(
            request.idempotencyKey.rawValue,
            "cova-play-report-00000000000000000000000000000000"
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request),
            fixture: "requests/play-report-request"
        )
    }

    // MARK: - 响应：真实 200 形态

    func testDecodesPlayReportResponse() throws {
        let response = try Fixture.decode(PlayReportResponseDto.self, "play-report-response")
        XCTAssertEqual(response.message, "ok")
        XCTAssertEqual(response.recorded, true)
        XCTAssertEqual(response.idempotentReplay, false)
        XCTAssertEqual(response.authenticated, true)
        XCTAssertEqual(response.play?.trackId, "library-9749cdc210a624de9d0da02e")
        XCTAssertEqual(response.play?.source, "player")
        XCTAssertEqual(response.play?.playedAt?.isEmpty, false)
    }

    /// 线上 200 的键集实测为 `{authenticated, idempotentReplay, message, play, recorded}`。
    ///
    /// 本用例是**响应面的取证**：DTO 五个字段全为可选，故该形态本就解得动（E2 的修复
    /// 不需要动响应结构）；这里把它钉下来，防止日后有人把某个字段改成必填而打破容忍。
    /// JSON 里键的顺序与旧 fixture 不同，并多带一个契约外的 `unknownField`：
    /// 顺序与未知键都不得影响解码。
    func testDecodesTheLiveTwoHundredKeySet() throws {
        let json = Data(
            #"""
            {"authenticated":true,"idempotentReplay":false,"message":"ok",
             "play":{"trackId":"library-1","source":"discover","playedAt":"2026-09-24T06:00:00.000Z"},
             "recorded":true,"unknownField":"契约外新增字段"}
            """#.utf8
        )
        let response = try JSONDecoder().decode(PlayReportResponseDto.self, from: json)
        XCTAssertEqual(response.authenticated, true)
        XCTAssertEqual(response.idempotentReplay, false)
        XCTAssertEqual(response.message, "ok")
        XCTAssertEqual(response.recorded, true)
        XCTAssertEqual(response.play?.source, "discover", "回显可以是 allowlist 内任一值（含其它客户端写的）")
    }

    /// 服务端去重命中：`recorded=false` + `idempotentReplay=true`（上层据此不再重复计数）。
    func testDecodesIdempotentReplayResponse() throws {
        let json = Data(
            #"{"message":"ok","recorded":false,"idempotentReplay":true,"authenticated":true,"play":{"trackId":"t1","source":"player","playedAt":"2026-09-17T03:10:00.000Z"}}"#.utf8
        )
        let response = try JSONDecoder().decode(PlayReportResponseDto.self, from: json)
        XCTAssertEqual(response.recorded, false)
        XCTAssertEqual(response.idempotentReplay, true)
    }

    /// 响应只带部分键（服务端按分支返回）也必须解得动 —— 五个字段全可选的容错面。
    func testDecodesPartialResponseWithoutPlayRecord() throws {
        let response = try JSONDecoder().decode(
            PlayReportResponseDto.self,
            from: Data(#"{"recorded":true,"idempotentReplay":false,"authenticated":true}"#.utf8)
        )
        XCTAssertEqual(response.recorded, true)
        XCTAssertNil(response.play)
        XCTAssertNil(response.message)
    }
}
