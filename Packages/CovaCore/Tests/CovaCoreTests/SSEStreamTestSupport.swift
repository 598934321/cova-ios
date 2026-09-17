import CovaCore
import Foundation
import XCTest

/// 虚拟时钟（单测；**不真实等待**）。
///
/// - `sleep` 注册等待者，只有 `advance(by:)` 才会放行；
/// - 取消（定时器被重置）会移除等待者并以 `CancellationError` 唤醒，避免悬挂。
actor VirtualClock: CovaClock {
    private var current: TimeInterval = 0
    private var waiters: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
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

    /// 推进虚拟时间，放行所有到期等待者。
    func advance(by seconds: TimeInterval) {
        current += seconds
        let due = waiters.filter { $0.value.deadline <= current }
        for (id, waiter) in due {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func pendingWaiterCount() -> Int { waiters.count }
}

/// 可注入的假 SSE 流（零真实网络）。
actor FakeSSEStreamingTransport: SSEStreamingTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var terminated = false

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
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

    private func markTerminated() { terminated = true }

    func waitUntilOpened() async {
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func send(_ text: String) { continuation?.yield(Data(text.utf8)) }
    func send(bytes: [UInt8]) { continuation?.yield(Data(bytes)) }
    func endStream() { continuation?.finish() }
    func failStream(_ error: Error) { continuation?.finish(throwing: error) }
    func isTerminated() -> Bool { terminated }
}

/// 可注入的假计划卡轮询（零真实网络）。
actor FakePlanPoller: OneStepPlanPolling {
    private var responses: [Result<[OneStepPlanCardDto], Error>] = []
    private var calls = 0
    private var requestedSessionIds: [String] = []

    func enqueue(_ cards: [OneStepPlanCardDto]) {
        responses.append(.success(cards))
    }

    func enqueue(failure: Error) {
        responses.append(.failure(failure))
    }

    func pollPlans(sessionId: String) async throws -> [OneStepPlanCardDto] {
        calls += 1
        requestedSessionIds.append(sessionId)
        guard !responses.isEmpty else { return [] }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls }
    func sessionIds() -> [String] { requestedSessionIds }
}

/// 汇总协调器输出流（测试用）。
actor FrameCollector {
    private var frames: [CovaSSEFrame] = []

    func append(_ frame: CovaSSEFrame) { frames.append(frame) }
    func snapshot() -> [CovaSSEFrame] { frames }
}

/// 消费者完成标志：`for await` 循环真正退出（含未 append 的帧已处理完）后才为 true。
///
/// 用于消除「状态位已终态但消费者尚未 append」的测试侧竞态（M4）。
actor CompletionFlag {
    private var completed = false
    func mark() { completed = true }
    func isCompleted() -> Bool { completed }
}

/// 有限让步轮询：等待条件成立（不真实等待，仅让出执行权）。
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

/// 以 1s 步进推进虚拟时间，直到条件成立或达到上限。
///
/// 相比一次 `advance(by: N)`，它对「定时器取消/重排之间的注册空窗」不敏感——无论等待者
/// 何时注册（deadline = 注册时刻 + 间隔），步进推进都能在有限上限内命中，消除测试侧时序竞态。
func advanceUntil(
    _ clock: VirtualClock,
    maxSeconds: Int = 200,
    _ condition: @Sendable () async -> Bool
) async {
    for _ in 0..<maxSeconds {
        if await condition() { return }
        await clock.advance(by: 1)
        await Task.yield()
    }
}

/// 结束消费者任务：先取消（解除未结束流上的 `for await` 阻塞）再等待。
/// 避免回归时测试永久悬挂，让失败以断言形式呈现而非 gate 超时。
func awaitConsumer(_ consumer: Task<Void, Never>) async {
    consumer.cancel()
    _ = await consumer.value
}

/// 断言条件最终成立（有限让步轮询；避免 `XCTAssert*(await …)` 的 autoclosure 限制）。
func assertEventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let ok = await waitUntil(condition)
    XCTAssertTrue(ok, "条件在有限让步内未成立", file: file, line: line)
}

func makeSSEFrame(_ name: String, _ json: String = "{}", malformed: Bool = false) -> CovaSSEFrame {
    CovaSSEFrame(rawEventName: name, payload: Data(json.utf8), isMalformed: malformed)
}
