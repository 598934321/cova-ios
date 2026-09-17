import Foundation

/// SSE 降级策略参数（D6：10s 无首事件 / 30s 静默 / 3 个坏事件 / done 前 EOF → 5s 轮询）。
public struct OneStepDegradationPolicy: Equatable, Sendable {
    /// 无首事件超时。
    public var firstEventTimeout: TimeInterval
    /// 静默（距上一活动）超时。
    public var silenceTimeout: TimeInterval
    /// 坏事件阈值（累计达到即降级）。
    public var malformedEventThreshold: Int
    /// 轮询间隔。
    public var pollInterval: TimeInterval

    public init(
        firstEventTimeout: TimeInterval = 10,
        silenceTimeout: TimeInterval = 30,
        malformedEventThreshold: Int = 3,
        pollInterval: TimeInterval = 5
    ) {
        self.firstEventTimeout = firstEventTimeout
        self.silenceTimeout = silenceTimeout
        self.malformedEventThreshold = malformedEventThreshold
        self.pollInterval = pollInterval
    }
}

/// 降级触发原因（四个契约条件，逐条可对证）。
public enum OneStepDegradationTrigger: Equatable, Sendable {
    case firstEventTimeout
    case silenceTimeout
    case malformedEvents(count: Int)
    case eofBeforeDone
}

/// 流式会话阶段。
public enum OneStepStreamPhase: Equatable, Sendable {
    /// SSE 活跃。
    case streaming
    /// 已降级，轮询中（SSE 已终止）。
    case polling
    /// 终态（done / 明确错误 / 取消）。
    case finished
}

/// 状态机对外动作（副作用由协调器执行，状态机本身纯逻辑）。
public enum OneStepStreamAction: Equatable, Sendable {
    /// 原样转发一条 SSE 帧。
    case emitFrame(CovaSSEFrame)
    /// 转发轮询得到的计划卡（协调器统一编码为 `plan_card` 帧）。
    case emitPlanCards([OneStepPlanCardDto])
    /// 立即取一次计划卡。
    case pollNow
    /// 终止 SSE 流（**降级与结束时必须发生**，保证不与轮询并发）。
    case terminateStreaming
    /// 结束整个会话。
    case finish
}

/// Cova 一步模式流式降级状态机（D6）。
///
/// 纯逻辑、时钟以参数注入（`at now:`），因此可用虚拟时间确定性测试四个触发条件。
/// 权威不变量：`streaming` 与 `polling` **互斥**（降级动作内同时下发 `terminateStreaming`）。
///
/// 坏事件定义见 `SSEFrameParser`：帧载荷非法 JSON。坏事件**不**转发（无有效载荷可给上层）。
public struct OneStepStreamMachine: Sendable {
    public let policy: OneStepDegradationPolicy

    public private(set) var phase: OneStepStreamPhase = .streaming
    public private(set) var degradedBy: OneStepDegradationTrigger?
    public private(set) var malformedEventCount = 0

    private var startedAt: TimeInterval
    private var lastActivityAt: TimeInterval
    private var receivedFirstEvent = false
    private var lastPollAt: TimeInterval
    private var awaitingPoll = false
    private var emittedCardSignatures: Set<String> = []

    public init(policy: OneStepDegradationPolicy = OneStepDegradationPolicy(), startedAt: TimeInterval) {
        self.policy = policy
        self.startedAt = startedAt
        self.lastActivityAt = startedAt
        self.lastPollAt = startedAt
    }

    public var isFinished: Bool { phase == .finished }

    /// 校正起始时间（仅用于 `start` 的时间获取窗口）：在收到任何事件、且仍处于 `streaming` 前有效。
    ///
    /// 协调器先在 `await clock.now()` 之前安装本状态机（临时 `startedAt = 0`），使窗口期内到达的
    /// `cancel()` 不被丢弃；取到真实时间后再调用本方法校正。
    mutating func updateStartTime(_ time: TimeInterval) {
        guard phase == .streaming, !receivedFirstEvent else { return }
        startedAt = time
        lastActivityAt = time
        lastPollAt = time
    }

    /// 收到一条 SSE 帧。
    public mutating func frameReceived(_ frame: CovaSSEFrame, at now: TimeInterval) -> [OneStepStreamAction] {
        guard phase == .streaming else { return [] }
        lastActivityAt = now
        if frame.isMalformed {
            malformedEventCount += 1
            guard malformedEventCount >= policy.malformedEventThreshold else { return [] }
            return degrade(.malformedEvents(count: malformedEventCount), at: now)
        }
        receivedFirstEvent = true
        // SSE 已投递的计划卡也登记去重，避免降级后首轮轮询重复投递同一张卡（m2）。
        if frame.event == .planCard,
           let card = try? JSONDecoder().decode(OneStepPlanCardDto.self, from: frame.payload) {
            emittedCardSignatures.insert(Self.signature(of: card))
        }
        switch frame.event {
        case .done, .error:
            phase = .finished
            return [.emitFrame(frame), .finish]
        default:
            return [.emitFrame(frame)]
        }
    }

