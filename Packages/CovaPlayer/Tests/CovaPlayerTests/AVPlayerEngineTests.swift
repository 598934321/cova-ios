import XCTest
import AVFoundation
import CovaCore
import Foundation
@testable import CovaPlayer

/// `AVPlayer` 薄适配器的可测面：纯映射 + 零网络的生命周期（只用本地 `file://` 地址，绝不加载 https 条目）。
final class AVPlayerEngineTests: XCTestCase {
    private func missingFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cova-missing-\(UUID().uuidString).m4a")
    }

    private func localizedItem(_ url: URL, id: String = "local") -> PlaybackItem {
        TestItems.make(id, source: .localized(TestItems.fileURL(url.path)))
    }

    private func bearerItem() -> PlaybackItem {
        TestItems.make(
            "priv",
            source: .bearerRequired(TestItems.audioURL("/api/media/private/priv.m4a?sig=aa"))
        )
    }

    // MARK: - 纯映射

    /// 装载闸门的两条腿（MAJ-8 加固后的完整口径）：
    /// ① 需 Bearer 的一律拒绝（D7）；② `.publicDirect` 必须落在**唯一生产出口**上才可播。
    ///
    /// 「接受公开直链」这一腿的夹具主机从 `cdn.covalink.example` 换成了生产出口 ——
    /// 不是弱化：断言数量只增不减，且新增了三条拒绝腿（异主机 / 显式非规范端口 / 注入非法出口）。
    /// 全程零网络：这里断言的是纯映射结果，没有任何 `AVPlayerItem` 真的去装载这条地址。
    func testPlayableURLRefusesBearerItemsAndAcceptsDirectAndLocalized() {
        guard case .failure(let failure) = AVPlayerEngine.playableURL(for: bearerItem()) else {
            return XCTFail("需 Bearer 的条目不得被交给播放器（D7）")
        }
        XCTAssertEqual(failure.kind, .localizationRequired)
        XCTAssertFalse(failure.description.contains("sig"))
        XCTAssertFalse(failure.description.contains("Bearer"))

        guard case .success(let url) = AVPlayerEngine.playableURL(for: localizedItem(missingFileURL())) else {
            return XCTFail("已本地化条目应可直接播")
        }
        XCTAssertEqual(url.scheme, "file")

        guard case .success(let publicURL) = AVPlayerEngine.playableURL(for: TestItems.makeProduction()) else {
            return XCTFail("生产出口上的公开直链应可直接播")
        }
        XCTAssertEqual(publicURL.scheme, "https")
        XCTAssertTrue(CovaEnvironment.isProductionOrigin(publicURL))
        // MAJ-8：曾经零判定的那条路 —— 另一台主机的 https 直链照样 `.success`。
        let foreignHost = TestItems.make("cdn-other", source: .publicDirect(
            try! AudioURL(https: URL(string: "https://cdn-other.invalid/a.m4a")!)
        ))
        guard case .failure(let rejected) = AVPlayerEngine.playableURL(for: foreignHost) else {
            return XCTFail("MAJ-8：非生产出口的公开直链必须被拒绝（旧实现返回 .success）")
        }
        XCTAssertEqual(rejected.kind, .invalidSourceURL)
        XCTAssertFalse(
            rejected.description.contains("cdn-other"),
            "拒绝理由不得回显被拒主机：\(rejected.description)"
        )
        // 显式非规范端口不是生产出口（`isProductionOrigin` 已有判据，这里验的是引擎真的吃到它）。
        let oddPort = TestItems.make("port", source: .publicDirect(
            try! AudioURL(https: URL(string: "https://covalink.cn:8443/a.m4a")!)
        ))
        guard case .failure = AVPlayerEngine.playableURL(for: oddPort) else {
            return XCTFail("显式非 443 端口不得被当作生产出口")
        }
        // 注入的出口不能把判定放宽到别处（fail-closed 的第二重）。
        let injected = AVPlayerEngine(egressOrigin: URL(string: "https://cdn.covalink.example")!)
        let injectedOrigin = injected.currentEgressOrigin
        XCTAssertFalse(CovaEnvironment.isProductionOrigin(injectedOrigin), "前置：注入的是非法出口")
        guard case .failure = AVPlayerEngine.playableURL(for: TestItems.makeProduction(), egressOrigin: injectedOrigin) else {
            return XCTFail("MAJ-8：注入别的出口只会一律拒绝，绝不放宽到那台主机")
        }
        // 正向对照（TD-9）：规范端口的生产地址仍是同一台出口（min-2 的口径一致性）。
        let canonicalPort = TestItems.make("canonical", source: .publicDirect(
            try! AudioURL(https: URL(string: "https://covalink.cn:443/audio/one.m4a")!)
        ))
        guard case .success = AVPlayerEngine.playableURL(for: canonicalPort) else {
            return XCTFail("min-2：`:443` 与不带端口是同一台主机，不得误杀")
        }
    }

    /// MAJ-8：引擎侧的出口判定本身（纯函数穷举，零 AVPlayer）。
    func testEngineEgressJudgementTable() {
        let origin = CovaEnvironment.apiBaseURL
        func allowed(_ raw: String) -> Bool {
            guard let url = URL(string: raw) else { return false }
            return AVPlayerEngine.isAllowedEgress(url, origin: origin)
        }
        XCTAssertTrue(allowed("https://covalink.cn/api/media/one.m4a"))
        XCTAssertTrue(allowed("https://covalink.cn:443/api/media/one.m4a"), "min-2：规范端口同一台")
        XCTAssertTrue(allowed("https://covalink.cn/api/media/one.m4a?sig=deadbeef"), "签名查询不影响权威")
        XCTAssertFalse(allowed("https://cdn-other.invalid/a.m4a"))
        XCTAssertFalse(allowed("https://cdn.covalink.example/a.m4a"), "子域/别的域都不是出口")
        XCTAssertFalse(allowed("http://covalink.cn/a.m4a"), "降级到 http 不是出口")
        XCTAssertFalse(allowed("https://covalink.cn:8443/a.m4a"))
        XCTAssertFalse(allowed("https://user@covalink.cn/a.m4a"), "内嵌 userinfo 一律拒绝")
        XCTAssertFalse(allowed("file:///tmp/a.m4a"), "本地地址不走这条判定")
        // 注入非法出口 = 一律拒绝（绝不因此放宽）。
        XCTAssertFalse(AVPlayerEngine.isAllowedEgress(
            URL(string: "https://covalink.cn/a.m4a")!,
            origin: URL(string: "https://evil.invalid")!
        ))
        let engine = AVPlayerEngine()
        XCTAssertEqual(engine.currentEgressOrigin, CovaEnvironment.apiBaseURL, "默认出口就是生产出口")
    }

    func testTimeConversionRejectsIndefiniteInvalidAndNegative() {
        XCTAssertEqual(AVPlayerEngine.seconds(CMTime(seconds: 12.5, preferredTimescale: 1000)), 12.5)
        XCTAssertNil(AVPlayerEngine.seconds(.indefinite))
        XCTAssertNil(AVPlayerEngine.seconds(.invalid))
        // 实测工具链事实：CoreMedia 会把「NaN 秒」的 CMTime 归一成 value 0 的合法刻度，
        // `CMTimeGetSeconds` 返回 0.0 而非 NaN —— 因此这里不需要（也不可能）靠 isFinite 兜住它；
        // 真正的 NaN/无穷污染来自 .invalid / .indefinite（timescale 0 → 除法产生 NaN），已在上面覆盖。
        XCTAssertEqual(AVPlayerEngine.seconds(CMTime(seconds: .nan, preferredTimescale: 1000)), 0)
        XCTAssertNil(AVPlayerEngine.seconds(CMTime(seconds: -1, preferredTimescale: 1000)))
        XCTAssertEqual(AVPlayerEngine.seconds(AVPlayerEngine.time(12.5)), 12.5)
        XCTAssertEqual(AVPlayerEngine.time(.nan), .zero)
        XCTAssertEqual(AVPlayerEngine.time(-3), .zero)
        XCTAssertEqual(AVPlayerEngine.periodicTimeInterval, 0.5)
        XCTAssertEqual(AVPlayerEngine.observedKeyPathList, ["status", "playbackBufferEmpty", "playbackLikelyToKeepUp"])
    }

    func testStatusToEventMappingCoversEveryKnownState() {
        XCTAssertEqual(AVPlayerEngine.event(for: .readyToPlay), .playing)
        XCTAssertEqual(AVPlayerEngine.event(for: .unknown), .buffering)
        if case .failed(let failure)? = AVPlayerEngine.event(for: .failed) {
            XCTAssertEqual(failure.kind, .mediaInvalid)
        } else {
            XCTFail("failed 状态必须映射为 .failed 事件")
        }
    }

    // MARK: - 装载被拒绝（D7 第二道闸，零 KVO 零网络）

    func testLoadOfBearerItemEmitsFailureWithoutTouchingThePlayer() async {
        let engine = AVPlayerEngine()
        let collector = EventCollector()
        let pump = Task { await collector.consume(engine.events, until: .any, target: 1) }
        await engine.load(bearerItem())
        let arrived = await collector.waitFor(MatchingKind.any, target: 1)
        XCTAssertTrue(arrived, "被拒绝的装载必须上报 .failed")
        let events = await collector.all
        XCTAssertEqual(events, [.failed(PlayerFailure(kind: .localizationRequired, message: "私有音频必须先本地化再播放"))])
        let observers = engine.liveTimeObserverCount
        XCTAssertEqual(observers, 0, "被拒绝的装载不得挂上观察者")
        pump.cancel()
    }

    // MARK: - 生命周期（本地地址）

    func testLoadPlayPauseSeekPublishSyncEventsAndKeepObserverLedger() async {
        let engine = AVPlayerEngine()
        let collector = EventCollector()
        let pump = Task { await collector.consume(engine.events, until: .syncTransport, target: 3) }
        await engine.load(localizedItem(missingFileURL()))
        await engine.play()
        await engine.pause()
        let arrived = await collector.waitFor(.syncTransport, target: 3)
        XCTAssertTrue(arrived, "load/play/pause 必须各自同步上报一条传输事件")
        let kinds = await collector.syncKinds
        XCTAssertEqual(Set(kinds), Set([EventCollector.Kind.buffering, .playing, .paused]), "三种节拍事件都必须出现")

        await engine.seek(to: 3)
        await engine.seek(to: .nan)
        await engine.setRate(1.5)
        await engine.setRate(0)
        await engine.setRate(.nan)
        let rate = await engine.currentRate()
        XCTAssertTrue(rate.isFinite)
        let time = await engine.currentTime()
        XCTAssertTrue(time >= 0)
        let duration = await engine.currentDuration()
        XCTAssertTrue(duration == nil || (duration!.isFinite && duration! >= 0))

        let observers = engine.liveTimeObserverCount
        XCTAssertEqual(observers, 1)
        let notifications = engine.liveNotificationObserverCount
        XCTAssertEqual(notifications, 1)
        let keyValue = engine.liveKeyValueObserverCount
        XCTAssertEqual(keyValue, AVPlayerEngine.observedKeyPathList.count)

        engine.stopAndRelease()
        let afterTime = engine.liveTimeObserverCount
        XCTAssertEqual(afterTime, 0, "周期观察者必须摘掉（通知残留是本仓红线）")
        let afterNotification = engine.liveNotificationObserverCount
        XCTAssertEqual(afterNotification, 0)
        let afterKeyValue = engine.liveKeyValueObserverCount
        XCTAssertEqual(afterKeyValue, 0, "KVO 必须逐个移除")
        let releases = engine.releasedCount
        XCTAssertEqual(releases, 1)
        engine.stopAndRelease()
        let secondRelease = engine.releasedCount
        XCTAssertEqual(secondRelease, 2, "重复释放必须安全")
        pump.cancel()
    }

    func testReloadingDetachesPreviousItemObservers() async {
        let engine = AVPlayerEngine()
        let collector = EventCollector()
        let pump = Task { await collector.consume(engine.events, until: .any, target: 2) }
        await engine.load(localizedItem(missingFileURL(), id: "first"))
        await engine.load(localizedItem(missingFileURL(), id: "second"))
        let arrived = await collector.waitFor(.any, target: 2)
        XCTAssertTrue(arrived)
        let observers = engine.liveTimeObserverCount
        XCTAssertEqual(observers, 1, "换曲不得叠加周期观察者")
        let keyValue = engine.liveKeyValueObserverCount
        XCTAssertEqual(keyValue, AVPlayerEngine.observedKeyPathList.count, "旧 item 的 KVO 必须先移除")
        engine.stopAndRelease()
        pump.cancel()
    }

    func testRateAndTimeAreReadableWithoutAnyItem() async {
        let engine = AVPlayerEngine()
        await engine.seek(to: 5)
        // 新契约（第 13 轮 R13-1）：**空载且未要播**时 `setRate` 只记待用速率、不下发 ——
        // AVPlayer 的 `rate = x` 赋值会顺手起播，所以「暂停中/空载时改个速度」
        // 绝不能把引擎放响。待用值由 `play()` 落地时应用。
        await engine.setRate(2)
        let deferred = await engine.currentRate()
        XCTAssertEqual(deferred, 0, accuracy: 0.001, "空载且未要播时不得真的改引擎速率（改速 ≠ 起播）")
        let time = await engine.currentTime()
        XCTAssertGreaterThanOrEqual(time, 0)
        let duration = await engine.currentDuration()
        XCTAssertNil(duration, "无 item 时不得编造时长")
        engine.stopAndRelease()
    }

    // MARK: - 环 4 修复 R4：观测者事件的装载代际闸门（缺陷 P4）

    /// 闸门本身的规则表（纯状态机，零 AVFoundation）：代际 + 「同代至多一条 ended」。
    func testEventGateRuleTable() {
        var gate = EngineEventGate()
        XCTAssertEqual(gate.episode, 0, "从未装载 = 第 0 代")
        XCTAssertTrue(gate.isCurrent(0))
        XCTAssertFalse(gate.accepts(.ended, from: 9), "不存在的代际不得放行")

        let first = gate.advance()
        XCTAssertEqual(first, 1)
        XCTAssertTrue(gate.accepts(.position(seconds: 5), from: first))
        XCTAssertTrue(gate.accepts(.ended, from: first), "当代的第一条 ended 必须放行")
        XCTAssertFalse(gate.accepts(.ended, from: first), "同代重复 ended 必须丢弃")
        XCTAssertTrue(gate.accepts(.failed(PlayerFailure(kind: .network)), from: first), "非 ended 事件不受「一集一次」约束")

        let second = gate.advance()
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(gate.accepts(.ended, from: first), "已被取代的条目：任何事件都不得再进事件流")
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.accepts(.ended, from: second), "换件后重新起算：新代的 ended 必须放行")
        XCTAssertFalse(gate.accepts(.ended, from: second))
        XCTAssertEqual(gate.episode, second)
    }

    /// 生产适配器确实走这道闸门：迟到 / 重复的观测者回调根本进不了事件流。
    func testObserverDeliveriesAreGatedByLoadEpisode() async {
        let engine = AVPlayerEngine()
        let collector = EventCollector()
        let pump = Task { await collector.consume(engine.events, until: .any, target: 1) }

        await engine.load(localizedItem(missingFileURL(), id: "first"))
        let firstEpisode = engine.currentEpisode
        XCTAssertGreaterThan(firstEpisode, 0, "装载后代际必须已推进（观测者块捕获的就是它）")
        XCTAssertTrue(engine.deliverObserved(.ended, from: firstEpisode), "当代 ended 必须投递")
        XCTAssertFalse(engine.deliverObserved(.ended, from: firstEpisode), "同代重复 ended 必须丢弃")

        await engine.load(localizedItem(missingFileURL(), id: "second"))
        let secondEpisode = engine.currentEpisode
        XCTAssertNotEqual(secondEpisode, firstEpisode, "换件必须推进装载代际")
        XCTAssertFalse(engine.deliverObserved(.ended, from: firstEpisode), "上一件迟到的 ended 不得进事件流")
        XCTAssertFalse(
            engine.deliverObserved(.position(seconds: 12), from: firstEpisode),
            "上一件迟到的位置上报不得把新项的进度条挪走"
        )
        XCTAssertTrue(engine.deliverObserved(.ended, from: secondEpisode), "新件的播完是另一件事")

        engine.stopAndRelease()
        let releasedEpisode = engine.currentEpisode
        XCTAssertGreaterThan(releasedEpisode, secondEpisode, "释放同样推进代际（在途回调随之作废）")
        XCTAssertFalse(engine.deliverObserved(.ended, from: secondEpisode), "释放后的在途回调不得复活事件流")

        let arrived = await collector.waitFor(.any, target: 1)
        XCTAssertTrue(arrived, "被放行的当代事件必须真的到达事件流")
        let collected = await collector.all
        XCTAssertFalse(
            collected.contains { event in
                if case .position(let seconds) = event, seconds == 12 { return true }
                return false
            },
            "过期代际的位置上报不得出现在事件流里（deliverObserved 是观测者回调的唯一入口）"
        )
        pump.cancel()
    }

    /// 被拒绝的装载（D7 第二道闸）不推进代际：此时引擎里仍是上一件在播，其事件依然是事实。
    func testRejectedLoadKeepsPreviousEpisodeDeliverable() async {
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(missingFileURL(), id: "first"))
        let firstEpisode = engine.currentEpisode
        await engine.load(bearerItem())
        XCTAssertEqual(engine.currentEpisode, firstEpisode, "拒绝装载 = 没有换件，代际不得推进")
        XCTAssertTrue(
            engine.deliverObserved(.position(seconds: 7), from: firstEpisode),
            "上一件仍在引擎里，它的事件必须继续投递"
        )
        engine.stopAndRelease()
    }

    // MARK: - 环 4 修复 R5：就绪事件必须尊重播放意图（缺陷 M10）

    /// 纯映射穷举：`readyToPlay` / `likelyToKeepUp` 在「用户已暂停」时**不得**上报 `.playing`。
    func testReadinessMappingFollowsPlaybackIntent() {
        let ready = AVPlayerItem.Status.readyToPlay
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "playbackLikelyToKeepUp", status: ready, duration: .invalid, playing: true),
            [.playing], "正向对照：意图为在播时缓冲恢复照常说『在播』"
        )
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "playbackLikelyToKeepUp", status: ready, duration: .invalid, playing: false),
            [.paused], "M10：暂停后缓冲恢复不得翻回播放"
        )
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "status", status: ready, duration: .invalid, playing: false),
            [.paused], "M10：readyToPlay 同理"
        )
        let timed = CMTime(seconds: 42, preferredTimescale: 1000)
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "status", status: ready, duration: timed, playing: false),
            [.paused, .duration(seconds: 42)], "时长上报不受意图影响（它不是播放状态）"
        )
        // 非就绪类映射保持原口径（不得被本条修复顺带改掉）。
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "status", status: .unknown, duration: .invalid, playing: false),
            [.buffering]
        )
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "status", status: .failed, duration: .invalid, playing: true).count,
            1, "failed 只带一条事件"
        )
        XCTAssertEqual(
            AVPlayerEngine.observedEvents(forKeyPath: "playbackBufferEmpty", status: ready, duration: timed, playing: true),
            [.buffering]
        )
        XCTAssertTrue(
            AVPlayerEngine.observedEvents(forKeyPath: "bogusKeyPath", status: ready, duration: timed, playing: true).isEmpty
        )
        XCTAssertEqual(AVPlayerEngine.readinessEvent(playing: true), .playing)
        XCTAssertEqual(AVPlayerEngine.readinessEvent(playing: false), .paused)
    }

    /// 意图账本：`play()` 置真、`pause()` / 释放置真 → 假；KVO 分支读的就是它。
    func testPlaybackIntentIsTrackedAcrossPlayPauseAndRelease() async {
        let engine = AVPlayerEngine()
        XCTAssertFalse(engine.currentPlaybackIntent, "未起播前不得假设用户要听")
        await engine.load(localizedItem(missingFileURL(), id: "intent"))
        await engine.play()
        XCTAssertTrue(engine.currentPlaybackIntent)
        await engine.pause()
        XCTAssertFalse(engine.currentPlaybackIntent, "M10：显式暂停必须抹掉播放意图")
        await engine.play()
        XCTAssertTrue(engine.currentPlaybackIntent)
        engine.stopAndRelease()
        XCTAssertFalse(engine.currentPlaybackIntent, "释放后不存在任何在播意图（R14-2：同时作废待用速率）")
    }

    // MARK: - 环 4 · 第 19 批 R14-2：「改速 ≠ 起播」的**正向**半边与待用速率的生命周期
    //
    // 第 18 批只钉了负向一半（「暂停时空载改速不得真的改引擎」），正向一半
    // （「记下的待用速率必须在 `play()` 落地时应用到 player」）**零测试** ——
    // 而且它在空载夹具下根本测不到：`AVPlayer` 没有条目时不报非零速率，
    // 于是 `player.rate = Float(pending)` 那一行删掉也不会有任何断言变动（评审实测）。
    // 这三条都用**真资产**驱动：运行时写一段纯静音 WAV，经生产同一条
    // `.localized` + `file://` 路径装载（零网络、零第三方依赖、不落进 git）。

    /// 正向半边：未要播时改速 → 只记（`currentRate() == 0`）→ `play()` → 记下的速率真的生效。
    func testDeferredRateIsAppliedWhenPlaybackStarts() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(try SilentWAV.write(seconds: 1, stem: "apply", in: directory)))

        await engine.setRate(2)
        let deferred = await engine.currentRate()
        XCTAssertEqual(
            deferred, 0, accuracy: 0.001,
            "前置：真条目已装载、但引擎不「要播」时改速不得下发（改速 ≠ 起播，R13-1）"
        )

        await engine.play()
        let applied = await engine.currentRate()
        XCTAssertEqual(
            applied, 2, accuracy: 0.001,
            "R14-2 正向半边：待用速率必须在 play() 落地时真的写进 player（实测 \(applied)）"
        )
        XCTAssertTrue(engine.currentPlaybackIntent)
        engine.stopAndRelease()
    }

    /// 泄漏半边（评审实测的形状）：`pendingRate` 不得活过 `stopAndRelease()`。
    /// 释放之后引擎不再属于任何持有者，下一次 `play()` 必须从**默认速率**起，
    /// 而不是带着上一个持有者留在待用槽里的速率。
    ///
    /// 形状必须是「**先 pause 再改速**」：要播状态下 `setRate` 是当场下发的，槽里根本不留东西 ——
    /// 第 19 批第一版就写成了 `play() → setRate(2) → stopAndRelease() → play()`，
    /// m-release（拆掉 `markReleased` 里的清空）在全量 414 条里 **0 失败**，
    /// 那条断言当时是恒真的（评审实测的复现是 `pause → setRate → stopAndRelease → play`）。
    func testPendingRateDoesNotOutliveRelease() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(try SilentWAV.write(seconds: 1, stem: "release", in: directory)))
        await engine.play()
        await engine.pause()
        await engine.setRate(2)
        let deferred = await engine.currentRate()
        XCTAssertEqual(
            deferred, 0, accuracy: 0.001,
            "前置：暂停中改速只记待用槽（此刻槽里确实是 2.0，泄漏才有主语）"
        )

        engine.stopAndRelease()
        let released = await engine.currentRate()
        XCTAssertEqual(released, 0, accuracy: 0.001, "前置：释放即停声")
        // 刻意不再 load：结果只由 `stopAndRelease` 那一处的清空决定（换件清空见下一条）。
        await engine.play()
        let inherited = await engine.currentRate()
        XCTAssertLessThan(
            inherited, 1.5,
            "R14-2：已释放、无条目的引擎不得被下一个持有者以上一个持有者的速率（2.0）启动；"
                + "默认侧的读数（0 / 1 视 AVPlayer 就绪状态而定）不是本条的口径（实测 \(inherited)）"
        )
        engine.stopAndRelease()
    }

    /// 契约的第二半（本次定的语义）：**换件即作废**待用速率 —— 它是针对被换掉那一条提的请求。
    /// 协调器每次起播后自己下 `setRate`（`loadCurrent`），所以清空不丢功能。
    func testPendingRateDoesNotCrossANewLoadedItem() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.setRate(2)   // 空载且未要播 → 只记进待用槽
        let deferred = await engine.currentRate()
        XCTAssertEqual(deferred, 0, accuracy: 0.001, "前置：空载改速不下发")

        await engine.load(localizedItem(try SilentWAV.write(seconds: 1, stem: "newitem", in: directory)))
        await engine.play()
        let applied = await engine.currentRate()
        XCTAssertEqual(
            applied, 1, accuracy: 0.001,
            "R14-2：新条目不得继承上一个持有者留下的待用速率（2.0），只能以自己的默认速率起播（实测 \(applied)）"
        )
        engine.stopAndRelease()
    }

    /// 被**拒绝**的装载（D7 / MAJ-8）不清待用速率：引擎里仍是上一件在播，那一件才是这条速率的主人。
    func testRejectedLoadKeepsPendingRateForTheItemStillInEngine() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(try SilentWAV.write(seconds: 1, stem: "keep", in: directory)))
        await engine.pause()
        await engine.setRate(2)
        await engine.load(bearerItem())        // 被拒绝：没有换件 ⇒ 待用槽属于仍在引擎里的那一件
        await engine.play()
        let applied = await engine.currentRate()
        XCTAssertEqual(
            applied, 2, accuracy: 0.001,
            "被拒装载后仍要应用为这一件记下的待用速率（清空它就是误伤，实测 \(applied)）"
        )
        engine.stopAndRelease()
    }

    // MARK: - 第 21 批 R15-2：五条边里先前无人钉住的那两条（`pause()` 保留 / `play()` 取走）
    //
    // 第 19 批把「释放 / 换件 / 被拒装载」三条钉住后，评审在**全量 415 条**上又实测了两条变异
    // 各自 0 失败（存活）：① 在 `pause()` 的状态转移里插一句 `pendingRate = nil`；
    // ② 删掉 `startPlaybackTakingPendingRate()` 里那句清空。两条的后果都是用户可见的
    // （①用户挑的速率悄悄退回默认、②陈旧速率盖掉更新过的那一个），差别只在既有夹具的
    // **时序**上没有让「待用槽在 pause 时非空」「同一个槽被第二次起播读到」这两个形状出现过 ——
    // 下面两条补的就是这两个时序，因此各自都是「正反镜像成对」的断言，不是恒真的一半。
    //
    // 资产长度：这里用 30 秒静音（既有三条用 1 秒）。这两条的时序比既有的长（两次起播 + 两次暂停），
    // 1 秒的条目会在中途播完、按 `actionAtItemEnd = .pause` 自行停住，那之后 `player.rate`
    // 的读数就不再由我们的赋值决定 —— 把这条窗口挪出时序之外，断言才只由「待用槽」说话。
    // 零网络、零第三方依赖、文件只在测试沙盒里存在（`TemporaryDirectory` 收尾删除）。

    /// 边「`pause()` —— **保留**」：暂停期间记下的待用速率，必须活过**再一次**暂停。
    ///
    /// 时序关键在「先记待用、后摁暂停」：既有的三条都在 `pause()` 之后才 `setRate`，
    /// 于是「pause 顺手清空」那条变异落在一个本来就空的槽上 ⇒ 无任何断言会动（评审实测）。
    /// 「暂停已经落地、又收到一次 pause」是真形状：`PlaybackCoordinator.pause()` 对不可暂停的
    /// 状态照样 `await engine.pause()`（第 588 行），装载入口为摁住旧声再摁一次（第 1191 行），
    /// 保持/收敛各腿经 `pauseEngineIfStillOwned`（第 997 行，五处调用）也摁 ——
    /// 拆掉「保留」，用户挑的 2× 就会在下一次起播时悄悄退回默认。
    func testPauseKeepsThePendingRateAcrossARepeatedPause() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(try SilentWAV.write(seconds: 30, stem: "pause-keeps", in: directory)))
        await engine.play()
        await engine.pause()

        await engine.setRate(2)                        // 暂停中改速 → 只记不下发
        let deferred = await engine.currentRate()
        XCTAssertEqual(deferred, 0, accuracy: 0.001, "前置：改速 ≠ 起播（此刻 2.0 确实在槽里）")
        await engine.pause()                           // ← 被钉住的那一下：不得抹掉槽里的 2.0
        let afterSecondPause = await engine.currentRate()
        XCTAssertEqual(afterSecondPause, 0, accuracy: 0.001, "前置：重复暂停仍是无声")

        await engine.play()
        let applied = await engine.currentRate()
        XCTAssertEqual(
            applied, 2, accuracy: 0.001,
            "R15-2：`pause()` 保留待用速率 —— 再摁一次暂停后起播，用户挑的 2.0 必须仍然生效（实测 \(applied)）"
        )

        // 正向镜像：`pause()` 也只是「保留」，既不改写也不追加 —— 后一次请求才是生效的那一个。
        await engine.pause()
        await engine.setRate(3)
        await engine.pause()
        await engine.play()
        let latest = await engine.currentRate()
        XCTAssertEqual(
            latest, 3, accuracy: 0.001,
            "R15-2 镜像：两次暂停之间改的速必须赢过更早的那一条（实测 \(latest)）"
        )
        engine.stopAndRelease()
    }

    /// 边「`play()` —— **取走并清空**」：被消费掉的那一条不得在第二次起播时重播。
    ///
    /// 既有的三条各自只走一次起播，「读值」留、「清空」删掉的变异因此没人看得见（评审实测）。
    /// 这里让同一个槽面对**第二次**起播，并且中间插入一次「当场下发」的改速（3.0）：
    /// 槽没清空 ⇒ `play()` 会把陈旧的 2.0 重新写回 `player.rate`，盖掉更新过的那一个。
    ///
    /// 默认侧的口径（实测）：第二次 `play()` 在无待用值时读到的是 **1.0**
    /// （`AVPlayer.play()` 自己把速率摁回 1×，它不记得我们当场下发过的 3.0 ——
    /// 那正是「待用槽」这套机制存在的理由）。所以本条钉的是「不得等于 2.0」那一侧，
    /// 与 `testPendingRateDoesNotOutliveRelease` 同一写法：默认侧 0 / 1 随就绪状态而定，
    /// 不是本条的口径；陈旧侧（2.0）才是。
    func testTakenPendingRateDoesNotOverrideANewerRateOnTheNextStart() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let engine = AVPlayerEngine()
        await engine.load(localizedItem(try SilentWAV.write(seconds: 30, stem: "take", in: directory)))
        await engine.setRate(2)                        // 未要播 → 记进待用槽
        let deferred = await engine.currentRate()
        XCTAssertEqual(deferred, 0, accuracy: 0.001, "前置：改速 ≠ 起播")

        await engine.play()
        let firstStart = await engine.currentRate()
        XCTAssertEqual(firstStart, 2, accuracy: 0.001, "前置：待用速率在第一次起播时生效（实测 \(firstStart)）")

        await engine.setRate(3)                        // 已在播 → 当场下发（R13-1 的另一半）
        let newer = await engine.currentRate()
        XCTAssertEqual(newer, 3, accuracy: 0.001, "前置：播放中改速当场生效（实测 \(newer)）")

        await engine.play()                            // 第二次起播：那条 2.0 早该被取走了
        let secondStart = await engine.currentRate()
        XCTAssertLessThan(
            secondStart, 1.5,
            "R15-2：`play()` 是**取走**而不是「读一眼」—— 第二次起播不得把更新的 3.0 覆盖回已消费的 2.0（实测 \(secondStart)）"
        )
        engine.stopAndRelease()
    }
}

