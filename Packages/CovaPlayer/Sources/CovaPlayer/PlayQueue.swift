import Foundation

/// 播放队列：**纯索引数学**（无副作用、无 async、无 I/O）。
///
/// 一切「为什么这样动」的裁决都收敛在这里，`PlaybackCoordinator` 只负责把这些结果
/// 变成引擎调用与状态迁移 —— 于是队列语义可以 100% 确定性测试。
///
/// 索引不变量（构造后恒成立）：
/// - `currentIndex == nil` ⟺ `items.isEmpty` 或「有队列但尚未选定当前项」；
/// - `currentIndex != nil` ⟹ `0 <= currentIndex < items.count`；
/// - 任何使 `items` 缩短的操作都会把 `currentIndex` 收敛到**同一身份**（或末项，或 nil）。
public struct PlayQueue: Equatable, Sendable {
    // MARK: - 结果类型

    /// 结构性失败原因（越界 / 空 / 找不到 / 未选曲）。
    ///
    /// `.tornDown` 是**唯一由上层产生的原因**：`PlayQueue` 本身没有生命周期概念，
    /// 该 case 只被 `PlaybackCoordinator` 用作「释放后一律拒绝」的返回值（缺陷 P3 的裁决）。
    public enum Failure: String, Equatable, Sendable, CustomStringConvertible {
        case emptyQueue
        case noCurrentIndex
        case indexOutOfRange
        case unknownItem
        case invalidDestination
        case tornDown

        public var description: String {
            switch self {
            case .emptyQueue: return "队列为空"
            case .noCurrentIndex: return "队列有项但尚未选定当前项"
            case .indexOutOfRange: return "索引越界"
            case .unknownItem: return "队列中不存在该曲目"
            case .invalidDestination: return "目标位置非法"
            case .tornDown: return "播放器已释放"
            }
        }
    }

    /// 变更类操作的结果。
    public enum Effect: Equatable, Sendable {
        case replaced(count: Int, current: Int?)
        case appended(at: Int)
        case insertedNext(at: Int)
        /// `current` = 变更后当前索引（`nil` = 已无当前项）。
        case removed(at: Int, remaining: Int, current: Int?)
        /// 拖拽排序：`current` 跟随**同一曲目**移动。
        case moved(from: Int, to: Int, current: Int?)
        case cleared
    }

    public enum Change: Equatable, Sendable {
        case applied(Effect)
        case rejected(Failure)
    }

    /// 推进类操作的结果（`next` / `previous` / `itemEnded` 共用）。
    public enum Step: Equatable, Sendable {
        /// 前进/后退到新索引；`wrapped` = 是否发生回绕。
        case moved(to: Int, wrapped: Bool)
        /// 不换曲，回到当前项 0 位置重播（`.one` 的 itemEnd）。
        case repeated(at: Int)
        /// 边界不动（`.off` / `.one` 下显式越过首尾）。
        case held
        /// `.off` 且末项播完：进入停止终态，不 wrap。
        case stopped
        case rejected(Failure)
    }

    /// 提交一个推进结果：**`step` 是纯查询，索引变更只在这里发生**。
    ///
    /// 拆成「计算 / 提交」两步，是为了让 `step` 可以在用例里被反复断言而不污染队列。
    /// 返回索引是否发生变化（`.repeated` / `.held` / `.stopped` 不改索引）。
    @discardableResult
    public mutating func apply(_ step: Step) -> Bool {
        switch step {
        case .moved(let index, _):
            guard items.indices.contains(index) else { return false }
            currentIndex = index
            return true
        case .repeated, .held, .stopped, .rejected:
            return false
        }
    }

    /// 推进的触发源：**同一模式在两种触发源下语义不同**（见裁决表）。
    public enum Trigger: Equatable, Sendable {
        /// 用户点按 ⏭ / ⏮。
        case userInitiated
        /// 引擎上报当前项播完。
        case itemEnded
        /// 当前项播放失败后自动跳下一首（design §9）。
        case itemFailed
    }

    public enum Direction: Equatable, Sendable {
        case forward
        case backward
    }

    // MARK: - 状态

    public private(set) var items: [PlaybackItem]
    public private(set) var currentIndex: Int?