    /// SSE 流正常或异常结束（EOF）。仅在仍处于 `streaming` 时触发降级——
    /// done 之后的 EOF 是正常收尾，不降级。
    public mutating func streamEnded(at now: TimeInterval) -> [OneStepStreamAction] {
        guard phase == .streaming else { return [] }
        return degrade(.eofBeforeDone, at: now)
    }

    /// 回传解析器丢弃的坏事件（超长行 / 超长事件数据 / EOF 残帧；无对应帧）。
    ///
    /// 与载荷非法 JSON 的坏事件共用同一计数与阈值，因此达到阈值时降级原因同样为
    /// `.malformedEvents`，而非恒报 `.eofBeforeDone`（Minor-1）。
    public mutating func recordDiscardedMalformedEvents(
        _ count: Int,
        at now: TimeInterval
    ) -> [OneStepStreamAction] {
        guard phase == .streaming, count > 0 else { return [] }
        lastActivityAt = now
        malformedEventCount += count
        guard malformedEventCount >= policy.malformedEventThreshold else { return [] }
        return degrade(.malformedEvents(count: malformedEventCount), at: now)
    }

    /// 到达下一个截止时刻（超时 / 轮询节拍）。
    public mutating func deadlineReached(at now: TimeInterval) -> [OneStepStreamAction] {
        switch phase {
        case .streaming:
            if !receivedFirstEvent {
                guard now - startedAt >= policy.firstEventTimeout else { return [] }
                return degrade(.firstEventTimeout, at: now)
            }
            guard now - lastActivityAt >= policy.silenceTimeout else { return [] }
            return degrade(.silenceTimeout, at: now)
        case .polling:
            guard !awaitingPoll, now - lastPollAt >= policy.pollInterval else { return [] }
            lastPollAt = now
            awaitingPoll = true
            return [.pollNow]
        case .finished:
            return []
        }
    }

    /// 下一次需要唤醒的绝对时刻（`nil` = 无需定时）。
    public func nextDeadline() -> TimeInterval? {
        switch phase {
        case .streaming:
            return receivedFirstEvent
                ? lastActivityAt + policy.silenceTimeout
                : startedAt + policy.firstEventTimeout
        case .polling:
            return awaitingPoll ? nil : lastPollAt + policy.pollInterval
        case .finished:
            return nil
        }
    }

    /// 轮询返回计划卡：去重后转发（同一 `planCardId` 且 revision/status/snapshotHash 未变则不重发）。
    public mutating func pollReceived(
        _ cards: [OneStepPlanCardDto],
        at now: TimeInterval
    ) -> [OneStepStreamAction] {
        guard phase == .polling else { return [] }
        awaitingPoll = false
        lastActivityAt = now
        // 节拍从「本次轮询完成」起算：慢回包 / 时间跳跃后不会因 nextDeadline 已过期而背靠背立即补发（Minor-2）。
        lastPollAt = now
        let fresh = cards.filter { emittedCardSignatures.insert(Self.signature(of: $0)).inserted }
        return fresh.isEmpty ? [] : [.emitPlanCards(fresh)]
    }

    /// 轮询失败：按 D6 终止条件，失败不结束会话，下一节拍重试（上层可随时取消）。
    public mutating func pollFailed(at now: TimeInterval) -> [OneStepStreamAction] {
        guard phase == .polling else { return [] }
        awaitingPoll = false
        lastPollAt = now
        lastActivityAt = now
        return []
    }

    /// 上层取消。
    public mutating func cancel() -> [OneStepStreamAction] {
        guard phase != .finished else { return [] }
        phase = .finished
        return [.terminateStreaming, .finish]
    }

    private mutating func degrade(
        _ trigger: OneStepDegradationTrigger,
        at now: TimeInterval
    ) -> [OneStepStreamAction] {
        phase = .polling
        degradedBy = trigger
        lastPollAt = now
        awaitingPoll = true
        return [.terminateStreaming, .pollNow]
    }

    private static func signature(of card: OneStepPlanCardDto) -> String {
        let revision = card.revision.map(String.init) ?? "-"
        return "\(card.planCardId)#\(revision)#\(card.status.rawValue)#\(card.snapshotHash ?? "-")"
    }
}