/// 引擎侧「速率真的落到 player」所需的**真资产**夹具：运行时写一段纯静音 WAV
/// （PCM 16-bit 单声道 8kHz，`seconds` 秒 → 每秒 16 KB），走生产同一条 `file://` 路径装载。
///
/// 为什么必须是真条目：`AVPlayer` 在无条目 / 无效条目下不报任何非零速率，
/// 「`play()` 落地时应用待用速率」这一半在空载夹具里测不到（删掉那一行也没有断言会动）。
/// 零网络、零第三方依赖、文件只活在测试沙盒里（`TemporaryDirectory` 收尾删除）。
private enum SilentWAV {
    private static let sampleRate = 8_000
    private static let byteRate = sampleRate * 2     // 单声道 × 16-bit

    static func write(seconds: Int, stem: String, in directory: TemporaryDirectory) throws -> URL {
        let dataBytes = byteRate * max(1, seconds)
        var bytes = Data()
        bytes.append(contentsOf: Array("RIFF".utf8))
        bytes.append(le32: UInt32(36 + dataBytes))
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8))
        bytes.append(le32: 16)          // fmt 块长度（PCM 规范头）
        bytes.append(le16: 1)           // 1 = 线性 PCM
        bytes.append(le16: 1)           // 声道数
        bytes.append(le32: UInt32(sampleRate))
        bytes.append(le32: UInt32(byteRate))
        bytes.append(le16: 2)           // blockAlign = 声道 × 字节宽
        bytes.append(le16: 16)          // 位深
        bytes.append(contentsOf: Array("data".utf8))
        bytes.append(le32: UInt32(dataBytes))
        bytes.append(Data(count: dataBytes))    // 全零 = 纯静音

        let url = directory.url.appendingPathComponent("cova-silent-\(stem).wav")
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }
}

