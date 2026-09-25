import CovaCore
import CovaUI
import SwiftUI
import XCTest

@testable import CovaFeature

/// 01 §5 徽标的**色档落点**（对应 `HomeView.swift` 的 `CreationBadgeFacts`）。
///
/// 为什么这一条要在 CovaFeature 里测而不是写进 CovaCore：判据本身（三档、`warning`/`success`/
/// `error` 的对应关系）在 core 那侧已经钉过了，这里钉的是**这一屏真的接到了那三个 token**——
/// 一个"逻辑对但配色错"的徽标（把失败画成 warning 橙）在 core 的测试里永远是绿的。
/// `body` 有没有把它摆在封面右上角，本目标没有 UI 快照框架，不在此声称。
final class HomeCreationBadgeFactsTests: XCTestCase {

    /// §5 逐字：生成中 `warning` / 完成 `success` / 失败 `error`。
    func testBadgeTonesMatchSpecTokens() {
        XCTAssertEqual(CreationBadgeFacts.color(.generating), CovaColor.warning)
        XCTAssertEqual(CreationBadgeFacts.color(.done), CovaColor.success)
        XCTAssertEqual(CreationBadgeFacts.color(.failed), CovaColor.error)
    }

    /// 三档两两不等：都指到同一个色（例如全 fallthrough 到 accent）在视觉上就是"没有状态区分"，
    /// 而这正是这一格存在的理由。
    func testTheThreeTonesAreMutuallyDistinct() {
        let tones = [
            CreationBadgeFacts.color(.generating),
            CreationBadgeFacts.color(.done),
            CreationBadgeFacts.color(.failed),
        ]
        XCTAssertEqual(Set(tones.map { String(describing: $0) }).count, 3)
    }

    /// 胶囊底的不透明度沿用仓里**已有**的那枚状态徽标（`PlayerViews` 的「生成候选 · 仅本人可见」
    /// 用的就是 12%）：同一族组件共用一个数，不每屏各挑一个。
    func testBadgeBackgroundReusesExistingBadgeAlpha() {
        XCTAssertEqual(CreationBadgeFacts.backgroundAlpha, 0.12)
    }

    /// 徽标只在后端真给了状态时才画（线上列表今天**不给** ⇒ 首页这一格今天没有徽标，
    /// 这是事实而不是缺漏：见 `HomeCreationGrid.statusFieldInListPayload`）。
    func testBadgeOnlyAppearsWhenBackendSentARecognisedStatus() throws {
        let data = Data(#"{"sessions":[{"id":"s1","title":"夜色巡航","status":"processing"}]}"#.utf8)
        let withStatus = try JSONDecoder().decode(StudioSessionListDto.self, from: data).sessions
        XCTAssertEqual(HomeCreationGrid.badge(forStatus: withStatus.first?.status), .generating)

        let bare = try JSONDecoder().decode(
            StudioSessionListDto.self,
            from: Data(#"{"sessions":[{"id":"s2","title":"没有状态这一格"}]}"#.utf8)
        ).sessions
        XCTAssertNil(HomeCreationGrid.badge(forStatus: bare.first?.status))
    }
}
