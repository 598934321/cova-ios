import CovaUI
import SwiftUI
import XCTest

/// COVA-142 · 布局不退的**实测**判据（不是估算）。
///
/// 做法：把组件放进 `UIHostingController`，在固定宽度下取 `sizeThatFits`，
/// 对比「带标识 / 不带标识」两种形态的高度。
///
/// 为什么必须实测：`CovaListRow` 的行高由**取大的那个**决定——封面 40pt 或
/// 「标题 + 副标题」两行文本。徽标挂在副标题行尾会把那一行撑高到 17pt 左右，
/// 但**只要不越过 40pt 的封面高度，行高就不变**。这个结论靠算容易算错
/// （字阶、行距、padding 叠加都在里面），所以直接量。
final class AIMarkLayoutTests: XCTestCase {
    private let width: CGFloat = 393

    @MainActor
    private func height<V: View>(_ view: V) -> CGFloat {
        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return size.height
    }

    /// 用例 1：**真实调用形态**（都有 40pt 封面）下，徽标不改行高。
    /// 7 处走 `CovaListRow` 的界面全部传了 `artwork`（无封面的曲目也传
    /// `CovaArtwork` 兜底块，仍是 40pt），所以这条就是那 7 处的共同结论。
    @MainActor
    func testListRowWithArtworkKeepsRowHeight() {
        let art = CovaArtwork(url: nil, title: "午夜霓虹下的漫步")
        let plain = CovaListRow(title: "午夜霓虹下的漫步", subtitle: "林知夏 · 03:42 · 92 BPM", artwork: art) {
            EmptyView()
        } action: {}
        let marked = CovaListRow(
            title: "午夜霓虹下的漫步", subtitle: "林知夏 · 03:42 · 92 BPM",
            artwork: art, aiOrigin: .aiGenerated
        ) {
            EmptyView()
        } action: {}

        let h0 = height(plain)
        let h1 = height(marked)
        print("[142] CovaListRow（带 40pt 封面，真实形态）行高：\(h0)pt → \(h1)pt（Δ\(h1 - h0)）")
        XCTAssertEqual(h1, h0, accuracy: 0.5, "徽标挂在副标题行尾，不许改行高")
        XCTAssertGreaterThanOrEqual(h1, 44, "行高必须仍在 44pt 触控红线之上")
    }

    /// 用例 1b：**不带封面**的形态（当前无调用点）会有 +3pt。
    ///
    /// 如实钉住而不是假装 Δ0：没有 40pt 封面兜底时，行高由文本撑开，
    /// 徽标（17.33pt）比副标题文本行（13.33pt）高 ⇒ 那一行变高 4pt、整行 +3pt。
    /// 之所以不为此改设计：①本仓没有这种调用点（`grep` 全部 CovaListRow 调用都传 artwork）；
    /// ②要压到 Δ0 就得给徽标去掉纵向 padding，胶囊会贴字、看得像故障。
    /// 将来若真出现无封面行，这条用例会提示「那里会 +3pt」。
    @MainActor
    func testListRowWithoutArtworkGrowsBy3PointsAsDocumented() {
        let plain = CovaListRow(title: "午夜霓虹下的漫步", subtitle: "林知夏 · 03:42", artwork: nil) {
            EmptyView()
        } action: {}
        let marked = CovaListRow(
            title: "午夜霓虹下的漫步", subtitle: "林知夏 · 03:42", artwork: nil, aiOrigin: .aiGenerated
        ) {
            EmptyView()
        } action: {}

        let delta = height(marked) - height(plain)
        print("[142] CovaListRow（无封面，当前无调用点）行高 Δ\(delta)pt")
        XCTAssertEqual(delta, 3.0, accuracy: 1.0, "无封面形态的增高已登记在此，超出 1pt 说明徽标尺寸变了")
    }

    /// 用例 3：徽标自身尺寸——四字 + caption2 + 左右 6pt padding。
    /// 钉上限是因为它要被塞进副标题行；一旦有人把字号调大，7 处列表会一起变挤。
    @MainActor
    func testBadgeIntrinsicSizeStaysCompact() {
        let badge = AIOriginBadge(.aiGenerated)
        let host = UIHostingController(rootView: badge)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))
        print("[142] AIOriginBadge 内在尺寸：\(size.width)×\(size.height)pt")
        XCTAssertLessThanOrEqual(size.height, 20, "徽标高不得超过 20pt（否则撑高副标题行）")
        XCTAssertLessThanOrEqual(size.width, 70, "徽标宽不得超过 70pt（否则窄行放不下）")
    }

    /// 用例 4：`aiOrigin == nil` 时徽标不占任何空间（= 完全不渲染），
    /// 这样歌单卡/会员权益行改写前端行为不变。
    ///
    /// 第一版这里写成 `Text("")`，实测 **12×18pt** —— 一个空 Text 带着固有尺寸，
    /// 在那些行里留下看不见的空隙。改成 `EmptyView()` 后为 0×0。这条用例就是那次修正的守卫。
    @MainActor
    func testNilOriginRendersNothing() {
        let nilBadge = AIOriginBadge(nil)
        let host = UIHostingController(rootView: nilBadge)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))
        print("[142] AIOriginBadge(nil) 尺寸：\(size.width)×\(size.height)pt")
        XCTAssertLessThanOrEqual(size.height, 1, "传 nil 时不应留下占位高度")
        XCTAssertLessThanOrEqual(size.width, 1, "传 nil 时不应留下占位宽度")

        let nilNotice = AIOriginNotice(nil)
        let noticeHost = UIHostingController(rootView: nilNotice)
        let noticeSize = noticeHost.sizeThatFits(in: CGSize(width: 200, height: 200))
        print("[142] AIOriginNotice(nil) 尺寸：\(noticeSize.width)×\(noticeSize.height)pt")
        XCTAssertLessThanOrEqual(noticeSize.height, 1, "L2 传 nil 同样不许留占位")
    }

    /// 用例 5：L2 整句在 393pt 宽下**不折行**（折行会让播放器信息区多出一行）。
    @MainActor
    func testNoticeFitsOnOneLineAtPhoneWidth() {
        let host = UIHostingController(rootView: AIOriginNotice(.aiGenerated))
        let size = host.sizeThatFits(in: CGSize(width: width - 40, height: .greatestFiniteMagnitude))
        print("[142] AIOriginNotice 在 \(width - 40)pt 宽下：\(size.width)×\(size.height)pt")
        XCTAssertLessThanOrEqual(size.height, 20, "整句在手机宽度下不许折成两行")
    }
}
