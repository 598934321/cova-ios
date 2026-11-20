import CovaUI
import XCTest

/// COVA-142 显式标识的**文案与接线**钉死用例。
///
/// 为什么这几条必须存在：法规要求的三个字面量一旦被谁「顺手润色」，
/// 用户可见文案就变了，而 UI 快照与字符串扫描都发现不了措辞漂移。
/// 这里逐字节钉住，改一个字就必须红。
final class AIMarkTests: XCTestCase {
    /// L1 必须是「AI 生成」——法条原文用「生成合成」。
    ///
    /// 长度钉 5：`A` `I` 空格 `生` `成`。写这条是因为「AI 生成」很容易被改成
    /// 「AI 生成作品」「AI生成」（少空格）这类看似等价的变体，而它们要么变长
    /// 挤坏窄行、要么与 web 侧文案不再逐字节一致。
    func testLevel1IsExactlyTheFourCharacterBadge() {
        XCTAssertEqual(AIMarkText.level1, "AI 生成")
        XCTAssertEqual(AIMarkText.level1.count, 5, "A I 空格 生 成 = 5 个字符")
        XCTAssertEqual(AIMarkText.level1.filter { $0.isWhitespace }.count, 1, "只许一个半角空格")
        XCTAssertFalse(AIMarkText.level1.hasPrefix(" "))
        XCTAssertFalse(AIMarkText.level1.hasSuffix(" "))
    }

    func testLevel2CarriesTheProviderName() {
        XCTAssertEqual(AIMarkText.level2, "本作品由 Cova AI 生成")
        // 第五条要求「服务提供者名称」⇒ 整句必须带主体名，只有「AI 生成」不够。
        XCTAssertTrue(AIMarkText.level2.contains("Cova AI"))
    }

    func testLevel3IsTheFullDeclarationForOffsiteExport() {
        XCTAssertEqual(
            AIMarkText.level3,
            "本作品由 Cova AI（CovaLink）使用人工智能技术生成合成。"
        )
        XCTAssertTrue(AIMarkText.level3.hasSuffix("。"), "完整声明必须以句号收尾")
    }

    func testEnglishUsesTheAdjectivalForm() {
        XCTAssertEqual(AIMarkText.english, "AI-generated")
    }

    /// 禁词守卫：写「AI 创作」就偏离了法条用词（弱化机器参与）。
    func testForbiddenPhraseIsFlagged() {
        XCTAssertEqual(AIMarkText.forbidden, "AI 创作")
        XCTAssertFalse(AIMarkText.level1.contains("创作"))
        XCTAssertFalse(AIMarkText.level2.contains("创作"))
        XCTAssertFalse(AIMarkText.level3.contains("创作"))
    }

    /// 三档强度必须真的是三级：L3 比 L2 长，L2 比 L1 长。
    /// 若谁把三档改成同一句话，用户在不同界面看到的强度就塌成一级。
    func testThreeLevelsAreActuallyTiered() {
        XCTAssertLessThan(AIMarkText.level1.count, AIMarkText.level2.count)
        XCTAssertLessThan(AIMarkText.level2.count, AIMarkText.level3.count)
    }
}
