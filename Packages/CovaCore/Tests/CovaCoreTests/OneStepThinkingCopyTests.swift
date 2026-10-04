import CovaCore
import XCTest

/// 09 §3.E thinking 公开短语裁决层（与 web `progress-status.ts` 同构表）的钉法。
///
/// 钉三件事：① 内部实现词（verifier / schema repair / constraint retry 一族）**永不**穿出；
/// ② 阶段判定与 refining 判定逐字对齐 web；③ 判不出来/空输入落 plan 档兜底句
/// 「正在整理计划细节」（09 §3.E 点名的那一句）。
final class OneStepThinkingCopyTests: XCTestCase {

    /// spec 逐字点名的三个未公开化字样，命中后必须落成公开短语。
    func testInternalImplementationTermsNeverPassThrough() {
        let cases = [
            "schema repair: fixing section 3",
            "verifier failed on constraint",
            "constraint retry pass 2",
        ]
        for raw in cases {
            let phrase = OneStepThinkingCopy.publicPhrase(raw)
            for term in ["schema repair", "verifier", "constraint", "retry", "repair"] {
                XCTAssertFalse(
                    phrase.lowercased().contains(term),
                    "\(raw) → \(phrase) 泄漏了内部词 \(term)"
                )
            }
        }
    }

    /// 与 web `resolveProgressStage` 逐字对齐的阶段裁决。
    func testStageResolutionMatchesWebTable() {
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("正在创作歌词第二段"),
            "正在创作歌词"
        )
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("designing style prompt"),
            "正在设计曲风"
        )
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("title candidates ready"),
            "正在构思候选曲名"
        )
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("requirement analysis"),
            "正在理解你的创作需求"
        )
    }

    /// web `ONE_STEP_REFINEMENT_MARKERS` 命中 → refining 档短语（同一张表、同一中文）。
    func testRefinementMarkersSwitchToRefiningPhrases() {
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("retry lyrics section"),
            "正在完善歌词结构"
        )
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("重新核对曲风"),
            "正在完善曲风方向"
        )
    }

    /// 表外措辞与空输入一律落 plan 档兜底句（spec 的原句），**不**把原文透出。
    func testUnknownAndEmptyInputFallBackToPlanPhrase() {
        XCTAssertEqual(OneStepThinkingCopy.publicPhrase(nil), "正在整理计划细节")
        XCTAssertEqual(OneStepThinkingCopy.publicPhrase(""), "正在整理计划细节")
        XCTAssertEqual(
            OneStepThinkingCopy.publicPhrase("xyz_unknown_internal_step"),
            "正在整理计划细节"
        )
    }
}

/// 09 §10 零余额话术门的判定层：只认「余额/额度/点数/积分 + 不足/不够」或英文
/// insufficient/topup 族的**完整**说法；裸「不足」「co」这类泛词必须不命中（宁漏勿冤）。
final class OneStepPlanFailureCopyTests: XCTestCase {

    func testBalancePhrasesAreRecognized() {
        let hits = [
            "余额不足，请充值",
            "INSUFFICIENT_BALANCE",
            "insufficient credits",
            "topup_required",
            "额度不够",
            "点数不足",
        ]
        for message in hits {
            XCTAssertTrue(
                OneStepPlanFailureCopy.isBalanceRefusal(message),
                "\(message) 应判为余额类拒绝"
            )
        }
    }

    /// 泛词与无关失败不得误伤：漏判只少一句余额话术，误判会把普通失败说成扣费问题。
    func testGenericFailuresAreNotBalanceRefusals() {
        let misses = [
            "参数不足",
            "时长不足",
            "record processing failed",
            "network timeout",
            "core dump",
            nil as String?,
        ]
        for message in misses {
            XCTAssertFalse(
                OneStepPlanFailureCopy.isBalanceRefusal(message),
                "\(message ?? "nil") 不得判为余额类拒绝"
            )
        }
    }
}
