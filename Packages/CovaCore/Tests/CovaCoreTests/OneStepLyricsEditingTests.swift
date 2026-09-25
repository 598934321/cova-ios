@testable import CovaCore
import Foundation
import XCTest

/// 09「歌词编辑」的纯逻辑层（`OneStepLyricsEditing.swift` + `OneStepLyricsEditDTOs.swift`）。
///
/// 这一屏 SwiftUI 的版式测不到，本文件也不假装测它：钉的是**能不能编辑、拼出去的是什么、
/// 哪些值可以上屏**这三件真能判对/判错的事。
///
/// 形状判据的出处全在已部署实现里（`多端/web`，本后端的唯一事实源），逐条写在被钉的那一侧。
/// 载荷一律**从 JSON 解出来**（不是用成员构造器造）：投影里哪个键给、哪个键不给，
/// 只有走解码这条路与真机一致。
final class OneStepLyricsEditingTests: XCTestCase {

    // MARK: - 夹具

    private func decoded(_ json: String) -> OneStepPlanCardDto {
        try! JSONDecoder().decode(OneStepPlanCardDto.self, from: Data(json.utf8))
    }

    /// 两段的正常歌词：第一段方括号 + 尾随空行，第二段**全角括号**（后端两种都认）。
    private var twoSections: String {
        """
        {"sectionId": "a", "type": "verse", "label": "主歌一", "text": "[主歌一]\\n第一段第一行\\n第二行\\n\\n", "order": 0},\
        {"sectionId": "b", "type": "chorus", "label": "副歌", "text": "【副歌】\\n合唱词\\n", "order": 1}
        """
    }

    private func lyricsJSON(sections: String? = nil, revision: String = "3") -> String {
        """
        {"source": "generated", "sourceText": "原始一句话", "sourceHash": "h1", \
        "displayText": "整篇", "generationText": "整篇", "revision": \(revision)\
        \(sections.map { ", \"sections\": [\($0)]" } ?? "")}
        """
    }

    private func cardJSON(
        sessionId: String = "\"s-1\"",
        revision: String = "7",
        title: String = """
        {"selected": "夜航", "candidates": ["夜航", "灯塔"], "page": 0, "pageSize": 10, "total": 50}
        """,
        lyrics: String
    ) -> String {
        """
        {"planCardId": "pc-1", "status": "ready", "sessionId": \(sessionId), "revision": \(revision), \
        "snapshotHash": "sha256:abc", "type": "vocal", "title": \(title), "credits": 12\
        \(lyrics.isEmpty ? "" : ", \"lyrics\": \(lyrics)")}
        """
    }

    private var healthyPlan: OneStepPlanCardDto {
        decoded(cardJSON(lyrics: lyricsJSON(sections: twoSections)))
    }

    // MARK: - 能不能编辑（不编造边界）

    func testHealthyCardIsEditable() throws {
        XCTAssertNil(OneStepLyricsEditor.block(for: healthyPlan, sessionID: "s-1"))
        let editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        XCTAssertEqual(editor.cardRevision, 7)
        XCTAssertEqual(editor.lyricsRevision, 3)
        XCTAssertEqual(editor.drafts.map(\.label), ["主歌一", "副歌"])
        XCTAssertEqual(editor.drafts.map(\.baseBody), ["第一段第一行\n第二行", "合唱词"])
        XCTAssertEqual(editor.documentSource, "generated")
        XCTAssertEqual(editor.titleCandidates, ["夜航", "灯塔"])
    }

