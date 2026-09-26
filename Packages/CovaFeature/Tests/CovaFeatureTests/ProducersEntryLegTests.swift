import CovaCore
import Foundation
import XCTest

@testable import CovaFeature

/// 23「制作人入口」的可见性裁决与卡面槽位（§5 P2-2 / §6 A10）。
///
/// ⚠️ **本文件的非空用例是 fixture，不是生产数据**（23 §7「必须说白」）：
/// 生产 `GET /api/studio/producers` 今天恒回 `{producers:[]}`（`PRODUCER_MODE` 未设 ⇒ 灰度关闭），
/// 本仓没有已开灰度的账号 ⇒ A10 前半**没有设备证据**，这里三件替代证据之一。
/// 它们证明的是：解码不崩、字段各归其槽位、未释义字段确实不上屏，
/// 以及"读不懂"不许被画成"没有"。**不证明**服务端真会返回这个形状（夹具按契约 §4.6 拼）。
///
/// 承重的那一格拉在最上面：`{producers:[]}` ⇒ 入口不渲染；
/// 解码失败 ⇒ **不**渲染成空态（`producersReadFailed` 存在的唯一理由就是把这两格分开）。
@MainActor
final class ProducersEntryLegTests: XCTestCase {

    // MARK: - 夹具（按契约 §4.6 的键清单拼的真实形状）
    //
    // 未释义字段的值全部用**哨兵串**：它们一旦出现在渲染面上，断言就会红 ——
    // 用 6 / 2 这种小整数当哨兵会被"第 2 步"之类的合法渲染误伤，那是假红不是判据。

    private let idSentinel = "prd-sentinel-7f3a91c2e4b8"
    private let audienceSentinel = "night-drive-audience-sentinel"
    private let greetingSentinel = "greeting-sentinel-想做个什么样的夜晚"
    private let demoCountSentinel = 60_606
    private let cardCountSentinel = 20_202

    private var grayReleasedJSON: String {
        """
        {"producers":[
          {"id":"\(idSentinel)","displayName":"林声","fictional":true,
           "tagline":"十年影视配乐，专做深夜情绪","audience":"\(audienceSentinel)",
           "greeting":"\(greetingSentinel)",
           "stages":[
             {"id":"st_1","label":"需求确认","summary":"先聊清楚要什么：场景、时长、人声还是纯音乐"},
             {"id":"st_2","label":"小样","summary":"出两版 30 秒小样，挑一版继续推"},
             {"id":"st_3","label":"交付"}
           ],
           "deliverables":[
             {"kind":"master_wav","label":"母带 WAV","required":true,"description":"24bit/48k"},
             {"kind":"stems_zip","label":"分轨包","required":false},
             {"kind":"brand_new_kind","label":"服务端新加的交付项","required":null},
             {"kind":"master_mp3"}
           ],
           "extensions":[
             {"id":"ex_1","label":"改词","description":"两轮以内","enabled":true},
             {"id":"ex_2","label":"  ","enabled":false},
             {"id":"ex_3","enabled":null}
           ],
           "demoCount":\(demoCountSentinel),"cardCount":\(cardCountSentinel)}
        ]}
        """
    }

    private func decode(_ json: String) throws -> ProducersResponseDto {
        try JSONDecoder().decode(ProducersResponseDto.self, from: Data(json.utf8))
    }

    private func stage(_ json: String) throws -> ProducerStageDto {
        try JSONDecoder().decode(ProducerStageDto.self, from: Data(json.utf8))
    }

    private func card(_ id: String, _ displayName: String?) -> ProducerCardDto {
        ProducerCardDto(id: id, displayName: displayName, tagline: nil)
    }

    // MARK: - A10 后半（今天可判）：`{producers:[]}` ⇒ 入口不可见

