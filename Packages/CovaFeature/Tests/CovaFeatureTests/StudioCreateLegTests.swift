import CovaCore
import CovaPlayer
import Foundation
import XCTest

@testable import CovaFeature

/// 01「继续聆听」与 19「创作台」在接线层的**纯映射腿**（A1/A5/A6/A13）。
///
/// 这一层不测视图渲染（TD-48：CovaFeature 只钉纯函数与媒体腿，界面的可信证据是截图）。
/// 这里钉的是"屏幕上那句话从哪来"的那一段因果：
/// · 历史行 → 视图模型：work 行不能被判成库曲行（否则 01 会拿库曲详情端点去打伪 id）；
/// · 作品行 → `PlaybackItem`：id 必须**原样**是伪 trackId（上报就靠它，A5）；
/// · 播放只吃 `audioUrl`、直存才允许 `playbackUrl`（A13 的分野）。
///
/// `@MainActor`：被测的两条腿都是 `AppSession`（`@MainActor` 类）的静态方法，
/// 隔离面必须一致才编得过（同 `StudioTerminalNotificationWiringTests` 的先例）。
@MainActor
final class StudioCreateLegTests: XCTestCase {

    // MARK: - 夹具

    private func item(_ trackId: String, track: PlayHistoryTrackDto?) -> PlayHistoryItemDto {
        PlayHistoryItemDto(
            id: "listen-1", trackId: trackId, playedAt: "2026-09-26T03:00:00.000Z",
            source: "player", track: track
        )
    }

    private func track(_ body: String) throws -> PlayHistoryTrackDto {
        try JSONDecoder().decode(PlayHistoryTrackDto.self, from: Data(body.utf8))
    }

    private func work(_ body: String) throws -> CreateWorkItemDto {
        try JSONDecoder().decode(CreateWorkItemDto.self, from: Data(body.utf8))
    }

    private let succeededAudioJSON = """
    {"id":"job-1:cand-1","jobId":"job-1","status":"succeeded","title":"夏夜",\
    "audioUrl":"/audio/summer_9f3a.mp3","duration":118.4,"instrumental":false}
    """

    private let onlyPlaybackJSON = """
    {"id":"job-2:cand-1","jobId":"job-2","status":"succeeded","title":"夏夜","audioUrl":null,\
    "playbackUrl":"https://covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com/c.mp3?sign=x"}
    """

    private let generatingJSON = """
    {"id":"job-3:pending-1","jobId":"job-3","status":"processing","title":"夏夜",\
    "audioUrl":null,"duration":null}
    """

    // MARK: - 历史行映射（A1）

    func testLibraryRowKeepsTrackIdAndChineseTitles() throws {
        let projected = try self.track(
            """
            {"id":"library-1","title":"Coastal Drive","titleCn":"沿海公路",\
            "artistNameCn":"极光原野","cover":"/covers/a.jpeg","duration":178.84}
            """
        )
        let row = try XCTUnwrap(
            AppSession.RecentPlayRow(item: item("library-1", track: projected))
        )
        XCTAssertEqual(row.kind, .library)
        XCTAssertEqual(row.id, "library-1")
        XCTAssertEqual(row.title, "沿海公路", "中文标题优先")
        XCTAssertEqual(row.artist, "极光原野")
        XCTAssertEqual(row.duration, 178.84)
        XCTAssertTrue(row.playable)
    }

    func testWorkRowIsMarkedWorkAndKeepsThePseudoTrackIdAsIdentity() throws {
        let projected = try self.track(
            """
            {"id":"job-1:cand-1","title":"Summer Signal","titleCn":"夏日信号",\
            "artist":null,"artistName":null,"bpm":null,"workId":"job-1:cand-1","duration":118.4}
            """
        )
        let row = try XCTUnwrap(
            AppSession.RecentPlayRow(item: item("job-1:cand-1", track: projected))
        )
        XCTAssertEqual(row.kind, .work)
        // **id 就是伪 trackId**：播放层把它原样发给 `POST /api/tracks/play`（A5）。
        XCTAssertEqual(row.id, "job-1:cand-1")
        XCTAssertNil(row.artist, "作品行的艺人恒 null ⇒ nil，不给它编一个「未知艺人」")
        XCTAssertEqual(row.title, "夏日信号")
        XCTAssertTrue(row.playable)
    }

