import Foundation

// MARK: - 制作人模式（P2 入口）
//
// 契约事实源：DEVELOPMENT.md §4.6 + §4.7「producers」，2026-09-26 生产只读实测。
// 一条今天就把这整屏钉住的事实：**生产环境这个功能是关的**
// （`PRODUCER_MODE` 未设 + `NODE_ENV=production` ⇒ 灰度关闭 ⇒ 恒回 `{producers:[]}`，限流 120/时）。
// 于是 §6 A10 那条判据（"灰度账号返回非空 ⇒ 出现制作人卡"）在普通账号上只能验到**后半句**
// （空 ⇒ 入口不可见），前半句要一个灰度账号 —— 这不是客户端能补的腿（硬边界 7）。
//
// 后半句才是本文件的承重设计：**「空」与「解不出来」必须是两件事**。
// UI 规则是「空 ⇒ 隐藏入口」而不是「置灰」，更不是「读不懂 ⇒ 当没有」。
// 所以 `producers` 这个键**严解**（缺键 / null / 不是数组 ⇒ 抛错），
// 而数组**元素**逐条宽松解（一条坏卡不连累同批其它卡，读不出的计入 `unreadableItemCount`）。
//
// 嵌套数组一律按 `[Element?]` 解再 `compactMap`：Swift 的数组解码遇到元素 `null` 会在
// **调用元素 init 之前**就抛 ⇒ 一个 `null` 能把整份列表判死。元素类型给成 Optional
// 就把那一格也收进"这一张卡少一节"的局部容忍里，而不是"整个功能没有"。

/// 卡内小节元素的可丢弃判据：一个字段都没读出来的元素不算一项内容。
protocol ProducerSectionElement {
    var hasAnyContent: Bool { get }
}

/// 一个制作人卡的一段舞台（`stages[]`）。
public struct ProducerStageDto: Decodable, Equatable, Sendable, ProducerSectionElement {
    public let id: String?
    public let label: String?
    public let summary: String?

    enum CodingKeys: String, CodingKey { case id, label, summary }

    /// **永不抛**：这一节坏形状只让它自己空掉，不判整张卡、更不判整份列表。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        summary = (try? container?.decodeIfPresent(String.self, forKey: .summary)) ?? nil
    }

    public var hasAnyContent: Bool {
        id != nil || label != nil || summary != nil
    }
}

/// 交付物一项（`deliverables[]`）。
public struct ProducerDeliverableDto: Decodable, Equatable, Sendable, ProducerSectionElement {
    /// 原始拼写（`kind` 是它的分类视图，两者都不丢信息）。
    public let rawKind: String?
    public let label: String?
    /// ⚠️ 可为 `nil` = 服务端没给 / 读不出。**不填 `false`**：`false` 是一句"这项不必须"的断言，
    /// 而客户端没有资格在服务端没说话的时候替它说。
    public let required: Bool?
    public let description: String?

    enum CodingKeys: String, CodingKey { case kind, label, required, description }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        rawKind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        required = (try? container?.decodeIfPresent(Bool.self, forKey: .required)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
    }

    /// 交付物类型（词表外的新值原样留在 `.unknown`，不折成别的假值）。
    public var kind: ProducerDeliverableKind? {
        rawKind.map(ProducerDeliverableKind.init(rawKind:))
    }

    /// 展示名：服务端 `label` 原文；空白按"没给"处理（**不**拿 `kind` 编一个名字上屏）。
    public var displayLabel: String? { WorksListQuery.textIfPresent(label) }

    public var hasAnyContent: Bool {
        rawKind != nil || label != nil || required != nil || description != nil
    }
}

/// `deliverables[].kind` 的闭集 8 值 + `.unknown(原拼写)`。
///
/// 为什么带 `.unknown`：这是**产品词表**，服务端加一档是正常的，而"加一档就让整张卡消失"不是
/// （用户已经在看的卡不该因为客户端词表版本旧而不见）。同 `CovaSSEEventType` / `CreditLedgerReason`。
public enum ProducerDeliverableKind: Equatable, Sendable {
    case masterMp3
    case masterWav
    case instrumentalMp3
    case instrumentalWav
    case copyrightCertificate
    case singerAuthorization
    case stemsZip
    case styleRemix
    case unknown(String)

    static let knownRawKinds: [String: ProducerDeliverableKind] = [
        "master_mp3": .masterMp3,
        "master_wav": .masterWav,
        "instrumental_mp3": .instrumentalMp3,
        "instrumental_wav": .instrumentalWav,
        "copyright_certificate": .copyrightCertificate,
        "singer_authorization": .singerAuthorization,
        "stems_zip": .stemsZip,
        "style_remix": .styleRemix,
    ]

    public init(rawKind: String) {
        self = ProducerDeliverableKind.knownRawKinds[rawKind] ?? .unknown(rawKind)
    }

