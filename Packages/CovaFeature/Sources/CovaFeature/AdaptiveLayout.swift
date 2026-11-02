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

    /// 顶层搜索格是否进页签栏（t84）：iPhone 底栏连搜索格最多 5 格，超出系统折出「更多」，
    /// 「我的」会被藏进去 ⇒ compact 宽度不显示搜索格（入口改为根屏放大镜）。
    static func showsSearchTab(isRegularWidth: Bool) -> Bool { isRegularWidth }

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
            if !CovaAdaptiveLayout.showsSearchTab(isRegularWidth: sizeClass == .regular) {
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
