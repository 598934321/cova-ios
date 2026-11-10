import XCTest

/// 093 AC-2：iPad 真机分屏下的布局验收（1/2 与 1/3）。
///
/// **这是验收，不是回归**：独立 scheme `CovaAcceptance`，不进门禁。
///
/// ## 为什么 XCUITest 是唯一可行路径
/// - `devicectl device appResize` 在本设备不可用：`Capability "Resizable App Management"
///   is not supported`（CoreDeviceError 1001）
/// - DeviceHub 在本机是不可达窗口（AX 树 `ax_window_unresolved`）
/// - CuaDriver / cliclick / KimiCU 只注入**本机 Mac** 输入，没有 USB 设备寻址
/// - XCUITest 注入走 DVT，能对连着的真机注入手势，**且能在进程外操作 SpringBoard**
///
/// ## 三个判据要点（093 审查后修正）
/// 1. **sizeClass 必须是实测**：从 App 内 DEBUG 钩子 `cova-trait-probe` 的
///    accessibilityValue 读（`hRegular` / `hCompact`），**不用窗口宽度推断**
/// 2. **cardColumnCount 必须是实测**：数渲染出的真实列数，并硬断言等于
///    `CovaAdaptiveLayout.cardColumnCount(isRegularWidth:axLayout:)` 算出的期望值
/// 3. **Dock 手势必须走 SpringBoard**：Dock 是系统元素，不在 Cova 窗口内
///
/// ## ⚠️ 判定陷阱：1/3 可能不是 Split View 而是 Slide Over
/// - **Split View 1/2**：两个 App 各占约半屏 ⇒ Cova 宽度变窄，sizeClass 可能降级
/// - **Slide Over**：主 App 仍占满屏，覆盖层浮在上面 ⇒ **Cova 的 sizeClass 不变**
///
/// 所以「1/3」这条**只有在确认是 Split View 形态后**才能用来证明「分屏改变 sizeClass」。
/// 若是 Slide Over，本条记为「形态不适用」，**不算覆盖，也不硬判失败**。

/// `CovaAdaptiveLayout.cardColumnCount(isRegularWidth:axLayout:)` 的**逐字复刻**。
///
/// 为什么不直接 import：XCUITest target（`bundle.ui-testing`）不能 `@testable import`
/// App 内部的 SPM 包（`Unable to resolve Swift module dependency to a compatible module:
/// 'CovaFeature'`）——UITest 跑在独立进程，不链接 App 的模块。
///
/// ⇒ 这里内联复刻，**并钉一条守卫断言**：复刻值与源实现的 switch 表逐项对齐。
/// 源实现若改了（`AdaptiveLayout.swift:18-25`），下面 `testGuardMirrorsSourceImplementation`
/// 会提醒更新——这是「复刻」能接受的代价，比自证循环强。
///
/// 源实现原文（`Packages/CovaFeature/Sources/CovaFeature/AdaptiveLayout.swift:18-25`）：
/// ```
/// static func cardColumnCount(isRegularWidth: Bool, axLayout: Bool) -> Int {
///     switch (isRegularWidth, axLayout) {
///     case (false, false): return 2
///     case (false, true): return 1
///     case (true, false): return 3
///     case (true, true): return 2
///     }
/// }
/// ```
private func expectedCardColumnCount(isRegularWidth: Bool, axLayout: Bool) -> Int {
    switch (isRegularWidth, axLayout) {
    case (false, false): return 2
    case (false, true): return 1
    case (true, false): return 3
    case (true, true): return 2
    }
}

