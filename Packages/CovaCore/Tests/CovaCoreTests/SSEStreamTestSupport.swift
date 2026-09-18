import CovaCore
import Foundation
import XCTest

/// 虚拟时钟（单测；**不真实等待**）。
///
/// - `sleep` 注册等待者，只有 `advance(by:)` / `advanceToNextDeadline(where:)` 才放行；
/// - 取消（定时器被重置）会移除等待者并以 `CancellationError` 唤醒，避免悬挂；
/// - `waitForDeadline(where:)` / `advanceToNextDeadline(where:)` 是**确定性推进原语**：
///   先挂起直到目标定时等待者**已注册**（由 `sleep` 注册事件唤醒），再推进到其截止时刻——
///   不做 1s 步进猜测，因此不存在「注册空窗」与「推进过冲」两类时序竞态（D16⑤）。
actor VirtualClock: CovaClock {
    private var current: TimeInterval = 0
    private var waiters: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    /// 定时等待者注册通知：消除「推进时定时器尚未注册」竞态（事件驱动，非让步轮询）。
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    /// 每次取时前主动让出的调度次数：>0 时放大「跨 await 读-改-写」竞态窗口（确定性复现 M1）。
    private let yields: Int

    init(yields: Int = 0) {
        self.yields = yields
    }

    func now() async -> TimeInterval {
        for _ in 0..<yields { await Task.yield() }
        return current
    }

    func sleep(seconds: TimeInterval) async throws {
        if seconds <= 0 { return }
        let id = UUID()
        let deadline = current + seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (deadline, continuation)
                    let pending = registrationWaiters
                    registrationWaiters = []
                    for waiter in pending { waiter.resume() }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 推进虚拟时间并放行所有到期等待者；返回放行的等待者数量。
    @discardableResult
    func advance(by seconds: TimeInterval) -> Int {
        current += seconds
        return releaseDueWaiters()
    }

    private func releaseDueWaiters() -> Int {
        let due = waiters.filter { $0.value.deadline <= current }
        for (id, waiter) in due {
            waiters[id] = nil
            waiter.continuation.resume()
        }
        return due.count
    }

    func pendingWaiterCount() -> Int { waiters.count }

    /// 确定性推进：挂起直到存在满足 `predicate` 的定时等待者，随后把时间推进到其中**最早的**
    /// 截止时刻，并放行所有已到期等待者（同一时刻被取消的旧定时器若仍在册则一并放行——
    /// 状态机按时间重判，早于静默窗口的残影不产生状态分叉）。
    ///
    /// 返回本次放行的等待者数量：0 表示命中的等待者在推进前已被取消（测试应据返回值判断是否空转）。
    @discardableResult
    func advanceToNextDeadline(
        where predicate: @Sendable (TimeInterval) -> Bool = { _ in true }
    ) async -> Int {
        while true {
            if let target = waiters.values.map({ $0.deadline }).filter(predicate).min() {
                current = max(current, target)
                return releaseDueWaiters()
            }
            await withCheckedContinuation { registrationWaiters.append($0) }
        }
    }
}

/// 可放行的异步门：`wait()` 挂起直到 `open()`。
///
/// 用于**确定性**构造「任务已创建但停在取消守卫之前」的注入点场景（事件驱动，不依赖调度竞态）。
/// 典型用法：`reached.open()` 标记「已到达」，`release.wait()` 阻塞任务体；测试侧先
/// `await reached.wait()` 再推进/取消，最后 `await release.open()` 放行。
actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

/// 可在指定时刻阻塞 `now()` 的虚拟时钟（测试专用）。
///
/// `armNowGate()` 让**随后第一次** `now()` 调用挂起（事件驱动，`waitForBlockedNowCalls` 可确定
/// 观测到该挂起），`openNowGate()` 放行。用于确定性控制「各异步路径读到时刻」的相对顺序，
/// 例如「帧处理已读到时刻、尚未写状态机时，让定时器先降级」。
/// 其余时间行为与 `VirtualClock` 一致（`sleep` 由 `advance` / `advanceToNextDeadline` 放行）。
actor GatedNowClock: CovaClock {
    private var current: TimeInterval = 0
    private var armedGates = 0
    private var blockedNowCalls = 0
    private var blockedNowWaiters: [CheckedContinuation<Void, Never>] = []
    private var nowGate: CheckedContinuation<Void, Never>?
    private var waiters: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    /// 装备一次「阻塞下一次 `now()`」。
    func armNowGate() { armedGates += 1 }

    func now() async -> TimeInterval {
        if armedGates > 0 {
            armedGates -= 1
            blockedNowCalls += 1
            let pending = blockedNowWaiters
            blockedNowWaiters = []
            for waiter in pending { waiter.resume() }
            await withCheckedContinuation { nowGate = $0 }
        }
        return current
    }

    /// 确定性等待：挂起直到已有 `count` 次 `now()` 调用被闸门拦住。
    func waitForBlockedNowCalls(_ count: Int = 1) async {
        while blockedNowCalls < count {
            await withCheckedContinuation { blockedNowWaiters.append($0) }
        }
    }

    func openNowGate() {
        nowGate?.resume()
        nowGate = nil
    }

    func sleep(seconds: TimeInterval) async throws {
        if seconds <= 0 { return }
        let id = UUID()
        let deadline = current + seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (deadline, continuation)
                    let pending = registrationWaiters
                    registrationWaiters = []
                    for waiter in pending { waiter.resume() }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseDueWaiters() -> Int {
        let due = waiters.filter { $0.value.deadline <= current }
        for (id, waiter) in due {
            waiters[id] = nil
            waiter.continuation.resume()
        }
        return due.count
    }

    @discardableResult
    func advanceToNextDeadline(
        where predicate: @Sendable (TimeInterval) -> Bool = { _ in true }
    ) async -> Int {
        while true {
            if let target = waiters.values.map({ $0.deadline }).filter(predicate).min() {
                current = max(current, target)
                return releaseDueWaiters()
            }
            await withCheckedContinuation { registrationWaiters.append($0) }
        }
    }
}

/// 可注入的假 SSE 流（零真实网络）。
actor FakeSSEStreamingTransport: SSEStreamingTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminateWaiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var terminated = false
    private var streamCallTotal = 0

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        streamCallTotal += 1
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.markTerminated() }
        }
        opened = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll()
        return stream
    }

    private func markTerminated() {
        terminated = true
        let pending = terminateWaiters
        terminateWaiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitUntilOpened() async {
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    /// 确定性等待：挂起直到底层流被终止（`onTermination` 信号）。
    func waitUntilTerminated() async {
        while !terminated {
            await withCheckedContinuation { terminateWaiters.append($0) }
        }
    }

    func send(_ text: String) { continuation?.yield(Data(text.utf8)) }
    func send(bytes: [UInt8]) { continuation?.yield(Data(bytes)) }
    func endStream() { continuation?.finish() }
    func failStream(_ error: Error) { continuation?.finish(throwing: error) }
    func isTerminated() -> Bool { terminated }
    func isOpened() -> Bool { opened }
    /// `stream()` 被调用的次数（D16：cancel 返回后不得再增加）。
    func streamCalls() -> Int { streamCallTotal }
}

/// 可注入的假计划卡轮询（零真实网络）。
actor FakePlanPoller: OneStepPlanPolling {
    private var responses: [Result<[OneStepPlanCardDto], Error>] = []
    private var calls = 0
    private var requestedSessionIds: [String] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ cards: [OneStepPlanCardDto]) {
        responses.append(.success(cards))
    }

    func enqueue(failure: Error) {
        responses.append(.failure(failure))
    }

    func pollPlans(sessionId: String) async throws -> [OneStepPlanCardDto] {
        calls += 1
        requestedSessionIds.append(sessionId)
        let pending = callWaiters
        callWaiters = []
        for waiter in pending { waiter.resume() }
        guard !responses.isEmpty else { return [] }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls }
    func sessionIds() -> [String] { requestedSessionIds }

    /// 确定性等待：挂起直到 `pollPlans` 至少被调用 `target` 次。
    func waitForCalls(_ target: Int) async {
        while calls < target {
            await withCheckedContinuation { callWaiters.append($0) }
        }
    }
}

