import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 14 联系区的判据（§7 的三条本地常量 + §6 的读法串 + mailto 的形状）。
/// 只钉判据层：`body` 有没有把它们接上屏，本目标没有 UI 快照框架，不在此声称。
final class EnterpriseContactCopyTests: XCTestCase {

    func testContactConstantsStayWhereSpecPinnedThem() {
        // 邮箱由 `inventory.md` 行 14 钉死；官网只有 https 生产出口（AGENTS 硬边界 2）。
        XCTAssertEqual(EnterpriseCopy.contactEmail, "enterprise@covalink.cn")
        XCTAssertEqual(EnterpriseCopy.siteURLString, "https://covalink.cn/enterprise")
        XCTAssertEqual(EnterpriseCopy.siteLabel, "covalink.cn/enterprise")
        XCTAssertTrue(EnterpriseCopy.siteURLString.hasPrefix("https://covalink.cn/"))
    }

    /// §7「**不**拼任何用户参数」：mailto 只带收件人，没有 query / fragment、也没有第二个地址。
    func testMailtoCarriesOnlyTheAddressAndNoUserParameters() {
        guard let url = EnterpriseCopy.mailto() else {
            return XCTFail("钉死的邮箱地址必须能构成一条 mailto")
        }
        XCTAssertEqual(url.scheme, "mailto")
        // mailto 是**非层化** URL：地址不住在 host 里，`mailto:` 之后整段就是收件人。
        XCTAssertEqual(url.host, nil)
        XCTAssertEqual(url.query, nil)
        XCTAssertEqual(url.fragment, nil)
        XCTAssertEqual(url.absoluteString, "mailto:enterprise@covalink.cn")
        XCTAssertNil(EnterpriseCopy.mailto(""))   // 空地址不构成一条 mailto（按了没反应的按钮）
    }

    /// §6 的朗读顺序串（逐字）。
    func testSpokenLabelsMatchSpecOrdering() {
        XCTAssertEqual(
            EnterpriseCopy.emailSpoken(), "发送邮件到 enterprise@covalink.cn，链接，将打开邮件程序")
        XCTAssertEqual(
            EnterpriseCopy.siteSpoken, "打开官网企业服务页，链接，将在系统浏览器中打开")
        XCTAssertEqual(EnterpriseCopy.projectLine, "你当前套餐可提交项目需求")
    }

    /// §8 禁词表（14 与 13 同表）：helper 产出的每一串都过一遍。
    func testNoContactCopyContainsD12BannedWording() {
        let banned = [
            "购买", "充值", "支付", "立即开通", "升级", "订阅管理", "付款", "价格",
            "元/月", "限时", "优惠", "恢复购买", "报价", "下单", "立即签约", "免费试用申请", "¥",
        ]
        let produced = [
            EnterpriseCopy.contactEmail, EnterpriseCopy.siteLabel, EnterpriseCopy.siteURLString,
            EnterpriseCopy.emailSpoken(), EnterpriseCopy.siteSpoken, EnterpriseCopy.projectLine,
        ]
        for text in produced {
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(text) 命中禁词「\(word)」")
            }
        }
    }
}
