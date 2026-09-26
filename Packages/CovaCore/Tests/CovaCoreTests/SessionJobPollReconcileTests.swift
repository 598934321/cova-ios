import CovaCore
import Foundation
import XCTest

/// 09 会话详情那条 jobs 轮询的**判决层**（`SessionJobPollReconcile`，DEVELOPMENT.md §5 P1-5）。
///
/// 这批用例守的是一件很难用眼睛看出来的缺陷族：**绿 build、红屏幕**。
/// 轮询那条腿写错一个字段，屏上就是每 5 秒洗一次卡（两张候选卡连同试听/收藏态一起消失），
/// 而编译器与后端响应都完全正常。所以每条用例都对着一个具体的"不许"：
/// · 「与屏上一致 ⇒ 什么都不写」（不白刷）；
/// · 「读到取消 ⇒ 只收口一次」（第二张通知、第二次环收口都不许存在）；
/// · 「流是这一轮的主人 ⇒ 轮询一个字都不写，并且让位」；
/// · 「投到上限 ⇒ 停，但**不**说失败」（观察者的预算不是被观察者的结论）；
/// · 「投影里没有候选 ⇒ 候选清单原样留着」（服务端在 submitted / 重试那两处就是不给候选：
///   `web/src/lib/one-step/generation.ts:1122-1151` 与 `:2461-2472`，核对记录在
///   `SessionJobPollReconcile.swift` 文件头）。
///
/// 节拍一律取 `StudioCreatePollSchedule` 的默认值 —— 用例同时钉住"这里没有第二套调度表"。
final class SessionJobPollReconcileTests: XCTestCase {

    // MARK: - 夹具

