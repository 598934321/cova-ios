import XCTest
@testable import CovaCore

/// COVA-20261024-003 R1：`GET /api/lyria/models` 的客户端侧判据。
///
/// 这组用例守的是契约里那四句**明文要求**（任何一句被改回去都要红）：
/// · 唯一来源（不硬编码清单）—— `testNoHardcodedModelsWhenNeverSucceeded`；
/// · 不重排 —— `testCatalogPreservesServerOrder`；
/// · 内存缓存 ≤60s —— `testCacheExpiresAtSixtySeconds` / `testMaximumAgeCannotExceedContract`；
/// · 失败回退上次成功并标「可能过期」—— `testFailureFallsBackToLastSuccessAsStale`；
/// · 空列表可重试提示 —— `testEmptyListShowsRetryHint`。
final class LyriaModelCatalogTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - 解码

    func testDecodesServerEnvelope() throws {
        let json = """
        {"enabled":true,"source":"live","models":[
          {"id":"Lyria 3.5","label":"Lyria 3.5","desc":"默认模型","isDefault":true},
          {"id":"Lyria 3 Pro","label":"Lyria 3 Pro","desc":"高音质分支","isDefault":false}
        ]}
        """
        let dto = try JSONDecoder().decode(LyriaModelsResponseDTO.self, from: Data(json.utf8))
        XCTAssertTrue(dto.enabled)
        XCTAssertEqual(dto.source, "live")
        XCTAssertEqual(dto.models.map(\.id), ["Lyria 3.5", "Lyria 3 Pro"])
        XCTAssertEqual(dto.models.first?.isDefault, true)
    }

    /// `enabled` 缺失 ⇒ 按未开放（不能让缺字段被读成"已开放"）。
    func testMissingEnabledDefaultsToFalse() throws {
        let json = #"{"models":[{"id":"Lyria 3.5"}]}"#
        let dto = try JSONDecoder().decode(LyriaModelsResponseDTO.self, from: Data(json.utf8))
        XCTAssertFalse(dto.enabled, "缺 enabled 不能猜成开放")
    }

    /// label 缺省回退 id；displayName 也认；desc 空白走 nil（不是空串）。
    func testTolerantRowDecoding() throws {
        let json = """
        {"enabled":true,"models":[
          {"id":"  Lyria X  "},
          {"id":"Lyria Y","displayName":"Y 展示名","desc":"   "}
        ]}
        """
        let dto = try JSONDecoder().decode(LyriaModelsResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.models[0].id, "Lyria X", "id 两侧空白裁掉")
        XCTAssertEqual(dto.models[0].label, "Lyria X", "label 缺省回退 id")
        XCTAssertEqual(dto.models[1].label, "Y 展示名", "displayName 也认")
        XCTAssertNil(dto.models[1].desc, "空白 desc 是 nil，不是空串")
    }

    // MARK: - R1：不硬编码清单

    /// 契约最硬的一条：**从未成功过时不许给清单**。
    ///
    /// web 侧 `fetchLyriaModels` 失败会回落静态常量 `LYRIA_MODELS_FALLBACK`（硬编码两条）；
    /// R1 的原话是「失败回退**上次成功结果**」。这条用例钉住本端不抄那份常量：
    /// 没成功过 ⇒ 空，由 UI 说「加载失败，点此重试」。
    func testNoHardcodedModelsWhenNeverSucceeded() {
        var cache = LyriaModelCache()
        XCTAssertNil(cache.fallback(), "从未成功过 ⇒ 不得凭空给一份清单")
        XCTAssertNil(cache.cached(now: base), "没有成功记录 ⇒ 无缓存")
        XCTAssertFalse(cache.isFresh(now: base))
    }

    // MARK: - R1：不重排

    func testCatalogPreservesServerOrder() {
        // 故意给一个**非字母序、非 isDefault 在前**的清单：任何排序都会让它变样。
        let models = [
            LyriaModelOptionDTO(id: "Lyria 3 Pro", label: "Pro", isDefault: false),
            LyriaModelOptionDTO(id: "Lyria 3.5", label: "3.5", isDefault: true),
            LyriaModelOptionDTO(id: "Lyria A", label: "A", isDefault: false),
        ]
        let catalog = LyriaModelCatalog(models: LyriaModelCatalog.sanitize(models), enabled: true)
        XCTAssertEqual(
            catalog.models.map(\.id), ["Lyria 3 Pro", "Lyria 3.5", "Lyria A"],
            "服务端给什么顺序就是什么顺序，客户端不重排"
        )
        XCTAssertEqual(catalog.defaultModelID, "Lyria 3.5", "默认项按 isDefault 找，不是取首行")
        XCTAssertEqual(catalog.models.count, 3)
    }

    /// 无 isDefault 时默认取首行（服务端通常已补，但客户端不因此崩）。
    func testDefaultFallsBackToFirstRow() {
        let catalog = LyriaModelCatalog(
            models: [LyriaModelOptionDTO(id: "A", label: "A"),
                     LyriaModelOptionDTO(id: "B", label: "B")],
            enabled: true
        )
        XCTAssertEqual(catalog.defaultModelID, "A")
        XCTAssertNil(LyriaModelCatalog(models: [], enabled: true).defaultModelID)
    }

    // MARK: - R1：空列表可重试提示

    func testEmptyListShowsRetryHint() {
        let empty = LyriaModelCatalog(models: [], enabled: true)
        XCTAssertTrue(empty.showsEmptyRetryHint, "开放但空 ⇒ 必须给可重试提示")
        XCTAssertFalse(
            LyriaModelCatalog(models: [], enabled: false).showsEmptyRetryHint,
            "未开放 ⇒ 整组隐藏，不是「空列表」"
        )
        XCTAssertFalse(
            LyriaModelCatalog(models: [LyriaModelOptionDTO(id: "A", label: "A")], enabled: true)
                .showsEmptyRetryHint,
            "有模型行 ⇒ 不需要重试提示"
        )
    }

    /// 空白 id 的行不渲染（渲染出来是一个选不中的空按钮）。
    func testSanitizeDropsBlankIDs() {
        let cleaned = LyriaModelCatalog.sanitize([
            LyriaModelOptionDTO(id: "", label: "空 id"),
            LyriaModelOptionDTO(id: "   ", label: "全空白"),
            LyriaModelOptionDTO(id: "Lyria 3.5", label: "好的一行"),
        ])
        XCTAssertEqual(cleaned.map(\.id), ["Lyria 3.5"])
    }

    // MARK: - R1：缓存 ≤60s

    func testCacheExpiresAtSixtySeconds() {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(
                models: [LyriaModelOptionDTO(id: "Lyria 3.5", label: "3.5")],
                enabled: true, source: "live"
            ),
            now: base
        )
        XCTAssertTrue(cache.isFresh(now: base), "刚记下就是新鲜的")
        XCTAssertNotNil(cache.cached(now: base.addingTimeInterval(59)))
        XCTAssertNil(cache.cached(now: base.addingTimeInterval(60)), "第 60 秒整过期（< 60 才算新鲜）")
        XCTAssertNil(cache.cached(now: base.addingTimeInterval(61)))
    }

    /// 缓存命中时 `source` 改写成 `cache`——屏上要能区分「这次是拉的」还是「缓存给的」。
    func testCacheHitRewritesSource() throws {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(
                models: [LyriaModelOptionDTO(id: "A", label: "A")],
                enabled: true, source: "live"
            ),
            now: base
        )
        let hit = try XCTUnwrap(cache.cached(now: base.addingTimeInterval(10)))
        XCTAssertEqual(hit.source, "cache")
        XCTAssertFalse(hit.isStale, "缓存命中不是「过期」——它还在 60s 内")
    }

    /// 契约上限是 60s：构造时传更大的值必须被钳回 60，不许自行放宽。
    func testMaximumAgeCannotExceedContract() {
        XCTAssertEqual(LyriaModelCache(maximumAge: 600).maximumAge, 60, "不许自行放大到 10 分钟")
        XCTAssertEqual(LyriaModelCache(maximumAge: -5).maximumAge, 0, "负值钳到 0")
        XCTAssertEqual(LyriaModelCache().maximumAge, 60, "默认就是契约值")
    }

    /// 时钟回拨不许把缓存读成"新鲜"（宁可多拉一次，也不拿未来时刻的缓存充数）。
    func testClockRollbackIsNotFresh() {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(models: [LyriaModelOptionDTO(id: "A", label: "A")], enabled: true),
            now: base
        )
        XCTAssertFalse(cache.isFresh(now: base.addingTimeInterval(-30)), "时钟回拨 ⇒ 判不新鲜")
        XCTAssertNil(cache.cached(now: base.addingTimeInterval(-30)))
    }

    // MARK: - R1：失败回退上次成功 + 标「可能过期」

    func testFailureFallsBackToLastSuccessAsStale() throws {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(
                models: [LyriaModelOptionDTO(id: "Lyria 3.5", label: "3.5")],
                enabled: true, source: "live"
            ),
            now: base
        )
        let fallback = try XCTUnwrap(cache.fallback())
        XCTAssertEqual(fallback.models.map(\.id), ["Lyria 3.5"], "回的是上次成功那份")
        XCTAssertTrue(fallback.isStale, "必须标「可能过期」")
        XCTAssertFalse(fallback.showsEmptyRetryHint, "有回退内容就不显示空列表提示")
    }

    /// 回退与缓存命中是**两件事**：过期后 `cached` 给 nil，`fallback` 仍给内容但标 stale。
    func testStaleFallbackIsDistinctFromCacheHit() throws {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(models: [LyriaModelOptionDTO(id: "A", label: "A")], enabled: true),
            now: base
        )
        let later = base.addingTimeInterval(120)
        XCTAssertNil(cache.cached(now: later), "120s 后缓存已过期")
        let stale = try XCTUnwrap(cache.fallback())
        XCTAssertTrue(stale.isStale, "但失败回退仍给上次成功结果，并标过期")
    }

    /// 记录成功时也要过一遍 sanitize（空白 id 不进缓存，免得缓存里攒垃圾）。
    func testRecordSanitizesAndClearsStale() {
        var cache = LyriaModelCache()
        cache.record(
            LyriaModelCatalog(
                models: [
                    LyriaModelOptionDTO(id: "", label: "坏行"),
                    LyriaModelOptionDTO(id: "A", label: "A"),
                ],
                enabled: true, isStale: true
            ),
            now: base
        )
        XCTAssertEqual(cache.lastSuccess?.models.map(\.id), ["A"], "缓存里不留空白 id")
        XCTAssertEqual(cache.lastSuccess?.isStale, false, "记成功即清 stale")
    }
}

