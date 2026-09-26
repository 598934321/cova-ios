@testable import CovaCore
import Foundation
import XCTest

/// `GET /api/studio/producers` 的契约面（DEVELOPMENT.md §4.6/§4.7 + A10）。
///
/// 本文件只测一件事，但那是整屏的生死：**「空列表」与「解不出来」必须是两件事**。
/// 生产环境今天灰度关闭（`PRODUCER_MODE` 未设 + `NODE_ENV=production`）⇒ 恒回 `{producers:[]}`
/// ⇒ 入口**隐藏**（A10 明写"不是置灰"）。而如果客户端把"读不懂"也读成空列表，
/// 契约一旦漂移（键改名、信封换形状）就会表现为"这个账号没有制作人"——
/// 那句话与"我们读不到你的制作人"在屏上是两句完全不同的话。
final class ProducersDTOTests: XCTestCase {

    // MARK: - 空 vs 解不出来

    func testEmptyListIsDefinitivelyEmptyAndHidesTheEntrance() throws {
        let response = try Fixture.decode(ProducersResponseDto.self, "producers-empty")
        XCTAssertTrue(response.producers.isEmpty)
        XCTAssertEqual(response.unreadableItemCount, 0)
        XCTAssertTrue(response.isDefinitivelyEmpty)
        XCTAssertTrue(response.shouldHideEntrance, "A10：空 ⇒ 不渲染入口，不是置灰")
    }

