import Foundation

/// 循环模式三态（design/screens/02-player.md §5）。
///
/// UI 侧的循环按钮按 `off → all → one → off` 显式转移（`advanced()`），
/// 不做隐式 toggle —— 转移表是产品口径的一部分，必须可被测试钉住。
///
/// `Codable`/`String` 原始值：仅本类型可持久化（模式不是敏感信息）；
/// 队列条目与地址刻意不可持久化，见 `PlaybackItem`。
public enum LoopMode: String, CaseIterable, Codable, Equatable, Sendable, CustomStringConvertible {
    /// 不循环：队列尾播完即停。
    case off
    /// 列表循环：末项播完回到首项。
    case all
    /// 单曲循环：当前项播完回到 0 继续。
    case one

    /// 按钮点击后的下一态（off → all → one → off）。
    public func advanced() -> LoopMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    /// 该模式是否会在播完时回到队列首项。
    public var wrapsToFirst: Bool { self == .all }

    /// 该模式是否重复当前项（只有 `.one` 在 itemEnd 时不换曲）。
    public var repeatsCurrentItem: Bool { self == .one }

    public var description: String { rawValue }
}
