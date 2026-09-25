import Foundation

/// 03 曲库级联筛选（`design/screens/03-library.md` §1/§2/§5）的纯逻辑层。
///
/// 放这里而不是留在 View 里的理由：这一层的输出**就是**发出去的查询串。
/// E3a 那次「筛选静默失效」（客户端发 `dimension=/term=`，服务端一个都不读）已经证明，
/// 编码散在 UI 层里时没人能断言它——所以维度表、级联树、选择态、请求编码全部
/// 收成可测的纯函数，View 只负责画。
///
/// ## 线上实测口径（2026-09-26 只读探针 `GET https://covalink.cn/api/library/taxonomy`，
/// 与 `web` 仓 `src/components/taxonomy/TaxonomyCascadeMenu.tsx` + `src/lib/public-library.ts` 互证；
/// 探针只打印键名与数组长度，不落任何响应体）
/// · 真实响应 **13** 个维度键（顺序即回显顺序）：`scene(18) mood(35) genre(27) subgenre(54)
///   style(14) instrument(55) attribute(6) energy(5) tag(6) vocalType(2) subscene(60)
///   type(8) musicalKey(24)`，全部 `active`（无停用词条）；
/// · **层级不是 children 字段，是 `aliases` 里的 `parent:<父级label>`**：`subgenre` 54/54 带
///   `parent:`、`subscene` 60/60 带 `parent:`，其余 11 个维度一个都没有 ⇒ 级联只存在于
///   genre→subgenre 与 scene→subscene 两对；
/// · 级联深度：subgenre 里 47 条的父级是 genre 词条（= 二级），**7 条的父级本身又是 subgenre**
///   （= 真正的三级延伸风格）⇒ 03 §2 的「一级大类 → 二级 subgenre → 三级延伸」在数据上成立，
///   只是第三级稀疏（7/54）。`subscene` 无三级（父级全部落在 scene）。
/// · **词条值用 `label` 不用 `id`**：web 的 facet `value` 取 `collectActiveTaxonomyLabels`
///   （label 口径），E3a 实测命中的 `energy=高` 也是 label ⇒ 本层一律 `label ?? id`。
/// · `GET /api/tracks` 的 `sort` **是服务端真支持的**（`web` 仓 `app/api/tracks/route.ts` 的
///   `orderBy` 分支 + 只读探针）：`newest`(默认，等价不传)/`popular`/`downloads`/`favorites`/
///   `featured`/`bpm_asc`/`duration_asc` 各档 200 且首屏行序互不相同，`relevance` 在无 `search`
///   时回 **500**；未知值（`sort=bogus`）被**静默忽略**回落到默认档。
///   封套带 `total`（实测 20425）⇒ 「共 N 首」是真数，不是本页行数。
///
/// ## 已知的数据缺口（不在本层修，登记在报告里）
/// · `subscene` 在 `TaxonomyDimensionsDto` 里**没有对应字段**（DTO 只有 12 维），Swift Codable
///   会静默丢掉 ⇒ 场景维度今天只能渲染一级。`childDimension(of:)` 已按名字预留接位，
///   DTO 补一个 `subscene` 即生效；
/// · web 侧注明 subscene 词条**尚无曲目标签数据**（facets 计数恒 0），即便 DTO 补齐，
///   选中二级也会回 0 行。

// MARK: - 词表 → 维度 / 级联树

/// 一个可筛选的词条。`value` 既是展示名也是发出去的参数值（见文件头的 label 口径）。
public struct LibraryFilterTerm: Equatable, Sendable {
    public let value: String
    /// 父级词条的 `value`（`aliases` 的 `parent:` 前缀），无父级为 nil。
    public let parent: String?

    public init(value: String, parent: String?) {
        self.value = value
        self.parent = parent
    }
}

