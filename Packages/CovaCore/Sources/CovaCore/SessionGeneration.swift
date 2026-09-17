import Foundation

/// 会话 generation（D8：登出/换号推进 generation，使在途异步结果失效）。
///
/// 语义：任何会改变「当前账号/会话」的操作都会把 generation 加一；
/// 异步结果回来时用**发起请求时的** generation 校验，不等于当前值即丢弃。
public struct SessionGeneration: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public static let initial = SessionGeneration(value: 0)

    public init(value: UInt64) {
        self.value = value
    }

    public func advanced() -> SessionGeneration {
        SessionGeneration(value: value &+ 1)
    }

    public static func < (lhs: SessionGeneration, rhs: SessionGeneration) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String { "gen-\(value)" }
}

/// generation 已过期（在途结果属于旧会话）。
public struct StaleSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    public let expected: SessionGeneration
    public let actual: SessionGeneration

    public init(expected: SessionGeneration, actual: SessionGeneration) {
        self.expected = expected
        self.actual = actual
    }

    public var description: String {
        "会话已失效（携带 \(expected)，当前 \(actual)）"
    }
}

/// 线程安全的 generation 推进与校验（Swift 6 actor 隔离）。
public actor SessionGenerationTracker {
    private var current: SessionGeneration

    public init(initial: SessionGeneration = .initial) {
        current = initial
    }

    /// 当前 generation 快照（发起异步请求时携带）。
    public func snapshot() -> SessionGeneration {
        current
    }

    /// 推进 generation，并返回新值（登出/换号/开始新会话时调用）。
    @discardableResult
    public func advance() -> SessionGeneration {
        current = current.advanced()
        return current
    }

    /// 在途结果是否仍属于当前会话。
    public func isCurrent(_ generation: SessionGeneration) -> Bool {
        generation == current
    }

    /// 校验在途结果；过期即抛 `StaleSessionError`。
    public func validate(_ generation: SessionGeneration) throws {
        guard generation == current else {
            throw StaleSessionError(expected: generation, actual: current)
        }
    }
}
