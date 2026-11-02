import Foundation

/// `GET /api/lyria/models` 的响应（COVA-20261024-003 R1）。
///
/// 服务端权威形态（`多端/web/src/app/api/lyria/models/route.ts`）：
/// `{ enabled, models, source }`，其中
/// · `enabled` = `COVA_LYRIA_ENABLED` 开关；false 时前端**隐藏 Lyria 分组**；
/// · `models` 已由服务端归一化（`cova-lyria.ts:163 normalizeLyriaModels`）：
///   非法 id 丢弃、`label` 缺省回退 id、`desc` 缺省「Lyria 生成通道」、无 isDefault 时首行补 true；
/// · `source` ∈ `live`/`fallback`/`cache`，**服务端自己的**缓存标记，不是客户端的。
///
/// 纪律（R1）：客户端**不硬编码清单、不重排**——服务端给什么顺序就什么顺序。
/// 本类型只做容错解码，不做任何语义改写。
public struct LyriaModelsResponseDTO: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let models: [LyriaModelOptionDTO]
    /// 服务端清单来源（`live`/`fallback`/`cache`）。缺失按 nil，不猜。
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case enabled, models, source
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // `enabled` 缺失 ⇒ 按未开放处理（与 web CreatePanel 的 `!data?.enabled` 隐藏同口径）：
        // 不能因为字段缺失就把 Lyria 分组放出来，那是"猜服务端已经开放"。
        enabled = ((try? root.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        let list = ((try? root.decodeIfPresent([LyriaModelOptionDTO].self, forKey: .models)) ?? nil) ?? []
        models = list
        let raw = ((try? root.decodeIfPresent(String.self, forKey: .source)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        source = (raw?.isEmpty == false) ? raw : nil
    }

    public init(enabled: Bool, models: [LyriaModelOptionDTO], source: String? = nil) {
        self.enabled = enabled
        self.models = models
        self.source = source
    }
}

/// 单个 Lyria 模型行。字段全部容错可空——服务端归一化后 `id` 必然非空，
/// 但客户端仍按"能读到就用"处理，读不到的行走 `LyriaModelCatalog.sanitize` 丢弃。
public struct LyriaModelOptionDTO: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let desc: String?
    public let isDefault: Bool

    public init(id: String, label: String, desc: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.desc = desc
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case id, label, desc, displayName, isDefault
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        // `id` 是唯一承重字段：空白即视为无效行，由上层过滤（这里给空串，不抛）。
        let rawID = ((try? root.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        // label 缺省回退 id（web normalizeLyriaModels 同款），displayName 也认。
        let rawLabel = ((try? root.decodeIfPresent(String.self, forKey: .label)) ?? nil)
            ?? ((try? root.decodeIfPresent(String.self, forKey: .displayName)) ?? nil)
        let trimmedLabel = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label = trimmedLabel.isEmpty ? id : trimmedLabel
        let rawDesc = ((try? root.decodeIfPresent(String.self, forKey: .desc)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        desc = (rawDesc?.isEmpty == false) ? rawDesc : nil
        isDefault = ((try? root.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? nil) ?? false
    }
}

/// 客户端侧「可渲染的 Lyria 清单」+ 新鲜度（R1 的四条要求在这里收口）。
///
/// 与 `LyriaModelsResponseDTO` 的分工：DTO 是**线格式**，本类型是**屏上事实**。
/// 后者多出三件线格式没有的东西：
/// 1. `isEmpty` —— 空列表要显示「可重试」提示，而不是空白；
/// 2. `isStale` —— 「请求失败回退上次成功结果并标**可能过期**」的那面旗；
/// 3. 保序校验 —— 服务端给什么顺序就是什么顺序，本类型**不排序**。
public struct LyriaModelCatalog: Equatable, Sendable {
    /// 可渲染的模型行（已丢弃非法行；顺序 = 服务端顺序）。
    public let models: [LyriaModelOptionDTO]
    /// 服务端说 Lyria 未开放（`enabled=false`）⇒ 整组隐藏。
    public let enabled: Bool
    /// 本份清单是否来自「上一次成功结果」而非本次实时拉取（失败回退）。
    public let isStale: Bool
    /// 服务端 source（`live`/`fallback`/`cache`），仅诊断用。
    public let source: String?

    public init(
        models: [LyriaModelOptionDTO],
        enabled: Bool,
        isStale: Bool = false,
        source: String? = nil
    ) {
        self.models = models
        self.enabled = enabled
        self.isStale = isStale
        self.source = source
    }

    /// R1：空列表要显示**可操作提示**（可重试）。分组可见但没有任何模型行 ⇒ true。
    public var showsEmptyRetryHint: Bool { enabled && models.isEmpty }

    /// 默认可选中的模型 id（`isDefault` 那条；没有则首行；空清单 nil）。
    public var defaultModelID: String? {
        models.first(where: \.isDefault)?.id ?? models.first?.id
    }

    /// 丢非法行的唯一入口（`id` 空白的行不渲染——渲染出来就是一个选不中的空按钮）。
    ///
    /// ⚠ 这里**同时做裁剪**：解码路径已在 `init(from:)` 裁过一次，但便利构造器
    /// `init(id:label:)` 不裁（它接受什么就存什么）⇒ 两条构造路径的"算不算空白"
    /// 必须在**这一个入口**上一致，否则「手搓的空白 id」会漏进模型清单。
    public static func sanitize(_ list: [LyriaModelOptionDTO]) -> [LyriaModelOptionDTO] {
        list.compactMap { option -> LyriaModelOptionDTO? in
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return LyriaModelOptionDTO(
                id: id,
                label: option.label,
                desc: option.desc,
                isDefault: option.isDefault
            )
        }
    }
}

/// R1 的缓存纪律：**内存缓存 ≤60s**，失败回退上次成功结果并标「可能过期」。
///
/// 纯值类型 + 注入时钟，于是「第 61 秒该不该重拉」「失败后是不是回退了上一次」
/// 都能不依赖真实时间断言（与本仓 `StudioCreatePollSchedule` 同一套做法）。
public struct LyriaModelCache: Equatable, Sendable {
    /// 契约上限 60s。以契约值为默认，不允许调用方随手放大。
    public static let maximumAgeSeconds: TimeInterval = 60

    public let maximumAge: TimeInterval
    /// 上一次**成功**的清单（失败回退的唯一来源）。
    public private(set) var lastSuccess: LyriaModelCatalog?
    /// 上次成功的时刻（`nil` = 从未成功过）。
    public private(set) var lastSuccessAt: Date?

    public init(maximumAge: TimeInterval = LyriaModelCache.maximumAgeSeconds) {
        // 钳制：负值/0 会让每一次读都判过期；大于契约 60s 等于自行放宽契约。
        self.maximumAge = min(max(maximumAge, 0), LyriaModelCache.maximumAgeSeconds)
    }

    /// 本份缓存是否还在有效期内（`unknown` = 从未成功 ⇒ 必须去拉）。
    public func isFresh(now: Date) -> Bool {
        guard let at = lastSuccessAt else { return false }
        let age = now.timeIntervalSince(at)
        // 时钟回拨（age < 0）按**不新鲜**处理：宁可多拉一次，也不拿未来时刻的缓存充数。
        return age >= 0 && age < maximumAge
    }

    /// 仍在有效期内则返回缓存（`source` 改写为 `cache`，标明这是缓存给的）。
    public func cached(now: Date) -> LyriaModelCatalog? {
        guard isFresh(now: now), let lastSuccess else { return nil }
        return LyriaModelCatalog(
            models: lastSuccess.models,
            enabled: lastSuccess.enabled,
            isStale: false,
            source: "cache"
        )
    }

    /// 记一次成功。
    public mutating func record(_ catalog: LyriaModelCatalog, now: Date) {
        let clean = LyriaModelCatalog(
            models: LyriaModelCatalog.sanitize(catalog.models),
            enabled: catalog.enabled,
            isStale: false,
            source: catalog.source
        )
        lastSuccess = clean
        lastSuccessAt = now
    }

    /// 请求失败时的回退：有上次成功 ⇒ 回它并标 `isStale=true`；从未成功过 ⇒ nil
    /// （调用方渲染「空 + 可重试」，**不要**自己编一份清单）。
    ///
    /// ⚠ 这里与 web 侧有一处**有意不同**：web 的 `fetchLyriaModels` 失败时回落到
    /// 静态常量 `LYRIA_MODELS_FALLBACK`（硬编码两条）。契约 R1 的原话是
    /// 「失败回退**上次成功结果**」，所以本端只回上次成功结果；从未成功过就给空，
    /// 由 UI 说「加载失败，点此重试」——**不硬编码清单**是 R1 的明文要求。
    public func fallback() -> LyriaModelCatalog? {
        guard let lastSuccess else { return nil }
        return LyriaModelCatalog(
            models: lastSuccess.models,
            enabled: lastSuccess.enabled,
            isStale: true,
            source: lastSuccess.source
        )
    }
}