    /// 每一种"不该给编辑入口"的形态各自命中自己那一档 —— 少一档就是有个入口在撒谎。
    func testEveryUnavailableShapeHasItsOwnBlock() throws {
        let cases: [(String, OneStepPlanCardDto, OneStepLyricsEditingBlock)] = [
            ("整张卡没有歌词键", decoded(cardJSON(lyrics: "")), .noLyrics),
            (
                "有文档但没分段",
                decoded(cardJSON(lyrics: lyricsJSON(sections: nil))),
                .sectionsMissing
            ),
            (
                "分段是空数组",
                decoded(cardJSON(lyrics: lyricsJSON(sections: ""))),
                .sectionsMissing
            ),
            (
                "某段没有 text 键",
                decoded(cardJSON(lyrics: lyricsJSON(sections: """
                    {"sectionId": "a", "type": "verse", "label": "主歌一", "text": "[主歌一]\\n词", "order": 0},\
                    {"sectionId": "b", "type": "chorus", "label": "副歌", "order": 1}
                    """))),
                .sectionTextMissing
            ),
            (
                "某段的 text 是 null",
                decoded(cardJSON(lyrics: lyricsJSON(sections: """
                    {"sectionId": "a", "type": "verse", "label": "主歌一", "text": null, "order": 0}
                    """))),
                .sectionTextMissing
            ),
            ("卡没有 revision", decoded(cardJSON(revision: "null", lyrics: lyricsJSON(sections: twoSections))), .cardRevisionUnknown),
            ("卡不属于这个会话", decoded(cardJSON(sessionId: "\"other\"", lyrics: lyricsJSON(sections: twoSections))), .cardSessionMismatch),
            ("标题池是空数组", decoded(cardJSON(title: """
                {"selected": "夜航", "candidates": [], "page": 0}
                """, lyrics: lyricsJSON(sections: twoSections))), .titlePoolIncomplete),
            ("标题池没有这个键", decoded(cardJSON(title: """
                {"selected": "夜航", "page": 0}
                """, lyrics: lyricsJSON(sections: twoSections))), .titlePoolIncomplete),
            ("标题页码越出后端允许的 0…4", decoded(cardJSON(title: """
                {"selected": "夜航", "candidates": ["夜航"], "page": 9}
                """, lyrics: lyricsJSON(sections: twoSections))), .titlePoolIncomplete)
        ]
        for (name, plan, expected) in cases {
            XCTAssertEqual(OneStepLyricsEditor.block(for: plan, sessionID: "s-1"), expected, name)
            XCTAssertNil(OneStepLyricsEditor(plan: plan, sessionID: "s-1"), "\(name)：拦下的形态建不出编辑器")
        }
    }

    /// 上屏话术：除"没有歌词"那一档必须**闭嘴**（09 §8 明令不显「无歌词」），
    /// 其余每一档都要有中文，且不许把英文漏出去。
    func testEveryBlockSaysSomethingChineseExceptTheSilentOne() throws {
        let all: [OneStepLyricsEditingBlock] = [
            .noLyrics, .sectionsMissing, .sectionTextMissing, .cardRevisionUnknown,
            .cardSessionMismatch, .titlePoolIncomplete
        ]
        var seen = Set<String>()
        for block in all {
            if block == .noLyrics {
                XCTAssertNil(block.userCopy, "纯音乐由参数行的「纯音乐」chip 说，这里不许再显一行")
                continue
            }
            guard let copy = block.userCopy else { return XCTFail("档位 \(block) 没有话术") }
            XCTAssertFalse(copy.isEmpty, "\(block)")
            XCTAssertFalse(copy.containsASCIILetter, "话术里不许有英文：\(copy)")
            XCTAssertTrue(seen.insert(copy).inserted, "两档共用一句话：\(copy)")
        }
    }

    // MARK: - 段落顺序与拆行

    /// 只读平铺印的正文**不含段标行**（段名另有标题行；旧版把整条 `text` 直接印出来，
    /// 于是"主歌一"这种段名在同一段里出现两回）。
    func testReadOnlyBodyDropsTheHeaderLine() throws {
        let plan = healthyPlan
        let sections = OneStepLyricsEditor.orderedSections(of: plan)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(OneStepLyricsEditor.bodyText(of: sections[0]), "第一段第一行\n第二行")
        XCTAssertEqual(OneStepLyricsEditor.bodyText(of: sections[1]), "合唱词")
        // 没段标的段 ⇒ 整条都是正文，不剥、也不误吞第一行
        XCTAssertEqual(OneStepLyricsEditor.bodyText(of: sections[0].replacingText("纯正文一行")), "纯正文一行")
    }

