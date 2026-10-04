import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 11「我的」的**文案与读法判据**（`MineCopy` + `CovaPlan.userLabel`），不是视图树。
///
/// 为什么只钉这一层：本目标没有 UI 快照框架，`body` 是否真把某个 helper 接上了屏
/// **不在覆盖之内，也不在这里声称**。这些 helper 守的是两类"错了会骗人"的口径 ——
/// 后端原值上屏（`计划：pro`），以及 §7 的不编造边界（缺字段被印成 `0`/占位符）。
final class MineCopyAndPlanLabelTests: XCTestCase {

    // MARK: - 套餐四档中文（11 §8 唯一源；13 会员页与 04 引用同一张表）

    func testEveryPlanCaseSurfacesChineseWithNoASCIILetters() {
        let all: [CovaPlan] = [.free, .creator, .pro, .enterprise]
        XCTAssertEqual(all.map(\.userLabel), ["免费版", "创作版", "专业版", "企业版"])
        for plan in all {
            let label = plan.userLabel
            XCTAssertFalse(label.isEmpty)
            // 本仓这一族的硬判据：显示面**一个 ASCII 字母都不许有**（`pro`/`creator` 上屏就是本轮的起点）。
            XCTAssertFalse(
                label.unicodeScalars.contains(where: { $0.isASCII && Character($0).isLetter }),
                "\(plan.rawValue) → \(label)")
            XCTAssertNotEqual(label, plan.rawValue, "显示面不得回到 wire 值")
        }
    }

    // MARK: - §7 / §8 不编造边界

    func testBalanceNeverConfusesMissingWithZero() {
        XCTAssertEqual(MineCopy.balance(nil), "--")
        XCTAssertEqual(MineCopy.balance(-1), "--")       // §8：可疑数字不上屏
        XCTAssertEqual(MineCopy.balance(0), "0")         // 真实零值 ≠ 无数据
        XCTAssertEqual(MineCopy.balance(128), "128")
        // §8：零余额与满值**同构** —— 这一支多出来的字只能是数字本身，不许有催促话术。
        XCTAssertEqual(MineCopy.balance(0).count, 1)
    }

    func testExpiryRowDegradesToNothingNotPlaceholder() {
        // 12:00Z：任何真实时区偏移都不会把日期推到前一天，用例因此不依赖跑测机的 TZ。
        XCTAssertEqual(MineCopy.expiryText("2026-12-03T12:00:00Z"), "有效期至 2026年12月3日")
        XCTAssertNil(MineCopy.expiryText(nil))
        XCTAssertNil(MineCopy.expiryText(""))
        XCTAssertNil(MineCopy.expiryText("不是日期"))
        XCTAssertNil(MineCopy.expiryDateText("2026-12-03"))   // 非 ISO8601 ⇒ 不猜
    }

    func testCovaIdAndVersionRowsHaveNoPlaceholderShape() {
        // §6 逐字：「Cova 号，CV 8 F 2 K 3 A，可复制」——标签说人话，不念字段名
        // （2026-10-01 C3：上一版把 `covaId` 这个英文字段名直接带上屏、带上读屏）。
        XCTAssertEqual(MineCopy.covaIdRowSpoken("CV-8F2K3A"), "Cova 号，CV 8 F 2 K 3 A，可复制")
        XCTAssertEqual(MineCopy.covaIdSpoken("CV-8F2K3A"), "CV 8 F 2 K 3 A")
        // 没有字母前缀可保的形状 ⇒ 全部逐字符（spec 只钉了带连字符那一种，不假装认识别的）。
        XCTAssertEqual(MineCopy.covaIdSpoken("CV8F2K3A"), "C V 8 F 2 K 3 A")
        XCTAssertEqual(MineCopy.covaIdSpoken(""), "")
        // 屏上不再出现字段名本身（行标签与读屏同一口径）。
        XCTAssertFalse(MineCopy.covaIdRowSpoken("CV-8F2K3A").contains("covaId"))
        // §3.H / §7：两枚版本键任一取不到 ⇒ 整行不渲染（不印「版本 —」）。
        XCTAssertEqual(MineCopy.versionValue(short: "0.2.69", build: "80"), "0.2.69 (80)")
        XCTAssertEqual(MineCopy.versionSpoken(short: "0.2.69", build: "80"), "版本 0.2.69，第 80 版")
        XCTAssertNil(MineCopy.versionValue(short: nil, build: "80"))
        XCTAssertNil(MineCopy.versionValue(short: "0.2.69", build: "  "))
        XCTAssertNil(MineCopy.versionSpoken(short: "", build: nil))
    }

    // MARK: - §6 的读法串（一行 = 一个元素）

    func testSpokenRowLabelsMatchSpecShape() {
        XCTAssertEqual(MineCopy.balanceSpoken(128), "余额，128 co，仅展示")
        XCTAssertEqual(MineCopy.balanceSpoken(nil), "余额，-- co，仅展示")
        XCTAssertEqual(MineCopy.planSpoken(.creator), "当前套餐，创作版")
        XCTAssertEqual(MineCopy.planSpoken(.enterprise), "当前套餐，企业版")
        // 2026-10-01 D12 修订：商业组是站内导航，读法不再带「前往官网了解」。
        XCTAssertEqual(MineCopy.commerceSpoken("会员权益"), "会员权益")
        XCTAssertEqual(MineCopy.commerceSpoken("企业服务"), "企业服务")
    }

    /// §9 验收第 7 条：版本行显示的正是 `project.yml` 的两枚键 —— 装配真给了键，
    /// helper 就必须能读到（读到什么值随版本递增变，所以钉的是"读得到且形状对"）。
    func testBundleVersionIsReadableFromTheRunningBundle() {
        let pair = MineCopy.bundleVersion()
        guard let short = pair.short, let build = pair.build else {
            return XCTFail("宿主未装配 CFBundleShortVersionString/CFBundleVersion")
        }
        XCTAssertFalse(short.isEmpty)
        XCTAssertFalse(build.isEmpty)
        XCTAssertEqual(MineCopy.versionValue(short: short, build: build), "\(short) (\(build))")
    }
}
