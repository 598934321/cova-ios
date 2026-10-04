@testable import CovaFeature
import CovaCore
import XCTest

/// 13 G 购买区 helper 的判据（`MembershipAndEnterprise.swift`）：
/// `alreadyOwned` 决定哪张卡不画购买钮，`displayTitle`/`displayPrice` 决定
/// 卡片印什么名什么价——三者都是纯函数，钉死语义而不是靠屏上看。
///
/// `@MainActor`：`MembershipView` 的静态成员带 View 的 actor 隔离。
@MainActor
final class MembershipPurchaseRowTests: XCTestCase {

    private func sub(_ productId: String, plan: String?) -> IapProductDto {
        IapProductDto(
            productId: productId, type: .subscription,
            displayName: nil, priceDisplay: nil, plan: plan)
    }

    // MARK: alreadyOwned

    /// 只有「订阅类 + 档位与登录用户一致」才算已拥有；其余一律画购买钮。
    func testAlreadyOwnedOnlyForMatchingSubscriptionPlan() {
        let creatorMonthly = sub("com.covalink.subscription.creator.monthly", plan: "creator")
        XCTAssertTrue(MembershipView.alreadyOwned(creatorMonthly, plan: .creator))
        XCTAssertFalse(MembershipView.alreadyOwned(creatorMonthly, plan: .pro))
        // co 包不是档位 ⇒ 永不"已拥有"（消费型本来就该能重复买）
        let pack = IapProductDto(
            productId: "com.covalink.credits.standard", type: .credits,
            displayName: nil, priceDisplay: nil, credits: 100)
        XCTAssertFalse(MembershipView.alreadyOwned(pack, plan: .creator))
        // 游客 / me 没回来 ⇒ 不拥有（不然"当前套餐"徽标会在没登录时乱亮）
        XCTAssertFalse(MembershipView.alreadyOwned(creatorMonthly, plan: nil))
        // plan 缺席或服务端发了不认识的档 ⇒ 不拥有
        XCTAssertFalse(MembershipView.alreadyOwned(sub("x.y", plan: nil), plan: .creator))
        XCTAssertFalse(MembershipView.alreadyOwned(sub("x.y", plan: "bogus"), plan: .creator))
    }

    // MARK: displayTitle / periodSuffix

    /// 展示名：镜像 `displayName` 优先；缺了拼「档位中文 + 周期」，绝不印 productId。
    func testDisplayTitlePrefersServerNameAndFallsBackToComposed() {
        let named = IapProductDto(
            productId: "p1", type: .credits,
            displayName: "标准包", priceDisplay: nil, credits: 100)
        XCTAssertEqual(MembershipView.displayTitle(named), "标准包")
        XCTAssertEqual(
            MembershipView.displayTitle(sub("x.monthly", plan: "creator")), "创作版 · 每月")
        XCTAssertEqual(
            MembershipView.displayTitle(sub("x.yearly", plan: "pro")), "专业版 · 每年")
        XCTAssertEqual(
            MembershipView.displayTitle(sub("x.lifetime", plan: "pro")), "专业版 · 一次性")
        // 未知档位：不瞎编档位名，只留下周期词（空洞如实话，不装认识）
        XCTAssertEqual(MembershipView.displayTitle(sub("x.yearly", plan: "bogus")), " · 每年")
        // co 包缺名：有量显「N co」，没量显「co 包」
        XCTAssertEqual(MembershipView.displayTitle(IapProductDto(
            productId: "c1", type: .credits, displayName: nil,
            priceDisplay: nil, credits: 500)), "500 co")
        XCTAssertEqual(MembershipView.displayTitle(IapProductDto(
            productId: "c2", type: .credits, displayName: nil,
            priceDisplay: nil)), "co 包")
    }

    /// productId 后缀 → 周期词；不认 `.monthly`/`.yearly` 以外的约定。
    func testPeriodSuffixMapsIdSuffixToCycleWord() {
        XCTAssertEqual(MembershipView.periodSuffix("a.b.monthly"), " · 每月")
        XCTAssertEqual(MembershipView.periodSuffix("a.b.yearly"), " · 每年")
        XCTAssertEqual(MembershipView.periodSuffix("a.b"), " · 一次性")
        // 裸 "monthly"（没有点号前缀）不算周期 ⇒ 一次性
        XCTAssertEqual(MembershipView.periodSuffix("monthly"), " · 一次性")
    }

    // MARK: displayPrice

    /// StoreKit `displayPrice` 唯一准绳；镜像 `priceDisplay` 只在 ASC 缺商品时兜底。
    func testDisplayPricePrefersStoreKitOverMirrorFallback() {
        let p = IapProductDto(
            productId: "p1", type: .credits, displayName: nil, priceDisplay: "¥30")
        XCTAssertEqual(MembershipView.displayPrice(p, prices: ["p1": "¥30.00"]), "¥30.00")
        XCTAssertEqual(MembershipView.displayPrice(p, prices: [:]), "¥30")
        let bare = IapProductDto(
            productId: "p2", type: .credits, displayName: nil, priceDisplay: nil)
        XCTAssertNil(MembershipView.displayPrice(bare, prices: [:]))
    }
}