    /// `order` 升序；**缺 order / 重号时按后端数组序**，不许被 Swift 的排序打乱。
    func testSectionOrderIsDeterministicAndNeverShuffled() throws {
        let missingOrder = decoded(cardJSON(lyrics: lyricsJSON(sections: """
            {"type": "verse", "label": "A", "text": "[A]\\n一\\n\\n"},\
            {"type": "chorus", "label": "B", "text": "[B]\\n二\\n\\n"},\
            {"type": "bridge", "label": "C", "text": "[C]\\n三\\n"}
            """)))
        let editor = try XCTUnwrap(OneStepLyricsEditor(plan: missingOrder, sessionID: "s-1"))
        XCTAssertEqual(editor.drafts.map(\.label), ["A", "B", "C"], "缺 order 就按数组序，不重排")

        // 显式 order 逆序给出 ⇒ 必须按 order 排，而不是按数组序。
        let explicit = decoded(cardJSON(lyrics: lyricsJSON(sections: """
            {"type": "bridge", "label": "C", "text": "[C]\\n三\\n", "order": 2},\
            {"type": "verse", "label": "A", "text": "[A]\\n一\\n\\n", "order": 0},\
            {"type": "chorus", "label": "B", "text": "[B]\\n二\\n", "order": 1}
            """)))
        XCTAssertEqual(try XCTUnwrap(OneStepLyricsEditor(plan: explicit, sessionID: "s-1")).drafts.map(\.label), ["A", "B", "C"])
    }

    /// 段标识别与后端同源：行首方括号才算段标；正文里的行内 `[男]` 不是。
    func testHeaderSplitRecognizesLineLeadingBracketsOnly() throws {
        let square = OneStepLyricsEditor.split(header: "[Verse 1]\n正文")
        XCTAssertEqual(square.label, "Verse 1")
        XCTAssertEqual(square.bracket, .square)
        XCTAssertEqual(square.body, "正文")

        let wide = OneStepLyricsEditor.split(header: "【副歌】\n正文")
        XCTAssertEqual(wide.label, "副歌")
        XCTAssertEqual(wide.bracket, .lenticular)

        XCTAssertEqual(OneStepLyricsEditor.split(header: "  [Chorus]\n词").label, "Chorus", "行首缩进仍算段标")

        let inline = OneStepLyricsEditor.split(header: "第一行 [男] 唱完")
        XCTAssertNil(inline.label)
        XCTAssertNil(inline.bracket)
        XCTAssertEqual(inline.body, "第一行 [男] 唱完")

        XCTAssertNil(OneStepLyricsEditor.split(header: "[Chorus] 紧接一句").label, "段标后没换行 ⇒ 是正文不是段标")
        XCTAssertNil(OneStepLyricsEditor.split(header: "[]\n词").label, "空括号不是段标")
        XCTAssertNil(OneStepLyricsEditor.split(header: "没有括号").label)

        let headerOnly = OneStepLyricsEditor.split(header: "[Chorus]")
        XCTAssertEqual(headerOnly.label, "Chorus")
        XCTAssertEqual(headerOnly.body, "")
        XCTAssertEqual(OneStepLyricsEditor.split(header: "[Chorus]\r\n词").body, "词", "CRLF 只吃掉一个换行")
    }

    // MARK: - 脏跟踪与回拼

