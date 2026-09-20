import AVFoundation
import CovaCore
import XCTest
@testable import CovaPlayer

/// 音频会话：中断/路由决策（纯 reducer + 可注入 gate）与 AVAudioSession 适配器的映射面。
final class AudioSessionControllerTests: XCTestCase {
    // MARK: - 归一化（通知名 + 脱敏投影 → 信号）

    func testNormalizerMapsInterruptionBeganAndEnded() {
        let began = AudioSessionNormalizer.signal(
            name: AudioSessionNotificationName.interruption,
            payload: AudioSessionNotificationPayload(interruptionKind: AudioSessionInterruptionKind.began)
        )
        XCTAssertEqual(began, .interruption(AudioInterruptionSignal(kind: .began)))
        let ended = AudioSessionNormalizer.signal(
            name: AudioSessionNotificationName.interruption,
            payload: AudioSessionNotificationPayload(
                interruptionKind: AudioSessionInterruptionKind.ended,
                shouldResumeSuggested: true
            )
        )
        XCTAssertEqual(ended, .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)))
        let endedQuietly = AudioSessionNormalizer.signal(
            name: AudioSessionNotificationName.interruption,
            payload: AudioSessionNotificationPayload(interruptionKind: AudioSessionInterruptionKind.ended)
        )
        XCTAssertEqual(endedQuietly, .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: false)))
    }

    func testNormalizerIsFailClosedOnUnknownNamesAndKinds() {
        XCTAssertEqual(
            AudioSessionNormalizer.signal(name: "SomethingElse", payload: .init()),
            .unrecognized(name: "SomethingElse")
        )
        // 中断通知但类型缺失 / 未识别字面量 → 不猜测。
        for kind in [nil, "", "other", "2"] {
            XCTAssertEqual(
                AudioSessionNormalizer.signal(
                    name: AudioSessionNotificationName.interruption,
                    payload: AudioSessionNotificationPayload(interruptionKind: kind)
                ),
                .unrecognized(name: AudioSessionNotificationName.interruption),
                "\(String(describing: kind))"
            )
        }
    }

    func testRouteChangeCarriesDeviceAvailabilityAndReason() {
        let signal = AudioSessionNormalizer.signal(
            name: AudioSessionNotificationName.routeChange,
            payload: AudioSessionNotificationPayload(
                routeChangeReasonKind: AudioSessionRouteChangeReasonKind.oldDeviceUnavailable,
                routeHasActiveOutput: false
            )
        )
        XCTAssertEqual(signal, .routeChange(AudioRouteChangeSignal(
            outputDeviceStillAvailable: false,
            reasonKind: AudioSessionRouteChangeReasonKind.oldDeviceUnavailable
        )))
    }

    /// 通知名必须与 AVFoundation 常量同一个值（否则真实中断永远进不来）。
    /// 定义侧已改为「SDK 常量派生」，本断言是回归钉子：退回字面串的改动会在这里变红。
    func testNotificationNameConstantsMatchAVFoundation() {
        XCTAssertEqual(AudioSessionNotificationName.interruption, AVAudioSession.interruptionNotification.rawValue)
        XCTAssertEqual(AudioSessionNotificationName.routeChange, AVAudioSession.routeChangeNotification.rawValue)
        XCTAssertEqual(
            AVAudioSessionAdapter.observedNotificationNames.map(\.rawValue),
            [AudioSessionNotificationName.interruption, AudioSessionNotificationName.routeChange]
        )
    }

    /// 回归钉子：中断类型整数**不得写死**（iOS 26 SDK 上 `ended.rawValue == 0`，
    /// 早期文档的 1/2 口径会让真实中断静默不进决策）。
    func testAdapterMapsInterruptionTypesViaSDKConstants() {
        XCTAssertEqual(
            AVAudioSessionAdapter.interruptionKind(from: AVAudioSession.InterruptionType.began.rawValue),
            AudioSessionInterruptionKind.began
        )
        XCTAssertEqual(
            AVAudioSessionAdapter.interruptionKind(from: AVAudioSession.InterruptionType.ended.rawValue),
            AudioSessionInterruptionKind.ended
        )
        XCTAssertNil(AVAudioSessionAdapter.interruptionKind(from: nil))
        XCTAssertNil(AVAudioSessionAdapter.interruptionKind(from: 9_999))
        XCTAssertTrue(AVAudioSessionAdapter.shouldResumeSuggested(
            from: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ))
        XCTAssertFalse(AVAudioSessionAdapter.shouldResumeSuggested(from: nil))
        // 负例也走 SDK 常量：`InterruptionOptions` 是 OptionSet，`shouldResume` 只占一位，
        // 因此「任意越界整数」（如 9_999，末位为 1）会**碰巧命中**该位 —— 拿字面量当负例
        // 本身就是这类缺陷的成因。负例 = 「SDK 常量去掉自己那一位」。
        XCTAssertFalse(AVAudioSessionAdapter.shouldResumeSuggested(
            from: AVAudioSession.InterruptionOptions.shouldResume.subtracting(.shouldResume).rawValue
        ))
    }

    /// 回归钉子（同类的第二处）：路由变更原因的整型值同样不可假设 ——
    /// `newDeviceAvailable` 与 `oldDeviceUnavailable` 相邻，把 3 当拔耳机其实拿到的是 `categoryChange`。
    /// 输入侧一律用 SDK 常量构造，期望侧用**内部词表**，故「映射表写错常量」必然变红。
    func testAdapterMapsRouteChangeReasonsViaSDKConstants() {
        XCTAssertEqual(
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ),
            AudioSessionRouteChangeReasonKind.oldDeviceUnavailable
        )
        XCTAssertEqual(
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ),
            AudioSessionRouteChangeReasonKind.newDeviceAvailable
        )
        XCTAssertEqual(
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.categoryChange.rawValue
            ),
            AudioSessionRouteChangeReasonKind.categoryChange
        )
        // 其余系统原因（override / routeConfigurationChange）→ other：观测到但不据此决策。
        XCTAssertEqual(
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.override.rawValue
            ),
            AudioSessionRouteChangeReasonKind.other
        )
        // 「reason 已知但探针仍报有输出」不得被误判为拔线（两条规则各管一头，不互相顶替）。
        XCTAssertNotEqual(
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ),
            AVAudioSessionAdapter.routeChangeReasonKind(
                from: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            )
        )
        XCTAssertNil(AVAudioSessionAdapter.routeChangeReasonKind(from: nil))
        XCTAssertNil(AVAudioSessionAdapter.routeChangeReasonKind(from: "2"))
    }

    /// SDK 常量口径自检：本文件所有断言都靠这几个常量的**互异性**成立；
    /// 若 SDK 自身把两个原因并成同值（工具链变更），此处立刻变红而不是静默退化。
    func testSDKSystemConstantsKeepTheirDistinctRawValues() {
        let interruptionRaws: [UInt] = [
            AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSession.InterruptionType.ended.rawValue,
        ]
        XCTAssertEqual(Set(interruptionRaws).count, interruptionRaws.count)
        let reasonRaws: [UInt] = [
            AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            AVAudioSession.RouteChangeReason.categoryChange.rawValue,
        ]
        XCTAssertEqual(Set(reasonRaws).count, reasonRaws.count)
        XCTAssertFalse(AVAudioSession.InterruptionOptions.shouldResume.isEmpty)
    }

    func testPayloadProjectionExtractsOnlyScalars() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        let payload = AVAudioSessionAdapter.payload(from: notification, routeHasActiveOutput: true)
        XCTAssertEqual(payload.interruptionKind, AudioSessionInterruptionKind.ended)
        XCTAssertTrue(payload.shouldResumeSuggested)
        XCTAssertTrue(payload.routeHasActiveOutput)
        let signal = AudioSessionNormalizer.signal(name: notification.name.rawValue, payload: payload)
        XCTAssertEqual(signal, .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)))
    }

    /// 路由变更通知的投影：原因走 SDK 常量映射；原始码只作诊断，决策面拿不到整数。
    func testPayloadProjectsRouteChangeReasonViaSDKConstants() {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ]
        )
        let payload = AVAudioSessionAdapter.payload(from: notification, routeHasActiveOutput: false)
        XCTAssertEqual(payload.routeChangeReasonKind, AudioSessionRouteChangeReasonKind.oldDeviceUnavailable)
        XCTAssertEqual(payload.routeChangeReasonRaw, Int(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        XCTAssertNil(payload.interruptionKind)
        let signal = AudioSessionNormalizer.signal(name: notification.name.rawValue, payload: payload)
        XCTAssertEqual(signal, .routeChange(AudioRouteChangeSignal(
            outputDeviceStillAvailable: false,
            reasonKind: AudioSessionRouteChangeReasonKind.oldDeviceUnavailable
        )))
    }

    func testPayloadFromEmptyUserInfoIsSafe() {
        let notification = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: nil)
        let payload = AVAudioSessionAdapter.payload(from: notification, routeHasActiveOutput: false)
        XCTAssertNil(payload.interruptionKind)
        XCTAssertNil(payload.routeChangeReasonKind)
        XCTAssertNil(payload.routeChangeReasonRaw)
        XCTAssertFalse(payload.shouldResumeSuggested)
        XCTAssertFalse(payload.routeHasActiveOutput)
    }

    // MARK: - 决策（来电后自动续播 / 拔耳机暂停）

    func testInterruptionBeganPausesAndRecordsResumeIntent() {
        var state = AudioSessionState()
        let decision = AudioSessionReducer.decide(.interruption(AudioInterruptionSignal(kind: .began)), state: &state)
        XCTAssertEqual(decision.command, .pause)
        XCTAssertTrue(decision.recordsShouldResume)
        XCTAssertTrue(state.shouldResume, "中断结束后要能自动续播")
        XCTAssertTrue(state.isInterrupted)
    }

    func testInterruptionEndedResumesOnlyWhenIntentWasRecorded() {
        var state = AudioSessionState()
        _ = AudioSessionReducer.decide(.interruption(AudioInterruptionSignal(kind: .began)), state: &state)
        let resumed = AudioSessionReducer.decide(
            .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: false)),
            state: &state
        )
        XCTAssertEqual(resumed, AudioSessionDecision(command: .resume, clearsShouldResume: true))
        XCTAssertEqual(resumed.command, AudioSessionCommand.resume)
        XCTAssertFalse(state.shouldResume)
        XCTAssertFalse(state.isInterrupted)
    }

    func testInterruptionEndedAfterManualPauseDoesNotAutoResume() {
        // 用户主动暂停后被系统中断（shouldResume 未记录）→ 中断结束不得自动续播。
        var state = AudioSessionState()
        let ended = AudioSessionReducer.decide(
            .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: false)),
            state: &state
        )
        XCTAssertEqual(ended.command, AudioSessionCommand.none)
    }

    func testInterruptionEndedCanRelyOnSystemSuggestionAlone() {
        var state = AudioSessionState()
        state.shouldResume = false
        let decision = AudioSessionReducer.decide(
            .interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)),
            state: &state
        )
        XCTAssertEqual(decision.command, .resume)
    }

    /// 原因未知（系统没给 reason / 越界）时退回探针兜底：无输出即暂停。
    func testRouteChangeWithoutOutputPausesAndClearsResumeIntent() {
        var state = AudioSessionState()
        state.shouldResume = true
        let decision = AudioSessionReducer.decide(
            .routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: false, reasonKind: nil)),
            state: &state
        )
        XCTAssertEqual(decision, AudioSessionDecision(command: .pause, clearsShouldResume: true))
        XCTAssertEqual(decision.command, AudioSessionCommand.pause)
        XCTAssertFalse(state.shouldResume, "拔耳机后重新插回不得自动出声")
    }

    /// 原因优先：蓝牙断开瞬间系统路由探针仍可能报「有输出」，`oldDeviceUnavailable` 必须无条件暂停。
    func testOldDeviceUnavailablePausesEvenWhenRouteProbeStillReportsOutput() {
        var state = AudioSessionState()
        state.shouldResume = true
        let decision = AudioSessionReducer.decide(
            .routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: true, reasonKind: AudioSessionRouteChangeReasonKind.oldDeviceUnavailable)),
            state: &state
        )
        XCTAssertEqual(decision, AudioSessionDecision(command: .pause, clearsShouldResume: true))
        XCTAssertFalse(state.shouldResume)
    }

    /// 裁决表反向：插回（newDeviceAvailable）与类目变化（categoryChange）在有输出时都不动作，
    /// 也不得清掉续播意图 —— 变异「暂停条件写成 reason 非空」会在这里变红。
    func testBenignRouteReasonsWithOutputAreIgnored() {
        for kind in [
            AudioSessionRouteChangeReasonKind.newDeviceAvailable,
            AudioSessionRouteChangeReasonKind.categoryChange,
            AudioSessionRouteChangeReasonKind.other,
        ] {
            var state = AudioSessionState()
            state.shouldResume = true
            let decision = AudioSessionReducer.decide(
                .routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: true, reasonKind: kind)),
                state: &state
            )
            XCTAssertEqual(decision.command, AudioSessionCommand.none, kind)
            XCTAssertTrue(state.shouldResume, "\(kind)：无关路由变更不得清掉续播意图")
        }
    }

    func testUnrecognizedSignalNeverTouchesPlayback() {
        var state = AudioSessionState()
        let decision = AudioSessionReducer.decide(.unrecognized(name: "AVAudioSessionMediaServicesWereReset"), state: &state)
        XCTAssertEqual(decision.command, AudioSessionCommand.none)
        XCTAssertEqual(state.lastCommand, AudioSessionCommand.none)
    }

    func testRepeatedBeganEndedCyclesStayConsistent() {
        var state = AudioSessionState()
        for _ in 0..<3 {
            XCTAssertEqual(AudioSessionReducer.decide(.interruption(AudioInterruptionSignal(kind: .began)), state: &state).command, .pause)
            XCTAssertEqual(AudioSessionReducer.decide(.interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)), state: &state).command, .resume)
        }
        XCTAssertFalse(state.isInterrupted)
        XCTAssertFalse(state.shouldResume)
    }

    // MARK: - Gate（把决策转成播放动作）

    func testGateDrivesPauseAndResumeOnCoordinator() async {
        let handler = AudioSessionCommandHandler(coordinator: nil)
        let system = StubAudioSessionSystem()
        let gate = AudioSessionGate(system: system, handler: handler)
        await gate.receive(.interruption(AudioInterruptionSignal(kind: .began)))
        var commands = await handler.appliedCommands
        XCTAssertEqual(commands, [.pause])
        await gate.receive(.interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)))
        commands = await handler.appliedCommands
        XCTAssertEqual(commands, [.pause, .resume], "来电结束自动续播")
        let state = await gate.currentAudioSessionState()
        XCTAssertFalse(state.isInterrupted)
    }

    func testGateIgnoresUnrecognizedAndNonResumableEvents() async {
        let handler = AudioSessionCommandHandler(coordinator: nil)
        let gate = AudioSessionGate(system: StubAudioSessionSystem(), handler: handler)
        await gate.receive(.unrecognized(name: "whatever"))
        await gate.receive(.routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: true)))
        let commands = await handler.appliedCommands
        XCTAssertTrue(commands.isEmpty)
    }

    func testGateStartConfiguresSessionOnceAndStopsCleanly() async throws {
        let system = StubAudioSessionSystem()
        let gate = AudioSessionGate(system: system, handler: AudioSessionCommandHandler(coordinator: nil))
        try await gate.start()
        try await gate.start()
        let configurations = system.configurationCount
        XCTAssertEqual(configurations, 1, "重复 start 不得重复激活会话")
        var started = await gate.isStarted()
        XCTAssertTrue(started)
        await gate.stop()
        let deactivations = system.deactivationCount
        XCTAssertEqual(deactivations, 1)
        started = await gate.isStarted()
        XCTAssertFalse(started)
        // stop 之后状态归零（不带着旧的续播意图复活）。
        let state = await gate.currentAudioSessionState()
        XCTAssertEqual(state, AudioSessionState())
        _ = configurations
        _ = deactivations
    }

    func testGateStartPropagatesSystemFailure() async {
        let system = StubAudioSessionSystem(failsConfigure: true)
        let gate = AudioSessionGate(system: system, handler: AudioSessionCommandHandler(coordinator: nil))
        do {
            try await gate.start()
            XCTFail("会话配置失败必须抛出")
        } catch let error as PlayerError {
            if case .writeFailed = error {} else { XCTFail("应为 writeFailed：\(error)") }
        } catch {
            XCTFail("应为 PlayerError：\(error)")
        }
        let started = await gate.isStarted()
        XCTAssertFalse(started)
    }

    func testGateStopsAreIdempotent() async throws {
        let gate = AudioSessionGate(system: StubAudioSessionSystem(), handler: AudioSessionCommandHandler(coordinator: nil))
        await gate.stop()
        try await gate.start()
        await gate.stop()
        await gate.stop()
        let started = await gate.isStarted()
        XCTAssertFalse(started)
    }

    // MARK: - 中断 → 真实播放暂停/续播（端到端，仍零硬件）

    func testInterruptionRoundTripPausesAndResumesRealCoordinator() async {
        let engine = ScriptedEngine()
        let coordinator = PlaybackCoordinator(engine: engine, clock: FakeClock())
        _ = await coordinator.start(items: TestItems.makeMany(["a"]))
        let handler = AudioSessionCommandHandler(coordinator: coordinator)
        let gate = AudioSessionGate(system: StubAudioSessionSystem(), handler: handler)

        await gate.receive(.interruption(AudioInterruptionSignal(kind: .began)))
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused, "来电必须暂停播放")

        await gate.receive(.interruption(AudioInterruptionSignal(kind: .ended, shouldResumeSuggested: true)))
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .playing, "来电结束自动续播")

        await gate.receive(.routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: false)))
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused, "拔耳机必须暂停")
        // 插回（有输出）不得自动出声。
        await gate.receive(.routeChange(AudioRouteChangeSignal(outputDeviceStillAvailable: true)))
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
    }

    /// 端到端接线：真实的 AVFoundation 通知名 + SDK 常量 userInfo + 真实适配器 + 真实协调器。
    ///
    /// 这条链上任何一处把「通知名 / userInfo 键 / 枚举整型值」写死或写错，都不会有编译期信号，
    /// 只会让真实中断静默不进决策 —— 只有用**系统常量**从最外层灌进来才能杀掉它。
    func testRealNotificationsDriveRealCoordinatorThroughAdapter() async throws {
        let engine = ScriptedEngine()
        let coordinator = PlaybackCoordinator(engine: engine, clock: FakeClock())
        _ = await coordinator.start(items: TestItems.makeMany(["wire"]))
        let started = await coordinator.currentSnapshot().state
        XCTAssertEqual(started, .playing)

        let adapter = AVAudioSessionAdapter()
        let handler = SignallingSessionHandler(coordinator: coordinator)
        let system = StubAudioSessionSystem()
        let gate = AudioSessionGate(system: system, handler: handler, adapter: adapter)
        addTeardownBlock {
            await gate.stop()
            await coordinator.teardown()
        }
        try await gate.start()
        let registered = adapter.observedNotificationCount
        XCTAssertEqual(registered, 2, "未注册真实通知则整条链根本没接上")

        // 1) 来电开始 → 暂停（探针始终报「有输出」，暂停只能来自中断分支）。
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        let sawFirst = await handler.waitForCommands(target: 1)
        XCTAssertTrue(sawFirst, "中断通知未驱动到播放层")
        var state = await coordinator.currentSnapshot().state
        XCTAssertEqual(state, .paused)

        // 2) 来电结束（系统建议续播）→ 自动续播。iOS 26 SDK 上 `ended.rawValue == 0`：
        //    任何按「1/2」口径写死的实现都会在这里变红（而不是静默不续播）。
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        let sawSecond = await handler.waitForCommands(target: 2)
        XCTAssertTrue(sawSecond, "中断结束未驱动到播放层")
        state = await coordinator.currentSnapshot().state
        XCTAssertEqual(state, .playing, "来电结束后必须自动续播")

        // 3) 拔耳机（原因 = oldDeviceUnavailable，探针此刻仍报有输出）→ 暂停。
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        let sawThird = await handler.waitForCommands(target: 3)
        XCTAssertTrue(sawThird, "路由变更未驱动到播放层")
        state = await coordinator.currentSnapshot().state
        XCTAssertEqual(state, .paused)

        // 4) 三次通知各自的命令与顺序（第 3 条之后没有第 4 条：插回不自动出声的口径由
        //    `testBenignRouteReasonsWithOutputAreIgnored` 在决策面钉住 —— 通知投递与 Task
        //    调度不保证跨通知的顺序，故此处不做「等待某事不发生」的竞态断言（D16⑤）。
        let applied = await handler.appliedUpTo(3)
        XCTAssertEqual(applied, [.pause, .resume, .pause])

        // 5) teardown 必须摘干净观测者（通知残留是本仓红线）。
        await gate.stop()
        let remaining = adapter.observedNotificationCount
        XCTAssertEqual(remaining, 0)
        XCTAssertFalse(adapter.holdsGate)
    }

    // MARK: - AVAudioSessionAdapter 冒烟（不依赖真机音频输出）

    func testAdapterMapsErrorsToStatusOnly() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        XCTAssertEqual(AVAudioSessionAdapter.status(of: error), -10868)
        // 只取整数码：任何非 NSError 输入也只会产出一个整数，不会带出文本。
        XCTAssertEqual(AVAudioSessionAdapter.status(of: CancellationError()), Int32((CancellationError() as NSError).code))
    }

    func testAdapterErrorDescriptionsCarryNoAddressOrCredential() {
        let error = PlayerError.writeFailed(-10868)
        let described = String(describing: error)
        XCTAssertFalse(described.contains("Bearer"))
        XCTAssertFalse(described.contains("http"))
        XCTAssertTrue(described.contains("-10868"))
    }

    func testAdapterObservingCountIsZeroBeforeRegistration() async {
        let adapter = AVAudioSessionAdapter()
        let count = adapter.observedNotificationCount
        XCTAssertEqual(count, 0)
        let holds = adapter.holdsGate
        XCTAssertFalse(holds)
        // 未注册时投递通知不得造成崩溃（forward 的 gate 为空即返回）。
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let after = adapter.observedNotificationCount
        XCTAssertEqual(after, 0)
    }
}

