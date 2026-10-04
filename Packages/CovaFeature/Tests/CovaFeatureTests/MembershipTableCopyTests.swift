import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 13 权益对比表的判据（表常量、列序、色映射）。与 `MineCopyAndPlanLabelTests` 同样
/// 只钉**判据层**：`body` 有没有把它们接上屏，本目标没有 UI 快照框架，不在此声称。
final class MembershipTableCopyTests: XCTestCase {

    // MARK: - §7：表的"列"必须与枚举同集同序

    /// 列错位不会崩，只会把「支持」印到隔壁套餐头上 —— 那是这张表最贵的错，所以逐行钉。
    func testComparisonTableColumnsMatchEnumAndEveryRowHasOneValuePerColumn() {
        XCTAssertEqual(MembershipView.columns, [.free, .creator, .pro, .enterprise])
        XCTAssertEqual(MembershipView.planNames, MembershipView.columns.map(\.userLabel))
        XCTAssertEqual(MembershipView.planNames, ["免费版", "创作版", "专业版", "企业版"])
        XCTAssertFalse(MembershipView.rows.isEmpty)
        for row in MembershipView.rows {
            XCTAssertEqual(row.values.count, MembershipView.columns.count, row.label)
        }
    }

    /// §7 第 2 条 + 待裁决 3 + 2026-10-01 C4：额度类数字**没有契约来源** ⇒
    /// 「每月额度」那一行**整行不渲染**（四格「—」等于印了一行没有数据的数据）；
    /// 其余行也不许出现任何数字原值。
    func testNoRowIsAllDashesAndNoCellCarriesInventedNumbers() {
        XCTAssertNil(
            MembershipView.rows.first { $0.label.contains("额度") },
            "没有数据源的额度行不许留在表里（整行「—」是占位不是信息）"
        )
        XCTAssertNil(
            MembershipView.rows.first { $0.values.allSatisfy { $0 == "—" } },
            "全破折号的行是占位行，不许出现"
        )
        for row in MembershipView.rows {
            for value in row.values {
                XCTAssertFalse(
                    value.unicodeScalars.contains(where: { $0.isASCII && Character($0).isNumber }),
                    "\(row.label) 出现了数字原值 \(value)")
            }
        }
    }

    /// §3.C + §5：✕ 用 muted 而不是 error（缺能力不是错误），✓ 用 memberGold，
    /// 文字值（定制/—）用 secondary —— 表里不许出现没被 spec 点过的自造色。
    func testCellColorsCarryTheSpecifiedSemantics() {
        XCTAssertEqual(MembershipView.cellColor("支持"), CovaColor.memberGold)
        XCTAssertEqual(MembershipView.cellColor("不支持"), CovaColor.muted)
        XCTAssertNotEqual(MembershipView.cellColor("不支持"), CovaColor.error)
        XCTAssertEqual(MembershipView.cellColor("定制"), CovaColor.secondary)
        XCTAssertEqual(MembershipView.cellColor("—"), CovaColor.secondary)
    }

    // MARK: - D12 前哨（`Scripts/d12-copy-check.sh` 扫字面量，这里扫 helper 的产出）

    func testNoTableCopyContainsD12BannedWording() {
        let banned = [
            "购买", "充值", "支付", "立即开通", "升级", "订阅管理", "付款", "价格",
            "元/月", "限时", "优惠", "恢复购买", "报价", "下单", "立即签约", "免费试用申请", "¥",
        ]
        var produced = MembershipView.planNames
        for row in MembershipView.rows {
            produced.append(row.label)
            produced.append(contentsOf: row.values)
        }
        for text in produced {
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(text) 命中禁词「\(word)」")
            }
        }
    }
}