    /// **一行都没改** ⇒ 回拼出的整篇与后端给的每个 `text` 逐字节相同。
    /// 这一条是"我的读法不许变成用户没做过的写"。
    func testUntouchedDocumentRoundTripsByteForByte() throws {
        let plan = healthyPlan
        let editor = try XCTUnwrap(OneStepLyricsEditor(plan: plan, sessionID: "s-1"))
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.dirtyCount, 0)
        XCTAssertEqual(editor.statusCopy, "未改动")
        XCTAssertEqual(
            editor.joinedLyrics(),
            plan.lyrics?.sections?.compactMap(\.text).joined() ?? "",
            "未编辑时拼接结果必须等于原文，一个空白都不许多"
        )
    }

    /// 改一段 ⇒ 段标保留、尾空白收掉、非末段以空行分隔、**另一段一字不动**。
    func testEditingOneSectionKeepsTheOthersVerbatim() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        XCTAssertEqual(editor.drafts.count, 2)
        editor.editBody("换掉的词", at: 0)
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.dirtyCount, 1)
        XCTAssertEqual(editor.statusCopy, "已改动 1 段")
        XCTAssertEqual(
            editor.joinedLyrics(),
            "[主歌一]\n换掉的词\n\n【副歌】\n合唱词\n",
            "改过的那段留段标行并以空行分隔；没改的那段维持原样（含结尾单换行）"
        )
        editor.editBody(editor.drafts[0].baseBody, at: 0)
        XCTAssertFalse(editor.isDirty, "改回原文就不算改动")
    }

    /// 末段不留尾分隔；本来没有段标的段**不替它现编一个**。
    func testHeaderlessSectionIsNotGivenAnInventedLabel() throws {
        let plan = decoded(cardJSON(lyrics: lyricsJSON(sections: """
            {"type": "other", "label": "歌词", "text": "没有段标的一行\\n\\n"},\
            {"type": "chorus", "label": "副歌", "text": "[副歌]\\n合唱\\n", "order": 1}
            """)))
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: plan, sessionID: "s-1"))
        editor.editBody("改了的一句", at: 0)
        XCTAssertEqual(editor.joinedLyrics(), "改了的一句\n\n[副歌]\n合唱\n")
    }

    /// 越界的段落序号什么都不做（不 crash、也不"顺手改到别的段"）。
    func testEditOutsideRangeIsANoOp() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        editor.editBody("越界", at: 5)
        editor.editBody("越界", at: -1)
        XCTAssertFalse(editor.isDirty)
    }

    func testResetRestoresEveryDraft() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        editor.editBody("乱码", at: 0)
        editor.editBody("更多乱码", at: 1)
        editor.reset()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.joinedLyrics(), healthyPlan.lyrics?.sections?.compactMap(\.text).joined())
    }

    // MARK: - 保存前自核

    func testSaveBlockCoversNoChangeAndEmptySection() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        XCTAssertEqual(editor.saveBlock(), "没有改动需要保存。")

        // 「第 N 段」按文档序数，不是"第几个改过的段"：这里改的是第 2 段。
        editor.editBody("   ", at: 1)
        XCTAssertEqual(
            editor.saveBlock(),
            "第 2 段是空的：要删掉整段请改用「修改要求」，就地保存不接受空段。"
        )
        editor.editBody("正常的一句", at: 1)
        XCTAssertNil(editor.saveBlock())

        editor.editBody("", at: 0)
        XCTAssertTrue(editor.saveBlock()!.contains("第 1 段"), "两段都空 ⇒ 先命中的是文档里靠前的那段")
    }

    /// 话术也不许漏英文。
    func testSaveBlockCopyIsChinese() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        editor.editBody("", at: 0)
        let copy = try XCTUnwrap(editor.saveBlock())
        XCTAssertFalse(copy.containsASCIILetter, copy)
    }

    // MARK: - 载荷形状（后端校验器逐字读的那几个键）

    /// `assertValidOneStepPlanPatch`（`web/src/lib/one-step/contracts.ts:781`）的硬判据：
    /// targetFields 非空不重、`changes` 的键集**等于** targetFields（:806）、幂等键非空；
    /// 外加 `patch.ts:139`：改歌词必须同时换标题池。
    func testPayloadSatisfiesTheServersPatchValidator() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        editor.editBody("新写的词", at: 1)
        let key = try OneStepLyricsEditToken().key
        let request = editor.patchRequest(key: key)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), Set([
            "sessionId", "planCardId", "expectedRevision", "idempotencyKey",
            "targetFields", "source", "operation", "changes", "targetVersions"
        ]), "一个键都不许多发明")
        XCTAssertEqual(root["sessionId"] as? String, "s-1")
        XCTAssertEqual(root["planCardId"] as? String, "pc-1")
        XCTAssertEqual(root["expectedRevision"] as? Int, 7)
        XCTAssertEqual(root["source"] as? String, "user")
        XCTAssertEqual(root["operation"] as? String, "targeted_patch")
        XCTAssertEqual(root["idempotencyKey"] as? String, key.rawValue)
        XCTAssertEqual(root["targetFields"] as? [String], ["lyrics", "titlePool"])

        let changes = try XCTUnwrap(root["changes"] as? [String: Any])
        XCTAssertEqual(Set(changes.keys), Set(["lyrics", "titlePool"]), "键集必须等于 targetFields")
        let pool = try XCTUnwrap(changes["titlePool"] as? [String: Any])
        XCTAssertEqual(pool["candidates"] as? [String], ["夜航", "灯塔"], "候选原样回带，不新增不重排")
        XCTAssertEqual(pool["page"] as? Int, 0)
        XCTAssertEqual(pool["pageSize"] as? Int, 10)

        let lyrics = try XCTUnwrap(changes["lyrics"] as? [String: Any])
        XCTAssertEqual(lyrics["operation"] as? String, "manual_edit")
        XCTAssertEqual(lyrics["source"] as? String, "generated", "文档来源原样回带")
        XCTAssertEqual(lyrics["sourceText"] as? String, "原始一句话")
        XCTAssertEqual(lyrics["revision"] as? Int, 3)
        let joined = editor.joinedLyrics()
        XCTAssertEqual(lyrics["displayText"] as? String, joined)
        XCTAssertEqual(lyrics["generationText"] as? String, joined, "两者同源（web InteractivePlanCard.tsx:483）")
        let sent = try XCTUnwrap(lyrics["sections"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["text"] as? String, "[主歌一]\n第一段第一行\n第二行\n\n", "未改的段逐字回带")
        XCTAssertEqual(sent[1]["text"] as? String, "【副歌】\n新写的词", "改过的段：换正文、括号形态沿用原文")
        XCTAssertEqual(sent[1]["type"] as? String, "chorus", "type 原样回带：本屏不读它，也不改写它")
        XCTAssertEqual(sent[1]["sectionId"] as? String, "b", "段号回带的是读到那个（后端会按新内容重算）")
        XCTAssertEqual(root["targetVersions"] as? [String: Int], ["lyrics": 3])
    }

    /// 读不到歌词版本时**不发** `targetVersions`，界面上也不印版本号 —— 两头都不猜。
    func testMissingLyricsRevisionOmitsTargetVersionsAndVersionLabel() throws {
        let plan = decoded(cardJSON(lyrics: lyricsJSON(sections: twoSections, revision: "null")))
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: plan, sessionID: "s-1"))
        editor.editBody("改一点", at: 0)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.patchRequest(key: try OneStepLyricsEditToken().key)))
            as? [String: Any]
        )
        XCTAssertNil(root["targetVersions"], "没有基线就不发这个键，让服务端按聚合版本落")
        let document = try XCTUnwrap((root["changes"] as? [String: Any])?["lyrics"] as? [String: Any])
        XCTAssertNil(document["revision"])
        XCTAssertNil(OneStepLyricsEditingCopy.versionLabel(editor.lyricsRevision))
        XCTAssertTrue(editor.payloadFingerprint.contains("none"), "指纹也要能区分这一格")
    }

    /// 没改动时 `joinedLyrics` 就是原文 ⇒ 载荷也必须是原文（后端会原样重放，不产生新内容）。
    func testPayloadWithoutAnyEditEchoesTheDocument() throws {
        let editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.patchRequest(key: try OneStepLyricsEditToken().key)))
            as? [String: Any]
        )
        let lyrics = try XCTUnwrap((root["changes"] as? [String: Any])?["lyrics"] as? [String: Any])
        XCTAssertEqual(
            lyrics["displayText"] as? String,
            healthyPlan.lyrics?.sections?.compactMap(\.text).joined()
        )
    }

    // MARK: - 幂等键（AGENTS 硬边界 5）

    /// 同一次改动**原样重发** ⇒ 同一把键（后端同键同载荷走重放，不会有第二次写）；
    /// 用户又改了一个字 / 基线 revision 变了 ⇒ 那是一次新的写 ⇒ 新键。
    func testTokenLedgerReusesOnlyForTheIdenticalWrite() throws {
        var editor = try XCTUnwrap(OneStepLyricsEditor(plan: healthyPlan, sessionID: "s-1"))
        editor.editBody("第一段改", at: 0)
        var ledger = OneStepLyricsEditTokenLedger()
        let first = try ledger.token(planCardID: "pc-1", fingerprint: editor.payloadFingerprint)
        let again = try ledger.token(planCardID: "pc-1", fingerprint: editor.payloadFingerprint)
        XCTAssertEqual(first.key, again.key, "同键同载荷才谈得上重放")
        XCTAssertEqual(ledger.count, 1)

        editor.editBody("又改了一点", at: 1)
        let newer = try ledger.token(planCardID: "pc-1", fingerprint: editor.payloadFingerprint)
        XCTAssertNotEqual(newer.key, first.key, "内容变了就是一次新的写，不许复用旧键")
        XCTAssertEqual(ledger.count, 2)

        // 指纹里带着基线 revision：同一篇文字、不同基线也是两次不同的写
        let otherBaseline = "9|\(editor.lyricsRevision.map(String.init) ?? "none")|\(editor.joinedLyrics())"
        XCTAssertNotEqual(try ledger.token(planCardID: "pc-1", fingerprint: otherBaseline).key, newer.key)
        // 不同卡不共享键
        XCTAssertNotEqual(try ledger.token(planCardID: "pc-2", fingerprint: editor.payloadFingerprint).key, newer.key)
    }

    func testTokenShapeStaysInsideTheServerCharset() throws {
        let token = try OneStepLyricsEditToken()
        XCTAssertTrue(token.key.rawValue.hasPrefix(OneStepLyricsEditToken.keyPrefix))
        XCTAssertEqual(
            token.key.rawValue.count,
            OneStepLyricsEditToken.keyPrefix.count + IdempotencyKeyGenerator.hexLength
        )
        XCTAssertNoThrow(try IdempotencyKey.validate(token.key.rawValue))
        XCTAssertNotEqual(try OneStepLyricsEditToken().key, token.key, "两次生成不能撞同一把键")
        // 别的操作前缀不许冒充这把键
        let foreign = IdempotencyKeyGenerator.generate(for: .planStart)
        XCTAssertThrowsError(try OneStepLyricsEditToken(key: foreign)) { error in
            XCTAssertEqual(error as? IdempotencyKeyError, .operationMismatch)
        }
    }

    // MARK: - 上屏词（本仓那一族"英文态名上屏"的新增面）

    /// 每个档位都有中文、互不重复，且**没有一个 ASCII 字母**（rawValue 上不了屏）。
    func testEveryPanelPhaseHasItsOwnChineseLabel() throws {
        let phases = OneStepLyricsPanelPhase.allCases
        XCTAssertEqual(phases.count, 8)
        var seen = Set<String>()
        for phase in phases {
            let label = phase.userLabel
            XCTAssertFalse(label.isEmpty, "\(phase.rawValue) 没有中文读数")
            XCTAssertFalse(label.containsASCIILetter, "\(phase.rawValue) 的读数漏了英文：\(label)")
            XCTAssertFalse(label.contains(phase.rawValue))
            XCTAssertTrue(seen.insert(label).inserted, "两档共用一句读数：\(label)")
        }
    }

    func testVersionAndSectionTitleCopies() throws {
        XCTAssertEqual(OneStepLyricsEditingCopy.versionLabel(3), "第 3 版")
        XCTAssertNil(OneStepLyricsEditingCopy.versionLabel(nil), "读不到版本就不印，不编一个「第 1 版」")
        XCTAssertNil(OneStepLyricsEditingCopy.versionLabel(0), "0 不是版本号")
        XCTAssertNil(OneStepLyricsEditingCopy.versionLabel(-2))
        XCTAssertEqual(OneStepLyricsEditingCopy.sectionTitle(label: " 副歌 ", order: 1), "副歌")
        XCTAssertEqual(OneStepLyricsEditingCopy.sectionTitle(label: "", order: 0), "段落 1")
        XCTAssertEqual(OneStepLyricsEditingCopy.sectionTitle(label: nil, order: 4), "段落 5")
    }

    /// 「共 M 版」只在版本列表真能对上当前版时才报；对不上就退回报当前版。
    func testVersionSummaryOnlyCountsWhatItCanSee() throws {
        func versions(_ numbers: [Int?]) -> [OneStepFieldVersionDto] {
            numbers.map { OneStepFieldVersionDto(field: "lyrics", version: $0, createdAt: nil) }
        }
        XCTAssertEqual(
            OneStepLyricsEditingCopy.versionSummary(versions([1, 2, 3]), current: 3), "第 3 版 · 共 3 版"
        )
        XCTAssertEqual(
            OneStepLyricsEditingCopy.versionSummary(versions([3, 1, 2]), current: 2), "第 2 版 · 共 3 版",
            "后端承诺升序，但读数不依赖它：乱序也数得对"
        )
        // 当前版不在列表里 ⇒ 账对不上，不吹"共几版"
        XCTAssertEqual(OneStepLyricsEditingCopy.versionSummary(versions([1, 2]), current: 5), "第 5 版")
        // 只有一版 ⇒ 没什么"共"可报
        XCTAssertEqual(OneStepLyricsEditingCopy.versionSummary(versions([2]), current: 2), "第 2 版")
        XCTAssertEqual(OneStepLyricsEditingCopy.versionSummary([], current: 2), "第 2 版")
        XCTAssertEqual(
            OneStepLyricsEditingCopy.versionSummary(versions([2, nil, 2]), current: 2), "第 2 版",
            "重号与没编号的条目都不参与总数"
        )
        XCTAssertNil(OneStepLyricsEditingCopy.versionSummary(versions([1, 2, 3]), current: nil))
    }

    /// 服务端业务码 → 事实。**英文码一个都不上屏**，两句话也不许混。
    func testRejectionClassificationPinsEveryServerCode() throws {
        let cases: [(CovaAPIError, OneStepLyricsEditRejection)] = [
            (.httpStatus(code: 409, apiCode: "conflict"), .staleCard),
            (.httpStatus(code: 409, apiCode: "idempotency_conflict"), .idempotencyConflict),
            (.httpStatus(code: 402, apiCode: "topup_required"), .insufficientBalance),
            (.httpStatus(code: 404, apiCode: "not_found"), .cardGone),
            (.httpStatus(code: 403, apiCode: "forbidden"), .cardGone),
            (.httpStatus(code: 400, apiCode: "invalid_lyrics"), .rejected(status: 400)),
            (.httpStatus(code: 500, apiCode: nil), .rejected(status: 500)),
            (.unauthorized(apiCode: nil), .cardGone)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(OneStepLyricsEditRejection.classify(error), expected, "\(error)")
        }
        // 不是这一族的错误 ⇒ 不冒充分诊结果，交给上层按网络故障说
        XCTAssertNil(OneStepLyricsEditRejection.classify(URLError(.timedOut)))
        XCTAssertNil(OneStepLyricsEditRejection.classify(CovaAPIError.offline))

        var seen = Set<String>()
        for rejection in [
            OneStepLyricsEditRejection.staleCard, .idempotencyConflict, .insufficientBalance, .cardGone,
            .rejected(status: 400)
        ] {
            XCTAssertFalse(rejection.userCopy.isEmpty)
            XCTAssertFalse(rejection.userCopy.containsASCIILetter, rejection.userCopy)
            XCTAssertTrue(seen.insert(rejection.userCopy).inserted)
        }
        // 「这次没有扣费」只许出现在"预检就把请求拦下"那一档（D12：只陈述事实，不给出充值的路）
        XCTAssertTrue(OneStepLyricsEditRejection.insufficientBalance.userCopy.hasPrefix("这次没有扣费"))
        XCTAssertFalse(OneStepLyricsEditRejection.staleCard.userCopy.contains("扣费"))
    }

    // MARK: - 响应承接（写成功与"读不回显"是两件事）

    func testPatchResponseEchoDecodesBothShapes() throws {
        let withCard = try XCTUnwrap(
            JSONDecoder().decode(
                OneStepLyricsPatchResponseDto.self,
                from: Data(#"{"planCard": {"planCardId": "pc-1", "status": "ready", "revision": 8}, "replayed": true}"#.utf8)
            )
        )
        XCTAssertEqual(withCard.planCard?.revision, 8)
        XCTAssertEqual(withCard.replayed, true)

        let echoOnly = try XCTUnwrap(
            JSONDecoder().decode(
                OneStepLyricsPatchResponseDto.self,
                from: Data(#"{"replayed": false}"#.utf8)
            )
        )
        XCTAssertNil(echoOnly.planCard, "缺回显不是解码失败：写已经落地，卡面下次读才算数")
    }

    /// 重做的扣费话术：**"没读到扣多少" ≠ "没扣"**，三种事实各说各的。
    func testRegenerateChargeCopyNeverConfusesUnreadWithZero() throws {
        let unread = OneStepLyricsRegenerateOutcome(card: nil, charged: nil, balance: nil, insufficient: nil)
        XCTAssertTrue(unread.chargeCopy.contains("没读到"), unread.chargeCopy)
        XCTAssertFalse(unread.chargeCopy.contains("0 co"), "不许把读不到印成扣了 0")

        let charged = OneStepLyricsRegenerateOutcome(card: nil, charged: 7, balance: 121, insufficient: false)
        XCTAssertTrue(charged.chargeCopy.contains("7 co"), charged.chargeCopy)
        XCTAssertFalse(charged.chargeCopy.contains("没扣"), charged.chargeCopy)

        let short = OneStepLyricsRegenerateOutcome(card: nil, charged: 0, balance: 0, insufficient: true)
        XCTAssertTrue(short.chargeCopy.contains("没能扣费"), short.chargeCopy)
    }

    /// 重做的载荷只有共享信封那三件 —— 多一个键都不发明（`shared.ts:81`）。
    func testRegenerateRequestCarriesOnlyTheEnvelope() throws {
        let key = try OneStepLyricsEditToken().key
        let data = try JSONEncoder().encode(
            OneStepLyricsRegenerateRequestDto(sessionId: "s-1", expectedRevision: 7, idempotencyKey: key)
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), Set(["sessionId", "expectedRevision", "idempotencyKey"]))
    }

    /// 字段版本列表：后端把 `content` 留成 unknown ⇒ 本屏不建模它，也不该因此整包解不开。
    func testFieldVersionsDecodeWithoutModelingContent() throws {
        let response = try XCTUnwrap(
            JSONDecoder().decode(
                OneStepFieldVersionsResponseDto.self,
                from: Data("""
                    {"versions": [{"field": "lyrics", "version": 1, "content": {"sections": []}, "createdAt": "t"},
                                  {"field": "lyrics", "version": 2}], "sectionHistory": []}
                    """.utf8)
            )
        )
        XCTAssertEqual(response.versions?.map(\.version), [1, 2])
        XCTAssertEqual(response.versions?.first?.field, "lyrics")
        XCTAssertNil(response.versions?.last?.createdAt, "没给的键就是 nil，不当成空串")
    }
}

private extension String {
    /// 有没有 ASCII 字母（本仓「屏上不许出现英文态名」的判据用得上；
    /// 不用 `CharacterSet.asciiLetters`：测试目标里已有一份同名的 fileprivate 辅助，会撞名）。
    var containsASCIILetter: Bool {
        unicodeScalars.contains { (0x41 ... 0x5A).contains($0.value) || (0x61 ... 0x7A).contains($0.value) }
    }
}
