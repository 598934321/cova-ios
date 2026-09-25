import CovaCore
import Foundation
import XCTest

/// 03 曲库级联筛选的纯逻辑（`LibraryFilter.swift`）。
///
/// 这一层值得逐条断言的原因是它的输出**就是**发出去的查询串：E3a 那次「筛选静默失效」
/// （客户端发 `dimension=/term=`，服务端一个都不读）在编译期和 UI 上都看不出来，
/// 只有把 query 的字节钉死才能挡住同一类回归。
///
/// 词表侧的断言用真实回灌 fixture `taxonomy.json`（`GET /api/library/taxonomy` 的脱敏副本，
/// 每维取前 2 项）；线上全量形态（13 维、subgenre 54/54 带 `parent:`、其中 7 条挂在别的
/// subgenre 上 = 真三级）在 2026-09-26 只读探针里核对过，探针只打印键名与数组长度。
final class LibraryFilterCascadeTests: XCTestCase {

    private func taxonomy() throws -> TaxonomyDto { try Fixture.decode(TaxonomyDto.self, "taxonomy") }

    private func term(_ id: String, label: String? = nil, parent: String? = nil) throws -> TaxonomyTermDto {
        var payload: [String: Any] = ["id": id, "aliases": parent.map { ["parent:\($0)"] } ?? []]
        if let label { payload["label"] = label }
        return try JSONDecoder().decode(
            TaxonomyTermDto.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    // MARK: - 词表 → 维度表

    func testDimensionsComeFromTaxonomyDtoInSpecOrder() throws {
        let dims = LibraryFilterSchema.dimensions(from: try taxonomy())
        XCTAssertEqual(
            dims.map(\.id),
            ["scene", "mood", "genre", "instrument", "energy", "vocalType", "style", "type", "attribute", "musicalKey", "tag"]
        )
        XCTAssertEqual(dims.first?.title, "场景")
        let genre = dims.first { $0.id == "genre" }
        XCTAssertEqual(genre?.title, "风格")
        XCTAssertEqual(genre?.childDimensionID, "subgenre")
        // 「风格」这一维的词条 = genre 本级 + subgenre 子级（子级靠 parent: 挂进二/三栏）。
        XCTAssertEqual(genre?.terms.map(\.value), ["R&B", "Funk", "Neo Soul", "Contemporary R&B"])
    }

    func testEmptyOrMissingDimensionsProduceNoChip() throws {
        let json = Data(#"{"taxonomy":{"scene":[{"id":"咖啡馆"}],"mood":[]}}"#.utf8)
        let dims = LibraryFilterSchema.dimensions(
            from: try JSONDecoder().decode(TaxonomyDto.self, from: json)
        )
        XCTAssertEqual(dims.map(\.id), ["scene"], "空数组维度与缺席维度都不该画 chip")
        XCTAssertEqual(dims[0].terms.map(\.value), ["咖啡馆"])
    }

    func testTermValueIsLabelNotID() throws {
        // 实测：服务端 track_tags 存的是 label（E3a 命中的 `energy=高` 是 label，
        // 而该词条 id 是 `high-energy`）⇒ 拿 id 发出去就是第二个「筛选静默失效」。
        let json = Data(#"{"taxonomy":{"energy":[{"id":"high-energy","label":"高"}]}}"#.utf8)
        let dims = LibraryFilterSchema.dimensions(
            from: try JSONDecoder().decode(TaxonomyDto.self, from: json)
        )
        XCTAssertEqual(dims.first?.terms.map(\.value), ["高"])
    }

    func testTermWithoutLabelFallsBackToID() throws {
        let json = Data(#"{"taxonomy":{"tag":[{"id":"cinematic"}]}}"#.utf8)
        let dims = LibraryFilterSchema.dimensions(
            from: try JSONDecoder().decode(TaxonomyDto.self, from: json)
        )
        XCTAssertEqual(dims.first?.terms.map(\.value), ["cinematic"])
    }

    func testOnlyParentAliasesCreateHierarchy() throws {
        // `aliases` 里的别的形态（web 另有 `group:` 乐器分组）不得被当成父级。
        let json = Data(
            #"{"taxonomy":{"genre":[{"id":"G","label":"G"}],"subgenre":[{"id":"S","label":"S","aliases":["group:G"]}]}}"#
                .utf8
        )
        let dims = LibraryFilterSchema.dimensions(
            from: try JSONDecoder().decode(TaxonomyDto.self, from: json)
        )
        let genre = try XCTUnwrap(dims.first { $0.id == "genre" })
        XCTAssertEqual(genre.terms.first(where: { $0.value == "S" })?.parent, nil)
        // ⇒ 建树时 S 没有父级可挂，只能自己成一栏都点得到的一级节点（宁可平铺，不可隐藏）。
        let tree = LibraryFilterSchema.cascadeTree(of: genre)
        XCTAssertEqual(tree.map(\.term.value), ["G", "S"])
        XCTAssertTrue(tree.allSatisfy { $0.children.isEmpty })
    }

    // MARK: - 级联树

    func testCascadeTreeAttachesChildrenByParentLabel() throws {
        let genre = try XCTUnwrap(
            LibraryFilterSchema.dimensions(from: taxonomy()).first { $0.id == "genre" }
        )
        let tree = LibraryFilterSchema.cascadeTree(of: genre)
        XCTAssertEqual(tree.map(\.term.value), ["R&B", "Funk"])
        XCTAssertEqual(tree[0].children.map(\.term.value), ["Neo Soul", "Contemporary R&B"])
        XCTAssertTrue(tree[1].children.isEmpty, "无子项的一级节点不该带空栏")
    }

    func testCascadeTreeSupportsThirdLevelThroughChainedParents() throws {
        // 线上真实形态（7/54）：三级延伸风格的父级本身是 subgenre。
        let dimension = LibraryFilterDimension(
            id: "genre", title: "风格",
            terms: [
                LibraryFilterTerm(value: "电子", parent: nil),
                LibraryFilterTerm(value: "House", parent: "电子"),
                LibraryFilterTerm(value: "Deep House", parent: "House"),
            ],
            childDimensionID: "subgenre"
        )
        let tree = LibraryFilterSchema.cascadeTree(of: dimension)
        XCTAssertEqual(tree.map(\.term.value), ["电子"])
        XCTAssertEqual(tree[0].children.map(\.term.value), ["House"])
        XCTAssertEqual(tree[0].children[0].children.map(\.term.value), ["Deep House"])
    }

    func testCascadeTreeDepthIsCappedAtThreeColumns() {
        let dimension = LibraryFilterDimension(
            id: "genre", title: "风格",
            terms: (1...5).map { LibraryFilterTerm(value: "L\($0)", parent: $0 == 1 ? nil : "L\($0 - 1)") },
            childDimensionID: "subgenre"
        )
        let tree = LibraryFilterSchema.cascadeTree(of: dimension)
        var depth = 1
        var node = tree[0]
        while let first = node.children.first { depth += 1; node = first }
        XCTAssertEqual(depth, 3, "03 §2 只画三栏；更深的链不该把面板撑成横向无尽头")
        XCTAssertEqual(node.children, [])
    }

    func testCascadeTreeSurfacesOrphanGroupsAsRoots() {
        // 父级词条不在任何一栏（未挂 parent 的「其他」、父词条被停用）时，
        // 子项必须仍能从一级点到（web 为此专门写过一条兜底注释）。
        let dimension = LibraryFilterDimension(
            id: "genre", title: "风格",
            terms: [
                LibraryFilterTerm(value: "R&B", parent: nil),
                LibraryFilterTerm(value: "Other Style", parent: "已停用大类"),
            ],
            childDimensionID: "subgenre"
        )
        let tree = LibraryFilterSchema.cascadeTree(of: dimension)
        XCTAssertEqual(tree.map(\.term.value), ["R&B", "已停用大类"])
        XCTAssertEqual(tree[1].children.map(\.term.value), ["Other Style"])
    }

    func testCascadeTreeSurvivesParentCycle() {
        let dimension = LibraryFilterDimension(
            id: "genre", title: "风格",
            terms: [
                LibraryFilterTerm(value: "A", parent: "B"),
                LibraryFilterTerm(value: "B", parent: "A"),
            ],
            childDimensionID: "subgenre"
        )
        let tree = LibraryFilterSchema.cascadeTree(of: dimension)
        XCTAssertEqual(tree.map(\.term.value), ["A", "B"], "无一级词条时靠孤儿兜底仍可点")
        for node in tree {
            XCTAssertEqual(node.children.count, 1)
            XCTAssertTrue(node.children[0].children.isEmpty, "环必须在第二层断开，不递归回自己")
        }
    }

    // MARK: - 选择态

    func testToggleAddsThenRemoves() {
        var selection = LibraryFilterSelection()
        XCTAssertEqual(selection.toggle(dimension: "scene", value: "咖啡馆"), .added)
        XCTAssertEqual(selection.toggle(dimension: "scene", value: "平静"), .added)
        XCTAssertEqual(selection.count(in: "scene"), 2)
        XCTAssertEqual(selection.toggle(dimension: "scene", value: "咖啡馆"), .removed)
        XCTAssertEqual(selection.values("scene"), ["平静"], "移除只掉那一个值，顺序保持")
    }

    func testSameValueUnderDifferentDimensionsIsIndependent() {
        // 「中」既是能量也是别的维度的词 ⇒ 两维各自计数、各自移除。
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "energy", value: "中")
        selection.toggle(dimension: "mood", value: "中")
        XCTAssertEqual(selection.totalCount, 2)
        let chips = selection.chips()
        XCTAssertEqual(chips.map(\.dimension), ["mood", "energy"], "chips 按维度表定序，不按点选顺序")
        selection.remove(dimension: "mood", value: "中")
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(selection.chips().map(\.dimension), ["energy"])
        XCTAssertTrue(selection.isSelected(dimension: "energy", value: "中"))
    }

    func testSelectionStaysUnderMaxPerDimension() {
        var selection = LibraryFilterSelection()
        for index in 0..<LibraryFilterSelection.maxValuesPerDimension {
            XCTAssertEqual(selection.toggle(dimension: "instrument", value: "i\(index)"), .added)
        }
        XCTAssertEqual(
            selection.toggle(dimension: "instrument", value: "overflow"), .rejectedByLimit,
            "超限的点选必须被拒绝并可被 UI 告知，而不是静默丢弃"
        )
        XCTAssertEqual(selection.count(in: "instrument"), LibraryFilterSelection.maxValuesPerDimension)
        XCTAssertFalse(selection.values("instrument").contains("overflow"))
    }

    func testBlankValuesAndWhitespaceAreIgnored() {
        var selection = LibraryFilterSelection()
        XCTAssertEqual(selection.toggle(dimension: "scene", value: "   "), .ignored)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.toggle(dimension: "scene", value: " 咖啡馆 "), .added)
        XCTAssertEqual(selection.values("scene"), ["咖啡馆"], "存的是去掉首尾空白的值")
    }

    func testUnknownTaxonomyValuesAreKeptAndVisible() {
        // 03 §7 预填 + 词表更新前的旧值：不认识也必须可见可发，否则用户在屏上删不掉它。
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "词表里没有的场景")
        XCTAssertEqual(selection.chips().map(\.value), ["词表里没有的场景"])
        let items = selection.queryItems(search: nil, sort: .newest)
        XCTAssertTrue(items.contains(URLQueryItem(name: "scene", value: "词表里没有的场景")))
    }

    func testClearOneAndClearAll() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "咖啡馆")
        selection.toggle(dimension: "mood", value: "平静")
        selection.toggle(dimension: "mood", value: "专注")
        selection.clear(dimension: "scene")
        XCTAssertEqual(selection.activeDimensions, ["mood"])
        selection.clearAll()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.totalCount, 0)
        XCTAssertTrue(selection.chips().isEmpty)
    }

    func testDimensionTitlesRideOnChipsAndUnknownDimensionsKeepRawName() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "咖啡馆")
        selection.toggle(dimension: "weird", value: "x")
        let chips = selection.chips()
        XCTAssertEqual(chips.first?.dimensionTitle, "场景")
        XCTAssertEqual(chips.last?.dimensionTitle, "weird", "词表外的维度名原样回显，不假造中文名")
    }

    func testMergePresetDedupesAndRespectsLimit() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "已有")
        selection.merge(["scene": ["已有", " 咖啡馆 ", ""], "mood": ["平静"]])
        XCTAssertEqual(selection.values("scene"), ["已有", "咖啡馆"])
        XCTAssertEqual(selection.values("mood"), ["平静"])
        var capped = LibraryFilterSelection(
            valuesByDimension: ["instrument": (0..<LibraryFilterSelection.maxValuesPerDimension).map { "i\($0)" }]
        )
        capped.merge(["instrument": ["overflow"], "mood": ["平静"]])
        XCTAssertFalse(capped.values("instrument").contains("overflow"))
    }

    // MARK: - 请求编码（E3a 口径的跨维度版）

    func testQueryItemsEncodeCrossDimensionMultiSelect() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "咖啡馆")
        selection.toggle(dimension: "mood", value: "平静")
        selection.toggle(dimension: "mood", value: "专注")
        selection.toggle(dimension: "genre", value: "R&B")
        let items = selection.queryItems(search: "夜", sort: .hottest, page: 2, pageSize: 20)
        XCTAssertEqual(
            items.map { "\($0.name)=\($0.value ?? "")" },
            ["page=2", "pageSize=20", "search=夜", "sort=favorites", "scene=咖啡馆", "mood=平静", "mood=专注", "genre=R&B"]
        )
    }

    func testQueryItemsAlwaysSendPaginationAndSortAndNeverSendEmptyKeys() {
        let items = LibraryFilterSelection().queryItems(search: "   ", sort: .recommended)
        XCTAssertEqual(
            items.map { "\($0.name)=\($0.value ?? "")" },
            ["page=1", "pageSize=20", "sort=featured"],
            "空 search 不发键（发 `search=` 会让「同一筛选 = 同一地址」这条不变量分裂）"
        )
    }

    func testQueryItemsEmitValuesInTapOrderAndDimensionsInSchemaOrder() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "genre", value: "电子")
        selection.toggle(dimension: "scene", value: "b")
        selection.toggle(dimension: "scene", value: "a")
        XCTAssertEqual(
            selection.queryItems(search: nil, sort: .newest)
                .filter { $0.name != "page" && $0.name != "pageSize" && $0.name != "sort" }
                .map { "\($0.name)=\($0.value ?? "")" },
            ["scene=b", "scene=a", "genre=电子"]
        )
    }

    func testIllegalDimensionNameNeverBecomesAQueryKey() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "a=b&c", value: "x")
        selection.toggle(dimension: "scene", value: "咖啡馆")
        let encoded = selection.queryItems(search: nil, sort: .newest)
            .map { "\($0.name)=\($0.value ?? "")" }
        XCTAssertFalse(encoded.contains { $0.contains("a=b") || $0.contains("&c") })
        XCTAssertTrue(encoded.contains("scene=咖啡馆"))
        // 但它仍在 chips 行上（用户删得掉），只是不进请求。
        XCTAssertEqual(selection.chips().count, 2)
    }

    func testSortCasesMapToServerBackedValuesOnly() {
        // 四个枚举值逐个钉死成实测存在的服务端档位（`web` 仓 route.ts 的 orderBy 分支 +
        // 只读探针 200 且行序互不相同）。`relevance` 在无 search 时实测 500 ⇒ 不出现。
        XCTAssertEqual(LibrarySort.allCases.map(\.queryValue), ["featured", "newest", "favorites", "duration_asc"])
        XCTAssertEqual(LibrarySort.allCases.map(\.label), ["推荐", "最新", "最热", "时长"])
        XCTAssertEqual(LibrarySort.hottest.detail, "收藏数")
    }

    // MARK: - URL → 选择态（同一条不变量的反向）

    func testDecodeRoundTripsSelectionIntoSameRequest() {
        var selection = LibraryFilterSelection()
        selection.toggle(dimension: "scene", value: "咖啡馆")
        selection.toggle(dimension: "energy", value: "高")
        selection.toggle(dimension: "energy", value: "中")
        let items = selection.queryItems(search: "晨间", sort: .duration)
        let decoded = LibraryFilterSelection.decode(queryItems: items)
        XCTAssertEqual(decoded.activeDimensions, ["scene", "energy"])
        XCTAssertEqual(
            decoded.queryItems(search: "晨间", sort: .duration),
            items,
            "从请求反解出的选择态再编码一次必须逐字相同"
        )
    }

    func testDecodeIgnoresUnknownKeysAndBlanksAndCapsValues() {
        let decoded = LibraryFilterSelection.decode(queryItems: [
            URLQueryItem(name: "page", value: "3"),
            URLQueryItem(name: "sort", value: "favorites"),
            URLQueryItem(name: "notADimension", value: "x"),
            URLQueryItem(name: "mood", value: "  "),
            URLQueryItem(name: "mood", value: "平静"),
            URLQueryItem(name: "mood", value: "平静"),
        ])
        XCTAssertEqual(decoded.values("mood"), ["平静"])
        XCTAssertEqual(decoded.totalCount, 1)
    }

    // MARK: - 计数文案（03 §1）

    func testResultCountText() {
        XCTAssertEqual(LibraryResultCount.text(total: 1248), "共 1,248 首")
        XCTAssertEqual(LibraryResultCount.text(total: 20425), "共 20,425 首", "线上基线 total 实测 20425")
        XCTAssertEqual(LibraryResultCount.text(total: 0), "共 0 首")
        XCTAssertEqual(LibraryResultCount.text(total: 999), "共 999 首")
        XCTAssertNil(LibraryResultCount.text(total: nil), "后端没给 total 就不报数，不拿本页行数冒充")
        XCTAssertNil(LibraryResultCount.text(total: -1))
        XCTAssertEqual(LibraryResultCount.grouped(1_000_000), "1,000,000")
    }

    // MARK: - 词表侧的 helper（parent 解析）

    func testParentPrefixParsingToleratesMissingAndBlank() throws {
        XCTAssertEqual(LibraryFilterSchema.parent(of: try term("S", parent: "R&B")), "R&B")
        XCTAssertNil(LibraryFilterSchema.parent(of: try term("S")))
        XCTAssertNil(LibraryFilterSchema.parent(of: try term("S", parent: "  ")), "parent: 后面是空白 ⇒ 视为无父级")
        XCTAssertEqual(LibraryFilterSchema.term(try term("high-energy", label: "高"))?.value, "高")
        XCTAssertNil(LibraryFilterSchema.term(try term("  ")), "id/label 都为空的词条不进词表")
    }
}