    /// 线格式原拼写（`.unknown` 回吐服务端那个词，一个字都不改）。
    public var rawKind: String {
        switch self {
        case .masterMp3: return "master_mp3"
        case .masterWav: return "master_wav"
        case .instrumentalMp3: return "instrumental_mp3"
        case .instrumentalWav: return "instrumental_wav"
        case .copyrightCertificate: return "copyright_certificate"
        case .singerAuthorization: return "singer_authorization"
        case .stemsZip: return "stems_zip"
        case .styleRemix: return "style_remix"
        case .unknown(let raw): return raw
        }
    }

    /// 音频那一族（母带/伴奏/分轨包）与条款那一族（版权证明/歌手授权）的分组判据。
    ///
    /// 只做**分类**：条款文案、授权流程、能不能出现入口都由合规评审决定（硬边界 9 D12），
    /// 本层不认识"能不能卖"这种问题。
    public var isAuthorizationBearing: Bool {
        switch self {
        case .copyrightCertificate, .singerAuthorization: return true
        default: return false
        }
    }
}

/// 一项扩展能力（`extensions[]`）。
public struct ProducerExtensionDto: Decodable, Equatable, Sendable, ProducerSectionElement {
    public let id: String?
    public let label: String?
    public let description: String?
    /// 同 `required`：`nil` 是"没给"，**不是**"关着"。
    public let enabled: Bool?

    enum CodingKeys: String, CodingKey { case id, label, description, enabled }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
        enabled = (try? container?.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
    }

    /// 只有服务端明确说 `true` 才算开着（`nil`/`false` 都不开 —— 但两者在屏上应当不同：
    /// `nil` 是没给状态，`false` 是给了"关"）。
    public var isEnabled: Bool { enabled == true }
    public var hasState: Bool { enabled != nil }

    public var hasAnyContent: Bool {
        id != nil || label != nil || description != nil || enabled != nil
    }
}

/// 一张制作人卡（`producers[]` 的元素）。
///
/// 键集实测**逐字**就是这些：`id / displayName / fictional / tagline / audience / greeting /
/// stages[] / deliverables[] / extensions[] / demoCount / cardCount`。
///
/// 除 `id` 之外一律可选，且**缺键就是 `nil`**：
/// `demoCount` / `cardCount` 不填 0（那是"这个制作人没有演示/没有卡"的断言），
/// `fictional` 不填 false（那会抹掉"虚构"标注，而虚构/真实正是这一屏的合规边界）。
///
/// 本类型**仅 Decodable**：卡里虽然没有凭证，但"把服务端投影序列化回磁盘当本地事实源"
/// 是本仓反复登记的缺陷族 —— 灰度一关，本地那份还在，入口就凭空出现。
public struct ProducerCardDto: Decodable, Equatable, Sendable {
    /// 卡片身份。**空串 = 读不出身份**（由 `ProducersResponseDto` 计成不可读并丢掉这一张）。
    public let id: String
    public let displayName: String?
    public let fictional: Bool?
    public let tagline: String?
    public let audience: String?
    public let greeting: String?
    public let stages: [ProducerStageDto]
    public let deliverables: [ProducerDeliverableDto]
    public let extensions: [ProducerExtensionDto]
    public let demoCount: Int?
    public let cardCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, displayName, fictional, tagline, audience, greeting
        case stages, deliverables, extensions, demoCount, cardCount
    }

    /// 显式成员初始化（有 `init(from:)` 就没有合成 memberwise；给出来让测试能从模块外造一张卡）。
    public init(
        id: String, displayName: String? = nil, fictional: Bool? = nil, tagline: String? = nil,
        audience: String? = nil, greeting: String? = nil, stages: [ProducerStageDto] = [],
        deliverables: [ProducerDeliverableDto] = [], extensions: [ProducerExtensionDto] = [],
        demoCount: Int? = nil, cardCount: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fictional = fictional
        self.tagline = tagline
        self.audience = audience
        self.greeting = greeting
        self.stages = stages
        self.deliverables = deliverables
        self.extensions = extensions
        self.demoCount = demoCount
        self.cardCount = cardCount
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? ""
        displayName = (try? container?.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        fictional = (try? container?.decodeIfPresent(Bool.self, forKey: .fictional)) ?? nil
        tagline = (try? container?.decodeIfPresent(String.self, forKey: .tagline)) ?? nil
        audience = (try? container?.decodeIfPresent(String.self, forKey: .audience)) ?? nil
        greeting = (try? container?.decodeIfPresent(String.self, forKey: .greeting)) ?? nil
        stages = Self.optionalArray(container, .stages)
        deliverables = Self.optionalArray(container, .deliverables)
        extensions = Self.optionalArray(container, .extensions)
        demoCount = (try? container?.decodeIfPresent(Int.self, forKey: .demoCount)) ?? nil
        cardCount = (try? container?.decodeIfPresent(Int.self, forKey: .cardCount)) ?? nil
    }

    /// 「元素可以是 null」的数组读法 + 丢掉**一个字段都没读出来**的元素。
    ///
    /// 两条都要，各治一种坏法：
    /// · `[Element?]`：Swift 的数组解码遇到元素 `null` 会在调元素 init **之前**就抛 ⇒
    ///   不这么写的话，一个小节里的一个 null 就能让整张卡、甚至整份列表消失；
    /// · 丢空元素：非对象元素（字符串/数字）在"永不抛"的 init 下会变成一个全 nil 的壳，
    ///   留着它就是给 UI 一个空白行（"这个制作人有个空交付项"是一句假话）。
    ///   代价说清楚：那一条被丢掉的元素**不计数** —— 卡内小节没有身份字段可数，
    ///   而"这一节少一项"不许升级成"这张卡读不懂"（整张卡的可见性比那一格重要）。
    static func optionalArray<Element: Decodable & ProducerSectionElement>(
        _ container: KeyedDecodingContainer<CodingKeys>?, _ key: CodingKeys
    ) -> [Element] {
        let raw = (try? container?.decodeIfPresent([Element?].self, forKey: key)) ?? nil
        return (raw ?? []).compactMap { element in
            guard let element, element.hasAnyContent else { return nil }
            return element
        }
    }

    /// 展示名：`displayName` 原文；空白按"没给"处理（**不**回落 `id` —— 把内部 id 印上屏
    /// 是 A15 那一类脏）。
    public var displayTitle: String? { WorksListQuery.textIfPresent(displayName) }

    /// 「是否虚构」拿不拿得出来（拿不出来时 UI 不许默认成"真实制作人"）。
    public var hasFictionalFlag: Bool { fictional != nil }

    /// 必须交付的那几项（`required == true`）。`nil`（没给）不计入 —— 它不等于"不必必须"。
    public var requiredDeliverables: [ProducerDeliverableDto] {
        deliverables.filter { $0.required == true }
    }

    /// 涉及授权条款的交付项（版权证明 / 歌手授权）。渲染它们的入口要先过合规评审（D12）。
    public var authorizationDeliverables: [ProducerDeliverableDto] {
        deliverables.filter { $0.kind?.isAuthorizationBearing == true }
    }
}