/// 桩音频会话系统：记录配置/反配置次数。
final class StubAudioSessionSystem: AudioSessionSystemInterface, @unchecked Sendable {
    private let lock = NSLock()
    private var _configurations = 0
    private var _deactivations = 0
    var outputsAvailable = true
    let failsConfigure: Bool

    init(failsConfigure: Bool = false) {
        self.failsConfigure = failsConfigure
    }

    var configurationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _configurations
    }

    var deactivationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _deactivations
    }

    func configureForPlayback() throws {
        lock.lock()
        _configurations += 1
        lock.unlock()
        if failsConfigure { throw PlayerError.writeFailed(-10868) }
    }

    func deactivate() throws {
        lock.lock()
        _deactivations += 1
        lock.unlock()
    }

    func hasActiveOutputPorts() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputsAvailable
    }
}

/// 信号式的会话命令处理者：既驱动真实协调器，又让测试「等信号再断言」（D16⑤ 禁止竞态断言）。
actor SignallingSessionHandler: AudioSessionCommandHandling {
    private let counter = SignalCounter()
    private(set) var commands: [AudioSessionCommand] = []
    private let coordinator: PlaybackCoordinator

    init(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
    }

    func apply(_ command: AudioSessionCommand) async {
        switch command {
        case .none:
            return
        case .pause:
            await coordinator.pause()
        case .resume:
            await coordinator.resume()
        }
        commands.append(command)
        counter.bump()
    }

    /// 挂起直到第 `target` 条命令落地（超时上界只把「永不到来」的回归从挂死转成变红）。
    func waitForCommands(target: Int) async -> Bool {
        await Signals.wait(target: target, counter: counter)
    }

    /// 等到第 `target` 条命令后返回已记录的序列。
    func appliedUpTo(_ target: Int) async -> [AudioSessionCommand] {
        _ = await Signals.wait(target: target, counter: counter)
        return commands
    }
}
