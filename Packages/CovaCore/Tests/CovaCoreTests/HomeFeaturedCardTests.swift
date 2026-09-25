import Foundation
import XCTest

@testable import CovaCore

/// 01 §3「今日推荐歌单大卡」的取值面（对应 `HomeSectionFacts.swift` 的 `HomeFeaturedCard`）。
///
/// 只钉判据层：选哪一张卡、元信息那句话说成什么样、遮罩占多高。**封面到底裁不裁得对**
/// 属于 body，本目标没有 UI 快照框架，不在这里声称（同 `SessionRowGeometryTests` 的口径）。
final class HomeFeaturedCardTests: XCTestCase {

    /// 线上真实键集的最小样本（2026-09-25 只读核对 `GET /api/playlists`：条目**没有**
    /// `featured`/`isFeatured`/`pinned` 任何一个 ⇒ "第一条精选"只能是服务端顺序的第一条）。
    private func playlists(_ json: String) throws -> [PlaylistDto] {
        try JSONDecoder().decode(PlaylistListDto.self, from: Data(json.utf8)).playlists
    }

    private func twoPlaylists() throws -> [PlaylistDto] {
        try playlists("""
        {"playlists":[
          {"id":"pl-1","title":"Road Trip","titleCn":"出门远行","scene":null,"trackCount":12,"totalDuration":1921},
          {"id":"pl-2","title":"Late Drive","titleCn":"夜色巡航","scene":"短视频/Vlog","trackCount":8,"totalDuration":600}
        ]}
        """)
    }

    /// §数据源：取第一条，**不重排也不跳过**脏行（跳过等于把"第一条"改成客户端挑的）。
    func testHeroIsServerOrderFirst() throws {
        let all = try twoPlaylists()
        XCTAssertEqual(HomeFeaturedCard.hero(of: all)?.id, "pl-1")
        XCTAssertNil(HomeFeaturedCard.hero(of: []))
    }

    /// §3「曲数 · 总时长」：两件都在 ⇒ 一行；只有一件 ⇒ 只说那一件；都没有 ⇒ `nil`
    /// （整段不渲染，而不是印一个"0 首"）。
    func testMetaLineOnlySaysWhatTheBackendGave() throws {
        XCTAssertEqual(HomeFeaturedCard.metaLine(trackCount: 12, totalDuration: 1921), "12 首 · 约 32 分")
        XCTAssertEqual(HomeFeaturedCard.metaLine(trackCount: 12, totalDuration: nil), "12 首")
        XCTAssertEqual(HomeFeaturedCard.metaLine(trackCount: 12, totalDuration: 0), "12 首")
        XCTAssertEqual(HomeFeaturedCard.metaLine(trackCount: nil, totalDuration: 3600), "约 1 小时 0 分")
        XCTAssertNil(HomeFeaturedCard.metaLine(trackCount: nil, totalDuration: nil))
        XCTAssertNil(HomeFeaturedCard.metaLine(trackCount: nil, totalDuration: .nan))
    }

    /// 时长的非法输入一律当作"没有这一件"：负数、NaN、inf 都不配变成一个读数。
    func testDurationRejectsUnreadableValues() {
        XCTAssertNil(HomeFeaturedCard.durationText(-120))
        XCTAssertNil(HomeFeaturedCard.durationText(.infinity))
        XCTAssertNil(HomeFeaturedCard.durationText(45))       // 不足 1 分钟 ⇒ 不说"约 0 分"
        XCTAssertEqual(HomeFeaturedCard.durationText(7_500), "约 2 小时 5 分")
    }

    /// §3 + components §2 的几何档：200 高、44 播放钮（= TG-03 最小触控档）、遮罩带占 45% 高。
    func testHeroGeometryMatchesSpecNumbers() {
        XCTAssertEqual(HomeFeaturedCard.heroHeight, 200)
        XCTAssertEqual(HomeFeaturedCard.playButtonSide, 44)
        XCTAssertEqual(HomeFeaturedCard.scrimHeightRatio, 0.45, accuracy: 0.0001)
    }

    /// 遮罩强度是**缺口 TG-40/TG-12 的降级值**（tokens.json 里至今没有遮罩档）：
    /// 它必须是个可说的中间值，不能是"看不见"(0) 也不能把整张封面涂死(1)。
    func testScrimAlphaIsABoundedSingleValue() {
        XCTAssertGreaterThan(HomeFeaturedCard.scrimMaxAlpha, 0)
        XCTAssertLessThan(HomeFeaturedCard.scrimMaxAlpha, 1)
    }
}