/// 带闸门的计划卡轮询：回包停在闸门处，供测试制造「回包 ∥ 取消」与「慢回包」场景。
actor GatedPlanPoller: OneStepPlanPolling {
    private let response: [OneStepPlanCardDto]
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var autoRelease = false
    private var calls = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    init(response: [OneStepPlanCardDto]) {
        self.response = response
    }

    func pollPlans(sessionId: String) async throws -> [OneStepPlanCardDto] {
        calls += 1
        let pendingWaiter = callWaiters
        callWaiters = []
        for waiter in pendingWaiter { waiter.resume() }
        if !autoRelease {
            await withCheckedContinuation { pending.append($0) }
        }
        return response
    }

    /// 放行一次在途回包；若当前无在途则令后续调用不再阻塞。
    func releaseOne() {
        if pending.isEmpty {
            autoRelease = true
        } else {
            pending.removeFirst().resume()
        }
    }

    /// 放行全部在途回包并令后续调用不再阻塞。
    func release() {
        autoRelease = true
        let waiters = pending
        pending = []
        for waiter in waiters { waiter.resume() }
    }

    func callCount() -> Int { calls }

    /// 确定性等待：挂起直到 `pollPlans` 至少被调用 `target` 次（在闸门阻塞之前触发）。
    func waitForCalls(_ target: Int) async {
        while calls < target {
            await withCheckedContinuation { callWaiters.append($0) }
        }
    }
}

