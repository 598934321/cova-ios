import CovaCore
import CovaPlayer
import Foundation
import XCTest

@testable import CovaFeature

/// 21「补充制作」面板的裁决面（§5 P2-1 / §6 A8）。
///
/// 这一批用例盯的是**会把用户骗到的那几格**，而不是"函数有没有返回值"：
/// · 作品路径多印一个 `co` 数字 = 说了一件不存在的事（服务端那一条腿分文不收）；
/// · 把不认识的 `version` 原串画成「制作中」= 替服务端说了一件它没说过的事；
/// · 给没有 `url` 的在途行留一枚「保存到本机」= 一个点下去必然失败的钮；
/// · `deliveryRevision` 的 `nil` 折成 0 = 一次真变化被静默吞掉。
///
/// 全部走纯函数与值类型（不构造 `AppSession`、不发网络请求）：同一套打法在 19/22/23
/// 那几屏的测试里已经在用，视图只负责把这里算出来的行摆出来。
@MainActor
final class WorkExtrasFlowTests: XCTestCase {

    // MARK: - 夹具

    /// 一条产物（线格式形状，键集照 §4.7 实测）。
    private func file(
        _ id: String, type: String?, url: String? = nil, version: String?, name: String? = nil
    ) -> WorkExtraDeliveryFileDto {
        WorkExtraDeliveryFileDto(
            id: id, name: name, rawType: type, url: url.map(SecretString.init),
            version: version, sourceGenerationJobId: "job-1", sourceCandidateId: "cand-1",
            createdAt: "2026-09-27T00:00:00Z"
        )
    }

    private func ready(_ id: String, type: String) -> WorkExtraDeliveryFileDto {
        file(id, type: type, url: "https://covalink.cn/api/studio/extras/artifacts/j1/\(id)",
             version: "补充制作")
    }

    private func decodeWork(_ json: String) throws -> WorkExtrasResponseDto {
        try JSONDecoder().decode(WorkExtrasResponseDto.self, from: Data(json.utf8))
    }

    private func decodeSession(_ json: String) throws -> SessionExtrasResponseDto {
        try JSONDecoder().decode(SessionExtrasResponseDto.self, from: Data(json.utf8))
    }