/// 一个筛选维度（含其级联子维度的词条）。
public struct LibraryFilterDimension: Equatable, Sendable {
    /// 契约维度名（= 查询参数名，E3a 实测：服务端读的就是维度名）。
    public let id: String
    /// 中文标题（§2 的「场景 / 情绪 / 风格 / …」）。
    public let title: String
    public let terms: [LibraryFilterTerm]
    /// 子维度名（genre→subgenre）。nil = 本维度无下级词表。
    public let childDimensionID: String?

    public init(id: String, title: String, terms: [LibraryFilterTerm], childDimensionID: String?) {
        self.id = id
        self.title = title
        self.terms = terms
        self.childDimensionID = childDimensionID
    }
}

/// 级联树节点（03 §2 的一栏里的一行）。
public struct LibraryCascadeNode: Equatable, Sendable, Identifiable {
    public let term: LibraryFilterTerm
    public let children: [LibraryCascadeNode]
    public var id: String { term.value }

    public init(term: LibraryFilterTerm, children: [LibraryCascadeNode]) {
        self.term = term
        self.children = children
    }
}

/// 维度表与级联建树（词表侧的纯函数，不持有状态）。
public enum LibraryFilterSchema {
    /// 03 §2 的 chip 顺序：一级 chips 行放前 6 个（屏宽内可滑完），其余收进「+」。
    /// `subgenre` 不单独成 chip —— 它是「风格」面板的第二/三栏（与 web 曲风面板同构）。
    /// BPM / 时长不是 taxonomy 维度（服务端是独立参数），沿用行内既有的时长/BPM 展示，
    /// 不在这里发明参数名。
    public static let layout: [(id: String, title: String, child: String?, inline: Bool)] = [
        ("scene", "场景", "subscene", true),
        ("mood", "情绪", nil, true),
        ("genre", "风格", "subgenre", true),
        ("instrument", "器乐", nil, true),
        ("energy", "能量", nil, true),
        ("vocalType", "人声", nil, true),
        ("style", "招牌风格", nil, false),
        ("type", "类型", nil, false),
        ("attribute", "属性", nil, false),
        ("musicalKey", "调性", nil, false),
        ("tag", "标签", nil, false),
    ]

    /// chip 行直接露出的维度数（其余走「+」）。
    public static let inlineDimensionCount = 6

    /// `aliases` 里父级挂接的前缀（实测唯一形态是 `parent:<父label>`）。
    static let parentPrefix = "parent:"

