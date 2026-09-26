import CovaCore
@testable import CovaPlayer
import Foundation
import XCTest

/// 作品播放上报（`work_listens`，DEVELOPMENT.md §4.3 / A5）在**播放层**的那一半。
///
/// 契约事实（2026-09-26 只读核对 `web/src/lib/play-history.ts`）：
/// · 服务端判据是 `!track && (trackId.includes(':') || jobExists(trackId))`（`:50`）⇒
///   客户端要做的只是**把伪 trackId 当成 itemID 交上去**，本层不需要知道两张表的区别；
/// · `source` 是闭合五值枚举，越界恒 400 `PLAY_SOURCE_INVALID`（`:8`、`:45`）；
/// · 同键下 `(trackId, source)` 任一不同 ⇒ 409 `IDEMPOTENCY_CONFLICT`（`:70-71`）
///   ⇒ 重试必须连来源一起复用，这正是本文件第 2 条用例钉的东西。
///
/// 与 `.privateCandidate` 的分野是这一层最容易接错的一格：候选**不上报**（design 02 §8），
/// 作品**要上报**（否则 `work_listens` 永远空、最近播放里也就永远没有作品行）。
final class WorkPlaybackReportTests: XCTestCase {
    private let session = PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))

    /// 已绑定会话的协调器：`deliver` 的闸门看的是**协调器自己那本会话账**
    /// （`bindSession` 写入的），不是 `playbackStarted` 传进来的那一份 ——
    /// 不先绑定，一切上报都落 `.queued(.unauthenticated)`，用例就成了空炮。
    private func coordinator(
        _ stub: StubPlayReportSubmitter = StubPlayReportSubmitter()
    ) async -> PlayReportCoordinator {
        let sut = PlayReportCoordinator(submitter: stub)
        await sut.bindSession(session)
        return sut
    }

    // MARK: - 上报腿

    func testWorkEpisodeReportsWithThePseudoTrackId() async throws {
        let stub = StubPlayReportSubmitter()
        let sut = await coordinator(stub)
        let outcome = await sut.playbackStarted(
            itemID: "job-test-0001:cand-1", kind: .work, session: session
        )
        guard case .sent(let itemID, let key) = outcome else {
            return XCTFail("作品必须上报，实际是 \(outcome)")
        }
        XCTAssertEqual(itemID, "job-test-0001:cand-1")
        XCTAssertTrue(key.isCanonical(for: .playReport))
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1)
        let ids = await stub.trackIDs
        XCTAssertEqual(ids, ["job-test-0001:cand-1"], "trackId 就是伪 id 本身")
        let sources = await stub.sources
        XCTAssertEqual(sources, [.player], "source 只能取闭合枚举里的值")
    }

    /// 409 的预防腿：同一集次重试必须**同键同 source**。
    /// 撤掉 `Episode.source`（改成每次提交重新取默认）⇒ 本条仍会绿，
    /// 所以这里同时钉住「键相同」与「来源相同」两件事，缺一不可。
    func testWorkEpisodeRetryReusesBothKeyAndSource() async throws {
        let stub = StubPlayReportSubmitter()
        await stub.script(.init(failures: [0: .transport]))
        let sut = await coordinator(stub)
        let first = await sut.playbackStarted(
            itemID: "job-test-0001:cand-1", kind: .work, session: session, source: .project
        )
        guard case .failed(let failedID, _, let reason) = first else {
            return XCTFail("第一次提交应当失败，实际是 \(first)")
        }
        XCTAssertEqual(failedID, "job-test-0001:cand-1")
        XCTAssertEqual(reason, .transport)

        let retried = await sut.retryPending()
        XCTAssertEqual(retried.count, 1)
        guard case .sent = retried.first else {
            return XCTFail("补发应当成功，实际是 \(String(describing: retried.first))")
        }
        let keys = await stub.keys
        let sources = await stub.sources
        guard keys.count == 2 else {
            return XCTFail("应当有两次提交（首次失败 + 补发），实际 \(keys.count) 次")
        }
        XCTAssertEqual(keys[0], keys[1], "重试必须复用同一把幂等键")
        XCTAssertEqual(sources, [.project, .project], "换来源会撞服务端 409 IDEMPOTENCY_CONFLICT")
    }

    /// 一次实际播放只报一次（pause/resume 复用集次）——作品与库曲同一条纪律。
    func testSecondStartOfTheSameWorkEpisodeIsNotASecondReport() async throws {
        let stub = StubPlayReportSubmitter()
        let sut = await coordinator(stub)
        _ = await sut.playbackStarted(itemID: "job-a:cand-1", kind: .work, session: session)
        let again = await sut.playbackStarted(itemID: "job-a:cand-1", kind: .work, session: session)
        guard case .suppressed(_, .alreadyReported) = again else {
            return XCTFail("同一集次重入应当被抑制，实际是 \(again)")
        }
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1)
    }

    /// 集次结束后再播同一作品 = 新集次 = **新键**（服务端才会记成新的一次播放）。
    func testNewEpisodeForTheSameWorkMintsANewKey() async throws {
        let stub = StubPlayReportSubmitter()
        let sut = await coordinator(stub)
        _ = await sut.playbackStarted(itemID: "job-a:cand-1", kind: .work, session: session)
        await sut.playbackEnded(itemID: "job-a:cand-1")
        _ = await sut.playbackStarted(itemID: "job-a:cand-1", kind: .work, session: session)
        let keys = await stub.keys
        guard keys.count == 2 else {
            return XCTFail("两个集次应当各提交一次，实际 \(keys.count) 次")
        }
        XCTAssertNotEqual(keys[0], keys[1], "集次结束后再播 = 新键（服务端才记成新的一次播放）")
    }

    // MARK: - 分野：候选不上报，库曲照旧

    func testPrivateCandidateIsStillSuppressed() async throws {
        let stub = StubPlayReportSubmitter()
        let sut = await coordinator(stub)
        let outcome = await sut.playbackStarted(
            itemID: "media_reference-1", kind: .privateCandidate, session: session
        )
        guard case .suppressed(_, .privateCandidate) = outcome else {
            return XCTFail("生成候选私有音频不上报（design 02 §8），实际是 \(outcome)")
        }
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0)
    }

    func testLibraryTrackStillReportsWithItsOwnId() async throws {
        let stub = StubPlayReportSubmitter()
        let sut = await coordinator(stub)
        _ = await sut.playbackStarted(
            itemID: "library-334cbf73cab881cd48fba970", kind: .libraryTrack, session: session
        )
        let ids = await stub.trackIDs
        XCTAssertEqual(ids, ["library-334cbf73cab881cd48fba970"])
        let calls = await stub.callCount
        XCTAssertEqual(calls, 1)
    }

    /// 未认证：作品的上报也要**挂起**而不是丢弃（凭证就绪后同键补发）。
    func testUnauthenticatedWorkEpisodeIsQueuedNotDropped() async throws {
        let stub = StubPlayReportSubmitter()
        // 刻意**不**走 `coordinator(_:)`：这一条要的就是未绑定会话的那本账。
        let sut = PlayReportCoordinator(submitter: stub)
        let outcome = await sut.playbackStarted(
            itemID: "job-a:cand-1", kind: .work, session: .unauthenticated
        )
        guard case .queued(_, let key, .unauthenticated) = outcome else {
            return XCTFail("未认证应当挂起，实际是 \(outcome)")
        }
        XCTAssertTrue(key.isCanonical(for: .playReport))
        let calls = await stub.callCount
        XCTAssertEqual(calls, 0)
        let pending = await sut.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    // MARK: - 条目与内容形态

    func testWorkItemAcceptsThePseudoTrackIdAsItsIdentifier() throws {
        let item = try PlaybackItem(
            id: "job-test-0001:cand-1", title: "夏日信号", artist: "我的作品",
            duration: 118.4,
            audioSource: .bearerRequired(try AudioURL(https: URL(string: "https://covalink.cn/audio/x.mp3")!)),
            kind: .work
        )
        XCTAssertEqual(item.kind, .work)
        XCTAssertEqual(item.id, "job-test-0001:cand-1")
        XCTAssertTrue(item.requiresLocalization, "需 Bearer 的作品音频仍走 D7 先本地化")
        XCTAssertTrue(PlaybackItem.Kind.allCases.contains(.work))
    }

    /// 作品音频是「这一条成品本身」（不存在同端点按授权发不同字节的形状）⇒ `.full` 可复用缓存。
    /// 库曲仍是 `.unspecified`（那条腿的教训写在 `contentKind(for:)` 的注释里）。
    func testContentKindForWorkIsFullWhileLibraryStaysUnspecified() throws {
        let source = PlaybackItem.AudioSource.bearerRequired(
            try AudioURL(https: URL(string: "https://covalink.cn/audio/x.mp3")!)
        )
        let work = try PlaybackItem(
            id: "job-a:cand-1", title: "t", artist: "a", audioSource: source, kind: .work
        )
        let library = try PlaybackItem(
            id: "library-1", title: "t", artist: "a", audioSource: source, kind: .libraryTrack
        )
        XCTAssertEqual(PrivateAudioFetcher.contentKind(for: work), .full)
        XCTAssertEqual(PrivateAudioFetcher.contentKind(for: library), .unspecified)
    }
}