    /// 裸 jobId 的作品行（服务端可能因取不到候选音频而丢行）：渲染但**不可点开**。
    func testBareJobIdWorkRowRendersButIsNotPlayable() throws {
        let projected = try self.track(#"{"id":"job-9","workId":"job-9","title":null}"#)
        let row = try XCTUnwrap(AppSession.RecentPlayRow(item: item("job-9", track: projected)))
        XCTAssertEqual(row.kind, .work)
        XCTAssertFalse(row.playable)
        XCTAssertEqual(row.title, "未命名作品", "没有标题时不印裸 id 冒充曲名")
    }

    func testRowWithoutAnyTrackProjectionStillClassifiesAndRenders() {
        let workRow = AppSession.RecentPlayRow(item: item("job-7:cand-2", track: nil))
        XCTAssertEqual(workRow?.kind, .work)
        XCTAssertEqual(workRow?.title, "未命名作品")
        let libraryRow = AppSession.RecentPlayRow(item: item("library-7", track: nil))
        XCTAssertEqual(libraryRow?.kind, .library)
        XCTAssertEqual(
            libraryRow?.title, "library-7", "库曲行没标题时退回 id —— 那是唯一可指认的事实"
        )
    }

    func testRowWithNoIdentityIsDroppedFromTheList() throws {
        XCTAssertNil(AppSession.RecentPlayRow(item: item("", track: nil)))
        let page = try JSONDecoder().decode(
            PlayHistoryPageDto.self,
            from: Data(
                """
                {"items":[{"trackId":"library-1"},{"trackId":"job-1:c-1"},{"playedAt":"x"}]}
                """.utf8
            )
        )
        let rows = AppSession.recentRows(from: page)
        XCTAssertEqual(rows.map(\.id), ["library-1", "job-1:c-1"])
    }

    // MARK: - 作品 → 播放条目（A5 的 id 来源 / A13 的地址分野）

    func testWorkPlaybackItemCarriesThePseudoTrackIdAsItemID() throws {
        let playback = try XCTUnwrap(
            AppSession.workPlaybackItem(from: work(succeededAudioJSON))
        )
        XCTAssertEqual(playback.id, "job-1:cand-1")
        XCTAssertEqual(playback.kind, .work)
        XCTAssertTrue(playback.requiresLocalization, "作品试听仍走 D7：先本地化再 file://")
        XCTAssertEqual(playback.duration, 118.4)
        // 地址只能从 `bearerRequired` 那一格里取 —— `playableURL` 对它是 **nil**
        // （类型层面就没有"绕过本地化直接播"的路径）。上一版本用例断的是 `playableURL`，
        // 那条断言在正确实现下必然红，是我写错了期望而不是代码错了。
        guard case .bearerRequired(let audio) = playback.audioSource else {
            return XCTFail("作品音频必须是 bearerRequired，否则 D7 的本地化那一步会被绕过")
        }
        XCTAssertEqual(audio.value.absoluteString, "https://covalink.cn/audio/summer_9f3a.mp3")
    }

    /// A13 的那一条分野：**播放只吃 `audioUrl`**。`playbackUrl` 是 COS 绝对直链，
    /// 而 `.publicDirect` 在 D23 之后只认生产出口 ⇒ 交给它等于让 AVPlayer 自己决定第二次出站。
    func testPlaybackRefusesTheCredentialFreeDirectLinkWhileDownloadAcceptsIt() throws {
        let work = try self.work(onlyPlaybackJSON)
        XCTAssertTrue(work.isPlayable, "有 playbackUrl 就算这行能出声")
        XCTAssertNil(AppSession.workPlaybackItem(from: work), "不许把名单桶直链交给播放器")
        let request = try XCTUnwrap(
            AppSession.workDownloadRequest(
                from: work,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
            )
        )
        XCTAssertEqual(
            request.source.value.host,
            "covalink-audio-1301797874.cos.ap-shanghai.myqcloud.com",
            "直存这一腿才允许走免凭证预签名直链"
        )
    }

    func testUnplayableRowsProduceNeitherThePlaybackNorTheDownloadLeg() throws {
        let work = try self.work(generatingJSON)
        XCTAssertFalse(work.isPlayable)
        XCTAssertNil(AppSession.workPlaybackItem(from: work))
        XCTAssertNil(AppSession.workDownloadRequest(
            from: work,
            session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
        ))
    }

    func testDownloadLegNeedsAnOwnerNamespace() throws {
        let work = try self.work(succeededAudioJSON)
        XCTAssertNil(
            AppSession.workDownloadRequest(from: work, session: nil),
            "没有凭证快照就没有可分桶的归属 ⇒ 不存"
        )
        XCTAssertNil(
            AppSession.workDownloadRequest(from: work, session: .unauthenticated),
            "无主目录不允许出现（D8）：没有 owner 就不存，而不是先存下再指望清理"
        )
    }

    // MARK: - 任务态的派生判据（A11 的两句话术）

    func testRetryAndBusyFlagsAreDerivedFromPhaseNotStoredTwice() {
        let busy: [AppSession.StudioCreateState.Phase] = [.submitting, .polling(.processing)]
        for phase in busy {
            XCTAssertTrue(AppSession.StudioCreateState(phase: phase).isBusy, "\(phase)")
        }
        let resting: [AppSession.StudioCreateState.Phase] = [
            .idle, .succeeded, .failed, .unconfirmed
        ]
        for phase in resting {
            XCTAssertFalse(AppSession.StudioCreateState(phase: phase).isBusy, "\(phase)")
        }
        XCTAssertTrue(AppSession.StudioCreateState(phase: .polling(.queued)).isPolling)
        XCTAssertFalse(AppSession.StudioCreateState(phase: .submitting).isPolling)
        // 「重试」（同键）与「重新生成」（新键）必须是两格，混了就等于把 A11 说反。
        XCTAssertTrue(AppSession.StudioCreateState(phase: .unconfirmed).canRetrySameSubmission)
        XCTAssertFalse(AppSession.StudioCreateState(phase: .failed).canRetrySameSubmission)
    }

    // MARK: - 失败话术的分派（A4）

    func testSubmissionFailureCopiesMatchTheScreenSpec() {
        XCTAssertEqual(
            StudioCreateSubmissionFailure.invalidInput(.emptyPrompt).userMessage,
            "请填写音乐描述"
        )
        XCTAssertEqual(
            StudioCreateSubmissionFailure
                .invalidInput(.promptTooLong(limit: 2000, actual: 2001)).userMessage,
            "音乐描述过长（最多 2000 字）"
        )
        XCTAssertEqual(
            StudioCreateSubmissionFailure
                .rejected(.creditsInsufficient(balance: 3, required: 20)).userMessage,
            "余额不足，本次需要 20 co"
        )
        XCTAssertTrue(
            StudioCreateSubmissionFailure.unresolvedSubmission.userMessage.contains("先别重复提交"),
            "2xx 没读到任务号时不许说「没提交成功」——那会诱导用户再点一次、真的二次扣费"
        )
        XCTAssertTrue(StudioCreateSubmissionFailure.unreachable(.network).isRetryableWithSameKey)
        XCTAssertFalse(
            StudioCreateSubmissionFailure.rejected(.idempotencyConflict).isRetryableWithSameKey
        )
        XCTAssertTrue(
            StudioCreateSubmissionFailure.unreachable(.network).userMessage
                .contains("不会重复扣费")
        )
    }

    func testCatalogFailureUserTextCoversEveryCase() {
        XCTAssertEqual(CatalogFailure.network.userText, "网络没通")
        XCTAssertEqual(CatalogFailure.server("HTTP 500").userText, "HTTP 500")
        XCTAssertEqual(CatalogFailure.unauthenticated.userText, "登录状态已过期")
        XCTAssertEqual(
            CatalogFailure.backendGap("NEEDS-35").userText, "后端契约缺口（NEEDS-35）"
        )
    }

    // MARK: - 扣费那一行（§7 #40：重放时服务端照样回 charge）

    /// 首次报到的 jobId 保持原话 —— 19 那张已验收的截图写的就是这句，改它要重新拍。
    func testChargeLineKeepsTheOriginalWordingForAFirstReport() {
        XCTAssertEqual(
            AppSession.studioCreateChargeLine(charge: 100, alreadyReported: false),
            "本次消耗 100 co"
        )
    }

    /// 同一个 jobId 第二次回来 ⇒ 不许再说"本次消耗"，也不许带数字（那读起来就是又扣了一笔）。
    func testChargeLineRefusesToRestateASpendForAReplayedJob() {
        let line = AppSession.studioCreateChargeLine(charge: 100, alreadyReported: true)
        XCTAssertEqual(line, "这个任务已经提交过（未重复扣费）")
        XCTAssertFalse(line?.contains("消耗") ?? true, "重放那一格不能沿用首次的措辞")
        XCTAssertFalse(line?.contains("100") ?? true, "重放时 charge 回的是单价，不是新扣额")
    }

    /// `nil` 与 `0` 都不渲染这一行，且**都不写成「免费」**（0 可能只是开发环境的计费开关）。
    func testChargeLineStaysSilentForZeroAndMissingCharge() {
        for charge in [nil, 0, -100] {
            for reported in [false, true] {
                XCTAssertNil(
                    AppSession.studioCreateChargeLine(charge: charge, alreadyReported: reported),
                    "charge=\(String(describing: charge)) reported=\(reported) 不该出这一行"
                )
            }
        }
    }
}