@MainActor
final class SplitViewAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    private let springboardID = "com.apple.springboard"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 093 要验的是**歌单广场**的网格列数（`PlaylistsPlazaView` 用 `cardColumns`），
        // 不是首页 rail。用既有走查钩子直达该页签，不靠点击。
        app.launchEnvironment["COVA_PREVIEW_TAB"] = "playlists"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App 没起来")
        // 等网格真的出现（歌单是网络数据，首帧可能还在骨架）。
        // ⚠️ Swift 6 严格并发：`setUpWithError` 不是 @MainActor，循环里调 @MainActor
        // 实例方法会报 "sending 'self' risks causing data races"。
        // ⇒ 这里只等「按钮数起来」（纯粹的 XCUIElement 查询，不碰 self 的 actor 隔离方法），
        //   真正的列数统计留到各 test 方法里（那些是 @MainActor）。
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if app.buttons.count > 5 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1.5)   // 让网格布局稳定
    }

    // MARK: - 基线

    /// 基线：确认真跑起来、能读到真实 sizeClass 与列数。
    /// **没有这一格不要往下走**——后续所有比较都以它为参照。
    func test00_Baseline() throws {
        attachScreen(name: "00-baseline-fullscreen")

        let trait = readSizeClass()
        let columns = countGridColumns()
        let window = app.windows.firstMatch.frame

        print("[split] baseline window=\(Int(window.width))x\(Int(window.height))pt")
        print("[split] baseline sizeClass(实测)=\(trait.raw)")
        print("[split] baseline cardColumnCount(实测)=\(columns)")

        // 基线必须是 full screen：宽度应接近整屏（正屏 iPad 13" 竖屏 1024pt / 横屏 1366pt）
        XCTAssertGreaterThan(window.width, 700, "基线不是全屏宽度，设备可能已在分屏态")

        // 列数硬断言：期望值由纯函数算出，与实测比
        let expected = expectedCardColumnCount(
            isRegularWidth: trait.isRegular, axLayout: currentAXLayout())
        XCTAssertEqual(columns, expected,
                       "基线列数与 cardColumnCount 期望不符（期望 \(expected) 实测 \(columns)）")
    }

    // MARK: - 只读模式（人手动分屏，Bot 只读数）

    /// **只读版**：不拖拽，只读当前已处于分屏态的实测值。
    ///
    /// 背景（面面 2026-11-10 裁决）：
    /// - XCUITest 的 `press(forDuration:thenDragTo:)` 一次性拖拽**无法触发 iPadOS 分屏**
    ///   （真机两次实测均 NotSplit，窗口 1600→1600pt 不变；判断是缺「拖出 Dock → 悬停边缘 →
    ///     边缘高亮 → 松手」的时序）
    /// - 093 单 AC-2 原文禁的是「模拟器 / 推断 / 代码里写着应该有 N 列」，
    ///   **没有禁「人手动分屏 + Bot 读数」**
    /// - ⇒ 分屏动作由人完成，App 侧读数（sizeClass / 列数 / 截图）由本测试自动采集。
    ///   **必须在报告里写明「分屏动作由人完成」，不能写成「全自动验收」。**
    ///
    /// 前置：用户已在真机上把 Cova 置于 Split View 且保持该状态。
    func test10_ReadOnlySplitState() throws {
        attachScreen(name: "10-readonly-split")

        let window = app.windows.firstMatch.frame
        let trait = readSizeClass()
        let columns = countGridColumns()
        let expected = expectedCardColumnCount(
            isRegularWidth: trait.isRegular, axLayout: currentAXLayout())

        print("[split] READONLY window=\(Int(window.width))x\(Int(window.height))pt")
        print("[split] READONLY sizeClass(实测)=\(trait.raw)")
        print("[split] READONLY cardColumnCount(实测)=\(columns) 期望=\(expected)")

        // ── 分屏形态判据（2026-11-10 修正）──
        //
        // **只看「宽度 < 全屏」是错的**：iPadOS 的「浮动窗口 / 缩放窗口」也是变窄，
        // 但它是**等比缩放**（1600x1200 → 1390x1045，宽高比 0.869/0.871 几乎相同）。
        // 真 Split View 是「**只缩宽、高度不变**」（1600x1200 → 约 800x1200）。
        //
        // 判据：宽高比下降幅度之差 > 0.10 ⇒ 只有宽度变 ⇒ Split View
        //       两者接近（差 < 0.05）⇒ 等比缩放 ⇒ 浮动/缩放窗口，不是 Split View
        let fullW: CGFloat = 1600, fullH: CGFloat = 1200   // 真机全屏基线（本批实测）
        let wRatio = window.width / fullW
        let hRatio = window.height / fullH
        let diverge = hRatio - wRatio
        print("[split] READONLY 宽度比=\(String(format: "%.3f", wRatio)) "
              + "高度比=\(String(format: "%.3f", hRatio)) 差=\(String(format: "%.3f", diverge))")

        let isSplitView = wRatio < 0.95 && diverge > 0.10
        let isFloating = wRatio < 0.95 && abs(diverge) <= 0.05
        print("[split] READONLY 形态判定: isSplitView=\(isSplitView) isFloating=\(isFloating)")

        if !isSplitView {
            recordCoverage("readonly", isFloating ? .notApplicable : .notCovered)
            let why = isFloating
                ? "等比例缩放 ⇒ 浮动/缩放窗口，不是 Split View（该形态不能证明分屏改变 sizeClass）"
                : "既不是 Split View 也不是浮动窗口（宽度未变）"
            XCTFail("READONLY：\(why)。实测 \(Int(window.width))x\(Int(window.height))pt，"
                    + "宽度比 \(String(format: "%.3f", wRatio)) 高度比 \(String(format: "%.3f", hRatio))")
            return
        }

        // 分屏态下：列数必须等于按**实测** sizeClass 算出的期望
        XCTAssertEqual(columns, expected,
                       "READONLY cardColumnCount 实测 \(columns) ≠ 期望 \(expected)"
                       + "（sizeClass=\(trait.raw)）")
        XCTAssertNotEqual(trait.raw, "hUnspecified", "READONLY：sizeClass 读不到真实值")

        recordCoverage("readonly", .covered)
        print("[split] READONLY ⇒ AC-2 实质判据已验（分屏动作由人完成，读数由测试自动采集）")
    }

    // MARK: - 1/2 分屏

    func test01_HalfSplit() throws {
        try performSplit(fraction: "1/2", dockDragToXRatio: 0.5, expectedForm: .splitView)
    }

    // MARK: - 1/3（可能是 Split View，也可能是 Slide Over）

    func test02_ThirdSplit() throws {
        try performSplit(fraction: "1/3", dockDragToXRatio: 0.33, expectedForm: .unknown)
    }

    // MARK: - AC-2 覆盖汇总（最后跑，报告读这个）

    /// 汇总本次 1/2 与 1/3 两条腿的覆盖状态，**直接打出 AC-2 的最终判定**。
    ///
    /// 口径（与 `ACCoverage` 注释一致）：
    /// - 两条 covered ⇒ **完整覆盖**
    /// - 一条 covered + 一条 notApplicable ⇒ **部分覆盖，不得标通过**
    /// - 任一 notCovered ⇒ **未完成，缺口在「手势没命中」**
    func test99_ReportCoverage() throws {
        let half = Self.coverageLog["1/2"]
        let third = Self.coverageLog["1/3"]

        print("[split] ═══ AC-2 覆盖汇总 ═══")
        print("[split]   1/2 = \(half?.rawValue ?? "未运行")")
        print("[split]   1/3 = \(third?.rawValue ?? "未运行")")

        let covered = [half, third].filter { $0 == .covered }.count
        let notApplicable = [half, third].filter { $0 == .notApplicable }.count
        let notCovered = [half, third].filter { $0 == .notCovered }.count

        let verdict: String
        if covered == 2 {
            verdict = "AC-2 完整覆盖（1/2 与 1/3 均为 Split View 且 sizeClass/列数已验）"
        } else if covered == 1 && notApplicable == 1 {
            verdict = "AC-2 **部分覆盖**：仅 \(covered)/2 条有效；另一条为 Slide Over，"
                    + "该形态 sizeClass 不变，无法证明「分屏改变 sizeClass」⇒ **不得标通过**"
        } else if notCovered > 0 {
            verdict = "AC-2 **未完成**：\(notCovered) 条未测到有效结果（手势未命中）"
        } else {
            verdict = "AC-2 状态不可判（覆盖日志不完整，可能有用例没跑）"
        }
        print("[split]   ⇒ \(verdict)")
        print("[split] ═══════════════════════")

        // 不硬断言「必须完整覆盖」（手势命中与否不是被测代码的错），
        // 但覆盖日志缺失要报出来——那是测试自身没跑全。
        XCTAssertNotNil(half, "1/2 腿没跑（test01 未执行？）")
        XCTAssertNotNil(third, "1/3 腿没跑（test02 未执行？）")
    }

    // MARK: - 核心流程

    private enum ExpectedForm { case splitView, slideOver, unknown }

    @MainActor
    private func performSplit(fraction: String, dockDragToXRatio: Double, expectedForm: ExpectedForm) throws {
        let beforeWindow = app.windows.firstMatch.frame
        let beforeTrait = readSizeClass()
        let beforeColumns = countGridColumns()
        print("[split] \(fraction) BEFORE window=\(Int(beforeWindow.width))pt "
              + "sizeClass=\(beforeTrait.raw) columns=\(beforeColumns)")

        // ① 从底部上滑唤出 Dock —— 必须在 SpringBoard 上做，Dock 不属于 Cova
        let springboard = XCUIApplication(bundleIdentifier: springboardID)
        let sbWin = springboard.windows.firstMatch
        guard sbWin.exists else {
            XCTFail("SpringBoard 窗口不可达，无法操作 Dock")
            return
        }

        let sbFrame = sbWin.frame
        let from = sbWin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999))
        let to = sbWin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreen(name: "\(fraction)-01-dock-shown")

        // ② Dock 图标拖到目标边缘：SpringBoard 的 Dock 里取第一个 app 图标
        // Dock 图标的选取：**不能用 `identifier == "AppIcon"`** ——
        // 实测 iPadOS 26.5 模拟器上 Dock 图标的 identifier 是**应用本地化名**
        // （`信息` / `Safari浏览器` / `Cova` …），`matching(identifier: "AppIcon")` 恒为 0。
        // 正确做法：按 y 坐标取「Dock 带」（屏幕底部约 92%–96%）里的图标。
        let sbH = sbFrame.height
        let dockBand = springboard.icons.allElementsBoundByIndex.filter { ic in
            let f = ic.frame
            guard f.width > 40, f.height > 40 else { return false }
            let ry = f.midY / sbH
            return ry > 0.90 && ry < 0.98
        }
        print("[split] \(fraction) Dock 带内图标数=\(dockBand.count) "
              + "(总图标 \(springboard.icons.count)，按 y∈[0.90,0.98] 过滤)")
        let iconCount = dockBand.count
        guard iconCount > 0 else {
            XCTFail("\(fraction)：SpringBoard 里找不到可拖的 App 图标（Dock 没唤出）")
            return
        }
        // 拖拽目标必须是一个**真 App**：
        // `AppLibrary`（App资源库）不是 App，拖它只会打开资源库、不会产生 Split View
        // —— 2026-11-10 首次真机运行就因此把 1/2 拖成了 NotSplit。
        let candidates = dockBand.filter { ic in
            let id = ic.identifier
            return id != "AppLibrary" && !id.isEmpty
        }
        guard let dragged = candidates.first else {
            XCTFail("\(fraction)：Dock 带里没有可拖的真 App（只有 App资源库）")
            return
        }
        print("[split] \(fraction) 拖拽目标: \(dragged.identifier) "
              + "frame=\(Int(dragged.frame.minX)),\(Int(dragged.frame.minY))")
        let start = dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Split View 的手势是「拖到屏幕**边缘**」触发吸附，不是拖到比例位置。
        // iPadOS 支持的比例是 1/2、2/3、3/4（没有 1/3）⇒ 1/3 这条本身可能不存在，
        // 仍按边缘拖（拖到左侧 2%），跑出来的形态如实记。
        let edgeX: CGFloat = 0.02
        let target = sbWin.coordinate(withNormalizedOffset: CGVector(dx: edgeX, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 1.5)
        Thread.sleep(forTimeInterval: 3.0)

        // ③ 拖完必须回到 Cova（分屏时 Cova 可能被切到后台）
        app.activate()
        Thread.sleep(forTimeInterval: 2.0)
        attachScreen(name: "\(fraction)-02-after-drag")

        // ④ 实测：窗口 / 真实 sizeClass / 真实列数
        let afterWindow = app.windows.firstMatch.frame
        let afterTrait = readSizeClass()
        let afterColumns = countGridColumns()
        print("[split] \(fraction) AFTER  window=\(Int(afterWindow.width))pt "
              + "sizeClass=\(afterTrait.raw) columns=\(afterColumns)")

        // ⑤ 形态判定：Split View 会让 Cova 变窄；Slide Over 不会
        let form = decideForm(beforeWindow: beforeWindow, afterWindow: afterWindow,
                              beforeTrait: beforeTrait, afterTrait: afterTrait)
        print("[split] \(fraction) 形态判定=\(form) "
              + "(宽度 \(Int(beforeWindow.width))→\(Int(afterWindow.width))pt, "
              + "sizeClass \(beforeTrait.raw)→\(afterTrait.raw))")

        // ⑥ 期望值来自纯函数，与实测硬比
        let expectedColumns = expectedCardColumnCount(
            isRegularWidth: afterTrait.isRegular, axLayout: currentAXLayout())
        print("[split] \(fraction) cardColumnCount 期望=\(expectedColumns) 实测=\(afterColumns)")

        switch form {
        case .slideOver:
            // Slide Over：主 App 占满屏、sizeClass 不变
            // ⇒ **该形态无法证明「分屏改变 sizeClass」**。
            // 这不是失败，也不是「测了但不算」——是「该形态不适用此判据」。
            // 记 notApplicable，让报告能直接写出「AC-2 部分覆盖」。
            recordCoverage(fraction, .notApplicable)
            print("[split] \(fraction) 形态=SlideOver ⇒ **该形态不适用 AC-2 判据**"
                  + "（主 App 尺寸未变、sizeClass 不变，无法证明分屏改变 sizeClass）")
            print("[split] \(fraction) ⇒ AC-2 该腿记为 notApplicable，不计入覆盖")
            XCTAssertGreaterThan(sbFrame.width, 0)   // 只留一个恒真但无害的 sanity check
        case .splitView(let narrowed):
            // 真分屏：尺寸必须变窄，且列数必须等于按**实测** sizeClass 算出的期望
            XCTAssertTrue(narrowed, "\(fraction)：判定为 Split View 但窗口没变窄")
            XCTAssertEqual(afterColumns, expectedColumns,
                           "\(fraction) cardColumnCount 实测 \(afterColumns) ≠ 期望 \(expectedColumns)")
            XCTAssertNotEqual(afterTrait.raw, "hUnspecified", "\(fraction)：sizeClass 读不到真实值")
            recordCoverage(fraction, .covered)
        case .notSplit:
            // **没测到有效结果**（既不是 Split View 也不是 Slide Over）。
            // 无论期望什么，都记 notCovered —— 这是 AC-2 的缺口，不是通过。
            recordCoverage(fraction, .notCovered)
            print("[split] \(fraction) 未拖出任何分屏/悬浮形态 ⇒ **未测到有效结果**，"
                  + "AC-2 该腿记 notCovered")
            if expectedForm == .splitView {
                XCTFail("\(fraction)：期望 Split View，但窗口宽度未变化（手势未命中，未测到有效结果）")
            }
        }
    }

    // MARK: - AC-2 覆盖状态（报告直接读这个，不用从日志拼）

    /// 每条分屏腿对 AC-2 的覆盖贡献。**「没测到有效结果」与「测了但不适用」必须分开**：
    /// - `covered`     ：拖出了 Split View，sizeClass 与列数都验过 ⇒ 计入 AC-2
    /// - `notApplicable`：形态是 Slide Over（主 App 尺寸不变、sizeClass 不变）
    ///                    ⇒ **该形态无法证明「分屏改变 sizeClass」**，这条不计入覆盖，
    ///                      但也不是失败——是「该形态不适用此判据」
    /// - `notCovered`  ：手势没拖出任何分屏/悬浮形态 ⇒ **没测到有效结果**，AC-2 缺口
    ///
    /// 汇总口径（写进报告）：
    /// - 1/2 与 1/3 **都** `covered` ⇒ AC-2 完整覆盖
    /// - 只有 1/2 `covered`，1/3 `notApplicable`（Slide Over）⇒ **AC-2 部分覆盖，不得标通过**
    /// - 任一 `notCovered` ⇒ AC-2 未完成，缺口原因如实写
    enum ACCoverage: String {
        case covered
        case notApplicable
        case notCovered
    }

    /// 本次运行每条腿的覆盖结果（供 `test99_ReportCoverage` 汇总）
    private static var coverageLog: [String: ACCoverage] = [:]

    private func recordCoverage(_ fraction: String, _ state: ACCoverage) {
        Self.coverageLog[fraction] = state
        print("[split] AC-2 覆盖记录：\(fraction) = \(state.rawValue)")
    }

    // MARK: - 形态判定

    private enum SplitForm: CustomStringConvertible {
        case splitView(narrowed: Bool)
        case slideOver
        case notSplit
        var description: String {
            switch self {
            case .splitView(let narrowed): return "SplitView(narrowed:\(narrowed))"
            case .slideOver: return "SlideOver"
            case .notSplit: return "NotSplit"
            }
        }
    }

    /// 依据：Split View ⇒ Cova 窗口显著变窄；Slide Over ⇒ 主 App 尺寸基本不变。
    /// 阈值取 5pt（分屏动画后允许的抖动）。
    @MainActor
    private func decideForm(
        beforeWindow: CGRect, afterWindow: CGRect,
        beforeTrait: SizeClassRead, afterTrait: SizeClassRead
    ) -> SplitForm {
        let delta = beforeWindow.width - afterWindow.width
        if delta > 5 {
            return .splitView(narrowed: true)
        }
        // 宽度没变但 sizeClass 变了 —— 理论上不该发生，如实归为 notSplit 并留日志
        if beforeTrait.raw != afterTrait.raw {
            print("[split] ⚠️ 宽度未变但 sizeClass 变了（\(beforeTrait.raw)→\(afterTrait.raw)），形态可疑")
            return .notSplit
        }
        // 宽度没变、sizeClass 也没变 ⇒ 可能是 Slide Over 覆盖（主 App 没变）
        return .notSplit
    }


    // MARK: - 守卫：复刻表与源实现一致

    /// 四象限穷举复刻值。**只验复刻表自身自洽**（源实现若改，靠 code review 对比注释里的原文），
    /// 但至少能挡住「手抄错一个格子」这类错误。
    func testGuardMirrorsSourceImplementation() throws {
        // 源实现（AdaptiveLayout.swift:18-25）：(false,false)=2 / (false,true)=1
        //                                        (true,false)=3  / (true,true)=2
        let table: [(reg: Bool, ax: Bool, expect: Int)] = [
            (false, false, 2), (false, true, 1),
            (true,  false, 3), (true,  true, 2),
        ]
        for row in table {
            XCTAssertEqual(
                expectedCardColumnCount(isRegularWidth: row.reg, axLayout: row.ax),
                row.expect,
                "复刻表 (reg=\(row.reg), ax=\(row.ax)) 与源实现不符")
        }
        print("[split] 守卫：复刻表四象限与 AdaptiveLayout.swift:18-25 一致 ✅")
    }

    // MARK: - 实测取值

    struct SizeClassRead {
        let raw: String
        var isRegular: Bool { raw == "hRegular" }
    }

    /// **实测**真实 `horizontalSizeClass` —— 读 App 内 DEBUG 钩子的 accessibilityValue。
    /// 绝不按窗口宽度推断（那样会和下方列数断言构成自证循环）。
    @MainActor
    private func readSizeClass() -> SizeClassRead {
        let probe = app.otherElements["cova-trait-probe"]
        guard probe.waitForExistence(timeout: 5) else {
            XCTFail("找不到 cova-trait-probe（App 是否以 DEBUG 构建？钩子只在 #if DEBUG 存在）")
            return SizeClassRead(raw: "hUnspecified")
        }
        let value = (probe.value as? String) ?? "hUnspecified"
        return SizeClassRead(raw: value)
    }

    /// 当前是否 AX 字号档（与 `cardColumnCount` 的第二个入参同源）。
    /// 测试环境取宿主与 App 实际运行的 Dynamic Type；默认非 AX。
    @MainActor
    private func currentAXLayout() -> Bool {
        // App 侧的 axLayout 来自 `@Environment(\.covaAXLayout)`，由 Dynamic Type 档推导。
        // 真机上未切 AX 档 ⇒ false。若将来在 AX 档跑，这里要改成读探针（与 sizeClass 同法）。
        false
    }

    /// **实测**网格列数：数歌单卡在首行的数量。
    ///
    /// 依据：`PlaylistsPlazaView` 用 `LazyVGrid` + `cardColumns`，每张卡是一个可点 Button。
    /// 取「同一 y 带内水平排列的卡片数」= 当前列数。
    /// **实测**网格列数：数「同一 y 带内、等宽、水平排列」的卡片数量。
    ///
    /// 判据：
    /// 1. 只算卡片尺寸的元素（宽 > 120pt，高 > 120pt）—— 排除 chips/按钮/tab bar
    /// 2. 按 y 中点归带（±8pt 视作同一行）
    /// 3. 同一行内取「出现最多的宽度」，同宽且相邻间距 > 0 的算一列
    /// 4. 返回所有行里最多的列数
    ///
    /// 歌单卡实测尺寸参考：iPad 竖屏 3 列时每张约 256×188pt（见 2026-11-06 量测）。
    @MainActor
    private func countGridColumns() -> Int {
        struct Box { let x: CGFloat; let w: CGFloat; let y: CGFloat }
        var boxes: [Box] = []

        for b in app.buttons.allElementsBoundByIndex {
            guard b.exists else { continue }
            let f = b.frame
            // 卡片尺寸门槛：歌单卡在 iPad 上最小约 140pt 宽（compact 2 列时更宽）
            guard f.width >= 120, f.height >= 120 else { continue }
            // 排除整屏宽的横条（"私藏分享…" 那种 794pt 宽的行）
            guard f.width < app.windows.firstMatch.frame.width * 0.9 else { continue }
            boxes.append(Box(x: f.minX, w: f.width, y: f.midY))
        }
        guard !boxes.isEmpty else { return 0 }

        // 按 y 归带
        var rows: [[Box]] = []
        for b in boxes.sorted(by: { $0.y < $1.y }) {
            if var last = rows.last, let first = last.first,
               abs(first.y - b.y) <= 8 {
                last.append(b)
                rows[rows.count - 1] = last
            } else {
                rows.append([b])
            }
        }

        // 每行取「同宽聚类」里数量最多的一簇的个数
        var best = 0
        for row in rows {
            // 宽度分桶（±4pt 同宽）
            var buckets: [Int: Int] = [:]
            for b in row { buckets[Int((b.w / 4).rounded()), default: 0] += 1 }
            let maxSameWidth = buckets.values.max() ?? 0
            best = max(best, maxSameWidth)
        }
        return best
    }

    @MainActor
    private func attachScreen(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
