@testable import CovaCore
import Foundation
import XCTest

/// extras（补充制作）两条腿的契约面（DEVELOPMENT.md §4.7「extras」）。
///
/// 本文件钉的四条会静默骗人的事实：
/// ① `instrumental == true` 的行服务端**滤掉**四项 ⇒ 客户端选项集必须跟着滤，否则画出来的是
///    点一下回 400 的钮；
/// ② `works/{id}/extras` **只认伪 id**（裸 jobId 404）且**不回 `deliveryRevision`**；
/// ③ 待做时 `url` 整个键不发、状态文本塞在 `version` 里 ⇒ 必须读成枚举，不是字符串；
/// ④ `files[].url` 里的 jobId 是 **worker job**，不是 `sourceGenerationJobId` ⇒ 只许原样消费。
final class ExtrasDTOTests: XCTestCase {

    // MARK: - 键集与筛选

    func testTheSixKeysAreTheClosedSetTheServerReads() {
        XCTAssertEqual(
            WorkExtraKey.allKeysInContractOrder.map(\.rawValue),
            ["wav", "stems", "vocal_stems", "accompaniment", "lyrics_video", "lyrics_timing"]
        )
        // 未知键服务端**静默丢弃**（不报错）⇒ 恢复入口认不出来就给 nil，不折成某个认识的值。
        XCTAssertNil(WorkExtraKey.recognized("mastering"))
        XCTAssertNil(WorkExtraKey.recognized("WAV"), "大小写不是同义词")
        XCTAssertEqual(WorkExtraKey.recognized("vocal_stems"), .vocalStems)
    }

    /// 纯音乐行的滤除集就是那四项（`wav`/`stems` 保留）。
    func testInstrumentalRowsLoseExactlyTheFourVocalBoundKeys() {
        let allowed = WorkExtraKey.allowedKeys(instrumental: true)
        XCTAssertEqual(allowed.map(\.rawValue), ["wav", "stems"])
        for key in WorkExtraKey.instrumentalExcludedKeys {
            XCTAssertFalse(WorkExtraKey.isAllowed(key, instrumental: true))
            XCTAssertTrue(WorkExtraKey.isAllowed(key, instrumental: false))
        }
        XCTAssertEqual(WorkExtraKey.allowedKeys(instrumental: false).count, 6)
    }

    /// `instrumental` 读不出 ⇒ **不滤**：滤掉就是替服务端做一个我们不知道成立与否的决定。
    func testUnknownInstrumentalityDoesNotFilterAnything() {
        XCTAssertEqual(WorkExtraKey.allowedKeys(instrumental: nil).count, 6, "没给就不滤，不猜")
        XCTAssertTrue(WorkExtraKey.isAllowed(.lyricsVideo, instrumental: nil))
    }

    // MARK: - 会话级扣费额（作品级分文不收）

    func testSessionDeductionTableMatchesTheContractCard() {
        XCTAssertEqual(WorkExtraKey.wav.sessionDeductionCredits, 20)
        XCTAssertEqual(WorkExtraKey.accompaniment.sessionDeductionCredits, 30)
        XCTAssertEqual(WorkExtraKey.stems.sessionDeductionCredits, 50)
        XCTAssertEqual(WorkExtraKey.vocalStems.sessionDeductionCredits, 50)
        XCTAssertEqual(WorkExtraKey.lyricsTiming.sessionDeductionCredits, 10)
        XCTAssertEqual(WorkExtraKey.lyricsVideo.sessionDeductionCredits, 100)
        // 去重后合计（同一个键写两遍不该翻倍）。
        XCTAssertEqual(
            WorkExtraKey.sessionDeductionTotal(for: [.wav, .wav, .stems]), 70,
            "重复键不得重复计入合计"
        )
        XCTAssertEqual(WorkExtraKey.sessionDeductionTotal(for: []), 0)
    }

    /// 作品级那一条腿恒 0 —— 这一条是文案判据的地基（§4.7：不许在免费那条腿上暗示数额）。
    func testWorksPathChargesNothingAtAll() throws {
        XCTAssertEqual(WorkExtraKey.worksPathDeductionCredits, 0)
        let request = try WorkExtrasRequestDto(keys: [.wav, .stems, .lyricsVideo])
        XCTAssertEqual(request.worksPathDeductionCredits, 0, "复用会话那张表就是说谎")
        // 同一组键在会话级是要扣的（两条腿的差别必须同时可断言，防止有人"统一"成一个数）。
        let session = try XCTUnwrap(
            SessionExtrasRequestDto(sessionId: "sess-test-0001", keys: [.wav, .stems, .lyricsVideo])
        )
        XCTAssertEqual(session.sessionDeductionTotalCredits, 170)
    }

