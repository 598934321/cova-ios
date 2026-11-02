import CovaUI
import XCTest

@testable import CovaFeature

/// t74c：登录/播放/播放全部对齐 web 2.77.75 的中性胶囊（白底深字细描边、`rounded-full`）。
/// 只钉可静态化的判据：形状裁决与 50pt 主钮高度；配色是否摆对由 Xcode 预览/截图验收。
final class NeutralCTAAlignmentTests: XCTestCase {
    /// brand 档一律胶囊；中性档默认仍 `radius.control`，显式 `capsule: true` 才胶囊。
    func testCapsuleDecision() {
        XCTAssertTrue(CovaButton.usesCapsule(style: .brand, capsule: false))
        XCTAssertTrue(CovaButton.usesCapsule(style: .primary, capsule: true))
        XCTAssertFalse(CovaButton.usesCapsule(style: .primary, capsule: false))
        XCTAssertFalse(CovaButton.usesCapsule(style: .secondary, capsule: false))
    }

    /// 游客引导「登录」与歌单「播放全部」保持 50pt 主钮高（TG-07），只换配色不换几何。
    func testGuestGuideAndPlayAllKeepPrimaryHeight() {
        XCTAssertEqual(ShellMetrics.primaryControlHeight, 50)
        XCTAssertEqual(PlaylistPrimaryCapsuleButton.height, 50)
    }
}

/// t74c：首页问候首行与 web `{salutation}，{displayName}` 逐字（游客也保留逗号）。
final class HomeGreetingAlignmentTests: XCTestCase {
    func testGreetingKeepsCommaWithoutName() {
        XCTAssertEqual(HomeComposerCopy.greetingLine(salutation: "早上好", name: nil), "早上好，")
        XCTAssertEqual(HomeComposerCopy.greetingLine(salutation: "晚上好", name: "小洪"), "晚上好，小洪")
    }
}

/// t74c：同栈 push 页签根屏 = 回根（不叠第二个广场 / 会话列表）。
final class TabRootPushTests: XCTestCase {
    func testPushingTabRootOnItsOwnStackPopsToRoot() {
        let session = AppSession()
        session.selectTab(.playlists)
        session.push(.playlist("p1"))
        session.push(.plaza)
        XCTAssertEqual(session.selection, .playlists)
        XCTAssertEqual(session.paths[.playlists] ?? [], [])
    }
}
