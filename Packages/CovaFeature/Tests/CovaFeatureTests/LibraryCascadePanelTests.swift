import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 03 级联面板里**屏上说了算**的几条判据：面板高度档、无结果文案、超限话术、本屏新增文案。
///
/// 说清覆盖边界：SwiftUI 的装配（`body` 有没有真的取用这些值、三栏有没有真的画出来）
/// 不在本文件覆盖之内 —— 这个测试目标没有 UI 快照框架，声称覆盖了 body 就是假话。
/// 级联的判断本身（维度表、建树、选择态、请求编码）在 CovaCore 侧
/// `LibraryFilterCascadeTests` 里逐条钉着，这里只补 CovaFeature 这一层的出口判据。
final class LibraryCascadePanelTests: XCTestCase {

    // MARK: - §2 面板高度档

    /// 03 §2 要的是「modal sheet，占屏 70%」，AX 档（≥AX1）必须近全屏 ——
    /// 放大字下 70% 会把词条行挤出可视区（07 §6 同一判据）。
    func testCascadePanelIsSeventyPercentAndNearFullInAX() {
        XCTAssertEqual(
            LibraryView.cascadeDetents(axLayout: false),
            [.fraction(0.7), .fraction(0.92)]
        )
        XCTAssertEqual(LibraryView.cascadeDetents(axLayout: true), [.large])
    }

    func testSortAndDimensionSheetsAlsoHonourAXLayout() {
        XCTAssertEqual(LibraryView.sortDetents(axLayout: false), [.fraction(0.42)])
        XCTAssertEqual(LibraryView.sortDetents(axLayout: true), [.large])
        XCTAssertEqual(LibraryView.dimensionListDetents(axLayout: false), [.fraction(0.5)])
        XCTAssertEqual(LibraryView.dimensionListDetents(axLayout: true), [.large])
    }

    // MARK: - §2 末 无结果态

    /// 没有筛选时不该劝人「清除」——没东西可清，那颗钮点了只会让人以为刚才的筛选还在。
    func testEmptyStateDoesNotOfferClearWhenNothingIsFiltered() {
        XCTAssertNil(LibraryView.emptyStateHint(selectionEmpty: true))
        XCTAssertNil(LibraryView.emptyStateActionTitle(selectionEmpty: true))
        XCTAssertEqual(LibraryView.emptyStateHint(selectionEmpty: false), "试试放宽条件")
        XCTAssertEqual(LibraryView.emptyStateActionTitle(selectionEmpty: false), "清除全部筛选")
    }

    // MARK: - 超限话术

    /// 点选被上限拒绝时必须报出**上限本身**与下一步（只说「太多了」等于没说）。
    func testLimitToastNamesTheCeilingAndTheNextStep() {
        let dimension = LibraryFilterDimension(
            id: "genre", title: "风格", terms: [], childDimensionID: "subgenre"
        )
        let copy = LibraryView.limitToast(for: dimension)
        XCTAssertTrue(copy.contains("风格"), copy)
        XCTAssertTrue(copy.contains("\(LibraryFilterSelection.maxValuesPerDimension)"), copy)
        XCTAssertTrue(copy.contains("先移除一项"), copy)
    }

    // MARK: - D12：本屏新增文案的本地地板

    /// 门禁脚本 `Scripts/d12-copy-check.sh` 扫的是全仓字面量；这一条只钉**本屏这条 UI 真能
    /// 打印出来的那批字符串**（排序档名、维度名、面板按钮、计数文案），因为它们是拼出来的、
    /// 静态扫描看不见运行时拼接的那一半。v1.0 不含任何购买/充值入口（D12），
    /// 下载入口连**构造**都不该有。
    func testScreenPrintableCopyCarriesNoBillingOrDownloadWording() {
        let banned = ["购买", "充值", "支付", "付款", "升级", "价格", "下单", "订阅", "下载", "¥"]
        var printed: [String] = [
            "已选：", "清除全部", "排序", "完成（已选 3）", "清除", "＋ 更多", "全部筛选维度",
            "上一层", "这一级没有词条", "已加载全部", "没有符合条件的曲目", "搜索场景词条",
        ]
        printed += LibrarySort.allCases.flatMap { [$0.label, $0.detail] }
        printed += LibraryFilterSchema.layout.map(\.title)
        printed += ["风格", "场景", "情绪"]
        printed += [
            LibraryView.emptyStateHint(selectionEmpty: true) ?? "",
            LibraryView.emptyStateActionTitle(selectionEmpty: true) ?? "",
            LibraryResultCount.text(total: 1248) ?? "",
            LibraryView.limitToast(
                for: LibraryFilterDimension(id: "mood", title: "情绪", terms: [], childDimensionID: nil)
            ),
        ]
        for text in printed {
            for word in banned {
                XCTAssertFalse(text.contains(word), "本屏文案「\(text)」含禁词「\(word)」")
            }
        }
    }
}
