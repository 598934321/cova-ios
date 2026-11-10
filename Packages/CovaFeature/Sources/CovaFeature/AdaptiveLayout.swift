import CovaUI
import SwiftUI

/// iPad 原生自适应（t74 · 2026-11-02 用户裁决：做原生 iPad，对齐 web 768×1024 设计）。
///
/// web 实拍（`qa-evidence/t74-clients/web/ipad-*.png`）的三条事实：
/// ① 768 宽时导航是**可收起的侧栏**（左上 sidebar 钮）——本端用 `TabView` 的
///    `.sidebarAdaptable`（iPad 侧栏 / iPhone 底栏，同一份页签声明）；
/// ② 卡片网格（歌单广场、榜单）在 768 宽是 **3 列**，手机是 2 列；
/// ③ 输入/表单类控件不跟着拉满整屏宽，居中限宽。
///
/// 判据收敛成纯函数（脱 UI 可测），视图只读 `horizontalSizeClass` 喂进来。
enum CovaAdaptiveLayout {
    /// regular 宽度下居中内容的最大宽度（web 首页输入卡在 768 宽约 640–720）。
    static let readableMaxWidth: CGFloat = 720

    /// 卡片网格列数：compact 2 / regular 3；AX 字号档各降一列（05 §Dynamic Type 的既有口径）。
    ///
    /// ⚠️ **只看 sizeClass 会在窄容器里挤出过挤的卡**（2026-11-11 用户实测 iPad 分屏后
    /// 「单纯拉伸」：795pt 栏里仍排 3 列，每卡仅 244pt）。带容器宽度反推的新实现见
    /// 下面的 `cardColumnCount(containerWidth:...)`；本函数保留为**列数上限的来源**
    /// 与既有测试/调用方的兼容入口。
    static func cardColumnCount(isRegularWidth: Bool, axLayout: Bool) -> Int {
        switch (isRegularWidth, axLayout) {
        case (false, false): return 2
        case (false, true): return 1
        case (true, false): return 3
        case (true, true): return 2
        }
    }