/// COVA-20261024-003 R2：生成状态轮询退避（1/2/4/5s + 可见性暂停）。
final class GenerationPollBackoffTests: XCTestCase {

    func testContractBackoffPattern() {
        let backoff = GenerationPollBackoff()
        XCTAssertEqual(GenerationPollBackoff.contractPattern, [1, 2, 4, 5], "契约写死 1/2/4/5")
        XCTAssertEqual(backoff.interval(forAttempt: 0), 1, "0 基不是合法尝试号，给首项")
        XCTAssertEqual(backoff.interval(forAttempt: 1), 1)
        XCTAssertEqual(backoff.interval(forAttempt: 2), 2)
        XCTAssertEqual(backoff.interval(forAttempt: 3), 4)
        XCTAssertEqual(backoff.interval(forAttempt: 4), 5)
        XCTAssertEqual(backoff.interval(forAttempt: 5), 5, "第 4 次起封顶 5s")
        XCTAssertEqual(backoff.interval(forAttempt: 999), 5)

        XCTAssertEqual(backoff.elapsed(beforeAttempt: 1), 0)
        XCTAssertEqual(backoff.elapsed(beforeAttempt: 2), 1)
        XCTAssertEqual(backoff.elapsed(beforeAttempt: 3), 3)
        XCTAssertEqual(backoff.elapsed(beforeAttempt: 4), 7)
        XCTAssertEqual(backoff.elapsed(beforeAttempt: 5), 12)
    }