    /// 造一行真实形态的任务：`metadata` 在线上是 **JSON 字符串**（与 `GenerationJobDto` 的
    /// 形态约定同一件事），所以这里走"字符串里再套字符串"，而不是图省事给个嵌套对象。
    private func job(status: String, candidateCount: Int?) throws -> GenerationJobDto {
        var fields = ["\"id\":\"job-1\"", "\"status\":\"\(status)\""]
        if let candidateCount {
            let items = (0..<candidateCount).map { index -> String in
                "{" + [
                    "\"id\":\"cand-\(index)\"",
                    "\"title\":\"版本 \(index + 1)\"",
                    "\"audioUrl\":\"/audio/x\(index).mp3\"",
                    "\"audioDownloadStatus\":\"ready\"",
                ].joined(separator: ",") + "}"
            }.joined(separator: ",")
            let metadata = "{\"candidates\":[\(items)],\"outputCount\":2}"
            fields.append(
                "\"metadata\":\"\(metadata.replacingOccurrences(of: "\"", with: "\\\""))\""
            )
        }
        return try JSONDecoder().decode(
            GenerationJobDto.self, from: Data(("{" + fields.joined(separator: ",") + "}").utf8)
        )
    }

    private func observation(
        status: GenerationJobStatus?, candidateCount: Int?
    ) throws -> SessionJobPollReconcile.Observation {
        guard let status else {
            return SessionJobPollReconcile.Observation(job: nil)
        }
        return SessionJobPollReconcile.Observation(
            job: try job(status: status.rawValue, candidateCount: candidateCount)
        )
    }

    private func decide(
        previous: GenerationJobStatus?,
        observed: GenerationJobStatus?,
        carriesCandidates: Bool = false,
        streamMidRound: Bool = false,
        attempt: Int = 1
    ) -> SessionJobPollReconcile.Decision {
        SessionJobPollReconcile.decide(
            previous: previous,
            observation: SessionJobPollReconcile.Observation(
                status: observed, carriesCandidates: carriesCandidates
            ),
            streamMidRound: streamMidRound,
            attempt: attempt
        )
    }

    // MARK: - 观测本身取自真实形态

    func testObservationReadsCandidatesOutOfMetadataString() throws {
        let withCandidates = try job(status: "succeeded", candidateCount: 2)
        let observed = SessionJobPollReconcile.Observation(job: withCandidates)
        XCTAssertEqual(observed.status, .succeeded)
        XCTAssertTrue(observed.carriesCandidates, "候选在 metadata 那串 JSON 里，解不出来就等于看不见")
        XCTAssertEqual(withCandidates.candidates().count, 2)

        // 初始 INSERT 那一行（submitted）根本没有 candidates 键 ⇒ 只能报"没带着"。
        let bare = SessionJobPollReconcile.Observation(
            job: try JSONDecoder().decode(
                GenerationJobDto.self,
                from: Data(#"{"id":"job-2","status":"submitted","metadata":"{\"title\":\"夏夜\"}"}"#
                    .utf8)
            )
        )
        XCTAssertEqual(bare.status, .submitted)
        XCTAssertFalse(bare.carriesCandidates)

        // 重试把同一行改回 submitted 时**显式**写空数组 ⇒ 同样是"没带着"，
        // 这一条判错就是拿 [] 去洗掉屏上那两张卡（`…/generation.ts:2467` 实测形态）。
        let emptied = SessionJobPollReconcile.Observation(
            job: try JSONDecoder().decode(
                GenerationJobDto.self,
                from: Data(
                    #"{"id":"job-3","status":"submitted","metadata":"{\"candidates\":[]}"}"#.utf8
                )
            )
        )
        XCTAssertFalse(emptied.carriesCandidates)
        XCTAssertEqual(emptied.status, .submitted)
    }

    // MARK: - 「与屏上一致 ⇒ 什么都不写」

    func testUnchangedStatusWritesNothingAndKeepsLegAlive() {
        let decision = decide(previous: .processing, observed: .processing)
        XCTAssertEqual(decision.reason, .unchanged)
        XCTAssertFalse(decision.writesJob, "同一件事不必再写一遍：写一次就有一次把别的东西顺带改掉的窗口")
        XCTAssertFalse(decision.writesCandidates, "行里没带着候选 ⇒ 清单一个字都不动")
        XCTAssertFalse(decision.settles, "还没完，收口一次就是把 08 那一格当场抹掉")
        XCTAssertFalse(decision.stops)
        XCTAssertFalse(decision.claimsFailure)
    }

    /// 状态不动而候选落地是**真实存在**的一种推进（worker 往 metadata 里写两张占位卡，
    /// `status` 仍是 processing）⇒ 清单那一维不跟着"状态相同"一起免写。
    func testStatusUnchangedStillSurfacesArrivedCandidates() {
        let decision = decide(
            previous: .processing, observed: .processing, carriesCandidates: true
        )
        XCTAssertEqual(decision.reason, .unchanged)
        XCTAssertFalse(decision.writesJob)
        XCTAssertTrue(
            decision.writesCandidates,
            "带着非空候选的行就是更新；不写它，用户就得离开再进来才看得见那两张卡"
        )
        XCTAssertFalse(decision.settles)
    }

    // MARK: - 「读到取消 ⇒ 只收口一次」

    func testCancelObservedSettlesOnceAndEndsTheLeg() throws {
        // 取消那一行通常**不**带候选（服务端只改 status / error_message）。
        let observed = try observation(status: .cancelled, candidateCount: nil)
        let decision = SessionJobPollReconcile.decide(
            previous: .processing, observation: observed, streamMidRound: false, attempt: 4
        )
        XCTAssertEqual(decision.reason, .terminalObserved)
        XCTAssertTrue(decision.writesJob)
        XCTAssertTrue(decision.settles, "取消必须走既有收口腿：08 的环与 18 的终态通知都挂在那一条上")
        XCTAssertTrue(decision.stops, "腿一停，同一个终态就不可能被收口第二次")
        XCTAssertFalse(decision.writesCandidates, "行里没候选 ⇒ 不许拿空数组去洗屏")
        XCTAssertFalse(decision.claimsFailure)

        // 第二道门：假想这条腿没停、又读到一次同样的取消 ⇒ 也绝不会再收口一次。
        let again = decide(previous: .cancelled, observed: .cancelled)
        XCTAssertFalse(again.settles, "同一个终态读第二遍不构成第二次收口：环与通知都只该被交出去一次")
        XCTAssertFalse(again.writesJob)
        XCTAssertFalse(again.writesCandidates)
        XCTAssertEqual(again.reason, .alreadySettled, "屏上已经是取消 ⇒ 这一档只剩'结束这条腿'一件事")
        XCTAssertTrue(again.stops)
    }

    func testSucceededAndFailedAreTerminalToo() {
        for status in [GenerationJobStatus.succeeded, .failed, .cancelled] {
            let decision = decide(previous: .submitted, observed: status)
            XCTAssertEqual(decision.reason, .terminalObserved, "\(status) 是后端说'这一路完了'")
            XCTAssertTrue(decision.settles)
            XCTAssertTrue(decision.stops)
        }
        for status in [GenerationJobStatus.queued, .submitted, .processing] {
            let decision = decide(previous: nil, observed: status)
            XCTAssertFalse(decision.settles, "\(status) 未终态：收口就是把刚上环的格子当场抹掉")
            XCTAssertFalse(decision.stops)
        }
    }

    // MARK: - 「流是这一轮的主人」

    func testStreamMidRoundDiscardsPollResultEvenWhenTerminal() {
        let decision = decide(
            previous: .processing, observed: .succeeded,
            carriesCandidates: true, streamMidRound: true, attempt: 2
        )
        XCTAssertEqual(decision.reason, .streamOwnsRound)
        XCTAssertFalse(decision.writesJob, "busy 期间屏上那两份状态还是这一轮开始**之前**的载荷，轮询写它就是抢主人")
        XCTAssertFalse(decision.writesCandidates)
        XCTAssertFalse(decision.settles)
        XCTAssertTrue(decision.stops, "让位 = 结束这条腿，等流结束后由载荷重新决定要不要再投")
        XCTAssertFalse(decision.claimsFailure)
    }

    func testArmingIsRefusedWhileStreamOwnsRound() {
        XCTAssertFalse(SessionJobPollReconcile.canArm(
            jobID: "job-1", status: .processing, streamMidRound: true
        ))
        XCTAssertTrue(SessionJobPollReconcile.canArm(
            jobID: "job-1", status: .processing, streamMidRound: false
        ))
        XCTAssertFalse(SessionJobPollReconcile.canArm(
            jobID: "job-1", status: .succeeded, streamMidRound: false
        ), "屏上那一行已经终态 ⇒ 继续投就是拿预算问一件有答案的事")
        XCTAssertFalse(SessionJobPollReconcile.canArm(
            jobID: nil, status: .processing, streamMidRound: false
        ), "没有任务号就没有任何东西可投：不拿会话号冒充")
        XCTAssertFalse(SessionJobPollReconcile.canArm(
            jobID: "   ", status: .processing, streamMidRound: false
        ))
        XCTAssertTrue(SessionJobPollReconcile.canArm(
            jobID: "job-1", status: nil, streamMidRound: false
        ), "刚 start 拿到任务号时屏上还没有那一行 ⇒ 未知不等于终态，这一路正要被看着")
    }

    // MARK: - 「投到上限 ⇒ 停，但绝不说失败」

    func testCapReachedStopsWithoutClaimingFailure() {
        let schedule = StudioCreatePollSchedule()
        let last = schedule.maximumAttemptCount
        XCTAssertTrue(last > 0)

        let stillOpen = decide(previous: .processing, observed: .processing, attempt: last)
        XCTAssertNotEqual(stillOpen.reason, .capReached, "上限内的最后一次仍然照常轮询")

        // 上限外那一趟：什么都不知道、什么都不改、直接停。
        let cap = decide(
            previous: .processing, observed: .processing, attempt: last + 1
        )
        XCTAssertEqual(cap.reason, .capReached)
        XCTAssertTrue(cap.stops)
        XCTAssertFalse(cap.writesJob, "到点时屏上那份已知状态就是已知状态，不许顺手改成别的")
        XCTAssertFalse(cap.writesCandidates)
        XCTAssertFalse(cap.settles, "到上限不是'结束'：环该继续亮着，等下一次载荷说真话")
        XCTAssertFalse(cap.claimsFailure, "'没再读到' ≠ '没能完成'（19 屏同一档叫 .unconfirmed）")

        // 上限外那一趟即使**读到了终态**也不改屏：腿已经在预算外，改判据就等于给自己续预算。
        let capWithTerminal = decide(
            previous: .processing, observed: .succeeded, attempt: last + 1
        )
        XCTAssertEqual(capWithTerminal.reason, .capReached)
        XCTAssertFalse(capWithTerminal.settles)
        XCTAssertFalse(capWithTerminal.writesJob)
    }

    func testNoReasonEverClaimsFailure() {
        // 把所有档位各造一次，逐档确认"这条腿自己从不产失败判词"。
        let decisions: [SessionJobPollReconcile.Decision] = [
            decide(previous: nil, observed: nil),                                        // noObservation
            decide(previous: .processing, observed: .processing),                         // unchanged
            decide(previous: .submitted, observed: .cancelled),                           // terminalObserved
            decide(previous: .cancelled, observed: .cancelled),                           // alreadySettled
            decide(previous: .submitted, observed: .processing),                          // advanced
            decide(previous: .processing, observed: .succeeded, streamMidRound: true),    // streamOwnsRound
            decide(previous: .processing, observed: .processing,
                   attempt: StudioCreatePollSchedule().maximumAttemptCount + 1),          // capReached
        ]
        XCTAssertEqual(
            Set(decisions.map(\.reason)), Set(SessionJobPollReconcile.Reason.allCases),
            "上面这七条要覆盖全部档位：新增一档而不带用例，这里先红"
        )
        XCTAssertTrue(decisions.allSatisfy { $0.claimsFailure == false })
    }

    // MARK: - 「投影没带候选 ⇒ 清单原样留着」

    func testTerminalRowWithoutCandidatesLeavesListAlone() {
        let decision = decide(previous: .processing, observed: .succeeded, carriesCandidates: false)
        XCTAssertTrue(decision.writesJob, "任务级读数仍以轮询为准（两个端点是同一个投影函数）")
        XCTAssertFalse(decision.writesCandidates, "行里没有候选 ⇒ 屏上那两张卡不许被空数组换掉")
        XCTAssertTrue(decision.settles)
    }

    func testTerminalRowWithCandidatesAdoptsList() {
        let decision = decide(previous: .processing, observed: .succeeded, carriesCandidates: true)
        XCTAssertTrue(decision.writesCandidates, "带着候选的终态行就是这一轮的结果，卡该亮起来")
        XCTAssertTrue(decision.writesJob)
    }

    /// submitted / processing 那几行服务端就是**不给**候选（文件头事实二：
    /// `…/generation.ts:1122-1151` 初始 INSERT 没有那个键、`:2461-2472` 重试显式写 `[]`）。
    /// 这一档判错 = 每 5 秒把屏上两张卡洗掉一次，而 build 全程是绿的。
    func testInFlightRowWithoutCandidatesNeverReplacesList() {
        let decision = decide(previous: .submitted, observed: .processing, carriesCandidates: false)
        XCTAssertEqual(decision.reason, .advanced)
        XCTAssertTrue(decision.writesJob)
        XCTAssertFalse(decision.writesCandidates, "行里没有候选 ⇒ 不许拿空数组去换屏上那两张卡")
        XCTAssertFalse(decision.stops)
        XCTAssertFalse(decision.settles)
    }

    // MARK: - 「单次读不到不杀腿」

    func testSingleUnusableObservationKeepsWaiting() {
        let decision = decide(previous: .processing, observed: nil, attempt: 9)
        XCTAssertEqual(decision.reason, .noObservation)
        XCTAssertFalse(decision.stops, "网络抖动不等于任务失败：继续按节拍投（19 屏同一口径）")
        XCTAssertFalse(decision.writesJob, "什么都没读到就不许写：写一次就把'我不知道'伪装成了一次观测")
        XCTAssertFalse(decision.writesCandidates)
        XCTAssertFalse(decision.settles)
        XCTAssertFalse(decision.claimsFailure)
    }

    // MARK: - 节拍只有一本账

    func testCadenceComesFromTheSharedScheduleNotASecondOne() {
        let shared = StudioCreatePollSchedule()
        XCTAssertEqual(shared.maximumAttemptCount, 183, "复用 19 屏那本节拍表（前 6 次 5s、之后 10s、上限约 30min）")
        XCTAssertEqual(shared.interval(forAttempt: 1), 5)
        XCTAssertEqual(shared.interval(forAttempt: 6), 5)
        XCTAssertEqual(shared.interval(forAttempt: 7), 10)
        // 判决的默认 schedule 就是这一本：换个 attempt 数字就能观察到同一道上限。
        let justInside = decide(previous: nil, observed: .processing, attempt: shared.maximumAttemptCount)
        let justOutside = decide(previous: nil, observed: .processing, attempt: shared.maximumAttemptCount + 1)
        XCTAssertEqual(justInside.reason, .advanced)
        XCTAssertEqual(justOutside.reason, .capReached)
    }
}
