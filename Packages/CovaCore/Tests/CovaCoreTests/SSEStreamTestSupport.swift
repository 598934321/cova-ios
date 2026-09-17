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

    func now() -> TimeInterval { current }

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
