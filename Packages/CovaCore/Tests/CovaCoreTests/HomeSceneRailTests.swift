import Foundation
import XCTest

@testable import CovaCore

/// 01 §4「场景精选横滑卡」的分组判据（对应 `HomeSectionFacts.swift` 的 `HomeSceneRail`）。
///
/// 这一层存在的意义就是**可测**：§数据来源写的是「playlists 按 scene 分组」，
/// 而线上真实数据里 `scene` 是**可空的**（2026-09-25 只读核对 `GET /api/playlists`
/// 593 行：只有 101 行带非空 `scene`，共 23 个取值）。
/// 于是"分组"要么真按那一个字段分，要么就没有 —— 不许造桶、不许造场景名。
final class HomeSceneRailTests: XCTestCase {

    /// 用 `JSONSerialization` 拼载荷而不是手写插值串：这里要验的是**分组判据**，
    /// 不是"我能不能把 JSON 字符串写对"（后者已经用转义写到测试跑不动了）。
    private func playlists(_ scenes: [String?]) throws -> [PlaylistDto] {
        var items: [[String: String]] = []
        for (index, scene) in scenes.enumerated() {
            // 必填集合只有 `id`/`title`（`PlaylistDto.title` 是 non-optional）；
            // 其余键一律缺席：可空字段缺席就是缺席，不填默认值。
            var item: [String: String] = ["id": "pl-\(index)", "title": "t\(index)"]
            if let scene { item["scene"] = scene }
            items.append(item)
        }
        let data = try JSONSerialization.data(withJSONObject: ["playlists": items])
        return try JSONDecoder().decode(PlaylistListDto.self, from: data).playlists
    }

    /// §数据来源：没有场景的行**不进这一区**，也不给它们编一个「其他」桶。
    func testBlankAndMissingScenesAreDroppedNotBucketed() throws {
        let groups = HomeSceneRail.groups(of: try playlists(["运动", nil, "  ", ""]))
        XCTAssertEqual(groups.map(\.scene), ["运动"])
        XCTAssertEqual(groups.first?.playlists.count, 1)
        XCTAssertTrue(HomeSceneRail.groups(of: try playlists([nil, ""])).isEmpty)
    }

    /// 挑哪几组用服务端给的事实（该场景下有几条歌单），同数再按服务端顺序里首次出现的位置。
    func testGroupOrderIsBackedByCountsThenServerOrder() throws {
        let groups = HomeSceneRail.groups(of: try playlists([
            "通勤", "旅行", "旅行", "运动", "通勤", "旅行", "运动",
        ]))
        // 旅行 3 条最多；通勤与运动各 2 条 ⇒ 按"首次出现"排：通勤在运动之前。
        XCTAssertEqual(groups.map(\.scene), ["旅行", "通勤", "运动"])
        XCTAssertEqual(groups.map { $0.playlists.count }, [3, 2, 2])
    }

    /// 组内保持服务端原顺序（客户端不重排歌单本身）。
    func testWithinGroupOrderIsServerOrder() throws {
        let all = try playlists(["运动", "通勤", "运动", "运动"])
        let groups = HomeSceneRail.groups(of: all)
        XCTAssertEqual(groups.first?.scene, "运动")
        XCTAssertEqual(groups.first?.playlists.map(\.id), ["pl-0", "pl-2", "pl-3"])
    }

    /// 一屏装不下 23 个场景 ⇒ 封顶是 UI 取舍，但取舍必须落在可断言的数上。
    func testRailCapsGroupsAndCardsPerGroup() throws {
        var scenes: [String?] = []
        for group in 0..<9 {
            for _ in 0..<5 { scenes.append("g\(group)") }
        }
        let groups = HomeSceneRail.groups(of: try playlists(scenes))
        XCTAssertEqual(groups.count, HomeSceneRail.groupLimit)
        XCTAssertTrue(groups.allSatisfy { $0.playlists.count == HomeSceneRail.cardsPerGroup })
    }

    /// 非法的挑选参数不能变出内容（负数上限 ⇒ 空轨道，而不是 `prefix(-1)` 崩在那里）。
    func testNonPositiveLimitsYieldEmptyRail() throws {
        let all = try playlists(["运动", "通勤"])
        XCTAssertTrue(HomeSceneRail.groups(of: all, groupLimit: 0).isEmpty)
        XCTAssertTrue(HomeSceneRail.groups(of: all, cardsPerGroup: -3).isEmpty)
    }

    /// §4 的 140×140 是 spec 数字，钉住它而不是让它长在视图体里。
    func testCardSideMatchesSpec() {
        XCTAssertEqual(HomeSceneRail.cardSide, 140)
    }
}
