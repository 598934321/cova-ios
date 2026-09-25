import CovaCore
import CovaUI
import XCTest

@testable import CovaFeature

/// 01 §6 那一栏的两件事：**头像腿**（R18-2 口径）与**去重后的栏内容**。
///
/// 为什么这一栏特别需要一条腿测试：§6 没有艺人端点（契约只有 `tracks` 的 `artistId` 筛选），
/// 所以整栏的人设都从曲目列表内嵌的 `artist.avatar` 来 —— 而线上那个字段
/// 2026-09-25 只读核对 `/api/tracks?page=1&pageSize=60` 是 **38/38 全部站内相对路径**。
/// 一条不经裁决的腿在这里 = 整栏 15 个圆位全部静默占位（R18-2 那个"一次请求都不发"的形状）。
final class HomeArtistRailLegTests: XCTestCase {

    /// 夹具里的三条曲目 ⇒ 三位音乐人（`ar-nil` 那一行有名字，所以照旧进栏，
    /// 只是它那一格由 `CovaArtwork` 自己显示"没给图"的占位）。
    private func fixtureTracks() throws -> [TrackDto] {
        try ArtworkFixture.decoded([TrackDto].self, key: "tracks")
    }

    /// §6 的去重：一次列表里同一个人出现多次 ⇒ 只占一格，顺序按首次出现。
    func testRailDeduplicatesTheEmbeddedArtists() throws {
        let single = try fixtureTracks()
        let doubled = single + single
        let once = HomeArtistRail.artists(from: single).map(\.id)
        XCTAssertEqual(once, ["ar-relative", "ar-absolute", "ar-nil"])
        XCTAssertEqual(HomeArtistRail.artists(from: doubled).map(\.id), once)
    }

    /// 站内相对（**线上这一栏的主流形态**）：补成生产 origin，查询串一个字节都不动。
    func testSiteRelativeAvatarLegResolvesToProductionOrigin() throws {
        let artist = HomeArtistRail.artists(from: try fixtureTracks())[0]
        XCTAssertEqual(artist.id, "ar-relative")
        XCTAssertResolved(
            HomeArtwork.artistAvatar(artist),
            equals: ArtworkFixture.production("/uploads/avatars/relative.png"),
            "§6 头像腿：站内相对必须补全后出站"
        )
    }

    /// 名单内的绝对地址照原样出去（不重写成生产 origin）。
    func testSanctionedAbsoluteAvatarLegPassesThrough() throws {
        let artists = HomeArtistRail.artists(from: try fixtureTracks())
        XCTAssertResolved(
            HomeArtwork.artistAvatar(artists[1]),
            equals: try ArtworkFixture.sanctioned("/avatars/absolute.png")
        )
    }

    /// 服务端这一行**没给**头像 ⇒ `.absent`：占位是正确行为，且**一次请求都不发**。
    /// 这一档与"给了但不可出站"必须可分辨（R18-2 分家的理由）。
    func testMissingAvatarLegIsAbsentNotAFailedFetch() throws {
        let artists = HomeArtistRail.artists(from: try fixtureTracks())
        XCTAssertAbsent(HomeArtwork.artistAvatar(artists[2]))
    }

    /// §6 的 64pt 头像档与那一格的排版地板：图不随字号放大（16 §AX 的同一句理由），
    /// 名字行比头像宽一点点，长名字留在自己那根柱子里。
    func testCellGeometryFollowsSpecNumberAndStaysBounded() {
        XCTAssertEqual(HomeArtistCell.side, 64)
        XCTAssertEqual(HomeArtistCell.side, CGFloat(HomeArtistRail.avatarDiameter))
        XCTAssertGreaterThan(HomeArtistCell.nameWidth, HomeArtistCell.side)
        XCTAssertLessThan(HomeArtistCell.nameWidth, HomeArtistCell.side * 2)
    }
}