/// `GET /api/studio/producers` 的响应 `{producers:[ProducerCard]}`。
///
/// ## 空列表与解码失败是两件事，这条写在结构上
/// · `{producers:[]}` ⇒ `isDefinitivelyEmpty == true` ⇒ **隐藏入口**（A10 那句"不是置灰"就是
///   这一格：灰着的入口在暗示"有但你用不了"，而真相是"没有"）；
/// · `{}` / `{producers:null}` / `{producers:"..."}` / 根本不是对象 ⇒ **抛错**
///   （`CovaAPIClient` 归一成 `CovaAPIError.decoding`），**绝不**静默降级成空列表 ——
///   那会把"契约漂了"伪装成"这个账号没有制作人"，而这两句在屏上是完全不同的两句
///   （与 `StudioSessionDTOTests` 钉的那条「一个都接不上必须报错，而不是静默当空列表」同源）；
/// · `{producers:[读不出的卡]}` ⇒ 列表空但 `unreadableItemCount > 0` ⇒ **不隐藏**，那是读不懂。
public struct ProducersResponseDto: Decodable, Equatable, Sendable {
    /// 端点路径（只读 GET，可直连生产；§4.6 限流 120/时）。
    public static let path = "/api/studio/producers"

    public let producers: [ProducerCardDto]
    /// `producers` 数组里读不出身份（非对象 / `null` 元素 / 无 `id` / `id` 空串）的元素个数。
    public let unreadableItemCount: Int

    enum CodingKeys: String, CodingKey { case producers }

    public init(producers: [ProducerCardDto], unreadableItemCount: Int) {
        self.producers = producers
        self.unreadableItemCount = unreadableItemCount
    }

    public init(from decoder: Decoder) throws {
        // 根不是对象 ⇒ 抛（"这根本不是一份 producers 响应"）。
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // **严解数组本身**：缺键 / null / 非数组都抛，不折成空列表。
        let wire = try root.decode([ProducerCardDto?].self, forKey: .producers)
        var cards: [ProducerCardDto] = []
        var unreadable = 0
        cards.reserveCapacity(wire.count)
        for element in wire {
            guard let card = element, !card.id.isEmpty else {
                unreadable += 1
                continue
            }
            cards.append(card)
        }
        producers = cards
        unreadableItemCount = unreadable
    }

    /// 服务端明确给了零张（灰度关闭 / 这个账号没有可见制作人）。
    public var isDefinitivelyEmpty: Bool { producers.isEmpty && unreadableItemCount == 0 }

    /// 入口该不该不渲染。`unreadableItemCount > 0` 时**不隐藏**（读不懂不是"没有"）。
    public var shouldHideEntrance: Bool { isDefinitivelyEmpty }

    /// `fictional` 没给的卡（既不算真实也不算虚构，UI 得单独处理那一格标注）。
    public var producersWithUnknownFictional: [ProducerCardDto] {
        producers.filter { !$0.hasFictionalFlag }
    }
}