    func testCapStops() {
        let short = GenerationPollBackoff(maximumElapsed: 3)
        // 第 3 次之前已等 3s ⇒ 不满足 < 3。
        XCTAssertTrue(short.shouldPoll(attempt: 1))
        XCTAssertTrue(short.shouldPoll(attempt: 2))
        XCTAssertFalse(short.shouldPoll(attempt: 3))
        XCTAssertEqual(short.maximumAttemptCount, 2)
        XCTAssertFalse(short.shouldPoll(attempt: 0), "0 基不是合法尝试号")
    }

    /// 病态参数不许造出「忙等」或「永不轮询」。
    func testClampsDegeneratePattern() {
        XCTAssertEqual(
            GenerationPollBackoff(pattern: []).pattern,
            GenerationPollBackoff.contractPattern,
            "空序列退回契约序列"
        )
        XCTAssertEqual(
            GenerationPollBackoff(pattern: [0, -1]).pattern,
            GenerationPollBackoff.contractPattern,
            "全非正数退回契约序列（否则就是忙等）"
        )
        XCTAssertEqual(GenerationPollBackoff(maximumElapsed: -10).maximumElapsed, 0)
        XCTAssertFalse(GenerationPollBackoff(maximumElapsed: 0).shouldPoll(attempt: 1))
    }