    // MARK: - ③ 待做状态：url 缺键 + version 是状态文本

    /// `url` 缺键的那些项**没有下载地址**，`version` 里塞的是状态文本 ⇒ 读成枚举。
    func testPendingFilesHaveNoURLAndTheirVersionIsStateTextNotAVersionNumber() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        XCTAssertEqual(response.files.count, 7)
        XCTAssertEqual(response.unreadableItemCount, 0)

        let pending = try XCTUnwrap(response.files.first { $0.id == "extra-worker-8f31c2-lyrics-video" })
        XCTAssertNil(pending.url, "待做时服务端整个 url 键都不发")
        XCTAssertFalse(pending.hasDownloadURL)
        XCTAssertFalse(pending.isDownloadable)
        XCTAssertEqual(pending.version, "补充制作准备中", "同一个字段承担的是状态文本")
        XCTAssertEqual(pending.deliveryState, .preparing)
        // 关键反证：把 version 当版本号读的那一句会印出「v 补充制作准备中」。
        XCTAssertNotEqual(pending.deliveryState, .ready)

        let failed = try XCTUnwrap(response.files.first { $0.id == "extra-worker-9a77b1-vocal-stems" })
        XCTAssertEqual(failed.deliveryState, .failed(message: "上游制作超时"))
        if case .failed(let message) = failed.deliveryState {
            XCTAssertEqual(message, "上游制作超时", "原因原文要拿得出来")
        } else {
            XCTFail("不是失败档")
        }

        let cancelled = try XCTUnwrap(response.files.first { $0.id == "extra-worker-9a77b1-lyrics-timing" })
        XCTAssertEqual(cancelled.deliveryState, .cancelled)

        // 第四个状态文本（"还没轮到"）是**我们没见过的**：不许被 default 吞成"准备中"。
        let other = try XCTUnwrap(response.files.first { $0.id == "extra-worker-9a77b1-cover" })
        XCTAssertEqual(other.deliveryState, .unrecognised(version: "还没轮到"))
        XCTAssertFalse(other.isDownloadable)

