import CovaCore
import XCTest

final class OneStepPlanDTOTests: XCTestCase {
    func testPlanStatusCoversExactlyTwelveContractStates() {
        XCTAssertEqual(OneStepPlanStatus.allCases.count, 12)
        XCTAssertEqual(
            Set(OneStepPlanStatus.allCases.map(\.rawValue)),
            [
                "analyzing", "ready", "patching", "starting", "generating", "media_staging",
                "demos_ready", "delivery_preparing", "rehydrating", "manual_recovery",
                "retryable_failure", "archived"
            ]
        )
    }

    func testPlanStatusDecodesEveryContractValue() throws {
        for status in OneStepPlanStatus.allCases {
            let decoded = try JSONDecoder().decode(
                OneStepPlanStatus.self,
                from: Data("\"\(status.rawValue)\"".utf8)
            )
            XCTAssertEqual(decoded, status)
        }
    }

    func testUnknownPlanStatusFailsDecoding() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(OneStepPlanStatus.self, from: Data("\"cancelled\"".utf8))
        )
    }

    func testPlanTypeDecodesContractValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"vocal\"".utf8)), .vocal)
        XCTAssertEqual(
            try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"instrumental\"".utf8)),
            .instrumental
        )
        XCTAssertThrowsError(try JSONDecoder().decode(OneStepPlanType.self, from: Data("\"choir\"".utf8)))
    }

    func testDecodesFullPlanCardProjection() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        XCTAssertEqual(response.planCards.count, 2)

        let card = response.planCards[0]
        XCTAssertEqual(card.contractVersion, "cova.one-step-plan.v1")
        XCTAssertEqual(card.planCardId, "plan-test-0001")
        XCTAssertEqual(card.sessionId, "session-test-0001")
        XCTAssertEqual(card.cardIndex, 0)
        XCTAssertEqual(card.revision, 4)
        XCTAssertEqual(card.status, .demosReady)
        XCTAssertEqual(card.type, .vocal)
        XCTAssertEqual(card.summary, "夏日广告配乐，明亮流行")
        XCTAssertEqual(card.sourceMessage?.messageId, "msg-test-0001")
        XCTAssertEqual(card.title?.selected, "Summer Signal")
        XCTAssertEqual(card.title?.candidates?.count, 3)
        XCTAssertEqual(card.title?.pageSize, 10)
        XCTAssertEqual(card.title?.total, 50)
        XCTAssertEqual(card.style?.analysisZh?.isEmpty, false)
        XCTAssertEqual(card.style?.promptEn?.isEmpty, false)
        XCTAssertEqual(card.style?.revision, 2)
        XCTAssertEqual(card.variants?.count, 2)
        XCTAssertEqual(card.variants?[0].direction, "melody-led")
        XCTAssertEqual(card.snapshotHash, "snapshot-test")
        XCTAssertEqual(card.credits, 315)
        XCTAssertEqual(card.updatedAt, "2026-09-17T02:00:00.000Z")
    }

    func testDecodesLyricsDocumentSections() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let lyrics = try XCTUnwrap(response.planCards[0].lyrics)
        XCTAssertEqual(lyrics.source, "generated")
        XCTAssertEqual(lyrics.revision, 3)
        XCTAssertEqual(lyrics.operation, "regenerate")
        XCTAssertEqual(lyrics.sections?.count, 2)
        XCTAssertEqual(lyrics.sections?[0].type, "intro")
        XCTAssertEqual(lyrics.sections?[1].label, "副歌")
        XCTAssertEqual(lyrics.sections?[1].order, 1)
        XCTAssertEqual(lyrics.displayText?.contains("夏日信号"), true)
    }

    func testDecodesParametersAndIgnoresUnionTypedFields() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let parameters = try XCTUnwrap(response.planCards[0].parameters)
        XCTAssertEqual(parameters.operation, "create")
        XCTAssertEqual(parameters.vocalGender, "f")
        XCTAssertEqual(parameters.weirdness, 0.3)
        XCTAssertEqual(parameters.styleWeight, 0.7)
        XCTAssertEqual(parameters.targetDurationSec, 120)
        XCTAssertEqual(parameters.durationSec, 120)
        XCTAssertEqual(parameters.bpm, 118)
        XCTAssertEqual(parameters.styleTags, ["A07:instrument:钢琴"])
        XCTAssertEqual(parameters.availableCoverUploadIds, [])
    }

    func testMinimalPlanCardToleratesMissingOptionalBlocks() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        let minimal = response.planCards[1]
        XCTAssertEqual(minimal.planCardId, "plan-test-0002")
        XCTAssertEqual(minimal.status, .analyzing)
        XCTAssertNil(minimal.sessionId)
        XCTAssertNil(minimal.title)
        XCTAssertNil(minimal.style)
        XCTAssertNil(minimal.lyrics)
        XCTAssertNil(minimal.parameters)
        XCTAssertNil(minimal.credits)
        XCTAssertNil(minimal.type)
        XCTAssertNil(minimal.variants)
    }

    func testPlanCardIgnoresUnknownNestedFields() throws {
        let response = try Fixture.decode(OneStepPlanCardsResponseDto.self, "one-step-plan-cards")
        XCTAssertEqual(response.planCards[0].planCardId, "plan-test-0001")
        XCTAssertEqual(response.planCards[0].lyrics?.sourceHash, "hash-test")
    }

    func testMissingPlanCardIdentityFailsDecoding() {
        let json = Data(#"{"planCards":[{"status":"ready"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OneStepPlanCardsResponseDto.self, from: json))
    }

    // MARK: 09 §3-G 参数行（中文标签 + 百分数）—— `OneStepPlanParameterCopy`
    //
    // 这一族用例是"后端原值不得上屏"在**参数行**上的对手测试：`DeliveryProgressPlannerTests`
    // 早就钉住了英文态名不外溢，但那条只管状态机，参数这一族漏了 ⇒ 同一个形状连着犯了三次
    // （`LoginAndMine` 的 `plan.rawValue`、`status.rawValue`、这里的 `weirdness 0.3`）。
    // 判据留在视图里就没有任何用例能钉它，所以裁决面挪到本层、用例也钉在本层。

    /// 参数 DTO 没有 public 成员构造器（只有 `Decodable`）⇒ 用例按**后端真实形态**喂 JSON，
    /// 顺带把"这些键确实解得出来"一起钉住。
    private func parameters(_ json: String) throws -> OneStepPlanParametersDto {
        try JSONDecoder().decode(OneStepPlanParametersDto.self, from: Data(json.utf8))
    }

    func testParameterChipsAreChineseLabelledAndPercentFormatted() throws {
        let parameters = try parameters(
            #"""
            {"operation":"create","vocalGender":"f","weirdness":0.3,"styleWeight":0.65,
             "targetDurationSec":120,"durationSec":120,"bpm":118,
             "styleTags":["A07:instrument:钢琴"],"availableCoverUploadIds":[]}
            """#
        )
        let chips = OneStepPlanParameterCopy.chips(parameters: parameters, type: .vocal)
        XCTAssertEqual(chips, ["演唱", "新建", "演唱者 女声", "时长 120 秒", "自由度 30%", "风格权重 65%"])

        // 反向判据：整行里不许出现一个后端键名或枚举原值（spec 的键值 chips 是"中文键 + 值"）。
        let joined = chips.joined(separator: "|")
        for leak in [
            "weirdness", "styleWeight", "vocalGender", "operation", "targetDurationSec",
            "durationSec", "bpm", "styleTags", "create", "random"
        ] {
            XCTAssertFalse(joined.contains(leak), "参数行外溢了后端原值：\(leak)")
        }
    }

    func testNilParametersProduceNoChips() {
        XCTAssertEqual(OneStepPlanParameterCopy.chips(parameters: nil, type: nil), [])
    }

    func testAbsentParameterRendersNothingInsteadOfZero() throws {
        // 缺一项 = 那一枚不渲染，**不**印成 0% / 0 秒（0 与"后端没给"是两件事，同 04 §4 的 `--` 判据）。
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: try parameters("{}"), type: nil), []
        )
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: try parameters(#"{"weirdness":0.5}"#), type: nil),
            ["自由度 50%"]
        )
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(
                parameters: try parameters(#"{"vocalGender":"m","styleWeight":0.5}"#), type: nil
            ),
            ["演唱者 男声", "风格权重 50%"]
        )
        XCTAssertNil(OneStepPlanParameterCopy.percent(nil))
    }

    func testPercentRoundsInsteadOfTruncating() {
        // 0.7 × 100 在二进制里是 69.99999999999999：截断会印成 69%，而 0–1 单位值的百分数不能差一档。
        XCTAssertEqual(OneStepPlanParameterCopy.percent(0.7), "70%")
        XCTAssertEqual(OneStepPlanParameterCopy.percent(0.65), "65%")
        XCTAssertEqual(OneStepPlanParameterCopy.percent(0.3), "30%")
        // 0 与 1 是合法端点（"没有值"由上面那条 nil 分支负责，不是这里的职责）。
        XCTAssertEqual(OneStepPlanParameterCopy.percent(0), "0%")
        XCTAssertEqual(OneStepPlanParameterCopy.percent(1), "100%")
    }

    func testUnitValueOutsideZeroToOneIsNotFabricatedIntoPercent() throws {
        for value in [1.5, -0.1, 30.0] {
            let parameters = try parameters(#"{"weirdness":\#(value),"styleWeight":\#(value)}"#)
            XCTAssertEqual(
                OneStepPlanParameterCopy.chips(parameters: parameters, type: nil), [],
                "越界值 \(value) 没有规格形态，不该被伪装成百分数"
            )
        }
        XCTAssertNil(OneStepPlanParameterCopy.percent(.nan))
        XCTAssertNil(OneStepPlanParameterCopy.percent(.infinity))
    }

    func testDurationPrefersTargetDurationSecAndShowsOneChip() throws {
        // 09 §3-G：两键同时存在以 `targetDurationSec` 为准（不是"两枚都印"，也不是后者盖掉前者）。
        let both = try parameters(#"{"targetDurationSec":90,"durationSec":240}"#)
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: both, type: nil), ["时长 90 秒"]
        )
        let fallback = try parameters(#"{"durationSec":240}"#)
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: fallback, type: nil), ["时长 240 秒"]
        )
    }

    func testUnknownEnumValuesAreOmittedNotEchoedOrInvented() throws {
        // 认不出的取值：整枚不渲染 —— 既不退回英文键名（那正是本轮要修的），
        // 也不现编一个"看着像"的中文词（`none`/`replace_section` 在 spec 与 web 的表里都没有名字）。
        let unknown = try parameters(#"{"operation":"replace_section","vocalGender":"none"}"#)
        XCTAssertEqual(OneStepPlanParameterCopy.chips(parameters: unknown, type: nil), [])
        XCTAssertNil(OneStepPlanParameterCopy.operationLabel("underpainting"))
        XCTAssertNil(OneStepPlanParameterCopy.operationLabel(nil))
        XCTAssertNil(OneStepPlanParameterCopy.vocalGenderLabel("alto"))
        XCTAssertNil(OneStepPlanParameterCopy.vocalGenderLabel(""))
        // 认得的那几项按 web 的表来（大小写与空白归一，不让后端换个写法就整行消失）。
        XCTAssertEqual(OneStepPlanParameterCopy.operationLabel("  CREATE "), "新建")
        XCTAssertEqual(OneStepPlanParameterCopy.vocalGenderLabel("F"), "女声")
        XCTAssertEqual(OneStepPlanParameterCopy.operationLabel("cover"), "改编")
        XCTAssertEqual(OneStepPlanParameterCopy.operationLabel("extend"), "续写")
        XCTAssertEqual(OneStepPlanParameterCopy.operationLabel("remaster"), "重制")
        XCTAssertEqual(OneStepPlanParameterCopy.vocalGenderLabel("random"), "随机")
    }

    func testTypeDrivesTheInstrumentalChip() throws {
        // 09 §8：「纯音乐由 `type` 决定并显「纯音乐」参数 chip」—— 不靠 `lyrics` 空不空去猜。
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: nil, type: .instrumental), ["纯音乐"]
        )
        XCTAssertEqual(OneStepPlanParameterCopy.typeLabel(.vocal), "演唱")
        // `parameters` 全缺而 `type` 有值 ⇒ 仍然出这一枚（它不来自 parameters）。
        XCTAssertEqual(
            OneStepPlanParameterCopy.chips(parameters: try parameters("{}"), type: .instrumental),
            ["纯音乐"]
        )
    }
}
