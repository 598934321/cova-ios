import CovaCore
import XCTest

/// 09 §3-I 补充制作进度条的映射（纯逻辑）。
///
/// 这批用例守的是三件**谎报风险**最高的事：
/// ① 出现条件只能钉在契约给的两个状态上（多画一格 = 发明）；
/// ② 界面上不得出现英文态名（§8 明令），逐状态 × 逐 job 态全组合扫；
/// ③ 契约没有进度字段 ⇒ 条**不许填满**（填满等于声称「完整音频已交付」，
///    而 `fullMediaReady` 不在契约里，见 NEEDS-25）。
final class DeliveryProgressPlannerTests: XCTestCase {
    /// 「拉丁字母」这一件事自己说清楚，不依赖 `CharacterSet.asciiLetters`（该成员在本机 SDK 不存在）。
    private static let latinLetters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    func testBarAppearsOnlyInDeliveryWindow() {
        for status in OneStepPlanStatus.allCases {
            let produced = DeliveryProgressPlanner.progress(planStatus: status, jobStatus: .processing)
            if status == .deliveryPreparing || status == .rehydrating {
                XCTAssertNotNil(produced, "\(status) 应有进度条（09 §9 行 8/9）")
            } else {
                XCTAssertNil(produced, "\(status) 不得出现进度条（09 §3-I 只给了两个状态）")
            }
        }
    }

    /// 前进序列一步一格、序号唯一；四态「不在这条路上」⇒ 没有位置。
    func testMilestonesFollowTheDocumentedForwardPath() {
        let mapped = DeliveryProgressPlanner.forwardPath.compactMap {
            DeliveryProgressPlanner.milestone(for: $0)
        }
        XCTAssertEqual(mapped, Array(1...8), "里程碑必须等于契约状态在前进序列里的位置")
        XCTAssertEqual(Set(mapped).count, 8, "两个状态撞在同一格 = 假装它们等价")

        for status in [OneStepPlanStatus.patching, .manualRecovery, .retryableFailure, .archived] {
            XCTAssertNil(DeliveryProgressPlanner.milestone(for: status), "\(status) 不是「走到哪一步」")
        }
    }

    /// 分母含那一格我们观察不到的完成态 ⇒ 窗口内**永不**填满。
    func testBarNeverClaimsCompleteInsideTheWindow() {
        for status in [OneStepPlanStatus.deliveryPreparing, .rehydrating] {
            guard let progress = DeliveryProgressPlanner.progress(planStatus: status, jobStatus: .processing)
            else { return XCTFail("\(status) 应有进度条") }
            XCTAssertLessThan(progress.fraction, 1.0, "\(status) 时填满就是谎报已交付")
            XCTAssertLessThan(progress.milestone, progress.totalMilestones)
            XCTAssertGreaterThan(progress.fraction, 0)
        }
    }

    /// 取消：文案换「本轮已停止」（§9 末注把这条表现层语义指定给 I 条），里程碑原地不动。
    func testCancelledJobChangesOnlyTheLabel() {
        let running = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .processing
        )
        let stopped = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .cancelled
        )
        XCTAssertEqual(stopped?.label, DeliveryProgressPlanner.stoppedLabel)
        XCTAssertEqual(stopped?.milestone, running?.milestone)
        XCTAssertEqual(stopped?.totalMilestones, running?.totalMilestones)
    }

    /// `rehydrating` 的文案是 §9 行 9 指定的「正在恢复完整音频」，不是 §3-I 的那句。
    func testRehydratingUsesTheRecoveryPhrase() {
        XCTAssertEqual(
            DeliveryProgressPlanner.progress(planStatus: .rehydrating, jobStatus: .processing)?.label,
            DeliveryProgressPlanner.rehydratingLabel
        )
        XCTAssertEqual(
            DeliveryProgressPlanner.progress(planStatus: .deliveryPreparing, jobStatus: nil)?.label,
            DeliveryProgressPlanner.preparingLabel,
            "job 态取不到也要有 §3-I 的那句固定文案"
        )
    }

    /// §8「不在界面上出现英文态名」：**全部** 12 × 7 组合扫三个展示面。
    func testNoContractStatusNameEverReachesTheSurface() {
        let jobStates: [GenerationJobStatus?] = [
            nil, .queued, .submitted, .processing, .succeeded, .failed, .cancelled,
        ]
        for status in OneStepPlanStatus.allCases {
            for job in jobStates {
                guard let progress = DeliveryProgressPlanner.progress(planStatus: status, jobStatus: job)
                else { continue }
                for face in [progress.label, progress.stepText, progress.voiceOverLabel] {
                    XCTAssertNil(
                        face.rangeOfCharacter(from: Self.latinLetters),
                        "界面文案里出现了拉丁字母（英文态名泄漏）：\(face) ← \(status)/\(String(describing: job))"
                    )
                    XCTAssertFalse(face.contains(status.rawValue))
                    if let job { XCTAssertFalse(face.contains(job.rawValue)) }
                }
            }
        }
    }

    /// VoiceOver 标签按 §7 的形态：句读 + 阶段，且**不**含百分比符号（我们没有百分比）。
    func testVoiceOverLabelCarriesStepNotPercentage() {
        let progress = DeliveryProgressPlanner.progress(
            planStatus: .deliveryPreparing, jobStatus: .processing
        )
        XCTAssertEqual(
            progress?.voiceOverLabel,
            "补充制作中，第 7 步，共 9 步"
        )
        XCTAssertFalse(progress?.voiceOverLabel.contains("%") ?? true)
        XCTAssertEqual(progress?.stepText, "7/9")
    }
}
