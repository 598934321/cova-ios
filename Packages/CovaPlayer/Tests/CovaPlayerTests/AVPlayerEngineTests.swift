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

        guard case .success(let publicURL) = AVPlayerEngine.playableURL(for: TestItems.make("pub")) else {
            return XCTFail("公开直链应可直接播")
        }
        XCTAssertEqual(publicURL.scheme, "https")
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
        await engine.setRate(2)
        let rate = await engine.currentRate()
        XCTAssertEqual(rate, 2, accuracy: 0.001)
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
        XCTAssertFalse(engine.currentPlaybackIntent, "释放后不存在任何在播意图")
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