    /// `aliases` 里可能有别的非 parent: 前缀（web 另有 `group:` 乐器分组）；只认 parent:。
    /// public：层级**只**来自这一条解析，所以它值得被单独断言（03 §2 的三栏是不是真存在，
    /// 全看这里认不认对）。
    public static func parent(of term: TaxonomyTermDto) -> String? {
        for alias in term.aliases ?? [] where alias.hasPrefix(parentPrefix) {
            let value = alias.dropFirst(parentPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    /// DTO 词条 → 筛选词条（无 label 回退 id；两者都空则丢弃）。
    public static func term(_ dto: TaxonomyTermDto) -> LibraryFilterTerm? {
        let value = (dto.label ?? dto.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return LibraryFilterTerm(value: value, parent: parent(of: dto))
    }

    /// 词表 12 维摊平成有序维度表；空维度（后端没给词条）直接不出现，不画空 chip。
    /// 级联维度的 `terms` = 本级词条 + 子维度词条（建树靠 `parent:` 链分栏）。
    public static func dimensions(from taxonomy: TaxonomyDto) -> [LibraryFilterDimension] {
        layout.compactMap { spec in
            guard let raw = rawTerms(named: spec.id, in: taxonomy) else { return nil }
            let terms = raw.compactMap(term) + childTerms(of: spec.child, in: taxonomy)
            guard !terms.isEmpty else { return nil }
            return LibraryFilterDimension(
                id: spec.id, title: spec.title, terms: terms, childDimensionID: spec.child
            )
        }
    }

    /// 本维度的级联子维度词条（`childDimensionID` 指向的那一维）。
    /// 子维度不在 DTO 里（如 `subscene`）就返回 nil —— 面板退化为一级，不编造层级。
    public static func childDimension(of id: String, in taxonomy: TaxonomyDto) -> [LibraryFilterTerm]? {
        let terms = rawTerms(named: childName(for: id), in: taxonomy)
        guard terms != nil else { return nil }
        let mapped = (terms ?? []).compactMap(term)
        return mapped.isEmpty ? nil : mapped
    }

    static func childName(for id: String) -> String? { layout.first { $0.id == id }?.child }

    /// 按维度名从 DTO 取原始词条；**名字不认识**（DTO 无该字段）返回 nil，
    /// 与「认识但后端给了空数组」区分开。
    static func rawTerms(named name: String?, in taxonomy: TaxonomyDto) -> [TaxonomyTermDto]? {
        guard let name else { return nil }
        let table = taxonomy.taxonomy
        switch name {
        case "scene": return table.scene
        case "mood": return table.mood
        case "genre": return table.genre
        case "subgenre": return table.subgenre
        case "style": return table.style
        case "instrument": return table.instrument
        case "attribute": return table.attribute
        case "energy": return table.energy
        case "tag": return table.tag
        case "vocalType": return table.vocalType
        case "type": return table.type
        case "musicalKey": return table.musicalKey
        default: return nil
        }
    }

    private static func childTerms(of child: String?, in taxonomy: TaxonomyDto) -> [LibraryFilterTerm] {
        (rawTerms(named: child, in: taxonomy) ?? []).compactMap(term)
    }

    /// 级联建树：一级 = 本维度词条，往下按 `parent:` 链挂子维度词条，最深 `maxDepth` 栏。
    ///
    /// 两条兜底（都是 web 踩过的「显示不全」）：
    /// · 父级不在任何一栏里的分组（未挂 parent 的「其他」、父词条被停用）→ 补成一级节点，
    ///   否则这些子选项在任何面板里都点不到；
    /// · 出现 `parent:` 自环/环链时不递归（`visited` 集合），避免建树死循环。
    public static func cascadeTree(
        of dimension: LibraryFilterDimension, maxDepth: Int = 3
    ) -> [LibraryCascadeNode] {
        var childrenByParent: [String: [LibraryFilterTerm]] = [:]
        for term in dimension.terms {
            guard let parent = term.parent else { continue }
            childrenByParent[parent, default: []].append(term)
        }
        let roots = dimension.terms.filter { $0.parent == nil }
        let rootsByValue = Set(roots.map(\.value))
        let built = roots.map {
            node(term: $0, childrenByParent: childrenByParent, depth: 1, maxDepth: maxDepth, visited: [$0.value])
        }
        var reachable = rootsByValue
        collect(built, into: &reachable)
        // 字典无序 ⇒ 孤儿兜底必须按父级名排序后再拼，否则同一份词表两次建树出的列序会抖
        // （§2 的「同一筛选 = 同一地址」不变量同理要求这里可复现）。
        let orphanParents = childrenByParent.keys
            .filter { !reachable.contains($0) }
            .sorted()
        let orphans = orphanParents.map {
            node(term: LibraryFilterTerm(value: $0, parent: nil), childrenByParent: childrenByParent, depth: 1, maxDepth: maxDepth, visited: [$0])
        }
        return built + orphans

    }

    private static func collect(_ nodes: [LibraryCascadeNode], into out: inout Set<String>) {
        for n in nodes { out.insert(n.term.value); collect(n.children, into: &out) }
    }

    /// 面板顶部的词条搜索（03 §2）：命中的节点**连同整条父链**保留，父链上其它分支剪掉。
    ///
    /// 返回的仍是树而不是扁平命中表 —— 搜 "Deep House" 时用户要看见的是「电子 › House ›
    /// Deep House」这条路径（父级就是这一档的语义），扁平表会把它抹平。
    /// 父级本身命中时整枝留下（父级命中 = 它下面这些都相关）。
    public static func filtering(
        _ nodes: [LibraryCascadeNode], matching text: String
    ) -> [LibraryCascadeNode] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.term.value.localizedCaseInsensitiveContains(needle) { return node }
            let kept = filtering(node.children, matching: needle)
            guard !kept.isEmpty else { return nil }
            return LibraryCascadeNode(term: node.term, children: kept)
        }
    }

    /// 搜索时该自动展开到哪条路径（各级首个命中节点的 value）。
    /// 没有这一条，过滤后的二/三栏会停在空位上 —— 树过滤对了但屏幕上什么都看不见。
    public static func expansionPath(
        _ nodes: [LibraryCascadeNode], matching text: String
    ) -> [String] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        for node in filtering(nodes, matching: needle) where node.term.value.localizedCaseInsensitiveContains(needle) {
            return [node.term.value]   // 父级命中即止：它整枝都要显示
        }
        guard let first = filtering(nodes, matching: needle).first else { return [] }
        return [first.term.value] + expansionPath(first.children, matching: needle)
    }

    private static func node(
        term: LibraryFilterTerm,
        childrenByParent: [String: [LibraryFilterTerm]],
        depth: Int,
        maxDepth: Int,
        visited: Set<String>
    ) -> LibraryCascadeNode {
        guard depth < maxDepth else { return LibraryCascadeNode(term: term, children: []) }
        let kids = (childrenByParent[term.value] ?? []).filter { !visited.contains($0.value) }
        var next = visited
        for kid in kids { next.insert(kid.value) }
        return LibraryCascadeNode(
            term: term,
            children: kids.map {
                node(term: $0, childrenByParent: childrenByParent, depth: depth + 1, maxDepth: maxDepth, visited: next)
            }
        )
    }
}

// MARK: - 排序（03 §5）

/// 03 §5 的四档排序。**每档都对应服务端真实存在的一个 `sort` 值**（见文件头实测），
/// 客户端不对单页结果做任何二次排序——那会在 `total`/分页还说着别的事时撒谎。
public enum LibrarySort: String, Equatable, Sendable, CaseIterable, Identifiable {
    case recommended
    case newest
    case hottest
    case duration

