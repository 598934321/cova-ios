@testable import CovaCore
import Foundation
import XCTest

/// 作品行内动作七个端点的契约面（DEVELOPMENT.md §4.7「行内动作」那三个坑）。
///
/// 最承重的一条是 **缺键 ≠ false**：`favorite`/`dislike` 的 body 里那个键缺席时服务端
/// 按 `true` 处理 ⇒ 取消收藏**必须显式发 false**。本文件证明三件事：
/// ① 类型上写不出"忘了赋值"（`.omitted` 是要点名的 case，而它的语义是"点亮"）；
/// ② 编码面真的能把键整个不发（fixture 逐字节比），且回读缺键能回到 `.omitted`；
/// ③ 回执与"这一单本来要做成什么"能对上（`agrees(with:)`），对不上就是可红的断言。
final class WorkActionsDTOTests: XCTestCase {

    // MARK: - ① / ② 三态开关：编码与解码两头都要钉

    func testExplicitFalseIsTheOnlyWayToAskForOff() throws {
        XCTAssertEqual(WorkActionToggle.requesting(state: false), .off)
        XCTAssertEqual(WorkActionToggle.requesting(state: true), .on)
        // 想关却"没决定"，在服务端那一头等于打开：这条是整张表的命门。
        XCTAssertEqual(WorkActionToggle.omitted.serverEffectiveState, true)
        XCTAssertEqual(WorkActionToggle.on.serverEffectiveState, true)
        XCTAssertEqual(WorkActionToggle.off.serverEffectiveState, false)
    }