/// 事件流协调器：驱动 SSE 解析 + 状态机 + 降级轮询，对外只暴露统一的 `CovaSSEFrame` 流。
///
/// 不变量：
/// - 单个会话内 `streaming` 与 `polling` 不同时存在——降级动作先 `terminateStreaming` 再 `pollNow`；
/// - 轮询结果被编码为与 SSE 同形的 `plan_card` 帧，上层无需区分来源；
/// - 终止（done / error / cancel）会取消全部内部任务并结束输出流。
public actor OneStepStreamCoordinator {
    /// 协调器为**单次使用**：重复 `start` 或终态后 `start` 一律抛错，绝不静默遗弃 continuation。
    public enum LifecycleError: Error, Equatable, Sendable {
        /// 已有会话在运行（同一实例重复 `start`）。
        case alreadyStarted
        /// 会话已到终态（done / 明确错误 / 取消）。
        case alreadyFinished
    }

    private enum Lifecycle {
        case idle
        case running
        case finished
    }

    private let clock: any CovaClock
    private let transport: any SSEStreamingTransport
    private let poller: any OneStepPlanPolling
    private let policy: OneStepDegradationPolicy

    private var lifecycle: Lifecycle = .idle
    private var machine: OneStepStreamMachine?
    private var sessionId = ""
    private var output: AsyncStream<CovaSSEFrame>.Continuation?
    private var sseTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    public init(
        clock: any CovaClock,
        transport: any SSEStreamingTransport,
        poller: any OneStepPlanPolling,
        policy: OneStepDegradationPolicy = OneStepDegradationPolicy()
    ) {
        self.clock = clock
        self.transport = transport
        self.poller = poller
        self.policy = policy
    }

    private var isFinished: Bool { lifecycle == .finished }

    /// 启动会话，返回统一事件流（SSE 帧与轮询计划卡帧同形）。
    ///
    /// 单次使用：`.running` → `alreadyStarted`，`.finished` → `alreadyFinished`；均不创建流、
    /// 不启动任何任务，因此不存在 continuation/任务泄漏。
    @discardableResult
    public func start(sessionId: String, agentRequest: HTTPRequest) async throws -> AsyncStream<CovaSSEFrame> {
        switch lifecycle {
        case .running:
            throw LifecycleError.alreadyStarted
        case .finished:
            throw LifecycleError.alreadyFinished
        case .idle:
            break
        }
        lifecycle = .running
        let (stream, continuation) = AsyncStream.makeStream(of: CovaSSEFrame.self)
        output = continuation
        self.sessionId = sessionId
        // 先安装状态机（临时 startedAt=0），确保 start 的 await 窗口内到达的 cancel() 不被丢弃；
        // 取到真实时间后再校正起始时间（此刻尚无事件/定时器/SSE）。
        machine = OneStepStreamMachine(policy: policy, startedAt: 0)
        let now = await clock.now()
        guard lifecycle == .running else {
            // 窗口内已 cancel：输出流已由 cancel 结束，直接返回该（已终止的）流。
            return stream
        }
        machine?.updateStartTime(now)
        rescheduleTimer(now: now)
        startSSE(agentRequest)
        return stream
    }

    /// 上层取消：终止 SSE 与轮询并结束输出流。
    ///
    /// **确定性取消语义（M-1）**：一旦调用，此协调器即锁定为终态，保证此后不会再有活跃会话：
    /// - 未 `start`（`.idle`）→ 直接置终态；其后 `start()` 抛 `alreadyFinished`，绝不打开 SSE；
    /// - 进行中（`.running`）→ 终止 SSE/轮询并结束输出流；
    /// - 已终态 → no-op。
    /// 因此无论 `cancel` 与 `start` 的调度顺序如何，都**不存在**「cancel 返回后 SSE 仍被打开」。
    public func cancel() async {
        switch lifecycle {
        case .finished:
            return
        case .idle:
            lifecycle = .finished
            return
        case .running:
            let now = await clock.now()
            guard !isFinished, var machine else { return }
            let actions = machine.cancel()
            self.machine = machine
            apply(actions, now: now)
        }
    }

    // MARK: - 观测（测试/调试）

    /// 是否已锁定终态（含「start 前被 cancel」）。
    public func isTerminated() -> Bool { lifecycle == .finished }
    public func currentPhase() -> OneStepStreamPhase? { machine?.phase }
    public func degradationTrigger() -> OneStepDegradationTrigger? { machine?.degradedBy }
    public func malformedEventCount() -> Int { machine?.malformedEventCount ?? 0 }

    // MARK: - SSE

    private func startSSE(_ request: HTTPRequest) {
        sseTask = Task { [weak self] in
            await self?.consume(request)
        }
    }

    private func consume(_ request: HTTPRequest) async {
        // M-1：已取消的 Task 仍会执行闭包体，若不在此处拦截就会在 `cancel()` 返回后仍发起一次传输。
        // 此检查在调用传输**之前**、且与 `transport.stream` 之间无 await，故 cancel 返回后绝不发起传输。
        guard !Task.isCancelled else { return }
        do {
            let chunks = try await transport.stream(request)
            var parser = SSEFrameParser()
            var reportedDiscarded = 0
            for try await chunk in chunks {
                if Task.isCancelled { return }
                for frame in parser.consume(chunk) { await handle(frame) }
                // 协议级坏事件（超长行/超长数据）无帧可派发，需显式回传参与坏事件判定。
                reportedDiscarded = await reportDiscardedMalformed(
                    total: parser.discardedMalformedEventCount,
                    reported: reportedDiscarded
                )
            }
            guard !Task.isCancelled else { return }
            for frame in parser.finish() { await handle(frame) }
            _ = await reportDiscardedMalformed(
                total: parser.discardedMalformedEventCount,
                reported: reportedDiscarded
            )
            await handleStreamEnded()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            await handleStreamEnded()
        }
    }

    /// 把解析器新丢弃的坏事件增量回传状态机（唯一 await 前置，再同步读-改-写）。
    @discardableResult
    private func reportDiscardedMalformed(total: Int, reported: Int) async -> Int {
        let delta = total - reported
        guard delta > 0 else { return total }
        let now = await clock.now()
        guard !isFinished, var machine else { return total }
        let actions = machine.recordDiscardedMalformedEvents(delta, at: now)
        self.machine = machine
        apply(actions, now: now)
        return total
    }

    /// 关键并发约定（M1）：**先取时间（唯一 await），再同步读-改-写状态机**。
    /// 任何 `await` 都不得出现在读 `machine` 与写回之间，否则会让出 actor 并以过期副本
    /// 覆盖并发方刚写入的状态（回退/重复轮询/轮询结果丢失）。
    private func handle(_ frame: CovaSSEFrame) async {
        let now = await clock.now()
        guard !isFinished, var machine else { return }
        let actions = machine.frameReceived(frame, at: now)
        self.machine = machine
        apply(actions, now: now)
    }

    private func handleStreamEnded() async {
        let now = await clock.now()
        guard !isFinished, var machine else { return }
        let actions = machine.streamEnded(at: now)
        self.machine = machine
        apply(actions, now: now)
    }

    // MARK: - 轮询

    private func performPoll() {
        // 同一时刻只允许一个在途轮询任务：先取消旧的，避免无主任务并发。
        pollTask?.cancel()
        let poller = self.poller
        let sessionId = self.sessionId
        pollTask = Task { [weak self] in
            do {
                let cards = try await poller.pollPlans(sessionId: sessionId)
                guard !Task.isCancelled else { return }
                await self?.receivePoll(cards)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.receivePollFailure()
            }
        }
    }

    private func receivePoll(_ cards: [OneStepPlanCardDto]) async {
        let now = await clock.now()
        pollTask = nil
        guard !isFinished, var machine else { return }
        let actions = machine.pollReceived(cards, at: now)
        self.machine = machine
        apply(actions, now: now)
    }

    private func receivePollFailure() async {
        let now = await clock.now()
        pollTask = nil
        guard !isFinished, var machine else { return }
        let actions = machine.pollFailed(at: now)
        self.machine = machine
        apply(actions, now: now)
    }

    // MARK: - 动作与定时

    private func apply(_ actions: [OneStepStreamAction], now: TimeInterval) {
        for action in actions {
            switch action {
            case .emitFrame(let frame):
                output?.yield(frame)
            case .emitPlanCards(let cards):
                for card in cards {
                    if let frame = CovaSSEFrame.planCard(card) { output?.yield(frame) }
                }
            case .pollNow:
                performPoll()
            case .terminateStreaming:
                sseTask?.cancel()
                sseTask = nil
            case .finish:
                finish()
            }
        }
        rescheduleTimer(now: now)
    }

    private func rescheduleTimer(now: TimeInterval) {
        timerTask?.cancel()
        timerTask = nil
        guard !isFinished, let deadline = machine?.nextDeadline() else { return }
        let delay = max(0, deadline - now)
        let clock = self.clock
        timerTask = Task { [weak self] in
            do { try await clock.sleep(seconds: delay) } catch { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        let now = await clock.now()
        guard !isFinished, var machine else { return }
        let actions = machine.deadlineReached(at: now)
        self.machine = machine
        apply(actions, now: now)
    }

    private func finish() {
        guard !isFinished else { return }
        lifecycle = .finished
        sseTask?.cancel()
        sseTask = nil
        pollTask?.cancel()
        pollTask = nil
        timerTask?.cancel()
        timerTask = nil
        output?.finish()
        output = nil
    }
}