    static func cardColumns(isRegularWidth: Bool, axLayout: Bool, spacing: CGFloat) -> [GridItem] {
        let count = cardColumnCount(isRegularWidth: isRegularWidth, axLayout: axLayout)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    // MARK: - 按容器宽度反推列数（COVA-20261111-111）

    /// 单卡最小可读宽度。
    ///
    /// **标定依据**（实测数据，见 `归档/qa-evidence/COVA-20261111-111/`）：
    /// - iPhone 17 Pro 402pt / **2 列** ⇒ 每卡 **175.0pt**（已上线的可读形态，下限参照）
    /// - iPad 竖屏 834pt / 3 列 ⇒ 每卡 **256.5pt**（偏挤，用户未抱怨但已接近）
    /// - iPad 全屏 1600pt / 3 列 ⇒ 每卡 **512.0pt**（舒适）
    ///
    /// 取 **280pt** 而不是 175pt：175 是「能看」的下限，但 iPad 是横屏大屏场景，
    /// 卡片里放的是 16:10 封面 + 两行文字，175pt 会让封面显得局促。
    /// 280pt 的效果（实测反推）：
    /// - iPhone 402pt ⇒ 1 列（**注意**：会与 compact 的 2 列口径冲突，见下）
    /// - iPad 835pt ⇒ 2 列
    /// - iPad 1600pt ⇒ 3 列
    ///
    /// ⇒ **compact 宽度不走这条反推**（保持 2/1 列原口径），只有 regular 容器才按宽度收列。
    /// 这样 iPhone 的已知可读形态完全不变。
    static let minCardWidth: CGFloat = 280

    /// 卡片网格能容纳几列：按「容器宽 / 卡片最小宽」反推。
    ///
    /// - Parameters:
    ///   - containerWidth: 容器**可用宽度**（已扣水平页边距）
    ///   - minCardWidth: 单卡最小可读宽度
    ///   - spacing: 列间距
    ///   - maxColumns: 上限（由 `axLayout` 与 sizeClass 决定，见 `cardColumnLimit`）
    /// - Returns: 实际列数，至少 1 列
    static func cardColumnCount(
        containerWidth: CGFloat,
        minCardWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int
    ) -> Int {
        guard maxColumns >= 1 else { return 1 }
        guard containerWidth.isFinite, containerWidth > 0 else { return 1 }
        for n in stride(from: maxColumns, through: 1, by: -1) {
            let needed = CGFloat(n) * minCardWidth + CGFloat(n - 1) * spacing
            if needed <= containerWidth { return n }
        }
        return 1
    }

    /// 列数上限：由 sizeClass 与 AX 档决定（沿用 05 §Dynamic Type 的四象限）。
    /// 容器宽度只能在**上限之内**往下收，不能突破 AX 的降列口径。
    static func cardColumnLimit(isRegularWidth: Bool, axLayout: Bool) -> Int {
        cardColumnCount(isRegularWidth: isRegularWidth, axLayout: axLayout)
    }

    /// 完整判据：既有四象限上限 + 容器宽度反推，取**较小值**。
    ///
    /// compact 宽度（iPhone / iPad 分屏窄栏）**不参与反推** —— 保持 2/1 列原口径，
    /// 避免把已上线的 iPhone 形态改掉。
    static func resolvedCardColumnCount(
        isRegularWidth: Bool,
        axLayout: Bool,
        containerWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        let limit = cardColumnLimit(isRegularWidth: isRegularWidth, axLayout: axLayout)
        guard isRegularWidth else { return limit }   // compact 保持原口径
        return cardColumnCount(
            containerWidth: containerWidth,
            minCardWidth: minCardWidth,
            spacing: spacing,
            maxColumns: limit)
    }

    /// 顶层搜索格是否进页签栏（t84）：iPhone 底栏连搜索格最多 5 格，超出系统折出「更多」，
    /// 「我的」会被藏进去 ⇒ compact 宽度不显示搜索格（入口改为根屏放大镜）。
    /// t74c 复审：iPhone Plus / Pro Max **横屏**也是 regular 宽，但仍是底栏 ⇒ 6 格照样折「更多」；
    /// 所以还要判设备是 iPad（`isPad` 由视图读 `UIDevice.userInterfaceIdiom` 传入，纯函数可测）。
    static func showsSearchTab(isRegularWidth: Bool, isPad: Bool) -> Bool { isPad && isRegularWidth }

    /// 歌单详情大封面的上限（t84）：regular 宽 360pt 居中；compact 满宽（iPhone 不变）。
    static func heroArtworkMaxWidth(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? 360 : .infinity
    }

    /// 居中限宽的上限：compact（iPhone / iPad 分屏窄栏）不限宽。
    static func contentMaxWidth(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? readableMaxWidth : .infinity
    }
}

/// regular 宽度下把内容限宽居中；compact 原样（不改 iPhone 观感）。
struct CovaReadableWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: CovaAdaptiveLayout.contentMaxWidth(isRegularWidth: sizeClass == .regular))
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func covaReadableWidth() -> some View { modifier(CovaReadableWidthModifier()) }
}

/// t84：compact 宽度（iPhone / iPad 分屏窄栏）搜索格不进底栏 ⇒ 曲库、歌单根屏右上角补一个放大镜，
/// 栈内 push 25 搜索屏。regular 宽有顶层搜索页签，不重复放。
struct CovaCompactSearchEntryModifier: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            if !CovaAdaptiveLayout.showsSearchTab(
                isRegularWidth: sizeClass == .regular,
                isPad: UIDevice.current.userInterfaceIdiom == .pad) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { session.push(.search) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                    .accessibilityIdentifier("cova.search.open")
                }
            }
        }
    }
}

extension View {
    func covaCompactSearchEntry() -> some View { modifier(CovaCompactSearchEntryModifier()) }
}