    /// - Parameter currentIndex: `nil` 表示「有队列但尚未选曲」（该状态由 `insertNext` /
    ///   `append` 保持，只有 `replace` 与导航会选曲）；越界索引钳到边界。
    public init(items: [PlaybackItem] = [], currentIndex: Int? = nil) {
        self.items = items
        guard let requested = currentIndex else { return }
        self.currentIndex = Self.clampedIndex(requested, count: items.count)
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// 当前项投影（不是「效果」，因此允许 Optional）。
    public var current: PlaybackItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public func contains(itemID: String) -> Bool {
        items.contains { $0.id == itemID }
    }

    public func index(ofItemID itemID: String) -> Int? {
        items.firstIndex { $0.id == itemID }
    }

    // MARK: - 变更

    /// 整队替换：越界起点钳制到末项；空队列 → 无当前项。
    public mutating func replace(_ items: [PlaybackItem], startingAt start: Int = 0) -> Change {
        self.items = items
        guard let index = Self.clampedIndex(start, count: items.count) else {
            currentIndex = nil
            return .applied(.replaced(count: 0, current: nil))
        }
        currentIndex = index
        return .applied(.replaced(count: items.count, current: index))
    }

    /// 清空。
    public mutating func removeAll() -> Change {
        items = []
        currentIndex = nil
        return .applied(.cleared)
    }

    /// 追加到队尾（允许同曲重复入队 —— 是否去重是上层产品决策，不是队列数学）。
    ///
    /// 追加**不选曲**：空队列追加后 `currentIndex` 仍为 nil（选曲只经 `replace` 或导航）。
    public mutating func append(_ item: PlaybackItem) -> Change {
        items.append(item)
        return .applied(.appended(at: items.count - 1))
    }

    /// 插到当前项之后（用户「下一首播这个」）。
    ///
    /// 无当前项（未选曲）时退化为队尾追加，且不改变 `currentIndex`。
    public mutating func insertNext(_ item: PlaybackItem) -> Change {
        guard let currentIndex else {
            items.append(item)
            return .applied(.insertedNext(at: items.count - 1))
        }
        let destination = min(currentIndex + 1, items.count)
        items.insert(item, at: destination)
        return .applied(.insertedNext(at: destination))
    }

    /// 按索引移除。
    public mutating func remove(at index: Int) -> Change {
        guard !items.isEmpty else { return .rejected(.emptyQueue) }
        guard items.indices.contains(index) else { return .rejected(.indexOutOfRange) }
        items.remove(at: index)
        return .applied(.removed(at: index, remaining: items.count, current: refreshCurrent(afterRemoving: index)))
    }

    /// 按曲目 id 移除（移除**首个**匹配项）。
    public mutating func remove(itemID: String) -> Change {
        guard let index = index(ofItemID: itemID) else { return .rejected(.unknownItem) }
        return remove(at: index)
    }

    /// 拖拽排序：`to` 是**移动后**该元素所在索引（与 `List`/`UICollectionView` 的 move 口径一致）。
    ///
    /// 当前索引按「身份不变」规则随位移修正：被移动的就是当前项 → 当前项换到新位置；
    /// 否则按「先移除后插入」的净位移修正。
    public mutating func move(from: Int, to destination: Int) -> Change {
        guard !items.isEmpty else { return .rejected(.emptyQueue) }
        guard items.indices.contains(from) else { return .rejected(.indexOutOfRange) }
        guard items.indices.contains(destination) else { return .rejected(.invalidDestination) }
        guard from != destination else {
            return .applied(.moved(from: from, to: destination, current: currentIndex))
        }
        let item = items.remove(at: from)
        items.insert(item, at: destination)
        let current = refreshCurrent(afterMovingFrom: from, to: destination)
        return .applied(.moved(from: from, to: destination, current: current))
    }

    // MARK: - 推进（裁决表所在）

    /// 在给定循环模式与触发源下推进当前索引。
    ///
    /// 裁决表（详见 `docs/log/20260921.md` §状态规则裁决表）：
    /// - `.one` + `itemEnded` → `.repeated`（不换曲，回到 0；**优先于**「后面还有曲目」）；
    /// - `.off` + `itemEnded` 于末项 → `.stopped`（**不 wrap**）；
    /// - `.all` 于末项（任意触发源）→ `.moved(to: 0, wrapped: true)`；单元素队列 → `.repeated`；
    /// - 显式 `next` 于末项且模式为 `.off` → `.held`（越界不动，也不进停止态）；
    /// - 显式 `previous` 于首项：`.all` 回绕末项，其余 `.held`；
    /// - `itemFailed` **永不**「重复当前项」——`.one` 在失败时按 `.all` 前进（否则对坏项无限重试）。
    public func step(direction: Direction, trigger: Trigger, under mode: LoopMode) -> Step {
        guard !items.isEmpty else { return .rejected(.emptyQueue) }
        guard let index = currentIndex else {
            // 未选曲时，用户显式导航即完成选曲（从首项开始）；自动推进无意义。
            guard trigger == .userInitiated else { return .rejected(.noCurrentIndex) }
            return .moved(to: 0, wrapped: false)
        }
        switch direction {
        case .forward:
            return forward(from: index, trigger: trigger, mode: mode)
        case .backward:
            return backward(from: index, mode: mode)
        }
    }

    private func forward(from index: Int, trigger: Trigger, mode: LoopMode) -> Step {
        // `.one` 的 itemEnd 优先于「后面还有曲目」：播完即回到当前项 0 位置，不换曲。
        if trigger == .itemEnded, mode.repeatsCurrentItem { return .repeated(at: index) }
        let next = index + 1
        if items.indices.contains(next) { return .moved(to: next, wrapped: false) }
        switch trigger {
        case .itemEnded:
            if mode.repeatsCurrentItem { return .repeated(at: index) }
            if mode.wrapsToFirst { return wrap(from: index) }
            return .stopped
        case .itemFailed:
            // **失败口径（与「播完」刻意不对称，P1c 的裁决）**：失败永远**尝试**离开当前项 ——
            // `.off` 末项播完即停，但末项失败回绕首项继续（design §9「自动跳下一首」）；
            // `.one` 下失败也不原地重试坏源，同样按回绕前进。
            // 唯一例外是**单元素队列**：无处可跳 → `wrap` 只能给出 `.repeated(当前)`，
            // 由 `PlaybackCoordinator.apply(.repeated)` 的一致性闸门收敛为「停止 + 终态」
            // （引擎里没有可播条目时绝不声称 `.playing`）。
            return wrap(from: index)
        case .userInitiated:
            return mode.wrapsToFirst ? wrap(from: index) : .held
        }
    }

    private func backward(from index: Int, mode: LoopMode) -> Step {
        let previous = index - 1
        if previous >= 0 { return .moved(to: previous, wrapped: false) }
        return mode.wrapsToFirst ? wrap(from: index) : .held
    }

    private func wrap(from index: Int) -> Step {
        // 单元素队列：回绕即「同一项重来」。
        guard items.count > 1 else { return .repeated(at: index) }
        if index == items.count - 1 { return .moved(to: 0, wrapped: true) }
        return .moved(to: items.count - 1, wrapped: true)
    }

    // MARK: - 私有索引修正

    /// 移除后的当前索引修正：
    /// - 队列已空 → nil；
    /// - 移除的就是当前项 → 指向**同位置的新元素**（末项被删则退一位）；
    /// - 移除项在当前项之前 → 当前索引前移一位；
    /// - 其余不变。
    mutating func refreshCurrent(afterRemoving removed: Int) -> Int? {
        guard let current = currentIndex else { return nil }
        if items.isEmpty {
            currentIndex = nil
            return nil
        }
        if removed == current {
            currentIndex = min(current, items.count - 1)
            return currentIndex
        }
        if removed < current {
            currentIndex = current - 1
            return currentIndex
        }
        return current
    }

    /// 位移后的当前索引修正（`move`）：`from == current` 时由 `wrap`/插入位置直接决定。
    mutating func refreshCurrent(afterMovingFrom from: Int, to destination: Int) -> Int? {
        guard let current = currentIndex else { return nil }
        if from == current {
            currentIndex = destination
            return destination
        }
        var adjusted = current
        if from < adjusted { adjusted -= 1 }
        if destination <= adjusted { adjusted += 1 }
        currentIndex = Self.clampedIndex(adjusted, count: items.count)
        return currentIndex
    }

    static func clampedIndex(_ raw: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(raw, 0), count - 1)
    }
}