    /// 信封形状不对 ⇒ **抛**（`CovaAPIClient` 归一成 `CovaAPIError.decoding`）。
    /// 撤掉"严解数组"这一条，这一组用例全绿而上一条变成假话。
    func testMalformedEnvelopesThrowRatherThanReadingAsEmpty() {
        let broken: [Data] = [
            Data("{}".utf8),                          // 没有 producers 键
            Data(#"{"producers":null}"#.utf8),         // 键在但是 null
            Data(#"{"producers":"none"}"#.utf8),       // 类型不对
            Data(#"{"producers":{}}"#.utf8),           // 不是数组
            Data("[]".utf8),                           // 根不是对象
            Data(#"{"items":[]}"#.utf8),               // 键名漂了
            Data("<html>rate limited</html>".utf8),    // 根本不是 JSON
        ]
        for body in broken {
            XCTAssertThrowsError(
                try JSONDecoder().decode(ProducersResponseDto.self, from: body),
                "\(String(decoding: body.prefix(40), as: UTF8.self)) 必须报错，不许静默当空列表"
            )
        }
    }

    /// 「一张都读不出来」不等于「服务端给了零张」：那种形状不许隐藏入口。
    func testAllUnreadableCardsDoNotCountAsAnEmptyFeature() throws {
        let page = try JSONDecoder().decode(
            ProducersResponseDto.self, from: Data(#"{"producers":[{},{"title":"没有 id"}]}"#.utf8)
        )
        XCTAssertTrue(page.producers.isEmpty)
        XCTAssertEqual(page.unreadableItemCount, 2)
        XCTAssertFalse(page.isDefinitivelyEmpty)
        XCTAssertFalse(page.shouldHideEntrance, "读不懂不等于没有，不许把入口收掉")
    }

    /// 数组里的 `null` 元素不许把整份列表判死（非 Optional 元素的数组解码会在调元素 init
    /// **之前**就抛 ⇒ 那一格必须已经收进局部容忍）。
    func testNullElementInsideTheArrayOnlyCostsThatOneCard() throws {
        let page = try JSONDecoder().decode(
            ProducersResponseDto.self,
            from: Data(#"{"producers":[null,{"id":"prod-ok","displayName":"可用"}]}"#.utf8)
        )
        XCTAssertEqual(page.producers.count, 1)
        XCTAssertEqual(page.unreadableItemCount, 1)
        XCTAssertEqual(page.producers.first?.displayTitle, "可用")
    }

    // MARK: - 卡片投影

    func testGreyScaleCardsDecodeEveryContractKey() throws {
        let response = try Fixture.decode(ProducersResponseDto.self, "producers-cards")
        XCTAssertEqual(response.producers.count, 2)
        XCTAssertEqual(response.unreadableItemCount, 0)
        XCTAssertFalse(response.shouldHideEntrance)

        let card = try XCTUnwrap(response.producers.first)
        XCTAssertEqual(card.id, "prod-northern-light")
        XCTAssertEqual(card.displayName, "北光")
        XCTAssertEqual(card.fictional, true, "虚构标注是这一屏的合规边界")
        XCTAssertEqual(card.tagline, "把 demo 做成可上架的母带")
        XCTAssertEqual(card.audience, "独立音乐人 / 短视频创作者")
        XCTAssertEqual(card.greeting, "把你的 demo 交给我，我来出母带。")
        XCTAssertEqual(card.stages.count, 2)
        XCTAssertEqual(card.stages.map(\.id), ["brief", "master"])
        XCTAssertEqual(card.stages.first?.summary, "读你的 demo 与歌词，确认目标版本")
        XCTAssertEqual(card.deliverables.count, 3)
        XCTAssertEqual(card.demoCount, 6)
        XCTAssertEqual(card.cardCount, 2)

        let second = try XCTUnwrap(response.producers.last)
        XCTAssertEqual(second.fictional, false)
        XCTAssertEqual(second.demoCount, 0, "0 就是零个演示 —— 与 nil 不是一回事")
        XCTAssertTrue(second.extensions.isEmpty, "服务端发了空数组，本层就留着空数组")
    }

    func testDeliverableKindsAreTheEightContractValuesPlusRawUnknown() throws {
        let response = try Fixture.decode(ProducersResponseDto.self, "producers-cards")
        let kinds = response.producers.flatMap(\.deliverables).compactMap(\.kind)
        XCTAssertEqual(kinds, [.masterWav, .stemsZip, .copyrightCertificate, .singerAuthorization])
        // 授权类那一族单独可辨（渲染它们要先过合规评审，D12）。
        XCTAssertEqual(
            response.producers.flatMap(\.authorizationDeliverables).compactMap(\.kind),
            [.copyrightCertificate, .singerAuthorization]
        )
        // 词表外的新值保住原拼写，不折成别的档。
        XCTAssertEqual(ProducerDeliverableKind(rawKind: " Dolby_Atmos "), .unknown(" Dolby_Atmos "))
        XCTAssertEqual(ProducerDeliverableKind(rawKind: " Dolby_Atmos ").rawKind, " Dolby_Atmos ")
        XCTAssertEqual(ProducerDeliverableKind(rawKind: "style_remix"), .styleRemix)
        XCTAssertEqual(
            Set(ProducerDeliverableKind.knownRawKinds.keys),
            ["master_mp3", "master_wav", "instrumental_mp3", "instrumental_wav",
             "copyright_certificate", "singer_authorization", "stems_zip", "style_remix"] as Set<String>
        )
    }

    /// `required` / `enabled` 的缺席**不许**被读成 false（那是替服务端说"这项不必须"）。
    func testMissingRequiredAndEnabledFlagsStayNilRatherThanBecomingFalse() throws {
        let response = try Fixture.decode(ProducersResponseDto.self, "producers-cards")
        let second = try XCTUnwrap(response.producers.last)
        let deliverable = try XCTUnwrap(second.deliverables.first)
        XCTAssertNil(deliverable.required, "fixture 里那一项服务端发的是 null")
        XCTAssertTrue(second.requiredDeliverables.isEmpty, "没给 required 就不算必须项")
        XCTAssertNil(deliverable.kind?.isAuthorizationBearing == true ? nil : deliverable.label)

        let first = try XCTUnwrap(response.producers.first)
        XCTAssertEqual(first.requiredDeliverables.count, 2, "master_wav 与版权证明都标了 true")
        XCTAssertEqual(first.requiredDeliverables.compactMap(\.kind), [.masterWav, .copyrightCertificate])

        let off = try XCTUnwrap(first.extensions.first { $0.id == "vocal-tune" })
        XCTAssertFalse(off.isEnabled)
        XCTAssertTrue(off.hasState, "服务端明确说了关，这与没给状态是两件事")
        let stateless = try JSONDecoder().decode(
            ProducersResponseDto.self,
            from: Data(#"{"producers":[{"id":"p","extensions":[{"id":"x","label":"新能力"}]}]}"#.utf8)
        )
        let unknown = try XCTUnwrap(stateless.producers.first?.extensions.first)
        XCTAssertNil(unknown.enabled)
        XCTAssertFalse(unknown.hasState)
        XCTAssertFalse(unknown.isEnabled, "没给状态也不许画成开着")
    }

    /// `fictional` 缺席 ⇒ 既不算真实也不算虚构（那一格标注必须由 UI 单独处理）。
    func testFictionalFlagAbsenceIsItsOwnCaseAndNeverDefaultsToReal() throws {
        let page = try JSONDecoder().decode(
            ProducersResponseDto.self,
            from: Data(#"{"producers":[{"id":"a","displayName":"甲"},{"id":"b","fictional":true,"displayName":"乙"}]}"#.utf8)
        )
        XCTAssertEqual(page.producers.count, 2)
        XCTAssertEqual(page.producersWithUnknownFictional.map(\.id), ["a"])
        let anonymous = try XCTUnwrap(page.producers.first)
        XCTAssertNil(anonymous.fictional)
        XCTAssertFalse(anonymous.hasFictionalFlag)
    }

    /// 计数与名字：缺键 ⇒ nil（**不填 0**、**不回落 id**）。
    func testCountsAndNamesAreNeverInvented() throws {
        let page = try JSONDecoder().decode(
            ProducersResponseDto.self,
            from: Data(#"{"producers":[{"id":"prod-x","displayName":"  ","demoCount":null}]}"#.utf8)
        )
        let card = try XCTUnwrap(page.producers.first)
        XCTAssertNil(card.displayTitle, "空白展示名就是不显示，也不回落内部 id")
        XCTAssertNil(card.demoCount, "读不出就是读不出；0 是一句没有演示的断言")
        XCTAssertNil(card.cardCount, "服务端没发 cardCount 这个键")
        XCTAssertEqual(card.id, "prod-x", "而身份那一格仍然留着")
    }

    /// 卡内的嵌套小节里一个 `null` 元素只丢那一个元素，别的照常（"少一节"≠"没有这张卡"）。
    func testNullInsideANestedSectionKeepsItsSiblings() throws {
        let page = try JSONDecoder().decode(
            ProducersResponseDto.self,
            from: Data(#"{"producers":[{"id":"p","stages":[null,{"id":"s1","label":"混音"},{"id":"s2"}],"deliverables":["坏元素",{"kind":"master_mp3","label":"母带","required":true}]}]}"#.utf8)
        )
        let card = try XCTUnwrap(page.producers.first)
        XCTAssertEqual(card.stages.count, 2, "null 那一节丢掉，另两节留着")
        XCTAssertEqual(card.stages.map(\.id), ["s1", "s2"])
        XCTAssertEqual(card.deliverables.count, 1, "非对象的元素读不出身份，被丢掉")
        XCTAssertEqual(card.deliverables.first?.kind, .masterMp3)
        XCTAssertEqual(card.requiredDeliverables.count, 1)
    }

    func testEndpointPathIsTheDocumentedReadOnlyRoute() {
        XCTAssertEqual(ProducersResponseDto.path, "/api/studio/producers")
        XCTAssertNotNil(CovaEnvironment.makeAPIURL(path: ProducersResponseDto.path))
    }
}