private extension Data {
    mutating func append(le32 value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }
}

/// 事件收集器：把「等到第 n 条事件」变成信号等待（D16⑤），超时只负责把挂死转成变红。
private actor EventCollector {
    enum Kind: Equatable {
        case buffering
        case playing
        case paused
        case other
    }

    private let counter = SignalCounter()
    private let syncCounter = SignalCounter()
    private(set) var events: [PlayerEvent] = []

    private static func kind(of event: PlayerEvent) -> Kind {
        switch event {
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        default: return .other
        }
    }

    /// 收集事件直到「按 filter 计数的目标事件」达标或流结束（无关事件照收但不计数）。
    func consume(
        _ stream: AsyncStream<PlayerEvent>,
        until filter: MatchingKind,
        target: Int
    ) async {
        var total = 0
        var synced = 0
        for await event in stream {
            events.append(event)
            total += 1
            counter.bump()
            if Self.kind(of: event) != .other {
                synced += 1
                syncCounter.bump()
            }
            if filter == .any, total >= target { return }
            if filter == .syncTransport, synced >= target { return }
        }
    }

    func waitFor(_ filter: MatchingKind, target: Int) async -> Bool {
        switch filter {
        case .any: return await Signals.wait(target: target, counter: counter)
        case .syncTransport: return await Signals.wait(target: target, counter: syncCounter)
        }
    }

    var all: [PlayerEvent] { events }

    /// 已收集的传输类事件（KVO 侧的 .failed/.duration 不参与，避免把顺序写成竞态）。
    var syncKinds: [Kind] {
        events.compactMap { event in
            let kind = Self.kind(of: event)
            return kind == .other ? nil : kind
        }
    }
}

private enum MatchingKind { case any, syncTransport }