        let ready = try XCTUnwrap(response.files.first { $0.id == "extra-worker-8f31c2-master-wav" })
        XCTAssertEqual(ready.deliveryState, .ready)
        XCTAssertEqual(ready.version, "3")
    }

    /// 没 url 也没 version（服务端只给了一半）⇒ `.unrecognised(nil)`，不猜"准备中"。
    func testMissingURLAndMissingVersionIsUnrecognisedNotPreparing() {
        XCTAssertEqual(
            WorkExtraDeliveryState.derive(urlPresent: false, version: nil), .unrecognised(version: nil)
        )
        XCTAssertEqual(WorkExtraDeliveryState.derive(urlPresent: false, version: ""),
                       .unrecognised(version: ""))
        XCTAssertEqual(WorkExtraDeliveryState.derive(urlPresent: true, version: "补充制作准备中"), .ready,
                       "url 在场就以可下载性为准")
        XCTAssertEqual(
            WorkExtraDeliveryState.derive(urlPresent: false, version: "失败："),
            .failed(message: nil), "只有前缀没有原因 ⇒ 原因如实是 nil，不编一句"
        )
    }

    // MARK: - ④ worker job ≠ 生成 job：原样消费

    /// `files[].url` 里那个 job 段是 **worker job**，与 `sourceGenerationJobId` 是两个不同的 id。
    /// 本层因此**不提供任何拼地址的出口**：能拿到的只有原文 `SecretString`。
    func testArtifactURLCarriesTheWorkerJobIDAndIsConsumedVerbatim() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let wav = try XCTUnwrap(response.files.first { $0.id == "extra-worker-8f31c2-master-wav" })
        let raw = try XCTUnwrap(wav.url?.rawValue)
        XCTAssertEqual(
            raw, "/api/studio/extras/artifacts/worker-8f31c2/master-wav?ref=mr_9d0e&intent=download",
            "地址必须逐字节原样，参数一个都不重编码"
        )
        XCTAssertEqual(wav.sourceGenerationJobId, "job-7f3a")
        XCTAssertTrue(raw.contains("worker-8f31c2"), "url 里是 worker job")
        XCTAssertFalse(raw.contains("job-7f3a"), "url 里**不是**生成 job —— 这就是那条禁令的形状")

        // 拿生成 job 去拼产物路径：服务端会给 404（或打到别的东西上）。这里把"那样拼出来的
        // 不是服务端给的那条"钉住，任何偷偷加构造器的改动都会撞上这条。
        let naive = "/api/studio/extras/artifacts/\(wav.sourceGenerationJobId!)/master-wav"
        XCTAssertNotEqual(raw, naive)
        XCTAssertTrue(
            response.files.allSatisfy { file in
                guard let url = file.url?.rawValue, let generation = file.sourceGenerationJobId else {
                    return true
                }
                return !url.contains("/artifacts/\(generation)/")
            }, "没有任何一条 url 用的是生成 job"
        )
    }

    /// `extra-<workerJobId>-<artifactId>`：两段都可能含 `-` ⇒ 本层**不**提供切分还原。
    func testArtifactIDIsOpaqueBecauseBothSegmentsMayContainDashes() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let file = try XCTUnwrap(response.files.first)
        XCTAssertTrue(file.id?.hasPrefix("extra-") == true)
        // 反射面只有契约那八个键 —— 没有 workerJobId / artifactId 这种"拆出来的"字段。
        let labels = Set(Mirror(reflecting: file).children.compactMap(\.label))
        XCTAssertEqual(labels, [
            "id", "name", "rawType", "url", "version", "sourceGenerationJobId",
            "sourceCandidateId", "createdAt",
        ])
    }

    // MARK: - 类型词表与逐行容错

    /// 词表外的新 type 必须**留下原拼写并保住这一行**（用户已经付过 co 的产物不许因为词表旧而消失）。
    func testUnknownFileTypeKeepsTheRowAndTheRawSpelling() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let flac = try XCTUnwrap(response.files.first { $0.id == "extra-worker-9a77b1-flac" })
        XCTAssertEqual(flac.rawType, "flac-master")
        XCTAssertEqual(flac.kind, .unknown("flac-master"))
        XCTAssertEqual(flac.kind?.rawType, "flac-master", "原拼写一个字都不改")
        XCTAssertTrue(flac.isDownloadable, "认不出类型不是不能下载")
        // 八值闭合词表：多一档/少一档都是契约变更，该在这里红。
        let documented = ["audio-wav", "instrumental-wav", "instrumental-mp3", "stems", "video",
                          "doc", "cover", "other"]
        for raw in documented {
            XCTAssertEqual(WorkExtraFileKind(rawType: raw).rawType, raw, "\(raw) 的往返拼写")
            XCTAssertNotEqual(WorkExtraFileKind(rawType: raw), .unknown(raw))
        }
        XCTAssertEqual(Set(WorkExtraFileKind.knownRawTypes.keys), Set(documented))
    }

    func testGarbageFileEntriesAreCountedNotSilentlyDropped() throws {
        let page = try Fixture.decode(WorkExtrasResponseDto.self, "extras-garbage-files")
        XCTAssertEqual(page.files.count, 1, "四个读不出的元素之后那一项必须还活着")
        XCTAssertEqual(page.unreadableItemCount, 3)
        XCTAssertEqual(page.files.first?.id, "extra-worker-1-art-1")
    }

    /// `files` 键读不出来 ⇒ **抛**（不许降级成"没有产物"）。
    func testMissingFilesKeyThrowsInsteadOfReadingAsNoArtifacts() {
        for body in ["{}", #"{"files":null}"#, #"{"files":"none"}"#, "[]"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(WorkExtrasResponseDto.self, from: Data(body.utf8))
            )
        }
        XCTAssertNoThrow(
            try JSONDecoder().decode(WorkExtrasResponseDto.self, from: Data(#"{"ok":true,"files":[]}"#.utf8))
        )
    }

    // MARK: - ② 两条腿的形状差别：作品级没有 deliveryRevision

    /// 作品级响应**不回** `deliveryRevision` ⇒ 类型上根本没有那个属性（不建模服务端不发的键）。
    func testWorksPathResponseHasNoDeliveryRevisionProperty() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let labels = Set(Mirror(reflecting: response).children.compactMap(\.label))
        XCTAssertEqual(labels, ["ok", "files", "unreadableItemCount"])
        XCTAssertFalse(labels.contains("deliveryRevision"), "作品级那一腿不许有这个字段")
        XCTAssertFalse(labels.contains("total"))
    }

    func testSessionPathCarriesTheWorkflowRevisionCounter() throws {
        let snapshot = try Fixture.decode(SessionExtrasResponseDto.self, "extras-session-snapshot")
        XCTAssertEqual(snapshot.deliveryRevision, 4, "会话级才有工作流计数器")
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertTrue(snapshot.isAcknowledged)

        // 计数器读不出 ⇒ nil，**不填 0**：0 会被读成"第一版"，于是漂移伪装成"版本没变"。
        let missing = try JSONDecoder().decode(
            SessionExtrasResponseDto.self, from: Data(#"{"ok":true,"files":[]}"#.utf8)
        )
        XCTAssertNil(missing.deliveryRevision)
        let stringly = try JSONDecoder().decode(
            SessionExtrasResponseDto.self,
            from: Data(#"{"ok":true,"files":[],"deliveryRevision":"4"}"#.utf8)
        )
        XCTAssertNil(stringly.deliveryRevision)
        XCTAssertEqual(stringly.files.count, 0)
    }

    // MARK: - 请求体与路径

    func testRequestBodiesEncodeOnlyTheContractKeys() throws {
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(try WorkExtrasRequestDto(keys: [.wav, .stems])),
            fixture: "requests/extras-works-request"
        )
        try XCTAssertEncodedJSONEqual(
            JSONEncoder().encode(
                try SessionExtrasRequestDto(
                    sessionId: "sess-test-0001", keys: [.wav, .accompaniment, .lyricsVideo]
                )
            ),
            fixture: "requests/extras-session-request"
        )
    }

    /// 空选择本地就拦（服务端那一档是 400「请选择可用的补充制作文件。」）。
    func testEmptySelectionIsRejectedBeforeTheNetwork() {
        XCTAssertThrowsError(try WorkExtrasRequestDto(keys: [])) { error in
            XCTAssertEqual(error as? WorkExtrasRequestError, .noKeysSelected)
        }
        XCTAssertThrowsError(try SessionExtrasRequestDto(sessionId: "sess-1", keys: []))
        XCTAssertThrowsError(try SessionExtrasRequestDto(sessionId: "   ", keys: [.wav])) { error in
            XCTAssertEqual(error as? WorkExtrasRequestError, .missingSessionID)
        }
    }

    func testDuplicateKeysAreDeduplicatedWhileOrderIsPreserved() throws {
        let request = try WorkExtrasRequestDto(keys: [.stems, .wav, .stems])
        XCTAssertEqual(request.keys, [.stems, .wav], "去重但不排序（排序会改掉提交的顺序语义）")
    }

    /// `works/{id}/extras` **只认伪 id**：裸 jobId 服务端直接 404，而屏上 404 与"作品不存在"分不开
    /// ⇒ 在本地就拦（§4.7）。占位行是合法伪 id，让它拿到服务端的 409。
    func testWorksExtrasPathAcceptsPseudoIDsOnly() throws {
        let request = try WorkExtrasRequestDto(keys: [.wav])
        XCTAssertEqual(
            try request.path(workID: "job-7f3a:cand-1"),
            "/api/studio/create/works/job-7f3a:cand-1/extras"
        )
        XCTAssertEqual(
            try request.path(workID: "job-7f3a:pending-1"),
            "/api/studio/create/works/job-7f3a:pending-1/extras",
            "占位行也发得出去（它拿到的是 409，那才是权威答复）"
        )
        XCTAssertThrowsError(try request.path(workID: "job-7f3a")) { error in
            XCTAssertEqual(error as? WorkExtrasRequestError, .bareJobIDRejected)
        }
        XCTAssertThrowsError(try request.path(workID: "job 1")) { error in
            XCTAssertEqual(
                error as? WorkExtrasRequestError, .bareJobIDRejected,
                "没有冒号段的 id 一律按裸 jobId 拦（哪怕里面还混了空格）"
            )
        }
        XCTAssertThrowsError(try request.path(workID: "job 1:cand")) { error in
            XCTAssertEqual(error as? WorkExtrasRequestError, .unsafeWorkIdentifier, "伪 id 里不许有空白")
        }
        XCTAssertThrowsError(try request.path(workID: "job:x/y")) { error in
            XCTAssertEqual(error as? WorkExtrasRequestError, .unsafeWorkIdentifier)
        }
        // GET 复列走同一条判据（同一个规则不许有第二份）。
        XCTAssertEqual(
            try WorkExtrasEndpoint.workPath(workID: "job-7f3a:cand-2"),
            "/api/studio/create/works/job-7f3a:cand-2/extras"
        )
    }

    func testSessionQueryCarriesExactlyOneKeyOrNil() {
        XCTAssertEqual(
            WorkExtrasEndpoint.sessionQueryItems(sessionId: "sess-test-0001")?
                .map { "\($0.name)=\($0.value ?? "")" },
            ["sessionId=sess-test-0001"]
        )
        XCTAssertNil(WorkExtrasEndpoint.sessionQueryItems(sessionId: ""), "不发空 sessionId")
        XCTAssertNil(WorkExtrasEndpoint.sessionQueryItems(sessionId: "  "))
        XCTAssertNil(WorkExtrasEndpoint.sessionQueryItems(sessionId: nil))
        XCTAssertNil(WorkExtrasEndpoint.sessionQueryItems(sessionId: "sess/../../x"))
        XCTAssertEqual(WorkExtrasEndpoint.sessionPath, "/api/studio/extras")
    }

    // MARK: - 错误分诊

    /// 四档实测原文逐条一档；两个 409 的**处置方向不同**，压成一档就是把两类用户都指错。
    func testTheFourDocumentedSentencesLandInFourDifferentBuckets() throws {
        func body(_ text: String) throws -> Data {
            try JSONEncoder().encode(["error": text])
        }
        XCTAssertEqual(
            ExtrasRejection.classify(statusCode: 404, body: try body("作品不存在")),
            .workMissing(serverMessage: "作品不存在")
        )
        let notCompleted = ExtrasRejection.classify(
            statusCode: 409, body: try body("作品尚未完成，完成后才可补充制作")
        )
        XCTAssertEqual(notCompleted, .notCompleted(serverMessage: "作品尚未完成，完成后才可补充制作"))
        XCTAssertTrue(notCompleted.shouldKeepWaiting, "还没做完 = 等，不是失败")

        let incomplete = ExtrasRejection.classify(
            statusCode: 409, body: try body("作品素材不完整，暂不能补充制作")
        )
        XCTAssertEqual(incomplete, .sourceIncomplete(serverMessage: "作品素材不完整，暂不能补充制作"))
        XCTAssertFalse(incomplete.shouldKeepWaiting, "素材不完整 = 等也没用")

        XCTAssertEqual(
            ExtrasRejection.classify(statusCode: 400, body: try body("请选择可用的补充制作文件。")),
            .noUsableKeys(serverMessage: "请选择可用的补充制作文件。")
        )
        XCTAssertNotEqual(notCompleted, incomplete, "两个 409 不许压成一档")
    }

    /// 没见过的一句 409 原文 ⇒ 落 `.server` 并**透传原文**，不给它编一句我的话。
    func testUnrecognisedServerSentencesArePassedThroughNotRewritten() {
        let odd = ExtrasRejection.classify(statusCode: 409, body: Data(#"{"error":"配额不足"}"#.utf8))
        XCTAssertEqual(odd, .server(statusCode: 409, serverMessage: "配额不足"))
        XCTAssertEqual(odd.userMessage, "配额不足")
        XCTAssertEqual(
            ExtrasRejection.classify(statusCode: 401, body: nil), .unauthenticated,
            "登录态那一档交给登录层，不在这里编话术"
        )
        XCTAssertFalse(
            ExtrasRejection.classify(statusCode: 409, body: nil).userMessage.isEmpty,
            "任何分支都得有可说的话（服务端没原文时也要说清未说明原因这一类）"
        )
    }

    // MARK: - 敏感面

    /// 产物地址收口 `SecretString`：描述/反射面不许漏出签名串（硬边界 3）。
    func testArtifactURLsAreRedactedInDescriptions() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let raw = try XCTUnwrap(response.files.first?.url?.rawValue)
        let firstFile = try XCTUnwrap(response.files.first)
        for rendered in [String(describing: response), String(reflecting: response),
                         String(describing: firstFile)] {
            XCTAssertFalse(rendered.contains(raw), "泄漏了产物地址")
        }
        XCTAssertTrue(String(describing: response).contains("<redacted>"))
    }

    /// 读不出/空的 name ⇒ nil，不拿 `type` 编一个文件名。
    func testDisplayNameDoesNotFallBackToTheFileType() throws {
        let response = try Fixture.decode(WorkExtrasResponseDto.self, "extras-works-files")
        let blank = try XCTUnwrap(response.files.first { $0.id == "extra-worker-9a77b1-cover" })
        XCTAssertEqual(blank.displayName, "封面")
        let nameless = WorkExtraDeliveryFileDto(
            id: "extra-x-y", name: "   ", rawType: nil, url: nil, version: "补充制作准备中",
            sourceGenerationJobId: nil, sourceCandidateId: nil, createdAt: nil
        )
        XCTAssertNil(nameless.displayName, "纯空白 name 就是没名字，不许拿 type 编一个文件名")
        XCTAssertEqual(nameless.deliveryState, .preparing)
        XCTAssertNil(nameless.kind, "type 没给就是没给，不造一个值")
    }
}