    // MARK: - 可见性

    /// R2：页面不可见 ⇒ 暂停；恢复可见 ⇒ **立刻拉**，不吃退避。
    func testInvisiblePausesAndResumeFiresImmediately() {
        let backoff = GenerationPollBackoff()
        XCTAssertEqual(
            backoff.decide(attempt: 1, isVisible: false),
            .paused,
            "不可见不发"
        )
        XCTAssertEqual(
            backoff.decide(attempt: 3, isVisible: true, justBecameVisible: true),
            .fireNow,
            "恢复可见立刻拉，不等 4s"
        )
        XCTAssertEqual(
            backoff.decide(attempt: 3, isVisible: true, justBecameVisible: false),
            .wait(4),
            "可见但在途 ⇒ 按节拍等"
        )
    }

    /// 不可见期间的暂停**不吃掉**尝试号：恢复后仍从原来的节拍继续（这是调用方职责，
    /// 本类型只保证「restart attempt 是新的那次」）。
    func testPausedDoesNotAdvancePattern() {
        let backoff = GenerationPollBackoff()
        for attempt in 1...3 {
            XCTAssertEqual(backoff.decide(attempt: attempt, isVisible: false), .paused)
        }
        XCTAssertEqual(backoff.decide(attempt: 1, isVisible: true), .wait(1), "恢复后第 1 次仍是 1s")
    }

    /// 到上限时**优先报上限**，即使页面不可见——停就是停，不再说「暂停等恢复」。
    func testCapWinsOverVisibility() {
        let short = GenerationPollBackoff(maximumElapsed: 3)
        XCTAssertEqual(short.decide(attempt: 3, isVisible: false), .stoppedAtCap)
        XCTAssertEqual(short.decide(attempt: 3, isVisible: true), .stoppedAtCap)
        XCTAssertEqual(
            short.decide(attempt: 3, isVisible: true, justBecameVisible: true),
            .stoppedAtCap,
            "到上限后恢复可见也不补拍"
        )
    }
}

/// R2 可见性状态机：不可见暂停 / 恢复可见立刻补一拍 / 补拍不吃退避 / 抖动不重复补拍。
final class GenerationPollVisibilityTests: XCTestCase {

    func testColdStartIsVisibleWithoutResumePending() {
        let v = GenerationPollVisibility()
        XCTAssertTrue(v.isVisible, "冷启即前台")
        XCTAssertFalse(v.resumePending, "冷启不是「刚恢复」，不需要补拍")
        var mut = v
        XCTAssertFalse(mut.consumeResume(), "没有待消费的补拍")
    }

    func testHidingPauses() {
        var v = GenerationPollVisibility()
        XCTAssertFalse(v.update(isVisible: false), "转不可见不触发补拍")
        XCTAssertFalse(v.isVisible)
    }

    func testResumeFiresOneCatchUpShot() {
        var v = GenerationPollVisibility()
        v.update(isVisible: false)
        XCTAssertTrue(v.update(isVisible: true), "恢复可见 ⇒ 该立刻补一拍")
        XCTAssertTrue(v.resumePending)
        XCTAssertTrue(v.consumeResume(), "这一拍不吃退避")
        XCTAssertFalse(v.consumeResume(), "补拍只有一次")
    }

    /// 重复喂「可见」不许重复触发补拍（`scenePhase` 抖动不该多打网络）。
    func testRepeatedVisibleDoesNotRefire() {
        var v = GenerationPollVisibility()
        XCTAssertFalse(v.update(isVisible: true), "本来就是可见，不算恢复")
        XCTAssertFalse(v.update(isVisible: true))
        XCTAssertFalse(v.resumePending)
    }

    /// 补拍那一拍不推进尝试号：退避序列的进度不因切前台而重置。
    func testResumeDoesNotAdvanceAttempt() {
        XCTAssertTrue(GenerationPollVisibility.advancesAttempt(resumeConsumed: false))
        XCTAssertFalse(GenerationPollVisibility.advancesAttempt(resumeConsumed: true))
    }

    /// 不可见期间反复 update(false) 也不攒补拍；一次恢复只给一拍。
    func testRepeatedHideAccumulatesNothing() {
        var v = GenerationPollVisibility()
        for _ in 0..<5 { v.update(isVisible: false) }
        v.update(isVisible: true)
        XCTAssertTrue(v.consumeResume())
        XCTAssertFalse(v.consumeResume(), "五次隐藏不等于五次补拍")
    }
}