    public var id: String { rawValue }

    /// 面板主文案（§5 逐字）。
    public var label: String {
        switch self {
        case .recommended: return "推荐"
        case .newest: return "最新"
        case .hottest: return "最热"
        case .duration: return "时长"
        }
    }

    /// 面板副文案：说清这一档**服务端到底按什么排**，不留想象空间。
    /// 「推荐」不是猜你喜欢，是 `sort=featured`（精选位优先）——后端没有个性化推荐分支，
    /// 所以这里给出的名字只能是「精选优先」这件事本身。
    public var detail: String {
        switch self {
        case .recommended: return "精选优先"
        case .newest: return "上架时间"
        case .hottest: return "收藏数"
        case .duration: return "时长升序"
        }
    }

    /// 发给服务端的 `sort` 值（全部实测 200 且行序互不相同）。
    public var queryValue: String {
        switch self {
        case .recommended: return "featured"
        case .newest: return "newest"
        case .hottest: return "favorites"
        case .duration: return "duration_asc"
        }
    }
}

// MARK: - 选择态

/// 单个词条的勾选结果（UI 要按结果说话，尤其超限那条）。
public enum LibraryFilterToggleOutcome: Equatable, Sendable {
    case added
    case removed
    /// 同维度已达上限，本次点选被拒绝（UI 提示「先移除一个」）。
    case rejectedByLimit
    /// 空词条（只有空白字符）不改变状态。
    case ignored
}

/// 跨维度多选的选择态（03 §1 已选 chips 行 + §2 面板的单一事实源）。
///
/// 不变量：
/// · 维度内词条按点选顺序去重保存（重复点同一词条只会翻转，不会写两遍）；
/// · 维度间是 AND、维度内是 OR —— 这是服务端 `conditions` 数组的语义（web 仓 `tracks/route.ts`），
///   客户端不自己求交并；
/// · 每个维度最多 `maxValuesPerDimension` 个词条：词条是**逐个**发成同名参数的（E3a 实测的
///   维度内多选编码），一屏 chips 行也只在十几项内可读；
/// · 允许存进**词表里没有**的值：03 §7 从首页场景卡/艺人页带进来的预填、以及词表更新前的
///   旧链接值，都必须照常发出去并可见，不能因为「不认识」就静默丢掉用户看到的筛选。
public struct LibraryFilterSelection: Equatable, Sendable {
    /// 单维度多选上限（见类型文档的编码理由）。
    public static let maxValuesPerDimension = 12

