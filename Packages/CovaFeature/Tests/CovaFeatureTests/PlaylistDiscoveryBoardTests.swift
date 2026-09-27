import CovaCore
import CovaFeature
import XCTest

/// §5 P3 读面的**判据面**（网络腿本身不在这里测：它只是 `client.get`，
/// 真正会骗人的是"这张卡跳哪"与"这一源给不给 chips"这两格）。
final class PlaylistDiscoveryBoardTests: XCTestCase {

    // 卡一律**从 JSON 解出来**，不调成员初始化器：`PlaylistDto` 的字段是 `public let`
    // 而它没有公开的成员初始化器（合成的是 internal）⇒ 走解码这条路才是真的走线上形状。
    // 用 JSONSerialization 拼，是为了不在测试里手写转义（上一版手写的引号是坏的：
    // 它让 try! 直接崩掉，五条用例一起红 —— 那是测试自己的错，不是判据的错）。
    private func pick(
        id: String = "p-1", href: String?, source: String?
    ) -> PlaylistPickDto {
        var object: [String: Any] = ["id": id, "title": "T"]
        if let source { object["source"] = source }
        if let href { object["href"] = href }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(PlaylistPickDto.self, from: data)
    }

    func testOfficialCardGoesToTheOfficialDetailRoute() {
        XCTAssertEqual(
            PlaylistBoard.destination(for: pick(href: "/playlists/p-1", source: "official")),
            .officialPlaylist("p-1")
        )
    }

    func testSharedCardGoesToTheShareRouteWithTheTokenFromHref() {
        XCTAssertEqual(
            PlaylistBoard.destination(for: pick(id: "up-9", href: "/share/playlist/tk-abc", source: "shared")),
            .sharedPlaylist("tk-abc"),
            "分享腿的 id 是用户歌单 id，拿它打官方详情只会 404 ⇒ 目标只能来自 href 里的 token"
        )
    }

    func testSharedCardWithoutAusableHrefIsNotTappable() {
        for href in [nil, "", "/share/playlist/", "/share/playlist/a/b", "/playlists/up-9"] {
            let card = pick(id: "up-9", href: href, source: "shared")
            XCTAssertEqual(
                PlaylistBoard.destination(for: card), .nowhere,
                "这一格不许退化成'先按官方试一下'：\(String(describing: href))"
            )
        }
    }

    func testUnrecognisedSourceIsNowhereRatherThanAGuess() {
        // 服务端多一类来源（partner 之类）时，猜它是官方 = 打错端点；猜它是分享 = 编一个 token。
        XCTAssertEqual(
            PlaylistBoard.destination(for: pick(href: "/whatever/1", source: "partner")), .nowhere
        )
        XCTAssertEqual(
            PlaylistBoard.destination(for: pick(href: "/whatever/1", source: nil)), .nowhere
        )
    }

    func testOfficialCardWithAnEmptyIDIsNotTappable() {
        XCTAssertEqual(
            PlaylistBoard.destination(for: pick(id: "", href: "/playlists/", source: "official")),
            .nowhere
        )
    }

    func testOnlyTheOfficialBoardShowsSceneChips() {
        XCTAssertTrue(PlazaSource.official.showsSceneChips)
        // daily 与 public 两支的投影里都没有 `scene`（逐条核过 web 的 select）
        // ⇒ 给一排点了必然为空的分类，比不给更坏。
        XCTAssertFalse(PlazaSource.daily.showsSceneChips)
        XCTAssertFalse(PlazaSource.shared.showsSceneChips)
    }

    func testBoardLabelsAreMachineNamesNotScreenCopy() {
        // 段控件的标签必须是中文那三个；rawValue 是机器名，不许直接上屏。
        XCTAssertEqual(
            PlazaSource.allCases.map(\.label), ["官方歌单", "每日推荐", "歌单广场"]
        )
        XCTAssertNotEqual(PlazaSource.daily.rawValue, PlazaSource.daily.label)
    }
}
