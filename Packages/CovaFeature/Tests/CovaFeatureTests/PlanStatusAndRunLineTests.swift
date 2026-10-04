import CovaCore
import XCTest

@testable import CovaFeature

/// 09 §9「计划卡 12 态 × UI 映射」里两颗钮的可用性矩阵 + 主钮文案 —— 逐行钉 spec 那张表。
/// 钉法是穷举：12 态全列出来（`CaseIterable`），每态的三列必须同时对上表。
final class PlanStatusAvailabilityTests: XCTestCase {

    /// §9 表的「开始制作」列：仅 `ready` 与 `retryable_failure` 可用；
    /// `retryable_failure` 那一档文案换「重新制作」（幂等键换新在父层）。
    func testStartAvailabilityMatchesSpecTable() {
        let canStartExpected: [OneStepPlanStatus] = [.ready, .retryableFailure]
        for status in OneStepPlanStatus.allCases {
            XCTAssertEqual(
                PlanStatusCopy.canStart(status), canStartExpected.contains(status),
                "\(status) 的「开始制作」可用性与 §9 表不一致"
            )
        }
        XCTAssertEqual(PlanStatusCopy.primaryAction(.retryableFailure), "重新制作")
        XCTAssertEqual(PlanStatusCopy.primaryAction(.ready), "开始制作")
    }

    /// §9 表的「修改要求」列：`analyzing / ready / demosReady / retryableFailure` 可用，
    /// 其余禁用 —— 在途与归档态不放开修改入口（写了也会撞正在执行的写）。
    func testReviseAvailabilityMatchesSpecTable() {
        let canReviseExpected: [OneStepPlanStatus] = [
            .analyzing, .ready, .demosReady, .retryableFailure,
        ]
        for status in OneStepPlanStatus.allCases {
            XCTAssertEqual(
                PlanStatusCopy.canRevise(status), canReviseExpected.contains(status),
                "\(status) 的「修改要求」可用性与 §9 表不一致"
            )
        }
    }

    /// §9 的 12 个中文态名逐字钉住（文案清单 09 §10「固定，禁改」）。
    func testStatusLabelsAreTheSpecVerbatimList() {
        let expected: [(OneStepPlanStatus, String)] = [
            (.analyzing, "草拟中"), (.ready, "待确认"), (.patching, "修改中"),
            (.starting, "已启动"), (.generating, "生成中"), (.mediaStaging, "音频落位中"),
            (.demosReady, "Demo 就绪"), (.deliveryPreparing, "补充制作中"),
            (.rehydrating, "文件恢复中"), (.manualRecovery, "需人工处理"),
            (.retryableFailure, "未完成，可重试"), (.archived, "已归档"),
        ]
        XCTAssertEqual(expected.count, OneStepPlanStatus.allCases.count)
        for (status, label) in expected {
            XCTAssertEqual(PlanStatusCopy.label(status), label)
        }
    }
}

/// 09 §3.F 的 `run_*` 映射表 —— spec 钉死「本屏唯一允许的实现表」。
/// 钉三点：六条已知事件的符号/短语/色逐字对上；未知 `run_*` 返回 nil（不显示、不算坏事件）；
/// run 恢复腿的 `run.status` 与 SSE 事件名同义（同一本账，不许再长出第二份文案表）。
final class RunLineCopyTests: XCTestCase {

    func testKnownEventsMatchSpecTable() {
        let expected: [(String, String, String, RunLineCopy.Tint)] = [
            ("run_started", "开始处理", "sparkles", .muted),
            ("reasoning_summary", "正在判断", "brain.head.profile", .muted),
            ("run_waiting_user", "等待你的决定", "person.crop.circle.badge.questionmark", .warning),
            ("run_waiting_worker", "歌曲制作中", "hammer", .muted),
            ("run_completed", "处理完成", "checkmark.circle", .success),
            ("run_failed", "处理失败", "xmark.octagon", .error),
        ]
        for (event, label, symbol, tint) in expected {
            let spec = RunLineCopy.line(forEvent: event)
            XCTAssertEqual(spec?.label, label, event)
            XCTAssertEqual(spec?.symbol, symbol, event)
            XCTAssertEqual(spec?.tint, tint, event)
        }
    }

    /// spec §3.F 末行：其他 `run_*`（未知名）**不显示**，也不计坏事件 —— nil 就是唯一答案。
    func testUnknownRunEventsProduceNoLine() {
        XCTAssertNil(RunLineCopy.line(forEvent: "run_thinking"))
        XCTAssertNil(RunLineCopy.line(forEvent: "run_custom_step"))
        XCTAssertNil(RunLineCopy.line(forEvent: ""))
    }

    /// 只有 `run_completed` 的那一行 3s 后淡出（§3.F 表注）；其余态常驻到被替换。
    func testOnlyCompletedLineFadesOut() {
        XCTAssertTrue(RunLineCopy.fadesOut(forEvent: "run_completed"))
        for event in [
            "run_started", "reasoning_summary", "run_waiting_user",
            "run_waiting_worker", "run_failed", "run_unknown_x",
        ] {
            XCTAssertFalse(RunLineCopy.fadesOut(forEvent: event), event)
        }
    }

    /// `GET /api/studio/agent-runs/{id}` 的 `run.status`（等待/终态四格）落到等价的
    /// SSE 事件名上 ⇒ 渲染仍走 `line(forEvent:)` 同一张表。在途态一律 nil。
    func testPollStatusVocabularySharesTheSameTable() {
        XCTAssertEqual(RunLineCopy.event(forStatus: "waiting_user"), "run_waiting_user")
        XCTAssertEqual(RunLineCopy.event(forStatus: "waiting_worker"), "run_waiting_worker")
        XCTAssertEqual(RunLineCopy.event(forStatus: "completed"), "run_completed")
        XCTAssertEqual(RunLineCopy.event(forStatus: "failed"), "run_failed")
        for inFlight in ["planning", "executing", "verifying", "repairing", "queued", ""] {
            XCTAssertNil(RunLineCopy.event(forStatus: inFlight), inFlight)
        }
    }
}