    func testDefinitivelyEmptyResponseHidesTheEntrance() throws {
        let page = try decode(#"{"producers":[]}"#)
        XCTAssertTrue(page.isDefinitivelyEmpty)
        XCTAssertTrue(page.shouldHideEntrance)
        XCTAssertEqual(page.unreadableItemCount, 0)
        let accounts = AppSession.producersAccounts(
            after: .responded(page), previous: [card("prd-1", "林声")]
        )
        // 灰度关掉是服务端的事实：手里那份旧的必须让位（不是"保留旧的显得还在开"）。
        XCTAssertTrue(accounts.cards.isEmpty)
        XCTAssertFalse(accounts.readFailed)
    }

    func testMissingKeyIsNotTheSameThingAsEmpty() {
        // `{}` / `{producers:null}` / 根不是对象 ⇒ **抛**（`CovaAPIClient` 归一成 `.decoding`），
        // 于是取数腿落 `.unreadable` 那一格，而**绝不**静默降级成空列表。
        for json in ["{}", #"{"producers":null}"#, #"{"producers":"none"}"#, "[]", "null"] {
            XCTAssertThrowsError(try decode(json), "\(json) 不该被解成一份 producers 响应")
        }
    }

    func testDecodeFailureKeepsPreviouslyShownCardsInsteadOfHidingThem() {
        let previous = [card("prd-1", "林声")]
        let accounts = AppSession.producersAccounts(after: .unreadable, previous: previous)
        // 「读不懂」不许被画成「没有」：卡留着 ⇒ 入口继续可见（A10 那句"不是置灰"的另一半）。
        XCTAssertEqual(accounts.cards, previous)
        XCTAssertTrue(accounts.readFailed)
    }

    func testUnreadablePayloadThatDecodesToZeroCardsDoesNotHideTheEntrance() throws {
        // `{producers:[读不出的卡]}`：数组长度 0 但 `unreadableItemCount > 0` ⇒ 不是"明确给了零张"。
        let page = try decode(#"{"producers":[{},{"id":""},{"id":null}]}"#)
        XCTAssertTrue(page.producers.isEmpty)
        XCTAssertEqual(page.unreadableItemCount, 3)
        XCTAssertFalse(page.isDefinitivelyEmpty)
        XCTAssertFalse(page.shouldHideEntrance)
        let accounts = AppSession.producersAccounts(
            after: .responded(page), previous: [card("prd-1", "林声")]
        )
        XCTAssertEqual(accounts.cards.count, 1, "读不懂不是「没有」，不许把入口藏掉")
        XCTAssertTrue(accounts.readFailed)
    }

    func testAPartiallyUnreadablePageStillShowsTheReadableCards() throws {
        let page = try decode(
            #"{"producers":[{"id":"prd-1","displayName":"林声"},{"id":""},{"kind":"x"}]}"#
        )
        XCTAssertEqual(page.producers.count, 1)
        XCTAssertEqual(page.unreadableItemCount, 2)
        let accounts = AppSession.producersAccounts(after: .responded(page), previous: [])
        XCTAssertEqual(accounts.cards.map(\.id), ["prd-1"])
        XCTAssertTrue(accounts.readFailed)   // 记一笔"这次有读不懂的东西"，但不影响已读到的那些
    }

    func testANullElementDoesNotSentenceTheWholeList() throws {
        // Swift 的数组解码遇到元素 `null` 会在调用元素 init **之前**抛 ⇒ 元素必须给成 Optional。
        // 这条用例钉的就是那个形状今天不再把整份列表判死。
        let page = try decode(#"{"producers":[null,{"id":"prd-1","displayName":"林声"}]}"#)
        XCTAssertEqual(page.producers.map(\.id), ["prd-1"])
        XCTAssertEqual(page.unreadableItemCount, 1)
    }

    // MARK: - A10 前半（今天**不可**设备判）：非空分支的形状

    func testNonEmptyResponseFeedsTheEntranceAndDecodesEverySection() throws {
        let page = try decode(grayReleasedJSON)
        XCTAssertEqual(page.producers.count, 1)
        XCTAssertEqual(page.unreadableItemCount, 0)
        XCTAssertFalse(page.shouldHideEntrance)
        let accounts = AppSession.producersAccounts(after: .responded(page), previous: [])
        XCTAssertEqual(accounts.cards.count, 1)
        XCTAssertFalse(accounts.readFailed)
    }

    func testUndefinedFieldsNeverReachTheScreenOrTheSpokenLabels() throws {
        // §9 判据：`fictional` / `audience` / `greeting` / `demoCount` / `cardCount` / `id`
        // 在截图与 VoiceOver 序列中**均不出现**（出现即为"把未释义字段当渲染依据"，判红）。
        let subject = try decode(grayReleasedJSON).producers[0]
        var rendered: [String] = [ProducersPanelFacts.headerSpokenLabel(subject)]
        rendered += ProducersPanelFacts.stageRows(subject.stages)
            .map { $0.spokenLabel(expanded: false) }
        rendered += ProducersPanelFacts.deliverableLabels(subject.deliverables)
        rendered += ProducersPanelFacts.extensionLabels(subject.extensions)
        let joined = rendered.joined(separator: "|")
        for sentinel in [
            idSentinel, audienceSentinel, greetingSentinel,
            "\(demoCountSentinel)", "\(cardCountSentinel)",
            // `fictional` 若要披露，唯一合理的中文就是「虚构」那两个字（§7 待答（2）等口径）；
            // 在拿到产品/法务文案之前把它画出来就是设计替法务说话。
            "虚构", "st_1", "ex_1", "24bit/48k", "两轮以内",
        ] {
            XCTAssertFalse(joined.contains(sentinel), "未释义/未授权字段 \(sentinel) 出现在了渲染面上")
        }
        // 同时证明卡面确实**有内容**（否则"不含禁串"会因为一片空白而假通过）。
        XCTAssertTrue(joined.contains("林声"))
        XCTAssertTrue(joined.contains("十年影视配乐，专做深夜情绪"))
        XCTAssertTrue(joined.contains("母带 WAV"))
    }

    func testHeaderSpokenLabelCarriesCategoryAndNonInteractiveWord() {
        let spoken = ProducersPanelFacts.headerSpokenLabel(card("prd-1", "林声"))
        // §6：「<displayName>，制作人，<tagline>，非交互内容」—— 卡不可点**必须被朗读出来**。
        XCTAssertEqual(spoken, "林声，制作人，非交互内容")
    }

    func testTaglineMissingMeansThatSegmentIsAbsentFromTheSpokenLabel() {
        let withTagline = ProducerCardDto(id: "p", displayName: "林声", tagline: "深夜情绪")
        XCTAssertEqual(
            ProducersPanelFacts.headerSpokenLabel(withTagline),
            "林声，制作人，深夜情绪，非交互内容"
        )
        // 空白按"没给"处理；**不**回落 `id`（把内部 id 印上屏是 A15 那一类脏）。
        let blank = ProducersPanelFacts.headerSpokenLabel(
            ProducerCardDto(id: "prd-x", displayName: "  ", tagline: "")
        )
        XCTAssertEqual(blank, "制作人，非交互内容")
        XCTAssertFalse(blank.contains("prd-x"))
    }

    // MARK: - G 步骤：序号来源、空段、不重排

    func testStageNumbersComeFromTheArrayIndexNotFromAReSort() throws {
        let rows = ProducersPanelFacts.stageRows(try decode(grayReleasedJSON).producers[0].stages)
        XCTAssertEqual(rows.map(\.number), [1, 2, 3], "序号由数组下标 +1 得出（契约无 order 字段）")
        XCTAssertEqual(rows.first?.label, "需求确认")
        XCTAssertEqual(
            rows[0].spokenLabel(expanded: false),
            "第 1 步，需求确认，先聊清楚要什么：场景、时长、人声还是纯音乐，展开"
        )
        XCTAssertTrue(rows[0].spokenLabel(expanded: true).hasSuffix("收起"))
        // 只有 label、没有 summary 的那一步 ⇒ 没有展开动作（§6：不存在的东西不进序列）。
        XCTAssertFalse(rows[2].hasSummary)
        XCTAssertEqual(rows[2].spokenLabel(expanded: false), "第 3 步，交付")
    }

    func testAStageWithNoContentAtAllDisappearsButKeepsTheNumberingHonest() throws {
        let rows = ProducersPanelFacts.stageRows([
            try stage(#"{"label":"需求确认"}"#),
            try stage(#"{"label":"   ","summary":"\n"}"#),
            try stage(#"{"summary":"第三步只有一句说明"}"#),
        ])
        // 中间那条两格都没有 ⇒ 不渲染，但**不**重编号：用户对照的是服务端那份步骤表。
        XCTAssertEqual(rows.map(\.number), [1, 3])
    }

    func testEmptyStagesProduceNoRows() {
        XCTAssertTrue(ProducersPanelFacts.stageRows([]).isEmpty)
    }

    // MARK: - H / I chips：只认服务端 `label`，取不到就不渲染

    func testDeliverableWithoutLabelIsDroppedRatherThanNamedFromItsKind() throws {
        let items = try decode(grayReleasedJSON).producers[0].deliverables
        let labels = ProducersPanelFacts.deliverableLabels(items)
        // 第 4 条只给了 `kind:master_mp3` ⇒ 没有中文口径可用 ⇒ 该条不渲染。
        XCTAssertEqual(labels, ["母带 WAV", "分轨包", "服务端新加的交付项"])
        // 词表外的新 `kind` 不丢条目（`.unknown` 保住原拼写），标签照旧取服务端那一句。
        XCTAssertEqual(items[2].kind, .unknown("brand_new_kind"))
        // `required: null` 不许被读成"不必须"（那是客户端替服务端做断言）。
        XCTAssertNil(items[2].required)
    }

    func testExtensionLabelsWithoutTextAreDroppedAndEnabledIsNotRendered() throws {
        let items = try decode(grayReleasedJSON).producers[0].extensions
        // 只有 `label` 一格进 chips：`description` / `enabled` 都没有 P2 的落点（§3.I）。
        XCTAssertEqual(ProducersPanelFacts.extensionLabels(items), ["改词"])
        XCTAssertFalse(items[2].isEnabled)
        XCTAssertFalse(items[2].hasState)
    }

    func testAStringArrayPayloadLosesTheSectionInsteadOfCrashing() throws {
        // §3.H「条目类型未文档化」的代价：若服务端回的是**字符串数组**，本层的对象解码会把整段
        // 读成"取不到" ⇒ 整段连同标题一起消失（不是崩，也不把英文键名印上屏）。
        // 这一条替 §7 待答（5）记下现场：答案回来之前，这个表现是**已知**的，不是意外。
        let page = try decode(
            #"{"producers":[{"id":"p1","displayName":"林声","deliverables":["母带 WAV"]}]}"#
        )
        XCTAssertEqual(page.producers.count, 1)
        XCTAssertTrue(page.producers[0].deliverables.isEmpty)
        XCTAssertTrue(ProducersPanelFacts.deliverableLabels(page.producers[0].deliverables).isEmpty)
    }

    func testChipWindowUsesTheCountBandAndOpensUpOnRequest() {
        let many = (1...31).map { "项\($0)" }
        let capped = ProducersPanelFacts.chipWindow(many, showsAll: false)
        XCTAssertEqual(capped.shown.count, ProducersPanelFacts.chipCountShown)
        XCTAssertEqual(capped.droppedCount, 11)
        XCTAssertEqual(ProducersCopy.moreCount(11), "+11")
        let opened = ProducersPanelFacts.chipWindow(many, showsAll: true)
        XCTAssertEqual(opened.shown.count, 31)
        XCTAssertNil(opened.droppedCount)
        // 未过阈值 ⇒ 全量、也不给「+N」（§8 极值档只在 >30 时才生效）。
        let few = ProducersPanelFacts.chipWindow((1...30).map { "项\($0)" }, showsAll: false)
        XCTAssertEqual(few.shown.count, 30)
        XCTAssertNil(few.droppedCount)
    }

    // MARK: - 两本账的分界（D9 owner 隔离的账本面）

    func testOnlyADefinitiveZeroClearsTheCards() throws {
        // 「空」只有一个来源：服务端明确给了零张。其余一律不许把 `producerCards` 清空。
        let previous = [card("prd-1", "林声")]
        let definitiveZero = try decode(#"{"producers":[]}"#)
        XCTAssertEqual(
            AppSession.producersAccounts(after: .unreadable, previous: previous).cards, previous
        )
        XCTAssertEqual(
            AppSession.producersAccounts(
                after: .responded(definitiveZero), previous: previous
            ).cards,
            [],
            "灰度关掉是服务端事实：这一格才允许把入口藏掉"
        )
    }
}