    func testFavoriteBodyEncodesTheThreeStatesDistinctly() throws {
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(WorkFavoriteRequestDto(.off)), fixture: "requests/work-favorite-off"
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(WorkFavoriteRequestDto(.on)), fixture: "requests/work-favorite-on"
        )
        // `.omitted` ⇒ **一个键都不发**（不是 `favorite:null`）。
        let omitted = try JSONEncoder().encode(WorkFavoriteRequestDto(.omitted))
        try XCTAssertEncodedJSONEqual(omitted, fixture: "requests/work-favorite-omitted")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        XCTAssertFalse(object.keys.contains("favorite"), "缺键那一格必须是真缺键")
    }

    func testDislikeBodyUsesItsOwnKeyNotFavorite() throws {
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(WorkDislikeRequestDto(.off)), fixture: "requests/work-dislike-off"
        )
        let on = try JSONEncoder().encode(WorkDislikeRequestDto(.on))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: on) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["dislike"], "点踩体里不许出现 favorite 这个键")
    }

    func testAbsentNullOrBoolDecodeBackToTheThreeStates() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(WorkFavoriteRequestDto.self, from: Data("{}".utf8)).favorite,
            .omitted, "缺键读回 omitted（不是 off）"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkFavoriteRequestDto.self, from: Data(#"{"favorite":null}"#.utf8)
            ).favorite,
            .omitted, "显式 null 在服务端与缺键同义"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkFavoriteRequestDto.self, from: Data(#"{"favorite":false}"#.utf8)
            ).favorite,
            .off
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkDislikeRequestDto.self, from: Data(#"{"dislike":true}"#.utf8)
            ).dislike,
            .on
        )
        // 坏类型（字符串 "false"）不许被读成 off：读不出布尔就是缺键那一档。
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkFavoriteRequestDto.self, from: Data(#"{"favorite":"false"}"#.utf8)
            ).favorite,
            .omitted
        )
    }

    /// 往返恒等：写出去的三种状态读回来还是那三种（不是一条只测一头的死代码）。
    func testToggleSurvivesARoundTripWithoutCollapsing() throws {
        for toggle: WorkActionToggle in [.on, .off, .omitted] {
            let data = try JSONEncoder().encode(WorkFavoriteRequestDto(toggle))
            let back = try JSONDecoder().decode(WorkFavoriteRequestDto.self, from: data)
            XCTAssertEqual(back, WorkFavoriteRequestDto(toggle))
            XCTAssertEqual(back.serverEffectiveState, toggle.serverEffectiveState)
        }
    }

    // MARK: - ③ 回执

    func testFavoriteEchoIsComparedAgainstWhatTheCallAskedFor() throws {
        let data = Data(#"{"ok":true,"favorited":true}"#.utf8)
        let response = try JSONDecoder().decode(WorkFavoriteResponseDto.self, from: data)
        XCTAssertTrue(response.isAcknowledged)
        XCTAssertTrue(response.agrees(with: .on))
        XCTAssertTrue(response.agrees(with: .omitted), "缺键的语义就是 true，回执对得上")
        XCTAssertFalse(response.agrees(with: .off), "说好了取消而服务端还是收藏着 ⇒ 必须能红")

        let off = try JSONDecoder().decode(
            WorkFavoriteResponseDto.self, from: Data(#"{"ok":true,"favorited":false}"#.utf8)
        )
        XCTAssertTrue(off.agrees(with: .off))
        XCTAssertFalse(off.agrees(with: .omitted))
    }

    /// `200` 但没有 `ok:true` ⇒ **不算确认**（不许把空体读成"成功了"，也不许读成"失败"）。
    func testEmptyOrMissingOkIsNeverReadAsAcknowledgement() throws {
        for body in ["{}", #"{"ok":false}"#, #"{"ok":null}"#, #"{"favorited":true}"#] {
            let response = try JSONDecoder().decode(
                WorkFavoriteResponseDto.self, from: Data(body.utf8)
            )
            XCTAssertFalse(response.isAcknowledged, "\(body) 不是确认")
        }
        let ack = try JSONDecoder().decode(
            WorkActionAcknowledgementDto.self, from: Data(#"{"ok":true}"#.utf8)
        )
        XCTAssertTrue(ack.isAcknowledged)
        XCTAssertFalse(
            try JSONDecoder().decode(WorkActionAcknowledgementDto.self, from: Data("{}".utf8))
                .isAcknowledged
        )
    }

    /// dislike 的回执**只有 `disliked`** ⇒ 类型上就没有 `favorited`（互斥的另一半由权威回读说话）。
    func testDislikeResponseDoesNotInventAFavoritedField() throws {
        let response = try JSONDecoder().decode(
            WorkDislikeResponseDto.self,
            from: Data(#"{"ok":true,"disliked":true,"favorited":false}"#.utf8)
        )
        XCTAssertEqual(response.disliked, true)
        let labels = Set(Mirror(reflecting: response).children.compactMap(\.label))
        XCTAssertEqual(labels, ["ok", "disliked"], "本层不建模服务端没为这个端点承诺的键")
    }

    func testNoteMaterializationHandsBackTheNoteId() throws {
        let response = try JSONDecoder().decode(
            WorkNoteMaterializationDto.self, from: Data(#"{"ok":true,"noteId":"note-9f3a"}"#.utf8)
        )
        XCTAssertTrue(response.isAcknowledged)
        XCTAssertEqual(response.resolvedNoteId, "note-9f3a")
        // 空串 noteId = 没拿到（幂等端点回个空串是漂移，不是"物化了一条空笔记"）。
        XCTAssertNil(
            try JSONDecoder().decode(
                WorkNoteMaterializationDto.self, from: Data(#"{"ok":true,"noteId":""}"#.utf8)
            ).resolvedNoteId
        )
    }

    /// `lrc: null` 是**正常路径**（纯音乐 / 无 clip / 上游任何失败都回这一形状）⇒ 不许弹错。
    func testTimingNullIsAFallbackNotAnError() throws {
        let null = try Fixture.decode(WorkTimingResponseDto.self, "work-timing-null")
        XCTAssertEqual(null.ok, true)
        XCTAssertNil(null.lrc)
        XCTAssertFalse(null.hasAlignedLyrics)
        XCTAssertTrue(null.shouldFallBackToPlainLyrics)

        let lrc = try Fixture.decode(WorkTimingResponseDto.self, "work-timing-lrc")
        XCTAssertTrue(lrc.hasAlignedLyrics)
        XCTAssertFalse(lrc.shouldFallBackToPlainLyrics)
        XCTAssertTrue(lrc.lrc?.contains("[00:12.40]") == true)

        // 空串/纯空白同样回退（有的服务端实现会给 ""）。
        for body in [#"{"ok":true,"lrc":""}"#, #"{"ok":true,"lrc":"  \n"}"#, #"{"ok":true}"#] {
            let parsed = try JSONDecoder().decode(WorkTimingResponseDto.self, from: Data(body.utf8))
            XCTAssertTrue(parsed.shouldFallBackToPlainLyrics, "\(body) 不该被当成有对齐歌词")
        }
    }

    func testShareStatusDistinguishesOffFromUnknown() throws {
        let off = try Fixture.decode(WorkShareStatusResponseDto.self, "work-share-status-off")
        XCTAssertEqual(off.state, .off, "服务端明说没开")

        let unknown = try JSONDecoder().decode(
            WorkShareStatusResponseDto.self, from: Data("{}".utf8)
        )
        XCTAssertEqual(unknown.state, .unknown, "没给 enabled 不许默认成「没开」")

        let on = try JSONDecoder().decode(
            WorkShareStatusResponseDto.self,
            from: Data(#"{"enabled":true,"sharePath":"/share/work/tk_1"}"#.utf8)
        )
        XCTAssertEqual(on.state, .on)
        XCTAssertEqual(on.sharePath, "/share/work/tk_1")
    }

    func testShareEnableEchoesTheSharePathVerbatim() throws {
        let response = try JSONDecoder().decode(
            WorkShareEnableResponseDto.self,
            from: Data(#"{"ok":true,"sharePath":"/share/work/tk_ab-12"}"#.utf8)
        )
        XCTAssertTrue(response.isAcknowledged)
        XCTAssertEqual(response.resolvedSharePath, "/share/work/tk_ab-12")
        XCTAssertNil(
            try JSONDecoder().decode(
                WorkShareEnableResponseDto.self, from: Data(#"{"ok":true,"sharePath":" "}"#.utf8)
            ).resolvedSharePath
        )
    }

    // MARK: - 改名

    func testRenameTitleBoundsAreOneThroughTwoHundred() throws {
        XCTAssertEqual(WorkRenameRequestDto.titleMinimumLength, 1)
        XCTAssertEqual(WorkRenameRequestDto.titleMaximumLength, 200)
        XCTAssertThrowsError(try WorkRenameRequestDto(title: "")) { error in
            XCTAssertEqual(error as? WorkActionRequestError, .emptyTitle)
        }
        XCTAssertThrowsError(try WorkRenameRequestDto(title: "   \n ")) { error in
            XCTAssertEqual(error as? WorkActionRequestError, .emptyTitle, "纯空白也是空标题")
        }
        let limit = String(repeating: "夏", count: 200)
        XCTAssertNoThrow(try WorkRenameRequestDto(title: limit))
        XCTAssertThrowsError(
            try WorkRenameRequestDto(title: limit + "extra")
        ) { error in
            XCTAssertEqual(
                error as? WorkActionRequestError, .titleTooLong(limit: 200, actual: 205)
            )
        }
        let request = try WorkRenameRequestDto(title: "  改过的标题  ")
        XCTAssertEqual(request.title, "改过的标题", "发出前 trim（同 generate 的 prompt 口径）")
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(request), fixture: "requests/work-rename-request"
        )
    }

    /// `PATCH` 的回执带**整行**：那一行走 `WorksListRowDto`（同一个行投影，不写第二份）。
    func testRenameResponseReusesTheWorksRowProjection() throws {
        let response = try Fixture.decode(WorkRenameResponseDto.self, "work-rename-response")
        XCTAssertTrue(response.isAcknowledged)
        XCTAssertFalse(response.workPresentButUnreadable)
        let row = try XCTUnwrap(response.work)
        XCTAssertEqual(row.displayTitle, "改过的标题")
        XCTAssertEqual(row.identity, .candidate(jobID: "job-7f3a", candidateID: "cand-1"))
        XCTAssertTrue(row.favorited)
        XCTAssertFalse(row.disliked)
    }

    /// 「服务端说改好了，回的那行我们认不出」与「根本没回 work」是两件事。
    func testUnreadableWorkIsDistinctFromMissingWork() throws {
        let noWork = try JSONDecoder().decode(
            WorkRenameResponseDto.self, from: Data(#"{"ok":true,"work":null}"#.utf8)
        )
        XCTAssertNil(noWork.work)
        XCTAssertFalse(noWork.workPresentButUnreadable, "显式 null 是「没给行」")

        let unreadable = try JSONDecoder().decode(
            WorkRenameResponseDto.self, from: Data(#"{"ok":true,"work":{"title":"没有 id"}}"#.utf8)
        )
        XCTAssertNil(unreadable.work)
        XCTAssertTrue(unreadable.workPresentButUnreadable, "给了行却读不出身份 ⇒ 必须可见")

        let missing = try JSONDecoder().decode(
            WorkRenameResponseDto.self, from: Data(#"{"ok":true}"#.utf8)
        )
        XCTAssertNil(missing.work)
        XCTAssertFalse(missing.workPresentButUnreadable)
    }

    // MARK: - 路径与方法

    func testRoutesMapOntoMethodsAndSubpathsExactlyOnceEach() throws {
        XCTAssertEqual(WorkActionRoute.allCases.count, 9, "七个端点里 share 占三种方法")
        for route in WorkActionRoute.allCases {
            switch route {
            case .favorite, .dislike, .note, .shareOpen: XCTAssertEqual(route.method, .post)
            case .timing, .shareStatus: XCTAssertEqual(route.method, .get)
            case .shareClose, .delete: XCTAssertEqual(route.method, .delete)
            case .rename: XCTAssertEqual(route.method, .patch)
            }
        }
        XCTAssertEqual(WorkActionRoute.favorite.path(workID: "job-1:cand-1"),
                       "/api/studio/create/works/job-1:cand-1/favorite")
        XCTAssertEqual(WorkActionRoute.shareStatus.path(workID: "job-1:cand-1"),
                       "/api/studio/create/works/job-1:cand-1/share")
        XCTAssertEqual(WorkActionRoute.rename.path(workID: "job-1:cand-1"),
                       "/api/studio/create/works/job-1:cand-1")
        XCTAssertEqual(WorkActionRoute.delete.path(workID: "job-9c2b"),
                       "/api/studio/create/works/job-9c2b", "裸 jobId 也是合法 id")
    }

    /// 伪 id 里的冒号必须放行（否则七条腿全都发不出去）。
    func testColonBearingPseudoIDSurviveThePathGate() throws {
        for id in ["job-7f3a:cand-1", "job-7f3a:pending-2", "job_1.2:cand-3", "job-7f3a"] {
            XCTAssertNotNil(WorkActionRoute.timing.path(workID: id), "\(id) 是合法伪 id")
        }
    }

    /// 认不出来的 id ⇒ **不发**（宁可不发，也不发一条打到别的资源上的路径）。
    func testUnsafeIdentifiersRefuseToProduceAPath() {
        let unsafe = ["", " ", "job/../x", "job?x=1", "job#frag", "job%20x", "job/1",
                      "job\\1", "job:1:2", "job 1", String(repeating: "j", count: 300)]
        for id in unsafe {
            XCTAssertNil(WorkActionRoute.favorite.path(workID: id), "\(id) 不该拼进路径")
            XCTAssertThrowsError(try WorkActionRoute.favorite.validatedPath(workID: id)) { error in
                XCTAssertEqual(error as? WorkActionRequestError, .unsafeWorkIdentifier)
            }
        }
    }

    /// §4.7 第②条：rename/delete/share 是 **job 级**（一次生成两行 ⇒ 改一行等于改两行）。
    /// UI 的交代口径全靠这一条，判据写错就是替用户改了另一行还不吭声。
    func testJobScopedVersusRowScopedActionsAreClassifiedPerTheContract() {
        for route in [WorkActionRoute.rename, .delete, .shareOpen, .shareStatus, .shareClose] {
            XCTAssertTrue(route.isJobScoped, "\(route) 是 job 级")
        }
        for route in [WorkActionRoute.favorite, .dislike, .note, .timing] {
            XCTAssertFalse(route.isJobScoped, "\(route) 是行级")
        }
    }

    // MARK: - 错误分诊（A4 / A15 同族判据）

    func testNotMaterialisedCarriesTheServerSentence() throws {
        let body = try Fixture.data("work-error-not-materialised")
        let rejection = WorkActionRejection.classify(statusCode: 409, body: body)
        XCTAssertEqual(
            rejection, .notMaterialisedYet(serverMessage: "作品尚未生成完成，暂不能执行此操作")
        )
        XCTAssertEqual(rejection.userMessage, "作品尚未生成完成，暂不能执行此操作", "409 透传原文")
    }

    func testEveryStatusBucketSaysSomethingHumanAndNeverAnEnglishCode() {
        let bodies: [Data?] = [
            Data(#"{"error":"作品不存在"}"#.utf8),
            Data(#"{"error":"not_found"}"#.utf8),
            Data(#"{"error":"rate_limited","code":"RATE_LIMITED"}"#.utf8),
            nil,
        ]
        let forbidden = ["not_found", "invalid_request", "RATE_LIMITED", "rate_limited",
                         "AUTH_REQUIRED", "IDEMPOTENCY_CONFLICT"]
        for status in [400, 401, 403, 404, 409, 429, 500, 502, 503] {
            for body in bodies {
                let rejection = WorkActionRejection.classify(statusCode: status, body: body)
                let message = rejection.userMessage
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.contains("未知错误"), "不许糊一个「未知错误」")
                for word in forbidden {
                    XCTAssertFalse(
                        message.contains(word), "\(status)/\(body?.description ?? "nil") 把英文码印上屏：\(message)"
                    )
                }
            }
        }
        XCTAssertEqual(WorkActionRejection.classify(statusCode: 401, body: nil), .unauthenticated)
        XCTAssertEqual(WorkActionRejection.classify(statusCode: 403, body: nil), .unauthenticated)
        XCTAssertEqual(
            WorkActionRejection.classify(statusCode: 404, body: Data(#"{"error":"作品不存在"}"#.utf8)),
            .workNotFound(serverMessage: "作品不存在")
        )
        XCTAssertEqual(
            WorkActionRejection.classify(statusCode: 400, body: nil).userMessage,
            "这一步没被接受（服务端未说明原因）"
        )
        XCTAssertEqual(
            WorkActionRejection.classify(statusCode: 429, body: nil).userMessage,
            "操作太频繁了，稍后再试"
        )
        XCTAssertEqual(
            WorkActionRejection.classify(statusCode: 500, body: nil).userMessage, "服务端错误（500）"
        )
    }

    /// 409 的两句 extras 原文与作品端点那句**不同**，但都归到"还没做完"这一档（见 ExtrasDTO 那套分诊）。
    func testThe409BucketDoesNotRewordTheServer() {
        let custom = Data(#"{"error":"作品尚未完成，完成后才可补充制作"}"#.utf8)
        XCTAssertEqual(
            WorkActionRejection.classify(statusCode: 409, body: custom).userMessage,
            "作品尚未完成，完成后才可补充制作"
        )
    }

    /// `error` 的透传闸门来自 `StudioCreateRejection.human`：**只有一份**。
    func testTheHumanSaysGateIsSharedNotReimplemented() {
        XCTAssertNil(WorkActionRejection.human("credits_insufficient"), "裸码形状不透传")
        XCTAssertEqual(WorkActionRejection.human("请填写音乐描述"), "请填写音乐描述")
        XCTAssertEqual(
            WorkActionRejection.human("Music description is too long, please shorten it"),
            "Music description is too long, please shorten it",
            "带空格/标点的当人话透传（不许替服务端改口）"
        )
        // 同一个闸门与 StudioCreate 那条判据必须给同一个答复（两处口径分家是本仓的复发缺陷族）。
        for probe in ["submit_failed", "作品不存在", "a_b c", ""] {
            XCTAssertEqual(
                WorkActionRejection.human(probe), StudioCreateRejection.human(probe),
                "闸门分家了：\(probe)"
            )
        }
    }
}
