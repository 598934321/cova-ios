import Foundation

/// 单调时钟抽象（降级状态机的超时与轮询节拍依赖它）。
///
/// 生产实现 = `SystemClock`（`ContinuousClock` + `Task.sleep`）；
/// 单测 = 注入的虚拟时钟（推进时间即可触发定时器，**不真实等待**）。
public protocol CovaClock: Sendable {
    /// 当前时间（秒，单调递增；仅用于求差值，绝对值无意义）。
    func now() async -> TimeInterval
    /// 睡眠指定秒数；被取消时抛 `CancellationError`。
    func sleep(seconds: TimeInterval) async throws
}

/// 生产时钟：`ContinuousClock` 取时 + `Task.sleep` 定时。
///
/// 无第三方依赖（仅 Foundation / Swift 标准库），平台中立（iOS/macOS 同编译）。
public struct SystemClock: CovaClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock().now
    }

    public func now() async -> TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock().now)
        let components = elapsed.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
