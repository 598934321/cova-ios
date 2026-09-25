import Foundation
import XCTest

@testable import CovaCore

/// 01 §6「AI 音乐人专栏」的去重面（对应 `HomeSectionFacts.swift` 的 `HomeArtistRail`）。
///
/// §6 写着内容源是 A01–A15、接口面是 `artistId` 筛选 tracks —— 契约里**没有**艺人端点，
/// 所以这一栏的人设只能从已取到的曲目内嵌 `artist` 去重。这一层钉的就是那一步去重：
/// 谁进栏、谁不进、什么顺序。它不许变成"看起来像 15 位"的 15 个空位。
final class HomeArtistRailTests: XCTestCase {

    /// `TrackDto` 的必填集（其余可空键一律不发；可空字段缺席就是缺席）。
    private func track(id: String, artist: [String: Any]) throws -> TrackDto {
        let payload: [String: Any] = [
            "id": id, "title": "t-" + id, "cover": "/c.png", "duration": 120, "bpm": 90,
            "audioUrl": "/a.mp3", "artist": artist, "scenes": [], "moods": [], "tags": [],
            "displayLabels": [], "waveformPeaks": [], "previewStart": 0, "previewEnd": 30,
            "highlightStart": 0, "highlightEnd": 30, "favoriteCount": 0,
            "vocalType": "instrumental", "energy": "低",
        ]
        return try JSONDecoder().decode(TrackDto.self, from: try Self.data(payload))
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        // `JSONSerialization` 只吃 Foundation 对象；这里的 `Any` 就是"测试自己拼的字典"。
        try JSONSerialization.data(withJSONObject: object)
    }

    private func artist(id: String, name: String = "Cova A07", nameCn: Any? = nil) -> [String: Any] {
        var object: [String: Any] = ["id": id, "name": name]
        if let nameCn { object["nameCn"] = nameCn }
        return object
    }

    /// 同一个人出现在多条曲目里 ⇒ 栏里只有他一格，且**保持首次出现**的顺序（不重排）。
    func testDedupKeepsFirstAppearanceOrder() throws {
        let tracks = [
            try track(id: "t1", artist: artist(id: "a1")),
            try track(id: "t2", artist: artist(id: "a2")),
            try track(id: "t3", artist: artist(id: "a1")),
            try track(id: "t4", artist: artist(id: "a3")),
        ]
        XCTAssertEqual(HomeArtistRail.artists(from: tracks).map(\.id), ["a1", "a2", "a3"])
    }

    /// 空 `id`（点进去无处可去）与两个名字都空（caption 无字可显）的行**不进栏**，
    /// 但**不**因此把后面的行顶上来冒充"更多人"。
    func testRowsThatCannotBecomeACellAreDropped() throws {
        let tracks = [
            try track(id: "t1", artist: artist(id: "")),
            try track(id: "t2", artist: artist(id: "a2", name: "  ")),
            try track(id: "t3", artist: artist(id: "a3", nameCn: "站内名")),
        ]
        XCTAssertEqual(HomeArtistRail.artists(from: tracks).map(\.id), ["a3"])
    }

    /// 名字优先级与 16 §3.C 同一条：`nameCn ?? name`；空白的 `nameCn` 不算"有中文名"。
    func testDisplayNamePrefersChineseThenFallsBackToNil() throws {
        let cn = try track(id: "t1", artist: artist(id: "a1", name: "Cova A07", nameCn: "夜航者"))
        XCTAssertEqual(HomeArtistRail.displayName(cn.artist), "夜航者")
        let blank = try track(id: "t2", artist: artist(id: "a2", name: "Cova A07", nameCn: "   "))
        XCTAssertEqual(HomeArtistRail.displayName(blank.artist), "Cova A07")
        let none = try track(id: "t3", artist: artist(id: "a3", name: "   "))
        XCTAssertNil(HomeArtistRail.displayName(none.artist))
    }

    /// 上限 = 15（§6 内容源写的 A01–A15）：多出来的一律不进，也不给一个"更多"的假入口。
    func testRailCapsAtTheA01ToA15Count() throws {
        var tracks: [TrackDto] = []
        for index in 0..<25 {
            tracks.append(try track(id: "t\(index)", artist: artist(id: "a-\(index)")))
        }
        XCTAssertEqual(HomeArtistRail.artists(from: tracks).count, HomeArtistRail.limit)
        XCTAssertEqual(HomeArtistRail.limit, 15)
        XCTAssertTrue(HomeArtistRail.artists(from: tracks, limit: 0).isEmpty)
    }

    /// §6 头像档 64pt。
    func testAvatarDiameterMatchesSpec() {
        XCTAssertEqual(HomeArtistRail.avatarDiameter, 64)
    }
}