    /// 一个已为某宿主打开、手里有这份快照的面板状态。
    private func state(
        _ host: WorkExtrasHost, files: [WorkExtraDeliveryFileDto], revision: Int? = nil
    ) -> WorkExtrasState {
        var subject = WorkExtrasState(host: host, ownerID: "principal-1")
        subject.applySnapshot(files, revision: revision)
        return subject
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let workHost = WorkExtrasHost.work(id: "job-1:cand-1", instrumental: nil)
    private let sessionHost = WorkExtrasHost.session(id: "sess-1", instrumental: nil)
    private let instrumentalWork = WorkExtrasHost.work(id: "job-2:cand-2", instrumental: true)

    // MARK: - §3.D 纯音乐：被屏蔽的四项**整行不存在**

    /// 纯音乐作品的 D 组恰两项（§9「被屏蔽的 4 项在视图树 / VoiceOver 序列 / 截图三处皆无」
    /// 的机械半条：行**根本没被构造出来**，不是置灰）。
    func testInstrumentalWorkOffersExactlyTwoKeysAndNeverTheOtherFour() {
        let rows = WorkExtrasPanelFacts.selectableRows(
            instrumental: true, files: [], localClaims: [], selected: [], chargesCredits: false
        )
        XCTAssertEqual(rows.map(\.key), [.wav, .stems])
        XCTAssertEqual(rows.map(\.label), ["母带 WAV", "分轨"])
        let banned: Set<WorkExtraKey> = [.vocalStems, .accompaniment, .lyricsTiming, .lyricsVideo]
        XCTAssertTrue(Set(rows.map(\.key)).isDisjoint(with: banned))
        let rendered = rows.flatMap { [$0.label, $0.caption, $0.costText ?? ""] }
        for needle in ["人声", "伴奏", "歌词", "不支持"] {
            XCTAssertFalse(
                rendered.contains(where: { $0.contains(needle) }),
                "纯音乐作品不许在 D 组画出含「\(needle)」的那一格（不渲染，而不是禁用）"
            )
        }
    }

    /// `instrumental` 读不出（`nil`）⇒ **不滤**：滤掉是替服务端做一个不知道成立与否的决定。
    func testUnknownInstrumentalFlagFallsBackToAllSixKeys() {
        XCTAssertEqual(
            WorkExtrasPanelFacts.allowedKeys(instrumental: nil), WorkExtrasPanelFacts.displayOrder
        )
        XCTAssertEqual(WorkExtrasPanelFacts.allowedKeys(instrumental: false).count, 6)
        XCTAssertEqual(WorkExtrasPanelFacts.allowedKeys(instrumental: true), [.wav, .stems])
    }

    /// 滤除与计价是两件事：纯音乐的会话宿主下，剩下那两枚**仍然带价目**。
    func testInstrumentalSessionLegStillPricesTheTwoSurvivingKeys() {
        let rows = WorkExtrasPanelFacts.selectableRows(
            instrumental: true, files: [], localClaims: [], selected: [.wav], chargesCredits: true
        )
        XCTAssertEqual(rows.map(\.costText), ["预计消耗 20 co", "预计消耗 50 co"])
        XCTAssertEqual(
            WorkExtrasPanelFacts.totalLine(selected: [.wav], chargesCredits: true, balance: nil)?.credits,
            20
        )
        // 作品宿主下的同两枚 ⇒ 一个数字都没有。
        let free = WorkExtrasPanelFacts.selectableRows(
            instrumental: true, files: [], localClaims: [], selected: [.wav], chargesCredits: false
        )
        XCTAssertTrue(free.allSatisfy { $0.costText == nil })
    }

    // MARK: - §3.D 展示顺序恒定（与响应数组顺序无关）

    /// 屏序恒为 `wav → stems → vocal_stems → accompaniment → lyrics_timing → lyrics_video`。
    ///
    /// 这一条同时钉住一处真实的坑：`WorkExtraKey.allKeysInContractOrder`（契约卡列键的顺序）
    /// 把 `lyrics_video` 排在 `lyrics_timing` **之前**，与 §3.D 的制作工序序相反。
    /// 拿枚举顺序当屏序，红的第一格就是用例里最后那两枚互换。
    func testDisplayOrderIsFixedRegardlessOfTheServerArrayOrder() throws {
        let page = try decodeWork(
            """
            {"ok":true,"files":[
              {"id":"extra-6","name":"夜-歌词视频.mp4","type":"video","url":"https://covalink.cn/v.mp4","version":"补充制作"},
              {"id":"extra-1","name":"夜-母带.wav","type":"audio-wav","url":"https://covalink.cn/w.wav","version":"补充制作"},
              {"id":"extra-5","name":"夜-歌词时序.json","type":"doc","url":"https://covalink.cn/t.json","version":"补充制作"}
            ]}
            """
        )
        let subject = state(workHost, files: page.files)
        // D 组：`wav` 与 `lyrics_video` 已被服务端答成"做好了"⇒ 从 D 组消失；剩下的按屏序。
        // `lyrics_timing` 留在 D 组是**已知限制**：那条产物的 `type` 是 `doc`，而 `doc` 同时是
        // `歌词.txt` 与 `制作参数.json` 的投影 ⇒ 认不出就不隐藏（下面 `testDocTypedFiles…` 那条）。
        XCTAssertEqual(
            subject.selectableRows.map(\.key),
            [.stems, .vocalStems, .accompaniment, .lyricsTiming]
        )
        // C 组：乱序数组进来，屏序出去（audio-wav 在前、video 在后；`doc` 认不出 ⇒ 不渲染）。
        XCTAssertEqual(subject.deliveredRows.map(\.artifactID), ["extra-1", "extra-6"])
        let order = WorkExtrasPanelFacts.displayOrder
        XCTAssertLessThan(
            try XCTUnwrap(order.firstIndex(of: .lyricsTiming)),
            try XCTUnwrap(order.firstIndex(of: .lyricsVideo))
        )
        XCTAssertNotEqual(order, WorkExtraKey.allKeysInContractOrder)
    }

    // MARK: - §3.D「同一 key 只出现在一处」：只认一对一的类型

    /// `audio-wav` ⇒ `wav`；`instrumental-wav` / `instrumental-mp3` ⇒ **`accompaniment`**；
    /// `video` ⇒ `lyrics_video`。
    ///
    /// ⚠️ 这一格与任务书给的映射**不同**，且是有意的：任务书写的是「`audio-wav`/`instrumental-wav`
    /// ⇒ wav」，而后端 `../web/src/lib/studio/extras-service.ts:313-322` 逐字是
    /// `master_wav → 'audio-wav'`、`accompaniment → mime 含 wav ? 'instrumental-wav' : 'instrumental-mp3'`。
    /// 把 `instrumental-wav` 记到 `wav` 名下会画出真 bug：做过**伴奏**的作品上，
    /// 「母带 WAV」会被无条件从 D 组抹掉（而它从没被做过），`accompaniment` 反而继续可选。
    func testUnambiguousTypesTakeTheirOwnKeyOutOfTheSelectableGroup() {
        XCTAssertEqual(
            WorkExtrasPanelFacts.hiddenKeys(in: [ready("1", type: "audio-wav")]), [.wav]
        )
        XCTAssertEqual(
            WorkExtrasPanelFacts.hiddenKeys(in: [ready("2", type: "instrumental-wav")]),
            [.accompaniment]
        )
        XCTAssertEqual(
            WorkExtrasPanelFacts.hiddenKeys(in: [ready("3", type: "instrumental-mp3")]),
            [.accompaniment]
        )
        XCTAssertEqual(
            WorkExtrasPanelFacts.hiddenKeys(in: [ready("4", type: "video")]), [.lyricsVideo]
        )
        let subject = state(
            workHost,
            files: [
                ready("1", type: "audio-wav"), ready("2", type: "instrumental-wav"),
                ready("4", type: "video"),
            ]
        )
        XCTAssertEqual(
            subject.selectableRows.map(\.key), [.stems, .vocalStems, .lyricsTiming],
            "隐藏的只有那三枚一对一的；认不出的继续留在 D 组"
        )
        XCTAssertEqual(subject.deliveredRows.map(\.label), ["母带 WAV", "伴奏", "歌词视频"])
    }

    /// 任务书点名的那一条限制：`stems` 一个类型盖住两三个 key ⇒ **一枚都不隐藏**。
    ///
    /// 分轨 / 人声分轨 / 伴奏同源于一个 worker（`create_stems`，只换 `outputs`），而
    /// `fileTypeForKind` 把 `stems` 与 `vocals` 都写成 `stems` ⇒ 拿类型指认是哪一个 key
    /// 就是自拼映射（硬边界 7）。漏隐藏的代价是"用户多点一次"，而后端
    /// `extras-service.ts:465-474` 在计费前先查 `prior` ⇒ 不重做也不重扣；
    /// 错隐藏的代价是把一件还没做过的事从屏上抹掉。所以宁缺不滥。
    /// 把它做精确所缺的那个字段 = 21 的**待答 1**（`files[]` 里可渲染的产物身份）。
    func testAStemsTypedFileHidesNeitherVocalStemsNorAccompanimentNorStems() {
        let stems = ready("extra-9", type: "stems")
        XCTAssertTrue(
            WorkExtrasPanelFacts.hiddenKeys(in: [stems]).isEmpty,
            "`stems` 盖住 分轨 / 人声分轨 两枚 ⇒ 一枚都不许隐藏"
        )
        let subject = state(sessionHost, files: [stems])
        XCTAssertEqual(subject.selectableRows.count, 6, "D 组不许因为一个认不出的类型而少行")
        // 那一格仍然出现在 C 组（用户已经付过 co 的产物不能看不见），标签说的是"两者之一"。
        XCTAssertEqual(subject.deliveredRows.map(\.label), ["分轨 / 人声分轨"])
        // 而 `instrumental-mp3`（伴奏）是另一码事：它一对一。
        let accompaniment = ready("extra-10", type: "instrumental-mp3")
        XCTAssertEqual(
            WorkExtrasPanelFacts.hiddenKeys(in: [stems, accompaniment]), [.accompaniment]
        )
    }

    /// `doc` 更糟：`timing` / `lyrics` / `metadata` 三种产物都投影成 `doc` ⇒
    /// 既不隐藏、也**不渲染**（那一格没有一句真话可说）。
    func testDocTypedFilesAreNeitherHiddenNorRendered() {
        let doc = ready("extra-11", type: "doc")
        XCTAssertTrue(WorkExtrasPanelFacts.hiddenKeys(in: [doc]).isEmpty)
        let subject = state(sessionHost, files: [doc])
        XCTAssertTrue(subject.deliveredRows.isEmpty, "认不出身份的一格不画出一条没有标签的行")
        XCTAssertTrue(subject.selectableRows.contains(where: { $0.key == .lyricsTiming }))
    }

    /// 在途（`.preparing`）与已完成一样把 key 收出 D 组；本地在途行被快照说上之后不收则不重复显。
    func testInFlightKeyLeavesSelectableGroupAndTheQueueDoesNotDoubleListIt() throws {
        let page = try decodeSession(
            """
            {"ok":true,"deliveryRevision":4,"files":[
              {"id":"extra-w-1","name":"夜-人声分轨.zip","type":"stems","version":"补充制作准备中"}
            ]}
            """
        )
        var subject = state(sessionHost, files: [], revision: 3)
        subject.locallyQueuedKeys = [.vocalStems]      // 刚点下去、还没等服务端说话
        XCTAssertEqual(subject.queueRows.map(\.label), ["人声分轨"])
        subject.applySnapshot(page.files, revision: page.deliveryRevision)
        // 快照里有一条"可能是它"的行 ⇒ 本地在途收掉，F 组只剩服务端那一条（同一 key 两行就是重复列）。
        XCTAssertTrue(subject.locallyQueuedKeys.isEmpty)
        XCTAssertEqual(subject.queueRows.map(\.label), ["分轨 / 人声分轨"])
        XCTAssertEqual(subject.deliveryRevision, 4)
        XCTAssertTrue(subject.deliveredRows.isEmpty)
    }

    // MARK: - §3.F 在途行没有 url ⇒ 整钮不渲染

    func testPendingRowExposesNoSaveActionAndNoProgressNumber() throws {
        let page = try decodeWork(
            """
            {"ok":true,"files":[
              {"id":"extra-w-2","name":"夜-母带.wav","type":"audio-wav","version":"补充制作准备中"}
            ]}
            """
        )
        let row = try XCTUnwrap(page.files.first)
        XCTAssertFalse(row.hasDownloadURL, "§4.7：待做时服务端**不发 url 键**")
        XCTAssertEqual(row.deliveryState, .preparing)
        let subject = state(workHost, files: page.files)
        let queued = try XCTUnwrap(subject.queueRows.first)
        XCTAssertFalse(queued.showsSaveAction, "无 url ⇒ 整钮不渲染（不是禁用态；09 §5 同判据）")
        XCTAssertEqual(queued.statusText, "制作中")
        XCTAssertTrue(queued.showsIndeterminate, "只有一枚菊花（17-S8 不确定指示）")
        let spoken = WorkExtrasPanelFacts.queueSpokenLabel(queued)
        XCTAssertEqual(spoken, "母带 WAV，制作中")
        // §9「屏内无百分比、无倒计时、无剩余时间」：这一格里没有任何进度可印。
        for needle in ["%", "剩余", "预计", "ETA", "秒"] {
            XCTAssertFalse(spoken.contains(needle))
        }
        XCTAssertFalse(subject.showsDeliveredSection, "只有一条待做行 ⇒ C 组连标题都不出现")
        XCTAssertEqual(subject.deliveredRows.count, 0)
        // 而这一格对应的 key 已经不在 D 组（同一 key 只出现在一处）。
        XCTAssertFalse(subject.selectableRows.contains(where: { $0.key == .wav }))
    }

    // MARK: - `.unrecognised` 的原串绝不画成「制作中」

    func testUnrecognisedVersionTextIsNeverRenderedAsPreparing() {
        let alien = file("extra-x", type: "audio-wav", version: "queued")
        XCTAssertEqual(alien.deliveryState, .unrecognised(version: "queued"))
        let subject = state(sessionHost, files: [alien])
        XCTAssertTrue(subject.queueRows.isEmpty, "认不出的那一格不是「制作中」")
        XCTAssertTrue(subject.deliveredRows.isEmpty)
        XCTAssertFalse(
            WorkExtrasPanelFacts.hiddenKeys(in: [alien]).contains(.wav),
            "认不出状态 ⇒ 不许替它决定这件东西已经在了"
        )
        XCTAssertTrue(subject.selectableRows.contains(where: { $0.key == .wav }))
        // 原串也不许从任何上屏/朗读片段里漏出去（17 §10 禁技术词 + A15）。
        let rendered = subject.selectableRows.flatMap { [$0.label, $0.caption] }
            + subject.queueRows.flatMap { [$0.label, $0.statusText ?? ""] }
            + subject.deliveredRows.map(\.label)
        XCTAssertFalse(rendered.contains(where: { $0.contains("queued") }))
    }

    /// `失败：<msg>` / `已取消` 两态同理：§8 清单里没有那一类词、§3.C 只承认两态 ⇒ 不渲染，
    /// key 继续可选（用户还能再要一次，服务端幂等复用不重扣）。
    func testFailedAndCancelledRowsAreNotDrawnAndLeaveTheirKeySelectable() {
        let failed = file("extra-f", type: "video", version: "失败：上游超时")
        let cancelled = file("extra-c", type: "audio-wav", version: "已取消")
        XCTAssertEqual(failed.deliveryState, .failed(message: "上游超时"))
        XCTAssertEqual(cancelled.deliveryState, .cancelled)
        let subject = state(sessionHost, files: [failed, cancelled])
        XCTAssertTrue(subject.deliveredRows.isEmpty)
        XCTAssertTrue(subject.queueRows.isEmpty)
        XCTAssertTrue(WorkExtrasPanelFacts.hiddenKeys(in: [failed, cancelled]).isEmpty)
        XCTAssertTrue(subject.selectableRows.contains(where: { $0.key == .wav }))
        XCTAssertTrue(subject.selectableRows.contains(where: { $0.key == .lyricsVideo }))
        // 「上游超时」是服务端的话，但本屏没有可挂它的那一格 ⇒ 也不许从标签里漏出去。
        let rendered = subject.selectableRows.flatMap { [$0.label, $0.caption] }
        XCTAssertFalse(rendered.contains(where: { $0.contains("上游") }))
    }

    // MARK: - §3.C `files` 为空 ⇒ C 组连同标题整组不渲染

    func testEmptyFilesRenderNoDeliveredGroupAndNoEmptyStateText() {
        let subject = state(workHost, files: [])
        XCTAssertFalse(subject.showsDeliveredSection)
        XCTAssertTrue(subject.deliveredRows.isEmpty)
        XCTAssertFalse(subject.showsQueueSection)
        // §3.C：不给「还没有交付物」那种空壳说明（D 组本身就在教用户怎么做）。
        XCTAssertEqual(subject.factLine, "这里不消耗 co")
        XCTAssertTrue(subject.showsSelectableSection)
    }

    /// §3.G：全部 key 都不可用 ⇒ D 组与主钮**一并消失**，只剩 C 组，不留空壳说明。
    ///
    /// 今天能到达那一格的路径只有两条：纯音乐作品（只剩两枚）+ `wav` 已完成 + `stems` 本地在途
    /// —— 因为 `stems` 类型认不出 key，靠服务端快照本身永远收不掉那一枚（待答 1 的可见面，
    /// 下面第二条用例就是把这件事钉成事实）。
    func testWhenNothingIsLeftSelectableBothTheGroupAndTheMainButtonDisappear() {
        var subject = state(instrumentalWork, files: [ready("1", type: "audio-wav")])
        subject.selectedKeys = [.stems]
        XCTAssertEqual(subject.effectiveSelection, [.stems])
        // 模拟"点下主钮之后"：勾选就地迁进本地在途（`submitWorkExtras` 做的事）。
        subject.locallyQueuedKeys.formUnion(subject.effectiveSelection)
        subject.selectedKeys.subtract(subject.locallyQueuedKeys)
        XCTAssertTrue(subject.showsDeliveredSection)
        XCTAssertFalse(subject.showsSelectableSection, "D 组整组消失")
        XCTAssertFalse(subject.canSubmit, "主钮随之消失（§3.G「一并」）")
        XCTAssertEqual(subject.queueRows.map(\.label), ["分轨"])
        XCTAssertEqual(subject.factLine, "这里不消耗 co")
    }

    // MARK: - §3.D2 / §9 计价面差异：作品路径搜不到任何 `co` 数字

    func testWorksPathRendersNoPriceAtAll() {
        var subject = state(workHost, files: [])
        subject.selectedKeys = Set(WorkExtraKey.allCases)
        XCTAssertTrue(subject.selectableRows.allSatisfy { $0.costText == nil && $0.credits == nil })
        XCTAssertNil(subject.totalLine(balance: 999), "作品路径没有合计行，也不显余额")
        XCTAssertEqual(subject.factLine, "这里不消耗 co")
        let rendered = subject.selectableRows.flatMap { [$0.label, $0.caption] }.joined()
        XCTAssertFalse(rendered.contains("co"))
        XCTAssertFalse(rendered.contains("预计"))
    }

    /// 会话路径：每条一行价目 + 合计行；§9 的三组算术判据逐条。
    func testSessionPathPricesEveryRowAndTotalsTheArithmetic() {
        let subject = state(sessionHost, files: [])
        XCTAssertEqual(
            subject.selectableRows.map(\.costText),
            [
                "预计消耗 20 co", "预计消耗 50 co", "预计消耗 50 co",
                "预计消耗 30 co", "预计消耗 10 co", "预计消耗 100 co",
            ]
        )
        func total(_ keys: [WorkExtraKey]) -> WorkExtrasTotalLine? {
            WorkExtrasPanelFacts.totalLine(selected: Set(keys), chargesCredits: true, balance: 128)
        }
        XCTAssertEqual(total(WorkExtraKey.allCases)?.credits, 260, "§9：全 6 项 = 260 co")
        XCTAssertEqual(total([.wav, .lyricsTiming])?.credits, 30, "§9：wav + lyrics_timing = 30 co")
        XCTAssertEqual(
            total([.accompaniment, .lyricsTiming])?.credits, 40, "§9：伴奏 + lyrics_timing = 40 co"
        )
        XCTAssertEqual(
            total([.accompaniment, .lyricsTiming])?.text, "本次合计预计消耗 40 co"
        )
        XCTAssertEqual(
            total([.accompaniment, .lyricsTiming])?.spokenLabel,
            "本次合计预计消耗 40 co，余额 128"
        )
        // 同一个勾选集落到作品宿主上 ⇒ 什么都没有（价目是**路径属性**，不是响应数值）。
        let free = state(workHost, files: [])
        XCTAssertNil(free.totalLine(balance: 128))
    }

    /// 0 不是事实而是"还没选"：零勾选 ⇒ 整行不渲染，绝不出现「预计消耗 0 co」。
    func testEmptySelectionRendersNoTotalLineRatherThanZeroCredits() {
        XCTAssertNil(
            WorkExtrasPanelFacts.totalLine(selected: [], chargesCredits: true, balance: 128),
            "§3.D2：勾选数 = 0 ⇒ 整行不渲染"
        )
        let subject = state(sessionHost, files: [])
        XCTAssertNil(subject.totalLine(balance: 0))
        XCTAssertFalse(subject.canSubmit)
        // 真正的 0 余额是**事实**（不是"取不到"）⇒ 余额位照常显，两件事不许混。
        XCTAssertEqual(
            WorkExtrasPanelFacts.totalLine(selected: [.lyricsTiming], chargesCredits: true, balance: 0)?
                .balanceText,
            "余额 0"
        )
    }

    /// 余额取不到 ⇒ 只显合计、**删掉余额位**（§3.D2 + 09 §8：不得显 0，也不显「—」）。
    func testMissingBalanceOmitsTheBalanceSlotInsteadOfPrintingZero() {
        let total = WorkExtrasPanelFacts.totalLine(
            selected: [.stems], chargesCredits: true, balance: nil
        )
        XCTAssertEqual(total?.text, "本次合计预计消耗 50 co")
        XCTAssertNil(total?.balanceText)
        XCTAssertNil(total?.balance)
        XCTAssertEqual(total?.spokenLabel, "本次合计预计消耗 50 co", "朗读里也不能冒出一段余额")
    }

    // MARK: - §7 会话腿对账：`deliveryRevision` 的 nil 不是 0

    func testMissingDeliveryRevisionIsNeverFoldedIntoZero() throws {
        XCTAssertNil(try decodeSession(#"{"ok":true,"files":[]}"#).deliveryRevision)
        XCTAssertNil(try decodeSession(#"{"ok":true,"files":[],"deliveryRevision":"3"}"#).deliveryRevision)
        XCTAssertNil(
            try decodeSession(#"{"ok":true,"files":[],"deliveryRevision":null}"#).deliveryRevision
        )
        // 对账判据：任一边 nil ⇒ 不重取（把"没有计数器"读成"第 0 版"= 静默吞掉一次真变化）。
        XCTAssertFalse(AppSession.workExtrasRevisionAdvanced(previous: nil, next: nil))
        XCTAssertFalse(AppSession.workExtrasRevisionAdvanced(previous: nil, next: 0))
        XCTAssertFalse(AppSession.workExtrasRevisionAdvanced(previous: 0, next: nil))
        XCTAssertFalse(AppSession.workExtrasRevisionAdvanced(previous: nil, next: 7))
        XCTAssertTrue(AppSession.workExtrasRevisionAdvanced(previous: 2, next: 3))
        XCTAssertFalse(AppSession.workExtrasRevisionAdvanced(previous: 3, next: 3))
        let drifted = try decodeSession(#"{"ok":true,"files":[]}"#)
        let subject = state(sessionHost, files: drifted.files, revision: drifted.deliveryRevision)
        XCTAssertNil(subject.deliveryRevision)
    }

    /// 作品腿的类型面上**没有**计数器（`WorkExtrasResponseDto` 没那个属性）⇒ 状态里恒 nil。
    func testWorksPathCarriesNoRevisionCounterAtAll() throws {
        let page = try decodeWork(#"{"ok":true,"files":[]}"#)
        let subject = state(workHost, files: page.files)
        XCTAssertNil(subject.deliveryRevision)
        XCTAssertFalse(subject.chargesCredits)
        XCTAssertFalse(workHost.chargesCredits)
        XCTAssertTrue(sessionHost.chargesCredits)
    }

    // MARK: - §4 的 409「等着就行」：行留在队列，不弹错误

    func testKeepWaitingFailureKeepsTheQueueRowAndProducesNoErrorMessage() throws {
        let rejection = ExtrasRejection.classify(
            statusCode: 409, body: data(#"{"error":"作品尚未完成，完成后才可补充制作"}"#)
        )
        XCTAssertEqual(rejection, .notCompleted(serverMessage: "作品尚未完成，完成后才可补充制作"))
        XCTAssertTrue(rejection.shouldKeepWaiting)
        let failure = ExtrasFailure.rejected(rejection)
        XCTAssertTrue(failure.shouldKeepWaiting)

        var subject = state(sessionHost, files: [])
        subject.selectedKeys = [.vocalStems]
        XCTAssertTrue(subject.applySubmitFailure(keepsWaiting: true, submittedKeys: [.vocalStems]))
        XCTAssertNil(subject.submitMessage, "错误原文那一格必须是空的（不弹错误、不显错误色）")
        XCTAssertEqual(subject.waitingNote, "这个已经在做了")
        XCTAssertEqual(subject.queueRows.map(\.label), ["人声分轨"], "行留在制作队列里")
        XCTAssertFalse(
            subject.selectableRows.contains(where: { $0.key == .vocalStems }),
            "同一 key 不许同时出现在 D 组与 F 组"
        )
        XCTAssertTrue(subject.selectedKeys.isEmpty)
        // 这一档没有错误可弹：`submitMessage` 是屏上唯一的错误色片段。
        XCTAssertNil(subject.totalLine(balance: 10))
    }

    /// 另一句 409（素材不完整）是**另一回事**：不等待 ⇒ 走行内原文（两个 409 处置不同）。
    func testSourceIncompleteRejectionIsAnErrorMessageNotAWaitingOne() throws {
        let rejection = ExtrasRejection.classify(
            statusCode: 409, body: data(#"{"error":"作品素材不完整，暂不能补充制作"}"#)
        )
        XCTAssertEqual(rejection, .sourceIncomplete(serverMessage: "作品素材不完整，暂不能补充制作"))
        XCTAssertFalse(rejection.shouldKeepWaiting)
        var subject = state(sessionHost, files: [])
        XCTAssertFalse(subject.applySubmitFailure(keepsWaiting: false, submittedKeys: [.wav]))
        XCTAssertNil(subject.waitingNote)
        XCTAssertTrue(subject.locallyQueuedKeys.isEmpty)
        XCTAssertTrue(subject.selectableRows.contains(where: { $0.key == .wav }), "勾选保留（§4 的 400 行同规则）")
    }

    // MARK: - §4 402：只在扣费的那条腿上改写成「余额不足」

    func testInsufficientCreditsIsRewrittenOnlyOnTheChargingLeg() {
        let failure = ExtrasFailure.rejected(
            .server(statusCode: 402, serverMessage: "素材还没准备好，稍后再试")
        )
        XCTAssertEqual(
            AppSession.workExtrasSubmitMessage(for: failure, host: sessionHost), "余额不足",
            "§4：required 未记录 ⇒ 走缺值那一句，不编数字"
        )
        XCTAssertEqual(
            AppSession.workExtrasSubmitMessage(for: failure, host: workHost),
            "素材还没准备好，稍后再试",
            "作品路径不扣费 ⇒ 那一条腿上的 402 与余额没有因果关系，不许替它说「余额不足」"
        )
        // 裸码形状（英文 `credits_insufficient`）不进人话：落到状态码那一句，不原样上屏。
        let bare = ExtrasFailure.rejected(
            .server(statusCode: 402, serverMessage: "credits_insufficient")
        )
        XCTAssertEqual(
            AppSession.workExtrasSubmitMessage(for: bare, host: workHost), "服务端错误（402）"
        )
    }

    // MARK: - 读失败分诊（§4 表）

    func testReadFailureClassesKeepOfflineAndUnauthenticatedApart() {
        XCTAssertEqual(AppSession.workExtrasReadFailure(for: .transport(.network)), .network)
        XCTAssertEqual(AppSession.workExtrasReadFailure(for: .transport(.unauthenticated)), .unauthenticated)
        XCTAssertEqual(AppSession.workExtrasReadFailure(for: .rejected(.unauthenticated)), .unauthenticated)
        XCTAssertEqual(AppSession.workExtrasReadFailure(for: .unreadableResponse), .unreadable)
        // 本地就没发出去的（裸 jobId）不许长成"服务端 400"的样子。
        let local = AppSession.workExtrasReadFailure(for: .localValidation(.bareJobIDRejected))
        if case .clientSide(let text) = local {
            XCTAssertTrue(text.contains("伪 id"))
        } else {
            XCTFail("本地校验失败必须落在 clientSide 那一格")
        }
    }

    /// 离线那一格：D/F/主钮整块不渲染由 `showsOfflineStrip` 说给视图；整块错误只属于"没读到东西"。
    func testOfflineStateShowsTheStripAndKeepsAnythingAlreadyRead() {
        var bare = state(workHost, files: [])
        bare.applyReadFailure(.network)
        XCTAssertTrue(bare.showsOfflineStrip)
        XCTAssertTrue(bare.showsWholePanelFailure, "首载没读到东西 ⇒ 整块那一格说话（重试 + 关闭）")

        var had = state(workHost, files: [ready("1", type: "audio-wav")])
        had.applyReadFailure(.network)
        XCTAssertEqual(had.deliveredRows.count, 1, "一次坏刷新不许把已经读到的交付物画没")
        XCTAssertFalse(had.showsWholePanelFailure)
        XCTAssertTrue(had.showsOfflineStrip)
    }

    // MARK: - §7 取件：`files[].url` 原样消费

    func testArtifactURLIsConsumedVerbatimAndNeverRebuilt() throws {
        let pending = file("extra-worker77-artifact3", type: "audio-wav", version: "补充制作准备中")
        XCTAssertNil(
            AppSession.workExtrasDownloadRequest(
                artifact: pending,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
            ),
            "没有 url 的产物构造不出一条直存请求（也没有任何自拼路径可走）"
        )
        let unnameable = file(
            "extra-worker77-artifact4", type: "brand-new-kind",
            url: "https://covalink.cn/api/studio/extras/artifacts/worker77/artifact4",
            version: "补充制作"
        )
        XCTAssertNil(
            AppSession.workExtrasDownloadRequest(
                artifact: unnameable,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
            ),
            "认不出身份 ⇒ 屏上没有那一行，也就不会往清单里塞一条没名字的产物"
        )
        let readyRow = file(
            "extra-worker77-artifact3", type: "instrumental-mp3",
            url: "https://covalink.cn/api/studio/extras/artifacts/worker77/artifact3?sig=AA%2Bb",
            version: "补充制作"
        )
        let request = try XCTUnwrap(
            AppSession.workExtrasDownloadRequest(
                artifact: readyRow,
                session: PlaybackSessionContext(owner: PrincipalID(rawValue: "principal-1"))
            )
        )
        // **原样**：同源、同一个 path、同一个 query 编码（`%2B` 没被改写成 `+`，也没被拆掉重拼）。
        XCTAssertEqual(
            request.source.value.absoluteString,
            "https://covalink.cn/api/studio/extras/artifacts/worker77/artifact3?sig=AA%2Bb"
        )
        // 产物 id 落进 store 的 `workId` 那一格（同一个 store、同一份清单；理由见实现侧注释）。
        XCTAssertEqual(request.workId, "extra-worker77-artifact3")
        XCTAssertEqual(request.title, "伴奏")
    }

    /// owner 不成立 ⇒ 不存（fail-closed，不给一个无主的落盘再去指望 store 拒掉它）。
    func testArtifactSaveNeedsAnOwnerNamespace() {
        let artifact = ready("extra-1", type: "audio-wav")
        XCTAssertNil(AppSession.workExtrasDownloadRequest(artifact: artifact, session: nil))
        XCTAssertNil(
            AppSession.workExtrasDownloadRequest(
                artifact: artifact, session: PlaybackSessionContext(owner: nil)
            )
        )
    }

    /// 名单外桶不在本屏的下载路径上；守卫仍由 store 兜，本层不裁决、更不自拼。
    func testThisLayerDoesNotAdjudicateEgressAndNeverRewritesTheHost() {
        let foreign = file(
            "extra-2", type: "video",
            url: "https://covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com/x.mp4",
            version: "补充制作"
        )
        let request = AppSession.workExtrasDownloadRequest(
            artifact: foreign, session: PlaybackSessionContext(owner: PrincipalID(rawValue: "p-1"))
        )
        XCTAssertEqual(
            request?.source.value.host,
            "covalink-uploads-1301797874.cos.ap-shanghai.myqcloud.com",
            "地址一个字都不改：主机裁决是 `WorkDownloadStore` 那道守卫的事"
        )
    }

    // MARK: - §4 最后两行的取件话术

    func testSaveFailureTextsUseOnlyTheTwoScreenSpecSentences() {
        XCTAssertEqual(
            AppSession.workExtrasSaveFailureText(.writeFailed(ENOSPC)), "空间不够了，清一清再试"
        )
        XCTAssertEqual(AppSession.workExtrasSaveFailureText(.emptyDownload), "这个文件没取到，重试")
        XCTAssertEqual(AppSession.workExtrasSaveFailureText(.badStatus(502)), "这个文件没取到，重试")
        XCTAssertEqual(
            AppSession.workExtrasSaveFailureText(.hostRejected(host: "elsewhere.invalid")),
            "这个文件没取到，重试"
        )
    }

    // MARK: - 勾选与提交的账（§3.E / §3.G）

    /// 勾选只认"还在 D 组"的行：key 被服务端答成已完成之后，它残留的勾选必须掉出去。
    func testSelectionDropsKeysThatLeftTheSelectableGroup() {
        var subject = state(sessionHost, files: [])
        subject.selectedKeys = [.wav, .accompaniment]
        XCTAssertEqual(subject.effectiveSelection, [.wav, .accompaniment])
        subject.applySnapshot([ready("1", type: "audio-wav")], revision: 8)
        XCTAssertEqual(subject.selectedKeys, [.accompaniment], "已完成的 wav 从勾选里掉出去")
        XCTAssertEqual(subject.effectiveSelection, [.accompaniment])
        XCTAssertEqual(subject.totalLine(balance: nil)?.credits, 30)
    }

    /// 纯音乐作品下，一份"带四项"的旧勾选快照也不能把被屏蔽的 key 带回 D 组。
    func testInstrumentalFilterAlsoPrunesSelectionAndTotalOnRead() {
        var subject = state(instrumentalWork, files: [])
        subject.selectedKeys = [.wav, .vocalStems, .lyricsVideo]
        subject.applySnapshot([], revision: nil)
        XCTAssertEqual(subject.selectedKeys, [.wav], "不合法的 key 不参与合计、也不被提交")
        XCTAssertEqual(subject.effectiveSelection, [.wav])
    }

    /// 在途那一格不给二次提交留缝：`submissionInFlight` ⇒ `canSubmit` 为 false。
    func testBusySubmissionMakesTheMainButtonIneligible() {
        var subject = state(sessionHost, files: [])
        subject.selectedKeys = [.wav]
        XCTAssertTrue(subject.canSubmit)
        subject.submissionInFlight = true
        XCTAssertFalse(subject.canSubmit, "一次点击 = 一个提交代号：在途时第二次点击到不了这里")
        subject.submissionInFlight = false
        XCTAssertTrue(subject.canSubmit)
    }

    /// 零勾选不可点，且屏上没有一句解释（§3.G：空选择不需要教训用户）。
    func testEmptySelectionIsDisabledWithoutAnyExplanatoryCopy() {
        let subject = state(sessionHost, files: [])
        XCTAssertFalse(subject.canSubmit)
        XCTAssertNil(subject.submitMessage, "主钮下方那一行解释性的错误原文必须是空的")
        XCTAssertNil(subject.waitingNote)
        XCTAssertNil(subject.totalLine(balance: 128), "零勾选也没有合计行")
        XCTAssertNil(subject.factLine, "会话路径不出现「这里不消耗 co」那一句")
    }

    // MARK: - §6 朗读顺序（价目片段只在该在的那条腿上出现）

    func testSpokenLabelsCarryThePriceFragmentOnlyOnTheChargingLeg() throws {
        let works = try XCTUnwrap(
            WorkExtrasPanelFacts.selectableRows(
                instrumental: nil, files: [], localClaims: [], selected: [.stems],
                chargesCredits: false
            ).first(where: { $0.key == .stems })
        )
        let charging = try XCTUnwrap(
            WorkExtrasPanelFacts.selectableRows(
                instrumental: nil, files: [], localClaims: [], selected: [.stems],
                chargesCredits: true
            ).first(where: { $0.key == .stems })
        )
        XCTAssertEqual(
            WorkExtrasPanelFacts.selectableSpokenLabel(works), "分轨，分开的轨道包，复选框，已勾选"
        )
        XCTAssertEqual(
            WorkExtrasPanelFacts.selectableSpokenLabel(charging),
            "分轨，分开的轨道包，预计消耗 50 co，复选框，已勾选"
        )
        // 未勾选那一停也要说得出（§6：勾选态由语义值表达，不靠颜色）。
        var unselected = state(sessionHost, files: [])
        unselected.selectedKeys = []
        let row = try XCTUnwrap(unselected.selectableRows.first)
        XCTAssertTrue(
            WorkExtrasPanelFacts.selectableSpokenLabel(row).hasSuffix("复选框，未勾选")
        )
    }

    func testDeliveredSpokenLabelMatchesTheTwoActionStates() {
        let save = WorkExtraDeliveredRow(
            artifactID: "extra-1", label: "母带 WAV", symbol: "waveform", isSaved: false,
            orderKey: .wav
        )
        let stored = WorkExtraDeliveredRow(
            artifactID: "extra-1", label: "母带 WAV", symbol: "waveform", isSaved: true,
            orderKey: .wav
        )
        XCTAssertEqual(WorkExtrasPanelFacts.deliveredSpokenLabel(save), "母带 WAV，保存到本机 按钮")
        XCTAssertEqual(
            WorkExtrasPanelFacts.deliveredSpokenLabel(stored),
            "母带 WAV，已在本机，删除本机文件 按钮"
        )
    }

    // MARK: - §8 词表（A15 + D12 的可见面）

    /// 「积分」「歌曲任务」「价目」「下载」这类漂移词不许出现在任何上屏或朗读片段里
    /// （D12 那批购买/充值类禁词由 `Scripts/d12-copy-check.sh` 扫全仓字面量，这一条盯的是
    /// 那个扫描器看不见的词）。
    func testScreenVocabularyStaysInsideTheTerminologyTable() {
        let strings: [String] = [
            WorkExtrasCopy.title, WorkExtrasCopy.sessionTitle,
            WorkExtrasCopy.deliveredHeader, WorkExtrasCopy.selectableHeader,
            WorkExtrasCopy.queueHeader, WorkExtrasCopy.start, WorkExtrasCopy.noCostHere,
            WorkExtrasCopy.preparing, WorkExtrasCopy.save, WorkExtrasCopy.saved,
            WorkExtrasCopy.deleteLocal, WorkExtrasCopy.readFailed, WorkExtrasCopy.close,
            WorkExtrasCopy.alreadyInFlight, WorkExtrasCopy.fileNotFetched,
            WorkExtrasCopy.noSpace, WorkExtrasCopy.offline, WorkExtrasCopy.insufficientBalance,
            WorkExtrasCopy.insufficientBalance(required: 60),
            WorkExtrasCopy.keyWav, WorkExtrasCopy.keyStems, WorkExtrasCopy.keyVocalStems,
            WorkExtrasCopy.keyAccompaniment, WorkExtrasCopy.keyLyricsTiming,
            WorkExtrasCopy.keyLyricsVideo,
            WorkExtrasCopy.captionWav, WorkExtrasCopy.captionStems,
            WorkExtrasCopy.captionVocalStems, WorkExtrasCopy.captionAccompaniment,
            WorkExtrasCopy.captionLyricsTiming, WorkExtrasCopy.captionLyricsVideo,
            WorkExtrasCopy.expectedCost(20), WorkExtrasCopy.totalExpectedCost(40),
            WorkExtrasCopy.balance(128),
        ]
        for banned in ["积分", "歌曲任务", "价目", "下载", "购买", "充值", "解锁", "免费"] {
            for text in strings {
                XCTAssertFalse(
                    text.contains(banned), "上屏/朗读串里出现漂移词「\(banned)」：\(text)"
                )
            }
        }
        XCTAssertEqual(WorkExtrasCopy.title, "补充制作")
        XCTAssertEqual(WorkExtrasCopy.sessionTitle, "补充制作 · 这次会话")
    }

    /// 两条标题都不带计费字样（§3.B）；两宿主的成功 Toast 各一句且不含数字（§4 成功行）。
    func testHostTitlesAndSuccessToastsCarryNoNumbersOrBillingWords() {
        XCTAssertEqual(workHost.title, "补充制作")
        XCTAssertEqual(sessionHost.title, "补充制作 · 这次会话")
        XCTAssertEqual(workHost.startedToast, "已开始制作")
        XCTAssertEqual(sessionHost.startedToast, "已开始补充制作")
        for text in [workHost.title, sessionHost.title, workHost.startedToast, sessionHost.startedToast] {
            XCTAssertFalse(text.contains(where: \.isNumber), "Toast 里不报数字（§4 成功行）")
            XCTAssertFalse(text.contains("co"))
        }
    }
}