/// 汇总协调器输出流（测试用）；所有等待均为事件驱动（`append` 唤醒）。
actor FrameCollector {
    private var frames: [CovaSSEFrame] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func append(_ frame: CovaSSEFrame) {
        frames.append(frame)
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func snapshot() -> [CovaSSEFrame] { frames }

    func planCardCount() -> Int { frames.filter { $0.event == .planCard }.count }

    /// 确定性等待：挂起直到累计帧数达到 `target`。
    func waitForCount(_ target: Int) async {
        while frames.count < target {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// 确定性等待：挂起直到 `planCard` 帧数达到 `target`。
    func waitForPlanCardCount(_ target: Int) async {
        while frames.filter({ $0.event == .planCard }).count < target {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// 消费者完成标志：`for await` 循环真正退出（含未 append 的帧已处理完）后才为 true。
///
/// 用于消除「状态位已终态但消费者尚未 append」的测试侧竞态（M4）。
actor CompletionFlag {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        completed = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// 确定性等待：挂起直到消费者真正跑完。
    func wait() async {
        while !completed {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// 计数信号（测试用）：注入钩子每次触发 `increment()`，测试用 `waitFor(_:)` 确定性等待。
///
/// 用于把「被测代码执行到某点」变成可等待事件（如「第 n 个轮询周期已开始/已结束」），
/// 取代「让出 N 次调度」的启发式等待（D16⑤）。
actor SignalCounter {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func increment() {
        count += 1
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func value() -> Int { count }

    func waitFor(_ target: Int) async {
        while count < target {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// 有限让步轮询：**仅允许**用于等待 OS 线程事件（如 `URLProtocol` 已交付响应）的尽力观测，
/// **不得**作为断言依据（D16⑤ 禁止调度竞态断言）。协调器套件一律使用信号/闸门原语。
@discardableResult
func waitUntil(
    maxYields: Int = 10_000,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<maxYields {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// 结束消费者任务：先取消（解除未结束流上的 `for await` 阻塞）再等待。
/// 避免回归时测试永久悬挂，让失败以断言形式呈现而非 gate 超时。
func awaitConsumer(_ consumer: Task<Void, Never>) async {
    consumer.cancel()
    _ = await consumer.value
}

func makeSSEFrame(_ name: String, _ json: String = "{}", malformed: Bool = false) -> CovaSSEFrame {
    CovaSSEFrame(rawEventName: name, payload: Data(json.utf8), isMalformed: malformed)
}