    /// 维度名 → 词条值（点选顺序）。
    public private(set) var valuesByDimension: [String: [String]]

    public init(valuesByDimension: [String: [String]] = [:]) { self.valuesByDimension = valuesByDimension }

    public var isEmpty: Bool { valuesByDimension.values.allSatisfy(\.isEmpty) }

    public var totalCount: Int { valuesByDimension.values.reduce(0) { $0 + $1.count } }

    /// 已选中的维度名（先按 `layout` 顺序，词表外的未知维度名再按字典序补在后面）。
    ///
    /// `legalOnly` 决定要不要过 `TrackListQuery.isLegalDimensionName`：**发请求**那一路必须过
    /// （维度名直接当查询键，`a=b&c` 能把整条查询改写出第二套语义 —— 注入面，E3a 同源），
    /// 而**画 chips** 那一路不能过：一个用户已经选上的值如果在屏上消失了，他就再也点不掉它。
    public func activeDimensions(legalOnly: Bool = true) -> [String] {
        let order = LibraryFilterSchema.layout.map(\.id)
        func legal(_ name: String) -> Bool { !legalOnly || TrackListQuery.isLegalDimensionName(name) }
        let known = order.filter { legal($0) && !values($0).isEmpty }
        let unknown = valuesByDimension.keys
            .filter { !order.contains($0) && legal($0) && !values($0).isEmpty }
            .sorted()
        return known + unknown
    }

    public var activeDimensions: [String] { activeDimensions(legalOnly: true) }

    public func values(_ dimension: String) -> [String] { valuesByDimension[dimension] ?? [] }

    public func count(in dimension: String) -> Int { values(dimension).count }

    public func isSelected(dimension: String, value: String) -> Bool { values(dimension).contains(value) }

    @discardableResult
    public mutating func toggle(dimension: String, value: String) -> LibraryFilterToggleOutcome {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        var current = values(dimension)
        if let at = current.firstIndex(of: trimmed) {
            current.remove(at: at)
        } else {
            guard current.count < Self.maxValuesPerDimension else { return .rejectedByLimit }
            current.append(trimmed)
        }
        valuesByDimension[dimension] = current.isEmpty ? nil : current
        return current.contains(trimmed) ? .added : .removed
    }

    /// chips 行的一个条目（§1「咖啡馆 ✕」）。值本身就够人读（词表值 = label），
    /// 维度名另给一个字段，供 UI 在两个维度撞词时区分。
    public struct Chip: Equatable, Hashable, Sendable {
        public let dimension: String
        public let dimensionTitle: String
        public let value: String
    }

    /// 已选 chips（§1）：按 `activeDimensions` 顺序展开，供「已选：…」行逐个移除。
    public func chips() -> [Chip] {
        let titled = Dictionary(
            uniqueKeysWithValues: LibraryFilterSchema.layout.map { ($0.id, $0.title) }
        )
        return activeDimensions(legalOnly: false).flatMap { name in
            values(name).map { value in
                Chip(dimension: name, dimensionTitle: titled[name] ?? name, value: value)
            }
        }
    }

    public mutating func remove(dimension: String, value: String) {
        var current = values(dimension)
        current.removeAll { $0 == value }
        valuesByDimension[dimension] = current.isEmpty ? nil : current
    }

    public mutating func clear(dimension: String) { valuesByDimension[dimension] = nil }

    public mutating func clearAll() { valuesByDimension = [:] }

    /// 合并进一组预置值（03 §7 的预填；同名维度合并去重，保留已有顺序，超上限即停）。
    public mutating func merge(_ preset: [String: [String]]) {
        outer: for (dimension, raw) in preset {
            var current = values(dimension)
            for value in TrackListQuery.sanitizedValues(raw) where !current.contains(value) {
                guard current.count < Self.maxValuesPerDimension else { break outer }
                current.append(value)
            }
            valuesByDimension[dimension] = current.isEmpty ? nil : current
        }
    }

    /// 从已有编码反解选择态（"URL 就是筛选状态"这条不变量的另一头）。
    ///
    /// 存在的理由不是好看：`/api/tracks` 的筛选**全部在 query 里**，所以任何一处把 URL 交回
    /// UI（深链、04 抽屉「曲库」入口回显、将来的分享链接）都需要这一条腿。不认识的名字一律
    /// 忽略（分页/排序键不该进选择态），认识的维度按 `layout` 顺序归位。
    public static func decode(queryItems: [URLQueryItem]) -> LibraryFilterSelection {
        let known = Set(LibraryFilterSchema.layout.map(\.id))
        var storage: [String: [String]] = [:]
        for item in queryItems {
            let name = item.name
            guard known.contains(name), let raw = item.value else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !(storage[name] ?? []).contains(value) else { continue }
            guard (storage[name] ?? []).count < maxValuesPerDimension else { continue }
            storage[name, default: []].append(value)
        }
        return LibraryFilterSelection(valuesByDimension: storage)
    }

    /// 03 §1/§2/§5 的完整查询编码（跨维度多选 + 搜索 + 排序 + 分页）。
    ///
    /// 编码沿 E3a 的实测口径：分页两键恒发、`search=<文本>`、维度名就是参数名、
    /// 维度内多选 = 重复同名参数。合法性门槛复用 `TrackListQuery.isLegalDimensionName`
    /// ——维度名直接当查询键，`a=b&c` 这种名字能把整条查询改写出第二套语义（注入面）。
    ///
    /// 排序**恒发** `sort=`：不发的话「推荐」和「最新」在服务端是同一档（默认即 newest），
    /// 屏上就会摆出两个做了同一件事的选项。
    public func queryItems(
        search: String?, sort: LibrarySort, artistID: String? = nil,
        page: Int = 1, pageSize: Int = 20
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let artistID = LibraryFilterSchema.trimmed(artistID) {
            items.append(URLQueryItem(name: "artistId", value: artistID))
        }
        if let search = LibraryFilterSchema.trimmed(search) {
            items.append(URLQueryItem(name: "search", value: search))
        }
        items.append(URLQueryItem(name: "sort", value: sort.queryValue))
        for dimension in activeDimensions {
            guard TrackListQuery.isLegalDimensionName(dimension) else { continue }
            for value in TrackListQuery.sanitizedValues(values(dimension)) {
                items.append(URLQueryItem(name: dimension, value: value))
            }
        }
        return items
    }
}

extension LibraryFilterSchema {
    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - 结果计数（03 §1「共 1,248 首」）

/// 结果计数文案。分组符按千位**手工**加（不走 `NumberFormatter`/locale）：
/// 这一行要在断言里钉死，而 locale 不是本 App 的输出契约。
public enum LibraryResultCount {
    public static func text(total: Int?) -> String? {
        guard let total, total >= 0 else { return nil }
        return "共 \(grouped(total)) 首"
    }

    public static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard value >= 0, digits.count > 3 else { return digits }
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }
}
